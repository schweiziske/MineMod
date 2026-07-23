-- Minecraft voxel lighting for Source-rendered players and prop models.
-- Opt-in because replacing prop RenderOverride can interact with other addons.
MC = MC or {}

MC.EntityLightingEnabled = MC.EntityLightingEnabled or CreateClientConVar(
	"mc_entity_lighting", "1", true, false,
	"Apply interpolated Minecraft lighting to players and common prop models"
)
MC.EntityLightingPlayers = MC.EntityLightingPlayers or CreateClientConVar(
	"mc_entity_lighting_players", "0", true, false,
	"Apply Minecraft entity lighting to players"
)
MC.EntityLightingProps = MC.EntityLightingProps or CreateClientConVar(
	"mc_entity_lighting_props", "1", true, false,
	"Apply Minecraft entity lighting to common prop classes"
)
MC.EntityLightingVehicles = MC.EntityLightingVehicles or CreateClientConVar(
	"mc_entity_lighting_vehicles", "1", true, false,
	"Apply Minecraft entity lighting to standard Source vehicle classes"
)
MC.EntityLightingGain = MC.EntityLightingGain or CreateClientConVar(
	"mc_entity_lighting_gain", "0.48", true, false,
	"Exposure multiplier for Minecraft-lit Source entities"
)
MC.EntityLightingReflections = MC.EntityLightingReflections or CreateClientConVar(
	"mc_entity_lighting_reflections", "0.35", true, false,
	"Reflection strength for Minecraft-lit entities; also scales with sampled brightness"
)
MC.EntityLightingInterval = MC.EntityLightingInterval or CreateClientConVar(
	"mc_entity_lighting_interval", "0.10", true, false,
	"Seconds between expensive voxel-light samples per entity; 0 updates every draw"
)
MC.EntityLightingPlayerGamma = MC.EntityLightingPlayerGamma or CreateClientConVar(
	"mc_entity_lighting_player_gamma", "2.2", true, false,
	"Display-to-linear conversion exponent for Source player ambient-cube lighting"
)

local PROP_CLASSES = {
	prop_physics = true,
	prop_physics_multiplayer = true,
	prop_dynamic = true,
	prop_dynamic_override = true,
	prop_ragdoll = true,
}
local VEHICLE_CLASSES = {
	prop_vehicle_jeep = true,
	prop_vehicle_airboat = true,
	prop_vehicle_prisoner_pod = true,
}

local previousWrappedProps = MC.EntityLightingWrappedProps
local wrappedProps = setmetatable( {}, { __mode = "k" } )
MC.EntityLightingWrappedProps = wrappedProps
local lightStates = setmetatable( {}, { __mode = "k" } )
local playerSourceDrawActive = false
local nextPropScan = 0

local function enabled()
	return MC.EntityLightingEnabled and MC.EntityLightingEnabled:GetBool()
end

local function playersEnabled()
	return enabled() and MC.EntityLightingPlayers and MC.EntityLightingPlayers:GetBool()
end

local function propsEnabled()
	return enabled() and MC.EntityLightingProps and MC.EntityLightingProps:GetBool()
end

local function vehiclesEnabled()
	return enabled() and MC.EntityLightingVehicles and MC.EntityLightingVehicles:GetBool()
end

local function entityClassEnabled( ent )
	if not IsValid( ent ) then return false end
	local class = ent:GetClass()
	return PROP_CLASSES[class] and propsEnabled()
		or VEHICLE_CLASSES[class] and vehiclesEnabled()
end

local function gain()
	return math.Clamp( MC.EntityLightingGain and MC.EntityLightingGain:GetFloat() or 0.48, 0, 1 )
end

local function reflectionStrength()
	return math.Clamp( MC.EntityLightingReflections and MC.EntityLightingReflections:GetFloat() or 0.35, 0, 1 )
end

local function playerLightingGamma()
	return math.Clamp( MC.EntityLightingPlayerGamma and MC.EntityLightingPlayerGamma:GetFloat() or 2.2, 1, 4 )
end

local function sampleInterval()
	return math.Clamp( MC.EntityLightingInterval and MC.EntityLightingInterval:GetFloat() or 0.10, 0, 2 )
end

local function samplePosition( ent, player )
	if player and ent.EyePos then return ent:EyePos() end
	local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
	return ent:LocalToWorld( Vector(
		( mins.x + maxs.x ) * 0.5,
		( mins.y + maxs.y ) * 0.5,
		mins.z + ( maxs.z - mins.z ) * 0.65
	) )
end

