MC = MC or {}

-- Keep the public preference available independently of backend loading.
local enabled = CreateClientConVar( "mc_native_mesh", "0", true, false,
	"Native mesh backend preference: 0 = Lua, 1 = request Native (L2 support pending)" )

local reported = false
local function checkNativeRequest()
	if not enabled:GetBool() then
		reported = false
		return
	end
	if reported then return end
	reported = true
	MC.Fault( "native_mesh_l2_unavailable",
		"mc_native_mesh requests Native, but no L2 Native renderer is loaded; Lua L2 remains active; use mc_native_mesh 0" )
end

cvars.AddChangeCallback( "mc_native_mesh", checkNativeRequest, "mc_native_mesh_l2_support" )
-- An archived request must not interrupt module loading in strict mode.
timer.Simple( 0, checkNativeRequest )
