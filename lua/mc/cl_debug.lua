--[[----------------------------------------------------------------------------
	MC : Minecraft-style F3 debug overlay (client only).
------------------------------------------------------------------------------]]

MC = MC or {}

surface.CreateFont( "mc_debug", { font = "Roboto", size = 18, weight = 500 } )

MC.DebugHUD = MC.DebugHUD or false
MC.mcDebugF3Down = MC.mcDebugF3Down or false
MC.ServerCollisionDebug = MC.ServerCollisionDebug or CreateClientConVar( "mc_server_collision_debug", "0", true, false,
	"Draw server-authoritative MC collision interest bounds" )
MC.ServerCollisionDebugBounds = MC.ServerCollisionDebugBounds or {}
MC.ClientCollisionAreaDebug = MC.ClientCollisionAreaDebug or CreateClientConVar( "mc_client_collision_area_debug", "0", true, false,
	"Draw clientside MC prediction collision interest areas" )
MC.ClientCollisionAABBDebug = MC.ClientCollisionAABBDebug or CreateClientConVar( "mc_client_collision_aabb_debug", "0", true, false,
	"Draw clientside MC prediction collision AABB boxes" )
MC.ClientCollisionAABBDebugLimit = MC.ClientCollisionAABBDebugLimit or CreateClientConVar( "mc_client_collision_aabb_debug_limit", "2048", true, false,
	"Maximum clientside MC prediction collision AABB boxes to draw" )

local function requestServerCollisionDebug()
	if not net or not MC.ServerCollisionDebug then return end
	net.Start( "mc_collision_debug_req" )
		net.WriteBool( MC.ServerCollisionDebug:GetBool() )
	net.SendToServer()
end

cvars.AddChangeCallback( "mc_server_collision_debug", function()
	requestServerCollisionDebug()
end, "mc" )

timer.Simple( 1, requestServerCollisionDebug )

hook.Add( "PlayerButtonDown", "mc_debug_toggle", function( ply, btn )
	if btn == KEY_F3 and ply == LocalPlayer() then
		if MC.mcDebugF3Down then return end
		MC.mcDebugF3Down = true
		MC.DebugHUD = not MC.DebugHUD
	end
end )

hook.Add( "PlayerButtonUp", "mc_debug_toggle_release", function( ply, btn )
	if btn == KEY_F3 and ply == LocalPlayer() then
		MC.mcDebugF3Down = false
	end
end )

concommand.Add( "mc_debug", function()
	MC.DebugHUD = not MC.DebugHUD
end )

