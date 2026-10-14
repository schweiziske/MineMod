-- MC terrain spotlight state. Source's projected flashlight cannot illuminate
-- the custom chunk shaders; clients consume this flag in mc:flashlight instead.
if not SERVER then return end

concommand.Add( "mc_world_flashlight", function( ply )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return end
	local now = CurTime()
	if now < ( ply.MCNextFlashlightToggle or 0 ) then return end
	ply.MCNextFlashlightToggle = now + 0.15
	local enabled = not ply:GetNW2Bool( "MCWorldFlashlight", false )
	-- Retain the server's flashlight permission, but always allow switching off.
	if enabled and hook.Run( "PlayerSwitchFlashlight", ply, true ) == false then return end
	ply:SetNW2Bool( "MCWorldFlashlight", enabled )
	ply:EmitSound( "items/flashlight1.wav", 60, 100, 0.5 )
end )

local function clearFlashlight( ply )
	ply:SetNW2Bool( "MCWorldFlashlight", false )
	ply.MCNextFlashlightToggle = nil
end
hook.Add( "PlayerSpawn", "mc_world_flashlight", clearFlashlight )
hook.Add( "PlayerDeath", "mc_world_flashlight", clearFlashlight )
