-- Shared axis-aligned face-occlusion helpers used by fluid flow and rendering.

MC = MC or {}
MC.Liquid = MC.Liquid or {}

local Liquid = MC.Liquid
local min = math.min
local max = math.max
local sort = table.sort
local EPSILON = 0.0001

local FACE_TOP = 1
local FACE_BOTTOM = 2
local FACE_XP = 3
local FACE_XN = 4
local FACE_YP = 5
local FACE_YN = 6

local function oppositeFace( face )
	if face == FACE_TOP then return FACE_BOTTOM end
	if face == FACE_BOTTOM then return FACE_TOP end
	if face == FACE_XP then return FACE_XN end
	if face == FACE_XN then return FACE_XP end
	if face == FACE_YP then return FACE_YN end
	return FACE_YP
end

local function faceOffset( face )
	if face == FACE_TOP then return 0, 0, 1 end
	if face == FACE_BOTTOM then return 0, 0, -1 end
	if face == FACE_XP then return 1, 0, 0 end
	if face == FACE_XN then return -1, 0, 0 end
	if face == FACE_YP then return 0, 1, 0 end
	return 0, -1, 0
end

local function stateBoxes( stateId, bx, by, bz )
	if not stateId or stateId == 0 then return nil end
	if MC.GetBlockCollisionBoxesForState then
		return MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz )
	end
	return nil
end

local Edges = {}
local Rects = {}
local LastEdgeCount = 0
local SolidByState = {}
local EmptyOcclusionByState = {}

local function addRect( count, a0, a1, b0, b1, targetB1 )
	a0, a1 = max( 0, a0 ), min( 1, a1 )
	b0, b1 = max( 0, b0 ), min( targetB1, b1 )
	if a1 <= a0 + EPSILON or b1 <= b0 + EPSILON then return count end
	count = count + 1
	local offset = ( count - 1 ) * 4
	Rects[offset + 1], Rects[offset + 2] = a0, a1
	Rects[offset + 3], Rects[offset + 4] = b0, b1
	Edges[count * 2 - 1], Edges[count * 2] = a0, a1
	return count
end

local function boundaryRect( box, face, height )
	if face == FACE_TOP then
		if box[3] > EPSILON then return nil end
		return box[1], box[4], box[2], box[5], 1
	elseif face == FACE_BOTTOM then
		if box[6] < 1 - EPSILON then return nil end
		return box[1], box[4], box[2], box[5], 1
	elseif face == FACE_XP then
		if box[1] > EPSILON then return nil end
		return box[2], box[5], box[3], box[6], height
	elseif face == FACE_XN then
		if box[4] < 1 - EPSILON then return nil end
		return box[2], box[5], box[3], box[6], height
	elseif face == FACE_YP then
		if box[2] > EPSILON then return nil end
		return box[1], box[4], box[3], box[6], height
	else
		if box[5] < 1 - EPSILON then return nil end
		return box[1], box[4], box[3], box[6], height
	end
end

-- Tests whether the union of boundary rectangles fully covers the fluid face.
-- Scratch arrays are reused because mesh construction is single-threaded in Lua.
local function stateUsesEmptyOcclusionShape( stateId, bx, by, bz )
	local cached = EmptyOcclusionByState[stateId]
	if cached ~= nil then return cached end
	local visual = MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId, bx, by, bz ) or nil
	if visual and MC.BlockVisualIsTranslucent and MC.BlockVisualIsTranslucent( visual, bx, by, bz ) then
		EmptyOcclusionByState[stateId] = true
		return true
	end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
	local block = MC.Blocks and MC.Blocks[id] or nil
	local empty = block and block.transparent == true or false
	EmptyOcclusionByState[stateId] = empty
	return empty
end

