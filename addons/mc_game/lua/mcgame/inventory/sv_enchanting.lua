-- Server-authoritative transient enchanting-table menu and experience/seed
-- transaction. Clients submit only an option index through the ordered
-- inventory menu-button channel; every result is recomputed here.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local API = MC.API or {}
local World = API.World or {}
local Coords = API.Coords or {}
local PlayerAPI = API.Player or {}
local Sound = API.Sound or {}
local SV = MC.SV
local ENCHANTING_SLOTS = 2
local INVENTORY_SIZE = 36
local STATE_VERSION = 1
local INT_MAX = 2147483647

if type( API.RegisterEvents ) == "function" then
	API.RegisterEvents( "mc.game.enchanting", {
		["MC.PlayerEnchantmentSeedChanged"] = {
			realm = "server",
			args = "ply, previousSeed, nextSeed, context",
			desc = "an enchanting-table transaction committed a new player enchantment seed",
		},
	} )
end

local function blockInfoAt( bx, by, bz )
	if type( World.GetBlockInfo ) ~= "function" then return nil end
	local info = World.GetBlockInfo( bx, by, bz )
	return info and ( info.mcid or info.name ) or nil, info and info.stateId or 0, info
end

local function enchantingStillValid( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false end
	local name = blockInfoAt( bx, by, bz )
	if name ~= "minecraft:enchanting_table" and name ~= "enchanting_table" then return false end
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

local function isLapis( stack )
	return not MC.IsEmptyItemStack( stack ) and stack.item == "minecraft:lapis_lazuli"
end

local function normalizedSeed( value )
	value = tonumber( value )
	if not value then return nil end
	return bit.tobit( math.floor( value ) )
end

local function nextEnchantmentSeed( record, context )
	local previous = normalizedSeed( record and record.enchantmentSeed ) or 0
	for salt = 1, 4 do
		local entropy = table.concat( {
			tostring( record and record.ownerId or "" ),
			tostring( SysTime and SysTime() or 0 ),
			tostring( CurTime and CurTime() or 0 ),
			tostring( context and context.actionId or "" ),
			tostring( math.random() ),
			tostring( salt ),
		}, ":" )
		local candidate = normalizedSeed( util.CRC( entropy ) )
		if candidate and candidate ~= previous and candidate ~= 0 then return candidate end
	end
	local fallback = bit.tobit( previous + 1831565813 )
	return fallback ~= 0 and fallback or 1
end

function SV.GetPlayerEnchantmentSeed( ply, create )
	if not IsValid( ply ) or not ply:IsPlayer() then return nil, "invalid_player" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, create ~= false ) or nil
	if not record then return nil, "inventory_not_loaded" end
	record.enchantmentSeed = normalizedSeed( record.enchantmentSeed ) or nextEnchantmentSeed( record )
	return record.enchantmentSeed
end

local function blankOptions( errorCode )
	local options = {}
	for optionIndex = 0, 2 do
		options[optionIndex + 1] = {
			index = optionIndex,
			cost = 0,
			lapisCost = optionIndex + 1,
			enchantments = {},
			clue = nil,
			clueLevel = 0,
			error = errorCode,
		}
	end
	return options
end

local function stackHash( stack )
	if MC.IsEmptyItemStack( stack ) then return "" end
	if MC.ItemStackHash then return tostring( MC.ItemStackHash( stack ) or "" ) end
	return tostring( stack.item or "" ) .. ":" .. tostring( stack.count or 0 )
end

