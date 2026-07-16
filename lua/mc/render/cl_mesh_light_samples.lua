-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local FACES = C.FACES
local mathClamp, mathFloor = math.Clamp, math.floor
local bit_bor, bit_lshift, bit_band, bit_rshift = bit.bor, bit.lshift, bit.band, bit.rshift
local SH_TOP, SH_BOTTOM, SH_X, SH_Y = C.SH_TOP, C.SH_BOTTOM, C.SH_X, C.SH_Y
local cornerXYZ = RM.cornerXYZ
local cornerSampleOffsets = RM.cornerSampleOffsets
local clampLightLevel = RM.clampLightLevel
local sampleCacheKey

local MC_LIGHT_AO_FACTORS = {
	[0] = 1.00,
	[1] = 0.82,
	[2] = 0.68,
	[3] = 0.55,
}

local MC_LIGHT_BEST_AO_FACTORS = {
	[0] = 1.00,
	[1] = 0.90,
	[2] = 0.78,
	[3] = 0.66,
}

local MC_LIGHT_SHADER_AO_FACTORS = {
	[0] = 1.00,
	[1] = 0.94,
	[2] = 0.86,
	[3] = 0.74,
}

local function faceSampleBaseCell( bx, by, bz, faceIndex, faceCubic )
	if faceCubic then
		local face = FACES[faceIndex]
		local off = face and face.off
		if off then return bx + off[1], by + off[2], bz + off[3] end
	end
	return bx, by, bz
end

local function offsetCell( bx, by, bz, off )
	return bx + off[1], by + off[2], bz + off[3]
end

local function minecraftSmoothCornerSamplesValues( bx, by, bz, faceIndex, x, y, z, faceCubic )
	local x0, x1 = cornerSampleOffsets( x )
	local y0, y1 = cornerSampleOffsets( y )
	local z0, z1 = cornerSampleOffsets( z )
	local baseX, baseY, baseZ = faceSampleBaseCell( bx, by, bz, faceIndex, faceCubic ~= false )
	if faceIndex == MC.Face.TOP then
		return baseX + x0, baseY + y0, baseZ, baseX + x1, baseY + y0, baseZ, baseX + x0, baseY + y1, baseZ, baseX + x1, baseY + y1, baseZ
	elseif faceIndex == MC.Face.BOTTOM then
		return baseX + x0, baseY + y0, baseZ, baseX + x1, baseY + y0, baseZ, baseX + x0, baseY + y1, baseZ, baseX + x1, baseY + y1, baseZ
	elseif faceIndex == MC.Face.XP then
		return baseX, baseY + y0, baseZ + z0, baseX, baseY + y1, baseZ + z0, baseX, baseY + y0, baseZ + z1, baseX, baseY + y1, baseZ + z1
	elseif faceIndex == MC.Face.XN then
		return baseX, baseY + y0, baseZ + z0, baseX, baseY + y1, baseZ + z0, baseX, baseY + y0, baseZ + z1, baseX, baseY + y1, baseZ + z1
	elseif faceIndex == MC.Face.YP then
		return baseX + x0, baseY, baseZ + z0, baseX + x1, baseY, baseZ + z0, baseX + x0, baseY, baseZ + z1, baseX + x1, baseY, baseZ + z1
	elseif faceIndex == MC.Face.YN then
		return baseX + x0, baseY, baseZ + z0, baseX + x1, baseY, baseZ + z0, baseX + x0, baseY, baseZ + z1, baseX + x1, baseY, baseZ + z1
	end
	return bx, by, bz, bx, by, bz, bx, by, bz, bx, by, bz
end

