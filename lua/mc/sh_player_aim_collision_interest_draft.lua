-- Draft only. This file is inside the addon, but it is not included by mc_load.lua.
-- Goal: add collision interest around the block hit by the player's aim ray.

---------------------------------------------------------------------
-- Server-side version
---------------------------------------------------------------------

local function collectPlayerAimCollisionInterestKeys( desired )
	for _, ply in ipairs( player.GetAll() ) do
		if IsValid( ply ) then
			local hit = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
			if hit and hit.bx then
				addCellNeighborhoodCollisionKeys(
					desired,
					hit.bx,
					hit.by,
					hit.bz,
					serverCollisionAimRadius()
				)
			end
		end
	end
end

local function addCellNeighborhoodCollisionKeys( desired, bx, by, bz, radius )
	radius = math.max( 0, math.floor( tonumber( radius ) or 0 ) )
	addChunkLocalBoundsCollisionInterest(
		desired,
		bx - radius,
		by - radius,
		bz - radius,
		bx + radius,
		by + radius,
		bz + radius
	)
end

---------------------------------------------------------------------
-- Client prediction version
---------------------------------------------------------------------

local function collectClientAimCollisionInterestKeys( lp, desired )
	if not IsValid( lp ) then return nil end

	local hit = MC.PlayerBlockAim and MC.PlayerBlockAim( lp ) or nil
	if not hit or not hit.bx then return nil end

	addClientCellNeighborhoodCollisionKeys(
		desired,
		hit.bx,
		hit.by,
		hit.bz,
		clientCollisionAimRadius()
	)

	local cx, cy, cz = MC.CellToChunk( hit.bx, hit.by, hit.bz )
	return MC.ChunkKey( cx, cy, cz ) .. "|" .. hit.bx .. ":" .. hit.by .. ":" .. hit.bz
end

local function addClientCellNeighborhoodCollisionKeys( desired, bx, by, bz, radius )
	radius = math.max( 0, math.floor( tonumber( radius ) or 0 ) )
	addClientChunkLocalBoundsCollisionInterest(
		desired,
		bx - radius,
		by - radius,
		bz - radius,
		bx + radius,
		by + radius,
		bz + radius
	)
end

---------------------------------------------------------------------
-- Radius behavior
---------------------------------------------------------------------

-- radius = 0: only the aimed block, 1x1x1
-- radius = 1: aimed block plus neighbors, 3x3x3
-- radius = 2: 5x5x5

-- Important: the client aim key includes bx/by/bz, not only the chunk key.
-- Otherwise aiming at a different block inside the same chunk would not
-- invalidate the collision interest signature.
