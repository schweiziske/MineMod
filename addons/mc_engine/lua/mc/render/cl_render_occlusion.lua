-- Conservative section portals. No rays, GPU readback or per-frame objects.
-- Topology is built from immutable snapshot revisions; graph edges, traversal
-- stamps and queues are numeric arrays reused across frames and chunk edits.
MC = MC or {}
local O = {}
MC.RenderOcclusion = O
local floor, band, bor = math.floor, bit.band, bit.bor
local byte, char, concat = string.byte, string.char, table.concat
local SIZE = MC.RENDER_SECTION_SIZE or 16
local CS, CH = MC.CS, MC.CH
local XY, Z = CS / SIZE, CH / SIZE
local TOTAL, CELLS = XY * XY * Z, SIZE ^ 3
local bits, opposite = { 1, 2, 4, 8, 16, 32 }, { 2, 1, 4, 3, 6, 5 }
local dx, dy, dz = { 0, 0, 1, -1, 0, 0 }, { 0, 0, 0, 0, 1, -1 }, { 1, -1, 0, 0, 0, 0 }
local OPEN = { 63, 63, 63, 63, 63, 63, uniform = 63, graphOpen = true }
local SOLID = { 0, 0, 0, 0, 0, 0, uniform = 64 }
O.OPEN, O.SOLID = OPEN, SOLID
local cellEdges, cellFaces, sectionEdges, sectionCross = {}, {}, {}, {}
local cells, flood, characters, codes = {}, {}, {}, {}
for i = 0, 64 do codes[i] = char( i ) end
for i = 1, CELLS do
	local n = i - 1
	local x, y, z = n % SIZE, floor( n / SIZE ) % SIZE, floor( n / ( SIZE * SIZE ) )
	local mask = 0
	for face = 1, 6 do
		local nx, ny, nz = x + dx[face], y + dy[face], z + dz[face]
		local outside = nx < 0 or nx >= SIZE or ny < 0 or ny >= SIZE or nz < 0 or nz >= SIZE
		cellEdges[n * 6 + face] = outside and 0 or nx + ny * SIZE + nz * SIZE * SIZE + 1
		if outside then mask = mask + bits[face] end
	end
	cellFaces[i] = mask
end
for i = 1, TOTAL do
	local n = i - 1
	local x, y, z = n % XY, floor( n / XY ) % XY, floor( n / ( XY * XY ) )
	for face = 1, 6 do
		local nx, ny, nz = x + dx[face], y + dy[face], z + dz[face]
		local slot = n * 6 + face
		sectionCross[slot] = nx < 0 or nx >= XY or ny < 0 or ny >= XY or nz < 0 or nz >= Z
		sectionEdges[slot] = nx % XY + ( ny % XY ) * XY + ( nz % Z ) * XY * XY + 1
	end
end

local byKey, topology, neighbors, freeBases = {}, {}, {}, {}
local boundary, boundarySlot, missing = {}, {}, {}
local seen, exits, sent, queued, queue = {}, {}, {}, {}, {}
local nextBase, revision, stamp, tail = 0, 0, 0, 0
local restricted = 0
local cachedRevision, lastRoot, lastSeed, exteriorSeen = -1, 0, 0, false
local world, worldGeneration, properties, visualRevision
local classes, classEpoch = {}, 0
local neighborChunks = {}
local stats = { nodes = 0, chunks = 0, builds = 0, topologyHits = 0, traversals = 0,
	cacheHits = 0, visited = 0, queuePeak = 0, lastMS = 0, topologyMS = 0, openBypasses = 0 }
O.stats = stats

function O.Reset()
	byKey, topology, neighbors, freeBases = {}, {}, {}, {}
	boundary, boundarySlot, missing = {}, {}, {}
	seen, exits, sent, queued, queue = {}, {}, {}, {}, {}
	nextBase, cachedRevision, lastRoot, lastSeed, exteriorSeen = 0, -1, 0, 0, false
	restricted = 0
	revision = revision + 1
	O.active, stats.nodes, stats.chunks, stats.visited = false, 0, 0, 0
end

local function syncContext()
	if world ~= MC.World or worldGeneration ~= MC.StateWorldGeneration then
		O.Reset()
		world, worldGeneration = MC.World, MC.StateWorldGeneration
	end
	if properties ~= MC.VanillaStateLighting or visualRevision ~= MC.BlockStateVisualRevision then
		O.Reset()
		properties, visualRevision = MC.VanillaStateLighting, MC.BlockStateVisualRevision
		classes, classEpoch = {}, classEpoch + 1
	end
end

