--[[----------------------------------------------------------------------------
	Authoritative inventory/container transport.

	The player inventory and chest menus share one ordered action protocol.  A
	chest and crafting menus are temporary containers whose external slots point
	into block/transient storage and whose trailing slots point at the same 36
	player slots.  The server never accepts arbitrary client stacks.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local PROTOCOL_VERSION = MC.InventoryProtocolVersion
local SNAPSHOT_PART_BYTES = 30000
local SNAPSHOT_MAX_BYTES = 1024 * 1024
local BACKGROUND_ACTION = 65535
local SLOT_BITS = 7
local MAX_MENU_SLOTS = 127

util.AddNetworkString( "mc_inventory_world_action" )

local function creativeAllowed( ply )
	return SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true
		and ( not MC.Config.InventoryCreative or MC.Config.InventoryCreative:GetBool() )
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

local function activeContainer( record )
	return record and record.session and record.session.container or record and record.container or nil
end

function SV.GetActiveInventoryContainer( record ) return activeContainer( record ) end

local function activeSession( record ) return record and record.session or nil end
local function sessionToken( record ) return activeSession( record ) and record.session.token or "" end

local function nextTransferId( record )
	record.snapshotTransferId = ( math.floor( tonumber( record.snapshotTransferId ) or 0 ) + 1 ) % 65536
	return record.snapshotTransferId
end

local function menuState( record )
	local container = activeContainer( record )
	if not container then return nil end
	local session = activeSession( record )
	local state = {
		version = 1,
		revision = container.revision,
		selected = record.selected,
		registryHash = tostring( MC.ItemRegistryHash or "" ),
		recipeRegistryHash = tostring( MC.RecipeRegistryHash or "" ),
		menuKind = session and session.kind or "player",
		slotCount = #container.slots,
		playerOffset = session and session.playerOffset or 0,
		chestSlots = session and session.chestSlots or 0,
		crafting = session and session.crafting == true or false,
		craftingWidth = session and session.craftingWidth or 0,
		craftingHeight = session and session.craftingHeight or 0,
		resultSlot = session and session.resultSlot or 0,
		items = {},
		playerItems = {},
		equipmentItems = {},
		playerSlotMap = {},
		equipmentSlotMap = {},
		containerId = container.id,
		token = sessionToken( record ),
		actionId = session and session.lastActionId or record.lastWorldActionId or BACKGROUND_ACTION,
		selectionId = record.lastSelectionId or 0,
		cursor = MC.InventoryDataStack( container.cursor ),
		quickCraft = { status = container.quickCraft.status, type = container.quickCraft.type, slots = {} },
	}
	for index in pairs( container.quickCraft.slots ) do state.quickCraft.slots[#state.quickCraft.slots + 1] = index end
	table.sort( state.quickCraft.slots )
	if #container.slots > MAX_MENU_SLOTS then return nil, "inventory_menu_too_large" end
	for _, slot in ipairs( container.slots ) do
		local stack = MC.InventorySlotGet( slot )
		if not MC.IsEmptyItemStack( stack ) then
			state.items[#state.items + 1] = { slot = slot.index, stack = MC.InventoryDataStack( stack ) }
		end
	end
	for index = 0, 35 do
		local stack = record.storage[index + 1]
		if not MC.IsEmptyItemStack( stack ) then
			state.playerItems[#state.playerItems + 1] = { slot = index, stack = MC.InventoryDataStack( stack ) }
		end
	end
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		local stack = record.equipment and record.equipment[slot] or nil
		if not MC.IsEmptyItemStack( stack ) then
			state.equipmentItems[#state.equipmentItems + 1] = { slot = slot, stack = MC.InventoryDataStack( stack ) }
		end
	end
	for playerIndex, menuIndex in pairs( session and session.playerMenuMap or {} ) do
		state.playerSlotMap[#state.playerSlotMap + 1] = { player = playerIndex, menu = menuIndex }
	end
	for slot, menuIndex in pairs( session and session.equipmentMenuMap or {} ) do
		state.equipmentSlotMap[#state.equipmentSlotMap + 1] = { slot = slot, menu = menuIndex }
	end
	table.sort( state.playerSlotMap, function( left, right ) return left.player < right.player end )
	table.sort( state.equipmentSlotMap, function( left, right ) return left.menu < right.menu end )
	return state
end

local function snapshotPayload( record )
	local state, stateError = menuState( record )
	if not state then return nil, stateError or "inventory_snapshot_state_failed" end
	local json = util.TableToJSON( state, false )
	if not json then return nil, "inventory_snapshot_json_failed" end
	local compressed = util.Compress( json )
	if not compressed then return nil, "inventory_snapshot_compress_failed" end
	if #compressed > SNAPSHOT_MAX_BYTES then return nil, "inventory_snapshot_too_large" end
	return compressed, #json
end

function SV.SendActiveInventorySnapshot( ply, reason )
	if not IsValid( ply ) then return false, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return false, "inventory_not_loaded" end
	local container = activeContainer( record )
	if not container then return false, "inventory_container_missing" end
	local payload, rawBytesOrError = snapshotPayload( record )
	if not payload then return false, rawBytesOrError end
	local transferId = nextTransferId( record )
	local parts = math.max( 1, math.ceil( #payload / SNAPSHOT_PART_BYTES ) )
	local hash = util.SHA256 and util.SHA256( payload ) or util.CRC( payload )

	net.Start( "mc_inventory_sync_begin" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( transferId, 16 )
		net.WriteUInt( container.revision, 32 )
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
		net.WriteUInt( container.revision, 32 )
	net.Send( ply )
	return true
end

SV.SendPlayerInventorySnapshot = SV.SendActiveInventorySnapshot

local function sendDelta( record, result, accepted, actionId, errorCode )
	local ply = record and record.owner
	if not IsValid( ply ) then return false end
	local container = activeContainer( record )
	if not container then return false end
	local changedSlots = result and result.changedSlots or {}
	if #changedSlots > MAX_MENU_SLOTS then return false end
	for _, index in ipairs( changedSlots ) do
		index = math.floor( tonumber( index ) or -1 )
		if index < 0 or index > MAX_MENU_SLOTS or not MC.ContainerGetSlot( container, index ) then return false end
	end
	net.Start( "mc_inventory_delta" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( container.id, 16 )
		net.WriteString( sessionToken( record ) )
		net.WriteBool( accepted == true )
		net.WriteUInt( math.floor( tonumber( actionId ) or BACKGROUND_ACTION ) % 65536, 16 )
		net.WriteUInt( container.revision, 32 )
		net.WriteUInt( record.selected, 4 )
		net.WriteUInt( record.lastSelectionId or 0, 32 )
		net.WriteString( string.sub( tostring( errorCode or "" ), 1, 96 ) )
		net.WriteUInt( #changedSlots, SLOT_BITS )
		for _, index in ipairs( changedSlots ) do
			net.WriteUInt( index, SLOT_BITS )
			MC.WriteItemStackNet( MC.ContainerGetStack( container, index ) )
		end
		MC.WriteItemStackNet( container.cursor )
		MC.WriteInventoryQuickCraftNet( container.quickCraft )
		MC.WriteItemStackNet( record.equipment and record.equipment.offhand )
	net.Send( ply )
	return true
end

function SV.PublishActiveInventoryCommit( record, result, context )
	context = context or {}
	context.inventoryDeltaPublished = true
	return sendDelta( record, result, true, context.actionId, "" )
end

function SV.PublishPlayerInventoryCommit( record, result, context )
	local session = record and record.session
	if session and session.container and session.container ~= record.container then
		session.container.revision = math.max( session.container.revision + 1, record.container.revision )
		local mapped = { changedSlots = {} }
		for _, index in ipairs( result and result.changedSlots or {} ) do
			local menuIndex = session.playerMenuMap and session.playerMenuMap[index]
				or ( session.playerOffset or 0 ) + index
			if menuIndex ~= nil and MC.ContainerGetSlot( session.container, menuIndex ) then
				mapped.changedSlots[#mapped.changedSlots + 1] = menuIndex
			end
		end
		return SV.PublishActiveInventoryCommit( record, mapped, context )
	end
	return SV.PublishActiveInventoryCommit( record, result, context )
end

local function commitDirectContainerMutation( container, snapshot, context )
	local changedSlots = MC.ContainerChangedSlots( container, snapshot )
	local cursorChanged = not MC.ItemStacksEqual( container.cursor, snapshot.cursor )
	if #changedSlots > 0 or cursorChanged then container.revision = container.revision + 1 end
	local changed = {}
	for _, index in ipairs( changedSlots ) do changed[index] = MC.CopyItemStack( MC.ContainerGetStack( container, index ) ) end
	local result = {
		ok = true,
		revision = container.revision,
		changedSlots = changedSlots,
		changed = changed,
		cursorChanged = cursorChanged,
		cursor = MC.CopyItemStack( container.cursor ),
		drops = {},
	}
	if type( container.onCommit ) == "function" and ( #changedSlots > 0 or cursorChanged ) then
		local called, commitError = pcall( container.onCommit, container, result, context or container.context or {} )
		if not called then
			MC.ContainerRestore( container, snapshot )
			return nil, commitError or "container_commit_failed"
		end
	end
	return result
end

function SV.PublishEquipmentCommit( record, result, context )
	context = context or {}
	local session = record and record.session
	if session and session.container then
		session.container.revision = math.max( session.container.revision, result.revision or 0 )
	end
	if session and session.equipmentMenuMap and session.container then
		local mapped = { changedSlots = {} }
		for _, slot in ipairs( result.changedSlots or {} ) do
			local menuIndex = session.equipmentMenuMap[slot]
			if menuIndex ~= nil then mapped.changedSlots[#mapped.changedSlots + 1] = menuIndex end
		end
		if #mapped.changedSlots > 0 then return SV.PublishActiveInventoryCommit( record, mapped, context ) end
	end
	local ply = record and record.owner
	if not IsValid( ply ) then return false end
	local changed = result and result.changedSlots or {}
	if #changed > #( MC.EquipmentSlotOrder or {} ) then return false end
	net.Start( "mc_equipment_delta" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( math.max( 0, math.floor( tonumber( result and result.revision ) or 0 ) ), 32 )
		net.WriteUInt( #changed, 3 )
		for _, slot in ipairs( changed ) do
			net.WriteUInt( MC.EquipmentSlotIds[slot] or 0, 3 )
			MC.WriteItemStackNet( record.equipment and record.equipment[slot] or nil )
		end
	net.Send( ply )
	return true
end

function SV.PublishPlayerInventorySelection( record, context )
	return sendDelta( record, { changedSlots = {} }, true, context and context.actionId, "" )
end

local function sendRejected( record, actionId, errorCode, resync )
	sendDelta( record, { changedSlots = {} }, false, actionId, errorCode )
	if resync and record and record.owner then SV.SendActiveInventorySnapshot( record.owner, errorCode ) end
end

local function newSessionToken( ply, record, kind )
	local seed = table.concat( {
		tostring( record.ownerId or ply:EntIndex() ), tostring( SysTime() ),
		tostring( math.random() ), tostring( ( activeContainer( record ) or {} ).revision or 0 ), tostring( kind or "player" ),
	}, ":" )
	return util.SHA256 and util.SHA256( seed ) or util.CRC( seed )
end

function SV.SendActiveInventoryOpen( ply, record, reason )
	local session = record and record.session
	local container = activeContainer( record )
	if not IsValid( ply ) or not session or not container then return false end
	net.Start( "mc_inventory_open" )
		net.WriteUInt( PROTOCOL_VERSION, 8 )
		net.WriteUInt( container.id, 16 )
		net.WriteString( session.token )
		net.WriteUInt( container.revision, 32 )
		net.WriteUInt( record.selected, 4 )
		net.WriteBool( session.creative == true )
		net.WriteString( string.sub( tostring( reason or session.kind or "player" ), 1, 64 ) )
		MC.WriteItemStackNet( container.cursor )
		net.WriteString( tostring( session.kind or "player" ) )
		net.WriteUInt( math.Clamp( #container.slots, 0, MAX_MENU_SLOTS ), 8 )
		net.WriteUInt( math.Clamp( math.floor( tonumber( session.playerOffset ) or 0 ), 0, MAX_MENU_SLOTS ), 8 )
		net.WriteUInt( math.Clamp( math.floor( tonumber( session.chestSlots ) or 0 ), 0, MAX_MENU_SLOTS ), 8 )
		net.WriteBool( session.crafting == true )
		net.WriteUInt( math.Clamp( math.floor( tonumber( session.craftingWidth ) or 0 ), 0, 15 ), 4 )
		net.WriteUInt( math.Clamp( math.floor( tonumber( session.craftingHeight ) or 0 ), 0, 15 ), 4 )
		net.WriteUInt( math.Clamp( math.floor( tonumber( session.resultSlot ) or 0 ), 0, MAX_MENU_SLOTS ), 8 )
	net.Send( ply )
	SV.SendActiveInventorySnapshot( ply, "open" )
	return true
end

function SV.OpenPlayerInventory( ply, reason )
	if not IsValid( ply ) or not ply:Alive() then return false, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return false, "inventory_not_loaded" end
	local now = CurTime()
	if record.lastOpenRequest and now - record.lastOpenRequest < 0.15 then return false, "open_rate_limited" end
	record.lastOpenRequest = now
	if record.session and record.session.kind ~= "player" then SV.ClosePlayerInventory( ply, "switch" ) end
	if not record.session then
		local creative = creativeAllowed( ply )
		local menu, playerOffset
		if creative and SV.BuildCreativeInventoryMenu then
			menu, playerOffset = SV.BuildCreativeInventoryMenu( ply, record )
		elseif not creative and SV.BuildPlayerCraftingMenu then
			menu, playerOffset = SV.BuildPlayerCraftingMenu( ply, record )
		end
		if menu then
			menu.cursor = MC.CopyItemStack( record.carried )
			record.carried = nil
			record.session = {
				token = newSessionToken( ply, record, "player" ),
				kind = "player",
				container = menu,
				openedAt = now,
				lastActionId = nil,
				crafting = not creative,
				creative = creative,
				craftingWidth = creative and 0 or 2,
				craftingHeight = creative and 0 or 2,
				resultSlot = 0,
				playerOffset = playerOffset,
				playerMenuMap = menu.playerMenuMap,
				menuPlayerMap = menu.menuPlayerMap,
				equipmentMenuMap = menu.equipmentMenuMap,
				chestSlots = 0,
			}
		else
			-- Keep the old direct inventory fallback available during a partial
			-- hot-reload or when an external addon replaces the crafting provider.
			record.container.cursor = MC.CopyItemStack( record.carried )
			record.carried = nil
			record.session = {
				token = newSessionToken( ply, record, "player" ),
				kind = "player",
				container = record.container,
				openedAt = now,
				lastActionId = nil,
				playerOffset = 0,
				chestSlots = 0,
				creative = creative,
			}
		end
	end
	return SV.SendActiveInventoryOpen( ply, record, reason or "player" )
end

local function returnCarriedToPlayer( record, context )
	local session = record and record.session
	local container = activeContainer( record )
	if not container or MC.IsEmptyItemStack( container.cursor ) then return end
	local carried = MC.CopyItemStack( container.cursor )
	container.cursor = nil
	if session and session.kind == "player" and session.crafting ~= true then
		local snapshot = MC.ContainerSnapshot( container )
		local targets = {}
		for slot = 0, 35 do targets[#targets + 1] = slot end
		local remaining = select( 1, MC.ContainerMoveStackTo( container, carried, targets, context or {} ) )
		record.carried = MC.CopyItemStack( remaining )
		if not MC.IsEmptyItemStack( remaining ) then record.dirty = true end
		if container == record.container then
			SV.CommitPlayerInventoryMutation( record, snapshot, context or { reason = "close" } )
		else
			commitDirectContainerMutation( container, snapshot, context or { reason = "close" } )
		end
		return
	end
	local playerContainer = record.container
	local snapshot = MC.ContainerSnapshot( playerContainer )
	local targets = {}
	for slot = 0, 35 do targets[#targets + 1] = slot end
	local remaining = select( 1, MC.ContainerMoveStackTo( playerContainer, carried, targets, context or {} ) )
	record.carried = MC.CopyItemStack( remaining )
	if not MC.IsEmptyItemStack( remaining ) then record.dirty = true end
	local changed = MC.ContainerChangedSlots( playerContainer, snapshot )
	if #changed > 0 then
		playerContainer.revision = math.max( playerContainer.revision + 1, container.revision or 0 )
		record.revision = playerContainer.revision
		record.dirty = true
		if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
	end
end

function SV.ClosePlayerInventory( ply, reason, token )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not record.session then return false, "inventory_not_open" end
	if token and token ~= "" and token ~= record.session.token then return false, "invalid_session" end
	local session = record.session
	local wasCrafting = session.crafting == true
	local closeCallback = session.onClose
	if session.crafting == true and SV.CloseCraftingMenu then
		SV.CloseCraftingMenu( record, session, { reason = "close" } )
	end
	returnCarriedToPlayer( record, { reason = "close" } )
	if IsValid( ply ) then
		net.Start( "mc_inventory_close" )
			net.WriteUInt( session.container.id, 16 )
			net.WriteString( session.token )
			net.WriteString( string.sub( tostring( reason or "closed" ), 1, 96 ) )
		net.Send( ply )
	end
	record.session = nil
	if SV.UpdatePlayerHeldNetwork then
		SV.UpdatePlayerHeldNetwork( record, { reason = "inventory_closed" } )
	end
	if type( closeCallback ) == "function" then
		local called, callbackError = pcall( closeCallback, record, session, reason or "closed" )
		if not called and ErrorNoHalt then ErrorNoHalt( "[MC Inventory] close callback failed: " .. tostring( callbackError ) .. "\n" ) end
	end
	if wasCrafting and IsValid( ply ) and SV.SendActiveInventorySnapshot then
		SV.SendActiveInventorySnapshot( ply, "crafting_close" )
	end
	return true
end

local function actionSequenceAllowed( session, actionId )
	if actionId == BACKGROUND_ACTION then return false end
	if not MC.InventoryActionIsNewer( actionId, session.lastActionId ) then return false end
	session.lastActionId = actionId
	return true
end

local function reserveActionDrops( context )
	local reserved = {}
	context.cancelDrops = function()
		for _, entity in ipairs( reserved ) do if IsValid( entity ) then entity:Remove() end end
		reserved = {}
	end
	context.prepareDrops = function( stacks )
		local ply = context.player
		local position = SV.PlayerItemDropPosition( ply )
		local velocity = SV.PlayerThrownDropVelocity( ply )
		for _, stack in ipairs( stacks ) do
			local entity, err = SV.SpawnItemDrop( position, stack, ply, {
				noMerge = true, pickupDelay = 2, velocity = velocity,
			} )
			if not entity then return false, err or "drop_spawn_failed" end
			reserved[#reserved + 1] = entity
		end
		return true
	end
end

local function sessionStillValid( session )
	if not session or type( session.validate ) ~= "function" then return true end
	local called, valid = pcall( session.validate )
	return called and valid == true
end

net.Receive( "mc_inventory_open_request", function( _, ply ) SV.OpenPlayerInventory( ply, "request" ) end )

net.Receive( "mc_inventory_action", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local actionId = net.ReadUInt( 16 )
	local input = net.ReadUInt( 3 )
	local slot = net.ReadInt( 16 )
	local button = net.ReadInt( 8 )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	local session, container = record and record.session, record and activeContainer( record )
	if not record or not session or not container then return end
	if containerId ~= container.id or token ~= session.token then sendRejected( record, actionId, "invalid_session", true ) return end
	if not sessionStillValid( session ) then
		sendRejected( record, actionId, "container_unavailable", false )
		SV.ClosePlayerInventory( ply, "container_unavailable" )
		return
	end
	if not actionRateAllowed( record ) then sendRejected( record, actionId, "rate_limited", false ) return end
	if not actionSequenceAllowed( session, actionId ) then sendRejected( record, actionId, "stale_action", true ) return end
	session.lastActivity = CurTime()
	local context = {
		player = ply, actionId = actionId,
		creative = creativeAllowed( ply ),
		canDrop = type( SV.SpawnItemDrop ) == "function",
		parityClicks = MC.GameplayParityInventoryClicksEnabled
			and MC.GameplayParityInventoryClicksEnabled() or false,
	}
	if MC.ConfigurePlayerSwap then
		MC.ConfigurePlayerSwap( container, record, session.equipmentMenuMap )
	end
	reserveActionDrops( context )
	local result = MC.ExecuteContainerInput( container, {
		revision = revision, actionId = actionId, input = input, slot = slot, button = button,
	}, context )
	if not result.ok then sendRejected( record, actionId, result.error, result.error == "revision_mismatch" ) return end
	if result.offhandChanged and not ( session.equipmentMenuMap and session.equipmentMenuMap.offhand ) then
		record.dirty = true
		SV.UpdatePlayerEquipmentNetwork( record )
	end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
end )

-- Ordered business-menu button. Unlike a normal slot click, this carries only
-- an option index; the active container owns all authoritative computation and
-- mutation. It deliberately shares the normal token/rate/action/revision gate.
net.Receive( "mc_inventory_menu_button", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local actionId = net.ReadUInt( 16 )
	local button = net.ReadUInt( 2 )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	local session, container = record and record.session, record and activeContainer( record )
	if not record or not session or not container then return end
	local function finishState( result, errorCode )
		if type( container.afterMenuButton ) == "function" then
			pcall( container.afterMenuButton, container, result, errorCode )
		elseif type( container.sendMenuState ) == "function" then
			pcall( container.sendMenuState, container )
		end
	end
	if containerId ~= container.id or token ~= session.token then
		sendRejected( record, actionId, "invalid_session", true )
		finishState( nil, "invalid_session" )
		return
	end
	if not sessionStillValid( session ) then
		sendRejected( record, actionId, "container_unavailable", false )
		SV.ClosePlayerInventory( ply, "container_unavailable" )
		return
	end
	if session.kind ~= "enchanting_table" or type( container.menuButton ) ~= "function" then
		sendRejected( record, actionId, "menu_button_unavailable", false )
		finishState( nil, "menu_button_unavailable" )
		return
	end
	if button < 0 or button > 2 then
		sendRejected( record, actionId, "invalid_menu_button", false )
		finishState( nil, "invalid_menu_button" )
		return
	end
	if not actionRateAllowed( record ) then
		sendRejected( record, actionId, "rate_limited", false )
		finishState( nil, "rate_limited" )
		return
	end
	if not actionSequenceAllowed( session, actionId ) then
		sendRejected( record, actionId, "stale_action", true )
		finishState( nil, "stale_action" )
		return
	end
	-- Menu options can change when bookshelves or the seed change without a
	-- client slot click. Require the exact advertised revision so an old button
	-- can never silently select a newly generated option.
	if revision ~= container.revision then
		sendRejected( record, actionId, "revision_mismatch", true )
		finishState( nil, "revision_mismatch" )
		return
	end
	session.lastActivity = CurTime()
	local context = {
		player = ply,
		actionId = actionId,
		creative = creativeAllowed( ply ),
		canDrop = type( SV.SpawnItemDrop ) == "function",
		menuButton = true,
	}
	local called, result, errorCode = pcall( container.menuButton, container, button, context )
	if not called or type( result ) ~= "table" or result.ok ~= true then
		errorCode = called and ( errorCode or result and result.error or "menu_button_rejected" ) or "menu_button_error"
		sendRejected( record, actionId, errorCode, errorCode == "revision_mismatch" or not called )
		finishState( nil, errorCode )
		return
	end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
	finishState( result, nil )
end )

-- Recipe-book placement is a separate ordered action.  The client sends only
-- the recipe identifier; the server resolves the generated definition,
-- checks the active menu dimensions and atomically selects real input stacks.
net.Receive( "mc_inventory_recipe_place", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local actionId = net.ReadUInt( 16 )
	local recipeId = net.ReadString()
	local useMax = net.ReadBool()
	local record = SV.GetPlayerInventoryRecord( ply, false )
	local session, container = record and record.session, record and activeContainer( record )
	if not record or not session or not container then return end
	if containerId ~= container.id or token ~= session.token then
		sendRejected( record, actionId, "invalid_session", true )
		return
	end
	if not sessionStillValid( session ) then
		sendRejected( record, actionId, "container_unavailable", false )
		SV.ClosePlayerInventory( ply, "container_unavailable" )
		return
	end
	if session.crafting ~= true and session.furnace ~= true then sendRejected( record, actionId, "recipe_book_unavailable", false ) return end
	if #recipeId < 1 or #recipeId > 128 then sendRejected( record, actionId, "invalid_recipe_id", false ) return end
	if not actionRateAllowed( record ) then sendRejected( record, actionId, "rate_limited", false ) return end
	if not actionSequenceAllowed( session, actionId ) then sendRejected( record, actionId, "stale_action", true ) return end
	if revision > container.revision then sendRejected( record, actionId, "revision_mismatch", true ) return end
	local recipe = MC.GetRecipe and MC.GetRecipe( recipeId ) or nil
	if not recipe or recipe.supported ~= true then sendRejected( record, actionId, "unknown_recipe", false ) return end
	local data = container.crafting
	local width = data and data.width or session.craftingWidth
	local height = data and data.height or session.craftingHeight
	if session.crafting == true and MC.RecipeBook and MC.RecipeBook.RecipeFitsGrid
	and not MC.RecipeBook.RecipeFitsGrid( recipe, width, height ) then
		sendRejected( record, actionId, "recipe_does_not_fit", false )
		return
	end
	session.lastActivity = CurTime()
	local context = {
		player = ply,
		actionId = actionId,
		creative = creativeAllowed( ply ),
		canDrop = type( SV.SpawnItemDrop ) == "function",
		recipeBook = true,
	}
	local result, errorCode
	if session.furnace == true then
		result, errorCode = MC.FurnacePlaceRecipe( container, recipe, context, useMax == true )
	else
		result, errorCode = MC.CraftingPlaceRecipe( container, recipe, context, useMax == true )
	end
	if not result then
		sendRejected( record, actionId, errorCode or "recipe_place_failed", errorCode == "revision_mismatch" )
		return
	end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
	if #result.drops > 0 and type( SV.SpawnItemDrop ) == "function" then
		local position = SV.PlayerItemDropPosition and SV.PlayerItemDropPosition( ply ) or ply:GetShootPos()
		for _, stack in ipairs( result.drops ) do
			SV.SpawnItemDrop( position, stack, ply, {
				noMerge = true,
				pickupDelay = MC.ItemEntityParity and MC.ItemEntityParity.Enabled
					and MC.ItemEntityParity.Enabled() and 2.0 or nil,
				velocity = SV.PlayerThrownDropVelocity and SV.PlayerThrownDropVelocity( ply ) or nil,
			} )
		end
	end
end )

net.Receive( "mc_inventory_creative_pick", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local actionId = net.ReadUInt( 16 )
	local requestedStack, stackError = MC.ReadItemStackNet()
	local targetSlot = net.ReadInt( 8 )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	local session, container = record and record.session, record and activeContainer( record )
	if not record or not session or not container then return end
	if session.kind ~= "player" or session.creative ~= true or containerId ~= container.id or token ~= session.token then sendRejected( record, actionId, "invalid_session", true ) return end
	if not sessionStillValid( session ) then sendRejected( record, actionId, "container_unavailable", false ) return end
	if not actionRateAllowed( record ) then sendRejected( record, actionId, "rate_limited", false ) return end
	if not actionSequenceAllowed( session, actionId ) then sendRejected( record, actionId, "stale_action", true ) return end
	if revision > container.revision then sendRejected( record, actionId, "revision_mismatch", true ) return end
	if not creativeAllowed( ply ) then sendRejected( record, actionId, "creative_only", false ) return end
	if ( targetSlot < -3 or targetSlot > 8 ) and targetSlot ~= 40
		or targetSlot == -2 and requestedStack ~= nil then sendRejected( record, actionId, "invalid_creative_target", false ) return end
	if stackError then sendRejected( record, actionId, stackError, false ) return end
	local stack
	if requestedStack then
		local definition = MC.GetItem( requestedStack.item )
		if not definition or definition.name == "minecraft:air" then sendRejected( record, actionId, "unknown_item", false ) return end
		stack, stackError = MC.NormalizeItemStack( requestedStack )
		if not stack then sendRejected( record, actionId, stackError or "invalid_item", false ) return end
		local reducingCarried = targetSlot == -1 and MC.ItemStacksCanMerge( stack, container.cursor )
			and stack.count <= container.cursor.count
		if not reducingCarried and not MC.CreativeCatalogContainsStack( stack ) then
			sendRejected( record, actionId, "creative_stack_not_catalogued", false )
			return
		end
	end
	local snapshot = MC.ContainerSnapshot( container )
	local ok, err = MC.MutateCreativeInventory( container, targetSlot, stack )
	if not ok then MC.ContainerRestore( container, snapshot ) sendRejected( record, actionId, err or "invalid_item", false ) return end
	session.lastActivity = CurTime()
	local context = { player = ply, actionId = actionId, creative = true, canDrop = type( SV.SpawnItemDrop ) == "function" }
	local result, commitError = commitDirectContainerMutation( container, snapshot, context )
	if not result then
		MC.ContainerRestore( container, snapshot )
		sendRejected( record, actionId, commitError or "creative_pick_failed", true )
		return
	end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
	if targetSlot == -3 and stack then
		local entity, dropError = SV.SpawnItemDrop( SV.PlayerItemDropPosition( ply ), stack, ply, {
			noMerge = true, pickupDelay = 2, velocity = SV.PlayerThrownDropVelocity( ply ),
		} )
		if not entity then MC.Fault( "inventory_catalog_drop_failed", "%s", tostring( dropError ) ) end
	end
end )

net.Receive( "mc_inventory_close", function( _, ply )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local record = SV.GetPlayerInventoryRecord( ply, false )
	local container = record and activeContainer( record )
	if record and container and containerId == container.id then SV.ClosePlayerInventory( ply, "client", token ) end
end )

net.Receive( "mc_inventory_resync", function( _, ply )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not actionRateAllowed( record ) then return end
	SV.SendActiveInventorySnapshot( ply, "requested" )
end )

net.Receive( "mc_inventory_select", function( _, ply )
	local selected = net.ReadUInt( 4 )
	local sequence = net.ReadUInt( 32 )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or selected > 8 then return end
	if not MC.InventorySelectionIsNewer( sequence, record.lastSelectionId or 0 ) then return end
	record.lastSelectionId = sequence
	local old = record.selected
	if actionRateAllowed( record ) then SV.SetPlayerSelectedSlot( ply, selected, { reason = "selected" } ) end
	if old == record.selected then sendDelta( record, { changedSlots = {} }, true, BACKGROUND_ACTION, "" ) end
end )

net.Receive( "mc_inventory_world_action", function( _, ply )
	local actionId, operation = net.ReadUInt( 16 ), net.ReadUInt( 2 )
	local selectionId, selected = net.ReadUInt( 32 ), net.ReadUInt( 4 )
	local whole = net.ReadBool()
	local bx, by, bz
	if operation == 0 then
		bx, by, bz = net.ReadInt( MC.Net.COORD_BITS ), net.ReadInt( MC.Net.COORD_BITS ), net.ReadInt( MC.Net.COORD_BITS )
	end
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not IsValid( ply ) or not ply:Alive() then return end
	if actionId == BACKGROUND_ACTION or not MC.InventoryActionIsNewer( actionId, record.lastWorldActionId ) then
		sendRejected( record, actionId, "stale_action", false ) return
	end
	record.lastWorldActionId = actionId
	if MC.InventorySelectionIsNewer( selectionId, record.lastSelectionId or 0 ) then record.lastSelectionId = selectionId end
	local Hand = MC.API.HandWeapon
	if record.session or not Hand.IsInventoryActive( ply ) or operation > 2 or selected > 8 then
		sendRejected( record, actionId, "inventory_unavailable", false ) return
	end
	if not actionRateAllowed( record ) then sendRejected( record, actionId, "rate_limited", false ) return end
	local container = record.container
	MC.ConfigurePlayerSwap( container, record )
	local context = { player = ply, actionId = actionId, creative = creativeAllowed( ply ),
		canDrop = type( SV.SpawnItemDrop ) == "function", parityClicks = true, reason = "world_inventory_action" }
	reserveActionDrops( context )
	local result
	if operation == 0 then
		-- ServerGamePacketListenerImpl handles the clicked cell, not the later
		-- camera direction. Resolve its item server-side after checking reach.
		if not MC.ReachAllowsEye( MC.API.Coords.EntityEyeWorldPos( ply ), bx, by, bz, MC.CurrentReach() ) then
			sendRejected( record, actionId, "pick_out_of_reach", false ) return
		end
		local target = MC.InventoryPickStackForState( MC.GetBlockState( bx, by, bz ) )
		local snapshot = MC.ContainerSnapshot( container )
		local ok, newSelected, err = MC.PickInventoryStack( container, selected, target, context.creative )
		if not ok then MC.ContainerRestore( container, snapshot ) sendRejected( record, actionId, err, false ) return end
		record.selected = newSelected
		result = SV.CommitPlayerInventoryMutation( record, snapshot, context )
	else
		record.selected = selected
		result = MC.ExecuteContainerInput( container, {
			input = operation == 1 and MC.ContainerInput.THROW or MC.ContainerInput.SWAP,
			slot = selected, button = operation == 1 and ( whole and 1 or 0 ) or 40,
		}, context )
	end
	if not result or not result.ok then
		sendRejected( record, actionId, result and result.error or "world_action_failed", true ) return
	end
	record.dirty = true
	SV.CancelMining( ply, "inventory_changed" )
	SV.CancelSelectedItemUse( ply, "inventory_changed" )
	SV.UpdatePlayerHeldNetwork( record, context )
	if result.offhandChanged then SV.UpdatePlayerEquipmentNetwork( record ) end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
end )

hook.Add( "PlayerDeath", "mc_inventory_close_on_death", function( ply )
	if SV.DropPlayerInventoryOnDeath then SV.DropPlayerInventoryOnDeath( ply ) end
end )

hook.Add( "PlayerDisconnected", "mc_inventory_network_cleanup", function( ply )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record then return end
	if record.session then
		SV.ClosePlayerInventory( ply, "disconnect" )
	else
		returnCarriedToPlayer( record, { reason = "disconnect" } )
	end
end )