local MeshLightSampleCache = {}
local MeshLightLevelCache = {}
local MeshAOSampleCache = {}
local MeshShadeBrightnessCache = {}
local MeshSmoothLightTranslucentCache = {}
local MeshSmoothLightCornerStateCache = {}
local MeshLightSampleHits, MeshLightSampleMisses = 0, 0
local MeshAOSampleHits, MeshAOSampleMisses = 0, 0
local MeshSampleBaseX, MeshSampleBaseY, MeshSampleBaseZ = 0, 0, 0
local MeshSampleLightingFn = nil
local MeshSampleAOFn = nil
local SAMPLE_CACHE_ORIGIN_PAD = 16
local SAMPLE_CACHE_AXIS_BITS = 6
local SAMPLE_CACHE_AXIS_SIZE = 64
local SAMPLE_CACHE_Z_SHIFT = SAMPLE_CACHE_AXIS_BITS * 2
local SAMPLE_CACHE_EXTRA_SHIFT = SAMPLE_CACHE_AXIS_BITS * 3

local function shadeRecolorIndex( shade )
	if shade == SH_TOP then return 1 end
	if shade == SH_BOTTOM then return 2 end
	if shade == SH_X then return 3 end
	if shade == SH_Y then return 4 end
	return 5
end

local function shadeIndexForFace( faceIndex )
	if faceIndex == MC.Face.TOP then return 1 end
	if faceIndex == MC.Face.BOTTOM then return 2 end
	if faceIndex == MC.Face.XP or faceIndex == MC.Face.XN then return 3 end
	if faceIndex == MC.Face.YP or faceIndex == MC.Face.YN then return 4 end
	return 5
end

local function shadeRGBAByIndex( shadeIndex )
	if shadeIndex == 1 then return 255, 255, 255, 255 end
	if shadeIndex == 2 then return 128, 128, 128, 255 end
	if shadeIndex == 3 then return 153, 153, 153, 255 end
	if shadeIndex == 4 then return 204, 204, 204, 255 end
	return 255, 255, 255, 255
end

local function cornerRecolorBits( cx, cy, cz )
	local bits = 0
	if ( cx or 0 ) > 0 then bits = bits + 1 end
	if ( cy or 0 ) > 0 then bits = bits + 2 end
	if ( cz or 0 ) > 0 then bits = bits + 4 end
	return bits
end

