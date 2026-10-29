-- Owned quad resources. The diagnostic and pack runtime never share writable slots.
MC = MC or {}
local R = MC.RenderL2Resources or { materials = {} }
MC.RenderL2Resources = R
local floor = math.floor
local ATLAS_SIZE, LIGHTMAP_SIZE = 16384, 16
local ATLAS_HEIGHT = 16384
R.ATLAS_SIZE, R.ATLAS_HEIGHT = ATLAS_SIZE, ATLAS_HEIGHT
R.CAPACITY = ATLAS_SIZE * math.floor( ATLAS_HEIGHT / 5 )
-- Native meshes retain their existing 24-bit corner payload within each bank.
-- The material supplies the bank, avoiding a per-vertex ABI/DLL change.
R.BANK_QUADS = 1048576
R.OCCLUSION_VERSION = 1
local DEPTH_MATERIAL_VERSION = 2

-- Lua refresh retains both the engine materials and live mesh references.
-- Rebuild old snapshots once, outside drawing; changing CreateMaterial's
-- parameters alone cannot update an already cached material.
local function refreshMaterialDepth( owner )
	if owner.depthMaterialVersion == DEPTH_MATERIAL_VERSION then return end
	for _, material in pairs( owner.materials ) do
		material:SetInt( "$depthtest", 1 )
		material:SetInt( "$writedepth", 0 )
		material:SetInt( "$ignorez", 0 )
		material:Recompute()
	end
	owner.depthMaterialVersion = DEPTH_MATERIAL_VERSION
end
refreshMaterialDepth( R )
if MC.RenderPackResources then refreshMaterialDepth( MC.RenderPackResources.shared ) end

-- Four corner rows occupy physical rows 0,1,3,4; row 2 holds one RGBA AO
-- texel per quad. Only complete five-row groups are allocated.
function R.CornerTexel( address )
	return address % ATLAS_SIZE, floor( ( floor( address / ATLAS_SIZE ) + 0.5 ) * 1.25 )
end

function R.OcclusionTexel( quad )
	return quad % ATLAS_SIZE, floor( quad / ATLAS_SIZE ) * 5 + 2
end

-- Internal helpers throw to the diagnostic owner, which reports after restoring
-- its render state. MC.Fault can itself throw when mc_strict is enabled.
function R.Require( ok, code, message )
	if not ok then error( { code = code, message = message }, 0 ) end
end
local requireValue = R.Require

function R.ValidateBuild()
	local catalog = MC.RenderPackRegistry
	requireValue( catalog and catalog.Get and catalog.Revision, "l2_visual_catalog", "render pack catalog is unavailable" )
	local build, err = catalog.Get( "pack", "mc:vanilla" )
	requireValue( type( build ) == "table" and build.schema == 1,
		"l2_visual_manifest", "mc:vanilla JSON descriptor is unavailable; run mc_render_pack scan: " .. tostring( err ) )
	requireValue( type( build.build ) == "string" and #build.build == 64
		and not build.build:find( "[^0-9a-f]" ), "l2_visual_fingerprint", "invalid candidate fingerprint" )
	requireValue( not R.build or R.build == build.build, "l2_visual_build_changed",
		"candidate build changed; restart the client before using another fingerprint" )
	requireValue( build.abi == 1 and build.layout == "mc:quad_corners_v1"
		and ( build.adapter == "mc:vanilla_quad_draft" or build.adapter == "mc:vanilla_quad_v2" ),
		"l2_visual_binding", "unsupported quad binding contract" )
	requireValue( file and file.Read and util and util.SHA256, "l2_visual_verify_api",
		"candidate verification requires file.Read and util.SHA256" )
	requireValue( type( build.programs ) == "table", "l2_visual_programs", "missing candidate programs" )
	local verified = {}
	for _, kind in ipairs( { "opaque", "cutout", "translucent" } ) do
		local program = build.programs[kind]
		requireValue( type( program ) == "table", "l2_visual_programs", "missing " .. kind .. " program" )
		for _, stage in ipairs( { "vertex", "pixel" } ) do
			local suffix = stage == "vertex" and "_vs30" or "_ps30"
			local name = "mc_vanilla_" .. ( stage == "vertex" and "vertex" or kind ) .. "_" .. build.build:sub( 1, 20 ) .. suffix
			requireValue( program[stage] == name, "l2_visual_program_name", "unexpected " .. kind .. " " .. stage .. " name" )
			local hash = program[stage .. "Hash"]
			if verified[name] then
				requireValue( verified[name] == hash, "l2_visual_program_hash", "conflicting hash for " .. name )
			else
				local bytes = file.Read( "shaders/fxc/" .. name .. ".vcs", "GAME" )
				requireValue( type( bytes ) == "string" and #bytes > 0 and #bytes <= 16777216
					and util.SHA256( bytes ) == hash, "l2_visual_program_bytes",
					"missing or mismatched " .. name .. ".vcs; mount mc_shaderpack_vanilla on the client and restart" )
				verified[name] = hash
			end
		end
	end
	return build, catalog.Revision( "pack", "mc:vanilla" )
