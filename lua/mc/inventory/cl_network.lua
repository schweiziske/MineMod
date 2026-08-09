--[[----------------------------------------------------------------------------
	Client inventory transport, ordered action queue and resynchronization.
------------------------------------------------------------------------------]]

MC = MC or {}

local State = MC.ClientInventory
local PROTOCOL_VERSION = 1
local SNAPSHOT_PART_BYTES = 30000
local SNAPSHOT_MAX_BYTES = 1024 * 1024
local BACKGROUND_ACTION = 65535

State.transfers = State.transfers or {}

local function emit( eventName, ... )
	if MC.RunEvent then MC.RunEvent( eventName, ... ) end
	if hook and hook.Run then hook.Run( string.gsub( eventName, "%.", "" ), ... ) end
end

function MC.RequestInventoryResync()
	local now = RealTime()
	if State.lastResyncRequest and now - State.lastResyncRequest < 0.5 then return false end
	State.lastResyncRequest = now
	net.Start( "mc_inventory_resync" )
	net.SendToServer()
	return true
end

local function failTransfer( transferId, reason )
	State.transfers[transferId] = nil
	State.lastError = reason
	MC.RequestInventoryResync()
	return false
end

net.Receive( "mc_inventory_sync_begin", function()
	local protocol = net.ReadUInt( 8 )
	local transferId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local rawBytes = net.ReadUInt( 32 )
	local compressedBytes = net.ReadUInt( 32 )
	local parts = net.ReadUInt( 16 )
	local hash = net.ReadString()
	local reason = net.ReadString()
	if protocol ~= PROTOCOL_VERSION or parts < 1 or parts > 64 or compressedBytes > SNAPSHOT_MAX_BYTES
	or rawBytes > SNAPSHOT_MAX_BYTES * 4 or #hash > 128 or #reason > 64 then
		failTransfer( transferId, "invalid_snapshot_begin" )
		return
	end
	State.transfers[transferId] = {
		startedAt = RealTime(),
		revision = revision,
		selected = selected,
		rawBytes = rawBytes,
		compressedBytes = compressedBytes,
		partsExpected = parts,
		parts = {},
		received = 0,
		bytes = 0,
		hash = hash,
		reason = reason,
	}
end )

net.Receive( "mc_inventory_sync_part", function()
	local transferId = net.ReadUInt( 16 )
	local index = net.ReadUInt( 16 )
	local length = net.ReadUInt( 16 )
	local chunk = net.ReadData( length )
	local transfer = State.transfers[transferId]
	if not transfer then return end
	if index < 1 or index > transfer.partsExpected or length < 1 or length > SNAPSHOT_PART_BYTES
	or type( chunk ) ~= "string" or #chunk ~= length or transfer.parts[index] then
		failTransfer( transferId, "invalid_snapshot_part" )
		return
	end
	transfer.parts[index] = chunk
	transfer.received = transfer.received + 1
	transfer.bytes = transfer.bytes + length
	if transfer.bytes > transfer.compressedBytes or transfer.bytes > SNAPSHOT_MAX_BYTES then
		failTransfer( transferId, "snapshot_size_exceeded" )
	end
end )

net.Receive( "mc_inventory_sync_end", function()
	local transferId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local transfer = State.transfers[transferId]
	if not transfer then return end
	State.transfers[transferId] = nil
	if revision ~= transfer.revision or transfer.received ~= transfer.partsExpected or transfer.bytes ~= transfer.compressedBytes then
		MC.RequestInventoryResync()
		return
	end
	local payload = table.concat( transfer.parts )
	local hash = util.SHA256 and util.SHA256( payload ) or util.CRC( payload )
	if hash ~= transfer.hash then MC.RequestInventoryResync() return end
	local json = util.Decompress( payload )
	if not json or #json ~= transfer.rawBytes then MC.RequestInventoryResync() return end
	local data = util.JSONToTable( json )
	local ok, err = MC.ApplyClientInventorySnapshot( data )
	if not ok then State.lastError = err MC.RequestInventoryResync() return end
	State.selected = transfer.selected
	emit( "MC.InventorySyncComplete", transfer.reason, State )
end )

