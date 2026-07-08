-- GPU chunk light data, stored in ONE shared atlas texture.
--
-- Layout (must match the chunk pixel shaders):
--   - Atlas RT "mc_gpu_chunk_light_atlas1": 4096x4096 RGBA8888, point-sampled,
--     divided into 32x32 tiles of 128x128 texels. Fixed 64MB VRAM ceiling,
--     replacing the old unbounded per-chunk 128x128 RTs (which the engine
--     never released).
--   - Tile 0 is always white: the fallback every not-yet-baked chunk lights
--     from (fullbright, same look as the old white fallback texture).
--   - Tiles 1..2 host the indirection table: residue index
--     i = (cx mod 32) + (cy mod 32)*32 + (cz mod 8)*1024 owns FOUR adjacent
--     texels at (128 + (i*4 mod 256) .. +3, i*4 / 256). The owning tile index
--     (col + row*32) is stored as 12 THRESHOLD BITS — every channel is 0 or
--     255, decoded in the shader with step(0.5). Raw byte indices are NOT
--     usable here: the RT write/read path was measured to shift bytes by up
--     to +-5 (surface draws) and must also survive any sampler-side gamma.
--     All-black texels decode to tile 0 = white. The shader derives the
--     chunk coordinate from vWorldPos - vLocalPos, so NO per-chunk material
--     state exists at draw time — the whole point of the atlas.
--   - Within a tile, cells pack exactly like the old per-chunk texture:
--     18x18x34 halo grid, linear index, 128 texels per row.
--
-- Slots are assigned to chunk keys on first visible touch and evicted
-- least-recently-visible when the atlas fills. Assignment never touches mesh
-- data — vertex format and contents are identical to the per-chunk-RT era,
-- so enabling/evicting/reassigning slots never rebuilds a mesh.
MC = MC or {}

local LIGHT_TEX_PAD = 1
local LIGHT_GRID_XY = 16 + LIGHT_TEX_PAD * 2
local LIGHT_GRID_Z = 32 + LIGHT_TEX_PAD * 2
local LIGHT_GRID_XY2 = LIGHT_GRID_XY * LIGHT_GRID_XY
local LIGHT_GRID_CELLS = LIGHT_GRID_XY2 * LIGHT_GRID_Z

local ATLAS_NAME = "mc_gpu_chunk_light_atlas1"
local ATLAS_SIZE = 4096
local TILE = 128
local TILES_PER_ROW = ATLAS_SIZE / TILE -- 32
local TILE_COUNT = TILES_PER_ROW * TILES_PER_ROW -- 1024
local FIRST_SLOT = 3 -- tile 0 = white fallback, tiles 1..2 = indirection table
local WRAP_X, WRAP_Y, WRAP_Z = 32, 32, 8
local INDIR_PIXEL_X = TILE -- indirection region: x 128..383 (tiles 1..2), y 0..127
local INDIR_COLS = 256 -- texels per indirection row; 4 texels per residue
local INDIR_ROWS = ( WRAP_X * WRAP_Y * WRAP_Z ) * 4 / INDIR_COLS -- 128 rows

MC.GpuChunkLightDirtyCells = MC.GpuChunkLightDirtyCells or {}
MC.GpuChunkLightDirtyChunks = MC.GpuChunkLightDirtyChunks or {}

-- slot bookkeeping (all rebuilt from scratch on Lua reload: the RT content
-- survives but the indirection region is repainted black by init, so stale
-- tiles can never be referenced)
local slotByKey = {}
local keyBySlot = {}
local slotTouch = {}
local slotReady = {}
local residueBySlot = {}
local residueOwner = {}
local freeSlots = {}
local freeSlotCount = 0
for slot = TILE_COUNT - 1, FIRST_SLOT, -1 do
	freeSlotCount = freeSlotCount + 1
	freeSlots[freeSlotCount] = slot
end

local pendingBake = {}
local pendingIndir = {} -- residueIndex -> tile index (0 = point at white)
local statsEvictions = 0
local statsBakes = 0
local statsResidueConflicts = 0

