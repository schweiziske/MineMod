MC = MC or {}

-- Keep the public preference available independently of backend loading.
local enabled = CreateClientConVar( "mc_native_mesh", "0", true, false,
	"L2 mesh backend: 0 = Lua, 1 = Native quad lighting and indexed mesh upload" )
MC.NativeMeshPreference = enabled

local reported = false
local function checkNativeRequest()
	local active, reason
	if MC.NativeL2 then active, reason = MC.NativeL2.SetEnabled( enabled:GetBool() ) end
	if not enabled:GetBool() then
		reported = false
		return
	end
	if active then reported = false return end
	if reported then return end
	reported = true
	MC.Fault( "native_mesh_l2_unavailable",
		"mc_native_mesh requests Native, but L2 is unavailable: %s; Lua L2 remains active; update the DLL or use mc_native_mesh 0",
		reason or "Native L2 adapter did not load" )
end

cvars.AddChangeCallback( "mc_native_mesh", checkNativeRequest, "mc_native_mesh_l2_support" )
-- An archived request must not interrupt module loading in strict mode.
timer.Simple( 0, checkNativeRequest )
