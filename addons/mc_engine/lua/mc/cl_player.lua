--[[----------------------------------------------------------------------------
	MC : clientside player hull for local movement prediction.
------------------------------------------------------------------------------]]

MC = MC or {}

local function applyLocalHull()
	local ply = LocalPlayer()
	if IsValid( ply ) then
		MC.ApplyPlayerHull( ply )
	end
end

hook.Add( "InitPostEntity", "mc_player_hull_client_init", function()
	timer.Simple( 0, applyLocalHull )
end )

hook.Add( "PlayerSpawn", "mc_player_hull_client_spawn", function( ply )
	if ply ~= LocalPlayer() then return end
	timer.Simple( 0, applyLocalHull )
end )

local nextApply = 0
hook.Add( "Think", "mc_player_hull_client_retry", function()
	if CurTime() < nextApply then return end
	nextApply = CurTime() + 1
	applyLocalHull()
end )
