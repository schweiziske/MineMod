-- Terrain flashlight controls belong to the engine, independent of held weapons.
if not CLIENT then return end

local function toggleFlashlight()
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return end
	RunConsoleCommand( "mc_world_flashlight" )
end

-- Explicit console commands must work while the console owns keyboard focus.
concommand.Add( "mc_flashlight", toggleFlashlight )

local keyDown = false
hook.Add( "Think", "mc_world_flashlight_input", function()
	local down = input.IsKeyDown( KEY_G )
	local pressed = down and not keyDown
	keyDown = down
	if not pressed then return end
	if gui.IsGameUIVisible() or vgui.CursorVisible() or IsValid( vgui.GetKeyboardFocus() ) then return end
	-- Respect existing binds; a bound mc_flashlight dispatches its own command.
	local bind = input.LookupKeyBinding( KEY_G )
	if bind and bind ~= "" then return end
	toggleFlashlight()
end )
