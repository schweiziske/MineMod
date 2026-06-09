--[[----------------------------------------------------------------------------
	MC : shared player collision hull sizing.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Config = MC.Config or {}

function MC.ApplyPlayerHull( ply )
	if not IsValid( ply ) then return end

	local bs = MC.BS or 36
	local width = MC.Config.PlayerHullWidth or bs * 0.6
	local height = MC.Config.PlayerHullHeight or bs * 1.8
	local duckHeight = MC.Config.PlayerDuckHeight or bs * 1.5
	local viewHeight = MC.Config.PlayerViewHeight or bs * 1.62
	local duckViewHeight = MC.Config.PlayerDuckViewHeight or bs * 1.27
	local jumpPower = MC.Config.PlayerJumpPower or 280
	local half = width * 0.5

	ply:SetHull( Vector( -half, -half, 0 ), Vector( half, half, height ) )
	ply:SetHullDuck( Vector( -half, -half, 0 ), Vector( half, half, duckHeight ) )
	ply:SetViewOffset( Vector( 0, 0, math.min( viewHeight, height - 1 ) ) )
	ply:SetViewOffsetDucked( Vector( 0, 0, math.min( duckViewHeight, duckHeight - 1 ) ) )
	ply:SetStepSize( bs * 0.5 )
	ply:SetJumpPower( jumpPower )
end
