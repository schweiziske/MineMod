-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh

-- Localized render-target/image-format constants that GShader Library also
-- defines. Keep them in this addon so the GPU light atlas, global lightmap,
-- and MC shadow map do not depend on CSM/GShader being mounted first.
IMAGE_FORMAT_RGBA8888 = IMAGE_FORMAT_RGBA8888 or 0
IMAGE_FORMAT_RGB565 = IMAGE_FORMAT_RGB565 or 4
IMAGE_FORMAT_A8 = IMAGE_FORMAT_A8 or 8
IMAGE_FORMAT_R32F = IMAGE_FORMAT_R32F or 27
CREATERENDERTARGETFLAGS_NOEDRAM = CREATERENDERTARGETFLAGS_NOEDRAM or 8
MATERIAL_FOG_MODE = MATERIAL_FOG_MODE or 0

local BS  = MC.BS
local CS  = MC.CS
local CH  = MC.CH
local CS2 = CS * CS
local RENDER_SECTION_SIZE = MC.RENDER_SECTION_SIZE or 8
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local RENDER_SECTIONS_Z = math.ceil( MC.CH / RENDER_SECTION_SIZE )

-- directional shading (modulates the texture via vertex colour)
local SH_TOP    = Color( 255, 255, 255 )
local SH_BOTTOM = Color( 128, 128, 128 )
local SH_X      = Color( 153, 153, 153 )
local SH_Y      = Color( 204, 204, 204 )

local N_UP    = Vector(  0,  0,  1 )
local N_DOWN  = Vector(  0,  0, -1 )
local N_XP    = Vector(  1,  0,  0 )
local N_XN    = Vector( -1,  0,  0 )
local N_YP    = Vector(  0,  1,  0 )
local N_YN    = Vector(  0, -1,  0 )

-- face table. slot: 1=top tile, 2=bottom tile, 3=side tile
-- c = four corners as { offX, offY, offZ, uFlag, vFlag } (a,b,c,d), drawn a,b,c + a,c,d
local FACES = {
	{ n = N_UP,   sh = SH_TOP,    slot = 1, off = {  0,  0,  1 }, c = { {0,0,1,0,1}, {1,0,1,1,1}, {1,1,1,1,0}, {0,1,1,0,0} } },
	{ n = N_DOWN, sh = SH_BOTTOM, slot = 2, off = {  0,  0, -1 }, c = { {0,1,0,0,1}, {1,1,0,1,1}, {1,0,0,1,0}, {0,0,0,0,0} } },
	{ n = N_XP,   sh = SH_X,      slot = 3, off = {  1,  0,  0 }, c = { {1,0,0,0,1}, {1,1,0,1,1}, {1,1,1,1,0}, {1,0,1,0,0} } },
	{ n = N_XN,   sh = SH_X,      slot = 3, off = { -1,  0,  0 }, c = { {0,1,0,0,1}, {0,0,0,1,1}, {0,0,1,1,0}, {0,1,1,0,0} } },
	{ n = N_YP,   sh = SH_Y,      slot = 3, off = {  0,  1,  0 }, c = { {1,1,0,0,1}, {0,1,0,1,1}, {0,1,1,1,0}, {1,1,1,0,0} } },
	{ n = N_YN,   sh = SH_Y,      slot = 3, off = {  0, -1,  0 }, c = { {0,0,0,0,1}, {1,0,0,1,1}, {1,0,1,1,0}, {0,0,1,0,0} } },
}
-- Source's front-face winding is opposite the corner order above.
local TRI = { 1, 3, 2, 1, 4, 3 }

local function cornerXYZ( cn )
	return cn.x or cn.cx or cn[1] or 0, cn.y or cn.cy or cn[2] or 0, cn.z or cn.cz or cn[3] or 0
end

local function cornerCellOffset( value )
	return value <= 0 and -1 or 0
end

local function cornerSampleOffsets( value )
	local low = cornerCellOffset( value )
	return low, low + 1
end

local function cornerStep( value )
	return value <= 0 and -1 or 1
end

local mathClamp, mathFloor = math.Clamp, math.floor

local VERT_LIMIT = 64998 -- multiple of 6, under the 65535 IMesh vertex cap

MC.RenderMeshConstants = MC.RenderMeshConstants or {}
MC.RenderMeshConstants.BS = BS
MC.RenderMeshConstants.CS = CS
MC.RenderMeshConstants.CH = CH
MC.RenderMeshConstants.CS2 = CS2
MC.RenderMeshConstants.RENDER_SECTIONS_XY = RENDER_SECTIONS_XY
MC.RenderMeshConstants.RENDER_SECTIONS_Z = RENDER_SECTIONS_Z
MC.RenderMeshConstants.VERT_LIMIT = VERT_LIMIT
MC.RenderMeshConstants.FACES = FACES
MC.RenderMeshConstants.TRI = TRI
MC.RenderMeshConstants.N_UP = N_UP
MC.RenderMeshConstants.N_DOWN = N_DOWN
MC.RenderMeshConstants.N_XP = N_XP
MC.RenderMeshConstants.N_XN = N_XN
MC.RenderMeshConstants.N_YP = N_YP
MC.RenderMeshConstants.N_YN = N_YN
MC.RenderMeshConstants.SH_TOP = SH_TOP
MC.RenderMeshConstants.SH_BOTTOM = SH_BOTTOM
MC.RenderMeshConstants.SH_X = SH_X
MC.RenderMeshConstants.SH_Y = SH_Y

RM.BS = BS
RM.CS = CS
RM.CH = CH
RM.CS2 = CS2
RM.RENDER_SECTION_SIZE = RENDER_SECTION_SIZE
RM.RENDER_SECTIONS_XY = RENDER_SECTIONS_XY
RM.RENDER_SECTIONS_Z = RENDER_SECTIONS_Z
RM.VERT_LIMIT = VERT_LIMIT
RM.FACES = FACES
RM.TRI = TRI
RM.mathClamp = mathClamp
RM.mathFloor = mathFloor
RM.cornerXYZ = cornerXYZ
RM.cornerCellOffset = cornerCellOffset
RM.cornerSampleOffsets = cornerSampleOffsets
RM.cornerStep = cornerStep
