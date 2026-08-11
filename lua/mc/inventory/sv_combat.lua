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

local function validPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer() and ply.Alive and ply:Alive()
end

local function activeMinecraftHand( ply, context )
	if context and context.allowAnyWeapon == true then return true end
	local weapon = IsValid( ply ) and ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	return IsValid( weapon ) and weapon.GetClass and weapon:GetClass() == "mc_item_hand"
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

local function bypassesShield( damageInfo )
	return hasDamageType( damageInfo, DMG_FALL )
		or hasDamageType( damageInfo, DMG_DROWN )
		or hasDamageType( damageInfo, DMG_POISON )
		or hasDamageType( damageInfo, DMG_RADIATION )
		or hasDamageType( damageInfo, DMG_BURN )
		or hasDamageType( damageInfo, DMG_SLOWBURN )
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
	return IsValid( inflictor ) and inflictor.GetClass and inflictor:GetClass() == "mc_projectile"
end

local function damageSourcePosition( victim, damageInfo )
	local attacker = damageInfo and damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
	local inflictor = damageInfo and damageInfo.GetInflictor and damageInfo:GetInflictor() or nil
	local inflictorClass = IsValid( inflictor ) and inflictor.GetClass and inflictor:GetClass() or ""
	if IsValid( inflictor ) and inflictor ~= victim
	and ( inflictorClass == "mc_projectile" or hasDamageType( damageInfo, DMG_BLAST ) ) then
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

local function shieldStackForState( record, state )
	if not record or not state or state.kind ~= "shield" then return nil end
	if state.hand == "offhand" then return record.equipment and record.equipment.offhand or nil end
	if state.selected ~= nil and state.selected ~= record.selected then return nil end
	return record.storage and record.storage[( math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 ) ) + 1] or nil
end

