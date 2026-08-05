--[[----------------------------------------------------------------------------
	MC : server block-cluster service.

	Converts a player-selected set of world cells into one mc_block_cluster
	physics entity (removing the blocks through the normal transaction
	pipeline), pastes clusters back onto the grid, breaks them under damage,
	and persists live clusters in a per-save sidecar file.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config
local Net = MC.Net

local CLUSTER_CLASS = "mc_block_cluster"
local CONVERT_COOLDOWN = 0.5
local DATA_REPLIES_PER_SECOND = 24

local function L( ply, key, fallback, vars )
	return MC.TFor and MC.TFor( ply, key, fallback, vars ) or fallback
end

local function notify( ply, msg )
	if IsValid( ply ) then ply:ChatPrint( "[MC] " .. msg ) end
end

local function canUseClusters( ply )
	if not IsValid( ply ) or ply:IsAdmin() then return true end
	local public = C.ClusterPublic or GetConVar( "mc_cluster_public" )
	if public and public:GetBool() then return true end
	notify( ply, L( ply, "cluster.admin_only", "只有管理员可以使用结构搬运器 (mc_cluster_public 0)" ) )
	return false
end

local function clusterCooldownOK( ply )
	if not IsValid( ply ) then return true end
	local t = CurTime()
	if ( ply.mcClusterNextOp or 0 ) > t then return false end
	ply.mcClusterNextOp = t + CONVERT_COOLDOWN
	return true
end

local function countPlayerClusters( sid )
	if not sid then return 0 end
	local n = 0
	for _, ent in ipairs( ents.FindByClass( CLUSTER_CLASS ) ) do
		if ent.ClusterOwnerSID == sid then n = n + 1 end
	end
	return n
end

-- Lazy MCB4 worlds keep chunks off the heap until something asks for them, and
-- MC.GetBlockState reports a non-resident chunk as air. Capturing a selection
-- in that state would silently drop those cells from the cluster AND leave the
-- real blocks in the world, where they reappear the moment the chunk hydrates.
-- Force every chunk the selection touches in first, and refuse the conversion
-- rather than truncate it if one will not load. The selection is already
-- bounded by mc_cluster_max_extent / max_blocks, so this is a small, finite
-- set - the same work walking into the area would have done anyway.
local function hydrateSelectionChunks( cells )
	local store = SV.ChunkStore
	if not store or not store.IsLazyWorld or not store.IsLazyWorld() then return true end
	if not store.HydrateChunkNow then return true end
	local pending = {}
	for _, cell in ipairs( cells ) do
		local cx, cy, cz = MC.CellToChunk( cell.bx, cell.by, cell.bz )
		local key = tostring( MC.ChunkKey( cx, cy, cz ) )
		if not store.LoadedKeys[key] then pending[key] = true end
	end
	for key in pairs( pending ) do
		store.HydrateChunkNow( key, true )
		-- A chunk with nothing on disk hydrates to nil but is still marked
		-- loaded ("known empty"); only a missing LoadedKeys flag means the
		-- load actually failed.
		if not store.LoadedKeys[key] then return false end
	end
	return true
end

--------------------------------------------------------------------- spawning
-- Proactive payload push: clients also request on demand (late joiners, full
-- updates), but pushing at spawn removes the round-trip for everyone present.
local function pushClusterData( ent, target )
	local blob = ent.ClusterBlob
	if not blob or blob == "" then return end
	net.Start( "mc_cluster_data" )
		net.WriteUInt( ent:EntIndex(), 16 )
		net.WriteUInt( #blob, 16 )
		net.WriteData( blob, #blob )
	if target then net.Send( target ) else net.Broadcast() end
end

-- One shared FX message: isSpawn=false is the full break burst, true is the
-- lighter conversion-complete sparkle.
local function broadcastClusterFx( ent, isSpawn )
	net.Start( "mc_cluster_break" )
		net.WriteUInt( ent:EntIndex(), 16 )
		net.WriteBool( isSpawn == true )
	net.Broadcast()
end

function SV.SpawnCluster( record, pos, ang, frozen, ownerSID )
	if MC.ClusterValidateRecord then
		local recordOK, recordErr = MC.ClusterValidateRecord( record )
		if not recordOK then return nil, recordErr end
	end
	local blob, encodeErr = MC.ClusterEncode( record )
	if not blob then return nil, encodeErr end

	local ent = ents.Create( CLUSTER_CLASS )
	if not IsValid( ent ) then return nil, "create_failed" end

	ent:SetPos( pos )
	ent:SetAngles( ang or angle_zero )
	ent:Spawn()
	ent:Activate()
	ent:SetClusterRecord( record, blob )
	ent.ClusterOwnerSID = ownerSID

	local ok, err, convexCount = ent:RebuildClusterPhysics( frozen ~= false )
	if not ok then
		ent:Remove()
		return nil, err, convexCount
	end
	pushClusterData( ent )
	-- The record lives on the entity (ent.ClusterRecord); hand listeners a
	-- copy so external code cannot desync blob/physics/mesh through it.
	if MC.RunEvent and MC.EventHasListeners and MC.EventHasListeners( "MC.ClusterSpawned" ) then
		local size, cells = record.size, record.cells
		local eventRecord = { size = { size[1], size[2], size[3] }, cells = {} }
		for i = 1, #cells do eventRecord.cells[i] = cells[i] end
		MC.RunEvent( "MC.ClusterSpawned", ent, eventRecord )
	end
	return ent
end

local function assignClusterOwner( ent, ply )
	if not IsValid( ent ) or not IsValid( ply ) then return end
	if ent.SetCreator then ent:SetCreator( ply ) end
	ent:SetOwnerLabel( string.sub( ply:Nick() or "", 1, 48 ) )
	if ent.CPPISetOwner then ent:CPPISetOwner( ply ) end
	if cleanup and cleanup.Add then cleanup.Add( ply, "props", ent ) end
end

-- Public: grant a spawned cluster prop-protection ownership, creator label
-- and cleanup registration (the convert path does this automatically).
SV.AssignClusterOwner = assignClusterOwner

------------------------------------------------------------------ duplicator
-- Dupe support (dupe tool and Adv Dupe use the same registry): the cluster
-- record rides in the copied entity table (heavy/transient fields are
-- stripped in ENT:OnEntityCopyTableFinish) and this factory rebuilds the
-- entity from it. Registered classes skip the generic table-apply, so
-- ownership is reassigned to the pasting player here. Same caps as the
-- convert path; dupes always paste frozen and the duplicator applies the
-- saved motion state afterwards.
duplicator.RegisterEntityClass( CLUSTER_CLASS, function( ply, data )
	local source = istable( data ) and istable( data.ClusterRecord ) and data.ClusterRecord or nil
	if not source then return nil end
	local record = { size = source.size, cells = source.cells, crate = source.crate == true }
	if not MC.ClusterValidateRecord( record ) then return nil end

	local count = math.floor( #record.cells / 4 )
	local maxExtent = MC.ClusterMaxExtent()
	if count > MC.ClusterMaxBlocks()
		or record.size[1] > maxExtent
		or record.size[2] > maxExtent
		or record.size[3] > maxExtent then
		return nil
	end

	local sid = IsValid( ply ) and ply:SteamID64() or nil
	local maxPer = C.ClusterMaxPerPlayer and C.ClusterMaxPerPlayer:GetInt() or 8
	if maxPer > 0 and countPlayerClusters( sid ) >= maxPer then
		notify( ply, L( ply, "cluster.per_player_limit",
			"你的结构实体已达上限 ({max} 个, mc_cluster_max_per_player)", { max = maxPer } ) )
		return nil
	end

	local ent = SV.SpawnCluster( record, data.Pos or vector_origin, data.Angle or angle_zero, true, sid )
	if not IsValid( ent ) then return nil end
	assignClusterOwner( ent, ply )
	if istable( data.ClusterOriginCell ) then ent.ClusterOriginCell = data.ClusterOriginCell end

	local health = tonumber( data.ClusterHealth )
	if health and ( ent.ClusterMaxHealth or 0 ) > 0 then
		ent.ClusterHealth = math.Clamp( health, 1, ent.ClusterMaxHealth )
		ent:SetHealth( math.floor( ent.ClusterHealth ) )
	end
	return ent
end, "Data" )

---------------------------------------------------------------- paste / undo
-- Place a cluster's blocks back onto the grid at targetMin with a quarter
-- turn, mirroring the preset placement pipeline. Removes the entity on
-- success. Never overwrites: every target cell must be air.
local function placeClusterAt( ply, ent, targetMin, rotation )
	local record = ent.ClusterRecord
	if not record then return false, "no_record" end

	local rotatedCells = MC.ClusterRotateCells( record.cells, record.size, rotation )
	local cells = {}
	local blocked = 0
	for i = 1, #rotatedCells, 4 do
		local bx = targetMin[1] + rotatedCells[i]
		local by = targetMin[2] + rotatedCells[i + 1]
		local bz = targetMin[3] + rotatedCells[i + 2]
		if not SV.WorldBoundsOK( bx, by, bz ) then return false, "out_of_bounds" end
		cells[#cells + 1] = { bx = bx, by = by, bz = bz, stateId = rotatedCells[i + 3] }
	end
	-- Same lazy-world trap as conversion: a non-resident chunk reads as air, so
	-- the occupancy check below would clear a target that is actually solid and
	-- paste into it. Hydrate the destination first; the transaction's
	-- validateChange still guards the commit, but failing there would leave a
	-- half-placed structure and a consumed entity.
	if not hydrateSelectionChunks( cells ) then return false, "not_loaded" end
	for _, cell in ipairs( cells ) do
		local bx, by, bz = cell.bx, cell.by, cell.bz
		if ( MC.GetBlockState( bx, by, bz ) or 0 ) ~= 0 then blocked = blocked + 1 end
	end
	if blocked > 0 then return false, "occupied", blocked end

	local maxBlocks = C.MaxBlocks and C.MaxBlocks:GetInt() or 0
	if maxBlocks > 0 and SV.BlockCount + #cells > maxBlocks then return false, "block_limit" end

	local changed
	if SV.ApplyBlockHydrationTransaction then
		local result = SV.ApplyBlockHydrationTransaction( cells, {
			actor = ply,
			fx = true,
			fxIndex = 1,
			fxPreferPlaced = true,
			handlers = true,
			blockUpdates = true,
			maxBlockCount = maxBlocks,
			validateChange = function( info )
				if info.oldStateId ~= 0 then return false, "occupied" end
				return true
			end,
		} )
		if result.ok == true then
			changed = result.changed
		elseif result.error ~= "chunk_hydration_transport_unavailable" then
			return false, result.error or "hydration_failed"
		end
	end
	if changed == nil then
		if not SV.SetBlocksBulk then return false, "bulk_api_unavailable" end
		local n, bulkErr = SV.SetBlocksBulk( cells, {
			actor = ply,
			fx = true,
			fxIndex = 1,
			handlers = true,
			priorityPhys = false,
			deferPhys = true,
			netPaced = true,
			stateStream = true,
			cellsPerMessage = 512,
		} )
		if ( n or 0 ) <= 0 then return false, bulkErr or "unchanged" end
		changed = n
	end
	if ( changed or 0 ) <= 0 then return false, "unchanged" end

	if MC.RunEvent then MC.RunEvent( "MC.ClusterPasted", ply, ent, changed ) end
	ent:Remove()
	return true, changed
end

-- Public: place a cluster entity's blocks back onto the grid. targetMin is
-- the { bx, by, bz } array-form world cell of the record's min corner;
-- rotation 0..3 clockwise quarter turns. Never overwrites occupied cells.
SV.PlaceClusterAt = placeClusterAt

local PASTE_FAIL_TEXT = {
	occupied = { "cluster.paste_err_occupied", "目标位置被方块占用" },
	out_of_bounds = { "cluster.paste_err_bounds", "超出建造范围" },
	block_limit = { "cluster.paste_err_limit", "会超过全局方块上限 (mc_max_blocks)" },
	no_record = { "cluster.paste_err_record", "结构数据缺失" },
	not_loaded = { "cluster.not_loaded", "选区内有区块未能加载，请稍后重试" },
}

local function pasteFailText( ply, err, blocked )
	if err == "occupied" and blocked then
		return L( ply, "cluster.paste_occupied_n", "目标位置有 {n} 格被方块占用", { n = blocked } )
	end
	local entry = PASTE_FAIL_TEXT[err]
	if entry then return L( ply, entry[1], entry[2] ) end
	return tostring( err )
end

------------------------------------------------------------------ conversion
local function registerClusterUndo( ply, ent, originCell )
	if not ( undo and undo.Create ) or not IsValid( ply ) then return end
	undo.Create( "mc_block_cluster" )
	undo.SetPlayer( ply )
	undo.SetCustomUndoText( L( ply, "cluster.undo_text", "撤销 MC 方块结构 (放回原位)" ) )
	undo.AddFunction( function()
		if not IsValid( ent ) then return end
		if not canUseClusters( ply ) then return end
		if SV.CanEdit and not SV.CanEdit( ply ) then return end
		local ok, err, blocked = placeClusterAt( ply, ent, originCell, 0 )
		if ok then
			notify( ply, L( ply, "cluster.undo_restored", "已把结构放回原位" ) )
		else
			notify( ply, L( ply, "cluster.undo_failed", "撤销失败: {err}", { err = pasteFailText( ply, err, blocked ) } ) )
		end
	end )
	undo.Finish()
end

net.Receive( "mc_cluster_convert", function( _, ply )
	local count = net.ReadUInt( 13 )
	local crate = net.ReadBool()
	if not canUseClusters( ply ) then return end
	local maxBlocks = MC.ClusterMaxBlocks()
	if count < 1 or count > maxBlocks then
		notify( ply, L( ply, "cluster.too_many", "选区超过上限 ({max} 方块, mc_cluster_max_blocks)", { max = maxBlocks } ) )
		return
	end
	if not SV.CanEdit( ply ) then return end
	if not clusterCooldownOK( ply ) then return end

	local maxPer = C.ClusterMaxPerPlayer and C.ClusterMaxPerPlayer:GetInt() or 8
	local sid = IsValid( ply ) and ply:SteamID64() or nil
	if maxPer > 0 and countPlayerClusters( sid ) >= maxPer then
		notify( ply, L( ply, "cluster.per_player_limit", "你的结构实体已达上限 ({max} 个, mc_cluster_max_per_player)", { max = maxPer } ) )
		return
	end

	local seen = {}
	local requested = {}
	local minx, miny, minz = math.huge, math.huge, math.huge
	local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
	for _ = 1, count do
		local bx = net.ReadInt( Net.COORD_BITS )
		local by = net.ReadInt( Net.COORD_BITS )
		local bz = net.ReadInt( Net.COORD_BITS )
		local key = MC.CellKey( bx, by, bz )
		if not seen[key] and SV.WorldBoundsOK( bx, by, bz ) then
			seen[key] = true
			requested[#requested + 1] = { bx = bx, by = by, bz = bz }
			minx, miny, minz = math.min( minx, bx ), math.min( miny, by ), math.min( minz, bz )
			maxx, maxy, maxz = math.max( maxx, bx ), math.max( maxy, by ), math.max( maxz, bz )
		end
	end
	if #requested == 0 then return end

	local maxExtent = MC.ClusterMaxExtent()
	if maxx - minx + 1 > maxExtent or maxy - miny + 1 > maxExtent or maxz - minz + 1 > maxExtent then
		notify( ply, L( ply, "cluster.too_large", "选区尺寸超过上限 ({max} 格, mc_cluster_max_extent)", { max = maxExtent } ) )
		return
	end

	-- loose sanity range: the selection AABB must be near the player
	if IsValid( ply ) then
		local eye = ply:EyePos()
		local rangeLimit = math.max( 4096, maxExtent * MC.BS * 4 )
		local nearest = Vector(
			math.Clamp( eye.x, minx * MC.BS, ( maxx + 1 ) * MC.BS ),
			math.Clamp( eye.y, miny * MC.BS, ( maxy + 1 ) * MC.BS ),
			math.Clamp( eye.z, minz * MC.BS, ( maxz + 1 ) * MC.BS ) )
		if eye:DistToSqr( nearest ) > rangeLimit * rangeLimit then
			notify( ply, L( ply, "cluster.too_far", "选区离你太远" ) )
			return
		end
	end

	if not hydrateSelectionChunks( requested ) then
		notify( ply, L( ply, "cluster.not_loaded", "选区内有区块未能加载，请稍后重试" ) )
		return
	end

	local cells = {}
	local removeCells = {}
	local n = 0
	for _, cell in ipairs( requested ) do
		local stateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0
		if stateId ~= 0 then
			cells[n + 1] = cell.bx - minx
			cells[n + 2] = cell.by - miny
			cells[n + 3] = cell.bz - minz
			cells[n + 4] = stateId
			n = n + 4
			removeCells[#removeCells + 1] = cell
		end
	end
	if n == 0 then
		notify( ply, L( ply, "cluster.empty", "选区里没有方块" ) )
		return
	end

	local record = {
		size = { maxx - minx + 1, maxy - miny + 1, maxz - minz + 1 },
		cells = cells,
		crate = crate or nil,
	}

	-- validate physics before touching the world (crate = one box, never fails)
	local convexes, convexErr, convexCount = MC.ClusterCollisionConvexes( record )
	if not convexes then
		if convexErr == "too_complex" then
			notify( ply, L( ply, "cluster.too_complex", "结构太复杂: {n}/{max} 个碰撞凸包", { n = convexCount or 0, max = MC.ClusterMaxConvexes() } ) )
		elseif convexErr == "no_collision" then
			notify( ply, L( ply, "cluster.no_collision", "选区里没有可碰撞的方块" ) )
		else
			notify( ply, L( ply, "cluster.phys_failed", "碰撞构建失败: {err}", { err = tostring( convexErr ) } ) )
		end
		return
	end

	local ent, spawnErr = SV.SpawnCluster( record, MC.CellWorldMin( minx, miny, minz ), angle_zero, true, sid )
	if not IsValid( ent ) then
		notify( ply, L( ply, "cluster.spawn_failed", "生成结构实体失败: {err}", { err = tostring( spawnErr ) } ) )
		return
	end
	ent.ClusterOriginCell = { minx, miny, minz }
	assignClusterOwner( ent, ply )

	-- Removal rides the hydration fast lane (chunk patches touch only the
	-- affected chunks), mirroring preset placement and paste-back. The plain
	-- bulk fallback below brackets every coalesced group with a WHOLE-WORLD
	-- light rebuild client-side — exactly the per-grab tax converting must
	-- not pay — so it only runs when hydration transport is unavailable.
	local changed
	if SV.ApplyBlockHydrationTransaction then
		local airCells = {}
		for i, cell in ipairs( removeCells ) do
			airCells[i] = { bx = cell.bx, by = cell.by, bz = cell.bz, stateId = 0 }
		end
		local result = SV.ApplyBlockHydrationTransaction( airCells, {
			actor = ply,
			fx = false,
			handlers = true,
			blockUpdates = true,
		} )
		if result.ok == true then
			changed = result.changed
		elseif result.error ~= "chunk_hydration_transport_unavailable" then
			ent:Remove()
			notify( ply, L( ply, "cluster.remove_failed", "移除方块失败，转换已取消" ) )
			return
		end
	end
	if changed == nil then
		changed = SV.RemoveBlocksBulk( removeCells, {
			actor = ply,
			fx = false,
			priorityPhys = true,
		} )
	end
	if ( changed or 0 ) <= 0 then
		ent:Remove()
		notify( ply, L( ply, "cluster.remove_failed", "移除方块失败，转换已取消" ) )
		return
	end
	if changed ~= #removeCells then
		MsgN( "[MC] cluster convert removed " .. tostring( changed ) .. "/" .. tostring( #removeCells ) .. " blocks" )
	end

	registerClusterUndo( ply, ent, ent.ClusterOriginCell )
	if MC.RunEvent then MC.RunEvent( "MC.ClusterConverted", ply, ent, #removeCells ) end
	if MC.ClusterEngineStyle == true then broadcastClusterFx( ent, true ) end
	if crate then
		notify( ply, L( ply, "cluster.converted_crate",
			"已转换 {n} 个方块为箱体结构 (整箱碰撞, 物理枪解冻可搬运, 对准按 G 放回网格)",
			{ n = #removeCells } ) )
	else
		notify( ply, L( ply, "cluster.converted",
			"已转换 {n} 个方块为结构实体 (初始为冻结状态, 物理枪解冻后可搬运, 对准后按 G 放回网格)",
			{ n = #removeCells } ) )
	end
end )

--------------------------------------------------------------------- payload
local function dataReplyAllowed( ply )
	if not IsValid( ply ) then return false end
	local t = CurTime()
	local window = ply.mcClusterDataWindow
	if not window or t - window.start >= 1 then
		window = { start = t, sent = 0 }
		ply.mcClusterDataWindow = window
	end
	if window.sent >= DATA_REPLIES_PER_SECOND then return false end
	window.sent = window.sent + 1
	return true
end

net.Receive( "mc_cluster_data_req", function( _, ply )
	local index = net.ReadUInt( 16 )
	if not dataReplyAllowed( ply ) then return end

	local ent = Entity( index )
	if not IsValid( ent ) or ent:GetClass() ~= CLUSTER_CLASS then return end
	local blob = ent.ClusterBlob
	if not blob or blob == "" then return end

	net.Start( "mc_cluster_data" )
		net.WriteUInt( index, 16 )
		net.WriteUInt( #blob, 16 )
		net.WriteData( blob, #blob )
	net.Send( ply )
end )

------------------------------------------------------------------- paste net
net.Receive( "mc_cluster_paste", function( _, ply )
	local index = net.ReadUInt( 16 )
	local ent = Entity( index )
	if not IsValid( ent ) or ent:GetClass() ~= CLUSTER_CLASS then return end
	if not canUseClusters( ply ) then return end
	if not SV.CanEdit( ply ) then return end
	if not clusterCooldownOK( ply ) then return end
	if IsValid( ply ) and ply:EyePos():DistToSqr( ent:WorldSpaceCenter() ) > 4096 * 4096 then return end

	local snap, snapErr = MC.ClusterComputeSnap( ent:GetPos(), ent:GetAngles() )
	if not snap then
		if snapErr == "tilted" then
			notify( ply, L( ply, "cluster.tilted", "结构倾斜太大, 先用物理枪放平再放回" ) )
		end
		return
	end

	local record = ent.ClusterRecord
	if not record then return end
	local targetMin = MC.ClusterSnapTargets( record, snap.pos, snap.rotation )
	local ok, result, blocked = placeClusterAt( ply, ent, targetMin, snap.rotation )
	if ok then
		notify( ply, L( ply, "cluster.pasted", "已把 {n} 个方块放回网格", { n = result } ) )
	else
		notify( ply, L( ply, "cluster.paste_failed", "放回失败: {err}", { err = pasteFailText( ply, result, blocked ) } ) )
	end
end )

------------------------------------------------------------------- breaking
function SV.BreakCluster( ent, attacker )
	if not IsValid( ent ) or ent.ClusterBroken then return end
	ent.ClusterBroken = true

	if MC.RunEvent then MC.RunEvent( "MC.ClusterBroken", ent, attacker ) end
	broadcastClusterFx( ent, false )
	ent:Remove()
end

-- Public: snapshot the non-air cells of an inclusive world cell box into a
-- cluster record without modifying the world. The record AABB is tightened
-- to the occupied cells; the same extent/count caps as the player convert
-- path apply. Pair with SV.SpawnCluster / MC.API.Cluster.Spawn.
function SV.CaptureClusterRecord( x1, y1, z1, x2, y2, z2 )
	local minx, maxx = math.min( x1, x2 ), math.max( x1, x2 )
	local miny, maxy = math.min( y1, y2 ), math.max( y1, y2 )
	local minz, maxz = math.min( z1, z2 ), math.max( z1, z2 )
	local maxExtent = MC.ClusterMaxExtent()
	if maxx - minx + 1 > maxExtent or maxy - miny + 1 > maxExtent or maxz - minz + 1 > maxExtent then
		return nil, "too_large"
	end

	local maxBlocks = MC.ClusterMaxBlocks()
	local found = {}
	local count = 0
	local ominx, ominy, ominz = math.huge, math.huge, math.huge
	local omaxx, omaxy, omaxz = -math.huge, -math.huge, -math.huge
	for bz = minz, maxz do
		for by = miny, maxy do
			for bx = minx, maxx do
				local stateId = MC.GetBlockState( bx, by, bz ) or 0
				if stateId ~= 0 then
					count = count + 1
					if count > maxBlocks then return nil, "too_many_cells" end
					found[#found + 1] = { bx, by, bz, stateId }
					ominx, ominy, ominz = math.min( ominx, bx ), math.min( ominy, by ), math.min( ominz, bz )
					omaxx, omaxy, omaxz = math.max( omaxx, bx ), math.max( omaxy, by ), math.max( omaxz, bz )
				end
			end
		end
	end
	if count == 0 then return nil, "empty" end

	local cells = {}
	local n = 0
	for _, cell in ipairs( found ) do
		cells[n + 1] = cell[1] - ominx
		cells[n + 2] = cell[2] - ominy
		cells[n + 3] = cell[3] - ominz
		cells[n + 4] = cell[4]
		n = n + 4
	end
	return {
		size = { omaxx - ominx + 1, omaxy - ominy + 1, omaxz - ominz + 1 },
		cells = cells,
	}, nil, { bx = ominx, by = ominy, bz = ominz }
end

---------------------------------------------------------------- persistence
local function clusterSidecarPath( path )
	return string.gsub( tostring( path or "" ), "%.[^/%.]*$", "" ) .. "_clusters.dat"
end

local function liveClusterEntities()
	local out = {}
	for _, ent in ipairs( ents.FindByClass( CLUSTER_CLASS ) ) do
		if IsValid( ent ) and ent.ClusterRecord then out[#out + 1] = ent end
	end
	return out
end

local function saveClustersSidecar( path )
	local sidecar = clusterSidecarPath( path )
	local list = {}
	for _, ent in ipairs( liveClusterEntities() ) do
		local pos = ent:GetPos()
		local ang = ent:GetAngles()
		local phys = ent:GetPhysicsObject()
		list[#list + 1] = {
			pos = { math.Round( pos.x, 2 ), math.Round( pos.y, 2 ), math.Round( pos.z, 2 ) },
			ang = { math.Round( ang.p, 2 ), math.Round( ang.y, 2 ), math.Round( ang.r, 2 ) },
			frozen = not ( IsValid( phys ) and phys:IsMotionEnabled() ),
			health = ent.ClusterHealth,
			owner = ent.ClusterOwnerSID,
			ownerName = ent:GetOwnerLabel(),
			origin = ent.ClusterOriginCell,
			size = ent.ClusterRecord.size,
			cells = ent.ClusterRecord.cells,
			crate = ent.ClusterRecord.crate == true or nil,
		}
	end

	if #list == 0 then
		if file.Exists( sidecar, "DATA" ) then file.Delete( sidecar ) end
		return
	end

	local json = util.TableToJSON( { v = 1, clusters = list } )
	local compressed = json and util.Compress( json ) or nil
	if not compressed then
		MsgN( "[MC] cluster sidecar encode failed for " .. sidecar )
		return
	end
	file.Write( sidecar, compressed )
	MsgN( "[MC] saved " .. #list .. " block cluster(s) -> " .. sidecar )
end

local function removeAllClusters()
	for _, ent in ipairs( ents.FindByClass( CLUSTER_CLASS ) ) do
		if IsValid( ent ) then ent:Remove() end
	end
end

local function loadClustersSidecar( path )
	removeAllClusters()

	local sidecar = clusterSidecarPath( path )
	local raw = file.Read( sidecar, "DATA" )
	if not raw or raw == "" then return end

	local json = string.sub( raw, 1, 1 ) == "{" and raw or util.Decompress( raw )
	local data = json and util.JSONToTable( json ) or nil
	if not data or not istable( data.clusters ) then
		MsgN( "[MC] cluster sidecar unreadable: " .. sidecar )
		return
	end

	local loaded = 0
	for _, entry in ipairs( data.clusters ) do
		local record = { size = entry.size, cells = entry.cells, crate = entry.crate == true }
		local ok = MC.ClusterValidateRecord( record )
		local pos = istable( entry.pos ) and Vector( tonumber( entry.pos[1] ) or 0, tonumber( entry.pos[2] ) or 0, tonumber( entry.pos[3] ) or 0 ) or nil
		if ok and pos then
			local ang = istable( entry.ang )
				and Angle( tonumber( entry.ang[1] ) or 0, tonumber( entry.ang[2] ) or 0, tonumber( entry.ang[3] ) or 0 )
				or angle_zero
			local ent = SV.SpawnCluster( record, pos, ang, entry.frozen ~= false, entry.owner )
			if IsValid( ent ) then
				if isstring( entry.ownerName ) and entry.ownerName ~= "" then
					ent:SetOwnerLabel( string.sub( entry.ownerName, 1, 48 ) )
				end
				if istable( entry.origin ) then ent.ClusterOriginCell = entry.origin end
				local health = tonumber( entry.health )
				if health and ( ent.ClusterMaxHealth or 0 ) > 0 then
					ent.ClusterHealth = math.Clamp( health, 1, ent.ClusterMaxHealth )
					ent:SetHealth( math.floor( ent.ClusterHealth ) )
				end
				loaded = loaded + 1
			end
		end
	end
	if loaded > 0 then MsgN( "[MC] loaded " .. loaded .. " block cluster(s) from " .. sidecar ) end
end

-- Wrap the save/load/delete pipeline; the guards keep autorefresh from
-- stacking wrappers.
SV.ClusterOrigSaveToPath = SV.ClusterOrigSaveToPath or SV.SaveToPath
function SV.SaveToPath( path, slotName )
	local ok, a, b, c, d = SV.ClusterOrigSaveToPath( path, slotName )
	-- Save the sidecar next to the file that was ACTUALLY written. On a lazy
	-- world the region persistence layer can redirect a default save to the
	-- chunk store's active manifest, and writing the sidecar at the requested
	-- path instead would orphan it from its save.
	if ok then saveClustersSidecar( isstring( a ) and a or path ) end
	return ok, a, b, c, d
end

SV.ClusterOrigLoadFromPath = SV.ClusterOrigLoadFromPath or SV.LoadFromPath
function SV.LoadFromPath( path, resyncClients, requestedName )
	local ok, err = SV.ClusterOrigLoadFromPath( path, resyncClients, requestedName )
	if ok then loadClustersSidecar( path ) end
	return ok, err
end

SV.ClusterOrigDeleteSave = SV.ClusterOrigDeleteSave or SV.DeleteSave
function SV.DeleteSave( slotName )
	local ok, err = SV.ClusterOrigDeleteSave( slotName )
	if ok and SV.SaveSlotName and SV.SaveSlotPath then
		local slot = SV.SaveSlotName( slotName )
		if slot then
			-- Directory saves keep the sidecar inside the slot folder, which
			-- DeleteSave already swept; the legacy .dat layout keeps it beside
			-- the save, where nothing else would remove it.
			local sidecar = clusterSidecarPath( SV.SaveSlotPath( slot ) )
			if file.Exists( sidecar, "DATA" ) then file.Delete( sidecar ) end
			if SV.LegacySaveSlotPath then
				local legacySidecar = clusterSidecarPath( SV.LegacySaveSlotPath( slot ) )
				if file.Exists( legacySidecar, "DATA" ) then file.Delete( legacySidecar ) end
			end
		end
	end
	return ok, err
end
