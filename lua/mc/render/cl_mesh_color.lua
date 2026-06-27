-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local FACES = C.FACES
local mathClamp = math.Clamp
local mathFloor = math.floor
local cornerXYZ = RM.cornerXYZ
local cornerStep = RM.cornerStep
local minecraftSmoothCornerBrightness = RM.minecraftSmoothCornerBrightness
local cachedMeshLightingSample = RM.cachedMeshLightingSample
local cachedMeshLightingSampleFast = RM.cachedMeshLightingSampleFast
local cachedMeshAOSample = RM.cachedMeshAOSample
local cachedMeshAOSampleFast = RM.cachedMeshAOSampleFast
local minecraftSmoothCornerBrightnessValues = RM.minecraftSmoothCornerBrightnessValues
local minecraftSmoothCornerShadeBrightnessValues = RM.minecraftSmoothCornerShadeBrightnessValues
local MC_LIGHT_STYLE_FAST = RM.MC_LIGHT_STYLE_FAST
local MC_LIGHT_STYLE_VANILLA = RM.MC_LIGHT_STYLE_VANILLA
local MC_LIGHT_STYLE_BEST = RM.MC_LIGHT_STYLE_BEST
local MC_LIGHT_STYLE_SHADER = RM.MC_LIGHT_STYLE_SHADER
local MC_LIGHT_AO_FACTORS = RM.MC_LIGHT_AO_FACTORS
local MC_LIGHT_BEST_AO_FACTORS = RM.MC_LIGHT_BEST_AO_FACTORS
local MC_LIGHT_SHADER_AO_FACTORS = RM.MC_LIGHT_SHADER_AO_FACTORS
local shadeRGBAByIndex = RM.shadeRGBAByIndex
local fullCubeColorCacheKey = RM.fullCubeColorCacheKey

local MeshFullCubeColorCache = {}
local MeshShaderDaylightFactor = nil

function RM.resetMeshColorLightingCaches()
	MeshFullCubeColorCache = {}
	MeshShaderDaylightFactor = nil
end

local function minecraftSmoothCornerShadeBrightness( bx, by, bz, faceIndex, cn )
	local cx, cy, cz = cornerXYZ( cn )
	return minecraftSmoothCornerShadeBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, true )
end

local function minecraftFastCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local face = FACES[faceIndex]
	local off = face and face.off
	if not off then return cachedMeshLightingSample( bx, by, bz, selfEmission ) end
	return cachedMeshLightingSample( bx + off[1], by + off[2], bz + off[3], selfEmission )
end

local function minecraftFastCornerBrightnessValues( bx, by, bz, faceIndex, selfEmission )
	local face = FACES[faceIndex]
	local off = face and face.off
	if not off then return cachedMeshLightingSample( bx, by, bz, selfEmission ) end
	return cachedMeshLightingSample( bx + off[1], by + off[2], bz + off[3], selfEmission )
end

local function fullCubeSmoothCornerBrightnessFast( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission )
	return minecraftSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx0, cy0, cz0, selfEmission )
end

local function fullCubeCornerAOWithFactorsFast( bx, by, bz, faceIndex, cx0, cy0, cz0, f1, f2, f3 )
	local xs = cx0 <= 0 and -1 or 1
	local ys = cy0 <= 0 and -1 or 1
	local zs = cz0 <= 0 and -1 or 1
	local side1Blocked, side2Blocked, cornerBlocked
	if faceIndex == MC.Face.TOP or faceIndex == MC.Face.BOTTOM then
		side1Blocked = cachedMeshAOSampleFast( bx + xs, by, bz )
		side2Blocked = cachedMeshAOSampleFast( bx, by + ys, bz )
		cornerBlocked = cachedMeshAOSampleFast( bx + xs, by + ys, bz )
	elseif faceIndex == MC.Face.XP or faceIndex == MC.Face.XN then
		side1Blocked = cachedMeshAOSampleFast( bx, by + ys, bz )
		side2Blocked = cachedMeshAOSampleFast( bx, by, bz + zs )
		cornerBlocked = cachedMeshAOSampleFast( bx, by + ys, bz + zs )
	else
		side1Blocked = cachedMeshAOSampleFast( bx + xs, by, bz )
		side2Blocked = cachedMeshAOSampleFast( bx, by, bz + zs )
		cornerBlocked = cachedMeshAOSampleFast( bx + xs, by, bz + zs )
	end
	if side1Blocked and side2Blocked then return f3 end
	local blocked = ( side1Blocked and 1 or 0 ) + ( side2Blocked and 1 or 0 ) + ( cornerBlocked and 1 or 0 )
	if blocked == 1 then return f1 end
	if blocked == 2 then return f2 end
	if blocked == 3 then return f3 end
	return 1
