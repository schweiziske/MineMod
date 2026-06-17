--[[----------------------------------------------------------------------------
	MC : server command layer.

	Console/chat command parsing lives here; world mutation stays in sv_world.lua.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config
local FILL_BULK_CELLS_PER_MESSAGE = 32
local FillJobs = {}
local NextFillBatchAt = 0

local function L( ply, key, fallback, vars )
	return MC.TFor and MC.TFor( ply, key, fallback, vars ) or fallback
end

local function chat( ply, msg )
	if SV.Chat then
		SV.Chat( ply, msg )
		if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. msg ) end
	elseif IsValid( ply ) then
		ply:ChatPrint( "[MC] " .. msg )
		ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. msg )
	else
		MsgN( "[MC] " .. msg )
	end
end

local function trimArg( s )
	return string.match( tostring( s or "" ), "^%s*(.-)%s*$" )
end

local function joinArgs( args, first, last )
	if not args[first] then return nil end
	local out = {}
	for i = first, last or #args do out[#out + 1] = args[i] end
	return table.concat( out, " " )
end

local function copyConsoleArgsWithCommand( command, args )
	local out = { command }
	for i = 1, #args do out[#out + 1] = args[i] end
	return out
end

------------------------------------------------------------------- fill command
local FILL_USAGE = "用法: /fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]> [state]"

local function fillAimText( ply )
	if not IsValid( ply ) or not MC.PlayerBlockAim then return nil end
	local hit = MC.PlayerBlockAim( ply )
	if not hit or not hit.bx then return nil end
	return string.format( "当前瞄准方块坐标: %d %d %d", hit.bx, hit.by, hit.bz )
end

local function sendFillUsage( ply )
	chat( ply, L( ply, "server.fill_usage", FILL_USAGE ) )
	local aim = fillAimText( ply )
	if aim then chat( ply, aim ) end
end

local function appendFillCell( cells, bx, by, bz, id, orient )
	cells[#cells + 1] = {
		bx = bx, by = by, bz = bz,
		id = id, orient = orient,
	}
end

local function buildFillCells( minx, maxx, miny, maxy, minz, maxz, id, orient )
	local cells = {}
	local add = 0

	for z = minz, maxz do
		for y = miny, maxy do
			for x = minx, maxx do
				local old = MC.GetBlock( x, y, z )
				local changed = old ~= id
				if not changed and id ~= 0 then
					changed = MC.GetBlockOrient( x, y, z ) ~= orient
				end
				if changed then
					if id == 0 then
						if old ~= 0 then appendFillCell( cells, x, y, z, 0, 0 ) end
					elseif old == 0 then
						if not SV.PlacementWouldTrapPlayer( x, y, z, id, orient ) then
							add = add + 1
							appendFillCell( cells, x, y, z, id, orient )
						end
					else
						appendFillCell( cells, x, y, z, id, orient )
					end
				end
			end
		end
	end

	return cells, add
end

local function fillBatchCells()
	if C.FillBatchCells then return math.max( 1, C.FillBatchCells:GetInt() ) end
	return math.max( 1, MC.Config.FillBatchCells or 512 )
end

local function fillBatchChunks()
	if C.FillBatchChunks then return math.max( 1, C.FillBatchChunks:GetInt() ) end
	return math.max( 1, MC.Config.FillBatchChunks or 16 )
end

local function fillBatchInterval()
	if C.FillBatchInterval then return math.max( 0, C.FillBatchInterval:GetFloat() ) end
	return math.max( 0, MC.Config.FillBatchInterval or 0.05 )
end

local function fillCellChunkKey( cell )
	local cx, cy, cz = MC.CellToChunk( cell.bx, cell.by, cell.bz )
	return MC.ChunkKey( cx, cy, cz )
end

