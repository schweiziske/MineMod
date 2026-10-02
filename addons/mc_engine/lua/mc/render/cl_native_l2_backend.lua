-- Native quad construction shares the Lua L2 scheduler, materials and atlas.
-- Lua compiles immutable model recipes; workers select/expand their instances.
-- Stage routing, uploads and publication remain owned by the Lua pipeline.
MC = MC or {}
local N = MC.NativeL2 or { active = false }
MC.NativeL2 = N
N.COMMAND_STRIDE = 11
-- Hot reload must not leave old transaction closures able to publish.
if N.CancelAll then N.CancelAll() end
N.pending, N.pendingCount = {}, 0
N.completed, N.stale, N.submitMS, N.commitMS = 0, 0, 0, 0
N.probed = false
N.cubeRecipes = {}
N.voxelBlocks, N.fallbackBlocks = 0, 0
N.worldBlocks, N.worldSections = 0, 0

function N.IsActive() return N.active == true end

function N.Probe()
	local module = mcmesh
	if N.probed and N.module == module then return N.available, N.reason end
	N.probed, N.module, N.available, N.voxelAvailable = true, module, false, false
	N.modelAvailable, N.worldAvailable = false, false
	N.reason = MC.NativeMeshModuleFailureReason or "installed DLL has no L2 interface; update mcswep_native_mesh"
	if type( module ) ~= "table" then return false, N.reason end
	for _, name in ipairs( { "L2Version", "CompileL2Template", "SubmitL2Section", "PollL2Section",
		"UploadL2Part", "CancelL2Section", "CanSubmitL2", "GetL2Stats" } ) do
		if type( module[name] ) ~= "function" then return false, N.reason end
	end
	local ok, version = pcall( module.L2Version )
	if not ok or version ~= 2 then
		N.reason = "incompatible Native L2 interface: " .. tostring( version )
		return false, N.reason
	end
	N.available, N.reason = true, nil
	N.voxelAvailable = type( module.CompileL2Cube ) == "function" and type( module.GetL2SectionParts ) == "function"
	N.modelAvailable = N.voxelAvailable and type( module.CompileL2Model ) == "function"
	N.worldAvailable = N.modelAvailable and type( module.SubmitWorldL2Section ) == "function"
		and type( module.IsWorldL2Current ) == "function" and type( module.GetWorldL2Topology ) == "function"
	return true
end

local function queueWorld( clearMeshes )
	local geometry = MC.RenderPackGeometry
	if geometry and clearMeshes then geometry.deferRetirement = true end
	local ok, err = pcall( function()
		for key in pairs( MC.World or {} ) do
			-- Stop drawing at frame sync; destruction drains on the main-thread budget.
			if clearMeshes then MC.FreeChunkMesh( key ) end
			MC.MarkChunkDirty( key, true )
		end
	end )
	if geometry then geometry.deferRetirement = nil end
	if not ok then error( err, 0 ) end
end

function N.SetEnabled( enabled )
	local available, reason = N.Probe()
	local active = enabled and available or false
	local takeover = MC.NativeTakeover
	local caps = takeover and takeover.Probe()
	if takeover and takeover.SetWorldEnabled and ( not active or caps and caps.worldAdapter == 1 ) then
		local ok, err = takeover.SetWorldEnabled( active )
		if not ok then return nil, err end
	end
	if active ~= N.active then
		N.CancelAll()
		N.active = active
		queueWorld( true )
		print( "[MC Native L2] " .. ( active and "Enabled (Native workers, Lua section scheduler)"
			or "Disabled (Lua L2)" ) .. "; previous meshes cleared; section rebuilds queued." )
	end
	if active then N.failure = nil end
	return active, reason
end

function N.DisableAfterFailure( reason )
	local wasActive = N.active
	N.failure, N.active = tostring( reason ), false
	if wasActive then
		print( "[MC Native L2] Native mesh build failed; switching mesh execution to Lua L2; world ownership unchanged. Reason: " .. N.failure )
	end
	-- Let the failed builder finish unwinding its section buffers first.
	if N.rebuildQueued then return end
	N.rebuildQueued = true
	timer.Simple( 0, function()
		N.rebuildQueued = nil
		queueWorld()
	end )
