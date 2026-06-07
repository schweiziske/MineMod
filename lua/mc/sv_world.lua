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
SV.PhysDirty  = SV.PhysDirty or {}   -- chunkKey -> true (collision needs rebuild)
SV.SyncQueue  = SV.SyncQueue or {}   -- player   -> { keys = {}, i = 1 }
SV.Dirty      = SV.Dirty or false    -- world changed since last save

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
	SV.PhysDirty[key] = true
end

-- debounced collision rebuild (coalesces many edits in the same frame/window)
timer.Create( "mc_phys_rebuild", 0.05, 0, function()
	if not next( SV.PhysDirty ) then return end
	for key in pairs( SV.PhysDirty ) do
		local chunk = MC.GetChunkByKey( key )
		if chunk and IsValid( chunk.ent ) then
			chunk.ent:RebuildPhysics()
		end
		SV.PhysDirty[key] = nil
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
		and math.abs( bz ) <= lim
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
-- Broadcast a change to everyone, including still-syncing players. This is safe:
-- full-sync reads LIVE chunk state and a single set is order-independent, so a
-- syncing client always converges (mc_set before its chunk arrives -> the later
-- mc_full replaces the chunk with live state; mc_set after -> applied on top).
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

local function callBlockHandler( id, name, ... )
	local b = MC.Blocks[id]
	local fn = b and b.handlers and b.handlers[name]
	if not fn then return nil end
	return fn( ... )
end

-- core mutation shared by Place/Break/fill/demo (no validation here)
local function apply( bx, by, bz, id, _, orient, actor )
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

	broadcastSet( bx, by, bz, id, orient )
	if old ~= 0 then callBlockHandler( old, "OnBreak", actor, bx, by, bz, oldOrient ) end
	if id ~= 0 then callBlockHandler( id, "OnPlace", actor, bx, by, bz, orient ) end
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

local function importCells( data, appendMode )
	if not data or not data.chunks then return nil, "文件格式不对" end
	local importMax = C.ImportMax and C.ImportMax:GetInt() or 300000
	local cache = {}
	local imported, skippedUnknown, skippedBounds, skippedLimit = 0, 0, 0, 0

	if not appendMode then
		clearWorldNoNet()
	end

	for _, ck in ipairs( data.chunks ) do
		local cx, cy, cz, cells = math.floor( tonumber( ck[1] ) or 0 ), math.floor( tonumber( ck[2] ) or 0 ), math.floor( tonumber( ck[3] ) or 0 ), ck[4]
		if istable( cells ) then
			local c = MC.EnsureChunk( cx, cy, cz )
			for i = 1, #cells, 3 do
				local li = math.floor( tonumber( cells[i] ) or -1 )
				local savedBlock = cells[i + 1]
				local state = cells[i + 2]
				if li >= 0 and li < MC.CS * MC.CS * MC.CS then
					local lx, ly, lz = MC.DecodeLocal( li )
					local bx, by, bz = cx * MC.CS + lx, cy * MC.CS + ly, cz * MC.CS + lz
					if not worldBoundsOK( bx, by, bz ) then
						skippedBounds = skippedBounds + 1
					elseif importMax > 0 and SV.BlockCount >= importMax and c.blocks[li] == nil then
						skippedLimit = skippedLimit + 1
					else
						local id = blockFromImport( cache, savedBlock )
						if id == 0 or not MC.IsValidBlock( id ) then
							skippedUnknown = skippedUnknown + 1
						else
							if c.blocks[li] == nil then
								c.count = c.count + 1
								SV.BlockCount = SV.BlockCount + 1
							end
							c.blocks[li] = id
							c.orients[li] = MC.NormalizeOrient( id, MC.StateToOrient( id, state ) )
							imported = imported + 1
						end
					end
				end
			end
			if c.count > 0 then
				SV.EnsureChunkEnt( c )
				SV.MarkPhysDirty( c.key )
			else
				MC.World[c.key] = nil
			end
		end
	end

	SV.Dirty = true
	resyncAllClients()
	return {
		imported = imported,
		total = SV.BlockCount,
		skippedUnknown = skippedUnknown,
		skippedBounds = skippedBounds,
		skippedLimit = skippedLimit,
	}
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

	local result, err = importCells( data, appendMode )
	if not result then chat( ply, "导入失败: " .. tostring( err ) ) return end
	local msg = string.format( "导入完成: %d 个方块，当前总数 %d，跳过未知 %d，越界 %d，超上限 %d",
		result.imported, result.total, result.skippedUnknown, result.skippedBounds, result.skippedLimit )
	chat( ply, msg )
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

------------------------------------------------------------------ world streaming
local function sendChunk( ply, chunk )
	net.Start( "mc_full" )
		net.WriteInt( chunk.cx, Net.COORD_BITS )
		net.WriteInt( chunk.cy, Net.COORD_BITS )
		net.WriteInt( chunk.cz, Net.COORD_BITS )
		net.WriteUInt( chunk.count, Net.COUNT_BITS )
		for li, id in pairs( chunk.blocks ) do
			net.WriteUInt( li, Net.LOCAL_BITS )
			net.WriteUInt( id, Net.ID_BITS )
			net.WriteUInt( MC.NormalizeOrient( id, chunk.orients and chunk.orients[li] ), Net.ORIENT_BITS )
		end
	net.Send( ply )
end

function SV.BeginSync( ply )
	local keys = {}
	for key in pairs( MC.World ) do keys[#keys + 1] = key end
	SV.SyncQueue[ply] = { keys = keys, i = 1 }
end

-- drip a few chunks per tick to each syncing player
timer.Create( "mc_sync", 0.1, 0, function()
	for ply, q in pairs( SV.SyncQueue ) do
		if not IsValid( ply ) then SV.SyncQueue[ply] = nil continue end
		local sent = 0
		while q.i <= #q.keys and sent < 4 do
			local chunk = MC.GetChunkByKey( q.keys[q.i] )
			if chunk and chunk.count > 0 then
				sendChunk( ply, chunk )
				sent = sent + 1
			end
			q.i = q.i + 1
		end
		if q.i > #q.keys then SV.SyncQueue[ply] = nil end
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

function SV.Save()
	local chunks = {}
	for _, c in pairs( MC.World ) do
		if c.count > 0 then
			local cells = {}
			local n = 0
			for li, id in pairs( c.blocks ) do
				n = n + 1 ; cells[n] = li
				n = n + 1 ; cells[n] = MC.BlockCanonicalName( id )
				n = n + 1 ; cells[n] = MC.BlockStateText( id, c.orients and c.orients[li] )
			end
			chunks[#chunks + 1] = { c.cx, c.cy, c.cz, cells }
		end
	end
	local json = util.TableToJSON( { v = 3, bs = MC.BS, cs = MC.CS, chunks = chunks } )
	if not json then return end
	file.CreateDir( "mc" )
	file.Write( savePath(), util.Compress( json ) )
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

	MC.World = {}
	SV.BlockCount = 0

	for _, ck in ipairs( data.chunks ) do
		local cx, cy, cz, cells = ck[1], ck[2], ck[3], ck[4]
		local c = MC.EnsureChunk( cx, cy, cz )
		local stride = ( data.v == 2 or data.v == 3 ) and 3 or 2
		for i = 1, #cells, stride do
			local li, savedBlock = cells[i], cells[i + 1]
			local resolved = data.v == 3 and MC.ResolveBlock( savedBlock ) or nil
			local id = resolved and resolved.id or math.floor( tonumber( savedBlock ) or 0 )
			local orient = stride == 3 and MC.StateToOrient( id, cells[i + 2] ) or MC.DefaultOrient( id )
			if MC.IsValidBlock( id ) and c.blocks[li] == nil then
				c.blocks[li] = id
				c.orients[li] = MC.NormalizeOrient( id, orient )
				c.count = c.count + 1
				SV.BlockCount = SV.BlockCount + 1
			end
		end
		if c.count > 0 then
			SV.EnsureChunkEnt( c )
			SV.MarkPhysDirty( c.key )
		else
			MC.World[c.key] = nil
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
			local e = c.ent
			if not IsValid( e ) then
				out( key .. "  count=" .. c.count .. "  *** ENT INVALID ***" )
			else
				local phys = e:GetPhysicsObject()
				local exp  = MC.ChunkWorldOrigin( c.cx, c.cy, c.cz )
				local pos  = e:GetPos()
				out( key .. "  count=" .. c.count ..
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
						cells[m] = ( c.cx * MC.CS + lx ) .. "," .. ( c.cy * MC.CS + ly ) .. "," .. ( c.cz * MC.CS + lz )
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
