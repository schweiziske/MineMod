-- Source-verified Dispenser / Dropper behavior dispatch.
--
-- The engine owns the triggered state and the four-tick schedule.  This file
-- only observes scheduled ticks and performs the game-side inventory/entity
-- action, so the engine never depends on mcgame.

MC = MC or {}
MC.SV = MC.SV or {}

local API = MC.API or {}
local World = API.World or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}
local Schedule = API.Schedule or {}
local L = MC.LogisticsParity or {}
local C = L.Constants or {}
local SV = MC.SV

local D = MC.LogisticsDispense or {}
MC.LogisticsDispense = D
D.Registry = D.Registry or {}
D.Unsupported = D.Unsupported or {}

local function copy( stack, count ) return MC.CopyItemStack( stack, count ) end

local function markChanged( container, slot )
	container.changed = true
	container.changedSlotSet = container.changedSlotSet or {}
	container.changedSlotSet[slot] = true
end

local function decrement( stack )
	return stack and stack.count > 1 and copy( stack, stack.count - 1 ) or nil
end

local function randomInt( context, bound )
	bound = math.max( 1, math.floor( tonumber( bound ) or 1 ) )
	if type( context ) == "table" and type( context.randomInt ) == "function" then
		return math.floor( tonumber( context.randomInt( bound ) ) or 0 ) % bound
	end
	if math.random then return math.random( 0, bound - 1 ) end
	return 0
end

local function randomUnit( context )
	if type( context ) == "table" and type( context.randomUnit ) == "function" then
		return math.max( 0, math.min( 1, tonumber( context.randomUnit() ) or 0 ) )
	end
	if math.Rand then return math.Rand( 0, 1 ) end
	return math.random()
end

local function triangle( context, mean, deviation )
	local a = randomUnit( context )
	local b = randomUnit( context )
	return mean + ( a - b ) * deviation
end

local function stateName( stateId )
	return Blocks.Name and Blocks.Name( stateId ) or nil
end

local function directionAt( stateId )
	return Blocks.GetProperty and L.NormalizeDirection( Blocks.GetProperty( stateId, "facing" ) ) or nil
end

local function worldPosition( bx, by, bz, direction )
	local x, y, z = L.DefaultDispensePosition( bx, by, bz, direction )
	if x == nil then return nil end
	local minimum = Coords.CellMin and Coords.CellMin( bx, by, bz )
	local size = Coords.BlockSize and tonumber( Coords.BlockSize() ) or tonumber( MC.BS ) or 36.5
	if minimum then return minimum + Vector( x - bx, y - by, z - bz ) * size end
	return Vector( x * size, y * size, z * size )
end

local function sourceVelocity( context, direction )
	local vx, vy, vz, deviation = L.DefaultDispenseVelocityMeans( direction, randomUnit( context ) )
	local dx, dy, dz = triangle( context, vx, deviation ), triangle( context, vy, deviation ),
		triangle( context, vz, deviation )
	local size = Coords.BlockSize and tonumber( Coords.BlockSize() ) or tonumber( MC.BS ) or 36.5
	return Vector( dx, dy, dz ) * ( size / ( C.tickSeconds or 0.05 ) )
end

local PROJECTILE_ITEMS = {
	"minecraft:arrow", "minecraft:tipped_arrow", "minecraft:spectral_arrow",
	"minecraft:egg", "minecraft:blue_egg", "minecraft:brown_egg", "minecraft:snowball",
	"minecraft:experience_bottle", "minecraft:splash_potion", "minecraft:lingering_potion",
	"minecraft:firework_rocket", "minecraft:fire_charge", "minecraft:wind_charge",
}
for _, itemName in ipairs( PROJECTILE_ITEMS ) do D.Registry[itemName] = "projectile" end