end

local function bestSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local brightness = math.Clamp( minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission ), 0, 1 )
	return math.Clamp( brightness ^ 0.85, 0, 1 )
end

local function bestSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
	local brightness = math.Clamp( minecraftSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission ), 0, 1 )
	return math.Clamp( brightness ^ 0.85, 0, 1 )
end

local function shaderSunFaceFactor( faceIndex )
	if faceIndex == MC.Face.TOP then return 1.16 end
	if faceIndex == MC.Face.BOTTOM then return 0.72 end
	if faceIndex == MC.Face.YP then return 1.08 end
	if faceIndex == MC.Face.XP then return 1.00 end
	if faceIndex == MC.Face.XN then return 0.88 end
	if faceIndex == MC.Face.YN then return 0.82 end
	return 1
end

local function shaderDaylightFactor()
	if MeshShaderDaylightFactor ~= nil then return MeshShaderDaylightFactor end
	local cv = MC.LightSkyLevel
	MeshShaderDaylightFactor = math.Clamp( ( cv and cv.GetInt and cv:GetInt() or 15 ) / 15, 0, 1 )
	return MeshShaderDaylightFactor
end

local function shaderSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
	local brightness = math.Clamp( bestSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission ), 0, 1 )
	local daylight = shaderDaylightFactor()
	local litSurface = math.Clamp( ( brightness - 0.22 ) / 0.78, 0, 1 )
	local sunMix = daylight * litSurface
	local directed = brightness * ( 1 + ( shaderSunFaceFactor( faceIndex ) - 1 ) * sunMix )
	local contrast = ( directed - 0.5 ) * 1.12 + 0.5
	return math.Clamp( contrast + daylight * 0.025, 0, 1 )
end

local function shaderSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
	local brightness = math.Clamp( bestSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission ), 0, 1 )
	local daylight = shaderDaylightFactor()
	local litSurface = math.Clamp( ( brightness - 0.22 ) / 0.78, 0, 1 )
	local sunMix = daylight * litSurface
	local directed = brightness * ( 1 + ( shaderSunFaceFactor( faceIndex ) - 1 ) * sunMix )
	local contrast = ( directed - 0.5 ) * 1.12 + 0.5
	return math.Clamp( contrast + daylight * 0.025, 0, 1 )
end

local function minecraftCornerOccludersValues( bx, by, bz, faceIndex, x, y, z )
	local xs, ys, zs = cornerStep( x ), cornerStep( y ), cornerStep( z )
	if faceIndex == MC.Face.TOP or faceIndex == MC.Face.BOTTOM then
		return bx + xs, by, bz, bx, by + ys, bz, bx + xs, by + ys, bz
	elseif faceIndex == MC.Face.XP or faceIndex == MC.Face.XN then
		return bx, by + ys, bz, bx, by, bz + zs, bx, by + ys, bz + zs
	elseif faceIndex == MC.Face.YP or faceIndex == MC.Face.YN then
		return bx + xs, by, bz, bx, by, bz + zs, bx + xs, by, bz + zs
	end
	return bx, by, bz, bx, by, bz, bx, by, bz
end

local function minecraftCornerAOWithFactorsValues( bx, by, bz, faceIndex, cx0, cy0, cz0, factors )
	local s1x, s1y, s1z, s2x, s2y, s2z, cx, cy, cz = minecraftCornerOccludersValues( bx, by, bz, faceIndex, cx0, cy0, cz0 )
	local side1Blocked = cachedMeshAOSample( s1x, s1y, s1z )
	local side2Blocked = cachedMeshAOSample( s2x, s2y, s2z )
	local cornerBlocked = cachedMeshAOSample( cx, cy, cz )
	if side1Blocked and side2Blocked then return factors[3] end
	local blocked = ( side1Blocked and 1 or 0 ) + ( side2Blocked and 1 or 0 ) + ( cornerBlocked and 1 or 0 )
	return factors[blocked] or 1
end

local function minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, factors )
	local cx, cy, cz = cornerXYZ( cn )
	return minecraftCornerAOWithFactorsValues( bx, by, bz, faceIndex, cx, cy, cz, factors )
