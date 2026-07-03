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

local function convarNumber( cv, fallback, minValue, maxValue )
	local value = cv and cv.GetFloat and cv:GetFloat() or fallback
	value = tonumber( value ) or fallback
	if value < minValue then value = minValue end
	if value > maxValue then value = maxValue end
	return value
end

-- User-tunable intensity curve for the light texture: gamma shapes the
-- falloff (gamma > 1 lifts mid levels, so torch edges reach visibly further),
-- brightness scales the result. Both feed the same channel the shadow pass
-- uses as its block-light floor, so brighter torch light also protects
-- shadowed areas more strongly — intended.
local function lightUnitFromLevel( level )
	local unit = math.Clamp( ( tonumber( level ) or 0 ) / 15, 0, 1 )
	local gamma = convarNumber( MC.MeshGpuLightGamma, 1, 0.25, 4 )
	if gamma ~= 1 then
		unit = unit ^ ( 1 / gamma )
	end
	local brightness = convarNumber( MC.MeshGpuLightBrightness, 1, 0.1, 4 )
	return math.Clamp( unit * brightness, 0, 1 )
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
	-- Column-based sky exposure (cl_sky_column) replaces the stored sky value
	-- when active.
	local skyOverridden = false
	if MC.SkyLightLevelAt then
		local skyLevel = MC.SkyLightLevelAt( bx, by, bz )
		if skyLevel then
			sky = skyLevel
			skyOverridden = true
		end
	end

	if MC.GlobalLightmapActive and MC.GlobalLightmapActive() then
		-- Global lightmap mode: chunk textures store RAW linear levels; the
		-- 16x16 lightmap applies the brightness curve, sun brightness and all
		-- time-of-day color/darkening. Chunk bytes are time-independent, so
		-- day/night never re-bakes chunks, and the r-channel night tint stays
		-- zero (night hue comes from the lightmap sky axis).
		local blockUnit = math.Clamp( block / 15, 0, 1 )
		local skyUnit
		local exposure = MC.SkyExposureUnitAt and MC.SkyExposureUnitAt( bx, by, bz ) or nil
		if exposure then
			skyUnit = exposure
		else
			skyUnit = math.Clamp( sky / 15, 0, 1 )
		end
		return 0, lightByteFromUnit( blockUnit ), lightByteFromUnit( skyUnit )
	end

	-- Fallback (grayscale) mode: curves and day factor bake into the bytes.
	local blockUnit = lightUnitFromLevel( block )
	local sunMul = convarNumber( MC.MeshGpuSunBrightness, 1, 0, 4 )
	-- Sky stays LINEAR: the gamma/brightness curve shapes torch falloff and
	-- would otherwise lift the level-4 moonlight into a bright night.
	local skyUnit
	if skyOverridden then
		skyUnit = math.Clamp( ( math.Clamp( sky, 0, 15 ) / 15 ) * sunMul, 0, 1 )
	else
		skyUnit = math.Clamp( lightUnitFromLevel( sky ) * sunMul, 0, 1 )
	end
	-- The r channel is repurposed as the night cool-tint weight (nothing read
	-- the old combined-brightness value): global night amount times how much
	-- this cell is sky-dominated. Torch pools bake ~0 and stay warm; caves
	-- have no sky light and stay neutral.
	local tintWeight = 0
	if skyOverridden and MC.DayCycleNightAmount then
		local night = MC.DayCycleNightAmount()
		if night > 0 and skyUnit > 0.001 then
			local dom = math.Clamp( ( skyUnit - blockUnit ) / skyUnit, 0, 1 )
			tintWeight = math.Clamp( night * dom * convarNumber( MC.DayCycleNightTint, 0.6, 0, 1 ), 0, 1 )
		end
	end
	return lightByteFromUnit( tintWeight ), lightByteFromUnit( blockUnit ), lightByteFromUnit( skyUnit )
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

-- Amortized full refresh: instead of dropping every cached texture at once
-- (one giant rebuild frame), mark a few chunks dirty per frame and let the
-- lazy bind-time refresh spread the cost. Used by the day/night level steps.
local pendingRefreshKeys = nil
local pendingRefreshIndex = 1

function MC.QueueAllGpuChunkLightTextureRefresh()
	local keys = {}
	for key in pairs( MC.GpuChunkLightTextures or {} ) do
		keys[#keys + 1] = key
	end
	pendingRefreshKeys = #keys > 0 and keys or nil
	pendingRefreshIndex = 1
end

hook.Remove( "Think", "mc_gpu_light_texture_refresh_queue" )
hook.Add( "Think", "mc_gpu_light_texture_refresh_queue", function()
	if not pendingRefreshKeys then return end
	local budget = convarNumber( MC.MeshGpuLightRefreshPerFrame, 2, 1, 32 )
	local keys = pendingRefreshKeys
	local n = #keys
	local i = pendingRefreshIndex
	local marked = 0
	while i <= n and marked < budget do
		local key = keys[i]
		i = i + 1
		if MC.GpuChunkLightTextures[key] then
			MC.GpuChunkLightDirtyChunks[key] = true
			MC.GpuChunkLightDirtyCells[key] = true
			marked = marked + 1
		end
	end
	pendingRefreshIndex = i
	if i > n then pendingRefreshKeys = nil end
end )

if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_gpu_light_texture", function()
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
		if MC.MarkAllMeshesDirty then MC.MarkAllMeshesDirty( "gpu_light_texture_toggle" ) end
	end, "mc_mesh_gpu_light_texture_rebuild" )
	local function refreshTimeOfDayLighting()
		if MC.GlobalLightmapActive and MC.GlobalLightmapActive() then
			if MC.RefreshGlobalLightmap then MC.RefreshGlobalLightmap() end
			return
		end
		if MC.QueueAllGpuChunkLightTextureRefresh then
			MC.QueueAllGpuChunkLightTextureRefresh()
		elseif MC.ClearAllGpuChunkLightTextures then
			MC.ClearAllGpuChunkLightTextures()
		end
	end
	-- Intensity curve changes: in global-lightmap mode the curves live in the
	-- 16x16 lightmap (regenerating it is free); in fallback mode they are
	-- baked into the chunk textures and need a full re-render.
	local function refreshLightCurves()
		if MC.GlobalLightmapActive and MC.GlobalLightmapActive() then
			if MC.RefreshGlobalLightmap then MC.RefreshGlobalLightmap() end
			return
		end
		if MC.ClearAllGpuChunkLightTextures then MC.ClearAllGpuChunkLightTextures() end
	end
	cvars.AddChangeCallback( "mc_mesh_gpu_light_brightness", refreshLightCurves, "mc_mesh_gpu_light_brightness_refresh" )
	cvars.AddChangeCallback( "mc_mesh_gpu_light_gamma", refreshLightCurves, "mc_mesh_gpu_light_gamma_refresh" )
	cvars.AddChangeCallback( "mc_mesh_gpu_sun_brightness", refreshTimeOfDayLighting, "mc_mesh_gpu_sun_brightness_refresh" )
	cvars.AddChangeCallback( "mc_daycycle_moon_light", refreshTimeOfDayLighting, "mc_daycycle_moon_light_refresh" )
	cvars.AddChangeCallback( "mc_daycycle_night_tint", refreshTimeOfDayLighting, "mc_daycycle_night_tint_refresh" )
end
