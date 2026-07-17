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

local function L( ply, key, fallback, vars )
	return MC.TFor and MC.TFor( ply, key, fallback, vars ) or fallback
end

local BULK_SET_CELLS_PER_MESSAGE = 1024
local GMOD_NET_MAX_BYTES = 65533
local NET_MESSAGE_OVERHEAD_BYTES = 64
local BULK_SET_CELL_BITS = Net.COORD_BITS * 3 + Net.ID_BITS + Net.ORIENT_BITS
local BULK_SET_HEADER_BITS = Net.COUNT_BITS + 1
local BULK_SET_FAST_CELLS_PER_MESSAGE = math.max( 1, math.min(
	bit.lshift( 1, Net.COUNT_BITS ) - 1,
	math.floor( ( ( GMOD_NET_MAX_BYTES - NET_MESSAGE_OVERHEAD_BYTES ) * 8 - BULK_SET_HEADER_BITS ) / BULK_SET_CELL_BITS )
) )
local BULK_BREAK_FX_LIMIT = 64
local SYNC_TIMER_INTERVAL = 0.05
local INTEREST_TIMER_INTERVAL = 0.25

SV.BlockCount = SV.BlockCount or 0
SV.BlockRevision = SV.BlockRevision or 0 -- one increment per committed authoritative transaction
SV.PhysDirty  = SV.PhysDirty or {}   -- chunkKey -> due time (collision needs rebuild)
SV.PhysDirtyPriority = SV.PhysDirtyPriority or {} -- player edits should not wait behind bulk rebuilds
SV.PhysDirtyBulk = SV.PhysDirtyBulk or {} -- chunkKey -> true when explosion/preset collision rebuild is throttled
SV.PhysDirtyBulkOrder = SV.PhysDirtyBulkOrder or {}
SV.SyncQueue  = SV.SyncQueue or {}   -- player -> { keys = {}, i = 1, active = nil }
SV.SnapshotQueue = SV.SnapshotQueue or {} -- player -> compressed save snapshot transfer state
SV.ReliableNetQueues = SV.ReliableNetQueues or {} -- player -> shared reliable send queue
SV.PlayerLoadedChunks = SV.PlayerLoadedChunks or {} -- player -> { [chunkKey] = true }
SV.PlayerFullSnapshot = SV.PlayerFullSnapshot or {} -- player -> true once full-world snapshot mode owns visibility
SV.PlayerHTTPDisabled = SV.PlayerHTTPDisabled or {} -- player -> true after client-side HTTP fetch is blocked/failed
SV.ServerCollisionActiveChunks = SV.ServerCollisionActiveChunks or {} -- chunkKey -> true for non-empty chunks with server collision
SV.ServerCollisionSignatures = SV.ServerCollisionSignatures or {} -- chunkKey -> sorted bounds signature
SV.ServerCollisionRefreshTick = SV.ServerCollisionRefreshTick or nil
SV.NextBulkCollisionRebuildAt = SV.NextBulkCollisionRebuildAt or 0
SV.CollisionDebugPlayers = SV.CollisionDebugPlayers or setmetatable( {}, { __mode = "k" } )
SV.Dirty      = SV.Dirty or false    -- world changed since last save

local function syncFastEnabled()
	return not C.SyncFast or C.SyncFast:GetBool()
end

local function syncCellsPerPart()
	if C.SyncCells then
		return math.Clamp( C.SyncCells:GetInt(), 1, MC.CS * MC.CS * MC.CH )
	end
	return C.SyncCellsPerPart or 2048
end

local function syncMessagesPerTick()
	if C.SyncMsgs then
		return math.Clamp( C.SyncMsgs:GetInt(), 1, syncFastEnabled() and 128 or 16 )
	end
	return C.SyncMessagesPerTick or 4
end

local function syncReliableBudget()
	if C.SyncBudget then
		return math.Clamp( C.SyncBudget:GetInt(), 2048, syncFastEnabled() and 8192 or 6144 )
	end
	return C.SyncReliableBudget or 32768
end

local function syncFrameSeconds()
	if not syncFastEnabled() then return nil end
	if C.SyncFrame then
		return math.Clamp( C.SyncFrame:GetFloat(), 0.25, 20 ) / 1000
	end
	return ( C.SyncFrameMS or 4 ) / 1000
end

local function syncInFlightLimit()
	if not syncFastEnabled() then return math.huge end
	if C.SyncWindow then
		return math.Clamp( C.SyncWindow:GetInt(), 32768, 131072 )
	end
	return C.SyncInFlightLimit or 65536
end

local function sharedReliableBudget()
	return math.min( syncReliableBudget(), 32768 )
end

local function syncSnapshotEnabled()
	if C.SyncSnapshot then return C.SyncSnapshot:GetBool() end
	return ( C.SyncSnapshot or 1 ) ~= 0
end

local function syncSnapshotPartBytes()
	if C.SyncSnapshotPartBytes then
		return math.Clamp( C.SyncSnapshotPartBytes:GetInt(), 4096, 60000 )
	end
	return C.SyncSnapshotPartBytes or 32768
end

local function httpChunkDeliveryEnabled()
	if C.ChunkHTTPEnabled then return C.ChunkHTTPEnabled:GetBool() end
	return ( MC.Config.ChunkHTTPEnabled or 0 ) ~= 0
end

local function httpChunkBaseURL()
	local url
	if C.ChunkHTTPBaseURL and C.ChunkHTTPBaseURL.GetString then
		url = C.ChunkHTTPBaseURL:GetString()
	else
		url = MC.Config.ChunkHTTPBaseURL
	end
	url = string.Trim( tostring( url or "" ) )
	return string.gsub( url, "/+$", "" )
end

local function httpChunkDeliveryActive()
	return httpChunkDeliveryEnabled()
		and httpChunkBaseURL() ~= ""
		and SV.ChunkStore
		and SV.ChunkStore.IsLazyWorld
		and SV.ChunkStore.IsLazyWorld()
end

local function playerHttpChunkDeliveryActive( ply )
	return httpChunkDeliveryActive()
		and not ( SV.PlayerHTTPDisabled and SV.PlayerHTTPDisabled[ply] )
end

function SV.IsChunkCollisionActive( key )
	local chunk = MC.GetChunkByKey( key )
	return chunk and chunk.count and chunk.count > 0
end

local function decodeLocalWithGeometry( li, chunkSize, height )
	chunkSize = math.floor( tonumber( chunkSize ) or MC.CS )
	if chunkSize <= 0 then chunkSize = MC.CS end
	height = math.floor( tonumber( height ) or MC.CH )
	if height <= 0 then height = MC.CH end
	local cs2 = chunkSize * chunkSize
	if li < 0 or li >= cs2 * height then return nil end
	local lz = math.floor( li / cs2 )
	local rem = li - lz * cs2
	local ly = math.floor( rem / chunkSize )
	local lx = rem - ly * chunkSize
	return lx, ly, lz
end

------------------------------------------------------------------ chunk entities
function SV.EnsureChunkEnt( chunk, force )
	if IsValid( chunk.ent ) then return chunk.ent end
	if not force and not SV.IsChunkCollisionActive( chunk.key ) then return nil end
	local e = ents.Create( "mc_chunk" )
	if not IsValid( e ) then return nil end
	e.cx, e.cy, e.cz = chunk.cx, chunk.cy, chunk.cz
	e.ChunkKey = chunk.key
	e:SetNWString( "MCChunkKey", tostring( chunk.key ) )
	e:SetPos( MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz ) )
	e:Spawn()
	e:Activate()
	chunk.ent = e
	return e
end

local rebuildPhysKey

function SV.MarkPhysDirty( key, priority, bounds )
	if not key then return end
	if SV.PhysDirtyBulk then SV.PhysDirtyBulk[key] = nil end
	if priority then
		SV.PhysDirty[key] = true
		SV.PhysDirtyPriority[key] = true
	else
		SV.PhysDirty[key] = true
		SV.PhysDirtyPriority[key] = nil
	end
	if rebuildPhysKey then rebuildPhysKey( key, bounds ) end
end

