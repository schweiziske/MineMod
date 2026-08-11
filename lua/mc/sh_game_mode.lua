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
	return MC.NormalizeGameMode( ply:GetNWString( "mc_gamemode", "survival" ) ) or "survival"
end

function MC.PlayerIsCreative( ply )
	return MC.PlayerGameMode( ply ) == "creative"
end

if SERVER then
	MC.Config = MC.Config or {}
	local flags = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.DefaultGameMode = GetConVar( "mc_default_gamemode" ) or CreateConVar(
		"mc_default_gamemode", "survival", flags,
		"Default Minecraft player mode: survival or creative"
	)
end
