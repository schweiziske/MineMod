--[[----------------------------------------------------------------------------
	MC : state-native collision shapes.

	Collision is resolved from the complete stateId. Shapes are interned so the
	32k vanilla states reuse a small set of box/convex templates instead of
	duplicating geometry per state or per voxel.

	Minecraft source references for the built-in families live under:
	  out/net/minecraft/world/level/block/
	The coordinates below are converted from Minecraft's X/Y/Z (Y up) to the
	addon's X/Y/Z (Z up).
------------------------------------------------------------------------------]]

MC = MC or {}

MC.BlockStateCollisionShapes = MC.BlockStateCollisionShapes or {}
MC.BlockStateCollisionShapeByName = MC.BlockStateCollisionShapeByName or {}
MC.BlockStateCollisionShapeBuckets = MC.BlockStateCollisionShapeBuckets or {}
MC.BlockStateCollisionResolvers = MC.BlockStateCollisionResolvers or {}
MC.BlockStateCollisionCache = MC.BlockStateCollisionCache or {}

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" )
end

local function normalizeBlockName( block )
	if type( block ) == "table" and block.name and block.firstStateId ~= nil then return block.name end
	if type( block ) == "number" and MC.BlockStateSchemas then
		local schema = MC.BlockStateSchemas[block]
		return schema and schema.name or nil
	end
	local name = string.lower( trim( block ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then
		local resolved = MC.ResolveBlock and MC.ResolveBlock( name ) or nil
		name = resolved and resolved.mcid or nil
	end
	return name
end

local function finiteNumber( value )
	value = tonumber( value )
	if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
	return value
end

local function normalizeBoxes( boxes )
	if type( boxes ) ~= "table" then return nil, "invalid_boxes" end
	local out = {}
	for _, box in ipairs( boxes ) do
		if type( box ) ~= "table" then return nil, "invalid_box" end
		local normalized = {}
		for index = 1, 6 do
			normalized[index] = finiteNumber( box[index] )
			if normalized[index] == nil then return nil, "invalid_box_coordinate" end
		end
		if normalized[1] >= normalized[4] or normalized[2] >= normalized[5] or normalized[3] >= normalized[6] then
			return nil, "empty_box"
		end
		out[#out + 1] = normalized
	end
	return out
end

local function normalizeConvexes( convexes )
	if type( convexes ) ~= "table" then return nil, "invalid_convexes" end
	local out = {}
	for _, convex in ipairs( convexes ) do
		if type( convex ) ~= "table" then return nil, "invalid_convex" end
		local points = {}
		for _, point in ipairs( convex ) do
			if type( point ) ~= "table" then return nil, "invalid_convex_point" end
			local x = finiteNumber( point[1] or point.x )
			local y = finiteNumber( point[2] or point.y )
			local z = finiteNumber( point[3] or point.z )
			if x == nil or y == nil or z == nil then return nil, "invalid_convex_coordinate" end
			points[#points + 1] = { x, y, z }
		end
		if #points < 4 then return nil, "convex_too_small" end
		out[#out + 1] = points
	end
	return out
end

local HASH_MODULUS = 2147483647
local HASH_SCALE = 1048576

local function hashNumber( hash, value )
	local scaled = value >= 0 and math.floor( value * HASH_SCALE + 0.5 ) or math.ceil( value * HASH_SCALE - 0.5 )
	return ( hash * 65599 + scaled + HASH_MODULUS ) % HASH_MODULUS
end

local function geometryHash( boxes, convexes )
	local hash = 17
	hash = hashNumber( hash, #( boxes or {} ) )
	for _, box in ipairs( boxes or {} ) do
		for index = 1, 6 do hash = hashNumber( hash, box[index] ) end
	end
	hash = hashNumber( hash, #( convexes or {} ) )
	for _, convex in ipairs( convexes or {} ) do
		hash = hashNumber( hash, #convex )
		for _, point in ipairs( convex ) do
			hash = hashNumber( hash, point[1] )
			hash = hashNumber( hash, point[2] )
			hash = hashNumber( hash, point[3] )
		end
	end
	return hash
end

local function sameGeometry( shape, boxes, convexes )
	local shapeBoxes = shape.boxes or {}
	local shapeConvexes = shape.convexes or {}
	if #shapeBoxes ~= #boxes or #shapeConvexes ~= #convexes then return false end
	for boxIndex, box in ipairs( boxes ) do
		local other = shapeBoxes[boxIndex]
		for index = 1, 6 do
			if other[index] ~= box[index] then return false end
		end
	end
	for convexIndex, convex in ipairs( convexes ) do
		local otherConvex = shapeConvexes[convexIndex]
		if #otherConvex ~= #convex then return false end
		for pointIndex, point in ipairs( convex ) do
			local otherPoint = otherConvex[pointIndex]
			if otherPoint[1] ~= point[1] or otherPoint[2] ~= point[2] or otherPoint[3] ~= point[3] then return false end
		end
	end
	return true
end

local function isFullCubeBoxes( boxes, convexes )
	if convexes and #convexes > 0 then return false end
	if not boxes or #boxes ~= 1 then return false end
	local box = boxes[1]
	return box[1] == 0 and box[2] == 0 and box[3] == 0
		and box[4] == 1 and box[5] == 1 and box[6] == 1
end

function MC.RegisterBlockStateCollisionShape( name, definition )
	if definition == nil and type( name ) == "table" then
		definition = name
		name = nil
	end
	if type( definition ) ~= "table" then return nil, "invalid_shape_definition" end
	name = name ~= nil and string.lower( trim( name ) ) or nil
	if name == "" then return nil, "invalid_shape_name" end

	local boxes, boxError
	if definition.boxes ~= nil then
		boxes, boxError = normalizeBoxes( definition.boxes )
		if not boxes then return nil, boxError end
	end
	local convexes, convexError
	if definition.convexes ~= nil or definition.collisionConvexes ~= nil then
		convexes, convexError = normalizeConvexes( definition.convexes or definition.collisionConvexes )
		if not convexes then return nil, convexError end
	end
	boxes = boxes or {}
	convexes = convexes or {}
	local hash = geometryHash( boxes, convexes )
	local bucket = MC.BlockStateCollisionShapeBuckets[hash]
	if bucket then
		for _, existing in ipairs( bucket ) do
			if sameGeometry( existing, boxes, convexes ) then
				if name then
					local named = MC.BlockStateCollisionShapeByName[name]
					if named and named ~= existing then return nil, "shape_name_conflict" end
					MC.BlockStateCollisionShapeByName[name] = existing
				end
				return existing, false
			end
		end
	end
	if name and MC.BlockStateCollisionShapeByName[name] then return nil, "shape_name_conflict" end

	local shape = {
		id = #MC.BlockStateCollisionShapes + 1,
		name = name,
		boxes = #boxes > 0 and boxes or nil,
		convexes = #convexes > 0 and convexes or nil,
		hasCollision = #boxes > 0 or #convexes > 0,
		fullCube = isFullCubeBoxes( boxes, convexes ),
	}
	MC.BlockStateCollisionShapes[shape.id] = shape
	if not bucket then
		bucket = {}
		MC.BlockStateCollisionShapeBuckets[hash] = bucket
	end
	bucket[#bucket + 1] = shape
	if name then MC.BlockStateCollisionShapeByName[name] = shape end
	return shape, true
end

function MC.ResolveBlockStateCollisionShape( shape )
	if type( shape ) == "table" and shape.id and MC.BlockStateCollisionShapes[shape.id] == shape then return shape end
	if type( shape ) == "number" then return MC.BlockStateCollisionShapes[math.floor( shape )] end
	if type( shape ) == "string" then return MC.BlockStateCollisionShapeByName[string.lower( trim( shape ) )] end
	return nil
end

local EMPTY_SHAPE = assert( MC.RegisterBlockStateCollisionShape( "empty", { boxes = {} } ) )
local FULL_CUBE_SHAPE = assert( MC.RegisterBlockStateCollisionShape( "full_cube", { boxes = { { 0, 0, 0, 1, 1, 1 } } } ) )
MC.EmptyBlockStateCollisionShape = EMPTY_SHAPE
MC.FullCubeBlockStateCollisionShape = FULL_CUBE_SHAPE

local function internBoxes( boxes )
	return assert( MC.RegisterBlockStateCollisionShape( { boxes = boxes } ) )
end

function MC.ClearBlockStateCollisionCache( block )
	if block == nil then
		MC.BlockStateCollisionCache = {}
		if MC.ClearBlockStateRenderClassCache then MC.ClearBlockStateRenderClassCache() end
		return
	end
	local name = normalizeBlockName( block )
	if not name then return end
	local schema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[name] or nil
	if schema and schema.firstStateId ~= nil and schema.lastStateId ~= nil then
		for stateId = schema.firstStateId, schema.lastStateId do MC.BlockStateCollisionCache[stateId] = nil end
		if MC.ClearBlockStateRenderClassCache then MC.ClearBlockStateRenderClassCache( name ) end
		return
	end
	MC.BlockStateCollisionCache = {}
	if MC.ClearBlockStateRenderClassCache then MC.ClearBlockStateRenderClassCache() end
end

function MC.RegisterBlockStateCollision( block, definition )
	local name = normalizeBlockName( block )
	if not name then return nil, "invalid_block_name" end
	if type( definition ) ~= "table" and type( definition ) ~= "function" then return nil, "invalid_collision_definition" end
	local record = type( definition ) == "function" and { Resolve = definition } or definition
	if record.Resolve ~= nil and type( record.Resolve ) ~= "function" then return nil, "invalid_collision_resolver" end
	MC.BlockStateCollisionResolvers[name] = record
	MC.ClearBlockStateCollisionCache( name )
	return record
end

local function property( stateId, schema, name, fallback )
	local definition = schema and schema.propertyByName and schema.propertyByName[name] or nil
	if not definition or schema.firstStateId == nil or definition.stride == nil then return fallback end
	local ordinal = stateId - schema.firstStateId
	local valueIndex = math.floor( ordinal / definition.stride ) % definition.count + 1
	local value = definition.values[valueIndex]
	if value == nil then return fallback end
	return value
end

local function hasProperty( schema, name )
	return schema and schema.propertyByName and schema.propertyByName[name] ~= nil
end

local function horizontalPlane( direction, thickness, height )
	local inset = 1 - thickness
	if direction == "north" then return { 0, inset, 0, 1, 1, height } end
	if direction == "east" then return { 0, 0, 0, thickness, 1, height } end
	if direction == "south" then return { 0, 0, 0, 1, thickness, height } end
	return { inset, 0, 0, 1, 1, height }
end

local FamilyShapeCache = {
	slab = {}, stairs = {}, door = {}, trapdoor = {}, fence = {}, fence_gate = {}, wall = {}, pane = {}, snow_layer = {}, cake = {},
}

local FacingIndex = { north = 0, east = 1, south = 2, west = 3 }
local StairShapeIndex = { straight = 0, inner_left = 1, inner_right = 2, outer_left = 3, outer_right = 4 }
local ClockwiseFacing = { north = "east", east = "south", south = "west", west = "north" }
local CounterClockwiseFacing = { north = "west", west = "south", south = "east", east = "north" }

local function connectionValue( value )
	return value == true or value == "low" or value == "tall"
end

local function stairStepRects( facing, shape )
	if facing == "north" then
		if shape == "outer_left" then return { { 0, 0, 0.5, 0.5 } } end
		if shape == "outer_right" then return { { 0.5, 0, 1, 0.5 } } end
		if shape == "inner_left" then return { { 0, 0, 1, 0.5 }, { 0, 0.5, 0.5, 1 } } end
		if shape == "inner_right" then return { { 0, 0, 1, 0.5 }, { 0.5, 0.5, 1, 1 } } end
		return { { 0, 0, 1, 0.5 } }
	elseif facing == "south" then
		if shape == "outer_left" then return { { 0.5, 0.5, 1, 1 } } end
		if shape == "outer_right" then return { { 0, 0.5, 0.5, 1 } } end
		if shape == "inner_left" then return { { 0, 0.5, 1, 1 }, { 0.5, 0, 1, 0.5 } } end
		if shape == "inner_right" then return { { 0, 0.5, 1, 1 }, { 0, 0, 0.5, 0.5 } } end
		return { { 0, 0.5, 1, 1 } }
	elseif facing == "west" then
		if shape == "outer_left" then return { { 0, 0.5, 0.5, 1 } } end
		if shape == "outer_right" then return { { 0, 0, 0.5, 0.5 } } end
		if shape == "inner_left" then return { { 0, 0, 0.5, 1 }, { 0.5, 0.5, 1, 1 } } end
		if shape == "inner_right" then return { { 0, 0, 0.5, 1 }, { 0.5, 0, 1, 0.5 } } end
		return { { 0, 0, 0.5, 1 } }
	else
		if shape == "outer_left" then return { { 0.5, 0, 1, 0.5 } } end
		if shape == "outer_right" then return { { 0.5, 0.5, 1, 1 } } end
		if shape == "inner_left" then return { { 0.5, 0, 1, 1 }, { 0, 0, 0.5, 0.5 } } end
		if shape == "inner_right" then return { { 0.5, 0, 1, 1 }, { 0, 0.5, 0.5, 1 } } end
		return { { 0.5, 0, 1, 1 } }
	end
end

local function resolveStairs( stateId, schema )
	local facing = property( stateId, schema, "facing", "north" )
	local half = property( stateId, schema, "half", "bottom" )
	local shape = property( stateId, schema, "shape", "straight" )
	local top = half == "top"
	local key = ( FacingIndex[facing] or 0 ) + ( top and 4 or 0 ) + ( StairShapeIndex[shape] or 0 ) * 8
	local cached = FamilyShapeCache.stairs[key]
	if cached then return cached end
	local boxes = { top and { 0, 0, 0.5, 1, 1, 1 } or { 0, 0, 0, 1, 1, 0.5 } }
	local z0, z1 = top and 0 or 0.5, top and 0.5 or 1
	for _, rect in ipairs( stairStepRects( facing, shape ) ) do
		boxes[#boxes + 1] = { rect[1], rect[2], z0, rect[3], rect[4], z1 }
	end
	cached = internBoxes( boxes )
	FamilyShapeCache.stairs[key] = cached
	return cached
end

local function resolveDoor( stateId, schema )
	local facing = property( stateId, schema, "facing", "north" )
	if property( stateId, schema, "open", false ) == true then
		local hinge = property( stateId, schema, "hinge", "left" )
		facing = hinge == "right" and CounterClockwiseFacing[facing] or ClockwiseFacing[facing]
	end
	local key = FacingIndex[facing] or 0
	local cached = FamilyShapeCache.door[key]
	if cached then return cached end
	cached = internBoxes( { horizontalPlane( facing, 3 / 16, 1 ) } )
	FamilyShapeCache.door[key] = cached
	return cached
end

local function resolveTrapdoor( stateId, schema )
	if property( stateId, schema, "open", false ) == true then
		local facing = property( stateId, schema, "facing", "north" )
		local key = FacingIndex[facing] or 0
		local cached = FamilyShapeCache.trapdoor[key]
		if cached then return cached end
		cached = internBoxes( { horizontalPlane( facing, 3 / 16, 1 ) } )
		FamilyShapeCache.trapdoor[key] = cached
		return cached
	end
	local top = property( stateId, schema, "half", "bottom" ) == "top"
	local key = top and 5 or 4
	local cached = FamilyShapeCache.trapdoor[key]
	if cached then return cached end
	cached = internBoxes( { top and { 0, 0, 13 / 16, 1, 1, 1 } or { 0, 0, 0, 1, 1, 3 / 16 } } )
	FamilyShapeCache.trapdoor[key] = cached
	return cached
end

local function connectionShape( stateId, schema, kind )
	local postWidth = kind == "pane" and 2 / 16 or kind == "wall" and 8 / 16 or 4 / 16
	local armWidth = kind == "wall" and 6 / 16 or postWidth
	local height = kind == "pane" and 1 or 1.5
	local postMin, postMax = ( 1 - postWidth ) / 2, ( 1 + postWidth ) / 2
	local armMin, armMax = ( 1 - armWidth ) / 2, ( 1 + armWidth ) / 2
	local includePost = kind ~= "wall" or property( stateId, schema, "up", true ) == true
	local north = property( stateId, schema, "north", false )
	local south = property( stateId, schema, "south", false )
	local west = property( stateId, schema, "west", false )
	local east = property( stateId, schema, "east", false )
	local mask = ( connectionValue( north ) and 1 or 0 ) + ( connectionValue( east ) and 2 or 0 )
		+ ( connectionValue( south ) and 4 or 0 ) + ( connectionValue( west ) and 8 or 0 )
	local key = mask + ( includePost and 16 or 0 )
	local cache = FamilyShapeCache[kind]
	local cached = cache[key]
	if cached then return cached end
	local boxes = {}
	if includePost then boxes[#boxes + 1] = { postMin, postMin, 0, postMax, postMax, height } end
	local northEnd = kind == "wall" and 11 / 16 or 0.5
	local southStart = kind == "wall" and 5 / 16 or 0.5
	if connectionValue( north ) then
		boxes[#boxes + 1] = { armMin, 0, 0, armMax, northEnd, height }
	end
	if connectionValue( south ) then
		boxes[#boxes + 1] = { armMin, southStart, 0, armMax, 1, height }
	end
	if connectionValue( west ) then
		boxes[#boxes + 1] = { 0, armMin, 0, northEnd, armMax, height }
	end
	if connectionValue( east ) then
		boxes[#boxes + 1] = { southStart, armMin, 0, 1, armMax, height }
	end
	cached = #boxes > 0 and internBoxes( boxes ) or EMPTY_SHAPE
	cache[key] = cached
	return cached
end

local function resolveBuiltInFamily( stateId, schema, visual )
	local block = visual and visual.block or schema.blockId ~= nil and MC.Blocks and MC.Blocks[schema.blockId] or nil
	local name = block and block.name or ""
	local shape = block and block.shape or nil
	local connection = block and block.connection or nil
	local generatedFamily = MC.GeneratedBlockStateCollisionFamilies and MC.GeneratedBlockStateCollisionFamilies[schema.name] or nil
	local projectFallback = schema.generated ~= true

	if generatedFamily == "slab" or projectFallback and hasProperty( schema, "type" ) and ( shape == "slab" or string.match( name, "_slab$" ) ) then
		local slabType = property( stateId, schema, "type", "bottom" )
		if slabType == "double" then return FULL_CUBE_SHAPE end
		local key = slabType == "top" and 1 or 0
		local cached = FamilyShapeCache.slab[key]
		if cached then return cached end
		cached = internBoxes( { slabType == "top" and { 0, 0, 0.5, 1, 1, 1 } or { 0, 0, 0, 1, 1, 0.5 } } )
		FamilyShapeCache.slab[key] = cached
		return cached
	end
	if generatedFamily == "stairs" or projectFallback and hasProperty( schema, "shape" ) and hasProperty( schema, "half" )
	and ( shape == "stairs" or string.match( name, "_stairs$" ) ) then
		return resolveStairs( stateId, schema )
	end
	if generatedFamily == "trapdoor" or projectFallback and string.match( name, "_trapdoor$" ) and hasProperty( schema, "open" ) then return resolveTrapdoor( stateId, schema ) end
	if generatedFamily == "door" or projectFallback and string.match( name, "_door$" ) and hasProperty( schema, "hinge" ) then return resolveDoor( stateId, schema ) end
	if generatedFamily == "fence_gate" or projectFallback and ( connection == "fence_gate" or string.match( name, "_fence_gate$" ) ) then
		if property( stateId, schema, "open", false ) == true then return EMPTY_SHAPE end
		local facing = property( stateId, schema, "facing", "north" )
		local zAxis = facing == "north" or facing == "south"
		local key = zAxis and 0 or 1
		local cached = FamilyShapeCache.fence_gate[key]
		if cached then return cached end
		cached = internBoxes( { zAxis and { 0, 0.375, 0, 1, 0.625, 1.5 } or { 0.375, 0, 0, 0.625, 1, 1.5 } } )
		FamilyShapeCache.fence_gate[key] = cached
		return cached
	end
	if generatedFamily == "fence" or projectFallback and ( connection == "fence" or string.match( name, "_fence$" ) ) then return connectionShape( stateId, schema, "fence" ) end
	if generatedFamily == "wall" or projectFallback and ( connection == "wall" or string.match( name, "_wall$" ) ) then return connectionShape( stateId, schema, "wall" ) end
	if generatedFamily == "pane" or projectFallback and ( connection == "pane" or connection == "bars" or name == "iron_bars" or string.match( name, "_stained_glass_pane$" ) ) then
		return connectionShape( stateId, schema, "pane" )
	end
	if generatedFamily == "snow_layer" or projectFallback and name == "snow" and hasProperty( schema, "layers" ) then
		local layers = math.floor( tonumber( property( stateId, schema, "layers", 1 ) ) or 1 )
		local cached = FamilyShapeCache.snow_layer[layers]
		if cached then return cached end
		local height = ( layers - 1 ) / 8
		cached = height > 0 and internBoxes( { { 0, 0, 0, 1, 1, height } } ) or EMPTY_SHAPE
		FamilyShapeCache.snow_layer[layers] = cached
		return cached
	end
	if generatedFamily == "cake" or projectFallback and name == "cake" and hasProperty( schema, "bites" ) then
		local bites = math.floor( tonumber( property( stateId, schema, "bites", 0 ) ) or 0 )
		local cached = FamilyShapeCache.cake[bites]
		if cached then return cached end
		cached = internBoxes( { { ( 1 + bites * 2 ) / 16, 1 / 16, 0, 15 / 16, 15 / 16, 0.5 } } )
		FamilyShapeCache.cake[bites] = cached
		return cached
	end
	return nil
end

local function collisionFromDefinition( definition, stateId, schema, visual, bx, by, bz )
	local value = definition.Resolve and definition.Resolve( stateId, schema, visual, bx, by, bz ) or definition
	local shape = MC.ResolveBlockStateCollisionShape( value )
	if shape then return shape end
	if type( value ) ~= "table" then return nil, "invalid_collision_result" end
	shape = MC.ResolveBlockStateCollisionShape( value.shape or value.shapeId )
	if shape then return shape end
	if value.boxes ~= nil or value.convexes ~= nil or value.collisionConvexes ~= nil then
		return MC.RegisterBlockStateCollisionShape( value )
	end
	if value.hasCollision == false then return EMPTY_SHAPE end
	return nil, "collision_result_missing_shape"
end

function MC.ResolveBlockStateCollision( stateId, bx, by, bz, visual )
	local cached = MC.BlockStateCollisionCache[stateId]
	if cached ~= nil then
		if cached == false then return nil, "unhandled_state_collision" end
		return cached
	end
	local schema = visual and visual.stateId == stateId and visual.schema
		or MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema then return nil, "invalid_state" end
	local definition = MC.BlockStateCollisionResolvers[schema.name]
	local positionDependent = definition and definition.positionDependent == true

	local shape, err
	if definition then shape, err = collisionFromDefinition( definition, stateId, schema, visual, bx, by, bz ) end
	if not shape and not err then shape = resolveBuiltInFamily( stateId, schema, visual ) end
	if not shape then
		if not positionDependent then MC.BlockStateCollisionCache[stateId] = false end
		return nil, err or "unhandled_state_collision"
	end
	if not positionDependent then
		MC.BlockStateCollisionCache[stateId] = shape
	end
	return shape
end