-- These entries are deliberately explicit no-ops until a matching backend is
-- available.  Java's behavior must not be approximated by silently dropping
-- the item when the action is equipment, a block entity, or player-contextual.
local UNSUPPORTED_ITEMS = {
	"minecraft:armor_stand", "minecraft:chest",
	"minecraft:oak_boat", "minecraft:spruce_boat", "minecraft:birch_boat", "minecraft:jungle_boat",
	"minecraft:dark_oak_boat", "minecraft:acacia_boat", "minecraft:cherry_boat", "minecraft:mangrove_boat",
	"minecraft:pale_oak_boat", "minecraft:bamboo_raft",
	"minecraft:oak_chest_boat", "minecraft:spruce_chest_boat", "minecraft:birch_chest_boat",
	"minecraft:jungle_chest_boat", "minecraft:dark_oak_chest_boat", "minecraft:acacia_chest_boat",
	"minecraft:cherry_chest_boat", "minecraft:mangrove_chest_boat", "minecraft:pale_oak_chest_boat",
	"minecraft:bamboo_chest_raft", "minecraft:lava_bucket", "minecraft:water_bucket",
	"minecraft:powder_snow_bucket", "minecraft:salmon_bucket", "minecraft:cod_bucket",
	"minecraft:pufferfish_bucket", "minecraft:tropical_fish_bucket", "minecraft:axolotl_bucket",
	"minecraft:tadpole_bucket", "minecraft:sulfur_cube_bucket", "minecraft:bucket",
	"minecraft:flint_and_steel", "minecraft:bone_meal", "minecraft:tnt",
	"minecraft:wither_skeleton_skull", "minecraft:carved_pumpkin", "minecraft:glass_bottle",
	"minecraft:glowstone", "minecraft:shears", "minecraft:brush", "minecraft:honeycomb",
	"minecraft:potion", "minecraft:shulker_box", "minecraft:white_shulker_box", "minecraft:orange_shulker_box",
	"minecraft:magenta_shulker_box", "minecraft:light_blue_shulker_box", "minecraft:yellow_shulker_box",
	"minecraft:lime_shulker_box", "minecraft:pink_shulker_box", "minecraft:gray_shulker_box",
	"minecraft:light_gray_shulker_box", "minecraft:cyan_shulker_box", "minecraft:purple_shulker_box",
	"minecraft:blue_shulker_box", "minecraft:brown_shulker_box", "minecraft:green_shulker_box",
	"minecraft:red_shulker_box", "minecraft:black_shulker_box",
	"minecraft:minecart", "minecraft:chest_minecart", "minecraft:furnace_minecart",
	"minecraft:tnt_minecart", "minecraft:hopper_minecart", "minecraft:command_block_minecart",
}
for _, itemName in ipairs( UNSUPPORTED_ITEMS ) do D.Unsupported[itemName] = "backend_unavailable" end

function D.BehaviorFor( stack )
	local itemName = type( stack ) == "table" and tostring( stack.item or "" ) or tostring( stack or "" )
	local behavior = D.Registry[itemName]
	if behavior then return behavior end
	if D.Unsupported[itemName] then return "unsupported" end
	if MC.ItemEquipmentSlot and MC.ItemEquipmentSlot( stack ) then return "unsupported" end
	if MC.ItemInTag and MC.ItemInTag( stack, "minecraft:sulfur_cube_swallowable" ) then return "unsupported" end
	local components = type( stack ) == "table" and stack.components or nil
	local entityData = type( components ) == "table"
		and ( components["minecraft:entity_data"] or components.entity_data ) or nil
	if string.match( itemName, "_spawn_egg$" ) and entityData ~= nil then return "unsupported" end
	return "default"
end

local function spawnDefaultItem( context, stack, direction )
	if not SV.SpawnItemDrop then return nil, "item_drop_backend_unavailable" end
	local position = worldPosition( context.bx, context.by, context.bz, direction )
	local entity = SV.SpawnItemDrop( position, copy( stack, 1 ), nil, {
		positionJitter = false, pickupDelay = 0, noMerge = true,
		velocity = sourceVelocity( context, direction ),
	} )
	return IsValid( entity ) and entity or nil, entity and nil or "item_drop_spawn_failed"
end

local function planDefaultBehavior( context, stack, direction )
	local spawned, err = spawnDefaultItem( context, stack, direction )
	if not spawned then return nil, err end
	return { spawned = { spawned }, after = decrement( stack ), behavior = "default" }
end

local function planBehavior( context, stack, direction )
	local behavior = D.BehaviorFor( stack )
	if behavior == "unsupported" then return nil, D.Unsupported[stack.item] or "behavior_backend_unavailable" end
	if behavior == "projectile" then return nil, "projectile_backend_incomplete" end
	if behavior == "default" then return planDefaultBehavior( context, stack, direction ) end
	return nil, "unknown_dispense_behavior"
end

