-- Client-only dynamic block texture layer.
--
-- Minecraft sprites such as fire, lit campfire logs, water and lava are vertical PNG
-- frame strips driven by .mcmeta. Source does not understand that format, so
-- the atlas builder keeps those atlas slots transparent and emits the Java
-- frames separately. Block animations reuse generated model quads; fluids reuse
-- RM.EmitLiquidBlock, whose geometry/occlusion/flow UV rules mirror Java's
-- FluidRenderer. Both paths remain independent of the Lua/native chunk backend.

MC = MC or {}
MC.BlockAnimationWorkVersion = 1

local RM = MC.RenderMesh or {}
local C = MC.RenderMeshConstants or {}
local VertexBuffer = MC.RenderVertexBuffer
local LightBuffer = MC.RenderLightBuffer
local TICK_SECONDS = 1 / 20
local REFRESH_INTERVAL = 0.25
local TRI = { 1, 3, 2, 1, 4, 3 }
local WATER_ANIMATIONS = {
	water_still = true,
	water_flow = true,
}
local LAVA_ANIMATIONS = {
	lava_still = true,
	lava_flow = true,
}
local FLUID_ANIMATIONS = {
	water = { still = "water_still", flow = "water_flow" },
	lava = { still = "lava_still", flow = "lava_flow" },
}
local FLUID_KIND_ORDER = { "water", "lava" }
local FLUID_ANIMATION_SET = {}
for _, kind in ipairs( FLUID_KIND_ORDER ) do
	local fluid = FLUID_ANIMATIONS[kind]
	FLUID_ANIMATION_SET[fluid.still] = true
	FLUID_ANIMATION_SET[fluid.flow] = true
end
-- Java intentionally changes these sprites at 10/20 Hz without mcmeta
-- interpolation. On a high-refresh Source client that cadence reads as visual
-- stutter, so only the flame layers crossfade while retaining Java's exact
-- frame order and per-frame duration. Other animated blocks keep mcmeta rules.
local SMOOTH_FLAME_ANIMATIONS = {
	fire_0 = true,
	fire_1 = true,
	soul_fire_0 = true,
	soul_fire_1 = true,
	campfire_fire = true,
	soul_campfire_fire = true,
}
local FACE_NORMALS = {
	[MC.Face.TOP] = Vector( 0, 0, 1 ),
	[MC.Face.BOTTOM] = Vector( 0, 0, -1 ),
	[MC.Face.XP] = Vector( 1, 0, 0 ),
	[MC.Face.XN] = Vector( -1, 0, 0 ),
	[MC.Face.YP] = Vector( 0, 1, 0 ),
	[MC.Face.YN] = Vector( 0, -1, 0 ),
}

local Entries = {}
local ModelEntries = {}
local EntriesByChunk = {}
local ModelAnimationSignatures = {}
local FluidEntryCounts = {}
local ScannedChunkVersions = {}
local MeshCache = {}
local FluidMeshCache = {}
local FluidMeshRetryAt = {}
local MaterialCache = {}
local FluidMeshesDirty = false
-- Bumped whenever a published fluid record appears, is replaced or removed.
-- Light-space consumers cache the water depth row against this revision.
local FluidMeshRevision = 0
local function touchFluidMeshes() FluidMeshRevision = FluidMeshRevision + 1 end
function MC.FluidMeshRevision() return FluidMeshRevision end
local LastRefresh = 0
local LastGeneration = tonumber( MC.StateWorldGeneration ) or 0
local LastAnimationPack
local LastWaterStyle
local AnimationStats = {
	builds = 0, modelBuilds = 0, lightRefreshes = 0, uploads = 0, failures = 0,
	attempts = 0, budgetYields = 0, workMS = 0, scanPasses = 0, scannedChunks = 0, scanMS = 0,
	classifiedStates = 0, candidateCells = 0,
	fluidBuildMS = 0, fluidLightMS = 0, modelMS = 0, uploadMS = 0,
	globalLightRefreshes = 0, localLightRefreshes = 0, skippedLightUploads = 0,
}

if not MC.Check( type( MC.StateVisualPlanRangeFast ) == "function"
	and type( MC.StateVisualPlanModelAtFast ) == "function"
	and type( MC.VisitStateVisualModelCandidates ) == "function" and type( MC.ForEachBlockState ) == "function"
	and type( MC.StateVisualModelData ) == "function" and type( MC.BlockModelSurface ) == "function",
	"block_animation_catalog_missing", "state visual catalog APIs are unavailable" ) then return end

local function blockSize()
	return MC.API.Coords.BlockSize()
end

local function currentWaterMaterial()
	if MC.RenderPBRWater then return MC.RenderPBRWater.CurrentMaterial() end
	return nil
end

local function destroyFluidRecord( record )
	if type( record ) ~= "table" then return end
	for _, batches in pairs( record.meshes ) do
		for _, batch in ipairs( batches ) do batch.mesh:Destroy() end
	end
end

local function releaseEmptyFluidChunk( key )
	if ( FluidEntryCounts[key] or 0 ) > 0 then return end
	FluidEntryCounts[key] = nil
	destroyFluidRecord( FluidMeshCache[key] )
	FluidMeshCache[key], FluidMeshRetryAt[key] = nil, nil
	touchFluidMeshes()
end

local function dirtyFluidChunk( key )
	local record = FluidMeshCache[key]
	if type( record ) == "table" then
		record.geometryDirty = true
	else
		FluidMeshCache[key] = nil
	end
end

local function dirtyFluidNeighbors( chunk )
	for z = chunk.cz - 1, chunk.cz + 1 do
		for y = chunk.cy - 1, chunk.cy + 1 do
			for x = chunk.cx - 1, chunk.cx + 1 do dirtyFluidChunk( MC.ChunkKey( x, y, z ) ) end
		end
	end
end

function MC.MarkBlockAnimationLightDirty( key )
	local record = FluidMeshCache[key]
	if type( record ) ~= "table" then return end
	record.lightDirty = true
	record.localLightDirty = true
end

function MC.MarkAllBlockAnimationLightDirty()
	for _, entry in pairs( ModelEntries ) do entry.nextLightAt = 0 end
	for key in pairs( FluidMeshCache ) do MC.MarkBlockAnimationLightDirty( key ) end
end

local function uploadAnimationMesh( vertices )
	local started = SysTime()
	local ok, meshObject = MC.Try( "block_animation_mesh", Mesh )
	if not ok or not meshObject then
		AnimationStats.failures = AnimationStats.failures + 1
		if ok then MC.Fault( "block_animation_mesh", "Mesh() returned no object" ) end
		return nil
	end
	local ok, err = pcall( RM.uploadMeshVertices, meshObject, vertices, nil, false )
	AnimationStats.uploadMS = AnimationStats.uploadMS + ( SysTime() - started ) * 1000
	if not ok then
		AnimationStats.failures = AnimationStats.failures + 1
		meshObject:Destroy()
		MC.Fault( "block_animation_upload", "%s", tostring( err ) )
		return nil
	end
	AnimationStats.uploads = AnimationStats.uploads + 1
	return meshObject
end

local function animationPacks()
	return MC.GeneratedBlockAnimationsByPack or {}
end

local function activePackName()
	return MC.TexturePackName and MC.TexturePackName() or MC.ActiveTexturePack or "default"
end

local generationAnimations = {water_still={}, water_flow={}}
local emptyAnimations = {}
local function generationOwnsAnimation()
	local packs = MC.ResourcePacks
	local generation = packs and packs.activeGeneration
	return generation and generation.pack == activePackName()
end

local function activeAnimations()
	-- Raw packs animate the atlas used by the ordinary world geometry. The
	-- old standalone PNG layer only fills transparent slots in legacy atlases.
	if generationOwnsAnimation() then
		-- Pixel animation belongs to the atlas. The dedicated PBR water
		-- geometry still owns waves/optics/reflections and uses no PNG frames.
		if currentWaterMaterial() then return generationAnimations end
		return emptyAnimations
	end
	local packs = animationPacks()
	return packs[activePackName()] or packs.default or {}
