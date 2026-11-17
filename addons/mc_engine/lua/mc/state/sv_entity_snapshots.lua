-- Optional, provider-owned living-entity data carried by the world payload.
-- The engine owns slots/transactions; providers own their entity schemas.
MC = MC or {}
MC.SV = MC.SV or {}
local SV = MC.SV
SV.EntitySnapshotProviders = SV.EntitySnapshotProviders or {}
local providers = SV.EntitySnapshotProviders
local snapshotSerial = 0

local function plainData( value, depth, budget )
	budget.n = budget.n + 1
	if depth > 32 or budget.n > 200000 then return false end
	local kind = type( value )
	if kind == "number" then return value == value and value ~= math.huge and value ~= -math.huge end
	if kind == "string" then return #value <= 1048576 end
	if kind == "boolean" or kind == "nil" then return true end
	if kind ~= "table" or getmetatable( value ) ~= nil then return false end
	for key, child in pairs( value ) do
		if type( key ) ~= "string" and type( key ) ~= "number" then return false end
		if not plainData( key, depth + 1, budget ) then return false end
		if not plainData( child, depth + 1, budget ) then return false end
	end
	return true
end

function SV.RegisterEntitySnapshotProvider( id, provider )
	if not isstring( id ) or not string.match( id, "^[%w_%-%.]+$" ) or #id > 96 then return false, "invalid_entity_provider_id" end
	if not istable( provider ) or not isnumber( provider.version ) or provider.version < 1
		or provider.version ~= math.floor( provider.version ) or provider.version == math.huge
		or not isfunction( provider.capture ) or not isfunction( provider.validate )
		or not isfunction( provider.stage ) then return false, "invalid_entity_provider" end
	providers[id] = provider
	return true
end

function SV.CaptureEntitySnapshots( options )
	if options ~= nil and not istable( options ) then return nil, "invalid_save_options" end
	if options and options.saveEntities ~= nil and not isbool( options.saveEntities ) then return nil, "invalid_save_entities_option" end
	local enabled = not options or options.saveEntities ~= false
	snapshotSerial = snapshotSerial + 1
	local result = { version = 1, enabled = enabled, providers = {},
		id = tostring( os.time() ) .. ":" .. tostring( SysTime() ) .. ":" .. snapshotSerial }
	if not enabled then return result end
	for id, provider in pairs( providers ) do
		local called, data, err = pcall( provider.capture )
		if not called then return nil, "entity_capture_exception:" .. id .. ":" .. tostring( data ) end
		if data == nil then return nil, "entity_capture_failed:" .. id .. ":" .. tostring( err ) end
		if not plainData( data, 0, { n = 0 } ) then return nil, "invalid_entity_data:" .. id end
		local checked, valid, reason = pcall( provider.validate, data )
		if not checked or valid ~= true then return nil, "entity_validation_failed:" .. id .. ":" .. tostring( reason or valid ) end
		result.providers[id] = { version = provider.version, data = data }
	end
	return result
end

function SV.PrepareEntitySnapshots( snapshot )
	if snapshot == nil then return {} end -- Existing block-only saves.
	if not istable( snapshot ) or snapshot.version ~= 1 or not isbool( snapshot.enabled )
		or not isstring( snapshot.id ) or snapshot.id == "" or #snapshot.id > 128
		or not istable( snapshot.providers ) or not plainData( snapshot, 0, { n = 0 } ) then
		return nil, "invalid_entity_snapshot"
	end
	local prepared = {}
	if not snapshot.enabled then return prepared end
	for id, entry in pairs( snapshot.providers ) do
		local provider = providers[id]
		if provider then
			if not istable( entry ) or entry.version ~= provider.version then return nil, "entity_schema_mismatch:" .. id end
			local called, valid, err = pcall( provider.validate, entry.data )
			if not called or valid ~= true then return nil, "invalid_saved_entities:" .. id .. ":" .. tostring( err or valid ) end
			prepared[#prepared + 1] = { id = id, provider = provider, data = entry.data }
		else
			MsgN( "[MC] entity provider unavailable; retained save data: " .. tostring( id ) )
		end
	end
	return prepared
end

function SV.RollbackEntitySnapshots( staged )
	local failures = {}
	for index = #staged, 1, -1 do
		local called, err = pcall( staged[index].rollback )
		if not called then failures[#failures + 1] = tostring( err ) end
	end
	return #failures == 0, table.concat( failures, "; " )
end

function SV.StageEntitySnapshots( prepared )
	local staged = {}
	for _, entry in ipairs( prepared ) do
		local called, transaction, err = pcall( entry.provider.stage, entry.data )
		if not called or not istable( transaction ) or not isfunction( transaction.commit )
			or not isfunction( transaction.rollback ) then
			if istable( transaction ) and isfunction( transaction.rollback ) then staged[#staged + 1] = transaction end
			local rolledBack, rollbackError = SV.RollbackEntitySnapshots( staged )
			local failure = "entity_restore_failed:" .. entry.id .. ":" .. tostring( err or transaction )
			if not rolledBack then failure = failure .. ":rollback_failed:" .. rollbackError end
			return nil, failure
		end
		staged[#staged + 1] = transaction
	end
	return staged
end

function SV.CommitEntitySnapshots( staged )
	for _, transaction in ipairs( staged ) do transaction.commit() end
end

function SV.AttachEntitySnapshotsToOverlay( overlay, snapshot )
	overlay.entitySnapshots = snapshot
	local store = SV.ChunkStore
	overlay.entitySnapshotsBase = store and store.EntitySnapshotBase or false
end

function SV.EntitySnapshotFromOverlay( snapshot, overlay )
	if overlay.entitySnapshots ~= nil and overlay.entitySnapshotsBase == ( snapshot and snapshot.id or false ) then
		return overlay.entitySnapshots
	end
	return snapshot
end

-- Resolve the same edit overlay selected by the staged lazy world. Embedded
-- snapshots also work in legacy saves and Workshop bundles without sidecars.
function SV.ResolveEntitySnapshots( data, path, realm )
	local snapshot = data.entitySnapshots
	local store = SV.ChunkStore
	local overlayPath
	if store and store.IsLazyWorld and store.IsLazyWorld() then
		-- ChunkStore already selected and decoded the block overlay, including
		-- legacy spelling and mounted GAME fallback. Consume that exact payload.
		return SV.PrepareEntitySnapshots( store.LoadedEntitySnapshots )
	end
	if not overlayPath and data.editOverlay then
		overlayPath = string.GetPathFromFilename( path ) .. data.editOverlay
	elseif not overlayPath and string.EndsWith( path, ".dat" ) then
		overlayPath = string.gsub( path, "%.dat$", "_edits.dat" )
	end
	local overlayRealms = realm == "GAME" and { "DATA", "GAME" } or { "DATA" }
	for _, overlayRealm in ipairs( overlayRealms ) do
		if overlayPath and file.Exists( overlayPath, overlayRealm ) then
			local raw = file.Read( overlayPath, overlayRealm )
			local overlay = raw and util.JSONToTable( raw )
			if not overlay and raw then
				local decoded = util.Decompress( raw )
				if decoded then overlay = util.JSONToTable( decoded ) end
			end
			if not istable( overlay ) then return nil, "invalid_entity_edit_overlay" end
			snapshot = SV.EntitySnapshotFromOverlay( snapshot, overlay )
			break
		end
	end
	return SV.PrepareEntitySnapshots( snapshot )
end
