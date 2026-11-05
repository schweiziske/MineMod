-- Server-authoritative Minecraft melee, shield and armor combat.
-- Damage/cooldown formulas mirror Player, CombatRules and BlocksAttacks from
-- out/net/minecraft while Source remains responsible for applying final HP.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local INFRASTRUCTURE = {
	mc_block_cluster = true,
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
	mc_item_drop = true,
	mc_projectile = true,
}

SV.CombatDamageContexts = SV.CombatDamageContexts or setmetatable( {}, { __mode = "k" } )
SV.CombatDamageContextStacks = SV.CombatDamageContextStacks or setmetatable( {}, { __mode = "k" } )

-- sv_fire loads before this module in production, while focused runtime tests
-- can load combat alone. Define the same small context API here as well so the
-- wrapper-safe contract is available in both load paths and on auto-refresh.
function SV.PushCombatDamageContext( target, damageInfo, metadata )
	local stack = SV.CombatDamageContextStacks[target]
	if not stack then
		stack = {}
		SV.CombatDamageContextStacks[target] = stack
	end
	stack[#stack + 1] = {
		damageInfo = damageInfo,
		metadata = metadata,
		previous = damageInfo and SV.CombatDamageContexts[damageInfo] or nil,
	}
	if damageInfo then SV.CombatDamageContexts[damageInfo] = metadata end
	return metadata
end

function SV.PopCombatDamageContext( target, damageInfo, metadata )
	local stack = SV.CombatDamageContextStacks[target]
	if not stack then
		if damageInfo and SV.CombatDamageContexts[damageInfo] == metadata then
			SV.CombatDamageContexts[damageInfo] = nil
		end
		return
	end
	local index
	for candidate = #stack, 1, -1 do
		local entry = stack[candidate]
		if entry.damageInfo == damageInfo and entry.metadata == metadata then
			index = candidate
			break
		end
	end
	local entry = index and table.remove( stack, index ) or nil
	if #stack == 0 then SV.CombatDamageContextStacks[target] = nil end
	if damageInfo and SV.CombatDamageContexts[damageInfo] == metadata then
		SV.CombatDamageContexts[damageInfo] = entry and entry.previous or nil
	end
end

