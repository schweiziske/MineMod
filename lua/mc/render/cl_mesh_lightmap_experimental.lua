-- Render mesh experimental UV1 hardware lightmap gate.
--
-- This file is intentionally the single opt-in point for the UV1
-- LightmappedGeneric path. The stable mainline is shader/vanilla CPU vertex
-- color lighting. Do not make shader or vanilla silently enter this path.
--
-- Current conclusion, 2026-06-26:
-- - UV1 lightmap is real Source UV1 sampling, but it is not production-ready.
-- - Minecraft smooth light is corner/discrete; Source interpolates UV1 over
--   triangles. High contrast block faces can show diagonal or fan artifacts.
-- - Diagonal selection only helps when the two diagonals differ. The user's
--   aimed YP wall face had equal diagonal UV1 distance, so it did nothing.
-- - Center splitting reduced UV distance in a local simulation, but produced
--   radial/windmill artifacts in-game. That attempt was removed.
-- - Exposure, material filtering, and block tint can amplify issues, but they
--   do not explain the core interpolation artifact or stale-cache risk.
-- - Avoid hot-session globals: every gate and helper needed by clean addon
--   loads must live in normal Lua files included by mc_load.lua.
-- - Revisit this path only with a better GPU shader/native-module approach or
--   a proven visual quality strategy for high-contrast quads.

MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh

MC.MeshLightmapExperimental = MC.MeshLightmapExperimental or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_experimental", "0", true, false,
	"Enable the isolated experimental UV1 lightmap backend when it is reconnected" ) )
MC.MeshLightmapUV = MC.MeshLightmapUV or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_uv", "0", true, false,
	"Experimental UV1 hardware lightmap switch; currently isolated from the main mesh backend" ) )
MC.MeshLightmapSource = MC.MeshLightmapSource or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_source", "generated", true, false,
	"Experimental hardware lightmap texture source: generated or image" ) )
MC.MeshLightmapImage = MC.MeshLightmapImage or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_image", "mc/lightmap.png", true, false,
	"Experimental material path for mc_mesh_lightmap_source image, such as mc/lightmap.png" ) )
MC.MeshLightmapAllowExternal = MC.MeshLightmapAllowExternal or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_allow_external", "0", true, false,
	"Allow mc_mesh_lightmap_source image to override the generated in-game MC lightmap" ) )
MC.MeshLightmapExposure = MC.MeshLightmapExposure or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_exposure", "1", true, false,
	"Brightness multiplier for the generated MC hardware lightmap texture" ) )
MC.MeshLightmapBaseScale = MC.MeshLightmapBaseScale or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_base_scale", "0.6", true, false,
	"Base brightness compensation for user hardware lightmaps; multiplied by mc_mesh_lightmap_exposure" ) )
MC.MeshLightmapAmbientScale = MC.MeshLightmapAmbientScale or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_ambient_scale", "1", true, false,
	"Multiplier for the Minecraft AmbientColor uniform in the generated MC hardware lightmap texture" ) )
MC.MeshLightmapSkyFactor = MC.MeshLightmapSkyFactor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_sky_factor", "1", true, false,
	"Minecraft lightmap SkyFactor uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBrightnessFactor = MC.MeshLightmapBrightnessFactor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_brightness_factor", "0", true, false,
	"Minecraft lightmap BrightnessFactor/gamma uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBlockFlicker = MC.MeshLightmapBlockFlicker or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_block_flicker", "0", true, false,
	"Apply Minecraft-style block light flicker to the generated UV1 lightmap texture" ) )
MC.MeshLightmapNightVisionFactor = MC.MeshLightmapNightVisionFactor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_night_vision_factor", "0", true, false,
	"Minecraft lightmap NightVisionFactor uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapDarknessScale = MC.MeshLightmapDarknessScale or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_darkness_scale", "0", true, false,
	"Minecraft lightmap DarknessScale uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBossDarkening = MC.MeshLightmapBossDarkening or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_boss_darkening", "0", true, false,
	"Minecraft lightmap BossOverlayWorldDarkeningFactor uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBlockTint = MC.MeshLightmapBlockTint or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_block_tint", "255 255 255", true, false,
	"Minecraft lightmap BlockLightTint RGB color for UV1 hardware lightmaps" ) )