local function pumpActions()
	if State.inflight or not State.session or #State.actions == 0 then return end
	local action = table.remove( State.actions, 1 )
	action.revision = State.revision
	State.inflight = action
	local messageName = action.kind == "creative_pick" and "mc_inventory_creative_pick" or "mc_inventory_action"
	net.Start( messageName )
		net.WriteUInt( State.session.containerId, 16 )
		net.WriteString( State.session.token )
		net.WriteUInt( action.revision, 32 )
		net.WriteUInt( action.actionId, 16 )
		if action.kind == "creative_pick" then
			net.WriteUInt( action.runtimeId, MC.ItemStackRuntimeIdBits )
			net.WriteUInt( action.count, 7 )
			net.WriteInt( action.targetSlot, 8 )
		else
			net.WriteUInt( action.input, 3 )
			net.WriteInt( action.slot, 16 )
			net.WriteInt( action.button, 8 )
		end
	net.SendToServer()
end

function MC.QueueInventoryInput( input, slot, button )
	if not State.session then return false, "inventory_not_open" end
	input = math.floor( tonumber( input ) or -1 )
	slot = math.floor( tonumber( slot ) or -999 )
	button = math.floor( tonumber( button ) or 0 )
	if input < 0 or input > 6 or ( slot ~= -999 and ( slot < 0 or slot >= 36 ) )
	or button < -128 or button > 127 then return false, "invalid_inventory_action" end
	if #State.actions >= 64 then return false, "inventory_action_queue_full" end
	local actionId = State.nextActionId % BACKGROUND_ACTION
	State.nextActionId = ( actionId + 1 ) % BACKGROUND_ACTION
	State.actions[#State.actions + 1] = {
		kind = "input",
		actionId = actionId,
		input = input,
		slot = slot,
		button = button,
	}
	pumpActions()
	return true, actionId
end

function MC.QueueCreativeInventoryPick( item, count, targetSlot )
	if not State.session or State.session.creative ~= true then return false, "creative_inventory_unavailable" end
	local definition = MC.GetItem( item )
	if not definition or definition.name == "minecraft:air" or definition.runtimeId == nil then return false, "unknown_item" end
	count = math.floor( tonumber( count ) or definition.maxStack or 1 )
	count = math.Clamp( count, 1, definition.maxStack or 1 )
	targetSlot = math.floor( tonumber( targetSlot ) or -1 )
	if targetSlot < -1 or targetSlot > 8 then return false, "invalid_creative_target" end
	if #State.actions >= 64 then return false, "inventory_action_queue_full" end
	local actionId = State.nextActionId % BACKGROUND_ACTION
	State.nextActionId = ( actionId + 1 ) % BACKGROUND_ACTION
	State.actions[#State.actions + 1] = {
		kind = "creative_pick",
		actionId = actionId,
		runtimeId = definition.runtimeId,
		count = count,
		targetSlot = targetSlot,
	}
	pumpActions()
	return true, actionId
end

function MC.QueueCreativeInventoryClear( targetSlot )
	if not State.session or State.session.creative ~= true then return false, "creative_inventory_unavailable" end
	targetSlot = math.floor( tonumber( targetSlot ) or -1 )
	if targetSlot < -1 or targetSlot > 8 then return false, "invalid_creative_target" end
	if #State.actions >= 64 then return false, "inventory_action_queue_full" end
	local air = MC.GetItem( "minecraft:air" )
	if not air or air.runtimeId == nil then return false, "item_registry_unavailable" end
	local actionId = State.nextActionId % BACKGROUND_ACTION
	State.nextActionId = ( actionId + 1 ) % BACKGROUND_ACTION
	State.actions[#State.actions + 1] = {
		kind = "creative_pick",
		actionId = actionId,
		runtimeId = air.runtimeId,
		count = 0,
		targetSlot = targetSlot,
	}
	pumpActions()
	return true, actionId
