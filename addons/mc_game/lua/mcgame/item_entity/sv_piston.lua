-- Consume the engine's sanitized piston movement event.  The engine commits
-- blocks atomically, so this game adapter reconstructs the two Java movement
-- half-ticks over the destination swept AABB for mc_item_drop entities only.

if not SERVER then return end

MC = MC or {}
MC.ItemEntityParity = MC.ItemEntityParity or {}

local R = MC.ItemEntityParity
local C = R.Constants

R.PistonAdapter = R.PistonAdapter or {}
local Adapter = R.PistonAdapter

local function validDrop( entity )
	return IsValid( entity ) and entity.GetClass and entity:GetClass() == "mc_item_drop"
end

local function axisBounds( minimum, maximum, axis )
	if axis == "x" then return minimum.x, maximum.x end
	if axis == "y" then return minimum.y, maximum.y end
	return minimum.z, maximum.z
end

local function setAxisBounds( minimum, maximum, axis, lo, hi )
	local outMin = Vector( minimum.x, minimum.y, minimum.z )
	local outMax = Vector( maximum.x, maximum.y, maximum.z )
	if axis == "x" then outMin.x, outMax.x = lo, hi
	elseif axis == "y" then outMin.y, outMax.y = lo, hi
	else outMin.z, outMax.z = lo, hi end
	return outMin, outMax
end

local function movementAxis( dx, dy, dz )
	if dx ~= 0 then return "x", dx > 0 and 1 or -1 end
	if dy ~= 0 then return "y", dy > 0 and 1 or -1 end
	if dz ~= 0 then return "z", dz > 0 and 1 or -1 end
	return nil, 0
end

function Adapter.MovementSlab( startMin, startMax, axis, sign, progress, delta )
	local size = R.BlockSize()
	-- `startMin/startMax` are the moving block's destination cell. At progress
	-- zero its collision shape is one block opposite the movement direction.
	local shift = -sign * ( 1 - progress ) * size
	local baseLo, baseHi = axisBounds( startMin, startMax, axis )
	local currentMin, currentMax = setAxisBounds(
		startMin, startMax, axis, baseLo + shift, baseHi + shift )
	-- setAxisBounds above cannot infer the axis' upper endpoint; calculate the
	-- translated full cell explicitly, then replace its leading half with the
	-- PistonMath movement area.
	baseLo, baseHi = baseLo + shift, baseHi + shift
	local slabLo, slabHi
	if sign > 0 then slabLo, slabHi = baseHi, baseHi + delta * size
	else slabLo, slabHi = baseLo - delta * size, baseLo end
	local slabMin, slabMax = setAxisBounds( currentMin, currentMax, axis, slabLo, slabHi )
	local broadMin = Vector( math.min( currentMin.x, slabMin.x ), math.min( currentMin.y, slabMin.y ), math.min( currentMin.z, slabMin.z ) )
	local broadMax = Vector( math.max( currentMax.x, slabMax.x ), math.max( currentMax.y, slabMax.y ), math.max( currentMax.z, slabMax.z ) )
	return currentMin, currentMax, slabMin, slabMax, broadMin, broadMax
end

local function movementDistance( slabMin, slabMax, entityMin, entityMax, axis, sign )
	local slabLo, slabHi = axisBounds( slabMin, slabMax, axis )
	local entityLo, entityHi = axisBounds( entityMin, entityMax, axis )
	if sign > 0 then return slabHi - entityLo end
	return entityHi - slabLo
end

