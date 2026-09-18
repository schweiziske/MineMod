-- Legacy packed GPU chunk-light atlas helpers with two interchangeable owners.
-- L2 keeps the animation notifications and global-lightmap refresh callbacks;
-- this module no longer starts an atlas or reacts to the retired texture toggle.
--
-- Native active: the DLL owns the procedural texture, stable slots and upload
-- barrier. Lua only asks for the slot encoded into diagnostics/fallback meshes.
-- Native inactive or absent: this file owns an equivalent 4096x4096 RT. There
-- is no LRU or indirection table. PrepareGpuChunkLightTexture() finishes the
-- complete tile before a new mesh is committed. Full-world invalidations keep
-- live slots and refresh their tiles under the shared Lua mesh frame budget.
MC = MC or {}

local ATLAS_NAME = "mc_gpu_chunk_light_atlas_lua_packed1"
local ATLAS_SIZE = 4096
local TILE_WIDTH = 324
local TILE_HEIGHT = 9
local TILES_PER_ROW = 12
local TILE_ROWS = 455
local SLOT_COUNT = TILES_PER_ROW * TILE_ROWS
local REAL_CAPACITY = SLOT_COUNT - 1
local GRID_XY = 18
local GRID_Z = 34
local FULLBRIGHT_PACKED = 255

MC.GpuChunkLightDirtyCells = MC.GpuChunkLightDirtyCells or {}
MC.GpuChunkLightDirtyChunks = MC.GpuChunkLightDirtyChunks or {}

local atlasRT
local uploadMaterial
local uploadToneScale
local atlasInitialized = false
local materialsBoundTo = nil
local slotByKey = {}
local keyBySlot = {}
local freeSlots = {}
local freeSlotCount = 0
local nextGeneration = 0
local statsAssignments = 0
local statsFallbackAssignments = 0
local statsReleases = 0
local statsBakes = 0
local statsUploadRects = 0
local statsUploadPixels = 0
local statsFullTileBakes = 0
local statsPartialTileBakes = 0
local statsRefreshMS = 0
local statsLastRefreshMS = 0
local statsLastRefreshTiles = 0

local function resetAllocator()
	slotByKey = {}
	keyBySlot = {}
	freeSlots = {}
	freeSlotCount = 0
	for slot = SLOT_COUNT - 1, 1, -1 do
		freeSlotCount = freeSlotCount + 1
		freeSlots[freeSlotCount] = slot
	end
end
resetAllocator()

local function gpuLightTextureEnabled()
	local cv = MC.MeshGpuLightTexture
	return cv and cv.GetBool and cv:GetBool() == true
end

function MC.UsingGpuLightTexture()
	return gpuLightTextureEnabled()
		and MC.MeshGpuShader
		and MC.MeshGpuShader.GetBool
		and MC.MeshGpuShader:GetBool() == true
		and MC.GpuLightTextureMaterialsReady ~= nil
		and MC.GpuLightTextureMaterialsReady()
end

local function nativeBackend()
	local backend = MC.NativeChunkBackend
	if not ( backend and backend.IsActive and backend.IsActive() == true ) then return nil end
	return backend
end

local function nextSlotGeneration()
	nextGeneration = nextGeneration + 1
	if nextGeneration <= 0 then nextGeneration = 1 end
	return nextGeneration
end

local function tilePixelOrigin( slot )
	local row = math.floor( slot / TILES_PER_ROW )
	local col = slot - row * TILES_PER_ROW
	return col * TILE_WIDTH, row * TILE_HEIGHT
end

local function chunkForKey( key )
	return MC.GetChunkByKey and MC.GetChunkByKey( key ) or nil
end

local function ensureAtlas()
	if atlasRT and atlasInitialized then return atlasRT end
	if not ( GetRenderTargetEx and render and render.PushRenderTarget and render.Clear ) then return nil end
	atlasRT = atlasRT or GetRenderTargetEx(
		ATLAS_NAME,
		ATLAS_SIZE,
		ATLAS_SIZE,
		RT_SIZE_LITERAL,
		MATERIAL_RT_DEPTH_NONE,
		bit.bor( 1, 4, 8, 256, 512 ),
		0,
		IMAGE_FORMAT_RGBA8888
	)
	if not atlasRT then return nil end
	render.PushRenderTarget( atlasRT )
		render.Clear( 255, 255, 255, 255, true, true )
	render.PopRenderTarget()
	atlasInitialized = true
	return atlasRT
end

