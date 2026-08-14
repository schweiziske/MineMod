-- Minecraft Java 26.2 game-layer integration for destructive explosions.
--
-- The engine owns ray selection, entity damage, voxel transactions and client
-- effects. This adapter owns survival concepts: enchantments, loot stacks,
-- dropped-item entities and TNT block chaining.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.Explosion = MC.Explosion or {}

local SV = MC.SV
local Explosion = MC.Explosion
local TICKS_PER_SECOND = 20
local MAX_DROPS_PER_COMBINED_STACK = 16
local ARMOR_EQUIPMENT_SLOTS = { "head", "chest", "legs", "feet" }

local function blockSize()
	return math.max( 1, tonumber( MC.BS ) or 36.5 )
end

local function reportGameplayError( stage, message )
	local output = "[MCGame] explosion " .. tostring( stage ) .. " failed: " .. tostring( message ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( output ) else print( output ) end
end

local function equipmentEnchantmentTotal( entity, enchantmentId )
	if not entity.IsPlayer or not entity:IsPlayer() or not SV.GetPlayerInventoryRecord
		or not MC.GetEnchantmentLevel then return 0 end
	local record = SV.GetPlayerInventoryRecord( entity, false )
	local equipment = record and record.equipment or nil
	if not equipment then return 0 end
	local total = 0
	for _, slot in ipairs( ARMOR_EQUIPMENT_SLOTS ) do
		total = total + math.max( 0,
			math.floor( tonumber( MC.GetEnchantmentLevel( equipment[slot], enchantmentId ) ) or 0 ) )
	end
	return total
end

-- EnchantmentHelper#getDamageProtection adds one point per Protection level
-- and two per Blast Protection level for explosion damage. CombatRules clamps
-- the total to 20 and applies it after ordinary armor absorption.
local function explosionEnchantmentProtection( entity )
	local protection = equipmentEnchantmentTotal( entity, "minecraft:protection" )
		+ equipmentEnchantmentTotal( entity, "minecraft:blast_protection" ) * 2
	return math.Clamp( tonumber( protection ) or 0, 0, 20 )
end

local function equipmentExplosionKnockbackResistance( entity )
	-- Blast Protection contributes the dedicated Java 26.2
	-- EXPLOSION_KNOCKBACK_RESISTANCE attribute. Netherite's ordinary armor
	-- knockback resistance deliberately does not apply here.
	return math.Clamp(
		equipmentEnchantmentTotal( entity, "minecraft:blast_protection" ) * 0.15,
		0, 1
	)
end

Explosion.GetEnchantmentProtection = explosionEnchantmentProtection
Explosion.GetEquipmentKnockbackResistance = equipmentExplosionKnockbackResistance

if hook and hook.Add then
	hook.Add( "MCITEM.DamageAfterEquipmentMitigation", "mc_explosion_enchantment_protection", function( entity, damageInfo )
		if not damageInfo or not damageInfo.IsDamageType or DMG_BLAST == nil
			or damageInfo:IsDamageType( DMG_BLAST ) ~= true then return end
		local protection = explosionEnchantmentProtection( entity )
		if protection <= 0 or not damageInfo.GetDamage or not damageInfo.SetDamage then return end
		damageInfo:SetDamage( math.max( 0, damageInfo:GetDamage() ) * ( 1 - protection / 25 ) )
	end )
end

if Explosion.RegisterKnockbackResistanceProvider then
	local registered, registerError = Explosion.RegisterKnockbackResistanceProvider(
		"mcgame_blast_protection",
		equipmentExplosionKnockbackResistance
	)
	if registered ~= true then reportGameplayError( "knockback registration", registerError ) end
else
	reportGameplayError( "knockback registration", "provider_registry_unavailable" )
end

local function addExplosionDrop( collectors, stack, bx, by, bz )
	if not stack or ( MC.IsEmptyItemStack and MC.IsEmptyItemStack( stack ) ) then return end
	local remaining = MC.CopyItemStack and MC.CopyItemStack( stack ) or stack
	for _, collector in ipairs( collectors ) do
		if not remaining then return end
		local merged, rest, moved
		if SV.MergeItemStacks then
			merged, rest, moved = SV.MergeItemStacks( collector.stack, remaining, MAX_DROPS_PER_COMBINED_STACK )
		elseif MC.ItemStacksCanMerge and MC.ItemStacksCanMerge( collector.stack, remaining ) then
			local room = math.max( 0,
				MAX_DROPS_PER_COMBINED_STACK - ( tonumber( collector.stack.count ) or 0 ) )
			moved = math.min( room, tonumber( remaining.count ) or 0 )
			if moved > 0 then
				merged = MC.CopyItemStack( collector.stack, collector.stack.count + moved )
				rest = remaining.count > moved
					and MC.CopyItemStack( remaining, remaining.count - moved ) or nil
			end
		end
		if ( tonumber( moved ) or 0 ) > 0 then collector.stack, remaining = merged, rest end
	end
	while remaining and ( tonumber( remaining.count ) or 0 ) > 0 do
		local count = math.min( MAX_DROPS_PER_COMBINED_STACK,
			math.floor( tonumber( remaining.count ) or 0 ) )
		collectors[#collectors + 1] = {
			stack = MC.CopyItemStack and MC.CopyItemStack( remaining, count ) or remaining,
			bx = bx, by = by, bz = bz,
		}
		remaining = remaining.count > count
			and MC.CopyItemStack( remaining, remaining.count - count ) or nil
	end
end

local function shouldDropFromExplosion( snapshot, options )
	if snapshot.name == "minecraft:tnt" or options.dropResources == false then return false end
	local handlers = snapshot.block and snapshot.block.handlers or nil
	if handlers and isfunction( handlers.DropFromExplosion ) then
		local ok, result = pcall( handlers.DropFromExplosion, snapshot, options )
		if not ok then reportGameplayError( "drop policy", result )
		elseif result ~= nil then return result == true end
	end
	return true
end

local function collectBlockDrops( collectors, snapshot, radius, options )
	if not shouldDropFromExplosion( snapshot, options ) or not SV.ResolveBlockDrops then return end
	local context = {
		bx = snapshot.bx, by = snapshot.by, bz = snapshot.bz,
		explosion = true,
		explosionRadius = options.dropDecay ~= false and radius or nil,
		blockEntity = snapshot.blockEntity,
		thisEntity = options.source,
	}
	local ok, drops = pcall( SV.ResolveBlockDrops, snapshot.stateId, nil, context )
	if not ok then reportGameplayError( "loot resolve", drops ) return end
	for _, stack in ipairs( type( drops ) == "table" and drops or {} ) do
		addExplosionDrop( collectors, stack, snapshot.bx, snapshot.by, snapshot.bz )
	end
end

local function explosionDropPosition( collector )
	local size = blockSize()
	return Vector(
		( collector.bx + 0.5 + math.Rand( -0.25, 0.25 ) ) * size,
		( collector.by + 0.5 + math.Rand( -0.25, 0.25 ) ) * size,
		( collector.bz + 0.5 + math.Rand( -0.25, 0.25 ) - 0.125 ) * size
	)
end

local function explosionDropVelocity()
	local scale = blockSize() * TICKS_PER_SECOND
	return Vector( math.Rand( -0.1, 0.1 ), math.Rand( -0.1, 0.1 ), 0.2 ) * scale
end

local function spawnCollectedDrops( collectors )
	if not SV.SpawnItemDrop then return 0 end
	local spawned = 0
	for _, collector in ipairs( collectors ) do
		local ok, entity = pcall( SV.SpawnItemDrop, explosionDropPosition( collector ), collector.stack, nil, {
			pickupDelay = 0.5,
			velocity = explosionDropVelocity(),
			noMerge = true,
			positionJitter = false,
			reason = "block_explosion",
		} )
		if not ok then reportGameplayError( "drop spawn", entity )
		elseif IsValid( entity ) then spawned = spawned + 1 end
	end
	return spawned
end

local function spawnChainedTnt( snapshots, actor )
	if not SV.SpawnPrimedTnt then return 0 end
	local chained = 0
	for _, snapshot in ipairs( snapshots ) do
		local fuse = math.random( 0, math.max( 1, math.floor( 80 / 4 ) ) - 1 ) + math.floor( 80 / 8 )
		local ok, entity = pcall( SV.SpawnPrimedTnt, snapshot.bx, snapshot.by, snapshot.bz, actor, {
			fuse = fuse,
			power = 4,
			silent = true,
			reason = "explosion_chain",
		} )
		if not ok then reportGameplayError( "TNT chain", entity )
		elseif IsValid( entity ) then chained = chained + 1 end
	end
	return chained
end

local function prepareBlockInteraction( snapshots, radius, options )
	if #snapshots == 0 then return nil end
	local collectors, chainedTnt = {}, {}
	for _, snapshot in ipairs( snapshots ) do
		if snapshot.name == "minecraft:tnt" then chainedTnt[#chainedTnt + 1] = snapshot end
		local ok, collectError = xpcall( function()
			collectBlockDrops( collectors, snapshot, radius, options )
		end, debug.traceback )
		if not ok then reportGameplayError( "loot collect", collectError ) end
	end
	return { collectors = collectors, chainedTnt = chainedTnt }
end

local function commitBlockInteraction( plan, _, _, _, options )
	local chained = spawnChainedTnt( plan.chainedTnt, options.actor )
	local spawned = spawnCollectedDrops( plan.collectors )
	return {
		dropCollectors = plan.collectors,
		spawnedDrops = spawned,
		chainedTnt = chained,
	}
end

if not Explosion.RegisterBlockInteractionHandler then
	reportGameplayError( "block registration", "block_interaction_registry_unavailable" )
	return
end

local registered, registerError = Explosion.RegisterBlockInteractionHandler( "mcgame_survival_blocks", {
	Prepare = prepareBlockInteraction,
	Commit = commitBlockInteraction,
} )
if registered ~= true then reportGameplayError( "block registration", registerError ) end
