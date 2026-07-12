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

function MC.StairBoxes( id, orient, bx, by, bz )
	orient = MC.NormalizeOrient( id, orient )
	local facing = MC.StairOrientFacing( orient )
	local top = MC.StairOrientHalf( orient ) == "top"
	local shape = MC.StairShapeAt( id, orient, bx, by, bz )
	local boxes = { top and { 0, 0, 0.5, 1, 1, 1 } or { 0, 0, 0, 1, 1, 0.5 } }
	local z0, z1 = top and 0 or 0.5, top and 0.5 or 1
	for _, rect in ipairs( stepRects( facing, shape ) ) do
		boxes[#boxes + 1] = { rect[1], rect[2], z0, rect[3], rect[4], z1 }
	end
	return boxes
end