local function nextFillBatch( job )
	local batch = {}
	local chunks = {}
	local chunkCount = 0
	local maxCells = fillBatchCells()
	local maxChunks = fillBatchChunks()

	while job.index <= #job.cells and #batch < maxCells do
		local cell = job.cells[job.index]
		local key = fillCellChunkKey( cell )
		if not chunks[key] then
			if chunkCount >= maxChunks and #batch > 0 then break end
			chunks[key] = true
			chunkCount = chunkCount + 1
		end
		batch[#batch + 1] = cell
		job.index = job.index + 1
	end

	return batch
end

local function enqueueFillJob( ply, cells )
	FillJobs[#FillJobs + 1] = {
		ply = ply,
		cells = cells,
		index = 1,
		changed = 0,
	}
	chat( ply, string.format( "[fill] queued %d blocks; batch=%d cells/%d chunks every %.2fs",
		#cells, fillBatchCells(), fillBatchChunks(), fillBatchInterval() ) )
end

timer.Create( "mc_fill_jobs", 0.05, 0, function()
	if #FillJobs == 0 then return end
	local now = CurTime()
	if now < NextFillBatchAt then return end
	NextFillBatchAt = now + fillBatchInterval()

	local job = FillJobs[1]
	local batch = nextFillBatch( job )
	if #batch > 0 then
		local changed = SV.SetBlocksBulk( batch, {
			actor = job.ply,
			fx = false,
			handlers = true,
			priorityPhys = false,
			immediatePhys = false,
			netPaced = true,
			cellsPerMessage = FILL_BULK_CELLS_PER_MESSAGE,
		} )
		job.changed = ( job.changed or 0 ) + ( changed or 0 )
	end

	if job.index > #job.cells then
		table.remove( FillJobs, 1 )
		chat( job.ply, L( job.ply, "server.filled", "已填充 {count} 个方块", { count = job.changed or 0 } ) )
	end
end )

local function runFill( ply, args )
	if #args < 8 then sendFillUsage( ply ) return end
	if not SV.CanEdit( ply ) then return end

	local x1, y1, z1 = tonumber( args[2] ), tonumber( args[3] ), tonumber( args[4] )
	local x2, y2, z2 = tonumber( args[5] ), tonumber( args[6] ), tonumber( args[7] )
	local id, orient, blockArg, parseErr = MC.ParseBlockSpec( trimArg( joinArgs( args, 8 ) ) )
	if not x1 or not y1 or not z1 or not x2 or not y2 or not z2 or id == nil or parseErr == "block" then
		sendFillUsage( ply )
		return
	end
	if parseErr == "state" then
		chat( ply, L( ply, "server.invalid_state", "方块状态不合法: {block}", { block = blockArg } ) )
		return
	end

	x1, y1, z1 = math.floor( x1 ), math.floor( y1 ), math.floor( z1 )
	x2, y2, z2 = math.floor( x2 ), math.floor( y2 ), math.floor( z2 )
	local minx, maxx = math.min( x1, x2 ), math.max( x1, x2 )
	local miny, maxy = math.min( y1, y2 ), math.max( y1, y2 )
	local minz, maxz = math.min( z1, z2 ), math.max( z1, z2 )

	if not SV.WorldBoundsOK( minx, miny, minz ) or not SV.WorldBoundsOK( maxx, maxy, maxz ) then
		chat( ply, L( ply, "server.world_limit", "超出建造范围 (mc_world_limit)" ) )
		return
	end

	local volume = ( maxx - minx + 1 ) * ( maxy - miny + 1 ) * ( maxz - minz + 1 )
	local fillMax = C.FillMax and C.FillMax:GetInt() or 32768
	if fillMax > 0 and volume > fillMax then
		chat( ply, L( ply, "server.fill_too_large", "填充范围太大 ({volume} > mc_fill_max {max})", { volume = volume, max = fillMax } ) )
		return
	end

	local cells, add = buildFillCells( minx, maxx, miny, maxy, minz, maxz, id, orient )
	local maxBlocks = C.MaxBlocks:GetInt()
	if id ~= 0 and maxBlocks > 0 and SV.BlockCount + add > maxBlocks then
		chat( ply, L( ply, "server.fill_max_blocks", "会超过方块上限 (mc_max_blocks)" ) )
		return
	end

	if #cells == 0 then
		chat( ply, L( ply, "server.filled", "已填充 {count} 个方块", { count = 0 } ) )
		return
	end

	enqueueFillJob( ply, cells )
	if false then
	local changed = SV.SetBlocksBulk( cells, {
		fx = false,
		handlers = true,
		priorityPhys = false,
		immediatePhys = false,
		netPaced = true,
		cellsPerMessage = FILL_BULK_CELLS_PER_MESSAGE,
	} )
	chat( ply, L( ply, "server.filled", "已填充 {count} 个方块", { count = changed or 0 } ) )
end

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
	runFill( ply, copyConsoleArgsWithCommand( "mc_fill", args ) )
end )
