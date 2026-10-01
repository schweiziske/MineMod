-- L1 render-pipeline boundary. Keeps backend facts numeric and flat.
MC = MC or {}
local Pipeline = MC.RenderPipeline or {}
MC.RenderPipeline = Pipeline
Pipeline.VERSION = 1
Pipeline.SECTION_SIZE = Pipeline.SECTION_SIZE or 8
Pipeline.stats = Pipeline.stats or {
	builds = 0, lightBuilds = 0, fallbackBuilds = 0,
	blocks = 0, vertices = 0, faces = 0,
	opaqueMeshes = 0, translucentMeshes = 0,
	lastMS = 0, lastKey = nil, lastSection = nil, lastMode = nil,
	dirtyEnqueues = 0, dirtyBuilds = 0, dirtyQueuePeak = 0,
}
local visibilityFields = {
	"visibilitySections", "visibilityQueries", "visibilityCacheHits",
	"visibilityStateReads", "visibilitySnapshotReads", "visibilityClassResolves",
	"visibilityBuildFailures",
}
for i = 1, #visibilityFields do
	local field = visibilityFields[i]
	Pipeline.stats[field] = Pipeline.stats[field] or 0
end
local dirtyFrameFields = {
	"dirtyScheduleFrames", "dirtyAttempts", "dirtyFailures", "dirtyRateLimitedAttempts",
	"dirtyBudgetYields", "dirtyRateLimitedYields", "dirtySelectionMS", "dirtyScheduleMS",
	"animationAttempts", "animationFailures", "animationPrepareMS",
}
for i = 1, #dirtyFrameFields do
	local field = dirtyFrameFields[i]
	Pipeline.stats[field] = Pipeline.stats[field] or 0
end
local buildStageFields = { "indexMS", "prepMS", "loopMS", "flushMS", "commitMS", "flatMS",
	"meshNewMS", "buildTriMS", "cornerUploadMS" }
Pipeline.buildStages = Pipeline.buildStages or {}
for i = 1, #buildStageFields do
	local field = buildStageFields[i]
	Pipeline.buildStages[field] = Pipeline.buildStages[field] or 0
end

-- Reuse the builder's boundary timers; no per-block or per-vertex clocks.
function Pipeline.NoteBuildStages( perf )
	local stages = Pipeline.buildStages
	for i = 1, #buildStageFields do
		local field = buildStageFields[i]
		stages[field] = stages[field] + ( perf[field] or 0 )
	end
end

-- Stable section result contract: key, sectionIndex, mode, blocks, vertices,
-- faces, opaqueMeshes, translucentMeshes, buildMS.
function Pipeline.RecordBuild( key, sectionIndex, mode, blocks, vertices, faces, opaqueMeshes, translucentMeshes, buildMS )
	local s = Pipeline.stats
	s.builds = s.builds + 1
	if mode == "light" then s.lightBuilds = s.lightBuilds + 1 end
	if mode == "fallback" then s.fallbackBuilds = s.fallbackBuilds + 1 end
	s.blocks = s.blocks + ( tonumber( blocks ) or 0 )
	s.vertices = s.vertices + ( tonumber( vertices ) or 0 )
	s.faces = s.faces + ( tonumber( faces ) or 0 )
	s.opaqueMeshes = s.opaqueMeshes + ( tonumber( opaqueMeshes ) or 0 )
	s.translucentMeshes = s.translucentMeshes + ( tonumber( translucentMeshes ) or 0 )
	s.lastMS = tonumber( buildMS ) or 0
	s.lastKey, s.lastSection, s.lastMode = key, sectionIndex or "full", mode or "geometry"
end

function Pipeline.ResetStats()
	local s = Pipeline.stats
	s.builds, s.lightBuilds, s.fallbackBuilds = 0, 0, 0
	s.blocks, s.vertices, s.faces = 0, 0, 0
	s.opaqueMeshes, s.translucentMeshes = 0, 0
	s.lastMS, s.lastKey, s.lastSection, s.lastMode = 0, nil, nil, nil
	s.dirtyEnqueues, s.dirtyBuilds, s.dirtyQueuePeak = 0, 0, 0
	for i = 1, #visibilityFields do s[visibilityFields[i]] = 0 end
	for i = 1, #dirtyFrameFields do s[dirtyFrameFields[i]] = 0 end
	for i = 1, #buildStageFields do Pipeline.buildStages[buildStageFields[i]] = 0 end
end

function Pipeline.GetStats() return Pipeline.stats end

-- Count attempted work, including a discarded build. Empty/light-only builds
-- cannot overwrite these counters, so benchmark phase deltas remain meaningful.
function Pipeline.NoteVisibility( sections, queries, hits, reads, snapshotReads, resolves, failures )
	local s = Pipeline.stats
	s.visibilitySections = s.visibilitySections + sections
	s.visibilityQueries = s.visibilityQueries + queries
	s.visibilityCacheHits = s.visibilityCacheHits + hits
	s.visibilityStateReads = s.visibilityStateReads + reads
	s.visibilitySnapshotReads = s.visibilitySnapshotReads + snapshotReads
	s.visibilityClassResolves = s.visibilityClassResolves + resolves
	s.visibilityBuildFailures = s.visibilityBuildFailures + failures
end