local atlasRT
local atlasInitialized = false
local materialsBound = false

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
	return packed % TILE, math.floor( packed / TILE )
end

local function tilePixelOrigin( slot )
	local row = math.floor( slot / TILES_PER_ROW )
	local col = slot - row * TILES_PER_ROW
	return col * TILE, row * TILE
end

local function residueIndexForChunk( chunk )
	local rx = chunk.cx % WRAP_X
	local ry = chunk.cy % WRAP_Y
	local rz = chunk.cz % WRAP_Z
	return rx + ry * WRAP_X + rz * WRAP_X * WRAP_Y
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
local function lightUnitFromLevel( p, level )
	local unit = math.Clamp( ( tonumber( level ) or 0 ) / 15, 0, 1 )
	local gamma = p.gamma
	if gamma ~= 1 then
		unit = unit ^ ( 1 / gamma )
	end
	return math.Clamp( unit * p.brightness, 0, 1 )
end

local cachedSkyBrightnessTime
local cachedSkyBrightnessMoon
local cachedSkyBrightnessEnabled
local cachedSkyBrightness = 1

local function currentDayCycleSkyBrightness()
	local now = CurTime and CurTime() or 0
	local moon = convarNumber( MC.DayCycleMoonLight, 2, 0, 15 )
	local enabled = MC.DayCycleEnabled and MC.DayCycleEnabled() == true
	if cachedSkyBrightnessTime ~= now
		or cachedSkyBrightnessMoon ~= moon
		or cachedSkyBrightnessEnabled ~= enabled then
		cachedSkyBrightnessTime = now
		cachedSkyBrightnessMoon = moon
		cachedSkyBrightnessEnabled = enabled
		cachedSkyBrightness = MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
	end
	return cachedSkyBrightness
end

local function cellSelfEmission( bx, by, bz )
	if not ( MC.GetBlock and MC.BlockLightEmission ) then return 0 end
	local id = MC.GetBlock( bx, by, bz )
	if not id or id == 0 then return 0 end
	return MC.BlockLightEmission( id ) or 0
end

-- Per-bake parameter snapshot: mode flag, curves and day-cycle factors are
-- identical for every cell in one bake, so read them once per bake instead
-- of once per texel (a whole-chunk bake touches ~11k cells).
local function bakeLightParams()
	local p = { lightmapMode = MC.GlobalLightmapActive and MC.GlobalLightmapActive() or false }
	if not p.lightmapMode then
		p.gamma = convarNumber( MC.MeshGpuLightGamma, 1, 0.25, 4 )
		p.brightness = convarNumber( MC.MeshGpuLightBrightness, 1, 0.1, 4 )
		p.sunMul = convarNumber( MC.MeshGpuSunBrightness, 1, 0, 4 )
		p.skyBrightness = currentDayCycleSkyBrightness()
		p.night = MC.DayCycleNightAmount and MC.DayCycleNightAmount() or 0
		p.nightTint = convarNumber( MC.DayCycleNightTint, 0.85, 0, 1 )
	end
	return p
end

