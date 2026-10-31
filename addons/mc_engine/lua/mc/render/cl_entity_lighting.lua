-- Minecraft voxel lighting for Source-rendered players, NPCs and prop models.
-- Opt-in because replacing prop RenderOverride can interact with other addons.
MC = MC or {}

MC.EntityLightingEnabled = CreateClientConVar(
	"mc_light_entity", "0", true, false,
	"Apply interpolated Minecraft lighting to players, NPCs and common prop models"
)
MC.EntityLightingPlayers = CreateClientConVar(
	"mc_light_entity_players", "1", true, false,
	"Apply Minecraft entity lighting to players"
)
MC.EntityLightingNPCs = CreateClientConVar(
	"mc_light_entity_npcs", "1", true, false,
	"Apply Minecraft entity lighting to NPCs and NextBots"
)
MC.EntityLightingProps = CreateClientConVar(
	"mc_light_entity_props", "1", true, false,
	"Apply Minecraft entity lighting to common prop classes"
)
MC.EntityLightingVehicles = CreateClientConVar(
	"mc_light_entity_vehicles", "1", true, false,
	"Apply Minecraft entity lighting to standard Source vehicle classes"
)
-- Consumed by cl_block_cluster.lua (mc_block_cluster entities); lives here so
-- the whole mc_light_entity family is declared in one place. Cluster gain
-- defaults to 1 because the cluster mesh uses chunk-style vertex lighting;
-- the 0.48 entity gain is an exposure correction for Source models only.
MC.EntityLightingClusters = CreateClientConVar(
	"mc_light_entity_cluster", "1", true, false,
	"Apply Minecraft entity lighting to block structure entities (mc_block_cluster)"
)
MC.EntityLightingClusterGain = CreateClientConVar(
	"mc_light_entity_cluster_gain", "1", true, false,
	"Exposure multiplier for Minecraft-lit block structures; 1 matches chunk vertex lighting"
)
MC.EntityLightingGain = CreateClientConVar(
	"mc_light_entity_gain", "0.48", true, false,
	"Exposure multiplier for Minecraft-lit Source entities"
)
MC.EntityLightingReflections = CreateClientConVar(
	"mc_light_entity_reflections", "0.35", true, false,
	"Reflection strength for Minecraft-lit entities; also scales with sampled brightness"
)
MC.EntityLightingInterval = CreateClientConVar(
	"mc_light_entity_interval", "0.10", true, false,
	"Minimum seconds between voxel-light samples per entity; 0 requests every frame, with at most 4 entities sampled per frame"
)
MC.EntityLightingPlayerGamma = CreateClientConVar(
	"mc_light_entity_player_gamma", "2.2", true, false,
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
local materialLists = setmetatable( {}, { __mode = "k" } )
local MAX_SAMPLES_PER_FRAME = 4
local sampleQueue, queueHead, queueTail = {}, 1, 0
local sampleFrame, frameSamples = -1, 0
local playerSourceDrawActive = false
local nextPropScan = 0

local function convarValueEnabled( value )
	local number = tonumber( value )
	if number ~= nil then return number ~= 0 end
	value = string.lower( tostring( value or "" ) )
	return value == "true" or value == "yes" or value == "on"
end

local masterEnabled = MC.EntityLightingEnabled and MC.EntityLightingEnabled:GetBool() or false
local playerLightingEnabled = MC.EntityLightingPlayers and MC.EntityLightingPlayers:GetBool() or false
local propLightingEnabled = MC.EntityLightingProps and MC.EntityLightingProps:GetBool() or false
local vehicleLightingEnabled = MC.EntityLightingVehicles and MC.EntityLightingVehicles:GetBool() or false
local npcLightingEnabled = MC.EntityLightingNPCs:GetBool()

local function enabled()
	return masterEnabled
end

local function playersEnabled()
	return enabled() and playerLightingEnabled
end

local function propsEnabled()
	return enabled() and propLightingEnabled
end

local function vehiclesEnabled()
	return enabled() and vehicleLightingEnabled
end

local function entityClassEnabled( ent )
	if not IsValid( ent ) then return false end
	if ent:IsNPC() or ent:IsNextBot() then return enabled() and npcLightingEnabled end
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

-- Voxel samplers consume persistent MC-world positions, not LocalToWorld's
-- engine frame. Sample the centre and six faces so a large prop's origin
-- inside a block does not decide the brightness of the entire model.
local function samplePosition( ent, player )
	local coords = MC.API.Coords
	if player then return coords.EntityEyeWorldPos( ent ) end
	local minimum, maximum = coords.EntityWorldAABB( ent )
	if not minimum or not maximum then
		MC.Fault( "entity_light_bounds", "world bounds unavailable for entity %d", ent:EntIndex() )
		return nil
	end
	return ( minimum + maximum ) * 0.5, minimum, maximum
end

local function sampleEntity( ent, player, position, minimum, maximum )
	local r, g, b = MC.SampleEntityLightingRGB( position )
	if player then return r, g, b end
	local inset = MC.API.Coords.BlockSize() * 0.125
	local point = Vector( position.x, position.y, position.z )
	for axis = 1, 3 do
		local key = axis == 1 and "x" or axis == 2 and "y" or "z"
		point[key] = minimum[key] - inset
		local sr, sg, sb = MC.SampleEntityLightingRGB( point )
		r, g, b = r + sr, g + sg, b + sb
		point[key] = maximum[key] + inset
		sr, sg, sb = MC.SampleEntityLightingRGB( point )
		r, g, b = r + sr, g + sg, b + sb
		point[key] = position[key]
	end
	return r / 7, g / 7, b / 7
end

local function queueSample( ent, state )
	if state.queued then return end
	state.queued = true
	queueTail = queueTail + 1
	sampleQueue[queueTail] = { entity = ent, state = state }
end

-- FIFO order prevents the first-drawn models from taking every frame's budget.
-- Requests expire after one frame without drawing, allowing next-frame service.
local function processSamples( now, frame, interval )
	if sampleFrame ~= frame then sampleFrame, frameSamples = frame, 0 end
	while queueHead <= queueTail and frameSamples < MAX_SAMPLES_PER_FRAME do
		local request = sampleQueue[queueHead]
		sampleQueue[queueHead], queueHead = nil, queueHead + 1
		local ent, state = request.entity, request.state
		state.queued = false
		if lightStates[ent] == state and IsValid( ent ) and state.lastSeenFrame >= frame - 1
			and ( state.player and playersEnabled() or not state.player and entityClassEnabled( ent ) )
			and state.sampledFrame ~= frame
			and ( not state.sampledAt or now - state.sampledAt >= interval ) then
			frameSamples = frameSamples + 1
			local position, minimum, maximum = samplePosition( ent, state.player )
			if position then
				local r, g, b = sampleEntity( ent, state.player, position, minimum, maximum )
				state.targetR, state.targetG, state.targetB = r, g, b
				state.sampledAt, state.sampledFrame = now, frame
				if not state.r then
					state.r, state.g, state.b, state.lastUpdate = r, g, b, now
				end
			end
		end
	end
	if queueHead > queueTail then queueHead, queueTail = 1, 0 end
end

local function sampledRGB( ent, player )
	-- World/lightmap publication can lag entity creation during connection.
	-- Keep the engine draw until a real MC lightmap is available.
	if not MC.GlobalLightmapRevision or MC.GlobalLightmapRevision <= 0 then return nil end
	local now, frame = RealTime(), FrameNumber()
	local state = lightStates[ent]
	local interval = sampleInterval()
	if not state then
		state = { player = player }
		lightStates[ent] = state
	end
	state.lastSeenFrame = frame
	if state.frame ~= frame then
		state.frame = frame
		if state.sampledFrame ~= frame and ( not state.sampledAt or now - state.sampledAt >= interval ) then
			queueSample( ent, state )
		end
		processSamples( now, frame, interval )
		if state.r then
			local blend = 1 - math.exp( -math.Clamp( now - state.lastUpdate, 0, 0.1 ) * 12 )
			state.r, state.g, state.b = Lerp( blend, state.r, state.targetR ),
				Lerp( blend, state.g, state.targetG ), Lerp( blend, state.b, state.targetB )
			state.lastUpdate = now
		end
	end
	-- Newly visible models retain Source lighting until their queued first sample.
	if not state.r then return nil end
	local mul = gain()
	return state.r * mul, state.g * mul, state.b * mul
end

local function modelMaterials( ent )
	local model, skin = ent:GetModel(), ent:GetSkin()
	local cached = materialLists[ent]
	if cached and cached.model == model and cached.skin == skin then return cached.materials end
	local materials, seen = {}, {}
	for _, name in ipairs( ent:GetMaterials() or {} ) do
		local mat = Material( name )
		if mat and not mat:IsError() and not seen[mat] then
			seen[mat] = true
			materials[#materials + 1] = mat
		end
	end
	materialLists[ent] = { model = model, skin = skin, materials = materials }
	return materials
end

local function dampMaterialReflections( ent, r, g, b, states )
	local factor = math.Clamp( math.max( r, g, b ) * reflectionStrength(), 0, 1 )
	-- Cache identities only: shared material parameters can change between draws.
	for _, mat in ipairs( modelMaterials( ent ) ) do
		local envTint = mat:GetVector( "$envmaptint" )
		-- Some IMaterial getters return zero values (not one nil value) when a
		-- parameter is absent. Assignment normalizes that case to nil before
		-- tonumber is called.
		local rawPhongBoost = mat:GetFloat( "$phongboost" )
		local phongBoost = rawPhongBoost ~= nil and tonumber( rawPhongBoost ) or nil
		local state = { mat = mat, phongBoost = phongBoost }
		states[#states + 1] = state
		if envTint then
			state.envTint = Vector( envTint.x, envTint.y, envTint.z )
			mat:SetVector( "$envmaptint", envTint * factor )
		end
		-- Many camera/weapon materials do not define $phongboost; GMod then
		-- returns nil rather than zero. Leave absent shader parameters alone.
		if phongBoost ~= nil then mat:SetFloat( "$phongboost", phongBoost * factor ) end
	end
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

-- Own the ambient cube for this draw. Multiplying Source's baked lighting
-- by MC light applies two unrelated worlds' lighting, and setting the cube
-- without suppression lets StudioRender replace it during DrawModel.
local function beginModelLighting( ent, player, state )
	local r, g, b = sampledRGB( ent, player )
	if not r then return end
	state.r, state.g, state.b = render.GetColorModulation()
	state.materials = {}
	dampMaterialReflections( ent, r, g, b, state.materials )
	local gamma = player and playerLightingGamma() or 2.2
	state.lighting = true
	render.SuppressEngineLighting( true )
	render.SetLocalModelLights()
	render.ResetModelLighting( r ^ gamma, g ^ gamma, b ^ gamma )
end

local function endModelLighting( state )
	if state.lighting then
		render.ResetModelLighting( 1, 1, 1 )
		render.SuppressEngineLighting( false )
	end
	if not state.r then return end
	render.SetColorModulation( state.r, state.g, state.b )
	restoreMaterialReflections( state.materials )
end

-- Use the same owned lighting scope for actors and props, including cleanup
-- if material setup or the model draw raises an error.
local function drawPlayerWithSourceLighting( ply )
	local state = {}
	playerSourceDrawActive = true
	local ok, err = pcall( function()
		beginModelLighting( ply, true, state )
		ply:DrawModel()
	end )
	playerSourceDrawActive = false
	endModelLighting( state )
	if not ok then MC.Fault( "entity_light_player_draw", "%s", tostring( err ) ) end
end

local function drawWrappedProp( ent, oldOverride, ... )
	local materialState = {}
	local ok, err = pcall( function( ... )
		beginModelLighting( ent, false, materialState )
		if oldOverride then return oldOverride( ent, ... ) end
		return ent:DrawModel( ... )
	end, ... )
	endModelLighting( materialState )
	if not ok then MC.Fault( "entity_light_draw", "%s", tostring( err ) ) end
end

local function unwrapProp( ent )
	local record = wrappedProps[ent]
	if not record then return end
	if IsValid( ent ) and ent.RenderOverride == record.wrapper then
		ent.RenderOverride = record.oldOverride
	end
	wrappedProps[ent] = nil
	lightStates[ent] = nil
	materialLists[ent] = nil
end

local function wrapProp( ent )
	if not IsValid( ent ) then return end
	if not entityClassEnabled( ent ) then return end
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
		if not entityClassEnabled( self ) or MC.RenderPBRShadows and MC.RenderPBRShadows.rendering then
			if oldOverride then return oldOverride( self, ... ) end
			return self:DrawModel( ... )
		end
		return drawWrappedProp( self, oldOverride, ... )
	end
	wrappedProps[ent] = { oldOverride = oldOverride, wrapper = wrapper }
	ent.RenderOverride = wrapper
end

local function clearLightStates()
	for ent in pairs( lightStates ) do lightStates[ent] = nil end
	for ent in pairs( materialLists ) do materialLists[ent] = nil end
	sampleQueue, queueHead, queueTail = {}, 1, 0
end

local function refreshProps()
	if enabled() and not MC.Check( type( MC.SampleEntityLightingRGB ) == "function"
		and MC.API and MC.API.Coords and MC.API.Coords.EntityWorldAABB
		and MC.API.Coords.EntityEyeWorldPos and MC.API.Coords.WorldToEngine,
		"entity_light_api", "entity lighting requires the world-coordinate RGB sampler" ) then return end
	if not enabled() then
		for ent in pairs( wrappedProps ) do unwrapProp( ent ) end
		clearLightStates()
		return
	end
	if not ( propsEnabled() or vehiclesEnabled() or npcLightingEnabled ) then
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
	-- The shadow owner supplies a depth material and a light-space camera.
	-- Do not recurse into the colour-lighting draw while collecting its pose.
	if MC.RenderPBRShadows and MC.RenderPBRShadows.rendering then return end
	if playerSourceDrawActive then return end
	if not playersEnabled() then return end
	drawPlayerWithSourceLighting( ply )
	return true
end )
hook.Remove( "PostDrawOpaqueRenderables", "mc_entity_lighting_safety" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_entity_lighting_safety" )

hook.Add( "OnEntityCreated", "mc_entity_lighting_props", function( ent )
	if not enabled() then return end
	timer.Simple( 0, function()
		if IsValid( ent ) then wrapProp( ent ) end
	end )
end )

hook.Add( "EntityRemoved", "mc_entity_lighting_cleanup", function( ent )
	wrappedProps[ent] = nil
	lightStates[ent] = nil
	materialLists[ent] = nil
end )

hook.Add( "Think", "mc_entity_lighting_props", function()
	local now = CurTime()
	if now < nextPropScan then return end
	nextPropScan = now + 2
	refreshProps()
end )

if cvars.RemoveChangeCallback then
	-- Remove callbacks left by the retired archived ConVars during Lua refresh.
	cvars.RemoveChangeCallback( "mc_entity_lighting", "mc_entity_lighting_refresh" )
	cvars.RemoveChangeCallback( "mc_entity_lighting_players", "mc_entity_lighting_players_refresh" )
	cvars.RemoveChangeCallback( "mc_entity_lighting_props", "mc_entity_lighting_props_refresh" )
	cvars.RemoveChangeCallback( "mc_entity_lighting_vehicles", "mc_entity_lighting_vehicles_refresh" )
	cvars.RemoveChangeCallback( "mc_light_entity", "mc_light_entity_refresh" )
	cvars.RemoveChangeCallback( "mc_light_entity_players", "mc_light_entity_players_refresh" )
	cvars.RemoveChangeCallback( "mc_light_entity_props", "mc_light_entity_props_refresh" )
	cvars.RemoveChangeCallback( "mc_light_entity_vehicles", "mc_light_entity_vehicles_refresh" )
	cvars.RemoveChangeCallback( "mc_light_entity_npcs", "mc_light_entity_npcs_refresh" )
end

cvars.AddChangeCallback( "mc_light_entity", function( _, _, newValue )
	masterEnabled = convarValueEnabled( newValue )
	refreshProps()
end, "mc_light_entity_refresh" )
cvars.AddChangeCallback( "mc_light_entity_players", function( _, _, newValue )
	playerLightingEnabled = convarValueEnabled( newValue )
	if not playersEnabled() then
		for _, ply in ipairs( player.GetAll() ) do lightStates[ply] = nil end
	end
end, "mc_light_entity_players_refresh" )
cvars.AddChangeCallback( "mc_light_entity_props", function( _, _, newValue )
	propLightingEnabled = convarValueEnabled( newValue )
	refreshProps()
end, "mc_light_entity_props_refresh" )
cvars.AddChangeCallback( "mc_light_entity_vehicles", function( _, _, newValue )
	vehicleLightingEnabled = convarValueEnabled( newValue )
	refreshProps()
end, "mc_light_entity_vehicles_refresh" )
cvars.AddChangeCallback( "mc_light_entity_npcs", function( _, _, newValue )
	npcLightingEnabled = convarValueEnabled( newValue )
	refreshProps()
end, "mc_light_entity_npcs_refresh" )

if previousWrappedProps then
	for ent, record in pairs( previousWrappedProps ) do
		if IsValid( ent ) and record and ent.RenderOverride == record.wrapper then
			ent.RenderOverride = record.oldOverride
		end
	end
end

timer.Simple( 0, refreshProps )
