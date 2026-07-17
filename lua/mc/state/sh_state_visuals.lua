--[[----------------------------------------------------------------------------
	MC : state-native visual descriptions.

	The world, network and save formats use complete stateId values. Rendering
	modules consume the compact description returned here instead of first
	downgrading the state to the legacy id + orient representation themselves.

	The default description remains compatible with existing generated block
	geometry. Feature modules can register state-specific blocks, faces, boxes,
	collision, translucency and light without changing the storage core.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.BlockStateVisualResolvers = MC.BlockStateVisualResolvers or {}
local BlockStateVisualCache = {}
local BlockStateRenderClassCache = {}
MC.BlockStateVisualCache = BlockStateVisualCache
MC.BlockStateRenderClassCache = BlockStateRenderClassCache

local RENDER_CLASS_FULL_CUBE = 1
local RENDER_CLASS_TRANSLUCENT = 2
local RENDER_CLASS_SCALE = 4
local floor = math.floor

local function clearCache( cache )
	for key in pairs( cache ) do cache[key] = nil end
end

local function normalizeBlockName( block )
	if type( block ) == "table" and block.name and block.firstStateId ~= nil then return block.name end
	if type( block ) == "number" and MC.BlockStateSchemas then
		local schema = MC.BlockStateSchemas[block]
		return schema and schema.name or nil
	end
	local name = string.lower( string.match( tostring( block or "" ), "^%s*(.-)%s*$" ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return name
end

local function shallowCopy( input )
	local out = {}
	for key, value in pairs( input or {} ) do out[key] = value end
	return out
end

local function mergeVisual( base, override )
	if type( override ) ~= "table" then return base end
	local out = shallowCopy( base )
	for key, value in pairs( override ) do
		if key == "block" and type( value ) == "table" then
			out.block = shallowCopy( base.block )
			for blockKey, blockValue in pairs( value ) do out.block[blockKey] = blockValue end
		else
			out[key] = value
		end
	end
	return out
end

local DIRECTION_BY_NAME = {
	down = 0,
	up = 1,
	north = 2,
	south = 3,
	west = 4,
	east = 5,
}
local AXIS_BY_NAME = { x = 0, y = 1, z = 2 }
local SLAB_BY_NAME = { bottom = 0, top = 1, double = 2 }

local function stateProperty( stateId, name, fallback )
	if not MC.GetStateProperty then return fallback end
	local value = MC.GetStateProperty( stateId, name )
	if value == nil then return fallback end
	return value
end

local function renderOrientForState( stateId, block )
	local rule = block and ( block.stateRule or block.orient ) or nil
	if rule == "axis" then return AXIS_BY_NAME[stateProperty( stateId, "axis", "y" )] or 1 end
	if rule == "facing" or rule == "horizontal_facing" then
		return DIRECTION_BY_NAME[stateProperty( stateId, "facing", "north" )] or 2
	end
	if rule == "slab" then return SLAB_BY_NAME[stateProperty( stateId, "type", "bottom" )] or 0 end
	if rule == "stairs" and MC.MakeStairOrient then
		return MC.MakeStairOrient(
			DIRECTION_BY_NAME[stateProperty( stateId, "facing", "north" )] or 2,
			stateProperty( stateId, "half", "bottom" )
		)
	end
	if rule == "door" and MC.MakeDoorOrient then
		return MC.MakeDoorOrient(
			DIRECTION_BY_NAME[stateProperty( stateId, "facing", "north" )] or 2,
			stateProperty( stateId, "half", "lower" ),
			stateProperty( stateId, "open", false ) == true,
			stateProperty( stateId, "hinge", "left" ),
			stateProperty( stateId, "powered", false ) == true
		)
	end
	if rule == "trapdoor" and MC.MakeTrapdoorOrient then
		return MC.MakeTrapdoorOrient(
			DIRECTION_BY_NAME[stateProperty( stateId, "facing", "north" )] or 2,
			stateProperty( stateId, "half", "bottom" ),
			stateProperty( stateId, "open", false ) == true,
			stateProperty( stateId, "powered", false ) == true
		)
	end
	if rule == "bed" and MC.MakeBedOrient then
		return MC.MakeBedOrient(
			DIRECTION_BY_NAME[stateProperty( stateId, "facing", "north" )] or 2,
			stateProperty( stateId, "part", "foot" )
		)
	end
	return 0
end

local function baseVisual( stateId, schema )
	local id = schema and schema.blockId or ( MC.BlockTypeForState and MC.BlockTypeForState( stateId ) )
	if id == nil then return nil, "state_missing_block" end
	local block = MC.Blocks and MC.Blocks[id] or nil
	return {
		stateId = stateId,
		id = id,
		blockId = id,
		renderOrient = renderOrientForState( stateId, block ),
		schema = schema,
		block = block,
	}
end

local VISUAL_PLAN_PROPERTIES = {
	axis = { "axis" },
	horizontal_facing = { "facing" },
	facing = { "facing" },
	slab = { "type" },
	stairs = { "facing", "half", "shape" },
	door = { "facing", "half", "hinge", "open", "powered" },
	trapdoor = { "facing", "half", "open", "powered" },
	bed = { "facing", "part" },
}

local function baseRendererHandlesConnection( block )
	local connection = block and block.connection
	return connection == "fence" or connection == "pane" or connection == "bars"
		or connection == "wall" or connection == "pipe6"
end

local function projectedVisualPlanId( stateId, schema, block, planId )
	if baseRendererHandlesConnection( block ) then return planId end
	local rule = block and ( block.stateRule or block.orient ) or nil
	local properties = VISUAL_PLAN_PROPERTIES[rule]
	local projectedState = schema and schema.defaultStateId or nil
	if not projectedState then return nil end
	if properties then
		for index = 1, #properties do
			local propertyName = properties[index]
			local value = MC.GetStateProperty and MC.GetStateProperty( stateId, propertyName ) or nil
			if value ~= nil and MC.StateWith then
				projectedState = MC.StateWith( projectedState, propertyName, value ) or projectedState
			end
		end
	end
	return MC.StateVisualPlanIdFast( projectedState )
end

function MC.ClearBlockStateVisualCache( block )
	if block == nil then
		clearCache( BlockStateVisualCache )
		clearCache( BlockStateRenderClassCache )
		return
	end
	local name = normalizeBlockName( block )
	if not name then return end
	for stateId, visual in pairs( BlockStateVisualCache ) do
		if visual and visual.schema and visual.schema.name == name then
			BlockStateVisualCache[stateId] = nil
			BlockStateRenderClassCache[stateId] = nil
		end
	end
end

function MC.ClearBlockStateRenderClassCache( block )
	if block == nil then
		clearCache( BlockStateRenderClassCache )
		return
	end
	local name = normalizeBlockName( block )
	local schema = name and MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[name] or nil
	if not schema or schema.firstStateId == nil or schema.lastStateId == nil then
		clearCache( BlockStateRenderClassCache )
		return
	end
	for stateId = schema.firstStateId, schema.lastStateId do
		BlockStateRenderClassCache[stateId] = nil
	end
end

function MC.RegisterBlockStateVisual( block, definition )
	local name = normalizeBlockName( block )
	if not name then return nil, "invalid_block_name" end
	if type( definition ) ~= "table" and type( definition ) ~= "function" then return nil, "invalid_visual_definition" end
	local record
	if type( definition ) == "function" then
		record = { Resolve = definition }
	else
		record = shallowCopy( definition )
		if record.Resolve ~= nil and type( record.Resolve ) ~= "function" then return nil, "invalid_visual_resolver" end
	end
	MC.BlockStateVisualResolvers[name] = record
	MC.ClearBlockStateVisualCache( name )
	return record
end

function MC.ResolveBlockStateVisual( stateId, bx, by, bz )
	local cached = BlockStateVisualCache[stateId]
	if cached then return cached end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema then return nil, "invalid_state" end
	local definition = MC.BlockStateVisualResolvers[schema.name]
	local positionDependent = definition and definition.positionDependent == true

	local visual, baseError = baseVisual( stateId, schema )
	if not visual then return nil, baseError end
	if definition then
		local override = definition.Resolve and definition.Resolve( stateId, schema, visual, bx, by, bz ) or definition
		visual = mergeVisual( visual, override )
	end
	visual.stateId = stateId
	visual.schema = schema
	visual.id = math.floor( tonumber( visual.id or visual.blockId or schema.blockId ) or -1 )
	visual.blockId = visual.id
	if visual.id < 0 or not MC.Blocks or not MC.Blocks[visual.id] then return nil, "visual_missing_block" end
	visual.renderOrient = math.floor( tonumber( visual.renderOrient ) or renderOrientForState( stateId, MC.Blocks[visual.id] ) )
	visual.block = visual.block or MC.Blocks[visual.id]
	if visual.block.id == nil then visual.block.id = visual.id end
	if CLIENT and MC.StateVisualPlanIdFast and stateId >= 0 and MC.StateVisualCatalog
	and stateId < MC.StateVisualCatalog.stateCount then
		local planId = MC.StateVisualPlanIdFast( stateId )
		visual.generatedPlanId = planId
		local projectedPlanId = projectedVisualPlanId( stateId, schema, visual.block, planId )
		visual.generatedVisualOverride = projectedPlanId ~= planId
			or MC.StateVisualPlanHasRandomChoice and MC.StateVisualPlanHasRandomChoice( planId ) == true
	end
	if not positionDependent and visual.cacheable ~= false then BlockStateVisualCache[stateId] = visual end
	return visual
end

local function visualValue( visual, key, ... )
	local value = visual and visual[key]
	if type( value ) == "function" then return value( visual, ... ) end
	return value
end

function MC.BlockVisualFace( visual, face, bx, by, bz )
	if not visual then return 0, 0, false, false end
	local faces = visual.faces
	local value = type( faces ) == "function" and faces( visual, face, bx, by, bz )
		or type( faces ) == "table" and faces[face] or nil
	if type( value ) == "number" then return value, 0, false, false end
	if type( value ) == "table" then
		return value.tile or value[1] or 0, value.rot or value[2] or 0,
			value.flipU == true or value[3] == true, value.flipV == true or value[4] == true
	end
	if visual.block and visual.block ~= MC.Blocks[visual.id] then
		local b = visual.block
		local tile = face == ( MC.Face and MC.Face.TOP or 1 ) and b.top
			or face == ( MC.Face and MC.Face.BOTTOM or 2 ) and b.bottom or b.side
		if tile ~= nil then return tile, 0, false, false end
	end
	return MC.BlockFace( visual.id, face, visual.renderOrient )
end

function MC.BlockFaceForState( stateId, face, bx, by, bz )
	return MC.BlockVisualFace( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), face, bx, by, bz )
end

function MC.BlockVisualBoxes( visual, bx, by, bz )
	if not visual then return nil end
	local boxes = visualValue( visual, "boxes", bx, by, bz )
	if boxes ~= nil then return boxes end
	return MC.BlockBoxes and MC.BlockBoxes( visual.id, visual.renderOrient, bx, by, bz ) or nil
end

function MC.BlockBoxesForState( stateId, bx, by, bz )
	return MC.BlockVisualBoxes( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualCollisionConvexes( visual, bx, by, bz )
	if not visual then return nil end
	local convexes = visualValue( visual, "collisionConvexes", bx, by, bz )
	if convexes ~= nil then return convexes end
	local stateCollision = MC.ResolveBlockStateCollision
		and MC.ResolveBlockStateCollision( visual.stateId, bx, by, bz, visual ) or nil
	if stateCollision then return stateCollision.convexes end
	return MC.BlockCollisionConvexes and MC.BlockCollisionConvexes( visual.id, visual.renderOrient, bx, by, bz ) or nil
end

function MC.BlockCollisionConvexesForState( stateId, bx, by, bz )
	return MC.BlockVisualCollisionConvexes( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualHasCollision( visual, bx, by, bz )
	if not visual then return false end
	local hasCollision = visualValue( visual, "hasCollision", bx, by, bz )
	if hasCollision ~= nil then return hasCollision == true end
	local stateCollision = MC.ResolveBlockStateCollision
		and MC.ResolveBlockStateCollision( visual.stateId, bx, by, bz, visual ) or nil
	if stateCollision then return stateCollision.hasCollision == true end
	return MC.BlockHasCollision and MC.BlockHasCollision( visual.id ) == true or false
end

function MC.BlockHasCollisionForState( stateId, bx, by, bz )
	return MC.BlockVisualHasCollision( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualCollisionBoxes( visual, bx, by, bz )
	if not visual or not MC.BlockVisualHasCollision( visual, bx, by, bz ) then return nil end
	local collisionBoxes = visualValue( visual, "collisionBoxes", bx, by, bz )
	if collisionBoxes ~= nil then return collisionBoxes end
	local stateCollision = MC.ResolveBlockStateCollision
		and MC.ResolveBlockStateCollision( visual.stateId, bx, by, bz, visual ) or nil
	if stateCollision then return stateCollision.boxes end
	return MC.GetBlockCollisionBoxes and MC.GetBlockCollisionBoxes( visual.id, visual.renderOrient, bx, by, bz ) or nil
end

function MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz )
	return MC.BlockVisualCollisionBoxes( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualIsFullCube( visual, bx, by, bz )
	if not visual then return false end
	local fullCube = visualValue( visual, "fullCube", bx, by, bz )
	if fullCube ~= nil then return fullCube == true end
	local stateCollision = MC.ResolveBlockStateCollision
		and MC.ResolveBlockStateCollision( visual.stateId, bx, by, bz, visual ) or nil
	if stateCollision then return stateCollision.fullCube == true end
	return MC.BlockIsFullCube and MC.BlockIsFullCube( visual.id, visual.renderOrient ) == true or false
end

function MC.BlockIsFullCubeForState( stateId, bx, by, bz )
	return MC.BlockVisualIsFullCube( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualIsTranslucent( visual, bx, by, bz )
	if not visual then return false end
	local translucent = visualValue( visual, "translucent", bx, by, bz )
	if translucent ~= nil then return translucent == true end
	return MC.IsTranslucentBlock and MC.IsTranslucentBlock( visual.id ) == true or false
end

-- Mesh face culling asks the same three questions for every neighbouring voxel:
-- which block type is it, is it a full cube, and is it translucent? Keep that
-- state-only answer packed into one number so the hot path does not repeatedly
-- traverse the generic visual/collision interfaces. Position-dependent custom
-- resolvers are still evaluated at the requested world coordinate and are not
-- cached.
function MC.ResolveBlockStateRenderClass( stateId, bx, by, bz )
	local cached = BlockStateRenderClassCache[stateId]
	if cached ~= nil then
		local flags = cached % RENDER_CLASS_SCALE
		return floor( cached / RENDER_CLASS_SCALE ),
			flags % 2 == RENDER_CLASS_FULL_CUBE,
			flags >= RENDER_CLASS_TRANSLUCENT
	end

	local visual = MC.ResolveBlockStateVisual( stateId, bx, by, bz )
	if not visual then return 0, false, false end
	local id = visual.id or visual.blockId or 0
	local fullCube = MC.BlockVisualIsFullCube( visual, bx, by, bz ) == true
	local translucent = MC.BlockVisualIsTranslucent( visual, bx, by, bz ) == true
	local schemaName = visual.schema and visual.schema.name
	local visualResolver = schemaName and MC.BlockStateVisualResolvers[schemaName] or nil
	local collisionResolver = schemaName and MC.BlockStateCollisionResolvers and MC.BlockStateCollisionResolvers[schemaName] or nil
	local positionDependent = visualResolver and visualResolver.positionDependent == true
		or collisionResolver and collisionResolver.positionDependent == true
		or visual.cacheable == false
	if not positionDependent then
		local flags = ( fullCube and RENDER_CLASS_FULL_CUBE or 0 )
			+ ( translucent and RENDER_CLASS_TRANSLUCENT or 0 )
		BlockStateRenderClassCache[stateId] = id * RENDER_CLASS_SCALE + flags
	end
	return id, fullCube, translucent, visual
end

function MC.IsTranslucentBlockState( stateId, bx, by, bz )
	return MC.BlockVisualIsTranslucent( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualLightEmission( visual, bx, by, bz )
	if not visual then return 0 end
	local emission = visualValue( visual, "lightEmission", bx, by, bz )
	if emission ~= nil then return math.max( 0, math.min( 15, math.floor( tonumber( emission ) or 0 ) ) ) end
	return MC.BlockLightEmission and MC.BlockLightEmission( visual.id ) or 0
end

function MC.BlockLightEmissionForState( stateId, bx, by, bz )
	return MC.BlockVisualLightEmission( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockVisualLightOpacity( visual, bx, by, bz )
	if not visual then return 15 end
	local opacity = visualValue( visual, "lightOpacity", bx, by, bz )
	if opacity ~= nil then return math.max( 0, math.min( 15, math.floor( tonumber( opacity ) or 0 ) ) ) end
	return MC.BlockLightOpacity and MC.BlockLightOpacity( visual.id, visual.renderOrient ) or 15
end

function MC.BlockLightOpacityForState( stateId, bx, by, bz )
	if tonumber( stateId ) == 0 then return 0 end
	return MC.BlockVisualLightOpacity( MC.ResolveBlockStateVisual( stateId, bx, by, bz ), bx, by, bz )
end

function MC.BlockModelDataForState( stateId, bx, by, bz )
	local visual = MC.ResolveBlockStateVisual( stateId, bx, by, bz )
	if not visual then return nil end
	local modelData = visualValue( visual, "modelData", bx, by, bz )
	if modelData ~= nil then return modelData, visual end
	return MC.BlockModelData and MC.BlockModelData( visual.block or visual.id, visual.renderOrient ) or visual.block, visual
end
