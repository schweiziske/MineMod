-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh

MC.MeshEmitProbe = MC.MeshEmitProbe or ( CreateClientConVar and CreateClientConVar( "mc_mesh_emit_probe", "0", true, false,
	"Print detailed MC mesh emit timings for diagnosing full geometry rebuild hot paths" ) )
MC.MeshBeginUpload = MC.MeshBeginUpload or ( CreateClientConVar and CreateClientConVar( "mc_mesh_begin_upload", "1", true, false,
	"Upload MC IMesh vertices with mesh.Begin instead of IMesh:BuildFromTriangles" ) )
MC.MeshDebugFullCubeOnly = MC.MeshDebugFullCubeOnly or ( CreateClientConVar and CreateClientConVar( "mc_mesh_debug_full_cube_only", "0", true, false,
	"Debug MC mesh emission by rendering only full cube blocks" ) )
-- Lighting convars use three function families (renamed 2026-07-09 from the
-- old mc_mesh_gpu_*/mc_mesh_shadow_* names; FCVAR_ARCHIVE keeps old saved
-- values alive, so renaming is this project's way of shipping new defaults):
--   mc_light_*    lighting pipeline + look selection + light levels
--   mc_lightmap_* the procedural 16x16 global lightmap texture
--   mc_shadow_*   the sun shadow system (shadow map + heightfield mode)
MC.MeshGpuShader = MC.MeshGpuShader or ( CreateClientConVar and CreateClientConVar( "mc_light_shader", "1", true, false,
	"Use the custom GPU shader for MC chunk atlas meshes when the compiled VCS files are available" ) )
MC.MeshGpuLightTexture = MC.MeshGpuLightTexture or ( CreateClientConVar and CreateClientConVar( "mc_light_texture", "1", true, false,
	"Sample chunk light textures in the GPU shader instead of baking chunk light into vertex colors" ) )
MC.MeshShadowMap = MC.MeshShadowMap or ( CreateClientConVar and CreateClientConVar( "mc_shadow", "1", true, false,
	"Let the GPU chunk shader receive the MC-owned sun shadow map" ) )
MC.MeshShadowMapStrength = MC.MeshShadowMapStrength or ( CreateClientConVar and CreateClientConVar( "mc_shadow_strength", "0.75", true, false,
	"Shadow multiplier strength for the MC chunk shader" ) )
MC.MeshShadowMapBias = MC.MeshShadowMapBias or ( CreateClientConVar and CreateClientConVar( "mc_shadow_bias", "0.0005", true, false,
	"Shadow map depth/edge bias for MC chunk shader sampling" ) )
MC.MeshShadowMapSoftness = MC.MeshShadowMapSoftness or ( CreateClientConVar and CreateClientConVar( "mc_shadow_softness", "1", true, false,
	"Shadow edge softness in shadow-map texels (clamped to at least 1 texel; the shadow bias scales with it)" ) )
-- One look selector instead of the old three mutually exclusive booleans
-- (mc_mesh_gpu_shader_fancy / _light_fast / _light_vanilla). Legacy archived
-- values from the pre-rename mc_light_style profile convar ("shader", "best",
-- numbers) normalize to fancy.
MC.LightStyle = MC.LightStyle or ( CreateClientConVar and CreateClientConVar( "mc_light_style", "fancy", true, false,
	"MC chunk lighting look: fancy = PCF shadows + cool/warm grading (default), plain = smooth lighting without grading, fast = low-sample legacy look, vanilla = 1:1 Minecraft lightmap composition (no shadows)" ) )
MC.MeshShadowMapTint = MC.MeshShadowMapTint or ( CreateClientConVar and CreateClientConVar( "mc_shadow_tint", "0.6", true, false,
	"Fancy look: how strongly shadows shift toward a cool sky tint (0 = plain darkening)" ) )
MC.MeshShadowMapEdgeFade = MC.MeshShadowMapEdgeFade or ( CreateClientConVar and CreateClientConVar( "mc_shadow_edge_fade", "0.1", true, false,
	"Fancy look: fade band width at the shadow coverage border in UV units (0 = hard cutoff)" ) )
MC.MeshShadowMapFaceShade = MC.MeshShadowMapFaceShade or ( CreateClientConVar and CreateClientConVar( "mc_shadow_face_shade", "0.65", true, false,
	"Fancy look: how strongly faces pointing away from the sun are shaded like cast shadow" ) )
MC.MeshShadowMapWarmth = MC.MeshShadowMapWarmth or ( CreateClientConVar and CreateClientConVar( "mc_shadow_warmth", "0.35", true, false,
	"Fancy look: warm tint on sunlit faces and torch-lit areas (0 = neutral)" ) )
MC.MeshBloom = MC.MeshBloom or ( CreateClientConVar and CreateClientConVar( "mc_light_bloom", "1", true, false,
	"Fancy GPU look: spread bright torch and sun highlight seeds with a screen-space bloom pass" ) )
MC.MeshBloomStrength = MC.MeshBloomStrength or ( CreateClientConVar and CreateClientConVar( "mc_light_bloom_strength", "0.8", true, false,
	"Fancy GPU bloom intensity (night automatically receives a small boost)" ) )
MC.MeshBloomThreshold = MC.MeshBloomThreshold or ( CreateClientConVar and CreateClientConVar( "mc_light_bloom_threshold", "0.7", true, false,
	"Fancy GPU bloom brightness threshold; higher values restrict bloom to hotter pixels" ) )
MC.MeshBloomRadius = MC.MeshBloomRadius or ( CreateClientConVar and CreateClientConVar( "mc_light_bloom_radius", "6", true, false,
	"Fancy GPU bloom blur radius in screen pixels" ) )
MC.MeshGpuLightBrightness = MC.MeshGpuLightBrightness or ( CreateClientConVar and CreateClientConVar( "mc_light_brightness", "1.5", true, false,
	"Brightness multiplier applied to block/sky light levels (1 = unchanged)" ) )
MC.MeshGpuLightGamma = MC.MeshGpuLightGamma or ( CreateClientConVar and CreateClientConVar( "mc_light_gamma", "1", true, false,
	"Light falloff curve; >1 brightens mid levels (torch edges), <1 darkens them (1 = linear)" ) )
MC.MeshGpuSunBrightness = MC.MeshGpuSunBrightness or ( CreateClientConVar and CreateClientConVar( "mc_light_sun_brightness", "1", true, false,
	"Sun/sky light brightness multiplier (1 = unchanged)" ) )
MC.DayCycleSunTilt = MC.DayCycleSunTilt or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_sun_tilt", "0.2", true, false,
	"Day cycle: sideways tilt of the sun path used by the shadow map (avoids axis-aligned shadows)" ) )
