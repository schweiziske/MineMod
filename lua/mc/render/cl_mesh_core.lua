-- Render materials, lighting helpers, mesh construction, and light-only mesh updates.
--[[----------------------------------------------------------------------------
	MC : client rendering

	Builds IMeshes per chunk from the voxel store with hidden-face culling and
	Minecraft-style directional face shading. Each chunk gets an opaque/cutout
	mesh list plus, when it contains translucent blocks, a separate translucent
	mesh list; both draw from PostDraw*Renderables hooks.
------------------------------------------------------------------------------]]

MC = MC or {}
if MC.ClientRenderLoaded and MC.FreeAllMeshes then
	MC.FreeAllMeshes()
end
MC.ClientRenderLoaded = true

local BS  = MC.BS
local CS  = MC.CS
local CH  = MC.CH
local CS2 = CS * CS
local RENDER_SECTION_SIZE = 8
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local RENDER_SECTIONS_Z = math.ceil( MC.CH / RENDER_SECTION_SIZE )

if MC.GeneratedAtlas then
	MC.Atlas.COLS = MC.GeneratedAtlas.COLS or MC.Atlas.COLS
	MC.Atlas.ROWS = MC.GeneratedAtlas.ROWS or MC.Atlas.ROWS
	MC.Atlas.TILE = MC.GeneratedAtlas.TILE or MC.Atlas.TILE
	MC.Atlas.PAD = MC.GeneratedAtlas.PAD or MC.Atlas.PAD
	MC.Atlas.STRIDE = MC.GeneratedAtlas.STRIDE or MC.Atlas.STRIDE
	MC.Atlas.MATERIAL = MC.GeneratedAtlas.MATERIAL or MC.Atlas.MATERIAL
	MC.Atlas.MATERIAL_TRANSLUCENT = MC.GeneratedAtlas.MATERIAL_TRANSLUCENT or MC.Atlas.MATERIAL_TRANSLUCENT
	MC.Atlas.W = MC.GeneratedAtlas.W or MC.Atlas.COLS * ( MC.Atlas.STRIDE or MC.Atlas.TILE )
	MC.Atlas.H = MC.GeneratedAtlas.H or MC.Atlas.ROWS * ( MC.Atlas.STRIDE or MC.Atlas.TILE )
end

local function atlasPngPath( path )
	path = path or "mc/atlas_365"
	path = path:gsub( "%.vmt$", "" )
	if path:sub( -4 ) == ".png" then return path end
	return path .. ".png"
end

-- single atlas material: alpha cutout (glass/leaves), vertex-shaded, backface-culled
MC.Material = Material( atlasPngPath( MC.Atlas.MATERIAL or "mc/atlas_365" ), "alphatest vertexcolor" )

-- second material over the same atlas pixels for translucent blocks: real alpha
-- blending in the translucent pass. GMod caches materials by path, so the build
-- writes a separate translucent atlas VMT/VTF instead of rebinding one texture
-- through two different flag sets.
local function translucentAtlasPath( path )
	path = path or "mc/atlas_365"
	return path:gsub( "%.png$", "" ) .. "_translucent"
end
local transPath = MC.Atlas.MATERIAL_TRANSLUCENT or translucentAtlasPath( MC.Atlas.MATERIAL )
MC.MaterialTranslucent = Material( atlasPngPath( transPath ), "translucent vertexcolor" )
if not MC.MaterialTranslucent or MC.MaterialTranslucent:IsError() then
	-- missing copy: fall back to the cutout material rather than drawing white
	MC.MaterialTranslucent = MC.Material
end

-- Opaque variant of the atlas for inventory icons. Semi-transparent blocks
-- (stained glass, tinted glass, ice, slime, honey) have low texel alpha that the
-- cutout material's alpha test discards, so their icons would render blank. This
-- is the cutout atlas minus $alphatest, so low-alpha texels are kept and the icon
-- shows the solid texture colour.
--
-- The atlas ships only as a PNG (no .vtf), so neither way of seeding $basetexture
-- works on its own: leaving it empty at creation renders a solid white square, and
-- a path string like "mc/atlas_365" is not the texture's cache key so it falls back
-- to a disk .vtf lookup that misses and draws the pink/black error checkerboard.
-- Point $basetexture at the registered name of the texture MC.Material already
-- loaded; the material system then resolves it from the texture cache (same texture,
-- no second copy) and the surface library binds it for 2D icon draws.
MC.MaterialIconOpaque = nil
do
	local baseTex = MC.Material and MC.Material.GetTexture and MC.Material:GetTexture( "$basetexture" )
	local baseName = baseTex and not baseTex:IsError() and baseTex.GetName and baseTex:GetName() or nil
	if baseName and baseName ~= "" then
		local mat = CreateMaterial( "mc_atlas_icon_opaque", "UnlitGeneric", {
			["$basetexture"] = baseName,
			["$vertexcolor"] = "1",
			["$nocull"] = "1",
			["$vertexalpha"] = "1",
		} )
		if mat and not mat:IsError() then
			mat:SetTexture( "$basetexture", baseTex )
			MC.MaterialIconOpaque = mat
		end
	end
end
if not MC.MaterialIconOpaque then
	-- atlas texture unavailable: fall back to the cutout material rather than
	-- drawing white/error icons (semi-transparent blocks just look blank)
	MC.MaterialIconOpaque = MC.Material
end

-- directional shading (modulates the texture via vertex colour)
local SH_TOP    = Color( 255, 255, 255 )
local SH_BOTTOM = Color( 130, 130, 130 )
local SH_X      = Color( 160, 160, 160 )
local SH_Y      = Color( 205, 205, 205 )

local N_UP    = Vector(  0,  0,  1 )
local N_DOWN  = Vector(  0,  0, -1 )
local N_XP    = Vector(  1,  0,  0 )
local N_XN    = Vector( -1,  0,  0 )
local N_YP    = Vector(  0,  1,  0 )
local N_YN    = Vector(  0, -1,  0 )

-- face table. slot: 1=top tile, 2=bottom tile, 3=side tile
-- c = four corners as { offX, offY, offZ, uFlag, vFlag } (a,b,c,d), drawn a,b,c + a,c,d
local FACES = {
	{ n = N_UP,   sh = SH_TOP,    slot = 1, off = {  0,  0,  1 }, c = { {0,0,1,0,1}, {1,0,1,1,1}, {1,1,1,1,0}, {0,1,1,0,0} } },
	{ n = N_DOWN, sh = SH_BOTTOM, slot = 2, off = {  0,  0, -1 }, c = { {0,1,0,0,1}, {1,1,0,1,1}, {1,0,0,1,0}, {0,0,0,0,0} } },
	{ n = N_XP,   sh = SH_X,      slot = 3, off = {  1,  0,  0 }, c = { {1,0,0,0,1}, {1,1,0,1,1}, {1,1,1,1,0}, {1,0,1,0,0} } },
	{ n = N_XN,   sh = SH_X,      slot = 3, off = { -1,  0,  0 }, c = { {0,1,0,0,1}, {0,0,0,1,1}, {0,0,1,1,0}, {0,1,1,0,0} } },
	{ n = N_YP,   sh = SH_Y,      slot = 3, off = {  0,  1,  0 }, c = { {1,1,0,0,1}, {0,1,0,1,1}, {0,1,1,1,0}, {1,1,1,0,0} } },
	{ n = N_YN,   sh = SH_Y,      slot = 3, off = {  0, -1,  0 }, c = { {0,0,0,0,1}, {1,0,0,1,1}, {1,0,1,1,0}, {0,0,1,0,0} } },
}
-- Source's front-face winding is opposite the corner order above.
local TRI = { 1, 3, 2, 1, 4, 3 }

local function cornerXYZ( cn )
	return cn.x or cn.cx or cn[1] or 0, cn.y or cn.cy or cn[2] or 0, cn.z or cn.cz or cn[3] or 0
end

local function cornerCellOffset( value )
	return value <= 0 and -1 or 0
end

local function cornerSampleOffsets( value )
	local low = cornerCellOffset( value )
	return low, low + 1
end

local function cornerStep( value )
	return value <= 0 and -1 or 1
end

local MC_LIGHT_STYLE_FAST = "fast"
local MC_LIGHT_STYLE_VANILLA = "vanilla"
local MC_LIGHT_STYLE_BEST = "best"
local MC_LIGHT_STYLE_SHADER = "shader"

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

local function currentLightStyle()
	local cv = MC.LightStyle
	local style = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or MC_LIGHT_STYLE_VANILLA
	if style == MC_LIGHT_STYLE_FAST or style == "low" or style == "0" then return MC_LIGHT_STYLE_FAST end
	if style == MC_LIGHT_STYLE_BEST or style == "fancy" or style == "high" or style == "2" then return MC_LIGHT_STYLE_BEST end
	if style == MC_LIGHT_STYLE_SHADER or style == "shaders" or style == "cinematic" or style == "3" then return MC_LIGHT_STYLE_SHADER end
	return MC_LIGHT_STYLE_VANILLA
end

local function minecraftSmoothCornerSamples( bx, by, bz, faceIndex, cn )
	local x, y, z = cornerXYZ( cn )
	local x0, x1 = cornerSampleOffsets( x )
	local y0, y1 = cornerSampleOffsets( y )
	local z0, z1 = cornerSampleOffsets( z )
	if faceIndex == MC.Face.TOP then
		return bx + x0, by + y0, bz + 1, bx + x1, by + y0, bz + 1, bx + x0, by + y1, bz + 1, bx + x1, by + y1, bz + 1
	elseif faceIndex == MC.Face.BOTTOM then
		return bx + x0, by + y0, bz - 1, bx + x1, by + y0, bz - 1, bx + x0, by + y1, bz - 1, bx + x1, by + y1, bz - 1
	elseif faceIndex == MC.Face.XP then
		return bx + 1, by + y0, bz + z0, bx + 1, by + y1, bz + z0, bx + 1, by + y0, bz + z1, bx + 1, by + y1, bz + z1
	elseif faceIndex == MC.Face.XN then
		return bx - 1, by + y0, bz + z0, bx - 1, by + y1, bz + z0, bx - 1, by + y0, bz + z1, bx - 1, by + y1, bz + z1
	elseif faceIndex == MC.Face.YP then
		return bx + x0, by + 1, bz + z0, bx + x1, by + 1, bz + z0, bx + x0, by + 1, bz + z1, bx + x1, by + 1, bz + z1
	elseif faceIndex == MC.Face.YN then
		return bx + x0, by - 1, bz + z0, bx + x1, by - 1, bz + z0, bx + x0, by - 1, bz + z1, bx + x1, by - 1, bz + z1
	end
	return bx, by, bz, bx, by, bz, bx, by, bz, bx, by, bz
end

local MeshLightSampleCache = {}
local MeshAOSampleCache = {}
local MeshLightSampleHits, MeshLightSampleMisses = 0, 0
local MeshAOSampleHits, MeshAOSampleMisses = 0, 0
local MeshSampleBaseX, MeshSampleBaseY, MeshSampleBaseZ = 0, 0, 0
local SAMPLE_CACHE_ORIGIN_PAD = 16
local SAMPLE_CACHE_AXIS_BITS = 6
local SAMPLE_CACHE_AXIS_SIZE = 64
local SAMPLE_CACHE_Z_SHIFT = SAMPLE_CACHE_AXIS_BITS * 2
local SAMPLE_CACHE_EXTRA_SHIFT = SAMPLE_CACHE_AXIS_BITS * 3
local bit_bor, bit_lshift = bit.bor, bit.lshift

