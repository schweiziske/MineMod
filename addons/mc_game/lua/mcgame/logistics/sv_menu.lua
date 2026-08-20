-- Hopper / Dispenser / Dropper menus and removal side effects.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local L = MC.LogisticsParity or {}
local C = L.Constants or {}
local API = MC.API or {}
local World = API.World or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}

local function copy( stack, count ) return MC.CopyItemStack( stack, count ) end
local function sameCell( left, right )
	return left and right and left.bx == right.bx and left.by == right.by and left.bz == right.bz
end

local function currentDefinition( bx, by, bz )
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	return L.ContainerDefinitionForState and L.ContainerDefinitionForState( stateId ) or nil
end

local function playerSlots( storage, offset )
	local definitions, playerMap, menuMap, hotbar = {}, {}, {}, {}
	for index = 0, 35 do
		local menuIndex = offset + index
		definitions[#definitions + 1] = {
			index = menuIndex, storage = storage, storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
		playerMap[index], menuMap[menuIndex] = menuIndex, index
		if index < 9 then hotbar[index + 1] = menuIndex end
	end
	return definitions, playerMap, menuMap, hotbar
end

local function changedLogisticsSlots( authoritative, storage, size )
	local changed = {}
	for slot = 0, size - 1 do
		if not MC.ItemStacksEqual( authoritative.storage[slot + 1], storage[slot + 1] ) then
			changed[#changed + 1] = slot
		end
	end
	return changed
end

local function buildMenu( ply, playerRecord, container )
	local storage, slots = {}, {}
	for slot = 1, container.size do
		storage[slot] = copy( container.storage[slot] )
		slots[#slots + 1] = {
			index = slot - 1, storage = storage, storageIndex = slot, group = "logistics_container",
		}
	end
	local playerDefinitions, playerMap, menuMap, hotbar = playerSlots( playerRecord.storage, container.size )
	for _, definition in ipairs( playerDefinitions ) do slots[#slots + 1] = definition end
	local menu, err = MC.NewInventoryContainer( {
		id = playerRecord.nextContainerId or 2, kind = container.kind,
		revision = math.max( playerRecord.container.revision or 0,
			container.physical[1].record.revision or 0 ),
		slots = slots, hotbarSlots = hotbar,
		transferRules = {
			logistics_container = { targets = { "main", "hotbar" }, reverse = true },
			main = { targets = { "logistics_container" } },
			hotbar = { targets = { "logistics_container" } },
		},
		context = { player = ply, logistics = true },
	} )
	if not menu then return nil, err end
	playerRecord.nextContainerId = ( menu.id + 1 ) % 65535
	if playerRecord.nextContainerId == 0 or playerRecord.nextContainerId == 1 then playerRecord.nextContainerId = 2 end
	menu.logisticsPosition = { bx = container.bx, by = container.by, bz = container.bz }
	menu.logisticsStorage, menu.logisticsSlots = storage, container.size
	menu.playerOffset, menu.playerMenuMap, menu.menuPlayerMap = container.size, playerMap, menuMap
	menu.beforeCommit = function()
		local authoritative, containerError = L.ContainerAt( container.bx, container.by, container.bz, nil, { create = false } )
		if not authoritative or authoritative.kind ~= container.kind then
			return false, containerError or "container_unavailable"
		end
		local changed = changedLogisticsSlots( authoritative, storage, container.size )
		if #changed == 0 then return true end
		for slot = 1, container.size do authoritative.storage[slot] = copy( storage[slot] ) end
		for _, slot in ipairs( changed ) do
			authoritative.changed, authoritative.changedSlotSet[slot] = true, true
		end
		local committed, commitError = L.CommitContainers( { authoritative }, "logistics_menu" )
		return committed == true, committed and nil or commitError
	end
	menu.onCommit = function( committed, result, context )
		local playerChanged = false
		for _, slot in ipairs( result.changedSlots or {} ) do
			if slot >= container.size then playerChanged = true break end
		end
		committed.revision = math.max( committed.revision, playerRecord.container.revision or 0 )
		playerRecord.container.revision, playerRecord.revision = committed.revision, committed.revision
		if playerChanged then
			playerRecord.dirty = true
			if SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( playerRecord ) end
		end
		if SV.PublishActiveInventoryCommit then
			SV.PublishActiveInventoryCommit( playerRecord, result, context or {} )
		end
	end
	return menu
end

local function menuStillValid( ply, position, kind )
	if not L.Enabled() or not IsValid( ply ) or not ply:Alive() then return false end
	local definition = currentDefinition( position.bx, position.by, position.bz )
	if not definition or definition.kind ~= kind then return false end
	if not Coords.CellMin or not Coords.BlockSize or not ply.EyePos then return false end
	local minimum = Coords.CellMin( position.bx, position.by, position.bz )
	local size = tonumber( Coords.BlockSize() ) or 0
	local eye = ply:EyePos()
	if not minimum or size <= 0 or not eye then return false end
	local px = math.max( minimum.x, math.min( eye.x, minimum.x + size ) )
	local py = math.max( minimum.y, math.min( eye.y, minimum.y + size ) )
	local pz = math.max( minimum.z, math.min( eye.z, minimum.z + size ) )
	local dx, dy, dz = eye.x - px, eye.y - py, eye.z - pz
	local reach = ( ( C.containerBlockInteractionRange or 4.5 )
		+ ( C.containerStillValidBuffer or 4 ) ) * size
	return dx * dx + dy * dy + dz * dz < reach * reach
end

function SV.OpenLogisticsContainer( ply, bx, by, bz )
	if not L.Enabled() or not IsValid( ply ) or not ply:Alive() then return false end
	local playerRecord = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not playerRecord then return false end
	local container, containerError = L.ContainerAt( bx, by, bz, nil, { create = true } )
	if not container or container.adapter ~= "logistics" then return false, containerError end
	if playerRecord.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "switch" ) end
	local menu, menuError = buildMenu( ply, playerRecord, container )
	if not menu then return false, menuError end
	menu.cursor = copy( playerRecord.carried )
	playerRecord.carried = nil
	local position = menu.logisticsPosition
	playerRecord.session = {
		token = util.SHA256 and util.SHA256( table.concat( {
			ply:EntIndex(), SysTime(), math.random(), menu.kind,
		}, ":" ) ) or util.CRC( tostring( SysTime() ) ),
		kind = menu.kind, container = menu, creative = false, openedAt = CurTime(), lastActionId = nil,
		playerOffset = menu.playerOffset, logisticsSlots = menu.logisticsSlots,
		playerMenuMap = menu.playerMenuMap, menuPlayerMap = menu.menuPlayerMap,
		logisticsPosition = position,
		validate = function() return menuStillValid( ply, position, menu.kind ) end,
	}
	if SV.SendActiveInventoryOpen then SV.SendActiveInventoryOpen( ply, playerRecord, menu.kind ) end
	return true
end

function SV.LogisticsCommitBlockContainer( container, record )
	for _, playerRecord in pairs( SV.PlayerInventories or {} ) do
		local session = playerRecord.session
		local menu = session and session.container or nil
		if menu and session.logisticsPosition and sameCell( session.logisticsPosition, container )
		and session.kind == container.kind and type( menu.logisticsStorage ) == "table" then
			local changed = {}
			for slot = 1, container.size do
				if not MC.ItemStacksEqual( menu.logisticsStorage[slot], container.storage[slot] ) then
					menu.logisticsStorage[slot] = copy( container.storage[slot] )
					changed[#changed + 1] = slot - 1
				end
			end
			if #changed > 0 and SV.PublishActiveInventoryCommit then
				menu.revision = math.max( menu.revision + 1, tonumber( record and record.revision ) or 0 )
				SV.PublishActiveInventoryCommit( playerRecord, { changedSlots = changed, revision = menu.revision }, {} )
			end
		end
	end
	return true
end

local function randomInt( bound ) return math.random( math.max( 1, math.floor( bound ) ) ) - 1 end
local function randomDouble() return math.Rand and math.Rand( 0, 1 ) or math.random() end

local function dropStack( bx, by, bz, stack )
	if MC.IsEmptyItemStack( stack ) or not SV.SpawnItemDrop or not Coords.CellMin or not Coords.BlockSize then return 0 end
	local minimum, size = Coords.CellMin( bx, by, bz ), tonumber( Coords.BlockSize() ) or 0
	if not minimum or size <= 0 then return 0 end
	local remaining, spawned = stack.count, 0
	local fx, fy, fz = L.ContainerDropPositionFractions( randomDouble )
	local position = minimum + Vector( fx * size, fy * size, fz * size )
	while remaining > 0 do
		local count = L.ContainerDropSplitCount( remaining, randomInt )
		if count <= 0 then break end
		local vx, vy, vz = L.ContainerDropVelocity( randomDouble )
		local entity = SV.SpawnItemDrop( position, copy( stack, count ), nil, {
			pickupDelay = 0, noMerge = true, positionJitter = false,
			velocity = Vector(
				L.BlocksPerTickToSource( vx, size ),
				L.BlocksPerTickToSource( vy, size ),
				L.BlocksPerTickToSource( vz, size )
			),
		} )
		if entity then spawned = spawned + 1 end
		remaining = remaining - count
	end
	return spawned
end

function SV.DropLogisticsContents( actor, bx, by, bz, blockEntity )
	if not L.Enabled() or not blockEntity or not L.StorageFromRecord then return 0 end
	local storage = L.StorageFromRecord( blockEntity )
	if not storage then return 0 end
	local definition = L.ContainerDefinitionForRecord and L.ContainerDefinitionForRecord( blockEntity ) or nil
	if not definition then return 0 end
	for ply, playerRecord in pairs( SV.PlayerInventories or {} ) do
		local session = playerRecord.session
		if session and sameCell( session.logisticsPosition, { bx = bx, by = by, bz = bz } )
		and SV.ClosePlayerInventory then SV.ClosePlayerInventory( ply, "logistics_removed" ) end
	end
	local spawned = 0
	for slot = 1, definition.slots do
		spawned = spawned + dropStack( bx, by, bz, storage[slot] )
	end
	return spawned
end

hook.Add( "MC.BlocksChanged", "mcgame_logistics_menu_validity", function()
	if not L.Enabled() then return end
	for ply, playerRecord in pairs( SV.PlayerInventories or {} ) do
		local session = playerRecord.session
		if session and session.logisticsPosition and session.validate then
			local called, valid = pcall( session.validate )
			if not called or valid ~= true then SV.ClosePlayerInventory( ply, "container_unavailable" ) end
		end
	end
end )

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_gameplay_parity_logistics", function( _, _, value )
		if tostring( value ) ~= "0" then return end
		for ply, playerRecord in pairs( SV.PlayerInventories or {} ) do
			if playerRecord.session and playerRecord.session.logisticsPosition and SV.ClosePlayerInventory then
				SV.ClosePlayerInventory( ply, "logistics_disabled" )
			end
		end
	end, "mcgame_logistics_menu_disable" )
end
