-- Server-authoritative transient anvil menus.

MC = MC or {}
MC.SV = MC.SV or {}

local API = MC.API or {}
local World = API.World or {}
local Coords = API.Coords or {}
local Blocks = API.Blocks or {}
local PlayerAPI = API.Player or {}
local SV = MC.SV
local ANVIL_SLOTS = 3
local INVENTORY_SIZE = 36
local MAX_RENAME_BYTES = 256

util.AddNetworkString( "mc_anvil_state" )
util.AddNetworkString( "mc_anvil_rename" )

if resource and resource.AddFile then
	for _, fileName in ipairs( {
		"materials/mc/gui/container/anvil.png",
		"materials/mc/gui/sprites/container/anvil/error.png",
		"materials/mc/gui/sprites/container/anvil/text_field.png",
		"materials/mc/gui/sprites/container/anvil/text_field_disabled.png",
		"sound/mc/random/anvil_use.ogg",
		"sound/mc/random/anvil_break.ogg",
	} ) do
		resource.AddFile( fileName )
	end
end

local function blockInfoAt( bx, by, bz )
	if type( World.GetBlockInfo ) ~= "function" then return nil end
	local info = World.GetBlockInfo( bx, by, bz )
	return info and ( info.mcid or info.name ) or nil, info and info.stateId or 0, info
end

