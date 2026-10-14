-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
-- Core materials provide atlas textures and CPU vertex colours only.

local function atlasPngPath( path )
	path = path:gsub( "%.vmt$", "" )
	if path:sub( -4 ) == ".png" then return path end
	return path .. ".png"
end

local function atlasMaterialTexture( material )
	local texture = material and material.GetTexture and material:GetTexture( "$basetexture" ) or nil
	if not texture or ( texture.IsError and texture:IsError() ) then return nil end
	return texture
end

local function atlasTextureKey( name )
	-- PNG imports expose flag-prefixed names without the lazy source's suffix.
	return ( name:gsub( "^%d%d%d%d%d%d%d", "" ):lower():gsub( "%.png$", "" ) )
end

local function atlasSourceKeys( source )
	return atlasTextureKey( source.opaqueTexture and source.opaqueTexture:GetName() or source.opaquePath or "" ),
		atlasTextureKey( source.translucentTexture and source.translucentTexture:GetName() or source.translucentPath or "" )
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
	-- PNG imports use a separate source from the world's mipmapped atlas.
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
local defaultDefinition = MC.TexturePackDiscovery.Default()
-- Only seed stable proxy objects here. The required default is baked from raw
-- PNG bytes in PostRender, once resource decoding and GPU uploads are available.
local defaultOpaqueSource = Material( "vgui/white" )
local defaultOpaqueTexture = atlasMaterialTexture( defaultOpaqueSource )
if not defaultOpaqueTexture or defaultOpaqueSource:IsError() then
	error( "Cannot initialize atlas proxy materials", 0 )
end

local defaultTranslucentTexture, defaultIconTexture = defaultOpaqueTexture, defaultOpaqueTexture

MC.Material = createCpuAtlasProxy( "mc_atlas_cpu_opaque_proxy1", defaultOpaqueTexture, false ) or defaultOpaqueSource
MC.MaterialOpaqueCPU = MC.Material
MC.MaterialTranslucent = createCpuAtlasProxy( "mc_atlas_cpu_translucent_proxy1", defaultTranslucentTexture, true )
	 or MC.Material

-- The proxy materials above are recreated with the default atlas on every map
-- load/Lua refresh. An old global value must not make startup sync believe the
-- newly-created proxies already use that pack.
MC.ActiveTexturePack = nil

local AtlasSources = {}

MC.TexturePackDefinitions = MC.TexturePackDefinitions or {}
if not ( MC.TexturePackDefinitions.default and MC.TexturePackDefinitions.default.runtimeIconTexture ) then
	MC.TexturePackDefinitions.default = {
		name = "default", owner = "texturepack.default", pending = true, atlasProfile = "default",
		title = defaultDefinition.title, description = defaultDefinition.description, preview = defaultDefinition.preview,
	}
end
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