end

function R.SourceTexture( material )
	requireValue( material and not material:IsError(), "l2_visual_source_material", "source material is unavailable" )
	local texture = material:GetTexture( "$basetexture" )
	requireValue( texture and not texture:IsError(), "l2_visual_source_texture", "source material has no valid $basetexture" )
	return texture
end

-- GetTexture can return distinct Lua wrappers for the same named engine texture.
function R.SameTexture( a, b )
	return a:GetName() == b:GetName() and a:Width() == b:Width() and a:Height() == b:Height()
end

R.pixelTextures = R.pixelTextures or {}
R.queuedLightTextures = R.queuedLightTextures or {}
R.LIGHT_TEXTURE_VERSION = 2
R.lightTextureMigrations = R.lightTextureMigrations or 0
R.lightTextureMigrationPending = true
local uploadQueuedLightPixels
local ensureQueuedLightmap

function R.LightTextureRevision()
	local reader = R.lightTextureRevisionReader
	if reader then return reader() end
	return 0
end

local function ensureUploadMaterial()
	if not R.uploadMaterial then
		R.uploadMaterial = CreateMaterial( "mc_l2_data_upload_linear1", "UnlitGeneric", {
			["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1,
			["$ignorez"] = 1, ["$nofog"] = 1, ["$nocull"] = 1, ["$no_fullbright"] = 1,
			["$gammacolorread"] = 1, ["$linearwrite"] = 1,
		} )
	end
	requireValue( R.uploadMaterial and not R.uploadMaterial:IsError(),
		"l2_visual_upload_material", "could not create the exact-byte upload material" )
end

-- Only the tiny, frequently rewritten light tables use queued RT writes. The
-- 16K corner/AO atlas stays procedural and never enters the queue vertex pool.
local function createQueuedLightTexture( name, width, height, point, initialPixels )
	requireValue( width * height <= 256 and GetRenderTargetEx and mesh and mesh.Begin
		and mesh.Color and mesh.Position and mesh.TexCoord and mesh.AdvanceVertex and mesh.End
		and render and render.SetMaterial and render.PushRenderTarget and render.PopRenderTarget
		and render.OverrideBlend and render.OverrideAlphaWriteEnable and render.OverrideColorWriteEnable
		and render.GetToneMappingScaleLinear and render.SetToneMappingScaleLinear
		and cam and cam.Start2D and cam.End2D and CreateMaterial and Vector and bit and bit.bor
		and MATERIAL_QUADS ~= nil and RT_SIZE_LITERAL ~= nil and MATERIAL_RT_DEPTH_NONE ~= nil
		and IMAGE_FORMAT_RGBA8888 ~= nil and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil,
		"l2_light_texture_api", "bounded queued light upload requires render targets and mesh drawing" )
	if mcmesh and mcmesh.L2PixelTextureVersion then
		requireValue( mcmesh.L2LightTextureRevision, "l2_light_texture_revision_api",
			"install the updated native module and restart to support queued light texture restoration" )
		R.lightTextureRevisionReader = mcmesh.L2LightTextureRevision
	end
	ensureUploadMaterial()
	local flags = bit.bor( 4, 8, 256, 512 )
	if point then flags = bit.bor( flags, 1 ) end
	local texture = GetRenderTargetEx( name, width, height, RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_NONE, flags, 0, IMAGE_FORMAT_RGBA8888 )
	requireValue( texture and not texture:IsError() and texture:Width() == width and texture:Height() == height,
		"l2_light_texture_create", "could not create the bounded RGBA8 light texture" )
	local vertices = {}
	for i = 0, width * height - 1 do
		local x, y = i % width, floor( i / width )
		vertices[i + 1] = { Vector( x, y, 0 ), Vector( x + 1, y, 0 ),
			Vector( x + 1, y + 1, 0 ), Vector( x, y + 1, 0 ) }
	end
	local layout = { width = width, height = height, vertices = vertices, deviceRevision = R.LightTextureRevision() }
	local pixels = initialPixels
	if not pixels then
		pixels = {}
		for i = 1, width * height do pixels[i] = 0 end
	end
	requireValue( #pixels == width * height, "l2_light_texture_initial_pixels",
		"initial light table must cover the complete target" )
	uploadQueuedLightPixels( texture, layout, 0, pixels )
	R.queuedLightTextures[texture:GetName()] = layout
	return texture
end

-- Migration runs before a draw transaction. Populate the new table and change
-- all retained samplers before retiring the old procedural resource. Release
-- drains its older queued consumers once; steady-state writes stay queued.
local function replaceLightTexture( previous, name, width, height, point, pixels, materials )
	local bindings = {}
	if previous then
		for material in pairs( materials ) do
			requireValue( material and not material:IsError(), "l2_light_texture_migration_material",
				"retained light sampler material is unavailable" )
			local texture = material:GetTexture( "$texture2" )
			requireValue( texture and not texture:IsError(), "l2_light_texture_migration_sampler",
				"retained material has no valid light table sampler" )
			if R.SameTexture( texture, previous ) then
				bindings[#bindings + 1] = { material = material, previous = texture }
			end
		end
	end
	local candidate = createQueuedLightTexture( name, width, height, point, pixels )
	local previousName, previousId
	if previous then
		previousName = previous:GetName()
		previousId = R.pixelTextures[previousName]
	end
	local changed = 0
	local ok, why = pcall( function()
		for i = 1, #bindings do
			changed = i
			bindings[i].material:SetTexture( "$texture2", candidate )
		end
		if previousId then
			local released, releaseError = mcmesh.ReleaseL2PixelTexture( previousId )
			requireValue( released, "l2_light_texture_migration_release", tostring( releaseError ) )
		end
	end )
	if not ok then
		local errors = {}
		for i = changed, 1, -1 do
			local binding = bindings[i]
			local restored, restoreError = pcall( binding.material.SetTexture,
				binding.material, "$texture2", binding.previous )
			if not restored then errors[#errors + 1] = tostring( restoreError ) end
		end
		if #errors > 0 then
			local message = tostring( why )
			if type( why ) == "table" and why.message then message = tostring( why.message ) end
			requireValue( false, "l2_light_texture_migration_rollback",
				message .. "; rollback: " .. table.concat( errors, "; " ) )
		end
		error( why, 0 )
	end
	if previousId then R.pixelTextures[previousName] = nil end
	if previous then R.lightTextureMigrations = R.lightTextureMigrations + 1 end
	return candidate
end

local function migrateRetainedLightTextures()
	if R.lightmap then ensureQueuedLightmap( R ) end
	local packs = MC.RenderPackResources
	if packs and packs.shared.lightmap then ensureQueuedLightmap( packs.shared ) end
	if R.dynamicLightTexture then R.DynamicLightTexture() end
end

local function lightTextureMode( texture )
	if not texture then return "uninitialized" end
	local name = texture:GetName()
	if R.queuedLightTextures[name] then return "queued_rt" end
	if R.pixelTextures[name] then return "native_sync" end
	return "legacy_rt"
end

function R.LightTextureStatus( owner )
	owner = owner or R
	return { version = R.LIGHT_TEXTURE_VERSION, lightmap = lightTextureMode( owner.lightmap ),
		dynamic = lightTextureMode( R.dynamicLightTexture ), migrations = R.lightTextureMigrations }
end

function R.CreatePixelTexture( width, height, point )
	requireValue( mcmesh and mcmesh.L2PixelTextureVersion and mcmesh.L2PixelTextureVersion() == 2 and mcmesh.CreateL2PixelTexture and mcmesh.UploadL2PixelTexture
		and mcmesh.FlushL2PixelTextures and mcmesh.BindL2PixelTexture and mcmesh.ReleaseL2PixelTexture,
		"l2_pixel_texture_api", "install the current native module and restart: Source pixel texture upload is required" )
	local descriptor, why = mcmesh.CreateL2PixelTexture( width, height, point )
	requireValue( descriptor, "l2_pixel_texture_create", tostring( why ) )
	local texture
	local ok, reason = pcall( function()
		local material = CreateMaterial( descriptor.name .. "_handle", "UnlitGeneric", { ["$basetexture"] = "vgui/white" } )
		requireValue( material and not material:IsError(), "l2_pixel_texture_material", "pixel texture material creation failed" )
		local bound, err = mcmesh.BindL2PixelTexture( descriptor.id, "!" .. material:GetName(), "$basetexture" )
		requireValue( bound, "l2_pixel_texture_bind", tostring( err ) )
		texture = material:GetTexture( "$basetexture" )
		requireValue( texture and not texture:IsError() and texture:Width() == width and texture:Height() == height,
			"l2_pixel_texture_dimensions", "Source pixel texture dimensions differ" )
	end )
	if not ok then
		local released, releaseError = mcmesh.ReleaseL2PixelTexture( descriptor.id )
		requireValue( released, "l2_pixel_texture_cleanup", tostring( releaseError ) )
		error( reason, 0 )
	end
	R.pixelTextures[texture:GetName()] = descriptor.id
	return texture
end

-- UploadPart only stages bytes. Every consumer enters here before sampling;
-- native drains older queued draws before publishing all pending rows together.
function R.FlushUploads()
	if R.lightTextureMigrationPending then
		local ok, why = pcall( migrateRetainedLightTextures )
		if not ok then
			return MC.Fault( "l2_light_texture_migration", "%s",
				type( why ) == "table" and why.message or tostring( why ) )
		end
		R.lightTextureMigrationPending = false
	end
	if not next( R.pixelTextures ) then return true end
	local ok, why = mcmesh.FlushL2PixelTextures()
	return MC.Check( ok, "l2_pixel_texture_flush", "%s", tostring( why ) )
end

-- Opt-in diagnostics only. Procedural textures cannot be pushed as an RT.
-- One image quad copies them into a caller-owned readback target.
function R.CopyPixelTexture( texture, target, sourceX, sourceY )
	requireValue( R.FlushUploads(), "l2_pixel_readback_flush", "pixel upload failed before readback" )
	sourceX, sourceY = sourceX or 0, sourceY or 0
	local w, h, tw, th = target:Width(), target:Height(), texture:Width(), texture:Height()
	requireValue( sourceX >= 0 and sourceY >= 0 and sourceX + w <= tw and sourceY + h <= th,
		"l2_pixel_readback_size", "readback region must preserve texel dimensions" )
	local material = CreateMaterial( texture:GetName() .. "_readback2", "UnlitGeneric", {
		["$basetexture"] = "vgui/white", ["$translucent"] = 1,
		["$ignorez"] = 1, ["$nofog"] = 1, ["$nocull"] = 1, ["$no_fullbright"] = 1,
		["$gammacolorread"] = 1, ["$linearwrite"] = 1,
	} )
	local id = R.pixelTextures[texture:GetName()]
	if id then
		-- Track this reference so releasing a diagnostic texture also unbinds
		-- its cached readback material instead of retaining a 1 GiB GPU image.
		local bound, why = mcmesh.BindL2PixelTexture( id, "!" .. material:GetName(), "$basetexture" )
		requireValue( bound, "l2_pixel_readback_bind", tostring( why ) )
	else material:SetTexture( "$basetexture", texture ) end
	R.pixelReadbackQuads = R.pixelReadbackQuads or {}
	local key = table.concat( { w, h, tw, th, sourceX, sourceY }, ":" )
	local quad = R.pixelReadbackQuads[key]
	if not quad then
		local u0, v0, u1, v1 = sourceX / tw, sourceY / th, ( sourceX + w ) / tw, ( sourceY + h ) / th
		quad = Mesh( material )
		quad:BuildFromTriangles( {
			{ pos = Vector( 0, 0, 0 ), u = u0, v = v0 }, { pos = Vector( w, 0, 0 ), u = u1, v = v0 },
			{ pos = Vector( w, h, 0 ), u = u1, v = v1 }, { pos = Vector( 0, 0, 0 ), u = u0, v = v0 },
			{ pos = Vector( w, h, 0 ), u = u1, v = v1 }, { pos = Vector( 0, h, 0 ), u = u0, v = v1 },
		} )
		R.pixelReadbackQuads[key] = quad
	end
	local pushed, camera, clipping, tone
	local ok, why = pcall( function()
		tone = render.GetToneMappingScaleLinear()
		render.SetToneMappingScaleLinear( Vector( 1, 1, 1 ) )
		render.PushRenderTarget( target ) pushed = true
		cam.Start2D() camera = true
		clipping = DisableClipping( true )
		render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
		render.OverrideAlphaWriteEnable( true, true )
		render.OverrideColorWriteEnable( true, true )
		render.SetMaterial( material ) quad:Draw()
	end )
	local errors = {}
	local function restore( active, fn, ... )
		if not active then return end
		local restored, reason = pcall( fn, ... )
		if not restored then errors[#errors + 1] = tostring( reason ) end
	end
	restore( pushed, render.OverrideColorWriteEnable, false )
	restore( pushed, render.OverrideAlphaWriteEnable, false )
	restore( pushed, render.OverrideBlend, false )
	restore( clipping ~= nil, DisableClipping, clipping )
	restore( camera, cam.End2D )
	restore( pushed, render.PopRenderTarget )
	restore( tone ~= nil, render.SetToneMappingScaleLinear, tone )
	requireValue( #errors == 0, "l2_pixel_readback_restore", table.concat( errors, "; " ) )
	if not ok then error( why, 0 ) end
end

ensureQueuedLightmap = function( owner )
	local previous = owner.lightmap
	if previous and owner.lightmapTextureVersion == R.LIGHT_TEXTURE_VERSION
		and owner.queuedLightmapTexture == previous then return end
	if previous and R.queuedLightTextures[previous:GetName()] then
		owner.lightmapTextureVersion, owner.queuedLightmapTexture = R.LIGHT_TEXTURE_VERSION, previous
		return
	end
	local materials = {}
	for _, material in pairs( owner.materials ) do materials[material] = true end
	local packs, scene = MC.RenderPackResources, MC.RenderScene
	if packs and owner == packs.shared and scene then
		for _, group in pairs( scene.groups ) do materials[group.composite] = true end
	end
	owner.lightmap = replaceLightTexture( previous, ( owner.prefix or "mc_l2_visual" ) .. "_lightmap_queued_v2",
		LIGHTMAP_SIZE, LIGHTMAP_SIZE, false, owner.lightmapPixels, materials )
	owner.lightmapTextureVersion, owner.queuedLightmapTexture = R.LIGHT_TEXTURE_VERSION, owner.lightmap
	owner.lightmapRevision, owner.lightmapDeviceRevision = nil, nil
	owner.lightmapUploadPending = true
end

function R.Ensure( build, owner )
	owner = owner or R
	R.drawPixels = nil
	if mcmesh and mcmesh.L2PixelTextureVersion then
		owner.build = build.build
		requireValue( not owner.atlas or R.pixelTextures[owner.atlas:GetName()],
			"l2_pixel_texture_restart", "restart to replace the old render-target light atlas" )
		if not owner.atlas then owner.atlas = R.CreatePixelTexture( ATLAS_SIZE, ATLAS_HEIGHT, true ) end
		ensureQueuedLightmap( owner )
		return
	end
	requireValue( GetRenderTargetEx and CreateMaterial and render and render.PushRenderTarget
		and render.PopRenderTarget and render.OverrideBlend and render.OverrideAlphaWriteEnable
		and render.OverrideColorWriteEnable and render.OverrideDepthEnable and cam and cam.Start2D
		and cam.End2D and surface and surface.SetDrawColor and surface.SetMaterial and surface.DrawTexturedRect
		and render.GetToneMappingScaleLinear and render.SetToneMappingScaleLinear and Vector and DisableClipping
		and bit and bit.bor and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil
		and RT_SIZE_LITERAL ~= nil and MATERIAL_RT_DEPTH_NONE ~= nil and IMAGE_FORMAT_RGBA8888 ~= nil,
		"l2_visual_resource_api", "quad diagnostics require RGBA8 targets and exact-byte render overrides" )
	owner.build = build.build
	local prefix = owner.prefix or "mc_l2_visual"
	if not owner.atlas then
		owner.atlas = GetRenderTargetEx( prefix .. "_quad_ao16k_v1", ATLAS_SIZE, ATLAS_HEIGHT,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
	end
	requireValue( owner.atlas and not owner.atlas:IsError() and owner.atlas:Width() == ATLAS_SIZE and owner.atlas:Height() == ATLAS_HEIGHT,
		"l2_visual_atlas", "16384x16384 point-filter corner/AO atlas required; restart clients retaining the old atlas" )
	ensureQueuedLightmap( owner )
end

function R.BoundMaterial( owner, slot, source, stage, blockSize, program, colorSpace, pbrMaps, atlasBank )
	refreshMaterialDepth( owner )
	local material = owner.materials[slot]
	if not material then
		local params = {
			["$vertexshader"] = program.vertex,
			["$pixshader"] = program.pixel,
			["$basetexture"] = source:GetName(),
			["$texture1"] = owner.atlas:GetName(), ["$texture2"] = owner.lightmap:GetName(),
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1,
			-- Vanilla fluids share the translucent atlas and have no reverse-face mesh.
			["$nocull"] = ( pbrMaps and pbrMaps.water or not pbrMaps and stage == "world_translucent" ) and 1 or 0,
			-- In screenspace_general, WRITEDEPTH=1 also selects DepthFunc(ALWAYS).
			-- Keep the default comparison; solid draw passes enable writes with
			-- render.OverrideDepthEnable(true, true). Water/glass only test depth.
			["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
			["$linearread_basetexture"] = colorSpace == "srgb"
				and not MC.ResourceGeneration.textures[source:GetName()] and 0 or 1, ["$linearread_texture1"] = 1,
			["$linearread_texture2"] = 1, ["$linearwrite"] = 1,
			["$c0_x"] = tostring( 1 / blockSize ), ["$c0_y"] = "0",
			["$c0_z"] = tostring( atlasBank or 0 ), ["$c0_w"] = "0.5",
		}
		if stage == "world_translucent" then
			params["$alphablend"], params["$translucent"] = 1, 1
		elseif stage == "world_cutout" then
			params["$alphatest"], params["$alphatested"], params["$alphatestreference"] = 1, 1, "0.5"
		end
		if pbrMaps then MC.RenderPBR.Parameters( params, pbrMaps ) end
		material = CreateMaterial( ( owner.prefix or "mc_l2_visual" ) .. DEPTH_MATERIAL_VERSION .. "_" .. slot,
			"screenspace_general_8tex", params )
		owner.materials[slot] = material
	end
	requireValue( material and not material:IsError(), "l2_visual_material", "could not create candidate material " .. slot )
	material:SetTexture( "$basetexture", source )
	material:SetTexture( "$texture1", owner.atlas )
	material:SetTexture( "$texture2", owner.lightmap )
	if pbrMaps then
		material:SetTexture( "$texture3", pbrMaps.normal )
		material:SetTexture( "$texture4", pbrMaps.orm )
		if pbrMaps.environment then
			material:SetTexture( "$texture6", pbrMaps.environment )
			material:SetTexture( "$texture7", pbrMaps.dfg )
		end
		MC.RenderPBR.Register( material )
	else
		material:SetFloat( "$c0_x", 1 / blockSize )
		MC.RenderVanillaWater.Register( material )
	end
	if MC.ResourceGeneration then
		if pbrMaps then MC.RenderPBR.BindSampling(material,source)
		else MC.ResourceGeneration.BindSampling(material,source) end
	end
	return material
end

function R.Material( index, source, translucent, blockSize, build )
	local pass = translucent and "translucent" or "cutout"
	return R.BoundMaterial( R, pass .. index, source, "world_" .. pass, blockSize, build.programs[pass], "linear" )
end

local function drawPixelRuns( width, firstPixel, pixels, zeroAlpha, rowScale, rowOffset )
	local i, hasZeroAlpha = 1, false
	while i <= #pixels do
		local pixel, value = firstPixel + i - 1, pixels[i]
		local x, y = pixel % width, floor( floor( pixel / width ) * rowScale + rowOffset )
		local length, limit = 1, math.min( #pixels - i + 1, width - x )
		while length < limit and pixels[i + length] == value do length = length + 1 end
		local alpha = floor( value / 16777216 )
		if alpha == 0 then hasZeroAlpha = true end
		if ( alpha == 0 ) == zeroAlpha then
			surface.SetDrawColor( value % 256, floor( value / 256 ) % 256,
				floor( value / 65536 ) % 256, zeroAlpha and 255 or alpha )
			surface.DrawTexturedRect( x, y, length, 1 )
		end
		i = i + length
	end
	return hasZeroAlpha
end

uploadQueuedLightPixels = function( texture, layout, firstPixel, pixels )
	-- Validate before entering mesh.Begin. Every queued vertex owns its RGBA,
	-- so a later CPU update cannot change an earlier view's light table.
	requireValue( type( firstPixel ) == "number" and firstPixel == floor( firstPixel ) and firstPixel >= 0
		and #pixels > 0 and firstPixel + #pixels <= layout.width * layout.height,
		"l2_light_upload_range", "light upload exceeds its bounded target" )
	for i = 1, #pixels do
		local value = pixels[i]
		requireValue( type( value ) == "number" and value >= 0 and value <= 4294967295 and value == floor( value ),
			"l2_light_upload_pixel", "light upload requires packed RGBA8 values" )
	end
	local pushed, camera, tone, blend, alpha, color = false, false, false, false, false, false
	local building = false
	local previousTone
	local ok, why = pcall( function()
		previousTone = render.GetToneMappingScaleLinear()
		tone = true
		render.SetToneMappingScaleLinear( Vector( 1, 1, 1 ) )
		render.PushRenderTarget( texture ) pushed = true
		cam.Start2D() camera = true
		render.SetMaterial( R.uploadMaterial )
		render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD ) blend = true
		render.OverrideAlphaWriteEnable( true, true ) alpha = true
		render.OverrideColorWriteEnable( true, true ) color = true
		mesh.Begin( MATERIAL_QUADS, #pixels )
		building = true
		for i = 1, #pixels do
			local value = pixels[i]
			local r, g, b, a = value % 256, floor( value / 256 ) % 256,
				floor( value / 65536 ) % 256, floor( value / 16777216 )
			local corners = layout.vertices[firstPixel + i]
			for corner = 1, 4 do
				mesh.Position( corners[corner] )
				mesh.TexCoord( 0, 0.5, 0.5 )
				mesh.Color( r, g, b, a )
				mesh.AdvanceVertex()
			end
		end
		mesh.End()
		building = false
	end )
	local errors = {}
	local function restore( active, fn, ... )
		if not active then return end
		local restored, reason = pcall( fn, ... )
		if not restored then errors[#errors + 1] = tostring( reason ) end
	end
	restore( building, mesh.End )
	restore( color, render.OverrideColorWriteEnable, false )
	restore( alpha, render.OverrideAlphaWriteEnable, false )
	restore( blend, render.OverrideBlend, false )
	restore( camera, cam.End2D )
	restore( pushed, render.PopRenderTarget )
	restore( tone, render.SetToneMappingScaleLinear, previousTone )
	requireValue( #errors == 0, "l2_light_upload_restore", table.concat( errors, "; " ) )
	if not ok then error( why, 0 ) end
end

local function uploadPixels( texture, width, firstPixel, pixels, rowScale, rowOffset, firstOcclusion, occlusion )
	local queued = R.queuedLightTextures[texture:GetName()]
	if queued then
		requireValue( width == queued.width and not rowScale and not rowOffset and not occlusion,
			"l2_light_upload_layout", "queued light textures do not support atlas addressing" )
		uploadQueuedLightPixels( texture, queued, firstPixel, pixels )
		return
	end
	local id = R.pixelTextures[texture:GetName()]
	if id then
		local ok, why = mcmesh.UploadL2PixelTexture( id, firstPixel, pixels, rowScale or 1, rowOffset or 0, firstOcclusion, occlusion )
		requireValue( ok == true, "l2_pixel_texture_upload", tostring( why ) )
		return
	end
	rowScale, rowOffset = rowScale or 1, rowOffset or 0
	local pushed, camera, blend, alpha, color, tone = false, false, false, false, false, false
	local oldToneScale, oldClipping
	local clipping = false
	local ok, err = pcall( function()
		requireValue( R.uploadMaterial and not R.uploadMaterial:IsError(),
			"l2_visual_upload_material", "exact-byte upload material is unavailable" )
		oldToneScale = render.GetToneMappingScaleLinear()
		render.PushRenderTarget( texture ) pushed = true
		cam.Start2D() camera = true
		-- Surface otherwise clips atlas writes to the game screen bounds.
		oldClipping = DisableClipping( true ) clipping = true
		-- Match the L1 packed uploader: no VGUI gamma conversion or exposure.
		tone = true
		render.SetToneMappingScaleLinear( Vector( 1, 1, 1 ) )
		surface.SetMaterial( R.uploadMaterial )
		render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD ) blend = true
		render.OverrideAlphaWriteEnable( true, true ) alpha = true
		render.OverrideColorWriteEnable( true, true ) color = true
		local zeroPixels = drawPixelRuns( width, firstPixel, pixels, false, rowScale, rowOffset )
		local zeroOcclusion = false
		if occlusion then zeroOcclusion = drawPixelRuns( width, firstOcclusion, occlusion, false, 5, 2 ) end
		if zeroPixels or zeroOcclusion then
			-- Surface drops alpha-zero draws before blending. Non-overlapping
			-- zero-alpha runs submit opaque RGB and store alpha via ZERO/ZERO.
			render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ZERO, BLENDFUNC_ADD )
			if zeroPixels then drawPixelRuns( width, firstPixel, pixels, true, rowScale, rowOffset ) end
			if zeroOcclusion then drawPixelRuns( width, firstOcclusion, occlusion, true, 5, 2 ) end
		end
	end )
	local errors = {}
	local function restore( active, fn, ... )
		if not active then return end
		local restored, why = pcall( fn, ... )
		if not restored then errors[#errors + 1] = tostring( why ) end
	end
	restore( color, render.OverrideColorWriteEnable, false )
	restore( alpha, render.OverrideAlphaWriteEnable, false )
	restore( blend, render.OverrideBlend, false )
	restore( clipping, DisableClipping, oldClipping )
	restore( tone, render.SetToneMappingScaleLinear, oldToneScale )
	restore( camera, cam.End2D )
	restore( pushed, render.PopRenderTarget )
	requireValue( ok and #errors == 0, "l2_visual_upload",
		"candidate pixel upload failed: " .. tostring( err ) .. " " .. table.concat( errors, "; " ) )
end

-- Local lights have a separate tiny data texture, consumed only by the
-- additive programs. The original lightmap/base shaders remain byte-identical.
function R.DynamicLightTexture()
	local previous = R.dynamicLightTexture
	if previous and R.dynamicLightTextureVersion == R.LIGHT_TEXTURE_VERSION
		and R.queuedDynamicLightTexture == previous then return previous end
	if not previous or not R.queuedLightTextures[previous:GetName()] then
		local materials, pixels = {}, nil
		local dynamic = MC.RenderDynamicLights
		if dynamic then
			for _, state in pairs( dynamic.materials ) do materials[state.material] = true end
			if dynamic.uploadValid then
				pixels = {}
				for i = 1, 40 do pixels[i] = dynamic.previousPixels[i] end
				for i = 41, 64 do pixels[i] = 0 end
			end
		end
		R.dynamicLightTexture = replaceLightTexture( previous, "mc_dynamic_lights_rgba8_queued_v2",
			64, 1, true, pixels, materials )
		if dynamic then dynamic.uploadValid = false end
	end
	local texture = R.dynamicLightTexture
	requireValue( texture and not texture:IsError() and texture:Width() == 64 and texture:Height() == 1,
		"dynamic_light_texture", "could not create the 64x1 point-filter light data texture" )
	R.dynamicLightTextureVersion, R.queuedDynamicLightTexture = R.LIGHT_TEXTURE_VERSION, texture
	return texture
end

function R.UploadDynamicLights( pixels )
	requireValue( #pixels == 40, "dynamic_light_upload_size", "eight five-texel light records required" )
	local texture = R.DynamicLightTexture()
	local layout = R.queuedLightTextures[texture:GetName()]
	local deviceRevision = R.LightTextureRevision()
	if layout.deviceRevision ~= deviceRevision then
		local restored = {}
		for i = 1, 40 do restored[i] = pixels[i] end
		for i = 41, 64 do restored[i] = 0 end
		uploadPixels( texture, 64, 0, restored )
		layout.deviceRevision = deviceRevision
	else
		uploadPixels( texture, 64, 0, pixels )
	end
	-- The RT write precedes this view's sampling in Source's own queue. Flushing
	-- procedural atlas work here would introduce an unrelated per-view wait.
end

function R.UploadPart( part, owner )
	owner = owner or R
	requireValue( part.quadCount > 0 and part.quadCount <= math.floor( MC.RenderMeshConstants.VERT_LIMIT / 6 )
		and ( part.nativeL2 or part.pixels and #part.pixels == part.quadCount * 4
			and part.occlusion and #part.occlusion == part.quadCount )
		and part.firstQuad >= 0 and part.firstQuad + part.quadCount <= ( owner.capacity or 8192 ),
		"l2_visual_atlas_range", "candidate atlas upload exceeds its bounded quad range" )
	if part.nativeL2 then
		local module = MC.NativeL2.module
		local id = R.pixelTextures[owner.atlas:GetName()]
		requireValue( id, "l2_pixel_texture_handle", "Native mesh requires an owned pixel texture" )
		local ok, why = module.UploadL2MeshPixels( part.mesh, id, part.firstQuad )
		requireValue( ok == true, "l2_native_pixel_upload", tostring( why ) )
		return
	end
	uploadPixels( owner.atlas, ATLAS_SIZE, part.firstQuad * 4, part.pixels, 1.25, 0.625, part.firstQuad, part.occlusion )
end

-- C++ stages the whole section and flushes it before CPU publication. Both
-- versions remain Native-owned, including rollback after a failed submission.
function R.UploadNativeLighting( transaction, owner, module, restore )
	local id = R.pixelTextures[owner.atlas:GetName()]
	requireValue( id, "l2_pixel_texture_handle", "Native lighting requires an owned pixel texture" )
	local ok, why = module.UploadL2Relight( transaction, id, restore == true )
	requireValue( ok == true, "l2_native_pixel_upload", tostring( why ) )
end

function R.UploadNativeLightingBatch( transactions, owner, module )
	local id = R.pixelTextures[owner.atlas:GetName()]
	requireValue( id, "l2_pixel_texture_handle", "Native lighting requires an owned pixel texture" )
	local ok, why = module.UploadL2RelightBatch( transactions, id )
	requireValue( ok == true, "l2_native_pixel_upload", tostring( why ) )
end

function R.RefreshLightmap( owner )
	owner = owner or R
	local revision = MC.GlobalLightmapRevision
	requireValue( type( revision ) == "number" and revision > 0 and MC.SampleGlobalLightmapRGB,
		"l2_visual_lightmap_unready", "wait for the first successful global lightmap refresh" )
	-- Active owners skip Ensure after Lua refresh. Migrate before the revision
	-- shortcut and before staging bytes, even when the lighting itself is fixed.
	ensureQueuedLightmap( owner )
	local deviceRevision = R.LightTextureRevision()
	if owner.lightmapRevision == revision and owner.lightmapDeviceRevision == deviceRevision then return end
	local previous = owner.lightmapPixels
	local pixels = owner.lightmapPendingPixels or {}
	owner.lightmapPendingPixels = pixels
	local changed = not previous or owner.lightmapUploadPending or owner.lightmapDeviceRevision ~= deviceRevision
	for sky = 0, 15 do
		for block = 0, 15 do
			local r, g, b = MC.SampleGlobalLightmapRGB( block, sky )
			requireValue( type( r ) == "number" and r >= 0 and r <= 1
				and type( g ) == "number" and g >= 0 and g <= 1
				and type( b ) == "number" and b >= 0 and b <= 1,
				"l2_visual_lightmap_sample", "global lightmap returned invalid RGB" )
			local index = sky * 16 + block + 1
			local pixel = floor( r * 255 + 0.5 ) + floor( g * 255 + 0.5 ) * 256
				+ floor( b * 255 + 0.5 ) * 65536 + 255 * 16777216
			pixels[index] = pixel
			if not changed and previous[index] ~= pixel then changed = true end
		end
	end
	if changed then
		-- A failed upload may have changed part of the RT. Repair it even if
		-- the next revision returns to the last successfully published bytes.
		owner.lightmapUploadPending = true
		uploadPixels( owner.lightmap, LIGHTMAP_SIZE, 0, pixels )
		owner.lightmapPixels, owner.lightmapPendingPixels = pixels, previous
		owner.lightmapUploadPending = false
		owner.lightmapUploads = ( owner.lightmapUploads or 0 ) + 1
	else
		owner.lightmapSkippedUploads = ( owner.lightmapSkippedUploads or 0 ) + 1
	end
	owner.lightmapRevision = revision
	owner.lightmapDeviceRevision = deviceRevision
end
