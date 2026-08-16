-- Vanilla barrier block markers. The block itself remains a non-rendering
-- special state; creative players holding a barrier in the main hand receive
-- BlockMarker-style camera-facing particles around nearby barrier cells.

if not CLIENT then return end

MC = MC or {}

local API = MC.API or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}
local GameMode = API.GameMode or {}
local Light = API.Light or {}
local World = API.World or {}

local BS = Coords.BlockSize and Coords.BlockSize() or 36.5
local TICK_INTERVAL = 0.05
local PARTICLE_LIFETIME = 80 * TICK_INTERVAL
local SAMPLE_COUNT = 667
local MAX_PARTICLES = 16384
local RESERVOIR_START = 12288
local RESERVOIR_SIZE = MAX_PARTICLES - RESERVOIR_START
local MAX_CATCHUP_STEPS = 4
local MARKER_MATERIAL = Material( "mc/item/barrier.png", "alphatest vertexcolor vertexalpha nocull" )

local Particles = {}
local StateIsBarrier = {}
local LightCache = {}
local NextTick = 0
local NextLightCacheSweep = 0

local function cellKey( bx, by, bz )
	return tostring( bx ) .. ":" .. tostring( by ) .. ":" .. tostring( bz )
end

local function clearMarkers()
	Particles = {}
	LightCache = {}
	NextLightCacheSweep = 0
end

local function activeMarkerTarget()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	local creative = GameMode.IsCreative and GameMode.IsCreative( ply ) or false
	if creative ~= true then return nil end
	local stack = MC.GetClientSelectedStack and MC.GetClientSelectedStack() or nil
	if type( stack ) ~= "table" or stack.item ~= "minecraft:barrier" then return nil end
	return ply
end

local function isBarrierState( stateId )
	stateId = math.floor( tonumber( stateId ) or 0 )
	if stateId <= 0 then return false end
	local cached = StateIsBarrier[stateId]
	if cached ~= nil then return cached end
	local name = Blocks.Name and Blocks.Name( stateId ) or nil
	cached = name == "minecraft:barrier"
	StateIsBarrier[stateId] = cached
	return cached
end

local function admitParticle()
	local count = #Particles
	if count >= MAX_PARTICLES then return false end
	if count < RESERVOIR_START then return true end
	local freeSpace = ( MAX_PARTICLES - count ) / RESERVOIR_SIZE
	local roll = math.Rand and math.Rand( 0, 1 ) or math.random()
	return roll < freeSpace * freeSpace
end

local function addMarker( bx, by, bz, now )
	if not admitParticle() then return end
	Particles[#Particles + 1] = {
		bx = bx, by = by, bz = bz,
		expiresAt = now + PARTICLE_LIFETIME,
	}
end

local function removeExpired( now )
	local write = 1
	for read = 1, #Particles do
		local particle = Particles[read]
		if particle.expiresAt > now then
			Particles[write] = particle
			write = write + 1
		end
	end
	for index = #Particles, write, -1 do Particles[index] = nil end
	if #Particles == 0 then
		LightCache = {}
		NextLightCacheSweep = now + 1
	elseif now >= NextLightCacheSweep then
		for key, cached in pairs( LightCache ) do
			if now - ( tonumber( cached.lastUsed ) or 0 ) > PARTICLE_LIFETIME then LightCache[key] = nil end
		end
		NextLightCacheSweep = now + 1
	end
end

local function triangularOffset( radius )
	return math.random( 0, radius - 1 ) - math.random( 0, radius - 1 )
end

local function sampleRadius( centerX, centerY, centerZ, radius, now )
	local bx = centerX + triangularOffset( radius )
	local by = centerY + triangularOffset( radius )
	local bz = centerZ + triangularOffset( radius )
	local stateId = World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	if isBarrierState( stateId ) then addMarker( bx, by, bz, now ) end
end

local function animateTick( ply, now )
	local bx, by, bz
	if Coords.EntityCell then bx, by, bz = Coords.EntityCell( ply ) end
	if bx == nil then return end
	for _ = 1, SAMPLE_COUNT do
		sampleRadius( bx, by, bz, 16, now )
		sampleRadius( bx, by, bz, 32, now )
	end
end

hook.Add( "Think", "mcgame_barrier_marker_ticks", function()
	local now = CurTime()
	local ply = activeMarkerTarget()
	removeExpired( now )
	if not ply then
		-- Existing BlockMarker particles are owned by ParticleEngine and retain
		-- their complete 80-tick lifetime after the player changes item or mode.
		-- Only stop producing new particles here.
		NextTick = now
		return
	end

	if NextTick <= 0 or now - NextTick > TICK_INTERVAL * MAX_CATCHUP_STEPS then NextTick = now end
	local steps = 0
	while now >= NextTick and steps < MAX_CATCHUP_STEPS do
		animateTick( ply, NextTick )
		NextTick = NextTick + TICK_INTERVAL
		steps = steps + 1
	end
end )

local function markerColor( particle, now )
	local key = cellKey( particle.bx, particle.by, particle.bz )
	local cached = LightCache[key]
	if cached and now < cached.nextAt then
		cached.lastUsed = now
		return cached.color
	end
	local r, g, b = 1, 1, 1
	local worldCenter = Coords.CellCenter and Coords.CellCenter( particle.bx, particle.by, particle.bz ) or nil
	if worldCenter and Light.SampleRGB then r, g, b = Light.SampleRGB( worldCenter, 0 ) end
	local color = Color(
		math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 ), 255
	)
	LightCache[key] = { color = color, nextAt = now + 0.1, lastUsed = now }
	return color
end

hook.Add( "PostDrawTranslucentRenderables", "mcgame_barrier_markers", function( _, drawingSkybox, drawing3DSkybox )
	if drawingSkybox or drawing3DSkybox or #Particles == 0 then return end
	if not MARKER_MATERIAL or MARKER_MATERIAL.IsError and MARKER_MATERIAL:IsError() then return end

	local now = CurTime()
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	render.SetMaterial( MARKER_MATERIAL )
	for _, particle in ipairs( Particles ) do
		local center = Coords.CellRenderCenter
			and Coords.CellRenderCenter( particle.bx, particle.by, particle.bz ) or nil
		if center then render.DrawSprite( center, BS, BS, markerColor( particle, now ) ) end
	end
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )

hook.Add( "MC.ClientWorldProjectionChanged", "mcgame_barrier_marker_world_reset", clearMarkers )
hook.Add( "ShutDown", "mcgame_barrier_marker_shutdown", clearMarkers )
