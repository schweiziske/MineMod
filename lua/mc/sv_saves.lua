--[[----------------------------------------------------------------------------
	MC : server save manager.

	Named save slots, metadata, console commands, and Derma UI net bridge live
	here so sv_world.lua can stay focused on voxel storage and world mutation.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config

local SAVE_DIR = "mc"
local SAVE_SLOT_DIR = "mc/saves"
local MAX_NET_SAVES = 4095
local SAVE_PUBLIC_HELP = "Allow non-admin players to list/load/save MC saves; delete remains admin-only"

local function ensureSaveDirs()
	file.CreateDir( SAVE_DIR )
	file.CreateDir( SAVE_SLOT_DIR )
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

local function writeSaveMeta( slotName, path, data, chunks, blocks )
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

local function readSaveDataSummary( slotName, path )
	local raw = file.Read( path, "DATA" )
	local json = raw and util.Decompress( raw )
	local data = json and util.JSONToTable( json )
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
	writeMetaTable( slotName, meta )
	return meta
end

function SV.SaveNamed( slotName )
	slotName = SV.SaveSlotName( slotName )
	if not slotName then return false, "missing_save_name" end
	ensureSaveDirs()
	local ok, path, data, chunks, blocks = SV.SaveToPath( SV.SaveSlotPath( slotName ), slotName )
	if ok then writeSaveMeta( slotName, path, data, chunks, blocks ) end
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
		sendSaveList( ply, "只有管理员可以读取/保存存档 (mc_save_public 0)", true, {} )
		return
	end
	sendSaveList( ply )
end )

net.Receive( "mc_save_action", function( _, ply )
	local action = string.lower( net.ReadString() or "" )
	local slotName = net.ReadString()

	local ok, err
	if action == "save" then
		if not canUseSaves( ply ) then
			sendSaveList( ply, "只有管理员可以保存存档 (mc_save_public 0)", true, {} )
			return
		end
		ok, err = SV.Save( slotName )
	elseif action == "load" then
		if not canUseSaves( ply ) then
			sendSaveList( ply, "只有管理员可以读取存档 (mc_save_public 0)", true, {} )
			return
		end
		ok, err = SV.LoadSave( slotName, true )
	elseif action == "delete" then
		if not canDeleteSaves( ply ) then
			sendSaveList( ply, "只有管理员可以删除存档", true, SV.SaveList() )
			return
		end
		ok, err = SV.DeleteSave( slotName )
	else
		ok, err = false, "unknown_action"
	end

	if ok then
		sendSaveList( ply, "操作完成: " .. action )
	else
		sendSaveList( ply, "操作失败: " .. tostring( err ), true )
	end
end )
