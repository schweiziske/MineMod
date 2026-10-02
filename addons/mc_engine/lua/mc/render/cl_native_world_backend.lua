-- Persistent state/light ownership only. No materials, draw hooks or L1 meshes.
MC = MC or {}
local T = MC.NativeTakeover
local B = MC.NativeChunkBackend or {}
MC.NativeChunkBackend = B
B.native, B.name = true, "native"
local floor = math.floor

local function requireResult( value, err )
	if value == nil or value == false then error( "Native world: " .. tostring( err ), 0 ) end
	return value
end
local function active()
	return assert( T.active, "Native world is not active" )
end
local function attach( chunk, session )
	MC.InvalidateChunkStateStorage( chunk )
	chunk.nativeStateStorage, chunk.stateStorageMigrated = true, true
	chunk.nativeMeshEpoch, chunk.chunkBackend = session.backendEpoch, "native"
	MC.AttachNativeChunkCompatibilityProxy( chunk )
end
local function stamp( session )
	T.serial = ( T.serial or 0 ) + 1
	local version = requireResult( session:Version() )
	session.backendEpoch = tostring( T.serial ) .. ":" .. version.epoch
	session.lightPending = true
end
local function apply( rows )
	local session = active()
	local result, err = session:ApplyBatch( rows )
	if not result then return nil, err end
	session.lightPending = true
	return true
end

function B.IsActive() return T.active ~= nil end
function B.Epoch() return T.active and T.active.backendEpoch end
function B.GetHandle() return T.active and T.active.handle end
function B.GetSectionInfo( chunk, index )
	return active().handle:GetSectionInfo( chunk.cx, chunk.cy, chunk.cz, index )
end
function B.GetCell( chunk, li )
	local lx, ly, lz = MC.DecodeLocal( li )
	local result, err = active().handle:GetCell( chunk.cx * MC.CS + lx, chunk.cy * MC.CS + ly, chunk.cz * MC.CH + lz )
	return requireResult( result, err )
end
function B.GetChunkCells( chunk )
	local result, err = active().handle:GetChunkCells( chunk.cx, chunk.cy, chunk.cz )
	return requireResult( result, err )
end
function B.GetSectionCells( chunk, index )
	return active().handle:GetSectionCells( chunk.cx, chunk.cy, chunk.cz, index )
end
function B.MarkLoaded( key )
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	local info = requireResult( active().handle:GetChunkInfo( cx, cy, cz ) )
	if info.present then return end
	requireResult( apply( { { op = "replace", cx = cx, cy = cy, cz = cz, terrainPresent = false } } ) )
end
function B.MarkUnloaded( key )
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	requireResult( apply( { { op = "unload", cx = cx, cy = cy, cz = cz } } ) )
end
function B.CreateChunk( chunk )
	B.MarkLoaded( chunk.key )
	local info = requireResult( active().handle:GetChunkInfo( chunk.cx, chunk.cy, chunk.cz ) )
	chunk.count = info.count
	attach( chunk, active() )
	return true
end
function B.SetCell( chunk, li, stateId, finalCount )
	local row = { op = "patch", cx = chunk.cx, cy = chunk.cy, cz = chunk.cz,
		cells = { li, stateId }, terrainPresent = finalCount > 0 }
	local err
	-- A state replacement must not inherit the old Block Entity's context.
	row.contexts, err = active():ContextEdits( chunk, row.cells )
	if not row.contexts then return nil, err end
	return apply( { row } )
end
function B.ApplyChunkCells( chunk, cells, replace )
	local row = { op = replace and "replace" or "patch", cx = chunk.cx, cy = chunk.cy, cz = chunk.cz,
		cells = cells, terrainPresent = chunk.count > 0 }
	local err
	row.contexts, err = active():ContextEdits( chunk, cells, chunk.blockEntities )
	if not row.contexts then return nil, err end
	local result
	result, err = apply( { row } )
	if not result then return nil, err end
	attach( chunk, active() )
	return true
end