local function lightTextureBytes( bx, by, bz, p )
	local brightness, level, block, sky = 1, 15, 15, 15
	if MC.SampleLighting then
		brightness, level, block, sky = MC.SampleLighting( bx, by, bz, cellSelfEmission( bx, by, bz ) )
	end
	level = tonumber( level ) or 15
	block = tonumber( block ) or level
	-- Sky now carries the flooded voxel sky light (cl_sky_flood): 15 above
	-- open sky, -1 per lateral block into interiors, 0 fully enclosed. It is
	-- an AMBIENT term only — the shader's shadow map is the one directional
	-- shadow; no column/pillar exposure override here anymore.
	sky = tonumber( sky ) or level

	if p.lightmapMode then
		-- Global lightmap mode: chunk textures store RAW linear levels; the
		-- 16x16 lightmap applies the brightness curve, sun brightness and all
		-- time-of-day color/darkening. Chunk bytes are time-independent, so
		-- day/night never re-bakes chunks, and the r-channel night tint stays
		-- zero (night hue comes from the lightmap sky axis).
		local blockUnit = math.Clamp( block / 15, 0, 1 )
		local skyUnit = math.Clamp( sky / 15, 0, 1 )
		return 0, lightByteFromUnit( blockUnit ), lightByteFromUnit( skyUnit )
	end

	-- Fallback (grayscale) mode: curves and day factor bake into the bytes.
	local blockUnit = lightUnitFromLevel( p, block )
	-- Sky stays LINEAR: the gamma/brightness curve shapes torch falloff and
	-- would otherwise lift the level-4 moonlight into a bright night.
	local skyUnit = math.Clamp( ( math.Clamp( sky, 0, 15 ) / 15 ) * p.skyBrightness * p.sunMul, 0, 1 )
	-- The r channel is repurposed as the night cool-tint weight (nothing read
	-- the old combined-brightness value): global night amount times how much
	-- this cell is sky-dominated. Torch pools bake ~0 and stay warm; caves
	-- have no sky light and stay neutral.
	local tintWeight = 0
	if p.night > 0 and skyUnit > 0.001 then
		local dom = math.Clamp( ( skyUnit - blockUnit ) / skyUnit, 0, 1 )
		tintWeight = math.Clamp( p.night * dom * p.nightTint, 0, 1 )
	end
	return lightByteFromUnit( tintWeight ), lightByteFromUnit( blockUnit ), lightByteFromUnit( skyUnit )
end

local function paddedCellWorldCoords( chunk, lx, ly, lz )
	return chunk.cx * MC.CS + lx - LIGHT_TEX_PAD,
		chunk.cy * MC.CS + ly - LIGHT_TEX_PAD,
		chunk.cz * MC.CH + lz - LIGHT_TEX_PAD
end

local function drawLightCell( chunk, lx, ly, lz, tileX, tileY, p )
	local bx, by, bz = paddedCellWorldCoords( chunk, lx, ly, lz )
	local combined, block, sky = lightTextureBytes( bx, by, bz, p )
	local packed = packedPaddedCell( lx, ly, lz )
	if not packed then return end
	local px, py = cellPixel( packed )
	surface.SetDrawColor( combined, block, sky, 255 )
	surface.DrawRect( tileX + px, tileY + py, 1, 1 )
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

-- Atlas creation + one-time init: whole RT white (tile 0 and every unbaked
-- tile default to fullbright), indirection region black (every residue points
-- at tile 0). Called from PreRender only — never mid-draw-pass.
local function ensureAtlas()
	if atlasRT and atlasInitialized then return atlasRT end
	if not ( GetRenderTargetEx and render and surface and cam ) then return nil end
	atlasRT = atlasRT or GetRenderTargetEx(
		ATLAS_NAME,
		ATLAS_SIZE,
		ATLAS_SIZE,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_NONE,
		bit.bor( 1, 4, 8, 256, 512 ), -- POINTSAMPLE|CLAMPS|CLAMPT|NOMIP|NOLOD
		0,
		IMAGE_FORMAT_RGBA8888
	)
	if not atlasRT then return nil end
	if not atlasInitialized then
		render.PushRenderTarget( atlasRT )
			render.Clear( 255, 255, 255, 255, true, true )
		render.PopRenderTarget()
		-- Viewport-scoped hardware clear: indirection texels are decoded as
		-- threshold bits in the shader; render.Clear writes raw bytes with no
		-- material-system involvement.
		render.PushRenderTarget( atlasRT, INDIR_PIXEL_X, 0, INDIR_COLS, INDIR_ROWS )
			render.Clear( 0, 0, 0, 255 )
		render.PopRenderTarget()
		atlasInitialized = true
	end
	return atlasRT
end

local function bindAtlasToMaterials()
	local target = atlasRT or ensureFallbackTexture()
	if not target then return end
	local function bind( material )
		if material and material.SetTexture and not material:IsError() then
			material:SetTexture( "$texture1", target )
		end
	end
	bind( MC.MaterialGpuLightTexture )
	bind( MC.MaterialGpuLightTextureFancy )
	bind( MC.MaterialGpuLightTextureHeight )
	bind( MC.MaterialGpuLightTextureFast )
	bind( MC.MaterialGpuLightTextureTranslucent )
	materialsBound = true