local function refreshOptions( menu )
	local data = menu and menu.enchanting
	local record = data and data.record
	if not data or not record then return false, "enchanting_data_missing" end

	local seed = normalizedSeed( record.enchantmentSeed )
	if seed == nil then
		seed = nextEnchantmentSeed( record )
		record.enchantmentSeed = seed
		record.dirty = true
	end
	local bookshelfCount = MC.EnchantingCountBookshelves
		and select( 1, MC.EnchantingCountBookshelves( data.bx, data.by, data.bz ) ) or 0
	local item = MC.ContainerGetStack( menu, data.itemSlot )
	local itemKey = stackHash( item )
	local changed = data.itemHash ~= itemKey or data.seed ~= seed or data.bookshelfCount ~= bookshelfCount
	local options, errorCode
	if MC.EnchantingBuildOptions then
		options, errorCode = MC.EnchantingBuildOptions( seed, bookshelfCount, item )
	end
	if not options then
		errorCode = errorCode
			or ( MC.EnchantingBuildOptions and "enchanting_options_failed" or "enchanting_rules_unavailable" )
		options = blankOptions( errorCode )
	end

	data.itemHash = itemKey
	data.seed = seed
	data.bookshelfCount = bookshelfCount
	data.options = options
	data.error = errorCode
	return true, changed
end

local function optionAvailability( menu, option )
	local data = menu.enchanting
	if data.error then return false, data.error end
	local lapis = MC.ContainerGetStack( menu, data.lapisSlot )
	local lapisCount = isLapis( lapis ) and math.max( 0, math.floor( tonumber( lapis.count ) or 0 ) ) or 0
	local experienceLevel = data.record and math.max( 0, math.floor( tonumber( data.record.experienceLevel ) or 0 ) ) or 0
	if not MC.EnchantingOptionAvailable then return false, "enchanting_rules_unavailable" end
	return MC.EnchantingOptionAvailable( option, experienceLevel, lapisCount, data.infinite == true )
end

local function sendState( record )
	local session = record and record.session
	local menu = session and session.container
	local data = menu and menu.enchanting
	local ply = record and record.owner
	if not data or session.kind ~= "enchanting_table" or not IsValid( ply ) then return false end
	local refreshed = refreshOptions( menu )
	if not refreshed then return false end

	net.Start( "mc_enchanting_state" )
		net.WriteUInt( STATE_VERSION, 8 )
		net.WriteUInt( menu.id, 16 )
		net.WriteString( session.token or "" )
		net.WriteUInt( math.Clamp( math.floor( tonumber( menu.revision ) or 0 ), 0, 4294967295 ), 32 )
		net.WriteUInt( math.Clamp( math.floor( tonumber( data.bookshelfCount ) or 0 ), 0, 15 ), 4 )
		for optionIndex = 0, 2 do
			local option = data.options and data.options[optionIndex + 1] or nil
			local available, errorCode = optionAvailability( menu, option )
			if option and option.error then errorCode = option.error end
			net.WriteUInt( math.Clamp( math.floor( tonumber( option and option.cost ) or 0 ), 0, INT_MAX ), 32 )
			net.WriteString( string.sub( tostring( option and option.clue or "" ), 1, 128 ) )
			net.WriteUInt( math.Clamp( math.floor( tonumber( option and option.clueLevel ) or 0 ), 0, 255 ), 8 )
			net.WriteBool( available == true )
			net.WriteString( string.sub( tostring( errorCode or "" ), 1, 96 ) )
		end
	net.Send( ply )
	return true
end

SV.SendEnchantingState = sendState

local function transactionContext( context, optionIndex )
	local result = {}
	for key, value in pairs( type( context ) == "table" and context or {} ) do result[key] = value end
	result.reason = "enchanting_table"
	result.option = optionIndex
	return result
end