end

local function minecraftSmoothCornerAO( bx, by, bz, faceIndex, cn )
	return minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, MC_LIGHT_AO_FACTORS )
end

local function minecraftBestCornerAO( bx, by, bz, faceIndex, cn )
	return minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, MC_LIGHT_BEST_AO_FACTORS )
end

local function minecraftShaderCornerAO( bx, by, bz, faceIndex, cn )
	return minecraftCornerAOWithFactors( bx, by, bz, faceIndex, cn, MC_LIGHT_SHADER_AO_FACTORS )
end

local function minecraftSmoothCornerAOValues( bx, by, bz, faceIndex, cx, cy, cz )
	return minecraftCornerAOWithFactorsValues( bx, by, bz, faceIndex, cx, cy, cz, MC_LIGHT_AO_FACTORS )
end

local function minecraftBestCornerAOValues( bx, by, bz, faceIndex, cx, cy, cz )
	return minecraftCornerAOWithFactorsValues( bx, by, bz, faceIndex, cx, cy, cz, MC_LIGHT_BEST_AO_FACTORS )
end

local function minecraftShaderCornerAOValues( bx, by, bz, faceIndex, cx, cy, cz )
	return minecraftCornerAOWithFactorsValues( bx, by, bz, faceIndex, cx, cy, cz, MC_LIGHT_SHADER_AO_FACTORS )
end

local function shaderFaceTint( faceIndex )
	if faceIndex == MC.Face.TOP then return 1.06, 1.03, 0.94 end
	if faceIndex == MC.Face.BOTTOM then return 0.76, 0.82, 0.98 end
	if faceIndex == MC.Face.YP then return 1.02, 1.00, 0.94 end
	if faceIndex == MC.Face.XP then return 0.96, 0.99, 1.04 end
	if faceIndex == MC.Face.XN then return 0.86, 0.90, 1.02 end
	if faceIndex == MC.Face.YN then return 0.82, 0.88, 1.04 end
	return 1, 1, 1
end

local function blockReceivesSmoothAO( id )
	if MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) then return false end
	return true
end
local MeshColorObjectCache = {}
local MeshColorObjectCacheCount = 0
local MESH_COLOR_OBJECT_CACHE_LIMIT = 4096

local function resetMeshColorObjectCache()
	MeshColorObjectCache = {}
	MeshColorObjectCacheCount = 0
end

local function colorFromRGBA( r, g, b, a )
	r = r or 255
	g = g or 255
	b = b or 255
	a = a or 255
	local key = r + g * 256 + b * 65536 + a * 16777216
	local cached = MeshColorObjectCache[key]
	if cached then return cached end
	local color = Color( r, g, b, a )
	if MeshColorObjectCacheCount < MESH_COLOR_OBJECT_CACHE_LIMIT then
		MeshColorObjectCache[key] = color
		MeshColorObjectCacheCount = MeshColorObjectCacheCount + 1
	end
	return color
end

local function litFaceColorValues( shade, bx, by, bz, id, faceIndex, cn, selfEmission, style )
	style = style or MC_LIGHT_STYLE_VANILLA
	local shadeR, shadeG, shadeB, shadeA = shade.r or 255, shade.g or 255, shade.b or 255, shade.a or 255
	if not MC.SampleLighting then return shadeR, shadeG, shadeB, shadeA end
	local brightness, ao
	if style == MC_LIGHT_STYLE_FAST then
		brightness = minecraftFastCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = 1
	elseif style == MC_LIGHT_STYLE_BEST then
		brightness = bestSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = blockReceivesSmoothAO( id ) and minecraftBestCornerAO( bx, by, bz, faceIndex, cn ) or 1
	elseif style == MC_LIGHT_STYLE_SHADER then
		brightness = shaderSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = blockReceivesSmoothAO( id ) and minecraftShaderCornerAO( bx, by, bz, faceIndex, cn ) or 1
	else
		brightness = minecraftSmoothCornerBrightness( bx, by, bz, faceIndex, cn, selfEmission )
		ao = blockReceivesSmoothAO( id ) and minecraftSmoothCornerAO( bx, by, bz, faceIndex, cn ) or 1
	end
	local mul = math.Clamp( ( tonumber( brightness ) or 1 ) * ao, 0, 1 )
	local rScale, gScale, bScale = 1, 1, 1
	if style == MC_LIGHT_STYLE_SHADER then
		rScale, gScale, bScale = shaderFaceTint( faceIndex )
	end
	local r = math.Clamp( math.floor( shadeR * mul * rScale + 0.5 ), 0, 255 )
	local g = math.Clamp( math.floor( shadeG * mul * gScale + 0.5 ), 0, 255 )
	local b = math.Clamp( math.floor( shadeB * mul * bScale + 0.5 ), 0, 255 )
	local a = shadeA
	return r, g, b, a