function SV.MarkPhysDirtyBulk( key )
	if not key then return end
	SV.PhysDirty[key] = true
	SV.PhysDirtyPriority[key] = nil
	if not SV.PhysDirtyBulk[key] then
		SV.PhysDirtyBulk[key] = true
		SV.PhysDirtyBulkOrder[#SV.PhysDirtyBulkOrder + 1] = key
	end
end

function rebuildPhysKey( key, bounds )
	local chunk = MC.GetChunkByKey( key )
	if chunk and not SV.IsChunkCollisionActive( key ) then
		if IsValid( chunk.ent ) then
			chunk.ent:Remove()
			chunk.ent = nil
		end
		return
	end
	if chunk and IsValid( chunk.ent ) then
		SV.EnsureChunkEnt( chunk )
		chunk.ent:RebuildPhysics()
	elseif chunk and chunk.count and chunk.count > 0 then
		SV.EnsureChunkEnt( chunk )
		if IsValid( chunk.ent ) then
			chunk.ent:RebuildPhysics()
		end
	end
	SV.PhysDirty[key] = nil
	SV.PhysDirtyPriority[key] = nil
	if SV.PhysDirtyBulk then SV.PhysDirtyBulk[key] = nil end
end

local function flushPhysDirtyKeys( keys )
	for key, bounds in pairs( keys or {} ) do
		if SV.PhysDirty[key] then
			rebuildPhysKey( key, istable( bounds ) and bounds or nil )
		end
	end
end

local function bulkCollisionInterval()
	if C.BulkCollisionInterval then return math.max( 0, C.BulkCollisionInterval:GetFloat() ) end
	return MC.Config.BulkCollisionInterval or 0.12
end

local function bulkCollisionChunksPerInterval()
	if C.BulkCollisionChunksPerInterval then
		return math.max( 1, C.BulkCollisionChunksPerInterval:GetInt() )
	end
	return math.max( 1, MC.Config.BulkCollisionChunksPerInterval or 1 )
end

local function flushBulkCollisionQueue()
	local now = CurTime()
	if now < ( SV.NextBulkCollisionRebuildAt or 0 ) then return end
	local limit = bulkCollisionChunksPerInterval()
	local built = 0

	while built < limit and #SV.PhysDirtyBulkOrder > 0 do
		local key = table.remove( SV.PhysDirtyBulkOrder, 1 )
		if SV.PhysDirtyBulk[key] and SV.PhysDirty[key] then
			rebuildPhysKey( key )
			built = built + 1
		else
			SV.PhysDirtyBulk[key] = nil
		end
	end

	if built > 0 then
		SV.NextBulkCollisionRebuildAt = now + bulkCollisionInterval()
	end
end

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

function SV.Chat( ply, msg )
	chat( ply, msg )
end

local function canEdit( ply )
	if C.AdminOnly:GetBool() and IsValid( ply ) and not ply:IsAdmin() then
		notify( ply, L( ply, "server.admin_build", "只有管理员可以建造 (mc_admin_only)" ) )
		return false
	end
	return true
end

function SV.CanEdit( ply )
	return canEdit( ply )
end

local function worldBoundsOK( bx, by, bz )
	local protoMax = bit.lshift( 1, Net.COORD_BITS - 1 ) - 1
	local lim = math.min( C.WorldLimit:GetInt(), protoMax )
	return math.abs( bx ) <= lim
		and math.abs( by ) <= lim
end

function SV.WorldBoundsOK( bx, by, bz )
	return worldBoundsOK( bx, by, bz )
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
			notify( ply, L( ply, "server.world_limit", "超出建造范围 (mc_world_limit)" ) )
			return false
		end
		local maxBlocks = C.MaxBlocks:GetInt()
		if maxBlocks > 0 and SV.BlockCount >= maxBlocks then
			notify( ply, L( ply, "server.max_blocks", "已达到方块上限 (mc_max_blocks)" ) )
			return false
		end
	end

	return true
end

--------------------------------------------------------------- reliable net queue
local function reliableTargetPlayers( target )
	if istable( target ) then
		local out = {}
		for _, ply in ipairs( target ) do
			if IsValid( ply ) then out[#out + 1] = ply end
		end
		return out
	end
	if IsValid( target ) then return { target } end
	return {}
end

local function compactReliableQueue( q )
	if ( q.head or 1 ) <= 32 then return end
	if q.head <= #q.items * 0.5 then return end
	local compacted = {}
	for i = q.head, #q.items do compacted[#compacted + 1] = q.items[i] end
	q.items = compacted
	q.head = 1
end

function SV.EnqueueReliableNet( target, bytes, sendFn, waitAck )
	if not isfunction( sendFn ) then return false end
	bytes = math.max( 1, math.floor( tonumber( bytes ) or 1 ) )
	local queued = false

	for _, ply in ipairs( reliableTargetPlayers( target ) ) do
		local q = SV.ReliableNetQueues[ply]
		if not q then
			q = { items = {}, head = 1, inflightBytes = 0 }
			SV.ReliableNetQueues[ply] = q
		end
		q.items[#q.items + 1] = {
			bytes = bytes,
			send = sendFn,
			waitAck = waitAck == true and not ply:IsBot(),
		}
		queued = true
	end

	return queued
end

function SV.ClearReliableNet( target )
	for _, ply in ipairs( reliableTargetPlayers( target ) ) do
		SV.ReliableNetQueues[ply] = nil
	end
end

timer.Create( "mc_reliable_net", SYNC_TIMER_INTERVAL, 0, function()
	local frameBudget = syncFrameSeconds()
	local deadline = frameBudget and ( SysTime() + frameBudget ) or nil

	for ply, q in pairs( SV.ReliableNetQueues ) do
		if not IsValid( ply ) then
			SV.ReliableNetQueues[ply] = nil
			continue
		end

		local sent = 0
		local sentBytes = 0
		local messageBudget = syncMessagesPerTick()
		local byteBudget = math.min( sharedReliableBudget(), syncInFlightLimit() )
		local inflightLimit = syncInFlightLimit()

		while sent < messageBudget do
			if deadline and SysTime() >= deadline then break end
			local item = q.items[q.head or 1]
			if not item then break end
			local itemBytes = math.max( 1, math.floor( tonumber( item.bytes ) or 1 ) )
			if item.waitAck and ( q.inflightBytes or 0 ) + itemBytes > inflightLimit then break end
			if sent > 0 and sentBytes + itemBytes > byteBudget then break end

			if item.send( ply ) == false then
				SV.ReliableNetQueues[ply] = nil
				break
			end
			q.head = ( q.head or 1 ) + 1
			sent = sent + 1
			sentBytes = sentBytes + itemBytes
			if item.waitAck then
				q.inflightBytes = ( q.inflightBytes or 0 ) + itemBytes
			end
		end

		if SV.ReliableNetQueues[ply] == q then
			if not q.items[q.head or 1] and ( q.inflightBytes or 0 ) <= 0 then
				SV.ReliableNetQueues[ply] = nil
			else
				compactReliableQueue( q )
			end
		end
	end
end )

net.Receive( "mc_reliable_ack", function( _, ply )
	local q = SV.ReliableNetQueues[ply]
	if not q then return end
	local bytes = math.Clamp( net.ReadUInt( 32 ), 0, 4194304 )
	q.inflightBytes = math.max( 0, ( q.inflightBytes or 0 ) - bytes )
	if not q.items[q.head or 1] and q.inflightBytes <= 0 then
		SV.ReliableNetQueues[ply] = nil
	end
end )

------------------------------------------------------------- single block update
local function broadcastSet( bx, by, bz, id, orient )
	orient = MC.NormalizeOrient( id, orient )
	net.Start( "mc_set" )
		net.WriteInt( bx, Net.COORD_BITS )
		net.WriteInt( by, Net.COORD_BITS )
		net.WriteInt( bz, Net.COORD_BITS )
		net.WriteUInt( id, Net.ID_BITS )
		net.WriteUInt( orient or 0, Net.ORIENT_BITS )
	net.Broadcast()
end

local function liveBulkTarget( target )
	if istable( target ) then
		local live = {}
		for _, ply in ipairs( target ) do
			if IsValid( ply ) then live[#live + 1] = ply end
		end
		if #live == 0 then return nil end
		return live
	end
	if IsValid( target ) then return target end
	return target
end

local function estimateBulkSetBytes( count )
	count = math.max( 0, math.floor( tonumber( count ) or 0 ) )
	return math.ceil( ( BULK_SET_HEADER_BITS + count * BULK_SET_CELL_BITS ) / 8 ) + NET_MESSAGE_OVERHEAD_BYTES
end

local function sendSetBulkMessage( changes, target, netName, explosionMeshThrottle, first, count, ackBytes )
	target = liveBulkTarget( target )
	if not target then return false end
	net.Start( netName )
		net.WriteUInt( count, Net.COUNT_BITS )
		for j = first, first + count - 1 do
			local cell = changes[j]
			local id = math.floor( tonumber( cell.id ) or 0 )
			local orient = MC.NormalizeOrient( id, cell.orient )
			net.WriteInt( cell.bx, Net.COORD_BITS )
			net.WriteInt( cell.by, Net.COORD_BITS )
			net.WriteInt( cell.bz, Net.COORD_BITS )
			net.WriteUInt( id, Net.ID_BITS )
			net.WriteUInt( orient or 0, Net.ORIENT_BITS )
		end
		net.WriteBool( explosionMeshThrottle )
		if ackBytes then net.WriteUInt( ackBytes, 32 ) end
	net.Send( target )
	return true
end

local function sendSetBulk( changes, target, options )
	if #changes == 0 then return end
	if not target then return end
	options = options or {}
	local explosionMeshThrottle = options.explosionMeshThrottle == true
	local netName = explosionMeshThrottle and "mc_set_bulk" or "mc_set_bulk_fast"
	local defaultCellsPerMessage = explosionMeshThrottle and BULK_SET_CELLS_PER_MESSAGE or BULK_SET_FAST_CELLS_PER_MESSAGE
	local cellsPerMessage = math.Clamp( math.floor( tonumber( options.cellsPerMessage ) or defaultCellsPerMessage ), 1, defaultCellsPerMessage )
	local i = 1

	if options.netPaced == true then
		while i <= #changes do
			local first = i
			local count = math.min( cellsPerMessage, #changes - i + 1 )
			local bytes = estimateBulkSetBytes( count )
			SV.EnqueueReliableNet( target, bytes, function( ply )
				return sendSetBulkMessage( changes, ply, netName, explosionMeshThrottle, first, count, bytes )
			end, true )
			i = i + count
		end
		return
	end

	while i <= #changes do
		local count = math.min( cellsPerMessage, #changes - i + 1 )
		sendSetBulkMessage( changes, target, netName, explosionMeshThrottle, i, count )
		i = i + count
	end
end

local function broadcastSetBulk( changes, options )
	sendSetBulk( changes, player.GetAll(), options )
end

-- a player-predicted edit got rejected: push the authoritative cell state back
-- to that player right away instead of waiting for the client's prediction
-- rollback timer (the client's mc_set receiver overwrites the misprediction)
function SV.SyncCell( ply, bx, by, bz )
	if not IsValid( ply ) then return end
	if SV.SendStateCorrection then
		SV.SendStateCorrection( ply, bx, by, bz, MC.GetBlockState( bx, by, bz ), SV.BlockRevision )
		return
	end
	net.Start( "mc_set" )
		net.WriteInt( bx, Net.COORD_BITS )
		net.WriteInt( by, Net.COORD_BITS )
		net.WriteInt( bz, Net.COORD_BITS )
		net.WriteUInt( MC.GetBlock( bx, by, bz ), Net.ID_BITS )
		net.WriteUInt( MC.GetBlockOrient( bx, by, bz ) or 0, Net.ORIENT_BITS )
	net.Send( ply )
end

function SV.SyncCells( ply, cells )
	if not IsValid( ply ) or not istable( cells ) or #cells == 0 then return end
	local changes = {}
	for _, cell in ipairs( cells ) do
		local bx = math.floor( tonumber( cell.bx ) or 0 )
		local by = math.floor( tonumber( cell.by ) or 0 )
		local bz = math.floor( tonumber( cell.bz ) or 0 )
		changes[#changes + 1] = {
			bx = bx, by = by, bz = bz,
			stateId = MC.GetBlockState( bx, by, bz ),
			id = MC.GetBlock( bx, by, bz ),
			orient = MC.GetBlockOrient( bx, by, bz ) or 0,
		}
	end
	if SV.SendStateCorrections then
		SV.SendStateCorrections( ply, changes, SV.BlockRevision )
		return
	elseif SV.SendStateCorrection then
		for _, change in ipairs( changes ) do
			SV.SendStateCorrection( ply, change.bx, change.by, change.bz, change.stateId, SV.BlockRevision )
		end
		return
	end
	sendSetBulk( changes, ply )
end

local function sendFx( kind, bx, by, bz, id, orient, stateId, recipients )
	if recipients == nil and #player.GetAll() == 0 then return end
	orient = MC.NormalizeOrient( id, orient )
	net.Start( "mc_fx" )
		net.WriteUInt( kind, 2 ) -- 1=place, 2=break
		net.WriteInt( bx, Net.COORD_BITS )
		net.WriteInt( by, Net.COORD_BITS )
		net.WriteInt( bz, Net.COORD_BITS )
		net.WriteUInt( id, Net.ID_BITS )
		net.WriteUInt( orient or 0, Net.ORIENT_BITS )
		net.WriteUInt( math.max( 0, math.floor( tonumber( stateId ) or 0 ) ), Net.STATE_ID_BITS or Net.ID_BITS )
	if recipients ~= nil then
		net.Send( recipients )
	else
		net.Broadcast()
	end
end

local function broadcastFx( kind, bx, by, bz, id, orient, stateId )
	sendFx( kind, bx, by, bz, id, orient, stateId )
end

local function normalizeFxKind( kind )
	if kind == "place" then return 1 end
	if kind == "break" or kind == "destroy" then return 2 end
	kind = math.floor( tonumber( kind ) or 0 )
	if kind == 1 or kind == 2 then return kind end
	return nil
end

function SV.PlayBlockFx( kind, id, orient, bx, by, bz, recipients, stateId )
	kind = normalizeFxKind( kind )
	id = math.floor( tonumber( id ) or 0 )
	if not kind then return false, "invalid_kind" end
	if id == 0 or not MC.IsValidBlock( id ) then return false, "invalid_block" end
	bx = math.floor( tonumber( bx ) or 0 )
	by = math.floor( tonumber( by ) or 0 )
	bz = math.floor( tonumber( bz ) or 0 )
	sendFx( kind, bx, by, bz, id, orient, stateId, recipients )
	return true
end

local function callBlockHandler( id, name, ... )
	local b = MC.Blocks[id]
	local fn = b and b.handlers and b.handlers[name]
	if not fn then return nil end
	return fn( ... )
end

local function cellCollisionDependsOnNeighbours( bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	return MC.BlockCollisionDependsOnNeighbours and MC.BlockCollisionDependsOnNeighbours( id ) == true
end

local function markNeighbourShapePhysDirty( bx, by, bz, priority, dirty )
	local seen = {}
	local function mark( x, y, z )
		if not cellCollisionDependsOnNeighbours( x, y, z ) then return end
		local key, bounds = MC.CellCollisionSubchunkBounds( x, y, z )
		if seen[key] then return end
		seen[key] = true
		local c = MC.GetChunkByKey( key )
		if c and c.count and c.count > 0 then
			SV.EnsureChunkEnt( c )
			SV.MarkPhysDirty( c.key, priority, { bounds } )
			if dirty then dirty[c.key] = true end
		end
	end

	mark( bx + 1, by, bz )
	mark( bx - 1, by, bz )
	mark( bx, by + 1, bz )
	mark( bx, by - 1, bz )
end

local function addDirtyBounds( dirtyBounds, key, bounds )
	if not dirtyBounds or not key or not bounds then return end
	local list = dirtyBounds[key]
	if not list then
		list = {}
		dirtyBounds[key] = list
	end
	for _, existing in ipairs( list ) do
		if existing[1] == bounds[1] and existing[2] == bounds[2] and existing[3] == bounds[3]
		and existing[4] == bounds[4] and existing[5] == bounds[5] and existing[6] == bounds[6] then
			return
		end
	end
	list[#list + 1] = bounds
end

local function collectCellPhysDirty( dirty, immediateDirty, dirtyBounds, bx, by, bz )
	local function mark( x, y, z )
		local key, bounds = MC.CellCollisionSubchunkBounds( x, y, z )
		dirty[key] = true
		addDirtyBounds( dirtyBounds, key, bounds )
		return key
	end
	local function markNeighbour( x, y, z )
		if cellCollisionDependsOnNeighbours( x, y, z ) then
			mark( x, y, z )
		end
	end

	local primaryKey = mark( bx, by, bz )
	if immediateDirty then immediateDirty[primaryKey] = dirtyBounds and dirtyBounds[primaryKey] or true end
	markNeighbour( bx + 1, by, bz )
	markNeighbour( bx - 1, by, bz )
	markNeighbour( bx, by + 1, bz )
	markNeighbour( bx, by - 1, bz )
end

local wouldTrapPlayer

local function normalizeWriteOptions( options )
	if istable( options ) then return options end
	if options ~= nil then return { actor = options } end
	return {}
end

local function stateFromLegacyWrite( id, orient )
	id = math.floor( tonumber( id ) or 0 )
	if id ~= 0 and not MC.IsValidBlock( id ) then return nil, "invalid_block" end
	local stateId, exact, err = MC.StateFromLegacy( id, id ~= 0 and MC.NormalizeOrient( id, orient ) or 0 )
	if not stateId then return nil, err or "invalid_state" end
	if exact ~= true then return nil, "state_not_legacy_projectable" end
	return stateId
end

-- a placed block must not overlap a living player's hull (don't trap / suffocate them)
wouldTrapPlayer = function( bx, by, bz, id, orient )
	return MC.PlacementOverlapsPlayerHull( bx, by, bz, id, orient )
end

-- Narrow host surface consumed by state/sv_block_transaction.lua. Keeping
-- these world-specific effects here lets the transaction module stay focused
-- without turning every local networking/physics helper into a public API.
SV.BlockTransactionHost = {
	normalizeWriteOptions = normalizeWriteOptions,
	stateFromLegacyWrite = stateFromLegacyWrite,
	wouldTrapPlayer = function( ... ) return wouldTrapPlayer( ... ) end,
	callBlockHandler = callBlockHandler,
	collectCellPhysDirty = collectCellPhysDirty,
	flushPhysDirtyKeys = flushPhysDirtyKeys,
	broadcastSet = broadcastSet,
	broadcastSetBulk = broadcastSetBulk,
	broadcastFx = broadcastFx,
}

function SV.PlacementWouldTrapPlayer( bx, by, bz, id, orient )
	return wouldTrapPlayer( bx, by, bz, id, orient )
end

local function validateReach( ply, bx, by, bz )
	local reach = C.Reach:GetFloat()
	if reach > 0 and IsValid( ply ) then
		if not MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, reach ) then
			notify( ply, "Too far (mc_reach)" )
			return false
		end
	end
	return true
end

local function validatePlacementPlan( ply, plan )
	if not plan or not plan.cells or #plan.cells == 0 then return false end
	if not cooldownOK( ply ) then return false end
	if not canEdit( ply ) then return false end
	if not validateReach( ply, plan.bx, plan.by, plan.bz ) then return false end

	local add = 0
	for _, cell in ipairs( plan.cells ) do
		if cell.stateId ~= nil and ( not MC.IsValidBlockState or not MC.IsValidBlockState( cell.stateId ) or cell.stateId == 0 ) then
			return false
		end
		if not worldBoundsOK( cell.bx, cell.by, cell.bz ) then
			notify( ply, L( ply, "server.world_limit", "Out of build range (mc_world_limit)" ) )
			return false
		end
		local existingId = MC.GetBlock( cell.bx, cell.by, cell.bz )
		if cell.updateExisting then
			if existingId == 0 or existingId ~= cell.id then return false end
		else
			if existingId ~= 0 then return false end
			if wouldTrapPlayer( cell.bx, cell.by, cell.bz, cell.id, cell.orient ) then
				notify( ply, "A player is in the way" )
				return false
			end
			add = add + 1
		end
	end

	local maxBlocks = C.MaxBlocks:GetInt()
	if maxBlocks > 0 and SV.BlockCount + add > maxBlocks then
		notify( ply, L( ply, "server.max_blocks", "Block limit reached (mc_max_blocks)" ) )
		return false
	end
	return true
end

local function validateBreakPlan( ply, plan )
	if not plan or not plan.cells or #plan.cells == 0 then return false end
	if not cooldownOK( ply ) then return false end
	if not canEdit( ply ) then return false end
	return validateReach( ply, plan.bx, plan.by, plan.bz )
end

function SV.PlaceState( ply, bx, by, bz, stateId )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId <= 0 or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return false end
	local plan = MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
	if not validatePlacementPlan( ply, plan ) then return false end
	local result = SV.ApplyBlockTransaction( plan.cells, {
		actor = ply,
		priorityPhys = true,
		immediatePhys = true,
		fxIndex = 1,
		netMode = "bulk",
	})
	return result.ok == true and result.changed > 0
end

function SV.Place( ply, bx, by, bz, id, orient )
	if not MC.IsValidBlock( id ) then return false end
	local plan = MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
	if not validatePlacementPlan( ply, plan ) then return false end
	local result = SV.ApplyBlockTransaction( plan.cells, {
		actor = ply,
		priorityPhys = true,
		immediatePhys = true,
		fxIndex = 1,
		netMode = "bulk",
	} )
	return result.ok == true and result.changed > 0
end

function SV.Break( ply, bx, by, bz )
	local plan = MC.BuildBreakPlan and MC.BuildBreakPlan( bx, by, bz )
	if not validateBreakPlan( ply, plan ) then return false end
	local result = SV.ApplyBlockTransaction( plan.cells, {
		actor = ply,
		priorityPhys = true,
		immediatePhys = true,
		fxIndex = 1,
		netMode = "bulk",
	} )
	return result.ok == true and result.changed > 0
end

function SV.SyncPlacementPlan( ply, bx, by, bz, id, orient )
	local plan = MC.BuildPlacementPlan and MC.BuildPlacementPlan( bx, by, bz, id, orient )
	if plan then
		SV.SyncCells( ply, plan.cells )
	else
		SV.SyncCell( ply, bx, by, bz )
	end
end

function SV.SyncBreakPlan( ply, bx, by, bz )
	local plan = MC.BuildBreakPlan and MC.BuildBreakPlan( bx, by, bz )
	if plan then
		SV.SyncCells( ply, plan.cells )
	else
		SV.SyncCell( ply, bx, by, bz )
	end
end

function SV.SetBlockState( bx, by, bz, stateId, options )
	options = normalizeWriteOptions( options )
	local transactionOptions = {}
	for key, value in pairs( options ) do transactionOptions[key] = value end
	transactionOptions.fx = options.fx ~= false
	transactionOptions.netMode = "single"
	return SV.ApplyBlockTransaction( {
		{ bx = bx, by = by, bz = bz, stateId = stateId, blockEntity = options.blockEntity },
	}, transactionOptions )
end

function SV.SyncPlacementStatePlan( ply, bx, by, bz, stateId )
	local plan = MC.BuildPlacementStatePlan and MC.BuildPlacementStatePlan( bx, by, bz, stateId )
	if plan then
		SV.SyncCells( ply, plan.cells )
	else
		SV.SyncCell( ply, bx, by, bz )
	end
end

function SV.SetBlock( bx, by, bz, id, orient, options )
	local stateId, err = stateFromLegacyWrite( id, orient )
	if not stateId then return false, err end
	local result = SV.SetBlockState( bx, by, bz, stateId, options )
	if result.ok ~= true then return false, result.error end
	if result.changed == 0 then return false, "unchanged" end
	return true
end

function SV.SetBlockSpec( bx, by, bz, spec, options )
	local stateId, err = MC.ParseBlockState( spec )
	if not stateId then return false, err or "invalid_state" end
	local result = SV.SetBlockState( bx, by, bz, stateId, options )
	if result.ok ~= true then return false, result.error end
	if result.changed == 0 then return false, "unchanged" end
	return true
end

function SV.SetBlocksBulk( cells, options )
	options = normalizeWriteOptions( options )
	if not istable( cells ) or #cells == 0 then return 0 end
	local transactionOptions = {}
	for key, value in pairs( options ) do transactionOptions[key] = value end
	transactionOptions.netMode = "bulk"
	local result = SV.ApplyBlockTransaction( cells, transactionOptions )
	if result.ok ~= true then return 0, result.error end
	return result.changed
end

function SV.RemoveBlock( bx, by, bz, options )
	return SV.SetBlock( bx, by, bz, 0, 0, options )
end

function SV.RemoveBlocksBulk( cells, options )
	options = normalizeWriteOptions( options )
	if not istable( cells ) or #cells == 0 then return 0 end
	local airStateId, err = stateFromLegacyWrite( 0, 0 )
	if not airStateId then return 0, err end
	local removals = {}
	for i = 1, #cells do
		local cell = cells[i]
		removals[i] = { bx = cell.bx, by = cell.by, bz = cell.bz, stateId = airStateId }
	end
	local transactionOptions = {}
	for key, value in pairs( options ) do transactionOptions[key] = value end
	transactionOptions.fxLimit = options.fxLimit ~= nil and options.fxLimit or BULK_BREAK_FX_LIMIT
	transactionOptions.netMode = "bulk"
	local result = SV.ApplyBlockTransaction( removals, transactionOptions )
	if result.ok ~= true then return 0, result.error end
	return result.changed
end

function SV.Use( ply, bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b or not b.handlers or not b.handlers.OnUse then return false end
	if not SV.Validate( ply, bx, by, bz, false ) then return false end
	return b.handlers.OnUse( ply, bx, by, bz, MC.GetBlockOrient( bx, by, bz ) ) == true
end

local function trimArg( s )
	return string.match( tostring( s or "" ), "^%s*(.-)%s*$" )
end

------------------------------------------------------------------- import tool
local IMPORT_USAGE = "用法: mc_import <mc_import/文件.json> [replace|append] [reject|preserve]"

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
	if SV.ChunkStore and SV.ChunkStore.Reset then SV.ChunkStore.Reset() end
	for _, c in pairs( MC.World ) do
		if IsValid( c.ent ) then c.ent:Remove() end
	end
	MC.World = {}
	SV.BlockCount = 0
	SV.PhysDirty = {}
	SV.PhysDirtyPriority = {}
	SV.PhysDirtyBulk = {}
	SV.PhysDirtyBulkOrder = {}
	SV.SyncQueue = {}
	SV.PlayerLoadedChunks = {}
end

local function beginWorldLoadStage()
	local previous = {
		world = MC.World,
		loadedChunkKeys = MC.LoadedChunkKeys,
		blockCount = SV.BlockCount,
		physDirty = SV.PhysDirty,
		physDirtyPriority = SV.PhysDirtyPriority,
		physDirtyBulk = SV.PhysDirtyBulk,
		physDirtyBulkOrder = SV.PhysDirtyBulkOrder,
	}
	MC.World = {}
	MC.LoadedChunkKeys = {}
	SV.BlockCount = 0
	SV.PhysDirty = {}
	SV.PhysDirtyPriority = {}
	SV.PhysDirtyBulk = {}
	SV.PhysDirtyBulkOrder = {}
	return previous
end

local function restoreWorldLoadStage( previous )
	MC.World = previous.world
	MC.LoadedChunkKeys = previous.loadedChunkKeys
	SV.BlockCount = previous.blockCount
	SV.PhysDirty = previous.physDirty
	SV.PhysDirtyPriority = previous.physDirtyPriority
	SV.PhysDirtyBulk = previous.physDirtyBulk
	SV.PhysDirtyBulkOrder = previous.physDirtyBulkOrder
end

local function commitWorldLoadStage( previous )
	if SV.ChunkStore and SV.ChunkStore.Reset then SV.ChunkStore.Reset() end
	for _, chunk in pairs( previous.world or {} ) do
		if IsValid( chunk.ent ) then chunk.ent:Remove() end
	end
	SV.SyncQueue = {}
	SV.PlayerLoadedChunks = {}
	for _, chunk in pairs( MC.World ) do
		if chunk.count and chunk.count > 0 then
			SV.EnsureChunkEnt( chunk )
			SV.MarkPhysDirty( chunk.key )
		end
	end
end

local function resyncAllClients()
	net.Start( "mc_clear" )
	net.Broadcast()
	for _, p in ipairs( player.GetAll() ) do
		SV.BeginSync( p )
	end
end

-- Narrow host surface for import/sv_world_sink.lua. Import format parsing and
-- staging live in separate modules; this file only exposes world lifecycle
-- operations that already belong to server authority.
SV.WorldImportHost = {
	beginWorldLoadStage = beginWorldLoadStage,
	restoreWorldLoadStage = restoreWorldLoadStage,
	commitWorldLoadStage = commitWorldLoadStage,
	resyncAllClients = resyncAllClients,
	worldBoundsOK = worldBoundsOK,
}

local function blockFromImport( cache, savedBlock )
	local key = tostring( savedBlock or "" )
	local cached = cache[key]
	if cached ~= nil then return cached end
	local resolved = MC.ResolveBlock( key )
	local id = resolved and resolved.id or 0
	cache[key] = id
	return id
end

local function importPaletteState( cache, palette, index )
	if not istable( palette ) then return nil, "missing_palette" end
	local spec = palette[math.floor( tonumber( index ) or 0 ) + 1]
	if not isstring( spec ) then return nil, "missing_palette_state" end
	cache._states = cache._states or {}
	local cached = cache._states[spec]
	if cached ~= nil then return cached ~= false and cached or nil end
	local stateId, err = MC.ParseBlockState( spec )
	cache._states[spec] = stateId or false
	return stateId, err
end

local function loadSavedBlockEntities( chunk, envelopes )
	if envelopes == nil then return true end
	if not chunk or not istable( envelopes ) then return false, "invalid_block_entities" end
	local seen = {}
	for _, envelope in ipairs( envelopes ) do
		if not istable( envelope ) then return false, "invalid_block_entity_envelope" end
		local localIndex = math.floor( tonumber( envelope.localIndex ) or -1 )
		if not MC.LocalIndexInRange( localIndex ) or seen[localIndex] then return false, "invalid_block_entity_index" end
		seen[localIndex] = true
		local lx, ly, lz = MC.DecodeLocal( localIndex )
		local stateId = MC.GetBlockState(
			chunk.cx * MC.CS + lx,
			chunk.cy * MC.CS + ly,
			chunk.cz * MC.CH + lz
		)
		local record, decodeError = MC.DecodeBlockEntityEnvelope( stateId, envelope )
		if not record then return false, decodeError end
		chunk.blockEntities = chunk.blockEntities or {}
		chunk.blockEntities[localIndex] = record
	end
	return true
end

local function loadSavedOpaqueBlockEntities( chunk, records, sourceDataVersion )
	if records == nil then return true end
	if not chunk or not istable( records ) then return false, "invalid_opaque_block_entities" end
	local seen, totalBytes = {}, 0
	for _, record in ipairs( records ) do
		if not istable( record ) then return false, "invalid_opaque_block_entity" end
		local localIndex = math.floor( tonumber( record.localIndex ) or -1 )
		if not MC.LocalIndexInRange( localIndex ) or seen[localIndex] then return false, "invalid_opaque_block_entity_index" end
		seen[localIndex] = true
		if not isstring( record.sourceType ) or record.sourceType == ""
		or record.encoding ~= "typed-nbt-json-v1" or not istable( record.data ) then
			return false, "invalid_opaque_block_entity_record"
		end
		local json = util.TableToJSON( record.data, false )
		local bytes = json and #json or 0
		if bytes < 1 or bytes > 1048576 then return false, "opaque_block_entity_too_large" end
		totalBytes = totalBytes + bytes
		if totalBytes > 8388608 then return false, "opaque_chunk_budget_exceeded" end
		if sourceDataVersion and tonumber( record.sourceDataVersion ) ~= tonumber( sourceDataVersion ) then
			return false, "opaque_block_entity_version_mismatch"
		end
		local lx, ly, lz = MC.DecodeLocal( localIndex )
		local stateId = MC.GetBlockState(
			chunk.cx * MC.CS + lx,
			chunk.cy * MC.CS + ly,
			chunk.cz * MC.CH + lz
		)
		if stateId == 0 then return false, "opaque_block_entity_without_state" end
		if chunk.blockEntities and chunk.blockEntities[localIndex] then
			return false, "opaque_block_entity_conflicts_active"
		end
		chunk.opaqueBlockEntities = chunk.opaqueBlockEntities or {}
		chunk.opaqueBlockEntities[localIndex] = record
	end
	return true
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
	li = math.floor( tonumber( li ) or -1 )
	local sourceHeight = legacyMode == "column" and MC.CH or legacyMode == "slice" and MC.CS or MC.CH
	if li < 0 or li >= MC.CS * MC.CS * sourceHeight then return 0, 1, 0 end
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

	local stateId
	if data.v == 4 or data.v == 5 or data.v == 9 then
		stateId = importPaletteState( cache, palette, savedBlock )
	else
		local id = blockFromImport( cache, savedBlock )
		local orient = MC.StateToOrient( id, state )
		stateId = MC.StateFromLegacy( id, orient )
	end
	if not stateId or stateId == 0 or not MC.IsValidBlockState( stateId ) then return 0, 1, 0 end

	local c = MC.GetChunk( ncx, ncy, ncz )
	c = c or MC.EnsureChunk( ncx, ncy, ncz )
	local changed, oldStateId = MC.SetChunkLocalStateRaw( c, nli, stateId )
	if changed == nil then return 0, 1, 0 end
	if changed and oldStateId == 0 then
		SV.BlockCount = SV.BlockCount + 1
	end
	if changed then touched[c.key] = c end
	return 1, 0, 0
end

local function importCells( data, appendMode, deferResync )
	if not data or not data.chunks then return nil, "invalid_file" end
	local cache = {}
	local palette = data.p or data.palette
	local expectedBlocks = istable( data.stats ) and math.floor( tonumber( data.stats.blocks ) or 0 ) or 0
	local imported, skippedUnknown, skippedBounds = 0, 0, 0

	if not appendMode then
		clearWorldNoNet()
	end

	for _, ck in ipairs( data.chunks ) do
		local cx, cy, cz, cells, legacyMode
		if data.v == 5 or data.v == 9 then
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
				local stride = ( data.v == 4 or data.v == 5 or data.v == 9 ) and 2 or 3
				for i = 1, #cells, stride do
					local add, unk, bounds = importOneCell( data, cache, palette, legacyMode, cx, cy, cz, math.floor( tonumber( cells[i] ) or -1 ), cells[i + 1], cells[i + 2], touched )
					imported = imported + add
					skippedUnknown = skippedUnknown + unk
					skippedBounds = skippedBounds + bounds
				end
			end
			for key, c in pairs( touched ) do
				MC.FinalizeChunkStateStorage( c )
				if c.count > 0 then
					SV.EnsureChunkEnt( c )
					SV.MarkPhysDirtyBulk( c.key )
				else
					MC.World[key] = nil
				end
			end
		end
	end

	SV.Dirty = true
	if not appendMode and SV.AdvanceWorldGeneration then SV.AdvanceWorldGeneration( true ) end
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
	if not appendMode and SV.AdvanceWorldGeneration then SV.AdvanceWorldGeneration( true ) end
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
	if data.format == "mc_world_import" then
		return "mc_world_import v=" .. tostring( data.formatVersion ) ..
			" chunks=" .. ( istable( data.chunks ) and #data.chunks or 0 )
	end
	if istable( data.parts ) then
		return "manifest parts=" .. #data.parts .. " v=" .. tostring( data.v )
	end
	return "single chunks=" .. ( istable( data.chunks ) and #data.chunks or 0 ) .. " v=" .. tostring( data.v )
end

local function importErrorText( ply, err )
	if err == "invalid_file" then
		return L( ply, "server.invalid_file", "文件格式不对" )
	end
	return tostring( err )
end

local function runImport( ply, args )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local first = string.lower( tostring( args[1] or "" ) )
	local base = ( first == "/mc_import" or first == "!mc_import" or first == "mc_import" ) and 2 or 1
	local path = normalizeImportPath( args[base] )
	if not path then chat( ply, L( ply, "server.import_usage", IMPORT_USAGE ) ) return end

	local mode = string.lower( tostring( args[base + 1] or "replace" ) )
	local appendMode = mode == "append"
	if mode ~= "replace" and mode ~= "append" then
		chat( ply, L( ply, "server.import_usage", IMPORT_USAGE ) )
		return
	end
	local unknownPolicy = string.lower( tostring( args[base + 2] or "reject" ) )
	if unknownPolicy ~= "reject" and unknownPolicy ~= "preserve" then
		chat( ply, L( ply, "server.import_usage", IMPORT_USAGE ) )
		return
	end

	if not file.Exists( path, "DATA" ) then
		chat( ply, L( ply, "server.import_missing", "找不到导入文件: garrysmod/data/{path}", { path = path } ) )
		return
	end

	local raw = file.Read( path, "DATA" )
	local data = raw and util.JSONToTable( raw )
	if not data then
		chat( ply, L( ply, "server.import_bad_json", "导入文件不是有效 JSON: {path}", { path = path } ) )
		return
	end

	chat( ply, "import format: " .. importFormatText( data ) .. " bytes=" .. #raw )
	local result, err
	if data.format == "mc_world_import" and SV.ImportWorldBundle then
		result, err = SV.ImportWorldBundle( data, path, {
			mode = appendMode and "append" or "replace",
			unknownPolicy = unknownPolicy,
		} )
	else
		result, err = importManifest( data, path, appendMode )
	end
	if not result then chat( ply, L( ply, "server.import_failed", "导入失败: {err}", { err = importErrorText( ply, err ) } ) ) return end
	local msg = L( ply, "server.import_done", "导入完成: {blocks} 个方块，当前总数 {total}，跳过未知 {unknown}，越界 {bounds}，超上限 {max}", {
		blocks = result.imported,
		total = result.total,
		unknown = result.skippedUnknown,
		bounds = result.skippedBounds,
		max = result.skippedLimit,
	} )
	chat( ply, msg )
	if result.lossSummary then chat( ply, "import verification: " .. result.lossSummary ) end
	if result.expected and result.expected > 0 and result.imported ~= result.expected then
		chat( ply, L( ply, "server.import_count_mismatch", "导入文件写着 {expected} 个方块，实际进服 {imported} 个；少的都在上面跳过统计里。", {
			expected = result.expected,
			imported = result.imported,
		} ) )
	end
	if result.skippedLimit > 0 then
		chat( ply, L( ply, "server.import_truncated", "导入被 mc_import_max={max} 截断了；完整区块请先执行 mc_import_max 0。", {
			max = tostring( C.ImportMax and C.ImportMax:GetInt() or "?" ),
		} ) )
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
	if not path then chat( ply, L( ply, "server.import_usage", IMPORT_USAGE ) ) return end
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
	return MC.EstimateSyncBeginBytes()
end

local function sendFullPart( ply, active, byteLimit )
	local chunk = MC.GetChunkByKey( active.key )
	if not chunk then
		active.i = #active.lis + 1
		return nil
	end

	local maxCells = syncCellsPerPart()
	if byteLimit then
		maxCells = math.min( maxCells, MC.SyncCellsForByteBudget( byteLimit ) )
		if maxCells <= 0 then return nil, "budget" end
	end

	local first = active.i
	local last = active.i - 1
	local count = 0
	while active.i <= #active.lis and count < maxCells do
		local li = active.lis[active.i]
		local id = chunk.blocks[li]
		if id and id ~= 0 then
			count = count + 1
			last = active.i
		end
		active.i = active.i + 1
	end

	if count == 0 then return nil end

	net.Start( "mc_full_part" )
		net.WriteInt( active.cx, Net.COORD_BITS )
		net.WriteInt( active.cy, Net.COORD_BITS )
		net.WriteInt( active.cz, Net.COORD_BITS )
		net.WriteUInt( count, Net.COUNT_BITS )
		for i = first, last do
			local li = active.lis[i]
			local id = chunk.blocks[li]
			if id and id ~= 0 then
				net.WriteUInt( li, Net.LOCAL_BITS )
				net.WriteUInt( id, Net.ID_BITS )
				net.WriteUInt( MC.NormalizeOrient( id, chunk.orients and chunk.orients[li] ), Net.ORIENT_BITS )
			end
		end
	net.Send( ply )
	return MC.EstimateSyncPartBytes( count )
end

local function sendFullEnd( ply, active )
	net.Start( "mc_full_end" )
		net.WriteInt( active.cx, Net.COORD_BITS )
		net.WriteInt( active.cy, Net.COORD_BITS )
		net.WriteInt( active.cz, Net.COORD_BITS )
	net.Send( ply )
	return MC.EstimateSyncEndBytes()
end

local function ensureSyncQueue( ply )
	local q = SV.SyncQueue[ply]
	if not q then
		q = { keys = {}, i = 1, inflightBytes = 0, queuedKeys = {} }
		SV.SyncQueue[ply] = q
	end
	q.queuedKeys = q.queuedKeys or {}
	return q
end

local function sendHttpManifest( ply )
	if not IsValid( ply ) or not playerHttpChunkDeliveryActive( ply ) then return false end
	if not SV.ChunkStore or not SV.ChunkStore.HttpManifestPayload then return false end
	local payload = SV.ChunkStore.HttpManifestPayload()
	if not payload or not payload.path or payload.path == "" then return false end
	net.Start( "mc_http_manifest" )
		net.WriteString( httpChunkBaseURL() )
		net.WriteString( payload.path )
		net.WriteUInt( math.max( 0, math.floor( tonumber( payload.chunks ) or 0 ) ), 32 )
		net.WriteUInt( math.max( 0, math.floor( tonumber( payload.blocks ) or 0 ) ), 32 )
		net.WriteUInt( math.Clamp( math.floor( tonumber( payload.height ) or MC.CH ), 1, 65535 ), 16 )
	net.Send( ply )
	return true
end

local function queueSyncKey( ply, key )
	local chunk = MC.GetChunkByKey( key )
	if not chunk or not chunk.count or chunk.count <= 0 then return false end
	local q = ensureSyncQueue( ply )
	if q.queuedKeys[key] then return true end
	if q.active and q.active.key == key then return true end
	q.keys[#q.keys + 1] = key
	q.queuedKeys[key] = true
	return true
end

local function queueAllLoadedChunksForPlayer( ply )
	if not IsValid( ply ) then return end
	local q = ensureSyncQueue( ply )
	q.keys = {}
	q.i = 1
	q.active = nil
	q.queuedKeys = {}
	q.inflightBytes = 0

	local keys = {}
	for key, chunk in pairs( MC.World or {} ) do
		if chunk.count and chunk.count > 0 then
			keys[#keys + 1] = key
		end
	end
	table.sort( keys, function( a, b ) return tostring( a ) < tostring( b ) end )

	local loaded = {}
	for _, key in ipairs( keys ) do
		if queueSyncKey( ply, key ) then
			loaded[key] = true
		end
	end
	SV.PlayerLoadedChunks[ply] = loaded
	return #keys
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
	SV.PlayerLoadedChunks[ply] = {}
	SV.PlayerFullSnapshot[ply] = nil
	SV.SyncQueue[ply] = { keys = {}, i = 1, inflightBytes = 0, queuedKeys = {} }
	SV.ClearReliableNet( ply )
	if SV.SendStateHello then
		SV.SyncQueue[ply] = nil
		SV.SendStateHello( ply )
		return
	end
	if syncSnapshotEnabled() and SV.BeginSnapshotSync and SV.BeginSnapshotSync( ply ) then
		return
	end
	sendHttpManifest( ply )
	queueAllLoadedChunksForPlayer( ply )
end

local function restartPlayerFullSync( ply )
	if not IsValid( ply ) then return end
	net.Start( "mc_clear" )
	net.Send( ply )
	SV.PlayerLoadedChunks[ply] = {}
	SV.PlayerFullSnapshot[ply] = nil
	SV.SyncQueue[ply] = { keys = {}, i = 1, inflightBytes = 0, queuedKeys = {} }
	SV.ClearReliableNet( ply )
	if SV.SendStateHello then
		SV.SyncQueue[ply] = nil
		SV.SendStateHello( ply )
		return
	end
	if syncSnapshotEnabled() and SV.BeginSnapshotSync and SV.BeginSnapshotSync( ply ) then
		return
	end
	queueAllLoadedChunksForPlayer( ply )
end

net.Receive( "mc_http_failed", function( _, ply )
	if not IsValid( ply ) then return end
	local reason = string.sub( tostring( net.ReadString() or "" ), 1, 180 )
	if SV.PlayerHTTPDisabled[ply] then return end
	SV.PlayerHTTPDisabled[ply] = true
	MsgN( "[MC] HTTP chunk delivery disabled for " .. tostring( ply:Nick() ) .. ": " .. reason )
	restartPlayerFullSync( ply )
end )

function SV.RefreshServerCollision( force )
	local tick = engine and engine.TickCount and engine.TickCount() or CurTime()
	if not force and SV.ServerCollisionRefreshTick == tick then return end
	SV.ServerCollisionRefreshTick = tick
	local desired = {}
	SV.ServerCollisionActiveChunks = desired
	for key, c in pairs( MC.World or {} ) do
		if c.count and c.count > 0 then
			desired[key] = true
			local oldSig = SV.ServerCollisionSignatures[key]
			SV.ServerCollisionSignatures[key] = "full"
			if not IsValid( c.ent ) then
				SV.EnsureChunkEnt( c )
				SV.MarkPhysDirty( key, true )
			elseif oldSig ~= "full" then
				SV.MarkPhysDirty( key, true )
			end
		else
			if IsValid( c.ent ) then
				c.ent:Remove()
				c.ent = nil
			end
			SV.ServerCollisionSignatures[key] = nil
			SV.PhysDirty[key] = nil
			SV.PhysDirtyPriority[key] = nil
			if SV.PhysDirtyBulk then SV.PhysDirtyBulk[key] = nil end
		end
	end
end

function SV.RefreshChunkInterest()
	SV.RefreshServerCollision( true )
end

local function collectCollisionDebugBounds( maxBounds )
	local out = {}
	maxBounds = math.max( 1, math.floor( tonumber( maxBounds ) or 512 ) )
	for key, bounds in pairs( SV.ServerCollisionActiveChunks or {} ) do
		local cx, cy, cz = MC.ChunkKeyToCoords( key )
		if cx and bounds == true then
			out[#out + 1] = { cx, cy, cz, 0, 0, 0, MC.CS - 1, MC.CS - 1, MC.CH - 1 }
			if #out >= maxBounds then return out end
		elseif cx and istable( bounds ) then
			for _, b in ipairs( bounds ) do
				out[#out + 1] = { cx, cy, cz, b[1], b[2], b[3], b[4], b[5], b[6] }
				if #out >= maxBounds then return out end
			end
		end
	end
	return out
end

local function sendCollisionDebug( ply )
	if not IsValid( ply ) or not SV.CollisionDebugPlayers[ply] then return end
	local bounds = collectCollisionDebugBounds( 512 )
	net.Start( "mc_collision_debug" )
		net.WriteUInt( #bounds, 10 )
		for _, b in ipairs( bounds ) do
			net.WriteInt( b[1], Net.COORD_BITS )
			net.WriteInt( b[2], Net.COORD_BITS )
			net.WriteInt( b[3], Net.COORD_BITS )
			net.WriteUInt( math.Clamp( b[4], 0, 63 ), 6 )
			net.WriteUInt( math.Clamp( b[5], 0, 63 ), 6 )
			net.WriteUInt( math.Clamp( b[6], 0, 63 ), 6 )
			net.WriteUInt( math.Clamp( b[7], 0, 63 ), 6 )
			net.WriteUInt( math.Clamp( b[8], 0, 63 ), 6 )
			net.WriteUInt( math.Clamp( b[9], 0, 63 ), 6 )
		end
	net.Send( ply )
end

net.Receive( "mc_collision_debug_req", function( _, ply )
	if not IsValid( ply ) then return end
	SV.CollisionDebugPlayers[ply] = net.ReadBool() or nil
	if SV.CollisionDebugPlayers[ply] then
		SV.RefreshServerCollision( true )
		sendCollisionDebug( ply )
	end
end )

timer.Create( "mc_collision_debug_send", 0.1, 0, function()
	for ply in pairs( SV.CollisionDebugPlayers ) do
		if IsValid( ply ) then
			sendCollisionDebug( ply )
		else
			SV.CollisionDebugPlayers[ply] = nil
		end
	end
end )

hook.Remove( "SetupMove", "mc_server_collision_interest_move" )

local function sendSyncStep( ply, q, byteLimit )
	while not q.active do
		if q.i > #q.keys then return false end
		local key = q.keys[q.i]
		q.i = q.i + 1
		if q.queuedKeys then q.queuedKeys[key] = nil end
		q.active = makeSyncActive( key )
	end

	local active = q.active
	if not active.begun then
		local bytes = MC.EstimateSyncBeginBytes()
		if byteLimit and byteLimit < bytes then return nil, "budget" end
		active.begun = true
		return sendFullBegin( ply, active )
	end

	while active.i <= #active.lis do
		local bytes, reason = sendFullPart( ply, active, byteLimit )
		if bytes then return bytes end
		if reason == "budget" then return nil, reason end
	end

	local bytes = MC.EstimateSyncEndBytes()
	if byteLimit and byteLimit < bytes then return nil, "budget" end
	q.active = nil
	return sendFullEnd( ply, active )
end

timer.Create( "mc_interest_sync", INTEREST_TIMER_INTERVAL, 0, function()
	SV.StreamInterestDirty = false
	SV.RefreshServerCollision()
end )

timer.Create( "mc_bulk_collision_rebuild", 0.05, 0, function()
	flushBulkCollisionQueue()
end )

-- drip small chunk parts to each syncing player; large chunks must never be one
-- reliable net message.
timer.Create( "mc_sync", SYNC_TIMER_INTERVAL, 0, function()
	local frameBudget = syncFrameSeconds()
	local deadline = frameBudget and ( SysTime() + frameBudget ) or nil
	for ply, q in pairs( SV.SyncQueue ) do
		if not IsValid( ply ) then SV.SyncQueue[ply] = nil continue end
		local sent = 0
		local sentBytes = 0
		local budget = syncMessagesPerTick()
		local byteBudget = syncReliableBudget()
		local window = syncInFlightLimit()
		while sent < budget and sentBytes < byteBudget do
			if deadline and SysTime() >= deadline then break end
			local remainingWindow = window - ( q.inflightBytes or 0 )
			if remainingWindow <= 0 then break end
			local stepBudget = math.min( byteBudget - sentBytes, remainingWindow )
			if stepBudget <= 0 then break end
			local bytes, reason = sendSyncStep( ply, q, stepBudget )
			if not bytes then
				if reason == "budget" then break end
				break
			end
			sent = sent + 1
			sentBytes = sentBytes + bytes
			q.inflightBytes = ( q.inflightBytes or 0 ) + bytes
		end
		if q.i > #q.keys and not q.active then SV.SyncQueue[ply] = nil end
	end
end )

net.Receive( "mc_full_ack", function( _, ply )
	local q = SV.SyncQueue[ply]
	if not q then return end
	local bytes = math.Clamp( net.ReadUInt( 32 ), 0, 4194304 )
	q.inflightBytes = math.max( 0, ( q.inflightBytes or 0 ) - bytes )
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
local SAVE_DIR = "mc"
local AUTOSAVE_TIMER = "mc_autosave"
local AUTOSAVE_CVAR_CALLBACK = "mc_autosave_timer"

local function savePath()
	return SAVE_DIR .. "/" .. game.GetMap() .. ".dat"
end

local function normalizedSavePath( path )
	return string.lower( string.gsub( tostring( path or "" ), "\\", "/" ) )
end

local function isDefaultSavePath( path )
	return normalizedSavePath( path ) == normalizedSavePath( savePath() )
end

local function ensureSaveDir()
	file.CreateDir( SAVE_DIR )
end

function SV.DefaultSavePath()
	return savePath()
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

local function buildSaveData( slotName )
	if not SV.BuildStateSaveData then return nil, nil, "state_save_codec_unavailable" end
	return SV.BuildStateSaveData( slotName )
end
local function sendSnapshotBegin( ply, token, err, parts, totalBytes, chunks, blocks )
	net.Start( "mc_snapshot_begin" )
		net.WriteString( token or "" )
		net.WriteBool( err ~= nil )
		net.WriteString( err or "" )
		net.WriteUInt( math.max( 0, math.floor( tonumber( parts ) or 0 ) ), 32 )
		net.WriteUInt( math.max( 0, math.floor( tonumber( totalBytes ) or 0 ) ), 32 )
		net.WriteUInt( math.max( 0, math.floor( tonumber( chunks ) or 0 ) ), 32 )
		net.WriteUInt( math.max( 0, math.floor( tonumber( blocks ) or 0 ) ), 32 )
	net.Send( ply )
end

local function sendSnapshotError( ply, err )
	if not IsValid( ply ) then return end
	sendSnapshotBegin( ply, "", tostring( err or "snapshot_failed" ), 0, 0, 0, 0 )
end

local function sendSnapshotPart( ply, token, part, data, offset, len )
	net.Start( "mc_snapshot_part" )
		net.WriteString( token )
		net.WriteUInt( part, 32 )
		net.WriteUInt( len, 16 )
		net.WriteData( string.sub( data, offset, offset + len - 1 ), len )
	net.Send( ply )
	return true
end

function SV.BeginSnapshotSync( ply )
	if not IsValid( ply ) then return false end

	local data, chunks, buildError = buildSaveData( "snapshot" )
	if not data then
		sendSnapshotError( ply, buildError or "snapshot_encode_failed" )
		return false
	end
	local json = util.TableToJSON( data )
	if not json or json == "" then
		sendSnapshotError( ply, "snapshot_json_failed" )
		return false
	end

	local compressed = util.Compress( json )
	if not compressed or compressed == "" then
		sendSnapshotError( ply, "snapshot_compress_failed" )
		return false
	end

	local partBytes = math.Clamp( syncSnapshotPartBytes(), 4096, sharedReliableBudget() )
	local parts = math.ceil( #compressed / partBytes )
	if parts < 1 then
		sendSnapshotError( ply, "snapshot_empty" )
		return false
	end

	local token = tostring( ply:EntIndex() ) .. ":" .. util.CRC( tostring( SysTime() ) .. ":" .. tostring( #compressed ) )
	SV.SyncQueue[ply] = nil
	SV.PlayerLoadedChunks[ply] = {}
	SV.PlayerFullSnapshot[ply] = true
	SV.SnapshotQueue[ply] = nil
	SV.ClearReliableNet( ply )

	sendSnapshotBegin( ply, token, nil, parts, #compressed, #chunks, SV.BlockCount )
	for part = 1, parts do
		local partIndex = part
		local offset = ( partIndex - 1 ) * partBytes + 1
		local len = math.min( partBytes, #compressed - offset + 1 )
		SV.EnqueueReliableNet( ply, len + NET_MESSAGE_OVERHEAD_BYTES, function( target )
			return sendSnapshotPart( target, token, partIndex, compressed, offset, len )
		end )
	end
	return true
end

timer.Create( "mc_snapshot_sync", SYNC_TIMER_INTERVAL, 0, function()
	for ply, q in pairs( SV.SnapshotQueue ) do
		if not IsValid( ply ) then SV.SnapshotQueue[ply] = nil continue end
		local sent = 0
		local sentBytes = 0
		local budget = syncMessagesPerTick()
		local byteBudget = syncReliableBudget()
		local window = syncInFlightLimit()

		while q.part <= q.parts and sent < budget and sentBytes < byteBudget do
			local remainingBytes = q.totalBytes - q.offset + 1
			if remainingBytes <= 0 then break end
			local len = math.min( q.partBytes, remainingBytes )
			if sentBytes + len > byteBudget then break end
			local remainingWindow = window - ( q.inflightBytes or 0 )
			if remainingWindow < len then break end

			local chunk = string.sub( q.data, q.offset, q.offset + len - 1 )
			net.Start( "mc_snapshot_part" )
				net.WriteString( q.token )
				net.WriteUInt( q.part, 32 )
				net.WriteUInt( len, 16 )
				net.WriteData( chunk, len )
			net.Send( ply )

			q.offset = q.offset + len
			q.part = q.part + 1
			q.inflightBytes = ( q.inflightBytes or 0 ) + len
			sent = sent + 1
			sentBytes = sentBytes + len
		end

		if q.part > q.parts and ( q.inflightBytes or 0 ) <= 0 then
			SV.SnapshotQueue[ply] = nil
		end
	end
end )

net.Receive( "mc_snapshot_ack", function( _, ply )
	local token = net.ReadString()
	local bytes = math.Clamp( net.ReadUInt( 32 ), 0, 4194304 )
	local complete = net.ReadBool()
	local q = SV.SnapshotQueue[ply]
	if q and q.token == token then
		q.inflightBytes = math.max( 0, ( q.inflightBytes or 0 ) - bytes )
		if complete then
			SV.SnapshotQueue[ply] = nil
		end
	end
	if complete then
		SV.PlayerFullSnapshot[ply] = true
	end
end )

local function overlaySavePath( path )
	return string.gsub( tostring( path or "" ), "%.[^/%.]*$", "" ) .. "_edits.dat"
end

function SV.SaveToPath( path, slotName )
	if SV.SaveInProgress then return false, "save_in_progress" end
	SV.SaveInProgress = true
	local saveIsDefault = isDefaultSavePath( path )
	local function finishSave( ok, ... )
		if ok and saveIsDefault then SV.Dirty = false end
		SV.SaveInProgress = false
		return ok, ...
	end

	if SV.ChunkStore and SV.ChunkStore.IsLazyWorld and SV.ChunkStore.IsLazyWorld() and SV.ChunkStore.SaveOverlay then
		local overlay = SV.ChunkStore.SaveOverlay()
		local json = util.TableToJSON( overlay )
		if not json then return finishSave( false, "overlay_json_failed" ) end
		ensureSaveDir()
		file.Write( overlaySavePath( path ), json )
		MsgN( "[MC] saved lazy edit overlay / " .. SV.BlockCount .. " blocks" ..
			( slotName and ( " as \"" .. slotName .. "\" on map " .. game.GetMap() ) or "" ) )
		return finishSave( true, path, overlay, 0, SV.BlockCount )
	end

	local data, chunks, buildError = buildSaveData( slotName )
	if not data then return finishSave( false, buildError or "save_encode_failed" ) end
	local json = util.TableToJSON( data )
	if not json then return finishSave( false, "save_json_failed" ) end
	ensureSaveDir()
	local compressed = util.Compress( json )
	if not compressed then return finishSave( false, "save_compress_failed" ) end
	local tempPath = path .. ".tmp"
	file.Write( tempPath, compressed )
	local verifyRaw = file.Read( tempPath, "DATA" )
	local verifyJSON = verifyRaw and util.Decompress( verifyRaw )
	local verifyData = verifyJSON and util.JSONToTable( verifyJSON )
	local verifyChunks, verifyBlocks = savedBlockCount( verifyData )
	if verifyBlocks ~= SV.BlockCount or verifyChunks ~= #chunks then
		file.Delete( tempPath )
		return finishSave( false, "save_verify_mismatch" )
	end
	local backupPath = path .. ".bak"
	if file.Exists( backupPath, "DATA" ) then file.Delete( backupPath ) end
	if file.Exists( path, "DATA" ) then
		file.Rename( path, backupPath )
		if not file.Exists( backupPath, "DATA" ) then
			file.Delete( tempPath )
			return finishSave( false, "save_backup_failed" )
		end
	end
	file.Rename( tempPath, path )
	if not file.Exists( path, "DATA" ) then
		if file.Exists( backupPath, "DATA" ) then file.Rename( backupPath, path ) end
		file.Delete( tempPath )
		return finishSave( false, "save_commit_failed" )
	end
	if file.Exists( backupPath, "DATA" ) then file.Delete( backupPath ) end
	MsgN( "[MC] saved " .. #chunks .. " chunks / " .. SV.BlockCount .. " blocks" ..
		( slotName and ( " as \"" .. slotName .. "\" on map " .. game.GetMap() ) or "" ) )
	return finishSave( true, path, data, #chunks, SV.BlockCount )
end

function SV.Save( slotName )
	if slotName ~= nil and string.Trim( tostring( slotName ) ) ~= "" and SV.SaveNamed then
		return SV.SaveNamed( slotName )
	end
	return SV.SaveToPath( savePath() )
end

local function savedHeightForData( data )
	local savedHeight = math.floor( tonumber( data.h ) or MC.CH )
	if savedHeight <= 0 then savedHeight = MC.CH end
	return savedHeight
end

local function savedChunkSizeForData( data )
	local savedChunkSize = math.floor( tonumber( data.cs ) or MC.CS )
	if savedChunkSize <= 0 then savedChunkSize = MC.CS end
	return savedChunkSize
end

local function readSaveJSON( path )
	local raw = file.Read( path, "DATA" )
	if not raw or raw == "" then return nil, "empty_save" end
	if string.sub( raw, 1, 1 ) == "{" then
		return util.JSONToTable( raw ), nil
	end
	local json = util.Decompress( raw )
	if not json then return nil, "decompress_failed" end
	return util.JSONToTable( json ), nil
end

local function loadSaveChunks( data, cache, deferWorldEffects )
	cache = cache or {}
	local strict = data.v == 9 or data.v == 10
	local savedHeight = savedHeightForData( data )
	local savedChunkSize = savedChunkSizeForData( data )
	local palette = data.p or data.palette

	for _, ck in ipairs( data.chunks or {} ) do
		if strict and not istable( ck ) then return false, "invalid_chunk_record" end
		local cx, cy, cz, cells, legacyMode, blockEntities, opaqueBlockEntities
		if data.v == 5 or data.v == 9 or data.v == 10 then
			cx, cy, cz, cells, blockEntities, opaqueBlockEntities = ck[1], ck[2], ck[3], ck[4], ck[5], ck[6]
		elseif data.v == 4 then
			cx, cy, cells, legacyMode = ck[1], ck[2], ck[3], "column"
		else
			cx, cy, cz, cells, legacyMode = ck[1], ck[2], ck[3], ck[4], "slice"
		end
		if strict then
			cx, cy, cz = tonumber( cx ), tonumber( cy ), tonumber( cz )
			if not cx or not cy or not cz or cx ~= math.floor( cx ) or cy ~= math.floor( cy ) or cz ~= math.floor( cz ) then
				return false, "invalid_chunk_coords"
			end
		end
		local touched = {}
		local loadError
		local stride = ( data.v == 4 or data.v == 5 or data.v == 9 or data.v == 10 ) and 2 or ( ( data.v == 2 or data.v == 3 ) and 3 or 2 )
		local function loadOneCell( li, savedBlock, state )
			if loadError then return end
			li = math.floor( tonumber( li ) or -1 )
			if strict and not MC.LocalIndexInRange( li ) then loadError = "invalid_local_index" return end
			local stateId, stateError
			if data.v == 4 or data.v == 5 or data.v == 9 or data.v == 10 then
				stateId, stateError = importPaletteState( cache, palette, savedBlock )
			else
				local resolved = data.v == 3 and MC.ResolveBlock( savedBlock ) or nil
				local id = resolved and resolved.id or math.floor( tonumber( savedBlock ) or 0 )
				local orient = state ~= nil and MC.StateToOrient( id, state ) or MC.DefaultOrient( id )
				stateId = MC.StateFromLegacy( id, orient )
			end
			if strict and ( not stateId or stateId == 0 or not MC.IsValidBlockState( stateId ) ) then
				loadError = stateError or "invalid_palette_state"
				return
			end
			local bx, by, bz
			if legacyMode == "column" then
				bx, by, bz = oldColumnCell( data, cx, cy, li )
			elseif legacyMode == "slice" then
				bx, by, bz = oldSliceCell( cx, cy, cz, li )
			else
				local lx, ly, lz = decodeLocalWithGeometry( li, savedChunkSize, savedHeight )
				if lx then
					bx, by, bz = cx * savedChunkSize + lx, cy * savedChunkSize + ly, cz * savedHeight + lz
				end
			end
			if strict and not bx then loadError = "invalid_cell_geometry" return end
			if bx then
				local ncx, ncy, ncz, nli = MC.CellToChunk( bx, by, bz )
				local c = MC.GetChunk( ncx, ncy, ncz )
				local existingState = c and MC.GetBlockState( bx, by, bz ) or 0
				if strict and existingState ~= 0 then loadError = "duplicate_cell" return end
				if MC.LocalIndexInRange( nli ) and stateId and stateId ~= 0 and MC.IsValidBlockState( stateId ) and existingState == 0 then
					c = c or MC.EnsureChunk( ncx, ncy, ncz )
					local changed, oldStateId = MC.SetChunkLocalStateRaw( c, nli, stateId )
					if strict and changed == nil then loadError = oldStateId or "state_write_failed" return end
					if changed then
						if oldStateId == 0 then SV.BlockCount = SV.BlockCount + 1 end
						touched[c.key] = c
					end
				end
			end
		end

		if isstring( cells ) then
			if strict then
				for entry in string.gmatch( cells, "[^;]+" ) do
					local liText, blockText = string.match( entry, "^(-?%d+):(-?%d+)$" )
					if not liText then loadError = "invalid_cell_record" break end
					loadOneCell( liText, blockText )
				end
			else
				for liText, blockText, stateText in string.gmatch( cells, "([^:;]+):([^:;]*):?([^;]*);?" ) do
					loadOneCell( liText, blockText, stateText ~= "" and stateText or nil )
				end
			end
		else
			if not istable( cells ) then
				if strict then loadError = "invalid_cells" end
			else
				if strict and #cells % stride ~= 0 then loadError = "invalid_cells" end
				for i = 1, #cells, stride do
					if loadError then break end
					loadOneCell( cells[i], cells[i + 1], stride == 3 and cells[i + 2] or nil )
				end
			end
		end
		if loadError then return false, loadError end
		if strict and blockEntities ~= nil then
			local chunk = MC.GetChunk( cx, cy, cz )
			local loadedEntities, entityError = loadSavedBlockEntities( chunk, blockEntities )
			if not loadedEntities then return false, entityError end
		end
		if strict and opaqueBlockEntities ~= nil then
			local chunk = MC.GetChunk( cx, cy, cz )
			local loadedOpaque, opaqueError = loadSavedOpaqueBlockEntities(
				chunk,
				opaqueBlockEntities,
				data.sourceDataVersion or data.source and data.source.dataVersion
			)
			if not loadedOpaque then return false, opaqueError end
		end
		for key, c in pairs( touched ) do
			MC.FinalizeChunkStateStorage( c )
			if c.count > 0 then
				if not deferWorldEffects then
					SV.EnsureChunkEnt( c )
					SV.MarkPhysDirty( c.key )
				end
			else
				MC.World[key] = nil
			end
		end
	end
	return true
end

local function savePartPath( manifestPath, partPath )
	partPath = string.Trim( tostring( partPath or "" ) )
	if partPath == "" then return nil end
	partPath = string.gsub( partPath, "\\", "/" )
	partPath = string.gsub( partPath, "%.%.+", "_" )
	if string.StartWith( partPath, "mc/" ) then return partPath end
	return string.GetPathFromFilename( manifestPath ) .. partPath
end

local function loadSaveParts( data, manifestPath, cache, deferWorldEffects )
	for _, part in ipairs( data.parts or {} ) do
		local partPath = savePartPath( manifestPath, part )
		if not partPath then return false, "invalid_save_part" end
		if not file.Exists( partPath, "DATA" ) then return false, "missing_save_part: " .. partPath end

		local partData = readSaveJSON( partPath )
		if not partData or not istable( partData.chunks ) then
			return false, "invalid_save_part: " .. partPath
		end

		partData.v = partData.v or data.v or 5
		partData.cs = partData.cs or data.cs
		partData.h = partData.h or data.h
		partData.p = partData.p or data.p
		partData.palette = partData.palette or data.palette
		partData.source = partData.source or data.source
		partData.sourceDataVersion = partData.sourceDataVersion or data.sourceDataVersion
		local loaded, loadError = loadSaveChunks( partData, cache, deferWorldEffects )
		if not loaded then return false, loadError end
	end
	return true
end

local function validateSavePartFiles( data, manifestPath )
	for _, part in ipairs( data.parts or {} ) do
		local partPath = savePartPath( manifestPath, part )
		if not partPath then return false, "invalid_save_part" end
		if not file.Exists( partPath, "DATA" ) then return false, "missing_save_part: " .. partPath end
		local partData, partError = readSaveJSON( partPath )
		if partError or not partData or not istable( partData.chunks ) then
			return false, "invalid_save_part: " .. partPath
		end
	end
	return true
end

function SV.LoadFromPath( path, resyncClients, requestedName )
	if not file.Exists( path, "DATA" ) then return false, "save_not_found" end

	local data, err = readSaveJSON( path )
	if err then return false, err end
	if not data or ( not data.chunks and not data.parts ) then return false, "invalid_save" end
	if data.format == "mc_world_import" then
		if not MC.Import or not MC.Import.ValidateSourceMetadata then return false, "import_format_unavailable" end
		local metadataOK, metadataError = MC.Import.ValidateSourceMetadata( data )
		if metadataOK ~= true then return false, metadataError or "invalid_import_metadata" end
		local loss = data.lossReport
		if not istable( loss ) or loss.archiveRoundTripLossless ~= true or loss.substitutedOrDropped == true then
			return false, "import_save_contains_loss"
		end
	end
	if data.v == 9 or data.v == 10 then
		local expectedHash = MC.BlockStateRegistryMetadata and MC.BlockStateRegistryMetadata.schemaHash or nil
		if not isstring( data.schemaHash ) or data.schemaHash == "" then return false, "missing_schema_hash" end
		if expectedHash and data.schemaHash ~= expectedHash then return false, "schema_hash_mismatch" end
		if savedChunkSizeForData( data ) ~= MC.CS or savedHeightForData( data ) ~= MC.CH then
			return false, "state_geometry_mismatch"
		end
	end

	if data.map and data.map ~= game.GetMap() then
		MsgN( "[MC] WARNING: save map " .. tostring( data.map ) .. " != current " .. game.GetMap() )
	end

	if data.bs and data.bs ~= MC.BS then
		MsgN( "[MC] WARNING: save BlockSize " .. data.bs .. " != current " .. MC.BS .. " (positions may be off)" )
	end
	local savedHeight = savedHeightForData( data )
	local savedChunkSize = savedChunkSizeForData( data )
	if data.v == 5 or data.v == 7 or data.v == 8 or data.v == 9 or data.v == 10 then
		if savedChunkSize ~= MC.CS or savedHeight ~= MC.CH then
			MsgN( "[MC] remapping save chunk geometry " .. savedChunkSize .. "x" .. savedChunkSize .. "x" .. savedHeight ..
				" -> " .. MC.CS .. "x" .. MC.CS .. "x" .. MC.CH )
		end
	end
	local isV8PartManifest = data.v == 8 and istable( data.parts )
	if istable( data.parts ) then
		local validParts, partError = validateSavePartFiles( data, path )
		if not validParts then return false, partError end
	end

	local stagedLoad = data.v == 9 or data.v == 10
	local previousWorld = stagedLoad and beginWorldLoadStage() or nil
	if not stagedLoad then clearWorldNoNet() end

	local cache = {}
	if isV8PartManifest or istable( data.parts ) then
		local ok, err = loadSaveParts( data, path, cache, stagedLoad )
		if not ok then
			if stagedLoad then restoreWorldLoadStage( previousWorld ) else clearWorldNoNet() end
			return false, err
		end
	else
		local ok, err = loadSaveChunks( data, cache, stagedLoad )
		if not ok then
			if stagedLoad then restoreWorldLoadStage( previousWorld ) else clearWorldNoNet() end
			return false, err
		end
	end
	if stagedLoad then commitWorldLoadStage( previousWorld ) end
	if SV.AdvanceWorldGeneration then SV.AdvanceWorldGeneration( true ) end

	SV.Dirty = false
	if resyncClients then resyncAllClients() end
	MsgN( "[MC] loaded " .. SV.BlockCount .. " blocks" ..
		( requestedName and ( " from \"" .. requestedName .. "\"" ) or "" ) ..
		( data.map and ( " saved on map " .. tostring( data.map ) ) or "" ) )
	return true
end

function SV.Load()
	return SV.LoadFromPath( savePath(), false )
end

local function autosaveConVar()
	if C.Autosave then return C.Autosave end
	C.Autosave = GetConVar( "mc_autosave" )
	return C.Autosave
end

local function autosaveSeconds()
	local cv = autosaveConVar()
	if not cv then return 0 end
	return math.max( 0, tonumber( cv:GetFloat() ) or 0 )
end

local function runAutosave()
	if not SV.Dirty then return end
	local ok, err = SV.Save()
	if ok == false then MsgN( "[MC] autosave failed: " .. tostring( err ) ) end
end

function SV.ConfigureAutosave()
	timer.Remove( AUTOSAVE_TIMER )

	local secs = autosaveSeconds()
	if secs <= 0 then
		MsgN( "[MC] autosave disabled" )
		return false
	end

	timer.Create( AUTOSAVE_TIMER, secs, 0, runAutosave )
	MsgN( "[MC] autosave every " .. tostring( secs ) .. "s" )
	return true
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_autosave", function()
		if SV.ConfigureAutosave then SV.ConfigureAutosave() end
	end, AUTOSAVE_CVAR_CALLBACK )
end

------------------------------------------------------------------------ hooks
hook.Add( "InitPostEntity", "mc_load", function()
	SV.Load()
	SV.ConfigureAutosave()
end )

hook.Add( "PlayerInitialSpawn", "mc_sync", function( ply )
	timer.Simple( 0.5, function()
		if IsValid( ply ) then SV.BeginSync( ply ) end
	end )
end )

hook.Add( "PlayerDisconnected", "mc_sync_clean", function( ply )
	SV.SyncQueue[ply] = nil
	SV.SnapshotQueue[ply] = nil
	SV.PlayerLoadedChunks[ply] = nil
	SV.PlayerFullSnapshot[ply] = nil
	SV.PlayerHTTPDisabled[ply] = nil
end )

hook.Add( "ShutDown", "mc_save", function()
	if SV.Dirty then SV.Save() end
end )

------------------------------------------------------------------- block select
-- clients call: mc_block_sel <id> [orient]; orient -1 keeps placement automatic
concommand.Add( "mc_block_sel", function( ply, _, args )
	local id = tonumber( args[1] )
	if IsValid( ply ) and MC.IsValidBlock( id ) then
		local orient = tonumber( args[2] )
		if SV.SelectCreativeLegacy then
			SV.SelectCreativeLegacy( ply, id, orient )
			return
		end
		ply:SetNWInt( "mc_block", id )
		ply:SetNWInt( "mc_block_orient", orient and orient >= 0 and MC.NormalizeOrient( id, orient ) or -1 )
	end
end )

------------------------------------------------------------------- admin commands
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
	SV.PhysDirtyPriority = {}
	SV.PhysDirtyBulk = {}
	SV.PhysDirtyBulkOrder = {}
	SV.SyncQueue = {}
	SV.SnapshotQueue = {}
	SV.PlayerLoadedChunks = {}
	SV.PlayerFullSnapshot = {}
	if SV.AdvanceWorldGeneration then SV.AdvanceWorldGeneration( true ) end
	SV.Dirty = true
	for _, target in ipairs( player.GetAll() ) do SV.BeginSync( target ) end
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
			SV.EnsureChunkEnt( c, true )
			SV.MarkPhysDirtyBulk( key )
			n = n + 1
		end
	end
	MsgN( "[MC] rebuilding collision for " .. n .. " chunks" )
	if IsValid( ply ) then ply:ChatPrint( "[MC] " .. L( ply, "server.rebuilt", "重建了 {count} 个区块的碰撞", { count = n } ) ) end
end )
