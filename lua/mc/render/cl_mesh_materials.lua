-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh
local MC_LIGHT_STYLE_SHADER = RM.MC_LIGHT_STYLE_SHADER
local MC_LIGHT_STYLE_GPU_SHADER = RM.MC_LIGHT_STYLE_GPU_SHADER
local MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE = RM.MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE

local function gpuLightMaterialParams( params )
	-- The packed atlas stores arbitrary bytes, so sampler1 must bypass sRGB
	-- decoding. White is a safe fullbright slot-0 fallback until Native binds
	-- its procedural 4096x4096 texture after the ABI handshake.
	params["$texture1"] = "vgui/white"
	params["$linearread_texture1"] = 1
	return params
end

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
	},
	programmer_art = {
		opaquePath = atlasPngPath( MC.Atlas.MATERIAL_PROGRAMMER_ART or "mc/atlas_365_programmer_art" ),
		translucentPath = atlasPngPath( MC.Atlas.MATERIAL_PROGRAMMER_ART_TRANSLUCENT or "mc/atlas_365_programmer_art_translucent" ),
		iconPath = atlasPngPath( MC.Atlas.MATERIAL_PROGRAMMER_ART_TRANSLUCENT or "mc/atlas_365_programmer_art_translucent" ),
	},
}

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
do
	local baseTex, baseName = atlasBaseTexture()
	if baseTex and baseName and baseName ~= "" and CreateMaterial then
		local mat = CreateMaterial( "mc_atlas_gpu_payload8_centroid_vface_opaque", "screenspace_general", {
			["$pixshader"] = "mc_gpu_chunk_payload4_vface_ps30",
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
		-- Native vertices always carry the stable light-atlas slot payload.  When
		-- mc_light_texture is disabled we still need the light-texture vertex
		-- shader to unpack the face index from G; the cheap legacy pixel shader
		-- then draws ordinary full-bright/face-shaded terrain without sampling
		-- the chunk-light atlas.  Keeping one immutable Native payload avoids a
		-- whole-world mesh rebuild (and mixed old/new payloads) on every toggle.
		local nativeSlotMat = CreateMaterial( "mc_atlas_native_slot_payload1_centroid_vface_opaque", "screenspace_general", {
			["$pixshader"] = "mc_gpu_chunk_payload4_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
		} )
		if nativeSlotMat and not nativeSlotMat:IsError() then
			nativeSlotMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialNativeSlotOpaque = nativeSlotMat
		end
		local lightTexMat = CreateMaterial( "mc_atlas_gpu_lighttex44_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_vanilla_smooth35_clean_pcf_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
			-- Shadow-map params read by the pixel shader at c0..c2. Define all
			-- of them here so the engine reliably uploads these registers;
			-- $c3/$eyepos must stay undefined so the shader's inline literal
			-- constants outside c0..c2/c11..c18 are never overwritten.
			-- ($viewprojmat/$invviewprojmat are set at bind time: the shader
			-- declares c11..c18 for the cascade matrices/table.)
			["$c0_x"] = "0",
			["$c0_y"] = "0.0005",
			["$c0_z"] = "0",
			["$c0_w"] = "-2",
			["$c1_x"] = "0",
			["$c1_y"] = "0",
			["$c1_z"] = "-1",
			["$c1_w"] = "0.0001",
			["$c2_x"] = "0",
			["$c2_y"] = "0",
			["$c2_z"] = "0",
			["$c2_w"] = "0",
		} )
		if lightTexMat and not lightTexMat:IsError() then
			lightTexMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTexture = lightTexMat
		end
		local linearMat = CreateMaterial( "mc_atlas_gpu_lighttex43_linear_debug_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_vanilla_smooth33_linear_debug_vface_ps30", ["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30", ["$basetexture"] = baseName,
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$linearwrite"] = 0, ["$alphatest"] = "1", ["$alphatestreference"] = "0.5", ["$alphatested"] = 1, ["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-4", ["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001", ["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0",
		} )
		if linearMat and not linearMat:IsError() then linearMat:SetTexture( "$basetexture", baseTex ); MC.MaterialGpuLightTextureLinearDebug = linearMat end
		local lightTexPpFixMat = CreateMaterial( "mc_atlas_gpu_lighttex42_ppfix_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_vanilla_smooth32_ppfix_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-2",
			["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001",
			["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0",
		} )
		if lightTexPpFixMat and not lightTexPpFixMat:IsError() then
			lightTexPpFixMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTexturePpFix = lightTexPpFixMat
		end
		-- Fancy variant: same pipeline plus cool shadow tint, warm sun/torch
		-- grading, back-face sun shading and shadow-window edge fade. It is the
		-- ONLY material allowed to define $c3_* (its pixel shader declares and
		-- uses register c3); defining $c3 on the plain material would make the
		-- engine upload c3 over that shader's inline literal constants.
		local fancyMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy28_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy32_clean_pcf_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "0",
			["$c0_y"] = "0.0005",
			["$c0_z"] = "0",
			["$c0_w"] = "-2",
			["$c1_x"] = "0",
			["$c1_y"] = "0",
			["$c1_z"] = "-1",
			["$c1_w"] = "0.0001",
			["$c2_x"] = "0",
			["$c2_y"] = "0",
			["$c2_z"] = "0",
			["$c2_w"] = "0",
			["$c3_x"] = "0.6",
			["$c3_y"] = "0.1",
			["$c3_z"] = "0.65",
			["$c3_w"] = "0.35",
		} )
		if fancyMat and not fancyMat:IsError() then
			fancyMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTextureFancy = fancyMat
		end
		local fancyLinearMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy27_linear_debug_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy30_linear_debug_vface_ps30", ["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30", ["$basetexture"] = baseName,
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$linearwrite"] = 0, ["$alphatest"] = "1", ["$alphatestreference"] = "0.5", ["$alphatested"] = 1, ["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-4", ["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001", ["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0", ["$c3_x"] = "0.6", ["$c3_y"] = "0.1", ["$c3_z"] = "0", ["$c3_w"] = "0.35",
		} )
		if fancyLinearMat and not fancyLinearMat:IsError() then fancyLinearMat:SetTexture( "$basetexture", baseTex ); MC.MaterialGpuLightTextureFancyLinearDebug = fancyLinearMat end
		local fancyPpFixMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy29_facefix_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy33_facefix_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-2",
			["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001",
			["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0",
			["$c3_x"] = "0.6", ["$c3_y"] = "0.1", ["$c3_z"] = "0.65", ["$c3_w"] = "0.35",
		} )
		if fancyPpFixMat and not fancyPpFixMat:IsError() then
			fancyPpFixMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTextureFancyPpFix = fancyPpFixMat
		end
		-- Heightfield shadow variant ("mc_shadow_mode height"): same
		-- light pipeline and fancy grading, but sun shadows come from ray
		-- marching a cached top-down height map bound at $texture3 鈥?no
		-- per-frame shadow depth pass. Its shader reads $c0..$c3 only;
		-- $viewprojmat/$invviewprojmat must NEVER be defined or set on this
		-- material (the engine would upload c11..c18 over compiler-placed
		-- inline literal constants).
		local heightMat = CreateMaterial( "mc_atlas_gpu_lighttex_height7_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_height6_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "0",
			["$c0_y"] = "0.05",
			["$c0_z"] = "0",
			["$c0_w"] = "1",
			["$c1_x"] = "0",
			["$c1_y"] = "0",
			["$c1_z"] = "1",
			["$c1_w"] = "2400",
			["$c2_x"] = "0",
			["$c2_y"] = "0",
			["$c2_z"] = "0",
			["$c2_w"] = "0",
			["$c3_x"] = "0.6",
			["$c3_y"] = "0.1",
			["$c3_z"] = "0.65",
			["$c3_w"] = "0.35",
		} )
		if heightMat and not heightMat:IsError() then
			heightMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTextureHeight = heightMat
		end
		-- Fast low-sample variant ("mc_light_style fast"): the original
		-- cheap look 鈥?4 light-texture taps + atlas per pixel, analytic
		-- warm/cool tint, no shadow or global-lightmap sampling. Only two
		-- samplers, so it rides the stable non-8tex shader base. Its shader
		-- reads $c0 only (day-cycle sky brightness / ambient / night blue /
		-- tint strength, set once per frame); never define $c1..$c3 or
		-- $viewprojmat on this material.
		local fastMat = CreateMaterial( "mc_atlas_gpu_lighttex_fast7_centroid_vface_opaque", "screenspace_general", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fast6_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "1",
			["$c0_y"] = "0.04",
			["$c0_z"] = "0",
			["$c0_w"] = "0.7",
		} )
		if fastMat and not fastMat:IsError() then
			fastMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTextureFast = fastMat
		end
		-- Vanilla Minecraft variant ("mc_light_style vanilla"): one global
		-- lightmap lookup x directional face shade x vertex AO, the exact 26.2
		-- terrain composition. The whole day/night look lives in the 16x16
		-- lightmap texture (rebuilt per tick from the vanilla lightmap.fsh
		-- formula in cl_mesh_global_lightmap); there is NO shadow map. Its
		-- shader reads no constant registers at all, so this material must
		-- never define (or receive via SetFloat/SetMatrix) any $c*_,
		-- $viewprojmat, $invviewprojmat or $eyepos parameters 鈥?the engine
		-- would upload those registers over compiler-placed literal constants.
		local vanillaMat = CreateMaterial( "mc_atlas_gpu_lighttex_mcvanilla4_centroid_vface_opaque", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_mcvanilla4_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = baseName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$alphatested"] = 1,
			["$nocull"] = "0",
		} )
		if vanillaMat and not vanillaMat:IsError() then
			vanillaMat:SetTexture( "$basetexture", baseTex )
			MC.MaterialGpuLightTextureVanilla = vanillaMat
		end
		-- Translucent GPU variant: glass/water go through the same voxel light
		-- + shadow map pipeline as opaque chunks (they previously stayed on the
		-- CPU vertex-color material and never received shadows). Same register
		-- layout as the fancy shader ($c0..$c3), real alpha blending instead of
		-- alpha test. Drawn in the translucent pass with depth writes off.
		local transTex, transTexName = materialBaseTexture( MC.MaterialTranslucent )
		if not ( transTex and transTexName and transTexName ~= "" ) then
			transTex, transTexName = baseTex, baseName
		end
		-- Translucent Native compatibility path.  The vanilla translucent shader
		-- already decodes the same slot payload and preserves real texture alpha.
		-- Both lighting samplers stay white, so mc_light_texture=0 performs no
		-- per-chunk light lookup while retaining face shade and block tint.
		local nativeSlotTransMat = CreateMaterial( "mc_atlas_native_slot_payload1_centroid_vface_translucent", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_mcvanilla_trans4_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = transTexName,
			["$texture2"] = "vgui/white",
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphablend"] = 1,
			["$translucent"] = 1,
			["$nocull"] = "0",
		} )
		if nativeSlotTransMat and not nativeSlotTransMat:IsError() then
			nativeSlotTransMat:SetTexture( "$basetexture", transTex )
			MC.MaterialNativeSlotTranslucent = nativeSlotTransMat
		end
		local transGpuMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy_trans20_centroid_vface", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy_trans23_clean_pcf_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = transTexName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			-- screenspace_general blends via $alphablend ($translucent is only
			-- the material-system sort flag and does not enable blending here).
			["$alphablend"] = 1,
			["$translucent"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "0",
			["$c0_y"] = "0.0005",
			["$c0_z"] = "0",
			["$c0_w"] = "-2",
			["$c1_x"] = "0",
			["$c1_y"] = "0",
			["$c1_z"] = "-1",
			["$c1_w"] = "0.0001",
			["$c2_x"] = "0",
			["$c2_y"] = "0",
			["$c2_z"] = "0",
			["$c2_w"] = "0",
			["$c3_x"] = "0.6",
			["$c3_y"] = "0.1",
			["$c3_z"] = "0.65",
			["$c3_w"] = "0.35",
		} )
		if transGpuMat and not transGpuMat:IsError() then
			transGpuMat:SetTexture( "$basetexture", transTex )
			MC.MaterialGpuLightTextureTranslucent = transGpuMat
		end
		local transLinearMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy_trans19_linear_debug_centroid_vface", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy_trans21_linear_debug_vface_ps30", ["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30", ["$basetexture"] = transTexName,
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$linearwrite"] = 0, ["$alphablend"] = 1, ["$translucent"] = 1, ["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-4", ["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001", ["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0", ["$c3_x"] = "0.6", ["$c3_y"] = "0.1", ["$c3_z"] = "0", ["$c3_w"] = "0.35",
		} )
		if transLinearMat and not transLinearMat:IsError() then transLinearMat:SetTexture( "$basetexture", transTex ); MC.MaterialGpuLightTextureTranslucentLinearDebug = transLinearMat end
		local transPpFixMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy_trans21_facefix_centroid_vface", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy_trans24_facefix_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = transTexName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			["$alphablend"] = 1,
			["$translucent"] = 1,
			["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-2",
			["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001",
			["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0",
			["$c3_x"] = "0.6", ["$c3_y"] = "0.1", ["$c3_z"] = "0.65", ["$c3_w"] = "0.35",
		} )
		if transPpFixMat and not transPpFixMat:IsError() then
			transPpFixMat:SetTexture( "$basetexture", transTex )
			MC.MaterialGpuLightTextureTranslucentPpFix = transPpFixMat
		end
		-- Vanilla translucent variant: same register-free vanilla shader over
		-- the translucent atlas, real alpha blending. Selected instead of the
		-- fancy translucent material while mc_light_style is "vanilla" so
		-- glass/water follow the vanilla composition (no shadow sampling).
		local vanillaTransMat = CreateMaterial( "mc_atlas_gpu_lighttex_mcvanilla_trans4_centroid_vface", "screenspace_general_8tex", gpuLightMaterialParams {
			["$pixshader"] = "mc_gpu_chunk_lighttex_mcvanilla_trans4_vface_ps30",
			["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30",
			["$basetexture"] = transTexName,
			["$x360appchooser"] = 1,
			["$vertexcolor"] = 1,
			["$linearwrite"] = 0,
			-- screenspace_general blends via $alphablend ($translucent is only
			-- the material-system sort flag and does not enable blending here).
			["$alphablend"] = 1,
			["$translucent"] = 1,
			["$nocull"] = "0",
		} )
		if vanillaTransMat and not vanillaTransMat:IsError() then
			vanillaTransMat:SetTexture( "$basetexture", transTex )
			MC.MaterialGpuLightTextureVanillaTranslucent = vanillaTransMat
		end
	end
end

function MC.IsGpuLightTextureMaterial( material )
	if not material then return false end
	if material == MC.MaterialGpuLightTexture then return true end
	if material == MC.MaterialGpuLightTextureLinearDebug then return true end
	if MC.MaterialGpuLightTexturePpFix and material == MC.MaterialGpuLightTexturePpFix then return true end
	if MC.MaterialGpuLightTextureFancy and material == MC.MaterialGpuLightTextureFancy then return true end
	if material == MC.MaterialGpuLightTextureFancyLinearDebug then return true end
	if MC.MaterialGpuLightTextureFancyPpFix and material == MC.MaterialGpuLightTextureFancyPpFix then return true end
	if MC.MaterialGpuLightTextureHeight and material == MC.MaterialGpuLightTextureHeight then return true end
	if MC.MaterialGpuLightTextureFast and material == MC.MaterialGpuLightTextureFast then return true end
	if MC.MaterialGpuLightTextureVanilla and material == MC.MaterialGpuLightTextureVanilla then return true end
	if MC.MaterialGpuLightTextureVanillaTranslucent and material == MC.MaterialGpuLightTextureVanillaTranslucent then return true end
	if MC.MaterialGpuLightTextureTranslucent and material == MC.MaterialGpuLightTextureTranslucent then return true end
	if material == MC.MaterialGpuLightTextureTranslucentLinearDebug then return true end
	if MC.MaterialGpuLightTextureTranslucentPpFix and material == MC.MaterialGpuLightTextureTranslucentPpFix then return true end
	return false
end

-- Look/style predicate shared with the shadow map / heightfield passes:
-- while the vanilla material owns the look there is no shadow consumer, so
-- those passes skip their per-frame RT work entirely.
local function lightStyleName()
	if MC.LightStyleName then return MC.LightStyleName() end
	return "fancy"
end

local function vanillaLightActive()
	if lightStyleName() ~= "vanilla" then return false end
	return MC.MaterialGpuLightTextureVanilla ~= nil and not MC.MaterialGpuLightTextureVanilla:IsError()
end

local function shadowPpFixActive()
	local cv = MC.MeshShadowFaceFix
	return cv and cv.GetBool and cv:GetBool() == true
end

function MC.UsingVanillaLightMaterial()
	return vanillaLightActive()
end

local function activeGpuLightTextureMaterial()
	-- mc_light_style picks the look; the shadow-free looks (fast/vanilla)
	-- also bypass the height material since it exists only to render shadows.
	local style = lightStyleName()
	if MC.MeshShadowMapMode and MC.MeshShadowMapMode() == "linear" then
		if style == "fancy" and MC.MaterialGpuLightTextureFancyLinearDebug and not MC.MaterialGpuLightTextureFancyLinearDebug:IsError() then return MC.MaterialGpuLightTextureFancyLinearDebug end
		if MC.MaterialGpuLightTextureLinearDebug and not MC.MaterialGpuLightTextureLinearDebug:IsError() then return MC.MaterialGpuLightTextureLinearDebug end
	end
	if style == "fast"
		and MC.MaterialGpuLightTextureFast and not MC.MaterialGpuLightTextureFast:IsError() then
		return MC.MaterialGpuLightTextureFast
	end
	if vanillaLightActive() then
		return MC.MaterialGpuLightTextureVanilla
	end
	-- Height shadow mode owns its own shader/material pair; it only makes
	-- sense while the shadow system is enabled at all.
	local shadowCv = MC.MeshShadowMap
	if shadowCv and shadowCv.GetBool and shadowCv:GetBool()
		and MC.MeshShadowMapMode and MC.MeshShadowMapMode() == "height"
		and MC.MaterialGpuLightTextureHeight and not MC.MaterialGpuLightTextureHeight:IsError() then
		return MC.MaterialGpuLightTextureHeight
	end
	if style == "fancy"
		and shadowPpFixActive()
		and MC.MaterialGpuLightTextureFancyPpFix and not MC.MaterialGpuLightTextureFancyPpFix:IsError() then
		return MC.MaterialGpuLightTextureFancyPpFix
	end
	if style == "fancy"
		and MC.MaterialGpuLightTextureFancy and not MC.MaterialGpuLightTextureFancy:IsError() then
		return MC.MaterialGpuLightTextureFancy
	end
	if shadowPpFixActive()
		and MC.MaterialGpuLightTexturePpFix and not MC.MaterialGpuLightTexturePpFix:IsError() then
		return MC.MaterialGpuLightTexturePpFix
	end
	return MC.MaterialGpuLightTexture
end

local function gpuChunkShaderEnabled()
	local profile = RM.CurrentLightProfile and RM.CurrentLightProfile() or nil
	local usesGpuPayload = profile and profile.usesGpuPayload
	if type( usesGpuPayload ) == "function" then return usesGpuPayload( profile ) == true end
	return usesGpuPayload == true
end

function MC.UsingGpuChunkShader()
	return gpuChunkShaderEnabled() == true
end

local function shaderProfileUsesGpuLightTexture()
	local cv = MC.MeshGpuLightTexture
	if not ( cv and cv.GetBool and cv:GetBool() ) then return false end
	if not ( MC.MaterialGpuLightTexture and not MC.MaterialGpuLightTexture:IsError() ) then return false end
	if not ( MC.MeshGpuShader and MC.MeshGpuShader.GetBool and MC.MeshGpuShader:GetBool() ) then return false end
	return true
end

function MC.CurrentChunkMaterial( translucent )
	local profile = RM.CurrentLightProfile and RM.CurrentLightProfile() or nil
	local chunkMaterial = profile and profile.chunkMaterial
	if chunkMaterial then
		local material = chunkMaterial( translucent, profile )
		if material then return material end
	end
	if translucent then return MC.MaterialTranslucent or MC.Material end
	return MC.Material
end

local function shaderProfileUsesGpuPayload()
	local cv = MC.MeshGpuShader
	if not ( cv and cv.GetBool and cv:GetBool() ) then return false end
	if shaderProfileUsesGpuLightTexture() then return true end
	if not ( MC.MaterialGpuOpaque and not MC.MaterialGpuOpaque:IsError() ) then return false end
	return true
end

local function gpuTranslucentMaterial()
	if not shaderProfileUsesGpuLightTexture() then return nil end
	-- Vanilla mode carries its own translucent variant so glass/water keep
	-- the register-free vanilla composition instead of the shadowed fancy one.
	if vanillaLightActive() then
		local vanillaTrans = MC.MaterialGpuLightTextureVanillaTranslucent
		if vanillaTrans and not vanillaTrans:IsError() then return vanillaTrans end
	end
	local mat = MC.MaterialGpuLightTextureTranslucent
	if MC.MeshShadowMapMode and MC.MeshShadowMapMode() == "linear" then
		local linear = MC.MaterialGpuLightTextureTranslucentLinearDebug
		if linear and not linear:IsError() then return linear end
	end
	if shadowPpFixActive() then
		local ppFixMat = MC.MaterialGpuLightTextureTranslucentPpFix
		if ppFixMat and not ppFixMat:IsError() then return ppFixMat end
	end
	if mat and not mat:IsError() then return mat end
	return nil
end

-- Native meshes use a different immutable vertex payload from Lua meshes.
-- Resolve their draw/handshake material separately so disabling the light
-- texture never feeds slot bytes into the legacy Lua GPU-payload shader.
function MC.NativeChunkMaterial( translucent )
	if shaderProfileUsesGpuLightTexture() then
		return translucent and gpuTranslucentMaterial() or activeGpuLightTextureMaterial()
	end
	if not shaderProfileUsesGpuPayload() then return nil end
	local material = translucent and MC.MaterialNativeSlotTranslucent or MC.MaterialNativeSlotOpaque
	if material and not material:IsError() then return material end
	return nil
end

local function shaderProfileChunkMaterial( translucent )
	if translucent then
		return gpuTranslucentMaterial() or MC.MaterialTranslucent or MC.Material
	end
	if shaderProfileUsesGpuLightTexture() then return activeGpuLightTextureMaterial() end
	if shaderProfileUsesGpuPayload() then return MC.MaterialGpuOpaque end
	return MC.Material
end

local function shaderProfileGpuPayloadMaterial()
	if shaderProfileUsesGpuLightTexture() then return activeGpuLightTextureMaterial() end
	return MC.MaterialGpuOpaque
end

local function shaderProfileGpuPayloadStyle()
	if shaderProfileUsesGpuLightTexture() then return MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE end
	return MC_LIGHT_STYLE_GPU_SHADER
end

-- Recolor/emit style resolution: the translucent GPU materials carry the
-- same vertex payload (face index + AO) as the opaque GPU materials.
local function shaderProfileEffectiveStyleForMaterial( material, style )
	if material ~= nil and shaderProfileUsesGpuLightTexture()
		and ( material == MC.MaterialGpuLightTextureTranslucent
			or material == MC.MaterialGpuLightTextureTranslucentPpFix
			or material == MC.MaterialGpuLightTextureVanillaTranslucent ) then
		return shaderProfileGpuPayloadStyle()
	end
	return style
end

if RM.RegisterLightProfile then
	RM.RegisterLightProfile( MC_LIGHT_STYLE_SHADER, {
		chunkMaterial = shaderProfileChunkMaterial,
		usesGpuPayload = shaderProfileUsesGpuPayload,
		gpuPayloadMaterial = shaderProfileGpuPayloadMaterial,
		gpuPayloadMaterialTranslucent = gpuTranslucentMaterial,
		gpuPayloadStyle = shaderProfileGpuPayloadStyle,
		effectiveStyleForMaterial = shaderProfileEffectiveStyleForMaterial,
	} )
	RM.RegisterLightProfile( MC_LIGHT_STYLE_GPU_SHADER, {
		chunkMaterial = shaderProfileChunkMaterial,
		usesGpuPayload = true,
		gpuPayloadMaterial = shaderProfileGpuPayloadMaterial,
		gpuPayloadMaterialTranslucent = gpuTranslucentMaterial,
		gpuPayloadStyle = shaderProfileGpuPayloadStyle,
		effectiveStyleForMaterial = shaderProfileEffectiveStyleForMaterial,
	} )
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_light_shader", function()
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "gpu_shader_toggle" ) end
	end, "mc_light_shader_rebuild" )
	cvars.AddChangeCallback( "mc_shadow_facefix", function()
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "shadow_ppfix_toggle" ) end
	end, "mc_shadow_facefix_rebuild" )
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
	value = string.lower( tostring( value or "default" ) )
	if value == "programmer_art" then return "programmer_art" end
	return "default"
