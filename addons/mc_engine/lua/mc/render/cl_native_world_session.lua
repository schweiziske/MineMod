-- Persistent world protocol. Render packs still own materials and stages.
MC = MC or {}
local T = MC.NativeTakeover or {}
T.PROTOCOL = 2
MC.NativeTakeover = T
local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat

function T.Probe()
	local module = mcmesh
	if type( module ) ~= "table" or type( module.GetTakeoverCapabilities ) ~= "function"
		or type( module.CreateWorldSession ) ~= "function" then return nil, "DLL has no independent world-session protocol" end
	local ok, caps = pcall( module.GetTakeoverCapabilities )
	if not ok or type( caps ) ~= "table" or caps.protocol ~= T.PROTOCOL or caps.versionEncoding ~= "hex64" then
		return nil, "incompatible world-session protocol"
	end
	return caps
end

function T.GetStatus()
	local caps, reason = T.Probe()
	local mesh = MC.NativeL2 and MC.NativeL2.IsActive() == true
	local active = T.active ~= nil
	local terrain = active and mesh and MC.NativeL2.worldAvailable == true
		and caps ~= nil and caps.terrainWorker == 1
	local status = {
		mode = active and "native_world_l2" or ( mesh and "native_l2_async" or "lua_l2" ),
		fullTakeover = false, worldBackend = active and "native" or "lua",
		worldLightBackend = active and "native_worker" or "lua",
		meshExecution = terrain and "native_world_workers_lua_sections"
			or ( mesh and "native_workers_lua_sections" or "lua_sync" ),
		terrainBackend = terrain and "native_models_shapes_fluids_lua_specials" or "lua",
		atlasUploader = "lua", capabilities = caps, reason = reason,
	}
	if caps then
		status.reason = terrain and "Native world/model/shape/fluid workers; special emitters, scheduling and GPU publication remain Lua"
			or ( active and "Native world active; direct terrain worker inactive" or "persistent Native world inactive" )
	end
	if T.active then status.world = T.active.handle:GetStats() end
	if T.development then status.development = T.development.handle:GetStats() end
	return status
end

local function u32( value )
	return char( value % 256, floor( value / 256 ) % 256, floor( value / 65536 ) % 256, floor( value / 16777216 ) % 256 )
end
local function integer( value, maximum )
	return type( value ) == "number" and value >= 0 and value <= maximum and value == floor( value )
end

local function renderClass( stateId, visual, bx, by, bz )
	if stateId == 0 then return 0 end
	local id, full, translucent
	if MC.ResolveBlockStateRenderClass then
		id, full, translucent = MC.ResolveBlockStateRenderClass( stateId, bx, by, bz )
	end
	if id == nil then id = visual.id or visual.blockId end
	if full == nil then full = MC.BlockVisualIsFullCube( visual, bx, by, bz ) end
	if translucent == nil then translucent = MC.BlockVisualIsTranslucent( visual, bx, by, bz ) end
	if not integer( id, 536870911 ) or full == nil or translucent == nil then return nil, "invalid render class" end
	local block = MC.Blocks[id]
	local transparent = translucent or block and block.transparent
	local special = MC.BlockUsesSpecialVisualEmitter and MC.BlockUsesSpecialVisualEmitter( id )
	return id * 8 + ( full and 1 or 0 ) + ( transparent and 2 or 0 ) + ( special and 4 or 0 )
end

-- Resolve at registration/mutation boundaries, never inside vertex loops.
local function fluidProfile( stateId, visual, bx, by, bz )
	local fluid = { kind = 0, height = 0, falling = false, solid = false, blocksMotion = false,
		ice = false, full = false, empty = true, lightSolid = false, boxes = {} }
	if stateId == 0 then return fluid end
	local kind, height, _, falling = MC.Liquid.DecodeState( stateId )
	fluid.kind = kind == "water" and 1 or kind == "lava" and 2 or 0
	fluid.height, fluid.falling = height or 0, falling == true
	fluid.full = MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true
	fluid.solid = MC.Liquid.StateSolid( stateId, bx, by, bz ) == true
	fluid.blocksMotion = MC.Liquid.StateBlocksMotion( stateId, bx, by, bz ) == true
	local translucent = MC.BlockVisualIsTranslucent( visual, bx, by, bz )
	fluid.empty = translucent == true or MC.Blocks[visual.id].transparent == true
	fluid.lightSolid = not translucent and MC.BlockVisualHasCollision( visual, bx, by, bz )
		and MC.BlockVisualIsFullCube( visual, bx, by, bz ) == true
	local name = MC.Blocks[visual.id].name
	fluid.ice = name == "ice" or name == "frosted_ice" or name == "packed_ice" or name == "blue_ice"
	if not fluid.full then
		fluid.boxes = MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz ) or {}
	end
	return fluid
