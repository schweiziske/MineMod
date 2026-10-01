-- One synchronous conversion slice, in block coordinates. Never keep this
-- cache across frames; section lighting tokens guard the enclosing candidate.
MC = MC or {}
local S = {}
MC.RenderL2Snapshot = S
local floor = math.floor
local FIELDS = { "emission", "dampening", "emissive", "shade", "viewBlocking", "solidRender", "fullCollision" }
local Snapshot = {}
Snapshot.__index = Snapshot

local function integer( value, low, high )
	return type( value ) == "number" and value >= low and value <= high and value == floor( value )
end

function Snapshot:Index( bx, by, bz )
	local x, y, z = bx - self.x, by - self.y, bz - self.z
	if not MC.Check( integer( x, 0, self.sx - 1 ) and integer( y, 0, self.sy - 1 ) and integer( z, 0, self.sz - 1 ),
		"l2_snapshot_bounds", "sample %s,%s,%s is outside the two-cell halo", bx, by, bz ) then return nil end
	return x + self.sx * ( y + self.sy * z )
end

function Snapshot:Read( bx, by, bz )
	local index = self:Index( bx, by, bz )
	if index == nil then return nil end
	local cached = self.cells[index]
	if cached then self.hits = self.hits + 1 return cached end
	self.misses = self.misses + 1
	local cx, cy, cz, li = self.cellToChunk( bx, by, bz )
	local key = self.chunkKey( cx, cy, cz )
	local chunk = self.getChunk( key )
	local loaded = chunk ~= nil or not self.streaming
		or cz < self.minCZ or cz > self.maxCZ or self.isLoaded( key ) == true
	if not loaded then
		-- A streaming boundary is explicitly opaque/dark, not air with sky 15.
		local cell = { block = 0, sky = 0, emission = 0, dampening = 15, emissive = false, shade = 0.2,
			viewBlocking = true, solidRender = true, fullCollision = true, loaded = false, stateId = false }
		self.cells[index], self.unloaded = cell, self.unloaded + 1
		return cell
	end
	local stateId = 0
	if chunk then
		local err
		stateId, err = self.getState( chunk, li )
		if not MC.Check( integer( stateId, 0, 4294967295 ), "l2_snapshot_state",
			"state read failed at %s,%s,%s: %s", bx, by, bz, tostring( err ) ) then return nil end
	end
	local properties = self.properties.Get( stateId, bx, by, bz )
	if not properties then return nil end
	if properties.collisionContext ~= "none" then
		local context = false
		if self.readContext then
			context = self.readContext( stateId, bx, by, bz, properties.collisionContext )
		elseif chunk and chunk.blockEntities and chunk.blockEntities[li] then
			MC.Fault( "l2_snapshot_context", "live %s has no lighting context resolver at %s,%s,%s",
				properties.collisionContext, bx, by, bz )
			return nil
		end
		properties = self.properties.Resolve( stateId, context )
		if not properties then return nil end
	end
	-- Sparse air and loaded-empty chunks both consult the actual light stores.
	local brightness, level, block, sky = self.sampleLight( bx, by, bz, 0 )
	if not MC.Check( integer( block, 0, 15 ) and integer( sky, 0, 15 ), "l2_snapshot_light",
		"raw block/sky levels missing at %s,%s,%s", bx, by, bz ) then return nil end
	local cell = { block = block, sky = sky, stateId = stateId, loaded = true }
	for i = 1, #FIELDS do local field = FIELDS[i] cell[field] = properties[field] end
	self.cells[index] = cell
	return cell
end

function S.New( chunk )
	local cs, ch = MC.CS, MC.CH
	if not MC.Check( type( chunk ) == "table" and integer( chunk.cx, -2147483648, 2147483647 )
		and integer( chunk.cy, -2147483648, 2147483647 ) and integer( chunk.cz, -2147483648, 2147483647 )
		and integer( cs, 1, 64 ) and integer( ch, 1, 64 ),
		"l2_snapshot_chunk", "expected grid chunk and runtime dimensions" ) then return nil end
	local accessors = { "CellToChunk", "ChunkKey", "GetChunkByKey", "IsChunkLoaded", "GetChunkBlockStateByLocalIndex", "SampleLighting" }
	for i = 1, #accessors do
		local key = accessors[i]
		if not MC.Check( type( MC[key] ) == "function", "l2_snapshot_dependency", "missing %s", key ) then return nil end
	end
	local properties = MC.StateLighting
	if not MC.Check( properties and properties.ready, "l2_snapshot_catalog", "state lighting catalog is not ready" ) then return nil end
	if properties.Prepare and not properties.Prepare() then return nil end
	-- Full snapshots omit air-only chunks. Only partial/streamed worlds have
	-- unknown chunks; mode 1 also declares the world's complete vertical extent.
	local transport = MC.StateNetworkTransport
	local streaming = MC.HttpChunkSync ~= nil or ( transport ~= nil and transport.streaming == true )
	local minCZ, maxCZ = -math.huge, math.huge
	if transport and transport.streaming and not MC.HttpChunkSync then
		minCZ, maxCZ = transport.streamMinCZ or minCZ, transport.streamMaxCZ or maxCZ
	end
	local snapshot = setmetatable( {
		x = chunk.cx * cs - 2, y = chunk.cy * cs - 2, z = chunk.cz * ch - 2,
		sx = cs + 4, sy = cs + 4, sz = ch + 4, cells = {}, hits = 0, misses = 0, unloaded = 0,
		cellToChunk = MC.CellToChunk, chunkKey = MC.ChunkKey, getChunk = MC.GetChunkByKey, isLoaded = MC.IsChunkLoaded,
		streaming = streaming, minCZ = minCZ, maxCZ = maxCZ,
		getState = MC.GetChunkBlockStateByLocalIndex, sampleLight = MC.SampleLighting,
		properties = properties, readContext = MC.ResolveVanillaLightingContext,
	}, Snapshot )
	snapshot.reader = function( bx, by, bz ) return snapshot:Read( bx, by, bz ) end
	return snapshot
end