end

local function resolveAtlasSource( name )
	local source = AtlasSources[name]
	if not source then return nil end
	if name == "programmer_art" then
		if not source.opaque or source.opaque:IsError() then
			source.opaque = loadAtlasSource( source.opaquePath )
		end
		if not source.icon or source.icon:IsError() then
			source.icon = loadAtlasIconSource( source.iconPath )
		end
		source.opaqueTexture = atlasMaterialTexture( source.opaque ) or source.opaqueTexture
		source.translucent = source.opaque
		source.translucentTexture = source.opaqueTexture
		source.iconTexture = atlasMaterialTexture( source.icon ) or source.iconTexture or source.opaqueTexture
	end
	return source
end

local function refreshGpuAtlasTextures( opaqueTexture, translucentTexture )
	local opaqueMaterialNames = {
		"MaterialGpuOpaque",
		"MaterialNativeSlotOpaque",
		"MaterialGpuLightTexture",
		"MaterialGpuLightTextureLinearDebug",
		"MaterialGpuLightTexturePpFix",
		"MaterialGpuLightTextureFancy",
		"MaterialGpuLightTextureFancyLinearDebug",
		"MaterialGpuLightTextureFancyPpFix",
		"MaterialGpuLightTextureHeight",
		"MaterialGpuLightTextureFast",
		"MaterialGpuLightTextureVanilla",
	}
	for _, name in ipairs( opaqueMaterialNames ) do setAtlasTexture( MC[name], opaqueTexture ) end

	local translucentMaterialNames = {
		"MaterialNativeSlotTranslucent",
		"MaterialGpuLightTextureVanillaTranslucent",
		"MaterialGpuLightTextureTranslucent",
		"MaterialGpuLightTextureTranslucentLinearDebug",
		"MaterialGpuLightTextureTranslucentPpFix",
	}
	for _, name in ipairs( translucentMaterialNames ) do setAtlasTexture( MC[name], translucentTexture ) end
