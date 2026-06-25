-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local mathClamp, mathFloor = math.Clamp, math.floor
local LIGHTMAP_TEXTURE_SIZE = RM.LIGHTMAP_TEXTURE_SIZE
local MC_LIGHTMAP_BLOCK_FACTOR = RM.MC_LIGHTMAP_BLOCK_FACTOR
local MC_LIGHTMAP_SKY_FACTOR = RM.MC_LIGHTMAP_SKY_FACTOR
local MC_LIGHTMAP_BLOCK_TINT_R = RM.MC_LIGHTMAP_BLOCK_TINT_R
local MC_LIGHTMAP_BLOCK_TINT_G = RM.MC_LIGHTMAP_BLOCK_TINT_G
local MC_LIGHTMAP_BLOCK_TINT_B = RM.MC_LIGHTMAP_BLOCK_TINT_B
local MC_LIGHTMAP_SKY_R = RM.MC_LIGHTMAP_SKY_R
local MC_LIGHTMAP_SKY_G = RM.MC_LIGHTMAP_SKY_G
local MC_LIGHTMAP_SKY_B = RM.MC_LIGHTMAP_SKY_B

local MeshLightmapTexture = nil
local MeshLightmapTextureDirty = true
local blockLightFlicker = 0
local MeshLightmapNextFlickerTick = 0
local USER_LIGHTMAP_BASE_SCALE = 0.8

local function sourceLightmapScaleCompensation()
	-- SetLightmapTexture binds this render target directly as a user lightmap.
	-- It is not a BSP lightmap page, so do not apply Source's baked-lightmap HDR/LDR storage scale here.
	return USER_LIGHTMAP_BASE_SCALE
end

local function mcLightmapBrightnessCurve( level )
	level = mathClamp( tonumber( level ) or 0, 0, 1 )
	return level / ( 4 - 3 * level )
end

local function parabolicMixFactor( level )
	level = mathClamp( tonumber( level ) or 0, 0, 1 )
	local x = 2 * level - 1
	return x * x
end

local function mcLightmapNotGamma( r, g, b )
	local maxComponent = math.max( r, g, b )
	if maxComponent <= 0 then return 0, 0, 0 end
	local maxInverted = 1 - maxComponent
	local maxScaled = 1 - maxInverted * maxInverted * maxInverted * maxInverted
	local scale = maxScaled / maxComponent
	return r * scale, g * scale, b * scale
end

local function meshLightmapFloatCVar( cv, fallback, minValue, maxValue )
	local value = cv and cv.GetFloat and cv:GetFloat() or fallback
	value = tonumber( value ) or fallback
	if minValue ~= nil and value < minValue then value = minValue end
	if maxValue ~= nil and value > maxValue then value = maxValue end
	return value
end

