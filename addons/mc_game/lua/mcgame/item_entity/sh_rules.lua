-- Source-verified ItemEntity rules for gameplay-parity checkpoint 4.
-- Values stay in Minecraft blocks/tick so every constant remains directly
-- comparable with out/net/minecraft; adapters convert only at the boundary.

MC = MC or {}
MC.ItemEntityParity = MC.ItemEntityParity or {}

local R = MC.ItemEntityParity

R.Constants = R.Constants or {
	tickSeconds = 1 / 20,
	width = 0.25,
	height = 0.25,
	eyeHeight = 0.2125,
	defaultHealth = 5,
	lifetimeTicks = 6000,
	infinitePickupDelay = 32767,
	infiniteAge = -32768,
	extendedAge = -6000,
	defaultPickupDelayTicks = 10,
	livingDropPickupDelayTicks = 40,
	gravity = 0.04,
	airDrag = 0.98,
	waterHorizontal = 0.99,
	lavaHorizontal = 0.95,
	fluidFloatHeight = 0.1,
	fluidVerticalTarget = 0.06,
	fluidVerticalLift = 0.0005,
	waterCurrentScale = 0.014,
	lavaCurrentScale = 0.0023333333333333335,
	fastLavaCurrentScale = 0.007,
	currentHeightScaleThreshold = 0.4,
	currentMinimumHorizontalSpeed = 0.003,
	currentMinimumImpulse = 0.0045,
	currentMinimumLengthSquared = 1.0e-5,
	idleHorizontalLengthSquared = 1.0e-5,
	mergeMovingRate = 2,
	mergeStationaryRate = 40,
	mergeHorizontalInflate = 0.5,
	fluidBoundsDeflate = 0.001,
	insideBoundsDeflate = 0.00001,
	fireSeconds = 8,
	lavaFireSeconds = 15,
	fireTicksPerSecond = 20,
	onFireDamageInterval = 20,
	inFireDamage = 1,
	soulFireDamage = 2,
	lavaDamage = 4,
	cactusDamage = 1,
	pistonTicks = 2,
	pistonTickMovement = 0.51,
	pistonPushOffset = 0.01,
}

local C = R.Constants

if CreateConVar then
	local flags = FCVAR_ARCHIVE or 0
	if SERVER and bit and bit.bor then
		flags = bit.bor( flags, FCVAR_REPLICATED or 0, FCVAR_NOTIFY or 0 )
	end
	R.EnableConVar = GetConVar and GetConVar( "mc_gameplay_parity_item_entity" )
		or CreateConVar( "mc_gameplay_parity_item_entity", "0", flags,
			"Enable source-verified Minecraft ItemEntity physics and lifecycle." )
end

function R.Enabled()
	local cv = R.EnableConVar
	if not cv and GetConVar then cv = GetConVar( "mc_gameplay_parity_item_entity" ) end
	return cv and cv.GetBool and cv:GetBool() == true or false
end

function R.SecondsToTicks( seconds )
	return math.max( 0, math.floor( ( tonumber( seconds ) or 0 ) / C.tickSeconds + 0.5 ) )
end

function R.ApplyFluidCurrent( vx, vy, vz, tracker, scale, player )
	vx, vy, vz = tonumber( vx ) or 0, tonumber( vy ) or 0, tonumber( vz ) or 0
	if type( tracker ) ~= "table" then return vx, vy, vz end
	local count = math.max( 0, math.floor( tonumber( tracker.count ) or 0 ) )
	local ix, iy, iz = tonumber( tracker.flowX ) or 0,
		tonumber( tracker.flowY ) or 0, tonumber( tracker.flowZ ) or 0
	local lengthSquared = ix * ix + iy * iy + iz * iz
	if count == 0 or lengthSquared < C.currentMinimumLengthSquared then return vx, vy, vz end
	if player == true then
		ix, iy, iz = ix / count, iy / count, iz / count
	else
		local length = math.sqrt( lengthSquared )
		ix, iy, iz = ix / length, iy / length, iz / length
	end
	local multiplier = tonumber( scale ) or 0
	ix, iy, iz = ix * multiplier, iy * multiplier, iz * multiplier
	local impulseLength = math.sqrt( ix * ix + iy * iy + iz * iz )
	if math.abs( vx ) < C.currentMinimumHorizontalSpeed
	and math.abs( vy ) < C.currentMinimumHorizontalSpeed
	and impulseLength > 0 and impulseLength < C.currentMinimumImpulse then
		local minimumScale = C.currentMinimumImpulse / impulseLength
		ix, iy, iz = ix * minimumScale, iy * minimumScale, iz * minimumScale
	end
	return vx + ix, vy + iy, vz + iz
