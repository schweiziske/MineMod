-- Shared ENTITY-vs-BLOCK hit-result ordering for mining and creative breaking.
-- The voxel DDA sees Minecraft collision boxes only, so a second Source trace
-- is required to stop attacks at nearer players, mobs, props, boats or carts.

MC = MC or {}

local BLOCK_AIM_INFRASTRUCTURE = {
	mc_block_cluster = true,
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
	mc_item_drop = true,
	mc_projectile = true,
}

local function blockSize()
	return MC.API.Coords.BlockSize()
end

local function blockAimDistance( start, direction, blockHit )
	local distance = tonumber( blockHit and blockHit.Distance )
	if distance and distance >= 0 then return distance end
	local hitPosition = blockHit and blockHit.HitPos
	if not hitPosition then return nil end
	return math.max( 0, ( hitPosition - start ):Dot( direction ) )
end

function MC.TraceEntityBeforeBlock( ply, blockHit, rayDirection )
	if not IsValid( ply ) or not blockHit or not util or not util.TraceLine then return nil, nil end
	local worldStart = MC.API.Coords.EntityEyeWorldPos( ply )
	local start = ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
	local direction = rayDirection or ply.EyeAngles and ply:EyeAngles():Forward()
		or ply.GetAimVector and ply:GetAimVector() or nil
	if not start or not direction or direction:LengthSqr() <= 0.000001 then return nil, nil end
	direction = Vector( direction.x, direction.y, direction.z )
	direction:Normalize()
	local blockDistance = blockAimDistance( worldStart, direction, blockHit )
	if not blockDistance then return nil, nil end
	local epsilon = math.max( blockSize() * 0.001, 0.01 )
	local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	local trace = util.TraceLine( {
		start = start,
		endpos = start + direction * ( blockDistance + epsilon ),
		filter = function( entity )
			if entity == ply or entity == weapon then return false end
			local className = IsValid( entity ) and entity.GetClass and entity:GetClass() or ""
			return BLOCK_AIM_INFRASTRUCTURE[className] ~= true
		end,
		mask = MASK_SHOT or MASK_SOLID,
	} )
	local tracedEntity = trace and trace.Entity or nil
	local target = MC.ResolveMinecraftVehicle and MC.ResolveMinecraftVehicle( tracedEntity ) or tracedEntity
	if not IsValid( target ) or target == ply or target.IsWorld and target:IsWorld() then return nil, trace end
	local hitPosition = trace.HitPos
	if trace.MCMinecraftVehicleHitPos then hitPosition = trace.MCMinecraftVehicleHitPos end
	if not hitPosition and target.WorldSpaceCenter then hitPosition = target:WorldSpaceCenter() end
	local entityDistance = hitPosition and math.max( 0, ( hitPosition - start ):Dot( direction ) ) or 0
	if entityDistance > blockDistance + epsilon then return nil, trace end
	return target, trace, entityDistance
end

function MC.EntityOccludesBlockAim( ply, blockHit )
	return IsValid( select( 1, MC.TraceEntityBeforeBlock( ply, blockHit ) ) )
end