local function normalizeTexturePackPreview( value )
	if type( value ) ~= "string" or #value > 256 or value:find( "%z" ) then return nil end
	-- Repository cover images are copied to DATA and exposed through the
	-- engine's relative ../data material path. Keep this narrow: arbitrary
	-- traversal must never become a material lookup.
	if value:match( "^%.%./data/mc/resourcepacks/previews/[a-f0-9]+$" ) then return value end
	return normalizeAtlasPath( value )
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
	if definition.pending then
		return { opaqueTexture = defaultOpaqueTexture, translucentTexture = defaultOpaqueTexture,
			iconTexture = defaultOpaqueTexture, runtime = true, pending = true, atlasProfile = "default" }
	end
	if definition.runtimeTexture then
		local texture = definition.runtimeTexture
		if not definition.runtimeIconTexture then return nil, "missing_runtime_item_texture" end
		return { opaqueTexture = texture, translucentTexture = texture, iconTexture = definition.runtimeIconTexture,
			runtime = true, owner = definition.owner, atlasProfile = definition.atlasProfile }
	end
	if definition.inheritBase == true then
		return {
			custom = true,
			inheritBase = true,
			owner = definition.owner,
			atlasProfile = definition.atlasProfile or "default",
		}
	end
	local source = {
		opaquePath = atlasPngPath( definition.opaquePath ),
		translucentPath = atlasPngPath( definition.translucentPath ),
		iconPath = atlasPngPath( definition.iconPath ),
		custom = true,
		owner = definition.owner,
		atlasProfile = definition.atlasProfile or "default",
	}
	if definition.pbr then
		-- Import and validate the complete static set before publishing its pack.
		source.opaque = loadAtlasSource( source.opaquePath )
		source.translucent = loadAtlasSource( source.translucentPath )
		source.opaqueTexture = atlasMaterialTexture( source.opaque )
		source.translucentTexture = atlasMaterialTexture( source.translucent )
		if source.opaque:IsError() or source.translucent:IsError()
			or not source.opaqueTexture or not source.translucentTexture then return nil, "missing_pbr_albedo" end
		local maps = { colorSpace = "srgb" }
		for _, channel in ipairs( { "normal", "orm" } ) do
			local material = Material( atlasPngPath( definition.pbr[channel] ), "mips" )
			local texture = atlasMaterialTexture( material )
			if material:IsError() or not texture then return nil, "missing_pbr_" .. channel end
			if texture:Width() ~= source.opaqueTexture:Width() or texture:Height() ~= source.opaqueTexture:Height()
				or texture:Width() ~= source.translucentTexture:Width() or texture:Height() ~= source.translucentTexture:Height() then
				return nil, "pbr_texture_layout_mismatch"
			end
			maps[channel] = texture
		end
		source.pbr = maps
	end
	return source
end

for name, definition in pairs( MC.TexturePackDefinitions ) do
	if normalizeTexturePackName( name ) == name and type( definition ) == "table" then
		local inheritBase = definition.inheritBase == true
		local opaquePath = normalizeAtlasPath( definition.opaquePath )
		local translucentPath = normalizeAtlasPath( definition.translucentPath ) or opaquePath
		local iconPath = normalizeAtlasPath( definition.iconPath ) or translucentPath
		local owner = normalizeTexturePackOwner( definition.owner )
		local atlasProfile = normalizeAtlasProfile( definition.atlasProfile )
		if ( opaquePath or inheritBase or definition.runtimeTexture or definition.pending ) and owner and atlasProfile then
			definition.inheritBase = inheritBase
			definition.opaquePath = opaquePath
			definition.translucentPath = translucentPath
			definition.iconPath = iconPath
			definition.owner = owner
			definition.atlasProfile = atlasProfile
			local source, err = atlasSourceFromDefinition( definition )
			if source then AtlasSources[name] = source
			else MC.Fault( "runtime_atlas_reload", "%s: %s", name, err ) end
		else
			MC.TexturePackDefinitions[name] = nil
		end
	else
		MC.TexturePackDefinitions[name] = nil
	end
end

