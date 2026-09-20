-- Takeover protocol 1. P0/P1 sessions are explicit development copies; they
-- never register an active chunk/terrain backend or disable Lua lighting.
MC = MC or {}
local T = { PROTOCOL = 1 }
MC.NativeTakeover = T
local floor, char, concat = math.floor, string.char, table.concat
local FIELDS = { "emission", "dampening", "emissive", "shade", "viewBlocking", "solidRender", "fullCollision",
	"skyPass", "shapeOcclusion", "dynamicShape", "viewContext", "collisionContext" }

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
	local sync = MC.NativeL2 and MC.NativeL2.IsActive() == true
	local status = {
		mode = sync and "native_l2_sync" or "lua_l2", fullTakeover = false,
		worldBackend = "lua", worldLightBackend = "lua", meshExecution = sync and "native_sync_lua_scheduler" or "lua_sync",
		atlasUploader = "lua", capabilities = caps, reason = reason,
	}
	if caps then status.reason = "P0/P1 development sessions; async terrain, native atlas, relight and multiview are pending" end
	if T.development then status.development = T.development.handle:GetStats() end
	return status
end

local function u32( value )
	return char( value % 256, floor( value / 256 ) % 256, floor( value / 65536 ) % 256, floor( value / 16777216 ) % 256 )
end

function T.BuildCatalog( revision )
	local lighting = MC.VanillaStateLighting
	if not ( lighting and lighting.ready and MC.BlockLightEmissionForState and MC.BlockLightOpacityForState
		and MC.ResolveBlockStateVisual ) then return nil, "state lighting registry is not ready" end
	if MC.BlockStateCount ~= lighting.stateCount then return nil, "custom states need a typed lighting catalog" end
	local profiles, mapping, cache = {}, {}, {}
	for stateId = 0, lighting.stateCount - 1 do
		local profile = lighting.Get( stateId )
		local visual, err = MC.ResolveBlockStateVisual( stateId, 0, 0, 0 )
		if not visual then return nil, "state visual " .. stateId .. ": " .. tostring( err ) end
		local resolver = visual.schema and MC.BlockStateVisualResolvers[visual.schema.name]
		if ( resolver and resolver.positionDependent ) or visual.cacheable == false
			or type( visual.lightEmission ) == "function" or type( visual.lightOpacity ) == "function" then
			return nil, "state " .. stateId .. " requires typed position-dependent propagation inputs"
		end
		local emission = MC.BlockLightEmissionForState( stateId, 0, 0, 0 )
		local opacity = MC.BlockLightOpacityForState( stateId, 0, 0, 0 )
		if type( emission ) ~= "number" or emission < 0 or emission > 15 or emission ~= floor( emission )
			or type( opacity ) ~= "number" or opacity < 0 or opacity > 15 or opacity ~= floor( opacity ) then
			return nil, "invalid propagation scalars for state " .. stateId
		end
		local variants = cache[profile]
		if not variants then variants = {} cache[profile] = variants end
		local key = emission * 16 + opacity
		local index = variants[key]
		if index == nil then
			local row = { propagationEmission = emission, propagationOpacity = opacity }
			for i = 1, #FIELDS do local field = FIELDS[i] row[field] = profile[field] end
			index = #profiles
			profiles[index + 1], variants[key] = row, index
		end
		mapping[stateId + 1] = u32( index )
	end
	return { formatVersion = 1, revision = revision or 1, schemaHash = lighting.schemaHash,
		stateCount = lighting.stateCount, profiles = profiles, stateProfiles = concat( mapping ) }
end

local Session = {}
Session.__index = Session
function Session:Version( revision )
	local version, err = self.handle:Version()
	if not version then return nil, err end
	if revision ~= nil then version.revision = revision end
	return version
end
function Session:ApplyBatch( batch, revision )
	local version, err = self:Version( revision )
	if not version then return nil, err end
	return self.handle:ApplyBatch( version, batch )
end
function Session:StartBinarySection( payload, metadata, revision )
	local version, err = self:Version( revision )
	if not version then return nil, err end
	return self.handle:StartBinaryDecode( version, payload, metadata )
end
function Session:Close()
	local ok, err = self.handle:Close()
	if ok and T.development == self then T.development = nil end
	return ok, err
end

