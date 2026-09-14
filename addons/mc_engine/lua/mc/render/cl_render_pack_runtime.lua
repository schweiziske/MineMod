-- Frame-boundary material binding for section-owned native L2 geometry.
MC = MC or {}
local L = MC.RenderPackRuntime or { version = 0, faults = {} }
MC.RenderPackRuntime = L
local Catalog, Bindings = MC.RenderPackRegistry, MC.RenderBlockBindings
local G, P, R = MC.RenderPackGeometry, MC.RenderPackResources, MC.RenderL2Resources
local requireValue = R.Require
local DEFAULT_PACK = "mc:vanilla"

function L.QueueFault( code, message )
	if type( message ) == "table" and message.code then code, message = message.code, message.message end
	L.faults[#L.faults + 1] = { code = code, message = tostring( message ) }
end

function L.ReportFaults()
	local pending, firstError = L.faults, nil
	L.faults = {}
	for _, fault in ipairs( pending ) do
		local ok, err = pcall( MC.Fault, fault.code, "%s", fault.message )
		if not ok and firstError == nil then firstError = err end
	end
	if firstError ~= nil then error( firstError, 0 ) end
end

local function releaseSection( section )
	for _, data in ipairs( section.resources ) do G.Release( data, L.QueueFault ) end
	section.resources = {}
end

local function release( runtime )
	if not runtime then return end
	for _, sections in pairs( runtime.sections ) do
		for _, section in pairs( sections ) do releaseSection( section ) end
	end
	runtime.sections = {}
end

local function sameWorld( c )
	return MC.World == c.world and MC.StateWorldGeneration == c.worldGeneration
		and MC.CS == c.cs and MC.CH == c.ch and MC.API.Coords.BlockSize() == c.blockSize
end

local function advanceVersion( c )
	L.version = L.version + 1
	c.version = L.version
end

function L.Select( id )
	local requests, keys, generation = Bindings.Snapshot()
	if not requests then return false, keys end
	local plan, err = Catalog.Plan( id, requests )
	if not plan then return false, err end
	release( L.pending )
	L.pending = { pack = id, plan = plan, bindingKeys = keys, bindingsGeneration = generation,
		phase = "validate", sections = {}, chunks = {}, materials = {}, rebuildRequests = {},
		started = SysTime(), sectionCount = 0, totalQuads = 0, drawEntries = 0, waitingSections = 0 }
	L.selected, L.bootstrapped = id, true
	return true, "preparing"
end

function L.Off()
	-- "Off" disables a custom pack, not the required world vertex format.
	return L.Select( DEFAULT_PACK )
end

function L.Reload()
	local id = L.selected or DEFAULT_PACK
	local requests, err = Bindings.Snapshot()
	if not requests then return false, err end
	local plan
	plan, err = Catalog.Plan( id, requests )
	if not plan then return false, err end
	local discovery = MC.Need( MC.RenderPackDiscovery, "render_pack_reload_discovery", "JSON discovery is unavailable" )
	if not discovery then return false, "render_pack_reload_discovery" end
	local ok
	ok, err = discovery.Reload( plan )
	if not ok then return false, err end
	return L.Select( id )
end

local function beginBindings( c )
	c.stages, c.passByKey = {}, {}
	for _, stage in ipairs( P.STAGES ) do
		local passes = {}
		c.stages[stage] = passes
		for _, node in ipairs( c.bundle.nodes[stage] ) do
			local pass = { node = node, store = {} }
			passes[#passes + 1] = pass
			c.passByKey[node.key] = pass
		end
	end
	c.opaqueStages = { c.stages.world_opaque, c.stages.world_cutout }
	c.translucentStages = { c.stages.world_translucent }
end

local function partitionMatches( c, source, size )
	if source.blockSize ~= size then return false end
	for _, list in ipairs( { source.opaque, source.translucent } ) do
		for _, part in ipairs( list ) do
			requireValue( part.l2 and part.resource and part.mesh, "render_pack_native_geometry",
				"world meshes must be emitted in L2 format; restart the client after upgrading" )
			for id in pairs( part.blockIds ) do
				if part.request ~= ( c.bindingKeys[id] or "terrain" ) then return false end
			end
		end
	end
	return true
end

local function bindSection( c, transaction, source, chunk, size )
	local bound = { source = source, chunk = chunk, resources = {}, passes = {}, quads = 0, draws = 0 }
	transaction.created[#transaction.created + 1] = bound
	for _, list in ipairs( { source.opaque, source.translucent } ) do
		for _, part in ipairs( list ) do
			local data = part.resource
			G.Retain( data )
			bound.resources[#bound.resources + 1] = data
			bound.quads = bound.quads + data.quadCount
			local materialCache = transaction.materials[part.material]
			if not materialCache then materialCache = {} transaction.materials[part.material] = materialCache end
			for _, node in ipairs( P.Passes( transaction.bundle, part.request, part.stage ) ) do
				local material = materialCache[node.key]
				if not material then
					material = P.Material( transaction.bundle, node, part.material, size )
					materialCache[node.key] = material
				end
				local entries = bound.passes[node.key]
				if not entries then entries = {} bound.passes[node.key] = entries end
				entries[#entries + 1] = { mesh = data.mesh, material = material }
				bound.draws = bound.draws + 1
			end
		end
	end
	return bound
end

local function flattenChunk( sections )
	local indices, result = {}, {}
	for index in pairs( sections or {} ) do indices[#indices + 1] = index end
	table.sort( indices )
	for _, index in ipairs( indices ) do
		for key, entries in pairs( sections[index].passes ) do
			local list = result[key]
			if not list then list = {} result[key] = list end
			for _, entry in ipairs( entries ) do list[#list + 1] = entry end
		end
	end
	return result
end

local function copyMaterialNodes( nodes )
	local copy = {}
	for key, value in pairs( nodes or {} ) do copy[key] = value end
	return copy
end

local function syncSections( c, force )
	local started, size = SysTime(), MC.API.Coords.BlockSize()
	requireValue( type( size ) == "number" and size > 0 and size < math.huge,
		"render_pack_block_size", "invalid runtime block size" )
	force = force or c.blockSize ~= size
	local transaction = { created = {}, bundle = P.Fork( c.bundle ), materials = {} }
	if not force then
		for material, nodes in pairs( c.materials ) do
			transaction.materials[material] = copyMaterialNodes( nodes )
		end
		for material, texture in pairs( c.bundle.sources ) do transaction.bundle.sources[material] = texture end
	end
	local sections, chunks, kept, touched, updates, rebuilds, usedMaterials = {}, {}, {}, {}, {}, {}, {}
	local changedSources = {}
	local count, quads, draws, waiting, changed = 0, 0, 0, 0, 0
	local ok, err = pcall( function()
		for key, sources in pairs( MC.MeshSections ) do
			local chunk = MC.GetChunkByKey( key )
			local old = c.sections[key] or {}
			for index, source in pairs( sources ) do
				if chunk then
					requireValue( type( source ) == "table" and source.l2 and source.chunk
						and source.worldGeneration ~= nil, "render_pack_native_geometry",
						"world section is not native L2; restart the client after upgrading" )
				end
				-- Streaming may detach a chunk before its budgeted mesh cleanup.
				if chunk and source.chunk == chunk and source.worldGeneration == MC.StateWorldGeneration then
					local bound = old[index]
					local partitionCurrent = not force and bound and bound.source == source and bound.chunk == chunk
					if not partitionCurrent and not partitionMatches( c, source, size ) then
						waiting = waiting + 1
						local previousRequest = c.rebuildRequests[key] and c.rebuildRequests[key][index]
						rebuilds[key] = rebuilds[key] or {}
						rebuilds[key][index] = source
						if c.bindingsGeneration == Bindings.generation and previousRequest ~= source then
							requireValue( type( MC.RequestRenderSectionGeometry ) == "function",
								"render_pack_rebuild_missing", "native section rebuild queue is unavailable" )
							MC.RequestRenderSectionGeometry( key, index, false )
						end
						if not bound or bound.chunk ~= chunk or not sameWorld( c ) then bound = nil end
					else
						local rebind = force or not bound or bound.source ~= source
						for _, list in ipairs( { source.opaque, source.translucent } ) do
							for _, part in ipairs( list ) do
								local material = part.material
								if changedSources[material] == nil then
									local previousTexture = c.bundle.sources[material]
									local changedSource = not previousTexture or not R.SameTexture( R.SourceTexture( material ), previousTexture )
									changedSources[material] = changedSource
									if changedSource then transaction.materials[material] = nil end
								end
								if changedSources[material] then rebind = true end
							end
						end
						if rebind then
							bound = bindSection( c, transaction, source, chunk, size )
							changed = changed + 1
							touched[key] = true
						end
					end
					if bound then
						sections[key] = sections[key] or {}
						sections[key][index], chunks[key], kept[bound] = bound, chunk, true
						count, quads, draws = count + 1, quads + bound.quads, draws + bound.draws
						for _, list in ipairs( { bound.source.opaque, bound.source.translucent } ) do
							for _, part in ipairs( list ) do
								usedMaterials[part.material] = true
								if not transaction.materials[part.material] then
									transaction.materials[part.material] = copyMaterialNodes( c.materials[part.material] )
									transaction.bundle.sources[part.material] = c.bundle.sources[part.material]
								end
							end
						end
					end
				end
			end
		end
		requireValue( draws <= 65536, "render_pack_draw_budget", "execution plan exceeds 65536 mesh draws" )
		for key, previous in pairs( c.sections ) do
			for _, bound in pairs( previous ) do
				if not kept[bound] then touched[key] = true changed = changed + 1 end
			end
		end
		for key in pairs( touched ) do updates[key] = flattenChunk( sections[key] ) end
		for material in pairs( transaction.materials ) do
			if not usedMaterials[material] then transaction.materials[material] = nil end
		end
		for material in pairs( transaction.bundle.sources ) do
			if not usedMaterials[material] then transaction.bundle.sources[material] = nil end
		end
	end )
	if not ok then
		for _, bound in ipairs( transaction.created ) do releaseSection( bound ) end
		error( err, 0 )
	end
	-- The draw lists and their retained handles change at one frame boundary.
	local previous = c.sections
	for key, update in pairs( updates ) do
		for nodeKey, pass in pairs( c.passByKey ) do pass.store[key] = update[nodeKey] end
	end
	c.sections, c.chunks, c.bundle, c.materials = sections, chunks, transaction.bundle, transaction.materials
	c.rebuildRequests = rebuilds
	c.sectionCount, c.totalQuads, c.drawEntries, c.waitingSections = count, quads, draws, waiting
	c.world, c.worldGeneration, c.cs, c.ch = MC.World, MC.StateWorldGeneration, MC.CS, MC.CH
	c.blockSize, c.drawGeneration = size, MC.ChunkDrawListVersion()
	c.updateMS, c.updatedSections = ( SysTime() - started ) * 1000, #transaction.created
	c.syncCount = ( c.syncCount or 0 ) + 1
	c.syncTotalMS = ( c.syncTotalMS or 0 ) + c.updateMS
	c.failedDrawGeneration = nil
	if changed > 0 or not c.version then advanceVersion( c ) end
	for _, list in pairs( previous ) do
		for _, bound in pairs( list ) do
			if not kept[bound] then releaseSection( bound ) end
		end
	end
end

local function publish( c )
	local previous = L.active
	c.phase, c.prepareMS = "active", ( SysTime() - c.started ) * 1000
	L.active, L.pending, L.lastError = c, nil, nil
	advanceVersion( c )
	release( previous )
	print( string.format( "[MC render pack] active=%s build=%s sections=%d quads=%d native=L2 prepare=%.2fms GPU=unverified",
		c.pack, c.plan.owners["pack/" .. c.pack].definition.build, c.sectionCount, c.totalQuads, c.prepareMS ) )
end

local function updateCandidate( c )
	if c.bindingsGeneration ~= Bindings.generation or not Catalog.IsCurrent( c.plan ) then
		local ok, err = L.Select( c.pack )
		requireValue( ok, "render_pack_reparse", tostring( err ) )
		return
	end
	if c.phase == "validate" then
		c.bundle = P.Validate( c.plan )
		P.Ensure( c.bundle )
		beginBindings( c )
		c.phase = "binding"
	end
	if MC.GlobalLightmapRevision == 0 then
		requireValue( type( MC.SampleGlobalLightmapRGB ) == "function",
			"l2_visual_lightmap_unready", "global lightmap sampler is unavailable" )
		c.phase = "waiting_lightmap"
		return
	end
	if c.phase == "waiting_lightmap" then c.phase = "binding" end
	P.RefreshLightmap()
	if c.phase == "binding" or c.drawGeneration ~= MC.ChunkDrawListVersion() or not sameWorld( c ) then
		syncSections( c )
	elseif not P.SourcesCurrent( c.bundle ) then
		syncSections( c, true )
	end
	if c.waitingSections == 0 then publish( c ) else c.phase = "waiting_meshes" end
end

local function fail( c, err )
	local message = type( err ) == "table" and err.message or tostring( err )
	local code = type( err ) == "table" and err.code or "render_pack_prepare"
	L.lastError = ( c and ( c.pack .. " phase=" .. c.phase .. ": " ) or "" ) .. tostring( message )
	if c == L.pending then
		release( c )
		L.pending = nil
		L.selected = L.active and L.active.pack or L.selected
	elseif c then
		c.failedDrawGeneration, c.failedBindings = MC.ChunkDrawListVersion(), Bindings.generation
		c.failedWorld, c.failedWorldGeneration = MC.World, MC.StateWorldGeneration
		c.failedBlockSize = MC.API.Coords.BlockSize()
		c.retryAt, c.updateError = SysTime() + 1, L.lastError
	end
	L.QueueFault( code, L.lastError .. ( L.active and "; previous L2 runtime retained" or "; no L2 runtime available" ) )
end

function L.Step()
	local frame = FrameNumber()
	if L.lastFrame == frame then return end
	L.lastFrame = frame
	local perf = MC.StreamPerformanceEnabled and MC.StreamPerformanceEnabled()
	local started = perf and SysTime()
	if not L.bootstrapped and MC.API.IsAvailable() then
		local generation = Catalog.Status().generation
		if L.bootAttemptGeneration ~= generation then
			L.bootAttemptGeneration = generation
			local ok, err = L.Select( DEFAULT_PACK )
			if not ok then fail( nil, { code = "render_pack_default", message = err } ) end
		end
	end
	local c = L.active
	if c then
		local retry = c.failedDrawGeneration ~= MC.ChunkDrawListVersion() or c.failedBindings ~= Bindings.generation
			or c.failedWorld ~= MC.World or c.failedWorldGeneration ~= MC.StateWorldGeneration
			or c.failedBlockSize ~= MC.API.Coords.BlockSize()
			or ( c.retryAt ~= nil and SysTime() >= c.retryAt )
		if retry then
			local ok, err = pcall( function()
				P.RefreshLightmap()
				if not L.pending and c.bindingsGeneration ~= Bindings.generation then
					local selected, selectionError = L.Select( c.pack )
					requireValue( selected, "render_pack_reparse", tostring( selectionError ) )
				end
				if c.drawGeneration ~= MC.ChunkDrawListVersion() or not sameWorld( c ) then
					syncSections( c )
				elseif not P.SourcesCurrent( c.bundle ) then
					syncSections( c, true )
				end
			end )
			if not ok then
				fail( c, err )
			else
				if c.updateError and L.lastError == c.updateError then L.lastError = nil end
				c.failedDrawGeneration, c.retryAt, c.updateError = nil, nil, nil
			end
		end
	end
	if L.pending then
		c = L.pending
		local ok, err = pcall( updateCandidate, c )
		if not ok then fail( c, err ) end
	end
	if perf then
		MC.StreamPerformanceAddFrameStage( "render.pack_update", ( SysTime() - started ) * 1000 )
	end
	L.ReportFaults()
end

function L.IsDrawing()
	return L.active ~= nil
end

local emptyStages, emptyChunks = {}, {}
function L.GetStages( translucent )
	if not L.active or not sameWorld( L.active ) then return emptyStages, L.version, emptyChunks end
	-- The synchronous draw pass checks world invariants once here, then only
	-- checks individual chunk identities against this published snapshot.
	if translucent then return L.active.translucentStages, L.active.version, L.active.chunks end
	return L.active.opaqueStages, L.active.version, L.active.chunks
end

function L.ChunkCurrent( key )
	local c = L.active
	return c and c.chunks[key] ~= nil and sameWorld( c ) and MC.GetChunkByKey( key ) == c.chunks[key]
end

function L.DrawFault( message )
	L.QueueFault( "render_pack_draw", ( L.active and L.active.pack or "unknown" ) .. ": " .. tostring( message ) )
end

function L.Status()
	local c, active = L.pending, L.active
	return { phase = c and c.phase or active and "active" or L.lastError and "failed" or "initializing",
		selected = L.selected or DEFAULT_PACK, active = active and active.pack, version = L.version,
		build = active and active.plan.owners["pack/" .. active.pack].definition.build,
		layout = "mc:quad_corners_v1", geometry = "native_l2",
		sections = active and active.sectionCount or 0, quads = active and active.totalQuads or 0,
		pendingQuads = c and c.totalQuads or 0, converted = 0, pinnedSections = 0,
		waitingSections = c and c.waitingSections or active and active.waitingSections or 0,
		pendingSections = c and c.sectionCount or 0,
		pendingMS = c and ( SysTime() - c.started ) * 1000 or 0,
		liveParts = G.liveParts, liveQuads = G.liveQuads, materials = P.materialCount,
		prepareMS = active and active.prepareMS or 0,
		updateMS = active and active.updateMS or 0, updatedSections = active and active.updatedSections or 0,
		syncCount = active and active.syncCount or 0, syncTotalMS = active and active.syncTotalMS or 0,
		lightmapUploads = P.shared.lightmapUploads or 0, lightmapSkippedUploads = P.shared.lightmapSkippedUploads or 0,
		gpuVerified = false, lastError = L.lastError }
end

MC.API.Render.SelectPack = L.Select
MC.API.Render.DisablePack = L.Off
MC.API.Render.GetRuntimeStatus = L.Status

local function printStatus()
	local s = L.Status()
	print( string.format( "[MC render pack] phase=%s selected=%s active=%s native=L2 sections=%d quads=%d parts=%d/16384 atlas=%d/1048576 materials=%d GPU=unverified",
		s.phase, s.selected, s.active or "-", s.sections, s.quads, s.liveParts, s.liveQuads, s.materials ) )
	print( string.format( "[MC render pack] prepare=%.2fms update=%.2fms updated=%d waiting=%d converted=0",
		s.prepareMS, s.updateMS, s.updatedSections, s.waitingSections ) )
	print( string.format( "[MC render pack work] syncs=%d syncMS=%.2f lightmapUploads=%d skippedLightmapUploads=%d",
		s.syncCount, s.syncTotalMS, s.lightmapUploads, s.lightmapSkippedUploads ) )
	if s.lastError then print( "[MC render pack] lastError=" .. s.lastError ) end
end

concommand.Add( "mc_render_pack", function( _, _, args )
	local action = args[1] or "status"
	if action == "status" and #args <= 1 then printStatus()
	elseif action == "scan" and #args == 1 then
		local ok, result = MC.RenderPackDiscovery.Scan()
		if type( result ) == "table" then
			print( string.format( "[MC render pack] scan files=%d changed=%d unchanged=%d failed=%d; no activation",
				result.files, result.changed, result.unchanged, result.failed ) )
		elseif not ok then print( "[MC render pack] scan rejected: " .. tostring( result ) ) end
	elseif ( action == "off" and #args == 1 ) or ( action == "select" and #args == 2 and args[2] == "off" ) then
		local ok, err = L.Off()
		print( "[MC render pack] " .. ( ok and "preparing " .. DEFAULT_PACK .. " (L2 default)" or "rejected: " .. tostring( err ) ) )
	elseif action == "select" and #args == 2 then
		local ok, err = L.Select( args[2] )
		print( "[MC render pack] " .. ( ok and "preparing " .. args[2] or "rejected: " .. tostring( err ) ) )
	elseif action == "reload" and #args == 1 then
		local ok, err = L.Reload()
		print( "[MC render pack] " .. ( ok and "reload preparing " .. L.selected or "reload rejected: " .. tostring( err ) ) )
	else print( "mc_render_pack scan | select <namespace:id> | reload | off (default L2) | status" ) end
	L.ReportFaults()
end )

hook.Add( "PreRender", "mc_render_pack_runtime", L.Step )