local function resetMeshLightingSampleCaches()
	MeshLightSampleCache = {}
	MeshAOSampleCache = {}
	MeshLightSampleHits, MeshLightSampleMisses = 0, 0
	MeshAOSampleHits, MeshAOSampleMisses = 0, 0
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
	if not MC.SampleLighting then return 1 end
	local key = sampleCacheKey( sx, sy, sz, selfEmission )
	if key ~= nil then
		local cached = MeshLightSampleCache[key]
		if cached ~= nil then
			MeshLightSampleHits = MeshLightSampleHits + 1
			return cached
		end
	end
	MeshLightSampleMisses = MeshLightSampleMisses + 1
	local brightness = MC.SampleLighting( sx, sy, sz, selfEmission )
	if key ~= nil then MeshLightSampleCache[key] = brightness end
	return brightness
end

local function cachedMeshAOSample( sx, sy, sz )
	if not MC.SampleAmbientOcclusion then return false end
	local key = sampleCacheKey( sx, sy, sz )
	if key ~= nil then
		local cached = MeshAOSampleCache[key]
		if cached ~= nil then
			MeshAOSampleHits = MeshAOSampleHits + 1
			return cached
		end
	end
	MeshAOSampleMisses = MeshAOSampleMisses + 1
	local sample = MC.SampleAmbientOcclusion( sx, sy, sz )
	local blocked = sample == true or sample == 1
	if key ~= nil then MeshAOSampleCache[key] = blocked end
	return blocked
end

local function noteMeshLightingCacheStats()
	local stats = MC.LightPerfStats or {}
	MC.LightPerfStats = stats
	stats.lastMeshLightCacheHits = MeshLightSampleHits
	stats.lastMeshLightCacheMisses = MeshLightSampleMisses
	stats.lastMeshAOCacheHits = MeshAOSampleHits
	stats.lastMeshAOCacheMisses = MeshAOSampleMisses
end

local function newMeshPerfStats()
	return {
		vertices = 0,
		faces = 0,
		meshes = 0,
		opaqueVerts = 0,
		translucentVerts = 0,
		blocksVisited = 0,
		blocksRendered = 0,
		blockCacheHits = 0,
		blockCacheMisses = 0,
		blockCacheRecolors = 0,
		fullCubeBlocks = 0,
		shapeBlocks = 0,
		modelBlocks = 0,
		liquidBlocks = 0,
		crossBlocks = 0,
		prepMS = 0,
		indexMS = 0,
		loopMS = 0,
		emitMS = 0,
		fullCubeMS = 0,
		shapeMS = 0,
		modelMS = 0,
		liquidMS = 0,
		crossMS = 0,
		flushMS = 0,
		meshNewMS = 0,
		buildTriMS = 0,
		destroyMS = 0,
		commitMS = 0,
		flatMS = 0,
		recolorMS = 0,
	}
end

local function meshPerfElapsedMS( startTime )
	return ( SysTime() - startTime ) * 1000
end

local function meshPerfRoundMS( value )
	return math.Round( value or 0, 3 )
end

local function meshPerfMS( startTime )
	return meshPerfRoundMS( meshPerfElapsedMS( startTime ) )
end

local function meshPerfAdd( perf, field, startTime )
	if not perf or not field or not startTime then return end
	perf[field] = ( perf[field] or 0 ) + meshPerfElapsedMS( startTime )
end

local function meshPerfAddBlockKind( perf, kind )
	if kind == "fullCube" then
		perf.fullCubeBlocks = perf.fullCubeBlocks + 1
	elseif kind == "model" then
		perf.modelBlocks = perf.modelBlocks + 1
	elseif kind == "liquid" then
		perf.liquidBlocks = perf.liquidBlocks + 1
	elseif kind == "cross" then
		perf.crossBlocks = perf.crossBlocks + 1
	else
		perf.shapeBlocks = perf.shapeBlocks + 1
	end
end

local function meshPerfAddKindDuration( perf, kind, durationMS )
	if kind == "fullCube" then
		perf.fullCubeMS = perf.fullCubeMS + durationMS
	elseif kind == "model" then
		perf.modelMS = perf.modelMS + durationMS
	elseif kind == "liquid" then
		perf.liquidMS = perf.liquidMS + durationMS
	elseif kind == "cross" then
		perf.crossMS = perf.crossMS + durationMS
	else
		perf.shapeMS = perf.shapeMS + durationMS
	end
end

local function shouldStoreBlockEmissionCache( kind, vertexCount )
	if vertexCount <= 0 then return false end
	if kind == "fullCube" and vertexCount <= 12 then return false end
	return true
end

local function publishMeshPerfStats( perf )
	local stats = MC.LightPerfStats
	if not stats or not perf then return end
	stats.lastMeshVertices = perf.vertices or 0
	stats.lastMeshFaces = perf.faces or 0
	stats.lastMeshMeshes = perf.meshes or 0
	stats.lastMeshOpaqueVerts = perf.opaqueVerts or 0
	stats.lastMeshTranslucentVerts = perf.translucentVerts or 0
	stats.lastMeshBlocksVisited = perf.blocksVisited or 0
	stats.lastMeshBlocksRendered = perf.blocksRendered or 0
	stats.lastMeshBlockCacheHits = perf.blockCacheHits or 0
	stats.lastMeshBlockCacheMisses = perf.blockCacheMisses or 0
	stats.lastMeshBlockCacheRecolors = perf.blockCacheRecolors or 0
	stats.lastMeshFullCubeBlocks = perf.fullCubeBlocks or 0
	stats.lastMeshShapeBlocks = perf.shapeBlocks or 0
	stats.lastMeshModelBlocks = perf.modelBlocks or 0
	stats.lastMeshLiquidBlocks = perf.liquidBlocks or 0
	stats.lastMeshCrossBlocks = perf.crossBlocks or 0
	stats.lastMeshPrepMS = meshPerfRoundMS( perf.prepMS )
	stats.lastMeshIndexMS = meshPerfRoundMS( perf.indexMS )
	stats.lastMeshLoopMS = meshPerfRoundMS( perf.loopMS )
	stats.lastMeshEmitMS = meshPerfRoundMS( perf.emitMS )
	stats.lastMeshFullCubeMS = meshPerfRoundMS( perf.fullCubeMS )
	stats.lastMeshShapeMS = meshPerfRoundMS( perf.shapeMS )
	stats.lastMeshModelMS = meshPerfRoundMS( perf.modelMS )
	stats.lastMeshLiquidMS = meshPerfRoundMS( perf.liquidMS )
	stats.lastMeshCrossMS = meshPerfRoundMS( perf.crossMS )
	stats.lastMeshFlushMS = meshPerfRoundMS( perf.flushMS )
	stats.lastMeshMeshNewMS = meshPerfRoundMS( perf.meshNewMS )
	stats.lastMeshBuildTrianglesMS = meshPerfRoundMS( perf.buildTriMS )
	stats.lastMeshDestroyMS = meshPerfRoundMS( perf.destroyMS )
	stats.lastMeshCommitMS = meshPerfRoundMS( perf.commitMS )
	stats.lastMeshFlatMS = meshPerfRoundMS( perf.flatMS )
	stats.lastMeshRecolorMS = meshPerfRoundMS( perf.recolorMS )
end

local function minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local ax, ay, az, bx2, by2, bz2, cx, cy, cz, dx, dy, dz = minecraftSmoothCornerSamples( bx, by, bz, faceIndex, cn )
	local a = tonumber( cachedMeshLightingSample( ax, ay, az, selfEmission ) ) or 1
	local b = tonumber( cachedMeshLightingSample( bx2, by2, bz2, selfEmission ) ) or 1
	local c = tonumber( cachedMeshLightingSample( cx, cy, cz, selfEmission ) ) or 1
	local d = tonumber( cachedMeshLightingSample( dx, dy, dz, selfEmission ) ) or 1
	return ( a + b + c + d ) * 0.25
end

local function minecraftFastCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local face = FACES[faceIndex]
	local off = face and face.off
	if not off then return cachedMeshLightingSample( bx, by, bz, selfEmission ) end
	return cachedMeshLightingSample( bx + off[1], by + off[2], bz + off[3], selfEmission )
end

local function bestSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local brightness = math.Clamp( minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission ), 0, 1 )
	return math.Clamp( brightness ^ 0.85, 0, 1 )
end

local function shaderSunFaceFactor( faceIndex )
	if faceIndex == MC.Face.TOP then return 1.16 end
	if faceIndex == MC.Face.BOTTOM then return 0.72 end
	if faceIndex == MC.Face.YP then return 1.08 end
	if faceIndex == MC.Face.XP then return 1.00 end
	if faceIndex == MC.Face.XN then return 0.88 end
	if faceIndex == MC.Face.YN then return 0.82 end
	return 1
end

local function shaderDaylightFactor()
	local cv = MC.LightSkyLevel
	return math.Clamp( ( cv and cv.GetInt and cv:GetInt() or 15 ) / 15, 0, 1 )
end

local function shaderSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local brightness = math.Clamp( bestSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission ), 0, 1 )
	local daylight = shaderDaylightFactor()
	local litSurface = math.Clamp( ( brightness - 0.22 ) / 0.78, 0, 1 )
	local sunMix = daylight * litSurface
	local directed = brightness * ( 1 + ( shaderSunFaceFactor( faceIndex ) - 1 ) * sunMix )
	local contrast = ( directed - 0.5 ) * 1.12 + 0.5
	return math.Clamp( contrast + daylight * 0.025, 0, 1 )
end

local function minecraftCornerOccluders( bx, by, bz, faceIndex, cn )
	local x, y, z = cornerXYZ( cn )
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

local function minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, factors )
	local s1x, s1y, s1z, s2x, s2y, s2z, cx, cy, cz = minecraftCornerOccluders( bx, by, bz, faceIndex, cn )
	local side1Blocked = cachedMeshAOSample( s1x, s1y, s1z )
	local side2Blocked = cachedMeshAOSample( s2x, s2y, s2z )
	local cornerBlocked = cachedMeshAOSample( cx, cy, cz )
	if side1Blocked and side2Blocked then return factors[3] end
	local blocked = ( side1Blocked and 1 or 0 ) + ( side2Blocked and 1 or 0 ) + ( cornerBlocked and 1 or 0 )
	return factors[blocked] or 1
end

local function minecraftSmoothCornerAO( bx, by, bz, faceIndex, cn )
	return minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, MC_LIGHT_AO_FACTORS )
end

local function minecraftBestCornerAO( bx, by, bz, faceIndex, cn )
	return minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, MC_LIGHT_BEST_AO_FACTORS )
end

local function minecraftShaderCornerAO( bx, by, bz, faceIndex, cn )
	return minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, MC_LIGHT_SHADER_AO_FACTORS )
end

local function shaderFaceTint( faceIndex )
	if faceIndex == MC.Face.TOP then return 1.06, 1.03, 0.94 end
	if faceIndex == MC.Face.BOTTOM then return 0.76, 0.82, 0.98 end
	if faceIndex == MC.Face.YP then return 1.02, 1.00, 0.94 end
	if faceIndex == MC.Face.XP then return 0.96, 0.99, 1.04 end
	if faceIndex == MC.Face.XN then return 0.86, 0.90, 1.02 end
	if faceIndex == MC.Face.YN then return 0.82, 0.88, 1.04 end
	return 1, 1, 1
end

