-- Optional client-wide incremental GC pacing. Automatic GC remains enabled.
MC = MC or {}
MC.GCSmoothing = MC.GCSmoothing or {}
local state = MC.GCSmoothing
local HOOK = "MC.GCSmoothing"
local setting = CreateClientConVar( "mc_gc_smoothing", "0", true, false,
	"GC smoothing: 0 restores previous settings; 1-16 requests smaller per-frame steps as the value increases. Affects all client Lua; atomic GC pauses remain possible.",
	0, 16 )

local function restore()
	hook.Remove( "PostRender", HOOK )
	if not state.active then return end
	collectgarbage( "setpause", state.previousPause )
	collectgarbage( "setstepmul", state.previousStepMul )
	state.active = false
	state.lastFrame = nil
end

local function step()
	local frame = FrameNumber()
	if state.lastFrame == frame then return end
	state.lastFrame = frame
	-- This is collector work in KB, not a time limit or bytes guaranteed freed.
	-- LuaJIT's atomic phase cannot be interrupted by a Lua frame budget.
	collectgarbage( "step", state.stepKB )
end

local function apply()
	local degree = math.Clamp( setting:GetInt(), 0, 16 )
	if degree == 0 then
		restore()
		return
	end
	if not state.active then
		state.previousPause = collectgarbage( "setpause", 100 )
		state.previousStepMul = collectgarbage( "setstepmul", 100 )
		state.active = true
	end
	state.stepKB = math.ceil( 256 / degree )
	hook.Add( "PostRender", HOOK, step )
end

cvars.AddChangeCallback( "mc_gc_smoothing", apply, HOOK )
hook.Add( "ShutDown", HOOK, restore )
apply()