local function selectOption( record, menu, optionIndex, context )
	local data = menu and menu.enchanting
	if not data or data.record ~= record then return nil, "enchanting_data_missing" end
	optionIndex = math.floor( tonumber( optionIndex ) or -1 )
	if optionIndex < 0 or optionIndex > 2 then return nil, "invalid_enchantment_option" end
	local refreshed, refreshError = refreshOptions( menu )
	if not refreshed then return nil, refreshError or "enchanting_options_failed" end

	local option = data.options and data.options[optionIndex + 1] or nil
	local available, availabilityError = optionAvailability( menu, option )
	if not available then return nil, availabilityError or "enchantment_unavailable" end
	local item = MC.ContainerGetStack( menu, data.itemSlot )
	if not MC.EnchantingIsItemEnchantable or not MC.EnchantingIsItemEnchantable( item ) then
		return nil, "enchantment_unavailable"
	end
	local output, outputError = MC.EnchantingApplyResult( item, option.enchantments )
	if not output then return nil, outputError or "enchantment_write_failed" end

	local payment = optionIndex + 1
	local lapis = MC.ContainerGetStack( menu, data.lapisSlot )
	local nextLapis = lapis
	if data.infinite ~= true then
		if not isLapis( lapis ) or math.floor( tonumber( lapis.count ) or 0 ) < payment then
			return nil, "not_enough_lapis"
		end
		nextLapis = lapis.count > payment and MC.CopyItemStack( lapis, lapis.count - payment ) or nil
	end

	-- Every operation which can reject a stack happens before experience is
	-- spent. Once TrySpend succeeds, the remaining commit is assignments only,
	-- so an external experience hook cannot leave a half-applied item transaction.
	local snapshot = MC.ContainerSnapshot( menu )
	local ok, err = MC.ContainerSetStack( menu, data.itemSlot, output )
	if not ok then MC.ContainerRestore( menu, snapshot ) return nil, err or "enchantment_result_rejected" end
	if data.infinite ~= true then
		ok, err = MC.ContainerSetStack( menu, data.lapisSlot, nextLapis )
		if not ok then MC.ContainerRestore( menu, snapshot ) return nil, err or "lapis_update_failed" end
	end

	local changedSlots = MC.ContainerChangedSlots( menu, snapshot )
	local changed = {}
	for _, index in ipairs( changedSlots ) do changed[index] = MC.CopyItemStack( MC.ContainerGetStack( menu, index ) ) end
	local nextSeed = nextEnchantmentSeed( record, context )
	local spendToken
	if data.infinite ~= true then
		if type( SV.TrySpendPlayerExperienceLevels ) ~= "function" then
			MC.ContainerRestore( menu, snapshot )
			return nil, "experience_service_unavailable"
		end
		data.transactionActive = true
		local spendCalled
		spendCalled, spendToken, err = pcall( SV.TrySpendPlayerExperienceLevels, record.owner, payment,
			transactionContext( context, optionIndex ) )
		data.transactionActive = false
		if not spendCalled or not spendToken then
			MC.ContainerRestore( menu, snapshot )
			return nil, spendCalled and ( err or "insufficient_experience" ) or "experience_spend_error"
		end
	end

	local previousSeed = record.enchantmentSeed
	record.enchantmentSeed = nextSeed
	record.dirty = true
	menu.revision = math.max( snapshot.revision + 1, ( record.container and record.container.revision or 0 ) + 1 )
	if record.container then record.container.revision = menu.revision end
	record.revision = menu.revision
	data.seed = nextSeed
	local result = {
		ok = true,
		actionId = context and context.actionId,
		revision = menu.revision,
		changedSlots = changedSlots,
		changed = changed,
		cursorChanged = false,
		cursor = MC.CopyItemStack( menu.cursor ),
		drops = {},
	}
	local eventOK, eventError = pcall( hook.Run, "MC.PlayerEnchantmentSeedChanged", record.owner,
		previousSeed, nextSeed, transactionContext( context, optionIndex ) )
	if not eventOK and ErrorNoHalt then
		ErrorNoHalt( "[MC Enchanting] seed-change listener failed: " .. tostring( eventError ) .. "\n" )
	end
	if type( Sound.Play ) == "function" and type( Coords.CellCenter ) == "function" then
		pcall( Sound.Play, "block.enchantment_table.use",
			Coords.CellCenter( data.bx, data.by, data.bz ), {
				volume = 1,
				pitch = math.Rand( 0.9, 1.0 ),
				soundLevel = 75,
			} )
	end
	return result
