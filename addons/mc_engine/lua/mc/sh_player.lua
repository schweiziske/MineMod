--[[----------------------------------------------------------------------------
	MC : shared player step sizing.
------------------------------------------------------------------------------]]

MC = MC or {}

function MC.ApplyPlayerHull( ply )
	if not IsValid( ply ) then return end

	local bs = MC.BS or 36.5
	--ply:SetStepSize( bs * 0.5 + 1 )
end

-- Players standing on MC collision must not keep those entities as their
-- networked ground entity. Server-side chunk collision (mc_chunk /
-- mc_chunk_phys) is TRANSMIT_NEVER, so on the owning client the networked
-- ground handle resolves to NULL. Source skips CategorizePosition for
-- MOVETYPE_WALK before Duck() runs (sv_optimizedmovement), so a duck or
-- unduck that completes right after a network update takes the in-air branch
-- on the client (origin shifted by the hull-height delta) while the server
-- takes the grounded branch — the origins diverge and the view rubber-bands
-- violently while crouching. Normalizing the ground to worldspawn on both
-- realms keeps the predicted and networked ground identical and always
-- resolvable client-side (the client's local ground is the prediction
-- carrier, which the server never sees as ground because server carriers
-- have no physics).
local MC_GROUND_CLASSES = {
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
}

hook.Add( "FinishMove", "mc_ground_entity_normalize", function( ply )
	if not IsValid( ply ) then return end
	local ground = ply:GetGroundEntity()
	if not IsValid( ground ) then return end -- NULL or worldspawn
	if MC_GROUND_CLASSES[ground:GetClass()] and ply.SetGroundEntity then
		ply:SetGroundEntity( game.GetWorld() )
	end
end )
