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
MC.MeshLightmapUV = MC.MeshLightmapUV or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_uv", "1", true, false,
	"Use UV1 hardware lightmaps for mc_light_style lightmap" ) )
MC.MeshLightmapSource = MC.MeshLightmapSource or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_source", "generated", true, false,
	"Hardware lightmap texture source: generated or image" ) )
MC.MeshLightmapImage = MC.MeshLightmapImage or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_image", "mc/lightmap.png", true, false,
	"Material path for mc_mesh_lightmap_source image, such as mc/lightmap.png" ) )
MC.MeshLightmapAllowExternal = MC.MeshLightmapAllowExternal or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_allow_external", "0", true, false,
	"Allow mc_mesh_lightmap_source image to override the generated in-game MC lightmap" ) )
MC.MeshLightmapExposure = MC.MeshLightmapExposure or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_exposure", "1", true, false,
	"Brightness multiplier for the generated MC hardware lightmap texture" ) )
MC.MeshLightmapAmbientScale = MC.MeshLightmapAmbientScale or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_ambient_scale", "1", true, false,
	"Multiplier for the Minecraft AmbientColor uniform in the generated MC hardware lightmap texture" ) )
MC.MeshLightmapSkyFactor = MC.MeshLightmapSkyFactor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_sky_factor", "1", true, false,
	"Minecraft lightmap SkyFactor uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBrightnessFactor = MC.MeshLightmapBrightnessFactor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_brightness_factor", "0", true, false,
	"Minecraft lightmap BrightnessFactor/gamma uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBlockFlicker = MC.MeshLightmapBlockFlicker or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_block_flicker", "1", true, false,
	"Apply Minecraft-style block light flicker to the generated UV1 lightmap texture" ) )
MC.MeshLightmapNightVisionFactor = MC.MeshLightmapNightVisionFactor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_night_vision_factor", "0", true, false,
	"Minecraft lightmap NightVisionFactor uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapDarknessScale = MC.MeshLightmapDarknessScale or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_darkness_scale", "0", true, false,
	"Minecraft lightmap DarknessScale uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBossDarkening = MC.MeshLightmapBossDarkening or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_boss_darkening", "0", true, false,
	"Minecraft lightmap BossOverlayWorldDarkeningFactor uniform for UV1 hardware lightmaps" ) )
MC.MeshLightmapBlockTint = MC.MeshLightmapBlockTint or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_block_tint", "255 216 140", true, false,
	"Minecraft lightmap BlockLightTint RGB color for UV1 hardware lightmaps" ) )
MC.MeshLightmapSkyColor = MC.MeshLightmapSkyColor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_sky_color", "255 255 255", true, false,
	"Minecraft lightmap SkyLightColor RGB color for UV1 hardware lightmaps" ) )
MC.MeshLightmapAmbientColor = MC.MeshLightmapAmbientColor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_ambient_color", "0 0 0", true, false,
	"Minecraft lightmap AmbientColor RGB color for UV1 hardware lightmaps" ) )
MC.MeshLightmapNightVisionColor = MC.MeshLightmapNightVisionColor or ( CreateClientConVar and CreateClientConVar( "mc_mesh_lightmap_night_vision_color", "153 153 153", true, false,
	"Minecraft lightmap NightVisionColor RGB color for UV1 hardware lightmaps" ) )

local MC_LIGHT_STYLE_FAST = "fast"
local MC_LIGHT_STYLE_VANILLA = "vanilla"
local MC_LIGHT_STYLE_BEST = "best"
local MC_LIGHT_STYLE_SHADER = "shader"
local MC_LIGHT_STYLE_LIGHTMAP = "lightmap"

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

local mathClamp, mathFloor = math.Clamp, math.floor

local function currentLightStyle()
	local cv = MC.LightStyle
	local style = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or MC_LIGHT_STYLE_VANILLA
	if style == MC_LIGHT_STYLE_FAST or style == "low" or style == "0" then return MC_LIGHT_STYLE_FAST end
	if style == MC_LIGHT_STYLE_BEST or style == "fancy" or style == "high" or style == "2" then return MC_LIGHT_STYLE_BEST end
	if style == MC_LIGHT_STYLE_LIGHTMAP or style == "lm" or style == "4" then return MC_LIGHT_STYLE_LIGHTMAP end
	if style == MC_LIGHT_STYLE_SHADER or style == "shaders" or style == "cinematic" or style == "3" then return MC_LIGHT_STYLE_SHADER end
	return MC_LIGHT_STYLE_VANILLA
end

local function meshLightmapUVEnabled()
	local cv = MC.MeshLightmapUV
	return not cv or not cv.GetBool or cv:GetBool()
end

local function meshDebugFullCubeOnly()
	local cv = MC.MeshDebugFullCubeOnly
	return cv and cv.GetBool and cv:GetBool() or false
end

local function lightmapStyleUsesHardware( style )
	return style == MC_LIGHT_STYLE_LIGHTMAP and meshLightmapUVEnabled()
end

local function fallbackLightStyle( style )
	return style == MC_LIGHT_STYLE_LIGHTMAP and MC_LIGHT_STYLE_VANILLA or style
end

MC.CurrentMeshLightStyle = currentLightStyle
MC.MeshLightStyleIsLightmap = lightmapStyleUsesHardware
MC.MeshLightStyleUsesHardwareLightmap = lightmapStyleUsesHardware

local function clampLightLevel( level )
	return mathClamp( mathFloor( tonumber( level ) or 0 ), 0, 15 )
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
	return lightmapUVFromSmoothCoords( clampLightLevel( block ) * 16, clampLightLevel( sky ) * 16 )
end

MC.MeshLightmapUVFromLevels = lightmapUVFromLevels
MC.MeshLightmapUVFromSmoothCoords = lightmapUVFromSmoothCoords

RM.MC_LIGHT_STYLE_FAST = MC_LIGHT_STYLE_FAST
RM.MC_LIGHT_STYLE_VANILLA = MC_LIGHT_STYLE_VANILLA
RM.MC_LIGHT_STYLE_BEST = MC_LIGHT_STYLE_BEST
RM.MC_LIGHT_STYLE_SHADER = MC_LIGHT_STYLE_SHADER
RM.MC_LIGHT_STYLE_LIGHTMAP = MC_LIGHT_STYLE_LIGHTMAP
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
RM.currentLightStyle = currentLightStyle
RM.meshLightmapUVEnabled = meshLightmapUVEnabled
RM.meshDebugFullCubeOnly = meshDebugFullCubeOnly
RM.lightmapStyleUsesHardware = lightmapStyleUsesHardware
RM.fallbackLightStyle = fallbackLightStyle
RM.clampLightLevel = clampLightLevel
RM.clampSmoothLightCoord = clampSmoothLightCoord
RM.lightmapUVFromSmoothCoords = lightmapUVFromSmoothCoords
RM.lightmapUVFromLevels = lightmapUVFromLevels