function Adapter.ProcessTick( payload, previousProgress, progress )
	if not R.Enabled() or type( payload ) ~= "table" then return end
	local size = R.BlockSize()
	local movedByEntity = setmetatable( {}, { __mode = "k" } )
	local entities = {}
	for _, movement in ipairs( payload.movements or {} ) do
		local dx, dy, dz = tonumber( movement.dx ) or 0,
			tonumber( movement.dy ) or 0, tonumber( movement.dz ) or 0
		local axis, sign = movementAxis( dx, dy, dz )
		if axis then
			local startMin, startMax = R.CellWorldBounds( movement.toX, movement.toY, movement.toZ )
			if startMin and startMax then
				local _, _, slabMin, slabMax, broadMin, broadMax = Adapter.MovementSlab(
					startMin, startMax, axis, sign, previousProgress, progress - previousProgress )
				MC.ItemDropQuery.InBox( broadMin.x, broadMin.y, broadMin.z,
					broadMax.x, broadMax.y, broadMax.z, entities )
				for i = 1, #entities do
					local entity = entities[i]
					if validDrop( entity ) then
						local entityMin, entityMax = R.WorldBounds( entity )
						if entityMin and R.AABBIntersects( broadMin, broadMax, entityMin, entityMax ) then
							-- SlimeBlock's special pre-collision velocity assignment applies
							-- to every non-player entity in the movement area.
							if movement.blockName == "minecraft:slime_block" then
								R.OverrideVelocityAxis( entity, dx, dy, dz )
							end
							if R.AABBIntersects( slabMin, slabMax, entityMin, entityMax ) then
								local distance = movementDistance( slabMin, slabMax, entityMin, entityMax, axis, sign )
								local cap = C.pistonTickMovement
								local used = movedByEntity[entity] or 0
								local remaining = math.max( 0, cap - used )
								local pushed = math.min( math.max( 0, distance ), progress - previousProgress )
								pushed = math.min( pushed + C.pistonPushOffset, remaining )
								if pushed > 0 then
									local delta = Vector( dx * pushed * size, dy * pushed * size, dz * pushed * size )
									entity:SetPos( entity:GetPos() + delta )
									MC.ItemDropQuery.Update( entity )
									movedByEntity[entity] = used + pushed
								end
							end
						end
					end
				end
			end
		end
	end
	-- HoneyBlock carries grounded entities in the top-side AABB even when the
	-- moving collision slab does not intersect their item box.
	for _, movement in ipairs( payload.movements or {} ) do
		if movement.blockName == "minecraft:honey_block" and ( tonumber( movement.dy ) or 0 ) == 0 then
			local startMin, startMax = R.CellWorldBounds( movement.toX, movement.toY, movement.toZ )
			if startMin and startMax then
				local shift = Vector( -( movement.dx or 0 ) * size * ( 1 - previousProgress ),
					-( movement.dy or 0 ) * size * ( 1 - previousProgress ),
					-( movement.dz or 0 ) * size * ( 1 - previousProgress ) )
				local stickyMin = startMin + shift + Vector( 0, 0, size * 15 / 16 )
				local stickyMax = startMin + shift + Vector( size, size, size * 1.500001 )
				MC.ItemDropQuery.InBox( stickyMin.x, stickyMin.y, stickyMin.z,
					stickyMax.x, stickyMax.y, stickyMax.z, entities )
				for i = 1, #entities do
					local entity = entities[i]
					if validDrop( entity ) and ( not entity.IsOnGround or entity:IsOnGround() ) then
						local entityMin, entityMax = R.WorldBounds( entity )
						if entityMin and R.AABBIntersects( stickyMin, stickyMax, entityMin, entityMax ) then
							local used = movedByEntity[entity] or 0
							local carried = math.min( progress - previousProgress,
								math.max( 0, C.pistonTickMovement - used ) )
							if carried > 0 then
								local delta = Vector( ( movement.dx or 0 ) * carried * size,
									( movement.dy or 0 ) * carried * size,
									( movement.dz or 0 ) * carried * size )
								entity:SetPos( entity:GetPos() + delta )
								MC.ItemDropQuery.Update( entity )
								movedByEntity[entity] = used + carried
							end
						end
					end
				end
			end
		end
	end
end

hook.Add( "MC.PistonMovementCommitted", "mcgame_item_entity_piston", function( payload )
	if not R.Enabled() or type( payload ) ~= "table" or type( payload.movements ) ~= "table" then return end
	for tick = 1, C.pistonTicks do
		local fraction = math.min( 1, tick * 0.5 )
		local previous = math.min( 1, ( tick - 1 ) * 0.5 )
		local delay = ( tick - 1 ) * C.tickSeconds
		local callback = function() Adapter.ProcessTick( payload, previous, fraction ) end
		if timer and timer.Simple and delay > 0 then timer.Simple( delay, callback ) else callback() end
	end
end )
