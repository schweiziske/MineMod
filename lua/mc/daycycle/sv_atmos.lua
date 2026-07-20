-- Optional Atmos 1.92 clock provider. The core daycycle remains independent
-- and falls back to its own clock when Atmos is absent or disabled.
if not SERVER then return end

MC = MC or {}
local DayCycle = MC.DayCycle
if not DayCycle or type( DayCycle.RegisterExternalTimeProvider ) ~= "function" then return end

local TICKS_PER_DAY = DayCycle.TicksPerDay or 24000
local cvFollowAtmos = CreateConVar( "mc_daycycle_follow_atmos", "0", { FCVAR_ARCHIVE, FCVAR_NOTIFY },
	"Follow the Atmos addon day/night clock when Atmos is installed" )
local nextSync = 0
local SYNC_INTERVAL = 0.25

local function getAtmosSource()
	local source = AtmosGlobal
	if type( source ) ~= "table" or type( source.GetTime ) ~= "function" then return nil end
	local enabled = GetConVar( "atmos_enabled" )
	if enabled and not enabled:GetBool() then return nil end
	return source
end

local function atmosTimeState()
	local source = getAtmosSource()
	if not source then return nil end
	local ok, hours = pcall( source.GetTime, source )
	hours = tonumber( hours )
	if not ok or not hours or hours ~= hours or hours == math.huge or hours == -math.huge then return nil end
	hours = hours % 24

	local realtime = GetConVar( "atmos_realtime" )
	local rate
	if realtime and realtime:GetBool() then
		rate = 1000 / 3600 -- one MC hour per real-world hour
	else
		local paused = GetConVar( "atmos_paused" )
		if source.m_Paused == true or ( paused and paused:GetBool() ) then
			rate = 0
		else
			-- Match Atmos Think: the night duration begins at 19:00, while its
			-- visual dusk animation ends later at 20:30.
			local night = hours > 19 or hours < 6.5
			local lengthCV = GetConVar( night and "atmos_dnc_length_night" or "atmos_dnc_length_day" )
			local length = lengthCV and lengthCV:GetInt() or 3600
			if length <= 0 then return nil end
			rate = TICKS_PER_DAY / length
		end
	end

	return ( ( hours - 6 ) * 1000 ) % TICKS_PER_DAY, rate
end

DayCycle.RegisterExternalTimeProvider( {
	-- Atmos env_sun sweeps from -X at dawn to +X at dusk, opposite to the
	-- MC convention used by the core daycycle's default sun vector.
	ReverseSunHorizontal = true,
	IsEnabled = function()
		return cvFollowAtmos:GetBool()
	end,
	GetTimeState = atmosTimeState,
	SetTime = function( ticks )
		local source = getAtmosSource()
		if not source or type( source.SetTime ) ~= "function" then return false end
		local hours = ( ( ticks % TICKS_PER_DAY ) / 1000 + 6 ) % 24
		return pcall( source.SetTime, source, hours )
	end,
} )

if cvFollowAtmos:GetBool() then
	local atmosTicks = DayCycle.GetExternalTimeState()
	DayCycle.Rebase( atmosTicks or DayCycle.GetNormalTicks() )
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_daycycle_follow_atmos", function()
		local atmosTicks = DayCycle.GetExternalTimeStateRegardlessOfEnabled()
		DayCycle.Rebase( atmosTicks or DayCycle.GetNormalTicks() )
	end, "mc_daycycle_follow_atmos_rebase" )
end

hook.Add( "Think", "mc_daycycle_follow_atmos", function()
	if not cvFollowAtmos:GetBool() or DayCycle.IsPaused() or CurTime() < nextSync then return end
	nextSync = CurTime() + SYNC_INTERVAL
	local atmosTicks = DayCycle.GetExternalTimeState()
	if atmosTicks ~= nil then
		DayCycle.Rebase( atmosTicks )
	elseif GetGlobalBool( "mc_daycycle_external_active", false ) then
		DayCycle.Rebase( DayCycle.GetNormalTicks() )
	end
end )
