-- Server replication for ArmorStand side effects that Source does not expose
-- as a built-in Minecraft entity event.
if not SERVER then return end

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local PARTICLE_MESSAGE = "mc_decoration_armor_stand_break_particles"

function D.EmitDecorationGameEvent( ent, eventName, actor, context )
	if not MC.RunEvent then return end
	MC.RunEvent( "MC.DecorationGameEvent", ent, eventName, actor, context or {} )
end

function D.SendArmorStandBreakingParticles( ent )
	if not IsValid( ent ) or not net then return false end
	local worldPosition = D.WorldFromEntity( ent ) or ent:GetPos()
	local small = ent.IsArmorStandSmall and ent:IsArmorStandSmall() == true
	local blockSize = MC.API and MC.API.Coords and MC.API.Coords.BlockSize
		and MC.API.Coords.BlockSize() or 36.5
	local maximumDistanceSquared = ( 32 * blockSize ) ^ 2
	local recipients = {}
	for _, ply in ipairs( player.GetHumans() ) do
		local playerPosition = D.WorldFromEntity( ply ) or ply:GetPos()
		if playerPosition:DistToSqr( worldPosition ) < maximumDistanceSquared then
			recipients[#recipients + 1] = ply
		end
	end
	if #recipients == 0 then return false end
	net.Start( PARTICLE_MESSAGE )
		net.WriteVector( worldPosition )
		net.WriteBool( small )
	net.Send( recipients )
	return true
end
