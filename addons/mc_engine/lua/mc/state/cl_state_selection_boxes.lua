-- Shared state-native selection boxes for authoritative aiming and outlines.
--
-- Prefer authored state collision boxes for solid shapes (stairs, doors,
-- fences, walls, slabs), then derive bounds from the exact compact visual-plan
-- models for non-colliding shapes such as rails, redstone and open gates.

MC = MC or {}

-- Selection (outline) shapes stay inside their own cell, like Java's
-- Block#getShape. Collision shapes such as fences reach 1.5 blocks high, so
-- they are clipped to [0,1] when used as a selection fallback. This keeps the
-- block ray a plain single-cell DDA that never has to inspect neighbours.
MC.BlockSelectionMin = 0
MC.BlockSelectionMax = 1
MC.BlockStateSelectionBoxes = MC.BlockStateSelectionBoxes or {}
local EMPTY_BOXES = {}
-- source geometry table -> normalized (validated, cell-clipped) table or false
local NormalizedBoxes = setmetatable( {}, { __mode = "k" } )
local ModelBounds = setmetatable( {}, { __mode = "k" } )
-- stateId -> normalized boxes or false (nil geometry), for states whose shape
-- does not depend on position. Dropped whenever the visual revision changes.
local StateBoxes = {}
local StateBoxesRevision

-- CampfireBlock#getShape uses the base, regardless of facing or lit state.
local CAMPFIRE_SELECTION_BOXES = { { 0, 0, 0, 1, 1, 7 / 16 } }

local function sameBox( a, b )
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
		and a[4] == b[4] and a[5] == b[5] and a[6] == b[6]
end

local function clip01( value )
	if value < 0 then return 0 end
	if value > 1 then return 1 end
	return value
end

