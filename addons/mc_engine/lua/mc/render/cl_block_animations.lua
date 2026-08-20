-- Client-only dynamic block texture layer.
--
-- Minecraft sprites such as fire, lit campfire logs, water and lava are vertical PNG
-- frame strips driven by .mcmeta. Source does not understand that format, so
-- the atlas builder keeps those atlas slots transparent and emits the Java
-- frames separately. Block animations reuse generated model quads; fluids reuse
-- RM.EmitLiquidBlock, whose geometry/occlusion/flow UV rules mirror Java's
-- FluidRenderer. Both paths remain independent of the Lua/native chunk backend.

MC = MC or {}

local RM = MC.RenderMesh or {}
local C = MC.RenderMeshConstants or {}
local BS = MC.BS or 36.5
local TICK_SECONDS = 1 / 20
local REFRESH_INTERVAL = 0.25
local MAX_RENDER_DISTANCE_SQR = ( BS * 96 ) ^ 2
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
local EntriesByChunk = {}
local ScannedChunkVersions = {}
local MeshCache = {}
local FluidMeshCache = {}
local MaterialCache = {}
local FluidMeshesDirty = false
local LastRefresh = 0
local LastGeneration = tonumber( MC.StateWorldGeneration ) or 0
local LastAnimationPack

local function animationPacks()
	return MC.GeneratedBlockAnimationsByPack or {}
end

local function activePackName()
	return MC.TexturePackName and MC.TexturePackName() or MC.ActiveTexturePack or "default"
end

local function activeAnimations()
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
	Entries[key] = nil
	local chunkEntries = EntriesByChunk[entry.chunkKey]
	if chunkEntries then
		chunkEntries[key] = nil
		if next( chunkEntries ) == nil then EntriesByChunk[entry.chunkKey] = nil end
	end
end

local function removeChunkEntries( chunkKey )
	for key in pairs( EntriesByChunk[chunkKey] or {} ) do Entries[key] = nil end
	EntriesByChunk[chunkKey] = nil
end

local function stateAnimationSignature( stateId, bx, by, bz )
	local found = false
	local signatureParts = {}
	local byTile = animationsByTile()
	if not ( MC.VisitStateVisualModels and MC.StateVisualModelData and MC.BlockModelSurface ) then return false end
	MC.VisitStateVisualModels( stateId, bx, by, bz, function( modelId )
		local model = MC.StateVisualModelData( modelId )
		for _, quad in ipairs( model and model.modelQuads or {} ) do
			local tile = MC.BlockModelSurface( model, quad )
			if byTile[tile] then
				found = true
				signatureParts[#signatureParts + 1] = tostring( modelId ) .. "/" .. tostring( tile )
			end
		end
	end )
	return found, table.concat( signatureParts, "," )
end

local function fluidAnimationKind( stateId )
	if not MC.LiquidKindForState then return nil end
	local kind = MC.LiquidKindForState( stateId )
	return FLUID_ANIMATIONS[kind] and kind or nil
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
	entry.stateId = stateId
	entry.chunkKey = chunkKey
	entry.hasStateAnimation = hasStateAnimation == true
	entry.visualSignature = visualSignature
	entry.fluidKind = fluidKind
	entry.nextLightAt = 0
	return entry
end

local function scanChunk( key, chunk )
	if ScannedChunkVersions[key] then FluidMeshesDirty = true end
	removeChunkEntries( key )
	if MC.ForEachBlockState then
		MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
			local hasStateAnimation, visualSignature = stateAnimationSignature( stateId, bx, by, bz )
			local fluidKind = fluidAnimationKind( stateId )
			if hasStateAnimation or fluidKind then
				addEntry( bx, by, bz, stateId, hasStateAnimation, visualSignature, fluidKind )
			end
		end )
	end
	ScannedChunkVersions[key] = { chunk = chunk, version = chunk.collisionVersion or 0 }
end