local function rollback( plan )
	for _, entity in ipairs( plan and plan.spawned or {} ) do if IsValid( entity ) then entity:Remove() end end
end

local function targetContainer( context, direction )
	local dx, dy, dz = L.DirectionOffset( direction )
	if not dx then return nil, "invalid_direction" end
	return L.ContainerAt( context.bx + dx, context.by + dy, context.bz + dz,
		L.OppositeDirection( direction ), { create = true } )
end

local function commitPlan( source, sourceSlot, target, plan, reason )
	local containers = { source }
	if target then containers[#containers + 1] = target end
	local snapshots = {}
	for _, container in ipairs( containers ) do
		snapshots[container] = { storage = {}, state = {}, changed = container.changed, stateChanged = container.stateChanged }
		for slot = 1, container.size do snapshots[container].storage[slot] = copy( container.storage[slot] ) end
		for key, value in pairs( container.state or {} ) do snapshots[container].state[key] = value end
	end
	source.storage[sourceSlot + 1] = plan.after
	markChanged( source, sourceSlot )
	local ok, result = L.CommitContainers( containers, reason )
	if not ok then
		for _, container in ipairs( containers ) do
			for slot = 1, container.size do container.storage[slot] = snapshots[container].storage[slot] end
			container.state = snapshots[container].state
			container.changed, container.stateChanged = snapshots[container].changed, snapshots[container].stateChanged
			container.changedSlotSet = {}
		end
		rollback( plan )
		return false, result
	end
	return true, result
end

local function dropperTransfer( source, slot, target )
	local stack = source.storage[slot + 1]
	if MC.IsEmptyItemStack( stack ) then return false end
	local remaining, moved = L.InsertStack( target, copy( stack, 1 ), target.accessDirection, source )
	if ( tonumber( moved ) or 0 ) ~= 1 or not MC.IsEmptyItemStack( remaining ) then return false end
	return true
end

function D.DispenseAt( context )
	if not L.Enabled() then return false, "feature_disabled" end
	context = type( context ) == "table" and context or {}
	local stateId = World.GetBlockState and World.GetBlockState( context.bx, context.by, context.bz ) or context.stateId or 0
	local name = stateName( stateId )
	if name ~= "minecraft:dispenser" and name ~= "minecraft:dropper" then return false, "not_dispenser" end
	local direction = directionAt( stateId)
	if not direction then return false, "facing_unavailable" end
	local source, sourceError = L.ContainerAt( context.bx, context.by, context.bz, nil, { create = true } )
	if not source then return false, sourceError end
	local slot = L.ReservoirSlot( source.storage, source.size, function( bound ) return randomInt( context, bound ) end )
	if slot < 0 then return true, { empty = true } end
	local stack = copy( source.storage[slot + 1] )
	if MC.IsEmptyItemStack( stack ) then return true, { empty = true } end

	if name == "minecraft:dropper" then
		local target, targetError = targetContainer( context, direction )
		if target then
			if not dropperTransfer( source, slot, target ) then return true, { blocked = true } end
			local plan = { after = decrement( stack ), spawned = {}, behavior = "container" }
			local ok, result = commitPlan( source, slot, target, plan, "dropper_container" )
			return ok, ok and { moved = true, behavior = "container", commit = result } or result
		elseif targetError ~= "not_container" then
			return false, targetError
		end
		local plan, planError = planDefaultBehavior( context, stack, direction )
		if not plan then return true, { unsupported = true, reason = planError } end
		local ok, result = commitPlan( source, slot, nil, plan, "dropper_dispense" )
		if not ok then return false, result end
		return true, { moved = true, behavior = plan.behavior, commit = result }
	end

	local plan, planError = planBehavior( context, stack, direction )
	if not plan then return true, { unsupported = true, reason = planError } end
	local ok, result = commitPlan( source, slot, nil, plan, name .. "_dispense" )
	if not ok then return false, result end
	return true, { moved = true, behavior = plan.behavior, commit = result }
end

function D.OnScheduledTick( context )
	if not L.Enabled() then return nil end
	D.DispenseAt( context )
	return nil
end

if Schedule.Observe then
	Schedule.Observe( "mcgame_logistics_dispenser", "minecraft:dispenser", { OnScheduledTick = D.OnScheduledTick } )
	Schedule.Observe( "mcgame_logistics_dropper", "minecraft:dropper", { OnScheduledTick = D.OnScheduledTick } )
end
