-- Minecraft-style day/night clock, shared between realms.
-- Server owns the clock (base tick + CurTime anchor pushed through SetGlobal*),
-- clients derive the current tick locally from the synced CurTime. 24000 ticks
-- per day like MC; tick 0 = 06:00, 6000 = noon, 12000 = 18:00, 18000 = midnight.
MC = MC or {}

local TICKS_PER_DAY = 24000
MC.DAYCYCLE_TICKS_PER_DAY = TICKS_PER_DAY
MC.DayCycle = MC.DayCycle or {}

function MC.DayCycleEnabled()
	return GetGlobalBool( "mc_daycycle_on", false ) == true
end

function MC.DayCyclePaused()
	return GetGlobalBool( "mc_daycycle_paused", false ) == true
end

function MC.DayCycleTicks()
	local baseTicks = GetGlobalFloat( "mc_daycycle_base_ticks", 6000 )
	if not MC.DayCycleEnabled() or MC.DayCyclePaused() then return baseTicks % TICKS_PER_DAY end
	local length = math.max( GetGlobalFloat( "mc_daycycle_length", 1200 ), 10 )
	local tickRate = GetGlobalFloat( "mc_daycycle_tick_rate", 0 )
	if tickRate == 0 and GetGlobalBool( "mc_daycycle_external_active", false ) then
		return baseTicks % TICKS_PER_DAY
	end
	if tickRate <= 0 or tickRate ~= tickRate or tickRate == math.huge or tickRate == -math.huge then
		tickRate = TICKS_PER_DAY / length
	end
	local baseCur = GetGlobalFloat( "mc_daycycle_base_curtime", 0 )
	return ( baseTicks + ( CurTime() - baseCur ) * tickRate ) % TICKS_PER_DAY
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

-- Map sun directions already use the render axes. Cache the engine query once
-- per frame so lighting and shadow consumers share it without extra allocations.
local mapSunFrame, mapSunX, mapSunY, mapSunZ
local function mapSunComponents()
	local frame = FrameNumber()
	if mapSunFrame ~= frame then
		mapSunFrame = frame
		mapSunX, mapSunY, mapSunZ = 0, 0, 1
		local info = util.GetSunInfo()
		local direction = info and info.direction
		if direction and not direction:IsZero() then
			local inverseLength = 1 / direction:Length()
			mapSunX = direction.x * inverseLength
			mapSunY = direction.y * inverseLength
			mapSunZ = direction.z * inverseLength
		end
	end
	return mapSunX, mapSunY, mapSunZ, mapSunZ
end

-- Untilted direction toward the sun plus its elevation (cos of the sun angle:
-- +1 noon, 0 at the horizon, negative at night). Sun travels east (+x) to
-- west (-x) through the zenith like MC. An external clock provider can opt
-- into the opposite horizontal convention for Source sky systems.
function MC.DayCycleSunComponents()
	if CLIENT and not MC.DayCycleEnabled() then return mapSunComponents() end
	local angle = MC.DayCycleCelestialAngle() * math.pi * 2
	local elevation = math.cos( angle )
	local horizontalSign = GetGlobalBool( "mc_daycycle_external_reverse_sun", false ) and 1 or -1
	return horizontalSign * math.sin( angle ), 0, elevation, elevation
end

function MC.DayCycleSunVector()
	local x, y, z, elevation = MC.DayCycleSunComponents()
	return Vector( x, y, z ), elevation
end

if not SERVER then return end

local DayCycle = MC.DayCycle
DayCycle.TicksPerDay = TICKS_PER_DAY

