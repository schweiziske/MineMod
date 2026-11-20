local Coords = MC.API.Coords
local SoundTypes = MC.GeneratedSoundTypes
local stepCatalog = "mc/generated/sh_generated_sound_steps.lua"
if SERVER then AddCSLuaFile( stepCatalog ) end
local StepOverrides = include( stepCatalog )
local StepWeights = {}
for soundType, set in pairs( SoundTypes ) do
	local candidates = StepOverrides[soundType] or set.hits
	if candidates and not StepWeights[candidates] then
		local total = 0
		for _, candidate in ipairs( candidates ) do
			total = total + ( candidate.weight or 1 )
		end
		StepWeights[candidates] = total
	end
end

local TerrainGround = {
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
}

-- Match Source's short ground probe, allowing for collision rounding.
local CONTACT_ABOVE = 0.125
local CONTACT_BELOW = 2.125
local EDGE_INSET = 0.0625
local floor, min, max = math.floor, math.min, math.max

local function findSupport( feet, size, minX, minY, maxX, maxY )
	local bottom, top = feet.z - CONTACT_BELOW, feet.z + CONTACT_ABOVE
	local bestId, bestX, bestY
	local hasConvex = false
	local bestDistance, bestHeight = math.huge, -math.huge
	-- Fences and walls can extend above the cell that owns them.
	for bz = floor( top / size ), floor( bottom / size ) - 1, -1 do
		local baseZ = bz * size
		for by = floor( minY / size ), floor( maxY / size ) do
			local baseY = by * size
			for bx = floor( minX / size ), floor( maxX / size ) do
				local state = MC.GetBlockState( bx, by, bz )
				if state and state ~= 0 then
					local baseX = bx * size
					local boxes = MC.GetBlockCollisionBoxesForState( state, bx, by, bz )
					if feet.z <= baseZ + size + CONTACT_BELOW then
						hasConvex = hasConvex or MC.BlockHasCollisionForState( state, bx, by, bz )
					end
					if boxes then
						for _, box in ipairs( boxes ) do
							local height = baseZ + box[6] * size
							if height >= bottom and height <= top then
								local left = max( minX, baseX + box[1] * size + EDGE_INSET )
								local right = min( maxX, baseX + box[4] * size - EDGE_INSET )
								local front = max( minY, baseY + box[2] * size + EDGE_INSET )
								local back = min( maxY, baseY + box[5] * size - EDGE_INSET )
								if left <= right and front <= back then
									local x = math.Clamp( feet.x, left, right )
									local y = math.Clamp( feet.y, front, back )
									local dx, dy = x - feet.x, y - feet.y
									local distance = dx * dx + dy * dy
									if distance < bestDistance or ( distance == bestDistance and height > bestHeight ) then
										bestId = MC.LegacyFromState( state )
										bestX, bestY = x, y
										bestDistance, bestHeight = distance, height
									end
								end
							end
						end
					end
				end
			end
		end
	end
	return bestId, bestX, bestY, hasConvex
end

local function traceSupport( ply, pos, x, y, expectedId )
	local trace = util.TraceLine( {
		start = Vector( x, y, pos.z + CONTACT_ABOVE ),
		endpos = Vector( x, y, pos.z - CONTACT_BELOW ),
		filter = ply,
		mask = MASK_PLAYERSOLID,
		collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT,
	} )
	if not trace.Hit then
		-- Other players' terrain collision is not generally present on this client.
		if CLIENT and ply ~= LocalPlayer() then return expectedId end
		return nil
	end
	if not ( IsValid( trace.Entity ) and TerrainGround[trace.Entity:GetClass()] ) then return nil end
	if expectedId then return expectedId end
	if trace.StartSolid or trace.HitNormal.z <= 0 then return nil end
	-- Ramps and other convex collision can have a surface between box tops.
	local hit = trace.HitPos
	hit.z = hit.z - EDGE_INSET
	local bx, by, bz = Coords.EngineToCell( hit, ply )
	if not bx then return nil end
	local id = MC.GetBlock( bx, by, bz )
	if id ~= 0 then return id end
end

local function footstepBlock( ply, pos )
	local ground = ply:GetGroundEntity()
	local validGround = IsValid( ground )
	local onTerrain = validGround and TerrainGround[ground:GetClass()]
	if validGround and not onTerrain then return nil end
	if next( MC.World ) == nil then return nil end

	local feet = Coords.EngineToWorld( pos, ply )
	if not feet then return nil end
	local size = Coords.BlockSize()
	local bx, by = floor( feet.x / size ), floor( feet.y / size )
	local bz = floor( ( feet.z - CONTACT_BELOW ) / size )
	local surface = ( bz + 1 ) * size
	-- Built-in full cubes at the centre of the hull need only their cell lookup.
	if onTerrain and feet.z >= surface - CONTACT_ABOVE and feet.z <= surface + CONTACT_BELOW then
		local state = MC.GetBlockState( bx, by, bz )
		if state and state ~= 0 then
			local visual = MC.ResolveBlockStateVisual( state, bx, by, bz )
			if MC.BlockVisualIsFullCube( visual, bx, by, bz ) and MC.BlockVisualHasCollision( visual, bx, by, bz ) then
				return visual.id
			end
		end
	end

	local id, _, _, hasConvex = findSupport( feet, size, feet.x, feet.y, feet.x, feet.y )
	if id then
		-- The movement hook can normalize MC ground to worldspawn. Verify that a
		-- nearby voxel isn't underneath a Source brush or prop at the same height.
		if onTerrain then return id end
		return traceSupport( ply, pos, pos.x, pos.y, id )
	end
	if hasConvex then
		id = traceSupport( ply, pos, pos.x, pos.y )
		if id then return id end
	end

	local mins, maxs = ply:GetCollisionBounds()
	local x, y
	id, x, y = findSupport( feet, size, feet.x + mins.x, feet.y + mins.y, feet.x + maxs.x, feet.y + maxs.y )
	if not id then return nil end
	if onTerrain then return id end
	return traceSupport( ply, pos, pos.x + ( x - feet.x ), pos.y + ( y - feet.y ), id )
end

local function selectStep( candidates )
	local roll = math.random( StepWeights[candidates] )
	for _, candidate in ipairs( candidates ) do
		roll = roll - ( candidate.weight or 1 )
		if roll <= 0 then return candidate end
	end
end

hook.Add( "PlayerFootstep", "mc_block_footsteps", function( ply, pos, _foot, _defaultSound, volume, recipients )
	if not ply:Alive() or ply:GetMoveType() ~= MOVETYPE_WALK or ply:WaterLevel() > 0 then return end
	local id = footstepBlock( ply, pos )
	local block = id and MC.Blocks[id]
	if not block then return end
	local soundType = block.soundType
	local soundSet = SoundTypes[soundType] or SoundTypes.STONE
	local candidates = StepOverrides[soundType] or soundSet.hits
	if not candidates then return end
	if #candidates == 0 then return true end

	-- Use Source's footstep recipients on the server. Clients also generate
	-- nearby footsteps in multiplayer, so both realms use the same hook.
	local step = selectStep( candidates )
	local pitch = math.Clamp( floor( soundSet.pitch * ( step.pitch or 1 ) * 100 + 0.5 ), 1, 255 )
	local gain = math.Clamp( volume * 0.5 * soundSet.volume * ( step.volume or 1 ), 0, 1 )
	ply:EmitSound( step.sound, 65, pitch, gain, CHAN_BODY, 0, 1, SERVER and recipients or nil )
	return true
end )