local function litFaceColor( shade, bx, by, bz, id, faceIndex, cn, selfEmission, style )
	if not MC.SampleLighting then return shade end
	style = style or MC_LIGHT_STYLE_VANILLA
	local brightness, ao
	if style == MC_LIGHT_STYLE_FAST then
		brightness = minecraftFastCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = 1
	elseif style == MC_LIGHT_STYLE_BEST then
		brightness = bestSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = minecraftBestCornerAO( bx, by, bz, faceIndex, cn )
	elseif style == MC_LIGHT_STYLE_SHADER then
		brightness = shaderSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = minecraftShaderCornerAO( bx, by, bz, faceIndex, cn )
	else
		brightness = minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = minecraftSmoothCornerAO( bx, by, bz, faceIndex, cn )
	end
	local mul = math.Clamp( ( tonumber( brightness ) or 1 ) * ao, 0, 1 )
	local rScale, gScale, bScale = 1, 1, 1
	if style == MC_LIGHT_STYLE_SHADER then
		rScale, gScale, bScale = shaderFaceTint( faceIndex )
	end
	return Color(
		math.Clamp( math.floor( ( shade.r or 255 ) * mul * rScale + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( ( shade.g or 255 ) * mul * gScale + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( ( shade.b or 255 ) * mul * bScale + 0.5 ), 0, 255 ),
		shade.a or 255
	)
end

local function quadCornerColors( shade, bx, by, bz, id, faceIndex, corners, selfEmission, style )
	if style == MC_LIGHT_STYLE_FAST then
		local color = litFaceColor( shade, bx, by, bz, id, faceIndex, corners[1], selfEmission, style )
		return { color, color, color, color }
	end
	return {
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[1], selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[2], selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[3], selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[4], selfEmission, style ),
	}
end

local ScratchCorners = {
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ 0, 0, 0 },
}

local function setScratchCorner( index, x, y, z )
	local c = ScratchCorners[index]
	c[1], c[2], c[3] = x, y, z
	return c
end

local function quadCornerColorValues( shade, bx, by, bz, id, faceIndex, selfEmission, style, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	if style == MC_LIGHT_STYLE_FAST then
		local color = litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 1, x1, y1, z1 ), selfEmission, style )
		return color, color, color, color
	end
	return
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 1, x1, y1, z1 ), selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 2, x2, y2, z2 ), selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 3, x3, y3, z3 ), selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 4, x4, y4, z4 ), selfEmission, style )
end

local VERT_LIMIT = 64998 -- multiple of 6, under the 65535 IMesh vertex cap

MC.RenderMeshConstants = MC.RenderMeshConstants or {}
MC.RenderMeshConstants.BS = BS
MC.RenderMeshConstants.CS = CS
MC.RenderMeshConstants.CH = CH
MC.RenderMeshConstants.CS2 = CS2
MC.RenderMeshConstants.RENDER_SECTIONS_XY = RENDER_SECTIONS_XY
MC.RenderMeshConstants.RENDER_SECTIONS_Z = RENDER_SECTIONS_Z
MC.RenderMeshConstants.VERT_LIMIT = VERT_LIMIT
MC.RenderMeshConstants.FACES = FACES
MC.RenderMeshConstants.TRI = TRI
MC.RenderMeshConstants.N_UP = N_UP
MC.RenderMeshConstants.N_DOWN = N_DOWN
MC.RenderMeshConstants.N_XP = N_XP
MC.RenderMeshConstants.N_XN = N_XN
MC.RenderMeshConstants.N_YP = N_YP
MC.RenderMeshConstants.N_YN = N_YN
MC.RenderMeshConstants.SH_TOP = SH_TOP
MC.RenderMeshConstants.SH_BOTTOM = SH_BOTTOM
MC.RenderMeshConstants.SH_X = SH_X
MC.RenderMeshConstants.SH_Y = SH_Y

local function recolorLightMeta( meta, style )
	return litFaceColor(
		meta.shade,
		meta.bx, meta.by, meta.bz,
		meta.id,
		meta.faceIndex,
		meta,
		meta.selfEmission,
		style
	)
end

local function recolorCachedBlockEmission( record, lightStyle )
	return MC.RecolorCachedBlockEmission( record, lightStyle, recolorLightMeta )
end

MC.Meshes      = MC.Meshes or {}      -- key -> { IMesh, ... } (opaque/cutout pass)
MC.MeshesTrans = MC.MeshesTrans or {} -- key -> { IMesh, ... } (translucent pass)
MC.MeshSections = MC.MeshSections or {} -- key -> sectionIndex -> { opaque = {}, translucent = {} }
MC.MeshSectionGeometry = MC.MeshSectionGeometry or {} -- key -> sectionIndex -> cached vertex/light records
MC.MeshDirty = MC.MeshDirty or {}  -- key -> true
MC.MeshLightDirty = MC.MeshLightDirty or {} -- key -> sectionIndex -> true for light-only colour updates
MC.MeshDirtyRateLimited = MC.MeshDirtyRateLimited or {} -- key -> true for explosion-driven mesh rebuilds
MC.ChunkEnts = MC.ChunkEnts or {}  -- key -> mc_chunk entity (clientside physics owner)
MC.PhysDirty = MC.PhysDirty or {}  -- key -> true while a clientside collision rebuild is being fired
MC.PhysDirtyPriority = MC.PhysDirtyPriority or {} -- key -> true for priority rebuild diagnostics
MC.PhysDirtyBulk = MC.PhysDirtyBulk or {} -- key -> true when bulk client collision rebuild is throttled
MC.PhysDirtyBulkOrder = MC.PhysDirtyBulkOrder or {}
MC.PhysDirtyBulkOrderHead = MC.PhysDirtyBulkOrderHead or 1
MC.ClientPhysRetryPending = MC.ClientPhysRetryPending or {}
MC.ClientPhysRetryAttempts = MC.ClientPhysRetryAttempts or {}
MC.RenderStats = MC.RenderStats or {}
MC.ClientPhysStats = MC.ClientPhysStats or {}
MC.ClientPhysBuiltSignatures = MC.ClientPhysBuiltSignatures or {}
MC.ClientPhysBuiltHadObjects = MC.ClientPhysBuiltHadObjects or {}
MC.ClientPhysBuiltObjectCounts = MC.ClientPhysBuiltObjectCounts or {}
MC.ClientPhysTargetSignatures = MC.ClientPhysTargetSignatures or {}
MC.ClientCollisionPlayerInterest = MC.ClientCollisionPlayerInterest or {}
MC.ClientCollisionAimInterest = MC.ClientCollisionAimInterest or {}


-- should the face between `cur` and neighbour `nb` be drawn?
local function sameLiquidKind( cur, nb )
	if not MC.LiquidKind then return false end
	local curKind = MC.LiquidKind( cur )
	if not curKind then return false end
	return curKind == MC.LiquidKind( nb )
end

local function visible( cur, nb, nbOrient )
	if nb == 0 then return true end
	if sameLiquidKind( cur, nb ) then return false end
	local d = MC.Blocks[nb]
	if d and d.transparent then return nb ~= cur end
	if MC.BlockIsFullCube and not MC.BlockIsFullCube( nb, nbOrient ) then return true end
	return false
end

local FLUID_SURFACE_HEIGHT = 0.8888889
local FLUID_WEIGHTED_HEIGHT = 0.8
local FLUID_FACE_OFFSET = 0.001
MC.RenderMeshConstants.FLUID_FACE_OFFSET = FLUID_FACE_OFFSET

local function isLiquidBlock( id )
	if MC.IsLiquidBlock then return MC.IsLiquidBlock( id ) end
	return MC.LiquidKind and MC.LiquidKind( id ) ~= nil or false
end

local function solidForFluidHeight( id, orient )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return true end
	if b.solid == false or b.transparent == true then return false end
	if MC.BlockIsFullCube then return MC.BlockIsFullCube( id, orient ) == true end
	return not b.shape
end

local function fluidHeightAt( bx, by, bz, kind )
	local id = MC.GetBlock( bx, by, bz )
	if MC.LiquidKind and MC.LiquidKind( id ) == kind then
		if sameLiquidKind( id, MC.GetBlock( bx, by, bz + 1 ) ) then return 1.0 end
		return FLUID_SURFACE_HEIGHT
	end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return solidForFluidHeight( id, orient ) and -1.0 or 0.0
end

local function addWeightedFluidHeight( total, weight, height )
	if height >= FLUID_WEIGHTED_HEIGHT then
		return total + height * 10, weight + 10
	elseif height >= 0 then
		return total + height, weight + 1
	end
	return total, weight
end

local function calculateAverageFluidHeight( kind, heightSelf, heightA, heightB, bx, by, bz )
	if heightA >= 1.0 or heightB >= 1.0 then return 1.0 end
	local total, weight = 0, 0
	if heightA > 0 or heightB > 0 then
		local cornerHeight = fluidHeightAt( bx, by, bz, kind )
		if cornerHeight >= 1.0 then return 1.0 end
		total, weight = addWeightedFluidHeight( total, weight, cornerHeight )
	end
	total, weight = addWeightedFluidHeight( total, weight, heightSelf )
	total, weight = addWeightedFluidHeight( total, weight, heightA )
	total, weight = addWeightedFluidHeight( total, weight, heightB )
	if weight <= 0 then return 0 end
	return total / weight
end

------------------------------------------------------------------ mesh lifecycle
local function destroyMeshList( store, key )
	local list = store[key]
	if not list then return end
	for i = 1, #list do
		if list[i] then list[i]:Destroy() end
	end
	store[key] = nil
end

local function destroySectionMeshList( list )
	if not list then return end
	for i = 1, #list do
		if list[i] then list[i]:Destroy() end
	end
end

local sectionIndexForLocal = MC.RenderSectionIndexForLocal
local clearChunkBlockEmitCache = MC.ClearChunkBlockEmitCache

local function rebuildFlatMeshLists( key )
	local sections = MC.MeshSections[key]
	if not sections then
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
		return
	end
	local opaque, translucent = {}, {}
	local totalSections = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
	for i = 1, totalSections do
		local section = sections[i]
		if section then
			for j = 1, #( section.opaque or {} ) do opaque[#opaque + 1] = section.opaque[j] end
			for j = 1, #( section.translucent or {} ) do translucent[#translucent + 1] = section.translucent[j] end
		end
	end
	MC.Meshes[key] = #opaque > 0 and opaque or nil
	MC.MeshesTrans[key] = #translucent > 0 and translucent or nil
end

function MC.FreeChunkMesh( key )
	if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	if MC.MeshLightDirty then MC.MeshLightDirty[key] = nil end
	clearChunkBlockEmitCache( key )
	local sections = MC.MeshSections[key]
	if sections then
		for _, section in pairs( sections ) do
			destroySectionMeshList( section.opaque )
			destroySectionMeshList( section.translucent )
		end
		MC.MeshSections[key] = nil
		if MC.ForgetChunkMeshSectionGeometryCache then
			MC.ForgetChunkMeshSectionGeometryCache( key )
		else
			MC.MeshSectionGeometry[key] = nil
		end
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
		return
	end
	if MC.ForgetChunkMeshSectionGeometryCache then
		MC.ForgetChunkMeshSectionGeometryCache( key )
	else
		MC.MeshSectionGeometry[key] = nil
	end
	destroyMeshList( MC.Meshes, key )
	destroyMeshList( MC.MeshesTrans, key )
end

local DecodeLocal = MC.DecodeLocal