function SV.IsPlayerShieldDisabled( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	return record ~= nil and ( tonumber( record.shieldDisabledUntil ) or 0 ) > CurTime()
end

function SV.DisablePlayerShield( ply, seconds, reason )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record then return false, "inventory_not_loaded" end
	seconds = math.max( 0, tonumber( seconds ) or 0 )
	if seconds <= 0 then return false, "invalid_shield_cooldown" end
	record.shieldDisabledUntil = math.max( tonumber( record.shieldDisabledUntil ) or 0, CurTime() + seconds )
	if IsValid( ply ) and ply.SetNWFloat then ply:SetNWFloat( "mc_shield_disabled_until", record.shieldDisabledUntil ) end
	if record.itemUse and record.itemUse.kind == "shield" and SV.CancelSelectedItemUse then
		SV.CancelSelectedItemUse( ply, reason or "shield_disabled" )
	end
	if MC.RunEvent then MC.RunEvent( "MC.ShieldDisabled", ply, seconds, reason or "shield_disabled" ) end
	return true, record.shieldDisabledUntil
end

local function activeShield( ply, record, damageInfo )
	if not record or bypassesShield( damageInfo ) or SV.IsPlayerShieldDisabled( ply ) then return nil end
	local state = record.itemUse
	local stack = shieldStackForState( record, state )
	local spec = stack and MC.ItemShieldSpec and MC.ItemShieldSpec( stack ) or nil
	if not state or not stack or not spec then return nil end
	if state.stackHash and MC.ItemStackHash and state.stackHash ~= MC.ItemStackHash( stack ) then return nil end
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
	if amount <= 0 then return nil, false end
	if state.hand == "offhand" and SV.DamageEquipmentItem then
		return SV.DamageEquipmentItem( ply, "offhand", amount, { player = ply, reason = "shield_block" } )
	end
	if SV.DamageSelectedItem then
		return SV.DamageSelectedItem( ply, amount, { player = ply, reason = "shield_block" } )
	end
	return nil, false, "durability_unavailable"
end

local function attackerDisablesShield( attacker, damageInfo )
	if projectileDamage( damageInfo ) or not validPlayer( attacker ) or not activeMinecraftHand( attacker ) then return 0 end
	local _, spec = selectedAttackSpec( attacker )
	return math.max( 0, tonumber( spec and spec.disableBlockingSeconds ) or 0 )
end

function SV.IsCombatTarget( target, attacker )
	if not IsValid( target ) or target == attacker or target.IsWorld and target:IsWorld() then return false end
	local class = target.GetClass and target:GetClass() or ""
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
	local target = trace and trace.Entity or nil
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
	if requestedTarget ~= nil and requestedTarget ~= target then return false, "attack_target_mismatch" end
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not record then return false, "inventory_not_loaded" end
	local stack, spec = selectedAttackSpec( ply )
	local now = CurTime()
	local elapsed = record.lastAttackAt and math.max( 0, now - record.lastAttackAt ) or nil
	local strength = MC.ItemAttackStrengthScale and MC.ItemAttackStrengthScale( elapsed, spec.attackSpeed ) or 1
	local damage = MC.ItemAttackDamageAtStrength and MC.ItemAttackDamageAtStrength( spec.attackDamage, strength )
		or math.max( 0, tonumber( spec.attackDamage ) or 1 )
	record.lastAttackAt = now
	if ply.SetNWFloat then
		ply:SetNWFloat( "mc_attack_strength", strength )
		ply:SetNWFloat( "mc_attack_ready_at", now + 1 / math.max( 0.1, tonumber( spec.attackSpeed ) or 4 ) )
	end
	if not DamageInfo then return false, "damage_info_unavailable" end
	local damageInfo = DamageInfo()
	if not damageInfo then return false, "damage_info_unavailable" end
	damageInfo:SetDamage( damage )
	if damageInfo.SetDamageType then damageInfo:SetDamageType( DMG_CLUB or 128 ) end
	if damageInfo.SetAttacker then damageInfo:SetAttacker( ply ) end
	local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon() or ply
	if damageInfo.SetInflictor then damageInfo:SetInflictor( IsValid( weapon ) and weapon or ply ) end
	local hitPosition = trace and trace.HitPos or entityCenter( target )
	if hitPosition and damageInfo.SetDamagePosition then damageInfo:SetDamagePosition( hitPosition ) end
	if damageInfo.SetReportedPosition and ply.GetShootPos then damageInfo:SetReportedPosition( ply:GetShootPos() ) end
	if damageInfo.SetDamageForce and ply.GetAimVector then damageInfo:SetDamageForce( ply:GetAimVector() * damage * 100 ) end
	local metadata = {
		attacker = ply,
		stack = MC.CopyItemStack( stack ),
		spec = spec,
		strength = strength,
		originalDamage = damage,
		finalDamage = damage,
		blockedDamage = 0,
		fullyBlocked = false,
	}
	SV.CombatDamageContexts[damageInfo] = metadata
	target:TakeDamageInfo( damageInfo )
	SV.CombatDamageContexts[damageInfo] = nil
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
	if not record then return end
	local damage = math.max( 0, tonumber( damageInfo:GetDamage() ) or 0 )
	if damage <= 0 then return end
	local metadata = SV.CombatDamageContexts[damageInfo]
	local blockedDamage = 0
	local shield, shieldState, shieldSpec = activeShield( target, record, damageInfo )
	local sourcePosition = shield and damageSourcePosition( target, damageInfo ) or nil
	if shield and sourcePosition and shieldFacesSource( target, sourcePosition, shieldSpec ) then
		blockedDamage = damage
		damageShield( target, record, shield, shieldState, blockedDamage )
		local attacker = damageInfo.GetAttacker and damageInfo:GetAttacker() or nil
		local disableSeconds = attackerDisablesShield( attacker, damageInfo )
		if disableSeconds > 0 then SV.DisablePlayerShield( target, disableSeconds, "axe_attack" ) end
		if MC.RunEvent then MC.RunEvent( "MC.ShieldBlockedDamage", target, attacker, blockedDamage, shieldState.hand ) end
		damage = 0
	end

	local armor, toughness, knockback = 0, 0, 0
	if SV.PlayerEquipmentTotals then armor, toughness, knockback = SV.PlayerEquipmentTotals( record ) end
	if damage > 0 and armor > 0 and not bypassesArmor( damageInfo ) then
		local durabilityDamage = MC.ArmorDurabilityDamageForHit and MC.ArmorDurabilityDamageForHit( damage )
			or math.max( 1, math.floor( damage / 4 ) )
		if SV.DamagePlayerArmor then
			SV.DamagePlayerArmor( target, durabilityDamage, { player = target, reason = "armor_hit" } )
		end
		damage = MC.ArmorDamageAfterAbsorb and MC.ArmorDamageAfterAbsorb( damage, armor, toughness ) or damage
	end
	if knockback > 0 and damageInfo.GetDamageForce and damageInfo.SetDamageForce then
		local force = damageInfo:GetDamageForce()
		if force then damageInfo:SetDamageForce( force * math.Clamp( 1 - knockback, 0, 1 ) ) end
	end
	damageInfo:SetDamage( damage )
	if metadata then
		metadata.blockedDamage = blockedDamage
		metadata.finalDamage = damage
		metadata.fullyBlocked = blockedDamage > 0 and damage <= 0
	end
end

hook.Add( "EntityTakeDamage", "mc_equipment_combat_damage", applyEquipmentCombatDamage )

hook.Add( "PlayerSwitchWeapon", "mc_equipment_combat_switch", function( ply, oldWeapon )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record then record.lastAttackAt = CurTime() end
	if IsValid( oldWeapon ) and oldWeapon.GetClass and oldWeapon:GetClass() == "mc_item_hand"
	and SV.CancelSelectedItemUse then
		SV.CancelSelectedItemUse( ply, "weapon_switched" )
	end
end )

hook.Add( "PlayerSpawn", "mc_equipment_combat_spawn", function( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record then
		record.shieldDisabledUntil = 0
		record.lastAttackAt = CurTime()
	end
	if IsValid( ply ) and ply.SetNWFloat then ply:SetNWFloat( "mc_shield_disabled_until", 0 ) end
end )

hook.Add( "PlayerDeath", "mc_equipment_combat_death", function( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record then record.shieldDisabledUntil = 0 end
	if IsValid( ply ) and ply.SetNWFloat then ply:SetNWFloat( "mc_shield_disabled_until", 0 ) end
end )