end

local function compile( quad, positions, uv, baked, mode, emission )
	local cache, key
	if quad.nativeL2Mutable then
		-- Cubes/crosses provide a stable geometry owner, but their atlas UVs can
		-- vary by state or location. Numeric keys preserve exact UVs without
		-- string rounding. Fluids and dynamic shapes have no immutable owner.
		local owner = quad.nativeL2Owner
		if owner then
			cache = owner.nativeL2Templates
			if not cache then cache = {} owner.nativeL2Templates = cache end
			for corner = 1, 4 do
				for axis = 1, 2 do
					local coordinate = uv[corner][axis]
					local child = cache[coordinate]
					if not child then child = {} cache[coordinate] = child end
					cache = child
				end
			end
			key = "template"
		end
	else
		cache = quad.nativeL2Templates
		if not cache then cache = {} quad.nativeL2Templates = cache end
		key = baked or quad
	end
	local previous = cache and cache[key]
	if previous and previous.module == N.module then return previous.value end
	local flags = 0
	if baked then
		flags = ( baked.cubic and 1 or 0 ) + ( baked.planar and 2 or 0 )
			+ ( baked.partial and 4 or 0 ) + ( baked.smooth and 8 or 0 )
	end
	local data = { mode, baked and baked.face or quad.faceIndex, flags,
		baked and baked.directionShade or 1, baked and baked.flatShade or 255,
		baked and baked.emission or emission, baked and baked.lightFace or 0 }
	for corner = 1, 4 do
		local p, tex = positions[corner], uv[corner]
		for axis = 1, 3 do data[7 + ( corner - 1 ) * 3 + axis] = p[axis] end
		data[20 + ( corner - 1 ) * 2], data[21 + ( corner - 1 ) * 2] = tex[1], tex[2]
	end
	local normal = quad.normal
	data[28], data[29], data[30] = normal.x, normal.y, normal.z
	for corner = 1, 4 do
		for source = 1, 4 do
			local value = 0
			if baked and baked.partial then value = baked.weights[corner][source]
			elseif source == 1 then value = baked and baked.indices[corner] - 1 or corner - 1 end
			data[30 + ( corner - 1 ) * 4 + source] = value
		end
	end
	local value, err = N.module.CompileL2Template( data )
	if value == nil then
		N.DisableAfterFailure( err )
		MC.RenderL2Resources.Require( false, "native_l2_template", "Native L2 template failed: " .. tostring( err ) )
	end
	if cache then cache[key] = { module = N.module, value = value } end
	return value
end

function N.Emit( slice, buffer, quad, positions, uv, baked, bx, by, bz, wx, wy, wz, tint, mode, emission, prepared )
	local template = compile( quad, positions, uv, baked, mode, emission )
	local size = slice.blockSize
	if quad.positions then size, wx, wy, wz = 1, 0, 0, 0 end
	local commands, offset = buffer.nativeCommands, buffer.quadCount * N.COMMAND_STRIDE
	commands[offset + 1] = template
	commands[offset + 2], commands[offset + 3], commands[offset + 4] = bx, by, bz
	commands[offset + 5], commands[offset + 6], commands[offset + 7] = wx, wy, wz
	commands[offset + 8], commands[offset + 9] = size, tint
	commands[offset + 10] = quad.opacity or ( quad.shade and quad.shade.a ) or 255
	commands[offset + 11] = prepared or false
	buffer.nv, buffer.quadCount = buffer.nv + 6, buffer.quadCount + 1
end