local function ensureChunkRenderSectionIndex( chunk )
	if not chunk then return nil end
	local version = chunk.collisionVersion or 0
	if chunk.renderSectionBlocks and chunk.renderSectionIndexVersion == version then
		return chunk.renderSectionBlocks
	end

	local bySection = {}
	for li, id in pairs( chunk.blocks or {} ) do
		local lx, ly, lz = DecodeLocal( li )
		local sectionIndex = sectionIndexForLocal( lx, ly, lz )
		local list = bySection[sectionIndex]
		if not list then
			list = {}
			bySection[sectionIndex] = list
		end
		list[li] = id
	end

	chunk.renderSectionBlocks = bySection
	chunk.renderSectionIndexVersion = version
	return bySection
end

local function rotatedUVFlags( uf, vf, rot, flipU, flipV )
	rot = rot % 4
	if rot == 1 then uf, vf = vf, 1 - uf
	elseif rot == 2 then uf, vf = 1 - uf, 1 - vf
	elseif rot == 3 then uf, vf = 1 - vf, uf end
	if flipU then uf = 1 - uf end
	if flipV then vf = 1 - vf end
	return uf, vf
end

local function tileUVRect( tile, uv )
	if not uv then return MC.TileUV( tile ) end
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	local baseX = col * stride + pad
	local baseY = row * stride + pad
	local u0 = baseX + ( tonumber( uv[1] ) or 0 ) / 16 * A.TILE + inset
	local v0 = baseY + ( tonumber( uv[2] ) or 0 ) / 16 * A.TILE + inset
	local u1 = baseX + ( tonumber( uv[3] ) or 16 ) / 16 * A.TILE - inset
	local v1 = baseY + ( tonumber( uv[4] ) or 16 ) / 16 * A.TILE - inset
	return u0 / A.W, v0 / A.H, u1 / A.W, v1 / A.H
end

local function tileUVPointRaw( tile, u, v )
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	u = tonumber( u ) or 0
	v = tonumber( v ) or 0
	local px = col * stride + pad + u / 16 * A.TILE
	local py = row * stride + pad + v / 16 * A.TILE
	if u <= 0 then px = px + inset elseif u >= 16 then px = px - inset end
	if v <= 0 then py = py + inset elseif v >= 16 then py = py - inset end
	return px / A.W, py / A.H
end

local function tileUVPoint( tile, uv )
	return tileUVPointRaw( tile, uv and uv[1], uv and uv[2] )
end

local function bakedFaceData( id, face, orient )
	local b = MC.Blocks[id]
	if not b or not b.baked then return nil end
	local baked = b.baked[orient] or b.baked[MC.DefaultOrient( id )] or b.baked[0]
	return baked and baked[face] or nil
end

local EPS = 0.0001

local BOX_FACE_CORNERS = {
	[1] = function( b ) return { { b[1], b[2], b[6] }, { b[4], b[2], b[6] }, { b[4], b[5], b[6] }, { b[1], b[5], b[6] } } end,
	[2] = function( b ) return { { b[1], b[5], b[3] }, { b[4], b[5], b[3] }, { b[4], b[2], b[3] }, { b[1], b[2], b[3] } } end,
	[3] = function( b ) return { { b[4], b[2], b[3] }, { b[4], b[5], b[3] }, { b[4], b[5], b[6] }, { b[4], b[2], b[6] } } end,
	[4] = function( b ) return { { b[1], b[5], b[3] }, { b[1], b[2], b[3] }, { b[1], b[2], b[6] }, { b[1], b[5], b[6] } } end,
	[5] = function( b ) return { { b[4], b[5], b[3] }, { b[1], b[5], b[3] }, { b[1], b[5], b[6] }, { b[4], b[5], b[6] } } end,
	[6] = function( b ) return { { b[1], b[2], b[3] }, { b[4], b[2], b[3] }, { b[4], b[2], b[6] }, { b[1], b[2], b[6] } } end,
}

local function boxFaceCornerValues( b, face, corner )
	local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
	if face == MC.Face.TOP then
		if corner == 1 then return x0, y0, z1 end
		if corner == 2 then return x1, y0, z1 end
		if corner == 3 then return x1, y1, z1 end
		return x0, y1, z1
	elseif face == MC.Face.BOTTOM then
		if corner == 1 then return x0, y1, z0 end
		if corner == 2 then return x1, y1, z0 end
		if corner == 3 then return x1, y0, z0 end
		return x0, y0, z0
	elseif face == MC.Face.XP then
		if corner == 1 then return x1, y0, z0 end
		if corner == 2 then return x1, y1, z0 end
		if corner == 3 then return x1, y1, z1 end
		return x1, y0, z1
	elseif face == MC.Face.XN then
		if corner == 1 then return x0, y1, z0 end
		if corner == 2 then return x0, y0, z0 end
		if corner == 3 then return x0, y0, z1 end
		return x0, y1, z1
	elseif face == MC.Face.YP then
		if corner == 1 then return x1, y1, z0 end
		if corner == 2 then return x0, y1, z0 end
		if corner == 3 then return x0, y1, z1 end
		return x1, y1, z1
	end
	if corner == 1 then return x0, y0, z0 end
	if corner == 2 then return x1, y0, z0 end
	if corner == 3 then return x1, y0, z1 end
	return x0, y0, z1
end

local BOX_UV_FLAGS = {
	{ 0, 1 },
	{ 1, 1 },
	{ 1, 0 },
	{ 0, 0 },
}

local function rotateModelXY( x, y, steps )
	steps = steps % 4
	if steps == 1 then return 1 - y, x end
	if steps == 2 then return 1 - x, 1 - y end
	if steps == 3 then return y, 1 - x end
	return x, y
end

local function rotateModelXZ( y, z, steps )
	steps = steps % 4
	if steps == 1 then return 1 - z, y end
	if steps == 2 then return 1 - y, 1 - z end
	if steps == 3 then return z, 1 - y end
	return y, z
end

local function rotateModelFaceZ( face, steps )
	steps = steps % 4
	for _ = 1, steps do
		if face == MC.Face.YN then face = MC.Face.XP
		elseif face == MC.Face.XP then face = MC.Face.YP
		elseif face == MC.Face.YP then face = MC.Face.XN
		elseif face == MC.Face.XN then face = MC.Face.YN end
	end
	return face
end

local function rotateModelFaceX( face, steps )
	steps = steps % 4
	for _ = 1, steps do
		if face == MC.Face.YN then face = MC.Face.BOTTOM
		elseif face == MC.Face.BOTTOM then face = MC.Face.YP
		elseif face == MC.Face.YP then face = MC.Face.TOP
		elseif face == MC.Face.TOP then face = MC.Face.YN end
	end
	return face
end

local function modelOrientSteps( b, orient )
	if not b then return 0, 0 end
	orient = MC.NormalizeOrient( b.id, orient )
	if b.orient == "axis" then
		if orient == MC.Axis.X then return 1, 1 end
		if orient == MC.Axis.Z then return 1, 0 end
		return 0, 0
	end
	if b.orient ~= "horizontal_facing" and b.orient ~= "facing" and b.orient ~= "door" and b.orient ~= "trapdoor" and b.orient ~= "bed" then return 0, 0 end
	if b.orient == "facing" then
		if orient == MC.Direction.DOWN then return 1, 0 end
		if orient == MC.Direction.UP then return 3, 0 end
	end
	if b.orient == "door" or b.orient == "trapdoor" or b.orient == "bed" then
		orient = MC.BlockHorizontalFacingForOrient and MC.BlockHorizontalFacingForOrient( b, orient ) or orient
	end
	if orient == MC.Direction.EAST then return 0, 1 end
	if orient == MC.Direction.SOUTH then return 0, 2 end
	if orient == MC.Direction.WEST then return 0, 3 end
	return 0, 0
end

local function rotatedModelQuads( b, orient )
	local data = MC.BlockModelData and MC.BlockModelData( b, orient ) or b
	if not data or not data.modelQuads then return nil end
	local xSteps, zSteps = modelOrientSteps( b, orient )
	if xSteps == 0 and zSteps == 0 then return data.modelQuads end
	data._rotatedModelQuads = data._rotatedModelQuads or {}
	local cacheKey = xSteps .. ":" .. zSteps
	if data._rotatedModelQuads[cacheKey] then return data._rotatedModelQuads[cacheKey] end
	local out = {}
	for qi, quad in ipairs( data.modelQuads ) do
		local verts = {}
		for vi, v in ipairs( quad.verts or {} ) do
			local y, z = rotateModelXZ( v.y, v.z, xSteps )
			local x
			x, y = rotateModelXY( v.x, y, zSteps )
			verts[vi] = { x = x, y = y, z = v.z, u = v.u, v = v.v }
			verts[vi].z = z
		end
		out[qi] = {
			face = rotateModelFaceZ( rotateModelFaceX( quad.face or MC.Face.TOP, xSteps ), zSteps ),
			tile = quad.tile,
			uv = quad.uv,
			rot = quad.rot or 0,
			verts = verts,
		}
	end
	data._rotatedModelQuads[cacheKey] = out
	return out
end

local function cornerUV16Values( face, c )
	if face == MC.Face.TOP then return c[1] * 16, ( 1 - c[2] ) * 16 end
	if face == MC.Face.BOTTOM then return c[1] * 16, c[2] * 16 end
	if face == MC.Face.XP then return c[2] * 16, ( 1 - c[3] ) * 16 end
	if face == MC.Face.XN then return ( 1 - c[2] ) * 16, ( 1 - c[3] ) * 16 end
	if face == MC.Face.YP then return ( 1 - c[1] ) * 16, ( 1 - c[3] ) * 16 end
	return c[1] * 16, ( 1 - c[3] ) * 16
end

local function cornerUV16Raw( face, x, y, z )
	if face == MC.Face.TOP then return x * 16, ( 1 - y ) * 16 end
	if face == MC.Face.BOTTOM then return x * 16, y * 16 end
	if face == MC.Face.XP then return y * 16, ( 1 - z ) * 16 end
	if face == MC.Face.XN then return ( 1 - y ) * 16, ( 1 - z ) * 16 end
	if face == MC.Face.YP then return ( 1 - x ) * 16, ( 1 - z ) * 16 end
	return x * 16, ( 1 - z ) * 16
end

local function cornerUV16( face, c )
	local u, v = cornerUV16Values( face, c )
	return { u, v }
end

local function paneSideTile( b )
	if not b or not b.name then return b and b.side or 0 end
	-- bar blocks (iron_bars, copper_bars variants) keep their own lattice texture
	if b.connection == "bars" then return b.side end
	if b.name == "glass_pane" and MC.Tiles and MC.Tiles.glass then return MC.Tiles.glass end
	local glassName = string.match( b.name, "^(.*_stained_glass)_pane$" )
	if glassName and MC.Tiles and MC.Tiles[glassName] ~= nil then return MC.Tiles[glassName] end
	return b.side
end

-- connection-arm direction tag -> the face at the open end of that arm
local ARM_END_FACE = {
	yn = MC.Face.YN,
	yp = MC.Face.YP,
	xn = MC.Face.XN,
	xp = MC.Face.XP,
}
local PANE_ARM_EDGE_UV = { 7, 0, 9, 7 }

