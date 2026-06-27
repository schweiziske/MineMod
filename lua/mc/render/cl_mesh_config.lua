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

local MC_LIGHT_STYLE_FAST = "fast"
local MC_LIGHT_STYLE_VANILLA = "vanilla"
local MC_LIGHT_STYLE_BEST = "best"
local MC_LIGHT_STYLE_SHADER = "shader"

local mathClamp, mathFloor = math.Clamp, math.floor

local function currentLightStyle()
	local cv = MC.LightStyle
	local style = cv and cv.GetString and string.lower( tostring( cv:GetString() or "" ) ) or MC_LIGHT_STYLE_VANILLA
	if style == MC_LIGHT_STYLE_FAST or style == "low" or style == "0" then return MC_LIGHT_STYLE_FAST end
	if style == MC_LIGHT_STYLE_BEST or style == "fancy" or style == "high" or style == "2" then return MC_LIGHT_STYLE_BEST end
	if style == MC_LIGHT_STYLE_SHADER or style == "shaders" or style == "cinematic" or style == "3" then return MC_LIGHT_STYLE_SHADER end
	return MC_LIGHT_STYLE_SHADER
end

local function meshDebugFullCubeOnly()
	local cv = MC.MeshDebugFullCubeOnly
	return cv and cv.GetBool and cv:GetBool() or false
end

MC.CurrentMeshLightStyle = currentLightStyle

local function clampLightLevel( level )
	return mathClamp( mathFloor( tonumber( level ) or 0 ), 0, 15 )
end

RM.MC_LIGHT_STYLE_FAST = MC_LIGHT_STYLE_FAST
RM.MC_LIGHT_STYLE_VANILLA = MC_LIGHT_STYLE_VANILLA
RM.MC_LIGHT_STYLE_BEST = MC_LIGHT_STYLE_BEST
RM.MC_LIGHT_STYLE_SHADER = MC_LIGHT_STYLE_SHADER
RM.currentLightStyle = currentLightStyle
RM.meshDebugFullCubeOnly = meshDebugFullCubeOnly
RM.clampLightLevel = clampLightLevel
