-- Standalone server-side time control for Atmos 1.92.
-- Unlike Atmos' original command, these commands also work from the
-- dedicated server console. In-game use is restricted to admins.

if not SERVER then return end

local cvLocked = CreateConVar(
	"mc_atmos_time_locked",
	"0",
	bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY ),
	"Keep Atmos fixed at mc_atmos_fixed_time."
)

local cvFixedTime = CreateConVar(
	"mc_atmos_fixed_time",
	"7",
	bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY ),
	"Fixed Atmos time in decimal hours (0-24)."
)

local function reply( ply, message )
	message = "[MC Atmos Time] " .. message
	if IsValid( ply ) then
		ply:PrintMessage( HUD_PRINTCONSOLE, message )
	else
		print( message )
	end
end

local function allowed( ply )
	return not IsValid( ply ) or ply:IsAdmin()
end

local function parseTime( value )
	value = string.Trim( tostring( value or "" ) )
	local hours, minutes = string.match( value, "^(%d%d?):(%d%d)$" )
	if hours then
		hours = tonumber( hours )
		minutes = tonumber( minutes )
		if hours and minutes and hours <= 24 and minutes < 60 then
			if hours == 24 and minutes ~= 0 then return nil end
			return ( hours % 24 ) + minutes / 60
		end
		return nil
	end

	local number = tonumber( value )
	if not number or number ~= number or number < 0 or number > 24 then return nil end
	return number % 24
end

local function getAtmos()
	if type( AtmosGlobal ) ~= "table" then return nil end
	if type( AtmosGlobal.SetTime ) ~= "function" then return nil end
	return AtmosGlobal
end

local function setAtmosTime( hours )
	local atmos = getAtmos()
	if not atmos then return false, "AtmosGlobal is not loaded; verify that Atmos is enabled." end

	-- Realtime mode overwrites m_Time every Think, so manual control must
	-- explicitly disable it first.
	local realtime = GetConVar( "atmos_realtime" )
	if realtime and realtime:GetBool() then
		RunConsoleCommand( "atmos_realtime", "0" )
	end

	local ok, err = pcall( atmos.SetTime, atmos, hours )
	if not ok then return false, tostring( err ) end
	return true
end

local function formatTime( hours )
	local wholeHours = math.floor( hours ) % 24
	local minutes = math.floor( ( hours - math.floor( hours ) ) * 60 + 0.5 )
	if minutes >= 60 then
		wholeHours = ( wholeHours + 1 ) % 24
		minutes = 0
	end
	return string.format( "%02d:%02d", wholeHours, minutes )
end

local function setCommand( ply, args, lock )
	if not allowed( ply ) then return end

	local hours = parseTime( args[1] )
	if hours == nil then
		reply( ply, "Usage: mc_atmos_settime <0-24 or HH:MM> [lock]" )
		return
	end

	RunConsoleCommand( "mc_atmos_fixed_time", tostring( hours ) )
	if lock ~= nil then
		RunConsoleCommand( "mc_atmos_time_locked", lock and "1" or "0" )
	elseif args[2] ~= nil then
		local lockArg = string.lower( tostring( args[2] ) )
		RunConsoleCommand( "mc_atmos_time_locked",
			( lockArg == "1" or lockArg == "true" or lockArg == "lock" ) and "1" or "0" )
	end

	local ok, err = setAtmosTime( hours )
	if not ok then
		reply( ply, "Failed to set time: " .. err )
		return
	end

	reply( ply, string.format( "Atmos time set to %s; locked=%s.",
		formatTime( hours ), cvLocked:GetBool() and "yes" or "no" ) )
end

concommand.Add( "mc_atmos_settime", function( ply, _, args )
	setCommand( ply, args or {} )
end )

concommand.Add( "mc_atmos_morning", function( ply, _, args )
	args = args or {}
	args[1] = args[1] or "7"
	setCommand( ply, args, true )
end )

concommand.Add( "mc_atmos_unlocktime", function( ply )
	if not allowed( ply ) then return end
	RunConsoleCommand( "mc_atmos_time_locked", "0" )
	reply( ply, "Atmos time lock disabled; time can progress again." )
end )

local nextEnforce = 0
hook.Add( "Think", "mc_atmos_fixed_time", function()
	if not cvLocked:GetBool() or CurTime() < nextEnforce then return end
	nextEnforce = CurTime() + 0.25

	local hours = parseTime( cvFixedTime:GetString() )
	if hours ~= nil then setAtmosTime( hours ) end
end )

hook.Add( "InitPostEntity", "mc_atmos_apply_fixed_time", function()
	if not cvLocked:GetBool() then return end
	timer.Simple( 1, function()
		local hours = parseTime( cvFixedTime:GetString() )
		if hours ~= nil then setAtmosTime( hours ) end
	end )
end )