local function dynamicShapeFaceData( b, face, box )
	if not b then return nil end
	if b.connection == "pipe6" then
		return { tile = b.side, rot = 0 }
	end
	if MC.IsPaneBlock and MC.IsPaneBlock( b.id ) then
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then
			if box and box.part == "arm" then
				return { tile = b.top, rot = 0, uv = PANE_ARM_EDGE_UV }
			end
			return { tile = b.top, rot = 0 }
		end
		-- the open end of an arm shows the pane edge strip, like Minecraft's
		-- cullfaced #edge face on the pane side models
		if box and box.part == "arm" and ARM_END_FACE[box.dir] == face then
			return { tile = b.top, rot = 0 }
		end
		return { tile = paneSideTile( b ), rot = 0 }
	end
	if MC.IsFenceBlock and MC.IsFenceBlock( b.id ) then
		return { tile = b.side, rot = 0 }
	end
	if MC.IsWallBlock and MC.IsWallBlock( b.id ) then
		return { tile = b.side, rot = 0 }
	end
	return nil
end

local function rectForFace( box, face )
	if face == MC.Face.TOP or face == MC.Face.BOTTOM then return box[1], box[4], box[2], box[5] end
	if face == MC.Face.XP or face == MC.Face.XN then return box[2], box[5], box[3], box[6] end
	return box[1], box[4], box[3], box[6]
end

local function facePlane( box, face )
	if face == MC.Face.TOP then return box[6] end
	if face == MC.Face.BOTTOM then return box[3] end
	if face == MC.Face.XP then return box[4] end
	if face == MC.Face.XN then return box[1] end
	if face == MC.Face.YP then return box[5] end
	return box[2]
end

local function coverRectForBox( box, face, plane, ox, oy, oz )
	local x0, y0, z0 = box[1] + ox, box[2] + oy, box[3] + oz
	local x1, y1, z1 = box[4] + ox, box[5] + oy, box[6] + oz
	if face == MC.Face.TOP and math.abs( z0 - plane ) <= EPS then return x0, x1, y0, y1 end
	if face == MC.Face.BOTTOM and math.abs( z1 - plane ) <= EPS then return x0, x1, y0, y1 end
	if face == MC.Face.XP and math.abs( x0 - plane ) <= EPS then return y0, y1, z0, z1 end
	if face == MC.Face.XN and math.abs( x1 - plane ) <= EPS then return y0, y1, z0, z1 end
	if face == MC.Face.YP and math.abs( y0 - plane ) <= EPS then return x0, x1, z0, z1 end
	if face == MC.Face.YN and math.abs( y1 - plane ) <= EPS then return x0, x1, z0, z1 end
	return nil
end

