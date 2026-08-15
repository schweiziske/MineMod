-- Shared compact Minecraft blockstate visual catalog accessors.
--
-- The generated source stores binary strings instead of tens of thousands of
-- Lua geometry/state tables. Geometry and material tables are decoded lazily
-- only when a state actually appears in a visible chunk or preview.

MC = MC or {}

local Catalog = MC.GeneratedStateVisualCatalog
if not Catalog then return end

MC.StateVisualCatalog = Catalog
MC.GeneratedStateVisualCatalog = nil

local byte = string.byte
local floor = math.floor
local bit_band, bit_bxor, bit_rshift = bit.band, bit.bxor, bit.rshift
local COORD_SCALE = Catalog.coordinateScale or 16384
local QUAD_BYTES = Catalog.packedQuadBytes or 32

local function u16( data, offset )
	local a, b = byte( data, offset, offset + 1 )
	return ( a or 0 ) + ( b or 0 ) * 256
end

local function i16( data, offset )
	local value = u16( data, offset )
	return value >= 32768 and value - 65536 or value
end

local function u32( data, offset )
	local a, b, c, d = byte( data, offset, offset + 3 )
	return ( a or 0 ) + ( b or 0 ) * 256 + ( c or 0 ) * 65536 + ( d or 0 ) * 16777216
end

function MC.StateVisualPlanIdFast( stateId )
	return u16( Catalog.statePlans, stateId * 2 + 1 )
end

function MC.StateVisualPlanId( stateId )
	stateId = floor( tonumber( stateId ) or -1 )
	if stateId < 0 or stateId >= Catalog.stateCount then return nil end
	return MC.StateVisualPlanIdFast( stateId )
end

local function positionChoice( bx, by, bz, salt, totalWeight )
	if totalWeight <= 1 or bx == nil or by == nil or bz == nil then return 0 end
	bx, by, bz = floor( bx ), floor( by ), floor( bz )
	local hash = bit_bxor( bx * 73428767, by * 912931, bz * 19349663, salt * 83492791 )
	return bit_band( hash, 0x7fffffff ) % totalWeight
end

local function selectedGroupModel( groupId, bx, by, bz, planId )
	local indexOffset = ( groupId - 1 ) * 3 + 1
	local alternativeOffset = u16( Catalog.groupIndex, indexOffset )
	local alternativeCount = byte( Catalog.groupIndex, indexOffset + 2 ) or 0
	if alternativeCount <= 0 then return nil end
	local firstOffset = alternativeOffset * 3 + 1
	if alternativeCount == 1 then return u16( Catalog.groupData, firstOffset ) end

	local totalWeight = 0
	for alternativeIndex = 0, alternativeCount - 1 do
		totalWeight = totalWeight + ( byte( Catalog.groupData, firstOffset + alternativeIndex * 3 + 2 ) or 1 )
	end
	local choice = positionChoice( bx, by, bz, groupId + planId * 131, totalWeight )
	for alternativeIndex = 0, alternativeCount - 1 do
		local offset = firstOffset + alternativeIndex * 3
		local weight = byte( Catalog.groupData, offset + 2 ) or 1
		if choice < weight then return u16( Catalog.groupData, offset ) end
		choice = choice - weight
	end
	return u16( Catalog.groupData, firstOffset )
end

function MC.StateVisualPlanRangeFast( stateId )
	local planId = MC.StateVisualPlanIdFast( stateId )
	local planIndexOffset = ( planId - 1 ) * 3 + 1
	return planId, u16( Catalog.planIndex, planIndexOffset ), byte( Catalog.planIndex, planIndexOffset + 2 ) or 0
end

function MC.StateVisualPlanModelAtFast( planId, groupOffset, groupIndex, bx, by, bz )
	local groupId = u16( Catalog.planData, ( groupOffset + groupIndex ) * 2 + 1 )
	return selectedGroupModel( groupId, bx, by, bz, planId )
end

function MC.VisitStateVisualModels( stateId, bx, by, bz, visitor )
	if type( visitor ) ~= "function" then return 0 end
	stateId = floor( tonumber( stateId ) or -1 )
	if stateId < 0 or stateId >= Catalog.stateCount then return 0 end
	local planId, groupOffset, groupCount = MC.StateVisualPlanRangeFast( stateId )
	for groupIndex = 0, groupCount - 1 do
		local modelId = MC.StateVisualPlanModelAtFast( planId, groupOffset, groupIndex, bx, by, bz )
		if modelId then visitor( modelId, groupIndex + 1, planId ) end
	end
	return groupCount, planId
end

function MC.CollectStateVisualModels( stateId, bx, by, bz, out )
	out = out or {}
	local count = 0
	local function collect( modelId )
		count = count + 1
		out[count] = modelId
	end
	local _, planId = MC.VisitStateVisualModels( stateId, bx, by, bz, collect )
	for index = count + 1, #out do out[index] = nil end
	out.n = count
	return out, planId
end

local GeometryCache = {}
local SurfaceCache = {}
local ModelDataCache = {}
local ModelTransformById = {}
local TransformedModelDataCache = {}
local RandomPlanCache = {}

function MC.StateVisualPlanHasRandomChoice( planId )
	local cached = RandomPlanCache[planId]
	if cached ~= nil then return cached end
	local planIndexOffset = ( planId - 1 ) * 3 + 1
	local groupOffset = u16( Catalog.planIndex, planIndexOffset )
	local groupCount = byte( Catalog.planIndex, planIndexOffset + 2 ) or 0
	for groupIndex = 0, groupCount - 1 do
		local groupId = u16( Catalog.planData, ( groupOffset + groupIndex ) * 2 + 1 )
		local alternativeCount = byte( Catalog.groupIndex, ( groupId - 1 ) * 3 + 3 ) or 0
		if alternativeCount > 1 then
			RandomPlanCache[planId] = true
			return true
		end
	end
	RandomPlanCache[planId] = false
	return false