end

local function animationsByTile()
	local animations = activeAnimations()
	local cached = animations._byTile
	if cached then return cached end
	cached = {}
	for name, animation in pairs( animations ) do
		if type( animation ) == "table" and animation.tile ~= nil then cached[animation.tile] = { name, animation } end
	end
	animations._byTile = cached
	return cached
end

local function cellKey( bx, by, bz )
	return MC.CellKey and MC.CellKey( bx, by, bz ) or ( bx .. ":" .. by .. ":" .. bz )
end

local function chunkKeyForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return MC.ChunkKey( cx, cy, cz )
end

local function removeEntry( key )
	local entry = Entries[key]
	if not entry then return end
	Entries[key], ModelEntries[key] = nil, nil
	if entry.fluidKind then
		FluidEntryCounts[entry.chunkKey] = ( FluidEntryCounts[entry.chunkKey] or 1 ) - 1
		releaseEmptyFluidChunk( entry.chunkKey )
	end
	local chunkEntries = EntriesByChunk[entry.chunkKey]
	if chunkEntries then
		chunkEntries[key] = nil
		if next( chunkEntries ) == nil then EntriesByChunk[entry.chunkKey] = nil end
	end
end

local function removeChunkEntries( chunkKey )
	for key in pairs( EntriesByChunk[chunkKey] or {} ) do Entries[key], ModelEntries[key] = nil, nil end
	EntriesByChunk[chunkKey] = nil
	FluidEntryCounts[chunkKey] = nil
end