MC.MeshLightmapSkyColor = MC.MeshLightmapSkyColor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_sky_color", "255 255 255", true, false,
	"Minecraft lightmap SkyLightColor RGB color for UV1 hardware lightmaps" ) )
MC.MeshLightmapAmbientColor = MC.MeshLightmapAmbientColor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_ambient_color", "0 0 0", true, false,
	"Minecraft lightmap AmbientColor RGB color for UV1 hardware lightmaps" ) )
MC.MeshLightmapNightVisionColor = MC.MeshLightmapNightVisionColor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_night_vision_color", "153 153 153", true, false,
	"Minecraft lightmap NightVisionColor RGB color for UV1 hardware lightmaps" ) )

local LIGHTMAP_TEXTURE_SIZE = 256
local LIGHTMAP_SMOOTH_COORD_MAX = 240
local LIGHTMAP_SMOOTH_COORD_TEXEL_CENTER = 8
local LIGHTMAP_SMOOTH_COORD_SCALE = 256
local LIGHTMAP_PACK_SKY_MASK = 0xFF0000
local LIGHTMAP_SMOOTH_PACK_MASK = 0xFF00FF
local MC_LIGHTMAP_BLOCK_FACTOR = 1.4
local MC_LIGHTMAP_SKY_FACTOR = 1
local MC_LIGHTMAP_BLOCK_TINT_R = 1
local MC_LIGHTMAP_BLOCK_TINT_G = 216 / 255
local MC_LIGHTMAP_BLOCK_TINT_B = 140 / 255
local MC_LIGHTMAP_SKY_R = 1
local MC_LIGHTMAP_SKY_G = 1
local MC_LIGHTMAP_SKY_B = 1

local MC_LIGHT_STYLE_LIGHTMAP = RM.MC_LIGHT_STYLE_LIGHTMAP or "lightmap"
local MC_LIGHT_STYLE_VANILLA = RM.MC_LIGHT_STYLE_VANILLA or "vanilla"
local mathClamp, mathFloor = math.Clamp, math.floor

local function meshLightmapExperimentalEnabled()
	local cv = MC.MeshLightmapExperimental
	return cv and cv.GetBool and cv:GetBool() or false
end

local function meshLightmapUVEnabled()
	local cv = MC.MeshLightmapUV
	return not cv or not cv.GetBool or cv:GetBool()
end

local function lightmapBackendAvailable()
	return false
end

local function lightmapStyleUsesHardware( style )
	return style == MC_LIGHT_STYLE_LIGHTMAP
		and meshLightmapExperimentalEnabled()
		and meshLightmapUVEnabled()
		and lightmapBackendAvailable()
end

local function fallbackLightStyle( style )
	if style == MC_LIGHT_STYLE_LIGHTMAP and not lightmapStyleUsesHardware( style ) then
		return MC_LIGHT_STYLE_VANILLA
	end
	return style
end

local function clampSmoothLightCoord( coord )
	return mathClamp( mathFloor( tonumber( coord ) or 0 ), 0, LIGHTMAP_SMOOTH_COORD_MAX )
end

local function lightmapUVFromSmoothCoords( blockCoord, skyCoord )
	blockCoord = clampSmoothLightCoord( blockCoord )
	skyCoord = clampSmoothLightCoord( skyCoord )
	return ( blockCoord + LIGHTMAP_SMOOTH_COORD_TEXEL_CENTER ) / LIGHTMAP_SMOOTH_COORD_SCALE,
		( skyCoord + LIGHTMAP_SMOOTH_COORD_TEXEL_CENTER ) / LIGHTMAP_SMOOTH_COORD_SCALE
