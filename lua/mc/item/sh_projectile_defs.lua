-- Shared projectile constants.  Motion is expressed in Minecraft blocks per
-- second first, then converted to Source units by the server entity.  Keeping
-- this table shared makes the client preview/model context agree with the
-- authoritative launch path without sending arbitrary client physics values.

MC = MC or {}

MC.ProjectileDefinitions = MC.ProjectileDefinitions or {
	["minecraft:arrow"] = {
		kind = "arrow", speed = 60, gravity = 20, lifetime = 20,
		damage = 2, pickup = true,
	},
	["minecraft:spectral_arrow"] = {
		kind = "arrow", speed = 60, gravity = 20, lifetime = 20,
		damage = 2, pickup = true,
	},
	["minecraft:egg"] = {
		kind = "throwable", speed = 30, gravity = 20, lifetime = 10,
		damage = 0,
	},
	["minecraft:snowball"] = {
		kind = "throwable", speed = 30, gravity = 20, lifetime = 10,
		damage = 0,
	},
	["minecraft:ender_pearl"] = {
		kind = "ender_pearl", speed = 30, gravity = 20, lifetime = 10,
		damage = 0, teleport = true,
	},
	["minecraft:experience_bottle"] = {
		kind = "throwable", speed = 14, gravity = 20, lifetime = 10,
		damage = 0, pitch = -20,
	},
	["minecraft:splash_potion"] = {
		kind = "potion", speed = 10, gravity = 20, lifetime = 10,
		damage = 0, pitch = -20,
	},
	["minecraft:lingering_potion"] = {
		kind = "potion", speed = 10, gravity = 20, lifetime = 10,
		damage = 0, pitch = -20,
	},
	["minecraft:wind_charge"] = {
		kind = "wind_charge", speed = 35, gravity = 0, lifetime = 8,
		damage = 0,
	},
	["minecraft:firework_rocket"] = {
		kind = "firework", speed = 40, gravity = 0, lifetime = 8,
		damage = 0,
	},
	["minecraft:trident"] = {
		kind = "trident", speed = 50, gravity = 20, lifetime = 20,
		damage = 8, pickup = true,
	},
}

MC.ProjectileAmmoDefinitions = MC.ProjectileAmmoDefinitions or {
	["minecraft:arrow"] = true,
	["minecraft:spectral_arrow"] = true,
	["minecraft:firework_rocket"] = true,
}

function MC.GetProjectileDefinition( item )
	local name = type( item ) == "table" and item.item or item
	return MC.ProjectileDefinitions[ tostring( name or "" ) ]
end

function MC.IsProjectileAmmo( item )
	local name = type( item ) == "table" and item.item or item
	return MC.ProjectileAmmoDefinitions[ tostring( name or "" ) ] == true
end

function MC.ProjectileWorldScale()
	return math.max( 0.001, tonumber( MC.BS ) or 36.5 )
end

-- Keep the conversion in one function.  The slightly verbose implementation
-- avoids a global-name typo becoming a silent nil multiplication in GLua.
function MC.ProjectileSpeed( definition, multiplier )
	return math.max( 0, tonumber( definition and definition.speed ) or 0 )
		* ( tonumber( multiplier ) or 1 ) * MC.ProjectileWorldScale()
end

MC.ProjectileSpeedUnits = MC.ProjectileSpeed

function MC.ProjectileGravity( definition )
	return math.max( 0, tonumber( definition and definition.gravity ) or 0 ) * MC.ProjectileWorldScale()
end

function MC.BowPowerForTicks( ticks )
	local power = math.max( 0, tonumber( ticks ) or 0 ) / 20
	power = ( power * power + power * 2 ) / 3
	return math.Clamp( power, 0, 1 )
end
