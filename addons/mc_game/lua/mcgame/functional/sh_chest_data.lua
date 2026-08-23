--[[----------------------------------------------------------------------------
	Vanilla chest block entities and state connections.

	Chest contents are sparse block-entity data stored on the two actual voxel
	cells.  A double chest is only a menu view over those two records; it never
	creates a synthetic third inventory or a Garry's Mod entity.
------------------------------------------------------------------------------]]

MC = MC or {}

local API = MC.API or {}
local Blocks = API.Blocks or {}
local World = API.World or {}

local CHEST_TYPE = "minecraft:chest"
local CHEST_CODEC_VERSION = 1
local CHEST_SLOTS = 27

local CHEST_STATE_NAMES = {
	["minecraft:chest"] = true,
	["minecraft:trapped_chest"] = true,
	["minecraft:copper_chest"] = true,
	["minecraft:exposed_copper_chest"] = true,
	["minecraft:weathered_copper_chest"] = true,
	["minecraft:oxidized_copper_chest"] = true,
	["minecraft:waxed_copper_chest"] = true,
	["minecraft:waxed_exposed_copper_chest"] = true,
	["minecraft:waxed_weathered_copper_chest"] = true,
	["minecraft:waxed_oxidized_copper_chest"] = true,
}

local function normalizedData( data )
	if data == nil then data = {} end
	if type( data ) ~= "table" then return nil, "invalid_chest_data" end
	local items, seen = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		if type( entry ) ~= "table" then return nil, "invalid_chest_item" end
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot < 0 or slot >= CHEST_SLOTS or seen[slot] then return nil, "invalid_chest_slot" end
		seen[slot] = true
		local stack, stackError = MC.NormalizeItemStack( entry.stack )
		if stackError then return nil, stackError end
		if stack then items[#items + 1] = { slot = slot, stack = stack } end
	end
	table.sort( items, function( left, right ) return left.slot < right.slot end )
	local customName = data.customName
	if customName ~= nil then
		if type( customName ) ~= "string" or #customName > 256 then return nil, "invalid_chest_name" end
		if customName == "" then customName = nil end
	end
	return { items = items, customName = customName }
end

local function encodeData( data )
	local normalized, err = normalizedData( data )
	if not normalized then return nil, err end
	return normalized
end

local function decodeData( data )
	return normalizedData( data )
end

local function validateData( data )
	local normalized, err = normalizedData( data )
	return normalized ~= nil, err
end

if Blocks and not Blocks.IsBlockEntityTypeRegistered( CHEST_TYPE ) then
	Blocks.RegisterBlockEntityType( {
		name = CHEST_TYPE,
		codecVersion = CHEST_CODEC_VERSION,
		serverOnly = true,
		Validate = validateData,
		Encode = encodeData,
		Decode = decodeData,
		CollectComponents = function( data )
			local normalized, err = normalizedData( data )
			if not normalized then return nil, err end
			return normalized.customName and { ["minecraft:custom_name"] = normalized.customName } or nil
		end,
		CreateDefault = function()
			return {
				type = CHEST_TYPE,
				codecVersion = CHEST_CODEC_VERSION,
				data = { items = {} },
			}
		end,
	} )
end

-- This file is loaded after sh_block_states.lua, while both registries are
-- still open.  Keeping the mapping here means generated catalogs remain
-- generated/source-owned and custom packs can opt out simply by omitting it.
if Blocks then
	local names = {}
	for name in pairs( CHEST_STATE_NAMES ) do names[#names + 1] = name end
	Blocks.BindBlockEntityType( names, CHEST_TYPE )
end

local function stateAt( changes, changeCount, bx, by, bz )
	for index = 1, changeCount do
		local cell = changes[index]
		if cell.bx == bx and cell.by == by and cell.bz == bz then
			if cell.stateId ~= nil then return cell.stateId end
			return Blocks.StateFromLegacy and Blocks.StateFromLegacy( cell.id or 0, cell.orient or 0 ) or 0
		end
	end
	return World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
end

local function chestStateInfo( stateId )
	local name = Blocks.Name and Blocks.Name( stateId ) or nil
	if not name or not CHEST_STATE_NAMES[name] then return nil end
	return {
		name = name,
		blockId = Blocks.StateBlockId and Blocks.StateBlockId( stateId ) or nil,
		facing = Blocks.GetProperty and Blocks.GetProperty( stateId, "facing" ) or "north",
		type = Blocks.GetProperty and Blocks.GetProperty( stateId, "type" ) or "single",
	}
end

function MC.ChestStateInfo( stateId ) return chestStateInfo( stateId ) end

local function directionOffset( direction )
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

local function cellKey( bx, by, bz )
	return tostring( math.floor( tonumber( bx ) or 0 ) ) .. ":"
		.. tostring( math.floor( tonumber( by ) or 0 ) ) .. ":"
		.. tostring( math.floor( tonumber( bz ) or 0 ) )
end

local function addCandidate( candidates, seen, bx, by, bz )
	local key = cellKey( bx, by, bz )
	if seen[key] then return end
	seen[key] = true
	candidates[#candidates + 1] = { bx = bx, by = by, bz = bz }
end

local function candidatePartner( changes, changeCount, candidate, info, direction, paired, noConnect )
	local dx, dy = directionOffset( direction )
	local bx, by, bz = candidate.bx + dx, candidate.by + dy, candidate.bz
	local neighbour = chestStateInfo( stateAt( changes, changeCount, bx, by, bz ) )
	if not neighbour or neighbour.type ~= "single" or not sameChest( info, neighbour ) then return nil end
	local key = cellKey( bx, by, bz )
	if paired[key] or noConnect[key] then return nil end
	return { bx = bx, by = by, bz = bz, info = neighbour, key = key }
end

-- ChestBlock#getStateForPlacement only runs the automatic clockwise/counter-
-- clockwise merge when isSecondaryUseActive() is false, so a chest placed while
-- sneaking stays SINGLE next to an existing chest. The flag rides on the placed
-- cell, and both sides are checked: the sneak-placed chest must not adopt a
-- neighbour, and an existing chest must not adopt the sneak-placed one.
-- Cells written by this transaction, as opposed to the neighbours pulled in as
-- candidates. Only these may initiate a merge; see the pairing loop below.
local function buildPlacedSet( changes, changeCount )
	local placed = {}
	for index = 1, changeCount do
		local cell = changes[index]
		if cell then placed[cellKey( cell.bx, cell.by, cell.bz )] = true end
	end
	return placed
end

local function buildNoConnectSet( changes, changeCount )
	local noConnect = {}
	for index = 1, changeCount do
		local cell = changes[index]
		if cell and cell.secondaryUse == true then
			noConnect[cellKey( cell.bx, cell.by, cell.bz )] = true
		end
	end
	return noConnect
end

local function addTypeUpdate( updates, changes, changeCount, bx, by, bz, info, chestType )
	if not info or info.type == chestType then return end
	local stateId = stateAt( changes, changeCount, bx, by, bz )
	local nextState = Blocks.WithProperty and Blocks.WithProperty( stateId, "type", chestType ) or nil
	if nextState then updates[#updates + 1] = { bx = bx, by = by, bz = bz, stateId = nextState } end
end

function MC.BuildChestConnectionStateUpdates( changes, changeCount )
	if type( changes ) ~= "table" or #changes == 0 or not Blocks.WithProperty then return {} end
	changeCount = math.min( math.floor( tonumber( changeCount ) or #changes ), #changes )
	local candidates, seen = {}, {}
	for index = 1, changeCount do
		local cell = changes[index]
		addCandidate( candidates, seen, cell.bx, cell.by, cell.bz )
		for _, direction in ipairs( { "north", "south", "west", "east" } ) do
			local dx, dy = directionOffset( direction )
			addCandidate( candidates, seen, cell.bx + dx, cell.by + dy, cell.bz )
		end
	end

	local updates, paired = {}, {}
	local noConnect = buildNoConnectSet( changes, changeCount )
	local placed = buildPlacedSet( changes, changeCount )
	-- First detach halves whose partner disappeared or changed type/facing.
	for _, candidate in ipairs( candidates ) do
		local info = chestStateInfo( stateAt( changes, changeCount, candidate.bx, candidate.by, candidate.bz ) )
		local direction = connectedDirection( info )
		if direction then
			local dx, dy = directionOffset( direction )
			local neighbour = chestStateInfo( stateAt( changes, changeCount, candidate.bx + dx, candidate.by + dy, candidate.bz ) )
			if not sameChest( info, neighbour ) or neighbour.type ~= oppositeType( info.type ) then
				addTypeUpdate( updates, changes, changeCount, candidate.bx, candidate.by, candidate.bz, info, "single" )
			end
		end
	end

	-- Then form at most one pair, clockwise first just like
	-- ChestBlock#getChestType.  The paired set prevents a third chest from
	-- stealing an existing half during one transaction.
	--
	-- Only a cell that actually CHANGED may start a pair. In Minecraft the merge
	-- is decided by getStateForPlacement for the block being placed; two chests
	-- that already exist side by side never merge on their own. The candidate
	-- list deliberately includes neighbours of the change (the detach pass above
	-- needs them), so without this gate, dropping any unrelated block beside two
	-- separate chests made one of those bystanders start a merge.
	for _, candidate in ipairs( candidates ) do
		local info = chestStateInfo( stateAt( changes, changeCount, candidate.bx, candidate.by, candidate.bz ) )
		if info and info.type == "single" then
			local key = cellKey( candidate.bx, candidate.by, candidate.bz )
			if placed[key] and not paired[key] and not noConnect[key] then
				local directions = { clockwise( info.facing ), counterClockwise( info.facing ) }
				for _, direction in ipairs( directions ) do
					local partner = candidatePartner( changes, changeCount, candidate, info, direction, paired, noConnect )
					if partner then
						local currentType = direction == clockwise( info.facing ) and "left" or "right"
						local otherType = oppositeType( currentType )
						addTypeUpdate( updates, changes, changeCount, candidate.bx, candidate.by, candidate.bz, info, currentType )
						addTypeUpdate( updates, changes, changeCount, partner.bx, partner.by, partner.bz, partner.info, otherType )
						paired[key] = true
						paired[partner.key] = true
						break
					end
				end
			end
		end
	end
	return updates
end

if Blocks then
	Blocks.RegisterPlacementStateProvider(
		"mc.game.chest_connections",
		MC.BuildChestConnectionStateUpdates,
		100
	)
end

local function storageFromData( data )
	local storage = {}
	for _, entry in ipairs( data and data.items or {} ) do
		local slot = math.floor( tonumber( entry.slot ) or -1 )
		if slot >= 0 and slot < CHEST_SLOTS then storage[slot + 1] = MC.CopyItemStack( entry.stack ) end
	end
	return storage
end

function MC.ChestStorageFromRecord( record )
	return storageFromData( record and record.data )
end

function MC.ChestRecordFromStorage( storage, customName )
	local items = {}
	for slot = 0, CHEST_SLOTS - 1 do
		local stack = storage and storage[slot + 1]
		if not MC.IsEmptyItemStack( stack ) then
			items[#items + 1] = { slot = slot, stack = MC.CopyItemStack( stack ) }
		end
	end
	return {
		type = CHEST_TYPE,
		codecVersion = CHEST_CODEC_VERSION,
		data = { items = items, customName = customName },
	}
end

function MC.ChestSlotCount() return CHEST_SLOTS end
function MC.IsChestState( stateId ) return chestStateInfo( stateId ) ~= nil end
