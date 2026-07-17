-- State-native horizontal neighbour connections for fences, panes/bars and
-- fence gates. Mirrors FenceBlock, IronBarsBlock and FenceGateBlock without
-- projecting through legacy orient or mutating the world outside a transaction.

MC = MC or {}

local Directions = {
	{ name = "north", dx = 0, dy = -1, face = 1, axis = 2, wallRect = { 7 / 16, 0, 9 / 16, 9 / 16 } },
	{ name = "south", dx = 0, dy = 1, face = 2, axis = 2, wallRect = { 7 / 16, 7 / 16, 9 / 16, 1 } },
	{ name = "west", dx = -1, dy = 0, face = 3, axis = 1, wallRect = { 0, 7 / 16, 9 / 16, 9 / 16 } },
	{ name = "east", dx = 1, dy = 0, face = 4, axis = 1, wallRect = { 7 / 16, 7 / 16, 1, 9 / 16 } },
}

local FaceSturdyCache = {}
local DownCoverCache = {}
local EPSILON = 0.0001

local function plannedState( changes, changeCount, bx, by, bz )
	for index = 1, changeCount do
		local cell = changes[index]
		if cell.bx == bx and cell.by == by and cell.bz == bz then
			if cell.stateId ~= nil then return cell.stateId end
			return MC.StateFromLegacy and MC.StateFromLegacy( cell.id or 0, cell.orient or 0 ) or 0
		end
	end
	return MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
end

local function blockForState( stateId )
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	return id and MC.Blocks and MC.Blocks[id] or nil
end

local function connectionKind( stateId )
	local block = blockForState( stateId )
	return block and block.connection or nil, block
end

local function isConnectionException( block )
	local name = block and block.name or ""
	return string.match( name, "_leaves$" ) ~= nil
		or name == "barrier"
		or name == "carved_pumpkin"
		or name == "jack_o_lantern"
		or name == "melon"
		or name == "pumpkin"
		or string.match( name, "_shulker_box$" ) ~= nil
end

local function boxCoversSample( box, face, u, v )
	if face == 1 then
		return box[5] >= 1 - EPSILON and u >= box[1] - EPSILON and u <= box[4] + EPSILON
			and v >= box[3] - EPSILON and v <= box[6] + EPSILON
	elseif face == 2 then
		return box[2] <= EPSILON and u >= box[1] - EPSILON and u <= box[4] + EPSILON
			and v >= box[3] - EPSILON and v <= box[6] + EPSILON
	elseif face == 3 then
		return box[4] >= 1 - EPSILON and u >= box[2] - EPSILON and u <= box[5] + EPSILON
			and v >= box[3] - EPSILON and v <= box[6] + EPSILON
	end
	return box[1] <= EPSILON and u >= box[2] - EPSILON and u <= box[5] + EPSILON
		and v >= box[3] - EPSILON and v <= box[6] + EPSILON
end

local function faceSturdy( stateId, bx, by, bz, face )
	if not stateId or stateId == 0 then return false end
	local cacheKey = stateId * 4 + face
	local cached = FaceSturdyCache[cacheKey]
	if cached ~= nil then return cached end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) then
		FaceSturdyCache[cacheKey] = true
		return true
	end
	local boxes = MC.GetBlockCollisionBoxesForState and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
	if not boxes or #boxes == 0 then
		FaceSturdyCache[cacheKey] = false
		return false
	end
	for y = 0, 15 do
		local v = ( y + 0.5 ) / 16
		for x = 0, 15 do
			local u = ( x + 0.5 ) / 16
			local covered = false
			for index = 1, #boxes do
				if boxCoversSample( boxes[index], face, u, v ) then
					covered = true
					break
				end
			end
			if not covered then
				FaceSturdyCache[cacheKey] = false
				return false
			end
		end
	end
	FaceSturdyCache[cacheKey] = true
	return true
end

local function gateAxis( stateId )
	local facing = MC.GetStateProperty and MC.GetStateProperty( stateId, "facing" ) or "north"
	return ( facing == "east" or facing == "west" ) and 1 or 2
end

local function fenceIsWooden( block )
	return block and block.name ~= "nether_brick_fence"
