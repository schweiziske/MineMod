-- Source-verified Hopper ticking and ItemEntity intake.

MC = MC or {}

local API = MC.API or {}
local World = API.World or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}
local Schedule = API.Schedule or {}
local L = MC.LogisticsParity or {}
local C = L.Constants or {}

local HOPPER = "minecraft:hopper"

local function integer( value, fallback )
	value = tonumber( value )
	return value ~= nil and math.floor( value ) or fallback
end

local function gameTick( supplied )
	local value = tonumber( supplied )
	if value ~= nil then return math.max( 0, math.floor( value ) ) end
	if engine and engine.TickCount then return math.max( 0, math.floor( engine.TickCount() ) ) end
	return math.max( 0, math.floor( ( CurTime and CurTime() or 0 ) / ( C.tickSeconds or 0.05 ) ) )
end

local function stateName( stateId )
	return Blocks.Name and Blocks.Name( stateId ) or nil
end

local function hopperState( bx, by, bz )
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	if stateId == 0 or stateName( stateId ) ~= HOPPER then return nil end
	local facing = Blocks.GetProperty and L.NormalizeDirection( Blocks.GetProperty( stateId, "facing" ) ) or nil
	local enabled = Blocks.GetProperty and Blocks.GetProperty( stateId, "enabled" ) == true or false
	if not facing then return nil end
	return stateId, facing, enabled
end

local function addUnique( entries, seen, container )
	if type( container ) ~= "table" or seen[container] then return end
	seen[container] = true
	entries[#entries + 1] = container
end

local function entityValid( entity )
	return entity ~= nil and ( not IsValid or IsValid( entity ) )
		and type( entity.GetDropStack ) == "function"
		and type( entity.SetDropStack ) == "function"
		and type( entity.Remove ) == "function"
end

local function entityStack( entity )
	if not entityValid( entity ) then return nil end
	return entity:GetDropStack()
end

local function stacksEqual( left, right )
	if MC.ItemStacksEqual then return MC.ItemStacksEqual( left, right ) == true end
	if MC.IsEmptyItemStack( left ) then return MC.IsEmptyItemStack( right ) end
	return type( right ) == "table" and left.item == right.item and left.count == right.count
end

local function pendingEntitiesCurrent( pending )
	for _, mutation in ipairs( pending ) do
		if not entityValid( mutation.entity )
		or not stacksEqual( entityStack( mutation.entity ), mutation.before ) then return false end
	end
	return true
end

local function applyEntityMutations( pending )
	for _, mutation in ipairs( pending ) do
		local entity = mutation.entity
		if entityValid( entity ) then
			if MC.IsEmptyItemStack( mutation.after ) then entity:Remove()
			else entity:SetDropStack( mutation.after ) end
		end
	end
end

local function suctionBounds( bx, by, bz )
	if not Coords.CellMin or not Coords.BlockSize then return nil end
	local minimum = Coords.CellMin( bx, by, bz )
	local size = tonumber( Coords.BlockSize() ) or 0
	if not minimum or size <= 0 then return nil end
	return {
		minX = minimum.x + ( C.hopperSuckMinX or 0 ) * size,
		minY = minimum.y + ( C.hopperSuckMinY or 0 ) * size,
		minZ = minimum.z + ( C.hopperSuckMinZ or 11 / 16 ) * size,
		maxX = minimum.x + ( C.hopperSuckMaxX or 1 ) * size,
		maxY = minimum.y + ( C.hopperSuckMaxY or 1 ) * size,
		maxZ = minimum.z + ( C.hopperSuckMaxZ or 2 ) * size,
	}
end

local function entityIntersects( entity, bounds )
	if not bounds or not Coords.EntityWorldAABB then return false end
	local minimum, maximum = Coords.EntityWorldAABB( entity )
	if not minimum or not maximum then return false end
	return maximum.x > bounds.minX and minimum.x < bounds.maxX
		and maximum.y > bounds.minY and minimum.y < bounds.maxY
		and maximum.z > bounds.minZ and minimum.z < bounds.maxZ
end

local function insertEntity( hopper, entity, pending )
	local before = entityStack( entity )
	if MC.IsEmptyItemStack( before ) then return false, false end
	local remaining, moved = L.InsertStack( hopper, before, nil, nil )
	if ( tonumber( moved ) or 0 ) <= 0 then return false, false end
	pending[#pending + 1] = {
		entity = entity, before = MC.CopyItemStack( before ), after = MC.CopyItemStack( remaining ),
	}
	return MC.IsEmptyItemStack( remaining ), true
end

local function itemEntitiesInSuction( bx, by, bz )
	local output, bounds = {}, suctionBounds( bx, by, bz )
	if not bounds then return output end
	MC.ItemDropQuery.InBox( bounds.minX, bounds.minY, bounds.minZ,
		bounds.maxX, bounds.maxY, bounds.maxZ, output )
	local count, previous = 0, #output
	for i = 1, previous do
		local entity = output[i]
		if entityValid( entity ) and entityIntersects( entity, bounds ) then
			count = count + 1
			output[count] = entity
		end
	end
	for i = count + 1, previous do output[i] = nil end
	return output
end

local function aboveStopsItems( bx, by, bz )
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz + 1 ) or 0
	if stateId == 0 then return false end
	local shape = Blocks.StateShapeAt and Blocks.StateShapeAt( stateId, bx, by, bz + 1 ) or nil
	-- Missing exact collision data is a conservative failure, never permission
	-- to pull an entity through a potentially solid block.
	if type( shape ) ~= "table" then return true end
	return L.BlockStopsHopperItems( stateName( stateId ), shape.fullCube == true )