local function clearEntries()
	Entries = {}
	EntriesByChunk = {}
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
	end
	for key, scanned in pairs( ScannedChunkVersions ) do
		local current = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
		if current ~= scanned.chunk then
			removeChunkEntries( key )
			ScannedChunkVersions[key] = nil
			FluidMeshesDirty = true
		end
	end
	for key, chunk in pairs( MC.World or {} ) do
		local scanned = ScannedChunkVersions[key]
		local version = chunk.collisionVersion or 0
		if not scanned or scanned.chunk ~= chunk or scanned.version ~= version then scanChunk( key, chunk ) end
	end
end

local function rotatedUVFlags( u, v, rotation )
	rotation = ( rotation or 0 ) % 4
	if rotation == 1 then return v, 1 - u end
	if rotation == 2 then return 1 - u, 1 - v end
	if rotation == 3 then return 1 - v, u end
	return u, v
end

local function quadNormal( points, fallback )
	local normal = ( points[2] - points[1] ):Cross( points[3] - points[1] )
	if normal:LengthSqr() <= 0.000001 then return fallback end
	normal:Normalize()
	return normal
end

local function meshForStateAnimation( stateId, bx, by, bz, animationName, animation, visualSignature )
	local cacheKey = activePackName() .. ":" .. tostring( stateId ) .. ":"
		.. tostring( visualSignature or 0 ) .. ":" .. tostring( animationName )
	local cached = MeshCache[cacheKey]
	if cached ~= nil then return cached ~= false and cached or nil end

	local vertices = {}
	MC.VisitStateVisualModels( stateId, bx, by, bz, function( modelId )
		local model = MC.StateVisualModelData( modelId )
		for _, quad in ipairs( model and model.modelQuads or {} ) do
			local tile = MC.BlockModelSurface( model, quad )
			if tile == animation.tile then
				local uv = quad.uv
				local u0 = ( uv and tonumber( uv[1] ) or 0 ) / 16
				local v0 = ( uv and tonumber( uv[2] ) or 0 ) / 16
				local u1 = ( uv and tonumber( uv[3] ) or 16 ) / 16
				local v1 = ( uv and tonumber( uv[4] ) or 16 ) / 16
				local points, uvs = {}, {}
				for index = 1, 4 do
					local x, y, z, uf, vf = MC.ModelQuadVertex( quad, index )
					uf, vf = rotatedUVFlags( uf, vf, quad.rot or 0 )
					points[index] = Vector( x * BS, y * BS, z * BS )
					uvs[index] = { u0 + ( u1 - u0 ) * uf, v0 + ( v1 - v0 ) * vf }
				end
				local normal = quadNormal( points, FACE_NORMALS[quad.face] or FACE_NORMALS[MC.Face.TOP] )
				for triangleIndex = 1, 6 do
					local source = TRI[triangleIndex]
					vertices[#vertices + 1] = {
						pos = points[source], normal = normal,
						u = uvs[source][1], v = uvs[source][2],
						color = color_white,
					}
				end
			end
		end
	end )
	if #vertices < 3 then
		MeshCache[cacheKey] = false
		return nil
	end
	local meshObject = Mesh()
	meshObject:BuildFromTriangles( vertices )
	MeshCache[cacheKey] = meshObject
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
	if cached ~= nil then return cached ~= false and cached or nil end
	if not RM.EmitLiquidBlock then
		FluidMeshCache[chunkKey] = false
		return nil
	end

	local availableKinds = {}
	local buckets = {}
	for _, kind in ipairs( FLUID_KIND_ORDER ) do
		local fluid = FLUID_ANIMATIONS[kind]
		if fluidBlockId( kind ) and animations[fluid.still] and animations[fluid.flow] then
			availableKinds[#availableKinds + 1] = kind
			buckets[fluid.still] = { {} }
			buckets[fluid.flow] = { {} }
		end
	end
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( chunkKey ) or MC.World and MC.World[chunkKey]
	if #availableKinds == 0 or not chunk then
		FluidMeshCache[chunkKey] = false
		return nil
	end

	local originBX = ( chunk.cx or 0 ) * ( MC.CS or 16 )
	local originBY = ( chunk.cy or 0 ) * ( MC.CS or 16 )
	local originBZ = ( chunk.cz or 0 ) * ( MC.CH or 32 )
	local vertexLimit = C.VERT_LIMIT or 64998
	local context = { fluidCornerHeightCache = {} }
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
	context.push = function( vertex )
		local batches = buckets[vertex.fluidAnimation]
		if not batches then return end
		local vertices = batches[#batches]
		if #vertices >= vertexLimit then
			vertices = {}
			batches[#batches + 1] = vertices
		end
		vertices[#vertices + 1] = {
			pos = vertex.pos,
			normal = vertex.normal,
			u = vertex.u,
			v = vertex.v,
			color = vertex.color or color_white,
		}
	end
	context.lightMeta = function() return nil end
	context.currentEmitLightStyle = function() return RM.MC_LIGHT_STYLE_VANILLA or "vanilla" end

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
			RM.EmitLiquidBlock(
				context, id, 0, entry.bx, entry.by, entry.bz,
				( entry.bx - originBX ) * BS,
				( entry.by - originBY ) * BS,
				( entry.bz - originBZ ) * BS,
				context.push, context.lightMeta, context.currentEmitLightStyle
			)
		end
	end

	local meshes = {}
	for name, batches in pairs( buckets ) do
		local meshList = {}
		for _, vertices in ipairs( batches ) do
			if #vertices >= 3 then
				local meshObject = Mesh()
				meshObject:BuildFromTriangles( vertices )
				meshList[#meshList + 1] = meshObject
			end
		end
		if #meshList > 0 then meshes[name] = meshList end
	end
	if next( meshes ) == nil then
		FluidMeshCache[chunkKey] = false
		return nil
	end
	local record = {
		meshes = meshes,
		fluidKinds = availableKinds,
		matrix = Matrix(),
		originBX = originBX,
		originBY = originBY,
		originBZ = originBZ,
		nextLightAt = 0,
	}
	FluidMeshCache[chunkKey] = record
	return record
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

local function entryColor( entry, center, emission, channel )
	local now = CurTime()
	if channel then
		entry.lightColors = entry.lightColors or {}
		entry.lightEmissions = entry.lightEmissions or {}
		entry.nextLightAtByChannel = entry.nextLightAtByChannel or {}
		if not entry.lightColors[channel]
		or now >= ( entry.nextLightAtByChannel[channel] or 0 )
		or entry.lightEmissions[channel] ~= emission then
			local r, g, b = 1, 1, 1
			if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( center, emission ) end
			entry.lightColors[channel] = Color(
				math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 ),
				math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 ),
				math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 ), 255
			)
			entry.lightEmissions[channel] = emission
			entry.nextLightAtByChannel[channel] = now + 0.1
		end
		return entry.lightColors[channel]
	end
	if not entry.lightColor or now >= ( entry.nextLightAt or 0 ) or entry.lightEmission ~= emission then
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( center, emission ) end
		entry.lightColor = Color(
			math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 ), 255
		)
		entry.lightEmission = emission
		entry.nextLightAt = now + 0.1
	end
	return entry.lightColor
