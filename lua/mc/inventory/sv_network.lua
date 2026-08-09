--[[----------------------------------------------------------------------------
	Authoritative player-inventory transport.

	Full state is compressed and chunked. Normal interaction responses contain
	only changed slots plus the carried stack, revision and action acknowledgement.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local PROTOCOL_VERSION = 1
local SNAPSHOT_PART_BYTES = 30000
local SNAPSHOT_MAX_BYTES = 1024 * 1024
local BACKGROUND_ACTION = 65535

local function creativeAllowed( ply )
	if MC.RunEvent then
		local allowed = MC.RunEvent( "MC.PlayerHasInfiniteMaterials", ply )
		if allowed ~= nil then return allowed == true end
	end
	return not MC.Config.InventoryCreative or MC.Config.InventoryCreative:GetBool()
end

local function actionRateAllowed( record )
	local now = CurTime()
	local rate = record.actionRate
	if not rate or now - rate.startedAt >= 1 then
		record.actionRate = { startedAt = now, count = 1 }
		return true
	end
	local limit = MC.Config.InventoryActionRate and MC.Config.InventoryActionRate:GetInt() or 80
	if rate.count >= limit then return false end
	rate.count = rate.count + 1
	return true
end

local function nextTransferId( record )
	record.snapshotTransferId = ( math.floor( tonumber( record.snapshotTransferId ) or 0 ) + 1 ) % 65536
	return record.snapshotTransferId
end

local function snapshotPayload( record )
	local state = SV.PlayerInventoryState( record )
	local json = util.TableToJSON( state, false )
	if not json then return nil, "inventory_snapshot_json_failed" end
	local compressed = util.Compress( json )
	if not compressed then return nil, "inventory_snapshot_compress_failed" end
	if #compressed > SNAPSHOT_MAX_BYTES then return nil, "inventory_snapshot_too_large" end
	return compressed, #json
end

function SV.SendPlayerInventorySnapshot( ply, reason )
	if not IsValid( ply ) then return false, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return false, "inventory_not_loaded" end
	local payload, rawBytesOrError = snapshotPayload( record )
	if not payload then return false, rawBytesOrError end
	local transferId = nextTransferId( record )
	local parts = math.max( 1, math.ceil( #payload / SNAPSHOT_PART_BYTES ) )
	local hash = util.SHA256 and util.SHA256( payload ) or util.CRC( payload )

	net.Start( "mc_inventory_sync_begin" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( transferId, 16 )
		net.WriteUInt( record.container.revision, 32 )
		net.WriteUInt( record.selected, 4 )
		net.WriteUInt( rawBytesOrError, 32 )
		net.WriteUInt( #payload, 32 )
		net.WriteUInt( parts, 16 )
		net.WriteString( hash )
		net.WriteString( string.sub( tostring( reason or "sync" ), 1, 64 ) )
	net.Send( ply )

	for part = 1, parts do
		local first = ( part - 1 ) * SNAPSHOT_PART_BYTES + 1
		local chunk = string.sub( payload, first, first + SNAPSHOT_PART_BYTES - 1 )
		net.Start( "mc_inventory_sync_part" )
			net.WriteUInt( transferId, 16 )
			net.WriteUInt( part, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.Send( ply )
	end

	net.Start( "mc_inventory_sync_end" )
		net.WriteUInt( transferId, 16 )
		net.WriteUInt( record.container.revision, 32 )
	net.Send( ply )
	return true
end

local function sessionToken( record )
	return record.session and record.session.token or ""
end

local function sendDelta( record, result, accepted, actionId, errorCode )
	local ply = record.owner
	if not IsValid( ply ) then return false end
	local changedSlots = result and result.changedSlots or {}
	if #changedSlots > 36 then return false end
	net.Start( "mc_inventory_delta" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( 1, 16 )
		net.WriteString( sessionToken( record ) )
		net.WriteBool( accepted == true )
		net.WriteUInt( math.floor( tonumber( actionId ) or BACKGROUND_ACTION ) % 65536, 16 )
		net.WriteUInt( record.container.revision, 32 )
		net.WriteUInt( record.selected, 4 )
		net.WriteString( string.sub( tostring( errorCode or "" ), 1, 96 ) )
		net.WriteUInt( #changedSlots, 6 )
		for _, index in ipairs( changedSlots ) do
			net.WriteUInt( index, 6 )
			MC.WriteItemStackNet( MC.ContainerGetStack( record.container, index ) )
		end
		MC.WriteItemStackNet( record.container.cursor )
	net.Send( ply )
	return true
end

function SV.PublishPlayerInventoryCommit( record, result, context )
	context = context or {}
	context.inventoryDeltaPublished = true
	return sendDelta( record, result, true, context.actionId, "" )
end

function SV.PublishPlayerInventorySelection( record, context )
	return sendDelta( record, { changedSlots = {} }, true, context and context.actionId, "" )
end

local function sendRejected( record, actionId, errorCode, resync )
	sendDelta( record, { changedSlots = {} }, false, actionId, errorCode )
	if resync then SV.SendPlayerInventorySnapshot( record.owner, errorCode ) end
end

local function newSessionToken( ply, record )
	local seed = table.concat( {
		tostring( record.ownerId or ply:EntIndex() ),
		tostring( SysTime() ),
		tostring( math.random() ),
		tostring( record.container.revision ),
	}, ":" )
	return util.SHA256 and util.SHA256( seed ) or util.CRC( seed )
end

function SV.OpenPlayerInventory( ply, reason )
	if not IsValid( ply ) or not ply:Alive() then return false, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return false, "inventory_not_loaded" end
	local now = CurTime()
	if record.lastOpenRequest and now - record.lastOpenRequest < 0.15 then return false, "open_rate_limited" end
	record.lastOpenRequest = now

	if not record.session then
		record.container.cursor = MC.CopyItemStack( record.carried )
		record.carried = nil
		record.session = {
			token = newSessionToken( ply, record ),
			openedAt = now,
			lastActionId = nil,
		}
	end
	net.Start( "mc_inventory_open" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( record.container.id, 16 )
		net.WriteString( record.session.token )
		net.WriteUInt( record.container.revision, 32 )
		net.WriteUInt( record.selected, 4 )
		net.WriteBool( creativeAllowed( ply ) )
		net.WriteString( string.sub( tostring( reason or "player" ), 1, 64 ) )
		MC.WriteItemStackNet( record.container.cursor )
	net.Send( ply )
	SV.SendPlayerInventorySnapshot( ply, "open" )
	return true
end

local function returnCarriedToInventory( record, context )
	local container = record.container
	if MC.IsEmptyItemStack( container.cursor ) then return end
	local snapshot = MC.ContainerSnapshot( container )
	local carried = MC.CopyItemStack( container.cursor )
	container.cursor = nil
	local targets = {}
	for slot = 0, 35 do targets[#targets + 1] = slot end
	local remaining = select( 1, MC.ContainerMoveStackTo( container, carried, targets, context ) )
	record.carried = MC.CopyItemStack( remaining )
	SV.CommitPlayerInventoryMutation( record, snapshot, context )
end

function SV.ClosePlayerInventory( ply, reason, token )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not record.session then return false, "inventory_not_open" end
	if token and token ~= "" and token ~= record.session.token then return false, "invalid_session" end
	returnCarriedToInventory( record, { reason = "close" } )
	net.Start( "mc_inventory_close" )
		net.WriteUInt( record.container.id, 16 )
		net.WriteString( record.session.token )
		net.WriteString( string.sub( tostring( reason or "closed" ), 1, 96 ) )
	net.Send( ply )
	record.session = nil
	return true
end

local function actionSequenceAllowed( session, actionId )
	if actionId == BACKGROUND_ACTION then return false end
	if session.lastActionId == nil then session.lastActionId = actionId return true end
	local distance = ( actionId - session.lastActionId ) % 65536
	if distance == 0 or distance > 32768 then return false end
	session.lastActionId = actionId
	return true
end

net.Receive( "mc_inventory_open_request", function( _, ply )
	SV.OpenPlayerInventory( ply, "request" )
end )

net.Receive( "mc_inventory_action", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local actionId = net.ReadUInt( 16 )
	local input = net.ReadUInt( 3 )
	local slot = net.ReadInt( 16 )
	local button = net.ReadInt( 8 )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not record.session then return end
	if containerId ~= record.container.id or token ~= record.session.token then
		sendRejected( record, actionId, "invalid_session", true )
		return
	end
	if not actionRateAllowed( record ) then sendRejected( record, actionId, "rate_limited", false ) return end
	if not actionSequenceAllowed( record.session, actionId ) then sendRejected( record, actionId, "stale_action", true ) return end
	record.session.lastActivity = CurTime()

	local context = {
		player = ply,
		actionId = actionId,
		creative = creativeAllowed( ply ),
		canDrop = type( SV.SpawnItemDrop ) == "function",
	}
	local result = MC.ExecuteContainerInput( record.container, {
		revision = revision,
		actionId = actionId,
		input = input,
		slot = slot,
		button = button,
	}, context )
	if not result.ok then
		sendRejected( record, actionId, result.error, result.error == "revision_mismatch" )
		return
	end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
	if #result.drops > 0 and type( SV.SpawnItemDrop ) == "function" then
		for _, stack in ipairs( result.drops ) do SV.SpawnItemDrop( ply:GetShootPos(), stack, ply ) end
	end
end )

net.Receive( "mc_inventory_close", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if record and containerId == record.container.id then SV.ClosePlayerInventory( ply, "client", token ) end
end )

net.Receive( "mc_inventory_resync", function( _, ply )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not actionRateAllowed( record ) then return end
	SV.SendPlayerInventorySnapshot( ply, "requested" )
end )

net.Receive( "mc_inventory_select", function( _, ply )
	local selected = net.ReadUInt( 4 )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not actionRateAllowed( record ) then return end
	SV.SetPlayerSelectedSlot( ply, selected, { reason = "selected" } )
end )

hook.Add( "PlayerDeath", "mc_inventory_close_on_death", function( ply )
	if SV.GetPlayerInventoryRecord( ply, false ) then SV.ClosePlayerInventory( ply, "death" ) end
end )

hook.Add( "PlayerDisconnected", "mc_inventory_network_cleanup", function( ply )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record then return end
	if record.container and record.container.cursor then record.carried = MC.CopyItemStack( record.container.cursor ) end
	record.session = nil
end )
