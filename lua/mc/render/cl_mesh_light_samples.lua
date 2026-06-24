-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local FACES = C.FACES
local mathClamp, mathFloor = math.Clamp, math.floor
local cornerSampleOffsets = RM.cornerSampleOffsets
local clampLightLevel = RM.clampLightLevel

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
local function isSolidRenderForLightmap( id, orient )
	if id == nil or id == 0 then return false end
	local block = MC.Blocks and MC.Blocks[id]
	if block and ( block.transparent == true or block.solid == false ) then return false end
	if MC.BlockIsFullCube then return MC.BlockIsFullCube( id, orient ) == true end
	if block and block.shape then return false end
	return true
end

local function isTranslucentForLightmap( bx, by, bz )
	local id = MC.GetBlock and MC.GetBlock( bx, by, bz ) or 0
	local orient = id ~= 0 and MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return not isSolidRenderForLightmap( id, orient )
end

local function faceSampleBaseCell( bx, by, bz, faceIndex, faceCubic )
	if faceCubic then
		local face = FACES[faceIndex]
		local off = face and face.off
		if off then return bx + off[1], by + off[2], bz + off[3] end
	end
	return bx, by, bz
end

local MC_LIGHTMAP_SIDE_OFFSETS = {
	[MC.Face.BOTTOM] = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 } },
	[MC.Face.TOP] = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 } },
	[MC.Face.YN] = { { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 } },
	[MC.Face.YP] = { { -1, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 }, { 0, 0, 1 } },
	[MC.Face.XN] = { { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 }, { 0, 1, 0 } },
	[MC.Face.XP] = { { 0, 0, -1 }, { 0, 0, 1 }, { 0, -1, 0 }, { 0, 1, 0 } },
}

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
local bit_bor, bit_lshift, bit_band = bit.bor, bit.lshift, bit.band

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
	local key = tostring( baseKey )
	local emission = clampLightLevel( quadLightEmission )
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
	MeshFullCubeColorCache = {}
	MeshLightSampleHits, MeshLightSampleMisses = 0, 0
	MeshAOSampleHits, MeshAOSampleMisses = 0, 0
	MeshShaderDaylightFactor = nil
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

local function sampleCacheKey( sx, sy, sz, extra )
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
	if not MC.GetBlock or not MC.BlockLightEmission then return 0 end
	local id = MC.GetBlock( mathFloor( sx ), mathFloor( sy ), mathFloor( sz ) )
	return MC.BlockLightEmission( id ) or 0
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

local function minecraftShadeBrightnessForBlock( id, orient )
	if id == nil or id == 0 then return 1 end
	local block = MC.Blocks and MC.Blocks[id]
	if block and block.shadeBrightness ~= nil then
		return mathClamp( tonumber( block.shadeBrightness ) or 1, 0, 1 )
	end
	if block and ( block.transparent == true or block.solid == false ) then return 1 end
	if MC.BlockIsFullCube then
		return MC.BlockIsFullCube( id, orient ) and 0.2 or 1
	end
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
	local id = MC.GetBlock and MC.GetBlock( bx, by, bz ) or 0
	local orient = id ~= 0 and MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	local shadeBrightness = minecraftShadeBrightnessForBlock( id, orient )
	if key ~= nil then MeshShadeBrightnessCache[key] = shadeBrightness end
	return shadeBrightness
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
	local ax, ay, az, bx2, by2, bz2, cx, cy, cz, dx, dy, dz = minecraftSmoothCornerSamplesValues( bx, by, bz, faceIndex, cx0, cy0, cz0 )
	local a = tonumber( cachedMeshLightingSample( ax, ay, az, selfEmission ) ) or 1
	local b = tonumber( cachedMeshLightingSample( bx2, by2, bz2, selfEmission ) ) or 1
	local c = tonumber( cachedMeshLightingSample( cx, cy, cz, selfEmission ) ) or 1
	local d = tonumber( cachedMeshLightingSample( dx, dy, dz, selfEmission ) ) or 1
	return ( a + b + c + d ) * 0.25
end

local function minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local cx, cy, cz = cornerXYZ( cn )
	return minecraftSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
end

RM.MC_LIGHT_AO_FACTORS = MC_LIGHT_AO_FACTORS
RM.MC_LIGHT_BEST_AO_FACTORS = MC_LIGHT_BEST_AO_FACTORS
RM.MC_LIGHT_SHADER_AO_FACTORS = MC_LIGHT_SHADER_AO_FACTORS
RM.isSolidRenderForLightmap = isSolidRenderForLightmap
RM.isTranslucentForLightmap = isTranslucentForLightmap
RM.faceSampleBaseCell = faceSampleBaseCell
RM.MC_LIGHTMAP_SIDE_OFFSETS = MC_LIGHTMAP_SIDE_OFFSETS
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
RM.minecraftShadeBrightnessForBlock = minecraftShadeBrightnessForBlock
RM.minecraftShadeBrightnessSample = minecraftShadeBrightnessSample
RM.noteMeshLightingCacheStats = noteMeshLightingCacheStats
RM.minecraftSmoothCornerBrightnessValues = minecraftSmoothCornerBrightnessValues
RM.minecraftSmoothCornerBrightness = minecraftSmoothCornerBrightness