function SV.GetCombatDamageContext( target, damageInfo )
	local direct = damageInfo and SV.CombatDamageContexts[damageInfo] or nil
	if direct ~= nil then return direct end
	local stack = SV.CombatDamageContextStacks[target]
	local entry = stack and stack[#stack] or nil
	return entry and entry.metadata or nil
end

local function validPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer() and ply.Alive and ply:Alive()
end

local function activeMinecraftHand( ply, context )
	if context and context.allowAnyWeapon == true then return true end
	local weapon = IsValid( ply ) and ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	return IsValid( weapon ) and weapon.GetClass and weapon:GetClass() == "mc_item_hand"
end

local function inventoryControlledMainhand( ply )
	local weapon = IsValid( ply ) and ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	if not IsValid( weapon ) then return false end
	local bridge = MC.HandWeaponBridge
	local className = weapon.GetClass and weapon:GetClass() or ""
	if className == "mc_item_hand" then return true end
	if bridge and ( className == bridge.HandClass or className == bridge.InventoryClass ) then return true end
	if weapon.MCHandWeaponBridgeProxy == true then return true end
	return weapon.GetNW2Bool and weapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true
end

local function explicitDeathProtectionBypass( target, damageInfo, metadata )
	if metadata and metadata.bypassesDeathProtection ~= nil then
		return metadata.bypassesDeathProtection == true
	end
	-- Source damage flags have no exact equivalent of Java's
	-- #minecraft:bypasses_invulnerability tag. Let callers mark only their own
	-- precise sources; defaulting ordinary fall/fire/void-looking damage to a
	-- bypass would incorrectly disable the totem.
	if MC.RunEvent then return MC.RunEvent( "MC.DeathProtectionBypass", target, damageInfo, metadata ) == true end
	return hook.Run( "MC.DeathProtectionBypass", target, damageInfo, metadata ) == true
end

local function heldDeathProtectionCandidate( target, record )
	local expected = "minecraft:totem_of_undying"
	local weapon = IsValid( target ) and target.GetActiveWeapon and target:GetActiveWeapon() or nil
	if IsValid( weapon ) and weapon.MCDeathProtectionItem == expected
	and isfunction( weapon.IsMCDeathProtectionAvailable )
	and isfunction( weapon.ConsumeMCDeathProtection )
	and weapon:IsMCDeathProtectionAvailable( target ) == true then
		return "mainhand", { item = expected, count = 1 }, weapon
	end
	if record and inventoryControlledMainhand( target ) then
		local selected = record.storage and record.storage[( math.Clamp(
			math.floor( tonumber( record.selected ) or 0 ), 0, 8
		) ) + 1] or nil
		if selected and selected.item == expected and ( tonumber( selected.count ) or 0 ) > 0 then
			return "mainhand", selected
		end
	end
	local offhand = record and record.equipment and record.equipment.offhand or nil
	if offhand and offhand.item == expected and ( tonumber( offhand.count ) or 0 ) > 0 then
		return "offhand", offhand
	end
	return nil
end

local function tryDeathProtection( target, record, damageInfo, metadata, damage )
	if damage <= 0 or damage < math.max( 0, tonumber( target:Health() ) or 0 ) then return false end
	if explicitDeathProtectionBypass( target, damageInfo, metadata ) then return false end
	local hand, stack, externalWeapon = heldDeathProtectionCandidate( target, record )
	if not hand or not stack then return false end
	local consumedStack
	if IsValid( externalWeapon ) then
		local consumed, stackOrError = externalWeapon:ConsumeMCDeathProtection( target )
		if consumed ~= true then return false end
		consumedStack = istable( stackOrError ) and stackOrError or stack
	else
		if not SV.ConsumeHeldItem then return false end
		local result, consumed
		result, consumed, consumedStack = SV.ConsumeHeldItem( target, 1, {
			hand = hand,
			expectedItem = stack.item,
			expectedHash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil,
			reason = "death_protection",
		} )
		if not result or consumed ~= 1 then return false end
	end
	damageInfo:SetDamage( 0 )
	-- Java sets health to one at the committed death-protection boundary. MCITEM
	-- then clears/reapplies effects and publishes the client event.
	target:SetHealth( 1 )
	if metadata then
		metadata.deathProtection = true
		metadata.deathProtectionHand = hand
		metadata.deathProtectionStack = MC.CopyItemStack( consumedStack or stack, 1 )
	end
	if MC.RunEvent then
		MC.RunEvent( "MC.DeathProtectionTriggered", target, hand, MC.CopyItemStack( consumedStack or stack, 1 ), damageInfo, metadata )
	end
	return true
end

local function entityCenter( ent )
	if not IsValid( ent ) then return nil end
	if ent.WorldSpaceCenter then return ent:WorldSpaceCenter() end
	if ent.GetPos then return ent:GetPos() end
	return nil
end

local function horizontalNormalized( vector )
	if not vector then return nil end
	local flat = Vector( vector.x or 0, vector.y or 0, 0 )
	if not flat.LengthSqr or flat:LengthSqr() <= 0.000001 then return nil end
	return flat:GetNormalized()
end

local function hasDamageType( damageInfo, flag )
	return flag ~= nil and damageInfo and damageInfo.IsDamageType and damageInfo:IsDamageType( flag ) == true
end

local function bypassesShield( target, damageInfo, metadata )
	if hasDamageType( damageInfo, DMG_FALL )
		or hasDamageType( damageInfo, DMG_DROWN )
		or hasDamageType( damageInfo, DMG_POISON )
		or hasDamageType( damageInfo, DMG_RADIATION )
		or hasDamageType( damageInfo, DMG_BURN )
		or hasDamageType( damageInfo, DMG_SLOWBURN ) then return true end
	if metadata and metadata.bypassesShield ~= nil then return metadata.bypassesShield == true end
	local inflictor = damageInfo and damageInfo.GetInflictor and damageInfo:GetInflictor() or nil
	if IsValid( inflictor ) then
		if inflictor.MCShieldBypass == true then return true end
		if isfunction( inflictor.BypassesMCShield )
		and inflictor:BypassesMCShield( target, damageInfo, metadata ) == true then
			return true
		end
	end
	-- Source damage flags cannot encode Java's BYPASSES_SHIELD tag precisely.
	-- External systems must opt in only for their exact custom source.
	if MC.RunEvent then return MC.RunEvent( "MC.ShieldBypass", target, damageInfo, metadata ) == true end
	return hook.Run( "MC.ShieldBypass", target, damageInfo, metadata ) == true
end

local function bypassesArmor( damageInfo )
	return hasDamageType( damageInfo, DMG_FALL )
		or hasDamageType( damageInfo, DMG_DROWN )
		or hasDamageType( damageInfo, DMG_POISON )
		or hasDamageType( damageInfo, DMG_RADIATION )
end

local function projectileDamage( damageInfo )
	if hasDamageType( damageInfo, DMG_BULLET ) or hasDamageType( damageInfo, DMG_BUCKSHOT ) then return true end
	local inflictor = damageInfo and damageInfo.GetInflictor and damageInfo:GetInflictor() or nil
	if not IsValid( inflictor ) then return false end
	if inflictor.MCProjectile == true or inflictor.MCShieldProjectile == true then return true end
	local className = inflictor.GetClass and inflictor:GetClass() or ""
	return className == "mc_projectile" or className == "mcitem_arrow" or className == "mcitem_trident"
end

local function damageSourcePosition( victim, damageInfo )
	local attacker = damageInfo and damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
	local inflictor = damageInfo and damageInfo.GetInflictor and damageInfo:GetInflictor() or nil
	local inflictorClass = IsValid( inflictor ) and inflictor.GetClass and inflictor:GetClass() or ""
	if IsValid( inflictor ) and inflictor ~= victim
	and ( inflictorClass == "mc_projectile" or inflictorClass == "mcitem_arrow"
		or inflictorClass == "mcitem_trident" or inflictor.MCProjectile == true
		or inflictor.MCShieldProjectile == true or hasDamageType( damageInfo, DMG_BLAST ) ) then
		return entityCenter( inflictor )
	end
	if IsValid( attacker ) and attacker ~= victim and not ( attacker.IsWorld and attacker:IsWorld() ) then
		return entityCenter( attacker )
	end
	if IsValid( inflictor ) and inflictor ~= victim and not ( inflictor.IsWorld and inflictor:IsWorld() ) then
		return entityCenter( inflictor )
	end
	return nil
end

local function selectedAttackSpec( ply )
	local stack = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
	return stack, MC.ItemAttackSpec and MC.ItemAttackSpec( stack ) or {
		type = "hand", attackDamage = 1, attackSpeed = 4, damagePerAttack = 0, disableBlockingSeconds = 0,
	}
end

-- Hits and misses consume the same attack charge. Mining does not.
function SV.ResetSelectedAttackCooldown( ply, record, spec )
	if not validPlayer( ply ) then return nil end
	record = record or SV.GetPlayerInventoryRecord( ply, false )
	if not record then return nil end
	if not spec then
		local stack
		stack, spec = selectedAttackSpec( ply )
	end
	local now = CurTime()
	local elapsed = record.lastAttackAt and math.max( 0, now - record.lastAttackAt ) or nil
	local strength = MC.ItemAttackStrengthScale( elapsed, spec.attackSpeed )
	record.lastAttackAt = now
	if ply.SetNWFloat then
		ply:SetNWFloat( "mc_attack_strength", strength )
		ply:SetNWFloat( "mc_attack_ready_at", now + 1 / math.max( 0.1, tonumber( spec.attackSpeed ) or 4 ) )
	end
	return strength
end

local function shieldStackForState( record, state )
	if not record or not state or state.kind ~= "shield" then return nil end
	if state.hand == "offhand" then return record.equipment and record.equipment.offhand or nil end
	if state.selected ~= nil and state.selected ~= record.selected then return nil end
	return record.storage and record.storage[( math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 ) ) + 1] or nil
