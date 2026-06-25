-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local FACES = C.FACES
local mathFloor = math.floor
local bit_bor, bit_lshift, bit_band, bit_rshift = bit.bor, bit.lshift, bit.band, bit.rshift
local clampLightLevel = RM.clampLightLevel
local LIGHTMAP_PACK_SKY_MASK = RM.LIGHTMAP_PACK_SKY_MASK
local LIGHTMAP_SMOOTH_PACK_MASK = RM.LIGHTMAP_SMOOTH_PACK_MASK
local lightmapUVFromSmoothCoords = RM.lightmapUVFromSmoothCoords
local cachedMeshLightLevelsSample = RM.cachedMeshLightLevelsSample
local blockLightEmissionAt = RM.blockLightEmissionAt
local faceSampleBaseCell = RM.faceSampleBaseCell
local cachedMeshAOSample = RM.cachedMeshAOSample
local isSolidRenderForLightmap = RM.isSolidRenderForLightmap
local isTranslucentForLightmap = RM.isTranslucentForLightmap
local MC_LIGHTMAP_SIDE_OFFSETS = RM.MC_LIGHTMAP_SIDE_OFFSETS
local MC_LIGHT_AO_FACTORS = RM.MC_LIGHT_AO_FACTORS
local offsetCell = RM.offsetCell
local cornerStep = RM.cornerStep

local function packedLightCoordsFromLevels( block, sky )
	return bit_bor( bit_lshift( clampLightLevel( block ), 4 ), bit_lshift( clampLightLevel( sky ), 20 ) )
end

local function packedLightCoordsAt( sx, sy, sz )
	local block, sky = cachedMeshLightLevelsSample( sx, sy, sz, blockLightEmissionAt( sx, sy, sz ) )
	return packedLightCoordsFromLevels( block, sky )
end

local function packedLightBlockLevel( packed )
	return bit_band( bit_rshift( packed or 0, 4 ), 15 )
end

local function packedLightSkyLevel( packed )
	return bit_band( bit_rshift( packed or 0, 20 ), 15 )
end

local function smoothPackedBlock( packed )
	return bit_band( packed or 0, 0xFF )
end

local function smoothPackedSky( packed )
	return bit_band( bit_rshift( packed or 0, 16 ), 0xFF )
end

local function smoothPackLightCoords( block, sky )
	return bit_bor(
		bit_band( mathFloor( tonumber( block ) or 0 ), 0xFF ),
		bit_lshift( bit_band( mathFloor( tonumber( sky ) or 0 ), 0xFF ), 16 )
	)
end

local function mcSmoothBlendLightCoords( neighbor1, neighbor2, neighbor3, center )
	neighbor1 = neighbor1 or 0
	neighbor2 = neighbor2 or 0
	neighbor3 = neighbor3 or 0
	center = center or 0
	if packedLightSkyLevel( center ) > 2 or packedLightBlockLevel( center ) > 2 then
		if neighbor1 == 0 then
			neighbor1 = center
		elseif packedLightSkyLevel( neighbor1 ) == 0 then
			neighbor1 = bit_bor( neighbor1, bit_band( center, LIGHTMAP_PACK_SKY_MASK ) )
		end
		if neighbor2 == 0 then
			neighbor2 = center
		elseif packedLightSkyLevel( neighbor2 ) == 0 then
			neighbor2 = bit_bor( neighbor2, bit_band( center, LIGHTMAP_PACK_SKY_MASK ) )
		end
		if neighbor3 == 0 then
			neighbor3 = center
		elseif packedLightSkyLevel( neighbor3 ) == 0 then
			neighbor3 = bit_bor( neighbor3, bit_band( center, LIGHTMAP_PACK_SKY_MASK ) )
		end
	end
	return bit_band( bit_rshift( neighbor1 + neighbor2 + neighbor3 + center, 2 ), LIGHTMAP_SMOOTH_PACK_MASK )
end

local function smoothWeightedBlendLightCoords( coords1, coords2, coords3, coords4, weight1, weight2, weight3, weight4 )
	local block = smoothPackedBlock( coords1 ) * weight1
		+ smoothPackedBlock( coords2 ) * weight2
		+ smoothPackedBlock( coords3 ) * weight3
		+ smoothPackedBlock( coords4 ) * weight4
	local sky = smoothPackedSky( coords1 ) * weight1
		+ smoothPackedSky( coords2 ) * weight2
		+ smoothPackedSky( coords3 ) * weight3
		+ smoothPackedSky( coords4 ) * weight4
	return smoothPackLightCoords( block, sky )
