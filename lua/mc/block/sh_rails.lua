-- State-native rail shape resolver based on BaseRailBlock and RailState.
-- Resolves flat, corner and ascending shapes inside the same placement/break
-- transaction. Powered/detector/activator rails remain straight-only.

MC = MC or {}

local NORTH, SOUTH, WEST, EAST = 1, 2, 3, 4
local Directions = {
	[NORTH] = { 0, -1 },
	[SOUTH] = { 0, 1 },
	[WEST] = { -1, 0 },
	[EAST] = { 1, 0 },
}

local ShapeConnections = {
	north_south = { NORTH, SOUTH },
	east_west = { WEST, EAST },
	ascending_north = { NORTH, SOUTH },
	ascending_south = { NORTH, SOUTH },
	ascending_west = { WEST, EAST },
	ascending_east = { WEST, EAST },
	south_east = { SOUTH, EAST },
	south_west = { SOUTH, WEST },
	north_west = { NORTH, WEST },
	north_east = { NORTH, EAST },
}

local function primaryState( changes, changeCount, bx, by, bz )
	for index = 1, changeCount do
		local cell = changes[index]
		if cell.bx == bx and cell.by == by and cell.bz == bz then
			if cell.stateId ~= nil then return cell.stateId end
			return MC.StateFromLegacy and MC.StateFromLegacy( cell.id or 0, cell.orient or 0 ) or 0
		end
	end
	return MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
end

local function stateAt( changes, changeCount, overrides, bx, by, bz )
	local override = overrides[MC.CellKey( bx, by, bz )]
	if override ~= nil then return override end
	return primaryState( changes, changeCount, bx, by, bz )
end

local function railInfo( stateId )
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	local name = block and block.name or nil
	if name ~= "rail" and name ~= "powered_rail" and name ~= "detector_rail" and name ~= "activator_rail" then return nil end
	return block, name ~= "rail"
end

local function railAtNear( changes, changeCount, overrides, bx, by, bz )
	for offset = 0, 2 do
		local testZ = offset == 0 and bz or offset == 1 and bz + 1 or bz - 1
		local stateId = stateAt( changes, changeCount, overrides, bx, by, testZ )
		local block, straight = railInfo( stateId )
		if block then return bx, by, testZ, stateId, straight end
	end
	return nil
end

local function shapeForState( stateId )
	return MC.GetStateProperty and MC.GetStateProperty( stateId, "shape" ) or "north_south"
end

local function shapeConnectsTo( shape, bx, by, targetX, targetY )
	local connections = ShapeConnections[shape]
	if not connections then return false end
	for index = 1, 2 do
		local offset = Directions[connections[index]]
		if bx + offset[1] == targetX and by + offset[2] == targetY then return true end
	end
	return false
end

local function softConnectionCount( changes, changeCount, overrides, bx, by, bz, stateId )
	local shape = shapeForState( stateId )
	local connections = ShapeConnections[shape] or ShapeConnections.north_south
	local count = 0
	for index = 1, 2 do
		local offset = Directions[connections[index]]
		local nx, ny, _, neighbourState = railAtNear( changes, changeCount, overrides, bx + offset[1], by + offset[2], bz )
		if nx and shapeConnectsTo( shapeForState( neighbourState ), nx, ny, bx, by ) then count = count + 1 end
	end
	return count
end

local function neighbourCanConnect( changes, changeCount, overrides, bx, by, bz, direction )
	local offset = Directions[direction]
	local nx, ny, nz, neighbourState = railAtNear( changes, changeCount, overrides, bx + offset[1], by + offset[2], bz )
	if not nx then return false end
	if shapeConnectsTo( shapeForState( neighbourState ), nx, ny, bx, by ) then return true end
	return softConnectionCount( changes, changeCount, overrides, nx, ny, nz, neighbourState ) ~= 2
end

local function railExactlyAt( changes, changeCount, overrides, bx, by, bz )
	return railInfo( stateAt( changes, changeCount, overrides, bx, by, bz ) ) ~= nil
end