end

local function fenceConnects( changes, changeCount, currentBlock, bx, by, bz, direction )
	local nx, ny = bx + direction.dx, by + direction.dy
	local neighbourState = plannedState( changes, changeCount, nx, ny, bz )
	local kind, neighbourBlock = connectionKind( neighbourState )
	if kind == "fence" and fenceIsWooden( currentBlock ) == fenceIsWooden( neighbourBlock ) then return true end
	if kind == "fence_gate" and gateAxis( neighbourState ) ~= direction.axis then return true end
	return not isConnectionException( neighbourBlock ) and faceSturdy( neighbourState, nx, ny, bz, direction.face )
end

local function paneConnects( changes, changeCount, bx, by, bz, direction )
	local nx, ny = bx + direction.dx, by + direction.dy
	local neighbourState = plannedState( changes, changeCount, nx, ny, bz )
	local kind, neighbourBlock = connectionKind( neighbourState )
	if kind == "pane" or kind == "bars" or kind == "wall" then return true end
	return not isConnectionException( neighbourBlock ) and faceSturdy( neighbourState, nx, ny, bz, direction.face )
end

local function wallConnects( changes, changeCount, bx, by, bz, direction )
	local nx, ny = bx + direction.dx, by + direction.dy
	local neighbourState = plannedState( changes, changeCount, nx, ny, bz )
	local kind, neighbourBlock = connectionKind( neighbourState )
	if kind == "wall" or kind == "pane" or kind == "bars" then return true end
	if kind == "fence_gate" and gateAxis( neighbourState ) ~= direction.axis then return true end
	return not isConnectionException( neighbourBlock ) and faceSturdy( neighbourState, nx, ny, bz, direction.face )
end

local function downFaceCovers( stateId, bx, by, bz, rect, rectIndex )
	if not stateId or stateId == 0 then return false end
	local cacheKey = stateId * 5 + rectIndex
	local cached = DownCoverCache[cacheKey]
	if cached ~= nil then return cached end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) then
		DownCoverCache[cacheKey] = true
		return true
	end
	local boxes = MC.GetBlockCollisionBoxesForState and MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or nil
	if not boxes or #boxes == 0 then
		DownCoverCache[cacheKey] = false
		return false
	end
	local minX, minY, maxX, maxY = rect[1], rect[2], rect[3], rect[4]
	for y = 0, 15 do
		local sampleY = ( y + 0.5 ) / 16
		if sampleY >= minY and sampleY <= maxY then
			for x = 0, 15 do
				local sampleX = ( x + 0.5 ) / 16
				if sampleX >= minX and sampleX <= maxX then
					local covered = false
					for index = 1, #boxes do
						local box = boxes[index]
						if box[3] <= EPSILON
						and sampleX >= box[1] - EPSILON and sampleX <= box[4] + EPSILON
						and sampleY >= box[2] - EPSILON and sampleY <= box[5] + EPSILON then
							covered = true
							break
						end
					end
					if not covered then
						DownCoverCache[cacheKey] = false
						return false
					end
				end
			end
		end
	end
	DownCoverCache[cacheKey] = true
	return true
end

local function wallPostOverride( block )
	local name = block and block.name or ""
	if name == "torch" or name == "soul_torch" or name == "redstone_torch" or name == "copper_torch"
	or name == "tripwire" or name == "cactus_flower" then return true end
	if string.match( name, "_pressure_plate$" ) or string.match( name, "_banner$" ) then return true end
	return string.match( name, "_sign$" ) ~= nil and string.find( name, "hanging_sign", 1, true ) == nil
end