end

------------------------------------------------------------------ slot manager

local function queueIndirWrite( residueIndex, slot )
	pendingIndir[residueIndex] = slot or 0
end

local function freeSlotForKey( key, skipIndirReset )
	local slot = slotByKey[key]
	if not slot then return end
	slotByKey[key] = nil
	keyBySlot[slot] = nil
	slotTouch[slot] = nil
	slotReady[slot] = nil
	local ri = residueBySlot[slot]
	residueBySlot[slot] = nil
	if ri and residueOwner[ri] == key then
		residueOwner[ri] = nil
		if not skipIndirReset then queueIndirWrite( ri, 0 ) end
	end
	freeSlotCount = freeSlotCount + 1
	freeSlots[freeSlotCount] = slot
end

local function evictOldestSlot()
	local oldestSlot, oldestTime
	for slot, _ in pairs( keyBySlot ) do
		local t = slotTouch[slot] or 0
		if not oldestTime or t < oldestTime then
			oldestTime = t
			oldestSlot = slot
		end
	end
	if not oldestSlot then return false end
	statsEvictions = statsEvictions + 1
	freeSlotForKey( keyBySlot[oldestSlot] )
	return true
end

local function assignSlot( key, chunk )
	local slot = slotByKey[key]
	if slot then return slot end

	local ri = residueIndexForChunk( chunk )
	-- Residue collision (two loaded chunks >= 32 chunks apart in x/y AND
	-- aligned mod 8 in z sharing one indirection texel). If the current owner
	-- was drawn recently, keep it and leave the newcomer slotless (it lights
	-- white) instead of letting the two steal the texel from each other and
	-- whole-rebake every frame. A stale owner is displaced normally.
	local oldOwner = residueOwner[ri]
	if oldOwner and oldOwner ~= key then
		statsResidueConflicts = statsResidueConflicts + 1
		local oldSlot = slotByKey[oldOwner]
		if oldSlot and ( RealTime() - ( slotTouch[oldSlot] or 0 ) ) < 1 then
			return nil
		end
		freeSlotForKey( oldOwner, true )
	end

	if freeSlotCount == 0 and not evictOldestSlot() then return nil end
	slot = freeSlots[freeSlotCount]
	freeSlots[freeSlotCount] = nil
	freeSlotCount = freeSlotCount - 1

	residueOwner[ri] = key
	residueBySlot[slot] = ri
	slotByKey[key] = slot
	keyBySlot[slot] = key
	slotTouch[slot] = RealTime()
	slotReady[slot] = nil
	return slot
end

------------------------------------------------------------------ dirty marking

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

------------------------------------------------------------------ baking

-- Whole-chunk bake with run merging: light fields are dominated by long
-- constant spans (uniform open sky, fully dark interiors, zero block light),
-- so consecutive same-color texels in a tile row collapse into ONE DrawRect.
-- This is the hitch path when chunks stream into view (18*18*34 ≈ 11k cells
-- per tile); merging typically cuts the surface call count by an order of
-- magnitude. Iteration order lz→ly→lx makes the packed cell index (and the
-- tile pixel) advance by exactly one per cell, so px/py track cellPixel().
local function refreshWholeChunk( chunk, tileX, tileY )
	local p = bakeLightParams()
	local baseX = chunk.cx * MC.CS - LIGHT_TEX_PAD
	local baseY = chunk.cy * MC.CS - LIGHT_TEX_PAD
	local baseZ = chunk.cz * MC.CH - LIGHT_TEX_PAD
	local setColor = surface.SetDrawColor
	local drawRect = surface.DrawRect
	local runR, runG, runB, runStart, runY, runLen
	local px, py = 0, 0
	for lz = 0, LIGHT_GRID_Z - 1 do
		local bz = baseZ + lz
		for ly = 0, LIGHT_GRID_XY - 1 do
			local by = baseY + ly
			for lx = 0, LIGHT_GRID_XY - 1 do
				local r, g, b = lightTextureBytes( baseX + lx, by, bz, p )
				-- px == 0 starts a new tile row: a run never spans rows.
				if runLen and px > 0 and r == runR and g == runG and b == runB then
					runLen = runLen + 1
				else
					if runLen then
						setColor( runR, runG, runB, 255 )
						drawRect( tileX + runStart, tileY + runY, runLen, 1 )
					end
					runR, runG, runB = r, g, b
					runStart, runY, runLen = px, py, 1
				end
				px = px + 1
				if px >= TILE then
					px = 0
					py = py + 1
				end
			end
		end
	end
	if runLen then
		setColor( runR, runG, runB, 255 )
		drawRect( tileX + runStart, tileY + runY, runLen, 1 )
	end
