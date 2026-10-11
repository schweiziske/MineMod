if SERVER then return end

MC = MC or {}
if MC.ClientPerformance then MC.ClientPerformance.Stop( "analysis_reloaded" ) end
local P = {}
MC.ClientPerformance = P
local active

local function say( message ) print( "[MC performance] " .. message ) end

-- Stage self time deducts instrumented children. Hook rows remain inclusive
-- and are a separate ranking, never added to stage totals or frame intervals.
function P.Analyze( report )
	local result = { label = report.label, mode = report.mode, status = report.status, reason = report.reason,
		frames = report.frames, frameMS = report.frameMS, stages = {}, callbacks = {}, slowStages = {},
		unfocusedFrames = 0, missingStages = report.missingStages, replacedStages = report.replacedStages,
		workStart = report.workStart, workEnd = report.workEnd, worldChanges = report.worldChanges,
		observerMS = report.sampleObserverMS,
		notes = {
			"All timings are client wall time, including possible engine/driver waits; GPU time is unmeasured.",
			"Stage self time excludes instrumented children only. Hook rankings overlap stage rankings.",
			"Slow stages cover the retained slowest frames, not every slow frame.",
			"Server collision must be recorded on the server; a missing client convar does not mean zero.",
		},
	}
	for _, window in ipairs( report.windows ) do result.unfocusedFrames = result.unfocusedFrames + window.unfocusedFrames end
	result.valid = report.status == "complete" and not report.failedStage and result.unfocusedFrames == 0
		and #report.replacedStages == 0
	result.fpsValid = result.valid and report.mode == "watch"
	local frames = math.max( report.frames, 1 )
	if result.fpsValid and report.frameMS and report.frameMS.mean > 0 then result.fps = 1000 / report.frameMS.mean end
	for index, name in ipairs( report.stages ) do
		local row = report.totals[index]
		if row[1] > 0 then
			result.stages[#result.stages + 1] = { name = name, calls = row[1], inclusiveMS = row[2], selfMS = row[3],
				selfPerFrameMS = row[3] / frames, maxCallMS = row[4], errors = row[5] }
		end
		local slow = { name = name, selfMS = 0, inclusiveMS = 0 }
		for _, frame in ipairs( report.slowest ) do
			if frame.focused == true then
				slow.selfMS = slow.selfMS + frame.stages[index][3]
				slow.inclusiveMS = slow.inclusiveMS + frame.stages[index][2]
			end
		end
		if slow.selfMS > 0 then result.slowStages[#result.slowStages + 1] = slow end
	end
	table.sort( result.stages, function( a, b ) return a.selfMS > b.selfMS end )
	table.sort( result.slowStages, function( a, b ) return a.selfMS > b.selfMS end )
	if report.hooks then
		for index, callback in ipairs( report.hooks.callbacks ) do
			local row = report.hooks.totals[index]
			if row[1] > 0 then
				result.callbacks[#result.callbacks + 1] = { event = callback.event, name = callback.id,
					calls = row[1], inclusiveMS = row[2], perFrameMS = row[2] / frames, maxCallMS = row[3] }
			end
		end
		table.sort( result.callbacks, function( a, b ) return a.inclusiveMS > b.inclusiveMS end )
	end
	return result
end

local function reportText( result )
	local lines = { string.format( "%s: %s (%s), valid=%s, frames=%d, unfocused=%d",
		result.label, result.status, result.reason, tostring( result.valid ), result.frames, result.unfocusedFrames ) }
	local frame = result.frameMS
	if frame then
		if result.fpsValid then
			lines[#lines + 1] = string.format( "Frame mean=%.2fms (~%.1f FPS), p95=%.2fms p99=%.2fms max=%.2fms",
				frame.mean, result.fps, frame.p95, frame.p99, frame.max )
		else
			lines[#lines + 1] = string.format( "All captured intervals: mean=%.2fms p95=%.2fms p99=%.2fms max=%.2fms; steady FPS unavailable",
				frame.mean, frame.p95, frame.p99, frame.max )
		end
	end
	lines[#lines + 1] = "Client stage ranking: self wall time; GPU unmeasured"
	for index = 1, math.min( 10, #result.stages ) do
		local row = result.stages[index]
		lines[#lines + 1] = string.format( "%d. %s self=%.2fms/frame total=%.2fms maxCall=%.2fms calls=%d",
			index, row.name, row.selfPerFrameMS, row.selfMS, row.maxCallMS, row.calls )
	end
	lines[#lines + 1] = "Client hook ranking: inclusive, overlaps stages and other hooks"
	for index = 1, math.min( 5, #result.callbacks ) do
		local row = result.callbacks[index]
		lines[#lines + 1] = string.format( "%d. %s.%s %.2fms/frame maxCall=%.2fms", index,
			row.event, row.name, row.perFrameMS, row.maxCallMS )
	end
	local work = result.workEnd
	if work then
		lines[#lines + 1] = string.format( "Final queues: chunks=%d geometry=%d light=%d native=%d sky=%s snapshot=%s cleanup=%d",
			work.chunks, work.geometryKeys, work.lightKeys, work.nativePending, tostring( work.skyPending ),
			tostring( work.snapshotPending ), work.cleanupPending )
	end
	lines[#lines + 1] = string.format( "Coverage: missingStages=%d replacedStages=%d observer=%.2fms",
		#result.missingStages, #result.replacedStages, result.observerMS )
	if result.mode == "load" then lines[#lines + 1] = "Loading frame averages include waiting/building; use raw per-second windows for each phase." end
	if result.unfocusedFrames > 0 then lines[#lines + 1] = "Capture contains unfocused frames; total means/rankings mix focus states. Slow-stage sums retain focused frames only." end
	return table.concat( lines, "\n" )
end

local function restoreStream( capture )
	if not capture.stream then return end
	if MC.StreamPerformanceStats == capture.stream then
		MC.SetStreamPerformanceEnabled( false )
		MC.StreamPerformanceStats = capture.previousStream
	else
		MC.Fault( "performance_stream_replaced", "stream capture was replaced during %s", capture.label )
	end
end

hook.Add( "MCNativeBenchComplete", "mc_client_performance", function( report, path )
	local capture = active
	if capture then
		active = nil
		if MC.StreamPerformanceStats == capture.stream then capture.streamReport = MC.GetStreamPerformanceSnapshot() end
		restoreStream( capture )
	end
	local result = P.Analyze( report )
	result.sourcePath = path
	result.stream = capture and capture.streamReport
	P.last = result
	P.lastText = reportText( result )
	P.lastPath = path:gsub( "%.json$", "_analysis.json" )
	local encoded = util.TableToJSON( result, true )
	if not MC.Check( encoded ~= nil, "performance_analysis_encode", "could not encode %s", report.label ) then return end
	file.Write( P.lastPath, encoded )
	local textPath = path:gsub( "%.json$", "_analysis.txt" )
	file.Write( textPath, P.lastText )
	MC.Check( file.Size( P.lastPath, "DATA" ) == #encoded and file.Size( textPath, "DATA" ) == #P.lastText,
		"performance_analysis_write", "could not write analysis for %s", report.label )
	say( P.lastText )
	say( "garrysmod/data/" .. P.lastPath )
end )

hook.Add( "MCNativeBenchAborted", "mc_client_performance", function( failure )
	if active then
		local capture = active
		active = nil
		restoreStream( capture )
	end
	MC.Fault( "performance_capture_aborted", "%s", failure )
end )

function P.Start( args )
	if active then return nil, "Client capture already running; use mc_perf_stop" end
	local bench = MC.Need( MC.NativeBench, "performance_bench_missing", "mc_native_bench.lua did not load" )
	if not bench then return nil, "NativeBench unavailable" end
	local mode = args[3] or "watch"
	if mode ~= "watch" and mode ~= "load" then return nil, "Usage: mc_perf_start <label> [seconds 5..120] [watch|load]" end
	if mode == "load" then
		if not MC.Check( type( MC.StreamPerformanceEnabled ) == "function" and type( MC.ResetStreamPerformanceStats ) == "function"
			and type( MC.GetStreamPerformanceSnapshot ) == "function" and type( MC.SetStreamPerformanceEnabled ) == "function",
			"performance_stream_missing", "cl_net.lua stream profiling API unavailable" ) then return nil, "Stream profiler unavailable" end
		if MC.StreamPerformanceEnabled() then return nil, "Another stream capture is active" end
	end
	local ok, err = bench.Start( { args[1] or "client", args[2] or ( mode == "load" and "120" or "15" ), mode, "4", "hooks" } )
	if not ok then return nil, err end
	active = { label = args[1] or "client" }
	if mode == "load" then
		active.previousStream = MC.StreamPerformanceStats
		MC.ResetStreamPerformanceStats( { maxPatches = 32, maxAftermathFrames = 512 } )
		active.stream = MC.StreamPerformanceStats
	end
	return true
end

function P.Stop( reason )
	if not active then return end
	MC.NativeBench.Stop( reason or "cancelled" )
	if active then
		local capture = active
		active = nil
		restoreStream( capture )
	end
end

concommand.Add( "mc_perf_start", function( _, _, args )
	local ok, err = P.Start( args )
	if not ok then say( err ) end
end, nil, "Capture client loading/rendering and write ranked JSON/text analysis" )
concommand.Add( "mc_perf_stop", function() P.Stop() end )
concommand.Add( "mc_perf_status", function() say( util.TableToJSON( MC.NativeBench.Status() ) ) end )
concommand.Add( "mc_perf_report", function()
	if P.last then say( P.lastText ) say( "garrysmod/data/" .. P.lastPath )
	else say( "No report yet; use mc_perf_start <label> [seconds] [watch|load]" ) end
end )