-- dump everything we know about the block under the crosshair (debugging
-- connection/texture issues without guessing)
concommand.Add( "mc_block_diag", function()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return end
	local hit = MC.PlayerBlockAim and MC.PlayerBlockAim( ply )
	if not hit or not hit.bx then
		print( "[MC diag] 准星没有指向方块" )
		return
	end
	local bx, by, bz = hit.bx, hit.by, hit.bz
	local id = MC.GetBlock( bx, by, bz )
	local orient = MC.GetBlockOrient( bx, by, bz )
	local b = MC.Blocks[id]
	print( string.format( "[MC diag] cell=(%d,%d,%d) id=%d name=%s mcid=%s", bx, by, bz, id, b and b.name or "?", b and b.mcid or "?" ) )
	if not b then return end
	print( string.format( "  shape=%s solid=%s transparent=%s pane=%s fence=%s translucent=%s",
		tostring( b.shape ), tostring( b.solid ), tostring( b.transparent ),
		tostring( MC.IsPaneBlock and MC.IsPaneBlock( id ) ),
		tostring( MC.IsFenceBlock and MC.IsFenceBlock( id ) ),
		tostring( MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) ) ) )
	print( string.format( "  tiles top=%s side=%s bottom=%s (boxFaces=%s modelQuads=%s)",
		tostring( b.top ), tostring( b.side ), tostring( b.bottom ),
		b.boxFaces and #b.boxFaces or "nil", b.modelQuads and #b.modelQuads or "nil" ) )
	local boxes = MC.BlockBoxes( id, orient, bx, by, bz ) or {}
	print( string.format( "  boxes=%d (post+arms; >1 表示有连接)", #boxes ) )
	for i, box in ipairs( boxes ) do
		print( string.format( "    [%d] %.4f,%.4f,%.4f -> %.4f,%.4f,%.4f %s%s",
			i, box[1], box[2], box[3], box[4], box[5], box[6],
			box.part and ( "part=" .. box.part ) or "", box.dir and ( " dir=" .. box.dir ) or "" ) )
	end
	local dirs = { { 0, -1, "y-" }, { 0, 1, "y+" }, { -1, 0, "x-" }, { 1, 0, "x+" } }
	for _, d in ipairs( dirs ) do
		local nid = MC.GetBlock( bx + d[1], by + d[2], bz )
		local nb = MC.Blocks[nid]
		print( string.format( "  neighbour %s: id=%d name=%s", d[3], nid, nb and nb.name or ( nid == 0 and "air" or "?" ) ) )
	end
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	local key = MC.ChunkKey( cx, cy, cz )
	local ent = MC.ChunkEnts and MC.ChunkEnts[key]
	print( string.format( "  chunk=%s opaqueMesh=%s transMesh=%s chunkEnt=%s phys=%s",
		key, tostring( MC.Meshes and MC.Meshes[key] ~= nil ), tostring( MC.MeshesTrans and MC.MeshesTrans[key] ~= nil ),
		tostring( IsValid( ent ) ), tostring( IsValid( ent ) and IsValid( ent:GetPhysicsObject() ) ) ) )
	print( string.format( "  material err: opaque=%s translucent=%s",
		tostring( MC.Material and MC.Material:IsError() ), tostring( MC.MaterialTranslucent and MC.MaterialTranslucent:IsError() ) ) )
end )

concommand.Add( "mc_client_diag", function()
	local chunks, blocks = 0, 0
	local minBZ, maxBZ
	for _, c in pairs( MC.World or {} ) do
		if c.count and c.count > 0 then
			chunks = chunks + 1
			blocks = blocks + c.count
			for li in pairs( c.blocks or {} ) do
				local _, _, lz = MC.DecodeLocal( li )
				local bz = c.cz * MC.CH + lz
				minBZ = minBZ and math.min( minBZ, bz ) or bz
				maxBZ = maxBZ and math.max( maxBZ, bz ) or bz
			end
		end
	end

	local meshes = 0
	for _, list in pairs( MC.Meshes or {} ) do
		if istable( list ) and #list > 0 then meshes = meshes + 1 end
	end

	local entsByMap = 0
	for _, e in ipairs( ents.FindByClass( "mc_chunk" ) ) do
		if IsValid( e ) then entsByMap = entsByMap + 1 end
	end

	local subchunkEnts, subchunkPhys = 0, 0
	for _, e in ipairs( ents.FindByClass( "mc_chunk_phys" ) ) do
		if IsValid( e ) then
			subchunkEnts = subchunkEnts + 1
			if IsValid( e:GetPhysicsObject() ) then subchunkPhys = subchunkPhys + 1 end
		end
	end

	local entsRegistered = 0
	for _, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then entsRegistered = entsRegistered + 1 end
	end

	local pending = 0
	for _ in pairs( MC.PendingFull or {} ) do pending = pending + 1 end
	local progress = MC.SyncProgress or {}
	local renderStats = MC.RenderStats or {}
	local physStats = MC.ClientPhysStats or {}
	local ply = LocalPlayer()
	local playerKey = "nil"
	local playerWorld = false
	local playerEnt = false
	local playerInterest = false
	local aimKey = "nil"
	local aimWorld = false
	local aimEnt = false
	local aimInterest = false

	if IsValid( ply ) then
		local pos = ply.WorldSpaceCenter and ply:WorldSpaceCenter() or ply:GetPos()
		local bx, by, bz = MC.WorldToCell( pos )
		local cx, cy, cz = MC.CellToChunk( bx, by, bz )
		playerKey = MC.ChunkKey( cx, cy, cz )
		playerWorld = MC.World and MC.World[playerKey] ~= nil
		playerEnt = MC.ChunkEnts and IsValid( MC.ChunkEnts[playerKey] )
		playerInterest = MC.ClientCollisionInterest and MC.ClientCollisionInterest[playerKey] ~= nil

		local aimDistConvar = GetConVar( "mc_collision_aim_distance" )
		local aimDist = aimDistConvar and aimDistConvar:GetFloat() or ( MC.Config and MC.Config.CollisionAimDistance ) or MC.BS * 64
		local hit = MC.TraceBlockRay and MC.TraceBlockRay( ply:EyePos(), ply:EyeAngles():Forward(), aimDist ) or nil
		if hit and hit.bx then
			local acx, acy, acz = MC.CellToChunk( hit.bx, hit.by, hit.bz )
			aimKey = MC.ChunkKey( acx, acy, acz )
			aimWorld = MC.World and MC.World[aimKey] ~= nil
			aimEnt = MC.ChunkEnts and IsValid( MC.ChunkEnts[aimKey] )
			aimInterest = MC.ClientCollisionInterest and MC.ClientCollisionInterest[aimKey] ~= nil
		end
	end

	print( string.format( "[MC client] world chunks=%d blocks=%d bz=%s..%s meshes=%d chunk ents=%d registered=%d pending=%d progress=%d/%d chunks=%d/%d dirty=%s",
		chunks, blocks, tostring( minBZ ), tostring( maxBZ ), meshes, entsByMap, entsRegistered, pending,
		progress.received or 0, progress.expected or 0, progress.doneChunks or 0, progress.chunks or 0,
		tostring( next( MC.MeshDirty or {} ) ~= nil ) ) )
	print( string.format( "[MC client] imesh key=%s time=%sms blocks=%s opaque=%s trans=%s",
		tostring( renderStats.lastMeshKey ), tostring( renderStats.lastMeshBuildMS ),
		tostring( renderStats.lastMeshBlocks ), tostring( renderStats.lastOpaqueMeshes ),
		tostring( renderStats.lastTranslucentMeshes ) ) )
	print( string.format( "[MC client] collision key=%s time=%sms bounds=%s phys=%s dirty=%s",
		tostring( physStats.lastClientPhysKey ), tostring( physStats.lastClientPhysBuildMS ),
		tostring( physStats.lastClientPhysBounds ), tostring( physStats.lastClientPhysHadObject ),
		tostring( next( MC.PhysDirty or {} ) ~= nil ) ) )
	print( string.format( "[MC client] collision detail mode=%s chunk=%s inputBounds=%s boxes=%s custom=%s convexes=%s subchunks=%s subchunkPhys=%s mainPhys=%s totalSubchunkEnts=%d/%d",
		tostring( physStats.lastClientPhysMode ), tostring( physStats.lastClientPhysChunkKey ),
		tostring( physStats.lastClientPhysInputBounds ), tostring( physStats.lastClientPhysBoxes ),
		tostring( physStats.lastClientPhysCustomConvexes ), tostring( physStats.lastClientPhysConvexes ),
		tostring( physStats.lastClientPhysSubchunks ), tostring( physStats.lastClientPhysSubchunkObjects ),
		tostring( physStats.lastClientPhysMainObject ), subchunkPhys, subchunkEnts ) )
	print( string.format( "[MC client] collision target playerKey=%s world=%s ent=%s interest=%s aimKey=%s world=%s ent=%s interest=%s lastReason=%s",
		tostring( playerKey ), tostring( playerWorld ), tostring( playerEnt ), tostring( playerInterest ),
		tostring( aimKey ), tostring( aimWorld ), tostring( aimEnt ), tostring( aimInterest ),
		tostring( physStats.lastClientPhysReason ) ) )
	print( string.format( "[MC client] server collision debug=%s bounds=%d age=%s",
		tostring( MC.ServerCollisionDebug and MC.ServerCollisionDebug:GetBool() ),
		#( MC.ServerCollisionDebugBounds or {} ),
		tostring( MC.ServerCollisionDebugUpdated and math.Round( CurTime() - MC.ServerCollisionDebugUpdated, 3 ) or "nil" ) ) )
	print( string.format( "[MC client] client collision debug area=%s aabb=%s interest=%d aabbBoxes=%d",
		tostring( MC.ClientCollisionAreaDebug and MC.ClientCollisionAreaDebug:GetBool() ),
		tostring( MC.ClientCollisionAABBDebug and MC.ClientCollisionAABBDebug:GetBool() ),
		table.Count( MC.ClientCollisionInterest or {} ),
		table.Count( MC.ClientCollisionAABBDebugBoxes or {} ) ) )
end )

local function mcProbeVec( v )
	if not v then return "nil" end
	return string.format( "(%.1f %.1f %.1f)", v.x, v.y, v.z )
end

local function mcProbeEnt( ent )
	if not IsValid( ent ) then return tostring( ent ) end
	return string.format( "%s idx=%s class=%s", tostring( ent ), tostring( ent:EntIndex() ), tostring( ent:GetClass() ) )
end

concommand.Add( "mc_phys_probe", function()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return end

	local start = ply:GetPos() + Vector( 0, 0, 8 )
	local finish = ply:GetPos() - Vector( 0, 0, 192 )
	local tr = util.TraceHull( {
		start = start,
		endpos = finish,
		mins = ply:OBBMins(),
		maxs = ply:OBBMaxs(),
		mask = MASK_PLAYERSOLID,
		filter = function( ent ) return ent ~= ply end,
	} )

	print( string.format( "[MCPROBE] player=%s hull=%s->%s hit=%s hitWorld=%s ent=%s hitPos=%s",
		mcProbeVec( ply:GetPos() ), mcProbeVec( start ), mcProbeVec( finish ),
		tostring( tr.Hit ), tostring( tr.HitWorld ), mcProbeEnt( tr.Entity ), mcProbeVec( tr.HitPos ) ) )

	local found = {}
	for _, ent in ipairs( ents.FindByClass( "mc_chunk_phys" ) ) do
		if IsValid( ent ) then
			local mins, maxs = ent:WorldSpaceAABB()
			local center = ( mins + maxs ) * 0.5
			found[#found + 1] = { ent = ent, mins = mins, maxs = maxs, dist = center:DistToSqr( ply:GetPos() ) }
		end
	end
	table.sort( found, function( a, b ) return a.dist < b.dist end )

	for i = 1, math.min( #found, 8 ) do
		local item = found[i]
		local ent = item.ent
		local phys = ent:GetPhysicsObject()
		print( string.format( "[MCPROBE] #%d %s key=%s subkey=%s nw=%s/%s/%s pos=%s solid=%s group=%s movetype=%s phys=%s physPos=%s aabb=%s->%s",
			i, mcProbeEnt( ent ), tostring( ent.ChunkKey ), tostring( ent.CollisionSubchunkKey ),
			tostring( ent:GetNWString( "MCChunkKey", "" ) ), tostring( ent:GetNWString( "MCSubchunkKey", "" ) ),
			tostring( ent:GetNWInt( "MCPhysPage", -1 ) ), mcProbeVec( ent:GetPos() ),
			tostring( ent:GetSolid() ), tostring( ent:GetCollisionGroup() ),
			tostring( ent:GetMoveType() ), tostring( IsValid( phys ) ),
			mcProbeVec( IsValid( phys ) and phys.GetPos and phys:GetPos() or nil ),
			mcProbeVec( item.mins ), mcProbeVec( item.maxs ) ) )
	end
end )

local function facingName( yaw )
	yaw = ( yaw % 360 + 360 ) % 360
	if yaw < 45 or yaw >= 315 then return "+X (东)" end
	if yaw < 135 then return "+Y (南)" end
	if yaw < 225 then return "-X (西)" end
	return "-Y (北)"
end

local function worldStats()
	local chunks, blocks = 0, 0
	for _, c in pairs( MC.World ) do
		if c.count and c.count > 0 then
			chunks = chunks + 1
			blocks = blocks + c.count
		end
	end
	return chunks, blocks
end

hook.Add( "HUDPaint", "mc_debug_hud", function()
	if not MC.DebugHUD then return end
	local ply = LocalPlayer()
	if not IsValid( ply ) then return end

	local pos = ply:GetPos()
	local bx, by, bz = MC.WorldToCell( pos )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )

	local tr = ply:GetEyeTrace()
	local lx, ly, lz = MC.WorldToCell( tr.HitPos - tr.HitNormal * 0.5 )
	local lid = MC.GetBlock( lx, ly, lz )
	local orient = MC.GetBlockOrient( lx, ly, lz )
	local state = MC.BlockStateText( lid, orient )
	local lcx, lcy, lcz = MC.CellToChunk( lx, ly, lz )
	local lb = MC.Blocks[lid]

	local chunks, blocks = worldStats()
	local renderStats = MC.RenderStats or {}
	local physStats = MC.ClientPhysStats or {}

	local looked = string.format( "%d %d %d [%d %s]", lx, ly, lz, lid, lb and lb.disp or "空气" )
	if state ~= "" then looked = looked .. " " .. state end

	local lines = {
		"MC 调试 (F3)",
		string.format( "XYZ:          %.1f   %.1f   %.1f", pos.x, pos.y, pos.z ),
		string.format( "方块格:       %d   %d   %d", bx, by, bz ),
		string.format( "区块列:       %d   %d", cx, cy ),
		"朝向:         " .. facingName( ply:EyeAngles().yaw ),
		"",
		"看向方块:     " .. looked,
		string.format( "看向区块列:   %d   %d", lcx, lcy ),
		string.format( "已加载:       %d 区块 / %d 方块", chunks, blocks ),
	}

	table.insert( lines, string.format( "IMesh:        %s ms  %s O / %s T", tostring( renderStats.lastMeshBuildMS ), tostring( renderStats.lastOpaqueMeshes ), tostring( renderStats.lastTranslucentMeshes ) ) )
	table.insert( lines, string.format( "Client Phys:  %s ms  bounds=%s", tostring( physStats.lastClientPhysBuildMS ), tostring( physStats.lastClientPhysBounds ) ) )

	surface.SetFont( "mc_debug" )
	local _, lh = surface.GetTextSize( "Ag" )
	local maxw = 0
	for i = 1, #lines do
		local w = surface.GetTextSize( lines[i] )
		if w > maxw then maxw = w end
	end

	local x, y, pad = 16, 130, 10
	draw.RoundedBox( 4, x, y, maxw + pad * 2, #lines * lh + pad * 2, Color( 0, 0, 0, 180 ) )

	local ty = y + pad
	for i = 1, #lines do
		draw.SimpleText( lines[i], "mc_debug", x + pad, ty, i == 1 and Color( 120, 235, 140 ) or color_white )
		ty = ty + lh
	end
end )

hook.Remove( "PostDrawTranslucentRenderables", "mc_server_collision_debug_draw" )
hook.Add( "PostDrawTranslucentRenderables", "mc_server_collision_debug_draw", function()
	if not MC.ServerCollisionDebug or not MC.ServerCollisionDebug:GetBool() then return end
	local bounds = MC.ServerCollisionDebugBounds or {}
	if #bounds == 0 then return end
	render.SetColorMaterial()
	local col = Color( 0, 220, 255, 220 )
	for _, b in ipairs( bounds ) do
		render.DrawWireframeBox( vector_origin, angle_zero, b.mins, b.maxs, col, true )
	end
end )

local function clientCollisionInterestWorldBounds( key, b )
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return nil end
	local origin = MC.ChunkWorldOrigin( cx, cy, cz )
	local bs = MC.BS
	return origin + Vector( b[1] * bs, b[2] * bs, b[3] * bs ),
		origin + Vector( ( b[4] + 1 ) * bs, ( b[5] + 1 ) * bs, ( b[6] + 1 ) * bs )
end

hook.Remove( "PostDrawTranslucentRenderables", "mc_client_collision_area_debug_draw" )
hook.Add( "PostDrawTranslucentRenderables", "mc_client_collision_area_debug_draw", function()
	if not MC.ClientCollisionAreaDebug or not MC.ClientCollisionAreaDebug:GetBool() then return end
	local interest = MC.ClientCollisionInterest or {}
	if next( interest ) == nil then return end

	local limit = MC.ClientCollisionAABBDebugLimit and MC.ClientCollisionAABBDebugLimit:GetInt() or 2048
	limit = math.Clamp( math.floor( tonumber( limit ) or 2048 ), 1, 20000 )
	local drawn = 0
	render.SetColorMaterial()
	local col = Color( 255, 220, 40, 230 )
	for key, bounds in pairs( interest ) do
		for _, b in ipairs( bounds or {} ) do
			local mins, maxs = clientCollisionInterestWorldBounds( key, b )
			if mins and maxs then
				render.DrawWireframeBox( vector_origin, angle_zero, mins, maxs, col, true )
				drawn = drawn + 1
				if drawn >= limit then return end
			end
		end
	end
end )

hook.Remove( "PostDrawTranslucentRenderables", "mc_client_collision_aabb_debug_draw" )
hook.Add( "PostDrawTranslucentRenderables", "mc_client_collision_aabb_debug_draw", function()
	if not MC.ClientCollisionAABBDebug or not MC.ClientCollisionAABBDebug:GetBool() then return end
	local byChunk = MC.ClientCollisionAABBDebugBoxes or {}
	if next( byChunk ) == nil then return end

	local limit = MC.ClientCollisionAABBDebugLimit and MC.ClientCollisionAABBDebugLimit:GetInt() or 2048
	limit = math.Clamp( math.floor( tonumber( limit ) or 2048 ), 1, 20000 )
	local drawn = 0
	render.SetColorMaterial()
	local col = Color( 80, 255, 120, 230 )
	for _, boxes in pairs( byChunk ) do
		for _, b in ipairs( boxes ) do
			render.DrawWireframeBox( vector_origin, angle_zero, b.mins, b.maxs, col, true )
			drawn = drawn + 1
			if drawn >= limit then return end
		end
	end
end )