local function stageLuaChunk( chunk, session )
	local cells, err = session.handle:GetChunkCells( chunk.cx, chunk.cy, chunk.cz )
	if not cells then return nil, err end
	if #cells ~= chunk.count * 2 then return nil, "native/Lua chunk count mismatch" end
	local staged = { sections = {}, blocks = {}, orients = {} }
	local sectionCells = MC.CS * MC.CS * 16
	for i = 1, #cells, 2 do
		local li, stateId = cells[i], cells[i + 1]
		local index = floor( li / sectionCells ) + 1
		local section = staged.sections[index]
		if not section then section = MC.StateSection.New() staged.sections[index] = section end
		local changed, problem = MC.StateSection.Set( section, li % sectionCells, stateId )
		if changed == nil then return nil, problem end
		local id, orient = MC.LegacyFromState( stateId )
		if id == nil then return nil, "state has no compatibility projection" end
		staged.blocks[li], staged.orients[li] = id, orient or 0
	end
	return staged
end
function B.MaterializeLuaStorage()
	-- Individual migration would create two writable authorities in one world.
	return nil, "native world owns state; disable Native to materialize Lua storage"
end

function B.SupportsBinarySectionPatches() return B.IsActive() end
function B.StartBinarySectionPatchDecode( payload, compression, rawBytes, generation, revision, chunks, cells )
	local session = active()
	local id, err = session:StartBinarySection( payload, { compression = compression, rawBytes = rawBytes,
		generation = generation, revision = revision, chunks = chunks, cells = cells } )
	if not id then return nil, err end
	session.decodeJobs = session.decodeJobs or {}
	session.decodeJobs[id] = true
	return id, session.backendEpoch
end
function B.PollBinarySectionPatchDecode( id )
	local session = active()
	if not session.decodeJobs or not session.decodeJobs[id] then return nil, "unknown native decode job" end
	local result, err = session.handle:PollBinaryDecode( id )
	if not result then return nil, err end
	if result.status == "ready" then
		result.backendEpoch = session.backendEpoch
		session.decodeJobs[id] = result
	end
	return result
end
function B.CommitBinarySectionPatch( id, include )
	local session = active()
	local ready = session.decodeJobs and session.decodeJobs[id]
	if type( ready ) ~= "table" then return nil, "native decode was not polled ready" end
	local result, err = session:CommitBinarySection( id, include, ready )
	if not result then return nil, err end
	session.decodeJobs[id], session.lightPending = nil, true
	return result
end
function B.CancelCompressedPatchDecode( id )
	local session = T.active
	if not session or not session.decodeJobs or not session.decodeJobs[id] then return false end
	session.decodeJobs[id] = nil
	return session.handle:CancelBinaryDecode( id )
end
function B.CancelAllCompressedPatchDecodes()
	if not T.active then return true end
	T.active.decodeJobs = {}
	return T.active.handle:CancelAllBinaryDecodes()
end
function B.ClearWorld()
	local session = active()
	requireResult( session.handle:Reset( session.config, session.catalog ) )
	session.decodeJobs, session.fault = {}, nil
	stamp( session )
end
function B.ScheduleBlockLightRebuild()
	local session = active()
	requireResult( B.SyncConfig() )
	requireResult( session.handle:RequestLighting() )
	session.lightPending, session.fault = true, nil
	return true
end
function B.GetLightingAt( bx, by, bz )
	local block, sky = active().handle:GetLight( bx, by, bz )
	if block == nil then error( "Native light read: " .. tostring( sky ), 0 ) end
	return block, sky
end
function B.GetBlockLightAt( bx, by, bz )
	local block = B.GetLightingAt( bx, by, bz )
	return block
end
function B.GetSkyLightAt( bx, by, bz )
	local _, sky = B.GetLightingAt( bx, by, bz )
	return sky
end
function B.IsLightReady( key, sectionIndex )
	local session = T.active
	if not session or session.fault then return false end
	if not key or not session.handle.IsMeshReady then return not session.lightPending end
	local chunk = MC.World[key]
	if not chunk or chunk.count == 0 then return true end
	local size = MC.RENDER_SECTION_SIZE or 8
	for index = sectionIndex or 1, sectionIndex or ( MC.CS / size ) ^ 2 * ( MC.CH / size ) do
		local ready, err = session.handle:IsMeshReady( chunk.cx, chunk.cy, chunk.cz, index )
		if ready == nil then error( "Native mesh readiness: " .. tostring( err ), 0 ) end
		if not ready then return false end
	end
	return true
