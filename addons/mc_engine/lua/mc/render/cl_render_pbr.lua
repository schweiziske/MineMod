-- Per-view PBR constants, shared by immutable materials. No per-chunk state.
MC = MC or {}
local B = MC.RenderPBR or { materials = {}, materialCount = 0,
	stats = { views = 0, cameraWrites = 0, lightingWrites = 0 } }
MC.RenderPBR = B
local requireValue = MC.RenderL2Resources.Require
local sqrt, min, max, abs = math.sqrt, math.min, math.max, math.abs
local exposure = CreateClientConVar( "mc_pbr_exposure", "1", true, false, "PBR exposure before tone mapping", 0.05, 8 )
local strength = CreateClientConVar( "mc_pbr_sun_strength", "2.5", true, false, "PBR direct solar radiance", 0, 8 )
local environment = CreateClientConVar( "mc_pbr_environment", "1", true, false, "PBR specular IBL intensity", 0, 4 )
local lightingKeys = { "$c1_w", "$c2_x", "$c2_y", "$c2_z", "$c2_w", "$c3_x", "$c3_y", "$c3_z", "$c3_w" }
local values = { 1, 0, 0, 1, 2.5, 1, 1, 1, 1 }
local eyeX, eyeY, eyeZ, lastFrame = 0, 0, 0, nil
local eyeRevision = ( B.eyeRevision or 0 ) + 1
local lightRevision = ( B.lightRevision or 0 ) + 1
local shadowRevision = ( B.shadowRevision or 0 ) + 1
local shadowTexture, shadowMatrix, shadowBias, shadowStrength = nil, nil, 0, 0
B.eyeRevision, B.lightRevision, B.shadowRevision = eyeRevision, lightRevision, shadowRevision
B.stats.shadowWrites = B.stats.shadowWrites or 0
local settingsDirty = true

local function settingsChanged() settingsDirty = true end
for _, name in ipairs( { "mc_pbr_exposure", "mc_pbr_sun_strength", "mc_pbr_environment", "mc_daycycle_sun_tilt" } ) do
	cvars.AddChangeCallback( name, settingsChanged, "mc_l2_pbr" )
end

function B.Parameters( params, maps )
	params["$c0_x"], params["$c0_y"] = "0", "0"
	params["$linearread_texture2"], params["$linearwrite"] = 0, 0
	params["$texture3"], params["$texture4"] = maps.normal:GetName(), maps.orm:GetName()
	params["$linearread_texture3"], params["$linearread_texture4"] = 1, 1
	params["$texture5"], params["$linearread_texture5"] = "vgui/white", 1
	if maps.environment then
		params["$texture6"], params["$texture7"] = maps.environment:GetName(), maps.dfg:GetName()
		params["$linearread_texture6"], params["$linearread_texture7"] = 1, 1
	end
	params["$c1_x"], params["$c1_y"], params["$c1_z"] = "0", "0", "0"
	for i = 1, #lightingKeys do params[lightingKeys[i]] = tostring( values[i] ) end
end

function B.Register( material )
	requireValue( type( MC.DayCycleSunComponents ) == "function" and type( FrameNumber ) == "function"
		and MC.DayCycleSunTilt and MC.DayCycleSunTilt.GetFloat,
		"render_pbr_daycycle", "PBR requires the scalar day-cycle provider and frame clock" )
	if B.materials[material] then return end
	B.materials[material] = { eyeRevision = -1, lightRevision = -1, shadowRevision = -1 }
	B.materialCount = B.materialCount + 1
end

function B.PrepareView( x, y, z )
	if B.materialCount == 0 then return end
	B.stats.views = B.stats.views + 1
	if x ~= eyeX or y ~= eyeY or z ~= eyeZ then
		eyeX, eyeY, eyeZ = x, y, z
		eyeRevision = eyeRevision + 1
		B.eyeRevision = eyeRevision
	end
	local frame = FrameNumber()
	if frame == lastFrame and not settingsDirty then return end
	lastFrame, settingsDirty = frame, false
	local sx, sy, sz, elevation = MC.DayCycleSunComponents()
	local tilt = MC.DayCycleSunTilt:GetFloat()
	sy = sy - tilt
	local inverseLength = 1 / sqrt( sx * sx + sy * sy + sz * sz )
	sx, sy, sz = sx * inverseLength, sy * inverseLength, sz * inverseLength
	local horizon = max( 0, 1 - abs( elevation ) / 0.35 )
	local direct = strength:GetFloat() * min( 1, max( 0, elevation / 0.08 ) )
	local ev, env = exposure:GetFloat(), environment:GetFloat()
	local green, blue = 1 - 0.32 * horizon, 1 - 0.57 * horizon
	if values[1] ~= ev or values[2] ~= sx or values[3] ~= sy or values[4] ~= sz
		or values[5] ~= direct or values[7] ~= green or values[8] ~= blue or values[9] ~= env then
		values[1], values[2], values[3], values[4], values[5] = ev, sx, sy, sz, direct
		values[7], values[8], values[9] = green, blue, env
		lightRevision = lightRevision + 1
		B.lightRevision = lightRevision
	end
