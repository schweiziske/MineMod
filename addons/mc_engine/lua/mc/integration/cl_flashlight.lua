-- Terrain flashlight controls belong to the engine, independent of held weapons.
if not CLIENT then return end

local function toggleFlashlight()
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return end
	RunConsoleCommand( "mc_world_flashlight" )
end

-- Explicit console commands must work while the console owns keyboard focus.
concommand.Add( "mc_flashlight", toggleFlashlight )
