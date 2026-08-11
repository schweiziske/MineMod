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
local PROTOCOL_VERSION = 1
local SNAPSHOT_PART_BYTES = 30000
local SNAPSHOT_MAX_BYTES = 1024 * 1024
local BACKGROUND_ACTION = 65535
local SLOT_BITS = 7
local MAX_MENU_SLOTS = 127

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
	}
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
		net.WriteString( string.sub( tostring( errorCode or "" ), 1, 96 ) )
		net.WriteUInt( #changedSlots, SLOT_BITS )
		for _, index in ipairs( changedSlots ) do
			net.WriteUInt( index, SLOT_BITS )
			MC.WriteItemStackNet( MC.ContainerGetStack( container, index ) )
		end
		MC.WriteItemStackNet( container.cursor )
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
	if session.lastActionId == nil then session.lastActionId = actionId return true end
	local distance = ( actionId - session.lastActionId ) % 65536
	if distance == 0 or distance > 32768 then return false end
	session.lastActionId = actionId
	return true
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
		creative = session.creative == true,
		canDrop = type( SV.SpawnItemDrop ) == "function",
	}
	local result = MC.ExecuteContainerInput( container, {
		revision = revision, actionId = actionId, input = input, slot = slot, button = button,
	}, context )
	if not result.ok then sendRejected( record, actionId, result.error, result.error == "revision_mismatch" ) return end
	if not context.inventoryDeltaPublished then sendDelta( record, result, true, actionId, "" ) end
	if #result.drops > 0 and type( SV.SpawnItemDrop ) == "function" then
		local position = SV.PlayerItemDropPosition and SV.PlayerItemDropPosition( ply ) or ply:GetShootPos()
		for _, stack in ipairs( result.drops ) do
			SV.SpawnItemDrop( position, stack, ply, {
				noMerge = true,
				velocity = SV.PlayerThrownDropVelocity and SV.PlayerThrownDropVelocity( ply ) or nil,
			} )
		end
	end
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
		creative = session.creative == true,
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
	local runtimeId = net.ReadUInt( MC.ItemStackRuntimeIdBits )
	local count = net.ReadUInt( 7 )
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
	if targetSlot < -1 or targetSlot > 8 then sendRejected( record, actionId, "invalid_creative_target", false ) return end
	local definition = MC.GetItem( runtimeId )
	if not definition then sendRejected( record, actionId, "unknown_item", false ) return end
	if definition.name == "minecraft:air" then count = 0 else count = math.Clamp( math.floor( tonumber( count ) or 1 ), 1, definition.maxStack or 1 ) end
	local snapshot = MC.ContainerSnapshot( container )
	local stack = count > 0 and MC.NewItemStack( definition.name, count ) or nil
	local ok, err
	if targetSlot >= 0 then ok, err = MC.ContainerSetStack( container, targetSlot, stack ) else ok, err = MC.ContainerSetCursor( container, stack ) end
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
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record or not actionRateAllowed( record ) then return end
	SV.SetPlayerSelectedSlot( ply, selected, { reason = "selected" } )
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