end

local function litFaceColorMetaValues( meta, style )
	style = style or MC_LIGHT_STYLE_VANILLA
	local shadeR, shadeG, shadeB, shadeA = shadeRGBAByIndex( meta.shadeIndex )
	if not MC.SampleLighting then return shadeR, shadeG, shadeB, shadeA end
	local bx, by, bz = meta.bx, meta.by, meta.bz
	local id = meta.id
	local faceIndex = meta.faceIndex
	local cx, cy, cz = meta.cx, meta.cy, meta.cz
	local selfEmission = meta.selfEmission
	local brightness, ao
	if style == MC_LIGHT_STYLE_FAST then
		brightness = minecraftFastCornerBrightness( bx, by, bz, faceIndex, meta, selfEmission )
		ao = 1
	elseif style == MC_LIGHT_STYLE_BEST then
		brightness = bestSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
		ao = blockReceivesSmoothAO( id ) and minecraftBestCornerAOValues( bx, by, bz, faceIndex, cx, cy, cz ) or 1
	elseif style == MC_LIGHT_STYLE_SHADER then
		brightness = shaderSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
		ao = blockReceivesSmoothAO( id ) and minecraftShaderCornerAOValues( bx, by, bz, faceIndex, cx, cy, cz ) or 1
	else
		brightness = minecraftSmoothCornerBrightnessValues( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
		ao = blockReceivesSmoothAO( id ) and minecraftSmoothCornerAOValues( bx, by, bz, faceIndex, cx, cy, cz ) or 1
	end
	local mul = math.Clamp( ( tonumber( brightness ) or 1 ) * ao, 0, 1 )
	local rScale, gScale, bScale = 1, 1, 1
	if style == MC_LIGHT_STYLE_SHADER then
		rScale, gScale, bScale = shaderFaceTint( faceIndex )
	end
	local r = math.Clamp( math.floor( shadeR * mul * rScale + 0.5 ), 0, 255 )
	local g = math.Clamp( math.floor( shadeG * mul * gScale + 0.5 ), 0, 255 )
	local b = math.Clamp( math.floor( shadeB * mul * bScale + 0.5 ), 0, 255 )
	return r, g, b, shadeA
end

local function litFaceColorMeta( meta, style )
	return colorFromRGBA( litFaceColorMetaValues( meta, style ) )
end

local function litFaceColor( shade, bx, by, bz, id, faceIndex, cn, selfEmission, style )
	return colorFromRGBA( litFaceColorValues( shade, bx, by, bz, id, faceIndex, cn, selfEmission, style ) )
end

local function colorFromShadeMul( shadeR, shadeG, shadeB, shadeA, mul, rScale, gScale, bScale )
	return colorFromRGBA(
		mathClamp( mathFloor( shadeR * mul * rScale + 0.5 ), 0, 255 ),
		mathClamp( mathFloor( shadeG * mul * gScale + 0.5 ), 0, 255 ),
		mathClamp( mathFloor( shadeB * mul * bScale + 0.5 ), 0, 255 ),
		shadeA
	)
end

local function fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, cx, cy, cz, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	local key = nil
	if style ~= MC_LIGHT_STYLE_SHADER then
		key = fullCubeColorCacheKey( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
	end
	if key ~= nil then
		local cached = MeshFullCubeColorCache[key]
		if cached then return cached end
	end

	local brightness, ao
	if style == MC_LIGHT_STYLE_BEST then
		brightness = mathClamp( fullCubeSmoothCornerBrightnessFast( bx, by, bz, faceIndex, cx, cy, cz, selfEmission ), 0, 1 )
		brightness = mathClamp( brightness ^ 0.85, 0, 1 )
		ao = receiveAO ~= false and fullCubeCornerAOWithFactorsFast( bx, by, bz, faceIndex, cx, cy, cz, 0.90, 0.78, 0.66 ) or 1
	elseif style == MC_LIGHT_STYLE_SHADER then
		brightness = mathClamp( fullCubeSmoothCornerBrightnessFast( bx, by, bz, faceIndex, cx, cy, cz, selfEmission ), 0, 1 )
		brightness = mathClamp( brightness ^ 0.85, 0, 1 )
		local litSurface = mathClamp( ( brightness - 0.22 ) / 0.78, 0, 1 )
		local directed = brightness * ( 1 + ( sunFactor - 1 ) * daylight * litSurface )
		brightness = mathClamp( ( directed - 0.5 ) * 1.12 + 0.5 + daylight * 0.025, 0, 1 )
		ao = receiveAO ~= false and fullCubeCornerAOWithFactorsFast( bx, by, bz, faceIndex, cx, cy, cz, 0.94, 0.86, 0.74 ) or 1
	else
		brightness = fullCubeSmoothCornerBrightnessFast( bx, by, bz, faceIndex, cx, cy, cz, selfEmission )
		ao = receiveAO ~= false and fullCubeCornerAOWithFactorsFast( bx, by, bz, faceIndex, cx, cy, cz, 0.82, 0.68, 0.55 ) or 1
	end
	local color = colorFromShadeMul( shadeR, shadeG, shadeB, shadeA, mathClamp( brightness * ao, 0, 1 ), rScale, gScale, bScale )
	if key ~= nil then MeshFullCubeColorCache[key] = color end
	return color
end

local function fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, cx, cy, cz, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	local brightness = mathClamp( fullCubeSmoothCornerBrightnessFast( bx, by, bz, faceIndex, cx, cy, cz, selfEmission ), 0, 1 )
	brightness = mathClamp( brightness ^ 0.85, 0, 1 )
	local litSurface = mathClamp( ( brightness - 0.22 ) / 0.78, 0, 1 )
	local directed = brightness * ( 1 + ( sunFactor - 1 ) * daylight * litSurface )
	brightness = mathClamp( ( directed - 0.5 ) * 1.12 + 0.5 + daylight * 0.025, 0, 1 )
	local ao = receiveAO ~= false and fullCubeCornerAOWithFactorsFast( bx, by, bz, faceIndex, cx, cy, cz, 0.94, 0.86, 0.74 ) or 1
	return colorFromShadeMul( shadeR, shadeG, shadeB, shadeA, mathClamp( brightness * ao, 0, 1 ), rScale, gScale, bScale )
end

local function fullCubeFaceCornerColorsShader( shadeIndex, bx, by, bz, faceIndex, selfEmission, receiveAO )
	local shadeR, shadeG, shadeB, shadeA = shadeRGBAByIndex( shadeIndex )
	local rScale, gScale, bScale = shaderFaceTint( faceIndex )
	local daylight = shaderDaylightFactor()
	local sunFactor = shaderSunFaceFactor( faceIndex )
	if faceIndex == MC.Face.TOP then
		return
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.BOTTOM then
		return
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.XP then
		return
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.XN then
		return
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.YP then
		return
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	end
	return
		fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
		fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 0, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
		fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
		fullCubeCornerColorShader( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 1, selfEmission, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
end

local function fullCubeFaceCornerColors( shadeIndex, bx, by, bz, faceIndex, selfEmission, style, receiveAO )
	local shadeR, shadeG, shadeB, shadeA = shadeRGBAByIndex( shadeIndex )
	if not MC.SampleLighting then
		local color = colorFromRGBA( shadeR, shadeG, shadeB, shadeA )
		return color, color, color, color
	end
	if style == MC_LIGHT_STYLE_FAST then
		local mul = mathClamp( tonumber( minecraftFastCornerBrightnessValues( bx, by, bz, faceIndex, selfEmission ) ) or 1, 0, 1 )
		local color = colorFromShadeMul( shadeR, shadeG, shadeB, shadeA, mul, 1, 1, 1 )
		return color, color, color, color
	end
	if style == MC_LIGHT_STYLE_SHADER then
		return fullCubeFaceCornerColorsShader( shadeIndex, bx, by, bz, faceIndex, selfEmission, receiveAO )
	end
	local rScale, gScale, bScale = 1, 1, 1
	local daylight, sunFactor = 0, 1
	if faceIndex == MC.Face.TOP then
		return
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.BOTTOM then
		return
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.XP then
		return
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.XN then
		return
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	elseif faceIndex == MC.Face.YP then
		return
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 1, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
			fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 1, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
	end
	return
		fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
		fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 0, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
		fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 1, 0, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO ),
		fullCubeCornerColor( shadeR, shadeG, shadeB, shadeA, bx, by, bz, faceIndex, 0, 0, 1, selfEmission, style, rScale, gScale, bScale, daylight, sunFactor, receiveAO )
end

local function quadCornerColors( shade, bx, by, bz, id, faceIndex, corners, selfEmission, style )
	if style == MC_LIGHT_STYLE_FAST then
		local color = litFaceColor( shade, bx, by, bz, id, faceIndex, corners[1], selfEmission, style )
		return color, color, color, color
	end
	return
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[1], selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[2], selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[3], selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, corners[4], selfEmission, style )
end

local ScratchCorners = {
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ 0, 0, 0 },
	{ 0, 0, 0 },
}

