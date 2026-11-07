-- Source airboats retain their native seats, engine, steering and collisions.
-- Minecraft water supplies the missing hull support; BSP water stays native.
local Coords = MC.API.Coords
local Liquid = MC.Liquid
local boats = {}
local clamp, floor = math.Clamp, math.floor
local force = Vector( 0, 0, 0 )

local function register( entity )
	if not IsValid( entity ) or entity:GetClass() ~= "prop_vehicle_airboat" then return end
	local physics = entity:GetPhysicsObject()
	if not IsValid( physics ) then return end
	local minimum, maximum = physics:GetAABB()
	local width, length = maximum.x - minimum.x, maximum.y - minimum.y
	if width <= 0 or length <= 0 then
		MC.Fault( "airboat_hull_bounds", "Invalid airboat physics bounds: %s", entity )
		return
	end
	local cx, cy = ( minimum.x + maximum.x ) * 0.5, ( minimum.y + maximum.y ) * 0.5
	local points = {}
	for _, x in ipairs( { -1, 1 } ) do
		for _, y in ipairs( { -1, 1 } ) do
			points[#points + 1] = Vector( cx + width * 0.38 * x, cy + length * 0.38 * y, minimum.z )
		end
	end
	boats[entity] = { physics = physics, points = points }
end

-- Probe the hull itself, not Entity:WaterLevel(), which only sees BSP water.
-- A continuing water column implies full displacement. Using the current
-- cell's top as its surface would trap a submerged boat at each cell boundary.
local function displacement( worldPosition, blockSize )
	local bx, by, bz = floor( worldPosition.x / blockSize ),
		floor( worldPosition.y / blockSize ), floor( worldPosition.z / blockSize )
	local state = MC.GetBlockState( bx, by, bz )
	local kind = Liquid.DecodeState( state )
	if kind ~= "water" then return 0 end
	local aboveKind = Liquid.DecodeState( MC.GetBlockState( bx, by, bz + 1 ) )
	if aboveKind == "water" then return blockSize * 1.2 end
	local surface = ( bz + MC.LiquidHeightAtCell( bx, by, bz, "water" ) ) * blockSize
	return math.max( 0, surface - worldPosition.z )
end

hook.Add( "OnEntityCreated", "mc_airboat_water", function( entity )
	if entity:GetClass() ~= "prop_vehicle_airboat" then return end
	timer.Simple( 0, function() register( entity ) end )
end )
hook.Add( "EntityRemoved", "mc_airboat_water", function( entity ) boats[entity] = nil end )
hook.Add( "InitPostEntity", "mc_airboat_water", function()
	for _, entity in ipairs( ents.FindByClass( "prop_vehicle_airboat" ) ) do register( entity ) end
end )

hook.Add( "Tick", "mc_airboat_water", function()
	local blockSize = Coords.BlockSize()
	local draft = blockSize * 0.3
	local gravity = math.max( 0, -physenv.GetGravity().z )
	local damping = 2 * math.sqrt( gravity / draft )
	local dt = engine.TickInterval()
	for entity, boat in pairs( boats ) do
		local physics = boat.physics
		if not IsValid( entity ) or not IsValid( physics ) then
			boats[entity] = nil
		elseif physics:IsMotionEnabled() and entity:WaterLevel() == 0 then
			local share = physics:GetMass() * dt / #boat.points
			for _, point in ipairs( boat.points ) do
				local enginePosition = entity:LocalToWorld( point )
				local worldPosition = Coords.EngineToWorld( enginePosition, entity )
				local depth = displacement( worldPosition, blockSize )
				if depth > 0 then
					local verticalSpeed = physics:GetVelocityAtPoint( enginePosition ).z
					force.z = clamp( gravity * depth / draft - damping * verticalSpeed, 0, gravity * 4 ) * share
					physics:ApplyForceOffset( force, enginePosition )
				end
			end
		end
	end
end )

-- Also support hot reload and vehicles spawned before this file was included.
for _, entity in ipairs( ents.FindByClass( "prop_vehicle_airboat" ) ) do register( entity ) end