end
function B.Pump()
	local session = T.active
	if not session or session.fault or not session.lightPending then return end
	local result, err = session.handle:Pump()
	if not result then
		session.fault = tostring( err )
		MC.Fault( "native_world_light", "%s; Native world retained", session.fault )
		return
	end
	session.lightPending = result.pending
	for _, row in ipairs( result.dirtySections ) do
		local key = MC.ChunkKey( row.cx, row.cy, row.cz )
		if MC.World[key] then
			for _, index in ipairs( row.sections ) do MC.InvalidateNativeLightSection( key, index ) end
		end
		if MC.ClearGpuChunkLightTexture then MC.ClearGpuChunkLightTexture( key ) end
	end
	MC.LightCellsReady = not result.pending
end

local function changedOwnership()
	if MC.NativeL2 then MC.NativeL2.CancelAll() end
	if MC.ClearLightingCache then MC.ClearLightingCache() end
end
local function beforeOwnershipChange()
	local transport = MC.StateNetworkTransport
	if transport and transport.NativeOwnershipChanged then transport.NativeOwnershipChanged() end
end
function B.SyncConfig( overrides )
	local session = T.active
	if not session then return true end
	local options = { maxChunks = session.config.maxChunks, maxLightChunks = session.config.maxLightChunks,
		maxLightBytes = session.config.maxLightBytes }
	for key, value in pairs( overrides or {} ) do options[key] = value end
	local config = T.WorldConfig( options )
	if not config.streaming then config.minChunkZ, config.maxChunkZ = nil, nil end
	local changed = false
	for _, key in ipairs( { "streaming", "minChunkZ", "maxChunkZ", "skyEnabled" } ) do
		if config[key] ~= session.config[key] then changed = true break end
	end
	if not changed then return true end
	local result, err = session.handle:Reconfigure( config )
	if not result then return nil, err end
	-- Native has invalidated the old epoch; transport must not skip its revisions.
	beforeOwnershipChange()
	session.config, session.decodeJobs, session.fault = config, {}, nil
	stamp( session )
	for _, chunk in pairs( MC.World ) do chunk.nativeMeshEpoch = session.backendEpoch end
	changedOwnership()
	for key in pairs( MC.World ) do MC.MarkChunkDirty( key, true ) end
	return true
end
function T.SetWorldEnabled( enabled, options, catalog )
	if enabled == B.IsActive() then return true end
	if enabled then
		local caps, reason = T.Probe()
		if not caps or caps.worldAdapter ~= 1 then return nil, reason or "DLL lacks the persistent-world adapter" end
		local session, err = T.CreateSession( options, catalog )
		if not session then return nil, err end
		local ok, imported, problem = pcall( session.ImportWorld, session )
		if not ok or not imported then session:Close() return nil, ok and problem or imported end
		stamp( session )
		beforeOwnershipChange()
		T.active = session
		for _, chunk in pairs( MC.World ) do attach( chunk, session ) end
		changedOwnership()
		return true
	end
	local session, staged = active(), {}
	for key, chunk in pairs( MC.World ) do
		local row, err = stageLuaChunk( chunk, session )
		if not row then return nil, err end
		staged[key] = row
	end
	-- No fallible conversion remains after crossing this ownership boundary.
	beforeOwnershipChange()
	B.CancelAllCompressedPatchDecodes()
	for key, row in pairs( staged ) do
		local chunk = MC.World[key]
		MC.InvalidateChunkStateStorage( chunk )
		chunk.stateSections, chunk.blocks, chunk.orients = row.sections, row.blocks, row.orients
		chunk.stateStorageMigrated, chunk.nativeStateStorage = true, false
		chunk.chunkBackend, chunk.nativeMeshEpoch = "lua", nil
	end
	T.active = nil
	session:Close()
	changedOwnership()
	if MC.RebuildLightingCells then MC.RebuildLightingCells() end
	return true
end

MC.RegisterChunkBackend( "native", B )
if hook then hook.Add( "Think", "mc_native_world_backend", B.Pump ) end