local function setScratchCorner( index, x, y, z )
	local c = ScratchCorners[index]
	c[1], c[2], c[3] = x, y, z
	return c
end

local function quadCornerColorValues( shade, bx, by, bz, id, faceIndex, selfEmission, style, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	if style == MC_LIGHT_STYLE_FAST then
		local color = litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 1, x1, y1, z1 ), selfEmission, style )
		return color, color, color, color
	end
	return
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 1, x1, y1, z1 ), selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 2, x2, y2, z2 ), selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 3, x3, y3, z3 ), selfEmission, style ),
		litFaceColor( shade, bx, by, bz, id, faceIndex, setScratchCorner( 4, x4, y4, z4 ), selfEmission, style )
end

local function recolorLightMeta( meta, style )
	return litFaceColorMeta( meta, style )
end

local function recolorCachedBlockEmission( record, lightStyle, meshPerf )
	return MC.RecolorCachedBlockEmission( record, lightStyle, recolorLightMeta, meshPerf )
end

RM.minecraftSmoothCornerShadeBrightness = minecraftSmoothCornerShadeBrightness
RM.minecraftFastCornerBrightness = minecraftFastCornerBrightness
RM.minecraftFastCornerBrightnessValues = minecraftFastCornerBrightnessValues
RM.fullCubeSmoothCornerBrightnessFast = fullCubeSmoothCornerBrightnessFast
RM.fullCubeCornerAOWithFactorsFast = fullCubeCornerAOWithFactorsFast
RM.bestSmoothCornerBrightness = bestSmoothCornerBrightness
RM.bestSmoothCornerBrightnessValues = bestSmoothCornerBrightnessValues
RM.shaderSunFaceFactor = shaderSunFaceFactor
RM.shaderDaylightFactor = shaderDaylightFactor
RM.shaderSmoothCornerBrightness = shaderSmoothCornerBrightness
RM.shaderSmoothCornerBrightnessValues = shaderSmoothCornerBrightnessValues
RM.minecraftCornerOccludersValues = minecraftCornerOccludersValues
RM.minecraftCornerAOWithFactorsValues = minecraftCornerAOWithFactorsValues
RM.minecraftCornerAOWithFactors = minecraftCornerAOWithFactors
RM.minecraftSmoothCornerAO = minecraftSmoothCornerAO
RM.minecraftBestCornerAO = minecraftBestCornerAO
RM.minecraftShaderCornerAO = minecraftShaderCornerAO
RM.minecraftSmoothCornerAOValues = minecraftSmoothCornerAOValues
RM.minecraftBestCornerAOValues = minecraftBestCornerAOValues
RM.minecraftShaderCornerAOValues = minecraftShaderCornerAOValues
RM.shaderFaceTint = shaderFaceTint
RM.resetMeshColorObjectCache = resetMeshColorObjectCache
RM.colorFromRGBA = colorFromRGBA
RM.litFaceColorValues = litFaceColorValues
RM.litFaceColorMetaValues = litFaceColorMetaValues
RM.litFaceColorMeta = litFaceColorMeta
RM.litFaceColor = litFaceColor
RM.colorFromShadeMul = colorFromShadeMul
RM.fullCubeCornerColor = fullCubeCornerColor
RM.fullCubeCornerColorShader = fullCubeCornerColorShader
RM.fullCubeFaceCornerColorsShader = fullCubeFaceCornerColorsShader
RM.fullCubeFaceCornerColors = fullCubeFaceCornerColors
RM.quadCornerColors = quadCornerColors
RM.quadCornerColorValues = quadCornerColorValues
RM.recolorLightMeta = recolorLightMeta
RM.recolorCachedBlockEmission = recolorCachedBlockEmission