local GPU_LIGHT_MATERIAL_NAMES = {
	"MaterialGpuLightTexture",
	"MaterialGpuLightTextureLinearDebug",
	"MaterialGpuLightTexturePpFix",
	"MaterialGpuLightTextureFancy",
	"MaterialGpuLightTextureFancyLinearDebug",
	"MaterialGpuLightTextureFancyPpFix",
	"MaterialGpuLightTextureHeight",
	"MaterialGpuLightTextureFast",
	"MaterialGpuLightTextureVanilla",
	"MaterialGpuLightTextureVanillaTranslucent",
	"MaterialGpuLightTextureTranslucent",
	"MaterialGpuLightTextureTranslucentLinearDebug",
	"MaterialGpuLightTextureTranslucentPpFix",
}

function MC.GetGpuChunkLightTextureMaterials()
	local materials = {}
	local signature = {}
	local seen = {}
	local function addMaterial( material, label )
		if not material or seen[material] or not material.GetName or not material.SetTexture
		or material:IsError() then return end
		seen[material] = true
		materials[#materials + 1] = material
		signature[#signature + 1] = label .. ":" .. tostring( material )
	end
	for _, name in ipairs( GPU_LIGHT_MATERIAL_NAMES ) do
		addMaterial( MC[name], name )
	end
	local pageCount = MC.AtlasPageCount and MC.AtlasPageCount() or 1
	if MC.AtlasPageMaterial then
		for page = 1, pageCount - 1 do
			addMaterial( select( 1, MC.AtlasPageMaterial( page, false ) ), "atlas_page_" .. page .. "_opaque" )
			addMaterial( select( 1, MC.AtlasPageMaterial( page, true ) ), "atlas_page_" .. page .. "_translucent" )
		end
	end
	return materials, table.concat( signature, "|" )
end

local function bindLuaAtlasToMaterials()
	local atlas = ensureAtlas()
	if not atlas then return false end
	local materials, signature = MC.GetGpuChunkLightTextureMaterials()
	local bound = 0
	for _, material in ipairs( materials ) do
		material:SetTexture( "$texture1", atlas )
		bound = bound + 1
	end
	if bound == 0 then return false end
	materialsBoundTo = "lua:" .. signature
	return true
end

function MC.BindGpuChunkLightTexture()
	local backend = nativeBackend()
	if backend and backend.BindLightAtlasMaterials then
		local ok = backend.BindLightAtlasMaterials() == true
		if ok then
			local _, signature = MC.GetGpuChunkLightTextureMaterials()
			materialsBoundTo = "native:" .. signature
		end
		return ok
	end
	return bindLuaAtlasToMaterials()
end

-- Material objects are recreated by Lua autorefresh. Existing meshes keep
-- their stable payload slots, but the replacement materials still need the
-- atlas owned by the currently active backend. This check performs no tile
-- work and only rebinds when the material/backend signature actually changes.
function MC.EnsureGpuChunkLightTextureBinding()
	local backend = nativeBackend()
	local _, signature = MC.GetGpuChunkLightTextureMaterials()
	local expected = ( backend and "native:" or "lua:" ) .. signature
	if signature ~= "" and materialsBoundTo == expected then return true end
	return MC.BindGpuChunkLightTexture()
end

local function assignLuaSlot( key )
	local owner = slotByKey[key]
	if owner then return owner end
	local chunk = chunkForKey( key )
	if not chunk then return nil end
	owner = {
		slot = 0,
		generation = nextSlotGeneration(),
		ready = true,
		dirty = false,
		fallback = true,
	}
	if freeSlotCount > 0 then
		local slot = freeSlots[freeSlotCount]
		freeSlots[freeSlotCount] = nil
		freeSlotCount = freeSlotCount - 1
		owner.slot = slot
		owner.ready = false
		owner.dirty = true
		owner.fallback = false
		keyBySlot[slot] = key
	else
		statsFallbackAssignments = statsFallbackAssignments + 1
	end
	slotByKey[key] = owner
	statsAssignments = statsAssignments + 1
	return owner
end

local function lightEnabled()
	local cv = MC.LightEnabled or ( GetConVar and GetConVar( "mc_light_enabled" ) )
	return not cv or not cv.GetBool or cv:GetBool() == true
end

local function cellSelfEmission( bx, by, bz )
	if not ( MC.GetBlock and MC.BlockLightEmission ) then return 0 end
	local id = MC.GetBlock( bx, by, bz )
	if not id or id == 0 then return 0 end
	return MC.BlockLightEmission( id ) or 0
end

local function rawPackedLight( bx, by, bz )
	if not lightEnabled() or not MC.SampleLighting then return FULLBRIGHT_PACKED end
	local _, level, block, sky = MC.SampleLighting( bx, by, bz, cellSelfEmission( bx, by, bz ) )
	level = tonumber( level ) or 15
	block = tonumber( block ) or level
	sky = tonumber( sky ) or level
	block = math.Clamp( math.floor( block + 0.5 ), 0, 15 )
	sky = math.Clamp( math.floor( sky + 0.5 ), 0, 15 )
	return block + sky * 16
end

local function packedPixel( chunk, pixelX, pixelY )
	local paddedX = pixelX % GRID_XY
	local paddedY = math.floor( pixelX / GRID_XY )
	local baseX = chunk.cx * ( MC.CS or 16 ) + paddedX - 1
	local baseY = chunk.cy * ( MC.CS or 16 ) + paddedY - 1
	local baseZ = chunk.cz * ( MC.CH or 32 ) + pixelY * 4 - 1
	local paddedZ = pixelY * 4
	local r = paddedZ < GRID_Z and rawPackedLight( baseX, baseY, baseZ ) or FULLBRIGHT_PACKED
	local g = paddedZ + 1 < GRID_Z and rawPackedLight( baseX, baseY, baseZ + 1 ) or FULLBRIGHT_PACKED
	local b = paddedZ + 2 < GRID_Z and rawPackedLight( baseX, baseY, baseZ + 2 ) or FULLBRIGHT_PACKED
	local a = paddedZ + 3 < GRID_Z and rawPackedLight( baseX, baseY, baseZ + 3 ) or FULLBRIGHT_PACKED
	return r, g, b, a
end

-- Return the packed RGBA texel touched by one world-space light cell in this
-- chunk's one-cell halo. A z change updates one channel, but the upload writes
-- the complete RGBA texel so the other three packed z samples stay intact.
local function packedPixelForWorldCell( chunk, bx, by, bz )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local paddedX = bx - chunk.cx * cs + 1
	local paddedY = by - chunk.cy * cs + 1
	local paddedZ = bz - chunk.cz * ch + 1
	if paddedX < 0 or paddedX >= GRID_XY
	or paddedY < 0 or paddedY >= GRID_XY
	or paddedZ < 0 or paddedZ >= GRID_Z then return nil end
	local pixelX = paddedX + paddedY * GRID_XY
	local pixelY = math.floor( paddedZ / 4 )
	return pixelY * TILE_WIDTH + pixelX
end

local function clearAtlasRect( x, y, width, height, r, g, b, a )
	render.PushRenderTarget( atlasRT, x, y, width, height )
		render.Clear( r, g, b, a, true, true )
	render.PopRenderTarget()
end

local function appendRect( rects, x, y, width, height, r, g, b, a )
	local n = #rects
	rects[n + 1], rects[n + 2], rects[n + 3], rects[n + 4] = x, y, width, height
	rects[n + 5], rects[n + 6], rects[n + 7], rects[n + 8] = r, g, b, a
end

local function dataUploadMaterial()
	if uploadMaterial then return uploadMaterial end
	if not CreateMaterial then return nil end
	local material = CreateMaterial( "mc_gpu_light_data_upload_linear1", "UnlitGeneric", {
		["$basetexture"] = "vgui/white",
		["$vertexcolor"] = 1,
		["$vertexalpha"] = 1,
		["$ignorez"] = 1,
		["$nofog"] = 1,
		["$nocull"] = 1,
		["$no_fullbright"] = 1,
		["$gammacolorread"] = 1,
		["$linearwrite"] = 1,
	} )
	if not material or material:IsError() then return nil end
	uploadMaterial = material
	return material
end

local function drawAtlasRects( rects, material )
	-- DrawRect's default VGUI material converts vertex RGB with pow(2.2),
	-- then applies hardware sRGB encoding. That round trip changes packed
	-- bytes (but not alpha), corrupting both light nibbles at three z phases.
	-- The linear material bypasses both conversions; exposure is neutralized
	-- by the caller because UnlitGeneric still applies tone mapping.
	surface.SetMaterial( material )
	render.OverrideAlphaWriteEnable( true, true )
	render.OverrideBlend( true,
		BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD,
		BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
	local hasZeroAlpha = false
	for i = 1, #rects, 8 do
		local alpha = rects[i + 7]
		if alpha == 0 then
			hasZeroAlpha = true
		else
			surface.SetDrawColor( rects[i + 4], rects[i + 5], rects[i + 6], alpha )
			surface.DrawTexturedRect( rects[i], rects[i + 1], rects[i + 2], rects[i + 3] )
		end
	end
	if not hasZeroAlpha then return end

	-- Surface discards alpha-zero draws before blending. Submit opaque RGB
	-- instead and force the stored alpha to zero with ZERO/ZERO. The rectangles
	-- do not overlap, so a second pass avoids per-rectangle blend changes.
	render.OverrideBlend( true,
		BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD,
		BLEND_ZERO, BLEND_ZERO, BLENDFUNC_ADD )
	for i = 1, #rects, 8 do
		if rects[i + 7] == 0 then
			surface.SetDrawColor( rects[i + 4], rects[i + 5], rects[i + 6], 255 )
			surface.DrawTexturedRect( rects[i], rects[i + 1], rects[i + 2], rects[i + 3] )
		end
	end
end

-- All four channels are light data, including alpha. Keep one RT bind per
-- tile, bypass color transfer/exposure, and replace all four byte channels.
-- Without the required controls, render.Clear is the exact, slower fallback.
local function uploadRects( rects )
	if not rects or #rects == 0 then return true end
	local fast = render and render.PushRenderTarget and render.OverrideBlend
		and render.OverrideAlphaWriteEnable
		and render.GetToneMappingScaleLinear and render.SetToneMappingScaleLinear and Vector
		and cam and cam.Start2D and cam.End2D
		and surface and surface.SetDrawColor and surface.SetMaterial and surface.DrawTexturedRect
		and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil
	local material = fast and dataUploadMaterial() or nil
	fast = fast and material ~= nil
	if fast then
		local oldToneScale = render.GetToneMappingScaleLinear()
		uploadToneScale = uploadToneScale or Vector( 1, 1, 1 )
		render.PushRenderTarget( atlasRT )
			cam.Start2D()
				render.SetToneMappingScaleLinear( uploadToneScale )
				local ok, err = pcall( drawAtlasRects, rects, material )
				render.OverrideBlend( false )
				render.OverrideAlphaWriteEnable( false )
				render.SetToneMappingScaleLinear( oldToneScale )
			cam.End2D()
		render.PopRenderTarget()
		if not ok then error( err, 0 ) end
	else
		for i = 1, #rects, 8 do
			clearAtlasRect(
				rects[i], rects[i + 1], rects[i + 2], rects[i + 3],
				rects[i + 4], rects[i + 5], rects[i + 6], rects[i + 7]
			)
		end
	end
	statsUploadRects = statsUploadRects + #rects / 8
	for i = 1, #rects, 8 do
		statsUploadPixels = statsUploadPixels + rects[i + 2] * rects[i + 3]
	end
	return true
end

local function buildWholeTileRects( chunk, tileX, tileY )
	local rects = {}
	if not lightEnabled() then
		appendRect( rects, tileX, tileY, TILE_WIDTH, TILE_HEIGHT, 255, 255, 255, 255 )
		return rects, TILE_WIDTH * TILE_HEIGHT
	end
	for pixelY = 0, TILE_HEIGHT - 1 do
		local runStart, runR, runG, runB, runA
		for pixelX = 0, TILE_WIDTH do
			local r, g, b, a
			if pixelX < TILE_WIDTH then r, g, b, a = packedPixel( chunk, pixelX, pixelY ) end
			if runStart == nil then
				runStart, runR, runG, runB, runA = pixelX, r, g, b, a
			elseif pixelX == TILE_WIDTH or r ~= runR or g ~= runG or b ~= runB or a ~= runA then
				appendRect( rects, tileX + runStart, tileY + pixelY,
					pixelX - runStart, 1, runR, runG, runB, runA )
				runStart, runR, runG, runB, runA = pixelX, r, g, b, a
			end
		end
	end
	return rects, TILE_WIDTH * TILE_HEIGHT
end

local function buildPartialTileRects( chunk, tileX, tileY, dirty )
	local pixels = {}
	for packedPixelIndex in pairs( dirty or {} ) do
		packedPixelIndex = tonumber( packedPixelIndex )
		if packedPixelIndex and packedPixelIndex >= 0
		and packedPixelIndex < TILE_WIDTH * TILE_HEIGHT then
			pixels[#pixels + 1] = packedPixelIndex
		end
	end
	table.sort( pixels )
	local rects = {}
	local runX, runY, runLen, runR, runG, runB, runA
	local function flushRun()
		if not runLen then return end
		appendRect( rects, tileX + runX, tileY + runY, runLen, 1, runR, runG, runB, runA )
		runX, runY, runLen, runR, runG, runB, runA = nil, nil, nil, nil, nil, nil, nil
	end
	for i = 1, #pixels do
		local packedPixelIndex = pixels[i]
		local pixelY = math.floor( packedPixelIndex / TILE_WIDTH )
		local pixelX = packedPixelIndex - pixelY * TILE_WIDTH
		local r, g, b, a = packedPixel( chunk, pixelX, pixelY )
		if runLen and pixelY == runY and pixelX == runX + runLen
		and r == runR and g == runG and b == runB and a == runA then
			runLen = runLen + 1
		else
			flushRun()
			runX, runY, runLen = pixelX, pixelY, 1
			runR, runG, runB, runA = r, g, b, a
		end
	end
	flushRun()
	return rects, #pixels
end

local function bakeLuaTile( key, owner, dirty )
	local chunk = chunkForKey( key )
	if not chunk or owner.slot == 0 then return owner.slot == 0, false end
	if not ensureAtlas() then return false, false end
	local tileX, tileY = tilePixelOrigin( owner.slot )
	local whole = owner.ready ~= true or owner.dirty == true or dirty == true
	if not whole and type( dirty ) ~= "table" then return true, false end
	local rects, pixels
	if whole then
		rects, pixels = buildWholeTileRects( chunk, tileX, tileY )
	else
		rects, pixels = buildPartialTileRects( chunk, tileX, tileY, dirty )
	end
	if not uploadRects( rects ) then return false, false end
	statsBakes = statsBakes + 1
	if whole then
		statsFullTileBakes = statsFullTileBakes + 1
	else
		statsPartialTileBakes = statsPartialTileBakes + 1
	end
	return true, true, pixels
end

local function refreshLuaOwners( owners )
	if not owners or #owners == 0 then return true end
	if not ensureAtlas() then return false end
	local completed = {}
	for i = 1, #owners do
		local item = owners[i]
		local owner = item.owner
		local dirty = MC.GpuChunkLightDirtyCells[item.key]
		local ok = owner.slot == 0
		if not ok then ok = bakeLuaTile( item.key, owner, dirty ) end
		if not ok then return false end
		completed[#completed + 1] = item
	end
	-- All writes above are synchronous. Readiness and dirty state only flip
	-- after each selected tile has been completely uploaded.
	for i = 1, #completed do
		local item = completed[i]
		if slotByKey[item.key] == item.owner then
			item.owner.ready = true
			item.owner.dirty = false
			MC.GpuChunkLightDirtyCells[item.key] = nil
			MC.GpuChunkLightDirtyChunks[item.key] = nil
		end
	end
	return true
end

local function prepareLuaKey( key )
	local owner = assignLuaSlot( key )
	if not owner then return 0, 0, false end
	if owner.slot ~= 0 and ( owner.dirty or not owner.ready
	or MC.GpuChunkLightDirtyCells[key] ~= nil ) then
		if not refreshLuaOwners( { { key = key, owner = owner } } ) then
			return 0, 0, false
		end
	end
	if not MC.EnsureGpuChunkLightTextureBinding() then return 0, 0, false end
	return owner.slot, owner.generation, owner.ready == true
end

function MC.PrepareGpuChunkLightTexture( key )
	local backend = nativeBackend()
	if backend and backend.GetLightAtlasSlot then
		if not MC.EnsureGpuChunkLightTextureBinding() then return 0, 0, false end
		local slot, generation = backend.GetLightAtlasSlot( key )
		slot = tonumber( slot ) or 0
		generation = tonumber( generation ) or 0
		return slot, generation, generation > 0
	end
	return prepareLuaKey( key )
end

function MC.GetGpuChunkLightSlot( key )
	local slot, generation = MC.PrepareGpuChunkLightTexture( key )
	return slot or 0, generation or 0
end

local function newDirtyBatch()
	return {
		owners = {}, ownerSeen = {}, chunkSeen = {}, animationSeen = {},
		chunks = 0, pixels = 0, firstKey = nil, native = nativeBackend() ~= nil,
	}
end

local function notifyAnimationChunk( batch, key )
	if batch.animationSeen[key] then return end
	batch.animationSeen[key] = true
	if MC.MarkBlockAnimationLightDirty then MC.MarkBlockAnimationLightDirty( key ) end
end

local function addOwnerToBatch( batch, key, owner )
	if not owner or batch.ownerSeen[key] then return end
	batch.ownerSeen[key] = true
	batch.owners[#batch.owners + 1] = { key = key, owner = owner }
end

local function noteBatchChunk( batch, key )
	if batch.chunkSeen[key] then return end
	batch.chunkSeen[key] = true
	batch.chunks = batch.chunks + 1
	batch.firstKey = batch.firstKey or key
end

local function markWholeKeyIntoBatch( batch, key )
	if not key then return false end
	notifyAnimationChunk( batch, key )
	if batch.native then return false end
	local owner = slotByKey[key]
	-- An unassigned chunk will receive a complete current-state bake when its
	-- mesh is first built, so there is no stale tile to update yet.
	if not owner then return false end
	owner.dirty = true
	MC.GpuChunkLightDirtyCells[key] = true
	MC.GpuChunkLightDirtyChunks[key] = true
	noteBatchChunk( batch, key )
	addOwnerToBatch( batch, key, owner )
	return true
end

local function markPixelIntoBatch( batch, key, owner, packedPixelIndex )
	if not owner or owner.slot == 0 or packedPixelIndex == nil then return false end
	local dirty = MC.GpuChunkLightDirtyCells[key]
	if dirty ~= true then
		if type( dirty ) ~= "table" then
			dirty = {}
			MC.GpuChunkLightDirtyCells[key] = dirty
		end
		if not dirty[packedPixelIndex] then
			dirty[packedPixelIndex] = true
			batch.pixels = batch.pixels + 1
		end
	end
	MC.GpuChunkLightDirtyChunks[key] = true
	noteBatchChunk( batch, key )
	addOwnerToBatch( batch, key, owner )
	return true
end

-- One changed cell belongs to its owning tile and only to halo-neighbour tiles
-- on the axes where it lies at a chunk boundary: at most 8 tiles, not 27.
local function markWorldCellIntoBatch( batch, bx, by, bz )
	if not MC.ChunkKey then return 0 end
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local cx, cy, cz = math.floor( bx / cs ), math.floor( by / cs ), math.floor( bz / ch )
	local lx, ly, lz = bx - cx * cs, by - cy * cs, bz - cz * ch
	local dx0, dx1 = lx == 0 and -1 or 0, lx == cs - 1 and 1 or 0
	local dy0, dy1 = ly == 0 and -1 or 0, ly == cs - 1 and 1 or 0
	local dz0, dz1 = lz == 0 and -1 or 0, lz == ch - 1 and 1 or 0
	local marked = 0
	for dz = dz0, dz1 do
		for dy = dy0, dy1 do
			for dx = dx0, dx1 do
				local key = MC.ChunkKey( cx + dx, cy + dy, cz + dz )
				notifyAnimationChunk( batch, key )
				if not batch.native then
					local owner = slotByKey[key]
					local chunk = owner and chunkForKey( key ) or nil
					if chunk and markPixelIntoBatch( batch, key, owner,
						packedPixelForWorldCell( chunk, bx, by, bz ) ) then marked = marked + 1 end
				end
			end
		end
	end
	return marked
end

local function markChunkNeighborhoodWhole( batch, cx, cy, cz )
	if not MC.ChunkKey then return end
	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				markWholeKeyIntoBatch( batch, MC.ChunkKey( cx + dx, cy + dy, cz + dz ) )
			end
		end
	end
end

local function markNativeMaskIntoBatch( batch, cx, cy, cz, dirtyBits )
	local cs, ch = MC.CS or 16, MC.CH or 32
	local expectedBytes = cs * cs * ch / 8
	if type( dirtyBits ) ~= "string" or #dirtyBits ~= expectedBytes then
		markChunkNeighborhoodWhole( batch, cx, cy, cz )
		return 0
	end
	local markedCells = 0
	for byteIndex = 1, #dirtyBits do
		local value = string.byte( dirtyBits, byteIndex ) or 0
		if value ~= 0 then
			for bitIndex = 0, 7 do
				if bit.band( value, bit.lshift( 1, bitIndex ) ) ~= 0 then
					local li = ( byteIndex - 1 ) * 8 + bitIndex
					local lz = math.floor( li / ( cs * cs ) )
					local rem = li - lz * cs * cs
					local ly = math.floor( rem / cs )
					local lx = rem - ly * cs
					markWorldCellIntoBatch( batch, cx * cs + lx, cy * cs + ly, cz * ch + lz )
					markedCells = markedCells + 1
				end
			end
		end
	end
	return markedCells
end

local function flushDirtyBatch( batch )
	if #batch.owners > 0 then refreshLuaOwners( batch.owners ) end
	return batch.chunks
end

local function refreshLuaKeySet( keys )
	local batch = newDirtyBatch()
	for key in pairs( keys or {} ) do markWholeKeyIntoBatch( batch, key ) end
	return flushDirtyBatch( batch )
end

function MC.MarkGpuChunkLightTextureDirty( key )
	local batch = newDirtyBatch()
	markWholeKeyIntoBatch( batch, key )
	return flushDirtyBatch( batch ) > 0
end

function MC.MarkGpuChunkLightTextureDirtyCell( bx, by, bz )
	local batch = newDirtyBatch()
	local marked = markWorldCellIntoBatch( batch, bx, by, bz )
	flushDirtyBatch( batch )
	if batch.native then return false end
	return marked > 0, batch.firstKey, marked
end

function MC.MarkGpuChunkLightTextureDirtyNative( cx, cy, cz, dirtyBits )
	local batch = newDirtyBatch()
	local markedCells = markNativeMaskIntoBatch( batch,
		math.floor( tonumber( cx ) or 0 ), math.floor( tonumber( cy ) or 0 ), math.floor( tonumber( cz ) or 0 ), dirtyBits )
	flushDirtyBatch( batch )
	if batch.native then return 0, 0 end
	return markedCells, batch.chunks
end

function MC.MarkGpuChunkLightTextureDirtyForChangedCells( changed )
	if type( changed ) ~= "table" then return 0 end
	local batch = newDirtyBatch()
	local count = math.floor( tonumber( changed.count ) or 0 )
	if count > 0 and type( changed.x ) == "table"
	and type( changed.y ) == "table" and type( changed.z ) == "table" then
		for i = 1, count do
			markWorldCellIntoBatch( batch, changed.x[i], changed.y[i], changed.z[i] )
		end
	else
		for i = 1, #changed, 3 do
			if changed[i + 2] ~= nil then
				markWorldCellIntoBatch( batch, changed[i], changed[i + 1], changed[i + 2] )
			end
		end
	end
	return flushDirtyBatch( batch )
end

function MC.MarkGpuChunkLightTextureDirtyChunkList( changed )
	if type( changed ) ~= "table" then return 0 end
	local batch = newDirtyBatch()
	for i = 1, #changed, 4 do
		local cx, cy, cz = tonumber( changed[i] ), tonumber( changed[i + 1] ), tonumber( changed[i + 2] )
		if cx and cy and cz then
			markNativeMaskIntoBatch( batch, math.floor( cx ), math.floor( cy ), math.floor( cz ), changed[i + 3] )
		end
	end
	return flushDirtyBatch( batch )
end

function MC.QueueAllGpuChunkLightTextureRefresh()
	if MC.MarkAllBlockAnimationLightDirty then MC.MarkAllBlockAnimationLightDirty() end
	local batch = newDirtyBatch()
	for key in pairs( slotByKey ) do markWholeKeyIntoBatch( batch, key ) end
	return batch.chunks
end

function MC.ProcessGpuChunkLightTextureRefresh( deadline, onChunkRefreshed )
	statsLastRefreshMS, statsLastRefreshTiles = 0, 0
	if nativeBackend() or ( MC.LightingBulkLoadDepth or 0 ) > 0
	or not MC.UsingGpuLightTexture() or next( MC.GpuChunkLightDirtyChunks ) == nil then return 0 end
	local started = SysTime()
	local attempts, pairedMS = 0, 0
	for key in pairs( MC.GpuChunkLightDirtyChunks ) do
		if deadline and SysTime() >= deadline then break end
		local owner = slotByKey[key]
		if owner and chunkForKey( key ) then
			attempts = attempts + 1
			if not refreshLuaOwners( { { key = key, owner = owner } } ) then break end
			statsLastRefreshTiles = statsLastRefreshTiles + 1
			if onChunkRefreshed then
				local pairStarted = SysTime()
				onChunkRefreshed( key )
				pairedMS = pairedMS + ( SysTime() - pairStarted ) * 1000
			end
		else
			MC.GpuChunkLightDirtyCells[key] = nil
			MC.GpuChunkLightDirtyChunks[key] = nil
		end
	end
	statsLastRefreshMS = math.max( 0, ( SysTime() - started ) * 1000 - pairedMS )
	statsRefreshMS = statsRefreshMS + statsLastRefreshMS
	return attempts
end

function MC.MarkGpuChunkLightTextureDirtyKeys( keys )
	if type( keys ) ~= "table" then return 0 end
	return refreshLuaKeySet( keys )
end

function MC.RequestGpuChunkLightTextureFullFlush()
	local queued = MC.QueueAllGpuChunkLightTextureRefresh()
	MC.ProcessGpuChunkLightTextureRefresh()
	return queued
end

function MC.RefreshGpuChunkLightTexture( key )
	local _, _, ready = MC.PrepareGpuChunkLightTexture( key )
	return ready and ( nativeBackend() and true or atlasRT ) or nil
end

-- Compatibility probes remain read-only. Drawing never allocates, evicts or
-- uploads a tile.
function MC.TouchGpuChunkLightTexture( key )
	local backend = nativeBackend()
	if backend and backend.GetLightAtlasSlot then
		local _, generation = backend.GetLightAtlasSlot( key )
		return ( tonumber( generation ) or 0 ) > 0
	end
	local owner = slotByKey[key]
	return owner ~= nil and owner.ready == true
end

function MC.PeekGpuChunkLightTexture( key )
	local owner = slotByKey[key]
	return owner and owner.ready and atlasRT or nil
end

function MC.ClearGpuChunkLightTexture( key )
	local owner = slotByKey[key]
	if owner then
		slotByKey[key] = nil
		if owner.slot ~= 0 then
			keyBySlot[owner.slot] = nil
			freeSlotCount = freeSlotCount + 1
			freeSlots[freeSlotCount] = owner.slot
		end
		statsReleases = statsReleases + 1
	end
	MC.GpuChunkLightDirtyCells[key] = nil
	MC.GpuChunkLightDirtyChunks[key] = nil
end

function MC.ClearAllGpuChunkLightTextures()
	local live = next( MC.Meshes or {} ) ~= nil
		or next( MC.MeshesTrans or {} ) ~= nil
		or next( MC.MeshSections or {} ) ~= nil
	if live then
		MC.QueueAllGpuChunkLightTextureRefresh()
	else
		resetAllocator()
		atlasInitialized = false
		materialsBoundTo = nil
		MC.GpuChunkLightDirtyCells = {}
		MC.GpuChunkLightDirtyChunks = {}
	end
	return true
end

local function nativeStats()
	local backend = nativeBackend()
	local stats = backend and backend.GetLightAtlasStats and backend.GetLightAtlasStats() or nil
	return istable( stats ) and stats or nil
end

-- Lua counters only. Refresh time covers the deferred queue, not inline bakes.
function MC.GpuLightAtlasWorkCounters()
	return statsBakes, statsRefreshMS, statsUploadPixels
end

function MC.GpuLightAtlasStats()
	local stats = nativeStats()
	if stats then
		stats.slotsUsed = tonumber( stats.assigned ) or 0
		stats.slotsFree = tonumber( stats.free ) or 0
		stats.evictions = 0
		stats.bakes = tonumber( stats.tileBuilds ) or 0
		stats.nativeTileBakes = stats.bakes
		stats.luaTileBakes = 0
		stats.residueConflicts = 0
		return stats
	end
	local used = 0
	for _ in pairs( slotByKey ) do used = used + 1 end
	local pending = 0
	for _ in pairs( MC.GpuChunkLightDirtyChunks ) do pending = pending + 1 end
	return {
		atlasSize = ATLAS_SIZE,
		tileWidth = TILE_WIDTH,
		tileHeight = TILE_HEIGHT,
		slotCount = SLOT_COUNT,
		realCapacity = REAL_CAPACITY,
		assigned = used,
		fallbackAssigned = statsFallbackAssignments,
		free = freeSlotCount,
		textureReady = atlasInitialized,
		stableSlots = true,
		slotsUsed = used,
		slotsFree = freeSlotCount,
		evictions = 0,
		bakes = statsBakes,
		nativeTileBakes = 0,
		luaTileBakes = statsBakes,
		residueConflicts = 0,
		assignments = statsAssignments,
		releases = statsReleases,
		uploadRects = statsUploadRects,
		uploadPixels = statsUploadPixels,
		fullTileBakes = statsFullTileBakes,
		partialTileBakes = statsPartialTileBakes,
		pendingRefresh = pending,
		refreshMS = statsRefreshMS,
		lastRefreshMS = statsLastRefreshMS,
		lastRefreshTiles = statsLastRefreshTiles,
	}
end

function MC.GpuLightAtlasDebug()
	return {
		native = nativeBackend() ~= nil,
		atlas = atlasRT,
		slotByKey = slotByKey,
		keyBySlot = keyBySlot,
		stats = MC.GpuLightAtlasStats(),
		stableSlots = true,
		indirection = false,
		frameFlush = false,
		budgetedRefresh = true,
	}
end

hook.Remove( "PreRender", "mc_gpu_light_texture_flush" )
hook.Remove( "Think", "mc_gpu_light_texture_refresh_queue" )

-- Remove the old registration as well when Lua autorefresh re-runs this file.
if cvars and cvars.RemoveChangeCallback then
	cvars.RemoveChangeCallback( "mc_light_texture", "mc_light_texture_rebuild" )
end

if cvars and cvars.AddChangeCallback then
	local function refreshGlobalOnly()
		if MC.RefreshGlobalLightmap then MC.RefreshGlobalLightmap() end
	end
	for _, name in ipairs( {
		"mc_light_brightness",
		"mc_light_gamma",
		"mc_light_sun_brightness",
		"mc_daycycle_moon_light",
		"mc_daycycle_night_tint",
	} ) do
		cvars.AddChangeCallback( name, refreshGlobalOnly, "mc_packed_light_refresh_" .. name )
	end
end
