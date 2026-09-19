-- Server-authoritative Minecraft projectile weapons and throwable items.
-- Clients never submit a trajectory: the server derives it from the player's
-- current eye angles, mutates inventory atomically, and owns the projectile
-- entity until impact or expiry.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local MAX_PROJECTILES_PER_SECOND = 16
local MAX_CHARGED_PROJECTILES = 16

local function validPlayer( ply )
	return IsValid( ply ) and ply:IsPlayer() and ply:Alive()
end

local function infiniteMaterials( ply )
	return SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true
end

local function selected( record )
	local index = math.Clamp( math.floor( tonumber( record and record.selected ) or 0 ), 0, 8 )
	return index, record and MC.ContainerGetStack( record.container, index ) or nil
end

local function projectileRateAllowed( record, amount )
	amount = math.Clamp( math.floor( tonumber( amount ) or 1 ), 1, MAX_PROJECTILES_PER_SECOND )
	local now = CurTime()
	local rate = record.projectileRate
	if not rate or now - rate.startedAt >= 1 then
		record.projectileRate = { startedAt = now, count = amount }
		return true
	end
	if rate.count + amount > MAX_PROJECTILES_PER_SECOND then return false end
	rate.count = rate.count + amount
	return true
end

local function allowedAmmo( kind )
	if kind == "bow" then
		return { ["minecraft:arrow"] = true, ["minecraft:spectral_arrow"] = true }
	end
	return { ["minecraft:arrow"] = true, ["minecraft:spectral_arrow"] = true,
		["minecraft:firework_rocket"] = true }
end

local function findAmmo( record, kind )
	local allowed = allowedAmmo( kind )
	for _, slot in ipairs( record and record.container and record.container.slots or {} ) do
		local stack = MC.InventorySlotGet( slot )
		if stack and allowed[stack.item] then return slot.index, stack end
	end
	return nil, nil
end

local function consumeStackAt( record, slotIndex, amount )
	local stack = MC.ContainerGetStack( record.container, slotIndex )
	if not stack or stack.count < amount then return false, "projectile_stack_missing" end
	local replacement = stack.count > amount and MC.CopyItemStack( stack, stack.count - amount ) or nil
	return MC.ContainerSetStack( record.container, slotIndex, replacement )
end

local function damageStack( stack, amount )
	local definition = stack and MC.GetItem( stack.item ) or nil
	local maximum = math.floor( tonumber( definition and definition.maxDamage ) or 0 )
	if maximum <= 0 or MC.ItemIsUnbreakable( stack ) then return MC.CopyItemStack( stack ), false end
	local damage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) ) + math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if damage >= maximum then return nil, true, damage end
	local replacement = MC.CopyItemStack( stack )
	replacement.damage = damage > 0 and damage or nil
	return replacement, false, damage
end

local function componentTable( stack )
	local components = MC.CopyItemComponents and MC.CopyItemComponents( stack and stack.components ) or {}
	return components or {}
end