end

local function decodeGeometry( geometryId )
	local cached = GeometryCache[geometryId]
	if cached then return cached end
	local indexOffset = ( geometryId - 1 ) * 6 + 1
	local dataOffset = u32( Catalog.geometryIndex, indexOffset )
	local quadCount = u16( Catalog.geometryIndex, indexOffset + 4 )
	local quads = {}
	for quadIndex = 1, quadCount do
		local offset = dataOffset + ( quadIndex - 1 ) * QUAD_BYTES + 1
		local packedFace = byte( Catalog.geometryData, offset ) or 1
		local face = bit_band( packedFace, 7 )
		local tintValue = bit_rshift( packedFace, 3 )
		local surface = byte( Catalog.geometryData, offset + 1 ) or 1
		local rotation = byte( Catalog.geometryData, offset + 2 ) or 0
		local uvFlags = byte( Catalog.geometryData, offset + 3 ) or 0
		local verts = {}
		local coordOffset = offset + 8
		for vertexIndex = 0, 3 do
			local target = vertexIndex * 5
			verts[target + 1] = i16( Catalog.geometryData, coordOffset ) / COORD_SCALE
			verts[target + 2] = i16( Catalog.geometryData, coordOffset + 2 ) / COORD_SCALE
			verts[target + 3] = i16( Catalog.geometryData, coordOffset + 4 ) / COORD_SCALE
			verts[target + 4] = bit_band( uvFlags, 2 ^ ( vertexIndex * 2 ) ) ~= 0 and 1 or 0
			verts[target + 5] = bit_band( uvFlags, 2 ^ ( vertexIndex * 2 + 1 ) ) ~= 0 and 1 or 0
			coordOffset = coordOffset + 6
		end
		quads[quadIndex] = {
			face = face,
			tintIndex = tintValue > 0 and tintValue - 1 or -1,
			surface = surface,
			rot = rotation,
			uv = {
				( byte( Catalog.geometryData, offset + 4 ) or 0 ) * 0.5,
				( byte( Catalog.geometryData, offset + 5 ) or 0 ) * 0.5,
				( byte( Catalog.geometryData, offset + 6 ) or 32 ) * 0.5,
				( byte( Catalog.geometryData, offset + 7 ) or 32 ) * 0.5,
			},
			verts = verts,
		}
	end
	cached = { compact = true, modelQuads = quads }
	GeometryCache[geometryId] = cached
	return cached
end

local function decodeSurfaces( surfaceId )
	local cached = SurfaceCache[surfaceId]
	if cached then return cached end
	local indexOffset = ( surfaceId - 1 ) * 6 + 1
	local entryOffset = u32( Catalog.surfaceIndex, indexOffset )
	local entryCount = u16( Catalog.surfaceIndex, indexOffset + 4 )
	cached = {}
	for entryIndex = 1, entryCount do
		cached[entryIndex] = u16( Catalog.surfaceData, ( entryOffset + entryIndex - 1 ) * 2 + 1 )
	end
	SurfaceCache[surfaceId] = cached
	return cached
end

function MC.StateVisualModelData( modelId )
	modelId = floor( tonumber( modelId ) or -1 )
	if modelId < 1 or modelId > Catalog.modelInstanceCount then return nil end
	local transform = ModelTransformById[modelId]
	if transform then
		local transformed = TransformedModelDataCache[modelId]
		if transformed then return transformed end
	end
	local mapOffset = ( modelId - 1 ) * 4 + 1
	local geometryId = u16( Catalog.modelMap, mapOffset )
	local surfaceId = u16( Catalog.modelMap, mapOffset + 2 )
	if geometryId == 0 or surfaceId == 0 then return nil end
	local cacheKey = geometryId * 2048 + surfaceId
	local cached = ModelDataCache[cacheKey]
	if not cached then
		local geometry = decodeGeometry( geometryId )
		cached = {
			compact = true,
			modelQuads = geometry.modelQuads,
			modelSurfaces = decodeSurfaces( surfaceId ),
			generatedStateVisual = true,
			geometryId = geometryId,
			surfaceId = surfaceId,
		}
		ModelDataCache[cacheKey] = cached
	end
	if not transform then return cached end
	local transformed = transform( cached, modelId ) or cached
	TransformedModelDataCache[modelId] = transformed
	return transformed
end

function MC.RegisterStateVisualModelTransform( modelId, transform )
	modelId = floor( tonumber( modelId ) or -1 )
	if modelId < 1 or modelId > Catalog.modelInstanceCount then return nil, "invalid_model_id" end
	if type( transform ) ~= "function" then return nil, "invalid_model_transform" end
	ModelTransformById[modelId] = transform
	TransformedModelDataCache[modelId] = nil
	return transform
end

function MC.ClearDecodedStateVisualModels()
	GeometryCache = {}
	SurfaceCache = {}
	ModelDataCache = {}
	TransformedModelDataCache = {}
	RandomPlanCache = {}
end

MC.StateVisualCatalogStats = {
	binaryBytes = Catalog.binaryBytes,
	states = Catalog.stateCount,
	plans = Catalog.visualPlanCount,
	models = Catalog.modelInstanceCount,
	geometryTemplates = Catalog.geometryTemplateCount,
	surfaceSets = Catalog.surfaceSetCount,
}
