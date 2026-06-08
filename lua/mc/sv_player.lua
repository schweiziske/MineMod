--[[----------------------------------------------------------------------------
	MC : player collision hull sizing.
------------------------------------------------------------------------------]]

MC = MC or {}

hook.Add( "PlayerSpawn", "mc_player_hull", function( ply )
	timer.Simple( 0, function()
		MC.ApplyPlayerHull( ply )
	end )
end )

hook.Add( "PlayerInitialSpawn", "mc_player_hull_initial", function( ply )
	timer.Simple( 0, function()
		MC.ApplyPlayerHull( ply )
	end )
end )
