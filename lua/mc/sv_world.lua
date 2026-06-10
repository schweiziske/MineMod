--[[----------------------------------------------------------------------------
	MC : server authority

	* validates and applies all placements/breaks (clients never mutate directly)
	* owns one mc_chunk entity per non-empty chunk (collision)
	* streams the world to joining players
	* persists to data/mc/<map>.dat
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV  = MC.SV
local Net = MC.Net
local C   = MC.Config

SV.BlockCount = SV.BlockCount or 0
SV.PhysDirty  = SV.PhysDirty or {}   -- chunkKey -> due time (collision needs rebuild)
SV.SyncQueue  = SV.SyncQueue or {}   -- player -> { keys = {}, i = 1, active = nil }
SV.Dirty      = SV.Dirty or false    -- world changed since last save
local PHYS_REBUILD_DELAY = 0.12

local function syncCellsPerPart()
	if C.SyncCells then
		return math.Clamp( C.SyncCells:GetInt(), 1, 12000 )
	end
	return C.SyncCellsPerPart or 4000
end

local function syncMessagesPerTick()
	if C.SyncMsgs then
		return math.Clamp( C.SyncMsgs:GetInt(), 1, 16 )
	end
	return C.SyncMessagesPerTick or 4
end

local function syncReliableBudget()
	if C.SyncBudget then
		return math.Clamp( C.SyncBudget:GetInt(), 8192, 52000 )
	end
	return C.SyncReliableBudget or 48000
end

local function estimateSyncPartBytes( cells )
	local bits = Net.COORD_BITS * 3 + Net.COUNT_BITS +
		cells * ( Net.LOCAL_BITS + Net.ID_BITS + Net.ORIENT_BITS )
	return math.ceil( bits / 8 ) + 64
end

local function decodeLocalWithHeight( li, height )
	local CS = MC.CS
	local CS2 = CS * CS
	if li < 0 or li >= CS2 * height then return nil end
	local lz = math.floor( li / CS2 )
	local rem = li - lz * CS2
	local ly = math.floor( rem / CS )
	local lx = rem - ly * CS
	return lx, ly, lz
end

------------------------------------------------------------------ chunk entities
function SV.EnsureChunkEnt( chunk )
	if IsValid( chunk.ent ) then return chunk.ent end
	local e = ents.Create( "mc_chunk" )
	if not IsValid( e ) then return nil end
	e.cx, e.cy, e.cz = chunk.cx, chunk.cy, chunk.cz
	e.ChunkKey = chunk.key
	e:SetPos( MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz ) )
	e:Spawn()
	e:Activate()
	chunk.ent = e
	return e
end

function SV.MarkPhysDirty( key )
	SV.PhysDirty[key] = CurTime() + PHYS_REBUILD_DELAY
end

-- debounced collision rebuild (coalesces many edits in the same frame/window)
timer.Create( "mc_phys_rebuild", 0.05, 0, function()
	if not next( SV.PhysDirty ) then return end
	local now = CurTime()
	local budget = 2
	for key in pairs( SV.PhysDirty ) do
		local due = SV.PhysDirty[key]
		if due == true or due <= now then
			local chunk = MC.GetChunkByKey( key )
			if chunk and IsValid( chunk.ent ) then
				chunk.ent:RebuildPhysics()
			end
			SV.PhysDirty[key] = nil
			budget = budget - 1
			if budget <= 0 then break end
		end
	end
end )

--------------------------------------------------------------------- validation
local function cooldownOK( ply )
	if not IsValid( ply ) then return true end
	local t = CurTime()
	if ( ply.mcNextOp or 0 ) > t then return false end
	ply.mcNextOp = t + 0.03
	return true
end

local function notify( ply, msg )
	if not IsValid( ply ) then return end
	if ( ply.mcNextWarn or 0 ) > CurTime() then return end
	ply.mcNextWarn = CurTime() + 2
	ply:ChatPrint( "[MC] " .. msg )
end

local function chat( ply, msg )
	if IsValid( ply ) then
		ply:ChatPrint( "[MC] " .. msg )
	else
		MsgN( "[MC] " .. msg )
	end
end

local function canEdit( ply )
	if C.AdminOnly:GetBool() and IsValid( ply ) and not ply:IsAdmin() then
		notify( ply, "只有管理员可以建造 (mc_admin_only)" )
		return false
	end
	return true
end

local function worldBoundsOK( bx, by, bz )
	local protoMax = bit.lshift( 1, Net.COORD_BITS - 1 ) - 1
	local lim = math.min( C.WorldLimit:GetInt(), protoMax )
	return math.abs( bx ) <= lim
		and math.abs( by ) <= lim
end

-- returns true if allowed; otherwise false (+ optional notify)
function SV.Validate( ply, bx, by, bz, placing )
	if not cooldownOK( ply ) then return false end
	if not canEdit( ply ) then return false end

	local reach = C.Reach:GetFloat()
	if reach > 0 and IsValid( ply ) then
		if not MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, reach ) then
			notify( ply, "Too far (mc_reach)" )
			return false
		end
	end

	if placing then
		if not worldBoundsOK( bx, by, bz ) then
			notify( ply, "超出建造范围 (mc_world_limit)" )
			return false
		end
		local maxBlocks = C.MaxBlocks:GetInt()
		if maxBlocks > 0 and SV.BlockCount >= maxBlocks then
			notify( ply, "已达到方块上限 (mc_max_blocks)" )
			return false
		end
	end

	return true
end

------------------------------------------------------------- single block update
-- Broadcast a change to everyone, including still-syncing players. Streamed
-- full-sync builds each chunk's local-index list when the stream starts and reads
-- live block values for every part, so single-block updates can interleave without
-- requiring one giant reliable message.
local function broadcastSet( bx, by, bz, id, orient )
	if #player.GetAll() == 0 then return end
	orient = MC.NormalizeOrient( id, orient )
	net.Start( "mc_set" )
		net.WriteInt( bx, Net.COORD_BITS )
		net.WriteInt( by, Net.COORD_BITS )
		net.WriteInt( bz, Net.COORD_BITS )
		net.WriteUInt( id, Net.ID_BITS )
		net.WriteUInt( orient or 0, Net.ORIENT_BITS )
	net.Broadcast()