end

local function fluidProfileKey( f )
	local parts = { f.kind, string.format( "%.17g", f.height ) }
	for _, field in ipairs( { "falling", "solid", "blocksMotion", "ice", "full", "empty", "lightSolid" } ) do
		parts[#parts + 1] = f[field] and 1 or 0
	end
	for _, box in ipairs( f.boxes ) do
		for a = 1, 6 do parts[#parts + 1] = string.format( "%.17g", box[a] ) end
	end
	return concat( parts, ":" )
end

local ShapeVariants = {}
local StairShapes = { "straight", "inner_left", "inner_right", "outer_left", "outer_right" }
local function shapeProfile( stateId, visual, bx, by, bz )
	local shape = { selector = 0, stair = -1, connections = 0, pane = false, variants = { {} } }
	if stateId == 0 then return shape end
	local b, id, orient = visual.block, visual.id, visual.renderOrient
	local connection = b.connection
	shape.pane = connection == "pane" or connection == "bars"
	if connection == "fence" or connection == "fence_gate" or connection == "wall" or shape.pane
		or b.solid ~= false and ( MC.BlockIsFullCube( id, orient ) or not b.shape ) then
		shape.connections = 1
	end
	if connection == "pipe6" or b.name == "chorus_flower" then shape.connections = shape.connections + 2 end
	if b.name == "end_stone" then shape.connections = shape.connections + 4 end
	if b.shape == "stairs" then shape.stair = MC.NormalizeOrient( id, orient ) end
	if visual.boxes == nil then
		if b.shape == "stairs" then shape.selector = 1
		elseif connection == "fence" or connection == "wall" or shape.pane then shape.selector = 2
		elseif connection == "pipe6" then shape.selector = 3 end
	end
	if shape.selector == 0 then
		shape.variants[1] = MC.BlockVisualBoxes( visual, bx, by, bz ) or {}
	else
		local kind = shape.pane and "pane" or connection
		local key = shape.selector == 1 and "stairs:" .. shape.stair or kind
		local variants = ShapeVariants[key]
		if not variants then
			variants = {}
			if shape.selector == 1 then
				for i, name in ipairs( StairShapes ) do variants[i] = MC.StairBoxes( id, orient, nil, nil, nil, name ) end
			else
				for mask = 0, shape.selector == 3 and 63 or 15 do
					variants[mask + 1] = MC.ConnectionBlockBoxes( kind, mask )
				end
			end
			ShapeVariants[key] = variants
		end
		shape.variants = variants
	end
	return shape
end

local function shapeProfileKey( shape )
	local parts = { shape.selector, shape.stair, shape.connections, shape.pane and 1 or 0 }
	-- Connection families share a selector but have different box dimensions.
	for _, box in ipairs( shape.variants[1] ) do
		for a = 1, 6 do parts[#parts + 1] = string.format( "%.17g", box[a] ) end
	end
	return concat( parts, ":" )
end

function T.ResolveProfile( stateId, bx, by, bz, envelope, baseOnly )
	local p = MC.StateLighting.Get( stateId, bx, by, bz )
	if not p then return nil, "missing lighting properties for state " .. stateId end
	if not baseOnly and p.collisionContext ~= "none" then
		local context = false
		if MC.ResolveVanillaLightingContext then
			context = MC.ResolveVanillaLightingContext( stateId, bx, by, bz, p.collisionContext, envelope )
		elseif envelope then return nil, "live entity has no lighting-context resolver" end
		if context == nil then return nil, "unknown lighting context" end
		p = MC.StateLighting.Resolve( stateId, context )
		if not p then return nil, "invalid lighting context" end
	end
	-- Air has pinned lighting, but no drawable block or visual descriptor.
	local visual, err
	local emission, opacity, class = 0, 0, 0
	if stateId ~= 0 then
		visual, err = MC.ResolveBlockStateVisual( stateId, bx, by, bz )
		if not visual then return nil, "state visual " .. stateId .. ": " .. tostring( err ) end
		emission = MC.BlockLightEmissionForState( stateId, bx, by, bz )
		opacity = MC.BlockLightOpacityForState( stateId, bx, by, bz )
		class, err = renderClass( stateId, visual, bx, by, bz )
		if class == nil then return nil, err end
	end
	if not integer( emission, 15 ) or not integer( opacity, 15 )
		or not integer( p.emission, 15 ) or not integer( p.dampening, 15 )
		or type( p.shade ) ~= "number" or not ( p.shade >= 0 and p.shade <= 1 ) then
		return nil, "invalid lighting scalars for state " .. stateId
	end
	local cost = math.max( 1, opacity )
	if opacity >= 15 then cost = 16
	elseif opacity > 2 and MC.Liquid then
		local kind = MC.Liquid.DecodeState( stateId )
		if kind == "water" then cost = 2 end
	end
	local word = p.emission * 256 + p.dampening * 4096
		+ ( p.emissive and 65536 or 0 ) + ( p.viewBlocking and 131072 or 0 )
		+ ( p.solidRender and 262144 or 0 ) + ( p.fullCollision and 524288 or 0 )
	return { propagationEmission = emission, propagationOpacity = opacity, skyCost = cost,
		l2Word = word, renderClass = class, shade = p.shade,
		fluid = fluidProfile( stateId, visual, bx, by, bz ),
		shape = shapeProfile( stateId, visual, bx, by, bz ) }, nil, p, visual
end

function T.BuildCatalog( revision )
	if not ( MC.StateLighting and MC.StateLighting.Prepare() and MC.ResolveBlockStateVisual
		and MC.BlockLightEmissionForState and MC.BlockLightOpacityForState ) then
		return nil, "state lighting registry is not ready"
	end
	if not ( MC.Liquid and MC.Liquid.DecodeState and MC.Liquid.StateSolid and MC.Liquid.StateBlocksMotion
		and MC.GetBlockCollisionBoxesForState and MC.BlockIsFullCubeForState ) then
		return nil, "fluid profile registry is not ready"
	end
	if not ( MC.BlockVisualBoxes and MC.BlockIsFullCube and MC.NormalizeOrient
		and MC.StairBoxes and MC.ConnectionBlockBoxes ) then
		return nil, "render shape registry is not ready"
	end
	if not integer( MC.BlockStateCount, 1048576 ) or MC.BlockStateCount == 0 then return nil, "invalid state count" end
	local profiles, mapping, contextual, cache = {}, {}, {}, {}
	local dynamicFields = { "fullCube", "hasCollision", "translucent", "lightEmission", "lightOpacity", "boxes" }
	for stateId = 0, MC.BlockStateCount - 1 do
		local row, err, p, visual = T.ResolveProfile( stateId, 0, 0, 0, nil, true )
		if not row then return nil, err end
		local dynamic = false
		if stateId ~= 0 then
			local schema = visual.schema
			local resolver = schema and MC.BlockStateVisualResolvers and MC.BlockStateVisualResolvers[schema.name]
			local collision = schema and MC.BlockStateCollisionResolvers and MC.BlockStateCollisionResolvers[schema.name]
			dynamic = visual.cacheable == false or resolver and resolver.positionDependent
				or collision and collision.positionDependent
			for i = 1, #dynamicFields do dynamic = dynamic or type( visual[dynamicFields[i]] ) == "function" end
			-- Do not resolve a packet's neighbor-dependent properties against the old world.
			if not MC.VanillaStateLighting.Contains( stateId )
				and MC.BlockCollisionDependsOnNeighbours( visual.id ) then
				return nil, "state " .. stateId .. " needs staged neighbor-dependent lighting"
			end
		end
		contextual[stateId + 1] = char( stateId ~= 0 and ( dynamic or p.collisionContext ~= "none" ) and 1 or 0 )
		local key = concat( { row.propagationEmission, row.propagationOpacity, row.skyCost,
			row.l2Word, row.renderClass, string.format( "%.17g", row.shade ), fluidProfileKey( row.fluid ),
			shapeProfileKey( row.shape ) }, ":" )
		local index = cache[key]
		if index == nil then
			index = #profiles
			profiles[index + 1], cache[key] = row, index
		end
		mapping[stateId + 1] = u32( index )
	end
	return { formatVersion = 2, revision = revision or 1, stateCount = MC.BlockStateCount,
		profiles = profiles, stateProfiles = concat( mapping ), contextual = concat( contextual ) }
end

local Session = {}
Session.__index = Session
function Session:Version()
	return self.handle:Version()
end
function Session:ApplyBatch( batch )
	local version, err = self:Version()
	if not version then return nil, err end
	return self.handle:ApplyBatch( version, batch )
end
function Session:StartBinarySection( payload, metadata )
	local version, err = self:Version()
	if not version then return nil, err end
	return self.handle:StartBinaryDecode( version, payload, metadata )
end
function Session:ContextEdits( chunk, cells, entities )
	local contexts = {}
	for i = 1, #cells, 2 do
		local li, stateId = cells[i], cells[i + 1]
		if byte( self.catalog.contextual, stateId + 1 ) == 1 then
			local lx, ly, lz = li % MC.CS, floor( li / MC.CS ) % MC.CS, floor( li / ( MC.CS * MC.CS ) )
			local value, err = T.ResolveProfile( stateId, chunk.cx * MC.CS + lx, chunk.cy * MC.CS + ly,
				chunk.cz * MC.CH + lz, entities and entities[li] )
			if not value then return nil, err end
			value.index = li
			contexts[#contexts + 1] = value
		end
	end
	return contexts
end
function Session:CommitBinarySection( id, include, ready )
	if not ready then
		local err
		ready, err = self.handle:PollBinaryDecode( id )
		if not ready then return nil, err end
	end
	if ready.status ~= "ready" then return nil, "binary decode is not ready" end
	local contexts = {}
	for _, index in ipairs( include ) do
		local chunk = ready.chunks[index]
		if not chunk then return nil, "invalid binary chunk selection" end
		if #chunk.contextCells > 0 then
			local entities = {}
			if chunk.blockEntitiesJSON ~= "" then
				local decoded = util.JSONToTable( chunk.blockEntitiesJSON )
				if not decoded then return nil, "invalid block entity JSON" end
				for _, entity in ipairs( decoded ) do
					local li = entity.localIndex
					if not integer( li, MC.CS * MC.CS * MC.CH - 1 ) or entities[li] then
						return nil, "invalid block entity localIndex"
					end
					entities[li] = entity
				end
			end
			local edits, err = self:ContextEdits( chunk, chunk.contextCells, entities )
			if not edits then return nil, err end
			contexts[#contexts + 1] = { op = "patch", cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, contexts = edits }
		end
	end
	local version, err = self:Version()
	if not version then return nil, err end
	return self.handle:CommitBinaryDecode( version, id, include, contexts )
end
function Session:Close()
	local ok, err = self.handle:Close()
	if ok and T.development == self then T.development = nil end
	return ok, err
end

-- One import at ownership transfer, not on every terrain build.
function Session:ImportWorld()
	local batch, seen, imported = {}, {}, 0
	local function flush()
		if #batch == 0 then return true end
		local result, err = self:ApplyBatch( batch )
		if not result then return nil, err end
		imported, batch = imported + #batch, {}
		return true
	end
	for key, chunk in pairs( MC.World ) do
		local row = { op = "replace", cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, cells = {},
			terrainPresent = chunk.count > 0 }
		MC.ForEachBlockState( chunk, function( bx, by, bz, lx, ly, lz, stateId )
			local li = lx + MC.CS * ( ly + MC.CS * lz )
			row.cells[#row.cells + 1], row.cells[#row.cells + 2] = li, stateId
		end )
		if #row.cells / 2 ~= chunk.count then return nil, "world iterator did not return the declared chunk contents" end
		local err
		row.contexts, err = self:ContextEdits( chunk, row.cells, chunk.blockEntities )
		if not row.contexts then return nil, err end
		batch[#batch + 1], seen[key] = row, true
		if #batch == 64 then local ok, problem = flush() if not ok then return nil, problem end end
	end
	for key, loaded in pairs( MC.LoadedChunkKeys or {} ) do
		if loaded and not seen[key] then
			local cx, cy, cz = MC.ChunkKeyToCoords( key )
			if cx == nil then return nil, "invalid loaded chunk key" end
			batch[#batch + 1] = { op = "replace", cx = cx, cy = cy, cz = cz, terrainPresent = false }
			if #batch == 64 then local ok, err = flush() if not ok then return nil, err end end
		end
	end
	local ok, err = flush()
	if not ok then return nil, err end
	return imported
end

function T.WorldConfig( options )
	options = options or {}
	local transport = MC.StateNetworkTransport
	local config = { protocol = 2, chunkSize = MC.CS, chunkHeight = MC.CH, sectionSize = MC.RENDER_SECTION_SIZE,
		coordinateSpace = "mc:block", blockSize = MC.API.Coords.BlockSize(),
		streaming = MC.HttpChunkSync ~= nil or ( transport ~= nil and transport.streaming == true ),
		skyEnabled = not MC.SkyFloodEnabled or MC.SkyFloodEnabled(),
		maxChunks = options.maxChunks, maxLightChunks = options.maxLightChunks, maxLightBytes = options.maxLightBytes }
	if transport and transport.streaming and not MC.HttpChunkSync then
		config.minChunkZ, config.maxChunkZ = transport.streamMinCZ, transport.streamMaxCZ
	end
	for _, key in ipairs( { "streaming", "minChunkZ", "maxChunkZ", "skyEnabled" } ) do
		if options[key] ~= nil then config[key] = options[key] end
	end
	return config
end
function T.CreateSession( options, catalog )
	local caps, reason = T.Probe()
	if not caps then return nil, reason end
	for _, key in ipairs( { "worldSession", "stateCatalog", "binarySection", "worldLighting", "l2Snapshot" } ) do
		if caps[key] ~= 1 then return nil, "missing world capability: " .. key end
	end
	if not catalog then
		catalog, reason = T.BuildCatalog()
		if not catalog then return nil, reason end
	end
	local config = T.WorldConfig( options )
	local handle, err = mcmesh.CreateWorldSession( config, catalog )
	if not handle then return nil, err end
	return setmetatable( { handle = handle, catalog = catalog, config = config }, Session )
end
T.CreateDevelopmentSession = T.CreateSession
-- Existing userdata stays owned across Lua auto-refresh; replace only its methods.
if T.development then setmetatable( T.development, Session ) end
if T.active then setmetatable( T.active, Session ) end

if hook then
hook.Add( "Think", "mc_native_development_light", function()
	local session = T.development
	if not session or not session.lightPending then return end
	local result, err = session.handle:Pump()
	if not result then
		session.lightPending = nil
		MC.Fault( "native_session_light", "%s", tostring( err ) )
		return
	end
	session.lightPending = result.pending
	session.lightResult = result
end )
hook.Add( "ShutDown", "mc_native_world_sessions", function()
	if T.development then T.development:Close() end
	if T.active then T.active:Close() T.active = nil end
end )
end

if concommand then
	concommand.Add( "mc_native_session_begin", function()
		if T.development then T.development:Close() end
		local session, err = T.CreateSession()
		if not session then MC.Fault( "native_session_init", "%s", tostring( err ) ) return end
		local imported
		imported, err = session:ImportWorld()
		if not imported then session:Close() MC.Fault( "native_session_import", "%s", tostring( err ) ) return end
		T.development = session
		print( "[MC Native] imported " .. imported .. " chunks into an independent development session; active ownership is unchanged" )
	end )
	concommand.Add( "mc_native_session_light", function()
		if not T.development then print( "[MC Native] run mc_native_session_begin first" ) return end
		local result, err = T.development.handle:RequestLighting()
		if not result then MC.Fault( "native_session_light", "%s", tostring( err ) ) return end
		T.development.lightPending = true
	end )
	concommand.Add( "mc_native_session_close", function() if T.development then T.development:Close() end end )
end
