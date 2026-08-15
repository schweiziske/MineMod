-- Shared state-native selection boxes for authoritative aiming and outlines.
--
-- Prefer authored state collision boxes for solid shapes (stairs, doors,
-- fences, walls, slabs), then derive bounds from the exact compact visual-plan
-- models for non-colliding shapes such as rails, redstone and open gates.

MC = MC or {}

local LastStateId, LastX, LastY, LastZ, LastBoxes

local function sameBox( a, b )
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
		and a[4] == b[4] and a[5] == b[5] and a[6] == b[6]
end

local function appendModelBounds( boxes, modelId )
	local data = MC.StateVisualModelData and MC.StateVisualModelData( modelId ) or nil
	local quads = data and data.modelQuads or nil
	if not quads or #quads == 0 or not MC.ModelQuadVertex then return end

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

	local box = { minX, minY, minZ, maxX, maxY, maxZ }
	for index = 1, #boxes do
		if sameBox( boxes[index], box ) then return end
	end
	boxes[#boxes + 1] = box
end

function MC.BlockSelectionBoxesForState( stateId, bx, by, bz )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 0 then return nil end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local collisionResolver = schema and MC.BlockStateCollisionResolvers
		and MC.BlockStateCollisionResolvers[schema.name] or nil
	local positionDependent = collisionResolver and collisionResolver.positionDependent == true
		or id and MC.BlockCollisionDependsOnNeighbours and MC.BlockCollisionDependsOnNeighbours( id ) == true
	if not positionDependent and stateId == LastStateId and bx == LastX and by == LastY and bz == LastZ then
		return LastBoxes
	end

	local boxes
	-- Keep the existing crossed-plane selection shape instead of replacing it
	-- with the full AABB of its diagonal quads.
	if block and block.shape == "cross" then
		boxes = MC.BlockBoxesForState and MC.BlockBoxesForState( stateId, bx, by, bz ) or nil
	end

	-- A stair model contains several cuboids inside one model instance, so its
	-- overall visual AABB would collapse back to a full cube. Use the authored
	-- state collision boxes to preserve straight/inner/outer stair steps.
	if boxes == nil and block and block.shape == "stairs" and MC.GetBlockCollisionBoxesForState then
		local collisionBoxes = MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz )
		if collisionBoxes and #collisionBoxes > 0 then boxes = collisionBoxes end
	end

	if boxes == nil and MC.VisitStateVisualModels and MC.StateVisualModelData then
		local generated = {}
		MC.VisitStateVisualModels( stateId, bx, by, bz, function( modelId )
			appendModelBounds( generated, modelId )
		end )
		if #generated > 0 then boxes = generated end
	end

	if boxes == nil and MC.GetBlockCollisionBoxesForState then
		local collisionBoxes = MC.GetBlockCollisionBoxesForState( stateId, bx, by, bz )
		if collisionBoxes and #collisionBoxes > 0 then boxes = collisionBoxes end
	end

	if boxes == nil and MC.BlockBoxesForState then boxes = MC.BlockBoxesForState( stateId, bx, by, bz ) end
	if positionDependent then
		LastStateId, LastX, LastY, LastZ, LastBoxes = nil, nil, nil, nil, nil
	else
		LastStateId, LastX, LastY, LastZ, LastBoxes = stateId, bx, by, bz, boxes
	end
	return boxes
end
