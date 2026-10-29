--[[----------------------------------------------------------------------------
	Server-side chest menus.

	The menu is a temporary view over the persistent player inventory and one or
	two sparse chest block-entity records.  Only the menu actions cross the net;
	the chest contents themselves remain authoritative on the server and are
	serialized by the normal region save codec.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local API = MC.API or {}
local World = API.World
local Blocks = API.Blocks
local CHEST_SLOTS = 27
local chestWorldEpoch = 0
SV.ChestOpeners = SV.ChestOpeners or {}
SV.ChestOpenPositions = SV.ChestOpenPositions or {}
util.AddNetworkString( "mc_chest_open_state" )
local CHEST_CLOSE_SOUNDS = {
	"mc/block/chest/close1.ogg",
	"mc/block/chest/close2.ogg",
	"mc/block/chest/close3.ogg",
}
local CHEST_BLOCK_NAMES = {
	chest = true, trapped_chest = true, copper_chest = true,
	exposed_copper_chest = true, weathered_copper_chest = true,
	oxidized_copper_chest = true, waxed_copper_chest = true,
	waxed_exposed_copper_chest = true, waxed_weathered_copper_chest = true,
	waxed_oxidized_copper_chest = true,
}

local function copyStack( stack ) return MC.CopyItemStack( stack ) end

local function chestOpenKey( position )
	return position and MC.CellKey and MC.CellKey( position.bx, position.by, position.bz ) or nil
end

local function sendChestOpenState( position, count, target )
	if not position then return end
	net.Start( "mc_chest_open_state" )
		net.WriteInt( position.bx, MC.Net.COORD_BITS )
		net.WriteInt( position.by, MC.Net.COORD_BITS )
		net.WriteInt( position.bz, MC.Net.COORD_BITS )
		net.WriteUInt( math.min( math.max( math.floor( tonumber( count ) or 0 ), 0 ), 255 ), 8 )
	if target then net.Send( target ) else net.Broadcast() end
end

local function adjustChestOpeners( positions, delta )
	local playedOpenSound = false
	local playedCloseSound = false
	for _, position in ipairs( positions or {} ) do
		local key = chestOpenKey( position )
		if key then
			local previousCount = tonumber( SV.ChestOpeners[key] ) or 0
			local count = math.max( 0, previousCount + delta )
			if count == 0 then
				SV.ChestOpeners[key] = nil
				SV.ChestOpenPositions[key] = nil
			else
				SV.ChestOpeners[key] = count
				SV.ChestOpenPositions[key] = { bx = position.bx, by = position.by, bz = position.bz }
			end
			sendChestOpenState( position, count )
			if MC.RunEvent then MC.RunEvent( "MC.ChestOpenCountChanged", position.bx, position.by, position.bz, count ) end
			if not playedOpenSound and previousCount == 0 and count > 0 then
				playedOpenSound = true
				local soundPosition = MC.CellWorldCenter( position.bx, position.by, position.bz )
				sound.Play( "mc/block/chest/open.ogg", soundPosition, 65, math.random( 90, 100 ), 0.5 )
			end
			if not playedCloseSound and previousCount > 0 and count == 0 then
				playedCloseSound = true
				local soundPosition = MC.CellWorldCenter( position.bx, position.by, position.bz )
				sound.Play( CHEST_CLOSE_SOUNDS[math.random( #CHEST_CLOSE_SOUNDS )], soundPosition, 65, math.random( 90, 100 ), 0.5 )
			end
		end
	end
end

function SV.GetChestOpenCount( bx, by, bz )
	local key = MC.CellKey and MC.CellKey( bx, by, bz ) or nil
	return key and ( tonumber( SV.ChestOpeners[key] ) or 0 ) or 0
end

hook.Add( "PlayerInitialSpawn", "mc_chest_open_state_sync", function( ply )
	timer.Simple( 1, function()
		if not IsValid( ply ) then return end
		for key, count in pairs( SV.ChestOpeners ) do
			if count > 0 then
				local position = SV.ChestOpenPositions[key]
				if position then sendChestOpenState( position, count, ply ) end
			end
		end
	end )
end )

local function recordChestOverlay( bx, by, bz, record )
	if not World or not World.SetBlockEntity then return false end
	local saved, saveError = World.SetBlockEntity( bx, by, bz, record, { reason = "chest_runtime" } )
	if saved == true then
		-- World.GetBlockEntity returns a private copy of the transaction-stamped
		-- record.  Menus must not keep the pre-write revision.
		local persisted = World.GetBlockEntity and World.GetBlockEntity( bx, by, bz ) or nil
		return type( persisted ) == "table" and persisted or record
	end
	local message = "[MC Chest] lazy overlay record failed: " .. tostring( saveError or "unknown" ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
	return false
end

local function mutableBlockEntity( bx, by, bz )
	if not World or not World.GetBlockEntity then return nil end
	return World.GetBlockEntity( bx, by, bz )
end

local function ensureMutableChestBlockEntity( bx, by, bz )
	local record = mutableBlockEntity( bx, by, bz )
	if record then return record end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not Blocks or not Blocks.CreateDefaultBlockEntity then return nil end
	local created = Blocks.CreateDefaultBlockEntity( stateId )
	if type( created ) ~= "table" then return nil end
	return recordChestOverlay( bx, by, bz, created ) or nil
end

local function stateInfoAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	return MC.ChestStateInfo and MC.ChestStateInfo( stateId ) or nil, stateId
end

local function offsetForDirection( direction )
	if direction == "north" then return 0, -1 end
	if direction == "south" then return 0, 1 end
	if direction == "west" then return -1, 0 end
	return 1, 0
end

local function clockwise( facing )
	if facing == "north" then return "east" end
	if facing == "east" then return "south" end
	if facing == "south" then return "west" end
	return "north"
end

local function counterClockwise( facing )
	if facing == "north" then return "west" end
	if facing == "west" then return "south" end
	if facing == "south" then return "east" end
	return "north"
end

local function oppositeType( chestType )
	return chestType == "left" and "right" or chestType == "right" and "left" or "single"
end

local function connectedDirection( info )
	if not info or info.type == "single" then return nil end
	return info.type == "left" and clockwise( info.facing ) or counterClockwise( info.facing )
end

local function sameChest( left, right )
	return left and right and left.name == right.name and left.facing == right.facing
end

local function chestPositions( bx, by, bz )
	local info = stateInfoAt( bx, by, bz )
	if not info or not CHEST_BLOCK_NAMES[string.match( info.name, ".*:([a-z0-9_]+)$" ) or ""] then return nil end
	local result = { { bx = bx, by = by, bz = bz, info = info } }
	local direction = connectedDirection( info )
	if not direction then return result end
	local dx, dy = offsetForDirection( direction )
	local otherInfo = stateInfoAt( bx + dx, by + dy, bz )
	if not sameChest( info, otherInfo ) or otherInfo.type ~= oppositeType( info.type ) then return result end
	result[#result + 1] = { bx = bx + dx, by = by + dy, bz = bz, info = otherInfo }
	-- Vanilla's first/second order follows DoubleBlockCombiner: RIGHT is first,
	-- LEFT is second.  This only affects slot ordering, not persistence.
	if info.type == "left" then
		return { result[2], result[1] }
	end
	return result
end

local function sessionToken( ply, record )
	local seed = table.concat( {
		tostring( record.ownerId or ply:EntIndex() ), tostring( SysTime() ),
		tostring( math.random() ), tostring( record.container.revision ), "chest",
	}, ":" )
	return util.SHA256 and util.SHA256( seed ) or util.CRC( seed )
end

local function markChestDirty( chestRecords )
	for _, entry in ipairs( chestRecords or {} ) do
		entry.record.dirty = true
		local position = entry.position
		if position then
			local persisted = recordChestOverlay( position.bx, position.by, position.bz, entry.record )
			if type( persisted ) == "table" then entry.record = persisted end
		end
	end
end

local function encodeChestRecord( record, storage )
	local rebuilt = MC.ChestRecordFromStorage( storage, record.data and record.data.customName )
	record.type = rebuilt.type
	record.codecVersion = rebuilt.codecVersion
	record.data = rebuilt.data
	record.revision = ( record.revision or 0 ) + 1
end

local function samePosition( left, right )
	return left and right and left.bx == right.bx and left.by == right.by and left.bz == right.bz
end

local function refreshChestMenus( records, storages, sourceMenu )
	for _, playerRecord in pairs( SV.PlayerInventories or {} ) do
		local session = playerRecord.session
		local menu = session and session.kind == "chest" and session.container or nil
		if menu and menu ~= sourceMenu then
			local changed = {}
			for menuIndex, menuEntry in ipairs( menu.chestRecords ) do
				for sourceIndex, sourceEntry in ipairs( records ) do
					if samePosition( menuEntry.position, sourceEntry.position ) then
						local position = sourceEntry.position
						local persisted = mutableBlockEntity( position.bx, position.by, position.bz )
						if not persisted then
							MC.Fault( "chest_menu_record_missing", "missing committed chest at %d,%d,%d",
								position.bx, position.by, position.bz )
						else
							menuEntry.record = persisted
						end
						local target = menu.chestStorages[menuIndex]
						local source = storages[sourceIndex]
						for slot = 1, CHEST_SLOTS do
							if not MC.ItemStacksEqual( target[slot], source[slot] ) then
								target[slot] = MC.CopyItemStack( source[slot] )
								changed[#changed + 1] = ( menuIndex - 1 ) * CHEST_SLOTS + slot - 1
							end
						end
						break
					end
				end
			end
			if #changed > 0 then
				menu.revision = math.max( menu.revision, playerRecord.container.revision ) + 1
				SV.PublishActiveInventoryCommit( playerRecord, { changedSlots = changed, revision = menu.revision }, {} )
			end
		end
	end
end

local function playerSlotDefinitions( storage, offset )
	local definitions = {}
	for index = 0, 35 do
		definitions[#definitions + 1] = {
			index = offset + index,
			storage = storage,
			storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
	end
	return definitions
end

local function buildMenu( ply, record, positions )
	local chestCount = #positions * CHEST_SLOTS
	local storages, chestRecords = {}, {}
	for index, position in ipairs( positions ) do
		local be = ensureMutableChestBlockEntity( position.bx, position.by, position.bz )
		if not be or be.type ~= "minecraft:chest" then return nil, "chest_data_missing" end
		local storage = MC.ChestStorageFromRecord( be )
		storages[index] = storage
		chestRecords[index] = { record = be, position = position }
	end

	local slots = {}
	for chestIndex = 1, #storages do
		local storage = storages[chestIndex]
		local base = ( chestIndex - 1 ) * CHEST_SLOTS
		for slot = 0, CHEST_SLOTS - 1 do
			slots[#slots + 1] = {
				index = base + slot, storage = storage, storageIndex = slot + 1, group = "chest",
			}
		end
	end
	local playerOffset = chestCount
	for _, definition in ipairs( playerSlotDefinitions( record.storage, playerOffset ) ) do slots[#slots + 1] = definition end

	local menu, err = MC.NewInventoryContainer( {
		id = record.nextContainerId or 2,
		kind = #positions > 1 and "chest_double" or "chest",
		revision = record.container.revision,
		slots = slots,
		hotbarSlots = (function()
			local map = {}
			for button = 0, 8 do map[button + 1] = playerOffset + button end
			return map
		end)(),
		transferRules = {
			chest = { targets = { "hotbar", "main" }, reverse = true },
			main = { targets = { "chest" } },
			hotbar = { targets = { "chest" } },
		},
	} )
	if not menu then return nil, err end
	record.nextContainerId = ( menu.id + 1 ) % 65535
	if record.nextContainerId == 0 or record.nextContainerId == 1 then record.nextContainerId = 2 end
	menu.context = { player = ply, chest = true }
	menu.chestRecords = chestRecords
	menu.chestStorages = storages
	menu.playerOffset = playerOffset
	menu.chestSlots = chestCount
	menu.onCommit = function( committed, result, context )
		local chestChanged = false
		local playerChanged = false
		for _, index in ipairs( result.changedSlots or {} ) do
			if index < playerOffset then chestChanged = true else playerChanged = true end
		end
		if chestChanged then
			for index, entry in ipairs( chestRecords ) do encodeChestRecord( entry.record, storages[index] ) end
			markChestDirty( chestRecords )
			refreshChestMenus( chestRecords, storages, committed )
		end
		if playerChanged then
			record.container.revision = record.container.revision + 1
			record.revision = record.container.revision
			record.dirty = true
			if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
		end
		if SV.PublishActiveInventoryCommit then
			SV.PublishActiveInventoryCommit( record, result, context or {} )
		end
	end
	return menu
end

local function chestMenuStillValid( ply, positions )
	if not IsValid( ply ) or not ply:Alive() or type( positions ) ~= "table" then return false end
	for _, position in ipairs( positions ) do
		local info = stateInfoAt( position.bx, position.by, position.bz )
		if not sameChest( position.info, info ) or info.type ~= position.info.type then return false end
	end
	local first = positions[1]
	local reach = MC.Config and MC.Config.Reach and MC.Config.Reach:GetFloat() or 0
	return reach <= 0 or not MC.ReachAllowsEye
		or MC.ReachAllowsEye( MC.API.Coords.EntityEyeWorldPos( ply ), first.bx, first.by, first.bz, reach )
end

function SV.GetChestMenuPositions( bx, by, bz ) return chestPositions( bx, by, bz ) end

-- Controlled logistics adapter. Chests do not otherwise have a shared runtime,
-- so this snapshots authoritative records and the commit fans the result back
-- into every independently opened chest menu.
function SV.LogisticsChestContainerAt( bx, by, bz )
	local positions = chestPositions( bx, by, bz )
	if not positions then return nil, "not_chest" end
	local records, storages, flat = {}, {}, {}
	for index, position in ipairs( positions ) do
		local record = ensureMutableChestBlockEntity( position.bx, position.by, position.bz )
		if not record or record.type ~= "minecraft:chest" then return nil, "chest_data_missing" end
		local storage = MC.ChestStorageFromRecord( record )
		records[index], storages[index] = { record = record, position = position }, storage
		local base = ( index - 1 ) * CHEST_SLOTS
		for slot = 1, CHEST_SLOTS do flat[base + slot] = MC.CopyItemStack( storage[slot] ) end
	end
	return {
		kind = "chest", bx = bx, by = by, bz = bz, size = #positions * CHEST_SLOTS,
		positions = positions, records = records, storages = storages, storage = flat,
	}
end

function SV.LogisticsCommitChestContainer( container, options )
	if type( container ) ~= "table" or type( container.records ) ~= "table"
		or type( container.storage ) ~= "table" then return false, "invalid_chest_commit" end
	options = type( options ) == "table" and options or {}
	for index, entry in ipairs( container.records ) do
		local base = ( index - 1 ) * CHEST_SLOTS
		local storage = container.storages[index] or {}
		for slot = 1, CHEST_SLOTS do storage[slot] = MC.CopyItemStack( container.storage[base + slot] ) end
		container.storages[index] = storage
		if not options.persisted then encodeChestRecord( entry.record, storage ) end
	end
	if not options.persisted then markChestDirty( container.records ) end
	refreshChestMenus( container.records, container.storages )
	return true
end

function SV.OpenChest( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:Alive() then return false end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return false end
	if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local positions = chestPositions( bx, by, bz )
	if not positions then return false end
	local menu, err = buildMenu( ply, record, positions )
	if not menu then return false, err end
	menu.cursor = MC.CopyItemStack( record.carried )
	record.carried = nil
	local now = CurTime()
	local epoch = chestWorldEpoch
	record.session = {
		token = sessionToken( ply, record ),
		kind = "chest",
		container = menu,
		creative = false,
		openedAt = now,
		lastActionId = nil,
		chestRecords = menu.chestRecords,
		positions = positions,
		validate = function() return epoch == chestWorldEpoch and chestMenuStillValid( ply, positions ) end,
		playerOffset = menu.playerOffset,
		chestSlots = menu.chestSlots,
		onClose = function()
			adjustChestOpeners( positions, -1 )
		end,
	}
	adjustChestOpeners( positions, 1 )
	if SV.SendActiveInventoryOpen then SV.SendActiveInventoryOpen( ply, record, "chest" ) end
	return true
end

function SV.DropChestContents( actor, bx, by, bz, blockEntity )
	if not blockEntity or not MC.ChestStorageFromRecord then return end
	local storage = MC.ChestStorageFromRecord( blockEntity )
	for slot = 1, CHEST_SLOTS do
		local stack = storage[slot]
		if stack and SV.SpawnItemDrop then
			local position = MC.CellWorldCenter and MC.CellWorldCenter( bx, by, bz ) or Vector( 0, 0, 0 )
			SV.SpawnItemDrop( position, copyStack( stack ), actor )
		end
	end
end

hook.Add( "MC.BlocksChanged", "mc_chest_menu_block_validity", function()
	for ply, record in pairs( SV.PlayerInventories or {} ) do
		local session = record.session
		local called, valid = true, true
		if session and session.kind == "chest" and session.validate then called, valid = pcall( session.validate ) end
		if session and session.kind == "chest" and ( not called or valid ~= true ) then
			SV.ClosePlayerInventory( ply, "container_unavailable" )
		end
	end
end )

local function closeWorldChestMenus()
	chestWorldEpoch = chestWorldEpoch + 1
	for ply, record in pairs( SV.PlayerInventories or {} ) do
		if record.session and record.session.kind == "chest" then
			SV.ClosePlayerInventory( ply, "world_changed" )
		end
	end
	SV.ChestOpeners = {}
	SV.ChestOpenPositions = {}
end

hook.Add( "MC.PreWorldLoad", "mc_chest_world_reset", closeWorldChestMenus )
hook.Add( "MC.WorldCleared", "mc_chest_world_clear", closeWorldChestMenus )
