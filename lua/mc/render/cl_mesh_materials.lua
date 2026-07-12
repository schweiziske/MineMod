-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh
local MC_LIGHT_STYLE_SHADER = RM.MC_LIGHT_STYLE_SHADER
local MC_LIGHT_STYLE_GPU_SHADER = RM.MC_LIGHT_STYLE_GPU_SHADER
local MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE = RM.MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE

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
		local lightTexMat = CreateMaterial( "mc_atlas_gpu_lighttex41_centroid_vface_opaque", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_vanilla_smooth34_clean_pcf_vface_ps30",
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
		local linearMat = CreateMaterial( "mc_atlas_gpu_lighttex43_linear_debug_centroid_vface_opaque", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_vanilla_smooth33_linear_debug_vface_ps30", ["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30", ["$basetexture"] = baseName,
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$linearwrite"] = 0, ["$alphatest"] = "1", ["$alphatestreference"] = "0.5", ["$alphatested"] = 1, ["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-4", ["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001", ["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0",
		} )
		if linearMat and not linearMat:IsError() then linearMat:SetTexture( "$basetexture", baseTex ); MC.MaterialGpuLightTextureLinearDebug = linearMat end
		local lightTexPpFixMat = CreateMaterial( "mc_atlas_gpu_lighttex42_ppfix_centroid_vface_opaque", "screenspace_general_8tex", {
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
		local fancyMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy23_centroid_vface_opaque", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy31_clean_pcf_vface_ps30",
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
		local fancyLinearMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy27_linear_debug_centroid_vface_opaque", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy30_linear_debug_vface_ps30", ["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30", ["$basetexture"] = baseName,
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$linearwrite"] = 0, ["$alphatest"] = "1", ["$alphatestreference"] = "0.5", ["$alphatested"] = 1, ["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-4", ["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001", ["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0", ["$c3_x"] = "0.6", ["$c3_y"] = "0.1", ["$c3_z"] = "0", ["$c3_w"] = "0.35",
		} )
		if fancyLinearMat and not fancyLinearMat:IsError() then fancyLinearMat:SetTexture( "$basetexture", baseTex ); MC.MaterialGpuLightTextureFancyLinearDebug = fancyLinearMat end
		local fancyPpFixMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy26_facefix_centroid_vface_opaque", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy29_facefix_vface_ps30",
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
		local heightMat = CreateMaterial( "mc_atlas_gpu_lighttex_height7_centroid_vface_opaque", "screenspace_general_8tex", {
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
		local fastMat = CreateMaterial( "mc_atlas_gpu_lighttex_fast7_centroid_vface_opaque", "screenspace_general", {
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
		local vanillaMat = CreateMaterial( "mc_atlas_gpu_lighttex_mcvanilla4_centroid_vface_opaque", "screenspace_general_8tex", {
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
		local transGpuMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy_trans15_centroid_vface", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy_trans22_clean_pcf_vface_ps30",
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
		local transLinearMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy_trans19_linear_debug_centroid_vface", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy_trans21_linear_debug_vface_ps30", ["$vertexshader"] = "mc_gpu_chunk_lighttex_vs30", ["$basetexture"] = transTexName,
			["$x360appchooser"] = 1, ["$vertexcolor"] = 1, ["$linearwrite"] = 0, ["$alphablend"] = 1, ["$translucent"] = 1, ["$nocull"] = "0",
			["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "0", ["$c0_w"] = "-4", ["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "-1", ["$c1_w"] = "0.0001", ["$c2_x"] = "0", ["$c2_y"] = "0", ["$c2_z"] = "0", ["$c2_w"] = "0", ["$c3_x"] = "0.6", ["$c3_y"] = "0.1", ["$c3_z"] = "0", ["$c3_w"] = "0.35",
		} )
		if transLinearMat and not transLinearMat:IsError() then transLinearMat:SetTexture( "$basetexture", transTex ); MC.MaterialGpuLightTextureTranslucentLinearDebug = transLinearMat end
		local transPpFixMat = CreateMaterial( "mc_atlas_gpu_lighttex_fancy_trans18_facefix_centroid_vface", "screenspace_general_8tex", {
			["$pixshader"] = "mc_gpu_chunk_lighttex_fancy_trans20_facefix_vface_ps30",
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
		local vanillaTransMat = CreateMaterial( "mc_atlas_gpu_lighttex_mcvanilla_trans4_centroid_vface", "screenspace_general_8tex", {
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