local function sampledRGB( ent, player )
	local now = CurTime()
	local state = lightStates[ent]
	if not state then
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then
			r, g, b = MC.SampleDynamicLightingRGB( samplePosition( ent, player ), 0 )
		end
		local interval = sampleInterval()
		local phase = interval > 0 and ( ( ent:EntIndex() % 7 ) / 7 ) * interval or 0
		state = {
			r = r, g = g, b = b,
			targetR = r, targetG = g, targetB = b,
			nextSample = now + interval + phase,
			lastUpdate = now,
		}
		lightStates[ent] = state
	else
		local interval = sampleInterval()
		if interval <= 0 or now >= ( state.nextSample or 0 ) then
			local r, g, b = 1, 1, 1
			if MC.SampleDynamicLightingRGB then
				r, g, b = MC.SampleDynamicLightingRGB( samplePosition( ent, player ), 0 )
			end
			state.targetR, state.targetG, state.targetB = r, g, b
			state.nextSample = now + interval
		end
		local dt = math.Clamp( now - ( state.lastUpdate or now ), 0, 0.1 )
		state.lastUpdate = now
		local blend = 1 - math.exp( -math.Clamp( dt, 0, 0.1 ) * 12 )
		state.r = Lerp( blend, state.r, state.targetR or state.r )
		state.g = Lerp( blend, state.g, state.targetG or state.g )
		state.b = Lerp( blend, state.b, state.targetB or state.b )
	end
	local mul = gain()
	return state.r * mul, state.g * mul, state.b * mul
end

