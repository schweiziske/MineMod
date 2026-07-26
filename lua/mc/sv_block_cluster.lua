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
	return ent
end

local function assignClusterOwner( ent, ply )
	if not IsValid( ent ) or not IsValid( ply ) then return end
	if ent.SetCreator then ent:SetCreator( ply ) end
	ent:SetOwnerLabel( string.sub( ply:Nick() or "", 1, 48 ) )
	if ent.CPPISetOwner then ent:CPPISetOwner( ply ) end
	if cleanup and cleanup.Add then cleanup.Add( ply, "props", ent ) end
end

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
		if ( MC.GetBlockState( bx, by, bz ) or 0 ) ~= 0 then blocked = blocked + 1 end
		cells[#cells + 1] = { bx = bx, by = by, bz = bz, stateId = rotatedCells[i + 3] }
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

	ent:Remove()
	return true, changed
end

local PASTE_FAIL_TEXT = {
	occupied = "目标位置被方块占用",
	out_of_bounds = "超出建造范围",
	block_limit = "会超过全局方块上限 (mc_max_blocks)",
	no_record = "结构数据缺失",
}

local function pasteFailText( ply, err, blocked )
	if err == "occupied" and blocked then
		return L( ply, "cluster.paste_occupied_n", "目标位置有 {n} 格被方块占用", { n = blocked } )
	end
	return PASTE_FAIL_TEXT[err] or tostring( err )
end

------------------------------------------------------------------ conversion
local function registerClusterUndo( ply, ent, originCell )
	if not ( undo and undo.Create ) or not IsValid( ply ) then return end
	undo.Create( "mc_block_cluster" )
	undo.SetPlayer( ply )
	undo.SetCustomUndoText( L( ply, "cluster.undo_text", "撤销 MC 方块结构 (放回原位)" ) )
	undo.AddFunction( function()
		if not IsValid( ent ) then return end
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
	}

	-- validate physics before touching the world
	local convexes, convexErr, convexCount = MC.BuildClusterConvexes( record.cells, record.size )
	if not convexes then
		if convexErr == "too_complex" then
			notify( ply, L( ply, "cluster.too_complex", "结构太复杂: {n}/{max} 个碰撞凸包", { n = convexCount or 0, max = MC.ClusterMaxConvexes } ) )
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

	local changed = SV.RemoveBlocksBulk( removeCells, {
		actor = ply,
		fx = false,
		priorityPhys = true,
	} )
	if ( changed or 0 ) <= 0 then
		ent:Remove()
		notify( ply, L( ply, "cluster.remove_failed", "移除方块失败，转换已取消" ) )
		return
	end
	if changed ~= #removeCells then
		MsgN( "[MC] cluster convert removed " .. tostring( changed ) .. "/" .. tostring( #removeCells ) .. " blocks" )
	end

	registerClusterUndo( ply, ent, ent.ClusterOriginCell )
	if MC.ClusterEngineStyle == true then broadcastClusterFx( ent, true ) end
	notify( ply, L( ply, "cluster.converted",
		"已转换 {n} 个方块为结构实体 (初始为冻结状态, 物理枪解冻后可搬运, 对准后按 G 放回网格)",
		{ n = #removeCells } ) )
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

	broadcastClusterFx( ent, false )
	ent:Remove()
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
		local record = { size = entry.size, cells = entry.cells }
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
	if ok then saveClustersSidecar( path ) end
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
			local sidecar = clusterSidecarPath( SV.SaveSlotPath( slot ) )
			if file.Exists( sidecar, "DATA" ) then file.Delete( sidecar ) end
		end
	end
	return ok, err
end
