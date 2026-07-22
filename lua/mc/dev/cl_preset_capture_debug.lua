-- Manual client-side diagnostics for preset cover capture.
-- Load with: lua_openscript_cl mc/dev/cl_preset_capture_debug.lua
-- Stop with: mc_preset_capture_debug_stop

if not CLIENT then return end

MC = MC or {}

if MC.PresetCaptureDebug and MC.PresetCaptureDebug.Stop then

	MC.PresetCaptureDebug.Stop()
end

local HOOK_PREFIX = "MC_PresetCaptureDebug"
local LOG_PATH = "mc/debug/preset_capture.log"
local state = {
	lastStep = nil,
	captureStartedAt = nil,
	postRenderFrames = 0,
	lastFileScan = 0,
	seenFiles = {},
	currentNet = nil,
}

local oldCapture = render.Capture
local oldFileWrite = file.Write
local oldNetStart = net.Start
local oldNetSendToServer = net.SendToServer

local function appendLog( message )
	local line = string.format( "[%0.3f] %s", SysTime(), tostring( message ) )
	print( "[MC preset debug] " .. line )
	file.CreateDir( "mc" )
	file.CreateDir( "mc/debug" )
	file.Append( LOG_PATH, line .. "\n" )
end

local function formatError( err )
	if debug and debug.traceback then return debug.traceback( tostring( err ), 2 ) end
	return tostring( err )
end

local function isCoverPath( path )
	return string.find( string.lower( tostring( path or "" ) ), "mc/preset_covers/", 1, true ) ~= nil
end

local function scanCoverFiles()
	local files = file.Find( "mc/preset_covers/*.jpg", "DATA" ) or {}
	for _, fileName in ipairs( files ) do
		local path = "mc/preset_covers/" .. fileName
		local size = file.Size( path, "DATA" ) or -1
		local previous = state.seenFiles[path]
		if previous == nil then
			state.seenFiles[path] = size
			appendLog( string.format( "cover file present: %s (%d bytes)", path, size ) )
		elseif previous ~= size then
			state.seenFiles[path] = size
			appendLog( string.format( "cover file size changed: %s (%d -> %d bytes)", path, previous, size ) )
		end
	end
end

render.Capture = function( options )
	local opts = options or {}
	local summary = string.format(
		"render.Capture called: format=%s quality=%s rect=%sx%s+%s+%s",
		tostring( opts.format ), tostring( opts.quality ), tostring( opts.w ), tostring( opts.h ),
		tostring( opts.x ), tostring( opts.y )
	)
	appendLog( summary )

	local ok, data = xpcall( function()
		return oldCapture( options )
	end, function( err )
		return formatError( err )
	end )
	if not ok then
		appendLog( "render.Capture ERROR: " .. tostring( data ) )
		error( data, 0 )
	end

	if not data or data == "" then
		appendLog( "render.Capture returned EMPTY data" )
	else
		local b1, b2 = string.byte( data, 1 ), string.byte( data, 2 )
		appendLog( string.format( "render.Capture returned %d bytes, header=%s,%s", #data, tostring( b1 ), tostring( b2 ) ) )
	end
	return data
end

file.Write = function( path, data, where )
	local result = oldFileWrite( path, data, where )
	if isCoverPath( path ) then
		local size = file.Size( path, where or "DATA" ) or -1
		appendLog( string.format( "file.Write cover: %s input=%d bytes onDisk=%d", tostring( path ), #( data or "" ), size ) )
	end
	return result
end

net.Start = function( name, unreliable )
	state.currentNet = tostring( name )
	if string.StartWith( state.currentNet, "mc_preset_cover_" ) then
		appendLog( string.format( "net.Start %s unreliable=%s", state.currentNet, tostring( unreliable ) ) )
	end
	return oldNetStart( name, unreliable )
end

net.SendToServer = function( ... )
	if state.currentNet and string.StartWith( state.currentNet, "mc_preset_cover_" ) then
		appendLog( "net.SendToServer " .. state.currentNet )
	end
	local result = oldNetSendToServer( ... )
	state.currentNet = nil
	return result
end

hook.Add( "Think", HOOK_PREFIX .. "_state", function()
	local step = tonumber( MC.PresetSelectionStep or 0 ) or 0
	if step ~= state.lastStep then
		appendLog( string.format( "PresetSelectionStep: %s -> %s", tostring( state.lastStep ), tostring( step ) ) )
		state.lastStep = step
		if step == 4 then
			state.captureStartedAt = SysTime()
			state.postRenderFrames = 0
			appendLog( string.format( "capture window started: screen=%dx%d paused=%s", ScrW(), ScrH(), tostring(game.IsPaused and game.IsPaused() or false) ) )
		elseif state.captureStartedAt then
			appendLog( string.format( "capture window ended after %.3fs; observed PostRender frames=%d", SysTime() - state.captureStartedAt, state.postRenderFrames ) )
			state.captureStartedAt = nil
		end
	end

	if SysTime() - state.lastFileScan >= 0.5 then
		state.lastFileScan = SysTime()
		scanCoverFiles()
	end
end )

hook.Add( "PostRender", HOOK_PREFIX .. "_render", function()
	if state.lastStep ~= 4 then return end
	state.postRenderFrames = state.postRenderFrames + 1
	if state.postRenderFrames <= 5 then
		appendLog( string.format( "PostRender frame %d: screen=%dx%d", state.postRenderFrames, ScrW(), ScrH() ) )
	end
end )

hook.Add( "OnLuaError", HOOK_PREFIX .. "_errors", function( message, realm )
	local text = tostring( message or "" )
	if string.find( text, "cl_presets", 1, true ) or string.find( text, "render.Capture", 1, true ) then
		appendLog( string.format( "OnLuaError realm=%s: %s", tostring( realm ), text ) )
	end
end )

function MC.PresetCaptureDebugStop()
	if MC.PresetCaptureDebug and MC.PresetCaptureDebug.Stop then MC.PresetCaptureDebug.Stop() end
end

MC.PresetCaptureDebug = {
	Stop = function()
		hook.Remove( "Think", HOOK_PREFIX .. "_state" )
		hook.Remove( "PostRender", HOOK_PREFIX .. "_render" )
		hook.Remove( "OnLuaError", HOOK_PREFIX .. "_errors" )
		render.Capture = oldCapture
		file.Write = oldFileWrite
		net.Start = oldNetStart
		net.SendToServer = oldNetSendToServer
		appendLog( "debug stopped; original functions restored" )
	end,
}

concommand.Remove( "mc_preset_capture_debug_stop" )
concommand.Add( "mc_preset_capture_debug_stop", function()
		if MC.PresetCaptureDebug and MC.PresetCaptureDebug.Stop then MC.PresetCaptureDebug.Stop() end
end )

appendLog( "debug loaded; reproduce one preset save now" )