MC.DayCycleMoonShadow = MC.DayCycleMoonShadow or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_moon_shadow", "0.3", true, false,
	"Day cycle: moon shadow strength at night relative to sun shadows (0 = no night shadows)" ) )
MC.DayCycleMoonLight = MC.DayCycleMoonLight or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_moon_light", "3", true, false,
	"Day cycle: moonlight sky level at deep night, 0-15 (MC default 4; lower = darker nights)" ) )
MC.DayCycleNightTint = MC.DayCycleNightTint or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_night_tint", "0.85", true, false,
	"Day cycle: how strongly sky-lit surfaces shift toward moonlight blue at night (0 = neutral)" ) )
MC.MeshGpuLightRefreshPerFrame = MC.MeshGpuLightRefreshPerFrame or ( CreateClientConVar and CreateClientConVar( "mc_light_refresh_per_frame", "2", true, false,
	"GPU light texture: chunks re-rendered per frame during day/night level steps (higher = faster but choppier)" ) )
MC.MeshGpuLightFlushPerFrame = MC.MeshGpuLightFlushPerFrame or ( CreateClientConVar and CreateClientConVar( "mc_light_flush_per_frame", "8", true, false,
	"GPU light texture: max chunk textures baked per frame in the PreRender flush (draw path never bakes; 0 = unlimited)" ) )
MC.MeshGpuLightmap = MC.MeshGpuLightmap or ( CreateClientConVar and CreateClientConVar( "mc_lightmap", "1", true, false,
	"Procedural 16x16 global lightmap: warm torch light, colored day/night sky axis (0 = grayscale fallback)" ) )
