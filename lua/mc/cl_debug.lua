--[[----------------------------------------------------------------------------
	MC : Minecraft-style F3 debug overlay (client only).
------------------------------------------------------------------------------]]

MC = MC or {}

surface.CreateFont( "mc_debug", { font = "Roboto", size = 18, weight = 500 } )

MC.DebugHUD = MC.DebugHUD or false

hook.Add( "PlayerButtonDown", "mc_debug_toggle", function( ply, btn )
	if btn == KEY_F3 and ply == LocalPlayer() then
		MC.DebugHUD = not MC.DebugHUD
	end
end )

concommand.Add( "mc_debug", function()
	MC.DebugHUD = not MC.DebugHUD
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

	local entsRegistered = 0
	for _, e in pairs( MC.ChunkEnts or {} ) do
		if IsValid( e ) then entsRegistered = entsRegistered + 1 end
	end

	local pending = 0
	for _ in pairs( MC.PendingFull or {} ) do pending = pending + 1 end
	local progress = MC.SyncProgress or {}

	print( string.format( "[MC client] world chunks=%d blocks=%d bz=%s..%s meshes=%d chunk ents=%d registered=%d pending=%d progress=%d/%d chunks=%d/%d dirty=%s",
		chunks, blocks, tostring( minBZ ), tostring( maxBZ ), meshes, entsByMap, entsRegistered, pending,
		progress.received or 0, progress.expected or 0, progress.doneChunks or 0, progress.chunks or 0,
		tostring( next( MC.MeshDirty or {} ) ~= nil ) ) )
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