end

function MC.TexturePackName()
	return MC.ActiveTexturePack or "default"
end

function MC.SetTexturePack( value )
	local requested = string.lower( tostring( value or "default" ) )
	local name = normalizeTexturePack( requested )
	local source = resolveAtlasSource( name ) or AtlasSources.default
	local opaqueTexture = source and source.opaqueTexture
	local translucentTexture = source and source.translucentTexture or opaqueTexture
	local iconTexture = source and source.iconTexture or opaqueTexture
	if not validAtlasTexture( opaqueTexture ) then
		return false, "missing_atlas_" .. name
	end
	if not validAtlasTexture( translucentTexture ) then translucentTexture = opaqueTexture end
	if not validAtlasTexture( iconTexture ) then iconTexture = opaqueTexture end

	-- MC.Material/MC.MaterialTranslucent are stable proxy objects referenced by
	-- existing mesh records. Updating their texture is enough to switch CPU
	-- meshes, icon panels and translucent draws without a full world rebuild.
	setAtlasTexture( MC.Material, opaqueTexture )
	setAtlasTexture( MC.MaterialTranslucent, translucentTexture )
	setAtlasTexture( MC.MaterialIconOpaque, opaqueTexture )
	setAtlasTexture( MC.MaterialCreativeIcon, iconTexture )
	setAtlasTexture( MC.MaterialCreativeIconOpaque, iconTexture )
	refreshGpuAtlasTextures( opaqueTexture, translucentTexture )
	if MC.RefreshShadowDepthAtlas then MC.RefreshShadowDepthAtlas( opaqueTexture ) end
	if MC.RefreshHeightfieldDepthAtlas then MC.RefreshHeightfieldDepthAtlas( opaqueTexture ) end

	MC.ActiveTexturePack = name
	MC.Atlas.ACTIVE_MATERIAL = name == "programmer_art"
		and ( MC.Atlas.MATERIAL_PROGRAMMER_ART or "mc/atlas_365_programmer_art" )
		or ( MC.Atlas.MATERIAL or "mc/atlas_365" )
	MC.Atlas.ACTIVE_MATERIAL_TRANSLUCENT = name == "programmer_art"
		and ( MC.Atlas.MATERIAL_PROGRAMMER_ART_TRANSLUCENT or "mc/atlas_365_programmer_art_translucent" )
		or ( MC.Atlas.MATERIAL_TRANSLUCENT or "mc/atlas_365_translucent" )

	if MC.RefreshBlockParticleMaterials then MC.RefreshBlockParticleMaterials( opaqueTexture ) end
	return true, name, requested == name
