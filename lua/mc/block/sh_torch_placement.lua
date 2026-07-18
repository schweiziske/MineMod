-- Vanilla torch item placement: floor variants become wall variants when the
-- clicked support face is horizontal, while shared properties (notably lit)
-- are preserved across the block-type change.

MC = MC or {}

local GroundToWall = {
	["minecraft:torch"] = "minecraft:wall_torch",
	["minecraft:soul_torch"] = "minecraft:soul_wall_torch",
	["minecraft:redstone_torch"] = "minecraft:redstone_wall_torch",
	["minecraft:copper_torch"] = "minecraft:copper_wall_torch",
}
local WallToGround = {}
for ground, wall in pairs( GroundToWall ) do WallToGround[wall] = ground end

local function facingForNormal( normal )
	if not normal then return nil end
	if math.abs( normal.x or 0 ) >= math.abs( normal.y or 0 ) then
		return ( normal.x or 0 ) >= 0 and "east" or "west"
	end
	return ( normal.y or 0 ) >= 0 and "south" or "north"
end

local function stateSchemaName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil, schema
end

local function copySharedProperties( sourceState, targetState )
	local targetSchema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( targetState ) or nil
	if not targetSchema or not targetSchema.properties then return targetState end
	for index = 1, #targetSchema.properties do
		local property = targetSchema.properties[index]
		local value = MC.GetStateProperty and MC.GetStateProperty( sourceState, property.name ) or nil
		if value ~= nil then targetState = MC.StateWith( targetState, property.name, value ) or targetState end
	end
	return targetState
end

function MC.ResolveTorchPlacementState( stateId, hitNormal )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 1 then return stateId end
	local name = stateSchemaName( stateId )
	local ground = WallToGround[name] or name
	local wall = GroundToWall[ground]
	if not wall then return stateId end

	local normalZ = hitNormal and tonumber( hitNormal.z ) or 1
	if normalZ < -0.5 then return nil, "torch_ceiling_unsupported" end
	local targetName = normalZ > 0.5 and ground or wall
	local targetSchema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[targetName] or nil
	if not targetSchema or targetSchema.defaultStateId == nil then return nil, "torch_state_missing" end
	local targetState = copySharedProperties( stateId, targetSchema.defaultStateId )
	if targetName == wall then
		local facing = facingForNormal( hitNormal )
		if not facing then return nil, "torch_wall_face_missing" end
		targetState = MC.StateWith( targetState, "facing", facing )
		if not targetState then return nil, "torch_wall_facing_invalid" end
	end
	return targetState
end
