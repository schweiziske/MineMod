-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}

local function atlasPngPath( path )
	path = path or "mc/atlas_365"
	path = path:gsub( "%.vmt$", "" )
	if path:sub( -4 ) == ".png" then return path end
	return path .. ".png"
end

-- single atlas material: alpha cutout (glass/leaves), vertex-shaded, backface-culled
MC.Material = Material( atlasPngPath( MC.Atlas.MATERIAL or "mc/atlas_365" ), "alphatest vertexcolor" )
MC.MaterialOpaqueCPU = MC.Material

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

local function materialBaseTexture( material )
	local baseTex = material and material.GetTexture and material:GetTexture( "$basetexture" )
	local baseName = baseTex and not baseTex:IsError() and baseTex.GetName and baseTex:GetName() or nil
	return baseTex, baseName
end

local function atlasBaseTexture()
	return materialBaseTexture( MC.Material )
end

MC.MaterialGpuOpaque = nil
do
	local baseTex, baseName = atlasBaseTexture()
	if baseTex and baseName and baseName ~= "" and CreateMaterial then
		local mat = CreateMaterial( "mc_atlas_gpu_payload4_opaque", "screenspace_general", {
			["$pixshader"] = "mc_gpu_chunk_payload_ps30",
			["$vertexshader"] = "mc_gpu_chunk_payload_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
		} )
		if mat and not mat:IsError() then
			mat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuOpaque = mat
		end
	end
end

local function gpuChunkShaderEnabled()
	local cv = MC.MeshGpuShader
	if not ( cv and cv.GetBool and cv:GetBool() ) then return false end
	if not ( MC.MaterialGpuOpaque and not MC.MaterialGpuOpaque:IsError() ) then return false end
	if MC.CurrentMeshLightStyle and MC.CurrentMeshLightStyle() ~= "shader" then return false end
	return true
end

function MC.UsingGpuChunkShader()
	return gpuChunkShaderEnabled() == true
end

function MC.CurrentChunkMaterial( translucent )
	if translucent then return MC.MaterialTranslucent or MC.Material end
	if gpuChunkShaderEnabled() then return MC.MaterialGpuOpaque end
	return MC.Material
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_gpu_shader", function()
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "gpu_shader_toggle" ) end
	end, "mc_mesh_gpu_shader_rebuild" )
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
	local baseTex, baseName = atlasBaseTexture()
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
