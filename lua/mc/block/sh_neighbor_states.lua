-- Small, direct neighbor-derived state rules that do not warrant a separate
-- block implementation yet: snowy ground, campfire smoke source, bubble-column
-- drag direction, and waterlogged extinguishing.

MC = MC or {}

local function primaryState( changes, changeCount, bx, by, bz )
	for index = 1, changeCount do
		local cell = changes[index]
		if cell.bx == bx and cell.by == by and cell.bz == bz then
			if cell.stateId ~= nil then return cell.stateId end
			return MC.StateFromLegacy and MC.StateFromLegacy( cell.id or 0, cell.orient or 0 ) or 0
		end
	end
	return MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
end

local function blockName( stateId )
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	return block and block.name or nil
end

local function schemaProperty( stateId, propertyName )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.propertyByName and schema.propertyByName[propertyName] or nil
end

local function stateProperty( stateId, propertyName )
	return MC.GetStateProperty and MC.GetStateProperty( stateId, propertyName ) or nil
end

local function setIfDifferent( updates, changes, changeCount, bx, by, bz, stateId, propertyName, value )
	if not stateId or stateId == 0 or not schemaProperty( stateId, propertyName ) then return end
	local nextState = MC.StateWith( stateId, propertyName, value ) or stateId
	local worldState = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if nextState ~= worldState then
		updates[#updates + 1] = { bx = bx, by = by, bz = bz, stateId = nextState }
	end
end

local function isSnow( name )
	return name == "snow" or name == "snow_block" or name == "powder_snow"
end

local function resolveCandidate( changes, changeCount, bx, by, bz, updates )
	local stateId = primaryState( changes, changeCount, bx, by, bz )
	if not stateId or stateId == 0 then return end
	local name = blockName( stateId )
	if schemaProperty( stateId, "snowy" ) then
		setIfDifferent( updates, changes, changeCount, bx, by, bz,
			stateId, "snowy", isSnow( blockName( primaryState( changes, changeCount, bx, by, bz + 1 ) ) ) )
	end
	if schemaProperty( stateId, "signal_fire" ) then
		setIfDifferent( updates, changes, changeCount, bx, by, bz,
			stateId, "signal_fire", blockName( primaryState( changes, changeCount, bx, by, bz - 1 ) ) == "hay_block" )
	end
	if schemaProperty( stateId, "drag" ) and name == "bubble_column" then
		local belowName = blockName( primaryState( changes, changeCount, bx, by, bz - 1 ) )
		local dragDown = belowName == "magma_block"
		if belowName ~= "magma_block" and belowName ~= "soul_sand" then dragDown = stateProperty( stateId, "drag" ) == true end
		setIfDifferent( updates, changes, changeCount, bx, by, bz, stateId, "drag", dragDown )
	end
	if schemaProperty( stateId, "waterlogged" ) and schemaProperty( stateId, "lit" )
	and stateProperty( stateId, "waterlogged" ) == true then
		setIfDifferent( updates, changes, changeCount, bx, by, bz, stateId, "lit", false )
	end
end

function MC.BuildNeighbourStateUpdates( changes, changeCount )
	if not changes or #changes == 0 then return {} end
	changeCount = math.min( math.floor( tonumber( changeCount ) or #changes ), #changes )
	local candidates, seen = {}, {}
	local function add( bx, by, bz )
		local key = MC.CellKey( bx, by, bz )
		if seen[key] then return end
		seen[key] = true
		candidates[#candidates + 1] = { bx = bx, by = by, bz = bz }
	end
	for index = 1, changeCount do
		local cell = changes[index]
		add( cell.bx, cell.by, cell.bz )
		add( cell.bx, cell.by, cell.bz - 1 )
		add( cell.bx, cell.by, cell.bz + 1 )
	end
	local updates = {}
	for index = 1, #candidates do
		local candidate = candidates[index]
		resolveCandidate( changes, changeCount, candidate.bx, candidate.by, candidate.bz, updates )
	end
	return updates
end
