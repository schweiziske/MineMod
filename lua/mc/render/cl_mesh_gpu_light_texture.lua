-- Experimental GPU-side chunk light texture support.
MC = MC or {}

local LIGHT_TEX_W = 128
local LIGHT_TEX_H = 64
local LIGHT_TEX_CELLS = LIGHT_TEX_W * LIGHT_TEX_H

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

local function cellPixel( li )
	li = math.floor( tonumber( li ) or 0 )
	if li < 0 then li = 0 elseif li >= LIGHT_TEX_CELLS then li = LIGHT_TEX_CELLS - 1 end
	return li % LIGHT_TEX_W, math.floor( li / LIGHT_TEX_W )
end

local function brightnessByte( bx, by, bz )
	local brightness = 1
	if MC.SampleLighting then
		brightness = MC.SampleLighting( bx, by, bz )
	end
	brightness = math.Clamp( tonumber( brightness ) or 1, 0, 1 )
	return math.floor( brightness * 255 + 0.5 )
end

local function chunkCellCoords( chunk, li )
	local lx, ly, lz = MC.DecodeLocal( li )
	return chunk.cx * MC.CS + lx, chunk.cy * MC.CS + ly, chunk.cz * MC.CH + lz
end

local function drawLightCell( chunk, li )
	local bx, by, bz = chunkCellCoords( chunk, li )
	local b = brightnessByte( bx, by, bz )
	local px, py = cellPixel( li )
	surface.SetDrawColor( b, b, b, 255 )
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
	return "mc_gpu_chunk_light_" .. tostring( key ):gsub( "%W", "_" )
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
	local key = MC.ChunkKey( cx, cy, cz )
	if not ( MC.World and MC.World[key] ) then return false end
	local dirty = MC.GpuChunkLightDirtyCells[key]
	if dirty ~= true then
		if not dirty then
			dirty = {}
			MC.GpuChunkLightDirtyCells[key] = dirty
		end
		dirty[li] = true
	end
	MC.GpuChunkLightDirtyChunks[key] = true
	return true, key, li
end

function MC.MarkGpuChunkLightTextureDirtyForChangedCells( changed )
	local count = changed and changed.count or 0
	local xs, ys, zs = changed and changed.x or {}, changed and changed.y or {}, changed and changed.z or {}
	local dirtyChunks = 0
	local seen = {}
	for i = 1, count do
		local ok, key = MC.MarkGpuChunkLightTextureDirtyCell( xs[i], ys[i], zs[i] )
		if ok and not seen[key] then
			seen[key] = true
			dirtyChunks = dirtyChunks + 1
		end
	end
	return dirtyChunks
end

local function refreshWholeChunk( chunk )
	for li = 0, ( MC.CS * MC.CS * MC.CH ) - 1 do
		drawLightCell( chunk, li )
	end
end

local function refreshDirtyCells( chunk, dirty )
	if dirty == true then
		refreshWholeChunk( chunk )
		return
	end
	for li in pairs( dirty or {} ) do
		drawLightCell( chunk, li )
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
