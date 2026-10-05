-- Frame-boundary material binding for section-owned native L2 geometry.
MC = MC or {}
local L = MC.RenderPackRuntime or { version = 0, faults = {} }
MC.RenderPackRuntime = L
local Catalog, Bindings = MC.RenderPackRegistry, MC.RenderBlockBindings
local G, P, R = MC.RenderPackGeometry, MC.RenderPackResources, MC.RenderL2Resources
local requireValue = R.Require
local DEFAULT_PACK = "mc:vanilla"
local WaterEnabled = MC.RenderPackSettings.Handle("water")
local noPasses = {}
-- Archived locally; the console command writes it, bootstrap reads it.
local SavedPack = CreateClientConVar( "mc_render_pack_saved", DEFAULT_PACK, true, false,
	"Render pack selected on join (set by mc_render_pack select/off)" )

function L.QueueFault( code, message )
	if type( message ) == "table" and message.code then code, message = message.code, message.message end
	L.faults[#L.faults + 1] = { code = code, message = tostring( message ) }
end

function L.ReportFaults()
	local pending, firstError = L.faults, nil
	if #pending == 0 then return end
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
	MC.RenderPackProcessing.Release( runtime.processing )
	runtime.processing = nil
end

local function sameWorld( c )
	return MC.World == c.world and MC.StateWorldGeneration == c.worldGeneration
		and c.atlasKey == MC.ActiveAtlasProfileKey
		and MC.CS == c.cs and MC.CH == c.ch and MC.API.Coords.BlockSize() == c.blockSize
end

local function advanceVersion( c, updates )
	local previous = c.version
	L.version = L.version + 1
	c.version = L.version
	local shadows = MC.RenderPBRShadows
	if shadows and shadows.RuntimeChanged then shadows.RuntimeChanged( c, previous, updates ) end
end

local function markChunkDirty( c, key )
	if not c then return end
	if key == nil then c.fullSync = true return end
	if not c.dirtyChunks then c.dirtyChunks = {} end
	c.dirtyChunks[key] = true
end

-- Each consumer keeps its own pending changes: an active pack may retry while
-- a candidate waits for repartitioned geometry. A no-key notification still
-- invalidates the complete world (including callers predating this API).
function L.MarkChunkDirty( key )
	markChunkDirty( L.active, key )
	markChunkDirty( L.pending, key )
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
	L.selected, L.bootstrapped, L.lastError = id, true, nil
	return true, "preparing"
end

function L.Off()
	-- "Off" disables a custom pack, not the required world vertex format.
	return L.Select( DEFAULT_PACK )
end

-- Resource generations own their texture lifetimes. Drop bundles before the
-- coordinator retires their textures; cached engine materials are rebound by
-- the next bundle. Section UV generations are checked separately.
function L.ResetAtlasBindings()
	local selected = L.selected or DEFAULT_PACK
	release(L.pending)
	release(L.active)
	L.pending, L.active = nil, nil
	L.version = L.version + 1
	return L.Select(selected)
end

-- Keep old runtime ownership until the replacement is bound. Texture loading
-- and baking finish synchronously; only geometry uses its existing scheduler
-- during this explicit loading transition.
function L.BeginAtlasTransition()
	L.atlasTransition = true
	local ok, err = L.Select(L.selected or DEFAULT_PACK)
	if not ok then L.atlasTransition = nil return false, err end
	return true
end

function L.AtlasTransitionStatus()
	if L.lastError and not L.pending then return false, L.lastError end
	if L.pending or not L.active or not sameWorld(L.active) then return nil end
	return true
end

function L.EndAtlasTransition()
	L.atlasTransition = nil
end

-- Select and remember a pack for the next join (console command and mc_config).
function L.Choose( id )
	local ok, err
	if id == DEFAULT_PACK then ok, err = L.Off() else ok, err = L.Select( id ) end
	if ok then SavedPack:SetString( id ) end
	return ok, err
end

function L.Selected()
	return L.selected or SavedPack:GetString()
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
			local pass = { node = node, store = {}, dirtyChunks = {} }
			passes[#passes + 1] = pass
			c.passByKey[node.key] = pass
		end
	end
	c.opaqueStages = { c.stages.world_opaque, c.stages.world_cutout }
	c.translucentStages = { c.stages.world_translucent }
end

local function partitionMatches( c, source, size )
	if source.blockSize ~= size then return false end
	for pass = 1, 2 do
		local list = pass == 1 and source.opaque or source.translucent
		for _, part in ipairs( list ) do
			requireValue( part.l2 and part.resource and part.mesh, "render_pack_native_geometry",
				"world meshes must be emitted in L2 format; restart the client after upgrading" )
			for id in pairs( part.blockIds ) do
				if part.request ~= ( c.bindingKeys[id] or "terrain" ) then return false end
				if ( part.castsShadow ~= false ) ~= ( MC.Blocks[id].castsShadow ~= false ) then return false end
			end
		end
	end
	return true
end

local function copyMaterialNodes( nodes )
	local copy = {}
	if nodes then for key, value in pairs( nodes ) do copy[key] = value end end
	return copy
end

local function bindSection( c, transaction, source, chunk, size )
	local bound = { source = source, chunk = chunk, bounds = source.bounds, resources = {}, passes = {}, quads = 0, draws = 0 }
	transaction.created[#transaction.created + 1] = bound
	for pass = 1, 2 do
		local list = pass == 1 and source.opaque or source.translucent
		for _, part in ipairs( list ) do
			local data = part.resource
			G.Retain( data )
			bound.resources[#bound.resources + 1] = data
			bound.quads = bound.quads + data.quadCount
			local materialCache = transaction.materials[part.material]
			if not materialCache and not transaction.force and not transaction.changedSources[part.material] then
				materialCache = c.materials[part.material]
			end
			local passes = P.Passes(transaction.bundle, part.request, part.stage)
			-- The dedicated water renderer owns optics, SSR, refraction and
			-- caustics. Never draw a second atlas surface underneath it.
			if part.water and c.waterEnabled then passes = noPasses end
			for _, node in ipairs( passes ) do
				local material = materialCache and materialCache[node.key]
				if not material then
					-- Published node caches are read-only until commit. Copy only
					-- when this source actually needs a new pass binding.
					if not transaction.materials[part.material] then
						materialCache = copyMaterialNodes( materialCache )
						transaction.materials[part.material] = materialCache
					end
					material = P.Material( transaction.bundle, node, part.material, size )
					materialCache[node.key] = material
				end
				local entries = bound.passes[node.key]
				if not entries then entries = {} bound.passes[node.key] = entries end
				entries[#entries + 1] = { mesh = data.mesh, material = material,
					vertexCount = data.quadCount * 6, bounds = part.bounds, direction = part.direction,
					castsShadow = part.castsShadow ~= false }
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
		local section = sections[index]
		for key, entries in pairs( section.passes ) do
			local list = result[key]
			if not list then list = { sections = {}, vertexCount = 0 } result[key] = list end
			local first, vertices = #list + 1, 0
			for _, entry in ipairs( entries ) do
				list[#list + 1] = entry
				vertices = vertices + entry.vertexCount
			end
			list.sections[#list.sections + 1] = { index = index, first = first, last = #list,
				bounds = section.bounds, vertexCount = vertices }
			list.vertexCount = list.vertexCount + vertices
			if section.bounds then list.bounds = MC.RenderSectionCull.Extend( list.bounds, section.bounds )
			else list.unbounded = true end
		end
	end
	for _, list in pairs( result ) do if list.unbounded then list.bounds = nil end end
	return result
end

local emptySections = {}

local function adjustMaterialUses( uses, previous, bound, delta )
	for pass = 1, 2 do
		local list = pass == 1 and bound.source.opaque or bound.source.translucent
		for _, part in ipairs( list ) do
			uses[part.material] = ( uses[part.material] or previous[part.material] or 0 ) + delta
		end
	end
end

local function sourceChanged( c, transaction, material )
	local changed = transaction.changedSources[material]
	if changed == nil then
		local previous = c.bundle.sources[material]
		changed = not previous or not R.SameTexture( R.SourceTexture( material ), previous )
		transaction.changedSources[material] = changed
		if changed then
			-- A texture shared with untouched chunks changed in this same frame.
			if previous and not transaction.full then transaction.fullRequired = true end
		end
	end
	return changed
end

local function syncChunk( c, transaction, key, size, force )
	local chunk = MC.GetChunkByKey( key )
	local old, sections, rebuilds = c.sections[key] or emptySections, {}, nil
	local previousRequests = c.rebuildRequests[key]
	if not transaction.full then
		for _ in pairs( previousRequests or emptySections ) do transaction.waiting = transaction.waiting - 1 end
	end
	for index, source in pairs( MC.MeshSections[key] or emptySections ) do
		if chunk then
			requireValue( type( source ) == "table" and source.l2 and source.chunk
				and source.worldGeneration ~= nil, "render_pack_native_geometry",
				"world section is not native L2; restart the client after upgrading" )
		end
		-- Streaming may detach a chunk before its mesh cleanup.
		if chunk and source.chunk == chunk and source.worldGeneration == MC.StateWorldGeneration then
			local bound = old[index]
			local layoutCurrent = source.atlasKey == MC.ActiveAtlasProfileKey
			local partitionCurrent = layoutCurrent and not force and bound and bound.source == source and bound.chunk == chunk
			if not layoutCurrent or not partitionCurrent and not partitionMatches( c, source, size ) then
				transaction.waiting = transaction.waiting + 1
				rebuilds = rebuilds or {}
				rebuilds[index] = source
				if c.bindingsGeneration == Bindings.generation and ( not previousRequests or previousRequests[index] ~= source ) then
					requireValue( type( MC.RequestRenderSectionGeometry ) == "function",
						"render_pack_rebuild_missing", "native section rebuild queue is unavailable" )
					MC.RequestRenderSectionGeometry( key, index, false )
				end
				if not layoutCurrent or not bound or bound.chunk ~= chunk or not sameWorld( c ) then bound = nil end
			else
				local rebind = force or not bound or bound.source ~= source or bound.chunk ~= chunk
				for pass = 1, 2 do
					local list = pass == 1 and source.opaque or source.translucent
					for _, part in ipairs( list ) do
						if sourceChanged( c, transaction, part.material ) then rebind = true end
					end
				end
				if rebind then bound = bindSection( c, transaction, source, chunk, size ) end
			end
			sections[index] = bound
		end
	end
	local changed = false
	for index, bound in pairs( old ) do
		if sections[index] ~= bound then
			transaction.removed[#transaction.removed + 1] = bound
			transaction.count = transaction.count - 1
			transaction.quads, transaction.draws = transaction.quads - bound.quads, transaction.draws - bound.draws
			adjustMaterialUses( transaction.materialUses, transaction.baseUses, bound, -1 )
			changed = true
		end
	end
	for index, bound in pairs( sections ) do
		if old[index] ~= bound then
			transaction.count = transaction.count + 1
			transaction.quads, transaction.draws = transaction.quads + bound.quads, transaction.draws + bound.draws
			adjustMaterialUses( transaction.materialUses, transaction.baseUses, bound, 1 )
			changed = true
		end
	end
	local update = { key = key, rebuilds = rebuilds }
	if next( sections ) then update.sections, update.chunk = sections, chunk end
	if changed then update.passes = flattenChunk( sections ) end
	transaction.updates[#transaction.updates + 1] = update
end

local function prepareSync( c, transaction, keys, size, force )
	transaction.bundle, transaction.materials, transaction.changedSources = P.Fork( c.bundle ), {}, {}
	transaction.materialUses, transaction.removed, transaction.updates = {}, {}, {}
	transaction.baseUses, transaction.force = c.materialUses or {}, force
	transaction.count, transaction.quads, transaction.draws = c.sectionCount, c.totalQuads, c.drawEntries
	transaction.waiting = transaction.full and 0 or c.waitingSections
	if not c.materialUses then
		-- One-time adoption of a runtime retained across Lua autorefresh.
		for _, sections in pairs( c.sections ) do
			for _, bound in pairs( sections ) do adjustMaterialUses( transaction.baseUses, emptySections, bound, 1 ) end
		end
	end
	if transaction.full then
		for key in pairs( MC.MeshSections ) do syncChunk( c, transaction, key, size, force ) end
		for key in pairs( c.sections ) do
			if MC.MeshSections[key] == nil then syncChunk( c, transaction, key, size, force ) end
		end
	else
		for key in pairs( keys ) do syncChunk( c, transaction, key, size, force ) end
	end
	requireValue( transaction.draws <= 65536, "render_pack_draw_budget", "execution plan exceeds 65536 mesh draws" )
	-- Check only surviving materials: a removed material can already be invalid.
	-- Changes shared with other chunks expand this transaction before publication.
	if not transaction.full then
		for material, texture in pairs( c.bundle.sources ) do
			local count = transaction.materialUses[material] or transaction.baseUses[material]
			if count and count > 0 and transaction.changedSources[material] == nil
				and not R.SameTexture( R.SourceTexture( material ), texture ) then
				transaction.fullRequired = true
			end
		end
	end
end

local function commitMaterials( c, transaction )
	local materials, sources, uses = c.materials, c.bundle.sources, transaction.baseUses
	local runtimePBR = c.bundle.runtimePBR or {}
	-- The transaction contains only touched counts and newly written bindings.
	-- Keep flat published maps; no overlay chains or copies of unrelated nodes.
	for material, count in pairs( transaction.materialUses ) do
		if count == 0 then
			uses[material], materials[material], sources[material] = nil, nil, nil
			runtimePBR[material] = nil
		else
			uses[material] = count
			if transaction.materials[material] then materials[material] = transaction.materials[material] end
			if transaction.bundle.sources[material] then
				sources[material] = transaction.bundle.sources[material]
				runtimePBR[material] = transaction.bundle.runtimePBR[material]
			end
		end
	end
	transaction.bundle.sources = sources
	transaction.bundle.runtimePBR = runtimePBR
	c.bundle, c.materialUses = transaction.bundle, uses
end

local function discardSync( transaction )
	for _, bound in ipairs( transaction.created ) do releaseSection( bound ) end
end

local function sameEntries( a, b )
	if a == b then return true end
	if not a or not b or #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end

local function syncSections( c, force )
	local started, size, generation = SysTime(), MC.API.Coords.BlockSize(), MC.ChunkDrawListVersion()
	local water = WaterEnabled:GetBool() and c.plan.owners["pack/" .. c.pack].definition.programs.water ~= nil
	force = force or c.waterEnabled ~= water
	c.waterEnabled = water
	requireValue( type( size ) == "number" and size > 0 and size < math.huge,
		"render_pack_block_size", "invalid runtime block size" )
	-- A map-only pack update can arrive alongside a sparse geometry update.
	force = force or c.blockSize ~= size
		or ( c.bundle.texturePackRevision or 0 ) ~= ( MC.TexturePackRevision or 0 )
	if force or not c.postProcessBound then
		local definition = c.plan.owners["pack/" .. c.pack].definition
		if definition.programs.post_ssao then c.postProcess = MC.RenderPBRPost.Register( definition, size, c.processing ) end
		c.postProcessBound = true
	end
	local keys, fullSync = c.dirtyChunks, c.fullSync
	local full = force or fullSync or not sameWorld( c ) or not keys or next( keys ) == nil
	-- New notifications during preparation belong to the next transaction.
	c.dirtyChunks, c.fullSync = nil, nil
	local transaction = { created = {}, full = full }
	local ok, err = pcall( prepareSync, c, transaction, keys, size, force )
	if ok and transaction.fullRequired then
		discardSync( transaction )
		transaction = { created = {}, full = true }
		ok, err = pcall( prepareSync, c, transaction, keys, size, force )
	end
	if not ok then
		discardSync( transaction )
		if not c.dirtyChunks then c.dirtyChunks = keys
		else for key in pairs( keys or emptySections ) do c.dirtyChunks[key] = true end end
		c.fullSync = c.fullSync or full
		error( err, 0 )
	end
	-- Publish only affected chunks, then retire their old handles. Untouched
	-- sections and pass lists keep their identities and need no reconstruction.
	if transaction.full then c.rebuildRequests = {} end
	for _, update in ipairs( transaction.updates ) do
		local key = update.key
		c.sections[key], c.chunks[key], c.rebuildRequests[key] = update.sections, update.chunk, update.rebuilds
		for nodeKey, pass in pairs( c.passByKey ) do
			if update.passes and not sameEntries( pass.store[key], update.passes[nodeKey] ) then
				pass.store[key] = update.passes[nodeKey]
			end
			pass.dirtyChunks = pass.dirtyChunks or {}
			pass.dirtyChunks[key] = true
		end
	end
	commitMaterials( c, transaction )
	c.sectionCount, c.totalQuads, c.drawEntries, c.waitingSections = transaction.count, transaction.quads, transaction.draws, transaction.waiting
	c.world, c.worldGeneration, c.cs, c.ch = MC.World, MC.StateWorldGeneration, MC.CS, MC.CH
	c.atlasKey = MC.ActiveAtlasProfileKey
	c.blockSize, c.drawGeneration = size, generation
	c.updateMS, c.updatedSections, c.scannedChunks = ( SysTime() - started ) * 1000, #transaction.created, #transaction.updates
	c.syncCount = ( c.syncCount or 0 ) + 1
	c.syncTotalMS = ( c.syncTotalMS or 0 ) + c.updateMS
	c.failedDrawGeneration = nil
	if #transaction.created > 0 or #transaction.removed > 0 or not c.version then
		advanceVersion( c, transaction.updates )
	end
	for _, bound in ipairs( transaction.removed ) do releaseSection( bound ) end
end

local function publish( c )
	local previous = L.active
	c.phase, c.prepareMS = "active", ( SysTime() - c.started ) * 1000
	L.active, L.pending, L.lastError = c, nil, nil
	-- Load the new pack's saved settings now; listeners such as shadows cache them.
	MC.RenderPackSettings.Refresh()
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
		c.processing = MC.RenderPackProcessing.Create( c.bundle.processing, c.pack )
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
	if c and c == L.pending then
		release( c )
		L.pending = nil
		L.selected = L.active and L.active.pack or L.selected
		-- MC.Fault deduplicates repeated codes. Every rejected selection still
		-- needs a terminal message after "preparing", even for the same fault.
		print( "[MC render pack] failed " .. L.lastError .. "; active=" .. ( L.active and L.active.pack or "none" ) )
		-- A saved pack that no longer prepares must not leave the world without L2.
		if not L.active and not L.atlasTransition and c.pack ~= DEFAULT_PACK then L.Select( DEFAULT_PACK ) end
	elseif c then
		c.failedDrawGeneration, c.failedBindings = MC.ChunkDrawListVersion(), Bindings.generation
		c.failedWorld, c.failedWorldGeneration = MC.World, MC.StateWorldGeneration
		c.failedBlockSize = MC.API.Coords.BlockSize()
		c.retryAt, c.updateError = SysTime() + 1, L.lastError
	end
	L.QueueFault( code, L.lastError .. ( L.active and "; previous L2 runtime retained" or "; no L2 runtime available" ) )
end

local function updateActive( c )
	P.RefreshLightmap()
	if not L.pending and c.bindingsGeneration ~= Bindings.generation then
		local selected, selectionError = L.Select( c.pack )
		requireValue( selected, "render_pack_reparse", tostring( selectionError ) )
	end
	local water = WaterEnabled:GetBool() and c.plan.owners["pack/" .. c.pack].definition.programs.water ~= nil
	if c.waterEnabled ~= water then syncSections(c, true)
	elseif c.drawGeneration ~= MC.ChunkDrawListVersion() or not sameWorld( c ) then
		syncSections( c )
	elseif not P.SourcesCurrent( c.bundle ) then
		syncSections( c, true )
	end
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
			local ok, err = L.Select( SavedPack:GetString() )
			if not ok then ok, err = L.Select( DEFAULT_PACK ) end
			if not ok then fail( nil, { code = "render_pack_default", message = err } ) end
		end
	end
	local c = L.active
	if c and not L.atlasTransition then
		local retry = c.failedDrawGeneration ~= MC.ChunkDrawListVersion() or c.failedBindings ~= Bindings.generation
			or c.failedWorld ~= MC.World or c.failedWorldGeneration ~= MC.StateWorldGeneration
			or c.failedBlockSize ~= MC.API.Coords.BlockSize()
			or ( c.retryAt ~= nil and SysTime() >= c.retryAt )
		if retry then
			local ok, err = pcall( updateActive, c )
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

function L.BeginProcessing( x, y, z, view )
	-- The retained runtime is not ready for shadow composition while its atlas
	-- or world snapshot is being replaced. PrepareDraw disables shadows on false.
	if L.atlasTransition then return false end
	local c = L.active
	if c and not sameWorld( c ) then return false end
	if not c or not c.processing then return true end
	if c.processingRetryAt and SysTime() < c.processingRetryAt then return false end
	local ok, result, err = pcall( MC.RenderPackProcessing.RunView, c.processing, "begin", c, x, y, z, view )
	if not ok or not result then
		MC.RenderPackProcessing.Invalidate( c.processing )
		c.processingRetryAt = SysTime() + 1
		MC.RenderPBR.DisableShadow()
		L.QueueFault( "render_processing_begin", ok and err or result )
		L.ReportFaults()
		return false
	end
	c.processingRetryAt = nil
	return true
end

-- Called after shadow geometry has left its RT scope, including cache hits.
-- Errors propagate to the shadow coordinator's disable/retry/fault path.
function L.ProcessShadow( x, y, z, view, shadow )
	local c = L.active
	if not c or not c.processing then return shadow.target end
	requireValue( sameWorld( c ) and not c.processingRetryAt, "render_processing_begin", "begin stage is unavailable" )
	local ok, err = MC.RenderPackProcessing.RunView( c.processing, "shadowcomp", c, x, y, z, view, shadow )
	if not ok then error( err, 0 ) end
	if not c.processing.definition.pipeline.exports.shadow_atlas then return shadow.target end
	local output = MC.RenderPackProcessing.Export( c.processing, "shadow_atlas" )
	requireValue( output ~= nil, "render_processing_export", "shadow_atlas was not published" )
	return output
end

function L.IsDrawing()
	return L.active ~= nil
end

local function refreshBlockEntityMaterials( c, sources, binding )
	if binding.materials and binding.blockSize == c.blockSize and P.SourcesCurrent( binding.bundle ) then return end
	local owner = "pack/" .. c.pack
	local def = c.plan.owners[owner].definition
	local pass = def.passes.terrain_cutout
	local node = { key = owner .. "/block_entity", owner = owner, stage = "world_cutout",
		adapter = def.adapter, program = def.programs.block_entity, materialMaps = def.materialMaps,
		dynamicProgram = def.adapter == "mc:pbr_quad_v4" and def.programs.dynamic_block_entity or nil }
	for _, semantic in ipairs( { "normal", "orm", "environment", "dfg" } ) do
		node[semantic] = c.bundle.textures[owner .. "/" .. pass.inputs[semantic]]
	end
	-- Entity sources have their own lifetime. Adding them to the terrain bundle
	-- would make a changed chest texture trigger a full section sync every frame.
	local bundle, materials = P.Fork( c.bundle ), {}
	for name, source in pairs( sources ) do
		materials[name] = P.Material( bundle, node, source, c.blockSize )
	end
	-- Publish the complete table only after all source/map bindings succeed.
	binding.bundle, binding.materials, binding.blockSize = bundle, materials, c.blockSize
end

-- Immutable source tables, with texture identity checked once per frame.
-- nil means the active pack has no entity path; false means a reported fault.
function L.BlockEntityMaterials( sources )
	if type( sources ) ~= "table" then return nil, "invalid_material_sources" end
	local c = L.active
	if not c or not sameWorld( c ) then return nil end
	local def = c.plan.owners["pack/" .. c.pack].definition
	if not def.programs.block_entity then return nil end
	local bindings = c.entityBindings
	if not bindings then bindings = {} c.entityBindings = bindings end
	local binding = bindings[sources]
	if not binding then binding = {} bindings[sources] = binding end
	local frame = FrameNumber()
	if binding.retryAt and SysTime() < binding.retryAt then return false, binding.error end
	if binding.frame ~= frame or binding.blockSize ~= c.blockSize then
		local ok, err = pcall( refreshBlockEntityMaterials, c, sources, binding )
		binding.frame = frame
		if not ok then
			binding.error, binding.retryAt = err, SysTime() + 1
			L.QueueFault( "render_block_entity_material", err )
			return false, err
		end
		binding.error, binding.retryAt = nil, nil
	end
	return binding.materials
end

-- Like standalone entities, water has no terrain source entry or extra world
-- pass. Its immutable program/resources are verified with the selected pack.
function L.PrepareSpriteLightMaterial( source, translucent )
	local c = L.active
	if not c or not sameWorld( c ) then return nil end
	local def = c.plan.owners["pack/" .. c.pack].definition
	if def.adapter ~= "mc:pbr_quad_v4" and def.adapter ~= "mc:vanilla_quad_v2" then return nil end
	if not def.programs.dynamic_sprite then return nil end
	local ok, material = pcall( MC.RenderDynamicLights.RegisterMaterial, source, def.programs.dynamic_sprite,
		P.shared, R.SourceTexture( source ), translucent and "world_translucent" or "world_cutout", c.blockSize, nil, true )
	if not ok then L.QueueFault( "render_sprite_light_material", material ) return false, material end
	return material
end

function L.WaterMaterial()
	local c = L.active
	if not c or not sameWorld( c ) then return nil end
	local owner = "pack/" .. c.pack
	if not c.plan.owners[owner].definition.programs.water then return nil end
	local binding = c.waterBinding
	if not binding then binding = {} c.waterBinding = binding end
	if binding.retryAt and SysTime() < binding.retryAt then return false, binding.error end
	if not binding.material or binding.blockSize ~= c.blockSize then
		local ok, material = pcall( P.WaterMaterial, c.bundle, owner, c.blockSize )
		if not ok then
			binding.error, binding.retryAt = material, SysTime() + 1
			L.QueueFault( "render_water_material", material )
			return false, material
		end
		binding.material, binding.blockSize = material, c.blockSize
		binding.error, binding.retryAt = nil, nil
	end
	return binding.material
end

local emptyStages, emptyChunks = {}, {}
function L.GetStages( translucent )
	if L.atlasTransition or not L.active or not sameWorld( L.active ) then return emptyStages, L.version, emptyChunks end
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
		scannedChunks = active and active.scannedChunks or 0,
		syncCount = active and active.syncCount or 0, syncTotalMS = active and active.syncTotalMS or 0,
		lightmapUploads = P.shared.lightmapUploads or 0, lightmapSkippedUploads = P.shared.lightmapSkippedUploads or 0,
		gpuVerified = false, lastError = L.lastError }
end

MC.API.Render.SelectPack = L.Select
MC.API.Render.DisablePack = L.Off
MC.API.Render.GetRuntimeStatus = L.Status
MC.API.Render.BlockEntityMaterials = L.BlockEntityMaterials
MC.API.Render.WaterMaterial = L.WaterMaterial

local function printStatus()
	local s = L.Status()
	print( string.format( "[MC render pack] phase=%s selected=%s active=%s native=L2 sections=%d quads=%d parts=%d/16384 atlas=%d/1048576 materials=%d GPU=unverified",
		s.phase, s.selected, s.active or "-", s.sections, s.quads, s.liveParts, s.liveQuads, s.materials ) )
	print( string.format( "[MC render pack] prepare=%.2fms update=%.2fms updated=%d waiting=%d converted=0",
		s.prepareMS, s.updateMS, s.updatedSections, s.waitingSections ) )
	print( string.format( "[MC render pack work] syncs=%d syncMS=%.2f scannedChunks=%d lightmapUploads=%d skippedLightmapUploads=%d",
		s.syncCount, s.syncTotalMS, s.scannedChunks, s.lightmapUploads, s.lightmapSkippedUploads ) )
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
		local ok, err = L.Choose( DEFAULT_PACK )
		print( "[MC render pack] " .. ( ok and "preparing " .. DEFAULT_PACK .. " (L2 default)" or "rejected: " .. tostring( err ) ) )
	elseif action == "select" and #args == 2 then
		local ok, err = L.Choose( args[2] )
		print( "[MC render pack] " .. ( ok and "preparing " .. args[2] or "rejected: " .. tostring( err ) ) )
	elseif action == "reload" and #args == 1 then
		local ok, err = L.Reload()
		print( "[MC render pack] " .. ( ok and "reload preparing " .. L.selected or "reload rejected: " .. tostring( err ) ) )
	else print( "mc_render_pack scan | select <namespace:id> | reload | off (default L2) | status" ) end
	L.ReportFaults()
end )

hook.Add( "PreRender", "mc_render_pack_runtime", L.Step )