MC.MeshGpuLightmapTorchWarmth = MC.MeshGpuLightmapTorchWarmth or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_torch_warmth", "0.7", true, false,
	"Global lightmap: warm tint of block light (0 = neutral white torches)" ) )
MC.MeshGpuLightmapAmbient = MC.MeshGpuLightmapAmbient or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_ambient", "0.18", true, false,
	"Global lightmap: minimum visible brightness in fully dark areas" ) )
MC.MeshGpuLightmapSunset = MC.MeshGpuLightmapSunset or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_sunset", "0.5", true, false,
	"Global lightmap: sunset/sunrise orange grading strength on the sky axis (0 = off)" ) )
MC.MeshGpuLightmapNightGamma = MC.MeshGpuLightmapNightGamma or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_night_gamma", "0.6", true, false,
	"Global lightmap: perceptual curve on day/night sky brightness (1 = linear; lower = brighter, bluer nights and gentler dusk)" ) )
MC.MeshGpuLightmapSkyCurve = MC.MeshGpuLightmapSkyCurve or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_sky_curve", "3", true, false,
	"Global lightmap: sky ambient falloff shape 1-(1-level)^curve; higher keeps shaded-but-open areas bright and only true enclosure dark (1 = linear)" ) )
MC.MeshGpuLightmapSkyMin = MC.MeshGpuLightmapSkyMin or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_sky_min", "0.18", true, false,
	"Global lightmap: minimum sky-AMBIENT fraction at sky level 0 (interior/under-structure ambient floor; direct sun is independent of this)" ) )
MC.MeshGpuLightmapEyeDark = MC.MeshGpuLightmapEyeDark or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_eye_dark", "1", true, false,
	"Global lightmap: sky-ambient multiplier when the CAMERA cell has no sky light (eyeBrightness cave darkening; 1 = off — it also darkens standing under large structures)" ) )
MC.MeshGpuLightmapVanillaGamma = MC.MeshGpuLightmapVanillaGamma or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_vanilla_gamma", "0.5", true, false,
	"Vanilla look: Minecraft brightness slider 0-1 (options.gamma; 0 = Moody, 0.5 = vanilla default, 1 = Bright)" ) )
MC.MeshGpuLightmapVanillaFlicker = MC.MeshGpuLightmapVanillaFlicker or ( CreateClientConVar and CreateClientConVar( "mc_lightmap_vanilla_flicker", "1", true, false,
	"Vanilla look: per-tick torch light flicker (LightmapRenderStateExtractor's random walk); 0 = steady block light" ) )
MC.MeshShadowMapSize = MC.MeshShadowMapSize or ( CreateClientConVar and CreateClientConVar( "mc_shadow_size", "4096", true, false,
	"MC-owned shadow map cascade tile resolution, 512-4096 (atlas is size x 3*size; 4096 costs ~240MB VRAM and needs a modern GPU)" ) )
MC.MeshShadowMapDistance = MC.MeshShadowMapDistance or ( CreateClientConVar and CreateClientConVar( "mc_shadow_distance", "10000", true, false,
	"MC-owned shadow map world-space coverage radius (the far cascade; inner cascades divide it by the cascade ratio)" ) )
MC.MeshShadowCascadeRatio = MC.MeshShadowCascadeRatio or ( CreateClientConVar and CreateClientConVar( "mc_shadow_cascade_ratio", "3", true, false,
	"Cascaded shadow map radius ratio between tiles: near = distance/ratio^2, mid = distance/ratio (higher = sharper near shadows, coarser mid range)" ) )
MC.MeshShadowMapCasterDistance = MC.MeshShadowMapCasterDistance or ( CreateClientConVar and CreateClientConVar( "mc_shadow_caster_distance", "10000", true, false,
	"Max distance from camera for MC chunks drawn into the shadow map" ) )
MC.MeshShadowMapUpdateInterval = MC.MeshShadowMapUpdateInterval or ( CreateClientConVar and CreateClientConVar( "mc_shadow_update_interval", "0", true, false,
	"Minimum seconds between MC shadow map redraws; 0 redraws every frame while enabled" ) )
