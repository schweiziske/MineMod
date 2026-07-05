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
MC.MeshGpuShader = MC.MeshGpuShader or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_shader", "1", true, false,
	"Use the experimental custom GPU shader for opaque MC chunk atlas meshes when the compiled VCS files are available" ) )
MC.MeshGpuLightTexture = MC.MeshGpuLightTexture or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_texture", "1", true, false,
	"Experimental: sample chunk light textures in the GPU shader instead of baking opaque chunk light into vertex colors" ) )
MC.MeshShadowMap = MC.MeshShadowMap or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map", "1", true, false,
	"Experimental: let GPU light texture chunk shader receive an MC-owned shadow map" ) )
MC.MeshShadowMapStrength = MC.MeshShadowMapStrength or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_strength", "0.75", true, false,
	"Experimental shadow multiplier strength for MC chunk shader" ) )
MC.MeshShadowMapBias = MC.MeshShadowMapBias or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_bias", "0.0005", true, false,
	"Experimental shadow map depth/edge bias for MC chunk shader sampling" ) )
MC.MeshShadowMapSoftness = MC.MeshShadowMapSoftness or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_softness", "1", true, false,
	"Experimental shadow edge softness in shadow-map texels (clamped to at least 1 texel; the shadow bias scales with it)" ) )
MC.MeshGpuShaderFancy = MC.MeshGpuShaderFancy or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_shader_fancy", "1", true, false,
	"Use the fancy GPU chunk shader variant (cool shadows, warm sun, back-face shading, edge fade)" ) )
MC.MeshGpuLightFast = MC.MeshGpuLightFast or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_fast", "0", true, false,
	"Low-sample fast GPU light shader (the original look): 4 light taps + atlas per pixel, warm/cool tinting, no shadow or lightmap sampling; overrides fancy/height selection" ) )
MC.MeshShadowMapTint = MC.MeshShadowMapTint or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_tint", "0.6", true, false,
	"Fancy shader: how strongly shadows shift toward a cool sky tint (0 = plain darkening)" ) )
MC.MeshShadowMapEdgeFade = MC.MeshShadowMapEdgeFade or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_edge_fade", "0.1", true, false,
	"Fancy shader: fade band width at the shadow coverage border in UV units (0 = hard cutoff)" ) )
MC.MeshShadowMapFaceShade = MC.MeshShadowMapFaceShade or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_face_shade", "0.65", true, false,
	"Fancy shader: how strongly faces pointing away from the sun are shaded like cast shadow" ) )
MC.MeshShadowMapWarmth = MC.MeshShadowMapWarmth or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_warmth", "0.35", true, false,
	"Fancy shader: warm tint on sunlit faces and torch-lit areas (0 = neutral)" ) )
MC.MeshGpuLightBrightness = MC.MeshGpuLightBrightness or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_brightness", "1", true, false,
	"GPU light texture: brightness multiplier applied to block/sky light levels (1 = unchanged)" ) )
MC.MeshGpuLightGamma = MC.MeshGpuLightGamma or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_gamma", "1", true, false,
	"GPU light texture: light falloff curve; >1 brightens mid levels (torch edges), <1 darkens them (1 = linear)" ) )
MC.MeshGpuSkyLight = MC.MeshGpuSkyLight or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_sky_light", "0", true, false,
	"GPU light texture: column sky exposure is disabled; day/night uses uniform sky light" ) )
MC.MeshGpuSkySoft = MC.MeshGpuSkySoft or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_sky_soft", "2", true, false,
	"Soft sky exposure radius in blocks: enclosed cells fade to dark with distance from the nearest open-sky column (0 = uniform sky light, interiors stay bright)" ) )
MC.MeshGpuSunBrightness = MC.MeshGpuSunBrightness or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_sun_brightness", "1", true, false,
	"GPU light texture: sun/sky light brightness multiplier (1 = unchanged)" ) )
MC.DayCycleSunTilt = MC.DayCycleSunTilt or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_sun_tilt", "0.2", true, false,
	"Day cycle: sideways tilt of the sun path used by the shadow map (avoids axis-aligned shadows)" ) )
MC.DayCycleMoonShadow = MC.DayCycleMoonShadow or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_moon_shadow", "0.3", true, false,
	"Day cycle: moon shadow strength at night relative to sun shadows (0 = no night shadows)" ) )
MC.DayCycleMoonLight = MC.DayCycleMoonLight or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_moon_light", "2", true, false,
	"Day cycle: moonlight sky level at deep night, 0-15 (MC default 4; lower = darker nights)" ) )
