--[[----------------------------------------------------------------------------
	MC : server save manager.

	Named save slots, metadata, console commands, and Derma UI net bridge live
	here so sv_world.lua can stay focused on voxel storage and world mutation.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config

local function L( ply, key, fallback, vars )
	return MC.TFor and MC.TFor( ply, key, fallback, vars ) or fallback
end

local SAVE_DIR = "mc"
local SAVE_SLOT_DIR = "mc/saves"
local SAVE_COVER_DIR = "mc/save_covers"
local MAX_NET_SAVES = 4095
local SAVE_COVER_PART_BYTES = 60000
local MAX_SAVE_COVER_BYTES = 1024 * 1024 * 2
local SAVE_PUBLIC_HELP = "Allow non-admin players to list/load/save MC saves; delete remains admin-only"

local function ensureSaveDirs()
	file.CreateDir( SAVE_DIR )
	file.CreateDir( SAVE_SLOT_DIR )
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
	return SAVE_SLOT_DIR .. "/" .. slotName .. ".dat"
end

function SV.SaveMetaPath( slotName )
	return SAVE_SLOT_DIR .. "/" .. slotName .. ".json"
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

local function writeSaveMeta( slotName, path, data, chunks, blocks, cover )
	ensureSaveDirs()
	local savedAt = data.savedAt or os.time()
	local meta = {
		v = 1,
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
	}
	local json = util.TableToJSON( meta, true )
	if json then file.Write( SV.SaveMetaPath( slotName ), json ) end
end

local function readSaveMeta( slotName )
	local raw = file.Read( SV.SaveMetaPath( slotName ), "DATA" )
	return raw and util.JSONToTable( raw ) or nil
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

local function readSaveJSON( path )
	local raw = file.Read( path, "DATA" )
	if not raw or raw == "" then return nil end
	if string.sub( raw, 1, 1 ) == "{" then
		return util.JSONToTable( raw )
	end
	local json = util.Decompress( raw )
	return json and util.JSONToTable( json ) or nil
end

local function readSaveDataSummary( slotName, path )
	local data = readSaveJSON( path )
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

local function writeMetaTable( slotName, meta )
	local json = util.TableToJSON( meta, true )
	if json then file.Write( SV.SaveMetaPath( slotName ), json ) end
end

local function saveMetaComplete( meta )
	return meta
		and meta.map ~= nil and meta.map ~= "" and meta.map ~= "unknown"
		and meta.savedAtText ~= nil and meta.savedAtText ~= ""
		and meta.blocks ~= nil
		and meta.chunks ~= nil
end

local function readSaveListMeta( slotName, path )
	local meta = readSaveMeta( slotName ) or {}
	if saveMetaComplete( meta ) then
		meta.name = meta.name or slotName
		meta.path = meta.path or path
		return meta
	end

	local summary = readSaveDataSummary( slotName, path )
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
	writeMetaTable( slotName, meta )
	return meta
end

function SV.SaveNamed( slotName, cover )
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return false, "missing_save_name" end
	ensureSaveDirs()
	local ok, path, data, chunks, blocks = SV.SaveToPath( SV.SaveSlotPath( slotName ), slotName )
	if ok then writeSaveMeta( slotName, path, data, chunks, blocks, cover ) end
	return ok, path
end

function SV.LoadSave( slotName, resyncClients )
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return false, "missing_save_name" end
	return SV.LoadFromPath( SV.SaveSlotPath( slotName ), resyncClients, slotName )
end

function SV.DeleteSave( slotName )
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return false, "missing_save_name" end
	local path = SV.SaveSlotPath( slotName )
	if not file.Exists( path, "DATA" ) then return false, "save_not_found" end
	file.Delete( path )
	file.Delete( SV.SaveMetaPath( slotName ) )
	SV.DeleteSaveCovers( slotName )
	MsgN( "[MC] deleted save \"" .. slotName .. "\"" )
	return true
end

function SV.SaveList()
	ensureSaveDirs()
	local files = file.Find( SAVE_SLOT_DIR .. "/*.dat", "DATA" ) or {}
	local out = {}
	for _, fn in ipairs( files ) do
		local slotName = string.gsub( fn, "%.dat$", "" )
		local path = SAVE_SLOT_DIR .. "/" .. fn
		local meta = readSaveListMeta( slotName, path )
		out[#out + 1] = {
			name = meta.name or slotName,
			map = meta.map or "unknown",
			blocks = math.floor( tonumber( meta.blocks ) or 0 ),
			chunks = math.floor( tonumber( meta.chunks ) or 0 ),
			savedAtText = meta.savedAtText or "?",
			cover = sanitizeSaveCover( meta.cover, slotName ) or "",
			path = path,
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

local function printSaveUseDenied( ply )
	printSaveManagerLine( ply, "[MC] only admins may list/load/save MC saves (set mc_save_public 1 to allow everyone)" )
end

local function printSaveDeleteDenied( ply )
	printSaveManagerLine( ply, "[MC] only admins may delete MC saves" )
end

local SaveCoverUploads = {}

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
	timer.Create( timerName, 0.01, parts, function()
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
	if not canUseSaves( ply ) then return end

	local slotName = SV.SaveSlotName( net.ReadString() )
	if not slotName then return end

	local cover = sanitizeSaveCover( net.ReadString(), slotName )
	local expectedParts = net.ReadUInt( 16 )
	local totalBytes = net.ReadUInt( 32 )
	if not cover or expectedParts < 1 or totalBytes < 1 or totalBytes > MAX_SAVE_COVER_BYTES then return end
	if not saveCoverBelongsToSlot( cover, slotName ) then cover = SV.SaveCoverPath( slotName ) end

	SaveCoverUploads[ply] = {
		slotName = slotName,
		cover = cover,
		expectedParts = expectedParts,
		totalBytes = totalBytes,
		receivedBytes = 0,
		receivedParts = 0,
		parts = {},
	}
end )

net.Receive( "mc_save_cover_part", function( _, ply )
	local upload = SaveCoverUploads[ply]
	if not upload then return end

	local cover = sanitizeSaveCover( net.ReadString(), upload.slotName )
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	if cover ~= upload.cover or index < 1 or index > upload.expectedParts then return end
	if len < 1 or len > SAVE_COVER_PART_BYTES or not chunk or #chunk ~= len then return end
	if upload.parts[index] then return end

	upload.parts[index] = chunk
	upload.receivedParts = upload.receivedParts + 1
	upload.receivedBytes = upload.receivedBytes + len
	if upload.receivedBytes > upload.totalBytes or upload.receivedBytes > MAX_SAVE_COVER_BYTES then
		SaveCoverUploads[ply] = nil
		return
	end

	if upload.receivedParts < upload.expectedParts then return end

	local data = table.concat( upload.parts )
	SaveCoverUploads[ply] = nil
	if #data ~= upload.totalBytes then return end

	ensureSaveDirs()
	file.Write( upload.cover, data )
	SV.DeleteSaveCovers( upload.slotName, upload.cover )
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
	local count = math.min( #saves, MAX_NET_SAVES )
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
			net.WriteString( tostring( save.map or "unknown" ) )
			net.WriteUInt( uint32( save.blocks ), 32 )
			net.WriteUInt( uint32( save.chunks ), 32 )
			net.WriteString( tostring( save.savedAtText or "?" ) )
			net.WriteString( tostring( save.cover or "" ) )
		end
	net.Send( ply )
end

concommand.Add( "mc_save", function( ply, _, args )
	if not canUseSaves( ply ) then printSaveUseDenied( ply ) return end
	SV.Save( saveCommandName( args ) )
end )

local function runSaveListCommand( ply )
	if not canUseSaves( ply ) then printSaveUseDenied( ply ) return end
	local saves = SV.SaveList()
	if #saves == 0 then
		printSaveManagerLine( ply, "[MC] no named saves in data/mc/saves" )
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
		sendSaveList( ply, L( ply, "server.save_admin_list", "只有管理员可以读取/保存存档 (mc_save_public 0)" ), true, {} )
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
			sendSaveList( ply, L( ply, "server.save_admin_save", "只有管理员可以保存存档 (mc_save_public 0)" ), true, {} )
			return
		end
		ok, err = SV.SaveNamed( slotName, cover )
	elseif action == "load" then
		if not canUseSaves( ply ) then
			sendSaveList( ply, L( ply, "server.save_admin_load", "只有管理员可以读取存档 (mc_save_public 0)" ), true, {} )
			return
		end
		ok, err = SV.LoadSave( slotName, true )
	elseif action == "delete" then
		if not canDeleteSaves( ply ) then
			sendSaveList( ply, L( ply, "server.save_admin_delete", "只有管理员可以删除存档" ), true, SV.SaveList() )
			return
		end
		ok, err = SV.DeleteSave( slotName )
	else
		ok, err = false, "unknown_action"
	end

	if ok then
		sendSaveList( ply, L( ply, "server.action_done", "操作完成: {action}", { action = action } ) )
	else
		sendSaveList( ply, L( ply, "server.action_failed", "操作失败: {err}", { err = tostring( err ) } ), true )
	end
end )
