-- Owned quad resources. The diagnostic and pack runtime never share writable slots.
MC = MC or {}
local R = MC.RenderL2Resources or { materials = {} }
MC.RenderL2Resources = R
local floor = math.floor
local ATLAS_SIZE, LIGHTMAP_SIZE = 2048, 16

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
	requireValue( build.abi == 1 and build.layout == "mc:quad_corners_v1" and build.adapter == "mc:vanilla_quad_draft",
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

function R.Ensure( build, owner )
	owner = owner or R
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
		owner.atlas = GetRenderTargetEx( prefix .. "_quad1", ATLAS_SIZE, ATLAS_SIZE,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
	end
	requireValue( owner.atlas and not owner.atlas:IsError() and owner.atlas:Width() == ATLAS_SIZE and owner.atlas:Height() == ATLAS_SIZE,
		"l2_visual_atlas", "could not create the 2048x2048 point-filter corner atlas" )
	if not owner.lightmap then
		-- No POINTSAMPLE bit: L2 performs its lightmap lookup at each quad corner.
		owner.lightmap = GetRenderTargetEx( prefix .. "_lightmap1", LIGHTMAP_SIZE, LIGHTMAP_SIZE,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor( 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
	end
	requireValue( owner.lightmap and not owner.lightmap:IsError()
		and owner.lightmap:Width() == LIGHTMAP_SIZE and owner.lightmap:Height() == LIGHTMAP_SIZE,
		"l2_visual_lightmap", "could not create the separate 16x16 linear-filter lightmap" )
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

function R.BoundMaterial( owner, slot, source, stage, blockSize, program, colorSpace, pbrMaps )
	local material = owner.materials[slot]
	if not material then
		local params = {
			["$vertexshader"] = program.vertex,
			["$pixshader"] = program.pixel,
			["$basetexture"] = source:GetName(),
			["$texture1"] = owner.atlas:GetName(), ["$texture2"] = owner.lightmap:GetName(),
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$nocull"] = 0,
			["$linearread_basetexture"] = colorSpace == "srgb" and 0 or 1, ["$linearread_texture1"] = 1,
			["$linearread_texture2"] = 1, ["$linearwrite"] = 1,
			["$c0_x"] = tostring( 1 / blockSize ), ["$c0_y"] = "0",
			["$c0_z"] = tostring( 1 / ATLAS_SIZE ), ["$c0_w"] = "0.5",
		}
		if stage == "world_translucent" then
			params["$alphablend"], params["$translucent"] = 1, 1
		elseif stage == "world_cutout" then
			params["$alphatest"], params["$alphatested"], params["$alphatestreference"] = 1, 1, "0.5"
		end
		if pbrMaps then MC.RenderPBR.Parameters( params, pbrMaps ) end
		material = CreateMaterial( ( owner.prefix or "mc_l2_visual" ) .. "1_" .. slot, "screenspace_general_8tex", params )
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
	end
	return material
end

function R.Material( index, source, translucent, blockSize, build )
	local pass = translucent and "translucent" or "cutout"
	return R.BoundMaterial( R, pass .. index, source, "world_" .. pass, blockSize, build.programs[pass], "linear" )
end

local function drawPixelRuns( width, firstPixel, pixels, zeroAlpha )
	local i, hasZeroAlpha = 1, false
	while i <= #pixels do
		local pixel, value = firstPixel + i - 1, pixels[i]
		local x, y = pixel % width, floor( pixel / width )
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

local function uploadPixels( texture, width, firstPixel, pixels )
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
		if drawPixelRuns( width, firstPixel, pixels, false ) then
			-- Surface drops alpha-zero draws before blending. Non-overlapping
			-- zero-alpha runs submit opaque RGB and store alpha via ZERO/ZERO.
			render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ZERO, BLEND_ZERO, BLENDFUNC_ADD )
			drawPixelRuns( width, firstPixel, pixels, true )
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

function R.UploadPart( part, owner )
	owner = owner or R
	requireValue( part.quadCount > 0 and part.quadCount <= math.floor( MC.RenderMeshConstants.VERT_LIMIT / 6 )
		and #part.pixels == part.quadCount * 4
		and part.firstQuad >= 0 and part.firstQuad + part.quadCount <= ( owner.capacity or 8192 ),
		"l2_visual_atlas_range", "candidate atlas upload exceeds its bounded quad range" )
	uploadPixels( owner.atlas, ATLAS_SIZE, part.firstQuad * 4, part.pixels )
end

function R.RefreshLightmap( owner )
	owner = owner or R
	local revision = MC.GlobalLightmapRevision
	requireValue( type( revision ) == "number" and revision > 0 and MC.SampleGlobalLightmapRGB,
		"l2_visual_lightmap_unready", "wait for the first successful global lightmap refresh" )
	if owner.lightmapRevision == revision then return end
	local previous = owner.lightmapPixels
	local pixels = owner.lightmapPendingPixels or {}
	owner.lightmapPendingPixels = pixels
	local changed = not previous or owner.lightmapUploadPending
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
end