end

local function drawFrame( meshObject, frame, color, alpha, translucent )
	if not frame or alpha <= 0 then return end
	local material = materialForPath( frame.material, translucent == true )
	if not material or material:IsError() then return end
	render.SetMaterial( material )
	render.SetColorModulation( color.r / 255, color.g / 255, color.b / 255 )
	render.SetBlend( alpha )
	meshObject:Draw()
end

local function drawAnimationMesh( meshObject, name, animation, color, elapsedTicks )
	if not meshObject or type( animation ) ~= "table" then return end
	local frame, nextFrame, progress = animationFrame( animation, elapsedTicks )
	if not frame then return end
	local translucent = FLUID_ANIMATION_SET[name] == true
	local interpolate = animation.interpolate or SMOOTH_FLAME_ANIMATIONS[name] == true
	if interpolate and nextFrame and nextFrame.material ~= frame.material then
		drawFrame( meshObject, frame, color, 1 - progress, translucent )
		drawFrame( meshObject, nextFrame, color, progress, translucent )
	else
		drawFrame( meshObject, frame, color, 1, translucent )
	end
end

local function drawEntry( entry, stateId, animations, elapsedTicks, visualSignature )
	local base = MC.CellRenderMin and MC.CellRenderMin( entry.bx, entry.by, entry.bz )
		or MC.CellWorldMin( entry.bx, entry.by, entry.bz )
	local center = MC.CellRenderCenter and MC.CellRenderCenter( entry.bx, entry.by, entry.bz )
		or MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
	local emission = MC.BlockLightEmissionForState and MC.BlockLightEmissionForState(
		stateId, entry.bx, entry.by, entry.bz ) or 0
	local color = entryColor( entry, center, emission )
	local matrix = entry.matrix or Matrix()
	entry.matrix = matrix
	matrix:SetTranslation( base )
	cam.PushModelMatrix( matrix )
	for name, animation in pairs( animations ) do
		if type( animation ) == "table" and animation.tile ~= nil then
			local meshObject = meshForStateAnimation(
				stateId, entry.bx, entry.by, entry.bz, name, animation, visualSignature
			)
			drawAnimationMesh( meshObject, name, animation, color, elapsedTicks )
		end
	end
	cam.PopModelMatrix()