local function readerFor( slice )
	if not slice.nativeReader then
		local snapshot = slice.snapshot
		slice.nativeReader = function( x, y, z )
			local cell = snapshot:Read( x, y, z )
			if not cell then return nil end
			local packed = cell.block + cell.sky * 16 + cell.emission * 256 + cell.dampening * 4096
				+ ( cell.emissive and 65536 or 0 ) + ( cell.viewBlocking and 131072 or 0 )
				+ ( cell.solidRender and 262144 or 0 ) + ( cell.fullCollision and 524288 or 0 )
				+ ( cell.loaded and 1048576 or 0 )
			local renderClass
			if slice.nativeVisibility then
				local origin = slice.nativeOrigin
				local id, full, transparent, special = slice.nativeVisibility.ClassAt(
					x - origin[1], y - origin[2], z - origin[3], x, y, z )
				MC.RenderL2Resources.Require( id ~= nil, "native_l2_visibility", slice.nativeVisibility.error )
				renderClass = id * 8 + ( full and 1 or 0 ) + ( transparent and 2 or 0 ) + ( special and 4 or 0 )
			end
			return packed, cell.shade, renderClass
		end
	end
	return slice.nativeReader
end

local function syncRecipes()
	local revision = { module = N.module, visual = MC.BlockStateVisualRevision or false,
		schema = MC.BlockStateSchemaById or false, bindings = MC.RenderBlockBindings.generation,
		emitters = MC.RenderMesh.NativeCubeRecipe, modelEmitter = MC.RenderMesh.NativeModelRecipe,
		models = MC.RenderL2Models, blocks = MC.Blocks, material = MC.Material,
		atlas = MC.Atlas, catalog = MC.StateVisualCatalog or false,
		fullCubeDebug = MC.RenderMesh.meshDebugFullCubeOnly(),
		collisionResolvers = MC.BlockStateCollisionResolvers or false,
		visualResolvers = MC.BlockStateVisualResolvers or false }
	local old = N.cubeRevision
	local changed = not old
	if old then for field, value in pairs( revision ) do if old[field] ~= value then changed = true break end end end
	if changed then N.cubeRevision, N.cubeRecipes = revision, {} end
end

local function recipeFor( state )
	local recipe = N.cubeRecipes[state]
	if recipe == nil then
		recipe = MC.RenderMesh.NativeCubeRecipe( state )
		if not recipe and N.modelAvailable then recipe = MC.RenderMesh.NativeModelRecipe( state ) end
		N.cubeRecipes[state] = recipe
	end
	return recipe
end

