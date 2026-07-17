-- State-native redstone wire visual connections.
--
-- This does not implement signal propagation yet. It maintains the vanilla
-- north/south/east/west shape properties when nearby blocks change, including
-- same-level, one-block-up and one-block-down wire paths.

MC = MC or {}

local Directions = {
	{ name = "north", dx = 0, dy = -1 },
	{ name = "south", dx = 0, dy = 1 },
	{ name = "west", dx = -1, dy = 0 },
	{ name = "east", dx = 1, dy = 0 },
}

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

function MC.IsRedstoneWireState( stateId )
	return stateName( stateId ) == "minecraft:redstone_wire"
end

local function plannedState( changes, bx, by, bz )
	for index = 1, #changes do
		local cell = changes[index]
		if cell.bx == bx and cell.by == by and cell.bz == bz then
			if cell.stateId ~= nil then return cell.stateId end
			return MC.StateFromLegacy and MC.StateFromLegacy( cell.id or 0, cell.orient or 0 ) or 0
		end
	end
	return MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
end

local function fullCubeAt( changes, bx, by, bz )
	local stateId = plannedState( changes, bx, by, bz )
	if not stateId or stateId == 0 then return false end
	if MC.BlockIsFullCubeForState then return MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true end
	local id, orient = MC.LegacyFromState( stateId )
	return id and MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) == true or false
end

local function connectionValue( changes, bx, by, bz, direction )
	local nx, ny = bx + direction.dx, by + direction.dy
	if MC.IsRedstoneWireState( plannedState( changes, nx, ny, bz ) ) then return "side" end

	local neighbourSolid = fullCubeAt( changes, nx, ny, bz )
	if neighbourSolid and not fullCubeAt( changes, bx, by, bz + 1 )
	and MC.IsRedstoneWireState( plannedState( changes, nx, ny, bz + 1 ) ) then
		return "up"
	end
	if not neighbourSolid and MC.IsRedstoneWireState( plannedState( changes, nx, ny, bz - 1 ) ) then
		return "side"
	end
	return "none"
end

local function resolvedWireState( changes, stateId, bx, by, bz, forceCross )
	local wasDot = MC.GetStateProperty( stateId, "north" ) == "none"
		and MC.GetStateProperty( stateId, "south" ) == "none"
		and MC.GetStateProperty( stateId, "east" ) == "none"
		and MC.GetStateProperty( stateId, "west" ) == "none"
	local values = {}
	for index = 1, #Directions do
		local direction = Directions[index]
		values[direction.name] = connectionValue( changes, bx, by, bz, direction )
	end
	-- RedStoneWireBlock.getConnectionState: a non-dot wire with no connection
	-- on one axis is completed into a straight line on that axis.
	local north = values.north ~= "none"
	local south = values.south ~= "none"
	local east = values.east ~= "none"
	local west = values.west ~= "none"
	local northSouthEmpty = not north and not south
	local eastWestEmpty = not east and not west
	local remainsDot = northSouthEmpty and eastWestEmpty
	if forceCross or not ( wasDot and remainsDot ) then
		if not west and northSouthEmpty then values.west = "side" end
		if not east and northSouthEmpty then values.east = "side" end
		if not north and eastWestEmpty then values.north = "side" end
		if not south and eastWestEmpty then values.south = "side" end
	end
	for index = 1, #Directions do
		local direction = Directions[index]
		stateId = MC.StateWith( stateId, direction.name, values[direction.name] ) or stateId
	end
	return stateId
end

local function addCandidate( candidates, seen, bx, by, bz )
	local key = MC.CellKey( bx, by, bz )
	if seen[key] then return end
	seen[key] = true
	candidates[#candidates + 1] = { bx = bx, by = by, bz = bz }
end

function MC.BuildRedstoneWireStateUpdates( changes )
	if not changes or #changes == 0 then return {} end
	local candidates, seen = {}, {}
	for index = 1, #changes do
		local cell = changes[index]
		addCandidate( candidates, seen, cell.bx, cell.by, cell.bz )
		addCandidate( candidates, seen, cell.bx, cell.by, cell.bz - 1 )
		addCandidate( candidates, seen, cell.bx, cell.by, cell.bz + 1 )
		for directionIndex = 1, #Directions do
			local direction = Directions[directionIndex]
			local nx, ny = cell.bx + direction.dx, cell.by + direction.dy
			addCandidate( candidates, seen, nx, ny, cell.bz - 1 )
			addCandidate( candidates, seen, nx, ny, cell.bz )
			addCandidate( candidates, seen, nx, ny, cell.bz + 1 )
		end
	end

	local updates = {}
	for index = 1, #candidates do
		local candidate = candidates[index]
		local stateId = plannedState( changes, candidate.bx, candidate.by, candidate.bz )
		if MC.IsRedstoneWireState( stateId ) then
			local worldState = MC.GetBlockState and MC.GetBlockState( candidate.bx, candidate.by, candidate.bz ) or 0
			local nextState = resolvedWireState( changes, stateId, candidate.bx, candidate.by, candidate.bz, worldState == 0 )
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