-- Validates once per geometry table and returns an immutable cell-clipped
-- copy (or the input itself when it already lies inside the cell).
local function normalizedBoxes( boxes )
	if boxes == nil then return nil end
	if type( boxes ) ~= "table" then
		MC.Fault( "selection_boxes_invalid", "selection boxes must be a table" )
		return EMPTY_BOXES
	end
	local cached = NormalizedBoxes[boxes]
	if cached ~= nil then return cached or EMPTY_BOXES end
	local clipped
	for index, box in ipairs( boxes ) do
		if type( box ) ~= "table" then
			MC.Fault( "selection_box_invalid", "selection box must be a table" )
			NormalizedBoxes[boxes] = false
			return EMPTY_BOXES
		end
		for axis = 1, 3 do
			local lo, hi = box[axis], box[axis + 3]
			if type( lo ) ~= "number" or type( hi ) ~= "number"
				or lo ~= lo or hi ~= hi or lo == math.huge or hi == -math.huge or lo > hi then
				MC.Fault( "selection_box_invalid", "selection bounds must be finite and ordered" )
				NormalizedBoxes[boxes] = false
				return EMPTY_BOXES
			end
			if not clipped and ( lo < 0 or hi > 1 ) then
				clipped = {}
				for previous = 1, index - 1 do clipped[previous] = boxes[previous] end
			end
		end
		if clipped then
			local x0, y0, z0 = clip01( box[1] ), clip01( box[2] ), clip01( box[3] )
			local x1, y1, z1 = clip01( box[4] ), clip01( box[5] ), clip01( box[6] )
			-- A box entirely outside the cell contributes nothing to this cell.
			if x0 < x1 and y0 < y1 and z0 < z1 then
				clipped[#clipped + 1] = { x0, y0, z0, x1, y1, z1 }
			end
		end
	end
	local result = clipped or boxes
	NormalizedBoxes[boxes] = result
	NormalizedBoxes[result] = result
	return result
end

-- Internal engine registration for selection shapes that differ from both
-- collision and rendering. Register on both realms; replace rather than
-- mutate the returned immutable geometry when the definition changes.
function MC.RegisterBlockStateSelectionBoxes( blockName, boxes )
	if type( blockName ) ~= "string" or not MC.BlockStateSchemaByName[blockName] then
		return nil, "invalid_block_name"
	end
	local validated = normalizedBoxes( boxes )
	if not validated or validated == EMPTY_BOXES then return nil, "invalid_selection_boxes" end
	local copy = {}
	for index, box in ipairs( validated ) do
		copy[index] = { box[1], box[2], box[3], box[4], box[5], box[6] }
	end
	NormalizedBoxes[copy] = copy
	MC.BlockStateSelectionBoxes[blockName] = copy
	StateBoxesRevision = nil
	return copy
end

for _, blockName in ipairs( { "minecraft:campfire", "minecraft:soul_campfire" } ) do
	local registered, err = MC.RegisterBlockStateSelectionBoxes( blockName, CAMPFIRE_SELECTION_BOXES )
	MC.Check( registered ~= nil, "selection_registration_failed", "%s: %s", blockName, tostring( err ) )
end

local function modelBounds( modelId )
	local data = MC.StateVisualModelData and MC.StateVisualModelData( modelId ) or nil
	local quads = data and data.modelQuads or nil
	if not quads or #quads == 0 or not MC.ModelQuadVertex then return end
	local cached = ModelBounds[data]
	if cached then return cached end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for quadIndex = 1, #quads do
		local quad = quads[quadIndex]
		for vertexIndex = 1, 4 do
			local x, y, z = MC.ModelQuadVertex( quad, vertexIndex )
			if x < minX then minX = x end
			if y < minY then minY = y end
			if z < minZ then minZ = z end
			if x > maxX then maxX = x end
			if y > maxY then maxY = y end
			if z > maxZ then maxZ = z end
		end
	end
	if minX == math.huge then return end

	local boxes = normalizedBoxes( { { minX, minY, minZ, maxX, maxY, maxZ } } )
	ModelBounds[data] = boxes
	return boxes
end

local function appendModelBounds( boxes, modelId )
	local bounds = modelBounds( modelId )
	if bounds == EMPTY_BOXES then return false end
	local box = bounds and bounds[1]
	if not box then return true end
	for index = 1, #boxes do
		if sameBox( boxes[index], box ) then return true end
	end
	boxes[#boxes + 1] = box
	return true
end

local function selectionIsPositionDependent( id, schema )
	local name = schema and schema.name
	local visualResolver = name and MC.BlockStateVisualResolvers and MC.BlockStateVisualResolvers[name]
	local collisionResolver = name and MC.BlockStateCollisionResolvers and MC.BlockStateCollisionResolvers[name]
	return visualResolver ~= nil and visualResolver.positionDependent == true
		or collisionResolver ~= nil and collisionResolver.positionDependent == true
		or id ~= nil and MC.BlockCollisionDependsOnNeighbours ~= nil
			and MC.BlockCollisionDependsOnNeighbours( id ) == true
end

local function resolveSelectionBoxes( stateId, id, block, schema, bx, by, bz )
	local boxes = schema and MC.BlockStateSelectionBoxes[schema.name] or nil
	-- Keep the existing crossed-plane selection shape instead of replacing it
	-- with the full AABB of its diagonal quads.
	if boxes == nil and block and block.shape == "cross" then
		boxes = MC.BlockBoxesForState and MC.BlockBoxesForState( stateId, bx, by, bz ) or nil
	end

	-- Solid blocks use their state geometry, not the union AABB of decorative
	-- quads. This preserves gaps in stairs, fences, walls and open doors.
	if boxes == nil and MC.GetBlockCollisionBoxesForState then
		local collisionBoxes = MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz )
		if collisionBoxes and #collisionBoxes > 0 then boxes = collisionBoxes end
	end

	if boxes == nil and MC.VisitStateVisualModels and MC.StateVisualModelData then
		local generated = {}
		local valid = true
		MC.VisitStateVisualModels( stateId, bx, by, bz, function( modelId )
			if not appendModelBounds( generated, modelId ) then valid = false end
		end )
		if not valid then return EMPTY_BOXES end
		if #generated > 0 then
			-- Every component was normalized when its model bounds were built.
			NormalizedBoxes[generated] = generated
			boxes = generated
		end
	end

	if boxes == nil and MC.BlockBoxesForState then boxes = MC.BlockBoxesForState( stateId, bx, by, bz ) end
	return normalizedBoxes( boxes )
end

-- Returns cell-local boxes inside [0,1], EMPTY (unselectable) or nil
-- (unspecified geometry). Results are cached per state unless the shape
-- depends on position; any visual/selection redefinition drops the cache.
function MC.BlockSelectionBoxesForState( stateId, bx, by, bz )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 0 then return nil end
	local revision = MC.BlockStateVisualRevision or 0
	if StateBoxesRevision ~= revision then
		StateBoxes = {}
		StateBoxesRevision = revision
	end
	local cached = StateBoxes[stateId]
	if cached ~= nil then return cached or nil end

	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local boxes = resolveSelectionBoxes( stateId, id, block, schema, bx, by, bz )
	if not selectionIsPositionDependent( id, schema ) then
		StateBoxes[stateId] = boxes or false
	end
	return boxes
end
