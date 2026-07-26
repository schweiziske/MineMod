-- Atomic/staged destination writer for validated Minecraft import plans.

MC = MC or {}
MC.Import = MC.Import or {}
MC.SV = MC.SV or {}

local Import, SV = MC.Import, MC.SV
local Host = SV.WorldImportHost
if not Host then error( "MC world import host is unavailable" ) end

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[copyValue( key, seen )] = copyValue( item, seen ) end
	return out
end

local function setBlockEntityAt( bx, by, bz, record )
	local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
	local chunk = MC.GetChunk( cx, cy, cz )
	if record then
		chunk = chunk or MC.EnsureChunk( cx, cy, cz )
		chunk.blockEntities = chunk.blockEntities or {}
		chunk.blockEntities[localIndex] = copyValue( record )
	elseif chunk and chunk.blockEntities then
		chunk.blockEntities[localIndex] = nil
		if next( chunk.blockEntities ) == nil then chunk.blockEntities = nil end
	end
end

local function setOpaqueBlockEntityAt( bx, by, bz, record )
	local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
	local chunk = MC.GetChunk( cx, cy, cz )
	if record then
		chunk = chunk or MC.EnsureChunk( cx, cy, cz )
		chunk.opaqueBlockEntities = chunk.opaqueBlockEntities or {}
		chunk.opaqueBlockEntities[localIndex] = copyValue( record )
	elseif chunk and chunk.opaqueBlockEntities then
		chunk.opaqueBlockEntities[localIndex] = nil
		if next( chunk.opaqueBlockEntities ) == nil then chunk.opaqueBlockEntities = nil end
	end
end

function Import.CreateWorldSink( options )
	options = istable( options ) and options or {}
	local mode = options.mode == "append" and "append" or "replace"
	local sink = {
		mode = mode,
		initialBlockCount = SV.BlockCount or 0,
		oldCells = {},
		oldByKey = {},
		touched = {},
		written = {},
		stage = mode == "replace" and Host.beginWorldLoadStage() or nil,
		committed = false,
	}

	function sink:Rollback()
		if self.committed then return false end
		if self.mode == "replace" then
			Host.restoreWorldLoadStage( self.stage )
			return true
		end
		for index = #self.oldCells, 1, -1 do
			local old = self.oldCells[index]
			MC.SetBlockStateRaw( old.bx, old.by, old.bz, old.stateId )
			setBlockEntityAt( old.bx, old.by, old.bz, old.blockEntity )
			setOpaqueBlockEntityAt( old.bx, old.by, old.bz, old.opaqueBlockEntity )
		end
		SV.BlockCount = self.initialBlockCount
		for key in pairs( self.touched ) do
			local chunk = MC.GetChunkByKey( key )
			if chunk then MC.FinalizeChunkStateStorage( chunk ) end
		end
		return true
	end

	function sink:WritePlan( plan )
		local function captureOld( bx, by, bz )
			if self.mode ~= "append" then return end
			local key = MC.CellKey( bx, by, bz )
			if self.oldByKey[key] then return end
			self.oldByKey[key] = true
			local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
			local oldChunk = MC.GetChunk( cx, cy, cz )
			self.oldCells[#self.oldCells + 1] = {
				bx = bx, by = by, bz = bz,
				stateId = MC.GetBlockState( bx, by, bz ),
				blockEntity = MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil,
				opaqueBlockEntity = oldChunk and oldChunk.opaqueBlockEntities
					and copyValue( oldChunk.opaqueBlockEntities[localIndex] ) or nil,
			}
		end
		for _, sourceChunk in ipairs( plan.chunks ) do
			local chunk = MC.GetChunk( sourceChunk.cx, sourceChunk.cy, sourceChunk.cz )
			if #sourceChunk.cells > 0 or #sourceChunk.opaqueBlockEntities > 0 then
				chunk = chunk or MC.EnsureChunk( sourceChunk.cx, sourceChunk.cy, sourceChunk.cz )
			end
			for _, cell in ipairs( sourceChunk.cells ) do
				local lx, ly, lz = MC.DecodeLocal( cell.localIndex )
				local bx = sourceChunk.cx * MC.CS + lx
				local by = sourceChunk.cy * MC.CS + ly
				local bz = sourceChunk.cz * MC.CH + lz
				captureOld( bx, by, bz )
				local changed, oldStateId = MC.SetChunkLocalStateRaw( chunk, cell.localIndex, cell.stateId )
				if changed == nil then self:Rollback() return false, oldStateId or "import_state_write_failed" end
				if changed then
					if oldStateId == 0 then SV.BlockCount = ( SV.BlockCount or 0 ) + 1 end
					self.written[#self.written + 1] = { bx = bx, by = by, bz = bz, stateId = cell.stateId }
				end
			end
			for _, record in ipairs( sourceChunk.opaqueBlockEntities or {} ) do
				local lx, ly, lz = MC.DecodeLocal( record.localIndex )
				local bx = sourceChunk.cx * MC.CS + lx
				local by = sourceChunk.cy * MC.CS + ly
				local bz = sourceChunk.cz * MC.CH + lz
				captureOld( bx, by, bz )
				if MC.GetBlockState( bx, by, bz ) == 0 then
					self:Rollback()
					return false, "opaque_block_entity_without_state"
				end
				if MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) then
					self:Rollback()
					return false, "opaque_block_entity_conflicts_active"
				end
				setOpaqueBlockEntityAt( bx, by, bz, record )
			end
			if chunk then self.touched[chunk.key] = true end
		end
		for key in pairs( self.touched ) do
			local chunk = MC.GetChunkByKey( key )
			if chunk then MC.FinalizeChunkStateStorage( chunk ) end
		end
		return true
	end

	function sink:Commit()
		if self.committed then return false, "import_already_committed" end
		if self.mode == "replace" then
			Host.commitWorldLoadStage( self.stage )
		else
			for key in pairs( self.touched ) do
				local chunk = MC.GetChunkByKey( key )
				if chunk and chunk.count and chunk.count > 0 then
					SV.EnsureChunkEnt( chunk )
					SV.MarkPhysDirtyBulk( key )
				end
			end
			if SV.ChunkStore and SV.ChunkStore.RecordEdit then
				for _, cell in ipairs( self.written ) do
					local id, orient = MC.LegacyFromState( cell.stateId )
					SV.ChunkStore.RecordEdit( cell.bx, cell.by, cell.bz, id or 0, orient or 0, cell.stateId )
				end
			end
		end
		self.committed = true
		SV.Dirty = true
		if SV.FlushLightingCaches then SV.FlushLightingCaches() end
		if SV.AdvanceWorldGeneration then SV.AdvanceWorldGeneration( true ) end
		Host.resyncAllClients()
		return true
	end

	return sink
end