local function faceCoveredByState( face, height, stateId, bx, by, bz, collisionFace )
	if not stateId or stateId == 0 or height <= 0 then return false end
	if face == FACE_TOP and height < 1 - EPSILON then return false end
	if not collisionFace and stateUsesEmptyOcclusionShape( stateId, bx, by, bz ) then return false end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) then
		return face ~= FACE_TOP or height >= 1 - EPSILON
	end
	local boxes = stateBoxes( stateId, bx, by, bz )
	if not boxes or #boxes == 0 then return false end

	local targetB1 = height
	if face == FACE_TOP or face == FACE_BOTTOM then targetB1 = 1 end
	local rectCount = 0
	for index = 1, #boxes do
		local a0, a1, b0, b1, limit = boundaryRect( boxes[index], face, height )
		if a0 then
			if a0 <= EPSILON and a1 >= 1 - EPSILON and b0 <= EPSILON and b1 >= limit - EPSILON then
				return true
			end
			rectCount = addRect( rectCount, a0, a1, b0, b1, limit )
		end
	end
	if rectCount == 0 then return false end

	local edgeCount = rectCount * 2
	for index = edgeCount + 1, LastEdgeCount do Edges[index] = nil end
	LastEdgeCount = edgeCount
	sort( Edges )
	local previous = 0
	for edgeIndex = 1, edgeCount do
		local edge = Edges[edgeIndex]
		if edge > previous + EPSILON then
			local sampleA = ( previous + edge ) * 0.5
			local coveredTo = 0
			while coveredTo < targetB1 - EPSILON do
				local nextCovered = coveredTo
				for rectIndex = 1, rectCount do
					local offset = ( rectIndex - 1 ) * 4
					if Rects[offset + 1] <= sampleA + EPSILON and Rects[offset + 2] >= sampleA - EPSILON
					and Rects[offset + 3] <= coveredTo + EPSILON and Rects[offset + 4] > nextCovered then
						nextCovered = Rects[offset + 4]
					end
				end
				if nextCovered <= coveredTo + EPSILON then return false end
				coveredTo = nextCovered
			end
		end
		if edge > previous then previous = edge end
	end
	return previous >= 1 - EPSILON
end

local function faceOccludedByState( face, height, stateId, bx, by, bz )
	return faceCoveredByState( face, height, stateId, bx, by, bz, false )
end

local function faceSturdyForFlow( stateId, bx, by, bz, face )
	return faceCoveredByState( oppositeFace( face ), 1, stateId, bx, by, bz, true )
end

-- BlockState#isSolid legacy calculation: collision bounds average size is at
-- least 0.7291666, or the collision bounds span a full block vertically.
local function stateSolid( stateId, bx, by, bz )
	if not stateId or stateId == 0 then return false end
	local cached = SolidByState[stateId]
	if cached ~= nil then return cached end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) then
		SolidByState[stateId] = true
		return true
	end
	local boxes = stateBoxes( stateId, bx, by, bz )
	if not boxes or #boxes == 0 then
		SolidByState[stateId] = false
		return false
	end
	local minX, minY, minZ = 1, 1, 1
	local maxX, maxY, maxZ = 0, 0, 0
	for index = 1, #boxes do
		local box = boxes[index]
		minX, minY, minZ = min( minX, box[1] ), min( minY, box[2] ), min( minZ, box[3] )
		maxX, maxY, maxZ = max( maxX, box[4] ), max( maxY, box[5] ), max( maxZ, box[6] )
	end
	local size = ( maxX - minX + maxY - minY + maxZ - minZ ) / 3
	local solid = size >= 0.7291666666666666 or maxZ - minZ >= 1
	SolidByState[stateId] = solid
	return solid
end

Liquid.OppositeFace = oppositeFace
Liquid.FaceOffset = faceOffset
Liquid.FaceOccludedByState = faceOccludedByState
Liquid.FaceSturdyForFlow = faceSturdyForFlow
Liquid.StateSolid = stateSolid
Liquid.FACE_TOP = FACE_TOP
Liquid.FACE_BOTTOM = FACE_BOTTOM
Liquid.FACE_XP = FACE_XP
Liquid.FACE_XN = FACE_XN
Liquid.FACE_YP = FACE_YP
Liquid.FACE_YN = FACE_YN
