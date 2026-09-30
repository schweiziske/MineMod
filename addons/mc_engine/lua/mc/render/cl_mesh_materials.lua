-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
-- Core materials provide atlas textures and CPU vertex colours only.

local function atlasPngPath( path )
	path = path or "mc/atlas_365"
	path = path:gsub( "%.vmt$", "" )
	if path:sub( -4 ) == ".png" then return path end
	return path .. ".png"
end

local function atlasMaterialTexture( material )
	local texture = material and material.GetTexture and material:GetTexture( "$basetexture" ) or nil
	if not texture or ( texture.IsError and texture:IsError() ) then return nil end
	return texture
end

local function loadAtlasSource( path )
	-- Material() caches generated PNG materials. Older texture-pack code changed
	-- the cached "alphatest vertexcolor" object itself, so asking for that same
	-- object after a Lua refresh can return its stale/error $basetexture. Use a
	-- separate, read-only PNG material cache entry and only copy its ITexture to
	-- the mutable render proxies below.
	return Material( atlasPngPath( path ), "noclamp mips" )
end

local function loadAtlasIconSource( path )
	-- Generated PNG materials are cached by path, including whether their
	-- ITexture was created with mipmaps. The translucent atlas is a byte-for-byte
	-- copy, so reserve that cache key for crisp UI icons while the opaque path
	-- keeps the mip chain used by world rendering.
	return Material( atlasPngPath( path ), "noclamp alphatest vertexcolor" )
end

local function createCpuAtlasProxy( name, texture, translucent )
	local textureName = texture and texture.GetName and texture:GetName() or nil
	if not ( CreateMaterial and textureName and textureName ~= "" ) then return nil end
	local params = {
		["$basetexture"] = textureName,
		["$vertexcolor"] = "1",
		["$nocull"] = "0",
	}
	if translucent then
		params["$translucent"] = "1"
	else
		params["$alphatest"] = "1"
		params["$alphatestreference"] = "0.5"
	end
	local material = CreateMaterial( name, "UnlitGeneric", params )
	if not material or material:IsError() then return nil end
	material:SetTexture( "$basetexture", texture )
	return material
end

-- Source materials remain immutable. Chunk meshes reference separate proxy
-- materials whose textures can be changed repeatedly without corrupting the
-- saved default source during Lua refreshes.
local defaultOpaqueSource = loadAtlasSource( MC.Atlas.MATERIAL or "mc/atlas_365" )
local defaultOpaqueTexture = atlasMaterialTexture( defaultOpaqueSource )

local defaultTranslucentSource = defaultOpaqueSource
local defaultTranslucentTexture = defaultOpaqueTexture
local defaultIconSource = loadAtlasIconSource(
	MC.Atlas.MATERIAL_TRANSLUCENT or "mc/atlas_365_translucent"
)
local defaultIconTexture = atlasMaterialTexture( defaultIconSource ) or defaultOpaqueTexture

MC.Material = createCpuAtlasProxy( "mc_atlas_cpu_opaque_proxy1", defaultOpaqueTexture, false ) or defaultOpaqueSource
MC.MaterialOpaqueCPU = MC.Material
MC.MaterialTranslucent = createCpuAtlasProxy( "mc_atlas_cpu_translucent_proxy1", defaultTranslucentTexture, true )
	 or MC.Material

-- The proxy materials above are recreated with the default atlas on every map
-- load/Lua refresh. An old global value must not make startup sync believe the
-- newly-created proxies already use that pack.
MC.ActiveTexturePack = nil

local AtlasSources = {
	default = {
		opaque = defaultOpaqueSource,
		translucent = defaultTranslucentSource,
		icon = defaultIconSource,
		opaqueTexture = defaultOpaqueTexture,
		translucentTexture = defaultTranslucentTexture,
		iconTexture = defaultIconTexture,
		atlasProfile = "default",
	},
	programmer_art = {
		opaquePath = atlasPngPath( MC.Atlas.MATERIAL_PROGRAMMER_ART or "mc/atlas_365_programmer_art" ),
		translucentPath = atlasPngPath( MC.Atlas.MATERIAL_PROGRAMMER_ART_TRANSLUCENT or "mc/atlas_365_programmer_art_translucent" ),
		iconPath = atlasPngPath( MC.Atlas.MATERIAL_PROGRAMMER_ART_TRANSLUCENT or "mc/atlas_365_programmer_art_translucent" ),
		atlasProfile = "default",
	},
}

