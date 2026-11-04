--[[----------------------------------------------------------------------------
	MC : server preset manager.

	Presets are saved selections of voxel cells. The server always captures from
	the authoritative voxel store and places through the world mutation API.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config
local Net = MC.Net

-- Translated with this server's files for the player's language.
local function L( ply, key, vars )
	return MC.I18n.Resolve( key, vars, MC.I18n.LanguageForPlayer( ply ) )
end

local PRESET_DIR = "mc/presets"
local PRESET_META_DIR = "mc/preset_meta"
local PRESET_COVER_DIR = "mc/preset_covers"
local PRESET_DATA_PART_BYTES = 16384
local PRESET_COVER_PART_BYTES = 16384
local PRESET_DOWNLOAD_PART_INTERVAL = 0.05
local PRESET_COVER_UPLOAD_TIMEOUT = 20
local PRESET_PLACE_COOLDOWN = 0.35
local PRESET_BULK_CELLS_PER_MESSAGE = 512
local MAX_PRESET_DATA_BYTES = 1024 * 1024 * 4
local MAX_PRESET_COVER_BYTES = 1024 * 1024 * 2
local MAX_NET_PRESETS = 4095
local PRESET_PUBLIC_HELP = "Allow non-admin players to list/load/save/place MC presets"

local PresetCoverUploads = {}
-- presetName -> { fileTime, data, payload }: decompressing + JSON-parsing a
-- large preset is expensive, so parsed presets (and their ready-to-send net
-- payload) are reused until the .dat on disk changes
local PresetCache = {}

local function ensurePresetDirs()
	file.CreateDir( "mc" )
	file.CreateDir( PRESET_DIR )
	file.CreateDir( PRESET_META_DIR )
	file.CreateDir( PRESET_COVER_DIR )
end

local function trim( value )
	return string.Trim( tostring( value or "" ) )
end

function SV.PresetName( name )
	name = trim( name )
	if name == "" then return nil end
	name = string.gsub( name, "[%c/\\:%*%?\"<>|]", "_" )
	name = string.gsub( name, "%.%.+", "_" )
	name = string.gsub( name, "^%.+", "" )
	name = trim( string.sub( name, 1, 64 ) )
	if name == "" then return nil end
	return name
end

function SV.PresetPath( presetName )
	return PRESET_DIR .. "/" .. presetName .. ".dat"
end

function SV.PresetMetaPath( presetName )
	return PRESET_META_DIR .. "/" .. presetName .. ".json"
end

function SV.PresetCoverPath( presetName )
	return PRESET_COVER_DIR .. "/" .. presetName .. ".jpg"
end

local function sanitizePresetCover( cover, presetName )
	cover = trim( cover )
	if cover == "" then return nil end
	cover = string.gsub( cover, "\\", "/" )
	cover = string.gsub( cover, "%.%.+", "_" )
	if not string.StartWith( cover, PRESET_COVER_DIR .. "/" ) then
		return SV.PresetCoverPath( presetName )
	end
	cover = string.gsub( cover, "[%c:%*%?\"<>|]", "_" )
	return string.sub( cover, 1, 180 )
end

local function sanitizePresetCoverReadPath( cover )
	cover = trim( cover )
	if cover == "" then return nil end
	cover = string.gsub( cover, "\\", "/" )
	cover = string.gsub( cover, "%.%.+", "_" )
	if not string.StartWith( cover, PRESET_COVER_DIR .. "/" ) then return nil end
	cover = string.gsub( cover, "[%c:%*%?\"<>|]", "_" )
	return string.sub( cover, 1, 180 )
end

local function presetCoverBelongsToPreset( cover, presetName )
	local base = PRESET_COVER_DIR .. "/" .. presetName
	return cover == base .. ".jpg" or string.StartWith( cover, base .. "_" )
end

local function deletePresetCovers( presetName, keepPath )
	presetName = SV.PresetName( presetName )
	if not presetName then return end

	local function deletePath( path )
		if path == keepPath then return end
		if file.Exists( path, "DATA" ) then file.Delete( path ) end
	end

	deletePath( SV.PresetCoverPath( presetName ) )

	local files = file.Find( PRESET_COVER_DIR .. "/" .. presetName .. "_*.jpg", "DATA" ) or {}
	for _, fn in ipairs( files ) do
		deletePath( PRESET_COVER_DIR .. "/" .. fn )
	end
end

local function presetPublicConVar()
	if not C.PresetPublic then
		C.PresetPublic = GetConVar( "mc_preset_public" ) or CreateConVar( "mc_preset_public", "0", bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED ), PRESET_PUBLIC_HELP )
	end
	return C.PresetPublic
end

local function canUsePresets( ply )
	return not IsValid( ply ) or ply:IsAdmin() or presetPublicConVar():GetBool()
end

local function canEditPresets( ply )
	if not canUsePresets( ply ) then
		if IsValid( ply ) then ply:ChatPrint( "[MC] " .. L( ply, "server.preset_admin" ) ) end
		return false
	end
	if C.AdminOnly and C.AdminOnly:GetBool() and IsValid( ply ) and not ply:IsAdmin() then
		ply:ChatPrint( "[MC] " .. L( ply, "server.preset_edit_admin" ) )
		return false
	end
	return true
end

local function sendPresetCoverAck( ply, cover, ok, err )
	if not IsValid( ply ) then return end
	net.Start( "mc_preset_cover_ack" )
		net.WriteString( tostring( cover or "" ) )
		net.WriteBool( ok == true )
		net.WriteString( tostring( err or "" ) )
	net.Send( ply )
end

local function failPresetCoverUpload( ply, upload, err )
	if PresetCoverUploads[ply] == upload then PresetCoverUploads[ply] = nil end
	sendPresetCoverAck( ply, upload and upload.cover or "", false, err )
end

local function isJPEGData( data )
	return isstring( data ) and #data >= 4 and string.byte( data, 1 ) == 255 and string.byte( data, 2 ) == 216
end

local function presetPlaceCooldownOK( ply )
	if not IsValid( ply ) then return true end
	local now = CurTime()
	if ( ply.mcNextPresetPlace or 0 ) > now then return false end
	ply.mcNextPresetPlace = now + PRESET_PLACE_COOLDOWN
	return true
end

local function worldBoundsOK( bx, by, bz )
	local protoMax = bit.lshift( 1, Net.COORD_BITS - 1 ) - 1
	local lim = math.min( C.WorldLimit:GetInt(), protoMax )
	return math.abs( bx ) <= lim and math.abs( by ) <= lim
end

local function presetMaxBlocks()
	if C.PresetMaxBlocks then return math.max( 0, C.PresetMaxBlocks:GetInt() ) end
	return 8192
end

local function asCell( value )
	if not istable( value ) then return nil end
	return {
		bx = math.floor( tonumber( value.bx ) or 0 ),
		by = math.floor( tonumber( value.by ) or 0 ),
		bz = math.floor( tonumber( value.bz ) or 0 ),
	}
end

local function normalComponent( value )
	value = math.floor( tonumber( value ) or 0 )
	if value > 0 then return 1 end
	if value < 0 then return -1 end
	return 0
end

local function asAnchor( value )
	if not istable( value ) then return nil end
	local out = asCell( value )
	if not out then return nil end
	out.nx = normalComponent( value.nx )
	out.ny = normalComponent( value.ny )
	out.nz = normalComponent( value.nz )
	if out.nx == 0 and out.ny == 0 and out.nz == 0 then out.nz = 1 end
	return out
end

local function presetPayloadToJSON( data )
	local json = util.TableToJSON( data )
	if not json or json == "" then return nil end
	local compressed = util.Compress( json )
	if not compressed or compressed == "" then return nil end
	return compressed
end

local function writePresetMeta( presetName, data )
	local meta = {
		v = 1,
		name = presetName,
		map = data.map or game.GetMap(),
		createdAt = data.createdAt,
		createdAtText = data.createdAtText,
		blocks = data.blocks or ( istable( data.cells ) and #data.cells or 0 ),
		size = data.size,
		cover = sanitizePresetCover( data.cover, presetName ) or "",
	}
	local json = util.TableToJSON( meta, true )
	if json then file.Write( SV.PresetMetaPath( presetName ), json ) end
end

local function readPresetMeta( presetName )
	local raw = file.Read( SV.PresetMetaPath( presetName ), "DATA" )
	return raw and util.JSONToTable( raw ) or nil
end

function SV.LoadPreset( presetName )
	presetName = SV.PresetName( presetName )
	if not presetName then return nil, "missing_preset_name" end

	local path = SV.PresetPath( presetName )
	if not file.Exists( path, "DATA" ) then
		PresetCache[presetName] = nil
		return nil, "preset_not_found"
	end

	local fileTime = file.Time( path, "DATA" ) or 0
	local cached = PresetCache[presetName]
	if cached and cached.fileTime == fileTime then
		return cached.data, nil, cached
	end

	local raw = file.Read( path, "DATA" )
	if not raw or raw == "" then return nil, "empty_preset" end
	local json = raw
	local payload = raw
	if string.sub( raw, 1, 1 ) ~= "{" then
		json = util.Decompress( raw )
	else
		payload = util.Compress( raw )
	end
	if not json then return nil, "decompress_failed" end
	local data = util.JSONToTable( json )
	if not data or not istable( data.cells ) then return nil, "invalid_preset" end
	data.name = data.name or presetName
	data.cover = sanitizePresetCover( data.cover, presetName ) or ""
	cached = { fileTime = fileTime, data = data, payload = payload }
	PresetCache[presetName] = cached
	return data, nil, cached
end

function SV.PresetList()
	ensurePresetDirs()
	local files = file.Find( PRESET_DIR .. "/*.dat", "DATA" ) or {}
	local out = {}
	for _, fn in ipairs( files ) do
		local presetName = string.gsub( fn, "%.dat$", "" )
		local meta = readPresetMeta( presetName )
		if not meta or not meta.blocks or not meta.size then
			local data = SV.LoadPreset( presetName )
			if data then
				meta = {
					name = presetName,
					map = data.map or "unknown",
					createdAt = data.createdAt,
					createdAtText = data.createdAtText or "?",
					blocks = data.blocks or #data.cells,
					size = data.size,
					cover = sanitizePresetCover( data.cover, presetName ) or "",
				}
				writePresetMeta( presetName, data )
			end
		end
		if meta then
			out[#out + 1] = {
				name = meta.name or presetName,
				map = meta.map or "unknown",
				createdAtText = meta.createdAtText or "?",
				blocks = math.floor( tonumber( meta.blocks ) or 0 ),
				size = meta.size or { 0, 0, 0 },
				cover = sanitizePresetCover( meta.cover, presetName ) or "",
			}
		end
	end
	table.sort( out, function( a, b ) return tostring( a.name ) < tostring( b.name ) end )
	return out
end

function SV.SavePreset( presetName, cornerA, cornerB, anchor, cover, ply )
	if not canEditPresets( ply ) then return false, "permission" end

	presetName = SV.PresetName( presetName )
	if not presetName then return false, "missing_preset_name" end
	cornerA = asCell( cornerA )
	cornerB = asCell( cornerB )
	anchor = asAnchor( anchor )
	if not cornerA or not cornerB or not anchor then return false, "invalid_selection" end

	local minx, maxx = math.min( cornerA.bx, cornerB.bx ), math.max( cornerA.bx, cornerB.bx )
	local miny, maxy = math.min( cornerA.by, cornerB.by ), math.max( cornerA.by, cornerB.by )
	local minz, maxz = math.min( cornerA.bz, cornerB.bz ), math.max( cornerA.bz, cornerB.bz )
	if anchor.bx < minx or anchor.bx > maxx or anchor.by < miny or anchor.by > maxy or anchor.bz < minz or anchor.bz > maxz then
		return false, "anchor_outside_selection"
	end

	local volume = ( maxx - minx + 1 ) * ( maxy - miny + 1 ) * ( maxz - minz + 1 )
	local maxPreset = presetMaxBlocks()
	if maxPreset > 0 and volume > maxPreset then return false, "selection_too_large" end

	local cells = {}
	for z = minz, maxz do
		for y = miny, maxy do
			for x = minx, maxx do
				local stateId = MC.GetBlockState( x, y, z )
				local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or MC.GetBlock( x, y, z )
				if stateId and stateId ~= 0 and id and id ~= 0 then
					local stateSpec = MC.FormatBlockState and MC.FormatBlockState( stateId ) or nil
					if not stateSpec then return false, "state_encode_failed" end
					cells[#cells + 1] = {
						x - minx,
						y - miny,
						z - minz,
						id,
						MC.GetBlockOrient( x, y, z ) or 0,
						stateSpec,
					}
					if maxPreset > 0 and #cells > maxPreset then return false, "preset_too_large" end
				end
			end
		end
	end
	if #cells == 0 then return false, "empty_selection" end

	ensurePresetDirs()
	local now = os.time()
	local data = {
		v = 2,
		name = presetName,
		map = game.GetMap(),
		createdAt = now,
		createdAtText = os.date( "%Y-%m-%d %H:%M:%S", now ),
		bs = MC.BS,
		size = { maxx - minx + 1, maxy - miny + 1, maxz - minz + 1 },
		anchor = { anchor.bx - minx, anchor.by - miny, anchor.bz - minz, anchor.nx, anchor.ny, anchor.nz },
		blocks = #cells,
		cells = cells,
		cover = sanitizePresetCover( cover, presetName ) or "",
		-- Rotation is applied at placement time around this saved anchor.
		rotation = "quarter_turn_z",
	}

	local compressed = presetPayloadToJSON( data )
	if not compressed then return false, "encode_failed" end
	if #compressed > MAX_PRESET_DATA_BYTES then return false, "preset_payload_too_large" end

	file.Write( SV.PresetPath( presetName ), compressed )
	-- prime the cache directly: file.Time has 1s resolution, so a same-second
	-- overwrite could otherwise keep serving the stale parsed preset
	PresetCache[presetName] = {
		fileTime = file.Time( SV.PresetPath( presetName ), "DATA" ) or 0,
		data = data,
		payload = compressed,
	}
	writePresetMeta( presetName, data )
	MsgN( string.format( "[MC] saved preset \"%s\" (%d blocks, %dx%dx%d)", presetName, #cells, data.size[1], data.size[2], data.size[3] ) )
	if MC.RunEvent then MC.RunEvent( "MC.PresetSaved", presetName, ply ) end
	return true, data
end

-- Delete a preset (.dat + meta + covers) and drop its cache entry.
function SV.DeletePreset( presetName )
	presetName = SV.PresetName( presetName )
	if not presetName then return false, "missing_preset_name" end
	local path = SV.PresetPath( presetName )
	if not file.Exists( path, "DATA" ) then return false, "preset_not_found" end
	file.Delete( path )
	local metaPath = SV.PresetMetaPath( presetName )
	if file.Exists( metaPath, "DATA" ) then file.Delete( metaPath ) end
	deletePresetCovers( presetName )
	PresetCache[presetName] = nil
	MsgN( "[MC] deleted preset \"" .. presetName .. "\"" )
	if MC.RunEvent then MC.RunEvent( "MC.PresetDeleted", presetName ) end
	return true
end

local function presetCellTable( data, origin, rotation )
	if MC.PresetCells then return MC.PresetCells( data, origin, rotation ) end

	local out = {}
	for _, cell in ipairs( data.cells or {} ) do
		local dx = math.floor( tonumber( cell[1] ) or 0 )
		local dy = math.floor( tonumber( cell[2] ) or 0 )
		local dz = math.floor( tonumber( cell[3] ) or 0 )
		local id = math.floor( tonumber( cell[4] ) or 0 )
		local orient = MC.NormalizeOrient( id, cell[5] )
		out[#out + 1] = {
			bx = origin.bx + dx,
			by = origin.by + dy,
			bz = origin.bz + dz,
			id = id,
			orient = orient,
		}
	end
	return out
end

local function presetSize( data )
	local size = data and data.size or {}
	local sx = math.max( 0, math.floor( tonumber( size[1] ) or 0 ) )
	local sy = math.max( 0, math.floor( tonumber( size[2] ) or 0 ) )
	local sz = math.max( 0, math.floor( tonumber( size[3] ) or 0 ) )
	return sx, sy, sz, sx * sy * sz
end

local function presetClearCells( data, origin, rotation )
	if MC.PresetClearCells then
		return MC.PresetClearCells( data, origin, rotation )
	end

	local out = {}
	local sx, sy, sz = presetSize( data )
	for dz = 0, sz - 1 do
		for dy = 0, sy - 1 do
			for dx = 0, sx - 1 do
				local bx = origin.bx + dx
				local by = origin.by + dy
				local bz = origin.bz + dz
				if MC.GetBlock( bx, by, bz ) ~= 0 then
					out[#out + 1] = { bx = bx, by = by, bz = bz }
				end
			end
		end
	end
	return out
end

local function validatePresetData( ply, data )
	if not canEditPresets( ply ) then return false, "permission" end
	if not data or not data.anchor then return false, "invalid_preset" end
	local maxPreset = presetMaxBlocks()
	local _, _, _, volume = presetSize( data )
	if maxPreset > 0 and volume > maxPreset then return false, "preset_too_large" end
	if maxPreset > 0 and #( data.cells or {} ) > maxPreset then return false, "preset_too_large" end
	return true
end

local function presetStateCells( data, origin, rotation )
	local transformed = presetCellTable( data, origin, rotation )
	local out = {}
	for _, cell in ipairs( transformed ) do
		if cell.stateError then return nil, cell.stateError end
		local stateId = cell.stateId
		if not stateId then
			local exact, err
			stateId, exact, err = MC.StateFromLegacy( cell.id, cell.orient )
			if not stateId or exact ~= true then return nil, err or "state_not_legacy_projectable" end
		end
		out[#out + 1] = {
			bx = cell.bx, by = cell.by, bz = cell.bz,
			stateId = stateId,
		}
	end
	return out
end

local function presetFinalCells( data, origin, overwrite, rotation )
	local placed, stateError = presetStateCells( data, origin, rotation )
	if not placed then return nil, stateError end
	if not overwrite then return placed end

	-- Insert preset blocks first so the placement FX still prefers a real block,
	-- then add air only for volume cells not occupied by the saved structure.
	local final, byKey = {}, {}
	local function setFinal( bx, by, bz, stateId, onlyIfMissing )
		local key = MC.CellKey( bx, by, bz )
		local index = byKey[key]
		if index then
			if not onlyIfMissing then final[index].stateId = stateId end
			return
		end
		byKey[key] = #final + 1
		final[#final + 1] = { bx = bx, by = by, bz = bz, stateId = stateId }
	end
	for _, cell in ipairs( placed ) do setFinal( cell.bx, cell.by, cell.bz, cell.stateId, false ) end
	for _, cell in ipairs( presetClearCells( data, origin, rotation ) ) do
		setFinal( cell.bx, cell.by, cell.bz, 0, true )
	end
	return final
end

local function validateFinalPresetCells( cells, overwrite )
	local blockDelta = 0
	for _, cell in ipairs( cells ) do
		if not worldBoundsOK( cell.bx, cell.by, cell.bz ) then return false, "out_of_bounds" end
		local oldStateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0
		if not overwrite and oldStateId ~= 0 then return false, "occupied" end
		if oldStateId == 0 and cell.stateId ~= 0 then blockDelta = blockDelta + 1 end
		if oldStateId ~= 0 and cell.stateId == 0 then blockDelta = blockDelta - 1 end
	end
	local maxBlocks = C.MaxBlocks and C.MaxBlocks:GetInt() or 0
	if maxBlocks > 0 and SV.BlockCount + blockDelta > maxBlocks then return false, "block_limit" end
	return true
end

function SV.PlacePreset( ply, presetName, origin, overwrite, rotation )
	overwrite = overwrite == true
	rotation = MC.PresetNormalizeRotation and MC.PresetNormalizeRotation( rotation ) or 0
	origin = asCell( origin )
	if not origin then return false, "invalid_origin" end
	if not presetPlaceCooldownOK( ply ) then return false, "preset_place_cooldown" end
	-- Same coarse gate as every other player edit path (admin convar plus the
	-- MC.CanPlayerEdit protection veto); console callers skip it.
	if IsValid( ply ) and SV.CanEdit and not SV.CanEdit( ply ) then return false, "permission" end
	local data, err = SV.LoadPreset( presetName )
	if not data then return false, err end

	local ok, validateErr = validatePresetData( ply, data )
	if not ok then return false, validateErr end
	local cells, cellsError = presetFinalCells( data, origin, overwrite, rotation )
	if not cells then return false, cellsError end
	for _, cell in ipairs( cells ) do
		if not worldBoundsOK( cell.bx, cell.by, cell.bz ) then return false, "out_of_bounds" end
	end

	local changed, bulkErr
	if SV.ApplyBlockHydrationTransaction then
		local result = SV.ApplyBlockHydrationTransaction( cells, {
			actor = ply,
			fx = true,
			fxIndex = 1,
			fxPreferPlaced = true,
			handlers = true,
			blockUpdates = true,
			maxBlockCount = C.MaxBlocks and C.MaxBlocks:GetInt() or 0,
			validateChange = function( info )
				if not overwrite and info.oldStateId ~= 0 then return false, "occupied" end
				return true
			end,
		} )
		if result.ok == true then
			changed = result.changed
		elseif result.error ~= "chunk_hydration_transport_unavailable" then
			return false, result.error or "preset_hydration_failed"
		end
	end
	if changed == nil and SV.SetBlocksBulk then
		local valid, fallbackError = validateFinalPresetCells( cells, overwrite )
		if not valid then return false, fallbackError end
		changed, bulkErr = SV.SetBlocksBulk( cells, {
			actor = ply,
			fx = true,
			fxIndex = 1,
			handlers = true,
			priorityPhys = false,
			deferPhys = true,
			netPaced = true,
			stateStream = true,
			cellsPerMessage = PRESET_BULK_CELLS_PER_MESSAGE,
		} )
	elseif changed == nil then
		return false, "bulk_api_unavailable"
	end

	local totalChanged = changed or 0
	if totalChanged <= 0 then return false, bulkErr or "unchanged" end
	if IsValid( ply ) then
		local key = overwrite and "server.preset_overwritten" or "server.preset_placed"
		ply:ChatPrint( "[MC] " .. L( ply, key, { name = tostring( data.name or presetName ), changes = totalChanged } ) )
	end
	if MC.RunEvent then
		MC.RunEvent( "MC.PresetPlaced", ply, tostring( data.name or presetName ),
			{ bx = origin.bx, by = origin.by, bz = origin.bz }, rotation, totalChanged, overwrite )
	end
	return true, totalChanged
end

local function sendPresetList( ply, message, isError, presets )
	if not IsValid( ply ) then return end
	presets = presets or SV.PresetList()
	local count = math.min( #presets, MAX_NET_PRESETS )
	net.Start( "mc_preset_list_data" )
		net.WriteString( message or "" )
		net.WriteBool( isError == true )
		net.WriteUInt( count, 12 )
		for i = 1, count do
			local preset = presets[i]
			local size = preset.size or {}
			net.WriteString( tostring( preset.name or "" ) )
			net.WriteString( tostring( preset.map or "unknown" ) )
			net.WriteUInt( math.Clamp( math.floor( tonumber( preset.blocks ) or 0 ), 0, 4294967295 ), 32 )
			net.WriteUInt( math.Clamp( math.floor( tonumber( size[1] ) or 0 ), 0, 65535 ), 16 )
			net.WriteUInt( math.Clamp( math.floor( tonumber( size[2] ) or 0 ), 0, 65535 ), 16 )
			net.WriteUInt( math.Clamp( math.floor( tonumber( size[3] ) or 0 ), 0, 65535 ), 16 )
			net.WriteString( tostring( preset.createdAtText or "?" ) )
			net.WriteString( tostring( preset.cover or "" ) )
		end
	net.Send( ply )
end

local function sendPresetDataError( ply, presetName, err )
	net.Start( "mc_preset_data" )
		net.WriteString( presetName or "" )
		net.WriteString( tostring( err or "error" ) )
		net.WriteBool( true )
		net.WriteUInt( 0, 16 )
		net.WriteUInt( 0, 32 )
	net.Send( ply )
end

local function sendPresetData( ply, presetName )
	if not IsValid( ply ) then return end
	local data, err, cached = SV.LoadPreset( presetName )
	if not data then sendPresetDataError( ply, presetName, err ) return end

	-- the .dat on disk is already the compressed JSON payload the client
	-- expects; reuse it instead of re-serializing + re-compressing per request
	local compressed = cached and cached.payload or nil
	if not compressed or compressed == "" then
		local json = util.TableToJSON( data )
		compressed = json and util.Compress( json ) or nil
	end
	if not compressed or compressed == "" or #compressed > MAX_PRESET_DATA_BYTES then
		sendPresetDataError( ply, presetName, "preset_payload_too_large" )
		return
	end

	local partBytes = SV.ReliableNetPayloadBytes
		and SV.ReliableNetPayloadBytes( 64, PRESET_DATA_PART_BYTES ) or PRESET_DATA_PART_BYTES
	local parts = math.ceil( #compressed / partBytes )
	net.Start( "mc_preset_data" )
		net.WriteString( data.name or presetName )
		net.WriteString( "" )
		net.WriteBool( false )
		net.WriteUInt( parts, 16 )
		net.WriteUInt( #compressed, 32 )
	net.Send( ply )

	for part = 1, parts do
		local partIndex = part
		local first = ( partIndex - 1 ) * partBytes + 1
		local len = math.min( partBytes, #compressed - first + 1 )
		SV.EnqueueReliableNet( ply, len + 64, function( target )
			local chunk = string.sub( compressed, first, first + len - 1 )
			net.Start( "mc_preset_data_part" )
				net.WriteString( data.name or presetName )
				net.WriteUInt( partIndex, 16 )
				net.WriteUInt( #chunk, 16 )
				net.WriteData( chunk, #chunk )
			net.Send( target )
			return true
		end )
	end
end

local function sendPresetCoverToClient( ply, cover )
	if not IsValid( ply ) then return end
	cover = sanitizePresetCoverReadPath( cover )
	if not cover or not file.Exists( cover, "DATA" ) then return end

	local data = file.Read( cover, "DATA" )
	if not data or data == "" or #data > MAX_PRESET_COVER_BYTES then return end

	local parts = math.ceil( #data / PRESET_COVER_PART_BYTES )
	local timerName = "MC_PresetCoverDownload_" .. ply:EntIndex() .. "_" .. util.CRC( cover )
	timer.Remove( timerName )

	net.Start( "mc_preset_cover_download_begin" )
		net.WriteString( cover )
		net.WriteUInt( parts, 16 )
		net.WriteUInt( #data, 32 )
	net.Send( ply )

	local i = 1
	timer.Create( timerName, PRESET_DOWNLOAD_PART_INTERVAL, parts, function()
		if not IsValid( ply ) then timer.Remove( timerName ) return end
		local first = ( i - 1 ) * PRESET_COVER_PART_BYTES + 1
		local chunk = string.sub( data, first, first + PRESET_COVER_PART_BYTES - 1 )
		net.Start( "mc_preset_cover_download_part" )
			net.WriteString( cover )
			net.WriteUInt( i, 16 )
			net.WriteUInt( #chunk, 16 )
			net.WriteData( chunk, #chunk )
		net.Send( ply )
		i = i + 1
	end )
end

net.Receive( "mc_preset_list_req", function( _, ply )
	if not canUsePresets( ply ) then
		sendPresetList( ply, L( ply, "server.preset_admin_list" ), true, {} )
		return
	end
	sendPresetList( ply )
end )

net.Receive( "mc_preset_load_req", function( _, ply )
	local presetName = net.ReadString()
	if not canUsePresets( ply ) then
		sendPresetDataError( ply, presetName, L( ply, "server.preset_admin_load" ) )
		return
	end
	sendPresetData( ply, presetName )
end )

net.Receive( "mc_preset_save", function( _, ply )
	if not canEditPresets( ply ) then
		sendPresetList( ply, L( ply, "server.preset_admin_save" ), true, {} )
		return
	end
	local presetName = net.ReadString()
	local cornerA = {
		bx = net.ReadInt( Net.COORD_BITS ),
		by = net.ReadInt( Net.COORD_BITS ),
		bz = net.ReadInt( Net.COORD_BITS ),
	}
	local cornerB = {
		bx = net.ReadInt( Net.COORD_BITS ),
		by = net.ReadInt( Net.COORD_BITS ),
		bz = net.ReadInt( Net.COORD_BITS ),
	}
	local anchor = {
		bx = net.ReadInt( Net.COORD_BITS ),
		by = net.ReadInt( Net.COORD_BITS ),
		bz = net.ReadInt( Net.COORD_BITS ),
		nx = net.ReadInt( 3 ),
		ny = net.ReadInt( 3 ),
		nz = net.ReadInt( 3 ),
	}
	local cover = net.ReadString()

	local ok, result = SV.SavePreset( presetName, cornerA, cornerB, anchor, cover, ply )
	if ok then
		sendPresetList( ply, L( ply, "server.preset_saved", { name = tostring( presetName ) } ) )
	else
		sendPresetList( ply, L( ply, "server.preset_save_failed", { err = tostring( result ) } ), true )
	end
end )

net.Receive( "mc_preset_place", function( _, ply )
	if not canEditPresets( ply ) then return end
	local presetName = net.ReadString()
	local origin = {
		bx = net.ReadInt( Net.COORD_BITS ),
		by = net.ReadInt( Net.COORD_BITS ),
		bz = net.ReadInt( Net.COORD_BITS ),
	}
	local overwrite = false
	if net.BytesLeft() > 0 then
		overwrite = net.ReadBool()
	end
	local rotation = 0
	if net.BytesLeft() > 0 then
		rotation = net.ReadUInt( 2 )
	end
	local ok, err = SV.PlacePreset( ply, presetName, origin, overwrite, rotation )
	if not ok and IsValid( ply ) then
		ply:ChatPrint( "[MC] " .. L( ply, "server.preset_place_failed", { err = tostring( err ) } ) )
	end
end )

net.Receive( "mc_preset_cover_begin", function( _, ply )
	local presetName = SV.PresetName( net.ReadString() )
	local rawCover = net.ReadString()
	local expectedParts = net.ReadUInt( 16 )
	local totalBytes = net.ReadUInt( 32 )
	if not canEditPresets( ply ) then sendPresetCoverAck( ply, rawCover, false, "permission" ) return end
	if not presetName then sendPresetCoverAck( ply, rawCover, false, "invalid_preset" ) return end

	local cover = sanitizePresetCover( rawCover, presetName )
	if not cover or expectedParts < 1 or totalBytes < 1 or totalBytes > MAX_PRESET_COVER_BYTES then
		sendPresetCoverAck( ply, rawCover, false, "invalid_upload" )
		return
	end
	if expectedParts ~= math.ceil( totalBytes / PRESET_COVER_PART_BYTES ) then
		sendPresetCoverAck( ply, rawCover, false, "invalid_part_count" )
		return
	end
	if not presetCoverBelongsToPreset( cover, presetName ) then cover = SV.PresetCoverPath( presetName ) end

	local upload = {
		presetName = presetName,
		cover = cover,
		expectedParts = expectedParts,
		totalBytes = totalBytes,
		receivedBytes = 0,
		receivedParts = 0,
		parts = {},
	}
	PresetCoverUploads[ply] = upload
	timer.Simple( PRESET_COVER_UPLOAD_TIMEOUT, function()
		if PresetCoverUploads[ply] == upload then failPresetCoverUpload( ply, upload, "timeout" ) end
	end )
end )

net.Receive( "mc_preset_cover_part", function( _, ply )
	local upload = PresetCoverUploads[ply]
	if not upload then return end

	local cover = sanitizePresetCover( net.ReadString(), upload.presetName )
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local chunk = net.ReadData( len )
	if cover ~= upload.cover or index < 1 or index > upload.expectedParts then failPresetCoverUpload( ply, upload, "invalid_part" ) return end
	if len < 1 or len > PRESET_COVER_PART_BYTES or not chunk or #chunk ~= len then failPresetCoverUpload( ply, upload, "invalid_part" ) return end
	if upload.parts[index] then return end

	upload.parts[index] = chunk
	upload.receivedParts = upload.receivedParts + 1
	upload.receivedBytes = upload.receivedBytes + len
	if upload.receivedBytes > upload.totalBytes or upload.receivedBytes > MAX_PRESET_COVER_BYTES then
		failPresetCoverUpload( ply, upload, "too_large" )
		return
	end

	if upload.receivedParts < upload.expectedParts then return end

	local data = table.concat( upload.parts )
	PresetCoverUploads[ply] = nil
	if #data ~= upload.totalBytes then sendPresetCoverAck( ply, upload.cover, false, "size_mismatch" ) return end
	if not isJPEGData( data ) then sendPresetCoverAck( ply, upload.cover, false, "invalid_jpeg" ) return end

	ensurePresetDirs()
	file.Write( upload.cover, data )
	if not file.Exists( upload.cover, "DATA" ) or file.Size( upload.cover, "DATA" ) ~= #data then
		sendPresetCoverAck( ply, upload.cover, false, "write_failed" )
		return
	end
	deletePresetCovers( upload.presetName, upload.cover )
	sendPresetCoverAck( ply, upload.cover, true )
end )

net.Receive( "mc_preset_cover_req", function( _, ply )
	if not canUsePresets( ply ) then return end
	sendPresetCoverToClient( ply, net.ReadString() )
end )

hook.Add( "PlayerDisconnected", "MC_ClearPresetCoverUpload", function( ply )
	PresetCoverUploads[ply] = nil
end )

concommand.Add( "mc_preset_list", function( ply )
	if not canUsePresets( ply ) then
		if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] only admins may list/load/save MC presets (set mc_preset_public 1 to allow everyone)" ) end
		return
	end
	local presets = SV.PresetList()
	if IsValid( ply ) then
		for _, preset in ipairs( presets ) do
			ply:PrintMessage( HUD_PRINTCONSOLE, string.format( "[MC] preset %s | %d blocks | %s", preset.name, preset.blocks or 0, preset.createdAtText or "?" ) )
		end
	else
		for _, preset in ipairs( presets ) do
			MsgN( string.format( "[MC] preset %s | %d blocks | %s", preset.name, preset.blocks or 0, preset.createdAtText or "?" ) )
		end
	end
end )