local function modelAnimationSignature( modelId, byTile )
	local model = MC.StateVisualModelData( modelId )
	local cached = ModelAnimationSignatures[modelId]
	if cached and cached.model == model and cached.byTile == byTile then return cached.signature end
	local parts
	if model then
		for _, quad in ipairs( model.modelQuads ) do
			local tile = MC.BlockModelSurface( model, quad )
			if byTile[tile] then
				if not parts then parts = {} end
				parts[#parts + 1] = modelId .. "/" .. tile
			end
		end
	end
	local signature = parts and table.concat( parts, "," ) or false
	ModelAnimationSignatures[modelId] = { model = model, byTile = byTile, signature = signature }
	return signature
end

local function stateAnimationSignature( stateId, bx, by, bz )
	local planId, groupOffset, groupCount = MC.StateVisualPlanRangeFast( stateId )
	local byTile = animationsByTile()
	local signature, parts
	for groupIndex = 0, groupCount - 1 do
		local modelId = MC.StateVisualPlanModelAtFast( planId, groupOffset, groupIndex, bx, by, bz )
		if modelId then
			local part = modelAnimationSignature( modelId, byTile )
			if part then
				if signature then
					if not parts then parts = { signature } end
					parts[#parts + 1] = part
				else signature = part end
			end
		end
	end
	if parts then signature = table.concat( parts, "," ) end
	return signature ~= nil, signature or ""
end

local function fluidAnimationKind( stateId )
	if not MC.LiquidKindForState then return nil end
	local kind = MC.LiquidKindForState( stateId )
	if generationOwnsAnimation() and kind ~= "water" then return nil end
	return FLUID_ANIMATIONS[kind] and kind or nil
end

local function animationStateFilter()
	local byTile, states = animationsByTile(), {}
	return function( stateId )
		local accepted = states[stateId]
		if accepted ~= nil then return accepted end
		AnimationStats.classifiedStates = AnimationStats.classifiedStates + 1
		accepted = fluidAnimationKind( stateId ) ~= nil
		if not accepted then
			MC.VisitStateVisualModelCandidates( stateId, function( modelId )
				if not accepted and modelAnimationSignature( modelId, byTile ) then accepted = true end
			end )
		end
		states[stateId] = accepted
		return accepted
	end
end

local function addEntry( bx, by, bz, stateId, hasStateAnimation, visualSignature, fluidKind )
	local key = cellKey( bx, by, bz )
	local chunkKey = chunkKeyForCell( bx, by, bz )
	local entry = Entries[key]
	if not entry then
		entry = { key = key, chunkKey = chunkKey, bx = bx, by = by, bz = bz }
		Entries[key] = entry
		EntriesByChunk[chunkKey] = EntriesByChunk[chunkKey] or {}
		EntriesByChunk[chunkKey][key] = true
	end
	if entry.fluidKind then FluidEntryCounts[chunkKey] = ( FluidEntryCounts[chunkKey] or 1 ) - 1 end
	if fluidKind then FluidEntryCounts[chunkKey] = ( FluidEntryCounts[chunkKey] or 0 ) + 1 end
	entry.stateId = stateId
	entry.chunkKey = chunkKey
	entry.hasStateAnimation = hasStateAnimation == true
	ModelEntries[key] = entry.hasStateAnimation and entry or nil
	entry.visualSignature = visualSignature
	entry.fluidKind = fluidKind
	entry.nextLightAt = 0
	return entry
end

local function updateCellEntry( bx, by, bz, stateId )
	local hasStateAnimation, visualSignature = stateAnimationSignature( stateId, bx, by, bz )
	local fluidKind = fluidAnimationKind( stateId )
	if hasStateAnimation or fluidKind then
		local entry = addEntry( bx, by, bz, stateId, hasStateAnimation, visualSignature, fluidKind )
		releaseEmptyFluidChunk( entry.chunkKey )
	else
		removeEntry( cellKey( bx, by, bz ) )
	end
end

local function scanChunk( key, chunk, stateFilter )
	AnimationStats.scannedChunks = AnimationStats.scannedChunks + 1
	dirtyFluidNeighbors( chunk )
	removeChunkEntries( key )
	MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
		AnimationStats.candidateCells = AnimationStats.candidateCells + 1
		local hasStateAnimation, visualSignature = stateAnimationSignature( stateId, bx, by, bz )
		local fluidKind = fluidAnimationKind( stateId )
		if hasStateAnimation or fluidKind then
			addEntry( bx, by, bz, stateId, hasStateAnimation, visualSignature, fluidKind )
		end
	end, stateFilter )
	releaseEmptyFluidChunk( key )
	ScannedChunkVersions[key] = { chunk = chunk, version = chunk.collisionVersion or 0 }
end

local function clearEntries()
	Entries = {}
	ModelEntries = {}
	EntriesByChunk = {}
	FluidEntryCounts = {}
	ScannedChunkVersions = {}
end

local function refreshChunks()
	local animationPack = activePackName()
	if animationPack ~= LastAnimationPack then
		clearEntries()
		FluidMeshesDirty = true
		LastAnimationPack = animationPack
	end
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if generation ~= LastGeneration then
		clearEntries()
		FluidMeshesDirty = true
		LastGeneration = generation
		touchFluidMeshes()
	end
	for key, scanned in pairs( ScannedChunkVersions ) do
		local current = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
		if current ~= scanned.chunk then
			removeChunkEntries( key )
			ScannedChunkVersions[key] = nil
			dirtyFluidNeighbors( scanned.chunk )
			if current then
				-- A replacement can outlive this frame's build budget. Keep the
				-- old publication until the replacement scan/build can commit.
				dirtyFluidChunk( key )
			else
				destroyFluidRecord( FluidMeshCache[key] )
				FluidMeshCache[key] = nil
				touchFluidMeshes()
			end
			FluidMeshRetryAt[key] = nil
		end
	end
	local stateFilter
	for key, chunk in pairs( MC.World or {} ) do
		local scanned = ScannedChunkVersions[key]
		local version = chunk.collisionVersion or 0
		if not scanned or scanned.chunk ~= chunk or scanned.version ~= version then
			if not stateFilter then stateFilter = animationStateFilter() end
			scanChunk( key, chunk, stateFilter )
		end
	end
end

local function rotatedUVFlags( u, v, rotation )
	rotation = ( rotation or 0 ) % 4
	if rotation == 1 then return v, 1 - u end
	if rotation == 2 then return 1 - u, 1 - v end
	if rotation == 3 then return 1 - v, u end
	return u, v
end

local function quadNormal( points, fallback, normal )
	local ax, ay, az = points[6] - points[1], points[7] - points[2], points[8] - points[3]
	local bx, by, bz = points[11] - points[1], points[12] - points[2], points[13] - points[3]
	local x, y, z = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	local lengthSqr = x * x + y * y + z * z
	if lengthSqr <= 0.000001 then return fallback end
	local length = math.sqrt( lengthSqr )
	normal.x, normal.y, normal.z = x / length, y / length, z / length
	return normal
end

local function meshForStateAnimation( stateId, bx, by, bz, animationName, animation, visualSignature )
	local cacheKey = activePackName() .. ":" .. tostring( stateId ) .. ":"
		.. tostring( visualSignature or 0 ) .. ":" .. tostring( animationName )
	local cached = MeshCache[cacheKey]
	if cached ~= nil then return cached end

	local vertices, points, normalScratch = VertexBuffer.New(), {}, {}
	local BS = blockSize()
	local ok = MC.Try( "block_animation_model", MC.VisitStateVisualModels, stateId, bx, by, bz, function( modelId )
		local model = MC.StateVisualModelData( modelId )
		for _, quad in ipairs( model and model.modelQuads or {} ) do
			local tile = MC.BlockModelSurface( model, quad )
			if tile == animation.tile then
				local uv = quad.uv
				local u0 = ( uv and tonumber( uv[1] ) or 0 ) / 16
				local v0 = ( uv and tonumber( uv[2] ) or 0 ) / 16
				local u1 = ( uv and tonumber( uv[3] ) or 16 ) / 16
				local v1 = ( uv and tonumber( uv[4] ) or 16 ) / 16
				for index = 1, 4 do
					local x, y, z, uf, vf = MC.ModelQuadVertex( quad, index )
					uf, vf = rotatedUVFlags( uf, vf, quad.rot or 0 )
					local offset = ( index - 1 ) * 5
					points[offset + 1], points[offset + 2], points[offset + 3] = x * BS, y * BS, z * BS
					points[offset + 4], points[offset + 5] = u0 + ( u1 - u0 ) * uf, v0 + ( v1 - v0 ) * vf
				end
				local normal = quadNormal( points, FACE_NORMALS[quad.face] or FACE_NORMALS[MC.Face.TOP], normalScratch )
				for triangleIndex = 1, 6 do
					local offset = ( TRI[triangleIndex] - 1 ) * 5
					VertexBuffer.PushValues( vertices, points[offset + 1], points[offset + 2], points[offset + 3],
						normal, points[offset + 4], points[offset + 5], color_white )
				end
			end
		end
	end )
	if not ok then
		AnimationStats.failures = AnimationStats.failures + 1
		return nil
	end
	if vertices.count < 3 then
		MeshCache[cacheKey] = false
		return false
	end
	local meshObject = uploadAnimationMesh( vertices )
	if not meshObject then return nil end
	MeshCache[cacheKey] = meshObject
	AnimationStats.modelBuilds = AnimationStats.modelBuilds + 1
	return meshObject
end

local FluidBlockIds = {}
local function fluidBlockId( kind )
	if FluidBlockIds[kind] ~= nil then return FluidBlockIds[kind] or nil end
	local fluid = FLUID_ANIMATIONS[kind]
	local schema = fluid and MC.BlockStateSchemaByName
		and MC.BlockStateSchemaByName["minecraft:" .. kind] or nil
	FluidBlockIds[kind] = schema and schema.blockId or false
	return FluidBlockIds[kind] or nil
end

local function fluidMeshesForChunk( chunkKey, animations )
	local cached = FluidMeshCache[chunkKey]
	if ( FluidEntryCounts[chunkKey] or 0 ) == 0 then return nil end
	if cached == false then return nil end
	if CurTime() < ( FluidMeshRetryAt[chunkKey] or 0 ) then return cached end
	if cached and ( not cached.geometryDirty or CurTime() < ( cached.retryAt or 0 ) ) then return cached end

	local availableKinds = {}
	local buckets = {}
	for _, kind in ipairs( FLUID_KIND_ORDER ) do
		local fluid = FLUID_ANIMATIONS[kind]
		if fluidBlockId( kind ) and animations[fluid.still] and animations[fluid.flow] then
			availableKinds[#availableKinds + 1] = kind
			buckets[fluid.still] = {}
			buckets[fluid.flow] = {}
		end
	end
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( chunkKey ) or MC.World and MC.World[chunkKey]
	if #availableKinds == 0 or not chunk then
		destroyFluidRecord( cached )
		FluidMeshCache[chunkKey] = false
		touchFluidMeshes()
		return nil
	end

	local originBX = ( chunk.cx or 0 ) * ( MC.CS or 16 )
	local originBY = ( chunk.cy or 0 ) * ( MC.CS or 16 )
	local originBZ = ( chunk.cz or 0 ) * ( MC.CH or 32 )
	local BS = blockSize()
	local waterMaterial
	if buckets.water_still then waterMaterial = currentWaterMaterial() end
	if waterMaterial == false then
		-- The resource owner reported the failure. Retain the complete old mesh
		-- and matching material until the next bounded preparation attempt.
		FluidMeshRetryAt[chunkKey] = CurTime() + REFRESH_INTERVAL
		return cached
	end
	RM.resetMeshLightingSampleCaches()
	RM.setMeshSampleCacheOrigin( originBX, originBY, originBZ )
	local vertexLimit = math.max( 3, math.floor( ( C.VERT_LIMIT or 64998 ) / 3 ) * 3 )
	local samples, copies = LightBuffer.New(), LightBuffer.NewCopyMap()
	local factory = RM.newLightMetaFactory( function( bx, by, bz )
		return bx - originBX + ( by - originBY ) * MC.CS + ( bz - originBZ ) * MC.CS * MC.CS
	end, samples )
	local context = { fluidCornerHeightCache = {}, waterColumnCache = {} }
	context.fluidAnimationResolver = function( _, faceIndex, u, v )
		-- FluidRenderer uses the still sprite for a motionless top and the
		-- bottom. Flowing tops rotate inside the central half of the 32x32
		-- sprite; every horizontal side samples that sprite's first half.
		local fluid = FLUID_ANIMATIONS[context.currentFluidKind]
		if not fluid then return nil, nil, nil end
		local flowingSide = faceIndex == MC.Face.XP or faceIndex == MC.Face.XN
			or faceIndex == MC.Face.YP or faceIndex == MC.Face.YN
		local flowingTop = faceIndex == MC.Face.TOP and context.flowingTop
		local flowing = flowingSide or flowingTop
		local name = flowing and fluid.flow or fluid.still
		if not animations[name] then return nil, nil, nil end
		-- EmitLiquidBlock stores the Java top rotation in the ordinary 0..16
		-- face-UV space, so the rotated top uses /16 to reach the flowing
		-- sprite's central half. Side UVs are ordinary full-face 0..16 values;
		-- Java maps those to the flowing sprite's first half with /32.
		local logicalSize = flowingTop and 16 or ( flowingSide and 32 or 16 )
		return ( tonumber( u ) or 0 ) / logicalSize,
			( tonumber( v ) or 0 ) / logicalSize, name
	end
	context.pushFluidValues = function( name, x, y, z, normal, u, v, color, light )
		local batches = buckets[name]
		if not batches then
			context.failed = true
			return
		end
		local batch = batches[#batches]
		if not batch or batch.verts.count >= vertexLimit then
			batch = { verts = VertexBuffer.New(), light = LightBuffer.New(),
				pbrWater = waterMaterial ~= nil and WATER_ANIMATIONS[name] == true }
			batches[#batches + 1] = batch
		end
		local sample = LightBuffer.CopySample( batch.light, samples, light, copies )
		if sample <= 0 then
			context.failed = true
			return
		end
		VertexBuffer.PushValues( batch.verts, x, y, z, normal, u, v, color )
		batch.light[batch.verts.count] = sample
	end
	context.push = function()
		context.failed = true
	end
	context.lightMeta = factory.fromCorner
	-- Emit the ordinary fluid geometry/light metadata. PBR water converts COLOR0
	-- once after emission; the published mesh always keeps its matching shader.
	context.currentEmitLightStyle = function() return RM.MC_LIGHT_STYLE_VANILLA or "vanilla" end

	local ok, emitted = MC.Try( "block_animation_emit", function()
		for entryKey in pairs( EntriesByChunk[chunkKey] or {} ) do
			local entry = Entries[entryKey]
			local stateId = entry and MC.GetBlockState and MC.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
			local kind = entry and fluidAnimationKind( stateId )
			local fluid = kind and FLUID_ANIMATIONS[kind] or nil
			local id = kind and fluidBlockId( kind ) or nil
			if entry and fluid and id and buckets[fluid.still] then
				local flowX, flowY = 0, 0
				if MC.LiquidFlowAtCell then
					flowX, flowY = MC.LiquidFlowAtCell( entry.bx, entry.by, entry.bz, kind )
				end
				flowX, flowY = tonumber( flowX ) or 0, tonumber( flowY ) or 0
				context.currentFluidKind = kind
				context.flowingTop = math.abs( flowX ) > 0.000001 or math.abs( flowY ) > 0.000001
				context.currentStateId = stateId
				LightBuffer.ResetScratch( samples )
				LightBuffer.ResetCopyMap( copies )
				local result = RM.EmitLiquidBlock(
					context, id, 0, entry.bx, entry.by, entry.bz,
					( entry.bx - originBX ) * BS,
					( entry.by - originBY ) * BS,
					( entry.bz - originBZ ) * BS,
					context.push, context.lightMeta, context.currentEmitLightStyle
				)
				if result == false or context.failed then return false end
			end
		end
		for _, batches in pairs( buckets ) do
			for _, batch in ipairs( batches ) do
				batch.fluidLight = RM.cacheFluidLightInputs( batch )
				if not batch.fluidLight then return false end
				if batch.pbrWater then
					MC.RenderPBRWater.BuildOptics( batch, context.waterColumnCache )
					local encoded = MC.RenderPBRWater.Recolor( batch, false )
					batch.fluidLight.published = encoded.colors
				end
			end
		end
		return true
	end )
	LightBuffer.ResetCopyMap( copies )
	if not ok or emitted ~= true then
		AnimationStats.failures = AnimationStats.failures + 1
		FluidMeshRetryAt[chunkKey] = CurTime() + REFRESH_INTERVAL
		if ok then MC.Fault( "block_animation_emit", "incomplete animated fluid geometry or light samples" ) end
		return cached
	end

	local halfXY, halfZ = MC.CS * BS * 0.5, MC.CH * BS * 0.5
	local record = { meshes = {}, lightBounds = { x = halfXY, y = halfXY, z = halfZ,
		radius = math.sqrt( halfXY * halfXY * 2 + halfZ * halfZ ) } }
	for name, batches in pairs( buckets ) do
		local meshList = {}
		record.meshes[name] = meshList
		for _, batch in ipairs( batches ) do
			if batch.verts.count >= 3 then
				batch.mesh = uploadAnimationMesh( batch.verts )
				if not batch.mesh then
					destroyFluidRecord( record )
					FluidMeshRetryAt[chunkKey] = CurTime() + REFRESH_INTERVAL
					return cached
				end
				batch.vertexCount = batch.verts.count
				meshList[#meshList + 1] = batch
			end
		end
		if #meshList == 0 then record.meshes[name] = nil end
	end
	if next( record.meshes ) == nil then
		destroyFluidRecord( cached )
		FluidMeshCache[chunkKey] = false
		touchFluidMeshes()
		return nil
	end
	-- Keep empty sprite kinds out of the draw loop, especially so water-only
	-- chunks don't push/pop the legacy point filter for an absent lava pass.
	for index = #availableKinds, 1, -1 do
		local fluid = FLUID_ANIMATIONS[availableKinds[index]]
		if not record.meshes[fluid.still] and not record.meshes[fluid.flow] then table.remove( availableKinds, index ) end
	end
	record.fluidKinds, record.matrix = availableKinds, Matrix()
	record.originBX, record.originBY, record.originBZ = originBX, originBY, originBZ
	record.chunk = chunk
	record.shadowBounds = { x = halfXY, y = halfXY, z = halfZ, hx = halfXY, hy = halfXY, hz = halfZ }
	record.blockSize, record.waterMaterial = BS, waterMaterial
	record.hasWater = record.meshes.water_still ~= nil or record.meshes.water_flow ~= nil
	record.cpuLight = not waterMaterial or record.meshes.lava_still ~= nil or record.meshes.lava_flow ~= nil
	record.lightmapRevision = MC.GlobalLightmapRevision
	record.nextLightmapAt = CurTime() + 0.1
	destroyFluidRecord( cached )
	FluidMeshCache[chunkKey] = record
	touchFluidMeshes()
	FluidMeshRetryAt[chunkKey] = nil
	AnimationStats.builds = AnimationStats.builds + 1
	return record
end

local function stageFluidLight( record, staged )
	if record.localLightDirty then
		RM.resetMeshLightingSampleCaches()
		RM.setMeshSampleCacheOrigin( record.originBX, record.originBY, record.originBZ )
	end
	for _, batches in pairs( record.meshes ) do
		for _, batch in ipairs( batches ) do
			if not batch.pbrWater or record.localLightDirty then
				local recolor = batch.pbrWater and MC.RenderPBRWater.Recolor or RM.recolorFluidEmission
				local ok, result = MC.Try( "block_animation_light", recolor,
					batch, record.localLightDirty == true )
				if not ok or not result then
					record.geometryDirty = true
					AnimationStats.failures = AnimationStats.failures + 1
					if ok then MC.Fault( "block_animation_light", "invalid light samples in an animated fluid batch" ) end
					return false
				end
				if result.changed then
					result.mesh = uploadAnimationMesh( batch.verts )
					if not result.mesh then return false end
				else
					AnimationStats.skippedLightUploads = AnimationStats.skippedLightUploads + 1
				end
				result.batch = batch
				staged[#staged + 1] = result
			end
		end
	end
	return true
end

local function refreshFluidLight( record )
	if not record.lightDirty or record.geometryDirty then return end
	if CurTime() < ( record.retryAt or 0 ) then return end
	-- Never rebuild a published IMesh in place. All sprite batches, including
	-- still/flow, must finish before this chunk switches to the new colours.
	local staged = {}
	local ok, result = pcall( stageFluidLight, record, staged )
	if not ok or result ~= true then
		for _, item in ipairs( staged ) do
			if item.mesh then item.mesh:Destroy() end
		end
		record.retryAt = CurTime() + REFRESH_INTERVAL
		if not ok then error( result, 0 ) end -- MC.Try/Fault already reported it.
		return
	end
	for _, item in ipairs( staged ) do
		if item.mesh then
			local previous = item.batch.mesh
			item.batch.mesh = item.mesh
			previous:Destroy()
		end
		item.palette.published = item.colors
		item.batch.fluidLight = item.palette
	end
	local counter = record.localLightDirty and "localLightRefreshes" or "globalLightRefreshes"
	AnimationStats[counter] = AnimationStats[counter] + 1
	record.retryAt = nil
	record.lightDirty = false
	record.localLightDirty = false
	record.lightmapRevision = MC.GlobalLightmapRevision
	record.nextLightmapAt = CurTime() + 0.1
	AnimationStats.lightRefreshes = AnimationStats.lightRefreshes + 1
end

local function materialForPath( path, translucent )
	local cacheKey = ( translucent and "translucent:" or "cutout:" ) .. path
	local cached = MaterialCache[cacheKey]
	if cached then return cached end
	local flags = translucent
		and "translucent nocull noclamp vertexcolor vertexalpha pointsample"
		or "alphatest nocull noclamp vertexcolor vertexalpha pointsample"
	cached = Material( path, flags )
	MaterialCache[cacheKey] = cached
	return cached
end

local function animationFrame( animation, elapsedTicks )
	local frames = animation.frames or {}
	if #frames == 0 then return nil, nil, 0 end
	local duration = animation.duration
	if not duration then
		duration = 0
		for _, frame in ipairs( frames ) do duration = duration + math.max( tonumber( frame.time ) or 1, 1 ) end
		animation.duration = math.max( duration, 1 )
	end
	local cursor = elapsedTicks % animation.duration
	for index, frame in ipairs( frames ) do
		local frameTime = math.max( tonumber( frame.time ) or 1, 1 )
		if cursor < frameTime then
			local nextFrame = frames[index % #frames + 1]
			return frame, nextFrame, cursor / frameTime
		end
		cursor = cursor - frameTime
	end
	return frames[1], frames[2] or frames[1], 0
end

local function entryColor( entry, center, emission )
	local now = CurTime()
	local frame, moving = FrameNumber(), #MC.RenderDynamicLights.active > 0
	if not entry.lightColor or now >= ( entry.nextLightAt or 0 ) or entry.lightEmission ~= emission
		or moving ~= entry.hadMovingLight or moving and entry.lightFrame ~= frame then
		local r, g, b = 1, 1, 1
		local worldCenter = MC.API.Coords.RenderToWorld( center )
		if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( worldCenter, emission ) end
		local color = entry.lightColor or Color( 255, 255, 255, 255 )
		color.r = math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 )
		color.g = math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 )
		color.b = math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 )
		entry.lightColor, entry.hadMovingLight, entry.lightFrame = color, moving, frame
		entry.lightEmission = emission
		entry.nextLightAt = now + 0.1
	end
	return entry.lightColor
end

local DEPTH_COLOR = Color( 255, 255, 255, 255 )
local function drawFrame( meshObject, frame, color, alpha, translucent, drawingDepth, localLight )
	if not frame or alpha <= 0 then return end
	local material = materialForPath( frame.material, translucent == true )
	if not material or material:IsError() then return end
	if drawingDepth then material = MC.RenderPBRSSR.DepthMaterial( material, true ) end
	render.SetMaterial( material )
	render.SetColorModulation( color.r / 255, color.g / 255, color.b / 255 )
	render.SetBlend( alpha )
	meshObject:Draw()
	if localLight and not drawingDepth then MC.RenderDynamicLights.Draw( material, meshObject, false, alpha ) end
end

local function drawAnimationMesh( meshObject, name, animation, color, elapsedTicks, drawingDepth, localLight )
	if not meshObject or type( animation ) ~= "table" then return end
	local frame, nextFrame, progress = animationFrame( animation, elapsedTicks )
	if not frame then return end
	local translucent = FLUID_ANIMATION_SET[name] == true
	local interpolate = animation.interpolate or SMOOTH_FLAME_ANIMATIONS[name] == true
	if drawingDepth then
		if translucent then return end
		-- Alpha-tested animation coverage uses the dominant frame. Fluids never
		-- enter the opaque scene depth used to trace reflections.
		if interpolate and nextFrame and progress >= 0.5 then frame = nextFrame end
		drawFrame( meshObject, frame, DEPTH_COLOR, 1, false, true )
		return
	end
	if interpolate and nextFrame and nextFrame.material ~= frame.material then
		drawFrame( meshObject, frame, color, 1 - progress, translucent, false, localLight )
		drawFrame( meshObject, nextFrame, color, progress, translucent, false, localLight )
	else
		drawFrame( meshObject, frame, color, 1, translucent, false, localLight )
	end
end

local function entryNeedsMeshes( entry )
	return entry.hasStateAnimation and ( not entry.animationMeshes or entry.meshStateId ~= entry.stateId
		or entry.meshSignature ~= entry.visualSignature or entry.meshRetryAt ~= nil )
end

local function fluidLightmapChanged( record )
	return record.cpuLight ~= false and record.lightmapRevision ~= MC.GlobalLightmapRevision
		and CurTime() >= ( record.nextLightmapAt or 0 )
end

function MC.BlockAnimationChunkHasEntries( key )
	return EntriesByChunk[key] ~= nil
end

function MC.BlockAnimationChunkPending( key )
	local record = FluidMeshCache[key]
	if type( record ) == "table" and ( record.geometryDirty or record.lightDirty or fluidLightmapChanged( record ) ) then return true end
	if ( FluidEntryCounts[key] or 0 ) > 0 and record == nil then return true end
	for entryKey in pairs( EntriesByChunk[key] or {} ) do
		local entry = Entries[entryKey]
		if entry and entryNeedsMeshes( entry ) then return true end
	end
	return false
end

-- Fluid geometry depends on neighbours; shared model templates do not.
function MC.MarkBlockAnimationFluidDirty( key )
	if ( FluidEntryCounts[key] or 0 ) <= 0 then return false end
	dirtyFluidChunk( key )
	return true
end

local function prepareEntry( entry, animations )
	local meshes = {}
	entry.meshRetryAt = nil
	for name, animation in pairs( animations ) do
		if type( animation ) == "table" and animation.tile ~= nil then
			local meshObject = meshForStateAnimation(
				entry.stateId, entry.bx, entry.by, entry.bz, name, animation, entry.visualSignature
			)
			if meshObject then meshes[#meshes + 1] = { mesh = meshObject, name = name, animation = animation } end
			if meshObject == nil then entry.meshRetryAt = CurTime() + REFRESH_INTERVAL end
		end
	end
	if not entry.meshRetryAt then
		entry.animationMeshes, entry.meshStateId, entry.meshSignature = meshes, entry.stateId, entry.visualSignature
	end
end

local animationMatrixPushed = false
local animationFilterMin, animationFilterMag = false, false
local function animationPointFilter( enabled )
	if enabled then
		if not animationFilterMin and render.PushFilterMin then
			render.PushFilterMin( TEXFILTER.POINT ) animationFilterMin = true
		end
		if not animationFilterMag and render.PushFilterMag then
			render.PushFilterMag( TEXFILTER.POINT ) animationFilterMag = true
		end
	else
		if animationFilterMag then render.PopFilterMag() animationFilterMag = false end
		if animationFilterMin then render.PopFilterMin() animationFilterMin = false end
	end
end

local function drawEntry( entry, elapsedTicks, drawingDepth )
	if not entry.animationMeshes then return end
	local base = MC.CellRenderMin and MC.CellRenderMin( entry.bx, entry.by, entry.bz )
		or MC.CellWorldMin( entry.bx, entry.by, entry.bz )
	local center = MC.CellRenderCenter and MC.CellRenderCenter( entry.bx, entry.by, entry.bz )
		or MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
	local emission = MC.BlockLightEmissionForState and MC.BlockLightEmissionForState(
		entry.stateId, entry.bx, entry.by, entry.bz ) or 0
	local color = drawingDepth and DEPTH_COLOR or entryColor( entry, center, emission )
	local matrix = entry.matrix or Matrix()
	entry.matrix = matrix
	matrix:SetTranslation( base )
	cam.PushModelMatrix( matrix )
	animationMatrixPushed = true
	for _, item in ipairs( entry.animationMeshes ) do
		drawAnimationMesh( item.mesh, item.name, item.animation, color, elapsedTicks, drawingDepth )
	end
	cam.PopModelMatrix()
	animationMatrixPushed = false
end

local function fluidChunkTransform( chunk, eye )
	if not chunk then return end
	local originBX = ( chunk.cx or 0 ) * ( MC.CS or 16 )
	local originBY = ( chunk.cy or 0 ) * ( MC.CS or 16 )
	local originBZ = ( chunk.cz or 0 ) * ( MC.CH or 32 )
	local BS = blockSize()
	local base = MC.CellRenderMin and MC.CellRenderMin( originBX, originBY, originBZ )
		or MC.CellWorldMin( originBX, originBY, originBZ )
	local chunkW = MC.ChunkWorld or BS * ( MC.CS or 16 )
	local chunkH = MC.ChunkWorldH or BS * ( MC.CH or 32 )
	local centerX, centerY, centerZ = base.x + chunkW * 0.5, base.y + chunkW * 0.5, base.z + chunkH * 0.5
	local distance = MC.EffectiveMeshDrawDistance and MC.EffectiveMeshDrawDistance() or 0
	if distance > 0 then
		local radius = math.sqrt( chunkW * chunkW * 0.5 + chunkH * chunkH * 0.25 )
		local maxDistance = distance + radius
		local dx, dy, dz = centerX - eye.x, centerY - eye.y, centerZ - eye.z
		local visible
		if MC.ChunkDrawDistanceVisible then
			visible = MC.ChunkDrawDistanceVisible( dx, dy, dz, maxDistance * maxDistance )
		else
			visible = dx * dx + dy * dy + dz * dz <= maxDistance * maxDistance
		end
		if visible == false then return end
	end
	return base, centerX, centerY, centerZ
end

local FLUID_LIGHT_COLOR = Color( 255, 255, 255, 255 )
local function drawFluidChunk( record, animations, elapsedTicks )
	local base = record.drawBase
	local lights = MC.RenderDynamicLights
	local localLight = lights.count > 0 and lights.AffectsBounds(
		base.x - lights.eyeX, base.y - lights.eyeY, base.z - lights.eyeZ, record.lightBounds )
	record.matrix:SetTranslation( base )
	cam.PushModelMatrix( record.matrix )
	animationMatrixPushed = true
	for _, kind in ipairs( record.fluidKinds or FLUID_KIND_ORDER ) do
		local fluid = FLUID_ANIMATIONS[kind]
		local blockId = fluidBlockId( kind )
		if fluid and blockId then
			local waterMaterial = kind == "water" and record.waterMaterial
			-- Let each PBR texture choose its own filter: smooth normal/IBL and
			-- POINT packed shadow depth. A global LINEAR override breaks shadows.
			animationPointFilter( not waterMaterial )
			for index = 1, 2 do
				local name = index == 1 and fluid.still or fluid.flow
				local batches = record.meshes[name]
				if batches then
					if waterMaterial then
						MC.RenderPBRWater.Bind( waterMaterial, record, base )
						render.SetMaterial( waterMaterial )
						render.SetColorModulation( 1, 1, 1 )
						render.SetBlend( 1 )
					end
					for _, batch in ipairs( batches ) do
						if waterMaterial then
							batch.mesh:Draw()
							if localLight then lights.Draw( waterMaterial, batch.mesh, false ) end
						else drawAnimationMesh( batch.mesh, name, animations[name], FLUID_LIGHT_COLOR, elapsedTicks, false, localLight ) end
					end
				end
			end
		end
	end
	cam.PopModelMatrix()
	animationMatrixPushed = false
end

local VisibleFluids = {}
local waterShadowBase = Vector()
-- Light-space visibility must not reuse the camera's VisibleFluids list.
-- Shadow rendering owns depth, material state and failure cleanup.
function MC.DrawWaterShadowCasters( view, shadow )
	if MC.RenderPackRuntime.atlasTransition then return end
	if LastGeneration ~= MC.StateWorldGeneration then return end
	local pending, stats = shadow.renderState, shadow.stats
	local blockSize = MC.API.Coords.BlockSize()
	local active = MC.RenderPackRuntime.active
	local waterMaterial = active and active.waterBinding and active.waterBinding.material
	for key, record in pairs( FluidMeshCache ) do
		if type( record ) == "table" and record.hasWater and record.waterMaterial
			and record.waterMaterial == waterMaterial
			and MC.GetChunkByKey( key ) == record.chunk and record.blockSize == blockSize
			and not ( MC.StreamHiddenChunkKeys and MC.StreamHiddenChunkKeys[key] ) then
			local x = record.originBX * record.blockSize + pending.frameX
			local y = record.originBY * record.blockSize + pending.frameY
			local z = record.originBZ * record.blockSize + pending.frameZ
			if MC.RenderShadowMath.Intersects( record.shadowBounds, x, y, z, view ) then
				local caster = shadow.CasterMaterial( record.waterMaterial, "world_translucent" )
				if caster then
					waterShadowBase.x, waterShadowBase.y, waterShadowBase.z = x, y, z
					record.matrix:SetTranslation( waterShadowBase )
					cam.PushModelMatrix( record.matrix )
					shadow.modelPushed = true
					render.SetMaterial( caster.material )
					for name in pairs( WATER_ANIMATIONS ) do
						local batches = record.meshes[name]
						for i = 1, batches and #batches or 0 do
							local batch = batches[i]
							batch.mesh:Draw()
							stats.draws, stats.vertices = stats.draws + 1, stats.vertices + batch.vertexCount
						end
					end
					cam.PopModelMatrix()
					shadow.modelPushed = false
				end
			end
		end
	end
end

local FluidLightMaterialKinds = {}
local function prepareFluidLightMaterials( animations, elapsedTicks )
	-- Resolve only the current/next visible sprite frames, before entering any
	-- render override. No eager loading of every animation frame or unused pack.
	local needed = FluidLightMaterialKinds
	for name in pairs( needed ) do needed[name] = nil end
	for _, record in ipairs( VisibleFluids ) do
		for name in pairs( record.meshes ) do
			if not ( record.waterMaterial and WATER_ANIMATIONS[name] ) then needed[name] = true end
		end
	end
	for name in pairs( needed ) do
		local animation = animations[name]
		if animation then
			local frame, nextFrame = animationFrame( animation, elapsedTicks )
			if frame then MC.RenderPackRuntime.PrepareSpriteLightMaterial( materialForPath( frame.material, true ), true ) end
			if nextFrame and animation.interpolate then
				MC.RenderPackRuntime.PrepareSpriteLightMaterial( materialForPath( nextFrame.material, true ), true )
			end
		end
	end
end

local function farFluidFirst( a, b )
	if a.drawDistance == b.drawDistance then return a.drawKey < b.drawKey end
	return a.drawDistance > b.drawDistance
end

local function collectVisibleFluids( eye )
	local count, water = 0, false
	for key in pairs( FluidEntryCounts ) do
		local record = FluidMeshCache[key]
		if type( record ) == "table" then
			local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
			local base, cx, cy, cz = fluidChunkTransform( chunk, eye )
			if base then
				count = count + 1
				record.drawBase, record.drawKey = base, key
				record.drawDistance = ( cx - eye.x ) ^ 2 + ( cy - eye.y ) ^ 2 + ( cz - eye.z ) ^ 2
				VisibleFluids[count] = record
				if record.hasWater and record.waterMaterial then water = true end
			end
		end
	end
	for index = #VisibleFluids, count + 1, -1 do VisibleFluids[index] = nil end
	if count > 1 then table.sort( VisibleFluids, farFluidFirst ) end
	return water
end

-- NeedsDepthPass runs before any colour hook. Gather from the current mesh
-- cache and render-space coordinates, not last frame's VisibleFluids list.
-- SSR immediately copies the selected records/bases before nested views can
-- reuse this list; the ordinary water draw still gathers its own view below.
function MC.CollectWaterSSRRecords( eye )
	if MC.RenderPackRuntime.atlasTransition then return end
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	if collectVisibleFluids( eye ) then return VisibleFluids end
end

local function clearFluidMeshes()
	for _, record in pairs( FluidMeshCache ) do destroyFluidRecord( record ) end
	for index = #VisibleFluids, 1, -1 do VisibleFluids[index] = nil end
	FluidMeshCache = {}
	FluidMeshRetryAt = {}
	FluidMeshesDirty = false
	touchFluidMeshes()
end

local function clearMeshes()
	for _, meshObject in pairs( MeshCache ) do
		if meshObject and meshObject ~= false and meshObject.Destroy then meshObject:Destroy() end
	end
	MeshCache = {}
	clearFluidMeshes()
end

-- Called once at the resource commit boundary, after the terrain runtime has
-- bound its candidate. This also handles same-name reloads without waiting
-- for the ordinary animation scan interval.
function MC.PrepareResourcePackAnimations()
	clearEntries()
	clearMeshes()
	refreshChunks()
	local animations = activeAnimations()
	if not generationOwnsAnimation() or not animations.water_still then return true end
	for key in pairs(FluidEntryCounts) do
		fluidMeshesForChunk(key, animations)
		if FluidMeshRetryAt[key] then return false, "resource_pack_water_mesh" end
	end
	return true
end

local function prepareAnimationWork( budget, canBuild, prepare, ... )
	if not canBuild( budget, false ) then
		AnimationStats.budgetYields = AnimationStats.budgetYields + 1
		return false
	end
	budget.attempts = budget.attempts + 1
	budget.animationAttempts = budget.animationAttempts + 1
	AnimationStats.attempts = AnimationStats.attempts + 1
	local started, failures = SysTime(), AnimationStats.failures
	prepare( ... )
	local elapsed = ( SysTime() - started ) * 1000
	AnimationStats.workMS = AnimationStats.workMS + elapsed
	local category = prepare == fluidMeshesForChunk and "fluidBuildMS"
		or prepare == refreshFluidLight and "fluidLightMS" or "modelMS"
	AnimationStats[category] = AnimationStats[category] + elapsed
	if AnimationStats.failures > failures then
		budget.failures = budget.failures + 1
		budget.animationFailures = budget.animationFailures + 1
	end
	return true
end

-- Local light changes run beside the terrain atlas upload, before background
-- scans/builds. A geometry-dirty fluid must publish current geometry as well.
local function prepareLocalFluidLighting( key, record, budget, canBuild, animations, now, eye )
	if type( record ) ~= "table" or not record.localLightDirty then return true end
	if now < ( FluidMeshRetryAt[key] or 0 ) or now < ( record.retryAt or 0 ) then return true end
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
	if not fluidChunkTransform( chunk, eye ) then return true end
	if not MC.Check( type( MC.SampleGlobalLightmapRGB ) == "function",
		"block_animation_lightmap_missing", "cl_mesh_global_lightmap.lua did not load" ) then return false end
	if record.geometryDirty then
		return prepareAnimationWork( budget, canBuild, fluidMeshesForChunk, key, animations )
	end
	return prepareAnimationWork( budget, canBuild, refreshFluidLight, record )
end

function MC.PrepareBlockAnimationLighting( budget, canBuild, chunkKey )
	if next( FluidMeshCache ) == nil then return end
	if chunkKey ~= nil then
		local record = FluidMeshCache[chunkKey]
		if type( record ) ~= "table" or not record.localLightDirty then return end
	end
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	if MC.GlobalLightmapRevision == 0 then return end
	local animations = activeAnimations()
	if next( animations ) == nil then return end
	local now, eye = CurTime(), EyePos()
	if chunkKey ~= nil then
		return prepareLocalFluidLighting( chunkKey, FluidMeshCache[chunkKey], budget, canBuild, animations, now, eye )
	end
	for key, record in pairs( FluidMeshCache ) do
		if not prepareLocalFluidLighting( key, record, budget, canBuild, animations, now, eye ) then return end
	end
end

-- The scheduler owns the deadline. Each model instance or fluid chunk is an
-- indivisible attempt; drawing only consumes the last published mesh buffers.
function MC.PrepareBlockAnimations( budget, canBuild )
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	local waterStyle = currentWaterMaterial()
	if waterStyle ~= false and (waterStyle ~= nil) ~= LastWaterStyle then
		LastWaterStyle = waterStyle ~= nil
		for key,record in pairs(FluidMeshCache) do
			if record == false then FluidMeshCache[key]=nil
			elseif record.hasWater then record.geometryDirty=true end
		end
	end
	local now = CurTime()
	if now >= LastRefresh then
		if not canBuild( budget, false ) then
			AnimationStats.budgetYields = AnimationStats.budgetYields + 1
			return
		end
		LastRefresh = now + REFRESH_INTERVAL
		local started = SysTime()
		refreshChunks()
		if FluidMeshesDirty then clearFluidMeshes() end
		AnimationStats.scanPasses = AnimationStats.scanPasses + 1
		AnimationStats.scanMS = AnimationStats.scanMS + ( SysTime() - started ) * 1000
	end
	local animations = activeAnimations()
	if next( animations ) == nil then return end
	local eye = EyePos()
	local maxRenderDistanceSqr = ( blockSize() * 96 ) ^ 2
	for _, entry in pairs( ModelEntries ) do
		if entryNeedsMeshes( entry ) and now >= ( entry.meshRetryAt or 0 ) then
			local center = MC.CellRenderCenter and MC.CellRenderCenter( entry.bx, entry.by, entry.bz )
				or MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
			if eye:DistToSqr( center ) <= maxRenderDistanceSqr
				and not prepareAnimationWork( budget, canBuild, prepareEntry, entry, animations ) then return end
		end
	end
	if next( FluidEntryCounts ) == nil then return end
	if not MC.Check( type( MC.SampleGlobalLightmapRGB ) == "function",
		"block_animation_lightmap_missing", "cl_mesh_global_lightmap.lua did not load" ) then return end
	-- The RT is initialized in Think; do not publish unlit fluid colours if
	-- the scheduler runs first. Later changes recolour under this same budget.
	if MC.GlobalLightmapRevision == 0 then return end
	local waterMaterial = currentWaterMaterial()
	local size = blockSize()
	for key in pairs( FluidEntryCounts ) do
		local record = FluidMeshCache[key]
		if type( record ) == "table" and waterMaterial ~= false then
			if record.blockSize ~= size or record.hasWater
				and ( record.waterMaterial ~= nil ) ~= ( waterMaterial ~= nil ) then
				record.geometryDirty = true
			elseif record.hasWater and waterMaterial then record.waterMaterial = waterMaterial end
		end
		if type( record ) == "table" and fluidLightmapChanged( record ) then record.lightDirty = true end
		local geometryDirty = record == nil or type( record ) == "table" and record.geometryDirty
		local lightDirty = type( record ) == "table" and record.lightDirty
		if ( geometryDirty or lightDirty ) and now >= ( FluidMeshRetryAt[key] or 0 )
			and ( type( record ) ~= "table" or now >= ( record.retryAt or 0 ) ) then
			local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
			if fluidChunkTransform( chunk, eye ) then
				if geometryDirty then
					if not prepareAnimationWork( budget, canBuild, fluidMeshesForChunk, key, animations ) then return end
				elseif not prepareAnimationWork( budget, canBuild, refreshFluidLight, record ) then
					return
				end
			end
		end
	end
end

hook.Remove( "Think", "mc_block_animation_chunk_scan" )

-- Render space is world space plus the chunk render-frame translation, so the
-- per-entry range test of every animated block needs no Vector per frame.
local function drawEntriesInRange( eye, elapsedTicks, drawingDepth )
	local size = blockSize()
	local half, maxRenderDistanceSqr = size * 0.5, ( size * 96 ) ^ 2
	local ox, oy, oz = MC.ChunkRenderFrameOffset()
	local wx, wy, wz = eye.x - ox - half, eye.y - oy - half, eye.z - oz - half
	for _, entry in pairs( ModelEntries ) do
		local dx, dy, dz = entry.bx * size - wx, entry.by * size - wy, entry.bz * size - wz
		if dx * dx + dy * dy + dz * dz <= maxRenderDistanceSqr then drawEntry( entry, elapsedTicks, drawingDepth ) end
	end
end

local function drawPreparedAnimations( animations, eye, elapsedTicks, water, view )
	drawEntriesInRange( eye, elapsedTicks )
	if water then
		animationPointFilter( false )
		MC.RenderPBRWater.CaptureRefraction( view, VisibleFluids )
	end
	-- Fluid colour passes test opaque depth but must never populate it. In
	-- particular, interpolated frames draw the same surface more than once.
	render.OverrideDepthEnable( true, false )
	for _, record in ipairs( VisibleFluids ) do
		drawFluidChunk( record, animations, elapsedTicks )
	end
end

hook.Add( "PostDrawTranslucentRenderables", "mc_block_animations", function( bDepth, _, bSky3D )
	if MC.RenderPackRuntime.atlasTransition then return end
	-- bSky can also be true in the main view on maps with a 2D skybox.
	if bDepth or bSky3D or MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	if MC.RenderPBRShadows and MC.RenderPBRShadows.rendering then return end
	local animations = activeAnimations()
	if next( animations ) == nil then return end
	if not MC.Check( type( render.OverrideDepthEnable ) == "function"
		and type( render.OverrideColorWriteEnable ) == "function",
		"block_animation_render_state", "depth/color-write override APIs are unavailable" ) then return end
	local eye = EyePos()
	local view = render.GetViewSetup and render.GetViewSetup( true )
	if view and view.origin then eye = view.origin end
	local water = collectVisibleFluids( eye )
	local elapsedTicks = ( RealTime and RealTime() or CurTime() ) / TICK_SECONDS
	local prepared, prepareError = pcall( prepareFluidLightMaterials, animations, elapsedTicks )
	if not prepared then MC.Fault( "fluid_dynamic_light_prepare", "%s", tostring( prepareError ) ) end
	-- Vanilla fluids and CPU-lit animations need the same current-view sources.
	if not MC.RenderPBR.PrepareDraw( eye.x, eye.y, eye.z, view, false ) then return end
	if water then
		-- Shadow/view preparation can render another view; do it before touching
		-- any animation matrix, depth override, or texture filter.
		MC.RenderPBRWater.PrepareView()
	end
	render.OverrideDepthEnable( false, false )
	render.OverrideColorWriteEnable( false, false )
	animationPointFilter( true )
	local ok, err = pcall( drawPreparedAnimations, animations, eye, elapsedTicks, water, view )
	-- Clean up before Fault: strict mode may throw, and a failed Draw must not
	-- leave later hooks using our matrix, depth override or texture filters.
	if animationMatrixPushed then
		cam.PopModelMatrix()
		animationMatrixPushed = false
	end
	render.OverrideDepthEnable( false, false )
	render.OverrideColorWriteEnable( false, false )
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	animationPointFilter( false )
	if not ok then MC.Fault( "block_animation_draw", "%s", tostring( err ) ) end
end )

local function drawAnimationDepth( eye, elapsedTicks )
	if generationOwnsAnimation() then return end
	drawEntriesInRange( eye, elapsedTicks, true )
end

hook.Remove( "PostDrawOpaqueRenderables", "mc_block_animation_depth" )
MC.RenderPBRSSR.RegisterDepthRenderer( "animations", function( view )
	if not MC.RenderPBRSSR.BeginDepth() then return end
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	animationPointFilter( true )
	render.OverrideDepthEnable( false, false )
	render.OverrideColorWriteEnable( true, true )
	local ok, err = pcall( drawAnimationDepth, view.origin, RealTime() / TICK_SECONDS )
	if animationMatrixPushed then cam.PopModelMatrix() animationMatrixPushed = false end
	render.OverrideDepthEnable( false, false )
	render.OverrideColorWriteEnable( false, false )
	render.SetBlend( 1 ) render.SetColorModulation( 1, 1, 1 )
	animationPointFilter( false )
	if not ok then
		error( { code = "block_animation_depth", message = tostring( err ) }, 0 )
	end
end )

hook.Add( "MCWorldAdapterChanged", "mc_block_animation_world_frame", function()
	MC.MarkAllBlockAnimationLightDirty()
end )
hook.Add( "MC.ClientBlockStateChanged", "mc_block_animation_fluid_geometry", function( bx, by, bz, _, stateId, reason )
	local key = chunkKeyForCell( bx, by, bz )
	updateCellEntry( bx, by, bz, stateId or MC.GetBlockState( bx, by, bz ) )
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
	local scanned = ScannedChunkVersions[key]
	-- Only a consecutive storage event can acknowledge a scan. A missed bulk
	-- update or replaced chunk must still go through the full refresh path.
	if reason == "storage_write" and scanned and scanned.chunk == chunk
		and chunk.collisionVersion == scanned.version + 1 then
		scanned.version = chunk.collisionVersion
	end
	-- FluidRenderer samples a 3x3 horizontal neighbourhood plus occluding
	-- blocks above/beside it. Invalidate only chunks containing those cells.
	local minX, minY, minZ = MC.CellToChunk( bx - 1, by - 1, bz - 1 )
	local maxX, maxY, maxZ = MC.CellToChunk( bx + 1, by + 1, bz + 1 )
	for z = minZ, maxZ do
		for y = minY, maxY do
			for x = minX, maxX do dirtyFluidChunk( MC.ChunkKey( x, y, z ) ) end
		end
	end
	-- Optical depth also depends on the bed below the visible surface. Geometry
	-- neighbours alone miss edits more than one cell below a chunk boundary.
	if MC.RenderPBRWater then
		local _, _, waterMaxZ = MC.CellToChunk( bx, by, bz + MC.RenderPBRWater.MAX_DEPTH )
		for z = maxZ + 1, waterMaxZ do
			for y = minY, maxY do
				for x = minX, maxX do
					local record = FluidMeshCache[MC.ChunkKey( x, y, z )]
					if type( record ) == "table" and record.waterMaterial then record.geometryDirty = true end
				end
			end
		end
	end
end )

function MC.BlockAnimationStats( validate )
	local out = {
		chunks = 0, batches = 0, vertices = 0, invalid = 0, geometryDirty = 0, lightDirty = 0,
		modelEntries = 0, pendingModels = 0, unbuiltChunks = 0,
	}
	for key, value in pairs( AnimationStats ) do out[key] = value end
	for _, entry in pairs( ModelEntries ) do
		out.modelEntries = out.modelEntries + 1
		if entryNeedsMeshes( entry ) then out.pendingModels = out.pendingModels + 1 end
	end
	for key in pairs( FluidEntryCounts ) do
		if FluidMeshCache[key] == nil then out.unbuiltChunks = out.unbuiltChunks + 1 end
	end
	for _, record in pairs( FluidMeshCache ) do
		if type( record ) == "table" then
			out.chunks = out.chunks + 1
			if record.geometryDirty then out.geometryDirty = out.geometryDirty + 1 end
			if record.lightDirty then out.lightDirty = out.lightDirty + 1 end
			for _, batches in pairs( record.meshes ) do
				for _, batch in ipairs( batches ) do
					out.batches = out.batches + 1
					out.vertices = out.vertices + batch.vertexCount
					if validate and ( not VertexBuffer.Validate( batch.verts ) or not LightBuffer.Validate( batch.light ) ) then
						out.invalid = out.invalid + 1
					end
				end
			end
		end
	end
	return out
end
hook.Add( "MC.ClientWorldProjectionChanged", "mc_block_animation_world_projection", function( reason )
	-- Block-entity data never changes a state or fluid; a full rescan and fluid
	-- mesh rebuild here would repeat for every sign, chest or furnace update.
	if reason == "block_entity_changed" then return end
	clearEntries()
	clearFluidMeshes()
end )
hook.Add( "ShutDown", "mc_block_animation_cleanup", clearMeshes )
hook.Add( "OnReloaded", "mc_block_animation_reload", function()
	clearMeshes()
	clearEntries()
	ModelAnimationSignatures = {}
end )