local function resolveWallState( changes, changeCount, stateId, bx, by, bz )
	local aboveState = plannedState( changes, changeCount, bx, by, bz + 1 )
	local aboveKind, aboveBlock = connectionKind( aboveState )
	local connected = {}
	for index = 1, #Directions do
		local direction = Directions[index]
		local sideConnected = wallConnects( changes, changeCount, bx, by, bz, direction )
		connected[direction.name] = sideConnected
		local side = sideConnected and ( downFaceCovers( aboveState, bx, by, bz + 1, direction.wallRect, index ) and "tall" or "low" ) or "none"
		stateId = MC.StateWith( stateId, direction.name, side ) or stateId
	end

	local northNone = not connected.north
	local southNone = not connected.south
	local westNone = not connected.west
	local eastNone = not connected.east
	local aboveHasPost = aboveKind == "wall" and MC.GetStateProperty( aboveState, "up" ) == true
	local hasCorner = northNone and southNone and westNone and eastNone
		or northNone ~= southNone or westNone ~= eastNone
	local northTall = MC.GetStateProperty( stateId, "north" ) == "tall"
	local southTall = MC.GetStateProperty( stateId, "south" ) == "tall"
	local westTall = MC.GetStateProperty( stateId, "west" ) == "tall"
	local eastTall = MC.GetStateProperty( stateId, "east" ) == "tall"
	local hasHighWall = northTall and southTall or westTall and eastTall
	local raisePost = aboveHasPost or hasCorner
	if not raisePost and not hasHighWall then
		raisePost = wallPostOverride( aboveBlock )
			or downFaceCovers( aboveState, bx, by, bz + 1, { 7 / 16, 7 / 16, 9 / 16, 9 / 16 }, 5 )
	end
	return MC.StateWith( stateId, "up", raisePost == true ) or stateId
end

local function resolveCrossState( changes, changeCount, stateId, block, bx, by, bz, kind )
	for index = 1, #Directions do
		local direction = Directions[index]
		local connected
		if kind == "fence" then
			connected = fenceConnects( changes, changeCount, block, bx, by, bz, direction )
		else
			connected = paneConnects( changes, changeCount, bx, by, bz, direction )
		end
		stateId = MC.StateWith( stateId, direction.name, connected ) or stateId
	end
	return stateId
end

local function resolveFenceGateState( changes, changeCount, stateId, bx, by, bz )
	local axis = gateAxis( stateId )
	local inWall
	if axis == 2 then
		inWall = connectionKind( plannedState( changes, changeCount, bx - 1, by, bz ) ) == "wall"
			or connectionKind( plannedState( changes, changeCount, bx + 1, by, bz ) ) == "wall"
	else
		inWall = connectionKind( plannedState( changes, changeCount, bx, by - 1, bz ) ) == "wall"
			or connectionKind( plannedState( changes, changeCount, bx, by + 1, bz ) ) == "wall"
	end
	return MC.StateWith( stateId, "in_wall", inWall == true ) or stateId
end

local function addCandidate( candidates, seen, bx, by, bz )
	local key = MC.CellKey( bx, by, bz )
	if seen[key] then return end
	seen[key] = true
	candidates[#candidates + 1] = { bx = bx, by = by, bz = bz }
end

function MC.BuildBlockConnectionStateUpdates( changes, changeCount )
	if not changes or #changes == 0 then return {} end
	changeCount = math.min( math.floor( tonumber( changeCount ) or #changes ), #changes )
	local candidates, seen = {}, {}
	for index = 1, changeCount do
		local cell = changes[index]
		addCandidate( candidates, seen, cell.bx, cell.by, cell.bz )
		addCandidate( candidates, seen, cell.bx, cell.by, cell.bz - 1 )
		for directionIndex = 1, #Directions do
			local direction = Directions[directionIndex]
			addCandidate( candidates, seen, cell.bx + direction.dx, cell.by + direction.dy, cell.bz )
		end
	end

	local updates = {}
	for index = 1, #candidates do
		local candidate = candidates[index]
		local stateId = plannedState( changes, changeCount, candidate.bx, candidate.by, candidate.bz )
		local kind, block = connectionKind( stateId )
		local nextState
		if kind == "fence" or kind == "pane" or kind == "bars" then
			nextState = resolveCrossState( changes, changeCount, stateId, block, candidate.bx, candidate.by, candidate.bz, kind )
		elseif kind == "wall" then
			nextState = resolveWallState( changes, changeCount, stateId, candidate.bx, candidate.by, candidate.bz )
		elseif kind == "fence_gate" then
			nextState = resolveFenceGateState( changes, changeCount, stateId, candidate.bx, candidate.by, candidate.bz )
		end
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