local function dampMaterialReflections( ent, r, g, b )
	if not ( ent.GetMaterials and Material ) then return nil end
	local factor = math.Clamp( math.max( r, g, b ) * reflectionStrength(), 0, 1 )
	local states = {}
	for _, name in ipairs( ent:GetMaterials() or {} ) do
		local mat = Material( name )
		if mat and not mat:IsError() then
			local envTint = mat:GetVector( "$envmaptint" )
			-- Some IMaterial getters return zero values (not one nil value) when a
			-- parameter is absent. Assignment normalizes that case to nil before
			-- tonumber is called.
			local rawPhongBoost = mat:GetFloat( "$phongboost" )
			local phongBoost = rawPhongBoost ~= nil and tonumber( rawPhongBoost ) or nil
			local state = { mat = mat, phongBoost = phongBoost }
			if envTint then
				state.envTint = Vector( envTint.x, envTint.y, envTint.z )
				mat:SetVector( "$envmaptint", envTint * factor )
			end
			-- Many camera/weapon materials do not define $phongboost; GMod then
			-- returns nil rather than zero. Leave absent shader parameters alone.
			if phongBoost ~= nil then mat:SetFloat( "$phongboost", phongBoost * factor ) end
			states[#states + 1] = state
		end
	end
	return states
end

local function restoreMaterialReflections( states )
	for _, state in ipairs( states or {} ) do
		local mat = state.mat
		if mat and not mat:IsError() then
			if state.envTint then mat:SetVector( "$envmaptint", state.envTint ) end
			if state.phongBoost ~= nil then mat:SetFloat( "$phongboost", state.phongBoost ) end
		end
	end
end

local function beginModelLighting( ent, player )
	local r, g, b = sampledRGB( ent, player )
	-- Inspect/material parameters before changing global render state. If an
	-- unusual addon material errors, it cannot leave the whole frame fullbright.
	local materialState = dampMaterialReflections( ent, r, g, b )
	-- Source refreshes/caches static model lighting when a prop comes to rest.
	-- Combining that cache with a custom ambient cube can suddenly double-light
	-- a stationary prop. Suppress the engine contribution, then explicitly
	-- multiply the fullbright model by our bounded voxel-light RGB.
	render.SuppressEngineLighting( true )
	render.SetColorModulation( r, g, b )
	return materialState
end

local function endModelLighting( materialState )
	restoreMaterialReflections( materialState )
	render.SetColorModulation( 1, 1, 1 )
	render.SuppressEngineLighting( false )
end

-- Source StudioModel lighting: an ambient cube sampled at a lighting origin.
-- Draw immediately in PrePlayerDraw so the cube cannot be replaced before the
-- model call. No color modulation, stencil, blend override or fullbright mode.
local function drawPlayerWithSourceLighting( ply )
	local r, g, b = sampledRGB( ply, true )
	-- SampleDynamicLightingRGB is also used as a display/vertex-color multiplier
	-- by held items and particles. Source's ambient cube consumes linear HDR
	-- intensity instead, so feeding 0.48 directly appears roughly 70% bright.
	-- Convert the sampled display values to linear before setting model light.
	local gamma = playerLightingGamma()
	r, g, b = r ^ gamma, g ^ gamma, b ^ gamma
	render.SetLightingOrigin( samplePosition( ply, true ) )
	render.SetLocalModelLights() -- remove unrelated Source local lights
	render.ResetModelLighting( r, g, b ) -- sets all six ambient-cube faces
	playerSourceDrawActive = true
	local ok, err = pcall( ply.DrawModel, ply )
	playerSourceDrawActive = false
	render.ResetModelLighting( 1, 1, 1 )
	if not ok then ErrorNoHalt( "[MC] player Source lighting draw failed: " .. tostring( err ) .. "\n" ) end
end

local function drawWrappedProp( ent, oldOverride, ... )
	local materialState = beginModelLighting( ent, false )
	local ok, err
	if oldOverride then
		ok, err = pcall( oldOverride, ent, ... )
	else
		ok, err = pcall( ent.DrawModel, ent, ... )
	end
	endModelLighting( materialState )
	if not ok then ErrorNoHalt( "[MC] entity lighting draw failed: " .. tostring( err ) .. "\n" ) end
end

local function unwrapProp( ent )
	local record = wrappedProps[ent]
	if not record then return end
	if IsValid( ent ) and ent.RenderOverride == record.wrapper then
		ent.RenderOverride = record.oldOverride
	end
	wrappedProps[ent] = nil
	lightStates[ent] = nil
end

local function wrapProp( ent )
	if not IsValid( ent ) then return end
	local class = ent:GetClass()
	if not ( PROP_CLASSES[class] or VEHICLE_CLASSES[class] ) then return end
	if wrappedProps[ent] then return end
	-- Sandbox temporarily owns RenderOverride while its spawn effect clips and
	-- refracts the new prop. Let it restore that override before we wrap it; the
	-- periodic scan will pick the prop up after the half-second effect ends.
	if IsValid( ent.SpawnEffect ) then return end
	local oldOverride = ent.RenderOverride
	-- Lua auto-refresh leaves the previous wrapper attached to live entities.
	-- Recover its captured original override so wrappers never stack and an old
	-- fullbright implementation cannot survive after this file reloads.
	if type( oldOverride ) == "function" and debug and debug.getinfo and debug.getupvalue then
		local info = debug.getinfo( oldOverride, "S" )
		local source = info and tostring( info.short_src or info.source or "" ) or ""
		if string.find( source, "cl_entity_lighting.lua", 1, true ) then
			for index = 1, 16 do
				local name, value = debug.getupvalue( oldOverride, index )
				if not name then break end
				if name == "oldOverride" then
					oldOverride = value
					break
				end
			end
		end
	end
	local wrapper = function( self, ... )
		if not entityClassEnabled( self ) then
			if oldOverride then return oldOverride( self, ... ) end
			return self:DrawModel( ... )
		end
		return drawWrappedProp( self, oldOverride, ... )
	end
	wrappedProps[ent] = { oldOverride = oldOverride, wrapper = wrapper }
	ent.RenderOverride = wrapper
end

local function refreshProps()
	if not ( propsEnabled() or vehiclesEnabled() ) then
		for ent in pairs( wrappedProps ) do unwrapProp( ent ) end
		return
	end
	for ent in pairs( wrappedProps ) do
		if not entityClassEnabled( ent ) then unwrapProp( ent ) end
	end
	for _, ent in ipairs( ents.GetAll() ) do wrapProp( ent ) end
end

hook.Remove( "PrePlayerDraw", "mc_entity_lighting_players" )
hook.Remove( "PostPlayerDraw", "mc_entity_lighting_players" )
hook.Add( "PrePlayerDraw", "mc_entity_lighting_players", function( ply )
	if playerSourceDrawActive then return end
	if not playersEnabled() then return end
	drawPlayerWithSourceLighting( ply )
	return true
end )
hook.Remove( "PostDrawOpaqueRenderables", "mc_entity_lighting_safety" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_entity_lighting_safety" )

hook.Add( "OnEntityCreated", "mc_entity_lighting_props", function( ent )
	if not ( propsEnabled() or vehiclesEnabled() ) then return end
	timer.Simple( 0, function()
		if IsValid( ent ) then wrapProp( ent ) end
	end )
end )

hook.Add( "EntityRemoved", "mc_entity_lighting_cleanup", function( ent )
	wrappedProps[ent] = nil
	lightStates[ent] = nil
end )

hook.Add( "Think", "mc_entity_lighting_props", function()
	local now = CurTime()
	if now < nextPropScan then return end
	nextPropScan = now + 2
	refreshProps()
end )

cvars.AddChangeCallback( "mc_entity_lighting", refreshProps, "mc_entity_lighting_refresh" )
cvars.AddChangeCallback( "mc_entity_lighting_props", refreshProps, "mc_entity_lighting_props_refresh" )
cvars.AddChangeCallback( "mc_entity_lighting_vehicles", refreshProps, "mc_entity_lighting_vehicles_refresh" )

if previousWrappedProps then
	for ent, record in pairs( previousWrappedProps ) do
		if IsValid( ent ) and record and ent.RenderOverride == record.wrapper then
			ent.RenderOverride = record.oldOverride
		end
	end
end

timer.Simple( 0, refreshProps )
