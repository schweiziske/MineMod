-- Experimental GPU-side chunk light texture support.
MC = MC or {}

local LIGHT_TEX_W = 128
local LIGHT_TEX_H = 128
local LIGHT_TEX_PAD = 1
local LIGHT_GRID_XY = 16 + LIGHT_TEX_PAD * 2
local LIGHT_GRID_Z = 32 + LIGHT_TEX_PAD * 2
local LIGHT_GRID_XY2 = LIGHT_GRID_XY * LIGHT_GRID_XY
local LIGHT_GRID_CELLS = LIGHT_GRID_XY2 * LIGHT_GRID_Z

MC.GpuChunkLightTextures = MC.GpuChunkLightTextures or {}
MC.GpuChunkLightDirtyCells = MC.GpuChunkLightDirtyCells or {}
MC.GpuChunkLightDirtyChunks = MC.GpuChunkLightDirtyChunks or {}

local fallbackTexture
local fallbackReady = false

local function gpuLightTextureEnabled()
	local cv = MC.MeshGpuLightTexture
	return cv and cv.GetBool and cv:GetBool() == true
end

function MC.UsingGpuLightTexture()
	return gpuLightTextureEnabled()
		and MC.MeshGpuShader
		and MC.MeshGpuShader.GetBool
		and MC.MeshGpuShader:GetBool() == true
		and MC.MaterialGpuLightTexture
		and not MC.MaterialGpuLightTexture:IsError()
end

local function packedPaddedCell( lx, ly, lz )
	lx = math.floor( tonumber( lx ) or 0 )
	ly = math.floor( tonumber( ly ) or 0 )
	lz = math.floor( tonumber( lz ) or 0 )
	if lx < 0 or lx >= LIGHT_GRID_XY or ly < 0 or ly >= LIGHT_GRID_XY or lz < 0 or lz >= LIGHT_GRID_Z then return nil end
	return lx + ly * LIGHT_GRID_XY + lz * LIGHT_GRID_XY2
end

local function unpackPaddedCell( packed )
	packed = math.floor( tonumber( packed ) or 0 )
	if packed < 0 then packed = 0 elseif packed >= LIGHT_GRID_CELLS then packed = LIGHT_GRID_CELLS - 1 end
	local lz = math.floor( packed / LIGHT_GRID_XY2 )
	local rem = packed - lz * LIGHT_GRID_XY2
	local ly = math.floor( rem / LIGHT_GRID_XY )
	local lx = rem - ly * LIGHT_GRID_XY
	return lx, ly, lz
end

local function cellPixel( packed )
	packed = math.floor( tonumber( packed ) or 0 )
	if packed < 0 then packed = 0 elseif packed >= LIGHT_GRID_CELLS then packed = LIGHT_GRID_CELLS - 1 end
	return packed % LIGHT_TEX_W, math.floor( packed / LIGHT_TEX_W )
end

local function lightByteFromUnit( value )
	return math.floor( math.Clamp( tonumber( value ) or 0, 0, 1 ) * 255 + 0.5 )
end

local function lightUnitFromLevel( level )
	return math.Clamp( ( tonumber( level ) or 0 ) / 15, 0, 1 )
end

local function cellSelfEmission( bx, by, bz )
	if not ( MC.GetBlock and MC.BlockLightEmission ) then return 0 end
	local id = MC.GetBlock( bx, by, bz )
	if not id or id == 0 then return 0 end
	return MC.BlockLightEmission( id ) or 0
end

local function lightTextureBytes( bx, by, bz )
	local brightness, level, block, sky = 1, 15, 15, 15
	if MC.SampleLighting then
		brightness, level, block, sky = MC.SampleLighting( bx, by, bz, cellSelfEmission( bx, by, bz ) )
	end
	level = tonumber( level ) or 15
	block = tonumber( block ) or level
	sky = tonumber( sky ) or level
	return lightByteFromUnit( brightness ), lightByteFromUnit( lightUnitFromLevel( block ) ), lightByteFromUnit( lightUnitFromLevel( sky ) )
end

local function paddedCellWorldCoords( chunk, lx, ly, lz )
	return chunk.cx * MC.CS + lx - LIGHT_TEX_PAD,
		chunk.cy * MC.CS + ly - LIGHT_TEX_PAD,
		chunk.cz * MC.CH + lz - LIGHT_TEX_PAD
end

local function drawLightCell( chunk, lx, ly, lz )
	local bx, by, bz = paddedCellWorldCoords( chunk, lx, ly, lz )
	local combined, block, sky = lightTextureBytes( bx, by, bz )
	local packed = packedPaddedCell( lx, ly, lz )
	if not packed then return end
	local px, py = cellPixel( packed )
	surface.SetDrawColor( combined, block, sky, 255 )
	surface.DrawRect( px, py, 1, 1 )
end

local function ensureFallbackTexture()
	if fallbackTexture and fallbackReady then return fallbackTexture end
	if not ( GetRenderTarget and render and surface and cam ) then return nil end
	fallbackTexture = fallbackTexture or GetRenderTarget( "mc_gpu_chunk_light_fallback", 2, 2 )
	if not fallbackTexture then return nil end
	render.PushRenderTarget( fallbackTexture, 0, 0, 2, 2 )
		render.Clear( 255, 255, 255, 255, true, true )
		cam.Start2D()
			surface.SetDrawColor( 255, 255, 255, 255 )
			surface.DrawRect( 0, 0, 2, 2 )
		cam.End2D()
	render.PopRenderTarget()
	fallbackReady = true
	return fallbackTexture
end

