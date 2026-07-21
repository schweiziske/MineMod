-- Passive client-side diagnostics for preset cover capture.
-- Does not wrap render.Capture, net, or file APIs, so it should not change timing.
-- Load with: lua_openscript_cl mc/dev/cl_preset_capture_debug_passive.lua
-- Stop with: mc_preset_capture_debug_passive_stop

if not CLIENT then return end

MC = MC or {}
if MC.PresetCaptureDebug and MC.PresetCaptureDebug.Stop then MC.PresetCaptureDebug.Stop() end

local PREFIX = "MC_PresetCaptureDebugPassive"
local LOG_PATH = "mc/debug/preset_capture_passive.log"
local lastStep = nil
local startedAt = nil
local postRenderFrames = 0
local lastScan = 0
local seenFiles = {}

local function log( message )
	local line = string.format( "[%0.3f] %s", SysTime(), tostring( message ) )
	print( "[MC preset passive debug] " .. line )
	file.CreateDir( "mc" )
	file.CreateDir( "mc/debug" )
	file.Append( LOG_PATH, line .. "\n" )
end

local function captureHookNames()
	local names = {}
	local postRender = hook.GetTable().PostRender or {}
	for name in pairs( postRender ) do
		if string.StartWith( tostring( name ), "MC_PresetCoverCapture_" ) then
			names[#names + 1] = tostring( name )
		end
	end
	table.sort( names )
	return #names > 0 and table.concat( names, "," ) or "none"
end

local function scanCoverFiles()
	local files = file.Find( "mc/preset_covers/*.jpg", "DATA" ) or {}
	for _, fileName in ipairs( files ) do
		local path = "mc/preset_covers/" .. fileName
		local size = file.Size( path, "DATA" ) or -1
		if seenFiles[path] == nil then
			seenFiles[path] = size
			log( string.format( "local cover appeared: %s (%d bytes)", path, size ) )
		elseif seenFiles[path] ~= size then
			local old = seenFiles[path]
			seenFiles[path] = size
			log( string.format( "local cover changed: %s (%d -> %d bytes)", path, old, size ) )
		end
	end
end

hook.Add( "Think", PREFIX .. "_state", function()
	local step = tonumber( MC.PresetSelectionStep or 0 ) or 0
	if step ~= lastStep then
		log( string.format( "PresetSelectionStep: %s -> %s; captureHooks=%s", tostring( lastStep ), tostring( step ), captureHookNames() ) )
		if step == 4 then
			startedAt = SysTime()
			postRenderFrames = 0
			log( string.format( "capture window started: screen=%dx%d", ScrW(), ScrH() ) )
		elseif startedAt then
			log( string.format( "capture window ended after %.3fs; PostRender frames=%d; captureHooks=%s", SysTime() - startedAt, postRenderFrames, captureHookNames() ) )
			startedAt = nil
		end
		lastStep = step
	end

	if SysTime() - lastScan >= 0.5 then
		lastScan = SysTime()
		scanCoverFiles()
		if startedAt and SysTime() - startedAt > 5.5 then
			log( string.format( "capture window exceeded 5.5s; PostRender frames=%d; captureHooks=%s", postRenderFrames, captureHookNames() ) )
			startedAt = nil
		end
	end
end )

hook.Add( "PostRender", PREFIX .. "_render", function()
	if lastStep ~= 4 then return end
	postRenderFrames = postRenderFrames + 1
	if postRenderFrames <= 3 then
		log( string.format( "PostRender observed frame %d: screen=%dx%d; captureHooks=%s", postRenderFrames, ScrW(), ScrH(), captureHookNames() ) )
	end
end )

hook.Add( "OnLuaError", PREFIX .. "_errors", function( message, realm )
	local text = tostring( message or "" )
	if string.find( text, "cl_presets", 1, true ) or string.find( text, "render.Capture", 1, true ) then
		log( string.format( "OnLuaError realm=%s: %s", tostring( realm ), text ) )
	end
end )

local function stop()
	hook.Remove( "Think", PREFIX .. "_state" )
	hook.Remove( "PostRender", PREFIX .. "_render" )
	hook.Remove( "OnLuaError", PREFIX .. "_errors" )
	log( "passive debug stopped" )
end

MC.PresetCaptureDebugPassiveStop = stop
concommand.Remove( "mc_preset_capture_debug_passive_stop" )
concommand.Add( "mc_preset_capture_debug_passive_stop", stop )
log( "passive debug loaded; reproduce one preset save now" )