local function generatedCube( state )
	-- Some ordinary cubes use generated plans (including weighted stone).
	-- Prove all alternatives enclose the unit cube; collision alone is insufficient.
	local visit = MC.VisitStateVisualModelCandidates
	if not visit then return false end -- Legacy/custom catalogs have no geometric proof.
	local found, complete = false, true
	visit( state, function( modelId )
		found = true
		if MC.StateVisualModelHasTransform( modelId ) then complete = false return end
		local model = MC.StateVisualModelData( modelId )
		if not model or not model.generatedStateVisual or #model.modelQuads ~= 6 then complete = false return end
		local faces = 0
		for _, quad in ipairs( model.modelQuads ) do
			local face = MC.RenderMeshConstants.FACES[quad.face]
			if not face then complete = false return end
			local corners = 0
			for vertex = 1, 4 do
				local x, y, z = MC.ModelQuadVertex( quad, vertex )
				for corner = 1, 4 do
					local c = face.c[corner]
					if x == c[1] and y == c[2] and z == c[3] then
						corners = bor( corners, 2 ^ ( corner - 1 ) )
						break
					end
				end
			end
			if corners ~= 15 then complete = false return end
			faces = bor( faces, bits[quad.face] )
		end
		if faces ~= 63 then complete = false end
	end )
	return found and complete
end

local function blockingState( state )
	local cached = classes[state]
	if cached ~= nil then return cached end
	-- Custom, missing or contextual data is open for this optimization. In
	-- particular, neither collision alone nor light opacity proves a solid wall.
	classes[state] = false
	if not properties or not properties.ready or properties.Contains and not properties.Contains( state ) then return false end
	local p = properties.Get( state )
	if not p or p.solidRender ~= true or p.fullCollision ~= true or p.viewBlocking ~= true
		or p.dynamicShape == true or p.viewContext and p.viewContext ~= "none"
		or p.collisionContext and p.collisionContext ~= "none" then return false end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( state )
	if schema and MC.BlockStateVisualResolvers and MC.BlockStateVisualResolvers[schema.name] then return false end
	local visual = MC.ResolveBlockStateVisual( state )
	if not visual or visual.cacheable == false
		or visual.translucent and visual.translucent ~= false then return false end
	local block = visual.block or MC.Blocks[visual.id]
	if not block or block.transparent == true or block.translucent == true then return false end
	if visual.generatedVisualOverride == true then
		classes[state] = generatedCube( state )
		return classes[state]
	end
	local full = visual.fullCube
	if full == nil then full = block.fullCube end
	if full ~= nil then
		if full ~= true then return false end
	-- Ordinary cubes omit fullCube; the state query resolves their geometry.
	elseif not MC.BlockVisualIsFullCube( visual ) then return false end
	classes[state] = true
	return true
end

function O.NativeBlockingState( state )
	syncContext()
	return blockingState( state )
end

function O.BuildTopology( snapshot )
	syncContext()
	if not snapshot then return OPEN end
	if snapshot.occlusionEpoch == classEpoch and snapshot.occlusion then
		stats.topologyHits = stats.topologyHits + 1
		return snapshot.occlusion
	end
	local started = SysTime()
	for i = 1, CELLS do cells[i] = 0 end
	local blocked = 0
	for i = 1, snapshot.count do
		if blockingState( snapshot.states[i] ) then
			local li = snapshot.indices[i]
			local x, y, z = li % CS, floor( li / CS ) % CS, floor( li / ( CS * CS ) )
			local slot = x % SIZE + ( y % SIZE ) * SIZE + ( z % SIZE ) * SIZE * SIZE + 1
			cells[slot], blocked = 64, blocked + 1
		end
	end
	local result
	if blocked == 0 then result = OPEN
	elseif blocked == CELLS then result = SOLID
	else
		result = { 0, 0, 0, 0, 0, 0 }
		for first = 1, CELLS do
			if cells[first] == 0 then
				local head, count, mask = 1, 1, 0
				flood[1], cells[first] = first, -1
				while head <= count do
					local cell = flood[head]
					head = head + 1
					mask = bor( mask, cellFaces[cell] )
					local offset = ( cell - 1 ) * 6
					for face = 1, 6 do
						local neighbor = cellEdges[offset + face]
						if neighbor ~= 0 and cells[neighbor] == 0 then
							count = count + 1
							flood[count], cells[neighbor] = neighbor, -1
						end
					end
				end
				for i = 1, count do cells[flood[i]] = mask + 128 end
				for face = 1, 6 do
					if band( mask, bits[face] ) ~= 0 then result[face] = bor( result[face], mask ) end
				end
			end
		end
		for i = 1, CELLS do
			local value = cells[i]
			characters[i] = codes[value >= 128 and value - 128 or value]
		end
		result.cells = concat( characters ) -- One byte per cell, no retained per-cell tables.
		result.graphOpen = result[1] == 63 and result[2] == 63 and result[3] == 63
			and result[4] == 63 and result[5] == 63 and result[6] == 63
	end
	snapshot.occlusion, snapshot.occlusionEpoch = result, classEpoch
	stats.builds = stats.builds + 1
	stats.topologyMS = ( SysTime() - started ) * 1000
	return result
