-- Minecraft-style day/night clock, shared between realms.
-- Server owns the clock (base tick + CurTime anchor pushed through SetGlobal*),
-- clients derive the current tick locally from the synced CurTime — no per-tick
-- net traffic. 24000 ticks per day like MC; tick 0 = 06:00, 6000 = noon,
-- 12000 = 18:00, 18000 = midnight.
MC = MC or {}

local TICKS_PER_DAY = 24000
MC.DAYCYCLE_TICKS_PER_DAY = TICKS_PER_DAY

function MC.DayCycleEnabled()
	return GetGlobalBool( "mc_daycycle_on", false ) == true
end

function MC.DayCycleTicks()
	local baseTicks = GetGlobalFloat( "mc_daycycle_base_ticks", 6000 )
	if not MC.DayCycleEnabled() then return baseTicks % TICKS_PER_DAY end
	local length = math.max( GetGlobalFloat( "mc_daycycle_length", 1200 ), 10 )
	local baseCur = GetGlobalFloat( "mc_daycycle_base_curtime", 0 )
	return ( baseTicks + ( CurTime() - baseCur ) * ( TICKS_PER_DAY / length ) ) % TICKS_PER_DAY
end

-- MC's smoothed celestial angle: 0 = noon, 0.5 = midnight.
function MC.DayCycleCelestialAngle()
	local f = ( MC.DayCycleTicks() / TICKS_PER_DAY - 0.25 ) % 1
	local f1 = 1 - ( math.cos( f * math.pi ) + 1 ) / 2
	return f + ( f1 - f ) / 3
end

-- Sky light level moonFloor..15 (MC subtracts up to 11 levels at night; the
-- night floor is the moonlight level, client-tunable via mc_daycycle_moon_light).
-- Quantized to whole levels so light textures only need a refresh when the
-- level actually steps.
function MC.DayCycleSkyLevel()
	if not MC.DayCycleEnabled() then return 15 end
	local floorLevel = 4
	local cv = MC.DayCycleMoonLight
	if cv and cv.GetFloat then
		floorLevel = math.Clamp( cv:GetFloat(), 0, 15 )
	end
	local angle = MC.DayCycleCelestialAngle()
	local darken = math.Clamp( 1 - ( math.cos( angle * math.pi * 2 ) * 2 + 0.5 ), 0, 1 )
	return math.Clamp( math.Round( 15 - darken * ( 15 - floorLevel ) ), 0, 15 )
end

-- 0 by day, 1 at deep night (sky level down at the moon floor). Drives the
-- night cool-tint weight baked into the light texture r channel.
function MC.DayCycleNightAmount()
	if not MC.DayCycleEnabled() then return 0 end
	local floorLevel = 4
	local cv = MC.DayCycleMoonLight
	if cv and cv.GetFloat then
		floorLevel = math.Clamp( cv:GetFloat(), 0, 15 )
	end
	local range = 15 - floorLevel
	if range <= 0 then return 0 end
	return math.Clamp( ( 15 - MC.DayCycleSkyLevel() ) / range, 0, 1 )
end

-- Continuous (unquantized) darkness 0..1: 0 through the day, 1 at deep night.
-- Used by the global lightmap so sunsets fade smoothly instead of stepping.
-- Smoothstepped: the raw clamp has slope kinks where it enters/leaves 0..1,
-- which read as lights snapping off at dusk and back on at dawn.
function MC.DayCycleNightBlend()
	if not MC.DayCycleEnabled() then return 0 end
	local angle = MC.DayCycleCelestialAngle()
	local t = math.Clamp( 1 - ( math.cos( angle * math.pi * 2 ) * 2 + 0.5 ), 0, 1 )
	return t * t * ( 3 - 2 * t )
end

-- Continuous sky brightness 0..1 with the moonlight floor applied.
function MC.DayCycleSkyBrightness()
	if not MC.DayCycleEnabled() then return 1 end
	local floorLevel = 4
	local cv = MC.DayCycleMoonLight
	if cv and cv.GetFloat then
		floorLevel = math.Clamp( cv:GetFloat(), 0, 15 )
	end
	return 1 - MC.DayCycleNightBlend() * ( 1 - floorLevel / 15 )
end

-- 0..1 window around sunrise/sunset (sun near the horizon) for warm grading.
function MC.DayCycleHorizonBlend()
	if not MC.DayCycleEnabled() then return 0 end
	local _, elevation = MC.DayCycleSunVector()
	return math.Clamp( 1 - math.abs( elevation ) / 0.35, 0, 1 )
end

-- Untilted direction toward the sun plus its elevation (cos of the sun angle:
-- +1 noon, 0 at the horizon, negative at night). Sun travels east (+x) to
-- west (-x) through the zenith like MC.
function MC.DayCycleSunVector()
	local angle = MC.DayCycleCelestialAngle() * math.pi * 2
	local elevation = math.cos( angle )
	return Vector( -math.sin( angle ), 0, elevation ), elevation
end

if SERVER then
	local cvEnabled = CreateConVar( "mc_daycycle", "0", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
		"Enable the MC day/night cycle" )
	local cvLength = CreateConVar( "mc_daycycle_length", "1200", { FCVAR_ARCHIVE },
		"Real seconds per full MC day (1200 = MC's 20 minutes)" )

	local baseTicks = 6000
	local baseCur = 0

	local function serverTicks()
		if not cvEnabled:GetBool() then return baseTicks end
		local length = math.max( cvLength:GetFloat(), 10 )
		return ( baseTicks + ( CurTime() - baseCur ) * ( TICKS_PER_DAY / length ) ) % TICKS_PER_DAY
	end

	local function rebase( ticks )
		baseTicks = ( tonumber( ticks ) or serverTicks() ) % TICKS_PER_DAY
		baseCur = CurTime()
		SetGlobalBool( "mc_daycycle_on", cvEnabled:GetBool() )
		SetGlobalFloat( "mc_daycycle_base_ticks", baseTicks )
		SetGlobalFloat( "mc_daycycle_base_curtime", baseCur )
		SetGlobalFloat( "mc_daycycle_length", math.max( cvLength:GetFloat(), 10 ) )
	end

	if cvars and cvars.AddChangeCallback then
		cvars.AddChangeCallback( "mc_daycycle", function() rebase() end, "mc_daycycle_rebase" )
		cvars.AddChangeCallback( "mc_daycycle_length", function() rebase() end, "mc_daycycle_length_rebase" )
	end

	hook.Add( "InitPostEntity", "mc_daycycle_init", function() rebase( baseTicks ) end )
	rebase( baseTicks )

	local NAMED_TIMES = {
		day = 1000,
		morning = 1000,
		noon = 6000,
		sunset = 12000,
		dusk = 12500,
		night = 13500,
		midnight = 18000,
		sunrise = 23000,
		dawn = 23000,
	}

	concommand.Add( "mc_time", function( ply, _, args )
		if IsValid( ply ) and not ply:IsAdmin() then return end
		local arg = args and args[1] and string.lower( tostring( args[1] ) ) or ""
		if arg == "" then
			local msg = string.format( "[MC] time = %d / %d (sky level %d)",
				math.floor( serverTicks() ), TICKS_PER_DAY, MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15 )
			if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, msg ) else print( msg ) end
			return
		end
		rebase( NAMED_TIMES[arg] or tonumber( arg ) or 6000 )
	end )
end
