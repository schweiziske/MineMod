-- Vanilla-compatible dynamic stair connection shapes.
-- Source reference: out/net/minecraft/world/level/block/StairBlock.java

MC = MC or {}
MC.NeighbourDependentShapes = MC.NeighbourDependentShapes or {}
MC.NeighbourDependentShapes.stairs = true

local DirectionOffset = {
	[MC.Direction.NORTH] = { 0, -1 },
	[MC.Direction.SOUTH] = { 0, 1 },
	[MC.Direction.WEST] = { -1, 0 },
	[MC.Direction.EAST] = { 1, 0 },
}
local CounterClockwise = {
	[MC.Direction.NORTH] = MC.Direction.WEST,
	[MC.Direction.WEST] = MC.Direction.SOUTH,
	[MC.Direction.SOUTH] = MC.Direction.EAST,
	[MC.Direction.EAST] = MC.Direction.NORTH,
}
local Opposite = {
	[MC.Direction.NORTH] = MC.Direction.SOUTH,
	[MC.Direction.SOUTH] = MC.Direction.NORTH,
	[MC.Direction.WEST] = MC.Direction.EAST,
	[MC.Direction.EAST] = MC.Direction.WEST,
}
local Axis = {
	[MC.Direction.NORTH] = "y",
	[MC.Direction.SOUTH] = "y",
	[MC.Direction.WEST] = "x",
	[MC.Direction.EAST] = "x",
}
local DirectionByName = {
	north = MC.Direction.NORTH,
	south = MC.Direction.SOUTH,
	west = MC.Direction.WEST,
	east = MC.Direction.EAST,
}
local ShapeIndex = {
	straight = 0,
	inner_left = 1,
	inner_right = 2,
	outer_left = 3,
	outer_right = 4,
}

local function neighbour( bx, by, bz, direction )
	if bx == nil or by == nil or bz == nil or not MC.GetBlock or not MC.GetBlockOrient then return nil end
	local off = DirectionOffset[direction]
	if not off then return nil end
	local id = MC.GetBlock( bx + off[1], by + off[2], bz )
	local b = MC.Blocks[id]
	if not b or b.shape ~= "stairs" then return nil end
	local orient = MC.GetBlockOrient( bx + off[1], by + off[2], bz )
	return MC.StairOrientFacing( orient ), MC.StairOrientHalf( orient )
end

local function canTakeShape( facing, half, bx, by, bz, direction )
	local neighbourFacing, neighbourHalf = neighbour( bx, by, bz, direction )
	return neighbourFacing == nil or neighbourFacing ~= facing or neighbourHalf ~= half
end

-- Mirrors StairBlock.getStairsShape. The derived shape is deliberately not
-- stored in orient: vanilla recomputes it whenever a horizontal neighbour
-- changes, and the existing 3-bit stair state remains facing + half only.
function MC.StairShapeAt( id, orient, bx, by, bz )
	local b = MC.Blocks[id]
	if not b or b.shape ~= "stairs" then return "straight" end
	orient = MC.NormalizeOrient( id, orient )
	local facing = MC.StairOrientFacing( orient )
	local half = MC.StairOrientHalf( orient )

	local aheadFacing, aheadHalf = neighbour( bx, by, bz, facing )
	if aheadFacing and aheadHalf == half and Axis[aheadFacing] ~= Axis[facing]
	and canTakeShape( facing, half, bx, by, bz, Opposite[aheadFacing] ) then
		return aheadFacing == CounterClockwise[facing] and "outer_left" or "outer_right"
	end

	local behind = Opposite[facing]
	local behindFacing, behindHalf = neighbour( bx, by, bz, behind )
	if behindFacing and behindHalf == half and Axis[behindFacing] ~= Axis[facing]
	and canTakeShape( facing, half, bx, by, bz, behindFacing ) then
		return behindFacing == CounterClockwise[facing] and "inner_left" or "inner_right"
	end

	return "straight"
end

