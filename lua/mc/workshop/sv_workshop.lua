--[[----------------------------------------------------------------------------
	MC Workshop server bridge.

	The server never talks to Steam and never publishes anything. It only exports
	an approved save to the requesting player, approves a downloaded Workshop
	bundle before accepting its large upload, validates it again, imports it into
	a new named save slot, and then uses the normal authoritative load path.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}
MC.Workshop = MC.Workshop or {}

local SV = MC.SV
local W = MC.Workshop
local C = MC.Config

local SAVE_SLOT_DIR = "mc/saves"
local WORKSHOP_SAVE_SLOT_DIR = "mc/workshop_saves"
local SAVE_COVER_DIR = "mc/save_covers"
local REQUEST_COOLDOWN = 2
local APPROVAL_TIMEOUT = 20

local UploadSessions = {}
local ExportSessions = {}
local RequestTimes = {}
W.ServerBaseGeneration = math.floor( tonumber( W.ServerBaseGeneration ) or 0 ) % 4294967296

local function L( ply, key, fallback, vars )
	return MC.TFor and MC.TFor( ply, key, fallback, vars ) or fallback
end

local function workshopManageConVar()
	if not C.WorkshopManage then
		local flags = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
		C.WorkshopManage = GetConVar( "mc_workshop_manage" ) or CreateConVar(
			"mc_workshop_manage", "0", flags,
			"Who may publish/import MC Workshop worlds: 0 superadmins, 1 admins, 2 everyone", 0, 2
		)
	end
	return C.WorkshopManage
end

function W.CanManage( ply )
	if not IsValid( ply ) then return true end
	local mode = math.Clamp( workshopManageConVar():GetInt(), 0, 2 )
	if mode <= 0 then return ply:IsSuperAdmin() end
	if mode == 1 then return ply:IsAdmin() end
	return true
end

local function rateAllowed( ply, operation )
	local now = CurTime()
	local state = RequestTimes[ply]
	if not state then state = {}; RequestTimes[ply] = state end
	if ( state[operation] or 0 ) > now then return false end
	state[operation] = now + REQUEST_COOLDOWN
	return true
end

local function readBoundedFile( path, maxBytes )
	local size = file.Size( path, "DATA" )
	if size == nil or size < 0 then return nil, "file_missing:" .. path end
	if size > maxBytes then return nil, "file_too_large:" .. path end
	local data = file.Read( path, "DATA" )
	if not isstring( data ) or #data ~= size then return nil, "file_read_failed:" .. path end
	return data
end

local function buildSaveBundle( ply, slotName )
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return nil, "invalid_slot" end
	local resolved = SV.ResolveSaveSlot and SV.ResolveSaveSlot( slotName ) or nil
	local manifestPath = resolved and resolved.path or nil
	if not manifestPath or string.EndsWith( manifestPath, ".dat" ) then return nil, "workshop_requires_region_save" end

	local root = string.gsub( string.GetPathFromFilename( manifestPath ), "/+$", "" )
	local files = {}
	local manifest, manifestError = readBoundedFile( manifestPath, W.MAX_MANIFEST_BYTES )
	if not manifest then return nil, manifestError end
	files["manifest.json"] = manifest
	local manifestTable = util.JSONToTable( manifest )
	if not istable( manifestTable ) or not istable( manifestTable.parts ) then return nil, "invalid_bundle_manifest_json" end

	local editsPath = root .. "/edits.json"
	if file.Exists( editsPath, "DATA" ) then
		local edits, editsError = readBoundedFile( editsPath, W.MAX_FILE_BYTES )
		if not edits then return nil, editsError end
		files["edits.json"] = edits
	end

	for _, part in ipairs( manifestTable.parts ) do
		if not istable( part ) then return nil, "invalid_bundle_part" end
		for _, field in ipairs( { "path", "fastPath" } ) do
			local bundlePath = part[field]
			if bundlePath ~= nil and files[bundlePath] == nil then
				if W.NormalizeBundlePath( bundlePath ) ~= bundlePath or not string.StartWith( bundlePath, "regions/" ) then
					return nil, "invalid_region_name"
				end
				local data, regionError = readBoundedFile( root .. "/" .. bundlePath, W.MAX_FILE_BYTES )
				if not data then return nil, regionError end
				files[bundlePath] = data
			end
		end
	end

	local meta = SV.GetSaveMeta( slotName )
	if not meta then return nil, "save_meta_missing" end
	local metaJSON = util.TableToJSON( meta, true )
	if metaJSON and #metaJSON <= W.MAX_FILE_BYTES then files["meta.json"] = metaJSON end
	local cover = tostring( meta.cover or "" )
	if cover ~= "" and file.Exists( cover, "DATA" ) then
		local coverData = readBoundedFile( cover, W.MAX_COVER_BYTES )
		if coverData and #coverData >= 4 and string.byte( coverData, 1 ) == 255 and string.byte( coverData, 2 ) == 216 then
			files["cover.jpg"] = coverData
		end
	end

	local stats = istable( manifestTable.stats ) and manifestTable.stats or {}
	local bundle, infoOrError = W.EncodeBundle( {
		kind = "mcswep_world",
		name = slotName,
		map = meta.map or manifestTable.map or game.GetMap(),
		savedAt = meta.savedAt or manifestTable.savedAt or os.time(),
		savedAtText = meta.savedAtText,
		bs = meta.bs or manifestTable.bs,
		h = meta.h or manifestTable.h,
		chunks = meta.chunks or stats.chunks,
		blocks = meta.blocks or manifestTable.blockCount or stats.blocks,
		schemaHash = manifestTable.schemaHash,
		source = meta.source,
		workshopId = meta.workshopId,
		publisherSteamId64 = IsValid( ply ) and ply:SteamID64() or nil,
	}, files )
	if not bundle then return nil, infoOrError end
	return bundle, infoOrError
end

local function sendExportBegin( ply, requestId, ok, err, slotName, parts, bytes, hash )
	net.Start( "mc_workshop_export_begin" )
		net.WriteUInt( requestId or 0, 32 )
		net.WriteBool( ok == true )
		net.WriteString( tostring( err or "" ) )
		net.WriteString( tostring( slotName or "" ) )
		net.WriteUInt( math.Clamp( parts or 0, 0, 65535 ), 16 )
		net.WriteUInt( math.Clamp( bytes or 0, 0, 4294967295 ), 32 )
		net.WriteString( tostring( hash or "" ) )
	net.Send( ply )
end

net.Receive( "mc_workshop_export_request", function( _, ply )
	local requestId = net.ReadUInt( 32 )
	local slotName = SV.SaveSlotName( net.ReadString() )
	if not W.CanManage( ply ) then sendExportBegin( ply, requestId, false, "permission" ) return end
	if SV.CanUseSaves and not SV.CanUseSaves( ply ) then sendExportBegin( ply, requestId, false, "save_permission" ) return end
	if ExportSessions[ply] then sendExportBegin( ply, requestId, false, "transfer_busy" ) return end
	if not rateAllowed( ply, "export" ) then sendExportBegin( ply, requestId, false, "rate_limited" ) return end
	if not slotName then sendExportBegin( ply, requestId, false, "invalid_slot" ) return end

	local bundle, infoOrError = buildSaveBundle( ply, slotName )
	if not bundle then sendExportBegin( ply, requestId, false, infoOrError, slotName ) return end
	local partBytes = SV.ReliableNetPayloadBytes
		and SV.ReliableNetPayloadBytes( 128, W.EXPORT_PART_BYTES ) or 3000
	local parts = math.ceil( #bundle / partBytes )
	if parts < 1 or parts > 65535 then sendExportBegin( ply, requestId, false, "export_part_limit", slotName ) return end
	local exportSession = { requestId = requestId }
	ExportSessions[ply] = exportSession
	local exportTimeout = math.Clamp( 120 + #bundle / 50000, 360, W.EXPORT_TIMEOUT_MAX + 120 )
	timer.Simple( exportTimeout, function()
		if ExportSessions[ply] == exportSession then ExportSessions[ply] = nil end
	end )
	sendExportBegin( ply, requestId, true, "", slotName, parts, #bundle, infoOrError.hash )
	MsgN( string.format( "[MC] %s exported save %s for client-side Workshop publish (%d bytes)",
		IsValid( ply ) and ply:Nick() or "server", slotName, #bundle ) )

	for part = 1, parts do
		local partIndex = part
		local first = ( partIndex - 1 ) * partBytes + 1
		local len = math.min( partBytes, #bundle - first + 1 )
		SV.EnqueueReliableNet( ply, len + 128, function( target )
			local chunk = string.sub( bundle, first, first + len - 1 )
			net.Start( "mc_workshop_export_part" )
				net.WriteUInt( requestId, 32 )
				net.WriteUInt( partIndex, 16 )
				net.WriteUInt( #chunk, 16 )
				net.WriteData( chunk, #chunk )
			net.Send( target )
			if partIndex == parts and ExportSessions[target] == exportSession then ExportSessions[target] = nil end
			return true
		end )
	end
end )

local function sendLoadApproval( ply, requestId, approved, token, err )
	net.Start( "mc_workshop_load_approval" )
		net.WriteUInt( requestId or 0, 32 )
		net.WriteBool( approved == true )
		net.WriteString( tostring( token or "" ) )
		net.WriteString( tostring( err or "" ) )
	net.Send( ply )
end

local function sendUploadResult( ply, requestId, ok, err, slotName, workshopId )
	if not IsValid( ply ) then return end
	net.Start( "mc_workshop_upload_result" )
		net.WriteUInt( requestId or 0, 32 )
		net.WriteBool( ok == true )
		net.WriteString( tostring( err or "" ) )
		net.WriteString( tostring( slotName or "" ) )
		net.WriteString( tostring( workshopId or "" ) )
	net.Send( ply )
end

local function nextBaseGeneration()
	W.ServerBaseGeneration = ( W.ServerBaseGeneration + 1 ) % 4294967296
	if W.ServerBaseGeneration == 0 then W.ServerBaseGeneration = 1 end
	return W.ServerBaseGeneration
end

local function sendBaseAnnouncement( ply )
	if not IsValid( ply ) or ply:IsBot() then return end
	local base = W.ServerBase
	net.Start( "mc_workshop_base_announce" )
		net.WriteUInt( W.ServerBaseGeneration, 32 )
		net.WriteBool( base ~= nil )
		if base then
			net.WriteString( base.workshopId )
			net.WriteString( base.contentHash )
			net.WriteUInt( base.archiveBytes, 32 )
			net.WriteString( base.slotName )
		end
	net.Send( ply )
end

local function announceBaseToAll()
	for _, ply in ipairs( player.GetHumans() ) do sendBaseAnnouncement( ply ) end
end

local function activateBaseForSlot( slotName )
	slotName = SV.SaveSlotName and SV.SaveSlotName( slotName ) or W.SafeSlotName( slotName )
	local meta = slotName and SV.GetSaveMeta and SV.GetSaveMeta( slotName ) or nil
	local workshopId = meta and W.NormalizeWorkshopId( meta.workshopId ) or nil
	local contentHash = meta and string.lower( tostring( meta.workshopContentHash or "" ) ) or ""
	if not workshopId or not W.IsContentHash( contentHash ) then
		W.ServerBase = nil
		nextBaseGeneration()
		announceBaseToAll()
		return false
	end

	local archiveBytes = math.floor( tonumber( meta.workshopArchiveBytes ) or 0 )
	if archiveBytes < 17 or archiveBytes > W.MAX_WORKSHOP_ARCHIVE_BYTES then archiveBytes = 0 end
	W.ServerBase = {
		generation = nextBaseGeneration(),
		slotName = slotName,
		workshopId = workshopId,
		contentHash = contentHash,
		archiveBytes = archiveBytes,
		clients = {},
	}
	announceBaseToAll()
	MsgN( string.format( "[MC Workshop] announced base %s hash=%s slot=%s",
		workshopId, contentHash, slotName ) )
	return true
end

function W.GetServerBaseReadiness()
	local base = W.ServerBase
	if not base then return { active = false, generation = W.ServerBaseGeneration, ready = 0, pending = 0, failed = 0 } end
	local ready, pending, failed = 0, 0, 0
	for _, ply in ipairs( player.GetHumans() ) do
		local state = base.clients[ply]
		if state and state.ready == true then ready = ready + 1
		elseif state and state.ready == false then failed = failed + 1
		else pending = pending + 1 end
	end
	return {
		active = true,
		generation = base.generation,
		workshopId = base.workshopId,
		contentHash = base.contentHash,
		ready = ready,
		pending = pending,
		failed = failed,
	}
end

local function makeUploadToken( ply, requestId )
	local seed = tostring( IsValid( ply ) and ply:SteamID64() or "server" ) .. ":" .. tostring( requestId )
		.. ":" .. tostring( SysTime() ) .. ":" .. tostring( math.random() )
	return util.CRC( seed ) .. util.CRC( string.reverse( seed ) )
end

local function sharedSessionPath( ply, session )
	if not session or not IsValid( ply ) then return nil end
	return W.ListenSharedArchivePath( ply:SteamID64(), session.requestId, session.contentHash )
end

local function cleanupSharedSessionFile( ply, session )
	if not session or session.transport ~= "shared" then return end
	local path = sharedSessionPath( ply, session )
	if path and file.Exists( path, "DATA" ) then file.Delete( path ) end
end

net.Receive( "mc_workshop_load_request", function( _, ply )
	local requestId = net.ReadUInt( 32 )
	local workshopId = W.NormalizeWorkshopId( net.ReadString() )
	local totalBytes = net.ReadUInt( 32 )
	local contentHash = string.lower( net.ReadString() or "" )
	local claimedName = W.SafeSlotName( net.ReadString() )
	local claimedMap = string.sub( net.ReadString() or "", 1, 64 )
	local claimedBlocks = net.ReadUInt( 32 )
	local claimedChunks = net.ReadUInt( 32 )
	local wantsShared = net.ReadBool()

	if not W.CanManage( ply ) then sendLoadApproval( ply, requestId, false, "", "permission" ) return end
	if not rateAllowed( ply, "load" ) then sendLoadApproval( ply, requestId, false, "", "rate_limited" ) return end
	if UploadSessions[ply] then sendLoadApproval( ply, requestId, false, "", "transfer_busy" ) return end
	if not workshopId or totalBytes < 17 or totalBytes > W.MAX_WORKSHOP_ARCHIVE_BYTES or not W.IsContentHash( contentHash ) then
		sendLoadApproval( ply, requestId, false, "", "invalid_load_request" )
		return
	end
	if wantsShared and ( game.IsDedicated() or not ply.IsListenServerHost or not ply:IsListenServerHost() ) then
		sendLoadApproval( ply, requestId, false, "", "shared_unavailable" )
		return
	end

	local session = {
		phase = "approved",
		requestId = requestId,
		workshopId = workshopId,
		totalBytes = totalBytes,
		contentHash = contentHash,
		token = makeUploadToken( ply, requestId ),
		claimedName = claimedName,
		claimedMap = claimedMap,
		claimedBlocks = claimedBlocks,
		claimedChunks = claimedChunks,
		transport = wantsShared and "shared" or "net",
	}
	UploadSessions[ply] = session
	sendLoadApproval( ply, requestId, true, session.token )
	timer.Simple( APPROVAL_TIMEOUT, function()
		if UploadSessions[ply] == session and session.phase == "approved" then
			cleanupSharedSessionFile( ply, session )
			UploadSessions[ply] = nil
		end
	end )
end )

net.Receive( "mc_workshop_upload_begin", function( _, ply )
	local requestId = net.ReadUInt( 32 )
	local token = net.ReadString()
	local workshopId = W.NormalizeWorkshopId( net.ReadString() )
	local totalBytes = net.ReadUInt( 32 )
	local expectedParts = net.ReadUInt( 16 )
	local contentHash = string.lower( net.ReadString() or "" )
	local session = UploadSessions[ply]
	if not session or session.phase ~= "approved" or session.requestId ~= requestId or session.token ~= token
		or session.transport ~= "net" or session.workshopId ~= workshopId
		or session.totalBytes ~= totalBytes or session.contentHash ~= contentHash then
		if session and session.transport == "shared" then cleanupSharedSessionFile( ply, session ) end
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, "approval_mismatch", "", workshopId )
		return
	end
	if expectedParts < 1 or expectedParts ~= math.ceil( totalBytes / W.UPLOAD_PART_BYTES ) then
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, "invalid_part_count", "", workshopId )
		return
	end

	session.phase = "uploading"
	session.expectedParts = expectedParts
	session.receivedParts = 0
	session.receivedBytes = 0
	session.parts = {}
	local uploadTimeout = math.Clamp( 60 + totalBytes / 100000, 300, W.UPLOAD_TIMEOUT_MAX )
	timer.Simple( uploadTimeout, function()
		if UploadSessions[ply] == session then
			UploadSessions[ply] = nil
			sendUploadResult( ply, requestId, false, "timeout", "", workshopId )
		end
	end )
end )

local function uniqueWorkshopSlot( preferred, workshopId )
	preferred = W.SafeSlotName( preferred ) or ( "workshop_" .. workshopId )
	if not SV.SaveExists( preferred ) then return preferred end
	local suffix = "_ws_" .. workshopId
	local stem = string.sub( preferred, 1, math.max( 1, 64 - #suffix ) )
	local candidate = W.SafeSlotName( stem .. suffix )
	if candidate and not SV.SaveExists( candidate ) then return candidate end
	for index = 2, 999 do
		local numbered = suffix .. "_" .. index
		stem = string.sub( preferred, 1, math.max( 1, 64 - #numbered ) )
		candidate = W.SafeSlotName( stem .. numbered )
		if candidate and not SV.SaveExists( candidate ) then return candidate end
	end
	return nil
end

local function writeBinaryFile( path, data )
	local handle = file.Open( path, "wb", "DATA" )
	if not handle then return false, "file_open_failed:" .. path end
	handle:Write( data )
	handle:Close()
	if not file.Exists( path, "DATA" ) or file.Size( path, "DATA" ) ~= #data then
		file.Delete( path )
		return false, "file_write_failed:" .. path
	end
	return true
end

local function cleanupImportedSlot( slotName )
	local root = WORKSHOP_SAVE_SLOT_DIR .. "/" .. slotName
	local regionDir = root .. "/regions"
	for _, name in ipairs( file.Find( regionDir .. "/*", "DATA" ) or {} ) do file.Delete( regionDir .. "/" .. name ) end
	file.Delete( regionDir )
	for _, name in ipairs( file.Find( root .. "/*", "DATA" ) or {} ) do file.Delete( root .. "/" .. name ) end
	file.Delete( root )
	file.Delete( SV.WorkshopSaveMetaPath and SV.WorkshopSaveMetaPath( slotName ) or ( root .. "/meta.json" ) )
	SV.DeleteSaveCovers( slotName )
end

local function importWorkshopBundle( ply, workshopId, contentHash, decoded, archiveBytes )
	local slotName = uniqueWorkshopSlot( decoded.metadata.name, workshopId )
	if not slotName then return nil, "save_name_exhausted" end
	local root = WORKSHOP_SAVE_SLOT_DIR .. "/" .. slotName
	local regionDir = root .. "/regions"
	file.CreateDir( "mc" )
	file.CreateDir( SAVE_SLOT_DIR )
	file.CreateDir( WORKSHOP_SAVE_SLOT_DIR )
	file.CreateDir( root )
	file.CreateDir( regionDir )

	local manifest = decoded.manifest
	manifest.slotName = slotName
	local manifestJSON = util.TableToJSON( manifest )
	if not manifestJSON then cleanupImportedSlot( slotName ) return nil, "manifest_encode_failed" end
	local ok, writeError = writeBinaryFile( root .. "/manifest.json", manifestJSON )
	if not ok then cleanupImportedSlot( slotName ) return nil, writeError end

	local paths = {}
	for path in pairs( decoded.files ) do paths[#paths + 1] = path end
	table.sort( paths )
	for _, path in ipairs( paths ) do
		if path == "edits.json" or string.StartWith( path, "regions/" ) then
			ok, writeError = writeBinaryFile( root .. "/" .. path, decoded.files[path] )
			if not ok then cleanupImportedSlot( slotName ) return nil, writeError end
		end
	end

	local coverPath = ""
	local coverData = decoded.files["cover.jpg"]
	if coverData then
		file.CreateDir( SAVE_COVER_DIR )
		coverPath = SV.SaveCoverPath( slotName )
		ok, writeError = writeBinaryFile( coverPath, coverData )
		if not ok then cleanupImportedSlot( slotName ) return nil, writeError end
		SV.DeleteSaveCovers( slotName, coverPath )
	end

	local stats = istable( manifest.stats ) and manifest.stats or {}
	local savedAt = math.floor( tonumber( manifest.savedAt or decoded.metadata.savedAt ) or os.time() )
	local meta = {
		v = 2,
		name = slotName,
		path = SV.WorkshopSaveSlotPath( slotName ),
		map = tostring( manifest.map or decoded.metadata.map or "unknown" ),
		savedAt = savedAt,
		savedAtText = os.date( "%Y-%m-%d %H:%M:%S", savedAt ),
		bs = tonumber( manifest.bs or decoded.metadata.bs ) or MC.BS,
		h = math.floor( tonumber( manifest.h or decoded.metadata.h ) or MC.CH ),
		chunks = math.floor( tonumber( stats.chunks or decoded.metadata.chunks ) or 0 ),
		blocks = math.floor( tonumber( manifest.blockCount or stats.blocks or decoded.metadata.blocks ) or 0 ),
		cover = coverPath,
		source = "workshop",
		workshopId = workshopId,
		workshopOwner = decoded.metadata.publisherSteamId64,
		workshopContentHash = contentHash,
		workshopArchiveBytes = math.floor( tonumber( archiveBytes ) or 0 ),
		workshopImportedAt = os.time(),
		workshopImportedBy = IsValid( ply ) and ply:SteamID64() or "server",
	}
	local wroteMeta, metaError = SV.WriteSaveMetaTable( slotName, meta, meta.path )
	if not wroteMeta then cleanupImportedSlot( slotName ) return nil, metaError or "meta_write_failed" end

	local loaded, loadError = SV.LoadSave( slotName, true )
	if not loaded then cleanupImportedSlot( slotName ) return nil, loadError or "load_failed" end
	MsgN( string.format( "[MC] %s imported Workshop world %s as %s",
		IsValid( ply ) and ply:Nick() or "server", workshopId, slotName ) )
	return slotName
end

local function finishUpload( ply, session, payload )
	if #payload ~= session.totalBytes then
		sendUploadResult( ply, session.requestId, false, "size_mismatch", "", session.workshopId )
		return
	end
	local contentHash = W.ContentHash( payload )
	if contentHash ~= session.contentHash then
		sendUploadResult( ply, session.requestId, false, "hash_mismatch", "", session.workshopId )
		return
	end
	local bundle, archiveError = W.DecodeWorkshopArchive( payload )
	if not bundle then
		sendUploadResult( ply, session.requestId, false, archiveError, "", session.workshopId )
		return
	end
	local decoded, decodeError = W.DecodeBundle( bundle )
	if not decoded then
		sendUploadResult( ply, session.requestId, false, decodeError, "", session.workshopId )
		return
	end
	local slotName, importError = importWorkshopBundle( ply, session.workshopId, contentHash, decoded, #payload )
	if not slotName then
		sendUploadResult( ply, session.requestId, false, importError, "", session.workshopId )
		return
	end
	sendUploadResult( ply, session.requestId, true, "", slotName, session.workshopId )
	if SV.SendSaveList and ( not SV.CanUseSaves or SV.CanUseSaves( ply ) ) then
		SV.SendSaveList( ply, L( ply, "workshop.import_done", "已从创意工坊读取: {name}", { name = slotName } ), false )
	end
end

net.Receive( "mc_workshop_shared_ready", function( _, ply )
	local requestId = net.ReadUInt( 32 )
	local token = net.ReadString()
	local workshopId = W.NormalizeWorkshopId( net.ReadString() )
	local totalBytes = net.ReadUInt( 32 )
	local contentHash = string.lower( net.ReadString() or "" )
	local clientWrote = net.ReadBool()
	local clientError = string.sub( net.ReadString() or "", 1, 96 )
	local session = UploadSessions[ply]
	if not session or session.phase ~= "approved" or session.transport ~= "shared"
		or session.requestId ~= requestId or session.token ~= token or session.workshopId ~= workshopId
		or session.totalBytes ~= totalBytes or session.contentHash ~= contentHash
		or game.IsDedicated() or not ply.IsListenServerHost or not ply:IsListenServerHost() then
		if session and session.transport == "shared" then cleanupSharedSessionFile( ply, session ) end
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, "approval_mismatch", "", workshopId )
		return
	end

	if not clientWrote then
		cleanupSharedSessionFile( ply, session )
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, clientError ~= "" and clientError or "shared_write_failed", "", workshopId )
		return
	end

	session.phase = "reading_shared"
	local path = sharedSessionPath( ply, session )
	local payload, readError
	if path then
		payload, readError = readBoundedFile( path, W.MAX_WORKSHOP_ARCHIVE_BYTES )
	else
		readError = "shared_read_failed"
	end
	cleanupSharedSessionFile( ply, session )
	UploadSessions[ply] = nil
	if not payload then
		sendUploadResult( ply, requestId, false, readError or "shared_read_failed", "", workshopId )
		return
	end
	timer.Simple( 0, function()
		if IsValid( ply ) then finishUpload( ply, session, payload ) end
	end )
end )

net.Receive( "mc_workshop_upload_part", function( _, ply )
	local requestId = net.ReadUInt( 32 )
	local token = net.ReadString()
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	local session = UploadSessions[ply]
	if not session or session.phase ~= "uploading" or session.requestId ~= requestId or session.token ~= token then return end
	session.messageCount = ( session.messageCount or 0 ) + 1
	if session.messageCount > session.expectedParts * 2 + 16 then
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, "too_many_parts", "", session.workshopId )
		return
	end
	if index < 1 or index > session.expectedParts or len < 1 or len > W.UPLOAD_PART_BYTES
		or not chunk or #chunk ~= len then
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, "invalid_part", "", session.workshopId )
		return
	end
	if session.parts[index] then return end
	session.parts[index] = chunk
	session.receivedParts = session.receivedParts + 1
	session.receivedBytes = session.receivedBytes + len
	if session.receivedBytes > session.totalBytes then
		UploadSessions[ply] = nil
		sendUploadResult( ply, requestId, false, "size_mismatch", "", session.workshopId )
		return
	end
	if session.receivedParts < session.expectedParts then return end

	UploadSessions[ply] = nil
	local bundle = table.concat( session.parts )
	timer.Simple( 0, function()
		if IsValid( ply ) then finishUpload( ply, session, bundle ) end
	end )
end )

local function sendBindResult( ply, requestId, ok, err, slotName, workshopId )
	net.Start( "mc_workshop_bind_result" )
		net.WriteUInt( requestId or 0, 32 )
		net.WriteBool( ok == true )
		net.WriteString( tostring( err or "" ) )
		net.WriteString( tostring( slotName or "" ) )
		net.WriteString( tostring( workshopId or "" ) )
	net.Send( ply )
end

net.Receive( "mc_workshop_bind_id", function( _, ply )
	local requestId = net.ReadUInt( 32 )
	local slotName = SV.SaveSlotName( net.ReadString() )
	local workshopId = W.NormalizeWorkshopId( net.ReadString() )
	local contentHash = string.lower( net.ReadString() or "" )
	local archiveBytes = net.ReadUInt( 32 )
	if not W.CanManage( ply ) then sendBindResult( ply, requestId, false, "permission" ) return end
	if SV.CanUseSaves and not SV.CanUseSaves( ply ) then sendBindResult( ply, requestId, false, "save_permission" ) return end
	if not rateAllowed( ply, "bind" ) then sendBindResult( ply, requestId, false, "rate_limited" ) return end
	if not slotName or not workshopId or not W.IsContentHash( contentHash )
		or archiveBytes < 17 or archiveBytes > W.MAX_WORKSHOP_ARCHIVE_BYTES then
		sendBindResult( ply, requestId, false, "invalid_bind" )
		return
	end
	local ok, err = SV.UpdateSaveWorkshopMetadata( slotName, workshopId, contentHash, ply:SteamID64(), archiveBytes )
	sendBindResult( ply, requestId, ok, ok and "" or err, slotName, workshopId )
	if ok and SV.SendSaveList then
		MsgN( string.format( "[MC] %s linked save %s to Workshop item %s",
			ply:Nick(), slotName, workshopId ) )
		SV.SendSaveList( ply, L( ply, "workshop.publish_bound", "已关联创意工坊 ID: {id}", { id = workshopId } ), false )
	end
	if ok and W.ServerLoadedSlot == slotName then activateBaseForSlot( slotName ) end
end )

net.Receive( "mc_workshop_base_ready", function( _, ply )
	local generation = net.ReadUInt( 32 )
	local workshopId = W.NormalizeWorkshopId( net.ReadString() )
	local actualHash = string.lower( string.sub( net.ReadString() or "", 1, 64 ) )
	local ready = net.ReadBool()
	local err = string.sub( net.ReadString() or "", 1, 96 )
	local base = W.ServerBase
	if not base or generation ~= base.generation or workshopId ~= base.workshopId then return end
	if ready and actualHash ~= base.contentHash then
		ready = false
		err = "hash_mismatch"
	end
	base.clients[ply] = {
		ready = ready == true,
		actualHash = actualHash,
		error = ready and nil or ( err ~= "" and err or "base_not_ready" ),
		updatedAt = CurTime(),
	}
	local counts = W.GetServerBaseReadiness()
	if ready then
		MsgN( string.format( "[MC Workshop] %s READY for base %s (%d ready, %d pending, %d failed)",
			ply:Nick(), base.workshopId, counts.ready, counts.pending, counts.failed ) )
	else
		base.allReadyFired = false
		MsgN( string.format( "[MC Workshop] %s failed base %s: %s",
			ply:Nick(), base.workshopId, base.clients[ply].error ) )
	end
	if counts.pending == 0 and counts.failed == 0 and not base.allReadyFired and MC.RunEvent then
		base.allReadyFired = true
		MC.RunEvent( "MC.WorkshopBaseReady", base.generation, base.workshopId, base.contentHash )
	end
end )

hook.Add( "MC.WorldLoaded", "MC_WorkshopAnnounceLoadedBase", function( _, slotName )
	W.ServerLoadedSlot = SV.SaveSlotName and SV.SaveSlotName( slotName ) or W.SafeSlotName( slotName )
	activateBaseForSlot( slotName )
end )

hook.Add( "MC.PlayerWorldSynced", "MC_WorkshopAnnounceBaseToSyncedPlayer", function( ply )
	if W.ServerBase and W.ServerBase.clients and W.ServerBase.clients[ply] == nil then
		W.ServerBase.allReadyFired = false
	end
	sendBaseAnnouncement( ply )
end )

hook.Add( "PlayerDisconnected", "MC_WorkshopClearTransfers", function( ply )
	cleanupSharedSessionFile( ply, UploadSessions[ply] )
	UploadSessions[ply] = nil
	ExportSessions[ply] = nil
	RequestTimes[ply] = nil
	if W.ServerBase and W.ServerBase.clients then W.ServerBase.clients[ply] = nil end
end )