end

local function externalShieldForPlayer( ply )
	local weapon = IsValid( ply ) and ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	if not IsValid( weapon ) or not isfunction( weapon.GetMCShieldCombatState ) then return nil end
	local ok, provided = pcall( weapon.GetMCShieldCombatState, weapon )
	if not ok or not istable( provided ) then return nil end
	local stack = { item = tostring( provided.item or "minecraft:shield" ), count = 1 }
	local spec = MC.ItemShieldSpec and MC.ItemShieldSpec( stack ) or nil
	if not spec then return nil end
	return stack, {
		kind = "shield",
		hand = "external",
		startedAt = tonumber( provided.startedAt ) or CurTime(),
		external = true,
		weapon = weapon,
		infiniteDurability = provided.infiniteDurability ~= false,
	}, spec
end

function SV.IsPlayerShieldDisabled( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	local disabledUntil = record and tonumber( record.shieldDisabledUntil ) or 0
	if IsValid( ply ) and ply.GetNWFloat then
		disabledUntil = math.max( disabledUntil or 0, tonumber( ply:GetNWFloat( "mc_shield_disabled_until", 0 ) ) or 0 )
	end
	return ( disabledUntil or 0 ) > CurTime()
end

local function shieldSoundPitch()
	local randomValue = math.Rand and math.Rand( 0, 1 ) or math.random()
	return 0.8 + randomValue * 0.4
end

function SV.DisablePlayerShield( ply, seconds, reason )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not validPlayer( ply ) then return false, "invalid_player" end
	seconds = math.max( 0, tonumber( seconds ) or 0 )
	if seconds <= 0 then return false, "invalid_shield_cooldown" end
	local previousUntil = record and tonumber( record.shieldDisabledUntil ) or 0
	if ply.GetNWFloat then previousUntil = math.max( previousUntil or 0, ply:GetNWFloat( "mc_shield_disabled_until", 0 ) ) end
	local disabledUntil = math.max( previousUntil or 0, CurTime() + seconds )
	if record then record.shieldDisabledUntil = disabledUntil end
	if ply.SetNWFloat then ply:SetNWFloat( "mc_shield_disabled_until", disabledUntil ) end
	if record and record.itemUse and record.itemUse.kind == "shield" and SV.CancelSelectedItemUse then
		SV.CancelSelectedItemUse( ply, reason or "shield_disabled" )
	end
	local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	local inventoryProxy = IsValid( weapon ) and weapon.GetNW2Bool
		and weapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true
	if IsValid( weapon ) and not inventoryProxy and isfunction( weapon.CancelMCShieldUse ) then
		weapon:CancelMCShieldUse( reason or "shield_disabled" )
	end
	if disabledUntil > previousUntil and MC.PlayJavaSoundEvent then
		MC.PlayJavaSoundEvent( "item.shield.break", entityCenter( ply ) or ply:GetPos(), 0.8,
			shieldSoundPitch(), 72 )
	end
	if MC.RunEvent then MC.RunEvent( "MC.ShieldDisabled", ply, seconds, reason or "shield_disabled" ) end
	return true, disabledUntil
end

local function activeShield( ply, record, damageInfo, metadata )
	if bypassesShield( ply, damageInfo, metadata ) or SV.IsPlayerShieldDisabled( ply ) then return nil end
	if record then
		local state = record.itemUse
		local stack = shieldStackForState( record, state )
		local spec = stack and MC.ItemShieldSpec and MC.ItemShieldSpec( stack ) or nil
		if state and stack and spec
		and ( not state.stackHash or not MC.ItemStackHash or state.stackHash == MC.ItemStackHash( stack ) ) then
			if CurTime() - ( tonumber( state.startedAt ) or CurTime() ) >= ( tonumber( spec.blockDelay ) or 0 ) then
				return stack, state, spec
			end
			return nil
		end
	end
	local stack, state, spec = externalShieldForPlayer( ply )
	if not stack then return nil end
	if CurTime() - ( tonumber( state.startedAt ) or CurTime() ) < ( tonumber( spec.blockDelay ) or 0 ) then return nil end
	return stack, state, spec
end

local function shieldFacesSource( ply, sourcePosition, spec )
	local center = entityCenter( ply )
	local eyeAngles = ply.EyeAngles and ply:EyeAngles() or nil
	local forward = eyeAngles and eyeAngles.Forward and horizontalNormalized( eyeAngles:Forward() ) or nil
	local toward = center and sourcePosition and horizontalNormalized( sourcePosition - center ) or nil
	if not forward or not toward or not forward.Dot then return false end
	local maximum = math.rad( math.max( 0, tonumber( spec.horizontalAngle ) or 90 ) )
	return forward:Dot( toward ) >= math.cos( maximum ) - 0.000001
end

local function damageShield( ply, record, stack, state, blockedDamage )
	local amount = MC.ItemShieldDurabilityDamage and MC.ItemShieldDurabilityDamage( stack, blockedDamage ) or 0
	if amount <= 0 then return true, false, nil, 0 end
	if state.external == true and state.infiniteDurability == true then return true, false, nil, 0 end
	local result, broken, damageError
	if state.hand == "offhand" and SV.DamageEquipmentItem then
		result, broken, damageError = SV.DamageEquipmentItem(
			ply, "offhand", amount, { player = ply, reason = "shield_block" } )
	elseif SV.DamageSelectedItem then
		result, broken, damageError = SV.DamageSelectedItem( ply, amount, {
			player = ply,
			reason = "shield_block",
			expectedItem = stack.item,
			expectedStackHash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil,
		} )
	else
		return false, false, "durability_unavailable", amount
	end
	-- Creative/infinite materials intentionally reports no mutation. Any other
	-- persistence failure must reject the free block instead of letting a stale
	-- shield absorb damage without paying its required durability.
	if result or damageError == "infinite_materials" then return true, broken == true, nil, amount end
	return false, false, damageError or "shield_durability_failed", amount
end

local function playShieldBlockSound( target )
	if MC.PlayJavaSoundEvent then
		MC.PlayJavaSoundEvent( "item.shield.block", entityCenter( target ) or target:GetPos(), 1,
			shieldSoundPitch(), 72 )
	end
end

local function playShieldBreakSound( target )
	if MC.PlayJavaSoundEvent then
		MC.PlayJavaSoundEvent( "item.shield.break", entityCenter( target ) or target:GetPos(), 0.8,
			shieldSoundPitch(), 72 )
	end
end

-- LivingEntity.blockedByItem knocks a non-projectile living attacker back with
-- strength 0.5. Convert Minecraft delta movement (blocks/tick) to Source
-- units/second while retaining Java's horizontal-halving and on-ground lift.
local function knockBackShieldAttacker( defender, attacker )
	if not IsValid( attacker ) or attacker == defender or not attacker.GetVelocity or not attacker.SetVelocity then return end
	local defenderCenter, attackerCenter = entityCenter( defender ), entityCenter( attacker )
	local away = defenderCenter and attackerCenter and horizontalNormalized( attackerCenter - defenderCenter ) or nil
	if not away then return end
	local scale = ( tonumber( MC.BS or MC.Config and MC.Config.BlockSize ) or 36.5 ) * 20
	local current = attacker:GetVelocity()
	local nextVelocity = Vector(
		current.x * 0.5 + away.x * 0.5 * scale,
		current.y * 0.5 + away.y * 0.5 * scale,
		current.z
	)
	if attacker.OnGround and attacker:OnGround() then
		nextVelocity.z = math.min( 0.4 * scale, current.z * 0.5 + 0.5 * scale )
	end
	-- Entity:SetVelocity adds to the current velocity for players/NPCs.
	attacker:SetVelocity( nextVelocity - current )
end

local function attackerDisablesShield( attacker, damageInfo )
	if projectileDamage( damageInfo ) or not validPlayer( attacker ) then return 0 end
	local activeWeapon = attacker.GetActiveWeapon and attacker:GetActiveWeapon() or nil
	if IsValid( activeWeapon ) then
		local direct = tonumber( activeWeapon.MCDisableBlockingSeconds ) or 0
		if isfunction( activeWeapon.GetMCDisableBlockingSeconds ) then
			direct = tonumber( activeWeapon:GetMCDisableBlockingSeconds() ) or direct
		end
		if direct > 0 then return direct end
	end
	local inventoryProxy = IsValid( activeWeapon ) and activeWeapon.GetNW2Bool
		and activeWeapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true
	if not activeMinecraftHand( attacker ) and not inventoryProxy then return 0 end
	local _, spec = selectedAttackSpec( attacker )
	return math.max( 0, tonumber( spec and spec.disableBlockingSeconds ) or 0 )
end

function SV.IsCombatTarget( target, attacker )
	target = MC.ResolveMinecraftVehicle and MC.ResolveMinecraftVehicle( target ) or target
	if not IsValid( target ) or target == attacker or target.IsWorld and target:IsWorld() then return false end
	local class = target.GetClass and target:GetClass() or ""
	if class == "mc_boat" or class == "mc_minecart" then return true end
	if INFRASTRUCTURE[class] then return false end
	if target.IsPlayer and target:IsPlayer() then return true end
	if target.IsNPC and target:IsNPC() then return true end
	if target.IsNextBot and target:IsNextBot() then return true end
	return target.Health and tonumber( target:Health() ) and target:Health() > 0 or false
end

function SV.TraceSelectedItemAttack( ply )
	if not validPlayer( ply ) then return nil, nil, "invalid_attacker" end
	local start = ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
	local direction = ply.GetAimVector and ply:GetAimVector()
		or ply.EyeAngles and ply:EyeAngles():Forward() or nil
	if not start or not direction then return nil, nil, "attack_trace_unavailable" end
	local blockSize = tonumber( MC.BS or MC.Config and MC.Config.BlockSize ) or 36.5
	local reach = math.max( 1, blockSize * 3 )
	local traceData = { start = start, endpos = start + direction * reach, filter = ply }
	if MASK_SHOT ~= nil then traceData.mask = MASK_SHOT end
	local trace = util and util.TraceLine and util.TraceLine( traceData ) or ply.GetEyeTrace and ply:GetEyeTrace() or nil
	local tracedEntity = trace and trace.Entity or nil
	local target = MC.ResolveMinecraftVehicle and MC.ResolveMinecraftVehicle( tracedEntity ) or tracedEntity
	if not SV.IsCombatTarget( target, ply ) then return nil, trace, "no_attack_target" end
	local hitPosition = trace.HitPos or entityCenter( target )
	if hitPosition and ( hitPosition - start ):LengthSqr() > reach * reach + 1 then
		return nil, trace, "attack_target_too_far"
	end
	return target, trace
end

function SV.AttackSelectedItem( ply, requestedTarget, context )
	context = context or {}
	if not validPlayer( ply ) or not activeMinecraftHand( ply, context ) then return false, "invalid_attack" end
	local target, trace, traceError = SV.TraceSelectedItemAttack( ply )
	if not target then return false, traceError or "no_attack_target" end
	local requested = MC.ResolveMinecraftVehicle and MC.ResolveMinecraftVehicle( requestedTarget ) or requestedTarget
	if requested ~= nil and requested ~= target then return false, "attack_target_mismatch" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record then return false, "inventory_not_loaded" end
	local stack, spec = selectedAttackSpec( ply )
	local strength = SV.ResetSelectedAttackCooldown( ply, record, spec )
	local damage = MC.ItemAttackDamageAtStrength and MC.ItemAttackDamageAtStrength( spec.attackDamage, strength )
		or math.max( 0, tonumber( spec.attackDamage ) or 1 )
	if not DamageInfo then return false, "damage_info_unavailable" end
	local damageInfo = DamageInfo()
	if not damageInfo then return false, "damage_info_unavailable" end
	-- Empty-hand damage uses the 20 MC HP -> 100 Source HP conversion.
	-- Keep the existing impulse strength independent of this health-unit mapping.
	local forceDamage = damage
	if MC.IsEmptyItemStack( stack ) then damage = damage * 5 end
	damageInfo:SetDamage( damage )
	if damageInfo.SetDamageType then damageInfo:SetDamageType( DMG_CLUB or 128 ) end
	if damageInfo.SetAttacker then damageInfo:SetAttacker( ply ) end
	local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or ply
	if damageInfo.SetInflictor then damageInfo:SetInflictor( IsValid( weapon ) and weapon or ply ) end
	local hitPosition = trace and trace.HitPos or entityCenter( target )
	if hitPosition and damageInfo.SetDamagePosition then damageInfo:SetDamagePosition( hitPosition ) end
	if damageInfo.SetReportedPosition and ply.GetShootPos then damageInfo:SetReportedPosition( ply:GetShootPos() ) end
	if damageInfo.SetDamageForce and ply.GetAimVector then damageInfo:SetDamageForce( ply:GetAimVector() * forceDamage * 100 ) end
	local metadata = {
		attacker = ply,
		-- Player.attack(Entity) creates DamageSource.playerAttack(player),
		-- which is the exact #minecraft:is_player_attack branch used by
		-- ArmorStand#hurtServer. Source DMG_CLUB is not a substitute.
		damageTypeId = "minecraft:player_attack",
		stack = MC.CopyItemStack( stack ),
		spec = spec,
		strength = strength,
		originalDamage = damage,
		finalDamage = damage,
		blockedDamage = 0,
		fullyBlocked = false,
	}
	SV.PushCombatDamageContext( target, damageInfo, metadata )
	local vehicleDamageSerial = target.MCVehicleDamageSerial
	local damageCallOK, damageCallError = pcall( function()
		target:TakeDamageInfo( damageInfo )
		-- Some Source base_anim configurations ignore TakeDamageInfo before the SENT
		-- callback even when a Lua damage handler exists. Vehicles expose an
		-- authoritative fallback; the serial makes it impossible to apply one hit
		-- twice when the engine callback did run synchronously.
		if IsValid( target ) and target.ApplyMinecraftVehicleDamage
		and target.MCVehicleDamageSerial == vehicleDamageSerial then
			target:ApplyMinecraftVehicleDamage( damageInfo )
		end
	end )
	SV.PopCombatDamageContext( target, damageInfo, metadata )
	if not damageCallOK then error( damageCallError, 0 ) end
	if metadata.fullyBlocked ~= true and ( tonumber( spec.damagePerAttack ) or 0 ) > 0 and SV.DamageSelectedItem then
		SV.DamageSelectedItem( ply, spec.damagePerAttack, { player = ply, reason = "attack" } )
	end
	if MC.RunEvent then MC.RunEvent( "MC.PlayerAttackedEntity", ply, target, metadata ) end
	return true, metadata
end

local function applyEquipmentCombatDamage( target, damageInfo )
	if not validPlayer( target ) then return end
	if SV.IsChunkCollisionPlayerDamage and SV.IsChunkCollisionPlayerDamage( target, damageInfo ) then return end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( target, false ) or nil
	local damage = math.max( 0, tonumber( damageInfo:GetDamage() ) or 0 )
	if damage <= 0 then return end
	local metadata = SV.GetCombatDamageContext( target, damageInfo )
	-- Damage-immunity effects (for example Frost Walker's precise campfire
	-- source tag) must resolve before shield/armor durability and mitigation.
	-- The later post-equipment hook remains the boundary for protection-style
	-- reductions that intentionally consume armor first.
	hook.Run( "MCITEM.DamageBeforeEquipmentMitigation", target, damageInfo, metadata )
	damage = math.max( 0, tonumber( damageInfo:GetDamage() ) or 0 )
	if damage <= 0 then
		damageInfo:SetDamage( 0 )
		if metadata then
			metadata.finalDamage = 0
			metadata.fullyBlocked = true
		end
		return
	end
	local blockedDamage = 0
	local shield, shieldState, shieldSpec = activeShield( target, record, damageInfo, metadata )
	local sourcePosition = shield and damageSourcePosition( target, damageInfo ) or nil
	if shield and sourcePosition and shieldFacesSource( target, sourcePosition, shieldSpec ) then
		local durabilityCommitted, shieldBroken, shieldDamageError = damageShield(
			target, record, shield, shieldState, damage )
		if durabilityCommitted then
			blockedDamage = damage
			playShieldBlockSound( target )
			if shieldBroken then playShieldBreakSound( target ) end
			local attacker = damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
			if not projectileDamage( damageInfo ) then
				knockBackShieldAttacker( target, attacker )
				-- Player.blockUsingItem re-reads the blocking stack after durability
				-- damage. A shield destroyed by this very hit no longer receives the
				-- axe cooldown or its separate disabled sound.
				local disableSeconds = not shieldBroken and attackerDisablesShield( attacker, damageInfo ) or 0
				if disableSeconds > 0 then SV.DisablePlayerShield( target, disableSeconds, "axe_attack" ) end
			end
			if MC.RunEvent then MC.RunEvent( "MC.ShieldBlockedDamage", target, attacker, blockedDamage, shieldState.hand ) end
			damage = 0
		elseif metadata then
			metadata.shieldDurabilityError = shieldDamageError
		end
	end

	local armor, toughness, knockback = 0, 0, 0
	if record and SV.PlayerEquipmentTotals then armor, toughness, knockback = SV.PlayerEquipmentTotals( record ) end
	if damage > 0 and armor > 0 and not bypassesArmor( damageInfo ) then
		local durabilityDamage = MC.ArmorDurabilityDamageForHit and MC.ArmorDurabilityDamageForHit( damage )
			or math.max( 1, math.floor( damage / 4 ) )
		if SV.DamagePlayerArmor then
			SV.DamagePlayerArmor( target, durabilityDamage, { player = target, reason = "armor_hit" } )
		end
		-- Pass the authoritative target/transaction through the generic armor
		-- boundary. Breach providers must bind to this exact hit; a global
		-- "last mace" context is unsafe when damage hooks nest.
		damage = MC.ArmorDamageAfterAbsorb and MC.ArmorDamageAfterAbsorb(
			damage, armor, toughness, target, damageInfo, metadata ) or damage
	end
	if knockback > 0 and damageInfo.GetDamageForce and damageInfo.SetDamageForce then
		local force = damageInfo:GetDamageForce()
		if force then damageInfo:SetDamageForce( force * math.Clamp( 1 - knockback, 0, 1 ) ) end
	end
	-- MCITEM status mitigation is deliberately invoked after the vanilla-shaped
	-- shield/armor calculation. Java LivingEntity.actuallyHurt consumes
	-- absorption after armor and magic resistance; exposing this boundary keeps
	-- an addon hook from depending on EntityTakeDamage registration order.
	damageInfo:SetDamage( math.max( 0, damage ) )
	hook.Run( "MCITEM.DamageAfterEquipmentMitigation", target, damageInfo, metadata )
	-- All protection listeners must finish before absorption consumes health.
	hook.Run( "MCITEM.DamageAfterProtectionMitigation", target, damageInfo, metadata )
	damage = math.max( 0, tonumber( damageInfo:GetDamage() ) or 0 )
	tryDeathProtection( target, record, damageInfo, metadata, damage )
	damage = math.max( 0, tonumber( damageInfo:GetDamage() ) or 0 )
	damageInfo:SetDamage( damage )
	if metadata then
		metadata.blockedDamage = blockedDamage
		metadata.finalDamage = damage
		metadata.fullyBlocked = blockedDamage > 0 and damage <= 0 and metadata.deathProtection ~= true
	end
end

hook.Add( "EntityTakeDamage", "mc_equipment_combat_damage", applyEquipmentCombatDamage )

hook.Add( "PlayerSwitchWeapon", "mc_equipment_combat_switch", function( ply, oldWeapon )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record then SV.ResetSelectedAttackCooldown( ply, record ) end
	local bridge = MC.HandWeaponBridge
	local controlled = IsValid( oldWeapon ) and (
		bridge and bridge.IsInventoryControlledClass and bridge.IsInventoryControlledClass( oldWeapon )
		or oldWeapon.GetClass and oldWeapon:GetClass() == "mc_item_hand"
		or oldWeapon.GetNW2Bool and oldWeapon:GetNW2Bool( "MCITEM_InventoryProxy", false ) == true
	) or false
	if controlled and SV.CancelSelectedItemUse then
		SV.CancelSelectedItemUse( ply, "weapon_switched" )
	end
end )

hook.Add( "PlayerSpawn", "mc_equipment_combat_spawn", function( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record then
		record.shieldDisabledUntil = 0
		SV.ResetSelectedAttackCooldown( ply, record )
	end
	if IsValid( ply ) and ply.SetNWFloat then ply:SetNWFloat( "mc_shield_disabled_until", 0 ) end
end )

hook.Add( "PlayerDeath", "mc_equipment_combat_death", function( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record then record.shieldDisabledUntil = 0 end
	if IsValid( ply ) and ply.SetNWFloat then ply:SetNWFloat( "mc_shield_disabled_until", 0 ) end
end )