MC.TexturePackDefinitions = MC.TexturePackDefinitions or {}
MC.TexturePackLeases = MC.TexturePackLeases or {}
MC.TexturePackLeaseSerial = MC.TexturePackLeaseSerial or 0
MC.TexturePackRevision = MC.TexturePackRevision or 0

local refreshTexturePackSelection

local function normalizeTexturePackName( value )
	value = string.lower( tostring( value or "" ) )
	value = string.match( value, "^%s*(.-)%s*$" ) or ""
	if value == "" or not string.match( value, "^[a-z0-9_%-]+$" ) then return nil end
	return value
end

local function normalizeAtlasPath( value )
	value = tostring( value or "" )
	value = string.match( value, "^%s*(.-)%s*$" ) or ""
	value = string.gsub( value, "\\", "/" )
	value = string.gsub( value, "%.vmt$", "" )
	value = string.gsub( value, "%.png$", "" )
	if value == "" or string.find( value, "%.%.", 1, true ) then return nil end
	if not string.match( value, "^[a-zA-Z0-9_/%-]+$") then return nil end
	return value
end

local function normalizeTexturePackOwner( value )
	value = string.lower( tostring( value or "" ) )
	value = string.match( value, "^%s*(.-)%s*$" ) or ""
	if value == "" or #value > 96 or not string.match( value, "^[a-z0-9_%.:%-]+$" ) then return nil end
	return value
end

local function normalizeAtlasProfile( value )
	if not MC.NormalizeAtlasProfileName or not MC.AtlasProfileExists then
		value = string.lower( tostring( value or "default" ) )
		return value == "default" and "default" or nil
	end
	local name = MC.NormalizeAtlasProfileName( value ) or "default"
	if not MC.AtlasProfileExists( name ) then return nil end
	return name
end

local function atlasSourceFromDefinition( definition )
	if definition.inheritBase == true then
		return {
			custom = true,
			inheritBase = true,
			owner = definition.owner,
			atlasProfile = definition.atlasProfile or "default",
		}
	end
	return {
		opaquePath = atlasPngPath( definition.opaquePath ),
		translucentPath = atlasPngPath( definition.translucentPath ),
		iconPath = atlasPngPath( definition.iconPath ),
		custom = true,
		owner = definition.owner,
		atlasProfile = definition.atlasProfile or "default",
	}
end

for name, definition in pairs( MC.TexturePackDefinitions ) do
	if normalizeTexturePackName( name ) == name and type( definition ) == "table" then
		local inheritBase = definition.inheritBase == true
		local opaquePath = normalizeAtlasPath( definition.opaquePath )
		local translucentPath = normalizeAtlasPath( definition.translucentPath ) or opaquePath
		local iconPath = normalizeAtlasPath( definition.iconPath ) or translucentPath
		local owner = normalizeTexturePackOwner( definition.owner )
		local atlasProfile = normalizeAtlasProfile( definition.atlasProfile )
		if ( opaquePath or inheritBase ) and owner and atlasProfile then
			definition.inheritBase = inheritBase
			definition.opaquePath = opaquePath
			definition.translucentPath = translucentPath
			definition.iconPath = iconPath
			definition.owner = owner
			definition.atlasProfile = atlasProfile
			AtlasSources[name] = atlasSourceFromDefinition( definition )
		else
			MC.TexturePackDefinitions[name] = nil
		end
	else
		MC.TexturePackDefinitions[name] = nil
	end
end