local function textureNameForKey( key )
	return "mc_gpu_chunk_light_smooth_halo1_" .. tostring( key ):gsub( "%W", "_" )
end

local function ensureChunkLightRecord( key )
	local rec = MC.GpuChunkLightTextures[key]
	if rec then return rec end
	if not GetRenderTarget then return nil end
	rec = {
		texture = GetRenderTarget( textureNameForKey( key ), LIGHT_TEX_W, LIGHT_TEX_H ),
		ready = false,
	}
	MC.GpuChunkLightTextures[key] = rec
	return rec
end

local function markWholeChunkDirty( key )
	if not key then return end
	MC.GpuChunkLightDirtyCells[key] = true
	MC.GpuChunkLightDirtyChunks[key] = true
end

function MC.MarkGpuChunkLightTextureDirty( key )
	markWholeChunkDirty( key )
end

function MC.MarkGpuChunkLightTextureDirtyCell( bx, by, bz )
	if not ( MC.CellToChunk and MC.ChunkKey ) then return false end
	local cx, cy, cz, li = MC.CellToChunk( bx, by, bz )
	if not MC.LocalIndexInRange or not MC.LocalIndexInRange( li ) then return false end
	local marked = 0
	local firstKey
	for dcx = -1, 1 do
		for dcy = -1, 1 do
			for dcz = -1, 1 do
				local key = MC.ChunkKey( cx + dcx, cy + dcy, cz + dcz )
				local chunk = MC.World and MC.World[key] or nil
				if chunk then
					local lx = bx - chunk.cx * MC.CS + LIGHT_TEX_PAD
					local ly = by - chunk.cy * MC.CS + LIGHT_TEX_PAD
					local lz = bz - chunk.cz * MC.CH + LIGHT_TEX_PAD
					local packed = packedPaddedCell( lx, ly, lz )
					if packed then
						local dirty = MC.GpuChunkLightDirtyCells[key]
						if dirty ~= true then
							if not dirty then
								dirty = {}
								MC.GpuChunkLightDirtyCells[key] = dirty
							end
							dirty[packed] = true
						end
						MC.GpuChunkLightDirtyChunks[key] = true
						firstKey = firstKey or key
						marked = marked + 1
					end
				end
			end
		end
	end
	return marked > 0, firstKey, marked
end

function MC.MarkGpuChunkLightTextureDirtyForChangedCells( changed )
	local count = changed and changed.count or 0
	local xs, ys, zs = changed and changed.x or {}, changed and changed.y or {}, changed and changed.z or {}
	local dirtyChunks = 0
	local seen = {}
	for i = 1, count do
		MC.MarkGpuChunkLightTextureDirtyCell( xs[i], ys[i], zs[i] )
	end
	for key in pairs( MC.GpuChunkLightDirtyChunks or {} ) do
		if not seen[key] then
			local chunk = MC.World and MC.World[key] or nil
			if chunk then
				seen[key] = true
				dirtyChunks = dirtyChunks + 1
			end
		end
	end
	return dirtyChunks
end

local function refreshWholeChunk( chunk )
	for lz = 0, LIGHT_GRID_Z - 1 do
		for ly = 0, LIGHT_GRID_XY - 1 do
			for lx = 0, LIGHT_GRID_XY - 1 do
				drawLightCell( chunk, lx, ly, lz )
			end
		end
	end
end

local function refreshDirtyCells( chunk, dirty )
	if dirty == true then
		refreshWholeChunk( chunk )
		return
	end
	for packed in pairs( dirty or {} ) do
		local lx, ly, lz = unpackPaddedCell( packed )
		drawLightCell( chunk, lx, ly, lz )
	end
end

function MC.RefreshGpuChunkLightTexture( key )
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or nil
	if not chunk then return ensureFallbackTexture() end
	local rec = ensureChunkLightRecord( key )
	if not rec or not rec.texture or not ( render and surface and cam ) then return ensureFallbackTexture() end
	local dirty = MC.GpuChunkLightDirtyCells[key]
	if rec.ready and not dirty then return rec.texture end

	render.PushRenderTarget( rec.texture, 0, 0, LIGHT_TEX_W, LIGHT_TEX_H )
		if not rec.ready then render.Clear( 255, 255, 255, 255, true, true ) end
		cam.Start2D()
			if not rec.ready then
				refreshWholeChunk( chunk )
			else
				refreshDirtyCells( chunk, dirty )
			end
		cam.End2D()
	render.PopRenderTarget()

	rec.ready = true
	MC.GpuChunkLightDirtyCells[key] = nil
	MC.GpuChunkLightDirtyChunks[key] = nil
	return rec.texture
end

function MC.BindGpuChunkLightTexture( key, material )
	if not material or not material.SetTexture then return false end
	local tex = MC.RefreshGpuChunkLightTexture( key ) or ensureFallbackTexture()
	if not tex then return false end
	material:SetTexture( "$texture1", tex )
	return true
end

function MC.ClearGpuChunkLightTexture( key )
	MC.GpuChunkLightTextures[key] = nil
	MC.GpuChunkLightDirtyCells[key] = nil
	MC.GpuChunkLightDirtyChunks[key] = nil
end

function MC.ClearAllGpuChunkLightTextures()
	MC.GpuChunkLightTextures = {}
	MC.GpuChunkLightDirtyCells = {}
	MC.GpuChunkLightDirtyChunks = {}
	fallbackTexture = nil
	fallbackReady = false
end

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_gpu_light_texture", function()
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "gpu_light_texture_toggle" ) end
	end, "mc_mesh_gpu_light_texture_rebuild" )
end