end

-- a player-predicted edit got rejected: push the authoritative cell state back
-- to that player right away instead of waiting for the client's prediction
-- rollback timer (the client's mc_set receiver overwrites the misprediction)
function SV.SyncCell( ply, bx, by, bz )
	if not IsValid( ply ) then return end
	net.Start( "mc_set" )
		net.WriteInt( bx, Net.COORD_BITS )
		net.WriteInt( by, Net.COORD_BITS )
		net.WriteInt( bz, Net.COORD_BITS )
		net.WriteUInt( MC.GetBlock( bx, by, bz ), Net.ID_BITS )
		net.WriteUInt( MC.GetBlockOrient( bx, by, bz ) or 0, Net.ORIENT_BITS )
	net.Send( ply )
end

local function broadcastFx( kind, bx, by, bz, id, orient )
	if #player.GetAll() == 0 then return end
	orient = MC.NormalizeOrient( id, orient )
	net.Start( "mc_fx" )
		net.WriteUInt( kind, 2 ) -- 1=place, 2=break
		net.WriteInt( bx, Net.COORD_BITS )
		net.WriteInt( by, Net.COORD_BITS )
		net.WriteInt( bz, Net.COORD_BITS )
		net.WriteUInt( id, Net.ID_BITS )
		net.WriteUInt( orient or 0, Net.ORIENT_BITS )
	net.Broadcast()
end

local function callBlockHandler( id, name, ... )
	local b = MC.Blocks[id]
	local fn = b and b.handlers and b.handlers[name]
	if not fn then return nil end
	return fn( ... )
end

local function markNeighbourShapePhysDirty( bx, by, bz )
	local function mark( x, y, z )
		local cx, cy, cz = MC.CellToChunk( x, y, z )
		local c = MC.GetChunkByKey( MC.ChunkKey( cx, cy, cz ) )
		if c and c.count and c.count > 0 then
			SV.EnsureChunkEnt( c )
			SV.MarkPhysDirty( c.key )
		end
	end

	mark( bx + 1, by, bz )
	mark( bx - 1, by, bz )
	mark( bx, by + 1, bz )
	mark( bx, by - 1, bz )
end

local function normalizeWriteOptions( options )
	if istable( options ) then return options end
	if options ~= nil then return { actor = options } end
	return {}
end

-- core mutation shared by Place/Break/fill/demo/public API.
-- This is still not a validation layer; callers decide whether player checks apply.
local function apply( bx, by, bz, id, _, orient, actor, options )
	options = options or {}
	local old = MC.GetBlock( bx, by, bz )
	local oldOrient = MC.GetBlockOrient( bx, by, bz )
	orient = MC.NormalizeOrient( id, orient )
	local chunk, created, emptied, changed = MC.SetBlockRaw( bx, by, bz, id, orient )
	if not changed then return false end

	local delta = 0
	if old == 0 and id ~= 0 then
		delta = 1
	elseif old ~= 0 and id == 0 then
		delta = -1
	end
	SV.BlockCount = math.max( 0, SV.BlockCount + delta )

	if id ~= 0 then
		SV.EnsureChunkEnt( chunk )
		SV.MarkPhysDirty( chunk.key )
	else
		if emptied then
			SV.PhysDirty[chunk.key] = nil
			if IsValid( chunk.ent ) then chunk.ent:Remove() end
		else
			SV.MarkPhysDirty( chunk.key )
		end
	end
	markNeighbourShapePhysDirty( bx, by, bz )

	broadcastSet( bx, by, bz, id, orient )
	local shouldFx = options.fx
	if shouldFx == nil then shouldFx = IsValid( actor ) end
	if shouldFx then
		if old ~= 0 and id == 0 then
			broadcastFx( 2, bx, by, bz, old, oldOrient )
		elseif old == 0 and id ~= 0 then
			broadcastFx( 1, bx, by, bz, id, orient )
		end
	end
	if options.handlers ~= false then
		if old ~= 0 then callBlockHandler( old, "OnBreak", actor, bx, by, bz, oldOrient ) end
		if id ~= 0 then callBlockHandler( id, "OnPlace", actor, bx, by, bz, orient ) end
	end
	SV.Dirty = true
	return true
end

-- a placed block must not overlap a living player's hull (don't trap / suffocate them)
local function wouldTrapPlayer( bx, by, bz )
	local mn = MC.CellWorldMin( bx, by, bz )
	local mx = Vector( mn.x + MC.BS, mn.y + MC.BS, mn.z + MC.BS )
	for _, p in ipairs( player.GetAll() ) do
		if p:Alive() then
			local pmn, pmx = p:WorldSpaceAABB()
			-- strict overlap test, so a block placed flush against a player is allowed
			if mn.x < pmx.x and mx.x > pmn.x
			and mn.y < pmx.y and mx.y > pmn.y
			and mn.z < pmx.z and mx.z > pmn.z then
				return true
			end
		end
	end
	return false
end

function SV.Place( ply, bx, by, bz, id, orient )
	if not MC.IsValidBlock( id ) then return false end
	if MC.GetBlock( bx, by, bz ) ~= 0 then return false end -- occupied
	if wouldTrapPlayer( bx, by, bz ) then
		notify( ply, "这里贴着玩家，放不了" )
		return false
	end
	if not SV.Validate( ply, bx, by, bz, true ) then return false end
	return apply( bx, by, bz, id, 1, orient, ply )
end

function SV.Break( ply, bx, by, bz )
	local old = MC.GetBlock( bx, by, bz )
	if old == 0 then return false end
	if not SV.Validate( ply, bx, by, bz, false ) then return false end
	return apply( bx, by, bz, 0, -1, nil, ply )
end