end

SV.EnchantingSelectOption = selectOption

local function buildMenu( ply, record, bx, by, bz )
	local specialStorage = {}
	local slots = {
		{
			index = 0, storage = specialStorage, storageIndex = 1, group = "enchanting_item", maxStack = 1,
			mayPlace = function( _, stack )
				return MC.EnchantingIsItemEnchantable and MC.EnchantingIsItemEnchantable( stack ) or false
			end,
			meta = { role = "input" },
		},
		{
			index = 1, storage = specialStorage, storageIndex = 2, group = "enchanting_lapis",
			mayPlace = function( _, stack ) return isLapis( stack ) end,
			meta = { role = "lapis" },
		},
	}
	local playerOffset = ENCHANTING_SLOTS
	local definitions, playerMap, menuMap, hotbar, targets = playerSlots( record.storage, playerOffset )
	for _, definition in ipairs( definitions ) do slots[#slots + 1] = definition end
	local function playerQuickMoveTargets( _, source )
		if isLapis( source ) then return { "enchanting_lapis" } end
		if MC.EnchantingIsItemEnchantable and MC.EnchantingIsItemEnchantable( source ) then
			return { "enchanting_item" }
		end
		return {}
	end
	local menu, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2,
		kind = "enchanting_table",
		revision = record.container.revision,
		slots = slots,
		hotbarSlots = hotbar,
		transferRules = {
			enchanting_item = { targets = { "main", "hotbar" }, reverse = true },
			enchanting_lapis = { targets = { "main", "hotbar" }, reverse = true },
			main = { resolve = playerQuickMoveTargets },
			hotbar = { resolve = playerQuickMoveTargets },
		},
		context = { player = ply, enchanting = true },
	} )
	if not menu then return nil, err end
	record.nextContainerId = ( menu.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	menu.playerOffset, menu.playerMenuMap, menu.menuPlayerMap = playerOffset, playerMap, menuMap
	menu.enchanting = {
		itemSlot = 0,
		lapisSlot = 1,
		playerTargets = targets,
		record = record,
		infinite = SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true,
		bx = bx, by = by, bz = bz,
	}
	menu.beforeCommit = function( committed ) return refreshOptions( committed ) end
	menu.onCommit = function( committed, result, context )
		local playerChanged = false
		for _, index in ipairs( result.changedSlots or {} ) do
			if menuMap[index] ~= nil then playerChanged = true break end
		end
		committed.revision = math.max( committed.revision, record.container.revision or 0 )
		record.container.revision, record.revision = committed.revision, committed.revision
		if playerChanged then
			record.dirty = true
			if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
		end
		if SV.PublishActiveInventoryCommit then SV.PublishActiveInventoryCommit( record, result, context or {} ) end
		sendState( record )
		return true
	end
	menu.menuButton = function( committed, button, context )
		return selectOption( record, committed, button, context )
	end
	menu.afterMenuButton = function() sendState( record ) end
	menu.sendMenuState = function() sendState( record ) end
	local refreshed, refreshError = refreshOptions( menu )
	if not refreshed then return nil, refreshError or "enchanting_options_failed" end
	return menu
end

SV.BuildEnchantingTableMenu = buildMenu

local function returnInputStack( record, menu, slotIndex, position )
	local stack = MC.ContainerGetStack( menu, slotIndex )
	if MC.IsEmptyItemStack( stack ) then return end
	MC.ContainerSetStack( menu, slotIndex, nil )
	local targets = {}
	for index = 0, INVENTORY_SIZE - 1 do targets[#targets + 1] = index end
	local remaining = select( 1, MC.ContainerMoveStackTo( record.container, stack, targets,
		{ reason = "enchanting_close" } ) )
	if not MC.IsEmptyItemStack( remaining ) then
		if SV.SpawnItemDrop then SV.SpawnItemDrop( position, remaining, record.owner )
		else record.carried = MC.CopyItemStack( remaining ) end
	end
end

function SV.OpenEnchantingTable( ply, bx, by, bz )
	if not enchantingStillValid( ply, bx, by, bz ) then return false, "enchanting_table_unavailable" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return false, "inventory_not_loaded" end
	if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local menu, err = buildMenu( ply, record, bx, by, bz )
	if not menu then return false, err end
	menu.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	local session = {
		token = util.SHA256 and util.SHA256( table.concat( {
			ply:EntIndex(), SysTime(), math.random(), "enchanting_table",
		}, ":" ) ) or util.CRC( tostring( SysTime() ) ),
		kind = "enchanting_table",
		container = menu,
		creative = false,
		openedAt = CurTime(),
		lastActionId = nil,
		playerOffset = menu.playerOffset,
		playerMenuMap = menu.playerMenuMap,
		menuPlayerMap = menu.menuPlayerMap,
		chestSlots = 0,
		enchanting = true,
		validate = function() return enchantingStillValid( ply, bx, by, bz ) end,
		onClose = function( closedRecord, closedSession )
			local closedMenu = closedSession.container
			local position = Coords.CellCenter( bx, by, bz )
			local before = MC.ContainerSnapshot( closedRecord.container )
			returnInputStack( closedRecord, closedMenu, 0, position )
			returnInputStack( closedRecord, closedMenu, 1, position )
			local changed = MC.ContainerChangedSlots( closedRecord.container, before )
			if #changed > 0 then
				closedRecord.container.revision = math.max( closedRecord.container.revision + 1, closedMenu.revision )
				closedRecord.revision, closedRecord.dirty = closedRecord.container.revision, true
				if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( closedRecord ) end
			end
			if IsValid( closedRecord.owner ) and SV.SendActiveInventorySnapshot then
				SV.SendActiveInventorySnapshot( closedRecord.owner, "enchanting_close" )
			end
		end,
	}
	record.session = session
	if SV.SendActiveInventoryOpen then SV.SendActiveInventoryOpen( ply, record, "enchanting_table" ) end
	sendState( record )
	return true
end

local function publishOptionRevision( record, menu, reason )
	local nextRevision = math.max( menu.revision or 0, record.container and record.container.revision or 0 ) + 1
	menu.revision = nextRevision
	if record.container then record.container.revision = nextRevision end
	record.revision = nextRevision
	if SV.PublishActiveInventoryCommit then
		SV.PublishActiveInventoryCommit( record, { changedSlots = {} }, { reason = reason or "enchanting_options" } )
	end
	sendState( record )
end

local function refreshOpenEnchantingMenus( reason )
	for ply, record in pairs( SV.PlayerInventories or {} ) do
		local session = record and record.session
		if session and session.kind == "enchanting_table" then
			if not session.validate() then
				if SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "enchanting_table_unavailable" ) end
			else
				local menu = session.container
				local ok, changed = refreshOptions( menu )
				if ok and changed then publishOptionRevision( record, menu, reason ) end
			end
		end
	end
end

hook.Add( "MC.BlocksChanged", "mc_enchanting_menu_refresh", function()
	refreshOpenEnchantingMenus( "enchanting_world_changed" )
end )

hook.Add( "MC.WorldFilled", "mc_enchanting_menu_fill_refresh", function()
	refreshOpenEnchantingMenus( "enchanting_world_filled" )
end )

hook.Add( "MC.PlayerExperienceChanged", "mc_enchanting_experience_refresh", function( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local session = record and record.session
	local data = session and session.container and session.container.enchanting
	if session and session.kind == "enchanting_table" and data and data.transactionActive ~= true then
		sendState( record )
	end
end )

timer.Create( "mc_enchanting_menu_periodic_refresh", 0.5, 0, function()
	refreshOpenEnchantingMenus( "enchanting_periodic_refresh" )
end )