local function addEdge( list, value, lo, hi )
	if value > lo + EPS and value < hi - EPS then list[#list + 1] = value end
end

local function pointInRect( a, b, r )
	return a >= r[1] - EPS and a <= r[2] + EPS and b >= r[3] - EPS and b <= r[4] + EPS
end

local function rectCovered( a0, a1, b0, b1, covers )
	if #covers == 0 then return false end
	local as = { a0, a1 }
	local bs = { b0, b1 }
	for _, r in ipairs( covers ) do
		addEdge( as, math.max( a0, math.min( a1, r[1] ) ), a0, a1 )
		addEdge( as, math.max( a0, math.min( a1, r[2] ) ), a0, a1 )
		addEdge( bs, math.max( b0, math.min( b1, r[3] ) ), b0, b1 )
		addEdge( bs, math.max( b0, math.min( b1, r[4] ) ), b0, b1 )
	end
	table.sort( as )
	table.sort( bs )
	for ai = 1, #as - 1 do
		for bi = 1, #bs - 1 do
			local ma = ( as[ai] + as[ai + 1] ) * 0.5
			local mb = ( bs[bi] + bs[bi + 1] ) * 0.5
			local ok = false
			for _, r in ipairs( covers ) do
				if pointInRect( ma, mb, r ) then ok = true break end
			end
			if not ok then return false end
		end
	end
	return true
end

local function coveredByBoxes( targetBox, face, boxes, ox, oy, oz )
	local plane = facePlane( targetBox, face )
	local a0, a1, b0, b1 = rectForFace( targetBox, face )
	local covers = {}
	for _, box in ipairs( boxes or {} ) do
		if box ~= targetBox then
			local ca0, ca1, cb0, cb1 = coverRectForBox( box, face, plane, ox or 0, oy or 0, oz or 0 )
			if ca0 and ca1 > a0 + EPS and ca0 < a1 - EPS and cb1 > b0 + EPS and cb0 < b1 - EPS then
				covers[#covers + 1] = { math.max( a0, ca0 ), math.min( a1, ca1 ), math.max( b0, cb0 ), math.min( b1, cb1 ) }
			end
		end
	end
	return rectCovered( a0, a1, b0, b1, covers )
end

local function shapeFaceCovered( cur, box, face, boxes, bx, by, bz )
	if coveredByBoxes( box, face, boxes, 0, 0, 0 ) then return true end
	local plane = facePlane( box, face )
	local off = FACES[face].off
	if ( face == MC.Face.TOP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.BOTTOM and math.abs( plane ) > EPS )
	or ( face == MC.Face.XP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.XN and math.abs( plane ) > EPS )
	or ( face == MC.Face.YP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.YN and math.abs( plane ) > EPS ) then
		return false
	end
	local nb = MC.GetBlock( bx + off[1], by + off[2], bz + off[3] )
	if nb == 0 then return false end
	if sameLiquidKind( cur, nb ) then return true end
	local d = MC.Blocks[nb]
	if d and d.transparent and not ( MC.IsPaneBlock and MC.IsPaneBlock( nb ) ) then return false end
	local nbOrient = MC.GetBlockOrient( bx + off[1], by + off[2], bz + off[3] )
	return coveredByBoxes( box, face, MC.BlockBoxes( nb, nbOrient, bx + off[1], by + off[2], bz + off[3] ), off[1], off[2], off[3] )
end

function MC.BuildChunkMesh( key, sectionIndex )
	local C = MC.RenderMeshConstants
	local buildStart = SysTime()
	local meshPerf = newMeshPerfStats()
	resetMeshLightingSampleCaches()
	local meshLightStyle = currentLightStyle()
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshLightStyle = meshLightStyle
	end
	if MC.LightPerfBeginMeshBuild then
		MC.LightPerfBeginMeshBuild( key, sectionIndex )
	end
	if not sectionIndex then
		local destroyStart = SysTime()
		MC.FreeChunkMesh( key )
		meshPerfAdd( meshPerf, "destroyMS", destroyStart )
	end

	local chunk = MC.GetChunkByKey( key )
	if not chunk or chunk.count == 0 then
		if sectionIndex then
			MC.ClearSectionBlockEmitCache( key, sectionIndex )
			local commitStart = SysTime()
			local sections = MC.MeshSections[key]
			local old = sections and sections[sectionIndex]
			if old then
				local destroyStart = SysTime()
				destroySectionMeshList( old.opaque )
				destroySectionMeshList( old.translucent )
				meshPerfAdd( meshPerf, "destroyMS", destroyStart )
				sections[sectionIndex] = nil
				if MC.ForgetMeshSectionGeometryCacheSlot then
					MC.ForgetMeshSectionGeometryCacheSlot( key, sectionIndex )
				elseif MC.MeshSectionGeometry[key] then
					MC.MeshSectionGeometry[key][sectionIndex] = nil
				end
				local flatStart = SysTime()
				rebuildFlatMeshLists( key )
				meshPerfAdd( meshPerf, "flatMS", flatStart )
			end
			meshPerfAdd( meshPerf, "commitMS", commitStart )
		else
			MC.FreeChunkMesh( key )
		end
		local meshMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
		MC.RenderStats.lastMeshBuildMS = meshMS
		MC.RenderStats.lastMeshKey = key
		MC.RenderStats.lastMeshSection = sectionIndex or "full"
		MC.RenderStats.lastMeshBlocks = 0
		MC.RenderStats.lastMeshVertices = 0
		MC.RenderStats.lastMeshFaces = 0
		MC.RenderStats.lastOpaqueMeshes = 0
		MC.RenderStats.lastTranslucentMeshes = 0
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshMode = "full"
			MC.LightPerfStats.lastMeshRecords = nil
			MC.LightPerfStats.lastMeshFallback = nil
		end
		meshPerf.prepMS = meshPerfMS( buildStart )
		publishMeshPerfStats( meshPerf )
		noteMeshLightingCacheStats()
		if MC.LightPerfEndMeshBuild then
			MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
		end
		return
	end
	local sectionNeedsRecolor = sectionIndex and MC.MeshLightDirty[key] and MC.MeshLightDirty[key][sectionIndex]
	local blockLightDirtySection = sectionNeedsRecolor and MC.GetBlockLightDirtySection and MC.GetBlockLightDirtySection( key, sectionIndex ) or nil
	local sectionNeedsFullRecolor = sectionNeedsRecolor and not blockLightDirtySection

	local bxo = chunk.cx * C.CS
	local byo = chunk.cy * C.CS
	local bzo = chunk.cz * C.CH
	setMeshSampleCacheOrigin( bxo, byo, bzo )
	chunk.orients = chunk.orients or {}
	local chunkBlocks = chunk.blocks or {}
	local chunkOrients = chunk.orients
	local normalizeOrient = MC.NormalizeOrient
	local blocksById = MC.Blocks
	local blockIsFullCube = MC.BlockIsFullCube
	local getBlock = MC.GetBlock
	local getBlockOrient = MC.GetBlockOrient
	local isPaneBlock = MC.IsPaneBlock
	local blockBoxes = MC.BlockBoxes

	local sectionBuffers = {}
	local cur

	local function localIndex( lx, ly, lz )
		return lx + ly * C.CS + lz * C.CS2
	end

	local function inCurrentChunk( lx, ly, lz )
		return lx >= 0 and lx < C.CS and ly >= 0 and ly < C.CS and lz >= 0 and lz < C.CH
	end

	local function blockAt( lx, ly, lz, bx, by, bz )
		if inCurrentChunk( lx, ly, lz ) then
			return chunkBlocks[localIndex( lx, ly, lz )] or 0
		end
		return getBlock( bx, by, bz )
	end

	local function orientAt( lx, ly, lz, bx, by, bz )
		if inCurrentChunk( lx, ly, lz ) then
			local li = localIndex( lx, ly, lz )
			local id = chunkBlocks[li]
			if not id then return 0 end
			return normalizeOrient and normalizeOrient( id, chunkOrients[li] ) or ( chunkOrients[li] or 0 )
		end
		return getBlockOrient and getBlockOrient( bx, by, bz ) or 0
	end

	local function visibleAt( curId, lx, ly, lz, bx, by, bz )
		local nb = blockAt( lx, ly, lz, bx, by, bz )
		if nb == 0 then return true end
		if sameLiquidKind( curId, nb ) then return false end
		local d = blocksById[nb]
		if d and d.transparent then return nb ~= curId end
		if blockIsFullCube and not blockIsFullCube( nb, orientAt( lx, ly, lz, bx, by, bz ) ) then return true end
		return false
	end

	local function shapeFaceCoveredAt( curId, box, faceIndex, boxes, bx, by, bz, lx, ly, lz )
		if boxes and #boxes > 1 and coveredByBoxes( box, faceIndex, boxes, 0, 0, 0 ) then return true end
		local plane = facePlane( box, faceIndex )
		local off = C.FACES[faceIndex].off
		if ( faceIndex == MC.Face.TOP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.BOTTOM and math.abs( plane ) > EPS )
		or ( faceIndex == MC.Face.XP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.XN and math.abs( plane ) > EPS )
		or ( faceIndex == MC.Face.YP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.YN and math.abs( plane ) > EPS ) then
			return false
		end
		local nlx, nly, nlz = lx + off[1], ly + off[2], lz + off[3]
		local nbx, nby, nbz = bx + off[1], by + off[2], bz + off[3]
		local nb = blockAt( nlx, nly, nlz, nbx, nby, nbz )
		if nb == 0 then return false end
		if sameLiquidKind( curId, nb ) then return true end
		local d = blocksById[nb]
		if d and d.transparent and not ( isPaneBlock and isPaneBlock( nb ) ) then return false end
		local nbOrient = orientAt( nlx, nly, nlz, nbx, nby, nbz )
		if blockIsFullCube and blockIsFullCube( nb, nbOrient ) then return true end
		return coveredByBoxes( box, faceIndex, blockBoxes and blockBoxes( nb, nbOrient, nbx, nby, nbz ) or nil, off[1], off[2], off[3] )
	end

	local function newMeshBuffer( material, translucent )
		return { list = {}, records = {}, verts = {}, light = {}, nv = 0, material = material, translucent = translucent == true }
	end

	local function newBlockCacheBuffer( material, translucent )
		return { verts = {}, light = {}, nv = 0, material = material, translucent = translucent == true, cacheOnly = true }
	end

	local function prepareBlockCacheBuffer( targetBuffer )
		cur = newBlockCacheBuffer( targetBuffer.material, targetBuffer.translucent )
		return true
	end

	local function buffersForLocal( lx, ly, lz )
		local index = MC.RenderSectionIndexForLocal( lx, ly, lz )
		if sectionIndex and index ~= sectionIndex then return nil end
		local buffers = sectionBuffers[index]
		if not buffers then
			buffers = {
				opaque = newMeshBuffer( MC.Material, false ),
				translucent = newMeshBuffer( MC.MaterialTranslucent, true ),
			}
			sectionBuffers[index] = buffers
		end
		return buffers
	end

	local function flush( buf )
		if buf.nv == 0 then return end
		local vertexCount = buf.nv
		local meshNewStart = SysTime()
		local m = Mesh( buf.material )
		meshPerfAdd( meshPerf, "meshNewMS", meshNewStart )
		local buildTrianglesStart = SysTime()
		m:BuildFromTriangles( buf.verts )
		meshPerfAdd( meshPerf, "buildTriMS", buildTrianglesStart )
		buf.list[#buf.list + 1] = m
		buf.records[#buf.records + 1] = {
			mesh = m,
			verts = buf.verts,
			light = buf.light,
			material = buf.material,
			vertexCount = vertexCount,
		}
		meshPerf.vertices = meshPerf.vertices + vertexCount
		meshPerf.faces = meshPerf.faces + math.floor( vertexCount / 6 )
		meshPerf.meshes = meshPerf.meshes + 1
		if buf.translucent then
			meshPerf.translucentVerts = meshPerf.translucentVerts + vertexCount
		else
			meshPerf.opaqueVerts = meshPerf.opaqueVerts + vertexCount
		end
		buf.verts = {}
		buf.light = {}
		buf.nv = 0
	end

	local function push( vert, light )
		local nv = cur.nv + 1
		cur.nv = nv
		cur.verts[nv] = vert
		cur.light[nv] = light
		if not cur.cacheOnly then
			meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + 1
			if nv >= C.VERT_LIMIT then flush( cur ) end
		end
	end

	local function lightMeta( shade, bx, by, bz, id, faceIndex, corner, selfEmission )
		local cx, cy, cz = cornerXYZ( corner )
		return {
			shade = shade,
			bx = bx,
			by = by,
			bz = bz,
			id = id,
			faceIndex = faceIndex,
			cx = cx,
			cy = cy,
			cz = cz,
			selfEmission = selfEmission,
		}
	end

	local function lightMetaValues( shade, bx, by, bz, id, faceIndex, cx, cy, cz, selfEmission )
		return {
			shade = shade,
			bx = bx,
			by = by,
			bz = bz,
			id = id,
			faceIndex = faceIndex,
			cx = cx,
			cy = cy,
			cz = cz,
			selfEmission = selfEmission,
		}
	end

	local function appendMeshList( out, list )
		for i = 1, #list do
			out[#out + 1] = list[i]
		end
	end

	local function flushSectionBuffers()
		local opaqueMeshes = {}
		local translucentMeshes = {}
		local opaqueRecords = {}
		local translucentRecords = {}
		local totalSections = C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = sectionBuffers[i]
			if buffers then
				flush( buffers.opaque )
				flush( buffers.translucent )
				appendMeshList( opaqueMeshes, buffers.opaque.list )
				appendMeshList( translucentMeshes, buffers.translucent.list )
				appendMeshList( opaqueRecords, buffers.opaque.records )
				appendMeshList( translucentRecords, buffers.translucent.records )
			end
		end
		return opaqueMeshes, translucentMeshes, opaqueRecords, translucentRecords
	end

	local function emitQuad( corners, normal, color, tile, bx, by, bz, id, faceIndex )
		local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
		local colors = quadCornerColors( color, bx, by, bz, id, faceIndex, corners, emission, meshLightStyle )
		for t = 1, 6 do
			local ci = C.TRI[t]
			local cn = corners[ci]
			local u, v = tileUVPointRaw( tile, cn[4], cn[5] )
			push( {
				pos    = Vector( cn[1], cn[2], cn[3] ),
				normal = normal,
				u      = u,
				v      = v,
				color  = colors[ci],
			}, lightMeta( color, bx, by, bz, id, faceIndex, cn, emission ) )
		end
	end

	local function emitCrossBlock( id, bx, by, bz, wx, wy, wz )
		local b = MC.Blocks[id]
		local tile = b and b.side or 0
		local z0, z1 = wz, wz + C.BS
		local a, c = 0.08 * C.BS, 0.92 * C.BS
		local p1 = {
			{ wx + a, wy + a, z0, 0, 16 },
			{ wx + c, wy + c, z0, 16, 16 },
			{ wx + c, wy + c, z1, 16, 0 },
			{ wx + a, wy + a, z1, 0, 0 },
		}
		local p2 = {
			{ wx + c, wy + a, z0, 0, 16 },
			{ wx + a, wy + c, z0, 16, 16 },
			{ wx + a, wy + c, z1, 16, 0 },
			{ wx + c, wy + a, z1, 0, 0 },
		}
		emitQuad( p1, C.N_YP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.YP )
		emitQuad( { p1[4], p1[3], p1[2], p1[1] }, C.N_YN, C.SH_TOP, tile, bx, by, bz, id, MC.Face.YN )
		emitQuad( p2, C.N_XP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.XP )
		emitQuad( { p2[4], p2[3], p2[2], p2[1] }, C.N_XN, C.SH_TOP, tile, bx, by, bz, id, MC.Face.XN )
	end

	local function emitModelBlock( b, orient, bx, by, bz, wx, wy, wz )
		local quads = rotatedModelQuads( b, orient )
		if not quads then return false end
		local mirrorU = b.orient == "door"
		local emission = MC.BlockLightEmission and MC.BlockLightEmission( b.id ) or 0
		for _, quad in ipairs( quads ) do
			local faceIndex = quad.face or MC.Face.TOP
			local face = C.FACES[faceIndex] or C.FACES[MC.Face.TOP]
			local u0, v0, u1, v1 = tileUVRect( quad.tile or 0, quad.uv )
			local colors = quadCornerColors( face.sh, bx, by, bz, b.id, faceIndex, quad.verts, emission, meshLightStyle )
			for t = 1, 6 do
				local ci = C.TRI[t]
				local vert = quad.verts[ci]
				local uf, vf = rotatedUVFlags( vert.u or 0, vert.v or 0, quad.rot or 0 )
				if mirrorU then uf = 1 - uf end
				push( {
					pos    = Vector( wx + vert.x * C.BS, wy + vert.y * C.BS, wz + vert.z * C.BS ),
					normal = face.n,
					u      = uf == 1 and u1 or u0,
					v      = vf == 1 and v1 or v0,
					color  = colors[ci],
				}, lightMeta( face.sh, bx, by, bz, b.id, faceIndex, vert, emission ) )
			end
		end
		return true
	end

	local function emitFluidQuad( verts, normal, shade, tile, bx, by, bz, id, faceIndex, lightCorners, uvCorners )
		local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
		local colors = quadCornerColors( shade, bx, by, bz, id, faceIndex, lightCorners, emission, meshLightStyle )
		for t = 1, 6 do
			local ci = C.TRI[t]
			local vert = verts[ci]
			local uv = uvCorners[ci]
			local u, v = tileUVPointRaw( tile, uv and uv[1], uv and uv[2] )
			push( {
				pos    = Vector( vert[1], vert[2], vert[3] ),
				normal = normal,
				u      = u,
				v      = v,
				color  = colors[ci],
			}, lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[ci], emission ) )
		end
	end

	local function emitLiquidBlock( id, orient, bx, by, bz, wx, wy, wz )
		local kind = MC.LiquidKind and MC.LiquidKind( id )
		if not kind then return false end

		local x0, y0, z0 = wx, wy, wz
		local x1, y1 = wx + C.BS, wy + C.BS
		local bottom = z0
		local hSelf = fluidHeightAt( bx, by, bz, kind )
		local hXN = fluidHeightAt( bx - 1, by, bz, kind )
		local hXP = fluidHeightAt( bx + 1, by, bz, kind )
		local hYN = fluidHeightAt( bx, by - 1, bz, kind )
		local hYP = fluidHeightAt( bx, by + 1, bz, kind )
		local h00, h10, h11, h01

		if hSelf >= 1.0 then
			h00, h10, h11, h01 = 1.0, 1.0, 1.0, 1.0
		else
			h00 = calculateAverageFluidHeight( kind, hSelf, hYN, hXN, bx - 1, by - 1, bz )
			h10 = calculateAverageFluidHeight( kind, hSelf, hYN, hXP, bx + 1, by - 1, bz )
			h11 = calculateAverageFluidHeight( kind, hSelf, hYP, hXP, bx + 1, by + 1, bz )
			h01 = calculateAverageFluidHeight( kind, hSelf, hYP, hXN, bx - 1, by + 1, bz )
		end

		local nbUp = MC.GetBlock( bx, by, bz + 1 )
		local renderUp = visible( id, nbUp, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz + 1 ) or 0 )
		local topOffset = renderUp and C.FLUID_FACE_OFFSET or 0
		local rh00 = math.max( h00 - topOffset, 0 )
		local rh10 = math.max( h10 - topOffset, 0 )
		local rh11 = math.max( h11 - topOffset, 0 )
		local rh01 = math.max( h01 - topOffset, 0 )
		local z00, z10, z11, z01 = z0 + rh00 * C.BS, z0 + rh10 * C.BS, z0 + rh11 * C.BS, z0 + rh01 * C.BS
		local tile

		if renderUp then
			tile = MC.BlockFace( id, MC.Face.TOP, orient )
			emitFluidQuad(
				{ { x0, y0, z00 }, { x1, y0, z10 }, { x1, y1, z11 }, { x0, y1, z01 } },
				C.N_UP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.TOP,
				{ { 0, 0, rh00 }, { 1, 0, rh10 }, { 1, 1, rh11 }, { 0, 1, rh01 } },
				{ { 0, 16 }, { 16, 16 }, { 16, 0 }, { 0, 0 } }
			)
		end

		local nbDown = MC.GetBlock( bx, by, bz - 1 )
		local renderDown = visible( id, nbDown, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz - 1 ) or 0 )
		local bottomZ = bottom + ( renderDown and C.FLUID_FACE_OFFSET or 0 ) * C.BS
		if renderDown then
			tile = MC.BlockFace( id, MC.Face.BOTTOM, orient )
			emitFluidQuad(
				{ { x0, y1, bottomZ }, { x1, y1, bottomZ }, { x1, y0, bottomZ }, { x0, y0, bottomZ } },
				C.N_DOWN, C.SH_BOTTOM, tile, bx, by, bz, id, MC.Face.BOTTOM,
				{ { 0, 1, 0 }, { 1, 1, 0 }, { 1, 0, 0 }, { 0, 0, 0 } },
				{ { 0, 16 }, { 16, 16 }, { 16, 0 }, { 0, 0 } }
			)
		end

		local function sideV( height )
			return math.Clamp( ( 1 - height ) * 8, 0, 8 )
		end

		local sideBottomV = 8
		local sideBottom = bottomZ
		local sideInset = C.FLUID_FACE_OFFSET * C.BS

		if visible( id, MC.GetBlock( bx + 1, by, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx + 1, by, bz ) or 0 ) then
			tile = MC.BlockFace( id, MC.Face.XP, orient )
			local sx = x1 - sideInset
			emitFluidQuad(
				{ { sx, y0, sideBottom }, { sx, y1, sideBottom }, { sx, y1, z11 }, { sx, y0, z10 } },
				C.N_XP, C.SH_X, tile, bx, by, bz, id, MC.Face.XP,
				{ { 1, 0, 0 }, { 1, 1, 0 }, { 1, 1, rh11 }, { 1, 0, rh10 } },
				{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh11 ) }, { 0, sideV( rh10 ) } }
			)
		end

		if visible( id, MC.GetBlock( bx - 1, by, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx - 1, by, bz ) or 0 ) then
			tile = MC.BlockFace( id, MC.Face.XN, orient )
			local sx = x0 + sideInset
			emitFluidQuad(
				{ { sx, y1, sideBottom }, { sx, y0, sideBottom }, { sx, y0, z00 }, { sx, y1, z01 } },
				C.N_XN, C.SH_X, tile, bx, by, bz, id, MC.Face.XN,
				{ { 0, 1, 0 }, { 0, 0, 0 }, { 0, 0, rh00 }, { 0, 1, rh01 } },
				{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh00 ) }, { 0, sideV( rh01 ) } }
			)
		end

		if visible( id, MC.GetBlock( bx, by + 1, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx, by + 1, bz ) or 0 ) then
			tile = MC.BlockFace( id, MC.Face.YP, orient )
			local sy = y1 - sideInset
			emitFluidQuad(
				{ { x1, sy, sideBottom }, { x0, sy, sideBottom }, { x0, sy, z01 }, { x1, sy, z11 } },
				C.N_YP, C.SH_Y, tile, bx, by, bz, id, MC.Face.YP,
				{ { 1, 1, 0 }, { 0, 1, 0 }, { 0, 1, rh01 }, { 1, 1, rh11 } },
				{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh01 ) }, { 0, sideV( rh11 ) } }
			)
		end

		if visible( id, MC.GetBlock( bx, by - 1, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx, by - 1, bz ) or 0 ) then
			tile = MC.BlockFace( id, MC.Face.YN, orient )
			local sy = y0 + sideInset
			emitFluidQuad(
				{ { x0, sy, sideBottom }, { x1, sy, sideBottom }, { x1, sy, z10 }, { x0, sy, z00 } },
				C.N_YN, C.SH_Y, tile, bx, by, bz, id, MC.Face.YN,
				{ { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, rh10 }, { 0, 0, rh00 } },
				{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh10 ) }, { 0, sideV( rh00 ) } }
			)
		end

		return true
	end

	local blockIter = chunk.blocks
	if sectionIndex then
		local indexStart = SysTime()
		local bySection = ensureChunkRenderSectionIndex( chunk )
		meshPerfAdd( meshPerf, "indexMS", indexStart )
		blockIter = bySection and bySection[sectionIndex] or {}
	end
	meshPerf.prepMS = meshPerfMS( buildStart )

	local loopStart = SysTime()
	for li, id in pairs( blockIter ) do
		meshPerf.blocksVisited = meshPerf.blocksVisited + 1
		local orient = MC.NormalizeOrient( id, chunk.orients[li] )
		local lx, ly, lz = DecodeLocal( li )
		local buffers = buffersForLocal( lx, ly, lz )
		if not buffers then continue end
		local bx, by, bz = bxo + lx, byo + ly, bzo + lz
		local wx, wy, wz = lx * C.BS, ly * C.BS, lz * C.BS
		local blockSectionIndex = MC.RenderSectionIndexForLocal( lx, ly, lz )

		local targetBuffer = ( MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) ) and buffers.translucent or buffers.opaque
		local cached = MC.GetCachedBlockEmission( key, blockSectionIndex, li, id, orient )
		local blockNeedsRecolor = sectionNeedsFullRecolor or ( blockLightDirtySection and blockLightDirtySection[li] )
		if cached and ( blockNeedsRecolor or cached.lightStyle ~= meshLightStyle ) then
			local recolorStart = SysTime()
			if recolorCachedBlockEmission( cached, meshLightStyle ) then
				meshPerfAdd( meshPerf, "recolorMS", recolorStart )
				meshPerf.blockCacheRecolors = meshPerf.blockCacheRecolors + 1
			else
				MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
				cached = nil
			end
		end
		if cached then
			meshPerf.blockCacheHits = meshPerf.blockCacheHits + 1
			local appended = MC.AppendCachedBlockEmission( cached, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
			if appended > 0 then meshPerf.blocksRendered = meshPerf.blocksRendered + 1 end
			local cachedKind = cached.kind or "shape"
			meshPerfAddBlockKind( meshPerf, cachedKind )
			continue
		end

		meshPerf.blockCacheMisses = meshPerf.blockCacheMisses + 1
		cur = nil

		local emitStart = SysTime()
		local emitKind = "shape"
		local directEmitCheapFullCube = false
		local directEmitVertexCount = 0
		local b = blocksById[id]
		if b and b.shape == "cross" then
			emitKind = "cross"
			prepareBlockCacheBuffer( targetBuffer )
			emitCrossBlock( id, bx, by, bz, wx, wy, wz )
		elseif b and b.shape == "model" and not ( ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) or ( MC.IsWallBlock and MC.IsWallBlock( id ) ) or b.connection == "pipe6" ) and prepareBlockCacheBuffer( targetBuffer ) and emitModelBlock( b, orient, bx, by, bz, wx, wy, wz ) then
			emitKind = "model"
			-- rendered from exact Minecraft model quads; boxes remain for collision/outline
		elseif isLiquidBlock( id ) and prepareBlockCacheBuffer( targetBuffer ) and emitLiquidBlock( id, orient, bx, by, bz, wx, wy, wz ) then
			emitKind = "liquid"
			-- rendered with Minecraft fluid surface height/offsets instead of full cube faces
		elseif MC.BlockIsFullCube and blockIsFullCube and blockIsFullCube( id, orient ) then
			emitKind = "fullCube"
			local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
			local visibleFaceCount = 0
			for f = 1, 6 do
				local face = C.FACES[f]
				local o = face.off
				if visibleAt( id, lx + o[1], ly + o[2], lz + o[3], bx + o[1], by + o[2], bz + o[3] ) then
					visibleFaceCount = visibleFaceCount + 1
				end
			end
			directEmitVertexCount = visibleFaceCount * 6
			directEmitCheapFullCube = not shouldStoreBlockEmissionCache( emitKind, directEmitVertexCount )
			if directEmitCheapFullCube then
				if targetBuffer.nv + directEmitVertexCount >= C.VERT_LIMIT then flush( targetBuffer ) end
				cur = targetBuffer
			else
				prepareBlockCacheBuffer( targetBuffer )
			end
			for f = 1, 6 do
				local face = C.FACES[f]
				local o = face.off
				local nbx, nby, nbz = bx + o[1], by + o[2], bz + o[3]
				if visibleAt( id, lx + o[1], ly + o[2], lz + o[3], nbx, nby, nbz ) then
					local baked = bakedFaceData( id, f, orient )
					local tile, rot, flipU, flipV
					local u0, v0, u1, v1
					if baked then
						tile = baked.tile
						rot = baked.rot or 0
						u0, v0, u1, v1 = tileUVRect( tile, baked.uv )
					else
						tile, rot, flipU, flipV = MC.BlockFace( id, f, orient )
						u0, v0, u1, v1 = MC.TileUV( tile )
					end
					local corners = face.c
					local nrm, col = face.n, face.sh
					local colors = quadCornerColors( col, bx, by, bz, id, f, corners, emission, meshLightStyle )

					for t = 1, 6 do
						local ci = C.TRI[t]
						local cn = corners[ci]
						local u, v
						if baked and baked.uvs then
							local uv = baked.uvs[ci]
							u, v = tileUVPointRaw( tile, uv and uv[1], uv and uv[2] )
						else
							local uf, vf = rotatedUVFlags( cn[4], cn[5], rot or 0, flipU, flipV )
							u = uf == 1 and u1 or u0
							v = vf == 1 and v1 or v0
						end
						push( {
							pos    = Vector( wx + cn[1] * C.BS, wy + cn[2] * C.BS, wz + cn[3] * C.BS ),
							normal = nrm,
							u      = u,
							v      = v,
							color  = colors[ci],
						}, lightMeta( col, bx, by, bz, id, f, cn, emission ) )
					end
				end
			end
		else
			-- fence/pane/wall/pipe boxes come from the runtime connection logic, so their
			-- indices do not line up with the generator's static boxFaces list;
			-- only the centre post (box 1) may take static face data
			prepareBlockCacheBuffer( targetBuffer )
			local isPipe6Shape = b and b.connection == "pipe6"
			local isConnShape = ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) or ( MC.IsWallBlock and MC.IsWallBlock( id ) ) or isPipe6Shape
			local boxes = blockBoxes and blockBoxes( id, orient, bx, by, bz ) or nil
			local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
			for boxIndex, box in ipairs( boxes or {} ) do
				for f = 1, 6 do
					if not shapeFaceCoveredAt( id, box, f, boxes, bx, by, bz, lx, ly, lz ) then
						local face = C.FACES[f]
						local modelFaces = b and b.boxFaces
						if isPipe6Shape then modelFaces = nil end
						local fd = modelFaces and modelFaces[boxIndex] and modelFaces[boxIndex][f]
						if isConnShape and boxIndex > 1 then fd = nil end
						local dynamicFd = dynamicShapeFaceData( b, f, box )
						if not modelFaces or fd or dynamicFd then
							fd = fd or dynamicFd
							local tile = fd and fd.tile or MC.BlockFace( id, f, orient )
							local u0, v0, u1, v1
							if fd and fd.uv then
								u0, v0, u1, v1 = tileUVRect( tile, fd.uv )
							end
							local nrm, col = face.n, face.sh
							local c1x, c1y, c1z = boxFaceCornerValues( box, f, 1 )
							local c2x, c2y, c2z = boxFaceCornerValues( box, f, 2 )
							local c3x, c3y, c3z = boxFaceCornerValues( box, f, 3 )
							local c4x, c4y, c4z = boxFaceCornerValues( box, f, 4 )
							local color1, color2, color3, color4 = quadCornerColorValues(
								col, bx, by, bz, id, f, emission, meshLightStyle,
								c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
							)
							for t = 1, 6 do
								local ci = C.TRI[t]
								local cx, cy, cz, color
								if ci == 1 then
									cx, cy, cz, color = c1x, c1y, c1z, color1
								elseif ci == 2 then
									cx, cy, cz, color = c2x, c2y, c2z, color2
								elseif ci == 3 then
									cx, cy, cz, color = c3x, c3y, c3z, color3
								else
									cx, cy, cz, color = c4x, c4y, c4z, color4
								end
								local u, v
								if fd and fd.uv then
									local flags = BOX_UV_FLAGS[ci]
									local uf, vf = rotatedUVFlags( flags[1], flags[2], fd.rot or 0 )
									u = uf == 1 and u1 or u0
									v = vf == 1 and v1 or v0
								else
									local cu, cv = cornerUV16Raw( f, cx, cy, cz )
									u, v = tileUVPointRaw( tile, cu, cv )
								end
								push( {
									pos    = Vector( wx + cx * C.BS, wy + cy * C.BS, wz + cz * C.BS ),
									normal = nrm,
									u      = u,
									v      = v,
									color  = color,
								}, lightMetaValues( col, bx, by, bz, id, f, cx, cy, cz, emission ) )
							end
						end
					end
				end
			end
		end
		local emittedVertices = directEmitCheapFullCube and directEmitVertexCount or ( cur and cur.nv or 0 )
		if directEmitCheapFullCube then
			MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
			if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
		else
			local blockRecord = {
				verts = cur.verts,
				light = cur.light,
				vertexCount = emittedVertices,
				material = targetBuffer.material,
				translucent = targetBuffer.translucent,
				kind = emitKind,
			}
			if shouldStoreBlockEmissionCache( emitKind, emittedVertices ) then
				blockRecord = MC.StoreBlockEmissionCache( key, blockSectionIndex, li, id, orient, meshLightStyle, blockRecord )
			else
				MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
				if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
			end
			MC.AppendCachedBlockEmission( blockRecord, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
		end
		if emittedVertices > 0 then
			meshPerf.blocksRendered = meshPerf.blocksRendered + 1
		end
		meshPerfAddBlockKind( meshPerf, emitKind )
		local emitMS = meshPerfElapsedMS( emitStart )
		meshPerf.emitMS = meshPerf.emitMS + emitMS
		meshPerfAddKindDuration( meshPerf, emitKind, emitMS )
	end
	meshPerfAdd( meshPerf, "loopMS", loopStart )

	local flushStart = SysTime()
	local opaqueMeshes, translucentMeshes, opaqueRecords, translucentRecords = flushSectionBuffers()
	meshPerfAdd( meshPerf, "flushMS", flushStart )

	local commitStart = SysTime()
	if sectionIndex then
		MC.MeshSections[key] = MC.MeshSections[key] or {}
		MC.MeshSectionGeometry[key] = MC.MeshSectionGeometry[key] or {}
		local old = MC.MeshSections[key][sectionIndex]
		if old then
			local destroyStart = SysTime()
			destroySectionMeshList( old.opaque )
			destroySectionMeshList( old.translucent )
			meshPerfAdd( meshPerf, "destroyMS", destroyStart )
		end
		if #opaqueMeshes > 0 or #translucentMeshes > 0 then
			MC.MeshSections[key][sectionIndex] = { opaque = opaqueMeshes, translucent = translucentMeshes }
			MC.MeshSectionGeometry[key][sectionIndex] = { opaque = opaqueRecords, translucent = translucentRecords }
			if MC.TouchMeshSectionGeometryCache then MC.TouchMeshSectionGeometryCache( key, sectionIndex ) end
		else
			MC.MeshSections[key][sectionIndex] = nil
			MC.ClearSectionBlockEmitCache( key, sectionIndex )
			if MC.ForgetMeshSectionGeometryCacheSlot then
				MC.ForgetMeshSectionGeometryCacheSlot( key, sectionIndex )
			else
				MC.MeshSectionGeometry[key][sectionIndex] = nil
			end
		end
		MC.ClearSectionBlockEmitDirty( key, sectionIndex )
		MC.ClearSectionBlockLightDirty( key, sectionIndex )
		if MC.MeshLightDirty[key] then MC.MeshLightDirty[key][sectionIndex] = nil end
		local flatStart = SysTime()
		rebuildFlatMeshLists( key )
		meshPerfAdd( meshPerf, "flatMS", flatStart )
	else
		MC.MeshSections[key] = {}
		MC.MeshSectionGeometry[key] = {}
		if MC.ClearChunkMeshSectionGeometryLRU then MC.ClearChunkMeshSectionGeometryLRU( key ) end
		local totalSections = C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = sectionBuffers[i]
			if buffers then
				MC.MeshSections[key][i] = {
					opaque = buffers.opaque.list,
					translucent = buffers.translucent.list,
				}
				MC.MeshSectionGeometry[key][i] = {
					opaque = buffers.opaque.records,
					translucent = buffers.translucent.records,
				}
				if MC.TouchMeshSectionGeometryCache then MC.TouchMeshSectionGeometryCache( key, i ) end
			end
		end
		MC.MeshLightDirty[key] = nil
		local flatStart = SysTime()
		rebuildFlatMeshLists( key )
		meshPerfAdd( meshPerf, "flatMS", flatStart )
	end
	if MC.PruneMeshSectionGeometryCache then MC.PruneMeshSectionGeometryCache() end
	if MC.PruneBlockEmitCache then MC.PruneBlockEmitCache() end
	meshPerfAdd( meshPerf, "commitMS", commitStart )
	local meshMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
	MC.RenderStats.lastMeshBuildMS = meshMS
	MC.RenderStats.lastMeshKey = key
	MC.RenderStats.lastMeshSection = sectionIndex or "full"
	MC.RenderStats.lastMeshBlocks = chunk.count or 0
	MC.RenderStats.lastMeshVertices = meshPerf.vertices
	MC.RenderStats.lastMeshFaces = meshPerf.faces
	MC.RenderStats.lastOpaqueMeshes = #opaqueMeshes
	MC.RenderStats.lastTranslucentMeshes = #translucentMeshes
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshMode = "full"
		MC.LightPerfStats.lastMeshRecords = nil
		MC.LightPerfStats.lastMeshFallback = nil
	end
	publishMeshPerfStats( meshPerf )
	noteMeshLightingCacheStats()
	if MC.LightPerfEndMeshBuild then
		MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
	end
end

function MC.RebuildChunkMeshLighting( key, sectionIndex )
	if not sectionIndex then return MC.BuildChunkMesh( key ) end
	local buildStart = SysTime()
	local meshPerf = newMeshPerfStats()
	resetMeshLightingSampleCaches()
	local meshLightStyle = currentLightStyle()
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshLightStyle = meshLightStyle
	end
	if MC.LightPerfBeginMeshBuild then
		MC.LightPerfBeginMeshBuild( key, sectionIndex )
	end

	local chunk = MC.GetChunkByKey( key )
	local section = MC.MeshSectionGeometry[key] and MC.MeshSectionGeometry[key][sectionIndex]
	if not chunk or chunk.count == 0 or not section then
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshMode = "fallback"
			MC.LightPerfStats.lastMeshFallback = "missing_cache"
		end
		return MC.BuildChunkMesh( key, sectionIndex )
	end

	setMeshSampleCacheOrigin( chunk.cx * CS, chunk.cy * CS, chunk.cz * MC.CH )
	meshPerf.prepMS = meshPerfMS( buildStart )

	local scannedRecords, updatedRecords = 0, 0
	local blockLightDirtySection = MC.GetBlockLightDirtySection and MC.GetBlockLightDirtySection( key, sectionIndex ) or nil
	local blockEmitCacheSection = blockLightDirtySection and MC.MeshBlockEmitCache[key] and MC.MeshBlockEmitCache[key][sectionIndex] or nil
	local function recolorDirtyBlockRecords()
		if not blockLightDirtySection then return true end
		if not blockEmitCacheSection then return false end
		for li in pairs( blockLightDirtySection ) do
			local blockRecord = blockEmitCacheSection[li]
			if blockRecord then
				local recolorStart = SysTime()
				local ok = recolorCachedBlockEmission( blockRecord, meshLightStyle )
				meshPerfAdd( meshPerf, "recolorMS", recolorStart )
				if not ok then return false end
				meshPerf.blockCacheRecolors = meshPerf.blockCacheRecolors + 1
			end
		end
		return true
	end

	local function updateRecord( record, translucent, recolorWholeRecord )
		scannedRecords = scannedRecords + 1
		if not record or not record.mesh or not record.verts or not record.light then return false end
		if #record.verts ~= #record.light then return false end
		local vertexCount = #record.verts
		if recolorWholeRecord then
			local recolorStart = SysTime()
			if not recolorCachedBlockEmission( record, meshLightStyle ) then return false end
			meshPerfAdd( meshPerf, "recolorMS", recolorStart )
		end
		local buildTrianglesStart = SysTime()
		record.mesh:BuildFromTriangles( record.verts )
		meshPerfAdd( meshPerf, "buildTriMS", buildTrianglesStart )
		meshPerf.vertices = meshPerf.vertices + vertexCount
		meshPerf.faces = meshPerf.faces + math.floor( vertexCount / 6 )
		meshPerf.meshes = meshPerf.meshes + 1
		if translucent then
			meshPerf.translucentVerts = meshPerf.translucentVerts + vertexCount
		else
			meshPerf.opaqueVerts = meshPerf.opaqueVerts + vertexCount
		end
		updatedRecords = updatedRecords + 1
		return true
	end

	local function updateList( list, translucent, recolorWholeRecord )
		for i = 1, #( list or {} ) do
			if not updateRecord( list[i], translucent, recolorWholeRecord ) then return false end
		end
		return true
	end

	local loopStart = SysTime()
	local recolorWholeRecord = not blockLightDirtySection
	local updateOK = recolorDirtyBlockRecords()
		and updateList( section.opaque, false, recolorWholeRecord )
		and updateList( section.translucent, true, recolorWholeRecord )
	meshPerfAdd( meshPerf, "loopMS", loopStart )
	if not updateOK then
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshMode = "fallback"
			MC.LightPerfStats.lastMeshFallback = "invalid_cache"
			MC.LightPerfStats.lastMeshRecords = tostring( updatedRecords ) .. "/" .. tostring( scannedRecords )
		end
		return MC.BuildChunkMesh( key, sectionIndex )
	end
	MC.ClearSectionBlockLightDirty( key, sectionIndex )
	if MC.TouchMeshSectionGeometryCache then MC.TouchMeshSectionGeometryCache( key, sectionIndex ) end
	if MC.PruneMeshSectionGeometryCache then MC.PruneMeshSectionGeometryCache() end

	local meshMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
	MC.RenderStats.lastMeshBuildMS = meshMS
	MC.RenderStats.lastMeshKey = key
	MC.RenderStats.lastMeshSection = sectionIndex
	MC.RenderStats.lastMeshBlocks = chunk.count or 0
	MC.RenderStats.lastMeshVertices = meshPerf.vertices
	MC.RenderStats.lastMeshFaces = meshPerf.faces
	MC.RenderStats.lastOpaqueMeshes = #( section.opaque or {} )
	MC.RenderStats.lastTranslucentMeshes = #( section.translucent or {} )
	if MC.LightPerfStats then
		MC.LightPerfStats.lastMeshMode = "light"
		MC.LightPerfStats.lastMeshRecords = tostring( updatedRecords ) .. "/" .. tostring( scannedRecords )
		MC.LightPerfStats.lastMeshFallback = nil
	end
	publishMeshPerfStats( meshPerf )
	noteMeshLightingCacheStats()
	if MC.LightPerfEndMeshBuild then
		MC.LightPerfEndMeshBuild( key, sectionIndex, meshMS )
	end
end
