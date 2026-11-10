-- Minecraft entity.player.hurt uses damage/hit1..3. These bundled copies are
-- resampled to 44.1 kHz mono for Source; emit on the victim so both the victim
-- and nearby players hear it, independently of the attacker's weapon sounds.
if not SERVER then return end

local hurtSounds = {
	"mc/player/hit1.ogg",
	"mc/player/hit2.ogg",
	"mc/player/hit3.ogg",
}
local nextHurtSound = setmetatable( {}, { __mode = "k" } )

local function isMinecraftItemAttack( target, damageInfo )
	-- Use the hit's direct source, not the attacker's current weapon: players
	-- can switch weapons while a projectile is still in flight.
	local inflictor = damageInfo:GetInflictor()
	if not IsValid( inflictor ) then return false end
	local className = inflictor:GetClass()
	if className == "mc_item_hand" then
		local metadata = MC.SV.GetCombatDamageContext( target, damageInfo )
		return metadata ~= nil and not MC.IsEmptyItemStack( metadata.stack )
	end
	if inflictor:IsWeapon() then
		return className == "weapon_bmb_item_model_test"
			or weapons.IsBasedOn( className, "weapon_bmb_item_model_test" )
	end
	return className == "mc_projectile" or string.StartWith( className, "mcitem_" )
end

local function playHurtSound( target )
	-- Minecraft's ordinary hurt feedback has a ten-tick (0.5 second) window.
	local now = CurTime()
	if now < ( nextHurtSound[target] or 0 ) then return end
	nextHurtSound[target] = now + 0.5
	target:EmitSound( hurtSounds[math.random( #hurtSounds )], 75,
		math.floor( 100 + ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 20 + 0.5 ), 1, CHAN_VOICE )
end

hook.Add( "PostEntityTakeDamage", "mc_player_hurt_sound", function( target, damageInfo, tookDamage )
	if not tookDamage or not IsValid( target ) or not target:IsPlayer() then return end
	if damageInfo:GetDamage() <= 0 then return end
	if not isMinecraftItemAttack( target, damageInfo ) then return end
	playHurtSound( target )
end )

-- Periodic potion damage uses its caster/world as the inflictor, so it never
-- passes the weapon filter above. MCITEM reports only accepted hits, including
-- damage absorbed by gold hearts; share the cooldown to avoid duplicate sounds.
hook.Add( "MCITEM.PotionPeriodicDamage", "mc_player_potion_hurt_sound", function( target, effectId )
	if not IsValid( target ) or not target:IsPlayer() then return end
	if effectId ~= "poison" and effectId ~= "wither" then return end
	playHurtSound( target )
end )