MC.MeshShadowMapSunStep = MC.MeshShadowMapSunStep or ( CreateClientConVar and CreateClientConVar( "mc_shadow_sun_step", "1", true, false,
	"Day cycle: shadow sun angle quantization step in degrees; the shadow grid holds still between steps so edges stop shimmering (0 = continuous sun)" ) )
MC.MeshShadowMode = MC.MeshShadowMode or ( CreateClientConVar and CreateClientConVar( "mc_shadow_mode", "map", true, false,
	"MC sun shadow technique: map = Photon-style distorted shadow map (sharp near, continuous falloff), csm = 3-cascade atlas, height = cached top-down heightfield ray march" ) )
MC.MeshHfShadowSize = MC.MeshHfShadowSize or ( CreateClientConVar and CreateClientConVar( "mc_shadow_hf_size", "1024", true, false,
	"Heightfield shadow mode: top-down height map resolution" ) )
MC.MeshHfShadowRange = MC.MeshHfShadowRange or ( CreateClientConVar and CreateClientConVar( "mc_shadow_hf_range", "4096", true, false,
	"Heightfield shadow mode: world-space coverage radius around the player" ) )
MC.MeshHfShadowMaxDist = MC.MeshHfShadowMaxDist or ( CreateClientConVar and CreateClientConVar( "mc_shadow_hf_max_dist", "2400", true, false,
	"Heightfield shadow mode: max world distance a caster can throw shadow (ray march reach)" ) )
MC.MeshHfShadowSoftness = MC.MeshHfShadowSoftness or ( CreateClientConVar and CreateClientConVar( "mc_shadow_hf_softness", "0.05", true, false,
	"Heightfield shadow mode: penumbra tangent; shadows widen by this per unit of blocker distance (0.02 = crisp, 0.12 = very soft)" ) )
MC.MeshHfShadowUpdateInterval = MC.MeshHfShadowUpdateInterval or ( CreateClientConVar and CreateClientConVar( "mc_shadow_hf_update_interval", "0.1", true, false,
	"Heightfield shadow mode: minimum seconds between height map redraws when meshes changed or the window recentered" ) )
MC.MeshConnectionVisibleTemplate = MC.MeshConnectionVisibleTemplate or ( CreateClientConVar and CreateClientConVar( "mc_mesh_connection_visible_template", "1", true, false,
	"Experimental: use cached visible geometry templates for fence/pane/wall/pipe connection shapes" ) )

local MC_LIGHT_STYLE_FAST = "fast"
local MC_LIGHT_STYLE_VANILLA = "vanilla"
local MC_LIGHT_STYLE_BEST = "best"
local MC_LIGHT_STYLE_SHADER = "shader"
local MC_LIGHT_STYLE_GPU_SHADER = "gpu_shader"
local MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE = "gpu_light_texture"

local mathClamp, mathFloor = math.Clamp, math.floor
local stringLower = string.lower

local LightProfiles = RM.LightProfiles or {}
RM.LightProfiles = LightProfiles

local function registerLightProfile( id, profile )
	if not id then return nil end
	local existing = LightProfiles[id] or {}
	if profile then
		for k, v in pairs( profile ) do
			existing[k] = v
		end
	end
	existing.id = existing.id or id
	existing.style = existing.style or id
	existing.fallbackStyle = existing.fallbackStyle or id
	LightProfiles[id] = existing
	return existing
end

function RM.RegisterLightProfile( id, profile )
	return registerLightProfile( id, profile )
end

function RM.GetLightProfile( style )
	style = style or MC_LIGHT_STYLE_SHADER
	local profile = LightProfiles[style]
	if profile then return profile end
	return LightProfiles[MC_LIGHT_STYLE_SHADER] or LightProfiles[MC_LIGHT_STYLE_VANILLA]
end

local function normalizeLightStyle( style )
	style = stringLower( tostring( style or "" ) )
	if style == MC_LIGHT_STYLE_FAST or style == "low" or style == "0" then return MC_LIGHT_STYLE_FAST end
	if style == MC_LIGHT_STYLE_VANILLA or style == "default" or style == "normal" or style == "1" then return MC_LIGHT_STYLE_VANILLA end
	if style == MC_LIGHT_STYLE_BEST or style == "fancy" or style == "high" or style == "2" then return MC_LIGHT_STYLE_BEST end
	if style == MC_LIGHT_STYLE_SHADER or style == "shaders" or style == "cinematic" or style == "3" then return MC_LIGHT_STYLE_SHADER end
	if LightProfiles[style] then return style end
	return MC_LIGHT_STYLE_SHADER