end

local TEXTURE_PACK_SYNC_TIMER = "mc_texture_pack_startup_sync"
local TEXTURE_PACK_INIT_HOOK = "mc_texture_pack_init_sync"
local TEXTURE_PACK_SYNC_INTERVAL = 0.25
local TEXTURE_PACK_SYNC_ATTEMPTS = 20

local function syncTexturePackFromConVar( force )
	if not ( MC.TexturePack and MC.TexturePack.GetString ) then return false end
	local configured = MC.TexturePack:GetString()
	if not force and MC.ActiveTexturePack == normalizeTexturePack( configured ) then return true end
	return MC.SetTexturePack( configured )
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
		local ok, active, alreadyNormalized = MC.SetTexturePack( value )
		if MC.RefreshConfigControlValue then MC.RefreshConfigControlValue( "mc_texture_pack", value ) end
		if not ok then
			MsgN( "[MC] texture pack unavailable: " .. tostring( value ) )
		elseif not alreadyNormalized and RunConsoleCommand then
			RunConsoleCommand( "mc_texture_pack", active )
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

-- This file owns the GPU material objects and may be re-run independently by
-- Lua autorefresh. Rebind the atlas immediately so already-live Lua or Native
-- meshes never render replacement materials with an empty $texture1.
if MC.EnsureGpuChunkLightTextureBinding
and MC.UsingGpuLightTexture and MC.UsingGpuLightTexture() then
	MC.EnsureGpuChunkLightTextureBinding()
end