function MC.RegisterTexturePack( name, definition, owner )
	name = normalizeTexturePackName( name )
	if not name or name == "default" or name == "programmer_art" then
		return false, "invalid_texture_pack_name"
	end
	if type( definition ) ~= "table" then return false, "invalid_texture_pack_definition" end
	for field, limit in pairs( { title = 128, description = 1024 } ) do
		local value = definition[field]
		if value ~= nil and ( type( value ) ~= "string" or #value > limit or value:find( "%z" ) ) then
			return false, "invalid_texture_pack_" .. field
		end
	end
	local preview
	if definition.preview ~= nil then
		if type( definition.preview ) ~= "string" or #definition.preview > 256 then return false, "invalid_texture_pack_preview" end
		preview = normalizeAtlasPath( definition.preview )
		if not preview then return false, "invalid_texture_pack_preview" end
	end
	owner = normalizeTexturePackOwner( owner )
	if not owner or owner == "mc" then return false, "invalid_texture_pack_owner" end
	local existing = MC.TexturePackDefinitions[name]
	if existing and existing.owner ~= owner then return false, "owned_by_" .. tostring( existing.owner ) end
	local inheritBase = definition.inheritBase == true
	local opaquePath = normalizeAtlasPath( definition.opaque or definition.opaquePath or definition.material )
	if not opaquePath and not inheritBase then return false, "invalid_opaque_atlas_path" end
	local translucentPath = normalizeAtlasPath( definition.translucent or definition.translucentPath ) or opaquePath
	local iconPath = normalizeAtlasPath( definition.icon or definition.iconPath ) or translucentPath
	local atlasProfile = normalizeAtlasProfile( definition.atlasProfile or definition.profile )
	if not atlasProfile then return false, "atlas_profile_not_registered" end
	local profileOwner = MC.AtlasProfileDefinitionOwner and MC.AtlasProfileDefinitionOwner( atlasProfile ) or "mc"
	if profileOwner ~= "mc" and profileOwner ~= owner then
		return false, "atlas_profile_owned_by_" .. tostring( profileOwner )
	end

	local previousDefinition = existing
	local previousSource = AtlasSources[name]
	local stored = {
		name = name,
		owner = owner,
		title = definition.title,
		description = definition.description,
		preview = preview,
		inheritBase = inheritBase,
		opaquePath = opaquePath,
		translucentPath = translucentPath,
		iconPath = iconPath,
		atlasProfile = atlasProfile,
	}
	MC.TexturePackDefinitions[name] = stored
	AtlasSources[name] = atlasSourceFromDefinition( stored )
	MC.TexturePackRevision = MC.TexturePackRevision + 1
	if refreshTexturePackSelection then
		local ok, err = refreshTexturePackSelection( true )
		if not ok then
			MC.TexturePackDefinitions[name] = previousDefinition
			AtlasSources[name] = previousSource
			MC.TexturePackRevision = MC.TexturePackRevision + 1
			refreshTexturePackSelection( true )
			return false, err
		end
	end
	if hook and hook.Run then hook.Run( "MC.TexturePackRegistered", name, owner ) end
	return true, name
end

function MC.UnregisterTexturePack( name, owner )
	name = normalizeTexturePackName( name )
	owner = normalizeTexturePackOwner( owner )
	if not name or not owner then return false, "invalid_texture_pack_owner" end
	local existing = MC.TexturePackDefinitions[name]
	if not existing then return false, "not_registered" end
	if existing.owner ~= owner then return false, "owner_mismatch" end

	local removedDefinition = existing
	local removedSource = AtlasSources[name]
	local removedLeases = {}
	MC.TexturePackDefinitions[name] = nil
	AtlasSources[name] = nil
	for leaseOwner, lease in pairs( MC.TexturePackLeases ) do
		if lease.name == name then
			removedLeases[leaseOwner] = lease
			MC.TexturePackLeases[leaseOwner] = nil
		end
	end
	MC.TexturePackRevision = MC.TexturePackRevision + 1
	if refreshTexturePackSelection then
		local current = MC.ActiveTexturePack
		if current == name then MC.ActiveTexturePack = nil end
		local ok, err = refreshTexturePackSelection( true )
		if not ok then
			MC.TexturePackDefinitions[name] = removedDefinition
			AtlasSources[name] = removedSource
			for leaseOwner, lease in pairs( removedLeases ) do MC.TexturePackLeases[leaseOwner] = lease end
			MC.ActiveTexturePack = current
			MC.TexturePackRevision = MC.TexturePackRevision + 1
			refreshTexturePackSelection( true )
			return false, err
		end
	end
	if hook and hook.Run then hook.Run( "MC.TexturePackUnregistered", name, owner ) end
	return true
end

function MC.UnregisterTexturePackOwner( owner )
	owner = normalizeTexturePackOwner( owner )
	if not owner then return 0 end
	local names = {}
	for name, definition in pairs( MC.TexturePackDefinitions ) do
		if definition.owner == owner then names[#names + 1] = name end
	end
	local removedLease = MC.TexturePackLeases[owner]
	MC.TexturePackLeases[owner] = nil
	for _, name in ipairs( names ) do
		MC.TexturePackDefinitions[name] = nil
		AtlasSources[name] = nil
	end
	if #names > 0 then MC.TexturePackRevision = MC.TexturePackRevision + 1 end
	if refreshTexturePackSelection then
		for _, name in ipairs( names ) do
			if MC.ActiveTexturePack == name then MC.ActiveTexturePack = nil break end
		end
		local ok, err = refreshTexturePackSelection( true )
		if not ok then
			if removedLease then MC.TexturePackLeases[owner] = removedLease end
			if ErrorNoHalt then
				ErrorNoHalt( "[MC] texture pack owner cleanup failed: " .. tostring( err ) .. "\n" )
			end
		end
	end
	if #names > 0 and hook and hook.Run then hook.Run( "MC.TexturePackOwnerUnregistered", owner, #names ) end
	return #names
end

function MC.TexturePackDefinitionOwner( name )
	name = normalizeTexturePackName( name )
	if name == "default" or name == "programmer_art" then return "mc" end
	local definition = name and MC.TexturePackDefinitions[name] or nil
	return definition and definition.owner or nil
end

function MC.AcquireTexturePack( owner, name, priority )
	owner = normalizeTexturePackOwner( owner )
	name = normalizeTexturePackName( name )
	if not owner or owner == "mc" then return false, "invalid_texture_pack_owner" end
	if not name or not AtlasSources[name] then return false, "texture_pack_not_registered" end
	local definitionOwner = MC.TexturePackDefinitionOwner( name )
	if definitionOwner ~= "mc" and definitionOwner ~= owner then
		return false, "owned_by_" .. tostring( definitionOwner )
	end

	local previousLease = MC.TexturePackLeases[owner]
	MC.TexturePackLeaseSerial = MC.TexturePackLeaseSerial + 1
	MC.TexturePackLeases[owner] = {
		owner = owner,
		name = name,
		priority = math.Clamp( math.floor( tonumber( priority ) or 0 ), -32768, 32767 ),
		serial = MC.TexturePackLeaseSerial,
	}
	if refreshTexturePackSelection then
		local ok, activeOrError = refreshTexturePackSelection( true )
		if not ok then
			MC.TexturePackLeases[owner] = previousLease
			refreshTexturePackSelection( true )
			return false, activeOrError
		end
	end
	if hook and hook.Run then hook.Run( "MC.TexturePackLeaseChanged", owner, name, true ) end
	return true, MC.TexturePackName and MC.TexturePackName() or name
end

function MC.ReleaseTexturePack( owner )
	owner = normalizeTexturePackOwner( owner )
	if not owner then return false, "invalid_texture_pack_owner" end
	local lease = MC.TexturePackLeases[owner]
	if not lease then return false, "not_acquired" end
	MC.TexturePackLeases[owner] = nil
	local ok, activeOrError = true, MC.TexturePackName and MC.TexturePackName() or "default"
	if refreshTexturePackSelection then ok, activeOrError = refreshTexturePackSelection( true ) end
	if not ok then
		MC.TexturePackLeases[owner] = lease
		refreshTexturePackSelection( true )
		return false, activeOrError
	end
	if hook and hook.Run then hook.Run( "MC.TexturePackLeaseChanged", owner, lease.name, false ) end
	return ok, activeOrError
end

function MC.TexturePackLeaseOwner()
	local winner
	for owner, lease in pairs( MC.TexturePackLeases ) do
		if AtlasSources[lease.name]
		and ( not winner or lease.priority > winner.priority
			or ( lease.priority == winner.priority and lease.serial > winner.serial ) ) then
			winner = {
				owner = owner,
				name = lease.name,
				priority = lease.priority,
				serial = lease.serial,
			}
		end
	end
	return winner and winner.owner or nil
end

function MC.ListTexturePacks()
	local result = {
		{ name = "default", owner = "mc", atlasProfile = "default", builtin = true,
			opaquePath = MC.Atlas.MATERIAL or "mc/atlas_365", preview = "mc/resourcepacks/default" },
		{ name = "programmer_art", owner = "mc", atlasProfile = "default", builtin = true,
			opaquePath = MC.Atlas.MATERIAL_PROGRAMMER_ART or "mc/atlas_365_programmer_art" },
	}
	for name, definition in pairs( MC.TexturePackDefinitions ) do
		result[#result + 1] = {
			name = name,
			owner = definition.owner,
			title = definition.title,
			description = definition.description,
			preview = definition.preview,
			opaquePath = definition.opaquePath,
			translucentPath = definition.translucentPath,
			iconPath = definition.iconPath,
			inheritBase = definition.inheritBase == true,
			atlasProfile = definition.atlasProfile or "default",
			builtin = false,
		}
	end
	table.sort( result, function( left, right ) return left.name < right.name end )
	return result
end

function MC.ListTexturePackLeases()
	local result = {}
	for owner, lease in pairs( MC.TexturePackLeases ) do
		result[#result + 1] = {
			owner = owner,
			name = lease.name,
			priority = lease.priority,
			serial = lease.serial,
		}
	end
	table.sort( result, function( left, right )
		if left.priority ~= right.priority then return left.priority > right.priority end
		if left.serial ~= right.serial then return left.serial > right.serial end
		return left.owner < right.owner
	end )
	return result
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
MC.MaterialNativeSlotOpaque = nil
MC.MaterialNativeSlotTranslucent = nil
MC.MaterialGpuLightTexture = nil
MC.MaterialGpuLightTextureLinearDebug = nil
MC.MaterialGpuLightTexturePpFix = nil
MC.MaterialGpuLightTextureFancy = nil
MC.MaterialGpuLightTextureFancyLinearDebug = nil
MC.MaterialGpuLightTextureFancyPpFix = nil
MC.MaterialGpuLightTextureHeight = nil
MC.MaterialGpuLightTextureFast = nil
MC.MaterialGpuLightTextureVanilla = nil
MC.MaterialGpuLightTextureVanillaTranslucent = nil
MC.MaterialGpuLightTextureTranslucent = nil
MC.MaterialGpuLightTextureTranslucentLinearDebug = nil
MC.MaterialGpuLightTextureTranslucentPpFix = nil

-- Retired L1 capability queries stay false for external callers and old hooks.
function MC.IsGpuLightTextureMaterial() return false end
function MC.GpuLightTextureMaterialsReady() return false end
function MC.UsingVanillaLightMaterial() return false end
function MC.UsingGpuChunkShader() return false end
function MC.NativeChunkMaterial() return nil end

-- L2 binds its own draw materials; these proxies own only the source texture.
function MC.CurrentChunkMaterial( translucent )
	if translucent then return MC.MaterialTranslucent end
	return MC.Material
end

function MC.ResolveChunkMaterial( translucent )
	local material = MC.CurrentChunkMaterial( translucent )
	local materialId, passId = MC.RenderMaterialABI.Resolve( material, translucent == true, false )
	return material, materialId, passId
end

if cvars and cvars.RemoveChangeCallback then
	cvars.RemoveChangeCallback( "mc_light_shader", "mc_light_shader_rebuild" )
	cvars.RemoveChangeCallback( "mc_shadow_facefix", "mc_shadow_facefix_rebuild" )
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

local function createCreativeIconMaterial( name, texture, alphaTest )
	local textureName = texture and texture.GetName and texture:GetName() or nil
	if not ( CreateMaterial and textureName and textureName ~= "" ) then return nil end
	local params = {
		["$basetexture"] = textureName,
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
		["$nocull"] = "1",
		["$pointsample"] = "1",
		["$nomip"] = "1",
		["$nolod"] = "1",
	}
	if alphaTest then
		params["$alphatest"] = "1"
		params["$alphatestreference"] = "0.5"
	end
	local material = CreateMaterial( name, "UnlitGeneric", params )
	if not material or material:IsError() then return nil end
	material:SetTexture( "$basetexture", texture )
	return material
end

-- Creative inventory only: these materials use the separately cached no-mip
-- atlas texture. World meshes continue using MC.Material and its mip chain.
MC.MaterialCreativeIcon = createCreativeIconMaterial(
	"mc_atlas_creative_icon_cutout_v1", defaultIconTexture, true
) or MC.Material
MC.MaterialCreativeIconOpaque = createCreativeIconMaterial(
	"mc_atlas_creative_icon_opaque_v1", defaultIconTexture, false
) or MC.MaterialIconOpaque

local function validAtlasTexture( texture )
	if not texture then return false end
	if texture.IsError and texture:IsError() then return false end
	return true
end

local function setAtlasTexture( material, texture )
	if not ( material and texture and material.SetTexture ) then return false end
	material:SetTexture( "$basetexture", texture )
	return true
end

local function normalizeTexturePack( value )
	value = normalizeTexturePackName( value ) or "default"
	if AtlasSources[value] then return value end
	return "default"
end

local function resolveAtlasSource( name )
	local source = AtlasSources[name]
	if not source then return nil end
	if source.inheritBase == true then
		local configured = MC.TexturePack and MC.TexturePack.GetString
			and normalizeTexturePackName( MC.TexturePack:GetString() ) or "default"
		local base = AtlasSources[configured]
		if not base or base.inheritBase == true or ( base.atlasProfile or "default" ) ~= "default" then
			configured, base = "default", AtlasSources.default
		end
		base = resolveAtlasSource( configured ) or AtlasSources.default
		if not base then return nil end
		return {
			opaque = base.opaque,
			translucent = base.translucent,
			icon = base.icon,
			opaqueTexture = base.opaqueTexture,
			translucentTexture = base.translucentTexture,
			iconTexture = base.iconTexture,
			opaquePath = base.opaquePath,
			translucentPath = base.translucentPath,
			iconPath = base.iconPath,
			atlasProfile = source.atlasProfile or "default",
			inheritedTexturePack = configured,
		}
	end
	if name == "programmer_art" or source.custom == true then
		if not source.opaque or source.opaque:IsError() then
			source.opaque = loadAtlasSource( source.opaquePath )
		end
		if not source.translucent or source.translucent:IsError() then
			source.translucent = loadAtlasSource( source.translucentPath or source.opaquePath )
		end
		if not source.icon or source.icon:IsError() then
			source.icon = loadAtlasIconSource( source.iconPath )
		end
		source.opaqueTexture = atlasMaterialTexture( source.opaque ) or source.opaqueTexture
		source.translucentTexture = atlasMaterialTexture( source.translucent ) or source.opaqueTexture
		source.iconTexture = atlasMaterialTexture( source.icon ) or source.iconTexture or source.opaqueTexture
	end
	return source
end

function MC.TexturePackName()
	return MC.ActiveTexturePack or "default"
end

function MC.SetTexturePack( value )
	local requested = normalizeTexturePackName( value ) or "default"
	local name = normalizeTexturePack( requested )
	local source = resolveAtlasSource( name ) or AtlasSources.default
	local opaqueTexture = source and source.opaqueTexture
	local translucentTexture = source and source.translucentTexture or opaqueTexture
	local iconTexture = source and source.iconTexture or opaqueTexture
	if not source or not source.opaque or source.opaque:IsError() or not validAtlasTexture( opaqueTexture ) then
		return false, "missing_atlas_" .. name
	end
	if not validAtlasTexture( translucentTexture ) then translucentTexture = opaqueTexture end
	if not validAtlasTexture( iconTexture ) then iconTexture = opaqueTexture end
	local profileName = source.atlasProfile or "default"
	if MC.SetAtlasProfile then
		local profileOK, profileResult = MC.SetAtlasProfile( profileName )
		if not profileOK then return false, profileResult or "atlas_profile_switch_failed" end
	end
	local previous = MC.ActiveTexturePack

	-- MC.Material/MC.MaterialTranslucent are stable proxy objects referenced by
	-- existing mesh records. Updating their texture is enough to switch CPU
	-- meshes, icon panels and translucent draws without a full world rebuild.
	setAtlasTexture( MC.Material, opaqueTexture )
	setAtlasTexture( MC.MaterialTranslucent, translucentTexture )
	setAtlasTexture( MC.MaterialIconOpaque, opaqueTexture )
	setAtlasTexture( MC.MaterialCreativeIcon, iconTexture )
	setAtlasTexture( MC.MaterialCreativeIconOpaque, iconTexture )
	MC.ActiveTexturePack = name
	MC.Atlas.ACTIVE_MATERIAL = source.opaquePath
		or ( name == "programmer_art"
			and ( MC.Atlas.MATERIAL_PROGRAMMER_ART or "mc/atlas_365_programmer_art" )
			or ( MC.Atlas.MATERIAL or "mc/atlas_365" ) )
	MC.Atlas.ACTIVE_MATERIAL_TRANSLUCENT = source.translucentPath
		or ( name == "programmer_art"
			and ( MC.Atlas.MATERIAL_PROGRAMMER_ART_TRANSLUCENT or "mc/atlas_365_programmer_art_translucent" )
			or ( MC.Atlas.MATERIAL_TRANSLUCENT or "mc/atlas_365_translucent" ) )

	if MC.RefreshBlockParticleMaterials then MC.RefreshBlockParticleMaterials( opaqueTexture ) end
	if hook and hook.Run then hook.Run( "MC.TexturePackChanged", name, previous ) end
	return true, name, requested == name
end

-- The manager changes the archived player preference, never a mode's lease.
-- Unlike the legacy low-level setter, unknown names cannot fall back silently.
function MC.SetTexturePackPreference( name )
	if type( name ) ~= "string" or normalizeTexturePackName( name ) ~= name then
		return false, "invalid_texture_pack_name"
	end
	if not AtlasSources[name] then return false, "texture_pack_not_registered" end
	if MC.TexturePackLeaseOwner() then return false, "texture_pack_controlled_by_mode" end
	if not MC.TexturePack or not MC.TexturePack.SetString then return false, "texture_pack_convar_unavailable" end
	local ok, result = MC.SetTexturePack( name )
	if not ok then return false, result end
	MC.TexturePack:SetString( name )
	return true, result
end

local function configuredTexturePackName()
	if not ( MC.TexturePack and MC.TexturePack.GetString ) then return "default" end
	return normalizeTexturePack( MC.TexturePack:GetString() )
end

local function winningTexturePackLease()
	local winner
	for owner, lease in pairs( MC.TexturePackLeases ) do
		if not AtlasSources[lease.name] then
			MC.TexturePackLeases[owner] = nil
		elseif not winner or lease.priority > winner.priority
		or ( lease.priority == winner.priority and lease.serial > winner.serial ) then
			winner = lease
		end
	end
	return winner
end

refreshTexturePackSelection = function( force )
	local lease = winningTexturePackLease()
	local selected = lease and lease.name or configuredTexturePackName()
	if not force and MC.ActiveTexturePack == selected then return true, selected, true end
	return MC.SetTexturePack( selected )
end

local TEXTURE_PACK_SYNC_TIMER = "mc_texture_pack_startup_sync"
local TEXTURE_PACK_INIT_HOOK = "mc_texture_pack_init_sync"
local TEXTURE_PACK_SYNC_INTERVAL = 0.25
local TEXTURE_PACK_SYNC_ATTEMPTS = 20

local function syncTexturePackFromConVar( force )
	return refreshTexturePackSelection( force )
end

local function startTexturePackStartupSync()
	if not ( timer and timer.Create ) then return end
	if timer.Remove then timer.Remove( TEXTURE_PACK_SYNC_TIMER ) end
	timer.Create( TEXTURE_PACK_SYNC_TIMER, TEXTURE_PACK_SYNC_INTERVAL, TEXTURE_PACK_SYNC_ATTEMPTS, function()
		syncTexturePackFromConVar( false )
	end )
end

if cvars and cvars.AddChangeCallback then
	if cvars.RemoveChangeCallback then
		cvars.RemoveChangeCallback( "mc_texture_pack", "mc_texture_pack_refresh" )
	end
	cvars.AddChangeCallback( "mc_texture_pack", function( _, _, value )
		local normalized = normalizeTexturePack( value )
		local ok, active, alreadyNormalized = refreshTexturePackSelection( true )
		if MC.RefreshConfigControlValue then MC.RefreshConfigControlValue( "mc_texture_pack", value ) end
		if not ok then
			MsgN( "[MC] texture pack unavailable: " .. tostring( value ) )
		elseif normalized ~= string.lower( tostring( value or "default" ) ) and RunConsoleCommand then
			RunConsoleCommand( "mc_texture_pack", normalized )
		end
	end, "mc_texture_pack_refresh" )
end

-- Archived client ConVars may be restored after this file's first read. Keep a
-- short reconciliation window even when applying the temporary default succeeds.
syncTexturePackFromConVar( true )
startTexturePackStartupSync()

if hook and hook.Add then
	if hook.Remove then hook.Remove( "InitPostEntity", TEXTURE_PACK_INIT_HOOK ) end
	hook.Add( "InitPostEntity", TEXTURE_PACK_INIT_HOOK, function()
		syncTexturePackFromConVar( true )
		startTexturePackStartupSync()
	end )
end