-- One explicit import, through the public iterator. This is never called on
-- each terrain build, and never substitutes __index-only blocks/orients proxies.
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
		local row = { op = "replace", cx = chunk.cx, cy = chunk.cy, cz = chunk.cz, cells = {}, contexts = {}, blockEntityCells = {} }
		row.terrainPresent = chunk.count == 0
		local invalid
		MC.ForEachBlockState( chunk, function( bx, by, bz, lx, ly, lz, stateId )
			local li = lx + MC.CS * ( ly + MC.CS * lz )
			row.cells[#row.cells + 1], row.cells[#row.cells + 2] = li, stateId
			local profile = MC.VanillaStateLighting.Get( stateId )
			if profile.collisionContext ~= "none" then
				local context = false
				if MC.ResolveVanillaLightingContext then
					context = MC.ResolveVanillaLightingContext( stateId, bx, by, bz, profile.collisionContext )
				elseif chunk.blockEntities and chunk.blockEntities[li] then invalid = "live entity has no lighting-context resolver" end
				if context == nil then invalid = "unknown lighting context at " .. bx .. "," .. by .. "," .. bz
				elseif context ~= false then
					row.contexts[#row.contexts + 1] = { index = li, kind = profile.collisionContext,
						closed = context.closed, progress = context.progress, fullCollision = context.fullCollision }
				end
			end
		end )
		if invalid then return nil, invalid end
		if #row.cells / 2 ~= chunk.count then return nil, "world iterator did not return the declared chunk contents" end
		local entities = {}
		for li, envelope in pairs( chunk.blockEntities or {} ) do
			row.blockEntityCells[#row.blockEntityCells + 1] = li
			entities[#entities + 1] = envelope
		end
		if #entities > 0 then row.blockEntitiesJSON = util.TableToJSON( entities ) end
		batch[#batch + 1], seen[key] = row, true
		if #batch == 64 then local ok, err = flush() if not ok then return nil, err end end
	end
	for key, loaded in pairs( MC.LoadedChunkKeys or {} ) do
		if loaded and not seen[key] then
			local cx, cy, cz = MC.ChunkKeyToCoords( key )
			if cx == nil then return nil, "invalid loaded chunk key" end
			batch[#batch + 1] = { op = "replace", cx = cx, cy = cy, cz = cz }
			if #batch == 64 then local ok, err = flush() if not ok then return nil, err end end
		end
	end
	local ok, err = flush()
	if not ok then return nil, err end
	return imported
end

function T.CreateDevelopmentSession( options, catalog )
	local caps, reason = T.Probe()
	if not caps then return nil, reason end
	for _, key in ipairs( { "worldSession", "stateCatalog", "binarySection", "worldLighting", "l2Snapshot" } ) do
		if caps[key] ~= 1 then return nil, "missing development capability: " .. key end
	end
	if not catalog then
		catalog, reason = T.BuildCatalog( 1 )
		if not catalog then return nil, reason end
	end
	options = options or {}
	local transport = MC.StateNetworkTransport
	local config = { protocol = 1, chunkSize = MC.CS, chunkHeight = MC.CH, sectionSize = MC.RENDER_SECTION_SIZE,
		coordinateSpace = "mc:block", blockSize = MC.API.Coords.BlockSize(), worldGeneration = options.worldGeneration or 0,
		streaming = MC.HttpChunkSync ~= nil or ( transport ~= nil and transport.streaming == true ),
		maxChunks = options.maxChunks, maxLightChunks = options.maxLightChunks }
	if transport and transport.streaming and not MC.HttpChunkSync then
		config.minChunkZ, config.maxChunkZ = transport.streamMinCZ, transport.streamMaxCZ
	end
	if options.streaming ~= nil then config.streaming = options.streaming end
	if options.minChunkZ ~= nil then config.minChunkZ = options.minChunkZ end
	if options.maxChunkZ ~= nil then config.maxChunkZ = options.maxChunkZ end
	local handle, err = mcmesh.CreateWorldSession( config, catalog )
	if not handle then return nil, err end
	return setmetatable( { handle = handle }, Session )
end

if hook then hook.Add( "ShutDown", "mc_native_world_sessions", function()
	if T.development then T.development:Close() end
end ) end

if concommand then
	concommand.Add( "mc_native_session_begin", function()
		if T.development then T.development:Close() end
		local session, err = T.CreateDevelopmentSession()
		if not session then MC.Fault( "native_session_init", "%s", tostring( err ) ) return end
		local imported
		imported, err = session:ImportWorld()
		if not imported then session:Close() MC.Fault( "native_session_import", "%s", tostring( err ) ) return end
		T.development = session
		print( "[MC Native] imported " .. imported .. " chunks into an independent development session; active world/lighting/terrain ownership is unchanged" )
	end )
	concommand.Add( "mc_native_session_light", function()
		if not T.development then print( "[MC Native] run mc_native_session_begin first" ) return end
		local result, err = T.development.handle:RebuildLighting()
		if not result then MC.Fault( "native_session_light", "%s", tostring( err ) ) return end
		PrintTable( result )
	end )
	concommand.Add( "mc_native_session_close", function() if T.development then T.development:Close() end end )
end