function N.WorldSnapshot( chunk, index )
	local backend = MC.NativeChunkBackend
	if not index or not N.active or not N.worldAvailable or not backend or not backend.IsActive() then return nil end
	if ( MC.RENDER_SECTION_SIZE or 8 ) ~= 8 then return nil end
	syncRecipes()
	local snapshot, err = backend.GetSectionInfo( chunk, index )
	MC.RenderL2Resources.Require( snapshot ~= nil, "native_section_info", tostring( err ) )
	local states = {}
	for state in pairs( snapshot.counts ) do
		if not recipeFor( state ) then return nil end
		states[#states + 1] = state
	end
	snapshot.stateList, snapshot.nativeOnly = states, true
	return { [index] = snapshot }
end

function N.PrepareVoxels( ctx, index, snapshot )
	if not N.voxelAvailable then return nil end
	syncRecipes()
	local recipes, seen = {}, {}
	local size = MC.RENDER_SECTION_SIZE or 8
	local xy, zero = MC.RenderMeshConstants.RENDER_SECTIONS_XY, index - 1
	local x, y, z = zero % xy * size, math.floor( zero / xy ) % xy * size, math.floor( zero / ( xy * xy ) ) * size
	if size ~= 8 then return nil end
	local groups = ctx.nativeGroups
	if not groups then groups = {} ctx.nativeGroups = groups end
	local used = 0
	local stateList = snapshot.stateList or snapshot.states
	for i = 1, #stateList do
		local state = stateList[i]
		if seen[state] == nil then
			local recipe = recipeFor( state )
			seen[state] = recipe ~= false
			if recipe then
				local buffers = ctx.buffersForLocal( x, y, z )
				local target = ctx.bufferForBlock( recipe.translucent and buffers.translucent or buffers.opaque, recipe.id )
				local packet = { recipe.value }
				packet.blocking = MC.RenderOcclusion.NativeBlockingState( state )
				for face = 1, recipe.model and 1 or 6 do
					local group = recipe.model and target or ctx.fullCubeBuffer( target, face )
					if not group.nativeGroup then
						group.nativeGroup = #groups + 1
						groups[#groups + 1] = group
					end
					packet[face + 1] = group.nativeGroup
				end
				recipes[state] = packet
			end
		end
		if seen[state] then used = used + ( snapshot.counts and snapshot.counts[state] or 1 ) end
	end
	N.voxelBlocks, N.fallbackBlocks = N.voxelBlocks + used, N.fallbackBlocks + snapshot.count - used
	if used == 0 then return nil end
	if not ctx.nativeVoxels then
		ctx.nativeVoxels = { ctx.blockSize, MC.CS, MC.CH, ctx.bxo, ctx.byo, ctx.bzo, {},
			math.min( 10833, math.floor( MC.RenderMeshConstants.VERT_LIMIT / 6 ) ) }
		ctx.nativeSlice.nativeVisibility = ctx.visibility
		ctx.nativeSlice.nativeOrigin = { ctx.bxo, ctx.byo, ctx.bzo }
	end
	local sections = ctx.nativeVoxels[7]
	sections[#sections + 1] = { snapshot.indices, snapshot.states, recipes, x, y, z,
		math.min( x + size - 1, MC.CS - 1 ), math.min( y + size - 1, MC.CS - 1 ), math.min( z + size - 1, MC.CH - 1 ) }
	ctx.meshPerf.blocksVisited = ctx.meshPerf.blocksVisited + used
	local backend = MC.NativeChunkBackend
	if N.worldAvailable and ctx.sectionIndex and backend and backend.IsActive() then
		ctx.nativeWorldHandle, ctx.nativeWorldRecipes = backend.GetHandle(), recipes
		ctx.nativeTopology = snapshot.nativeOnly == true
		N.worldBlocks, N.worldSections = N.worldBlocks + used, N.worldSections + 1
	end
	return recipes
end

function N.Upload( buffer, firstQuad, material )
	local result, err = N.module.UploadL2Part( buffer.nativeJob, buffer.nativePart, firstQuad, "!" .. material:GetName() )
	MC.RenderL2Resources.Require( result ~= nil, "native_l2_build", "Native L2 batch failed: " .. tostring( err ) )
	return result
end

function N.IsPending( key, index )
	local sections = N.pending[key]
	if not sections then return false end
	return not index or sections[0] ~= nil or sections[index] ~= nil
end

function N.CanBuild()
	return N.pendingCount < 8 and N.module.CanSubmitL2()
end

local function current( tx )
	syncRecipes()
	return not tx.invalid and N.active and tx.module == N.module
		and tx.world == MC.World and tx.generation == MC.StateWorldGeneration
		and tx.chunk == MC.GetChunkByKey( tx.key ) and tx.size == MC.API.Coords.BlockSize()
		and tx.cs == MC.CS and tx.ch == MC.CH
		and tx.bindings == MC.RenderBlockBindings.generation
		and tx.visual == MC.BlockStateVisualRevision and tx.schema == MC.BlockStateSchemaById
		and tx.recipes == N.cubeRevision
		and ( not tx.ctx.nativeWorldHandle or tx.module.IsWorldL2Current( tx.id, tx.ctx.nativeWorldHandle ) == true )
end

function N.Invalidate( key, index )
	local sections = N.pending[key]
	if not sections then return end
	for slot, tx in pairs( sections ) do
		if not index or slot == 0 or slot == index then
			tx.invalid = true
			tx.module.CancelL2Section( tx.id )
		end
	end
end

local function remove( tx )
	local sections = N.pending[tx.key]
	sections[tx.index or 0] = nil
	if next( sections ) == nil then N.pending[tx.key] = nil end
	N.pendingCount = N.pendingCount - 1
	tx.module.CancelL2Section( tx.id )
end

function N.CancelAll()
	local faults = {}
	local function report( code, message ) faults[#faults + 1] = { code, message } end
	for _, sections in pairs( N.pending ) do
		for _, tx in pairs( sections ) do
			remove( tx )
			tx.discard( report )
		end
	end
	for _, fault in ipairs( faults ) do MC.Fault( fault[1], "%s", fault[2] ) end
end

function N.Submit( ctx, commit, discard )
	syncRecipes()
	local commands = {}
	for i, part in ipairs( ctx.nativeParts ) do commands[i] = part.nativeCommands end
	local started = SysTime()
	local id, err
	if ctx.nativeWorldHandle then
		id, err = N.module.SubmitWorldL2Section( commands, ctx.nativeWorldHandle,
			ctx.chunk.cx, ctx.chunk.cy, ctx.chunk.cz, ctx.sectionIndex, ctx.nativeWorldRecipes,
			ctx.nativeVoxels[8], ctx.nativeTopology )
	else
		id, err = N.module.SubmitL2Section( commands, readerFor( ctx.nativeSlice ), ctx.nativeSlice.snapshot, ctx.nativeVoxels )
	end
	N.submitMS = N.submitMS + ( SysTime() - started ) * 1000
	if id == false then return false end
	if not id then
		N.DisableAfterFailure( err )
		MC.RenderL2Resources.Require( false, "native_l2_submit", "Native L2 submission failed: " .. tostring( err ) )
	end
	local key, index = ctx.key, ctx.sectionIndex
	local sections = N.pending[key]
	if not sections then sections = {} N.pending[key] = sections end
	local tx = { id = id, key = key, index = index, ctx = ctx, nextPart = 1, module = N.module,
		world = MC.World, generation = MC.StateWorldGeneration, chunk = ctx.chunk, size = ctx.blockSize,
		cs = MC.CS, ch = MC.CH, bindings = MC.RenderBlockBindings.generation,
		recipes = N.cubeRevision,
		visual = MC.BlockStateVisualRevision, schema = MC.BlockStateSchemaById, commit = commit, discard = discard }
	sections[index or 0] = tx
	N.pendingCount = N.pendingCount + 1
	for i, part in ipairs( ctx.nativeParts ) do part.nativeJob, part.nativePart = id, i end
	return true
end

function N.Pump( budget )
	local faults = {}
	local function report( code, message ) faults[#faults + 1] = { code, message } end
	for _, sections in pairs( N.pending ) do
		for _, tx in pairs( sections ) do
			if not current( tx ) then
				remove( tx )
				tx.discard( report )
				N.stale = N.stale + 1
				-- Keep dirty work queued. Unloaded chunks must not be recreated.
				if MC.GetChunkByKey( tx.key ) then
					if tx.index then MC.ClearSectionBlockEmitCache( tx.key, tx.index )
					else MC.ClearChunkBlockEmitCache( tx.key ) end
					-- Global revisions can change without an explicit section dirty.
					-- Explicit invalidation already queued work, or intentionally freed it.
					if not tx.invalid then
						if tx.index then MC.RequestRenderSectionGeometry( tx.key, tx.index )
						else MC.MarkChunkDirty( tx.key, true ) end
					end
					if MC.WakeLazyMeshBuilder then MC.WakeLazyMeshBuilder() end
				end
			else
				local ok, err = pcall( function()
					local ready, reason = tx.module.PollL2Section( tx.id )
					MC.RenderL2Resources.Require( ready ~= nil, "native_l2_worker", tostring( reason ) )
					if not ready then return end
					if tx.ctx.nativeTopology and not tx.ctx.nativeTopologyValue then
						local value, problem = tx.module.GetWorldL2Topology( tx.id )
						MC.RenderL2Resources.Require( value ~= nil, "native_l2_topology", tostring( problem ) )
						tx.ctx.nativeTopologyValue = value
					end
					local parts = tx.ctx.nativeParts
					if tx.ctx.nativeVoxels and not tx.partsResolved then
						local layout, layoutError = tx.module.GetL2SectionParts( tx.id )
						MC.RenderL2Resources.Require( layout ~= nil and #layout >= #parts, "native_l2_layout", tostring( layoutError ) )
						for i = #parts + 1, #layout do
							local info = layout[i]
							local source = tx.ctx.nativeGroups[info.group]
							MC.RenderL2Resources.Require( source ~= nil and info.quads > 0
								and info.quads <= tx.ctx.nativeVoxels[8], "native_l2_layout", "invalid worker group" )
							local part = {}
							for field, value in pairs( source ) do part[field] = value end
							part.nv, part.quadCount = info.quads * 6, info.quads
								part.nativeVoxelPart, part.nativeCommands = true, nil
							part.nativeJob, part.nativePart = tx.id, i
							parts[i] = part
						end
						tx.partsResolved = true
					end
					while tx.nextPart <= #parts do
						if budget.attempts > 0 and budget.deadline and SysTime() >= budget.deadline then return end
						budget.attempts = budget.attempts + 1
						local started = SysTime()
						tx.ctx.uploadNativePart( parts[tx.nextPart] )
						local elapsed = ( SysTime() - started ) * 1000
						tx.ctx.nativeUploadMS = ( tx.ctx.nativeUploadMS or 0 ) + elapsed
						tx.ctx.meshPerf.flushMS = tx.ctx.meshPerf.flushMS + elapsed
						tx.nextPart = tx.nextPart + 1
					end
					local started = SysTime()
					tx.commit()
					N.commitMS = N.commitMS + ( SysTime() - started ) * 1000
					N.completed = N.completed + 1
					if MC.RenderPipeline and MC.RenderPipeline.NoteDirtyBuild then MC.RenderPipeline.NoteDirtyBuild( 1 ) end
					local dirty = MC.MeshDirty[tx.key]
					if tx.index and type( dirty ) == "table" then
						dirty[tx.index] = nil
						if next( dirty ) == nil then MC.MeshDirty[tx.key] = nil end
					elseif not tx.index then MC.MeshDirty[tx.key] = nil end
					if not MC.MeshDirty[tx.key] and MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[tx.key] = nil end
					remove( tx )
				end )
				if not ok then
					remove( tx )
					tx.discard( report )
					N.DisableAfterFailure( type( err ) == "table" and err.message or err )
					report( type( err ) == "table" and err.code or "native_l2_publish",
						"chunk " .. tostring( tx.key ) .. " section " .. tostring( tx.index ) .. ": "
							.. tostring( type( err ) == "table" and err.message or err )
							.. ( tx.ctx.nativePublished and "; published L2 geometry retained; rebuild queued"
								or "; previous L2 section retained" ) )
				end
			end
		end
	end
	for _, fault in ipairs( faults ) do MC.Fault( fault[1], "%s", fault[2] ) end
end

if N.active and not N.Probe() then N.DisableAfterFailure( N.reason ) end

if concommand then
	concommand.Add( "mc_native_status", function()
		local available, reason = N.Probe()
		print( "[MC Native L2] requested=" .. tostring( MC.NativeMeshPreference:GetBool() )
			.. " active=" .. tostring( N.active ) .. " available=" .. tostring( available )
			.. " layout=mc:quad_corners_v1 scheduler=Lua-sections execution=worker-pool" )
		if reason or N.failure then print( "[MC Native L2] " .. tostring( N.failure or reason ) ) end
		if MC.NativeTakeover then PrintTable( MC.NativeTakeover.GetStatus() ) end
		if available then PrintTable( N.module.GetL2Stats() ) end
		PrintTable( { pendingSections = N.pendingCount, committedSections = N.completed,
				staleSections = N.stale, submitMS = N.submitMS, commitMS = N.commitMS,
				sectionWorkerAvailable = N.voxelAvailable, sectionWorkerBlocks = N.voxelBlocks, luaEmitterBlocks = N.fallbackBlocks,
				modelWorkerAvailable = N.modelAvailable, worldSectionAvailable = N.worldAvailable,
				worldWorkerBlocks = N.worldBlocks, worldWorkerSections = N.worldSections } )
	end )
	concommand.Add( "mc_native_toggle", function()
		RunConsoleCommand( "mc_native_mesh", MC.NativeMeshPreference:GetBool() and "0" or "1" )
	end )
end