end

function R.ApplyTrackedCurrents( vx, vy, vz, fluids )
	fluids = type( fluids ) == "table" and fluids or {}
	vx, vy, vz = R.ApplyFluidCurrent( vx, vy, vz, fluids.water, C.waterCurrentScale, false )
	return R.ApplyFluidCurrent( vx, vy, vz, fluids.lava, C.lavaCurrentScale, false )
end

function R.ApplyFluidMovement( vx, vy, vz, fluids )
	fluids = type( fluids ) == "table" and fluids or {}
	local waterHeight = tonumber( fluids.water and fluids.water.height ) or 0
	local lavaHeight = tonumber( fluids.lava and fluids.lava.height ) or 0
	local multiplier
	if waterHeight > C.fluidFloatHeight then multiplier = C.waterHorizontal
	elseif lavaHeight > C.fluidFloatHeight then multiplier = C.lavaHorizontal end
	if not multiplier then return tonumber( vx ) or 0, tonumber( vy ) or 0, tonumber( vz ) or 0, nil end
	vx, vy, vz = ( tonumber( vx ) or 0 ) * multiplier,
		( tonumber( vy ) or 0 ) * multiplier, tonumber( vz ) or 0
	if vz < C.fluidVerticalTarget then vz = vz + C.fluidVerticalLift end
	return vx, vy, vz, waterHeight > C.fluidFloatHeight and "water" or "lava"
end

function R.ApplyPreMoveForces( vx, vy, vz, fluids )
	fluids = type( fluids ) == "table" and fluids or {}
	local kind
	vx, vy, vz, kind = R.ApplyFluidMovement( vx, vy, vz, fluids )
	if kind then return vx, vy, vz, kind end
	return tonumber( vx ) or 0, tonumber( vy ) or 0, ( tonumber( vz ) or 0 ) - C.gravity, nil
end

function R.ApplyDrag( vx, vy, vz, onGround, friction )
	local horizontal = C.airDrag
	if onGround == true then horizontal = horizontal * ( tonumber( friction ) or 0.6 ) end
	vx, vy, vz = ( tonumber( vx ) or 0 ) * horizontal,
		( tonumber( vy ) or 0 ) * horizontal, ( tonumber( vz ) or 0 ) * C.airDrag
	if onGround == true and vz < 0 then vz = vz * -0.5 end
	return vx, vy, vz
end

function R.ShouldSkipMovement( onGround, vx, vy, tickCount, entityId )
	if onGround ~= true then return false end
	local horizontalSquared = ( tonumber( vx ) or 0 ) ^ 2 + ( tonumber( vy ) or 0 ) ^ 2
	if horizontalSquared > C.idleHorizontalLengthSquared then return false end
	return ( ( math.floor( tonumber( tickCount ) or 0 )
		+ math.floor( tonumber( entityId ) or 0 ) ) % 4 ) ~= 0
end

function R.MergeRate( movedAcrossCell )
	return movedAcrossCell == true and C.mergeMovingRate or C.mergeStationaryRate
end

function R.ShouldMergeThisTick( tickCount, movedAcrossCell )
	local rate = R.MergeRate( movedAcrossCell )
	return math.floor( tonumber( tickCount ) or 0 ) % rate == 0
end

function R.CountsCanMerge( leftCount, rightCount, maximum )
	leftCount, rightCount = math.floor( tonumber( leftCount ) or 0 ), math.floor( tonumber( rightCount ) or 0 )
	maximum = math.max( 0, math.floor( tonumber( maximum ) or 0 ) )
	return leftCount > 0 and rightCount > 0 and leftCount < maximum
		and rightCount < maximum and leftCount + rightCount <= maximum
end

function R.MergeTarget( currentCount, otherCount )
	-- ItemEntity#tryToMerge: equal counts merge the current entity into `other`.
	return ( tonumber( otherCount ) or 0 ) < ( tonumber( currentCount ) or 0 )
		and "current" or "other"
end