end

local function refreshDirtyCells( chunk, dirty, tileX, tileY )
	if dirty == true then
		refreshWholeChunk( chunk, tileX, tileY )
		return
	end
	local p = bakeLightParams()
	for packed in pairs( dirty or {} ) do
		local lx, ly, lz = unpackPaddedCell( packed )
		drawLightCell( chunk, lx, ly, lz, tileX, tileY, p )
	end
end

function MC.RefreshGpuChunkLightTexture( key )
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or nil
	if not chunk then return nil end
	local atlas = ensureAtlas()
	if not ( atlas and render and surface and cam ) then return nil end
	local slot = assignSlot( key, chunk )
	if not slot then return atlas end
	local dirty = MC.GpuChunkLightDirtyCells[key]
	if slotReady[slot] and not dirty then return atlas end

	local tileX, tileY = tilePixelOrigin( slot )
	local wholeBake = not slotReady[slot]
	render.PushRenderTarget( atlas )
		cam.Start2D()
			if wholeBake then
				refreshWholeChunk( chunk, tileX, tileY )
			else
				refreshDirtyCells( chunk, dirty, tileX, tileY )
			end
		cam.End2D()
	render.PopRenderTarget()

	statsBakes = statsBakes + 1
	if wholeBake then
		slotReady[slot] = true
		-- Point the indirection at this tile only after its content exists,
		-- so a chunk never lights from another chunk's stale texels.
		queueIndirWrite( residueBySlot[slot], slot )
	end
	MC.GpuChunkLightDirtyCells[key] = nil
	MC.GpuChunkLightDirtyChunks[key] = nil
	return atlas
end

------------------------------------------------------------------ draw path

-- Draw-path per-chunk work is now PURE LUA: refresh the slot's LRU stamp and
-- queue a budgeted PreRender bake when dirty or unassigned. The atlas itself
-- is bound to $texture1 once (bindAtlasToMaterials), so the per-chunk
-- SetTexture that used to dominate the frame is gone.
function MC.TouchGpuChunkLightTexture( key )
	local slot = slotByKey[key]
	if slot then
		slotTouch[slot] = RealTime()
		if MC.GpuChunkLightDirtyChunks[key] then pendingBake[key] = true end
		return true
	end
	pendingBake[key] = true
	return false
end

function MC.PeekGpuChunkLightTexture( key )
	local slot = slotByKey[key]
	if slot and slotReady[slot] then
		if MC.GpuChunkLightDirtyChunks[key] then pendingBake[key] = true end
		return atlasRT
	end
	pendingBake[key] = true
	return nil
end

-- Compatibility shim for external callers: the atlas needs no per-chunk
-- binding, so this only touches the slot.
function MC.BindGpuChunkLightTexture( key, material )
	MC.TouchGpuChunkLightTexture( key )
	return true
end

local function flushBudget()
	local cv = MC.MeshGpuLightFlushPerFrame
	local n = cv and cv.GetInt and cv:GetInt() or 8
	n = tonumber( n ) or 8
	if n <= 0 then return math.huge end
	return n
end