function MC.RegisterTexturePack( name, definition, owner, deferSelection )
	name = normalizeTexturePackName( name )
	if not name or name == "default" and owner ~= "texturepack.default" then
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
		preview = normalizeTexturePackPreview( definition.preview )
		if not preview then return false, "invalid_texture_pack_preview" end
	end
	owner = normalizeTexturePackOwner( owner )
	if not owner or owner == "mc" then return false, "invalid_texture_pack_owner" end
	local existing = MC.TexturePackDefinitions[name]
	if existing and existing.owner ~= owner then return false, "owned_by_" .. tostring( existing.owner ) end
	if MC.AtlasBaker then
		for _, pack in pairs( MC.AtlasBaker.packs ) do
			if pack.name == name and pack.owner ~= owner then return false, "owned_by_" .. pack.owner end
		end
	end
	local inheritBase = definition.inheritBase == true
	local pending = definition.pending == true
	if pending and ( name ~= "default" or definition.runtimeTexture or inheritBase ) then
		return false, "invalid_pending_texture_pack"
	end
	local atlasProfile = normalizeAtlasProfile( definition.atlasProfile or definition.profile )
	if not atlasProfile then return false, "atlas_profile_not_registered" end
	local runtimeTexture = definition.runtimeTexture
	local runtimeIconTexture = definition.runtimeIconTexture
	if runtimeTexture ~= nil then
		local kind = type( runtimeTexture )
		if ( kind ~= "ITexture" and kind ~= "userdata" and kind ~= "table" )
			or type( runtimeTexture.GetName ) ~= "function" or type( runtimeTexture.IsError ) ~= "function"
			or type( runtimeTexture.Width ) ~= "function" or type( runtimeTexture.Height ) ~= "function"
			or runtimeTexture:IsError() or runtimeTexture:GetName() == "" then return false, "invalid_runtime_texture" end
		local layout
		if atlasProfile == "default" then layout = MC.DefaultAtlasProfileLayout or MC.GeneratedAtlas or MC.Atlas
		else layout = MC.AtlasProfiles[atlasProfile].layout end
		if runtimeTexture:Width() ~= layout.W or runtimeTexture:Height() ~= layout.H then return false, "runtime_texture_layout_mismatch" end
		if inheritBase then return false, "runtime_texture_cannot_inherit" end
		local iconKind = type( runtimeIconTexture )
		if ( iconKind ~= "ITexture" and iconKind ~= "userdata" and iconKind ~= "table" )
			or type( runtimeIconTexture.GetName ) ~= "function" or type( runtimeIconTexture.IsError ) ~= "function"
			or type( runtimeIconTexture.Width ) ~= "function" or type( runtimeIconTexture.Height ) ~= "function"
			or runtimeIconTexture:IsError() or runtimeIconTexture:GetName() == ""
			or runtimeIconTexture:Width() ~= layout.W or runtimeIconTexture:Height() ~= layout.H then
			return false, "invalid_runtime_item_texture"
		end
	end
	local opaquePath = normalizeAtlasPath( definition.opaque or definition.opaquePath or definition.material )
	local runtimePBR
	if definition.runtimePBR ~= nil then
		local maps = definition.runtimePBR
		if not runtimeTexture or type( maps ) ~= "table" then return false, "invalid_runtime_pbr" end
		for _, channel in ipairs( { "normal", "orm" } ) do
			local texture = maps[channel]
			local kind = type( texture )
			if ( kind ~= "ITexture" and kind ~= "userdata" and kind ~= "table" )
				or type( texture.GetName ) ~= "function" or type( texture.IsError ) ~= "function"
				or type( texture.Width ) ~= "function" or type( texture.Height ) ~= "function"
				or texture:IsError() or texture:GetName() == ""
				or texture:Width() ~= runtimeTexture:Width() or texture:Height() ~= runtimeTexture:Height() then
				return false, "invalid_runtime_pbr_" .. channel
			end
		end
		if maps.normal:GetName() == runtimeTexture:GetName() or maps.orm:GetName() == runtimeTexture:GetName()
			or maps.normal:GetName() == maps.orm:GetName() then return false, "runtime_pbr_channels_alias" end
		runtimePBR = { normal = maps.normal, orm = maps.orm, colorSpace = "srgb", runtime = true }
	end
	if not opaquePath and not inheritBase and not runtimeTexture and not pending then return false, "invalid_opaque_atlas_path" end
	local translucentPath = normalizeAtlasPath( definition.translucent or definition.translucentPath ) or opaquePath
	local iconPath = normalizeAtlasPath( definition.icon or definition.iconPath ) or translucentPath
	local pbr
	if definition.pbr ~= nil then
		if runtimeTexture or inheritBase or type( definition.pbr ) ~= "table" then return false, "invalid_static_pbr" end
		pbr = {}
		for _, channel in ipairs( { "normal", "orm" } ) do
			if type( definition.pbr[channel] ) ~= "string" then return false, "invalid_pbr_" .. channel end
			pbr[channel] = normalizeAtlasPath( definition.pbr[channel] )
			if not pbr[channel] then return false, "invalid_pbr_" .. channel end
		end
		local normal, orm = pbr.normal:lower(), pbr.orm:lower()
		if normal == orm or normal == opaquePath:lower() or normal == translucentPath:lower()
			or orm == opaquePath:lower() or orm == translucentPath:lower() then return false, "pbr_channels_alias" end
	end
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
		runtimeTexture = runtimeTexture,
		runtimeIconTexture = runtimeIconTexture,
		pending = pending,
		runtimePBR = runtimePBR,
		pbr = pbr,
		inheritBase = inheritBase,
		opaquePath = opaquePath,
		translucentPath = translucentPath,
		iconPath = iconPath,
		atlasProfile = atlasProfile,
	}
	local source, sourceError = atlasSourceFromDefinition( stored )
	if not source then return false, sourceError end
	-- Map lookup uses actual albedo identity, including inherited selections.
	-- Publishing two owners for the same source would make that lookup ambiguous.
	if not inheritBase then
		local opaque, translucent = atlasSourceKeys( source )
		for otherName, other in pairs( AtlasSources ) do
			local otherDefinition = MC.TexturePackDefinitions[otherName]
			if otherName ~= name and not other.inheritBase
				and ( pbr or runtimePBR or other.pbr or otherDefinition and otherDefinition.runtimePBR ) then
				local otherOpaque, otherTranslucent = atlasSourceKeys( other )
				if opaque == otherOpaque or opaque == otherTranslucent
					or translucent == otherOpaque or translucent == otherTranslucent then
					return false, "pbr_albedo_already_registered"
				end
			end
		end
	end
	MC.TexturePackDefinitions[name] = stored
	AtlasSources[name] = source
	MC.TexturePackRevision = MC.TexturePackRevision + 1
	if refreshTexturePackSelection and not deferSelection then
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

