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
MC.MeshGpuShader = MC.MeshGpuShader or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_shader", "0", true, false,
	"Use the experimental custom GPU shader for opaque MC chunk atlas meshes when the compiled VCS files are available" ) )
MC.MeshGpuLightTexture = MC.MeshGpuLightTexture or ( CreateClientConVar and CreateClientConVar( "mc_mesh_gpu_light_texture", "0", true, false,
	"Experimental: sample chunk light textures in the GPU shader instead of baking opaque chunk light into vertex colors" ) )
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
