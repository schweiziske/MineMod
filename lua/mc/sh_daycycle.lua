-- Compatibility loader for the split daycycle implementation.
if SERVER then
	AddCSLuaFile( "mc/daycycle/sh_core.lua" )
end

include( "mc/daycycle/sh_core.lua" )

if SERVER then
	include( "mc/daycycle/sv_atmos.lua" )
end
