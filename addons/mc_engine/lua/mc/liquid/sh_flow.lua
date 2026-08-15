-- Minecraft FlowingFluid#getFlow in project X/Y/Z coordinates.

MC = MC or {}
MC.Liquid = MC.Liquid or {}

local Liquid = MC.Liquid
local decodeState = Liquid.DecodeState
local sqrt = math.sqrt
local FACE_XP = Liquid.FACE_XP
local FACE_XN = Liquid.FACE_XN
local FACE_YP = Liquid.FACE_YP
local FACE_YN = Liquid.FACE_YN

local HorizontalDirections = {
	{ 1, 0, FACE_XP },
	{ -1, 0, FACE_XN },
	{ 0, 1, FACE_YP },
	{ 0, -1, FACE_YN },
}

local function stateBlocksMotion( stateId, bx, by, bz )
	if not stateId or stateId == 0 then return false end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
	local block = MC.Blocks and MC.Blocks[id] or nil
	local name = block and block.name or nil
	if name == "cobweb" or name == "bamboo_sapling" then return false end
	return Liquid.StateSolid and Liquid.StateSolid( stateId, bx, by, bz ) == true or false
end

local function flowDistance( bx, by, bz, kind, ownHeight, dx, dy )
	local nx, ny = bx + dx, by + dy
	local neighbourState = MC.GetBlockState( nx, ny, bz ) or 0
	local neighbourKind, neighbourHeight = decodeState( neighbourState )
	if neighbourKind == kind then return ownHeight - neighbourHeight end
	-- FlowingFluid#affectsFlow ignores a different liquid type entirely.
	if neighbourKind or stateBlocksMotion( neighbourState, nx, ny, bz ) then return 0 end
	local belowState = MC.GetBlockState( nx, ny, bz - 1 ) or 0
	local belowKind, belowHeight = decodeState( belowState )
	if belowKind ~= kind or belowHeight <= 0 then return 0 end
	return ownHeight - ( belowHeight - 8 / 9 )
end

local function isIceState( stateId )
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
	local block = MC.Blocks and MC.Blocks[id] or nil
	local name = block and block.name or nil
	return name == "ice" or name == "frosted_ice" or name == "packed_ice" or name == "blue_ice"
end

local function fallingTouchesSolidFace( bx, by, bz, kind )
	for index = 1, 4 do
		local direction = HorizontalDirections[index]
		local nx, ny = bx + direction[1], by + direction[2]
		for dz = 0, 1 do
			local nz = bz + dz
			local stateId = MC.GetBlockState( nx, ny, nz ) or 0
			local neighbourKind = decodeState( stateId )
			if neighbourKind ~= kind and not isIceState( stateId )
			and Liquid.FaceSturdyForFlow( stateId, nx, ny, nz, direction[3] ) then
				return true
			end
		end
	end
	return false
end

function MC.LiquidFlowAtCell( bx, by, bz, requiredKind )
	if not MC.GetBlockState then return 0, 0, 0 end
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, ownHeight, _, falling = decodeState( stateId )
	if not kind or requiredKind and kind ~= requiredKind then return 0, 0, 0 end

	local flowX = flowDistance( bx, by, bz, kind, ownHeight, 1, 0 )
		- flowDistance( bx, by, bz, kind, ownHeight, -1, 0 )
	local flowY = flowDistance( bx, by, bz, kind, ownHeight, 0, 1 )
		- flowDistance( bx, by, bz, kind, ownHeight, 0, -1 )
	local horizontalLength = sqrt( flowX * flowX + flowY * flowY )
	if horizontalLength > 0.000001 then
		flowX, flowY = flowX / horizontalLength, flowY / horizontalLength
	else
		flowX, flowY = 0, 0
	end

	local flowZ = 0
	if falling and fallingTouchesSolidFace( bx, by, bz, kind ) then
		flowZ = -6
	end
	local length = sqrt( flowX * flowX + flowY * flowY + flowZ * flowZ )
	if length <= 0.000001 then return 0, 0, 0 end
	return flowX / length, flowY / length, flowZ / length
end

Liquid.StateBlocksMotion = stateBlocksMotion
