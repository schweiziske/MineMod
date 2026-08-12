--[[----------------------------------------------------------------------------
	MC : Minecraft Java 26.2 explosion ray selection.

	This module only selects cells. Damage explosions and TRIGGER_BLOCK
	explosions provide their own resistance calculator and interaction policy.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.Explosion = MC.Explosion or {}

local Explosion = MC.Explosion

local GRID_MAX = 15
local STEP = 0.3
local AIR_COST = 0.22500001

Explosion.JavaRaySteps = Explosion.JavaRaySteps or {}

local function buildRaySteps()
	local steps = {}
	for xx = 0, GRID_MAX do
		for yy = 0, GRID_MAX do
			for zz = 0, GRID_MAX do
				if xx == 0 or xx == GRID_MAX or yy == 0 or yy == GRID_MAX
					or zz == 0 or zz == GRID_MAX then
					local dx = xx / GRID_MAX * 2 - 1
					local dy = yy / GRID_MAX * 2 - 1
					local dz = zz / GRID_MAX * 2 - 1
					local length = math.sqrt( dx * dx + dy * dy + dz * dz )
					steps[#steps + 1] = {
						dx = dx / length * STEP,
						dy = dy / length * STEP,
						dz = dz / length * STEP,
					}
				end
			end
		end
	end
	return steps
end

if #Explosion.JavaRaySteps == 0 then
	Explosion.JavaRaySteps = buildRaySteps()
end

local function cellKey( bx, by, bz )
	if MC.CellKey then
		local key = MC.CellKey( bx, by, bz )
		if key ~= nil then return key end
	end
	return tostring( bx ) .. ":" .. tostring( by ) .. ":" .. tostring( bz )
end

-- Mirrors ServerExplosion.calculateExplodedPositions:
-- 16^3 boundary rays, randomized radius power, 0.3-block advances and the
-- unconditional 0.22500001 loss after every step. resistance() returns nil
-- for Optional.empty(), which deliberately means no resistance subtraction.
function Explosion.SelectJavaExplosionCells( center, radius, options )
	if not isvector( center ) then return nil, "invalid_center" end
	radius = tonumber( radius ) or 0
	if radius <= 0 then return nil, "invalid_radius" end
	options = options or {}

	local blockSize = tonumber( MC.BS ) or 0
	if blockSize <= 0 then return nil, "invalid_block_size" end
	local cx, cy, cz = center.x / blockSize, center.y / blockSize, center.z / blockSize
	local getState = MC.GetBlockState
	if not isfunction( getState ) then return nil, "block_state_unavailable" end

	local inBounds = options.inBounds
	local resistance = options.resistance
	local shouldSelect = options.shouldSelect
	local selected, seen = {}, {}

	for rayIndex = 1, #Explosion.JavaRaySteps do
		local ray = Explosion.JavaRaySteps[rayIndex]
		local remainingPower = radius * ( 0.7 + math.Rand( 0, 0.6 ) )
		local x, y, z = cx, cy, cz

		while remainingPower > 0 do
			local bx, by, bz = math.floor( x ), math.floor( y ), math.floor( z )
			if isfunction( inBounds ) and inBounds( bx, by, bz ) == false then break end

			local stateId = getState( bx, by, bz ) or 0
			local value = isfunction( resistance )
				and resistance( stateId, bx, by, bz, remainingPower ) or nil
			if isnumber( value ) then
				remainingPower = remainingPower - ( value + 0.3 ) * STEP
			end

			local selectable = not isfunction( shouldSelect )
				or shouldSelect( stateId, bx, by, bz, remainingPower ) ~= false
			if remainingPower > 0 and selectable then
				local key = cellKey( bx, by, bz )
				if not seen[key] then
					seen[key] = true
					selected[#selected + 1] = { bx = bx, by = by, bz = bz }
				end
			end

			x = x + ray.dx
			y = y + ray.dy
			z = z + ray.dz
			remainingPower = remainingPower - AIR_COST
		end
	end

	return selected
end