end

local function lightmapUVFromLevels( block, sky )
	local clampLightLevel = RM.clampLightLevel
	block = clampLightLevel and clampLightLevel( block ) or mathClamp( mathFloor( tonumber( block ) or 0 ), 0, 15 )
	sky = clampLightLevel and clampLightLevel( sky ) or mathClamp( mathFloor( tonumber( sky ) or 0 ), 0, 15 )
	return lightmapUVFromSmoothCoords( block * 16, sky * 16 )
end

MC.MeshLightmapBackendAvailable = lightmapBackendAvailable
MC.MeshLightmapExperimentalEnabled = meshLightmapExperimentalEnabled
MC.MeshLightStyleIsLightmap = lightmapStyleUsesHardware
MC.MeshLightStyleUsesHardwareLightmap = lightmapStyleUsesHardware
MC.MeshLightmapUVFromLevels = lightmapUVFromLevels
MC.MeshLightmapUVFromSmoothCoords = lightmapUVFromSmoothCoords

RM.LIGHTMAP_TEXTURE_SIZE = LIGHTMAP_TEXTURE_SIZE
RM.LIGHTMAP_SMOOTH_COORD_MAX = LIGHTMAP_SMOOTH_COORD_MAX
RM.LIGHTMAP_SMOOTH_COORD_TEXEL_CENTER = LIGHTMAP_SMOOTH_COORD_TEXEL_CENTER
RM.LIGHTMAP_SMOOTH_COORD_SCALE = LIGHTMAP_SMOOTH_COORD_SCALE
RM.LIGHTMAP_PACK_SKY_MASK = LIGHTMAP_PACK_SKY_MASK
RM.LIGHTMAP_SMOOTH_PACK_MASK = LIGHTMAP_SMOOTH_PACK_MASK
RM.MC_LIGHTMAP_BLOCK_FACTOR = MC_LIGHTMAP_BLOCK_FACTOR
RM.MC_LIGHTMAP_SKY_FACTOR = MC_LIGHTMAP_SKY_FACTOR
RM.MC_LIGHTMAP_BLOCK_TINT_R = MC_LIGHTMAP_BLOCK_TINT_R
RM.MC_LIGHTMAP_BLOCK_TINT_G = MC_LIGHTMAP_BLOCK_TINT_G
RM.MC_LIGHTMAP_BLOCK_TINT_B = MC_LIGHTMAP_BLOCK_TINT_B
RM.MC_LIGHTMAP_SKY_R = MC_LIGHTMAP_SKY_R
RM.MC_LIGHTMAP_SKY_G = MC_LIGHTMAP_SKY_G
RM.MC_LIGHTMAP_SKY_B = MC_LIGHTMAP_SKY_B
RM.lightmapBackendAvailable = lightmapBackendAvailable
RM.meshLightmapExperimentalEnabled = meshLightmapExperimentalEnabled
RM.meshLightmapUVEnabled = meshLightmapUVEnabled
RM.lightmapStyleUsesHardware = lightmapStyleUsesHardware
RM.fallbackLightStyle = fallbackLightStyle
RM.clampSmoothLightCoord = clampSmoothLightCoord
RM.lightmapUVFromSmoothCoords = lightmapUVFromSmoothCoords
RM.lightmapUVFromLevels = lightmapUVFromLevels

if RM.RegisterLightProfile then
	RM.RegisterLightProfile( MC_LIGHT_STYLE_LIGHTMAP, {
		fallbackStyle = MC_LIGHT_STYLE_VANILLA,
		usesGpuPayload = false,
		usesHardwareLightmap = false,
		hardwareAvailable = lightmapStyleUsesHardware,
	} )
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_lightmap_experimental", function()
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "lightmap_experimental_toggle" ) end
	end, "mc_mesh_lightmap_experimental_rebuild" )
end
