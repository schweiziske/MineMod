-- Per-player Minecraft-style game mode. The server owns the value; clients
-- only read the replicated projection for UI and prediction decisions.

MC = MC or {}
MC.GameModes = MC.GameModes or {
	survival = true,
	creative = true,
}

function MC.NormalizeGameMode( value )
	value = string.lower( string.Trim( tostring( value or "" ) ) )
	if value == "c" or value == "1" or value == "creative" then return "creative" end
	if value == "s" or value == "0" or value == "survival" then return "survival" end
	return nil
end

function MC.PlayerGameMode( ply )
	if not IsValid( ply ) then return "survival" end
	if SERVER and MC.SV and MC.SV.GetPlayerGameMode then
		return MC.SV.GetPlayerGameMode( ply )
	end
	return MC.NormalizeGameMode( ply:GetNWString( "mc_gamemode", "creative" ) ) or "creative"
end

function MC.PlayerIsCreative( ply )
	return MC.PlayerGameMode( ply ) == "creative"
end

if SERVER then
	MC.Config = MC.Config or {}
	local flags = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.DefaultGameMode = GetConVar( "mc_default_gamemode" ) or CreateConVar(
		"mc_default_gamemode", "creative", flags,
		"Default Minecraft player mode: survival or creative"
	)
	MC.Config.AllowGameModeSwitch = GetConVar( "mc_allow_gamemode_switch" ) or CreateConVar(
		"mc_allow_gamemode_switch", "1", flags,
		"Allow players to switch their own Minecraft mode between creative and survival", 0, 1
	)
end

if CLIENT then
	-- A real, visible client ConVar; the server's reply remains authoritative.
	concommand.Remove( "mc_gamemode" )
	local modeConVar = CreateClientConVar( "mc_gamemode", "creative", true, false,
		"Your Minecraft mode: creative (1) or survival (0); subject to server permissions" )
	local applyingServerMode = false
	local ready = false
	local function requestMode( mode )
		net.Start( "mc_player_gamemode" )
			net.WriteBool( mode ~= nil )
			if mode then net.WriteBool( mode == "creative" ) end
		net.SendToServer()
	end
	net.Receive( "mc_player_gamemode", function()
		local mode = net.ReadBool() and "creative" or "survival"
		applyingServerMode = true
		modeConVar:SetString( mode )
		applyingServerMode = false
	end )
	cvars.AddChangeCallback( "mc_gamemode", function( _, _, value )
		if applyingServerMode or not ready then return end
		requestMode( MC.NormalizeGameMode( value ) )
	end, "mc_request_player_gamemode" )
	local function synchronizeMode()
		if not IsValid( LocalPlayer() ) then return end
		ready = true
		requestMode( nil )
	end
	hook.Add( "InitPostEntity", "mc_sync_player_gamemode", synchronizeMode )
	timer.Simple( 0, synchronizeMode )
end
