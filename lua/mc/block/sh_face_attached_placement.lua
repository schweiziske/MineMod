-- Vanilla attachment support shared by levers, buttons and floor-only pressure
-- plates. The clicked support face determines lever/button floor/wall/ceiling;
-- pressure plates always validate the cell directly below.

MC = MC or {}

local HorizontalOffset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
}

-- MC.Liquid uses the six vanilla-style outward face directions for its
-- collision-face coverage test. Reuse it instead of allocating/scanning boxes
-- on every placement or neighbour update.
local SupportFace = {
	north = 6, south = 5,
	west = 4, east = 3,
}

local FaceAttachedState = {}
local PressurePlateState = {}

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

local function isFaceAttachedState( stateId )
	local cached = FaceAttachedState[stateId]
	if cached ~= nil then return cached end
	local name = stateName( stateId )
	local attached = name == "minecraft:lever" or name and string.match( name, "_button$" ) ~= nil or false
	if name or MC.BlockStateRegistryFrozen then FaceAttachedState[stateId] = attached end
	return attached
end

local function isPressurePlateState( stateId )
	local cached = PressurePlateState[stateId]
	if cached ~= nil then return cached end
	local name = stateName( stateId )
	local pressurePlate = name and string.match( name, "_pressure_plate$" ) ~= nil or false
	if name or MC.BlockStateRegistryFrozen then PressurePlateState[stateId] = pressurePlate end
	return pressurePlate
end

local function horizontalFacingForPlayer( ply )
	local forward = IsValid( ply ) and ply:EyeAngles():Forward() or nil
	if not forward then return "north" end
	if math.abs( forward.x ) > math.abs( forward.y ) then return forward.x >= 0 and "east" or "west" end
	return forward.y >= 0 and "south" or "north"
end

local function facingForNormal( normal )
	if math.abs( normal.x or 0 ) >= math.abs( normal.y or 0 ) then
		return ( normal.x or 0 ) >= 0 and "east" or "west"
	end
	return ( normal.y or 0 ) >= 0 and "south" or "north"
end

function MC.ResolveFaceAttachedPlacementState( stateId, hitNormal, ply )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 1 or not isFaceAttachedState( stateId ) then return stateId end
	local normalZ = tonumber( hitNormal and hitNormal.z ) or 1
	local face, facing
	if normalZ > 0.5 then
		face, facing = "floor", horizontalFacingForPlayer( ply )
	elseif normalZ < -0.5 then
		face, facing = "ceiling", horizontalFacingForPlayer( ply )
	else
		face, facing = "wall", facingForNormal( hitNormal or {} )
	end
	stateId = MC.StateWith( stateId, "face", face ) or stateId
	stateId = MC.StateWith( stateId, "facing", facing ) or stateId
	return stateId
end

function MC.FaceAttachedSupportCell( bx, by, bz, stateId )
	if isPressurePlateState( stateId ) then return bx, by, bz - 1, 1 end
	if not isFaceAttachedState( stateId ) then return nil end
	local face = MC.GetStateProperty( stateId, "face" )
	if face == "floor" then return bx, by, bz - 1, 1 end
	if face == "ceiling" then return bx, by, bz + 1, 2 end
	local facing = MC.GetStateProperty( stateId, "facing" )
	local offset = HorizontalOffset[facing]
	if not offset then return nil end
	return bx - offset[1], by - offset[2], bz, SupportFace[facing]
end

function MC.FaceAttachedCanSurvive( bx, by, bz, stateId )
	local sx, sy, sz, supportFace = MC.FaceAttachedSupportCell( bx, by, bz, stateId )
	if sx == nil then return true end
	local supportState = MC.GetBlockState and MC.GetBlockState( sx, sy, sz ) or 0
	if supportState == 0 then return false end
	local liquid = MC.Liquid
	if supportFace and liquid and liquid.FaceSturdyForFlow then
		return liquid.FaceSturdyForFlow( supportState, sx, sy, sz, supportFace ) == true
	end
	return MC.BlockIsFullCubeForState
		and MC.BlockIsFullCubeForState( supportState, sx, sy, sz ) == true or false
end