end

local function drawFluidChunk( chunkKey, animations, elapsedTicks, eye )
	local chunk = MC.GetChunkByKey and MC.GetChunkByKey( chunkKey ) or MC.World and MC.World[chunkKey]
	if not chunk then return end
	local originBX = ( chunk.cx or 0 ) * ( MC.CS or 16 )
	local originBY = ( chunk.cy or 0 ) * ( MC.CS or 16 )
	local originBZ = ( chunk.cz or 0 ) * ( MC.CH or 32 )
	local base = MC.CellRenderMin and MC.CellRenderMin( originBX, originBY, originBZ )
		or MC.CellWorldMin( originBX, originBY, originBZ )
	local chunkW = MC.ChunkWorld or BS * ( MC.CS or 16 )
	local chunkH = MC.ChunkWorldH or BS * ( MC.CH or 32 )
	local center = base + Vector( chunkW * 0.5, chunkW * 0.5, chunkH * 0.5 )
	local distance = MC.EffectiveMeshDrawDistance and MC.EffectiveMeshDrawDistance() or 0
	if distance > 0 then
		local radius = math.sqrt( chunkW * chunkW * 0.5 + chunkH * chunkH * 0.25 )
		local maxDistance = distance + radius
		local dx, dy, dz = center.x - eye.x, center.y - eye.y, center.z - eye.z
		local visible
		if MC.ChunkDrawDistanceVisible then
			visible = MC.ChunkDrawDistanceVisible( dx, dy, dz, maxDistance * maxDistance )
		else
			visible = dx * dx + dy * dy + dz * dz <= maxDistance * maxDistance
		end
		if visible == false then return end
	end

	local record = fluidMeshesForChunk( chunkKey, animations )
	if not record then return end
	record.matrix:SetTranslation( base )
	cam.PushModelMatrix( record.matrix )
	for _, kind in ipairs( record.fluidKinds or FLUID_KIND_ORDER ) do
		local fluid = FLUID_ANIMATIONS[kind]
		local blockId = fluidBlockId( kind )
		if fluid and blockId then
			local emission = MC.BlockLightEmission and MC.BlockLightEmission( blockId ) or 0
			local fluidColor = entryColor( record, center, emission, kind )
			for _, name in ipairs( { fluid.still, fluid.flow } ) do
				for _, meshObject in ipairs( record.meshes[name] or {} ) do
					drawAnimationMesh( meshObject, name, animations[name], fluidColor, elapsedTicks )
				end
			end
		end
	end
	cam.PopModelMatrix()