end

function B.SunComponents()
	return values[2], values[3], values[4], values[5]
end

function B.SunEnabled()
	local _, _, _, elevation = MC.DayCycleSunComponents()
	return strength:GetFloat() > 0 and elevation > 0
end

-- PrepareView refreshes these with the same exposure and solar colour used
-- by surface materials. Return scalar radiance; do not allocate per view.
function B.AtmosphereSun()
	local radiance = values[5] * values[1]
	return values[6] * radiance, values[7] * radiance, values[8] * radiance
end

-- A publication follows a complete map render. The reused Matrix may have
-- changed in place, so its identity is deliberately not used as a revision.
function B.PublishShadow( texture, matrix, bias, weight )
	shadowTexture, shadowMatrix, shadowBias, shadowStrength = texture, matrix, bias, weight
	shadowRevision = shadowRevision + 1
	B.shadowRevision = shadowRevision
end

function B.DisableShadow()
	if shadowStrength == 0 then return end
	shadowStrength = 0
	shadowRevision = shadowRevision + 1
	B.shadowRevision = shadowRevision
end

-- A secondary RenderView can replace the shared shadow atlas between render
-- hooks. Prepare at the receiver draw boundary, before any mesh/pass state is
-- pushed, so this view's camera and shadow coverage are restored together.
function B.PrepareDraw( x, y, z, view, depthOnly )
	local shadows = MC.RenderPBRShadows
	if shadows and shadows.rendering then return false end
	B.PrepareView( x, y, z )
	-- The shadow pass is registered after the PBR material provider. Materials
	-- also support use without that pass, with their shadow strength at zero.
	if B.materialCount > 0 and shadows and not depthOnly then shadows.Update( x, y, z, view ) end
	-- The shadow render may have drawn a secondary view. Upload moving lights
	-- afterwards, before any caller pushes draw/filter/depth state. Vanilla also
	-- reaches this boundary even when there are no PBR materials.
	-- A reported local-light upload failure disables only the extra draw. The
	-- base world must remain visible; strict faults still propagate normally.
	if not depthOnly then MC.RenderDynamicLights.Prepare( x, y, z ) end
	return true
end

function B.PrepareCurrentView( depthOnly )
	local view = render.GetViewSetup and render.GetViewSetup( true )
	local eye = view and view.origin or EyePos()
	return B.PrepareDraw( eye.x, eye.y, eye.z, view, depthOnly )
end

function B.Bind( material )
	local state = B.materials[material]
	if not state then return end
	if state.eyeRevision ~= eyeRevision then
		material:SetFloat( "$c1_x", eyeX )
		material:SetFloat( "$c1_y", eyeY )
		material:SetFloat( "$c1_z", eyeZ )
		state.eyeRevision = eyeRevision
		B.stats.cameraWrites = B.stats.cameraWrites + 3
	end
	if state.lightRevision ~= lightRevision then
		for i = 1, #lightingKeys do material:SetFloat( lightingKeys[i], values[i] ) end
		state.lightRevision = lightRevision
		B.stats.lightingWrites = B.stats.lightingWrites + #lightingKeys
	end
	if state.shadowRevision ~= shadowRevision then
		material:SetFloat( "$c0_x", shadowBias )
		material:SetFloat( "$c0_y", shadowStrength )
		if shadowStrength > 0 then
			material:SetTexture( "$texture5", shadowTexture )
			material:SetMatrix( "$viewprojmat", shadowMatrix )
		end
		state.shadowRevision = shadowRevision
		B.stats.shadowWrites = B.stats.shadowWrites + ( shadowStrength > 0 and 4 or 2 )
	end
end

concommand.Add( "mc_pbr_stats", function()
	print( string.format( "[MC PBR] materials=%d views=%d cameraFloatWrites=%d lightingFloatWrites=%d shadowWrites=%d; GPU timing unmeasured",
		B.materialCount, B.stats.views, B.stats.cameraWrites, B.stats.lightingWrites, B.stats.shadowWrites ) )
end )