local function meshRecolorKey( shadeIndex, bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
	local emission = tonumber( selfEmission ) or 0
	return bit_bor(
		bit_band( bx or 0, 15 ),
		bit_lshift( bit_band( by or 0, 15 ), 4 ),
		bit_lshift( bit_band( bz or 0, 15 ), 8 ),
		bit_lshift( bit_band( faceIndex or 0, 7 ), 12 ),
		bit_lshift( shadeIndex or 5, 15 ),
		bit_lshift( cornerRecolorBits( cx, cy, cz ), 18 ),
		bit_lshift( bit_band( emission, 15 ), 21 )
	)
end

local function quantizedQuadCoord( value )
	return tostring( mathFloor( ( tonumber( value ) or 0 ) * 16 + 0.5 ) )
end

local function weightedQuadRecolorKey( baseKey, quad, quadLightEmission )
	local emission = clampLightLevel( quadLightEmission )
	if not quad and emission <= 0 then return baseKey end
	local key = tostring( baseKey )
	if emission > 0 then key = key .. ":qe" .. emission end
	if not quad then return key end
	return key
		.. ":" .. quantizedQuadCoord( quad.x1 ) .. "," .. quantizedQuadCoord( quad.y1 ) .. "," .. quantizedQuadCoord( quad.z1 )
		.. ":" .. quantizedQuadCoord( quad.x2 ) .. "," .. quantizedQuadCoord( quad.y2 ) .. "," .. quantizedQuadCoord( quad.z2 )
		.. ":" .. quantizedQuadCoord( quad.x3 ) .. "," .. quantizedQuadCoord( quad.y3 ) .. "," .. quantizedQuadCoord( quad.z3 )
		.. ":" .. quantizedQuadCoord( quad.x4 ) .. "," .. quantizedQuadCoord( quad.y4 ) .. "," .. quantizedQuadCoord( quad.z4 )
end

local function resetMeshLightingSampleCaches()
	MeshLightSampleCache = {}
	MeshLightLevelCache = {}
	MeshAOSampleCache = {}
	MeshShadeBrightnessCache = {}
	MeshSmoothLightTranslucentCache = {}
	MeshSmoothLightCornerStateCache = {}
	MeshFullCubeColorCache = {}
	MeshLightSampleHits, MeshLightSampleMisses = 0, 0
	MeshAOSampleHits, MeshAOSampleMisses = 0, 0
	MeshSampleLightingFn = MC.SampleLighting
	MeshSampleAOFn = MC.SampleAmbientOcclusion
	if RM.resetMeshColorLightingCaches then RM.resetMeshColorLightingCaches() end
end

local function fullCubeColorCacheKey( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
	local x = bx - MeshSampleBaseX
	local y = by - MeshSampleBaseY
	local z = bz - MeshSampleBaseZ
	if x < 0 or x >= SAMPLE_CACHE_AXIS_SIZE
	or y < 0 or y >= SAMPLE_CACHE_AXIS_SIZE
	or z < 0 or z >= SAMPLE_CACHE_AXIS_SIZE then
		return nil
	end
	local cornerBits = 0
	if cx > 0 then cornerBits = cornerBits + 1 end
	if cy > 0 then cornerBits = cornerBits + 2 end
	if cz > 0 then cornerBits = cornerBits + 4 end

	return bit_bor(
		x,
		bit_lshift( y, SAMPLE_CACHE_AXIS_BITS ),
		bit_lshift( z, SAMPLE_CACHE_Z_SHIFT ),
		bit_lshift( bit_band( faceIndex or 0, 7 ), SAMPLE_CACHE_EXTRA_SHIFT ),
		bit_lshift( cornerBits, SAMPLE_CACHE_EXTRA_SHIFT + 3 ),
		bit_lshift( bit_band( selfEmission or 0, 15 ), SAMPLE_CACHE_EXTRA_SHIFT + 6 )
	)
end

local function setMeshSampleCacheOrigin( bx, by, bz )
	MeshSampleBaseX = ( bx or 0 ) - SAMPLE_CACHE_ORIGIN_PAD
	MeshSampleBaseY = ( by or 0 ) - SAMPLE_CACHE_ORIGIN_PAD
	MeshSampleBaseZ = ( bz or 0 ) - SAMPLE_CACHE_ORIGIN_PAD
end

function sampleCacheKey( sx, sy, sz, extra )
	local x = math.floor( sx - MeshSampleBaseX )
	local y = math.floor( sy - MeshSampleBaseY )
	local z = math.floor( sz - MeshSampleBaseZ )
	extra = math.floor( tonumber( extra ) or 0 )

	if x < 0 or x >= SAMPLE_CACHE_AXIS_SIZE
	or y < 0 or y >= SAMPLE_CACHE_AXIS_SIZE
	or z < 0 or z >= SAMPLE_CACHE_AXIS_SIZE
	or extra < 0 or extra >= SAMPLE_CACHE_AXIS_SIZE then
		return nil
	end

	return bit_bor( x, bit_lshift( y, SAMPLE_CACHE_AXIS_BITS ), bit_lshift( z, SAMPLE_CACHE_Z_SHIFT ), bit_lshift( extra, SAMPLE_CACHE_EXTRA_SHIFT ) )
end

local function cachedMeshLightingSample( sx, sy, sz, selfEmission )
	local sampleLighting = MeshSampleLightingFn
	if not sampleLighting then return 1 end
	local key = sampleCacheKey( sx, sy, sz, selfEmission )
	if key ~= nil then
		local cached = MeshLightSampleCache[key]
		if cached ~= nil then
			MeshLightSampleHits = MeshLightSampleHits + 1
			return cached
		end
	end
	MeshLightSampleMisses = MeshLightSampleMisses + 1
	local brightness = sampleLighting( sx, sy, sz, selfEmission )
	if key ~= nil then MeshLightSampleCache[key] = brightness end
	return brightness
end

local function cachedMeshLightLevelsSample( sx, sy, sz, selfEmission )
	local sampleLighting = MeshSampleLightingFn
	if not sampleLighting then return 15, 15 end
	local key = sampleCacheKey( sx, sy, sz, selfEmission )
	if key ~= nil then
		local cached = MeshLightLevelCache[key]
		if cached ~= nil then
			MeshLightSampleHits = MeshLightSampleHits + 1
			return bit_band( cached, 15 ), bit_band( mathFloor( cached / 16 ), 15 )
		end
	end
	MeshLightSampleMisses = MeshLightSampleMisses + 1
	local _, level, block, sky = sampleLighting( sx, sy, sz, selfEmission )
	local emission = clampLightLevel( selfEmission )
	block = math.max( clampLightLevel( block or level ), emission )
	sky = clampLightLevel( sky )
	local packed = block + sky * 16
	if key ~= nil then MeshLightLevelCache[key] = packed end
	return block, sky
end

local function blockLightEmissionAt( sx, sy, sz )
	if not MC.GetBlockState or not MC.BlockLightEmissionForState then return 0 end
	local bx, by, bz = mathFloor( sx ), mathFloor( sy ), mathFloor( sz )
	local stateId = MC.GetBlockState( bx, by, bz )
	return MC.BlockLightEmissionForState( stateId, bx, by, bz ) or 0
end

local function cachedMeshAOSample( sx, sy, sz )
	local sampleAO = MeshSampleAOFn
	if not sampleAO then return false end
	local key = sampleCacheKey( sx, sy, sz )
	if key ~= nil then
		local cached = MeshAOSampleCache[key]
		if cached ~= nil then
			MeshAOSampleHits = MeshAOSampleHits + 1
			return cached
		end
	end
	MeshAOSampleMisses = MeshAOSampleMisses + 1
	local sample = sampleAO( sx, sy, sz )
	local blocked = sample == true or sample == 1
	if key ~= nil then MeshAOSampleCache[key] = blocked end
	return blocked
end

local function sampleCacheKeyFast( sx, sy, sz, extra )
	local x = sx - MeshSampleBaseX
	local y = sy - MeshSampleBaseY
	local z = sz - MeshSampleBaseZ
	extra = extra or 0

	if x < 0 or x >= SAMPLE_CACHE_AXIS_SIZE
	or y < 0 or y >= SAMPLE_CACHE_AXIS_SIZE
	or z < 0 or z >= SAMPLE_CACHE_AXIS_SIZE
	or extra < 0 or extra >= SAMPLE_CACHE_AXIS_SIZE then
		return nil
	end

	return bit_bor( x, bit_lshift( y, SAMPLE_CACHE_AXIS_BITS ), bit_lshift( z, SAMPLE_CACHE_Z_SHIFT ), bit_lshift( extra, SAMPLE_CACHE_EXTRA_SHIFT ) )
end

local function cachedMeshLightingSampleFast( sx, sy, sz, selfEmission )
	local sampleLighting = MeshSampleLightingFn
	if not sampleLighting then return 1 end
	local key = sampleCacheKeyFast( sx, sy, sz, selfEmission )
	if key ~= nil then
		local cached = MeshLightSampleCache[key]
		if cached ~= nil then
			MeshLightSampleHits = MeshLightSampleHits + 1
			return cached
		end
	end
	MeshLightSampleMisses = MeshLightSampleMisses + 1
	local brightness = sampleLighting( sx, sy, sz, selfEmission )
	if key ~= nil then MeshLightSampleCache[key] = brightness end
	return brightness or 1
end

local function cachedMeshAOSampleFast( sx, sy, sz )
	local sampleAO = MeshSampleAOFn
	if not sampleAO then return false end
	local key = sampleCacheKeyFast( sx, sy, sz, 0 )
	if key ~= nil then
		local cached = MeshAOSampleCache[key]
		if cached ~= nil then
			MeshAOSampleHits = MeshAOSampleHits + 1
			return cached
		end
	end
	MeshAOSampleMisses = MeshAOSampleMisses + 1
	local sample = sampleAO( sx, sy, sz )
	local blocked = sample == true or sample == 1
	if key ~= nil then MeshAOSampleCache[key] = blocked end
	return blocked
end

local function minecraftShadeBrightnessForState( stateId, bx, by, bz )
	if stateId == nil or stateId == 0 then return 1 end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
	local block = MC.Blocks and MC.Blocks[id]
	if block and block.shadeBrightness ~= nil then
		return mathClamp( tonumber( block.shadeBrightness ) or 1, 0, 1 )
	end
	if MC.IsTranslucentBlockState and MC.IsTranslucentBlockState( stateId, bx, by, bz ) then return 1 end
	if MC.BlockHasCollisionForState and not MC.BlockHasCollisionForState( stateId, bx, by, bz ) then return 1 end
	if MC.BlockIsFullCubeForState then return MC.BlockIsFullCubeForState( stateId, bx, by, bz ) and 0.2 or 1 end
	if block and block.shape then return 1 end
	return 0.2
end

local function minecraftShadeBrightnessSample( sx, sy, sz )
	local key = sampleCacheKey( sx, sy, sz, 0 )
	if key ~= nil then
		local cached = MeshShadeBrightnessCache[key]
		if cached ~= nil then return cached end
	end
	local bx, by, bz = mathFloor( sx ), mathFloor( sy ), mathFloor( sz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	local shadeBrightness = minecraftShadeBrightnessForState( stateId, bx, by, bz )
	if key ~= nil then MeshShadeBrightnessCache[key] = shadeBrightness end
	return shadeBrightness
end

local function solidRenderForSmoothLight( stateId, bx, by, bz )
	if stateId == nil or stateId == 0 then return false end
	if MC.IsTranslucentBlockState and MC.IsTranslucentBlockState( stateId, bx, by, bz ) then return false end
	if MC.BlockHasCollisionForState and not MC.BlockHasCollisionForState( stateId, bx, by, bz ) then return false end
	return MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true or false
end

local function translucentForSmoothLight( bx, by, bz )
	local key = sampleCacheKey( bx, by, bz, 0 )
	if key ~= nil then
		local cached = MeshSmoothLightTranslucentCache[key]
		if cached ~= nil then return cached end
	end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	local translucent = not solidRenderForSmoothLight( stateId, bx, by, bz )
	if key ~= nil then MeshSmoothLightTranslucentCache[key] = translucent end
	return translucent
end

local function packedSmoothLightFromLevels( block, sky )
	return bit_bor( bit_lshift( clampLightLevel( block ), 4 ), bit_lshift( clampLightLevel( sky ), 20 ) )
end

local function packedSmoothLightAt( sx, sy, sz, selfEmission )
	local block, sky = cachedMeshLightLevelsSample( sx, sy, sz, math.max( blockLightEmissionAt( sx, sy, sz ), clampLightLevel( selfEmission ) ) )
	return packedSmoothLightFromLevels( block, sky )
end

local function packedSmoothLightBlockLevel( packed )
	return bit_band( bit_rshift( packed or 0, 4 ), 15 )
end

local function packedSmoothLightSkyLevel( packed )
	return bit_band( bit_rshift( packed or 0, 20 ), 15 )
end

local function smoothPackedBlock( packed )
	return bit_band( packed or 0, 0xFF )
end

local function smoothPackedSky( packed )
	return bit_band( bit_rshift( packed or 0, 16 ), 0xFF )
end

local SMOOTH_LIGHT_PACK_SKY_MASK = 0xFF0000
local SMOOTH_LIGHT_PACK_MASK = 0xFF00FF

local function blendSmoothPackedLight( neighbor1, neighbor2, neighbor3, center )
	neighbor1 = neighbor1 or 0
	neighbor2 = neighbor2 or 0
	neighbor3 = neighbor3 or 0
	center = center or 0
	if packedSmoothLightSkyLevel( center ) > 2 or packedSmoothLightBlockLevel( center ) > 2 then
		if neighbor1 == 0 then
			neighbor1 = center
		elseif packedSmoothLightSkyLevel( neighbor1 ) == 0 then
			neighbor1 = bit_bor( neighbor1, bit_band( center, SMOOTH_LIGHT_PACK_SKY_MASK ) )
		end
		if neighbor2 == 0 then
			neighbor2 = center
		elseif packedSmoothLightSkyLevel( neighbor2 ) == 0 then
			neighbor2 = bit_bor( neighbor2, bit_band( center, SMOOTH_LIGHT_PACK_SKY_MASK ) )
		end
		if neighbor3 == 0 then
			neighbor3 = center
		elseif packedSmoothLightSkyLevel( neighbor3 ) == 0 then
			neighbor3 = bit_bor( neighbor3, bit_band( center, SMOOTH_LIGHT_PACK_SKY_MASK ) )
		end
	end
	return bit_band( bit_rshift( neighbor1 + neighbor2 + neighbor3 + center, 2 ), SMOOTH_LIGHT_PACK_MASK )
end

local function smoothLightCenterPacked( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local face = FACES[faceIndex]
	local off = face and face.off
	if not off then return packedSmoothLightAt( bx, by, bz, selfEmission ) end
	local nbx, nby, nbz = bx + off[1], by + off[2], bz + off[3]
	if faceCubic then return packedSmoothLightAt( nbx, nby, nbz, selfEmission ) end
	local stateId = MC.GetBlockState and MC.GetBlockState( nbx, nby, nbz ) or 0
	if not solidRenderForSmoothLight( stateId, nbx, nby, nbz ) then
		return packedSmoothLightAt( nbx, nby, nbz, selfEmission )
	end
	return packedSmoothLightAt( bx, by, bz, selfEmission )
end

local function smoothLightSingleCornerState( baseX, baseY, baseZ, faceIndex, cx, cy, cz, selfEmission, offX, offY, offZ, lightCenter, shadeCenter )
	local ax, ay, az, bx2, by2, bz2, dx, dy, dz
	if faceIndex == MC.Face.TOP or faceIndex == MC.Face.BOTTOM then
		local xs = cx <= 0 and -1 or 1
		local ys = cy <= 0 and -1 or 1
		ax, ay, az = baseX + xs, baseY, baseZ
		bx2, by2, bz2 = baseX, baseY + ys, baseZ
		dx, dy, dz = baseX + xs, baseY + ys, baseZ
	elseif faceIndex == MC.Face.XP or faceIndex == MC.Face.XN then
		local ys = cy <= 0 and -1 or 1
		local zs = cz <= 0 and -1 or 1
		ax, ay, az = baseX, baseY + ys, baseZ
		bx2, by2, bz2 = baseX, baseY, baseZ + zs
		dx, dy, dz = baseX, baseY + ys, baseZ + zs
	else
		local xs = cx <= 0 and -1 or 1
		local zs = cz <= 0 and -1 or 1
		ax, ay, az = baseX + xs, baseY, baseZ
		bx2, by2, bz2 = baseX, baseY, baseZ + zs
		dx, dy, dz = baseX + xs, baseY, baseZ + zs
	end

	local lightA = packedSmoothLightAt( ax, ay, az, selfEmission )
	local lightB = packedSmoothLightAt( bx2, by2, bz2, selfEmission )
	local shadeA = minecraftShadeBrightnessSample( ax, ay, az )
	local shadeB = minecraftShadeBrightnessSample( bx2, by2, bz2 )
	local lightD, shadeD
	if not translucentForSmoothLight( ax + offX, ay + offY, az + offZ )
	and not translucentForSmoothLight( bx2 + offX, by2 + offY, bz2 + offZ ) then
		lightD = lightA
		shadeD = shadeA
	else
		lightD = packedSmoothLightAt( dx, dy, dz, selfEmission )
		shadeD = minecraftShadeBrightnessSample( dx, dy, dz )
	end
	return blendSmoothPackedLight( lightA, lightB, lightD, lightCenter ),
		( shadeA + shadeB + shadeD + shadeCenter ) * 0.25
end

local function smoothLightCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	faceCubic = faceCubic ~= false
	local face = FACES[faceIndex]
	local off = face and face.off
	local corners = face and face.c
	if not corners or not off then
		local centerLight = packedSmoothLightAt( bx, by, bz, selfEmission )
		return centerLight, centerLight, centerLight, centerLight, 1, 1, 1, 1
	end

	local baseX, baseY, baseZ = faceSampleBaseCell( bx, by, bz, faceIndex, faceCubic )
	local lightCenter = smoothLightCenterPacked( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local shadeCenter = minecraftShadeBrightnessSample( baseX, baseY, baseZ )
	local offX, offY, offZ = off[1], off[2], off[3]
	local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
	local l1, s1 = smoothLightSingleCornerState( baseX, baseY, baseZ, faceIndex, c1[1], c1[2], c1[3], selfEmission, offX, offY, offZ, lightCenter, shadeCenter )
	local l2, s2 = smoothLightSingleCornerState( baseX, baseY, baseZ, faceIndex, c2[1], c2[2], c2[3], selfEmission, offX, offY, offZ, lightCenter, shadeCenter )
	local l3, s3 = smoothLightSingleCornerState( baseX, baseY, baseZ, faceIndex, c3[1], c3[2], c3[3], selfEmission, offX, offY, offZ, lightCenter, shadeCenter )
	local l4, s4 = smoothLightSingleCornerState( baseX, baseY, baseZ, faceIndex, c4[1], c4[2], c4[3], selfEmission, offX, offY, offZ, lightCenter, shadeCenter )
	return
		l1, l2, l3, l4,
		s1, s2, s3, s4
end

local function smoothLightCornerStateCached( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local subKey = ( faceIndex or 0 ) + ( faceCubic ~= false and 0 or 8 ) + clampLightLevel( selfEmission ) * 16
	local baseKey = sampleCacheKeyFast( bx, by, bz, 0 )
	if baseKey == nil then
		return smoothLightCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	end
	local key = baseKey * 4096 + subKey
	local cached = MeshSmoothLightCornerStateCache[key]
	if cached then return cached[1], cached[2], cached[3], cached[4], cached[5], cached[6], cached[7], cached[8] end
	local l1, l2, l3, l4, s1, s2, s3, s4 = smoothLightCornerState( bx, by, bz, faceIndex, selfEmission, faceCubic )
	MeshSmoothLightCornerStateCache[key] = { l1, l2, l3, l4, s1, s2, s3, s4 }
	return l1, l2, l3, l4, s1, s2, s3, s4
end

local function faceVertexCornerIndex( faceIndex, cx, cy, cz )
	local corners = FACES[faceIndex] and FACES[faceIndex].c
	if not corners then return 1 end
	local c = corners[1]
	local dx, dy, dz = cx - c[1], cy - c[2], cz - c[3]
	local bestIndex, bestDistance = 1, dx * dx + dy * dy + dz * dz
	for i = 2, 4 do
		c = corners[i]
		dx, dy, dz = cx - c[1], cy - c[2], cz - c[3]
		local distance = dx * dx + dy * dy + dz * dz
		if distance < bestDistance then
			bestIndex, bestDistance = i, distance
		end
	end
	return bestIndex
end

local function smoothSlotForFaceVertex( faceIndex, cx, cy, cz )
	return faceVertexCornerIndex( faceIndex, cx, cy, cz )
end

local function renderedBrightnessFromSmoothPacked( packed, selfEmission )
	local block = ( smoothPackedBlock( packed ) or 0 ) / 16
	local sky = ( smoothPackedSky( packed ) or 0 ) / 16
	local level = math.max( block, sky, clampLightLevel( selfEmission ) )
	local cv = MC.LightAmbientMin
	local ambient = mathClamp( cv and cv.GetFloat and cv:GetFloat() or 0, 0, 1 )
	return mathClamp( ambient + ( 1 - ambient ) * ( level / 15 ), 0, 1 )
end

local function smoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission, faceCubic )
	local l1, l2, l3, l4 = smoothLightCornerStateCached( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local slot = smoothSlotForFaceVertex( faceIndex, cx, cy, cz )
	if slot == 1 then return renderedBrightnessFromSmoothPacked( l1, selfEmission )
	elseif slot == 2 then return renderedBrightnessFromSmoothPacked( l2, selfEmission )
	elseif slot == 3 then return renderedBrightnessFromSmoothPacked( l3, selfEmission ) end
	return renderedBrightnessFromSmoothPacked( l4, selfEmission )
end

local function smoothCornerBrightnessPacketValues( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local l1, l2, l3, l4 = smoothLightCornerStateCached( bx, by, bz, faceIndex, selfEmission, faceCubic )
	return
		renderedBrightnessFromSmoothPacked( l1, selfEmission ),
		renderedBrightnessFromSmoothPacked( l2, selfEmission ),
		renderedBrightnessFromSmoothPacked( l3, selfEmission ),
		renderedBrightnessFromSmoothPacked( l4, selfEmission )
end

local function smoothCornerShadeBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission, faceCubic )
	local _, _, _, _, s1, s2, s3, s4 = smoothLightCornerStateCached( bx, by, bz, faceIndex, selfEmission, faceCubic )
	local slot = smoothSlotForFaceVertex( faceIndex, cx, cy, cz )
	if slot == 1 then return s1 elseif slot == 2 then return s2 elseif slot == 3 then return s3 end
	return s4
end

local function noteMeshLightingCacheStats()
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastMeshLightCacheHits = MeshLightSampleHits
	stats.lastMeshLightCacheMisses = MeshLightSampleMisses
	stats.lastMeshAOCacheHits = MeshAOSampleHits
	stats.lastMeshAOCacheMisses = MeshAOSampleMisses
end

local function minecraftSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission )
	return smoothCornerBrightnessValues( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission, true )
end

local function minecraftSmoothCornerShadeBrightnessValues( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission, faceCubic )
	return smoothCornerShadeBrightnessValues( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission, faceCubic )
end

local function minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local cx, cy, cz = cornerXYZ( cn )
	return minecraftSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
end

RM.MC_LIGHT_AO_FACTORS = MC_LIGHT_AO_FACTORS
RM.MC_LIGHT_BEST_AO_FACTORS = MC_LIGHT_BEST_AO_FACTORS
RM.MC_LIGHT_SHADER_AO_FACTORS = MC_LIGHT_SHADER_AO_FACTORS
RM.faceSampleBaseCell = faceSampleBaseCell
RM.offsetCell = offsetCell
RM.minecraftSmoothCornerSamplesValues = minecraftSmoothCornerSamplesValues
RM.shadeRecolorIndex = shadeRecolorIndex
RM.shadeIndexForFace = shadeIndexForFace
RM.shadeRGBAByIndex = shadeRGBAByIndex
RM.cornerRecolorBits = cornerRecolorBits
RM.meshRecolorKey = meshRecolorKey
RM.quantizedQuadCoord = quantizedQuadCoord
RM.weightedQuadRecolorKey = weightedQuadRecolorKey
RM.resetMeshLightingSampleCaches = resetMeshLightingSampleCaches
RM.fullCubeColorCacheKey = fullCubeColorCacheKey
RM.setMeshSampleCacheOrigin = setMeshSampleCacheOrigin
RM.sampleCacheKey = sampleCacheKey
RM.cachedMeshLightingSample = cachedMeshLightingSample
RM.cachedMeshLightLevelsSample = cachedMeshLightLevelsSample
RM.blockLightEmissionAt = blockLightEmissionAt
RM.cachedMeshAOSample = cachedMeshAOSample
RM.sampleCacheKeyFast = sampleCacheKeyFast
RM.cachedMeshLightingSampleFast = cachedMeshLightingSampleFast
RM.cachedMeshAOSampleFast = cachedMeshAOSampleFast
RM.minecraftShadeBrightnessForState = minecraftShadeBrightnessForState
RM.minecraftShadeBrightnessSample = minecraftShadeBrightnessSample
RM.noteMeshLightingCacheStats = noteMeshLightingCacheStats
RM.minecraftSmoothCornerBrightnessValues = minecraftSmoothCornerBrightnessValues
RM.minecraftSmoothCornerBrightnessPacketValues = smoothCornerBrightnessPacketValues
RM.minecraftSmoothCornerShadeBrightnessValues = minecraftSmoothCornerShadeBrightnessValues
RM.minecraftSmoothCornerBrightness = minecraftSmoothCornerBrightness
