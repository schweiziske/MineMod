--[[----------------------------------------------------------------------------
	MC : server-side admin bridge for the config menu.
------------------------------------------------------------------------------]]

MC = MC or {}

util.AddNetworkString( "mc_config_set" )

local function canSetServerConfig( ply )
	return IsValid( ply ) and ply:IsAdmin()
end

net.Receive( "mc_config_set", function( _, ply )
	if not canSetServerConfig( ply ) then return end

	local name = string.Trim( net.ReadString() or "" )
	local value = string.Trim( net.ReadString() or "" )
	if name == "" or #name > 96 or #value > 512 then return end
	if not MC.FindConfigConVar( "server", name ) then return end

	local cvar = GetConVar( name )
	if not cvar then return end
	cvar:SetString( value )
end )

