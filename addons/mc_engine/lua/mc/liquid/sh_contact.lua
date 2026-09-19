-- Point and player-AABB contact queries against Minecraft fluid surfaces.

MC = MC or {}
MC.Liquid = MC.Liquid or {}

local Liquid = MC.Liquid
local decodeState = Liquid.DecodeState
local floor = math.floor
local max = math.max
local min = math.min

local HORIZONTAL_INSET = 2
local VERTICAL_PADDING = 1

local function liquidAtPoint( x, y, z )
	if not MC.GetBlockState then return nil end
	local blockSize = MC.API.Coords.BlockSize()
	local bx, by, bz = floor( x / blockSize ), floor( y / blockSize ), floor( z / blockSize )
	local stateId = MC.GetBlockState( bx, by, bz ) or 0
	local kind, _, level, falling = decodeState( stateId )
	if not kind then return nil end
	local height = MC.LiquidHeightAtCell( bx, by, bz, kind )
	local surfaceZ = ( bz + height ) * blockSize
	if z >= surfaceZ then return nil end
	return {
		bx = bx, by = by, bz = bz,
		id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0,
		stateId = stateId, kind = kind,
		height = height, surfaceZ = surfaceZ,
		level = level, falling = falling,
	}
end

function MC.LiquidAtPos( pos )
	if not pos then return nil end
	return liquidAtPoint( pos.x, pos.y, pos.z )
end

function MC.PlayerEyeLiquid( ply )
	if not IsValid( ply ) or not ply.EyePos then return nil end
	local eye, err = MC.API.Coords.EntityEyeWorldPos( ply )
	if not eye then
		MC.Fault( "liquid_eye_world_position", "liquid eye query: %s", tostring( err ) )
		return nil
	end
	return liquidAtPoint( eye.x, eye.y, eye.z )
end

local function playerMoveBounds( ply, mv )
	local pos, err
	if mv and mv.GetOrigin then
		pos, err = MC.API.Coords.MoveOriginWorldPos( ply, mv:GetOrigin() )
	else
		pos, err = MC.API.Coords.EntityWorldPos( ply )
	end
	if not pos then
		MC.Fault( "liquid_move_world_position", "liquid body query: %s", tostring( err ) )
		return nil
	end
	local mins = ply:OBBMins()
	local maxs = ply:OBBMaxs()
	local maxInset = max( 0, min( ( maxs.x - mins.x ) * 0.45, ( maxs.y - mins.y ) * 0.45 ) )
	local inset = min( HORIZONTAL_INSET, maxInset )
	return pos.x + mins.x + inset,
		pos.y + mins.y + inset,
		pos.z + mins.z - VERTICAL_PADDING,
		pos.x + maxs.x - inset,
		pos.y + maxs.y - inset,
		pos.z + maxs.z + VERTICAL_PADDING
end

function MC.PlayerLiquidContact( ply, mv )
	if not IsValid( ply ) or not MC.GetBlockState then return nil end
	local x0, y0, z0, x1, y1, z1 = playerMoveBounds( ply, mv )
	if x0 == nil then return nil end
	local blockSize = MC.API.Coords.BlockSize()
	local minBx, minBy, minBz = floor( x0 / blockSize ), floor( y0 / blockSize ), floor( z0 / blockSize )
	local maxBx, maxBy, maxBz = floor( x1 / blockSize ), floor( y1 / blockSize ), floor( z1 / blockSize )
	local bestWater, bestLava
	local bestWaterDepth, bestLavaDepth = -1, -1
	local waterFlowX, waterFlowY, waterFlowZ, waterFlowCount = 0, 0, 0, 0
	local lavaFlowX, lavaFlowY, lavaFlowZ, lavaFlowCount = 0, 0, 0, 0

	for bz = minBz, maxBz do
		local cellBottom = bz * blockSize
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local stateId = MC.GetBlockState( bx, by, bz ) or 0
				local kind, _, level, falling = decodeState( stateId )
				if kind then
					local height = MC.LiquidHeightAtCell( bx, by, bz, kind )
					local surfaceZ = cellBottom + height * blockSize
					if z1 > cellBottom and z0 < surfaceZ then
						local depth = max( 0, ( surfaceZ - z0 ) / blockSize )
						local flowX, flowY, flowZ = 0, 0, 0
						if MC.LiquidFlowAtCell then flowX, flowY, flowZ = MC.LiquidFlowAtCell( bx, by, bz, kind ) end
						local depthScale = depth < 0.4 and depth or 1
						flowX, flowY, flowZ = flowX * depthScale, flowY * depthScale, flowZ * depthScale
						if kind == "lava" then
							lavaFlowX, lavaFlowY, lavaFlowZ = lavaFlowX + flowX, lavaFlowY + flowY, lavaFlowZ + flowZ
							lavaFlowCount = lavaFlowCount + 1
						else
							waterFlowX, waterFlowY, waterFlowZ = waterFlowX + flowX, waterFlowY + flowY, waterFlowZ + flowZ
							waterFlowCount = waterFlowCount + 1
						end
						local previousDepth = kind == "lava" and bestLavaDepth or bestWaterDepth
						if depth > previousDepth then
							local contact = {
								bx = bx, by = by, bz = bz,
								id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0,
								stateId = stateId, kind = kind,
								height = height, surfaceZ = surfaceZ, depth = depth,
								level = level, falling = falling,
							}
							if kind == "lava" then
								bestLava, bestLavaDepth = contact, depth
							else
								bestWater, bestWaterDepth = contact, depth
							end
						end
					end
				end
			end
		end
	end
	local best, flowX, flowY, flowZ, flowCount
	if bestLava then
		best, flowX, flowY, flowZ, flowCount = bestLava, lavaFlowX, lavaFlowY, lavaFlowZ, lavaFlowCount
	else
		best, flowX, flowY, flowZ, flowCount = bestWater, waterFlowX, waterFlowY, waterFlowZ, waterFlowCount
	end
	if best and flowCount > 0 then
		best.flowX, best.flowY, best.flowZ = flowX / flowCount, flowY / flowCount, flowZ / flowCount
	end
	return best
end

Liquid.PointContact = liquidAtPoint