end

local function currentLightStyle()
	local cv = MC.LightProfile
	local style = normalizeLightStyle( cv and cv.GetString and cv:GetString() or MC_LIGHT_STYLE_SHADER )
	return style
end

-- GPU look selector (mc_light_style): which chunk pixel shader family draws
-- the world. Distinct from the legacy mc_light_profile pipeline selector
-- above. Unknown values — including archived leftovers from when this NAME
-- held the profile selector ("shader", "best", numbers) — fall back to fancy.
function MC.LightStyleName()
	local cv = MC.LightStyle
	local style = cv and cv.GetString and stringLower( tostring( cv:GetString() or "" ) ) or "fancy"
	if style == "plain" or style == "fast" or style == "vanilla" then return style end
	return "fancy"
end

function RM.CurrentLightProfile()
	return RM.GetLightProfile( currentLightStyle() )
end

local function effectiveLightStyleForMaterial( style, material, profile )
	profile = profile or RM.GetLightProfile( style )
	local payloadMaterial = profile and profile.gpuPayloadMaterial
	if type( payloadMaterial ) == "function" then payloadMaterial = payloadMaterial() end
	local payloadStyle = profile and profile.gpuPayloadStyle
	if type( payloadStyle ) == "function" then payloadStyle = payloadStyle( profile, material ) end
	if payloadStyle and payloadMaterial and material == payloadMaterial then return payloadStyle end
	local fn = profile and profile.effectiveStyleForMaterial
	if fn then return fn( material, style, profile ) end
	return style
end

local function meshDebugFullCubeOnly()
	local cv = MC.MeshDebugFullCubeOnly
	return cv and cv.GetBool and cv:GetBool() or false
end

MC.CurrentMeshLightStyle = currentLightStyle
MC.RegisterLightProfile = RM.RegisterLightProfile
MC.GetLightProfile = RM.GetLightProfile
MC.CurrentLightProfile = RM.CurrentLightProfile

local function clampLightLevel( level )
	return mathClamp( mathFloor( tonumber( level ) or 0 ), 0, 15 )
end

registerLightProfile( MC_LIGHT_STYLE_FAST, {
	name = "Fast",
	usesGpuPayload = false,
} )
registerLightProfile( MC_LIGHT_STYLE_VANILLA, {
	name = "Vanilla",
	usesGpuPayload = false,
} )
registerLightProfile( MC_LIGHT_STYLE_BEST, {
	name = "Best",
	usesGpuPayload = false,
} )
registerLightProfile( MC_LIGHT_STYLE_SHADER, {
	name = "Shader",
	usesGpuPayload = false,
} )
registerLightProfile( MC_LIGHT_STYLE_GPU_SHADER, {
	name = "GPU Shader Payload",
	fallbackStyle = MC_LIGHT_STYLE_SHADER,
	usesGpuPayload = true,
} )
registerLightProfile( MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE, {
	name = "GPU Light Texture",
	fallbackStyle = MC_LIGHT_STYLE_SHADER,
	usesGpuPayload = true,
	usesGpuLightTexture = true,
} )

RM.MC_LIGHT_STYLE_FAST = MC_LIGHT_STYLE_FAST
RM.MC_LIGHT_STYLE_VANILLA = MC_LIGHT_STYLE_VANILLA
RM.MC_LIGHT_STYLE_BEST = MC_LIGHT_STYLE_BEST
RM.MC_LIGHT_STYLE_SHADER = MC_LIGHT_STYLE_SHADER
RM.MC_LIGHT_STYLE_GPU_SHADER = MC_LIGHT_STYLE_GPU_SHADER
RM.MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE = MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE
RM.currentLightStyle = currentLightStyle
RM.normalizeLightStyle = normalizeLightStyle
RM.effectiveLightStyleForMaterial = effectiveLightStyleForMaterial
RM.meshDebugFullCubeOnly = meshDebugFullCubeOnly
RM.clampLightLevel = clampLightLevel