local function flushIndirWrites()
	if not next( pendingIndir ) then return end
	local atlas = ensureAtlas()
	if not atlas then return end
	-- The tile index (0..1023) is written as 12 threshold bits: four adjacent
	-- texels, three channels each, every channel 0 or 255. Full-range values
	-- survive any gamma/dither on either side of the RT path — raw byte
	-- indices measurably do not. Written via viewport-scoped render.Clear
	-- (byte-exact hardware clear); writes are rare (slot assign/evict).
	for ri, slot in pairs( pendingIndir ) do
		pendingIndir[ri] = nil
		local base = ri * 4
		local py = math.floor( base / INDIR_COLS )
		local px = base - py * INDIR_COLS
		local v = slot
		for k = 0, 3 do
			local r = ( v % 2 ) * 255
			local g = ( math.floor( v / 2 ) % 2 ) * 255
			local b = ( math.floor( v / 4 ) % 2 ) * 255
			render.PushRenderTarget( atlas, INDIR_PIXEL_X + px + k, py, 1, 1 )
				render.Clear( r, g, b, 255 )
			render.PopRenderTarget()
			v = math.floor( v / 8 )
		end
	end
end

hook.Remove( "PreRender", "mc_gpu_light_texture_flush" )
hook.Add( "PreRender", "mc_gpu_light_texture_flush", function()
	-- All RT work lives here, never inside the chunk draw pass.
	if gpuLightTextureEnabled() then
		if ensureAtlas() and not materialsBound then bindAtlasToMaterials() end
	end
	if next( pendingBake ) then
		local budget = flushBudget()
		for key in pairs( pendingBake ) do
			pendingBake[key] = nil
			local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or nil
			if chunk then
				MC.RefreshGpuChunkLightTexture( key )
				budget = budget - 1
				if budget <= 0 then break end
			end
		end
	end
	flushIndirWrites()
end )

function MC.ClearGpuChunkLightTexture( key )
	freeSlotForKey( key )
	MC.GpuChunkLightDirtyCells[key] = nil
	MC.GpuChunkLightDirtyChunks[key] = nil
	pendingBake[key] = nil
end

function MC.ClearAllGpuChunkLightTextures()
	slotByKey = {}
	keyBySlot = {}
	slotTouch = {}
	slotReady = {}
	residueBySlot = {}
	residueOwner = {}
	freeSlots = {}
	freeSlotCount = 0
	for slot = TILE_COUNT - 1, FIRST_SLOT, -1 do
		freeSlotCount = freeSlotCount + 1
		freeSlots[freeSlotCount] = slot
	end
	pendingBake = {}
	pendingIndir = {}
	MC.GpuChunkLightDirtyCells = {}
	MC.GpuChunkLightDirtyChunks = {}
	-- Repaint the whole indirection region black next PreRender: every chunk
	-- falls back to white until its budgeted rebake, same behavior the old
	-- "drop every per-chunk RT" path had.
	atlasInitialized = false
end

function MC.GpuLightAtlasStats()
	local used = 0
	for _ in pairs( keyBySlot ) do used = used + 1 end
	return {
		slotsUsed = used,
		slotsFree = freeSlotCount,
		evictions = statsEvictions,
		bakes = statsBakes,
		residueConflicts = statsResidueConflicts,
	}
end

-- Probe/diagnostic access to the internal slot state. Not a stable API.
function MC.GpuLightAtlasDebug()
	return {
		atlas = atlasRT,
		slotByKey = slotByKey,
		keyBySlot = keyBySlot,
		slotReady = slotReady,
		residueBySlot = residueBySlot,
		residueOwner = residueOwner,
		pendingBake = pendingBake,
		pendingIndir = pendingIndir,
		TILE = TILE,
		TILES_PER_ROW = TILES_PER_ROW,
		INDIR_PIXEL_X = INDIR_PIXEL_X,
		INDIR_COLS = INDIR_COLS,
		INDIR_ROWS = INDIR_ROWS,
		WRAP_X = WRAP_X,
		WRAP_Y = WRAP_Y,
		WRAP_Z = WRAP_Z,
	}
end

-- Amortized full refresh: instead of dropping every slot at once (one giant
-- rebuild frame), mark a few chunks dirty per frame and let the visible-touch
-- queue spread the rebake cost. Used by the day/night level steps.
local pendingRefreshKeys = nil
local pendingRefreshIndex = 1

function MC.QueueAllGpuChunkLightTextureRefresh()
	local keys = {}
	for key in pairs( slotByKey ) do
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
		if slotByKey[key] then
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
