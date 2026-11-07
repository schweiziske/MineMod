-- Hull movement for voxel swimming. All positions and hulls here are in engine
-- space; only the liquid contact queries use MC world space.
MC = MC or {}
MC.Liquid = MC.Liquid or {}

local abs, max = math.abs, math.max
local States = setmetatable( {}, { __mode = "k" } )

local function stateFor( ply )
	local state = States[ply]
	if state then return state end
	state = {
		query = { start = Vector(), endpos = Vector(), mask = MASK_PLAYERSOLID,
			collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT, output = {} },
		nx = {}, ny = {}, nz = {},
	}
	States[ply] = state
	return state
end

local function traceHull( state, ply, x, y, z, endX, endY, endZ )
	local query = state.query
	query.start:SetUnpacked( x, y, z )
	query.endpos:SetUnpacked( endX, endY, endZ )
	query.filter = ply
	local result = util.TraceHull( query )
	query.filter = nil
	return result
end

local function slide( state, ply, x, y, z, vx, vy, vz, seconds )
	local primalX, primalY, primalZ = vx, vy, vz
	local originalX, originalY, originalZ = vx, vy, vz
	local nx, ny, nz = state.nx, state.ny, state.nz
	local planes = 0
	for bump = 1, 4 do
		if vx == 0 and vy == 0 and vz == 0 then break end
		local hit = traceHull( state, ply, x, y, z, x + vx * seconds, y + vy * seconds, z + vz * seconds )
		if hit.AllSolid then return x, y, z, 0, 0, 0 end
		if hit.Fraction > 0 then
			x, y, z = hit.HitPos.x, hit.HitPos.y, hit.HitPos.z
			originalX, originalY, originalZ = vx, vy, vz
			planes = 0
		end
		if hit.Fraction == 1 then break end
		seconds = seconds * ( 1 - hit.Fraction )
		planes = planes + 1
		local normal = hit.HitNormal
		nx[planes], ny[planes], nz[planes] = normal.x, normal.y, normal.z
		local accepted = false
		for i = 1, planes do
			local into = originalX * nx[i] + originalY * ny[i] + originalZ * nz[i]
			vx, vy, vz = originalX - nx[i] * into, originalY - ny[i] * into, originalZ - nz[i] * into
			accepted = true
			for j = 1, planes do
				if j ~= i and vx * nx[j] + vy * ny[j] + vz * nz[j] < 0 then
					accepted = false
					break
				end
			end
			if accepted then break end
		end
		if not accepted then
			if planes ~= 2 then return x, y, z, 0, 0, 0 end
			local cx, cy, cz = ny[1] * nz[2] - nz[1] * ny[2],
				nz[1] * nx[2] - nx[1] * nz[2], nx[1] * ny[2] - ny[1] * nx[2]
			local lengthSquared = cx * cx + cy * cy + cz * cz
			if lengthSquared < 0.000001 then return x, y, z, 0, 0, 0 end
			local along = ( originalX * cx + originalY * cy + originalZ * cz ) / lengthSquared
			vx, vy, vz = cx * along, cy * along, cz * along
		end
		if vx * primalX + vy * primalY + vz * primalZ <= 0 then return x, y, z, 0, 0, 0 end
		if abs( vx ) < 0.0001 then vx = 0 end
		if abs( vy ) < 0.0001 then vy = 0 end
		if abs( vz ) < 0.0001 then vz = 0 end
	end
	return x, y, z, vx, vy, vz
end

function MC.Liquid.MoveSwimming( ply, move, velocity, seconds )
	local state = stateFor( ply )
	local query = state.query
	if ply:Crouching() then
		query.mins, query.maxs = ply:GetHullDuck()
	else
		query.mins, query.maxs = ply:GetHull()
	end
	local origin, base = move:GetOrigin(), ply:GetBaseVelocity()
	local startX, startY, startZ = origin.x, origin.y, origin.z
	local vx, vy, vz = velocity.x + base.x, velocity.y + base.y, velocity.z + base.z
	local x, y, z, endVX, endVY, endVZ = slide( state, ply, startX, startY, startZ, vx, vy, vz, seconds )

	-- Compare a grounded step against the ordinary slide. Never raise a player
	-- who is swimming freely, and never accept an unstandable landing plane.
	if ply:OnGround() and vz <= 0 and ( x ~= startX + vx * seconds or y ~= startY + vy * seconds ) then
		local step = max( 0, ply:GetStepSize() )
		local up = traceHull( state, ply, startX, startY, startZ, startX, startY, startZ + step )
		if not up.StartSolid and not up.AllSolid then
			local sx, sy, sz, svx, svy = slide( state, ply, up.HitPos.x, up.HitPos.y, up.HitPos.z, vx, vy, vz, seconds )
			local down = traceHull( state, ply, sx, sy, sz, sx, sy, sz - step )
			if not down.StartSolid and not down.AllSolid and down.Hit and down.HitNormal.z >= 0.7 then
				local dx, dy = x - startX, y - startY
				local stepX, stepY = sx - startX, sy - startY
				if stepX * stepX + stepY * stepY > dx * dx + dy * dy then
					x, y, z, endVX, endVY = down.HitPos.x, down.HitPos.y, down.HitPos.z, svx, svy
					move:SetFinalStepHeight( move:GetFinalStepHeight() + max( 0, z - startZ ) )
				end
			end
		end
	end

	ply:SetGroundEntity( NULL )
	if endVZ <= 0 then
		local ground = traceHull( state, ply, x, y, z, x, y, z - 2 )
		if not ground.StartSolid and not ground.AllSolid and ground.Hit and ground.HitNormal.z >= 0.7 then
			ply:SetGroundEntity( ground.Entity )
			endVZ = base.z
		end
	end
	origin:SetUnpacked( x, y, z )
	velocity:SetUnpacked( endVX - base.x, endVY - base.y, endVZ - base.z )
	move:SetOrigin( origin )
	move:SetVelocity( velocity )
end
