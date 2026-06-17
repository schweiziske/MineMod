--[[----------------------------------------------------------------------------
	MC : shared player step sizing.
------------------------------------------------------------------------------]]

MC = MC or {}

function MC.ApplyPlayerHull( ply )
	if not IsValid( ply ) then return end

	local bs = MC.BS or 36.5
	--ply:SetStepSize( bs * 0.5 + 1 )
end
