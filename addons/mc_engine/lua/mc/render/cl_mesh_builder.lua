-- Native L2 section construction. Published geometry is immutable.
MC = MC or {}
local RM = MC.RenderMesh
local GeometryStore, Snapshot = MC.RenderGeometryStore, MC.RenderSnapshot
local Occlusion, SectionCull = MC.RenderOcclusion, MC.RenderSectionCull
local meshPerfAdd = RM.meshPerfAdd
local destroySectionMeshList = RM.destroySectionMeshList

local function noteVisibilityStats( perf, failed )
	local pipeline = MC.RenderPipeline
	if not pipeline or not pipeline.NoteVisibility then return end
	pipeline.NoteVisibility( perf.visibilitySections or 0, perf.visibilityQueries or 0,
		perf.visibilityCacheHits or 0, perf.visibilityStateReads or 0,
		perf.visibilitySnapshotReads or 0, perf.visibilityClassResolves or 0, failed and 1 or 0 )
end

local function build( key, sectionIndex, lightOnly )
	local world = MC.NativeChunkBackend
	local native = MC.NativeL2
	local deferLighting = not lightOnly and sectionIndex ~= nil and MC.MeshSections[key] ~= nil
		and world and world.IsActive() and native and native.IsActive() and native.deferredLightingAvailable
	local lightPending = world and world.IsActive() and not world.IsLightReady( key, sectionIndex )
	if lightPending and not deferLighting then return "blocked" end
	if native and native.IsActive() then
		if native.IsPending( key, sectionIndex ) then return "pending" end
		if not native.CanBuild() then return "deferred" end
		if lightOnly and native.TryRelight then
			local result = native.TryRelight( key, sectionIndex )
			if result ~= nil then return result end
		end
	end
	local started, perf = SysTime(), RM.newMeshPerfStats()
	local probe = RM.meshEmitProbeEnabled()
	RM.resetMeshLightingSampleCaches()
	RM.resetMeshColorObjectCache()
	if MC.LightPerfBeginMeshBuild then MC.LightPerfBeginMeshBuild( key, sectionIndex ) end
	local chunk = MC.GetChunkByKey( key )
	local ctx, opaque, translucent, opaqueRecords, translucentRecords
	local topology
	local faults = {}
	local function queueFault( code, message )
		faults[#faults + 1] = { code = code, message = tostring( message ) }
	end
	local function reportFaults()
		local firstError
		for _, fault in ipairs( faults ) do
			local ok, err = pcall( MC.Fault, fault.code, "%s", fault.message )
			if not ok and not firstError then firstError = err end
		end
		if firstError then error( firstError, 0 ) end
	end
	local function retire( section )
		if not section then return end
		destroySectionMeshList( section.opaque, queueFault )
		destroySectionMeshList( section.translucent, queueFault )
	end

	if chunk and chunk.count > 0 then
		local indexStart = SysTime()
		local snapshots, err
		local prepared = true
		if native and native.WorldSnapshot then prepared, snapshots = pcall( native.WorldSnapshot, chunk, sectionIndex ) end
		if not prepared then err, snapshots = snapshots, nil
		elseif not snapshots then snapshots, err = Snapshot.Prepare( chunk, sectionIndex ) end
		meshPerfAdd( perf, "indexMS", indexStart )
		if not snapshots then
			MC.Fault( type( err ) == "table" and err.code or "render_snapshot_prepare_failed",
				"chunk %s section %s: %s; previous L2 section retained",
				tostring( key ), tostring( sectionIndex ), tostring( type( err ) == "table" and err.message or err ) )
			return false
		end
		if sectionIndex then
			if not snapshots[sectionIndex].nativeOnly then topology = Occlusion.BuildTopology( snapshots[sectionIndex] ) end
		else
			topology = {}
			for index = 1, Snapshot.SECTION_COUNT do topology[index] = Occlusion.BuildTopology( snapshots[index] ) end
		end
		if not sectionIndex then MC.ClearChunkBlockEmitCache( key ) end
		if not sectionIndex or snapshots[sectionIndex].count > 0 then
			local ok
			ok, err = pcall( function()
				ctx = RM.NewBuildContext( key, sectionIndex, chunk, perf, probe, "l2", started, nil, snapshots, lightOnly )
				ctx.generatedCullPlans = RM.PrepareGeneratedPlanCulling( snapshots, sectionIndex )
				ctx.nativeDeferLighting, ctx.nativeLightPending = deferLighting == true, lightPending == true
				local loopStart = SysTime()
				RM.withIsolatedRawLighting( ctx.bxo, ctx.byo, ctx.bzo, function()
					for index = sectionIndex or 1, sectionIndex or Snapshot.SECTION_COUNT do
						local snapshot = snapshots[index]
						if snapshot.count > 0 then
							ctx.beginSection( index )
								local recipes
								if ctx.nativeL2 then recipes = native.PrepareVoxels( ctx, index, snapshot ) end
							for i = 1, snapshot.nativeOnly and 0 or snapshot.count do
									if ( not recipes or not recipes[snapshot.states[i]] )
										and RM.EmitBlock( ctx, snapshot.indices[i], snapshot.states[i] ) == false then
									error( { code = "render_visibility_failed", message = ctx.visibility.error }, 0 )
								end
							end
						end
					end
				end )
				meshPerfAdd( perf, "loopMS", loopStart )
				local flushStart = SysTime()
				opaque, translucent, opaqueRecords, translucentRecords = ctx.flushSectionBuffers()
				meshPerfAdd( perf, "flushMS", flushStart )
			end )
			noteVisibilityStats( perf, not ok )
			if not ok then
				-- Finish all resource cleanup before strict-mode fault reporting can throw.
				if ctx then ctx.discardSectionBuffers( queueFault ) end
				queueFault( type( err ) == "table" and err.code or "render_l2_build",
					string.format( "chunk %s section %s: %s; previous L2 section retained",
						tostring( key ), tostring( sectionIndex ),
						tostring( type( err ) == "table" and err.message or err ) ) )
				reportFaults()
				return false
			end
		end
	end
	if not ctx then
		opaque, translucent, opaqueRecords, translucentRecords = {}, {}, {}, {}
	end
	if chunk and not topology then
		if sectionIndex then topology = Occlusion.OPEN
		else
			topology = {}
			for index = 1, Snapshot.SECTION_COUNT do topology[index] = Occlusion.OPEN end
		end
	end

	local preparationMS
	local function commit()
		local completionStart = SysTime()
		-- Deferred uploads fill the section-owned lists, not the earlier flat copies.
		if ctx and ctx.nativeL2 then
			opaque, translucent, opaqueRecords, translucentRecords = ctx.flushSectionBuffers()
			if ctx.nativeTopology then topology = ctx.nativeTopologyValue end
		end
		local function publishSection( index, opaqueList, translucentList, opaqueCPU, translucentCPU )
			if #opaqueList == 0 and #translucentList == 0 then
				MC.MeshSections[key][index] = nil
				MC.ClearSectionBlockEmitCache( key, index )
				GeometryStore.ForgetSection( key, index )
				return
			end
			local section = { l2 = true, chunk = chunk, blockSize = ctx.blockSize, worldGeneration = MC.StateWorldGeneration,
				opaque = opaqueList, translucent = translucentList,
				bounds = SectionCull.SectionBounds( index, ctx.blockSize, opaqueList, translucentList ) }
			if ctx.nativeTopology then
				section.nativeRecipes, section.nativeWorldHandle = native.cubeRevision, ctx.nativeWorldHandle
			end
			MC.MeshSections[key][index] = section
			-- Ownership transfers before any retirement/diagnostic call can throw.
			ctx.sectionBuffers[index].published = true
			ctx.nativePublished = ctx.nativeL2
			GeometryStore.SetSection( key, index, GeometryStore.MakeSection( opaqueCPU, translucentCPU ), section )
			GeometryStore.TouchSection( key, index )
		end

		local commitStart = SysTime()
		if sectionIndex then
			local sections = MC.MeshSections[key]
			if not sections then sections = {} MC.MeshSections[key] = sections end
			local old = sections[sectionIndex]
			publishSection( sectionIndex, opaque, translucent, opaqueRecords, translucentRecords )
			retire( old )
			MC.ClearSectionBlockEmitDirty( key, sectionIndex )
			MC.ClearSectionBlockLightDirty( key, sectionIndex )
			if MC.MeshLightDirty[key] then MC.MeshLightDirty[key][sectionIndex] = nil end
		else
			local old = MC.MeshSections[key]
			MC.MeshSections[key] = {}
			GeometryStore.ClearChunk( key )
			MC.ClearChunkMeshSectionGeometryLRU( key )
			if ctx then
				for index, buffers in pairs( ctx.sectionBuffers ) do
					publishSection( index, buffers.opaque.list, buffers.translucent.list,
						buffers.opaque.records, buffers.translucent.records )
				end
			else MC.ClearChunkBlockEmitCache( key ) end
			for _, section in pairs( old or {} ) do retire( section ) end
			MC.MeshLightDirty[key] = nil
		end
		Occlusion.Commit( key, chunk, sectionIndex, topology )
		local flatStart = SysTime()
		RM.rebuildFlatMeshLists( key )
		meshPerfAdd( perf, "flatMS", flatStart )
		GeometryStore.Prune()
		MC.PruneBlockEmitCache()
		meshPerfAdd( perf, "commitMS", commitStart )

		local elapsed = math.Round( preparationMS and
			( preparationMS + ( ctx.nativeUploadMS or 0 ) + ( SysTime() - completionStart ) * 1000 )
			or ( SysTime() - started ) * 1000, 3 )
		local stats = MC.RenderStats
		stats.lastMeshLatencyMS = math.Round( ( SysTime() - started ) * 1000, 3 )
		stats.lastMeshBuildMS, stats.lastMeshKey, stats.lastMeshSection = elapsed, key, sectionIndex or "full"
		stats.lastMeshBlocks, stats.lastMeshVertices, stats.lastMeshFaces = chunk and chunk.count or 0, perf.vertices, perf.faces
		stats.lastOpaqueMeshes, stats.lastTranslucentMeshes = #opaque, #translucent
		if MC.LightPerfStats then
			MC.LightPerfStats.lastMeshLightStyle = "l2"
			MC.LightPerfStats.lastMeshMode = lightOnly and "l2_light" or "l2_geometry"
			MC.LightPerfStats.lastMeshRecords, MC.LightPerfStats.lastMeshFallback = nil, nil
		end
		RM.publishMeshPerfStats( perf )
		RM.noteMeshLightingCacheStats()
		RM.printMeshEmitProbe( key, sectionIndex, elapsed, perf )
		if MC.LightPerfEndMeshBuild then MC.LightPerfEndMeshBuild( key, sectionIndex, elapsed ) end
		if MC.RenderPipeline and MC.RenderPipeline.RecordBuild then
			MC.RenderPipeline.RecordBuild( key, sectionIndex, lightOnly and "light" or "geometry",
				stats.lastMeshBlocks, perf.vertices, perf.faces, #opaque, #translucent, elapsed )
			MC.RenderPipeline.NoteBuildStages( perf )
		end
		reportFaults()
		return true
	end
	if ctx and ctx.nativeL2 and ( #ctx.nativeParts > 0 or ctx.nativeVoxels ) then
		local ok, submitted = pcall( native.Submit, ctx, commit, ctx.discardSectionBuffers )
		preparationMS = ( SysTime() - started ) * 1000
		if not ok or not submitted then
			ctx.discardSectionBuffers( queueFault )
			if not ok then
				queueFault( type( submitted ) == "table" and submitted.code or "native_l2_submit",
					type( submitted ) == "table" and submitted.message or submitted )
				reportFaults()
				return false
			end
			return "deferred"
		end
		return "pending"
	end
	return commit()
end

function MC.BuildChunkMesh( key, sectionIndex )
	return build( key, sectionIndex, false )
end

function MC.RebuildChunkMeshLighting( key, sectionIndex )
	-- Reuse unchanged block emissions, regenerate dirty corners, then atomically
	-- publish a local section. No L1 recoloring or world-wide pack preparation.
	return build( key, sectionIndex, true )
end