local function stepRects( facing, shape )
	if facing == MC.Direction.NORTH then
		if shape == "outer_left" then return { { 0, 0, 0.5, 0.5 } } end
		if shape == "outer_right" then return { { 0.5, 0, 1, 0.5 } } end
		if shape == "inner_left" then return { { 0, 0, 1, 0.5 }, { 0, 0.5, 0.5, 1 } } end
		if shape == "inner_right" then return { { 0, 0, 1, 0.5 }, { 0.5, 0.5, 1, 1 } } end
		return { { 0, 0, 1, 0.5 } }
	elseif facing == MC.Direction.SOUTH then
		if shape == "outer_left" then return { { 0.5, 0.5, 1, 1 } } end
		if shape == "outer_right" then return { { 0, 0.5, 0.5, 1 } } end
		if shape == "inner_left" then return { { 0, 0.5, 1, 1 }, { 0.5, 0, 1, 0.5 } } end
		if shape == "inner_right" then return { { 0, 0.5, 1, 1 }, { 0, 0, 0.5, 0.5 } } end
		return { { 0, 0.5, 1, 1 } }
	elseif facing == MC.Direction.WEST then
		if shape == "outer_left" then return { { 0, 0.5, 0.5, 1 } } end
		if shape == "outer_right" then return { { 0, 0, 0.5, 0.5 } } end
		if shape == "inner_left" then return { { 0, 0, 0.5, 1 }, { 0.5, 0.5, 1, 1 } } end
		if shape == "inner_right" then return { { 0, 0, 0.5, 1 }, { 0.5, 0, 1, 0.5 } } end
		return { { 0, 0, 0.5, 1 } }
	else
		if shape == "outer_left" then return { { 0.5, 0, 1, 0.5 } } end
		if shape == "outer_right" then return { { 0.5, 0.5, 1, 1 } } end
		if shape == "inner_left" then return { { 0.5, 0, 1, 1 }, { 0, 0, 0.5, 0.5 } } end
		if shape == "inner_right" then return { { 0.5, 0, 1, 1 }, { 0, 0.5, 0.5, 1 } } end
		return { { 0.5, 0, 1, 1 } }
	end
end

function MC.StairBoxes( id, orient, bx, by, bz, resolvedShape )
	orient = MC.NormalizeOrient( id, orient )
	local facing = MC.StairOrientFacing( orient )
	local top = MC.StairOrientHalf( orient ) == "top"
	local shape = resolvedShape or MC.StairShapeAt( id, orient, bx, by, bz )
	local boxes = { top and { 0, 0, 0.5, 1, 1, 1 } or { 0, 0, 0, 1, 1, 0.5 } }
	local z0, z1 = top and 0 or 0.5, top and 0.5 or 1
	for _, rect in ipairs( stepRects( facing, shape ) ) do
		boxes[#boxes + 1] = { rect[1], rect[2], z0, rect[3], rect[4], z1 }
	end
	return boxes
end

-- State-native collision has a stateId-only cache by default. Stair corners
-- cannot use it because vanilla derives inner/outer shape from horizontal
-- neighbours. Register every stair family as position-dependent and return an
-- interned shape built by the exact same MC.StairShapeAt/MC.StairBoxes path the
-- renderer uses.
local StairCollisionShapes = {}

local function stairCollision( stateId, schema, visual, bx, by, bz )
	local id = visual and visual.id or schema and schema.blockId
	if id == nil then return nil end
	local facingName = MC.GetStateProperty and MC.GetStateProperty( stateId, "facing" ) or "north"
	local half = MC.GetStateProperty and MC.GetStateProperty( stateId, "half" ) or "bottom"
	local orient = MC.MakeStairOrient( DirectionByName[facingName] or MC.Direction.NORTH, half )
	local shape = MC.StairShapeAt( id, orient, bx, by, bz )
	local key = orient + ( ShapeIndex[shape] or 0 ) * 8
	local cached = StairCollisionShapes[key]
	if cached then return cached end
	if not MC.RegisterBlockStateCollisionShape then return { boxes = MC.StairBoxes( id, orient, bx, by, bz, shape ) } end
	cached = MC.RegisterBlockStateCollisionShape( { boxes = MC.StairBoxes( id, orient, bx, by, bz, shape ) } )
	StairCollisionShapes[key] = cached
	return cached
end

local function registerStairCollisionResolvers()
	if not MC.RegisterBlockStateCollision then return 0 end
	local registered = 0
	for id, block in pairs( MC.Blocks or {} ) do
		if block and block.shape == "stairs" then
			local schema = MC.BlockStateSchemas and MC.BlockStateSchemas[id]
			if schema and MC.RegisterBlockStateCollision( schema.name, {
				positionDependent = true,
				Resolve = stairCollision,
			} ) then
				registered = registered + 1
			end
		end
	end
	return registered
end

local function ensureStairCollisionResolvers()
	local registered = registerStairCollisionResolvers()
	-- Generated schemas finalize on the loader's zero-delay timer. On a fresh
	-- boot this module runs just before that callback; on hot reload they are
	-- already available and registration completes immediately.
	if registered == 0 and not MC.BlockStateRegistryFrozen and timer and timer.Simple then
		timer.Simple( 0, ensureStairCollisionResolvers )
	end
	return registered
end

ensureStairCollisionResolvers()