end

local function eject( hopper, facing, containers, seen )
	local dx, dy, dz = L.DirectionOffset( facing )
	if not dx then return false end
	local targetDirection = L.OppositeDirection( facing )
	local target = L.ContainerAt( hopper.bx + dx, hopper.by + dy, hopper.bz + dz,
		targetDirection, { create = true } )
	if not target or L.ContainerIsFull( target, targetDirection ) then return false end
	local moved = L.TransferOne( hopper, target, nil, targetDirection ) == true
	if moved then addUnique( containers, seen, target ) end
	return moved
end

local function suckFromAbove( hopper, containers, seen, pending )
	local source, sourceError = L.ContainerAt( hopper.bx, hopper.by, hopper.bz + 1,
		"down", { create = true } )
	if source then
		local moved = L.TransferOne( source, hopper, "down", nil ) == true
		if moved then addUnique( containers, seen, source ) end
		return moved, false
	end
	-- A recognized block container whose adapter/data is unavailable still
	-- suppresses the ItemEntity fallback, as Java does when a container exists.
	if sourceError ~= "not_container" then return false, false end
	if aboveStopsItems( hopper.bx, hopper.by, hopper.bz ) then return false, false end
	local touched = false
	for _, entity in ipairs( itemEntitiesInSuction( hopper.bx, hopper.by, hopper.bz ) ) do
		local complete, inserted = insertEntity( hopper, entity, pending )
		touched = touched or inserted
		if complete then return true, touched end
	end
	return false, touched
end

local function commitMove( containers, pending, reason )
	if not pendingEntitiesCurrent( pending ) then return false, "stale_item_entity" end
	local committed, result = L.CommitContainers( containers, reason )
	if not committed then return false, result end
	applyEntityMutations( pending )
	return true, result
end

local function tryMoveAt( bx, by, bz, options )
	options = type( options ) == "table" and options or {}
	if not L.Enabled() then return false, "feature_disabled" end
	local stateId, facing, enabled = hopperState( bx, by, bz )
	if not stateId then return false, "not_hopper" end
	local hopper, hopperError = L.ContainerAt( bx, by, bz, nil, { create = true } )
	if not hopper then return false, hopperError end
	local containers, seen, pending = { hopper }, { [hopper] = true }, {}
	local cooldown = integer( hopper.state and hopper.state.transferCooldown, C.hopperInitialCooldown or -1 )
	if options.tick then
		cooldown = cooldown - 1
		hopper.state.transferCooldown = cooldown
		hopper.state.tickedGameTime = gameTick( options.logicTick )
		hopper.stateChanged = true
		if cooldown <= 0 then hopper.state.transferCooldown = 0 end
	end
	local allowed = cooldown <= 0 and enabled
	local changed, entityTouched = false, false
	if allowed then
		if not L.ContainerIsEmpty( hopper ) then changed = eject( hopper, facing, containers, seen ) end
		if not L.ContainerIsFull( hopper ) then
			if options.entity then
				local complete, inserted = insertEntity( hopper, options.entity, pending )
				changed, entityTouched = changed or complete, inserted
			else
				local sucked, touched = suckFromAbove( hopper, containers, seen, pending )
				changed, entityTouched = changed or sucked, touched
			end
		end
		if changed then
			hopper.state.transferCooldown = C.hopperTransferCooldown or 8
			hopper.stateChanged = true
		end
	end
	local dirty = hopper.changed or hopper.stateChanged or entityTouched or #containers > 1
	if not dirty then return true, { changed = false, moved = false, entityTouched = false } end
	local committed, result = commitMove( containers, pending, options.reason or "hopper_transfer" )
	if not committed then return false, result end
	return true, {
		changed = true, moved = changed, entityTouched = entityTouched,
		cooldown = hopper.state.transferCooldown, commit = result,
	}