end

net.Receive( "mc_inventory_delta", function()
	local protocol = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local accepted = net.ReadBool()
	local actionId = net.ReadUInt( 16 )
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local errorCode = net.ReadString()
	local changedCount = net.ReadUInt( 6 )
	local changed, decodeError = {}, nil
	for _ = 1, changedCount do
		local index = net.ReadUInt( 6 )
		local stack, err = MC.ReadItemStackNet()
		if err then decodeError = err end
		changed[index] = stack or false
	end
	local cursor, cursorError = MC.ReadItemStackNet()
	decodeError = decodeError or cursorError
	if protocol ~= PROTOCOL_VERSION or containerId ~= 1 or #token > 128 or #errorCode > 96 or decodeError then
		State.lastError = decodeError or "invalid_inventory_delta"
		MC.RequestInventoryResync()
		return
	end
	local cursorApplies = State.session and token == State.session.token or false
	MC.ApplyClientInventoryDelta( revision, selected, changed, cursor, cursorApplies )
	if actionId ~= BACKGROUND_ACTION and State.inflight and State.inflight.actionId == actionId then
		State.inflight = nil
		if not accepted then
			State.actions = {}
			State.lastError = errorCode ~= "" and errorCode or "inventory_action_rejected"
		end
		pumpActions()
	end
	emit( "MC.InventoryActionResult", actionId, accepted, errorCode, revision, State )
end )

net.Receive( "mc_inventory_open", function()
	local protocol = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local selected = net.ReadUInt( 4 )
	local creative = net.ReadBool()
	local reason = net.ReadString()
	local cursor, err = MC.ReadItemStackNet()
	if protocol ~= PROTOCOL_VERSION or containerId ~= 1 or token == "" or #token > 128 or err then
		State.lastError = err or "invalid_inventory_open"
		return
	end
	State.session = {
		containerId = containerId,
		token = token,
		creative = creative,
		reason = reason,
	}
	State.revision = revision
	State.selected = selected
	State.cursor = cursor
	State.actions = {}
	State.inflight = nil
	emit( "MC.InventoryOpened", State.session, State )
end )

net.Receive( "mc_inventory_close", function()
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local reason = net.ReadString()
	if State.session and State.session.containerId == containerId and State.session.token == token then
		State.session = nil
		State.cursor = nil
		State.actions = {}
		State.inflight = nil
		emit( "MC.InventoryClosed", reason, State )
	end
end )

function MC.RequestInventoryOpen()
	local now = RealTime()
	if State.lastOpenRequest and now - State.lastOpenRequest < 0.2 then return false end
	State.lastOpenRequest = now
	net.Start( "mc_inventory_open_request" )
	net.SendToServer()
	return true
end

function MC.CloseInventorySession()
	if not State.session then return false end
	net.Start( "mc_inventory_close" )
		net.WriteUInt( State.session.containerId, 16 )
		net.WriteString( State.session.token )
	net.SendToServer()
	return true
end

function MC.SelectInventoryHotbarSlot( selected )
	selected = math.floor( tonumber( selected ) or -1 )
	if selected < 0 or selected > 8 then return false end
	State.selected = selected
	emit( "MC.InventorySelectionChanged", selected, State )
	net.Start( "mc_inventory_select" )
		net.WriteUInt( selected, 4 )
	net.SendToServer()
	return true
end

hook.Add( "Think", "mc_inventory_transfer_timeout", function()
	local now = RealTime()
	for transferId, transfer in pairs( State.transfers ) do
		if now - transfer.startedAt > 20 then failTransfer( transferId, "snapshot_timeout" ) end
	end
end )

concommand.Add( "mc_inventory", function() MC.RequestInventoryOpen() end )
