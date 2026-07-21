-- Server-side builder for a Minecraft Debug World style block/state gallery.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local BUILD_TIMER = "mc_debug_gallery_build"
local GLOBAL_DESCRIPTOR = "mc_debug_gallery"
local BATCH_CELLS = 1024
local BATCH_INTERVAL = 0.02
local DEFAULT_COLUMNS = { blocks = 40, states = 64, promo = 1, build = 1 }
local DEFAULT_STATE_ROWS_PER_LAYER = 64
local DEFAULT_STATE_LAYER_HEIGHT = 8
local DEFAULT_SPACING = 2
local SAMPLE_HEIGHT = 3
local ActiveJob
local NextJobId = 0

local function output( ply, message )
	message = tostring( message or "" )
	MsgN( "[MC debug gallery] " .. message )
	if IsValid( ply ) then
		ply:ChatPrint( "[MC] " .. message )
		ply:PrintMessage( HUD_PRINTCONSOLE, "[MC] " .. message )
	end
end

local function publish( descriptor )
	SV.DebugGalleryDescriptor = descriptor
	SetGlobalString( GLOBAL_DESCRIPTOR, descriptor and ( util.TableToJSON( descriptor, false ) or "" ) or "" )
end

local function nextJobId()
	NextJobId = ( NextJobId + 1 ) % 4294967296
	if NextJobId == 0 then NextJobId = 1 end
	return NextJobId
end

local function blockState( name, fallback )
	local stateId = MC.DefaultBlockState and MC.DefaultBlockState( name ) or nil
	if stateId and stateId ~= 0 then return stateId end
	return fallback
end

local function pedestalStates()
	local stone = blockState( "minecraft:stone", 1 )
	return blockState( "minecraft:light_gray_concrete", stone ), blockState( "minecraft:black_concrete", stone )
end

local function cardinalAxes( ply )
	if not IsValid( ply ) then return 1, 0, 0, 1 end
	local forward = ply:EyeAngles():Forward()
	local rowX, rowY
	if math.abs( forward.x ) >= math.abs( forward.y ) then
		rowX, rowY = forward.x >= 0 and 1 or -1, 0
	else
		rowX, rowY = 0, forward.y >= 0 and 1 or -1
	end
	return rowY, -rowX, rowX, rowY
end