end

function L.TickHopperAt( context )
	context = type( context ) == "table" and context or {}
	return tryMoveAt( context.bx, context.by, context.bz, {
		tick = true, logicTick = context.logicTick, reason = "hopper_tick",
	} )
end

function L.EntityInsideHopperAt( bx, by, bz, entity )
	if not L.Enabled() or not entityValid( entity ) then return false, "feature_disabled" end
	if not entityIntersects( entity, suctionBounds( bx, by, bz ) ) then return false, "outside_suction" end
	return tryMoveAt( bx, by, bz, { entity = entity, reason = "hopper_entity_inside" } )
end

function L.EntityInsideItemDrop( entity )
	if not L.Enabled() or not entityValid( entity ) or not Coords.EntityWorldAABB
		or not Coords.WorldToCell then return false end
	local minimum, maximum = Coords.EntityWorldAABB( entity )
	if not minimum or not maximum then return false end
	local epsilon = math.max( Coords.BlockSize() * 0.000001, 0.000001 )
	local x0, y0, z0 = Coords.WorldToCell( Vector( minimum.x + epsilon, minimum.y + epsilon, minimum.z + epsilon ) )
	local x1, y1, z1 = Coords.WorldToCell( Vector( maximum.x - epsilon, maximum.y - epsilon, maximum.z - epsilon ) )
	if x0 == nil or x1 == nil then return false end
	for bx = x0, x1 do
		for by = y0, y1 do
			for bz = z0 - 2, z1 do
				-- Most occupied cells are air. Avoid allocating suction bounds and
				-- re-reading the item's AABB for each non-hopper cell every tick.
				local stateId = World.GetBlockState( bx, by, bz )
				if stateName( stateId ) == HOPPER then
					local ok, result = L.EntityInsideHopperAt( bx, by, bz, entity )
					if ok and result and ( result.moved or result.entityTouched ) then return true end
					if not entityValid( entity ) then return true end
				end
			end
		end
	end
	return false
end

local function scheduleAt( bx, by, bz )
	if not L.Enabled() or not Schedule.BlockTick then return false end
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	if stateName( stateId ) ~= HOPPER then return false end
	return Schedule.BlockTick( bx, by, bz, 1 ) == true
end

local function warmHoppers( cx, cy, cz )
	if not L.Enabled() or not World.ForEachBlockEntity then return end
	World.ForEachBlockEntity( HOPPER, function( bx, by, bz )
		if cx ~= nil and Coords.CellToChunk then
			local entryCX, entryCY, entryCZ = Coords.CellToChunk( bx, by, bz )
			if entryCX ~= cx or entryCY ~= cy or entryCZ ~= cz then return end
		end
		scheduleAt( bx, by, bz )
	end )
end

local function onScheduledTick( context )
	if not L.Enabled() then return nil end
	-- Schedule first: a rejected container transaction or an isolated callback
	-- error must not permanently stop this block entity's ticker.
	scheduleAt( context.bx, context.by, context.bz )
	L.TickHopperAt( context )
	return nil
end

if Schedule.Observe then
	Schedule.Observe( "mcgame_logistics_hopper", HOPPER, { OnScheduledTick = onScheduledTick } )
end

if hook and hook.Add then
	hook.Add( "MC.WorldLoaded", "mcgame_logistics_hopper_world_warm", function() warmHoppers() end )
	hook.Add( "MC.ChunkHydrated", "mcgame_logistics_hopper_chunk_warm", function( _, cx, cy, cz )
		warmHoppers( cx, cy, cz )
	end )
	hook.Add( "MC.BlocksChanged", "mcgame_logistics_hopper_placed", function( changes )
		if not L.Enabled() then return end
		for _, change in ipairs( changes or {} ) do scheduleAt( change.bx, change.by, change.bz ) end
	end )
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_gameplay_parity_logistics", function( _, _, value )
		if tostring( value ) ~= "0" then warmHoppers() end
	end, "mcgame_logistics_hopper_enable" )
end