local cvEnabled = CreateConVar( "mc_daycycle", "0", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Enable the MC day/night cycle; when disabled, use the map sun direction" )
local cvPaused = CreateConVar( "mc_daycycle_paused", "0", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Pause the MC day/night clock at its current time" )
local cvLength = CreateConVar( "mc_daycycle_length", "1200", { FCVAR_ARCHIVE },
	"Real seconds per full MC day (1200 = MC's 20 minutes)" )

local baseTicks = 6000
local baseCur = 0

DayCycle.ConVars = {
	enabled = cvEnabled,
	paused = cvPaused,
	length = cvLength,
}

local function valueBool( value )
	value = string.lower( tostring( value or "" ) )
	return value ~= "" and value ~= "0" and value ~= "false" and value ~= "off"
end

local function validFiniteNumber( value )
	value = tonumber( value )
	if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
	return value
end

local function providerTimeState( requireEnabled )
	local provider = DayCycle.ExternalTimeProvider
	if type( provider ) ~= "table" or type( provider.GetTimeState ) ~= "function" then return nil end
	if requireEnabled then
		if type( provider.IsEnabled ) ~= "function" then return nil end
		local ok, enabled = pcall( provider.IsEnabled )
		if not ok or not enabled then return nil end
	end

	local ok, ticks, tickRate = pcall( provider.GetTimeState )
	if not ok then return nil end
	ticks = validFiniteNumber( ticks )
	tickRate = validFiniteNumber( tickRate )
	if ticks == nil or tickRate == nil or tickRate < 0 then return nil end
	return ticks % TICKS_PER_DAY, tickRate, provider
end

function DayCycle.RegisterExternalTimeProvider( provider )
	DayCycle.ExternalTimeProvider = provider
end

function DayCycle.GetExternalTimeState()
	return providerTimeState( true )
end

function DayCycle.GetExternalTimeStateRegardlessOfEnabled()
	return providerTimeState( false )
end

local function serverTicksForState( enabled, paused, length )
	if not enabled or paused then return baseTicks end
	length = math.max( tonumber( length ) or cvLength:GetFloat(), 10 )
	return ( baseTicks + ( CurTime() - baseCur ) * ( TICKS_PER_DAY / length ) ) % TICKS_PER_DAY
end

function DayCycle.GetNormalTicks()
	return serverTicksForState( cvEnabled:GetBool(), cvPaused:GetBool(), cvLength:GetFloat() )
end

function DayCycle.IsPaused()
	return cvPaused:GetBool()
end

local function serverTicks()
	if cvEnabled:GetBool() and not cvPaused:GetBool() then
		local externalTicks = DayCycle.GetExternalTimeState()
		if externalTicks ~= nil then return externalTicks end
	end
	return DayCycle.GetNormalTicks()
end

function DayCycle.GetServerTicks()
	return serverTicks()
end

function DayCycle.Rebase( ticks )
	local externalTicks, externalRate, provider = DayCycle.GetExternalTimeState()
	if ticks == nil and externalTicks ~= nil then ticks = externalTicks end
	baseTicks = ( validFiniteNumber( ticks ) or serverTicks() ) % TICKS_PER_DAY
	baseCur = CurTime()
	SetGlobalBool( "mc_daycycle_on", cvEnabled:GetBool() )
	SetGlobalBool( "mc_daycycle_paused", cvPaused:GetBool() )
	SetGlobalBool( "mc_daycycle_external_active", externalTicks ~= nil )
	SetGlobalBool( "mc_daycycle_external_reverse_sun", provider and provider.ReverseSunHorizontal == true or false )
	SetGlobalFloat( "mc_daycycle_base_ticks", baseTicks )
	SetGlobalFloat( "mc_daycycle_base_curtime", baseCur )
	SetGlobalFloat( "mc_daycycle_length", math.max( cvLength:GetFloat(), 10 ) )
	SetGlobalFloat( "mc_daycycle_tick_rate", externalRate or ( TICKS_PER_DAY / math.max( cvLength:GetFloat(), 10 ) ) )
end

function DayCycle.SetTime( ticks )
	local _, _, provider = DayCycle.GetExternalTimeState()
	if provider and type( provider.SetTime ) == "function" then
		local ok, applied = pcall( provider.SetTime, ticks )
		if ok and applied then
			DayCycle.Rebase()
			return
		end
	end
	DayCycle.Rebase( ticks )
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_daycycle", function( _, oldValue )
		if DayCycle.GetExternalTimeState() ~= nil then DayCycle.Rebase()
		else DayCycle.Rebase( serverTicksForState( valueBool( oldValue ), cvPaused:GetBool(), cvLength:GetFloat() ) ) end
	end, "mc_daycycle_rebase" )
	cvars.AddChangeCallback( "mc_daycycle_paused", function( _, oldValue )
		if DayCycle.GetExternalTimeState() ~= nil then DayCycle.Rebase()
		else DayCycle.Rebase( serverTicksForState( cvEnabled:GetBool(), valueBool( oldValue ), cvLength:GetFloat() ) ) end
	end, "mc_daycycle_paused_rebase" )
	cvars.AddChangeCallback( "mc_daycycle_length", function( _, oldValue )
		if DayCycle.GetExternalTimeState() ~= nil then DayCycle.Rebase()
		else DayCycle.Rebase( serverTicksForState( cvEnabled:GetBool(), cvPaused:GetBool(), tonumber( oldValue ) or cvLength:GetFloat() ) ) end
	end, "mc_daycycle_length_rebase" )
end

local function startupTicks()
	local externalTicks = DayCycle.GetExternalTimeState()
	return externalTicks or baseTicks
end

hook.Add( "InitPostEntity", "mc_daycycle_init", function() DayCycle.Rebase( startupTicks() ) end )
DayCycle.Rebase( startupTicks() )

local NAMED_TIMES = {
	day = 1000,
	morning = 1000,
	noon = 6000,
	sunset = 12000,
	dusk = 12500,
	night = 13000,
	midnight = 18000,
	sunrise = 23000,
	dawn = 23000,
}

local function printTimeMessage( ply, message )
	if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, message ) else print( message ) end
end

local function printTimeUsage( ply )
	printTimeMessage( ply,
		"[MC] Usage: mc_time [set] <tick|day|morning|noon|sunset|dusk|night|midnight|sunrise|dawn>" )
end

concommand.Add( "mc_time", function( ply, _, args )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local firstArg = args and args[1] and string.lower( tostring( args[1] ) ) or ""
	if firstArg == "" then
		local msg = string.format( "[MC] time = %d / %d (sky level %d, paused=%s)",
			math.floor( serverTicks() ), TICKS_PER_DAY, MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15,
			tostring( cvPaused:GetBool() ) )
		printTimeMessage( ply, msg )
		return
	end

	-- Accept the vanilla-style form (mc_time set night) as well as the
	-- original compact form (mc_time night). Never turn malformed input into
	-- an unexpected jump to noon.
	local arg = firstArg
	if firstArg == "set" then
		arg = args and args[2] and string.lower( tostring( args[2] ) ) or ""
		if args and args[3] then
			printTimeUsage( ply )
			return
		end
	elseif args and args[2] then
		printTimeUsage( ply )
		return
	end

	local ticks = NAMED_TIMES[arg] or validFiniteNumber( arg )
	if ticks == nil then
		printTimeUsage( ply )
		return
	end
	DayCycle.SetTime( ticks )
end )