local function resolveRailShape( changes, changeCount, overrides, bx, by, bz, stateId, straight )
	local n = neighbourCanConnect( changes, changeCount, overrides, bx, by, bz, NORTH )
	local s = neighbourCanConnect( changes, changeCount, overrides, bx, by, bz, SOUTH )
	local w = neighbourCanConnect( changes, changeCount, overrides, bx, by, bz, WEST )
	local e = neighbourCanConnect( changes, changeCount, overrides, bx, by, bz, EAST )
	local northOrSouth = n or s
	local westOrEast = w or e
	local shape
	if northOrSouth and not westOrEast then shape = "north_south" end
	if westOrEast and not northOrSouth then shape = "east_west" end

	local southAndEast = s and e
	local southAndWest = s and w
	local northAndEast = n and e
	local northAndWest = n and w
	if not straight then
		if southAndEast and not n and not w then shape = "south_east" end
		if southAndWest and not n and not e then shape = "south_west" end
		if northAndWest and not s and not e then shape = "north_west" end
		if northAndEast and not s and not w then shape = "north_east" end
	end

	if not shape then
		if northOrSouth and westOrEast then
			shape = shapeForState( stateId )
		elseif northOrSouth then
			shape = "north_south"
		elseif westOrEast then
			shape = "east_west"
		end
		if not straight then
			-- RailState.place with hasSignal=false: later matches win.
			if northAndWest then shape = "north_west" end
			if northAndEast then shape = "north_east" end
			if southAndWest then shape = "south_west" end
			if southAndEast then shape = "south_east" end
		end
	end

	shape = shape or shapeForState( stateId ) or "north_south"
	if shape == "north_south" then
		if railExactlyAt( changes, changeCount, overrides, bx, by - 1, bz + 1 ) then shape = "ascending_north" end
		if railExactlyAt( changes, changeCount, overrides, bx, by + 1, bz + 1 ) then shape = "ascending_south" end
	elseif shape == "east_west" then
		if railExactlyAt( changes, changeCount, overrides, bx + 1, by, bz + 1 ) then shape = "ascending_east" end
		if railExactlyAt( changes, changeCount, overrides, bx - 1, by, bz + 1 ) then shape = "ascending_west" end
	end
	return shape
end

local function addCandidate( candidates, seen, bx, by, bz )
	local key = MC.CellKey( bx, by, bz )
	if seen[key] then return end
	seen[key] = true
	candidates[#candidates + 1] = { bx = bx, by = by, bz = bz, key = key }
end

function MC.BuildRailStateUpdates( changes, changeCount )
	if not changes or #changes == 0 then return {} end
	changeCount = math.min( math.floor( tonumber( changeCount ) or #changes ), #changes )
	local relevant = false
	local emptyOverrides = {}
	for index = 1, changeCount do
		local cell = changes[index]
		local oldState = MC.GetBlockState and MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0
		if railInfo( oldState ) or railInfo( primaryState( changes, changeCount, cell.bx, cell.by, cell.bz ) ) then
			relevant = true
			break
		end
		for dz = -1, 1 do
			if railAtNear( changes, changeCount, emptyOverrides, cell.bx, cell.by, cell.bz + dz ) then
				relevant = true
				break
			end
		end
		if relevant then break end
		for direction = 1, 4 do
			local offset = Directions[direction]
			if railAtNear( changes, changeCount, emptyOverrides, cell.bx + offset[1], cell.by + offset[2], cell.bz ) then
				relevant = true
				break
			end
		end
		if relevant then break end
	end
	if not relevant then return {} end
	local candidates, seen = {}, {}
	for index = 1, changeCount do
		local cell = changes[index]
		for dz = -2, 2 do
			for dx = -2, 2 do
				for dy = -2, 2 do
					if math.abs( dx ) + math.abs( dy ) <= 2 then
						addCandidate( candidates, seen, cell.bx + dx, cell.by + dy, cell.bz + dz )
					end
				end
			end
		end
	end

	local overrides = {}
	for iteration = 1, 8 do
		local changed = false
		for index = 1, #candidates do
			local candidate = candidates[index]
			local stateId = stateAt( changes, changeCount, overrides, candidate.bx, candidate.by, candidate.bz )
			local _, straight = railInfo( stateId )
			if straight ~= nil then
				local shape = resolveRailShape( changes, changeCount, overrides, candidate.bx, candidate.by, candidate.bz, stateId, straight )
				local nextState = MC.StateWith( stateId, "shape", shape ) or stateId
				if nextState ~= stateId then
					overrides[candidate.key] = nextState
					changed = true
				end
			end
		end
		if not changed then break end
	end

	local updates = {}
	for index = 1, #candidates do
		local candidate = candidates[index]
		local nextState = overrides[candidate.key]
		if nextState then
			local worldState = MC.GetBlockState and MC.GetBlockState( candidate.bx, candidate.by, candidate.bz ) or 0
			if nextState ~= worldState then
				updates[#updates + 1] = {
					bx = candidate.bx, by = candidate.by, bz = candidate.bz,
					stateId = nextState,
				}
			end
		end
	end
	return updates
end