end

local function updateBoundary( id )
	local mask, offset = 0, ( id - 1 ) * 6
	for face = 1, 6 do if neighbors[offset + face] == 0 then mask = mask + bits[face] end end
	missing[id] = mask
	local slot = boundarySlot[id]
	if mask ~= 0 and not slot then
		boundary[#boundary + 1], boundarySlot[id] = id, #boundary + 1
	elseif mask == 0 and slot then
		local last = boundary[#boundary]
		boundary[slot], boundarySlot[last] = last, slot
		boundary[#boundary], boundarySlot[id] = nil, nil
	end
end

function O.Forget( key, expectedChunk )
	local record = byKey[key]
	if not record or expectedChunk and record.chunk ~= expectedChunk then return end
	for i = 1, TOTAL do
		local id = record.base + i
		local offset = ( id - 1 ) * 6
		for face = 1, 6 do
			local neighbor = neighbors[offset + face]
			if neighbor ~= 0 and ( neighbor <= record.base or neighbor > record.base + TOTAL ) then
				neighbors[( neighbor - 1 ) * 6 + opposite[face]] = 0
				updateBoundary( neighbor )
			end
			neighbors[offset + face] = -1 -- remove this node from the exterior list.
		end
		updateBoundary( id )
		if not topology[id].graphOpen then restricted = restricted - 1 end
		topology[id], seen[id], exits[id], sent[id], queued[id] = nil, 0, 0, 0, 0
	end
	byKey[key] = nil
	freeBases[#freeBases + 1] = record.base
	stats.nodes, stats.chunks = stats.nodes - TOTAL, stats.chunks - 1
	revision = revision + 1
end

local function register( key, chunk )
	local record = byKey[key]
	if record and record.chunk == chunk then return record end
	if record then O.Forget( key ) end
	local base = freeBases[#freeBases]
	if base then freeBases[#freeBases] = nil
	else base, nextBase = nextBase, nextBase + TOTAL end
	record = { key = key, chunk = chunk, base = base }
	byKey[key] = record
	for face = 1, 6 do
		neighborChunks[face] = byKey[MC.ChunkKey( chunk.cx + dx[face], chunk.cy + dy[face], chunk.cz + dz[face] )]
	end
	for i = 1, TOTAL do
		local id = base + i
		topology[id], seen[id], exits[id], sent[id], queued[id] = OPEN, 0, 0, 0, 0
		for face = 1, 6 do
			local slot, neighbor = ( i - 1 ) * 6 + face, 0
			if not sectionCross[slot] then neighbor = base + sectionEdges[slot]
			elseif neighborChunks[face] then neighbor = neighborChunks[face].base + sectionEdges[slot] end
			neighbors[( id - 1 ) * 6 + face] = neighbor
			if neighbor ~= 0 and sectionCross[slot] then
				neighbors[( neighbor - 1 ) * 6 + opposite[face]] = id
				updateBoundary( neighbor )
			end
		end
		updateBoundary( id )
	end
	for face = 1, 6 do neighborChunks[face] = nil end
	stats.nodes, stats.chunks = stats.nodes + TOTAL, stats.chunks + 1
	revision = revision + 1
	return record
end

function O.Commit( key, chunk, index, value )
	syncContext()
	if not chunk then O.Forget( key ) return end
	local record = register( key, chunk )
	local changed = false
	for i = index or 1, index or TOTAL do
		local nextTopology = index and value or value[i]
		if topology[record.base + i] ~= nextTopology then
			if not topology[record.base + i].graphOpen then restricted = restricted - 1 end
			if not nextTopology.graphOpen then restricted = restricted + 1 end
			topology[record.base + i], changed = nextTopology, true
		end
	end
	if changed then revision = revision + 1 end
end

function O.Invalidate( key, index )
	local record = byKey[key]
	if not record then return end
	if record.chunk ~= MC.GetChunkByKey( key ) then O.Forget( key ) return end
	local changed = false
	for i = index or 1, index or TOTAL do
		local id = record.base + i
		if topology[id] ~= OPEN then
			if not topology[id].graphOpen then restricted = restricted - 1 end
			topology[id], changed = OPEN, true
		end
	end
	if changed then revision = revision + 1 end
end

local function visit( id, mask )
	if seen[id] ~= stamp then
		seen[id], exits[id], sent[id] = stamp, 0, 0
		stats.visited = stats.visited + 1
	end
	local combined = bor( exits[id], mask )
	if combined == exits[id] then return end
	exits[id] = combined
	if queued[id] ~= stamp then
		tail = tail + 1
		queue[tail], queued[id] = id, stamp
	end
end

local function enter( id, face )
	-- A solid neighbor is still drawable: it owns the wall blocking further
	-- traversal. Only propagation, never that wall, is stopped by its portals.
	visit( id, topology[id][face] )
end

local function visitExterior()
	exteriorSeen = true
	for i = 1, #boundary do
		local id = boundary[i]
		local mask = missing[id]
		for face = 1, 6 do if band( mask, bits[face] ) ~= 0 then enter( id, face ) end end
	end
end

local function viewRoot( bx, by, bz )
	syncContext()
	O.active = false
	if bx == nil or by == nil or bz == nil or stats.nodes == 0 or not MC.MeshOcclusionCull:GetBool() then return false, 0, 63 end
	local cx, cy, cz = floor( bx / CS ), floor( by / CS ), floor( bz / CH )
	local record = byKey[MC.ChunkKey( cx, cy, cz )]
	local root, seed = 0, 63
	if record and record.chunk == MC.GetChunkByKey( record.key ) then
		local x, y, z = bx - cx * CS, by - cy * CS, bz - cz * CH
		local index = floor( x / SIZE ) + floor( y / SIZE ) * XY + floor( z / SIZE ) * XY * XY + 1
		root = record.base + index
		local source = topology[root]
		seed = source.uniform
		if seed == nil then seed = byte( source.cells, x % SIZE + ( y % SIZE ) * SIZE + ( z % SIZE ) * SIZE * SIZE + 1 ) end
		if seed == 64 then return false, 0, 63 end -- noclip/ambiguous camera inside a wall.
	end
	if restricted == 0 and seed ~= 0 then
		stats.openBypasses, stats.lastMS, stats.visited = stats.openBypasses + 1, 0, 0
		return false, 0, 63 -- No graph edge can block anything.
	end
	return true, root, seed
end

local nativeGraphRevision, nativeGraphModule
function O.PrepareNativeView( bx, by, bz, module )
	local active, root, seed = viewRoot( bx, by, bz )
	if active and ( nativeGraphRevision ~= revision or nativeGraphModule ~= module ) then
		local ok, err
		if module.SetL2DrawSpatialGraph then
			ok, err = module.SetL2DrawSpatialGraph( revision, nextBase, topology, neighbors, byKey, TOTAL, XY, Z, SIZE )
		else
			-- Older loaded DLLs keep their existing ABI until the next client restart.
			ok, err = module.SetL2DrawGraph( revision, nextBase, topology, neighbors, byKey, TOTAL )
		end
		if not ok then error( "Native visibility graph: " .. tostring( err ), 0 ) end
		nativeGraphRevision, nativeGraphModule = revision, module
	end
	if not active then return false, root, seed, 0, 0, 0 end
	return active, root, seed, floor( bx / SIZE ), floor( by / SIZE ), floor( bz / SIZE )
end

function O.PrepareView( bx, by, bz )
	local active, root, seed = viewRoot( bx, by, bz )
	if not active then return end
	O.active = true
	-- Moving inside the already reached component needs no new flood, even
	-- across a section boundary. Facing changes never invalidate connectivity.
	if cachedRevision == revision and ( root == 0 and exteriorSeen
		or root == lastRoot and seed == lastSeed
		or root ~= 0 and seed ~= 0 and seen[root] == stamp and band( exits[root], seed ) == seed ) then
		stats.cacheHits, stats.lastMS = stats.cacheHits + 1, 0
		return
	end
	local started = SysTime()
	stamp, tail, exteriorSeen, stats.visited = stamp + 1, 0, false, 0
	if root == 0 then visitExterior() else visit( root, seed ) end
	local head = 1
	while head <= tail do
		local id = queue[head]
		head, queued[id] = head + 1, 0
		local pending = band( exits[id], 63 - sent[id] )
		sent[id] = exits[id]
		for face = 1, 6 do
			if band( pending, bits[face] ) ~= 0 then
				local neighbor = neighbors[( id - 1 ) * 6 + face]
				if neighbor ~= 0 then enter( neighbor, opposite[face] )
				elseif not exteriorSeen then visitExterior() end
			end
		end
	end
	cachedRevision, lastRoot, lastSeed = revision, root, seed
	stats.traversals = stats.traversals + 1
	stats.lastMS, stats.queuePeak = ( SysTime() - started ) * 1000, math.max( stats.queuePeak, tail )
end

function O.ChunkRecord( key, chunk )
	if not O.active then return nil end
	local record = byKey[key]
	if record and record.chunk == chunk then return record end
end

function O.SectionVisible( record, index )
	return not record or seen[record.base + index] == stamp
end