local function anvilStillValid( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	local name = blockInfoAt( bx, by, bz )
	if name ~= "minecraft:anvil" and name ~= "minecraft:chipped_anvil" and name ~= "minecraft:damaged_anvil" then
		return false
	end
	if type( PlayerAPI.CanReachCell ) ~= "function" then return false end
	return PlayerAPI.CanReachCell( ply, bx, by, bz ) == true
end

local function playerSlots( storage, offset )
	local definitions, map, reverse, hotbar, targets = {}, {}, {}, {}, {}
	for index = 0, INVENTORY_SIZE - 1 do
		local menuIndex = offset + index
		definitions[#definitions + 1] = {
			index = menuIndex,
			storage = storage,
			storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
		map[index], reverse[menuIndex] = menuIndex, index
		targets[#targets + 1] = menuIndex
		if index < 9 then hotbar[index + 1] = menuIndex end
	end
	return definitions, map, reverse, hotbar, targets
end

local function sameResult( left, right )
	return not MC.IsEmptyItemStack( left ) and not MC.IsEmptyItemStack( right )
		and MC.ItemStacksEqual( left, right, true )
end

local function insertResultCursor( container, result )
	local carried = container.cursor
	if MC.IsEmptyItemStack( carried ) then return MC.ContainerSetCursor( container, result ) end
	if not sameResult( carried, result ) then return false, "result_cursor_different_item" end
	local nextCount = carried.count + result.count
	if nextCount > MC.ItemStackMaxCount( carried ) then return false, "result_cursor_full" end
	return MC.ContainerSetCursor( container, MC.CopyItemStack( carried, nextCount ) )
end

local function insertResultHotbar( container, result, button, context )
	local menuIndex = container.hotbarSlots[( tonumber( button ) or -1 ) + 1]
	local slot = menuIndex ~= nil and MC.ContainerGetSlot( container, menuIndex ) or nil
	if not slot then return false, "missing_hotbar_slot" end
	local existing = MC.InventorySlotGet( slot )
	if MC.IsEmptyItemStack( existing ) then
		if not MC.InventorySlotMayPlace( slot, result, context ) or result.count > MC.InventorySlotLimit( slot, result ) then
			return false, "result_hotbar_denied"
		end
		return MC.InventorySlotSet( slot, result )
	end
	if not sameResult( existing, result ) then return false, "result_hotbar_occupied" end
	local nextCount = existing.count + result.count
	if nextCount > MC.InventorySlotLimit( slot, result ) then return false, "result_hotbar_full" end
	return MC.InventorySlotSet( slot, MC.CopyItemStack( existing, nextCount ) )
end

local function refreshResult( menu )
	local data = menu.anvil
	if not data then return false, "anvil_data_missing" end
	local left = MC.ContainerGetStack( menu, data.leftSlot )
	if not MC.IsEmptyItemStack( left ) and data.leftHash ~= MC.ItemStackHash( left ) then
		data.leftHash = MC.ItemStackHash( left )
		local custom, present = MC.GetItemCustomName( left )
		data.renameText = present and custom or ""
		data.renameExplicit = present
	end
	if MC.IsEmptyItemStack( left ) then
		data.leftHash, data.renameText, data.renameExplicit = nil, "", false
	end
	local result, info = MC.AnvilCreateResult(
		left,
		MC.ContainerGetStack( menu, data.rightSlot ),
		data.renameText,
		{ creative = data.creative == true, renameExplicit = data.renameExplicit == true }
	)
	data.info = info or { resultAvailable = false, cost = 0, error = "anvil_result_failed" }
	local ok, err = MC.ContainerSetStack( menu, data.resultSlot, result )
	return ok == true, err
end

local function takeResult( menu, slotIndex, button, state, context, mode )
	local data = menu.anvil
	if not data or slotIndex ~= data.resultSlot then return false, "invalid_result_slot" end
	local refreshed, refreshError = refreshResult( menu )
	if not refreshed then return false, refreshError or "anvil_result_refresh_failed" end
	local result = MC.ContainerGetStack( menu, data.resultSlot )
	local info = data.info or {}
	if MC.IsEmptyItemStack( result ) or info.resultAvailable ~= true then return false, info.error or "no_anvil_result" end
	if data.creative ~= true then
		if type( SV.PlayerHasExperienceLevels ) ~= "function" then return false, "experience_service_unavailable" end
		if not SV.PlayerHasExperienceLevels( data.record.owner, info.cost ) then return false, "insufficient_experience" end
	end

	local inserted, insertError
	if mode == "quick_move" then
		local remaining, moved = MC.ContainerMoveStackTo( menu, result, data.playerTargets or {}, context )
		inserted = moved and MC.IsEmptyItemStack( remaining )
		insertError = inserted and nil or "anvil_inventory_full"
	elseif mode == "swap" then
		inserted, insertError = insertResultHotbar( menu, result, button, context )
	else
		if button ~= 0 and button ~= 1 then return false, "invalid_button" end
		inserted, insertError = insertResultCursor( menu, result )
	end
	if not inserted then return false, insertError or "anvil_result_insert_failed" end

	local left = MC.ContainerGetStack( menu, data.leftSlot )
	local right = MC.ContainerGetStack( menu, data.rightSlot )
	if MC.IsEmptyItemStack( left ) then return false, "left_input_missing" end
	local ok, err = MC.ContainerSetStack( menu, data.leftSlot, nil )
	if not ok then return false, err end
	if ( tonumber( info.materialCost ) or 0 ) > 0 then
		local used = math.max( 1, math.floor( tonumber( info.materialCost ) or 0 ) )
		ok, err = MC.ContainerSetStack( menu, data.rightSlot,
			right and right.count > used and MC.CopyItemStack( right, right.count - used ) or nil )
	elseif not info.onlyRenaming then
		ok, err = MC.ContainerSetStack( menu, data.rightSlot, nil )
	end
	if not ok then return false, err end
	data.pendingUse = {
		cost = info.cost,
		infinite = data.creative == true,
		bx = data.bx, by = data.by, bz = data.bz,
		renameText = data.renameText,
		renameExplicit = data.renameExplicit,
		leftHash = data.leftHash,
	}
	data.renameText, data.renameExplicit, data.leftHash = "", false, nil
	return true
end

local function sendState( record )
	local session = record and record.session
	local menu = session and session.container
	local data = menu and menu.anvil
	local ply = record and record.owner
	if not data or not IsValid( ply ) then return false end
	local info = data.info or {}
	net.Start( "mc_anvil_state" )
		net.WriteUInt( menu.id, 16 )
		net.WriteString( session.token or "" )
		net.WriteString( string.sub( data.renameText or "", 1, MAX_RENAME_BYTES ) )
		net.WriteBool( data.renameExplicit == true )
		net.WriteUInt( math.Clamp( math.floor( tonumber( info.cost ) or 0 ), 0, 2147483647 ), 32 )
		net.WriteBool( info.resultAvailable == true )
		net.WriteBool( info.tooExpensive == true and data.creative ~= true )
		net.WriteBool( data.creative == true or info.resultAvailable == true
			and SV.PlayerHasExperienceLevels and SV.PlayerHasExperienceLevels( ply, info.cost ) == true )
		net.WriteString( string.sub( tostring( info.error or "" ), 1, 96 ) )
	net.Send( ply )
	return true
end

local function damageAnvilAfterUse( data )
	if not data or data.infinite == true then
		if data then sound.Play( "mc/random/anvil_use.ogg", Coords.CellCenter( data.bx, data.by, data.bz ), 75, 100, 1 ) end
		return
	end
	local position = Coords.CellCenter( data.bx, data.by, data.bz )
	if math.Rand( 0, 1 ) >= 0.12 then sound.Play( "mc/random/anvil_use.ogg", position, 75, 100, 1 ) return end
	local name, stateId = blockInfoAt( data.bx, data.by, data.bz )
	local nextName = name == "minecraft:anvil" and "minecraft:chipped_anvil"
		or name == "minecraft:chipped_anvil" and "minecraft:damaged_anvil" or nil
	if nextName then
		local nextResolved = type( Blocks.Resolve ) == "function" and Blocks.Resolve( nextName ) or nil
		local nextState = nextResolved and type( Blocks.DefaultState ) == "function"
			and Blocks.DefaultState( nextResolved.id ) or nil
		local facing = stateId and type( Blocks.GetProperty ) == "function"
			and Blocks.GetProperty( stateId, "facing" ) or nil
		if nextState and facing and type( Blocks.WithProperty ) == "function" then
			nextState = Blocks.WithProperty( nextState, "facing", facing ) or nextState
		end
		if nextState and type( World.SetBlock ) == "function" then
			World.SetBlock( data.bx, data.by, data.bz, nextState,
				{ actor = nil, fx = false, handlers = false, compareCollision = true } )
		end
		sound.Play( "mc/random/anvil_use.ogg", position, 75, 100, 1 )
	else
		if type( World.RemoveBlock ) == "function" then
			World.RemoveBlock( data.bx, data.by, data.bz, { actor = nil, fx = false, handlers = false } )
		end
		sound.Play( "mc/random/anvil_break.ogg", position, 75, 100, 1 )
	end
end

local function buildMenu( ply, record, bx, by, bz )
	local inputStorage, resultStorage = {}, {}
	local slots = {
		{ index = 0, storage = inputStorage, storageIndex = 1, group = "anvil_left", meta = { role = "input" } },
		{ index = 1, storage = inputStorage, storageIndex = 2, group = "anvil_right", meta = { role = "input" } },
		{ index = 2, storage = resultStorage, storageIndex = 1, group = "anvil_result",
			mayPlace = function() return false end, meta = { role = "result" } },
	}
	local playerOffset = ANVIL_SLOTS
	local definitions, playerMap, menuMap, hotbar, targets = playerSlots( record.storage, playerOffset )
	for _, definition in ipairs( definitions ) do slots[#slots + 1] = definition end
	local menu, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2,
		kind = "anvil",
		revision = record.container.revision,
		slots = slots,
		hotbarSlots = hotbar,
		transferRules = {
			anvil_left = { targets = { "main", "hotbar" } },
			anvil_right = { targets = { "main", "hotbar" } },
			anvil_result = { targets = { "main", "hotbar" } },
			main = { targets = { "anvil_left", "anvil_right" } },
			hotbar = { targets = { "anvil_left", "anvil_right" } },
		},
		context = { player = ply, anvil = true },
	} )
	if not menu then return nil, err end
	record.nextContainerId = ( menu.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	menu.playerOffset, menu.playerMenuMap, menu.menuPlayerMap = playerOffset, playerMap, menuMap
	menu.anvil = {
		leftSlot = 0, rightSlot = 1, resultSlot = 2,
		playerTargets = MC.ContainerResolveTargets( menu, { "hotbar", "main" }, true ),
		renameText = "", renameExplicit = false,
		creative = SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true,
		record = record,
		bx = bx, by = by, bz = bz,
	}
	menu.beforeCommit = function( committed, context )
		local refreshed, refreshError = refreshResult( committed )
		if not refreshed then return false, refreshError or "anvil_result_refresh_failed" end
		local use = committed.anvil and committed.anvil.pendingUse
		if use and use.infinite ~= true and not use.experienceToken then
			if type( SV.TrySpendPlayerExperienceLevels ) ~= "function" then
				return false, "experience_service_unavailable"
			end
			local spendContext = {
				reason = "anvil_take_result",
				actionId = context and context.actionId,
				cost = use.cost,
				bx = use.bx, by = use.by, bz = use.bz,
			}
			committed.anvil.transactionActive = true
			local spendCalled, token, spendError = pcall( SV.TrySpendPlayerExperienceLevels,
				record.owner, use.cost, spendContext )
			committed.anvil.transactionActive = false
			if not spendCalled or not token then
				return false, spendCalled and ( spendError or "insufficient_experience" ) or "experience_spend_error"
			end
			use.experienceToken = token
		end
		return true
	end
	menu.onInputRollback = function( committed, _, context )
		local use = committed.anvil and committed.anvil.pendingUse
		if not use then return end
		if use.experienceToken and SV.RollbackPlayerExperienceSpend then
			SV.RollbackPlayerExperienceSpend( use.experienceToken, {
				reason = "anvil_input_rollback",
				actionId = context and context.actionId,
			} )
		end
		committed.anvil.renameText = use.renameText or ""
		committed.anvil.renameExplicit = use.renameExplicit == true
		committed.anvil.leftHash = use.leftHash
		committed.anvil.pendingUse = nil
		refreshResult( committed )
		sendState( record )
	end
	menu.takeResult = takeResult
	local refreshed, refreshError = refreshResult( menu )
	if not refreshed then return nil, refreshError or "anvil_result_refresh_failed" end
	menu.onCommit = function( committed, result, context )
		local use = committed.anvil and committed.anvil.pendingUse
		if use then committed.anvil.pendingUse = nil end
		local playerChanged = false
		for _, index in ipairs( result.changedSlots or {} ) do if menuMap[index] ~= nil then playerChanged = true break end end
		committed.revision = math.max( committed.revision, record.container.revision or 0 )
		record.container.revision, record.revision = committed.revision, committed.revision
		if playerChanged then
			record.dirty = true
			if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
		end
		if SV.PublishActiveInventoryCommit then SV.PublishActiveInventoryCommit( record, result, context or {} ) end
		if use then damageAnvilAfterUse( use ) end
		sendState( record )
		return true
	end
	return menu
end

local function returnInputStack( record, menu, slotIndex, position )
	local stack = MC.ContainerGetStack( menu, slotIndex )
	if MC.IsEmptyItemStack( stack ) then return end
	MC.ContainerSetStack( menu, slotIndex, nil )
	local targets = {}
	for index = 0, INVENTORY_SIZE - 1 do targets[#targets + 1] = index end
	local remaining = select( 1, MC.ContainerMoveStackTo( record.container, stack, targets, { reason = "anvil_close" } ) )
	if not MC.IsEmptyItemStack( remaining ) and SV.SpawnItemDrop then SV.SpawnItemDrop( position, remaining, record.owner ) end
end

function SV.OpenAnvil( ply, bx, by, bz )
	if not anvilStillValid( ply, bx, by, bz ) then return false, "anvil_unavailable" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return false, "inventory_not_loaded" end
	if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local menu, err = buildMenu( ply, record, bx, by, bz )
	if not menu then return false, err end
	menu.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	local session = {
		token = util.SHA256 and util.SHA256( table.concat( { ply:EntIndex(), SysTime(), math.random(), "anvil" }, ":" ) )
			or util.CRC( tostring( SysTime() ) ),
		kind = "anvil", container = menu, creative = false, openedAt = CurTime(), lastActionId = nil,
		playerOffset = menu.playerOffset, resultSlot = 2, anvil = true,
		validate = function() return anvilStillValid( ply, bx, by, bz ) end,
		onClose = function( closedRecord, closedSession )
			local closedMenu = closedSession.container
			local position = Coords.CellCenter( bx, by, bz )
			local before = MC.ContainerSnapshot( closedRecord.container )
			returnInputStack( closedRecord, closedMenu, 0, position )
			returnInputStack( closedRecord, closedMenu, 1, position )
			MC.ContainerSetStack( closedMenu, 2, nil )
			local changed = MC.ContainerChangedSlots( closedRecord.container, before )
			if #changed > 0 then
				closedRecord.container.revision = math.max( closedRecord.container.revision + 1, closedMenu.revision )
				closedRecord.revision, closedRecord.dirty = closedRecord.container.revision, true
				if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( closedRecord ) end
			end
			if IsValid( closedRecord.owner ) and SV.SendActiveInventorySnapshot then
				SV.SendActiveInventorySnapshot( closedRecord.owner, "anvil_close" )
			end
		end,
	}
	record.session = session
	if SV.SendActiveInventoryOpen then SV.SendActiveInventoryOpen( ply, record, "anvil" ) end
	sendState( record )
	return true
end

net.Receive( "mc_anvil_rename", function( bytes, ply )
	if bytes > 4096 then return end
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local requestedName = net.ReadString()
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local session = record and record.session
	local menu = session and session.container
	if not menu or session.kind ~= "anvil" or containerId ~= menu.id or token ~= session.token then return end
	if not anvilStillValid( ply, menu.anvil.bx, menu.anvil.by, menu.anvil.bz ) then
		SV.ClosePlayerInventory( ply, "container_unavailable" )
		return
	end
	local now = CurTime()
	local rate = session.anvilRenameRate
	if not rate or now - rate.startedAt >= 1 then
		session.anvilRenameRate = { startedAt = now, count = 1 }
	elseif rate.count >= 40 then
		sendState( record )
		return
	else
		rate.count = rate.count + 1
	end
	if #requestedName > MAX_RENAME_BYTES then sendState( record ) return end
	local filtered = MC.AnvilValidateName( requestedName )
	if not filtered then sendState( record ) return end
	-- A rename message exists only after a user edit. The initial, non-explicit
	-- prefill is established exclusively by refreshResult on the server, so a
	-- client cannot suppress rename/removal costs by submitting explicit=false.
	menu.anvil.renameText, menu.anvil.renameExplicit = filtered, true
	local snapshot = MC.ContainerSnapshot( menu )
	local refreshed = refreshResult( menu )
	if not refreshed then MC.ContainerRestore( menu, snapshot ) sendState( record ) return end
	local changed = MC.ContainerChangedSlots( menu, snapshot )
	if #changed > 0 then menu.revision = menu.revision + 1 end
	record.container.revision = math.max( record.container.revision or 0, menu.revision )
	record.revision = record.container.revision
	local result = { ok = true, revision = menu.revision, changedSlots = changed, changed = {}, cursor = MC.CopyItemStack( menu.cursor ), drops = {} }
	for _, index in ipairs( changed ) do result.changed[index] = MC.CopyItemStack( MC.ContainerGetStack( menu, index ) ) end
	if #changed > 0 and SV.PublishActiveInventoryCommit then SV.PublishActiveInventoryCommit( record, result, { reason = "anvil_rename" } ) end
	sendState( record )
end )

hook.Add( "MC.BlocksChanged", "mc_anvil_menu_validity", function()
	for ply, record in pairs( SV.PlayerInventories or {} ) do
		local session = record and record.session
		if session and session.kind == "anvil" and not session.validate() then
			SV.ClosePlayerInventory( ply, "anvil_unavailable" )
		end
	end
end )

hook.Add( "MC.PlayerExperienceChanged", "mc_anvil_experience_refresh", function( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local session = record and record.session
	local data = session and session.container and session.container.anvil
	if session and session.kind == "anvil" and data and data.transactionActive ~= true then
		sendState( record )
	end
end )
