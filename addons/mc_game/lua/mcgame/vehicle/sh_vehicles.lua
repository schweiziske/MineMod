--[[----------------------------------------------------------------------------
	Minecraft vehicle item metadata and server-authoritative placement.

	The visible mc_boat/mc_minecart entities own Minecraft movement rules. Each
	entity creates a hidden prop_vehicle_prisoner_pod for GMod's native enter,
	exit and driver-input path; no parallel driving protocol is introduced here.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.VehicleItems = MC.VehicleItems or {}

local EngineAPI = MC.API
local World = EngineAPI and EngineAPI.World
local Blocks = EngineAPI and EngineAPI.Blocks
local Coords = EngineAPI and EngineAPI.Coords
local Liquid = EngineAPI and EngineAPI.Liquid

local function engineBlockSize()
	return Coords and Coords.BlockSize and Coords.BlockSize() or 36.5
end

local VEHICLE_INTERACT_NET = "mc_minecraft_vehicle_interact"

local BOAT_ITEMS = {
	["minecraft:oak_boat"] = "oak",
	["minecraft:spruce_boat"] = "spruce",
	["minecraft:birch_boat"] = "birch",
	["minecraft:jungle_boat"] = "jungle",
	["minecraft:acacia_boat"] = "acacia",
	["minecraft:dark_oak_boat"] = "dark_oak",
	["minecraft:mangrove_boat"] = "mangrove",
	["minecraft:cherry_boat"] = "cherry",
	["minecraft:pale_oak_boat"] = "pale_oak",
	["minecraft:bamboo_raft"] = "bamboo",
}

for itemName, woodType in pairs( BOAT_ITEMS ) do
	MC.VehicleItems[itemName] = {
		class = "mc_boat",
		kind = "boat",
		woodType = woodType,
		raft = woodType == "bamboo",
	}
end

MC.VehicleItems["minecraft:minecart"] = {
	class = "mc_minecart",
	kind = "minecart",
}

local function vehicleSpec( itemName )
	return MC.VehicleItems[tostring( itemName or "" )]
end

function MC.VehicleSpecForItem( itemName )
	return vehicleSpec( itemName )
end

local MINECRAFT_VEHICLE_CLASSES = {
	mc_boat = true,
	mc_minecart = true,
}

-- Java keeps compact physics boxes (minecart 0.98 x 0.7, boat 1.375 x
-- 0.5625), while the authored visible meshes extend beyond them. Keep physics
-- Java-sized and use local pick boxes only for right-click selection. The boat
-- body generated in mc_boat/cl_init.lua spans exactly X [-1, 1], Y
-- [-0.625, 0.625], Z [0, 0.5625]; the small padding makes its rim/open top easy
-- to target without allowing interaction through a nearer world obstruction.
local VEHICLE_INTERACTION_BOXES = {
	mc_minecart = { -0.70, -0.70, -0.05, 0.70, 0.70, 0.85 },
	mc_boat = { -1.00, -0.75, -0.05, 1.00, 0.75, 0.85 },
}
local VEHICLE_INTERACTION_QUERY_PADDING = 1.30

local MINECART_RAIL_COLLISION_CARRIERS = {
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
}

-- Source exposes an entire Minecraft chunk through a few coarse VPhysics
-- carriers. A minecart following a slope would otherwise hit the carrier's
-- square terrain lip before its Java-sized hull can descend. While a cart is
-- rail-bound, mc_minecart performs the exact block-shape collision pass itself;
-- native collisions with players, other minecarts and ordinary props remain.
hook.Add( "ShouldCollide", "mc_minecart_java_rail_block_collision", function( first, second )
	if not IsValid( first ) or not IsValid( second ) then return end
	local cart, carrier
	if first:GetClass() == "mc_minecart" and MINECART_RAIL_COLLISION_CARRIERS[second:GetClass()] then
		cart, carrier = first, second
	elseif second:GetClass() == "mc_minecart" and MINECART_RAIL_COLLISION_CARRIERS[first:GetClass()] then
		cart, carrier = second, first
	end
	if not IsValid( cart ) or not IsValid( carrier ) then return end
	if cart.MCActiveRail ~= nil or cart.GetOnRails and cart:GetOnRails() then return false end
end )

function MC.ResolveMinecraftVehicle( entity )
	if not IsValid( entity ) then return nil end
	local className = entity.GetClass and entity:GetClass() or ""
	if MINECRAFT_VEHICLE_CLASSES[className] then return entity end

	-- The server stores an explicit link on hidden prisoner-pod seats. Client
	-- Lua fields do not network, so the parent relation is the shared fallback.
	local linked = entity.MCMinecraftVehicle
	if IsValid( linked ) and MINECRAFT_VEHICLE_CLASSES[linked:GetClass()] then return linked end
	local parent = entity.GetParent and entity:GetParent() or nil
	if IsValid( parent ) and MINECRAFT_VEHICLE_CLASSES[parent:GetClass()] then return parent end
	return nil
end

local function hiddenMinecraftVehicleSeat( entity )
	if not IsValid( entity ) or not entity.GetClass
	or entity:GetClass() ~= "prop_vehicle_prisoner_pod" then return false end
	local vehicle = MC.ResolveMinecraftVehicle( entity )
	return IsValid( vehicle ) and vehicle ~= entity
end

local function vectorAxis( value, axis )
	if axis == 1 then return value.x end
	if axis == 2 then return value.y end
	return value.z
end

local function rayIntersectsLocalBox( entity, start, finish, bounds, blockSize )
	if not IsValid( entity ) or not entity.WorldToLocal then return nil end
	local localStart = entity:WorldToLocal( start )
	local localFinish = entity:WorldToLocal( finish )
	local delta = localFinish - localStart
	local near, far = 0, 1
	for axis = 1, 3 do
		local origin = vectorAxis( localStart, axis )
		local amount = vectorAxis( delta, axis )
		local minimum = bounds[axis] * blockSize
		local maximum = bounds[axis + 3] * blockSize
		if math.abs( amount ) <= 0.000001 then
			if origin < minimum or origin > maximum then return nil end
		else
			local first = ( minimum - origin ) / amount
			local second = ( maximum - origin ) / amount
			if first > second then first, second = second, first end
			near = math.max( near, first )
			far = math.min( far, second )
			if near > far then return nil end
		end
	end
	if far < 0 or near > 1 then return nil end
	return math.max( 0, near ) * ( finish - start ):Length()
end

local function expandedVehicleHit( start, direction, reach, blockSize, obstructionDistance )
	if not ents or not ents.FindInBox then return nil, nil end
	local finish = start + direction * reach
	-- A yawed 2 x 1.5 boat can put its origin up to 1.25 blocks from a ray that
	-- still intersects the local pick box, so the broad phase must cover that
	-- rotated radius rather than only the unrotated half extents.
	local horizontalPadding = blockSize * VEHICLE_INTERACTION_QUERY_PADDING
	local padding = Vector( horizontalPadding, horizontalPadding, blockSize * 0.9 )
	local queryMin = Vector( math.min( start.x, finish.x ), math.min( start.y, finish.y ),
		math.min( start.z, finish.z ) ) - padding
	local queryMax = Vector( math.max( start.x, finish.x ), math.max( start.y, finish.y ),
		math.max( start.z, finish.z ) ) + padding
	local closest, closestDistance
	for _, entity in ipairs( ents.FindInBox( queryMin, queryMax ) or {} ) do
		local className = IsValid( entity ) and entity.GetClass and entity:GetClass() or ""
		local bounds = VEHICLE_INTERACTION_BOXES[className]
		if bounds then
			local distance = rayIntersectsLocalBox( entity, start, finish, bounds, blockSize )
			if distance and distance <= obstructionDistance + blockSize * 0.001
			and ( not closestDistance or distance < closestDistance ) then
				closest, closestDistance = entity, distance
			end
		end
	end
	return closest, closestDistance
end

function MC.TraceMinecraftVehicle( ply, reachBlocks, mask )
	if not IsValid( ply ) or not ply:IsPlayer() or not util or not util.TraceLine then return nil, nil end
	local start = Coords and Coords.EntityEyeWorldPos and Coords.EntityEyeWorldPos( ply )
		or ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
	local direction = ply.GetAimVector and ply:GetAimVector()
		or ply.EyeAngles and ply:EyeAngles():Forward() or nil
	if not start or not direction or direction:LengthSqr() <= 0 then return nil, nil end
	direction = Vector( direction.x, direction.y, direction.z )
	direction:Normalize()
	local blockSize = engineBlockSize()
	local reach = blockSize * math.max( 1, tonumber( reachBlocks ) or 5 )
	local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	local trace = util.TraceLine( {
		start = start,
		endpos = start + direction * reach,
		filter = function( entity )
			if entity == ply or entity == weapon then return false end
			-- Native seats exist only to carry GMod's vehicle protocol. Their
			-- airboat-seat model/trace box is offset from the rendered Minecraft
			-- vehicle and must never become the interaction or occlusion target.
			if hiddenMinecraftVehicleSeat( entity ) then return false end
			return true
		end,
		mask = mask or MASK_SOLID,
	} )
	local directlyHit = MC.ResolveMinecraftVehicle( trace and trace.Entity )
	if IsValid( directlyHit ) then return directlyHit, trace end

	-- A block or another solid entity still occludes the enlarged interaction
	-- rim. Only accept a model-box hit that lies before the ordinary trace hit.
	local obstructionDistance = reach
	if trace and trace.Hit then
		if trace.Fraction ~= nil then
			obstructionDistance = math.Clamp( tonumber( trace.Fraction ) or 0, 0, 1 ) * reach
		elseif trace.HitPos then
			obstructionDistance = math.Clamp( ( trace.HitPos - start ):Dot( direction ), 0, reach )
		end
	end
	local expandedHit, expandedDistance = expandedVehicleHit( start, direction, reach, blockSize, obstructionDistance )
	if IsValid( expandedHit ) and trace then
		trace.MCMinecraftVehicleEntity = expandedHit
		trace.MCMinecraftVehicleHitPos = start + direction * expandedDistance
	end
	return expandedHit, trace
end

local function riddenMinecraftVehicle( ply )
	if not IsValid( ply ) or not ply:InVehicle() then return nil end
	return MC.ResolveMinecraftVehicle( ply:GetVehicle() )
end

-- Shared by the global right-click command hook and SWEPs that need an
-- explicit interaction preflight (notably mc_inventory). The client sends no
-- trusted target data; the server traces again in SV.UseMinecraftVehicle.
function MC.TryInteractMinecraftVehicle( ply, requestedVehicle )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() or ply:InVehicle() then return false end
	local vehicle = MC.ResolveMinecraftVehicle( requestedVehicle )
		or select( 1, MC.TraceMinecraftVehicle( ply, 3, MASK_SOLID ) )
	if not IsValid( vehicle ) then return false end

	if SERVER then
		if not MC.SV or not MC.SV.UseMinecraftVehicle then return false end
		return MC.SV.UseMinecraftVehicle( ply, vehicle ) == true, vehicle
	end
	if ply ~= LocalPlayer() or not net then return false end
	local now = RealTime()
	if now >= ( ply.MCMinecraftVehicleNextClientInteractAt or 0 ) then
		ply.MCMinecraftVehicleNextClientInteractAt = now + 0.05
		net.Start( VEHICLE_INTERACT_NET )
		net.SendToServer()
	end
	return true, vehicle
end

if CLIENT then
	-- Minecraft's interact button is right click. Consume only a press that is
	-- actually aimed at one of our native-seat-backed entities, leaving every
	-- other SWEP's secondary action untouched.
	hook.Add( "StartCommand", "mc_minecraft_vehicle_right_click", function( ply, command )
		if not IsValid( ply ) or ply ~= LocalPlayer() then return end
		if not command:KeyDown( IN_ATTACK2 ) then
			ply.MCMinecraftVehicleSecondaryHeld = false
			ply.MCMinecraftVehicleSecondaryConsumed = false
			return
		end
		if not ply.MCMinecraftVehicleSecondaryHeld then
			ply.MCMinecraftVehicleSecondaryHeld = true
			if not ply:InVehicle() then
				if MC.TryInteractMinecraftVehicle( ply ) then
					ply.MCMinecraftVehicleSecondaryConsumed = true
				end
			end
		end
		if ply.MCMinecraftVehicleSecondaryConsumed and command.RemoveKey then
			command:RemoveKey( IN_ATTACK2 )
		end
	end )
end

-- Block the prisoner pod's native +use exit in both prediction realms. The
-- server briefly raises MCAllowMinecraftVehicleExit for Shift/forced exits.
hook.Add( "CanExitVehicle", "mc_minecraft_vehicle_shift_only_exit", function( seat, ply )
	local vehicle = MC.ResolveMinecraftVehicle( seat )
	if not IsValid( vehicle ) then return end
	if not IsValid( ply ) or not ply:Alive() or vehicle.MCDestroyed then return true end
	if CLIENT then return false end
	return ply.MCAllowMinecraftVehicleExit == true
end )

local function attachUseHandlers()
	for itemName in pairs( MC.VehicleItems ) do
		local definition = MC.PendingItems and MC.PendingItems[itemName]
		if definition then
			definition.useHandler = function( ply, stack, context )
				if not SERVER or not MC.SV or not MC.SV.UseVehicleItem then return false end
				return MC.SV.UseVehicleItem( ply, stack, context ) == true
			end
		end
	end
end

attachUseHandlers()

if not SERVER then return end

MC.SV = MC.SV or {}
local SV = MC.SV

function SV.UseMinecraftVehicle( ply, requestedVehicle )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() or ply:InVehicle() then
		return false, "invalid_vehicle_user"
	end
	local now = CurTime()
	if now < ( ply.MCMinecraftVehicleNextEnterAt or 0 ) then return false, "vehicle_entry_cooldown" end
	local vehicle, trace = MC.TraceMinecraftVehicle( ply, 3, MASK_SOLID )
	local requested = MC.ResolveMinecraftVehicle( requestedVehicle )
	if requested and vehicle ~= requested then return false, "vehicle_trace_mismatch" end
	vehicle = requested or vehicle
	if not IsValid( vehicle ) then return false, "vehicle_miss" end
	if not isfunction( vehicle.TryEnterPlayer ) then return false, "vehicle_use_unavailable" end
	if vehicle:TryEnterPlayer( ply ) ~= true then return false, "vehicle_entry_rejected" end
	ply.MCMinecraftVehicleEnteredAt = now
	ply.MCMinecraftVehicleNextEnterAt = now + 0.2
	return true, vehicle, trace
end

function SV.ExitMinecraftVehiclePlayer( ply, reason )
	local vehicle = riddenMinecraftVehicle( ply )
	if not IsValid( vehicle ) then return false, "not_in_minecraft_vehicle" end
	ply.MCAllowMinecraftVehicleExit = true
	ply:ExitVehicle()
	ply.MCAllowMinecraftVehicleExit = nil
	if ply:InVehicle() then return false, "native_vehicle_exit_rejected" end
	local now = CurTime()
	ply.MCMinecraftVehicleNextEnterAt = now + 0.25
	ply.MCMinecraftVehicleLastExitReason = tostring( reason or "shift" )
	return true, vehicle
end

net.Receive( VEHICLE_INTERACT_NET, function( _, ply )
	local now = CurTime()
	if now < ( ply.MCMinecraftVehicleInteractNextAt or 0 ) then return end
	ply.MCMinecraftVehicleInteractNextAt = now + 0.1
	SV.UseMinecraftVehicle( ply )
end )

hook.Add( "StartCommand", "mc_minecraft_vehicle_shift_exit", function( ply, command )
	local vehicle = riddenMinecraftVehicle( ply )
	if not IsValid( vehicle ) then
		ply.MCMinecraftVehicleShiftHeld = false
		return
	end
	if not command:KeyDown( IN_SPEED ) then
		ply.MCMinecraftVehicleShiftHeld = false
		return
	end
	if command.RemoveKey then command:RemoveKey( IN_SPEED ) end
	if ply.MCMinecraftVehicleShiftHeld then return end
	ply.MCMinecraftVehicleShiftHeld = true
	if CurTime() - ( ply.MCMinecraftVehicleEnteredAt or 0 ) < 0.25 then return end
	SV.ExitMinecraftVehiclePlayer( ply, "shift" )
end )

local function isRailState( stateId )
	local name = Blocks and Blocks.Name and Blocks.Name( stateId ) or ""
	return name == "minecraft:rail"
		or name == "minecraft:powered_rail"
		or name == "minecraft:detector_rail"
		or name == "minecraft:activator_rail"
end

local RAY_EPSILON = 1e-7

local function rayAxisSlab( origin, direction, minimum, maximum, tMin, tMax, nearNormal, farNormal, hitNormal )
	if math.abs( direction ) <= RAY_EPSILON then
		if origin < minimum or origin > maximum then return nil end
		return tMin, tMax, hitNormal
	end
	local near = ( minimum - origin ) / direction
	local far = ( maximum - origin ) / direction
	local normal = nearNormal
	if near > far then near, far, normal = far, near, farNormal end
	if near > tMin then tMin, hitNormal = near, normal end
	tMax = math.min( tMax, far )
	if tMin - tMax > RAY_EPSILON then return nil end
	return tMin, tMax, hitNormal
end

local function rayFluidBox( start, direction, maxDistance, bx, by, bz, height )
	local blockSize = engineBlockSize()
	local minimum = Coords.CellMin( bx, by, bz )
	local maximum = minimum + Vector( blockSize, blockSize, math.Clamp( height, 0, 1 ) * blockSize )
	local tMin, tMax, normal = 0, maxDistance, Vector( 0, 0, 0 )
	tMin, tMax, normal = rayAxisSlab( start.x, direction.x, minimum.x, maximum.x, tMin, tMax,
		Vector( -1, 0, 0 ), Vector( 1, 0, 0 ), normal )
	if not tMin then return nil end
	tMin, tMax, normal = rayAxisSlab( start.y, direction.y, minimum.y, maximum.y, tMin, tMax,
		Vector( 0, -1, 0 ), Vector( 0, 1, 0 ), normal )
	if not tMin then return nil end
	tMin, tMax, normal = rayAxisSlab( start.z, direction.z, minimum.z, maximum.z, tMin, tMax,
		Vector( 0, 0, -1 ), Vector( 0, 0, 1 ), normal )
	if not tMin or tMax < -RAY_EPSILON or tMin > maxDistance + RAY_EPSILON then return nil end
	return math.max( 0, tMin ), normal
end

local function axisStep( origin, direction, cell, blockSize )
	if direction > RAY_EPSILON then
		return 1, ( ( cell + 1 ) * blockSize - origin ) / direction, blockSize / direction
	elseif direction < -RAY_EPSILON then
		return -1, ( cell * blockSize - origin ) / direction, -blockSize / direction
	end
	return 0, math.huge, math.huge
end

local function distancePastCell( origin, direction, bx, by, bz, blockSize )
	local minimum = Coords.CellMin( bx, by, bz )
	local distance = math.huge
	if direction.x > RAY_EPSILON then distance = math.min( distance, ( minimum.x + blockSize - origin.x ) / direction.x )
	elseif direction.x < -RAY_EPSILON then distance = math.min( distance, ( minimum.x - origin.x ) / direction.x ) end
	if direction.y > RAY_EPSILON then distance = math.min( distance, ( minimum.y + blockSize - origin.y ) / direction.y )
	elseif direction.y < -RAY_EPSILON then distance = math.min( distance, ( minimum.y - origin.y ) / direction.y ) end
	if direction.z > RAY_EPSILON then distance = math.min( distance, ( minimum.z + blockSize - origin.z ) / direction.z )
	elseif direction.z < -RAY_EPSILON then distance = math.min( distance, ( minimum.z - origin.z ) / direction.z ) end
	if distance == math.huge then return nil end
	return math.max( 0, distance ) + math.max( blockSize / 4096, 0.01 )
end

local function traceBlockOutline( start, direction, maxDistance )
	if not World or not World.TraceRay then return nil end
	local origin = start
	local travelled = 0
	local blockSize = engineBlockSize()
	local maxSteps = math.ceil( maxDistance / blockSize ) * 3 + 8
	for _ = 1, maxSteps do
		local remaining = maxDistance - travelled
		if remaining <= 0 then break end
		local hit = World.TraceRay( origin, direction, remaining )
		if not hit then return nil end
		local fluid = Liquid and Liquid.GetAt and Liquid.GetAt( hit.bx, hit.by, hit.bz ) or nil
		if not fluid or fluid.waterlogged == true then
			local localDistance = tonumber( hit.Distance )
				or isvector( hit.HitPos ) and hit.HitPos:Distance( origin ) or 0
			hit.Distance = travelled + localDistance
			hit.HitPos = start + direction * hit.Distance
			hit.Fraction = maxDistance > 0 and hit.Distance / maxDistance or 0
			return hit
		end
		local advance = distancePastCell( origin, direction, hit.bx, hit.by, hit.bz, blockSize )
		if not advance then return nil end
		travelled = travelled + advance
		origin = start + direction * travelled
	end
	return nil
end

local function traceFluidRay( start, direction, maxDistance )
	if not World or not World.GetBlockState or not Liquid or not Liquid.GetAt then return nil end
	direction = Vector( direction.x, direction.y, direction.z )
	if direction:LengthSqr() <= RAY_EPSILON then return nil end
	direction:Normalize()
	local blockSize = engineBlockSize()
	local bx, by, bz = Coords.WorldToCell( start )
	local sx, tx, dx = axisStep( start.x, direction.x, bx, blockSize )
	local sy, ty, dy = axisStep( start.y, direction.y, by, blockSize )
	local sz, tz, dz = axisStep( start.z, direction.z, bz, blockSize )
	local distance = 0
	local maxSteps = math.ceil( maxDistance / blockSize ) * 3 + 8

	for _ = 1, maxSteps do
		local stateId = World.GetBlockState( bx, by, bz ) or 0
		local fluid = Liquid.GetAt( bx, by, bz )
		if fluid then
			local hitDistance, hitNormal = rayFluidBox( start, direction, maxDistance, bx, by, bz, fluid.height )
			if hitDistance and hitDistance + RAY_EPSILON >= distance then
				return {
					Hit = true,
					HitMCFluid = true,
					StateId = stateId,
					FluidKind = fluid.kind,
					bx = bx, by = by, bz = bz,
					HitPos = start + direction * hitDistance,
					HitNormal = hitNormal,
					Fraction = hitDistance / maxDistance,
					Distance = hitDistance,
				}
			end
		end

		if tx <= ty and tx <= tz then
			distance = tx
			if distance > maxDistance then break end
			bx, tx = bx + sx, tx + dx
		elseif ty <= tz then
			distance = ty
			if distance > maxDistance then break end
			by, ty = by + sy, ty + dy
		else
			distance = tz
			if distance > maxDistance then break end
			bz, tz = bz + sz, tz + dz
		end
	end
	return nil
end

local function traceVehiclePlacement( ply, includeFluids )
	if not IsValid( ply ) or not ply:IsPlayer() then return nil end
	local blockSize = engineBlockSize()
	local maxDistance = blockSize * 5
	local start = Coords and Coords.EntityEyeWorldPos and Coords.EntityEyeWorldPos( ply ) or ply:EyePos()
	local direction = ply:EyeAngles():Forward()
	direction:Normalize()
	local blockHit = traceBlockOutline( start, direction, maxDistance )
	local fluidHit = includeFluids and traceFluidRay( start, direction, maxDistance ) or nil
	if fluidHit and ( not blockHit or fluidHit.Distance <= ( blockHit.Distance or math.huge ) ) then return fluidHit end
	return blockHit
end

MC.TraceVehiclePlacement = traceVehiclePlacement

local function playerStartsInsidePickableEntity( ply )
	if not ents then return false end
	local eye = Coords and Coords.EntityEyeWorldPos and Coords.EntityEyeWorldPos( ply ) or ply:EyePos()
	local blockSize = engineBlockSize()
	local direction = ply:EyeAngles():Forward()
	direction:Normalize()
	local playerMin, playerMax = Coords and Coords.EntityWorldAABB and Coords.EntityWorldAABB( ply )
	if not playerMin then playerMin, playerMax = ply:WorldSpaceAABB() end
	local reach = direction * blockSize * 5
	local queryMin = Vector( math.min( playerMin.x, playerMin.x + reach.x ),
		math.min( playerMin.y, playerMin.y + reach.y ), math.min( playerMin.z, playerMin.z + reach.z ) )
		- Vector( blockSize, blockSize, blockSize )
	local queryMax = Vector( math.max( playerMax.x, playerMax.x + reach.x ),
		math.max( playerMax.y, playerMax.y + reach.y ), math.max( playerMax.z, playerMax.z + reach.z ) )
		+ Vector( blockSize, blockSize, blockSize )
	local candidates
	if ents.FindInBox then candidates = ents.FindInBox( queryMin, queryMax )
	elseif ents.FindInSphere then candidates = ents.FindInSphere( eye, blockSize * 6 )
	else return false end
	for _, entity in ipairs( candidates or {} ) do
		if IsValid( entity ) and entity ~= ply and entity ~= ply:GetActiveWeapon() then
			local class = entity:GetClass()
			if class ~= "mc_chunk" and class ~= "mc_chunk_phys" and class ~= "mc_collision_carrier" then
				local mins, maxs = entity:WorldSpaceAABB()
				if eye.x >= mins.x and eye.x <= maxs.x and eye.y >= mins.y and eye.y <= maxs.y
				and eye.z >= mins.z and eye.z <= maxs.z then return true end
			end
		end
	end
	return false
end

local function voxelHullBlocked( className, position )
	local blockSize = engineBlockSize()
	local mins, maxs
	if className == "mc_boat" then
		mins = Vector( -0.6875 * blockSize, -0.6875 * blockSize, 0 )
		maxs = Vector( 0.6875 * blockSize, 0.6875 * blockSize, 0.5625 * blockSize )
	else
		mins = Vector( -0.49 * blockSize, -0.49 * blockSize, 0 )
		maxs = Vector( 0.49 * blockSize, 0.49 * blockSize, 0.7 * blockSize )
	end
	if not World or not World.GetBlockState then return false end
	local worldMin, worldMax = position + mins, position + maxs
	local minBx, minBy, minBz = Coords.WorldToCell( worldMin )
	local maxBx, maxBy, maxBz = Coords.WorldToCell( worldMax )
	for bz = minBz, maxBz do
		for by = minBy, maxBy do
			for bx = minBx, maxBx do
				local stateId = World.GetBlockState( bx, by, bz ) or 0
				if stateId ~= 0 and not ( Liquid and Liquid.GetAt and Liquid.GetAt( bx, by, bz ) ) then
					local shape = World.GetCellShape and World.GetCellShape( bx, by, bz ) or nil
					local boxes = shape and shape.collisionBoxes or nil
					if boxes == nil and shape and shape.hasCollision then boxes = { { 0, 0, 0, 1, 1, 1 } } end
					local cellMin = Coords.CellMin( bx, by, bz )
					for _, box in ipairs( boxes or {} ) do
						local boxMin = cellMin + Vector( box[1] * blockSize, box[2] * blockSize, box[3] * blockSize )
						local boxMax = cellMin + Vector( box[4] * blockSize, box[5] * blockSize, box[6] * blockSize )
						if worldMin.x < boxMax.x and worldMax.x > boxMin.x
						and worldMin.y < boxMax.y and worldMax.y > boxMin.y
						and worldMin.z < boxMax.z and worldMax.z > boxMin.z then return true end
					end
				end
			end
		end
	end
	return false
end

local function spawnBlocked( className, position )
	if voxelHullBlocked( className, position ) then return true end
	local filter = function( entity )
		local class = IsValid( entity ) and entity:GetClass() or ""
		return class ~= "mc_chunk" and class ~= "mc_chunk_phys" and class ~= "mc_collision_carrier"
	end
	local blockSize = engineBlockSize()
	local halfWidth = className == "mc_boat" and 0.6875 or 0.49
	local height = className == "mc_boat" and 0.5625 or 0.7
	local trace = util.TraceHull( {
		start = position,
		endpos = position,
		mins = Vector( -halfWidth * blockSize, -halfWidth * blockSize, 0 ),
		maxs = Vector( halfWidth * blockSize, halfWidth * blockSize, height * blockSize ),
		filter = filter,
		mask = MASK_SOLID,
	} )
	return trace.Hit == true
end

local function consumeSpawnedVehicle( ply, stack, entity, reason )
	if not SV.ConsumeSelectedItem then entity:Remove() return false, "selected_consume_unavailable" end
	local result, _, _, _, consumeError = SV.ConsumeSelectedItem( ply, 1, nil, {
		expectedItem = stack.item,
		expectedStackHash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil,
		reason = reason,
	} )
	if not result or result.ok ~= true then
		entity:Remove()
		return false, consumeError or "vehicle_consume_failed"
	end
	return true
end

local function spawnVehicle( ply, stack, spec, position, angles, setup )
	-- BoatItem rejects a colliding boat. The non-experimental MinecartItem used
	-- by OldMinecartBehavior does not run a noCollision check at placement time.
	if spec.kind == "boat" and spawnBlocked( spec.class, position ) then
		return false, "vehicle_spawn_blocked"
	end
	local entity = ents.Create( spec.class )
	if not IsValid( entity ) then return false, "vehicle_entity_unavailable" end
	entity:SetPos( position )
	entity:SetAngles( angles )
	entity:SetOwner( ply )
	if setup then setup( entity ) end
	entity:Spawn()
	entity:Activate()
	if not IsValid( entity ) then return false, "vehicle_spawn_failed" end
	local consumed, consumeError = consumeSpawnedVehicle( ply, stack, entity, "place_" .. spec.kind )
	if not consumed then return false, consumeError end
	return true, entity
end

function SV.UseVehicleItem( ply, stack, context )
	local spec = stack and vehicleSpec( stack.item ) or nil
	if not spec or not IsValid( ply ) or not ply:Alive() then return false, "invalid_vehicle_item" end
	if spec.kind == "boat" then
		local hit = traceVehiclePlacement( ply, true )
		if not hit or not hit.Hit or not hit.HitPos then return false, "vehicle_miss" end
		if playerStartsInsidePickableEntity( ply ) then return false, "vehicle_eye_obstructed" end
		local yaw = ply:EyeAngles().y
		return spawnVehicle( ply, stack, spec, hit.HitPos, Angle( 0, yaw, 0 ), function( entity )
			entity:SetBoatType( spec.woodType )
			entity:SetBoatItemName( stack.item )
			entity:SetRaft( spec.raft == true )
		end )
	end

	local target = context and context.target or nil
	local bx, by, bz = target and target.bx, target and target.by, target and target.bz
	if bx == nil then
		local hit = traceVehiclePlacement( ply, false )
		if not hit then return false, "minecart_miss" end
		bx, by, bz = hit.bx, hit.by, hit.bz
	end
	local stateId = World and World.GetBlockState and World.GetBlockState( bx, by, bz ) or 0
	if not isRailState( stateId ) then return false, "minecart_requires_rail" end
	local shape = Blocks and Blocks.GetProperty and Blocks.GetProperty( stateId, "shape" ) or "north_south"
	local slope = string.sub( tostring( shape ), 1, 10 ) == "ascending_"
	local blockSize = engineBlockSize()
	local position = Coords.CellMin( bx, by, bz ) + Vector( blockSize * 0.5, blockSize * 0.5, blockSize * ( 0.0625 + ( slope and 0.5 or 0 ) ) )
	local yaw = ( shape == "east_west" or shape == "ascending_east" or shape == "ascending_west" ) and 0 or 90
	return spawnVehicle( ply, stack, spec, position, Angle( 0, yaw, 0 ), function( entity )
		entity:SetMinecartItemName( stack.item )
	end )
end