MC.DayCycleNightTint = MC.DayCycleNightTint or ( CreateClientConVar and CreateClientConVar( "mc_daycycle_night_tint", "0.85", true, false,
	"Day cycle: how strongly sky-lit surfaces shift toward moonlight blue at night (0 = neutral)" ) )
MC.MeshGpuLightRefreshPerFrame = MC.MeshGpuLightRefreshPerFrame or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_refresh_per_frame", "2", true, false,
	"GPU light texture: chunks re-rendered per frame during day/night level steps (higher = faster but choppier)" ) )
MC.MeshGpuLightFlushPerFrame = MC.MeshGpuLightFlushPerFrame or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_flush_per_frame", "8", true, false,
	"GPU light texture: max chunk textures baked per frame in the PreRender flush (draw path never bakes; 0 = unlimited)" ) )
MC.MeshGpuLightmap = MC.MeshGpuLightmap or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_lightmap", "1", true, false,
	"Procedural 16x16 global lightmap: warm torch light, colored day/night sky axis (0 = grayscale fallback)" ) )
MC.MeshGpuLightmapTorchWarmth = MC.MeshGpuLightmapTorchWarmth or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_lightmap_torch_warmth", "0.7", true, false,
	"Global lightmap: warm tint of block light (0 = neutral white torches)" ) )
MC.MeshGpuLightmapAmbient = MC.MeshGpuLightmapAmbient or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_lightmap_ambient", "0.04", true, false,
	"Global lightmap: minimum visible brightness in fully dark areas" ) )
MC.MeshGpuLightmapSunset = MC.MeshGpuLightmapSunset or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_lightmap_sunset", "0.5", true, false,
	"Global lightmap: sunset/sunrise orange grading strength on the sky axis (0 = off)" ) )
MC.MeshGpuLightmapNightGamma = MC.MeshGpuLightmapNightGamma or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_lightmap_night_gamma", "0.6", true, false,
	"Global lightmap: perceptual curve on day/night sky brightness (1 = linear; lower = brighter, bluer nights and gentler dusk)" ) )
MC.MeshShadowMapSource = MC.MeshShadowMapSource or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_source", "mc", true, false,
	"Experimental shadow source for MC chunks: mc, screen, or combined" ) )
MC.MeshShadowMapScreenContrast = MC.MeshShadowMapScreenContrast or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_screen_contrast", "6", true, false,
	"Experimental contrast multiplier when sampling the screen-space CSM shadow mask" ) )
MC.MeshShadowMapSize = MC.MeshShadowMapSize or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_size", "2048", true, false,
	"Experimental MC-owned shadow map resolution" ) )
MC.MeshShadowMapDistance = MC.MeshShadowMapDistance or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_distance", "4096", true, false,
	"Experimental MC-owned shadow map world-space coverage radius" ) )
MC.MeshShadowMapCasterDistance = MC.MeshShadowMapCasterDistance or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_caster_distance", "4608", true, false,
	"Experimental max distance from camera for MC chunks drawn into the shadow map" ) )
MC.MeshShadowMapUpdateInterval = MC.MeshShadowMapUpdateInterval or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_map_update_interval", "0", true, false,
	"Experimental minimum seconds between MC shadow map redraws; 0 redraws every frame while enabled" ) )
MC.MeshShadowMode = MC.MeshShadowMode or ( CreateClientConVar and CreateClientConVar( "mc_mesh_shadow_mode", "map", true, false,
	"MC sun shadow technique: map = per-frame sun-space shadow map (PCF), height = cached top-down heightfield ray march (soft shadows, no per-frame depth pass)" ) )
MC.MeshHfShadowSize = MC.MeshHfShadowSize or ( CreateClientConVar and CreateClientConVar( "mc_mesh_hf_shadow_size", "1024", true, false,
	"Heightfield shadow mode: top-down height map resolution" ) )
MC.MeshHfShadowRange = MC.MeshHfShadowRange or ( CreateClientConVar and CreateClientConVar( "mc_mesh_hf_shadow_range", "4096", true, false,
	"Heightfield shadow mode: world-space coverage radius around the player" ) )
MC.MeshHfShadowMaxDist = MC.MeshHfShadowMaxDist or ( CreateClientConVar and CreateClientConVar( "mc_mesh_hf_shadow_max_dist", "2400", true, false,
	"Heightfield shadow mode: max world distance a caster can throw shadow (ray march reach)" ) )
