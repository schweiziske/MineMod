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

hook.Add( "PostEntityTakeDamage", "mc_player_hurt_sound", function( target, damageInfo, tookDamage )
	if not tookDamage or not IsValid( target ) or not target:IsPlayer() then return end
	if damageInfo:GetDamage() <= 0 then return end
	-- Minecraft's ordinary hurt feedback has a ten-tick (0.5 second) window.
	local now = CurTime()
	if now < ( nextHurtSound[target] or 0 ) then return end
	nextHurtSound[target] = now + 0.5
	target:EmitSound( hurtSounds[math.random( #hurtSounds )], 75,
		math.floor( 100 + ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 20 + 0.5 ), 1, CHAN_VOICE )
end )
