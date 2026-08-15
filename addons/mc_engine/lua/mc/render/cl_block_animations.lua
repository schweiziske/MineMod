-- Client-only dynamic block texture layer.
--
-- Minecraft block sprites such as fire and the lit campfire logs are vertical
-- PNG frame strips driven by .mcmeta. Source does not understand that format,
-- so the atlas builder keeps those atlas slots transparent and emits the Java
-- frames separately. This layer reuses the generated blockstate model quads,
-- preserving every vanilla rotation/UV while remaining independent of the Lua
-- or native chunk mesh backend.

MC = MC or {}

local BS = MC.BS or 36.5
local TICK_SECONDS = 1 / 20
local REFRESH_INTERVAL = 0.25
local MAX_RENDER_DISTANCE_SQR = ( BS * 96 ) ^ 2
local TRI = { 1, 3, 2, 1, 4, 3 }
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
local MaterialCache = {}
local LastRefresh = 0
local LastGeneration = tonumber( MC.StateWorldGeneration ) or 0

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

local function addEntry( bx, by, bz, stateId )
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
	entry.nextLightAt = 0
	return entry
end

local function scanChunk( key, chunk )
	removeChunkEntries( key )
	if MC.ForEachBlockState then
		MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
			if stateAnimationSignature( stateId, bx, by, bz ) then addEntry( bx, by, bz, stateId ) end
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
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if generation ~= LastGeneration then
		clearEntries()
		LastGeneration = generation
	end
	for key, scanned in pairs( ScannedChunkVersions ) do
		local current = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
		if current ~= scanned.chunk then
			removeChunkEntries( key )
			ScannedChunkVersions[key] = nil
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
	local cacheKey = tostring( stateId ) .. ":" .. tostring( visualSignature or 0 ) .. ":" .. tostring( animationName )
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

local function materialForPath( path )
	local cached = MaterialCache[path]
	if cached then return cached end
	cached = Material( path, "alphatest nocull noclamp vertexcolor vertexalpha" )
	MaterialCache[path] = cached
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

local function drawFrame( meshObject, frame, color, alpha )
	if not frame or alpha <= 0 then return end
	local material = materialForPath( frame.material )
	if not material or material:IsError() then return end
	render.SetMaterial( material )
	render.SetColorModulation( color.r / 255, color.g / 255, color.b / 255 )
	render.SetBlend( alpha )
	meshObject:Draw()
end

local function drawEntry( entry, stateId, animations, elapsedTicks )
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
	local _, visualSignature = stateAnimationSignature( stateId, entry.bx, entry.by, entry.bz )
	for name, animation in pairs( animations ) do
		if type( animation ) == "table" and animation.tile ~= nil then
			local meshObject = meshForStateAnimation( stateId, entry.bx, entry.by, entry.bz, name, animation, visualSignature )
			if meshObject then
				local frame, nextFrame, progress = animationFrame( animation, elapsedTicks )
				local interpolate = animation.interpolate or SMOOTH_FLAME_ANIMATIONS[name] == true
				if interpolate and nextFrame and nextFrame.material ~= frame.material then
					drawFrame( meshObject, frame, color, 1 - progress )
					drawFrame( meshObject, nextFrame, color, progress )
				else
					drawFrame( meshObject, frame, color, 1 )
				end
			end
		end
	end
	cam.PopModelMatrix()
end

hook.Add( "Think", "mc_block_animation_chunk_scan", function()
	if CurTime() < LastRefresh then return end
	LastRefresh = CurTime() + REFRESH_INTERVAL
	refreshChunks()
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
		local center = MC.CellRenderCenter and MC.CellRenderCenter( entry.bx, entry.by, entry.bz )
			or MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
		if eye:DistToSqr( center ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = MC.GetBlockState and MC.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
			if stateId == 0 or not stateAnimationSignature( stateId, entry.bx, entry.by, entry.bz ) then removeEntry( key )
			else drawEntry( entry, stateId, animations, elapsedTicks ) end
		end
	end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )

local function clearMeshes()
	for _, meshObject in pairs( MeshCache ) do
		if meshObject and meshObject ~= false and meshObject.Destroy then meshObject:Destroy() end
	end
	MeshCache = {}
end

hook.Add( "MCWorldAdapterChanged", "mc_block_animation_world_frame", function()
	for _, entry in pairs( Entries ) do entry.nextLightAt = 0 end
end )
hook.Add( "ShutDown", "mc_block_animation_cleanup", clearMeshes )
hook.Add( "OnReloaded", "mc_block_animation_reload", function()
	clearMeshes()
	clearEntries()
end )