MC.MeshHfShadowSoftness = MC.MeshHfShadowSoftness or ( CreateClientConVar and CreateClientConVar( "mc_mesh_hf_shadow_softness", "0.05", true, false,
	"Heightfield shadow mode: penumbra tangent; shadows widen by this per unit of blocker distance (0.02 = crisp, 0.12 = very soft)" ) )
MC.MeshHfShadowUpdateInterval = MC.MeshHfShadowUpdateInterval or ( CreateClientConVar and CreateClientConVar( "mc_mesh_hf_shadow_update_interval", "0.1", true, false,
	"Heightfield shadow mode: minimum seconds between height map redraws when meshes changed or the window recentered" ) )
MC.MeshConnectionVisibleTemplate = MC.MeshConnectionVisibleTemplate or ( CreateClientConVar and CreateClientConVar( "mc_mesh_connection_visible_template", "1", true, false,
	"Experimental: use cached visible geometry templates for fence/pane/wall/pipe connection shapes" ) )

local MC_LIGHT_STYLE_FAST = "fast"
local MC_LIGHT_STYLE_VANILLA = "vanilla"
local MC_LIGHT_STYLE_BEST = "best"
local MC_LIGHT_STYLE_SHADER = "shader"
local MC_LIGHT_STYLE_GPU_SHADER = "gpu_shader"
local MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE = "gpu_light_texture"
local MC_LIGHT_STYLE_LIGHTMAP = "lightmap"

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
	if style == MC_LIGHT_STYLE_LIGHTMAP or style == "lm" or style == "uv1" or style == "hardware" or style == "4" then return MC_LIGHT_STYLE_LIGHTMAP end
	if LightProfiles[style] then return style end
	return MC_LIGHT_STYLE_SHADER
end

local function currentLightStyle()
	local cv = MC.LightStyle
	local style = normalizeLightStyle( cv and cv.GetString and cv:GetString() or MC_LIGHT_STYLE_SHADER )
	local fallbackLightStyle = RM.fallbackLightStyle
	if fallbackLightStyle then style = fallbackLightStyle( style ) end
	return style
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
	usesHardwareLightmap = false,
} )
registerLightProfile( MC_LIGHT_STYLE_VANILLA, {
	name = "Vanilla",
	usesGpuPayload = false,
	usesHardwareLightmap = false,
} )
registerLightProfile( MC_LIGHT_STYLE_BEST, {
	name = "Best",
	usesGpuPayload = false,
	usesHardwareLightmap = false,
} )
registerLightProfile( MC_LIGHT_STYLE_SHADER, {
	name = "Shader",
	usesGpuPayload = false,
	usesHardwareLightmap = false,
} )
registerLightProfile( MC_LIGHT_STYLE_GPU_SHADER, {
	name = "GPU Shader Payload",
	fallbackStyle = MC_LIGHT_STYLE_SHADER,
	usesGpuPayload = true,
	usesHardwareLightmap = false,
} )
registerLightProfile( MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE, {
	name = "GPU Light Texture",
	fallbackStyle = MC_LIGHT_STYLE_SHADER,
	usesGpuPayload = true,
	usesGpuLightTexture = true,
	usesHardwareLightmap = false,
} )
registerLightProfile( MC_LIGHT_STYLE_LIGHTMAP, {
	name = "Lightmap",
	fallbackStyle = MC_LIGHT_STYLE_VANILLA,
	usesGpuPayload = false,
	usesHardwareLightmap = false,
} )

RM.MC_LIGHT_STYLE_FAST = MC_LIGHT_STYLE_FAST
RM.MC_LIGHT_STYLE_VANILLA = MC_LIGHT_STYLE_VANILLA
RM.MC_LIGHT_STYLE_BEST = MC_LIGHT_STYLE_BEST
RM.MC_LIGHT_STYLE_SHADER = MC_LIGHT_STYLE_SHADER
RM.MC_LIGHT_STYLE_GPU_SHADER = MC_LIGHT_STYLE_GPU_SHADER
RM.MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE = MC_LIGHT_STYLE_GPU_LIGHT_TEXTURE
RM.MC_LIGHT_STYLE_LIGHTMAP = MC_LIGHT_STYLE_LIGHTMAP
RM.currentLightStyle = currentLightStyle
RM.normalizeLightStyle = normalizeLightStyle
RM.effectiveLightStyleForMaterial = effectiveLightStyleForMaterial
RM.meshDebugFullCubeOnly = meshDebugFullCubeOnly
RM.clampLightLevel = clampLightLevel