local function initialDescriptor( ply, mode, columns, spacing, rowsPerLayer, layerHeight )
	local entries = MC.DebugGalleryEntries( mode )
	local columnX, columnY, rowX, rowY = cardinalAxes( ply )
	local playerX, playerY, playerZ = 0, 0, 0
	if IsValid( ply ) then playerX, playerY, playerZ = MC.WorldToCell( ply:GetPos() + Vector( 0, 0, 1 ) ) end
	local width = ( columns - 1 ) * spacing
	local forwardOffset = mode == "promo" and 10 or mode == "build" and 8 or 6
	local originX = playerX + rowX * forwardOffset - columnX * math.floor( width * 0.5 )
	local originY = playerY + rowY * forwardOffset - columnY * math.floor( width * 0.5 )
	return {
		version = 1,
		mode = mode,
		count = #entries,
		columns = columns,
		spacing = spacing,
		rowsPerLayer = rowsPerLayer,
		layerHeight = layerHeight,
		layers = math.ceil( #entries / ( columns * rowsPerLayer ) ),
		originX = originX,
		originY = originY,
		baseZ = playerZ,
		sampleZ = playerZ + SAMPLE_HEIGHT,
		columnX = columnX,
		columnY = columnY,
		rowX = rowX,
		rowY = rowY,
		status = "building",
		progress = 0,
	}
end

local function fitDescriptorToWorld( descriptor )
	local limit = SV.WorldCoordinateLimit and SV.WorldCoordinateLimit() or 1024
	local minX, minY, minZ, maxX, maxY, maxZ = MC.DebugGalleryBounds( descriptor )
	if not minX then return false, "empty_gallery" end
	if maxX - minX > limit * 2 or maxY - minY > limit * 2 or maxZ - minZ > limit * 2 then
		return false, "gallery_too_large_for_mc_world_limit"
	end
	local shiftX, shiftY, shiftZ = 0, 0, 0
	if minX < -limit then shiftX = -limit - minX end
	if maxX + shiftX > limit then shiftX = limit - maxX end
	if minY < -limit then shiftY = -limit - minY end
	if maxY + shiftY > limit then shiftY = limit - maxY end
	if minZ < -limit then shiftZ = -limit - minZ end
	if maxZ + shiftZ > limit then shiftZ = limit - maxZ end
	descriptor.originX = descriptor.originX + shiftX
	descriptor.originY = descriptor.originY + shiftY
	descriptor.baseZ = descriptor.baseZ + shiftZ
	descriptor.sampleZ = descriptor.sampleZ + shiftZ
	return true
end

local function descriptorCellKeys( descriptor )
	local keys = {}
	if not descriptor then return keys end
	for index = 1, descriptor.count or 0 do
		local bx, by, bz = MC.DebugGalleryCell( descriptor, index, false )
		keys[MC.CellKey( bx, by, bz )] = true
		bx, by, bz = MC.DebugGalleryCell( descriptor, index, true )
		keys[MC.CellKey( bx, by, bz )] = true
	end
	for _, cell in ipairs( MC.DebugGalleryPromoDecorCells and MC.DebugGalleryPromoDecorCells( descriptor ) or {} ) do
		local bx = descriptor.originX + cell.x * descriptor.columnX + cell.y * descriptor.rowX
		local by = descriptor.originY + cell.x * descriptor.columnY + cell.y * descriptor.rowY
		keys[MC.CellKey( bx, by, descriptor.baseZ + cell.z )] = true
	end
	return keys
end

local function prepareBuildChanges( descriptor, oldDescriptor, force )
	local entries = MC.DebugGalleryEntries( descriptor.mode )
	local oldOwned = descriptorCellKeys( oldDescriptor )
	local desired = {}
	local changes = {}
	local delta = 0
	local occupied = 0
	local occupiedExamples = {}
	local lightBase, darkBase = pedestalStates()

	local function want( bx, by, bz, stateId )
		local key = MC.CellKey( bx, by, bz )
		desired[key] = true
		local oldStateId = MC.GetBlockState( bx, by, bz )
		if oldStateId == stateId then return end
		if oldStateId ~= 0 and not oldOwned[key] and not force then
			occupied = occupied + 1
			if #occupiedExamples < 4 then occupiedExamples[#occupiedExamples + 1] = string.format( "%d,%d,%d", bx, by, bz ) end
			return
		end
		if oldStateId == 0 and stateId ~= 0 then delta = delta + 1 end
		if oldStateId ~= 0 and stateId == 0 then delta = delta - 1 end
		changes[#changes + 1] = { bx = bx, by = by, bz = bz, stateId = stateId }
	end

	for index, stateId in ipairs( entries ) do
		local bx, by, bz, column, row = MC.DebugGalleryCell( descriptor, index, false )
		want( bx, by, bz, stateId )
		-- Promo/build entries rest on the decor scenery instead of floating above checker pedestals.
		if descriptor.mode ~= "promo" and descriptor.mode ~= "build" then
			local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
			local parity = descriptor.mode == "states" and ( ( schema and schema.blockId or index ) % 2 ) or ( ( column + row ) % 2 )
			bx, by, bz = MC.DebugGalleryCell( descriptor, index, true )
			want( bx, by, bz, parity == 0 and lightBase or darkBase )
		end
	end
	for _, cell in ipairs( MC.DebugGalleryPromoDecorCells and MC.DebugGalleryPromoDecorCells( descriptor ) or {} ) do
		local bx = descriptor.originX + cell.x * descriptor.columnX + cell.y * descriptor.rowX
		local by = descriptor.originY + cell.x * descriptor.columnY + cell.y * descriptor.rowY
		want( bx, by, descriptor.baseZ + cell.z, cell.stateId )
	end

	if oldDescriptor then
		for index = 1, oldDescriptor.count or 0 do
			for _, baseLayer in ipairs( { false, true } ) do
				local bx, by, bz = MC.DebugGalleryCell( oldDescriptor, index, baseLayer )
				local key = MC.CellKey( bx, by, bz )
				if not desired[key] then want( bx, by, bz, 0 ) end
			end
		end
	end

	if occupied > 0 then return nil, "occupied", occupied, occupiedExamples end
	local maxBlocks = MC.Config and MC.Config.MaxBlocks and MC.Config.MaxBlocks:GetInt() or 0
	if maxBlocks > 0 and ( SV.BlockCount or 0 ) + delta > maxBlocks then return nil, "max_blocks" end
	return changes, nil, delta
end

local function prepareClearChanges( descriptor )
	local changes = {}
	for index = 1, descriptor.count or 0 do
		for _, baseLayer in ipairs( { false, true } ) do
			local bx, by, bz = MC.DebugGalleryCell( descriptor, index, baseLayer )
			if MC.GetBlockState( bx, by, bz ) ~= 0 then
				changes[#changes + 1] = { bx = bx, by = by, bz = bz, stateId = 0 }
			end
		end
	end
	for _, cell in ipairs( MC.DebugGalleryPromoDecorCells and MC.DebugGalleryPromoDecorCells( descriptor ) or {} ) do
		local bx = descriptor.originX + cell.x * descriptor.columnX + cell.y * descriptor.rowX
		local by = descriptor.originY + cell.x * descriptor.columnY + cell.y * descriptor.rowY
		local bz = descriptor.baseZ + cell.z
		if MC.GetBlockState( bx, by, bz ) ~= 0 then changes[#changes + 1] = { bx = bx, by = by, bz = bz, stateId = 0 } end
	end
	return changes
end

local function flushJobPhysics( job )
	for key in pairs( job.physKeys or {} ) do
		if SV.MarkPhysDirtyBulk then SV.MarkPhysDirtyBulk( key ) end
	end
	if MC.ClearAllBlockConnectionMaskCaches then MC.ClearAllBlockConnectionMaskCaches() end
end

local function finishJob( job, failed )
	timer.Remove( BUILD_TIMER )
	flushJobPhysics( job )
	if SV.EndStateBulkGroup then SV.EndStateBulkGroup( job.id, SV.BlockRevision ) end
	ActiveJob = nil
	if failed then
		job.descriptor.status = "failed"
		job.descriptor.error = failed
		publish( job.descriptor )
		output( job.ply, "调试展台生成失败: " .. tostring( failed ) .. "；可运行 mc_debug_world clear 清理已生成部分。" )
		return
	end
	if job.clear then
		publish( nil )
		output( job.ply, string.format( "已清理调试展台（%d 处改动）。", job.changed ) )
		return
	end
	job.descriptor.status = "ready"
	job.descriptor.progress = 1
	job.descriptor.changed = job.changed
	job.descriptor.finishedAt = os.time()
	publish( job.descriptor )
	output( job.ply, string.format(
		"调试展台完成：%s 模式，%d 个条目，%d 层，%d 处改动。准星指向方块即可查看完整标识。",
		job.descriptor.mode == "states" and "全部状态" or job.descriptor.mode == "promo" and "宣传展示"
			or job.descriptor.mode == "build" and "建造场景" or "每种方块",
		job.descriptor.count, job.descriptor.layers or 1, job.changed
	) )
end

local function startJob( ply, descriptor, changes, clear )
	local job = {
		id = nextJobId(),
		ply = ply,
		descriptor = descriptor,
		changes = changes,
		index = 1,
		changed = 0,
		physKeys = {},
		clear = clear == true,
		lastPublishedBucket = -1,
	}
	ActiveJob = job
	publish( descriptor )
	if #changes == 0 then finishJob( job ) return end

	timer.Create( BUILD_TIMER, BATCH_INTERVAL, 0, function()
		if ActiveJob ~= job then timer.Remove( BUILD_TIMER ) return end
		local batch = {}
		local last = math.min( #job.changes, job.index + BATCH_CELLS - 1 )
		for index = job.index, last do batch[#batch + 1] = job.changes[index] end
		local changed, err = SV.SetBlocksBulk( batch, {
			actor = job.ply,
			fx = false,
			handlers = false,
			blockUpdates = false,
			priorityPhys = false,
			immediatePhys = false,
			netPaced = true,
			stateStream = true,
			stateGroupId = job.id,
			physCollector = job.physKeys,
		} )
		if err then finishJob( job, err ) return end
		job.changed = job.changed + ( changed or 0 )
		job.index = last + 1

		local progress = math.min( 1, ( job.index - 1 ) / #job.changes )
		local bucket = math.floor( progress * 20 )
		if bucket ~= job.lastPublishedBucket then
			job.lastPublishedBucket = bucket
			job.descriptor.progress = progress
			publish( job.descriptor )
		end
		if job.index > #job.changes then finishJob( job ) end
	end )
end

local function usage( ply )
	output( ply, "用法: mc_debug_world [blocks|states|promo|build|clear|status] [列数] [间距] [每层行数] [层高] [force]" )
end

local function runCommand( ply, args )
	if IsValid( ply ) and not ply:IsAdmin() then output( ply, "只有管理员可以生成调试展台。" ) return end
	local action = string.lower( tostring( args[1] or "blocks" ) )
	if action == "status" then
		local descriptor = SV.DebugGalleryDescriptor
		if not descriptor then output( ply, "当前没有调试展台。" ) return end
		output( ply, string.format( "模式=%s 条目=%d 层数=%d 状态=%s 进度=%d%%",
			descriptor.mode, descriptor.count or 0, descriptor.layers or 1,
			descriptor.status or "?", math.floor( ( descriptor.progress or 0 ) * 100 ) ) )
		return
	end
	if ActiveJob then output( ply, "已有调试展台任务正在执行，请等待完成。" ) return end
	if action == "clear" then
		local descriptor = SV.DebugGalleryDescriptor
		if not descriptor then output( ply, "当前没有可清理的调试展台。" ) return end
		local changes = prepareClearChanges( descriptor )
		descriptor.status = "clearing"
		descriptor.progress = 0
		output( ply, string.format( "开始清理调试展台，共 %d 处改动。", #changes ) )
		startJob( ply, descriptor, changes, true )
		return
	end
	if action ~= "blocks" and action ~= "states" and action ~= "promo" and action ~= "build" then usage( ply ) return end
	if not MC.BlockStateRegistryFrozen then output( ply, "方块状态注册表尚未就绪，请稍后重试。" ) return end

	local columns = math.Clamp( math.floor( tonumber( args[2] ) or DEFAULT_COLUMNS[action] ), 1, 256 )
	local spacing = math.Clamp( math.floor( tonumber( args[3] ) or DEFAULT_SPACING ), 1, 8 )
	local rowsPerLayer = action == "states"
		and math.Clamp( math.floor( tonumber( args[4] ) or DEFAULT_STATE_ROWS_PER_LAYER ), 1, 256 )
		or math.max( 1, math.ceil( #MC.DebugGalleryEntries( action ) / columns ) )
	local layerHeight = action == "states"
		and math.Clamp( math.floor( tonumber( args[5] ) or DEFAULT_STATE_LAYER_HEIGHT ), SAMPLE_HEIGHT + 2, 64 )
		or 1
	local force = false
	for _, arg in ipairs( args ) do if string.lower( tostring( arg ) ) == "force" then force = true end end
	local descriptor = initialDescriptor( ply, action, columns, spacing, rowsPerLayer, layerHeight )
	local fit, fitError = fitDescriptorToWorld( descriptor )
	if not fit then output( ply, "无法生成调试展台: " .. tostring( fitError ) ) return end
	local changes, changeError, occupied, examples = prepareBuildChanges( descriptor, SV.DebugGalleryDescriptor, force )
	if not changes then
		if changeError == "occupied" then
			output( ply, string.format( "目标区域有 %d 个非展台方块（如 %s）。确认可覆盖后在命令末尾加 force。",
				occupied or 0, table.concat( examples or {}, " / " ) ) )
		elseif changeError == "max_blocks" then
			output( ply, "生成后会超过 mc_max_blocks 限制。" )
		else
			output( ply, "无法生成调试展台: " .. tostring( changeError ) )
		end
		return
	end
	output( ply, string.format( "开始生成 %s 调试展台：%d 个条目，%d 层，%d 处改动。",
		action == "states" and "全部状态" or action == "promo" and "宣传展示"
			or action == "build" and "建造场景" or "每种方块",
		descriptor.count, descriptor.layers, #changes ) )
	startJob( ply, descriptor, changes, false )
end

concommand.Add( "mc_debug_world", function( ply, _, args ) runCommand( ply, args ) end )

hook.Add( "PlayerSay", "mc_debug_world_chat", function( ply, text )
	local args = string.Explode( "%s+", string.Trim( text ), true )
	local command = string.lower( tostring( args[1] or "" ) )
	if command ~= "/debugworld" and command ~= "!debugworld" then return end
	table.remove( args, 1 )
	runCommand( ply, args )
	return ""
end )

hook.Add( "InitPostEntity", "mc_debug_gallery_publish", function()
	publish( SV.DebugGalleryDescriptor )
end )
