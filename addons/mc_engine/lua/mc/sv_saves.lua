--[[----------------------------------------------------------------------------
	MC : server save manager.

	Named save slots, metadata, console commands, and Derma UI net bridge live
	here so sv_world.lua can stay focused on voxel storage and world mutation.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config

-- Translated with this server's files for the player's language.
local function L( ply, key, vars )
	return MC.I18n.Resolve( key, vars, MC.I18n.LanguageForPlayer( ply ) )
end

local SAVE_DIR = "mc"
local SAVE_SLOT_DIR = "mc/saves"
local WORKSHOP_SAVE_SLOT_DIR = "mc/workshop_saves"
local MOUNTED_SAVE_SLOT_DIR = "data_static/mc/saves"
local MOUNTED_SAVE_KEY_PREFIX = "@mounted:"
local SAVE_COVER_DIR = "mc/save_covers"
local MAX_NET_SAVES = 4095
local SAVE_LIST_NET_BUDGET = 60000
local SAVE_COVER_PART_BYTES = 16384
local MAX_SAVE_COVER_BYTES = 1024 * 1024 * 2
local SAVE_COVER_UPLOAD_TIMEOUT = 20
local SAVE_COVER_DOWNLOAD_PART_INTERVAL = 0.05
local SAVE_PUBLIC_HELP = "Allow non-admin players to list/load/save MC saves; delete remains admin-only"

local function ensureSaveDirs()
	file.CreateDir( SAVE_DIR )
	file.CreateDir( SAVE_SLOT_DIR )
	file.CreateDir( WORKSHOP_SAVE_SLOT_DIR )
	file.CreateDir( SAVE_COVER_DIR )
end

function SV.SaveSlotName( name )
	name = string.Trim( tostring( name or "" ) )
	if name == "" then return nil end
	name = string.gsub( name, "[%c/\\:%*%?\"<>|]", "_" )
	name = string.gsub( name, "%.%.+", "_" )
	name = string.gsub( name, "^%.+", "" )
	name = string.Trim( string.sub( name, 1, 64 ) )
	if name == "" then return nil end
	return name
end

function SV.SaveSlotPath( slotName )
	return SAVE_SLOT_DIR .. "/" .. slotName .. "/manifest.json"
end

function SV.SaveMetaPath( slotName )
	return SAVE_SLOT_DIR .. "/" .. slotName .. "/meta.json"
end

function SV.WorkshopSaveSlotPath( slotName )
	return WORKSHOP_SAVE_SLOT_DIR .. "/" .. slotName .. "/manifest.json"
end

function SV.WorkshopSaveMetaPath( slotName )
	return WORKSHOP_SAVE_SLOT_DIR .. "/" .. slotName .. "/meta.json"
end

function SV.MountedSaveSlotPath( packageName )
	return MOUNTED_SAVE_SLOT_DIR .. "/" .. packageName .. "/manifest.json"
end

local function mountedSaveKey( packageName )
	return MOUNTED_SAVE_KEY_PREFIX .. packageName
end

local function mountedPackageFromKey( value )
	value = string.Trim( tostring( value or "" ) )
	if not string.StartWith( value, MOUNTED_SAVE_KEY_PREFIX ) then return nil end
	local packageName = string.sub( value, #MOUNTED_SAVE_KEY_PREFIX + 1 )
	local clean = SV.SaveSlotName( packageName )
	if clean ~= packageName then return nil end
	return clean
end

local function mountedSaveDescriptor( packageName, path )
	local info = MC.Workshop and MC.Workshop.GetMountedPackageInfo
		and MC.Workshop.GetMountedPackageInfo( packageName ) or nil
	return {
		name = packageName,
		key = mountedSaveKey( packageName ),
		path = path or SV.MountedSaveSlotPath( packageName ),
		source = "mounted",
		root = MOUNTED_SAVE_SLOT_DIR,
		realm = "GAME",
		workshopId = info and info.workshopId or nil,
		archiveBytes = info and info.archiveBytes or 0,
		addonFile = info and info.file or nil,
	}
end

function SV.LegacySaveSlotPath( slotName )
	return SAVE_SLOT_DIR .. "/" .. slotName .. ".dat"
end

local function legacySaveMetaPath( slotName )
	return SAVE_SLOT_DIR .. "/" .. slotName .. ".json"
end

local function manifestMetaPath( manifestPath, slotName )
	if string.EndsWith( tostring( manifestPath or "" ), ".dat" ) then return legacySaveMetaPath( slotName ) end
	return string.GetPathFromFilename( manifestPath ) .. "meta.json"
end

function SV.ResolveSaveSlot( slotName )
	local mountedPackage = mountedPackageFromKey( slotName )
	if mountedPackage then
		local mountedPath = SV.MountedSaveSlotPath( mountedPackage )
		if file.Exists( mountedPath, "GAME" ) then
			return mountedSaveDescriptor( mountedPackage, mountedPath )
		end
		return nil
	end

	slotName = SV.SaveSlotName( slotName )
	if not slotName then return nil end
	local localPath = SV.SaveSlotPath( slotName )
	if file.Exists( localPath, "DATA" ) then
		return { name = slotName, key = slotName, path = localPath, source = "local", root = SAVE_SLOT_DIR, realm = "DATA" }
	end
	local workshopPath = SV.WorkshopSaveSlotPath( slotName )
	if file.Exists( workshopPath, "DATA" ) then
		return { name = slotName, key = slotName, path = workshopPath, source = "workshop", root = WORKSHOP_SAVE_SLOT_DIR, realm = "DATA" }
	end
	local legacyPath = SV.LegacySaveSlotPath( slotName )
	if file.Exists( legacyPath, "DATA" ) then
		return { name = slotName, key = slotName, path = legacyPath, source = "local", root = SAVE_SLOT_DIR, realm = "DATA", legacy = true }
	end
	local mountedPath = SV.MountedSaveSlotPath( slotName )
	if file.Exists( mountedPath, "GAME" ) then
		return mountedSaveDescriptor( slotName, mountedPath )
	end
	return nil
end

function SV.SaveCoverPath( slotName )
	return SAVE_COVER_DIR .. "/" .. slotName .. ".jpg"
end

function SV.DeleteSaveCovers( slotName, keepPath )
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return end

	local function deletePath( path )
		if path == keepPath then return end
		if file.Exists( path, "DATA" ) then file.Delete( path ) end
	end

	deletePath( SV.SaveCoverPath( slotName ) )

	local files = file.Find( SAVE_COVER_DIR .. "/" .. slotName .. "_*.jpg", "DATA" ) or {}
	for _, fn in ipairs( files ) do
		deletePath( SAVE_COVER_DIR .. "/" .. fn )
	end
end

local function sanitizeSaveCover( cover, slotName )
	cover = string.Trim( tostring( cover or "" ) )
	if cover == "" then return nil end
	cover = string.gsub( cover, "\\", "/" )
	cover = string.gsub( cover, "%.%.+", "_" )
	if not string.StartWith( cover, SAVE_COVER_DIR .. "/" ) then
		return SV.SaveCoverPath( slotName )
	end
	cover = string.gsub( cover, "[%c:%*%?\"<>|]", "_" )
	return string.sub( cover, 1, 160 )
end

local function sanitizeSaveCoverReadPath( cover )
	cover = string.Trim( tostring( cover or "" ) )
	if cover == "" then return nil end
	cover = string.gsub( cover, "\\", "/" )
	cover = string.gsub( cover, "%.%.+", "_" )
	if not string.StartWith( cover, SAVE_COVER_DIR .. "/" ) then return nil end
	cover = string.gsub( cover, "[%c:%*%?\"<>|]", "_" )
	return string.sub( cover, 1, 160 )
end

local function saveCoverBelongsToSlot( cover, slotName )
	local base = SAVE_COVER_DIR .. "/" .. slotName
	return cover == base .. ".jpg" or string.StartWith( cover, base .. "_" )
end

local function writeSaveMeta( slotName, path, data, chunks, blocks, cover, source )
	ensureSaveDirs()
	local root = string.GetPathFromFilename( path )
	file.CreateDir( root )
	local metaPath = manifestMetaPath( path, slotName )
	local previousRaw = file.Read( metaPath, "DATA" )
	local previous = previousRaw and util.JSONToTable( previousRaw ) or {}
	local savedAt = data.savedAt or os.time()
	local meta = {
		v = 2,
		name = slotName,
		path = path,
		map = data.map or game.GetMap(),
		savedAt = savedAt,
		savedAtText = os.date( "%Y-%m-%d %H:%M:%S", savedAt ),
		bs = data.bs,
		h = data.h,
		chunks = chunks,
		blocks = blocks,
		cover = sanitizeSaveCover( cover or data.cover, slotName ),
		source = source == "workshop" and "workshop" or "local",
		workshopId = previous.workshopId,
		workshopOwner = previous.workshopOwner,
		workshopPublishedAt = previous.workshopPublishedAt,
		workshopContentHash = previous.workshopContentHash,
		workshopArchiveBytes = previous.workshopArchiveBytes,
		workshopImportedAt = previous.workshopImportedAt,
		workshopImportedBy = previous.workshopImportedBy,
	}
	local json = util.TableToJSON( meta, true )
	if json then file.Write( metaPath, json ) end
end

local function readSaveMeta( slotName, path, source, realm )
	local metaPath = manifestMetaPath( path, slotName )
	realm = realm == "GAME" and "GAME" or "DATA"
	local raw = file.Read( metaPath, realm )
	local meta = raw and util.JSONToTable( raw ) or nil
	if istable( meta ) and ( source == "workshop" or source == "mounted" ) then meta.source = source end
	return meta
end

local function savedBlockCount( data )
	if not data or not istable( data.chunks ) then return 0, 0 end
	local blocks = 0
	for _, c in ipairs( data.chunks ) do
		local cells = c[4]
		if istable( cells ) then
			blocks = blocks + math.floor( #cells / 2 )
		elseif isstring( cells ) then
			for entry in string.gmatch( cells, "[^;]+" ) do
				if entry ~= "" then blocks = blocks + 1 end
			end
		end
	end
	return #data.chunks, blocks
end

local function readSaveJSON( path, realm )
	realm = realm == "GAME" and "GAME" or "DATA"
	local raw = file.Read( path, realm )
	if not raw or raw == "" then return nil end
	if string.sub( raw, 1, 1 ) == "{" then
		return util.JSONToTable( raw )
	end
	local json = util.Decompress( raw )
	return json and util.JSONToTable( json ) or nil
end

local function readSaveDataSummary( slotName, path, realm )
	local data = readSaveJSON( path, realm )
	if data and istable( data.parts ) and istable( data.stats ) then
		local savedAt = tonumber( data.savedAt )
		return {
			v = 1,
			name = slotName,
			path = path,
			map = data.map or "unknown",
			savedAt = savedAt,
			savedAtText = savedAt and os.date( "%Y-%m-%d %H:%M:%S", savedAt ) or "?",
			bs = data.bs,
			h = data.h,
			chunks = math.floor( tonumber( data.stats.chunks ) or 0 ),
			blocks = math.floor( tonumber( data.stats.blocks ) or 0 ),
			cover = sanitizeSaveCover( data.cover, slotName ),
		}
	end
	if not data or not data.chunks then return nil end
	local chunks, blocks = savedBlockCount( data )
	local savedAt = tonumber( data.savedAt )
	return {
		v = 1,
		name = slotName,
		path = path,
		map = data.map or "unknown",
		savedAt = savedAt,
		savedAtText = savedAt and os.date( "%Y-%m-%d %H:%M:%S", savedAt ) or "?",
		bs = data.bs,
		h = data.h,
		chunks = chunks,
		blocks = blocks,
		cover = sanitizeSaveCover( data.cover, slotName ),
	}
end

local function writeMetaTable( slotName, meta, path )
	local json = util.TableToJSON( meta, true )
	if not json then return false end
	path = path or meta.path or SV.SaveSlotPath( slotName )
	local metaPath
	if string.EndsWith( tostring( path or "" ), ".dat" ) then
		metaPath = legacySaveMetaPath( slotName )
	else
		file.CreateDir( string.GetPathFromFilename( path ) )
		metaPath = manifestMetaPath( path, slotName )
	end
	file.Write( metaPath, json )
	return file.Read( metaPath, "DATA" ) == json
end

local function saveMetaComplete( meta )
	return meta
		and meta.map ~= nil and meta.map ~= "" and meta.map ~= "unknown"
		and meta.savedAtText ~= nil and meta.savedAtText ~= ""
		and meta.blocks ~= nil
		and meta.chunks ~= nil
end

local function readSaveListMeta( slotName, path, source, realm )
	realm = realm == "GAME" and "GAME" or "DATA"
	local meta = readSaveMeta( slotName, path, source, realm ) or {}
	if source == "workshop" or source == "mounted" then meta.source = source end
	if saveMetaComplete( meta ) then
		meta.name = meta.name or slotName
		meta.path = meta.path or path
		return meta
	end

	local summary = readSaveDataSummary( slotName, path, realm )
	if not summary then
		meta.name = meta.name or slotName
		meta.path = meta.path or path
		return meta
	end

	meta.v = meta.v or 1
	meta.name = meta.name or summary.name
	meta.path = meta.path or summary.path
	if meta.map == nil or meta.map == "" or meta.map == "unknown" then meta.map = summary.map end
	meta.savedAt = meta.savedAt or summary.savedAt
	if meta.savedAtText == nil or meta.savedAtText == "" or meta.savedAtText == "?" then meta.savedAtText = summary.savedAtText end
	if meta.bs == nil then meta.bs = summary.bs end
	if meta.h == nil then meta.h = summary.h end
	if meta.chunks == nil then meta.chunks = summary.chunks end
	if meta.blocks == nil then meta.blocks = summary.blocks end
	if meta.cover == nil then meta.cover = summary.cover end
	if realm == "DATA" then writeMetaTable( slotName, meta, path ) end
	return meta
end

function SV.SaveExists( slotName )
	return SV.ResolveSaveSlot( slotName ) ~= nil
end

function SV.GetSaveMeta( slotName )
	local resolved = SV.ResolveSaveSlot( slotName )
	if not resolved then return nil, "save_not_found" end
	return readSaveListMeta( resolved.name, resolved.path, resolved.source, resolved.realm ), resolved.path, resolved.source
end

function SV.WriteSaveMetaTable( slotName, meta, path )
	slotName = SV.SaveSlotName( slotName )
	if not slotName or not istable( meta ) then return false, "invalid_save_meta" end
	path = path or SV.SaveSlotPath( slotName )
	meta.name = slotName
	meta.path = path
	if string.StartWith( string.lower( path ), string.lower( WORKSHOP_SAVE_SLOT_DIR .. "/" ) ) then meta.source = "workshop" end
	if not writeMetaTable( slotName, meta, path ) then return false, "meta_write_failed" end
	return true
end

function SV.UpdateSaveWorkshopMetadata( slotName, workshopId, contentHash, ownerSteamId64, archiveBytes )
	local meta, path, source = SV.GetSaveMeta( slotName )
	if not meta then return false, path end
	if source == "mounted" then return false, "mounted_save_read_only" end
	workshopId = MC.Workshop and MC.Workshop.NormalizeWorkshopId( workshopId ) or nil
	if not workshopId then return false, "invalid_workshop_id" end
	meta.v = math.max( math.floor( tonumber( meta.v ) or 1 ), 2 )
	local resolved = SV.ResolveSaveSlot( slotName )
	meta.source = resolved and resolved.source == "workshop" and "workshop" or "local"
	meta.workshopId = workshopId
	meta.workshopOwner = string.Trim( tostring( ownerSteamId64 or meta.workshopOwner or "" ) )
	meta.workshopPublishedAt = os.time()
	if MC.Workshop and MC.Workshop.IsContentHash( contentHash ) then
		meta.workshopContentHash = string.lower( tostring( contentHash ) )
	end
	archiveBytes = math.floor( tonumber( archiveBytes ) or 0 )
	if MC.Workshop and archiveBytes >= 17 and archiveBytes <= MC.Workshop.MAX_WORKSHOP_ARCHIVE_BYTES then
		meta.workshopArchiveBytes = archiveBytes
	end
	return SV.WriteSaveMetaTable( slotName, meta, path )
end

function SV.SaveNamed( slotName, cover )
	if mountedPackageFromKey( slotName ) then return false, "mounted_save_read_only" end
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return false, "missing_save_name" end
	ensureSaveDirs()
	local resolved = SV.ResolveSaveSlot( slotName )
	if resolved and resolved.source == "mounted" then return false, "mounted_save_read_only" end
	local source = resolved and resolved.source or "local"
	local targetPath = resolved and not resolved.legacy and resolved.path or SV.SaveSlotPath( slotName )
	local ok, path, data, chunks, blocks = SV.SaveToPath( targetPath, slotName )
	if ok then writeSaveMeta( slotName, path, data, chunks, blocks, cover, source ) end
	return ok, path
end

function SV.LoadSave( slotName, resyncClients )
	local resolved = SV.ResolveSaveSlot( slotName )
	if not resolved then return false, "save_not_found" end
	return SV.LoadFromPath( resolved.path, resyncClients, resolved.key or resolved.name, resolved.realm )
end

function SV.DeleteSave( slotName )
	local resolved = SV.ResolveSaveSlot( slotName )
	if not resolved then return false, "save_not_found" end
	if resolved.source == "mounted" then return false, "mounted_save_read_only" end
	slotName = resolved.name
	if resolved.legacy then
		file.Delete( resolved.path )
		file.Delete( legacySaveMetaPath( slotName ) )
	else
		local root = string.GetPathFromFilename( resolved.path )
		root = string.gsub( root, "/+$", "" )
		local regionDir = root .. "/regions"
		for _, name in ipairs( file.Find( regionDir .. "/*", "DATA" ) or {} ) do file.Delete( regionDir .. "/" .. name ) end
		file.Delete( regionDir )
		for _, name in ipairs( file.Find( root .. "/*", "DATA" ) or {} ) do file.Delete( root .. "/" .. name ) end
		file.Delete( root )
	end
	SV.DeleteSaveCovers( slotName )
	MsgN( "[MC] deleted save \"" .. slotName .. "\"" )
	if MC.RunEvent then MC.RunEvent( "MC.SaveDeleted", slotName ) end
	return true
end

function SV.SaveList()
	ensureSaveDirs()
	local files = file.Find( SAVE_SLOT_DIR .. "/*.dat", "DATA" ) or {}
	local paths = {}
	local function collectRoot( root, source, pathForSlot, realm )
		realm = realm == "GAME" and "GAME" or "DATA"
		local _, directories = file.Find( root .. "/*", realm )
		for _, slotName in ipairs( directories or {} ) do
			local clean = SV.SaveSlotName( slotName )
			local path = clean and pathForSlot( clean ) or nil
			local key = source == "mounted" and mountedSaveKey( slotName ) or clean
			if clean == slotName and path and file.Exists( path, realm ) and not paths[key] then
				if source == "mounted" then
					paths[key] = mountedSaveDescriptor( slotName, path )
				else
					paths[key] = { name = slotName, key = key, path = path, source = source, realm = realm }
				end
			end
		end
	end
	collectRoot( SAVE_SLOT_DIR, "local", SV.SaveSlotPath, "DATA" )
	collectRoot( WORKSHOP_SAVE_SLOT_DIR, "workshop", SV.WorkshopSaveSlotPath, "DATA" )
	collectRoot( MOUNTED_SAVE_SLOT_DIR, "mounted", SV.MountedSaveSlotPath, "GAME" )
	for _, fn in ipairs( files ) do
		local slotName = string.gsub( fn, "%.dat$", "" )
		if not paths[slotName] then
			paths[slotName] = { name = slotName, key = slotName, path = SAVE_SLOT_DIR .. "/" .. fn, source = "local", realm = "DATA" }
		end
	end
	local out = {}
	for _, descriptor in pairs( paths ) do
		local slotName, path, source, realm = descriptor.name, descriptor.path, descriptor.source, descriptor.realm
		local meta = readSaveListMeta( slotName, path, source, realm )
		local workshopId = MC.Workshop and MC.Workshop.NormalizeWorkshopId( meta.workshopId ) or nil
		if not workshopId and MC.Workshop then workshopId = MC.Workshop.NormalizeWorkshopId( descriptor.workshopId ) end
		out[#out + 1] = {
			name = meta.name or slotName,
			key = descriptor.key or slotName,
			map = meta.map or "unknown",
			blocks = math.floor( tonumber( meta.blocks ) or 0 ),
			chunks = math.floor( tonumber( meta.chunks ) or 0 ),
			savedAtText = meta.savedAtText or "?",
			cover = source == "mounted" and "" or ( sanitizeSaveCover( meta.cover, slotName ) or "" ),
			path = path,
			source = source,
			workshopId = workshopId or "",
		}
	end
	table.sort( out, function( a, b ) return tostring( a.name ) < tostring( b.name ) end )
	return out
end

local function joinArgs( args, first, last )
	if not args or not args[first] then return nil end
	local out = {}
	for i = first, last or #args do out[#out + 1] = args[i] end
	return table.concat( out, " " )
end

local function saveCommandName( args )
	return joinArgs( args or {}, 1 )
end

local function printSaveManagerLine( ply, msg )
	MsgN( msg )
	if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, msg ) end
end

local function savePublicConVar()
	if not C.SavePublic then
		C.SavePublic = GetConVar( "mc_save_public" ) or CreateConVar( "mc_save_public", "0", bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED ), SAVE_PUBLIC_HELP )
	end
	return C.SavePublic
end

local function savePublicEnabled()
	return savePublicConVar():GetBool()
end

local function canUseSaves( ply )
	return not IsValid( ply ) or ply:IsAdmin() or savePublicEnabled()
end

local function canDeleteSaves( ply )
	return not IsValid( ply ) or ply:IsAdmin()
end

SV.CanUseSaves = canUseSaves
SV.CanDeleteSaves = canDeleteSaves

local function printSaveUseDenied( ply )
	printSaveManagerLine( ply, "[MC] only admins may list/load/save MC saves (set mc_save_public 1 to allow everyone)" )
end

local function printSaveDeleteDenied( ply )
	printSaveManagerLine( ply, "[MC] only admins may delete MC saves" )
end

local SaveCoverUploads = {}

local function sendSaveCoverAck( ply, cover, ok, err )
	if not IsValid( ply ) then return end
	net.Start( "mc_save_cover_ack" )
		net.WriteString( tostring( cover or "" ) )
		net.WriteBool( ok == true )
		net.WriteString( tostring( err or "" ) )
	net.Send( ply )
end

local function failSaveCoverUpload( ply, upload, err )
	if SaveCoverUploads[ply] == upload then SaveCoverUploads[ply] = nil end
	sendSaveCoverAck( ply, upload and upload.cover or "", false, err )
end

local function isJPEGData( data )
	return isstring( data ) and #data >= 4 and string.byte( data, 1 ) == 255 and string.byte( data, 2 ) == 216
end

local function sendSaveCoverToClient( ply, cover )
	if not IsValid( ply ) then return end
	cover = sanitizeSaveCoverReadPath( cover )
	if not cover or not file.Exists( cover, "DATA" ) then return end

	local data = file.Read( cover, "DATA" )
	if not data or data == "" or #data > MAX_SAVE_COVER_BYTES then return end

	local parts = math.ceil( #data / SAVE_COVER_PART_BYTES )
	local timerName = "MC_SaveCoverDownload_" .. ply:EntIndex() .. "_" .. util.CRC( cover )
	timer.Remove( timerName )

	net.Start( "mc_save_cover_download_begin" )
		net.WriteString( cover )
		net.WriteUInt( parts, 16 )
		net.WriteUInt( #data, 32 )
	net.Send( ply )

	local i = 1
	timer.Create( timerName, SAVE_COVER_DOWNLOAD_PART_INTERVAL, parts, function()
		if not IsValid( ply ) then timer.Remove( timerName ) return end

		local first = ( i - 1 ) * SAVE_COVER_PART_BYTES + 1
		local chunk = string.sub( data, first, first + SAVE_COVER_PART_BYTES - 1 )
		net.Start( "mc_save_cover_download_part" )
			net.WriteString( cover )
			net.WriteUInt( i, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.Send( ply )
		i = i + 1
	end )
end

net.Receive( "mc_save_cover_begin", function( _, ply )
	local slotName = SV.SaveSlotName( net.ReadString() )
	local rawCover = net.ReadString()
	local expectedParts = net.ReadUInt( 16 )
	local totalBytes = net.ReadUInt( 32 )
	if not canUseSaves( ply ) then sendSaveCoverAck( ply, rawCover, false, "permission" ) return end
	if not slotName then sendSaveCoverAck( ply, rawCover, false, "invalid_slot" ) return end

	local cover = sanitizeSaveCover( rawCover, slotName )
	if not cover or expectedParts < 1 or totalBytes < 1 or totalBytes > MAX_SAVE_COVER_BYTES then
		sendSaveCoverAck( ply, rawCover, false, "invalid_upload" )
		return
	end
	if expectedParts ~= math.ceil( totalBytes / SAVE_COVER_PART_BYTES ) then
		sendSaveCoverAck( ply, rawCover, false, "invalid_part_count" )
		return
	end
	if not saveCoverBelongsToSlot( cover, slotName ) then cover = SV.SaveCoverPath( slotName ) end

	local upload = {
		slotName = slotName,
		cover = cover,
		expectedParts = expectedParts,
		totalBytes = totalBytes,
		receivedBytes = 0,
		receivedParts = 0,
		parts = {},
	}
	SaveCoverUploads[ply] = upload
	timer.Simple( SAVE_COVER_UPLOAD_TIMEOUT, function()
		if SaveCoverUploads[ply] == upload then failSaveCoverUpload( ply, upload, "timeout" ) end
	end )
end )

net.Receive( "mc_save_cover_part", function( _, ply )
	local upload = SaveCoverUploads[ply]
	if not upload then return end

	local cover = sanitizeSaveCover( net.ReadString(), upload.slotName )
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	if cover ~= upload.cover or index < 1 or index > upload.expectedParts then failSaveCoverUpload( ply, upload, "invalid_part" ) return end
	if len < 1 or len > SAVE_COVER_PART_BYTES or not chunk or #chunk ~= len then failSaveCoverUpload( ply, upload, "invalid_part" ) return end
	if upload.parts[index] then return end

	upload.parts[index] = chunk
	upload.receivedParts = upload.receivedParts + 1
	upload.receivedBytes = upload.receivedBytes + len
	if upload.receivedBytes > upload.totalBytes or upload.receivedBytes > MAX_SAVE_COVER_BYTES then
		failSaveCoverUpload( ply, upload, "too_large" )
		return
	end

	if upload.receivedParts < upload.expectedParts then return end

	local data = table.concat( upload.parts )
	SaveCoverUploads[ply] = nil
	if #data ~= upload.totalBytes then sendSaveCoverAck( ply, upload.cover, false, "size_mismatch" ) return end
	if not isJPEGData( data ) then sendSaveCoverAck( ply, upload.cover, false, "invalid_jpeg" ) return end

	ensureSaveDirs()
	file.Write( upload.cover, data )
	if not file.Exists( upload.cover, "DATA" ) or file.Size( upload.cover, "DATA" ) ~= #data then
		sendSaveCoverAck( ply, upload.cover, false, "write_failed" )
		return
	end
	SV.DeleteSaveCovers( upload.slotName, upload.cover )
	sendSaveCoverAck( ply, upload.cover, true )
end )

net.Receive( "mc_save_cover_req", function( _, ply )
	if not canUseSaves( ply ) then return end
	sendSaveCoverToClient( ply, net.ReadString() )
end )

hook.Add( "PlayerDisconnected", "MC_ClearSaveCoverUpload", function( ply )
	SaveCoverUploads[ply] = nil
end )

local function sendSaveList( ply, message, isError, saves )
	if not IsValid( ply ) then return end
	saves = saves or SV.SaveList()
	local count, estimatedBytes = 0, 32 + #tostring( message or "" )
	for index = 1, math.min( #saves, MAX_NET_SAVES ) do
		local save = saves[index]
		local rowBytes = 24
			+ #tostring( save.name or "" )
			+ #tostring( save.key or "" )
			+ #tostring( save.map or "" )
			+ #tostring( save.savedAtText or "" )
			+ #tostring( save.cover or "" )
			+ #tostring( save.source or "" )
			+ #tostring( save.workshopId or "" )
		if estimatedBytes + rowBytes > SAVE_LIST_NET_BUDGET then break end
		estimatedBytes = estimatedBytes + rowBytes
		count = index
	end
	local function uint32( value )
		return math.floor( math.Clamp( tonumber( value ) or 0, 0, 4294967295 ) )
	end
	net.Start( "mc_save_list_data" )
		net.WriteString( message or "" )
		net.WriteBool( isError == true )
		net.WriteUInt( count, 12 )
		for i = 1, count do
			local save = saves[i]
			net.WriteString( tostring( save.name or "" ) )
			net.WriteString( tostring( save.key or save.name or "" ) )
			net.WriteString( tostring( save.map or "unknown" ) )
			net.WriteUInt( uint32( save.blocks ), 32 )
			net.WriteUInt( uint32( save.chunks ), 32 )
			net.WriteString( tostring( save.savedAtText or "?" ) )
			net.WriteString( tostring( save.cover or "" ) )
			net.WriteString( tostring( save.source or "local" ) )
			net.WriteString( tostring( save.workshopId or "" ) )
		end
	net.Send( ply )
end

SV.SendSaveList = sendSaveList

concommand.Add( "mc_save", function( ply, _, args )
	if not canUseSaves( ply ) then printSaveUseDenied( ply ) return end
	SV.Save( saveCommandName( args ) )
end )

local function runSaveListCommand( ply )
	if not canUseSaves( ply ) then printSaveUseDenied( ply ) return end
	local saves = SV.SaveList()
	if #saves == 0 then
		printSaveManagerLine( ply, "[MC] no named saves in DATA:mc/saves, DATA:mc/workshop_saves, or GAME:data_static/mc/saves" )
		return
	end
	printSaveManagerLine( ply, "[MC] named saves:" )
	for _, save in ipairs( saves ) do
		printSaveManagerLine( ply, string.format(
			"[MC] %s | map=%s | blocks=%d | chunks=%d | saved=%s",
			tostring( save.name ), tostring( save.map ), save.blocks or 0, save.chunks or 0, tostring( save.savedAtText )
		) )
	end
end

concommand.Add( "mc_save_list", runSaveListCommand )
concommand.Add( "mc_saves", runSaveListCommand )

concommand.Add( "mc_load_save", function( ply, _, args )
	if not canUseSaves( ply ) then printSaveUseDenied( ply ) return end
	local ok, err = SV.LoadSave( saveCommandName( args ), true )
	if not ok then printSaveManagerLine( ply, "[MC] load save failed: " .. tostring( err ) ) end
end )

concommand.Add( "mc_delete_save", function( ply, _, args )
	if not canDeleteSaves( ply ) then printSaveDeleteDenied( ply ) return end
	local ok, err = SV.DeleteSave( saveCommandName( args ) )
	if not ok then printSaveManagerLine( ply, "[MC] delete save failed: " .. tostring( err ) ) end
end )

net.Receive( "mc_save_list_req", function( _, ply )
	if not canUseSaves( ply ) then
		sendSaveList( ply, L( ply, "server.save_admin_list" ), true, {} )
		return
	end
	sendSaveList( ply )
end )

net.Receive( "mc_save_action", function( _, ply )
	local action = string.lower( net.ReadString() or "" )
	local slotName = net.ReadString()
	local cover = ""
	if net.BytesLeft() > 0 then
		cover = net.ReadString()
	end

	local ok, err
	if action == "save" then
		if not canUseSaves( ply ) then
			sendSaveList( ply, L( ply, "server.save_admin_save" ), true, {} )
			return
		end
		ok, err = SV.SaveNamed( slotName, cover )
	elseif action == "load" then
		if not canUseSaves( ply ) then
			sendSaveList( ply, L( ply, "server.save_admin_load" ), true, {} )
			return
		end
		ok, err = SV.LoadSave( slotName, true )
	elseif action == "delete" then
		if not canDeleteSaves( ply ) then
			sendSaveList( ply, L( ply, "server.save_admin_delete" ), true, SV.SaveList() )
			return
		end
		ok, err = SV.DeleteSave( slotName )
	else
		ok, err = false, "unknown_action"
	end

	if ok then
		sendSaveList( ply, L( ply, "server.action_done", { action = action } ) )
	else
		sendSaveList( ply, L( ply, "server.action_failed", { err = tostring( err ) } ), true )
	end
end )