-- Called at material-build boundaries, never from a quad/vertex loop. Matching
-- the actual source also supports inherited packs without using active UI state.
function MC.TexturePackPBR( source )
	local name = source:GetName()
	local key = atlasTextureKey( name )
	for pack, definition in pairs( MC.TexturePackDefinitions ) do
		if definition.runtimePBR and definition.runtimeTexture:GetName() == name then return definition.runtimePBR end
		local atlas = AtlasSources[pack]
		if atlas and atlas.pbr then
			local opaque, translucent = atlasSourceKeys( atlas )
			if key == opaque or key == translucent then return atlas.pbr end
		end
	end
end
MC.RuntimeAtlasPBR = MC.TexturePackPBR

function MC.UnregisterTexturePack( name, owner )
	name = normalizeTexturePackName( name )
	if name == "default" then return false, "required_default_texture_pack" end
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
		if definition.owner == owner and name ~= "default" then names[#names + 1] = name end
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
	local definition = name and MC.TexturePackDefinitions[name] or nil
	return definition and definition.owner or nil
end

function MC.AcquireTexturePack( owner, name, priority )
	owner = normalizeTexturePackOwner( owner )
	name = normalizeTexturePackName( name )
	if not owner or owner == "mc" then return false, "invalid_texture_pack_owner" end
	if not name or not AtlasSources[name] then return false, "texture_pack_not_registered" end
	local definitionOwner = MC.TexturePackDefinitionOwner( name )
	if definitionOwner ~= "mc" and definitionOwner ~= owner and not MC.TexturePackDiscovery.IsPublicPack( name ) then
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
	local result = {}
	for name, definition in pairs( MC.TexturePackDefinitions ) do
		result[#result + 1] = {
			name = name,
			owner = definition.owner,
			title = definition.title,
			description = definition.description,
			preview = definition.preview,
			runtime = definition.runtimeTexture ~= nil,
			pending = definition.pending == true,
			pbr = definition.runtimePBR ~= nil or definition.pbr ~= nil,
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
local iconMaterials = {}
local function createCreativeIconMaterial( name, texture, alphaTest )
	local textureName = texture and texture.GetName and texture:GetName() or nil
	if not ( CreateMaterial and textureName and textureName ~= "" ) then return nil end
	-- VGUI caches the mapping dimensions at material creation. SetTexture does
	-- not update them: a 1x1 bootstrap collapses rectangular icon UVs to a point.
	-- Reuse materials only for equal dimensions, including across pack switches.
	name = name .. "_mapping_v2_" .. texture:Width() .. "x" .. texture:Height()
	local cached = iconMaterials[name]
	if cached then return cached end
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
	iconMaterials[name] = material
	return material
end

local function iconMaterialsFor( texture )
	local cutout = createCreativeIconMaterial( "mc_atlas_creative_icon_cutout", texture, true )
	local opaque = createCreativeIconMaterial( "mc_atlas_creative_icon_opaque", texture, false )
	if not cutout or not opaque then return nil, "atlas_icon_material_creation" end
	return {cutout=cutout, opaque=opaque}
end

local function applyIconMaterials( materials, texture )
	materials.cutout:SetTexture( "$basetexture", texture )
	materials.opaque:SetTexture( "$basetexture", texture )
	MC.MaterialCreativeIcon = materials.cutout
	MC.MaterialCreativeIconOpaque = materials.opaque
	MC.MaterialIconOpaque = materials.opaque
end

local initialIcons, initialIconError = iconMaterialsFor( defaultIconTexture )
if not initialIcons then error( initialIconError, 0 ) end
applyIconMaterials( initialIcons, defaultIconTexture )

-- POINT filtering does not disable mip selection. Held blocks use the icon
-- texture's base level, with their own cutout/translucent material semantics.
MC.MaterialHeldBlock = createCpuAtlasProxy( "mc_atlas_held_cutout_v1", defaultIconTexture, false )
MC.MaterialHeldBlockTranslucent = createCpuAtlasProxy( "mc_atlas_held_translucent_v1", defaultIconTexture, true )
if not MC.MaterialHeldBlock or not MC.MaterialHeldBlockTranslucent then
	error( "Cannot create held block atlas materials", 0 )
end

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
		if not base or base.inheritBase == true then
			configured, base = "default", AtlasSources.default
		end
		base = resolveAtlasSource( configured ) or AtlasSources.default
		if not base then return nil end
		if base.atlasProfile ~= "default" and source.atlasProfile ~= "default" and source.atlasProfile ~= base.atlasProfile then
			return nil, "inherited_atlas_profile_mismatch"
		end
		return {
			runtime = base.runtime,
			pending = base.pending,
			opaque = base.opaque,
			translucent = base.translucent,
			icon = base.icon,
			opaqueTexture = base.opaqueTexture,
			translucentTexture = base.translucentTexture,
			iconTexture = base.iconTexture,
			opaquePath = base.opaquePath,
			translucentPath = base.translucentPath,
			iconPath = base.iconPath,
			atlasProfile = source.atlasProfile == "default" and base.atlasProfile or source.atlasProfile,
			inheritedTexturePack = configured,
		}
	end
	if source.custom == true then
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
		source.iconTexture = atlasMaterialTexture( source.icon )
	end
	return source
end

function MC.TexturePackName()
	return MC.ActiveTexturePack or "default"
end

function MC.SetTexturePack( value )
	local requested = normalizeTexturePackName( value ) or "default"
	local name = normalizeTexturePack( requested )
	local source, sourceError = resolveAtlasSource( name )
	if not source then return false, sourceError or "missing_atlas_" .. name end
	local opaqueTexture = source and source.opaqueTexture
	local translucentTexture = source and source.translucentTexture or opaqueTexture
	local iconTexture = source and source.iconTexture
	if not source or not source.runtime and (not source.opaque or source.opaque:IsError()) or not validAtlasTexture( opaqueTexture ) then
		return false, "missing_atlas_" .. name
	end
	if not validAtlasTexture( translucentTexture ) then translucentTexture = opaqueTexture end
	if not validAtlasTexture( iconTexture ) then return false, "missing_item_atlas_" .. name end
	local icons, iconError = iconMaterialsFor( iconTexture )
	if not icons then return false, iconError end
	local profileName = source.atlasProfile or "default"
	if MC.SetAtlasProfile then
		local profileOK, profileResult = MC.SetAtlasProfile( profileName )
		if not profileOK then return false, profileResult or "atlas_profile_switch_failed" end
	end
	local previous = MC.ActiveTexturePack

	-- MC.Material/MC.MaterialTranslucent are stable proxy objects referenced by
	-- existing mesh records. UI materials additionally require matching mapping
	-- dimensions; geometry rebuilds for changed layouts are handled above.
	setAtlasTexture( MC.Material, opaqueTexture )
	setAtlasTexture( MC.MaterialTranslucent, translucentTexture )
	applyIconMaterials( icons, iconTexture )
	setAtlasTexture( MC.MaterialHeldBlock, iconTexture )
	setAtlasTexture( MC.MaterialHeldBlockTranslucent, iconTexture )
	MC.ActiveTexturePack = name
	MC.TexturePackPending = source.pending == true
	MC.Atlas.ACTIVE_MATERIAL = source.opaquePath or opaqueTexture:GetName()
	MC.Atlas.ACTIVE_MATERIAL_TRANSLUCENT = source.translucentPath or translucentTexture:GetName()

	if MC.RefreshBlockParticleMaterials then MC.RefreshBlockParticleMaterials( opaqueTexture ) end
	if MC.ResourceGeneration then
		if MC.ResourcePacks then
			MC.ResourcePacks.activeGeneration = MC.ResourceGeneration.textures[opaqueTexture:GetName()]
		end
		for _, material in ipairs({MC.Material, MC.MaterialTranslucent, MC.MaterialIconOpaque, MC.MaterialCreativeIcon, MC.MaterialCreativeIconOpaque,
			MC.MaterialHeldBlock, MC.MaterialHeldBlockTranslucent}) do
			MC.ResourceGeneration.TrackMaterial(material)
		end
	end
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
	-- A staged raw definition must not be replaced by the startup reconciler
	-- before its geometry has committed. Leases still win immediately.
	if MC.ResourcePacks and MC.ResourcePacks.job and MC.ResourcePacks.job.raw
		and MC.ResourcePacks.job.state == "applying" and not MC.TexturePackLeaseOwner()
		and MC.TexturePack:GetString() == MC.ResourcePacks.job.preference then
		return true, MC.TexturePackName(), true
	end
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
		elseif normalized ~= string.lower( tostring( value or "default" ) ) and RunConsoleCommand
			and not normalizeTexturePackName(value) then
			RunConsoleCommand( "mc_texture_pack", normalized )
		end
	end, "mc_texture_pack_refresh" )
end

-- Archived client ConVars may be restored after this file's first read. Keep a
-- short reconciliation window even when applying the temporary default succeeds.
MC.TexturePackDiscovery.Scan( "atlas" )
if not MC.TexturePackDefinitions.default then error( "Required default source registration failed", 0 ) end
syncTexturePackFromConVar( true )
startTexturePackStartupSync()

if hook and hook.Add then
	if hook.Remove then hook.Remove( "InitPostEntity", TEXTURE_PACK_INIT_HOOK ) end
	hook.Add( "InitPostEntity", TEXTURE_PACK_INIT_HOOK, function()
		syncTexturePackFromConVar( true )
		startTexturePackStartupSync()
	end )
end