function SV.SetBlock( bx, by, bz, id, orient, options )
	options = normalizeWriteOptions( options )
	id = math.floor( tonumber( id ) or 0 )
	if id ~= 0 and not MC.IsValidBlock( id ) then return false, "invalid_block" end
	if id ~= 0 and options.preventPlayerOverlap and wouldTrapPlayer( bx, by, bz ) then return false, "player_overlap" end
	if id == 0 then orient = 0 end

	local changed = apply( bx, by, bz, id, 0, orient, options.actor, {
		fx = options.fx ~= false,
		handlers = options.handlers,
	} )
	if not changed then return false, "unchanged" end
	return true
end

function SV.SetBlockSpec( bx, by, bz, spec, options )
	local id, orient, _, err = MC.ParseBlockSpec( spec )
	if err or not id then return false, err or "invalid_block" end
	return SV.SetBlock( bx, by, bz, id, orient, options )
end

function SV.RemoveBlock( bx, by, bz, options )
	return SV.SetBlock( bx, by, bz, 0, 0, options )
end

function SV.Use( ply, bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b or not b.handlers or not b.handlers.OnUse then return false end
	if not SV.Validate( ply, bx, by, bz, false ) then return false end
	return b.handlers.OnUse( ply, bx, by, bz, MC.GetBlockOrient( bx, by, bz ) ) == true
end

------------------------------------------------------------------- fill command
local function trimArg( s )
	return string.match( tostring( s or "" ), "^%s*(.-)%s*$" )
end

local function joinArgs( args, first, last )
	if not args[first] then return nil end
	local out = {}
	for i = first, last or #args do out[#out + 1] = args[i] end
	return table.concat( out, " " )
end

local function parseBlockStateTail( text )
	return MC.ParseBlockSpec( trimArg( text ) )
end

local FILL_USAGE = "用法: /fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]> [state]"

local function runFill( ply, args )
	if #args < 8 then chat( ply, FILL_USAGE ) return end
	if not canEdit( ply ) then return end

	local x1, y1, z1 = tonumber( args[2] ), tonumber( args[3] ), tonumber( args[4] )
	local x2, y2, z2 = tonumber( args[5] ), tonumber( args[6] ), tonumber( args[7] )
	local id, orient, blockArg, parseErr = parseBlockStateTail( joinArgs( args, 8 ) )
	if not x1 or not y1 or not z1 or not x2 or not y2 or not z2 or parseErr == "block" then
		chat( ply, FILL_USAGE )
		return
	end
	if parseErr == "state" then
		chat( ply, "方块状态不合法: " .. blockArg )
		return
	end

	x1, y1, z1 = math.floor( x1 ), math.floor( y1 ), math.floor( z1 )
	x2, y2, z2 = math.floor( x2 ), math.floor( y2 ), math.floor( z2 )
	local minx, maxx = math.min( x1, x2 ), math.max( x1, x2 )
	local miny, maxy = math.min( y1, y2 ), math.max( y1, y2 )
	local minz, maxz = math.min( z1, z2 ), math.max( z1, z2 )

	if not worldBoundsOK( minx, miny, minz ) or not worldBoundsOK( maxx, maxy, maxz ) then
		chat( ply, "超出建造范围 (mc_world_limit)" )
		return
	end

	local volume = ( maxx - minx + 1 ) * ( maxy - miny + 1 ) * ( maxz - minz + 1 )
	local fillMax = C.FillMax and C.FillMax:GetInt() or 32768
	if fillMax > 0 and volume > fillMax then
		chat( ply, "填充范围太大 (" .. volume .. " > mc_fill_max " .. fillMax .. ")" )
		return
	end

	local add = 0
	for z = minz, maxz do
		for y = miny, maxy do
			for x = minx, maxx do
				local old = MC.GetBlock( x, y, z )
				local oldOrient = MC.GetBlockOrient( x, y, z )
				if old ~= id or ( id ~= 0 and oldOrient ~= orient ) then
					if old == 0 and id ~= 0 and not wouldTrapPlayer( x, y, z ) then add = add + 1 end
				end
			end
		end
	end

	local maxBlocks = C.MaxBlocks:GetInt()
	if id ~= 0 and maxBlocks > 0 and SV.BlockCount + add > maxBlocks then
		chat( ply, "会超过方块上限 (mc_max_blocks)" )
		return
	end

	local changed = 0
	for z = minz, maxz do
		for y = miny, maxy do
			for x = minx, maxx do
				local old = MC.GetBlock( x, y, z )
				local oldOrient = MC.GetBlockOrient( x, y, z )
				if old ~= id or ( id ~= 0 and oldOrient ~= orient ) then
					if id == 0 then
						if apply( x, y, z, 0 ) then changed = changed + 1 end
					elseif old == 0 and not wouldTrapPlayer( x, y, z ) then
						if apply( x, y, z, id, 1, orient ) then changed = changed + 1 end
					elseif old ~= 0 then
						if apply( x, y, z, id, 0, orient ) then changed = changed + 1 end
					end
				end
			end
		end
	end

	chat( ply, "已填充 " .. changed .. " 个方块" )
end

hook.Add( "PlayerSay", "mc_fill_command", function( ply, text )
	local args = string.Explode( "%s+", string.Trim( text ), true )
	if not args[1] then return end
	local cmd = string.lower( args[1] )
	if cmd == "/fill" or cmd == "!fill" or cmd == "fill" then
		runFill( ply, args )
		return ""
	end
end )

concommand.Add( "mc_fill", function( ply, _, args )
	table.insert( args, 1, "mc_fill" )
	runFill( ply, args )
end )

------------------------------------------------------------------- import tool
local IMPORT_USAGE = "用法: mc_import <mc_import/文件.json> [replace|append]"

local function normalizeImportPath( path )
	path = trimArg( path or "" )
	path = string.gsub( path, "\\", "/" )
	path = string.gsub( path, "^/+", "" )
	if path == "" then return nil end
	if not string.StartWith( path, "mc_import/" ) then
		path = "mc_import/" .. path
	end
	if not string.EndsWith( string.lower( path ), ".json" ) then
		path = path .. ".json"
	end
	return path
end

local function clearWorldNoNet()
	for _, c in pairs( MC.World ) do
		if IsValid( c.ent ) then c.ent:Remove() end
	end
	MC.World = {}
	SV.BlockCount = 0
	SV.PhysDirty = {}
	SV.SyncQueue = {}
end

local function resyncAllClients()
	net.Start( "mc_clear" )
	net.Broadcast()
	for _, p in ipairs( player.GetAll() ) do
		SV.BeginSync( p )
	end
end

local function blockFromImport( cache, savedBlock )
	local key = tostring( savedBlock or "" )
	local cached = cache[key]
	if cached ~= nil then return cached end
	local resolved = MC.ResolveBlock( key )
	local id = resolved and resolved.id or 0
	cache[key] = id
	return id
end

local function importPaletteEntry( cache, palette, index )
	if not istable( palette ) then return 0, 0 end
	local spec = palette[math.floor( tonumber( index ) or 0 ) + 1]
	if not spec then return 0, 0 end

	local cached = cache[spec]
	if cached then return cached[1], cached[2] end

	local id, orient = MC.ParseBlockSpec( spec )
	id = id or 0
	orient = MC.NormalizeOrient( id, orient )
	cache[spec] = { id, orient }
	return id, orient
end

local function decodeLegacyLocal( li )
	local cs, cs2 = MC.CS, MC.CS * MC.CS
	local lz = math.floor( li / cs2 )
	local ly = math.floor( ( li - lz * cs2 ) / cs )
	local lx = li - lz * cs2 - ly * cs
	return lx, ly, lz
end

local function oldColumnCell( data, cx, cy, li )
	local lx, ly, lz = decodeLegacyLocal( li )
	local minZ = math.floor( tonumber( data.minZ ) or 0 )
	return cx * MC.CS + lx, cy * MC.CS + ly, minZ + lz
end

local function oldSliceCell( cx, cy, oldCz, li )
	local lx, ly, lz = decodeLegacyLocal( li )
	return cx * MC.CS + lx, cy * MC.CS + ly, oldCz * MC.CS + lz
end

local function importOneCell( data, cache, palette, legacyMode, cx, cy, cz, li, savedBlock, state, touched )
	local bx, by, bz
	if legacyMode == "column" then
		bx, by, bz = oldColumnCell( data, cx, cy, li )
	elseif legacyMode == "slice" then
		bx, by, bz = oldSliceCell( cx, cy, cz, li )
	else
		local lx, ly, lz = MC.DecodeLocal( li )
		bx, by, bz = cx * MC.CS + lx, cy * MC.CS + ly, cz * MC.CH + lz
	end

	local ncx, ncy, ncz, nli = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange( nli ) then return 0, 0, 0 end
	if not worldBoundsOK( bx, by, bz ) then return 0, 0, 1 end

	local id, orient
	if data.v == 4 or data.v == 5 then
		id, orient = importPaletteEntry( cache, palette, savedBlock )
	else
		id = blockFromImport( cache, savedBlock )
		orient = MC.StateToOrient( id, state )
	end
	if id == 0 or not MC.IsValidBlock( id ) then return 0, 1, 0 end

	local c = MC.GetChunk( ncx, ncy, ncz )
	c = c or MC.EnsureChunk( ncx, ncy, ncz )
	if c.blocks[nli] == nil then
		c.count = c.count + 1
		SV.BlockCount = SV.BlockCount + 1
	end
	c.blocks[nli] = id
	c.orients[nli] = MC.NormalizeOrient( id, orient )
	touched[c.key] = c
	return 1, 0, 0
end

local function importCells( data, appendMode, deferResync )
	if not data or not data.chunks then return nil, "文件格式不对" end
	local cache = {}
	local palette = data.p or data.palette
	local expectedBlocks = istable( data.stats ) and math.floor( tonumber( data.stats.blocks ) or 0 ) or 0
	local imported, skippedUnknown, skippedBounds = 0, 0, 0

	if not appendMode then
		clearWorldNoNet()
	end

	for _, ck in ipairs( data.chunks ) do
		local cx, cy, cz, cells, legacyMode
		if data.v == 5 then
			cx, cy, cz, cells = math.floor( tonumber( ck[1] ) or 0 ), math.floor( tonumber( ck[2] ) or 0 ), math.floor( tonumber( ck[3] ) or 0 ), ck[4]
		elseif data.v == 4 then
			cx, cy, cells, legacyMode = math.floor( tonumber( ck[1] ) or 0 ), math.floor( tonumber( ck[2] ) or 0 ), ck[3], "column"
		else
			cx, cy, cz, cells, legacyMode = math.floor( tonumber( ck[1] ) or 0 ), math.floor( tonumber( ck[2] ) or 0 ), math.floor( tonumber( ck[3] ) or 0 ), ck[4], "slice"
		end
		if istable( cells ) or isstring( cells ) then
			local touched = {}
			if isstring( cells ) then
				for liText, blockText, stateText in string.gmatch( cells, "([^:;]+):([^:;]*):?([^;]*);?" ) do
					local add, unk, bounds = importOneCell( data, cache, palette, legacyMode, cx, cy, cz, math.floor( tonumber( liText ) or -1 ), blockText, stateText ~= "" and stateText or nil, touched )
					imported = imported + add
					skippedUnknown = skippedUnknown + unk
					skippedBounds = skippedBounds + bounds
				end
			else
				local stride = ( data.v == 4 or data.v == 5 ) and 2 or 3
				for i = 1, #cells, stride do
					local add, unk, bounds = importOneCell( data, cache, palette, legacyMode, cx, cy, cz, math.floor( tonumber( cells[i] ) or -1 ), cells[i + 1], cells[i + 2], touched )
					imported = imported + add
					skippedUnknown = skippedUnknown + unk
					skippedBounds = skippedBounds + bounds
				end
			end
			for key, c in pairs( touched ) do
				if c.count > 0 then
					SV.EnsureChunkEnt( c )
					SV.MarkPhysDirty( c.key )
				else
					MC.World[key] = nil
				end
			end
		end
	end

	SV.Dirty = true
	if not deferResync then
		resyncAllClients()
	end
	return {
		imported = imported,
		total = SV.BlockCount,
		expected = expectedBlocks,
		skippedUnknown = skippedUnknown,
		skippedBounds = skippedBounds,
		skippedLimit = 0,
	}
end

local function importPartFile( partPath, appendMode )
	if not file.Exists( partPath, "DATA" ) then
		return nil, "missing part garrysmod/data/" .. partPath
	end
	local raw = file.Read( partPath, "DATA" )
	local data = raw and util.JSONToTable( raw )
	if not data then
		return nil, "invalid part JSON: " .. partPath
	end
	return importCells( data, appendMode, true )
end

local function importManifest( data, manifestPath, appendMode )
	if not istable( data.parts ) then
		return importCells( data, appendMode )
	end

	if not appendMode then
		clearWorldNoNet()
	end

	local dir = string.GetPathFromFilename( manifestPath )
	local totalImported, totalUnknown, totalBounds, totalLimit = 0, 0, 0, 0
	local expected = istable( data.stats ) and math.floor( tonumber( data.stats.blocks ) or 0 ) or 0
	for _, part in ipairs( data.parts ) do
		local partPath = tostring( part or "" )
		if partPath == "" then continue end
		if not string.StartWith( partPath, "mc_import/" ) then
			partPath = dir .. partPath
		end
		local result, err = importPartFile( partPath, true )
		if not result then return nil, err end
		totalImported = totalImported + result.imported
		totalUnknown = totalUnknown + result.skippedUnknown
		totalBounds = totalBounds + result.skippedBounds
		totalLimit = totalLimit + result.skippedLimit
	end

	SV.Dirty = true
	resyncAllClients()
	return {
		imported = totalImported,
		total = SV.BlockCount,
		expected = expected,
		skippedUnknown = totalUnknown,
		skippedBounds = totalBounds,
		skippedLimit = totalLimit,
	}
end

local function importFormatText( data )
	if istable( data.parts ) then
		return "manifest parts=" .. #data.parts .. " v=" .. tostring( data.v )
	end
	return "single chunks=" .. ( istable( data.chunks ) and #data.chunks or 0 ) .. " v=" .. tostring( data.v )
end

local function runImport( ply, args )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local first = string.lower( tostring( args[1] or "" ) )
	local base = ( first == "/mc_import" or first == "!mc_import" or first == "mc_import" ) and 2 or 1
	local path = normalizeImportPath( args[base] )
	if not path then chat( ply, IMPORT_USAGE ) return end

	local mode = string.lower( tostring( args[base + 1] or "replace" ) )
	local appendMode = mode == "append"
	if mode ~= "replace" and mode ~= "append" then
		chat( ply, IMPORT_USAGE )
		return
	end

	if not file.Exists( path, "DATA" ) then
		chat( ply, "找不到导入文件: garrysmod/data/" .. path )
		return
	end

	local raw = file.Read( path, "DATA" )
	local data = raw and util.JSONToTable( raw )
	if not data then
		chat( ply, "导入文件不是有效 JSON: " .. path )
		return
	end

	chat( ply, "import format: " .. importFormatText( data ) .. " bytes=" .. #raw )
	local result, err = importManifest( data, path, appendMode )
	if not result then chat( ply, "导入失败: " .. tostring( err ) ) return end
	local msg = string.format( "导入完成: %d 个方块，当前总数 %d，跳过未知 %d，越界 %d，超上限 %d",
		result.imported, result.total, result.skippedUnknown, result.skippedBounds, result.skippedLimit )
	chat( ply, msg )
	if result.expected and result.expected > 0 and result.imported ~= result.expected then
		chat( ply, "导入文件写着 " .. result.expected .. " 个方块，实际进服 " .. result.imported .. " 个；少的都在上面跳过统计里。" )
	end
	if result.skippedLimit > 0 then
		chat( ply, "导入被 mc_import_max=" .. tostring( C.ImportMax and C.ImportMax:GetInt() or "?" ) .. " 截断了；完整区块请先执行 mc_import_max 0。" )
	end
	MsgN( "[MC] imported " .. path .. " (" .. ( appendMode and "append" or "replace" ) .. ")" )
end

hook.Add( "PlayerSay", "mc_import_command", function( ply, text )
	local args = string.Explode( "%s+", string.Trim( text ), true )
	if not args[1] then return end
	local cmd = string.lower( args[1] )
	if cmd == "/mc_import" or cmd == "!mc_import" then
		runImport( ply, args )
		return ""
	end
end )

concommand.Add( "mc_import", function( ply, _, args )
	runImport( ply, args )
end )

concommand.Add( "mc_import_probe", function( ply, _, args )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local path = normalizeImportPath( args[1] )
	if not path then chat( ply, IMPORT_USAGE ) return end
	if not file.Exists( path, "DATA" ) then
		chat( ply, "probe missing: garrysmod/data/" .. path )
		return
	end
	local raw = file.Read( path, "DATA" )
	local data = raw and util.JSONToTable( raw )
	if not data then
		chat( ply, "probe invalid JSON bytes=" .. tostring( raw and #raw or "nil" ) )
		return
	end
	chat( ply, "probe " .. path .. ": " .. importFormatText( data ) .. " bytes=" .. #raw )
	if istable( data.parts ) and data.parts[1] then
		local dir = string.GetPathFromFilename( path )
		local partPath = tostring( data.parts[1] )
		if not string.StartWith( partPath, "mc_import/" ) then partPath = dir .. partPath end
		local partRaw = file.Read( partPath, "DATA" )
		local partData = partRaw and util.JSONToTable( partRaw )
		chat( ply, "probe first part " .. partPath .. ": " .. ( partData and importFormatText( partData ) or "invalid" ) .. " bytes=" .. tostring( partRaw and #partRaw or "nil" ) )
	end
end )

------------------------------------------------------------------ world streaming
local function sendFullBegin( ply, active )
	net.Start( "mc_full_begin" )
		net.WriteInt( active.cx, Net.COORD_BITS )
		net.WriteInt( active.cy, Net.COORD_BITS )
		net.WriteInt( active.cz, Net.COORD_BITS )
		net.WriteUInt( #active.lis, Net.COUNT_BITS )
	net.Send( ply )
end

local function sendFullPart( ply, active )
	local chunk = MC.GetChunkByKey( active.key )
	if not chunk then
		active.i = #active.lis + 1
		return false
	end

	local maxCells = syncCellsPerPart()
	local part = {}
	while active.i <= #active.lis and #part < maxCells do
		local li = active.lis[active.i]
		local id = chunk.blocks[li]
		if id and id ~= 0 then
			part[#part + 1] = {
				li = li,
				id = id,
				orient = MC.NormalizeOrient( id, chunk.orients and chunk.orients[li] ),
			}
		end
		active.i = active.i + 1
	end

	if #part == 0 then return false end

	net.Start( "mc_full_part" )
		net.WriteInt( active.cx, Net.COORD_BITS )
		net.WriteInt( active.cy, Net.COORD_BITS )
		net.WriteInt( active.cz, Net.COORD_BITS )
		net.WriteUInt( #part, Net.COUNT_BITS )
		for i = 1, #part do
			local cell = part[i]
			net.WriteUInt( cell.li, Net.LOCAL_BITS )
			net.WriteUInt( cell.id, Net.ID_BITS )
			net.WriteUInt( cell.orient, Net.ORIENT_BITS )
		end
	net.Send( ply )
	return true
end

local function sendFullEnd( ply, active )
	net.Start( "mc_full_end" )
		net.WriteInt( active.cx, Net.COORD_BITS )
		net.WriteInt( active.cy, Net.COORD_BITS )
		net.WriteInt( active.cz, Net.COORD_BITS )
	net.Send( ply )
end

local function makeSyncActive( key )
	local chunk = MC.GetChunkByKey( key )
	if not chunk or chunk.count <= 0 then return nil end

	local lis = {}
	for li, id in pairs( chunk.blocks ) do
		if id and id ~= 0 and MC.LocalIndexInRange( li ) then
			lis[#lis + 1] = li
		end
	end
	table.sort( lis )

	return {
		key = key,
		cx = chunk.cx,
		cy = chunk.cy,
		cz = chunk.cz,
		lis = lis,
		i = 1,
		begun = false,
	}
end

function SV.BeginSync( ply )
	local keys = {}
	for key in pairs( MC.World ) do keys[#keys + 1] = key end
	SV.SyncQueue[ply] = { keys = keys, i = 1 }
end

local function sendSyncStep( ply, q )
	while not q.active do
		if q.i > #q.keys then return false end
		q.active = makeSyncActive( q.keys[q.i] )
		q.i = q.i + 1
	end

	local active = q.active
	if not active.begun then
		sendFullBegin( ply, active )
		active.begun = true
		return true
	end

	while active.i <= #active.lis do
		if sendFullPart( ply, active ) then return true end
	end

	sendFullEnd( ply, active )
	q.active = nil
	return true
end

-- drip small chunk parts to each syncing player; large chunks must never be one
-- reliable net message.
timer.Create( "mc_sync", 0.05, 0, function()
	for ply, q in pairs( SV.SyncQueue ) do
		if not IsValid( ply ) then SV.SyncQueue[ply] = nil continue end
		local sent = 0
		local sentBytes = 0
		local budget = syncMessagesPerTick()
		local byteBudget = syncReliableBudget()
		local partBytes = estimateSyncPartBytes( syncCellsPerPart() )
		while sent < budget and sentBytes + partBytes <= byteBudget and sendSyncStep( ply, q ) do
			sent = sent + 1
			sentBytes = sentBytes + partBytes
		end
		if q.i > #q.keys and not q.active then SV.SyncQueue[ply] = nil end
	end
end )

timer.Create( "mc_block_tick", 1, 0, function()
	if not MC.HasBlockTickHandlers then return end
	for _, c in pairs( MC.World ) do
		if c.count and c.count > 0 then
			MC.ForEachBlock( c, function( bx, by, bz, _, _, _, id, orient )
				callBlockHandler( id, "OnTick", bx, by, bz, orient )
			end )
		end
	end
end )

------------------------------------------------------------------- persistence
local function savePath()
	return "mc/" .. game.GetMap() .. ".dat"
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

local function packSaveCells( cells )
	local out = {}
	local n = 0
	for i = 1, #cells, 2 do
		n = n + 1
		out[n] = tostring( cells[i] ) .. ":" .. tostring( cells[i + 1] )
	end
	return table.concat( out, ";" )
end

function SV.Save()
	local chunks = {}
	local palette = {}
	local paletteIndex = {}
	for _, c in pairs( MC.World ) do
		if c.count > 0 then
			local cells = {}
			local n = 0
			for li, id in pairs( c.blocks ) do
				local state = MC.BlockStateText( id, c.orients and c.orients[li] )
				local spec = MC.BlockCanonicalName( id )
				if state ~= "" then spec = spec .. "[" .. state .. "]" end
				local pi = paletteIndex[spec]
				if pi == nil then
					pi = #palette
					palette[#palette + 1] = spec
					paletteIndex[spec] = pi
				end
				n = n + 1 ; cells[n] = li
				n = n + 1 ; cells[n] = pi
			end
			chunks[#chunks + 1] = { c.cx, c.cy, c.cz, packSaveCells( cells ) }
		end
	end
	local json = util.TableToJSON( { v = 5, bs = MC.BS, cs = MC.CS, h = MC.CH, p = palette, chunks = chunks } )
	if not json then return end
	file.CreateDir( "mc" )
	local compressed = util.Compress( json )
	if not compressed then return end
	file.Write( savePath(), compressed )
	local verifyRaw = file.Read( savePath(), "DATA" )
	local verifyJSON = verifyRaw and util.Decompress( verifyRaw )
	local verifyData = verifyJSON and util.JSONToTable( verifyJSON )
	local verifyChunks, verifyBlocks = savedBlockCount( verifyData )
	if verifyBlocks ~= SV.BlockCount or verifyChunks ~= #chunks then
		MsgN( "[MC] !!! save verify mismatch chunks " .. verifyChunks .. "/" .. #chunks ..
			" blocks " .. verifyBlocks .. "/" .. SV.BlockCount )
	end
	SV.Dirty = false
	MsgN( "[MC] saved " .. #chunks .. " chunks / " .. SV.BlockCount .. " blocks" )
end

function SV.Load()
	local path = savePath()
	if not file.Exists( path, "DATA" ) then return end

	local raw = file.Read( path, "DATA" )
	if not raw or raw == "" then return end
	local json = util.Decompress( raw )
	if not json then return end
	local data = util.JSONToTable( json )
	if not data or not data.chunks then return end

	if data.bs and data.bs ~= MC.BS then
		MsgN( "[MC] WARNING: save BlockSize " .. data.bs .. " != current " .. MC.BS .. " (positions may be off)" )
	end
	local savedHeight = math.floor( tonumber( data.h ) or MC.CH )
	if savedHeight <= 0 then savedHeight = MC.CH end
	if data.v == 5 and savedHeight ~= MC.CH then
		MsgN( "[MC] remapping save chunk height " .. savedHeight .. " -> " .. MC.CH )
	end

	MC.World = {}
	SV.BlockCount = 0
	local cache = {}
	local palette = data.p or data.palette

	for _, ck in ipairs( data.chunks ) do
		local cx, cy, cz, cells, legacyMode
		if data.v == 5 then
			cx, cy, cz, cells = ck[1], ck[2], ck[3], ck[4]
		elseif data.v == 4 then
			cx, cy, cells, legacyMode = ck[1], ck[2], ck[3], "column"
		else
			cx, cy, cz, cells, legacyMode = ck[1], ck[2], ck[3], ck[4], "slice"
		end
		local touched = {}
		local stride = ( data.v == 4 or data.v == 5 ) and 2 or ( ( data.v == 2 or data.v == 3 ) and 3 or 2 )
		local function loadOneCell( li, savedBlock, state )
			li = math.floor( tonumber( li ) or -1 )
			local id, orient
			if data.v == 4 or data.v == 5 then
				id, orient = importPaletteEntry( cache, palette, savedBlock )
			else
				local resolved = data.v == 3 and MC.ResolveBlock( savedBlock ) or nil
				id = resolved and resolved.id or math.floor( tonumber( savedBlock ) or 0 )
				orient = state ~= nil and MC.StateToOrient( id, state ) or MC.DefaultOrient( id )
			end
			local bx, by, bz
			if legacyMode == "column" then
				bx, by, bz = oldColumnCell( data, cx, cy, li )
			elseif legacyMode == "slice" then
				bx, by, bz = oldSliceCell( cx, cy, cz, li )
			else
				local lx, ly, lz = decodeLocalWithHeight( li, data.v == 5 and savedHeight or MC.CH )
				if lx then
					bx, by, bz = cx * MC.CS + lx, cy * MC.CS + ly, cz * savedHeight + lz
				end
			end
			if bx then
				local ncx, ncy, ncz, nli = MC.CellToChunk( bx, by, bz )
				local c = MC.GetChunk( ncx, ncy, ncz )
				if MC.LocalIndexInRange( nli ) and MC.IsValidBlock( id ) and ( not c or c.blocks[nli] == nil ) then
					c = c or MC.EnsureChunk( ncx, ncy, ncz )
					c.blocks[nli] = id
					c.orients[nli] = MC.NormalizeOrient( id, orient )
					c.count = c.count + 1
					SV.BlockCount = SV.BlockCount + 1
					touched[c.key] = c
				end
			end
		end

		if isstring( cells ) then
			for liText, blockText, stateText in string.gmatch( cells, "([^:;]+):([^:;]*):?([^;]*);?" ) do
				loadOneCell( liText, blockText, stateText ~= "" and stateText or nil )
			end
		else
			for i = 1, #cells, stride do
				loadOneCell( cells[i], cells[i + 1], stride == 3 and cells[i + 2] or nil )
			end
		end
		for key, c in pairs( touched ) do
			if c.count > 0 then
				SV.EnsureChunkEnt( c )
				SV.MarkPhysDirty( c.key )
			else
				MC.World[key] = nil
			end
		end
	end

	MsgN( "[MC] loaded " .. SV.BlockCount .. " blocks" )
end

------------------------------------------------------------------------ hooks
hook.Add( "InitPostEntity", "mc_load", function()
	SV.Load()
	local secs = C.Autosave:GetInt()
	if secs > 0 then
		timer.Create( "mc_autosave", secs, 0, function()
			if SV.Dirty then SV.Save() end
		end )
	end
end )

hook.Add( "PlayerInitialSpawn", "mc_sync", function( ply )
	timer.Simple( 0.5, function()
		if IsValid( ply ) then SV.BeginSync( ply ) end
	end )
end )

hook.Add( "PlayerDisconnected", "mc_sync_clean", function( ply )
	SV.SyncQueue[ply] = nil
end )

hook.Add( "ShutDown", "mc_save", function()
	if SV.Dirty then SV.Save() end
end )

------------------------------------------------------------------- block select
-- clients call: mc_block_sel <id>  (used by the SWEP)
concommand.Add( "mc_block_sel", function( ply, _, args )
	local id = tonumber( args[1] )
	if IsValid( ply ) and MC.IsValidBlock( id ) then
		ply:SetNWInt( "mc_block", id )
	end
end )

------------------------------------------------------------------- admin commands
concommand.Add( "mc_save", function( ply )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	SV.Save()
end )

concommand.Add( "mc_save_diag", function( ply )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local memChunks = 0
	for _, c in pairs( MC.World ) do
		if c.count and c.count > 0 then memChunks = memChunks + 1 end
	end
	local raw = file.Read( savePath(), "DATA" )
	local json = raw and util.Decompress( raw )
	local data = json and util.JSONToTable( json )
	local diskChunks, diskBlocks = savedBlockCount( data )
	local msg = "[MC] save diag memory chunks=" .. memChunks .. " blocks=" .. SV.BlockCount ..
		" disk chunks=" .. diskChunks .. " blocks=" .. diskBlocks ..
		" h=" .. tostring( data and data.h or "nil" ) ..
		" dirty=" .. tostring( SV.Dirty )
	if SV.Dirty and ( diskChunks ~= memChunks or diskBlocks ~= SV.BlockCount ) then
		msg = msg .. " (run mc_save to write memory to disk)"
	end
	MsgN( msg )
	if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, msg ) end
end )

concommand.Add( "mc_clear", function( ply )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	for _, c in pairs( MC.World ) do
		if IsValid( c.ent ) then c.ent:Remove() end
	end
	MC.World = {}
	SV.BlockCount = 0
	SV.PhysDirty = {}
	SV.Dirty = true
	net.Start( "mc_clear" ) net.Broadcast()
	MsgN( "[MC] world cleared" )
end )

concommand.Add( "mc_resync", function( ply )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local targets = IsValid( ply ) and { ply } or player.GetAll()
	for _, p in ipairs( targets ) do
		net.Start( "mc_clear" )
		net.Send( p )
		SV.BeginSync( p )
	end
	MsgN( "[MC] resync requested for " .. #targets .. " player(s)" )
end )

-- diagnostics: run `mc_diag` (aim roughly at a build). Prints to your console.
concommand.Add( "mc_diag", function( ply )
	if not IsValid( ply ) then return end

	local function out( s )
		ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. s )
		MsgN( "[MC diag] " .. s )
	end

	-- 1) what did the eye trace actually hit? (is the block collision being struck?)
	local tr = ply:GetEyeTrace()
	local he = tr.Entity
	local entdesc = tr.HitWorld and "worldspawn(map)" or
		( IsValid( he ) and ( he:GetClass() .. "[" .. he:EntIndex() .. "]" ) or "none" )
	out( "--- trace ---" )
	out( "hit=" .. tostring( tr.Hit ) .. "  hitworld=" .. tostring( tr.HitWorld ) .. "  ent=" .. entdesc )
	out( "hitpos=" .. tostring( tr.HitPos ) .. "  normal=" .. tostring( tr.HitNormal ) )

	local bx, by, bz = MC.WorldToCell( tr.HitPos - tr.HitNormal * 0.5 )
	local px, py, pz = MC.WorldToCell( tr.HitPos + tr.HitNormal * 0.5 )
	out( "break cell = " .. bx .. "," .. by .. "," .. bz .. "  (id " .. MC.GetBlock( bx, by, bz ) .. ")" )
	out( "place cell = " .. px .. "," .. py .. "," .. pz .. "  (id " .. MC.GetBlock( px, py, pz ) .. ")" )

	-- 2) alignment dump of EVERY placed chunk (independent of aim). DRIFT must be 0:
	--    DRIFT > 0 means the entity moved off its chunk origin -> collision no longer
	--    matches the mesh.
	out( "--- chunks (total blocks " .. SV.BlockCount .. ") ---" )
	local n = 0
	for key, c in pairs( MC.World ) do
		if c.count > 0 then
			n = n + 1
			local minBZ, maxBZ
			for li in pairs( c.blocks ) do
				local _, _, lz = MC.DecodeLocal( li )
				local bz = c.cz * MC.CH + lz
				minBZ = minBZ and math.min( minBZ, bz ) or bz
				maxBZ = maxBZ and math.max( maxBZ, bz ) or bz
			end
			local e = c.ent
			if not IsValid( e ) then
				out( key .. "  count=" .. c.count .. "  bz=" .. tostring( minBZ ) .. ".." .. tostring( maxBZ ) .. "  *** ENT INVALID ***" )
			else
				local phys = e:GetPhysicsObject()
				local exp  = MC.ChunkWorldOrigin( c.cx, c.cy, c.cz )
				local pos  = e:GetPos()
				out( key .. "  count=" .. c.count ..
					"  bz=" .. tostring( minBZ ) .. ".." .. tostring( maxBZ ) ..
					"  solid=" .. e:GetSolid() .. "/" .. SOLID_VPHYSICS ..
					"  mtype=" .. e:GetMoveType() ..
					"  phys=" .. tostring( IsValid( phys ) ) ..
					( IsValid( phys ) and ( "  vol=" .. math.Round( phys:GetVolume() ) ) or "" ) )
				out( "     pos=" .. tostring( pos ) .. "  expected=" .. tostring( exp ) ..
					"  DRIFT=" .. string.format( "%.2f", ( pos - exp ):Length() ) )
				-- list real block cells so we can compare against the trace's break/place cell
				local cells, m = {}, 0
				for li in pairs( c.blocks ) do
					m = m + 1
					if m <= 8 then
						local lx, ly, lz = MC.DecodeLocal( li )
						cells[m] = ( c.cx * MC.CS + lx ) .. "," .. ( c.cy * MC.CS + ly ) .. "," .. ( c.cz * MC.CH + lz )
					end
				end
				if m > 8 then cells[#cells + 1] = "(+" .. ( m - 8 ) .. " more)" end
				out( "     block cells: " .. table.concat( cells, "  " ) )
			end
		end
	end
	if n == 0 then out( "(no placed chunks)" ) end
end )

-- force a collision rebuild on every existing chunk (admin); use after updating code
concommand.Add( "mc_rebuild", function( ply )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local n = 0
	for key, c in pairs( MC.World ) do
		if c.count > 0 then
			SV.EnsureChunkEnt( c )
			SV.MarkPhysDirty( key )
			n = n + 1
		end
	end
	MsgN( "[MC] rebuilding collision for " .. n .. " chunks" )
	if IsValid( ply ) then ply:ChatPrint( "[MC] 重建了 " .. n .. " 个区块的碰撞" ) end
end )