local function copyProjectileStacks( projectileStacks )
	if type( projectileStacks ) ~= "table" then return nil end
	local copied = {}
	for _, projectile in ipairs( projectileStacks ) do
		local normalized = MC.NormalizeItemStack and MC.NormalizeItemStack( projectile ) or nil
		if normalized then copied[#copied + 1] = MC.CopyItemStack( normalized, 1 ) end
	end
	return #copied > 0 and copied or nil
end

local function chargedProjectiles( stack )
	local components = stack and stack.components or nil
	local value = components and ( components["minecraft:charged_projectiles"] or components.charged_projectiles ) or nil
	return copyProjectileStacks( value )
end

local function chargedProjectile( stack )
	local projectiles = chargedProjectiles( stack )
	return projectiles and projectiles[1] or nil
end

local function setChargedProjectiles( stack, projectileStacks )
	local replacement = MC.CopyItemStack( stack )
	local components = componentTable( replacement )
	components["minecraft:charged_projectiles"] = copyProjectileStacks( projectileStacks )
	replacement.components = next( components ) and components or nil
	return replacement
end

local function setChargedProjectile( stack, projectileStack )
	return setChargedProjectiles( stack, projectileStack and { projectileStack } or nil )
end

local function projectileIsIntangible( stack )
	local components = stack and stack.components or nil
	return type( components ) == "table"
		and ( components["minecraft:intangible_projectile"] ~= nil
			or components.intangible_projectile ~= nil )
end

local function intangibleProjectile( stack )
	local replacement = MC.CopyItemStack( stack, 1 )
	local components = componentTable( replacement )
	components["minecraft:intangible_projectile"] = true
	replacement.components = components
	return replacement
end

local function buildChargedProjectiles( ammo, projectileCount, intangibleFirst )
	projectileCount = math.Clamp(
		math.floor( tonumber( projectileCount ) or 1 ), 1, MAX_CHARGED_PROJECTILES )
	local projectiles = {}
	for index = 1, projectileCount do
		local projectile = MC.CopyItemStack( ammo, 1 )
		if intangibleFirst == true or index > 1 then projectile = intangibleProjectile( projectile ) end
		projectiles[#projectiles + 1] = projectile
	end
	return projectiles
end

local function projectileDurabilityUse( projectile )
	return projectile and projectile.item == "minecraft:firework_rocket" and 3 or 1
end

local function chargedProjectilesDurabilityUse( projectileStacks )
	local amount = 0
	for _, projectile in ipairs( projectileStacks or {} ) do
		amount = amount + projectileDurabilityUse( projectile )
	end
	return math.Clamp( amount, 1, 255 )
end

local function chargedProjectileHashesMatch( projectileStacks, expectedHashes )
	if type( expectedHashes ) ~= "table" then return true end
	if #projectileStacks ~= #expectedHashes then return false end
	for index, projectile in ipairs( projectileStacks ) do
		local hash = MC.ItemStackHash and MC.ItemStackHash( projectile ) or nil
		if hash ~= tostring( expectedHashes[index] ) then return false end
	end
	return true
end

local function crossbowProjectileCount( weaponStack )
	local level = MC.GetEnchantmentLevel
		and MC.GetEnchantmentLevel( weaponStack, "minecraft:multishot" ) or 0
	return ( tonumber( level ) or 0 ) > 0 and 3 or 1
end

local function crossbowProjectileSpread( weaponStack )
	local level = MC.GetEnchantmentLevel
		and MC.GetEnchantmentLevel( weaponStack, "minecraft:multishot" ) or 0
	return ( tonumber( level ) or 0 ) > 0 and 10 or 0
end

local function crossbowShotAngles( projectileCount, spread )
	projectileCount = math.max( 1, math.floor( tonumber( projectileCount ) or 1 ) )
	spread = tonumber( spread ) or 0
	local step = projectileCount == 1 and 0 or 2 * spread / ( projectileCount - 1 )
	local offset = ( ( projectileCount - 1 ) % 2 ) * step / 2
	local sign, angles = 1, {}
	for zeroIndex = 0, projectileCount - 1 do
		angles[#angles + 1] = offset + sign * math.floor( ( zeroIndex + 1 ) / 2 ) * step
		sign = -sign
	end
	return angles
end

local function rotatedAround( vector, axis, degrees )
	local radians = math.rad( tonumber( degrees ) or 0 )
	if math.abs( radians ) < 0.000001 then return vector end
	axis = axis:GetNormalized()
	local cosine, sine = math.cos( radians ), math.sin( radians )
	return vector * cosine + axis:Cross( vector ) * sine
		+ axis * axis:Dot( vector ) * ( 1 - cosine )
end

local function eyeDirection( ply, pitchOffset )
	local angles = ply:EyeAngles()
	if pitchOffset and Angle then angles = Angle( angles.p + pitchOffset, angles.y, angles.r ) end
	return angles:Forward(), angles
end

local function spawnProjectile( ply, itemName, itemDamage, velocity, definition, options, projectiles )
	if not ents or not ents.Create then return nil, "projectile_entity_unavailable" end
	local ent = ents.Create( "mc_projectile" )
	if not IsValid( ent ) then return nil, "projectile_entity_unavailable" end
	-- Own the entity before any initialization callback can fail.
	projectiles[#projectiles + 1] = ent
	local origin = ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
	local direction = velocity:LengthSqr() > 0 and velocity:GetNormalized() or Vector( 0, 0, 1 )
	ent:SetPos( origin + direction * 12 )
	ent:SetOwner( ply )
	ent:Spawn()
	ent:Activate()
	if ent.SetProjectileItem then ent:SetProjectileItem( itemName, itemDamage ) end
	local launchOptions = {}
	for key, value in pairs( options or {} ) do launchOptions[key] = value end
	launchOptions.gravity = launchOptions.gravity ~= nil and launchOptions.gravity or MC.ProjectileGravity( definition )
	launchOptions.lifetime = launchOptions.lifetime ~= nil and launchOptions.lifetime or definition.lifetime
	launchOptions.damage = launchOptions.damage ~= nil and launchOptions.damage or definition.damage
	local launched, launchError
	if ent.Launch then
		launched, launchError = ent:Launch( velocity, launchOptions )
	else
		launched, launchError = false, "projectile_launch_unavailable"
	end
	if launched ~= true then
		return nil, launchError or "projectile_launch_failed"
	end
	if not IsValid( ent ) then return nil, "projectile_entity_removed" end
	return ent
end

local function removeProjectileEntities( projectiles )
	for _, ent in ipairs( projectiles or {} ) do
		if IsValid( ent ) then ent:Remove() end
	end
end

local function prepareProjectiles( record, snapshot, projectiles, mutate, launch )
	-- Publication remains outside this boundary: its callbacks may already have
	-- sent/persisted the new inventory and must not trigger a speculative rollback.
	local called, prepared, preparationError = pcall( function()
		if mutate then
			local changed, mutationError = mutate()
			if changed ~= true then return nil, mutationError or "projectile_inventory_mutation_failed" end
		end
		return launch()
	end )
	if called and prepared then return prepared end
	MC.ContainerRestore( record.container, snapshot )
	removeProjectileEntities( projectiles )
	if not called then
		MC.Fault( "projectile_prepare_exception", "%s", tostring( prepared ) )
		return nil, "projectile_prepare_exception"
	end
	return nil, preparationError or "projectile_spawn_failed"
end

local function commitMutation( record, snapshot, ply, context, projectiles )
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, context or {} )
	if not result then
		MC.ContainerRestore( record.container, snapshot )
		removeProjectileEntities( projectiles )
		return nil, commitError or "projectile_inventory_commit_failed"
	end
	return result
end

local function mutateAndLaunch( ply, record, sourceStack, itemName, itemDamage, velocity, definition, options, mutate )
	if not projectileRateAllowed( record ) then return nil, "projectile_rate_limited" end
	local snapshot = MC.ContainerSnapshot( record.container )
	local projectiles, launchOptions = {}, {}
	local ent, launchError = prepareProjectiles( record, snapshot, projectiles, mutate, function()
		for key, value in pairs( options or {} ) do launchOptions[key] = value end
		launchOptions.sourceStack = MC.CopyItemStack( sourceStack )
		return spawnProjectile( ply, itemName, itemDamage, velocity, definition, launchOptions, projectiles )
	end )
	if not ent then return nil, launchError end
	local result, commitError = commitMutation( record, snapshot, ply, {
		player = ply, reason = launchOptions.reason or "projectile", actionId = launchOptions.actionId,
	}, projectiles )
	if not result then return nil, commitError end
	return ent, result
end

local function mutateAndLaunchMany( ply, record, specifications, context, mutate )
	if type( specifications ) ~= "table" or #specifications == 0 then
		return nil, "projectile_specifications_missing"
	end
	if not projectileRateAllowed( record, #specifications ) then return nil, "projectile_rate_limited" end
	local snapshot = MC.ContainerSnapshot( record.container )
	local projectiles = {}
	local prepared, preparationError = prepareProjectiles( record, snapshot, projectiles, mutate, function()
		for _, specification in ipairs( specifications ) do
			local launchOptions = {}
			for key, value in pairs( specification.options or {} ) do launchOptions[key] = value end
			launchOptions.sourceStack = MC.CopyItemStack( specification.sourceStack )
			local ent, launchError = spawnProjectile(
				ply,
				specification.itemName,
				specification.itemDamage,
				specification.velocity,
				specification.definition,
				launchOptions,
				projectiles
			)
			if not ent then return nil, launchError end
		end
		return true
	end )
	if not prepared then return nil, preparationError end

	local result, commitError = commitMutation( record, snapshot, ply, {
		player = ply,
		reason = context and context.reason or "projectile",
		actionId = context and context.actionId,
	}, projectiles )
	if not result then return nil, commitError end
	return projectiles, result
end

local function commitOnly( record, snapshot, ply, context )
	return commitMutation( record, snapshot, ply, context, {} )
end

function SV.CanBeginProjectileUse( ply, record, stack, kind )
	if kind ~= "bow" and kind ~= "crossbow" and kind ~= "trident" then return true end
	if kind == "crossbow" and MC.ItemCrossbowCharged and MC.ItemCrossbowCharged( stack ) then return true end
	if kind == "trident" then
		local definition = MC.GetItem( stack.item )
		local maximum = tonumber( definition and definition.maxDamage ) or 0
		return maximum <= 0 or ( tonumber( stack.damage ) or 0 ) + 1 < maximum, "trident_broken"
	end
	local _, ammo = findAmmo( record, kind )
	if ammo or infiniteMaterials( ply ) then return true end
	return false, "projectile_ammo_missing"
end

function SV.FireBow( ply, record, stack, state, context )
	context = context or {}
	if not validPlayer( ply ) or not record or not stack then return false, "invalid_bow" end
	local ticks = math.max( 0, ( CurTime() - ( tonumber( state.startedAt ) or CurTime() ) ) * 20 )
	local power = MC.BowPowerForTicks and MC.BowPowerForTicks( ticks ) or math.min( 1, ticks / 20 )
	if power < 0.1 then return false, "bow_draw_too_short" end
	local ammoSlot, ammo = findAmmo( record, "bow" )
	local infinite = infiniteMaterials( ply )
	if not ammo and not infinite then return false, "projectile_ammo_missing" end
	ammo = ammo and MC.CopyItemStack( ammo, 1 ) or MC.NewItemStack( "minecraft:arrow", 1 )
	if not ammo then return false, "default_arrow_missing" end
	local definition = MC.GetProjectileDefinition( ammo.item ) or MC.GetProjectileDefinition( "minecraft:arrow" )
	local _, weaponStack = selected( record )
	local replacement, broken = damageStack( weaponStack, 1 )
	local direction = eyeDirection( ply )
	local speed = MC.ProjectileSpeed( definition, power * 1 )
	local velocity = direction * speed
	local projectileDamage = ( tonumber( definition.damage ) or 2 ) + 3 * power
	local ent, result = mutateAndLaunch( ply, record, ammo, ammo.item, 0, velocity, definition, {
		damage = projectileDamage, critical = power >= 1, pickup = not infinite,
		infinite = infinite,
		onFire = MC.GetEnchantmentLevel and MC.GetEnchantmentLevel( weaponStack, "minecraft:flame" ) > 0 or false,
		reason = context.reason or "bow", actionId = context.actionId,
	}, function()
		if not infinite and ( not ammoSlot or not consumeStackAt( record, ammoSlot, 1 ) ) then
			return false, "projectile_ammo_consume_failed"
		end
		local selectedIndex = record.selected
		local ok, err = MC.ContainerSetStack( record.container, selectedIndex, infinite and weaponStack or replacement )
		if not ok then return false, err or "bow_durability_failed" end
		return true
	end )
	if not ent then return false, result end
	if MC.RunEvent then MC.RunEvent( "MC.BowFired", ply, ent, power, broken == true ) end
	return true, ent
end

function SV.FinishCrossbowUse( ply, record, stack, state, context )
	context = context or {}
	if not validPlayer( ply ) or not record or not stack then return false, "invalid_crossbow" end
	local charged = chargedProjectiles( stack )
	local progress = tonumber( state.progress )
	if not charged then
		if not progress or progress < 0.999 then return false, "crossbow_not_charged" end
		local ammoSlot, ammo = findAmmo( record, "crossbow" )
		local infinite = infiniteMaterials( ply )
		if not ammo and not infinite then return false, "projectile_ammo_missing" end
		ammo = ammo and MC.CopyItemStack( ammo, 1 ) or MC.NewItemStack( "minecraft:arrow", 1 )
		if not ammo then return false, "default_arrow_missing" end
		local snapshot = MC.ContainerSnapshot( record.container )
		if not infinite and ( not ammoSlot or not consumeStackAt( record, ammoSlot, 1 ) ) then
			MC.ContainerRestore( record.container, snapshot )
			return false, "projectile_ammo_consume_failed"
		end
		local projectiles = buildChargedProjectiles( ammo, crossbowProjectileCount( stack ), infinite )
		local selectedIndex = record.selected
		local replacement = setChargedProjectiles( stack, projectiles )
		local ok, setError = MC.ContainerSetStack( record.container, selectedIndex, replacement )
		if not ok then
			MC.ContainerRestore( record.container, snapshot )
			return false, setError or "crossbow_charge_failed"
		end
		local result, commitError = commitOnly( record, snapshot, ply, {
			player = ply, reason = context.reason or "crossbow_charge", actionId = context.actionId,
		} )
		if not result then return false, commitError end
		if MC.RunEvent then
			MC.RunEvent( "MC.CrossbowCharged", ply, MC.CopyItemStack( ammo ), copyProjectileStacks( projectiles ) )
		end
		return true, "charged"
	end

	local infinite = infiniteMaterials( ply )
	local clearedStack = setChargedProjectiles( stack, nil )
	local durabilityAmount = chargedProjectilesDurabilityUse( charged )
	local replacement, broken = damageStack( clearedStack, durabilityAmount )
	local selectedIndex = record.selected
	local direction, eyeAngles = eyeDirection( ply )
	local shotAngles = crossbowShotAngles( #charged, crossbowProjectileSpread( stack ) )
	local specifications, eventPower = {}, nil
	for index, projectile in ipairs( charged ) do
		local definition = MC.GetProjectileDefinition( projectile.item )
		if not definition then return false, "crossbow_projectile_unsupported" end
		local power = projectile.item == "minecraft:firework_rocket" and 1.6 or 3.15
		eventPower = eventPower or power
		local shotDirection = rotatedAround( direction, eyeAngles:Up(), shotAngles[index] )
		local intangible = projectileIsIntangible( projectile )
		specifications[#specifications + 1] = {
			sourceStack = projectile,
			itemName = projectile.item,
			itemDamage = projectile.damage or 0,
			velocity = shotDirection * MC.ProjectileSpeed( definition, power / 3.15 ),
			definition = definition,
			options = {
				damage = definition.damage,
				pickup = not intangible and definition.pickup == true,
				infinite = intangible,
				-- AbstractArrow with any positive Piercing level bypasses shields entirely.
				-- Firework rockets are not AbstractArrow and therefore never inherit it.
				shieldBypass = definition.kind == "arrow" and MC.GetEnchantmentLevel
					and MC.GetEnchantmentLevel( stack, "minecraft:piercing" ) > 0 or false,
				reason = context.reason or "crossbow",
				actionId = context.actionId,
			},
		}
	end
	local entities, result = mutateAndLaunchMany( ply, record, specifications, {
		reason = context.reason or "crossbow",
		actionId = context.actionId,
	}, function()
		local nextStack = infinite and clearedStack or replacement
		local ok, err = MC.ContainerSetStack( record.container, selectedIndex, nextStack )
		return ok, err or "crossbow_durability_failed"
	end )
	if not entities then return false, result end
	if MC.RunEvent then
		MC.RunEvent( "MC.CrossbowFired", ply, entities[1], eventPower, broken == true, entities )
	end
	return true, entities[1]
end

function SV.ThrowTrident( ply, record, stack, state, context )
	context = context or {}
	if not validPlayer( ply ) or not record or not stack then return false, "invalid_trident" end
	local ticks = math.max( 0, ( CurTime() - ( tonumber( state.startedAt ) or CurTime() ) ) * 20 )
	if ticks < 10 then return false, "trident_draw_too_short" end
	local definition = MC.GetProjectileDefinition( "minecraft:trident" )
	local infinite = infiniteMaterials( ply )
	local currentDamage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) )
	local maximum = tonumber( MC.ItemMaxDamage( stack ) ) or 0
	if not infinite and maximum > 0 and currentDamage + 1 >= maximum then return false, "trident_would_break" end
	local thrownDamage = infinite and currentDamage or currentDamage + 1
	local thrownStack = MC.CopyItemStack( stack )
	if thrownStack then thrownStack.damage = thrownDamage > 0 and thrownDamage or nil end
	local direction = eyeDirection( ply )
	local velocity = direction * MC.ProjectileSpeed( definition, 2.5 / 2.5 )
	local ent, result = mutateAndLaunch( ply, record, thrownStack, "minecraft:trident", thrownDamage, velocity, definition, {
		damage = definition.damage, pickup = not infinite, infinite = infinite,
		reason = context.reason or "trident", actionId = context.actionId,
	}, function()
		if infinite then return true end
		return MC.ContainerSetStack( record.container, record.selected, nil )
	end )
	if not ent then return false, result end
	if MC.RunEvent then MC.RunEvent( "MC.TridentThrown", ply, ent ) end
	return true, ent
end

function SV.ThrowItemProjectile( ply, record, stack, context )
	context = context or {}
	if not validPlayer( ply ) or not record or not stack then return false, "invalid_projectile" end
	local definition = MC.GetProjectileDefinition( stack.item )
	if not definition then return false, "projectile_unsupported" end
	local infinite = infiniteMaterials( ply )
	local direction = eyeDirection( ply, definition.pitch )
	local velocity = direction * MC.ProjectileSpeed( definition, 1 )
	local ent, result = mutateAndLaunch( ply, record, stack, stack.item, stack.damage or 0, velocity, definition, {
		pickup = false, infinite = infinite, reason = context.reason or "projectile", actionId = context.actionId,
	}, function()
		if infinite then return true end
		return MC.ContainerSetStack( record.container, record.selected,
			stack.count > 1 and MC.CopyItemStack( stack, stack.count - 1 ) or nil )
	end )
	if not ent then return false, result end
	if MC.RunEvent then MC.RunEvent( "MC.ProjectileThrown", ply, ent, stack.item ) end
	return true, ent
end

-- Ammo helpers for EXTERNAL projectile SWEPs (exposed through
-- MC.API.Inventory.HasAmmo / ConsumeAmmo). MCSWEP's own bow/crossbow path above
-- consumes ammo inside its launch transaction; an external SWEP owns its own
-- projectile entity, so it needs the ammo half on its own. Same allowed-item
-- table, same creative "infinite materials" rule, same container commit.
function SV.FindProjectileAmmo( ply, kind )
	if not validPlayer( ply ) then return nil, nil, "invalid_player" end
	if not SV.GetPlayerInventoryRecord then return nil, nil, "inventory_api_unavailable" end
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record then return nil, nil, "inventory_not_loaded" end
	local slot, stack = findAmmo( record, kind == "crossbow" and "crossbow" or "bow" )
	if not stack then return nil, nil, "projectile_ammo_missing" end
	return slot, MC.CopyItemStack( stack )
end

function SV.SelectProjectileAmmo( ply, kind )
	if not validPlayer( ply ) then return nil, nil, false, false, "invalid_player" end
	if not SV.GetPlayerInventoryRecord then return nil, nil, false, false, "inventory_api_unavailable" end
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record then return nil, nil, false, false, "inventory_not_loaded" end
	kind = kind == "crossbow" and "crossbow" or "bow"
	local slot, stack = findAmmo( record, kind )
	local infinite = infiniteMaterials( ply )
	if stack then return MC.CopyItemStack( stack, 1 ), slot, infinite, false, nil end
	if not infinite then return nil, nil, false, false, "projectile_ammo_missing" end
	local fallback = MC.NewItemStack( "minecraft:arrow", 1 )
	if not fallback then return nil, nil, true, true, "default_arrow_missing" end
	return fallback, nil, true, true, nil
end

function SV.TakeProjectileAmmo( ply, kind, amount, context )
	amount = math.max( math.floor( tonumber( amount ) or 1 ), 1 )
	if not validPlayer( ply ) then return nil, 0, false, false, "invalid_player" end
	if not SV.GetPlayerInventoryRecord then return nil, 0, false, false, "inventory_api_unavailable" end
	local record = SV.GetPlayerInventoryRecord( ply, false )
	if not record then return nil, 0, false, false, "inventory_not_loaded" end
	kind = kind == "crossbow" and "crossbow" or "bow"
	local slot, stack = findAmmo( record, kind )
	local infinite = infiniteMaterials( ply )
	if not stack then
		if not infinite then return nil, 0, false, false, "projectile_ammo_missing" end
		local fallback = MC.NewItemStack( "minecraft:arrow", amount )
		if not fallback then return nil, 0, true, true, "default_arrow_missing" end
		return fallback, amount, true, true, nil
	end

	local take = math.min( amount, stack.count )
	local selectedStack = MC.CopyItemStack( stack, take )
	if infinite then return selectedStack, take, true, false, nil end

	local snapshot = MC.ContainerSnapshot( record.container )
	local ok, consumeError = consumeStackAt( record, slot, take )
	if not ok then
		MC.ContainerRestore( record.container, snapshot )
		return nil, 0, false, false, consumeError or "projectile_ammo_consume_failed"
	end
	local result, commitError = commitOnly( record, snapshot, ply, {
		player = ply,
		reason = ( istable( context ) and context.reason ) or "external_projectile_ammo",
		actionId = istable( context ) and context.actionId or nil,
	} )
	if not result then return nil, 0, false, false, commitError end
	return selectedStack, take, false, false, nil
end

-- External resolver-driven crossbows must not compose "take one arrow" and
-- "write charged_projectiles" as two commits. A disconnect, revision race or
-- failed second commit between those operations would either eat or duplicate
-- projectiles. Java's draw() consumes only the first ammunition item, copies it
-- for every Multishot side projectile, and marks every synthetic copy with
-- INTANGIBLE_PROJECTILE. This helper stores that complete list atomically.
function SV.LoadSelectedCrossbowProjectiles( ply, kind, projectileCount, context )
	context = context or {}
	if not validPlayer( ply ) then return nil, false, false, nil, "invalid_player" end
	local record, selectedIndex, weaponStack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, false, false, nil, matchError end
	if not MC.ItemBehavior or MC.ItemBehavior( weaponStack ) ~= "crossbow" then
		return nil, false, false, nil, "selected_item_not_crossbow"
	end
	if chargedProjectiles( weaponStack ) then
		return nil, false, false, nil, "crossbow_already_charged"
	end

	kind = kind == "crossbow" and "crossbow" or "bow"
	local ammoSlot, ammo = findAmmo( record, kind )
	local infinite = infiniteMaterials( ply )
	local generated = false
	if not ammo then
		if not infinite then return nil, false, false, nil, "projectile_ammo_missing" end
		ammo = MC.NewItemStack( "minecraft:arrow", 1 )
		generated = true
	end
	if not ammo then return nil, infinite, generated, nil, "default_arrow_missing" end
	ammo = MC.CopyItemStack( ammo, 1 )
	local projectiles = buildChargedProjectiles( ammo, projectileCount, infinite )

	local snapshot = MC.ContainerSnapshot( record.container )
	if not infinite then
		local consumed, consumeError = consumeStackAt( record, ammoSlot, 1 )
		if consumed ~= true then
			MC.ContainerRestore( record.container, snapshot )
			return nil, false, false, nil, consumeError or "projectile_ammo_consume_failed"
		end
	end
	local replacement = setChargedProjectiles( weaponStack, projectiles )
	local stored, storeError = MC.ContainerSetStack( record.container, selectedIndex, replacement )
	if stored ~= true then
		MC.ContainerRestore( record.container, snapshot )
		return nil, infinite, generated, nil, storeError or "crossbow_charge_failed"
	end
	local result, commitError = commitOnly( record, snapshot, ply, {
		player = ply,
		reason = context.reason or "external_crossbow_charge",
		actionId = context.actionId,
	} )
	if not result then return nil, infinite, generated, nil, commitError end
	if MC.RunEvent then
		MC.RunEvent( "MC.CrossbowCharged", ply, MC.CopyItemStack( ammo ), copyProjectileStacks( projectiles ) )
	end
	return copyProjectileStacks( projectiles ), infinite, generated, result, nil
end

-- Compatibility wrapper for pre-Multishot external callers.
function SV.LoadSelectedCrossbowProjectile( ply, kind, context )
	local projectiles, infinite, generated, result, err =
		SV.LoadSelectedCrossbowProjectiles( ply, kind, 1, context )
	return projectiles and projectiles[1] or nil, infinite, generated, result, err
end

-- Completes an external charged-crossbow shot as one selected-slot commit.
-- Callers create every entity first and delete all of them if this rejects the
-- expected list or the inventory commit fails. New plural callers omit an
-- override so durability is derived exactly per projectile: arrow=1, rocket=3.
local function commitSelectedCrossbowProjectiles( ply, durabilityAmount, context )
	context = context or {}
	if not validPlayer( ply ) then return nil, false, nil, false, "invalid_player" end
	local record, selectedIndex, weaponStack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, false, nil, false, matchError end
	if not MC.ItemBehavior or MC.ItemBehavior( weaponStack ) ~= "crossbow" then
		return nil, false, nil, false, "selected_item_not_crossbow"
	end
	local projectiles = chargedProjectiles( weaponStack )
	if not projectiles then return nil, false, nil, false, "crossbow_not_charged" end
	if context.expectedProjectileHash ~= nil then
		local hash = MC.ItemStackHash and MC.ItemStackHash( projectiles[1] ) or nil
		if hash ~= tostring( context.expectedProjectileHash ) then
			return nil, false, nil, false, "charged_projectile_changed"
		end
	end
	if not chargedProjectileHashesMatch( projectiles, context.expectedProjectileHashes ) then
		return nil, false, nil, false, "charged_projectiles_changed"
	end

	durabilityAmount = durabilityAmount == nil
		and chargedProjectilesDurabilityUse( projectiles )
		or math.Clamp( math.floor( tonumber( durabilityAmount ) or 1 ), 1, 255 )
	local infinite = infiniteMaterials( ply )
	local cleared = setChargedProjectiles( weaponStack, nil )
	local replacement, broken, newDamage = damageStack( cleared, infinite and 0 or durabilityAmount )
	if infinite then
		replacement = cleared
		broken = false
		newDamage = math.max( 0, math.floor( tonumber( weaponStack.damage ) or 0 ) )
	end

	local snapshot = MC.ContainerSnapshot( record.container )
	local changed, changeError = MC.ContainerSetStack( record.container, selectedIndex, replacement )
	if changed ~= true then
		MC.ContainerRestore( record.container, snapshot )
		return nil, false, nil, infinite, changeError or "crossbow_shot_mutation_failed"
	end
	local result, commitError = commitOnly( record, snapshot, ply, {
		player = ply,
		reason = context.reason or "external_crossbow_shot",
		actionId = context.actionId,
	} )
	if not result then return nil, false, nil, infinite, commitError end

	local definition = MC.GetItem and MC.GetItem( weaponStack.item ) or nil
	if not infinite and definition and ( tonumber( definition.maxDamage ) or 0 ) > 0
	and not ( MC.ItemIsUnbreakable and MC.ItemIsUnbreakable( weaponStack ) )
	and MC.RunEvent then
		MC.RunEvent(
			"MC.ItemDurabilityChanged",
			ply,
			selectedIndex,
			MC.CopyItemStack( weaponStack ),
			MC.CopyItemStack( replacement ),
			newDamage,
			broken == true
		)
	end
	return result, broken == true, copyProjectileStacks( projectiles ), infinite, nil
end

function SV.CommitSelectedCrossbowProjectilesShot( ply, context )
	return commitSelectedCrossbowProjectiles( ply, nil, context )
end

-- Compatibility wrapper for pre-Multishot external callers.
function SV.CommitSelectedCrossbowShot( ply, durabilityAmount, context )
	local result, broken, projectiles, infinite, err =
		commitSelectedCrossbowProjectiles( ply, durabilityAmount, context )
	return result, broken, projectiles and projectiles[1] or nil, infinite, err
end

-- Returns consumed, itemName, err, infinite.
function SV.ConsumeProjectileAmmo( ply, kind, amount, context )
	local stack, consumed, infinite, _, err = SV.TakeProjectileAmmo( ply, kind, amount, context )
	return consumed or 0, stack and stack.item or nil, err, infinite == true, stack
end

local function safeTeleport( ply, position )
	if not validPlayer( ply ) or not position then return false end
	local mins, maxs = ply:OBBMins(), ply:OBBMaxs()
	local blocked = util.TraceHull( {
		start = position, endpos = position, mins = mins, maxs = maxs,
		filter = ply, mask = MASK_PLAYERSOLID,
	} )
	if blocked.Hit then return false end
	ply:SetPos( position )
	if ply.SetVelocity then ply:SetVelocity( Vector( 0, 0, 0 ) ) end
	return true
end

function SV.HandleProjectileImpact( ent, trace )
	if not IsValid( ent ) then return false end
	local itemName = ent.GetProjectileItemName and ent:GetProjectileItemName() or ""
	local definition = MC.GetProjectileDefinition( itemName ) or {}
	local owner = ent:GetOwner()
	local hitEntity = trace and trace.Entity or nil
	if IsValid( hitEntity ) and hitEntity ~= owner and ( tonumber( ent.MCDamage ) or 0 ) > 0 then
		local damageInfo = DamageInfo and DamageInfo() or nil
		if damageInfo then
			damageInfo:SetDamage( tonumber( ent.MCDamage ) or 0 )
			damageInfo:SetDamageType( DMG_BULLET or 2 )
			damageInfo:SetAttacker( IsValid( owner ) and owner or ent )
			damageInfo:SetInflictor( ent )
			damageInfo:SetDamagePosition( trace.HitPos )
			-- ArmorStand's ALWAYS_KILLS_ARMOR_STANDS tag is keyed by the
			-- Minecraft projectile damage type, not Source DMG_BULLET. Carry the
			-- exact item-derived id through the existing combat context boundary.
			local damageTypeId = itemName
			if definition.kind == "arrow" then damageTypeId = "minecraft:arrow"
			elseif definition.kind == "trident" then damageTypeId = "minecraft:trident"
			elseif definition.kind == "wind_charge" then damageTypeId = "minecraft:wind_charge"
			elseif definition.kind == "firework" then damageTypeId = "minecraft:fireworks" end
			local metadata = {
				damageTypeId = damageTypeId,
				projectile = ent,
				definition = definition,
				attacker = owner,
			}
			if SV.PushCombatDamageContext then SV.PushCombatDamageContext( hitEntity, damageInfo, metadata ) end
			hitEntity:TakeDamageInfo( damageInfo )
			if SV.PopCombatDamageContext then SV.PopCombatDamageContext( hitEntity, damageInfo, metadata ) end
		end
		if ent.GetProjectileOnFire and ent:GetProjectileOnFire() then
			local ignitionContext = {
				source = "burning_projectile",
				projectile = ent,
				owner = owner,
				definition = definition,
				trace = trace,
			}
			local ignitionSeconds = 5
			ignitionContext.requestedIgnitionSeconds = ignitionSeconds
			local modified = MC.RunEvent and MC.RunEvent(
				"MC.ModifyEntityIgnitionDuration", hitEntity, ignitionSeconds, ignitionContext ) or nil
			ignitionContext.ignitionDurationModified = true
			if modified ~= nil then
				ignitionSeconds = math.max( 0, tonumber( modified ) or ignitionSeconds )
			end
			ignitionContext.modifiedIgnitionSeconds = ignitionSeconds
			local handled
			if ignitionSeconds <= 0 then
				handled = true
			elseif MC.RunEvent then
				handled = MC.RunEvent( "MC.IgniteEntity", hitEntity, ignitionSeconds, ignitionContext )
			end
			if handled == nil and hitEntity.Ignite then hitEntity:Ignite( ignitionSeconds, 0 ) end
		end
	end
	if definition.teleport and validPlayer( owner ) and trace and trace.HitPos then
		safeTeleport( owner, trace.HitPos + ( trace.HitNormal or Vector( 0, 0, 1 ) ) * 8 )
	end
	if definition.kind == "arrow" or definition.kind == "trident" then
		local source = ent.MCSourceStack or MC.NewItemStack( itemName, 1, nil, ent:GetProjectileDamage() )
		if source and ent.MCPickup and not ent.MCInfinite and SV.SpawnItemDrop then
			SV.SpawnItemDrop( trace and trace.HitPos or ent:GetPos(), source, owner, {
				pickupDelay = 0.2,
				target = definition.kind == "trident" and owner or nil,
			} )
		end
	end
	if MC.RunEvent then MC.RunEvent( "MC.ProjectileImpact", ent, trace, hitEntity, definition ) end
	ent:Remove()
	return true
end