local DAMAGE_TYPE_TAGS = {
	["minecraft:is_fire"] = {
		["minecraft:in_fire"] = true, ["minecraft:campfire"] = true,
		["minecraft:on_fire"] = true, ["minecraft:lava"] = true,
		["minecraft:hot_floor"] = true, ["minecraft:sulfur_cube_hot"] = true,
		["minecraft:unattributed_fireball"] = true, ["minecraft:fireball"] = true,
	},
	["minecraft:is_explosion"] = {
		["minecraft:fireworks"] = true, ["minecraft:explosion"] = true,
		["minecraft:player_explosion"] = true, ["minecraft:bad_respawn_point"] = true,
	},
}

R.DamageTypeTags = R.DamageTypeTags or DAMAGE_TYPE_TAGS

local FIRE_RESISTANT_ITEMS = {
	"ancient_debris", "netherite_block", "netherite_ingot", "netherite_scrap",
	"netherite_sword", "netherite_shovel", "netherite_pickaxe", "netherite_axe", "netherite_hoe",
	"netherite_helmet", "netherite_chestplate", "netherite_leggings", "netherite_boots",
	"netherite_horse_armor", "netherite_spear", "netherite_nautilus_armor",
}

R.DefaultDamageResistance = R.DefaultDamageResistance or {
	["minecraft:nether_star"] = "#minecraft:is_explosion",
}
for _, name in ipairs( FIRE_RESISTANT_ITEMS ) do
	R.DefaultDamageResistance["minecraft:" .. name] = "#minecraft:is_fire"
end

local function canonicalId( value )
	value = string.lower( tostring( value or "" ) )
	if value == "" then return nil end
	local tag = string.sub( value, 1, 1 ) == "#"
	if tag then value = string.sub( value, 2 ) end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	return tag and "#" .. value or value
end

local function componentFor( stack, key )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil end
	return components[key] ~= nil and components[key] or components[string.gsub( key, "^minecraft:", "" )]
end

local function resistanceContains( value, damageType, seen )
	if type( value ) == "string" then
		local id = canonicalId( value )
		if not id then return false end
		if string.sub( id, 1, 1 ) ~= "#" then return id == damageType end
		local tag = R.DamageTypeTags[string.sub( id, 2 )]
		return tag and tag[damageType] == true or false
	end
	if type( value ) ~= "table" then return false end
	seen = seen or {}
	if seen[value] then return false end
	seen[value] = true
	if value.types ~= nil and resistanceContains( value.types, damageType, seen ) then return true end
	if value.values ~= nil and resistanceContains( value.values, damageType, seen ) then return true end
	for key, entry in pairs( value ) do
		if key ~= "types" and key ~= "values" then
			if type( key ) == "string" and entry == true and resistanceContains( key, damageType, seen ) then return true end
			if resistanceContains( entry, damageType, seen ) then return true end
		end
	end
	return false
end

function R.EffectiveDamageResistance( stack )
	local component = componentFor( stack, "minecraft:damage_resistant" )
	if component ~= nil then return component end
	return R.DefaultDamageResistance[type( stack ) == "table" and stack.item or nil]
end

function R.StackResistsDamage( stack, damageType )
	damageType = canonicalId( damageType )
	if not damageType then return false end
	return resistanceContains( R.EffectiveDamageResistance( stack ), damageType )
end

function R.StackCanBeHurtBy( stack, damageType )
	return not R.StackResistsDamage( stack, damageType )
end

function R.HealthAfterDamage( health, damage )
	local value = ( tonumber( health ) or C.defaultHealth ) - math.max( 0, tonumber( damage ) or 0 )
	-- Java's (int) cast truncates toward zero.
	return value < 0 and math.ceil( value ) or math.floor( value )
end

function R.AABBIntersects( aMin, aMax, bMin, bMax )
	return aMax.x > bMin.x and aMin.x < bMax.x
		and aMax.y > bMin.y and aMin.y < bMax.y
		and aMax.z > bMin.z and aMin.z < bMax.z
end

function R.PistonPushDistance( entityMin, entityMax, destinationMin, destinationMax, dx, dy, dz )
	local offset = C.pistonPushOffset
	if dx > 0 then return math.max( 0, destinationMax.x - entityMin.x + offset ) end
	if dx < 0 then return math.max( 0, entityMax.x - destinationMin.x + offset ) end
	if dy > 0 then return math.max( 0, destinationMax.y - entityMin.y + offset ) end
	if dy < 0 then return math.max( 0, entityMax.y - destinationMin.y + offset ) end
	if dz > 0 then return math.max( 0, destinationMax.z - entityMin.z + offset ) end
	if dz < 0 then return math.max( 0, entityMax.z - destinationMin.z + offset ) end
	return 0
end