function Pipeline.NoteDirtyEnqueue( count, queueDepth )
	local s = Pipeline.stats
	s.dirtyEnqueues = s.dirtyEnqueues + ( tonumber( count ) or 1 )
	if queueDepth and queueDepth > s.dirtyQueuePeak then s.dirtyQueuePeak = queueDepth end
end

function Pipeline.NoteDirtyBuild( count )
	Pipeline.stats.dirtyBuilds = Pipeline.stats.dirtyBuilds + ( tonumber( count ) or 1 )
end

-- Queue depth is sampled during selection, not by rescanning on every enqueue.
-- Scheduler time includes selection/build/upload but excludes bulk collision.
function Pipeline.NoteDirtyFrame( attempts, failures, rateAttempts, frameYield, rateYield, queueDepth, selectionMS, scheduleMS,
	animationAttempts, animationFailures, animationMS )
	local s = Pipeline.stats
	animationAttempts, animationFailures = animationAttempts or 0, animationFailures or 0
	s.dirtyScheduleFrames = s.dirtyScheduleFrames + 1
	s.dirtyAttempts = s.dirtyAttempts + attempts - animationAttempts
	s.dirtyFailures = s.dirtyFailures + failures - animationFailures
	s.animationAttempts = s.animationAttempts + animationAttempts
	s.animationFailures = s.animationFailures + animationFailures
	s.animationPrepareMS = s.animationPrepareMS + ( animationMS or 0 )
	s.dirtyRateLimitedAttempts = s.dirtyRateLimitedAttempts + rateAttempts
	s.dirtyBudgetYields = s.dirtyBudgetYields + ( frameYield and 1 or 0 )
	s.dirtyRateLimitedYields = s.dirtyRateLimitedYields + ( rateYield and 1 or 0 )
	s.dirtySelectionMS = s.dirtySelectionMS + selectionMS
	s.dirtyScheduleMS = s.dirtyScheduleMS + scheduleMS
	if queueDepth > s.dirtyQueuePeak then s.dirtyQueuePeak = queueDepth end
end

if concommand and concommand.Add then
	concommand.Add( "mc_render_pipeline_stats", function()
		local s = Pipeline.stats
		print( string.format(
			"[MC pipeline] builds=%d light=%d fallback=%d dirtyEnqueues=%d dirtyBuilds=%d queuePeak=%d vertices=%d faces=%d opaqueMeshes=%d translucentMeshes=%d lastMS=%.3f",
			s.builds, s.lightBuilds, s.fallbackBuilds, s.dirtyEnqueues, s.dirtyBuilds,
			s.dirtyQueuePeak, s.vertices, s.faces, s.opaqueMeshes, s.translucentMeshes, s.lastMS
		) )
		print( string.format(
			"[MC visibility] sections=%d queries=%d hits=%d stateReads=%d snapshotReads=%d classResolves=%d failedBuilds=%d",
			s.visibilitySections, s.visibilityQueries, s.visibilityCacheHits,
			s.visibilityStateReads, s.visibilitySnapshotReads, s.visibilityClassResolves,
			s.visibilityBuildFailures
		) )
		print( string.format(
			"[MC scheduler] frames=%d attempts=%d failures=%d rateAttempts=%d budgetYields=%d rateYields=%d selectionMS=%.3f totalMS=%.3f",
			s.dirtyScheduleFrames, s.dirtyAttempts, s.dirtyFailures, s.dirtyRateLimitedAttempts,
			s.dirtyBudgetYields, s.dirtyRateLimitedYields, s.dirtySelectionMS, s.dirtyScheduleMS
		) )
		print( string.format( "[MC animation scheduler] attempts=%d failures=%d prepareMS=%.3f",
			s.animationAttempts, s.animationFailures, s.animationPrepareMS ) )
		local animationStats = MC.Need( MC.BlockAnimationStats,
			"render_pipeline_animation_stats_missing", "block animation statistics are unavailable" )
		if animationStats then
			local a = animationStats()
			print( string.format( "[MC animation work] scans=%d chunks=%d states=%d candidates=%d scanMS=%.3f workMS=%.3f",
				a.scanPasses, a.scannedChunks, a.classifiedStates, a.candidateCells, a.scanMS, a.workMS ) )
			print( string.format( "[MC animation detail] fluidBuilds=%d modelBuilds=%d localRefreshes=%d globalRefreshes=%d uploads=%d skippedUploads=%d fluidBuildMS=%.3f fluidLightMS=%.3f modelMS=%.3f uploadMS=%.3f",
				a.builds, a.modelBuilds, a.localLightRefreshes, a.globalLightRefreshes, a.uploads, a.skippedLightUploads,
				a.fluidBuildMS, a.fluidLightMS, a.modelMS, a.uploadMS ) )
		end
		local stages = Pipeline.buildStages
		print( string.format( "[MC terrain stages] indexMS=%.3f prepMS=%.3f loopMS=%.3f flushMS=%.3f commitMS=%.3f flatMS=%.3f",
			stages.indexMS, stages.prepMS, stages.loopMS, stages.flushMS, stages.commitMS, stages.flatMS ) )
		print( string.format( "[MC terrain uploads] meshNewMS=%.3f vertexUploadMS=%.3f cornerUploadMS=%.3f (included in build stages)",
			stages.meshNewMS, stages.buildTriMS, stages.cornerUploadMS ) )
	end )
end