end

local function clearFluidMeshes()
	for _, record in pairs( FluidMeshCache ) do
		if type( record ) == "table" and type( record.meshes ) == "table" then
			for _, meshList in pairs( record.meshes ) do
				for _, meshObject in ipairs( meshList ) do
					if meshObject and meshObject.Destroy then meshObject:Destroy() end
				end
			end
		end
	end
	FluidMeshCache = {}
	FluidMeshesDirty = false
end

local function clearMeshes()
	for _, meshObject in pairs( MeshCache ) do
		if meshObject and meshObject ~= false and meshObject.Destroy then meshObject:Destroy() end
	end
	MeshCache = {}
	clearFluidMeshes()
end

hook.Add( "Think", "mc_block_animation_chunk_scan", function()
	if CurTime() < LastRefresh then return end
	LastRefresh = CurTime() + REFRESH_INTERVAL
	refreshChunks()
	if FluidMeshesDirty then clearFluidMeshes() end
end )

hook.Add( "PostDrawTranslucentRenderables", "mc_block_animations", function( _, _, bSky3D )
	if bSky3D or MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	local animations = activeAnimations()
	if next( animations ) == nil then return end
	local eye = EyePos()
	local elapsedTicks = ( RealTime and RealTime() or CurTime() ) / TICK_SECONDS
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	for key, entry in pairs( Entries ) do
		if entry.hasStateAnimation then
			local center = MC.CellRenderCenter and MC.CellRenderCenter( entry.bx, entry.by, entry.bz )
				or MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
			if eye:DistToSqr( center ) <= MAX_RENDER_DISTANCE_SQR then
				local stateId = MC.GetBlockState and MC.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
				local hasStateAnimation, visualSignature = false, nil
				if stateId == entry.stateId then
					hasStateAnimation, visualSignature = entry.hasStateAnimation, entry.visualSignature
				elseif stateId ~= 0 then
					hasStateAnimation, visualSignature = stateAnimationSignature(
						stateId, entry.bx, entry.by, entry.bz
					)
					entry.stateId = stateId
					entry.hasStateAnimation = hasStateAnimation
					entry.visualSignature = visualSignature
					entry.fluidKind = fluidAnimationKind( stateId )
				else
					entry.stateId = stateId
					entry.hasStateAnimation = false
					entry.visualSignature = nil
					entry.fluidKind = nil
				end
				if hasStateAnimation then
					drawEntry( entry, stateId, animations, elapsedTicks, visualSignature )
				elseif not entry.fluidKind then
					removeEntry( key )
				end
			end
		end
	end
	for chunkKey in pairs( EntriesByChunk ) do
		drawFluidChunk( chunkKey, animations, elapsedTicks, eye )
	end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )

hook.Add( "MCWorldAdapterChanged", "mc_block_animation_world_frame", function()
	for _, entry in pairs( Entries ) do entry.nextLightAt = 0 end
end )
hook.Add( "MC.ClientBlockStateChanged", "mc_block_animation_fluid_geometry", function()
	-- FluidRenderer samples a 3x3 horizontal neighbourhood plus occluding
	-- blocks above/beside it. Coalesce arbitrary cell edits into one cache clear.
	FluidMeshesDirty = true
end )
hook.Add( "MC.ClientWorldProjectionChanged", "mc_block_animation_world_projection", function()
	clearEntries()
	clearFluidMeshes()
end )
hook.Add( "ShutDown", "mc_block_animation_cleanup", clearMeshes )
hook.Add( "OnReloaded", "mc_block_animation_reload", function()
	clearMeshes()
	clearEntries()
end )