local function meshLightmapColorCVar( cv, defaultR, defaultG, defaultB )
	local value = cv and cv.GetString and tostring( cv:GetString() or "" ) or ""
	local hex = value:match( "^%s*#?(%x%x)(%x%x)(%x%x)%s*$" )
	if hex then
		local r, g, b = value:match( "^%s*#?(%x%x)(%x%x)(%x%x)%s*$" )
		return tonumber( r, 16 ) / 255, tonumber( g, 16 ) / 255, tonumber( b, 16 ) / 255
	end
	local values = {}
	for numberText in value:gmatch( "[-+]?%d*%.?%d+" ) do
		values[#values + 1] = tonumber( numberText )
		if #values >= 3 then break end
	end
	if #values >= 3 then
		local scale = ( values[1] > 1 or values[2] > 1 or values[3] > 1 ) and 255 or 1
		return mathClamp( values[1] / scale, 0, 1 ),
			mathClamp( values[2] / scale, 0, 1 ),
			mathClamp( values[3] / scale, 0, 1 )
	end
	return defaultR, defaultG, defaultB
end

local function meshLightmapLevel01( level )
	return mathClamp( tonumber( level ) or 0, 0, 15 ) / 15
end

local function meshLightmapBrightnessByte( block, sky )
	local ambientScale = meshLightmapFloatCVar( MC.MeshLightmapAmbientScale, 1, 0, nil )
	local exposure = meshLightmapFloatCVar( MC.MeshLightmapExposure, 1, 0, nil ) * sourceLightmapScaleCompensation()
	local skyFactor = meshLightmapFloatCVar( MC.MeshLightmapSkyFactor, MC_LIGHTMAP_SKY_FACTOR, 0, nil )
	local brightnessFactor = meshLightmapFloatCVar( MC.MeshLightmapBrightnessFactor, 0, 0, 1 )
	local nightVisionFactor = meshLightmapFloatCVar( MC.MeshLightmapNightVisionFactor, 0, 0, 1 )
	local darknessScale = meshLightmapFloatCVar( MC.MeshLightmapDarknessScale, 0, 0, 1 )
	local bossOverlayWorldDarkeningFactor = meshLightmapFloatCVar( MC.MeshLightmapBossDarkening, 0, 0, 1 )
	local blockFactor = MC_LIGHTMAP_BLOCK_FACTOR + blockLightFlicker
	blockFactor = math.max( blockFactor, 0 )
	local ambientColorR, ambientColorG, ambientColorB = meshLightmapColorCVar( MC.MeshLightmapAmbientColor, 0, 0, 0 )
	local nightVisionColorR, nightVisionColorG, nightVisionColorB = meshLightmapColorCVar( MC.MeshLightmapNightVisionColor, 153 / 255, 153 / 255, 153 / 255 )
	local blockLightTintR, blockLightTintG, blockLightTintB = meshLightmapColorCVar(
		MC.MeshLightmapBlockTint, MC_LIGHTMAP_BLOCK_TINT_R, MC_LIGHTMAP_BLOCK_TINT_G, MC_LIGHTMAP_BLOCK_TINT_B
	)
	local skyLightColorR, skyLightColorG, skyLightColorB = meshLightmapColorCVar(
		MC.MeshLightmapSkyColor, MC_LIGHTMAP_SKY_R, MC_LIGHTMAP_SKY_G, MC_LIGHTMAP_SKY_B
	)
	ambientColorR = mathClamp( ambientColorR * ambientScale, 0, 1 )
	ambientColorG = mathClamp( ambientColorG * ambientScale, 0, 1 )
	ambientColorB = mathClamp( ambientColorB * ambientScale, 0, 1 )
	local blockLevel = meshLightmapLevel01( block )
	local skyLevel = meshLightmapLevel01( sky )
	local blockBrightness = mcLightmapBrightnessCurve( blockLevel ) * blockFactor
	local skyBrightness = mcLightmapBrightnessCurve( skyLevel ) * skyFactor
	local blockTintMix = 0.9 * parabolicMixFactor( blockLevel )
	local blockR = blockLightTintR + ( 1 - blockLightTintR ) * blockTintMix
	local blockG = blockLightTintG + ( 1 - blockLightTintG ) * blockTintMix
	local blockB = blockLightTintB + ( 1 - blockLightTintB ) * blockTintMix
	local r = math.max( ambientColorR, nightVisionColorR * nightVisionFactor )
	local g = math.max( ambientColorG, nightVisionColorG * nightVisionFactor )
	local b = math.max( ambientColorB, nightVisionColorB * nightVisionFactor )
	r = r + skyLightColorR * skyBrightness + blockR * blockBrightness
	g = g + skyLightColorG * skyBrightness + blockG * blockBrightness
	b = b + skyLightColorB * skyBrightness + blockB * blockBrightness
	r = r + ( r * 0.7 - r ) * bossOverlayWorldDarkeningFactor
	g = g + ( g * 0.6 - g ) * bossOverlayWorldDarkeningFactor
	b = b + ( b * 0.6 - b ) * bossOverlayWorldDarkeningFactor
	r, g, b = r - darknessScale, g - darknessScale, b - darknessScale
	r, g, b = mathClamp( r, 0, 1 ), mathClamp( g, 0, 1 ), mathClamp( b, 0, 1 )
	local gammaR, gammaG, gammaB = mcLightmapNotGamma( r, g, b )
	r = mathClamp( ( r + ( gammaR - r ) * brightnessFactor ) * exposure, 0, 1 )
	g = mathClamp( ( g + ( gammaG - g ) * brightnessFactor ) * exposure, 0, 1 )
	b = mathClamp( ( b + ( gammaB - b ) * brightnessFactor ) * exposure, 0, 1 )
	return mathFloor( r * 255 + 0.5 ), mathFloor( g * 255 + 0.5 ), mathFloor( b * 255 + 0.5 )
end

local function meshLightmapSmoothCoordLevel( pixel )
	local coord = mathClamp( ( tonumber( pixel ) or 0 ) - 8, 0, 240 )
	return coord
end

local function ensureMeshLightmapTexture()
	if MeshLightmapTexture then return MeshLightmapTexture end
	if GetRenderTarget then
		MeshLightmapTexture = GetRenderTarget( "mc_mesh_lightmap_256", LIGHTMAP_TEXTURE_SIZE, LIGHTMAP_TEXTURE_SIZE )
	end
	return MeshLightmapTexture
end

local MC_LIGHTMAP_TEXTURE_HELPERS = ( function()
	local helpers = {}
	local externalMaterial = nil
	local externalTexture = nil
	local externalPath = nil

	local function meshLightmapSource()
		local cv = MC.MeshLightmapSource
		return string.lower( tostring( cv and cv.GetString and cv:GetString() or "generated" ) )
	end

	local function externalMeshLightmapAllowed()
		local cv = MC.MeshLightmapAllowExternal
		return cv and cv.GetBool and cv:GetBool() == true
	end

	local function meshLightmapImagePath()
		local cv = MC.MeshLightmapImage
		local path = tostring( cv and cv.GetString and cv:GetString() or "mc/lightmap.png" )
		path = path:gsub( "\\", "/" )
		path = path:gsub( "%.vmt$", "" )
		if path == "" then path = "mc/lightmap.png" end
		if not string.find( path, "%.%w+$" ) then path = path .. ".png" end
		return path
	end

	local function clearExternalMeshLightmapTexture()
		externalMaterial = nil
		externalTexture = nil
		externalPath = nil
	end

	local function externalMeshLightmapMaterial()
		if not externalMeshLightmapAllowed() then return nil end
		local source = meshLightmapSource()
		if source ~= "image" and source ~= "png" and source ~= "external" then return nil end
		if not Material then return nil end
		local path = meshLightmapImagePath()
		if externalPath ~= path then
			externalPath = path
			externalMaterial = nil
			externalTexture = nil
		end
		if externalMaterial then return externalMaterial end
		local mat = Material( path, "noclamp smooth" )
		if not mat or ( mat.IsError and mat:IsError() ) then return nil end
		local tex = mat.GetTexture and mat:GetTexture( "$basetexture" ) or nil
		if not tex or ( tex.IsError and tex:IsError() ) then return nil end
		externalMaterial = mat
		externalTexture = tex
		return mat
	end

	local function externalMeshLightmapTexture()
		local mat = externalMeshLightmapMaterial()
		if not mat then return nil end
		return externalTexture
	end

	helpers.clearExternalMeshLightmapTexture = clearExternalMeshLightmapTexture
	helpers.externalMeshLightmapAllowed = externalMeshLightmapAllowed
	helpers.externalMeshLightmapMaterial = externalMeshLightmapMaterial
	helpers.externalMeshLightmapTexture = externalMeshLightmapTexture
	return helpers
end )()

function MC.RefreshMeshLightmapTexture()
	local tex = ensureMeshLightmapTexture()
	if not tex or not render or not surface or not cam then return tex end
	local externalMaterial = MC_LIGHTMAP_TEXTURE_HELPERS.externalMeshLightmapMaterial()
	local compensation = mathClamp( sourceLightmapScaleCompensation(), 0, 1 )
	local compensationByte = mathFloor( compensation * 255 + 0.5 )
	render.PushRenderTarget( tex )
		render.Clear( 0, 0, 0, 255, true, true )
		cam.Start2D()
			if externalMaterial then
				surface.SetMaterial( externalMaterial )
				surface.SetDrawColor( compensationByte, compensationByte, compensationByte, 255 )
				surface.DrawTexturedRect( 0, 0, LIGHTMAP_TEXTURE_SIZE, LIGHTMAP_TEXTURE_SIZE )
			else
				for y = 0, LIGHTMAP_TEXTURE_SIZE - 1 do
					local skyCoord = meshLightmapSmoothCoordLevel( y )
					for x = 0, LIGHTMAP_TEXTURE_SIZE - 1 do
						local blockCoord = meshLightmapSmoothCoordLevel( x )
						local r, g, b = meshLightmapBrightnessByte( blockCoord / 16, skyCoord / 16 )
						surface.SetDrawColor( r, g, b, 255 )
						surface.DrawRect( x, y, 1, 1 )
					end
				end
			end
		cam.End2D()
	render.PopRenderTarget()
	MeshLightmapTextureDirty = false
	return tex
end

local function markMeshLightmapTextureDirty()
	MeshLightmapTextureDirty = true
end

local function tickMeshLightmapBlockFlicker()
	local cv = MC.MeshLightmapBlockFlicker
	if cv and cv.GetBool and not cv:GetBool() then return end
	local now = CurTime and CurTime() or SysTime()
	if now < MeshLightmapNextFlickerTick then return end
	MeshLightmapNextFlickerTick = now + 0.05
	blockLightFlicker = blockLightFlicker
		+ ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * math.Rand( 0, 1 ) * math.Rand( 0, 1 ) * 0.1
	blockLightFlicker = blockLightFlicker * 0.9
	markMeshLightmapTextureDirty()
end

function MC.GetMeshLightmapTexture()
	tickMeshLightmapBlockFlicker()
	if MeshLightmapTextureDirty or not MeshLightmapTexture then
		return MC.RefreshMeshLightmapTexture()
	end
	return MeshLightmapTexture
end

function MC.PushMeshLightmapLinearFilter()
	if not render then return false, false end
	local linear = TEXFILTER and TEXFILTER.LINEAR or 2
	local pushedMin, pushedMag = false, false
	if render.PushFilterMin then
		render.PushFilterMin( linear )
		pushedMin = true
	end
	if render.PushFilterMag then
		render.PushFilterMag( linear )
		pushedMag = true
	end
	return pushedMin, pushedMag
end

function MC.PopMeshLightmapLinearFilter( pushedMin, pushedMag )
	if not render then return end
	if pushedMag and render.PopFilterMag then render.PopFilterMag() end
	if pushedMin and render.PopFilterMin then render.PopFilterMin() end
end

local function markLoadedMeshesDirtyForLightmapFormat()
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and chunk.count and chunk.count > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
		end
	end
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_debug_full_cube_only", function()
		markLoadedMeshesDirtyForLightmapFormat()
	end, "mc_mesh_debug_full_cube_only_rebuild" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_uv", function()
		markLoadedMeshesDirtyForLightmapFormat()
	end, "mc_mesh_lightmap_uv_rebuild" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_source", function()
		MC_LIGHTMAP_TEXTURE_HELPERS.clearExternalMeshLightmapTexture()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_source_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_image", function()
		MC_LIGHTMAP_TEXTURE_HELPERS.clearExternalMeshLightmapTexture()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_image_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_allow_external", function()
		MC_LIGHTMAP_TEXTURE_HELPERS.clearExternalMeshLightmapTexture()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_allow_external_refresh" )
	cvars.AddChangeCallback( "mat_hdr_level", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_hdr_scale_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_exposure", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_exposure_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_ambient_scale", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_ambient_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_sky_factor", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_sky_factor_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_brightness_factor", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_brightness_factor_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_block_flicker", function()
		blockLightFlicker = 0
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_block_flicker_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_night_vision_factor", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_night_vision_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_darkness_scale", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_darkness_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_boss_darkening", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_boss_darkening_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_block_tint", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_block_tint_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_sky_color", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_sky_color_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_ambient_color", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_ambient_color_refresh" )
	cvars.AddChangeCallback( "mc_mesh_lightmap_night_vision_color", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_night_vision_color_refresh" )
	cvars.AddChangeCallback( "mc_light_ambient_min", function()
		markMeshLightmapTextureDirty()
	end, "mc_mesh_lightmap_light_ambient_refresh" )
end

RM.markLoadedMeshesDirtyForLightmapFormat = markLoadedMeshesDirtyForLightmapFormat
RM.markMeshLightmapTextureDirty = markMeshLightmapTextureDirty
RM.sourceLightmapScaleCompensation = sourceLightmapScaleCompensation
