-- Optional Source-engine lighting bridge for MC mesh vertex colors.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh

local C = MC.RenderMeshConstants
local BS = C and C.BS or MC.BS or 32
local FACES = C and C.FACES or {}
local mathClamp = math.Clamp
local mathFloor = math.floor

MC.MeshSourceLighting = MC.MeshSourceLighting or ( CreateClientConVar and CreateClientConVar(
	"mc_mesh_source_lighting", "0", true, false,
	"Blend Source engine static lighting into MC mesh vertex colors: 0 off, 1 ambient, 2 normal, 3 max"
) )
MC.MeshSourceLightingStrength = MC.MeshSourceLightingStrength or ( CreateClientConVar and CreateClientConVar(
	"mc_mesh_source_lighting_strength", "0.55", true, false,
	"How strongly Source lighting modulates MC mesh vertex colors"
) )
MC.MeshSourceLightingMin = MC.MeshSourceLightingMin or ( CreateClientConVar and CreateClientConVar(
	"mc_mesh_source_lighting_min", "0.35", true, false,
	"Minimum Source lighting multiplier for MC mesh vertex colors"
) )
MC.MeshSourceLightingScale = MC.MeshSourceLightingScale or ( CreateClientConVar and CreateClientConVar(
	"mc_mesh_source_lighting_scale", "1.0", true, false,
	"Scale applied to sampled Source lighting before blending into MC mesh colors"
) )

local SourceLightingCacheR = {}
local SourceLightingCacheG = {}
local SourceLightingCacheB = {}
local SourceLightingEnabled, SourceLightingMode, SourceLightingStrength, SourceLightingMin, SourceLightingScale

local function refreshSourceLightingState()
	local mode = MC.MeshSourceLighting and MC.MeshSourceLighting.GetInt and MC.MeshSourceLighting:GetInt() or 0
	SourceLightingMode = mathClamp( mathFloor( tonumber( mode ) or 0 ), 0, 3 )
	SourceLightingEnabled = SourceLightingMode > 0 and render ~= nil
	SourceLightingStrength = mathClamp( MC.MeshSourceLightingStrength and MC.MeshSourceLightingStrength.GetFloat and MC.MeshSourceLightingStrength:GetFloat() or 0.55, 0, 1 )
	SourceLightingMin = mathClamp( MC.MeshSourceLightingMin and MC.MeshSourceLightingMin.GetFloat and MC.MeshSourceLightingMin:GetFloat() or 0.35, 0, 4 )
	SourceLightingScale = mathClamp( MC.MeshSourceLightingScale and MC.MeshSourceLightingScale.GetFloat and MC.MeshSourceLightingScale:GetFloat() or 1, 0, 8 )
end

function RM.resetSourceLightingCache()
	SourceLightingCacheR = {}
	SourceLightingCacheG = {}
	SourceLightingCacheB = {}
	refreshSourceLightingState()
end

local function sourceLightingKey( bx, by, bz, faceIndex, cx, cy, cz )
	local sx = mathFloor( ( tonumber( cx ) or 0 ) * 16 + 0.5 )
	local sy = mathFloor( ( tonumber( cy ) or 0 ) * 16 + 0.5 )
	local sz = mathFloor( ( tonumber( cz ) or 0 ) * 16 + 0.5 )
	local key = bx
	key = key * 64 + by
	key = key * 64 + bz
	key = key * 8 + ( faceIndex or 0 )
	key = key * 17 + sx
	key = key * 17 + sy
	key = key * 17 + sz
	return key
end

local function samplePos( bx, by, bz, faceIndex, cx, cy, cz )
	local base = MC.CellWorldMin and MC.CellWorldMin( bx, by, bz )
	if not base then return nil end
	local face = FACES[faceIndex]
	local n = face and face.n
	local inset = 0.025 * BS
	return Vector(
		base.x + ( tonumber( cx ) or 0.5 ) * BS + ( n and n.x or 0 ) * inset,
		base.y + ( tonumber( cy ) or 0.5 ) * BS + ( n and n.y or 0 ) * inset,
		base.z + ( tonumber( cz ) or 0.5 ) * BS + ( n and n.z or 0 ) * inset
	), n
end

local function vectorRGB( v )
	if not v then return 1, 1, 1 end
	return tonumber( v.x ) or 1, tonumber( v.y ) or 1, tonumber( v.z ) or 1
end

function RM.sourceLightingRGB( bx, by, bz, faceIndex, cx, cy, cz )
	if SourceLightingEnabled == nil then refreshSourceLightingState() end
	if not SourceLightingEnabled then return 1, 1, 1 end
	local key = sourceLightingKey( bx or 0, by or 0, bz or 0, faceIndex or 0, cx or 0.5, cy or 0.5, cz or 0.5 )
	local cached = SourceLightingCacheR[key]
	if cached then return cached, SourceLightingCacheG[key], SourceLightingCacheB[key] end

	local pos, normal = samplePos( bx or 0, by or 0, bz or 0, faceIndex or 0, cx, cy, cz )
	if not pos then return 1, 1, 1 end
	local ar, ag, ab = 1, 1, 1
	local nr, ng, nb = 1, 1, 1
	if ( SourceLightingMode == 1 or SourceLightingMode == 3 ) and render.GetLightColor then
		ar, ag, ab = vectorRGB( render.GetLightColor( pos ) )
	end
	if ( SourceLightingMode == 2 or SourceLightingMode == 3 ) and render.ComputeLighting and normal then
		nr, ng, nb = vectorRGB( render.ComputeLighting( pos, normal ) )
	end
	local sr, sg, sb
	if SourceLightingMode == 1 then
		sr, sg, sb = ar, ag, ab
	elseif SourceLightingMode == 2 then
		sr, sg, sb = nr, ng, nb
	else
		sr, sg, sb = math.max( ar, nr ), math.max( ag, ng ), math.max( ab, nb )
	end
	sr = mathClamp( sr * SourceLightingScale, SourceLightingMin, 4 )
	sg = mathClamp( sg * SourceLightingScale, SourceLightingMin, 4 )
	sb = mathClamp( sb * SourceLightingScale, SourceLightingMin, 4 )
	SourceLightingCacheR[key] = sr
	SourceLightingCacheG[key] = sg
	SourceLightingCacheB[key] = sb
	return sr, sg, sb
end

function RM.applySourceLightingToRGB( r, g, b, bx, by, bz, faceIndex, cx, cy, cz )
	if SourceLightingEnabled == nil then refreshSourceLightingState() end
	if not SourceLightingEnabled or SourceLightingStrength <= 0 then return r, g, b end
	local sr, sg, sb = RM.sourceLightingRGB( bx, by, bz, faceIndex, cx, cy, cz )
	local inv = 1 - SourceLightingStrength
	local fr = inv + SourceLightingStrength * sr
	local fg = inv + SourceLightingStrength * sg
	local fb = inv + SourceLightingStrength * sb
	return
		mathClamp( mathFloor( ( r or 255 ) * fr + 0.5 ), 0, 255 ),
		mathClamp( mathFloor( ( g or 255 ) * fg + 0.5 ), 0, 255 ),
		mathClamp( mathFloor( ( b or 255 ) * fb + 0.5 ), 0, 255 )
end

refreshSourceLightingState()
