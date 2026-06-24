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

local function createLightmappedAtlasMaterial( name, sourceMaterial, fallbackMaterial, extraParams )
	if not CreateMaterial then return fallbackMaterial end
	local baseTex, baseName = materialBaseTexture( sourceMaterial )
	if not baseName or baseName == "" then return fallbackMaterial end
	local params = {
		["$basetexture"] = baseName,
		["$vertexcolor"] = "1",
		["$alphatest"] = "1",
		["$alphatestreference"] = "0.5",
		["$nocull"] = "0",
		["$pointsample"] = "1",
	}
	for key, value in pairs( extraParams or {} ) do
		params[key] = value
	end
	local mat = CreateMaterial( name, "LightmappedGeneric", params )
	if mat and not mat:IsError() then
		mat:SetTexture( "$basetexture", baseTex )
		return mat
	end
	return fallbackMaterial
end

-- CreateMaterial returns an already-cached IMaterial when the name matches, so
-- keep a versioned name for hot-reloadable shader parameter changes.
local LIGHTMAPPED_MATERIAL_VERSION = "v3"
MC.MaterialLightmapped = createLightmappedAtlasMaterial( "mc_atlas_lightmapped_" .. LIGHTMAPPED_MATERIAL_VERSION, MC.Material, MC.Material )
MC.MaterialLightmappedTranslucent = createLightmappedAtlasMaterial( "mc_atlas_lightmapped_translucent_" .. LIGHTMAPPED_MATERIAL_VERSION, MC.MaterialTranslucent, MC.MaterialTranslucent, {
	["$alphatest"] = "0",
	["$vertexalpha"] = "1",
	["$translucent"] = "1",
} )

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