end

local function lightCoordsWithQuadEmission( lightCoords, quadLightEmission )
	local emission = clampLightLevel( quadLightEmission )
	if emission <= 0 then return lightCoords end
	local block = math.max( packedLightBlockLevel( lightCoords ), emission )
	local sky = math.max( packedLightSkyLevel( lightCoords ), emission )
	return packedLightCoordsFromLevels( block, sky )
end

local function lightmapUVFromSmoothPacked( lightCoords, quadLightEmission )
	local smooth = lightCoordsWithQuadEmission( lightCoords, quadLightEmission )
	return lightmapUVFromSmoothCoords( smoothPackedBlock( smooth ), smoothPackedSky( smooth ) )
end

local function lightCenterPackedCoords( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local face = FACES[faceIndex]
	local off = face and face.off
	if not off then return packedLightCoordsAt( bx, by, bz, selfEmission ) end
	local nbx, nby, nbz = bx + off[1], by + off[2], bz + off[3]
	if faceCubic then
		return packedLightCoordsAt( nbx, nby, nbz, selfEmission )
	end
	local id = MC.GetBlock and MC.GetBlock( nbx, nby, nbz ) or 0
	local orient = id ~= 0 and MC.GetBlockOrient and MC.GetBlockOrient( nbx, nby, nbz ) or 0
	if not isSolidRenderForLightmap( id, orient ) then
		return packedLightCoordsAt( nbx, nby, nbz, selfEmission )
	end
	return packedLightCoordsAt( bx, by, bz, selfEmission )
end

local function remapFaceCornerLightSlot( faceIndex, cornerIndex )
	if faceIndex == MC.Face.TOP then
		if cornerIndex == 1 then return 3 elseif cornerIndex == 2 then return 4 elseif cornerIndex == 3 then return 1 end
		return 2
	elseif faceIndex == MC.Face.YN or faceIndex == MC.Face.XN then
		if cornerIndex == 1 then return 2 elseif cornerIndex == 2 then return 3 elseif cornerIndex == 3 then return 4 end
		return 1
	elseif faceIndex == MC.Face.XP then
		if cornerIndex == 1 then return 4 elseif cornerIndex == 2 then return 1 elseif cornerIndex == 3 then return 2 end
		return 3
	end
	return cornerIndex
end

local function minecraftCornerOccludersValues( bx, by, bz, faceIndex, x, y, z )
	local xs, ys, zs = cornerStep( x ), cornerStep( y ), cornerStep( z )
	if faceIndex == MC.Face.TOP or faceIndex == MC.Face.BOTTOM then
		return bx + xs, by, bz, bx, by + ys, bz, bx + xs, by + ys, bz
	elseif faceIndex == MC.Face.XP or faceIndex == MC.Face.XN then
		return bx, by + ys, bz, bx, by, bz + zs, bx, by + ys, bz + zs
	elseif faceIndex == MC.Face.YP or faceIndex == MC.Face.YN then
		return bx + xs, by, bz, bx, by, bz + zs, bx + xs, by, bz + zs
	end
	return bx, by, bz, bx, by, bz, bx, by, bz
end

local function minecraftSmoothCornerAOValuesForLightmap( bx, by, bz, faceIndex, cx, cy, cz )
	if not cachedMeshAOSample then return 1 end
	local s1x, s1y, s1z, s2x, s2y, s2z, cornerX, cornerY, cornerZ =
		minecraftCornerOccludersValues( bx, by, bz, faceIndex, cx, cy, cz )
	local side1Blocked = cachedMeshAOSample( s1x, s1y, s1z )
	local side2Blocked = cachedMeshAOSample( s2x, s2y, s2z )
	local cornerBlocked = cachedMeshAOSample( cornerX, cornerY, cornerZ )
	if side1Blocked and side2Blocked then return MC_LIGHT_AO_FACTORS[3] end
	local blocked = ( side1Blocked and 1 or 0 ) + ( side2Blocked and 1 or 0 ) + ( cornerBlocked and 1 or 0 )
	return MC_LIGHT_AO_FACTORS[blocked] or 1
end

local function lightmapFaceAOValues( bx, by, bz, faceIndex )
	local face = FACES[faceIndex]
	if not face or not face.c then return 1, 1, 1, 1 end
	local values = { 1, 1, 1, 1 }
	for cornerIndex = 1, 4 do
		local c = face.c[cornerIndex]
		if c then
			local slot = remapFaceCornerLightSlot( faceIndex, cornerIndex )
			values[slot] = minecraftSmoothCornerAOValuesForLightmap( bx, by, bz, faceIndex, c[1], c[2], c[3] )
		end
	end
	return values[1], values[2], values[3], values[4]
end

local function mcLightmapCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	faceCubic = faceCubic ~= false
	local sides = MC_LIGHTMAP_SIDE_OFFSETS[faceIndex]
	local face = FACES[faceIndex]
	local off = face and face.off
	if not sides or not off then
		local centerLight = packedLightCoordsAt( bx, by, bz, selfEmission )
		return centerLight, centerLight, centerLight, centerLight, 1, 1, 1, 1
	end

	local baseX, baseY, baseZ = faceSampleBaseCell( bx, by, bz, faceIndex, faceCubic )
	local s0x, s0y, s0z = offsetCell( baseX, baseY, baseZ, sides[1] )
	local s1x, s1y, s1z = offsetCell( baseX, baseY, baseZ, sides[2] )
	local s2x, s2y, s2z = offsetCell( baseX, baseY, baseZ, sides[3] )
	local s3x, s3y, s3z = offsetCell( baseX, baseY, baseZ, sides[4] )
	local light0 = packedLightCoordsAt( s0x, s0y, s0z, selfEmission )
	local light1 = packedLightCoordsAt( s1x, s1y, s1z, selfEmission )
	local light2 = packedLightCoordsAt( s2x, s2y, s2z, selfEmission )
	local light3 = packedLightCoordsAt( s3x, s3y, s3z, selfEmission )
	local translucent0 = isTranslucentForLightmap( s0x + off[1], s0y + off[2], s0z + off[3] )
	local translucent1 = isTranslucentForLightmap( s1x + off[1], s1y + off[2], s1z + off[3] )
	local translucent2 = isTranslucentForLightmap( s2x + off[1], s2y + off[2], s2z + off[3] )
	local translucent3 = isTranslucentForLightmap( s3x + off[1], s3y + off[2], s3z + off[3] )
	local lightCorner02
	if not translucent2 and not translucent0 then
		lightCorner02 = light0
	else
		local x, y, z = s0x + sides[3][1], s0y + sides[3][2], s0z + sides[3][3]
		lightCorner02 = packedLightCoordsAt( x, y, z, selfEmission )
	end
	local lightCorner03
	if not translucent3 and not translucent0 then
		lightCorner03 = light0
	else
		local x, y, z = s0x + sides[4][1], s0y + sides[4][2], s0z + sides[4][3]
		lightCorner03 = packedLightCoordsAt( x, y, z, selfEmission )
	end
	local lightCorner12
	if not translucent2 and not translucent1 then
		lightCorner12 = light0
	else
		local x, y, z = s1x + sides[3][1], s1y + sides[3][2], s1z + sides[3][3]
		lightCorner12 = packedLightCoordsAt( x, y, z, selfEmission )
	end
	local lightCorner13
	if not translucent3 and not translucent1 then
		lightCorner13 = light0
	else
		local x, y, z = s1x + sides[4][1], s1y + sides[4][2], s1z + sides[4][3]
		lightCorner13 = packedLightCoordsAt( x, y, z, selfEmission )
	end
	local lightCenter = lightCenterPackedCoords( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local tc1 = mcSmoothBlendLightCoords( light3, light0, lightCorner03, lightCenter )
	local tc2 = mcSmoothBlendLightCoords( light2, light0, lightCorner02, lightCenter )
	local tc3 = mcSmoothBlendLightCoords( light2, light1, lightCorner12, lightCenter )
	local tc4 = mcSmoothBlendLightCoords( light3, light1, lightCorner13, lightCenter )
	local ao1, ao2, ao3, ao4 = lightmapFaceAOValues( bx, by, bz, faceIndex )
	return tc1, tc2, tc3, tc4, ao1, ao2, ao3, ao4
end

local function faceVertexCornerIndex( faceIndex, cx, cy, cz )
	local function near( ax, ay, az, bx, by, bz )
		local dx, dy, dz = ax - bx, ay - by, az - bz
		return dx * dx + dy * dy + dz * dz
	end
	local corners = FACES[faceIndex] and FACES[faceIndex].c
	if not corners then return 1 end
	local bestIndex, bestDistance = 1, near( cx, cy, cz, corners[1][1], corners[1][2], corners[1][3] )
	for i = 2, 4 do
		local c = corners[i]
		local distance = near( cx, cy, cz, c[1], c[2], c[3] )
		if distance < bestDistance then
			bestIndex, bestDistance = i, distance
		end
	end
	return bestIndex
end

local function faceVertexLightSlot( faceIndex, cornerIndex )
	return remapFaceCornerLightSlot( faceIndex, cornerIndex )
end

local function smoothCornerPackedLightCoordsValues( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission, faceCubic )
	local tc1, tc2, tc3, tc4 = mcLightmapCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local slot = faceVertexLightSlot( faceIndex, faceVertexCornerIndex( faceIndex, cx0, cy0, cz0 ) )
	if slot == 1 then return tc1 elseif slot == 2 then return tc2 elseif slot == 3 then return tc3 end
	return tc4
end

local MC_LIGHTMAP_SIZE_DOWN = 1
local MC_LIGHTMAP_SIZE_UP = 2
local MC_LIGHTMAP_SIZE_NORTH = 3
local MC_LIGHTMAP_SIZE_SOUTH = 4
local MC_LIGHTMAP_SIZE_WEST = 5
local MC_LIGHTMAP_SIZE_EAST = 6
local MC_LIGHTMAP_SIZE_FLIP_DOWN = 7
local MC_LIGHTMAP_SIZE_FLIP_UP = 8
local MC_LIGHTMAP_SIZE_FLIP_NORTH = 9
local MC_LIGHTMAP_SIZE_FLIP_SOUTH = 10
local MC_LIGHTMAP_SIZE_FLIP_WEST = 11
local MC_LIGHTMAP_SIZE_FLIP_EAST = 12

local SD, SU = MC_LIGHTMAP_SIZE_DOWN, MC_LIGHTMAP_SIZE_UP
local SN, SS = MC_LIGHTMAP_SIZE_NORTH, MC_LIGHTMAP_SIZE_SOUTH
local SW, SE = MC_LIGHTMAP_SIZE_WEST, MC_LIGHTMAP_SIZE_EAST
local SFD, SFU = MC_LIGHTMAP_SIZE_FLIP_DOWN, MC_LIGHTMAP_SIZE_FLIP_UP
local SFN, SFS = MC_LIGHTMAP_SIZE_FLIP_NORTH, MC_LIGHTMAP_SIZE_FLIP_SOUTH
local SFW, SFE = MC_LIGHTMAP_SIZE_FLIP_WEST, MC_LIGHTMAP_SIZE_FLIP_EAST

local MC_LIGHTMAP_WEIGHT_INFO = {
	[MC.Face.BOTTOM] = {
		remap = { 1, 2, 3, 4 },
		weights = {
			{ SFW, SS, SFW, SFS, SW, SFS, SW, SS },
			{ SFW, SN, SFW, SFN, SW, SFN, SW, SN },
			{ SFE, SN, SFE, SFN, SE, SFN, SE, SN },
			{ SFE, SS, SFE, SFS, SE, SFS, SE, SS },
		},
	},
	[MC.Face.TOP] = {
		remap = { 3, 4, 1, 2 },
		weights = {
			{ SE, SS, SE, SFS, SFE, SFS, SFE, SS },
			{ SE, SN, SE, SFN, SFE, SFN, SFE, SN },
			{ SW, SN, SW, SFN, SFW, SFN, SFW, SN },
			{ SW, SS, SW, SFS, SFW, SFS, SFW, SS },
		},
	},
	[MC.Face.YN] = {
		remap = { 4, 1, 2, 3 },
		weights = {
			{ SU, SFW, SU, SW, SFU, SW, SFU, SFW },
			{ SU, SFE, SU, SE, SFU, SE, SFU, SFE },
			{ SD, SFE, SD, SE, SFD, SE, SFD, SFE },
			{ SD, SFW, SD, SW, SFD, SW, SFD, SFW },
		},
	},
	[MC.Face.YP] = {
		remap = { 1, 2, 3, 4 },
		weights = {
			{ SU, SFW, SFU, SFW, SFU, SW, SU, SW },
			{ SD, SFW, SFD, SFW, SFD, SW, SD, SW },
			{ SD, SFE, SFD, SFE, SFD, SE, SD, SE },
			{ SU, SFE, SFU, SFE, SFU, SE, SU, SE },
		},
	},
	[MC.Face.XN] = {
		remap = { 4, 1, 2, 3 },
		weights = {
			{ SU, SS, SU, SFS, SFU, SFS, SFU, SS },
			{ SU, SN, SU, SFN, SFU, SFN, SFU, SN },
			{ SD, SN, SD, SFN, SFD, SFN, SFD, SN },
			{ SD, SS, SD, SFS, SFD, SFS, SFD, SS },
		},
	},
	[MC.Face.XP] = {
		remap = { 2, 3, 4, 1 },
		weights = {
			{ SFD, SS, SFD, SFS, SD, SFS, SD, SS },
			{ SFD, SN, SFD, SFN, SD, SFN, SD, SN },
			{ SFU, SN, SFU, SFN, SU, SFN, SU, SN },
			{ SFU, SS, SFU, SFS, SU, SFS, SU, SS },
		},
	},
}

local function makeWeightedLightmapQuad( x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4, faceCubic )
	return {
		x1 = x1, y1 = y1, z1 = z1,
		x2 = x2, y2 = y2, z2 = z2,
		x3 = x3, y3 = y3, z3 = z3,
		x4 = x4, y4 = y4, z4 = z4,
		faceCubic = faceCubic ~= false,
		minX = math.min( x1, x2, x3, x4 ),
		maxX = math.max( x1, x2, x3, x4 ),
		minY = math.min( y1, y2, y3, y4 ),
		maxY = math.max( y1, y2, y3, y4 ),
		minZ = math.min( z1, z2, z3, z4 ),
		maxZ = math.max( z1, z2, z3, z4 ),
	}
end

local function quadFaceCubic( faceIndex, id, orient, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	if MC.BlockIsFullCube and id and MC.BlockIsFullCube( id, orient or 0 ) then return true end
	local eps = 0.0001
	local minX, maxX = math.min( x1, x2, x3, x4 ), math.max( x1, x2, x3, x4 )
	local minY, maxY = math.min( y1, y2, y3, y4 ), math.max( y1, y2, y3, y4 )
	local minZ, maxZ = math.min( z1, z2, z3, z4 ), math.max( z1, z2, z3, z4 )
	if faceIndex == MC.Face.TOP then return math.abs( minZ - maxZ ) <= eps and maxZ > 1 - eps end
	if faceIndex == MC.Face.BOTTOM then return math.abs( minZ - maxZ ) <= eps and minZ < eps end
	if faceIndex == MC.Face.XP then return math.abs( minX - maxX ) <= eps and maxX > 1 - eps end
	if faceIndex == MC.Face.XN then return math.abs( minX - maxX ) <= eps and minX < eps end
	if faceIndex == MC.Face.YP then return math.abs( minY - maxY ) <= eps and maxY > 1 - eps end
	if faceIndex == MC.Face.YN then return math.abs( minY - maxY ) <= eps and minY < eps end
	return true
end

local function lightmapFaceShapeValue( quad, sizeInfo )
	if sizeInfo == MC_LIGHTMAP_SIZE_DOWN then return quad.minZ end
	if sizeInfo == MC_LIGHTMAP_SIZE_UP then return quad.maxZ end
	if sizeInfo == MC_LIGHTMAP_SIZE_NORTH then return quad.minY end
	if sizeInfo == MC_LIGHTMAP_SIZE_SOUTH then return quad.maxY end
	if sizeInfo == MC_LIGHTMAP_SIZE_WEST then return quad.minX end
	if sizeInfo == MC_LIGHTMAP_SIZE_EAST then return quad.maxX end
	if sizeInfo == MC_LIGHTMAP_SIZE_FLIP_DOWN then return 1 - quad.minZ end
	if sizeInfo == MC_LIGHTMAP_SIZE_FLIP_UP then return 1 - quad.maxZ end
	if sizeInfo == MC_LIGHTMAP_SIZE_FLIP_NORTH then return 1 - quad.minY end
	if sizeInfo == MC_LIGHTMAP_SIZE_FLIP_SOUTH then return 1 - quad.maxY end
	if sizeInfo == MC_LIGHTMAP_SIZE_FLIP_WEST then return 1 - quad.minX end
	if sizeInfo == MC_LIGHTMAP_SIZE_FLIP_EAST then return 1 - quad.maxX end
	return 0
end

local function pointDistanceSquared( ax, ay, az, bx, by, bz )
	local dx, dy, dz = ax - bx, ay - by, az - bz
	return dx * dx + dy * dy + dz * dz
end

local function weightedQuadCornerIndex( quad, cx, cy, cz )
	local bestIndex, bestDistance = 1, pointDistanceSquared( cx, cy, cz, quad.x1, quad.y1, quad.z1 )
	local d2 = pointDistanceSquared( cx, cy, cz, quad.x2, quad.y2, quad.z2 )
	if d2 < bestDistance then bestIndex, bestDistance = 2, d2 end
	d2 = pointDistanceSquared( cx, cy, cz, quad.x3, quad.y3, quad.z3 )
	if d2 < bestDistance then bestIndex, bestDistance = 3, d2 end
	d2 = pointDistanceSquared( cx, cy, cz, quad.x4, quad.y4, quad.z4 )
	if d2 < bestDistance then bestIndex = 4 end
	return bestIndex
end

local function lightmapWeightSlotForCorner( info, cornerIndex )
	local remap = info and info.remap
	if not remap then return cornerIndex end
	for i = 1, 4 do
		if remap[i] == cornerIndex then return i end
	end
	return cornerIndex
end

local function faceQuadWeights( faceIndex, quad, cx, cy, cz )
	local info = MC_LIGHTMAP_WEIGHT_INFO[faceIndex]
	if not info then return 1, 0, 0, 0 end
	local cornerIndex = weightedQuadCornerIndex( quad, cx, cy, cz )
	local slot = lightmapWeightSlotForCorner( info, cornerIndex )
	local weights = info.weights[slot] or info.weights[1]
	return
		lightmapFaceShapeValue( quad, weights[1] ) * lightmapFaceShapeValue( quad, weights[2] ),
		lightmapFaceShapeValue( quad, weights[3] ) * lightmapFaceShapeValue( quad, weights[4] ),
		lightmapFaceShapeValue( quad, weights[5] ) * lightmapFaceShapeValue( quad, weights[6] ),
		lightmapFaceShapeValue( quad, weights[7] ) * lightmapFaceShapeValue( quad, weights[8] )
end

local function quadIsFacePartial( faceIndex, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	local partialEPS = 0.0001
	local minX = math.min( x1, x2, x3, x4 )
	local maxX = math.max( x1, x2, x3, x4 )
	local minY = math.min( y1, y2, y3, y4 )
	local maxY = math.max( y1, y2, y3, y4 )
	local minZ = math.min( z1, z2, z3, z4 )
	local maxZ = math.max( z1, z2, z3, z4 )
	if minX < -partialEPS or minY < -partialEPS or minZ < -partialEPS
	or maxX > 1 + partialEPS or maxY > 1 + partialEPS or maxZ > 1 + partialEPS then
		return false
	end
	if faceIndex == MC.Face.TOP or faceIndex == MC.Face.BOTTOM then
		return minX >= partialEPS or minY >= partialEPS or maxX <= 1 - partialEPS or maxY <= 1 - partialEPS
	elseif faceIndex == MC.Face.XP or faceIndex == MC.Face.XN then
		return minY >= partialEPS or minZ >= partialEPS or maxY <= 1 - partialEPS or maxZ <= 1 - partialEPS
	elseif faceIndex == MC.Face.YP or faceIndex == MC.Face.YN then
		return minX >= partialEPS or minZ >= partialEPS or maxX <= 1 - partialEPS or maxZ <= 1 - partialEPS
	end
	return false
end

local function weightedLightmapQuadForFace( faceIndex, faceCubic, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	if not quadIsFacePartial( faceIndex, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 ) then return nil end
	return makeWeightedLightmapQuad( x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4, faceCubic )
end

local function lightmapPacketSetCorner( packet, cornerIndex, smooth, shade, quadLightEmission )
	local u1, v1 = lightmapUVFromSmoothPacked( smooth, quadLightEmission )
	if cornerIndex == 1 then
		packet.u1_1, packet.v1_1, packet.shade1 = u1, v1, shade
	elseif cornerIndex == 2 then
		packet.u1_2, packet.v1_2, packet.shade2 = u1, v1, shade
	elseif cornerIndex == 3 then
		packet.u1_3, packet.v1_3, packet.shade3 = u1, v1, shade
	else
		packet.u1_4, packet.v1_4, packet.shade4 = u1, v1, shade
	end
end

local function lightmapPacketSetFullCorner( packet, cornerIndex, faceIndex, cx, cy, cz, quadLightEmission,
	coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
	local slot = faceVertexLightSlot( faceIndex, faceVertexCornerIndex( faceIndex, cx, cy, cz ) )
	if slot == 1 then
		lightmapPacketSetCorner( packet, cornerIndex, coords1, shade1, quadLightEmission )
	elseif slot == 2 then
		lightmapPacketSetCorner( packet, cornerIndex, coords2, shade2, quadLightEmission )
	elseif slot == 3 then
		lightmapPacketSetCorner( packet, cornerIndex, coords3, shade3, quadLightEmission )
	else
		lightmapPacketSetCorner( packet, cornerIndex, coords4, shade4, quadLightEmission )
	end
end

local function lightmapPacketSetWeightedCorner( packet, cornerIndex, faceIndex, quad, cx, cy, cz, quadLightEmission,
	coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
	local weight1, weight2, weight3, weight4 = faceQuadWeights( faceIndex, quad, cx, cy, cz )
	local smooth = smoothWeightedBlendLightCoords( coords1, coords2, coords3, coords4, weight1, weight2, weight3, weight4 )
	local shade = shade1 * weight1 + shade2 * weight2 + shade3 * weight3 + shade4 * weight4
	lightmapPacketSetCorner( packet, cornerIndex, smooth, shade, quadLightEmission )
end

local function lightmapFacePacketForQuad( bx, by, bz, faceIndex, selfEmission, faceCubic, quadLightEmission,
	x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	faceCubic = faceCubic ~= false
	quadLightEmission = clampLightLevel( quadLightEmission )
	local coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 = mcLightmapCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local weightedQuad = weightedLightmapQuadForFace( faceIndex, faceCubic, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	local packet = {
		weightedLightmapQuad = weightedQuad,
		faceCubic = faceCubic,
		weighted = weightedQuad ~= nil,
	}
	if weightedQuad then
		lightmapPacketSetWeightedCorner( packet, 1, faceIndex, weightedQuad, x1, y1, z1, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
		lightmapPacketSetWeightedCorner( packet, 2, faceIndex, weightedQuad, x2, y2, z2, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
		lightmapPacketSetWeightedCorner( packet, 3, faceIndex, weightedQuad, x3, y3, z3, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
		lightmapPacketSetWeightedCorner( packet, 4, faceIndex, weightedQuad, x4, y4, z4, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
	else
		lightmapPacketSetFullCorner( packet, 1, faceIndex, x1, y1, z1, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
		lightmapPacketSetFullCorner( packet, 2, faceIndex, x2, y2, z2, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
		lightmapPacketSetFullCorner( packet, 3, faceIndex, x3, y3, z3, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
		lightmapPacketSetFullCorner( packet, 4, faceIndex, x4, y4, z4, quadLightEmission, coords1, coords2, coords3, coords4, shade1, shade2, shade3, shade4 )
	end
	return packet
end

local function lightmapPacketWeightedQuad( packet )
	return packet and packet.weightedLightmapQuad or nil
end

local function lightmapPacketCornerUV( packet, cornerIndex )
	if not packet then return nil, nil end
	if cornerIndex == 1 then return packet.u1_1, packet.v1_1 end
	if cornerIndex == 2 then return packet.u1_2, packet.v1_2 end
	if cornerIndex == 3 then return packet.u1_3, packet.v1_3 end
	return packet.u1_4, packet.v1_4
end

local function lightmapPacketCornerShade( packet, cornerIndex )
	if not packet then return nil end
	if cornerIndex == 1 then return packet.shade1 end
	if cornerIndex == 2 then return packet.shade2 end
	if cornerIndex == 3 then return packet.shade3 end
	return packet.shade4
end

local function weightedFaceLightmapUVValues( bx, by, bz, faceIndex, quad, cx, cy, cz, selfEmission, quadLightEmission )
	local faceCubic = not quad or quad.faceCubic ~= false
	local coords1, coords2, coords3, coords4 = mcLightmapCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local weight1, weight2, weight3, weight4 = faceQuadWeights( faceIndex, quad, cx, cy, cz )
	local smooth = smoothWeightedBlendLightCoords( coords1, coords2, coords3, coords4, weight1, weight2, weight3, weight4 )
	return lightmapUVFromSmoothPacked( smooth, quadLightEmission )
end

local function smoothCornerLightmapUVFromMeta( meta )
	if not meta then return nil, nil end
	if meta.weightedLightmapQuad then
		return weightedFaceLightmapUVValues( meta.bx, meta.by, meta.bz, meta.faceIndex, meta.weightedLightmapQuad, meta.cx, meta.cy, meta.cz, meta.selfEmission, meta.quadLightEmission )
	end
	local smooth = smoothCornerPackedLightCoordsValues( meta.bx, meta.by, meta.bz, meta.faceIndex, meta.cx, meta.cy, meta.cz, meta.selfEmission, meta.faceCubic )
	return lightmapUVFromSmoothPacked( smooth, meta.quadLightEmission )
end

local function minecraftSmoothCornerShadeBrightnessValues( bx, by, bz, faceIndex, cx0, cy0, cz0, faceCubic )
	local _, _, _, _, shade1, shade2, shade3, shade4 = mcLightmapCornerState( bx, by, bz, faceIndex, 0, faceCubic )
	local slot = faceVertexLightSlot( faceIndex, faceVertexCornerIndex( faceIndex, cx0, cy0, cz0 ) )
	if slot == 1 then return shade1 elseif slot == 2 then return shade2 elseif slot == 3 then return shade3 end
	return shade4
end

local function weightedFaceShadeBrightnessValues( bx, by, bz, faceIndex, quad, cx, cy, cz )
	local faceCubic = not quad or quad.faceCubic ~= false
	local _, _, _, _, shade1, shade2, shade3, shade4 = mcLightmapCornerState( bx, by, bz, faceIndex, 0, faceCubic )
	local weight1, weight2, weight3, weight4 = faceQuadWeights( faceIndex, quad, cx, cy, cz )
	return shade1 * weight1 + shade2 * weight2 + shade3 * weight3 + shade4 * weight4
end


RM.smoothCornerLightmapUVFromMeta = smoothCornerLightmapUVFromMeta
RM.minecraftSmoothCornerShadeBrightnessValues = minecraftSmoothCornerShadeBrightnessValues
RM.weightedFaceShadeBrightnessValues = weightedFaceShadeBrightnessValues
RM.lightmapFacePacketForQuad = lightmapFacePacketForQuad
RM.lightmapPacketWeightedQuad = lightmapPacketWeightedQuad
RM.lightmapPacketCornerUV = lightmapPacketCornerUV
RM.lightmapPacketCornerShade = lightmapPacketCornerShade
RM.weightedLightmapQuadForFace = weightedLightmapQuadForFace
RM.makeWeightedLightmapQuad = makeWeightedLightmapQuad
RM.quadFaceCubic = quadFaceCubic
RM.quadIsFacePartial = quadIsFacePartial
RM.packedLightCoordsFromLevels = packedLightCoordsFromLevels
RM.packedLightCoordsAt = packedLightCoordsAt
RM.packedLightBlockLevel = packedLightBlockLevel
RM.packedLightSkyLevel = packedLightSkyLevel
RM.smoothPackedBlock = smoothPackedBlock
RM.smoothPackedSky = smoothPackedSky
RM.lightCoordsWithQuadEmission = lightCoordsWithQuadEmission
