--[[----------------------------------------------------------------------------
	MC : per-player prediction collision carrier pool.
	A small fixed set of mc_collision_carrier entities per player, transmitted
	only to their owner. The owning client bakes its interest collision onto
	them (mc/render/cl_collision.lua). The server never rebuilds or removes
	them while the player is connected, so client prediction collision cannot
	be broken by chunk entity churn after block edits.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}
local SV = MC.SV

local function carrierCount()
	return math.Clamp( math.floor( tonumber( MC.Config and MC.Config.ClientCollisionCarriers ) or 24 ), 1, 64 )
end

local function hideCarrierFromOthers( ent, owner )
	for _, other in ipairs( player.GetAll() ) do
		if other ~= owner then
			ent:SetPreventTransmit( other, true )
		end
	end
end

local function validCarriers( ply )
	local out = {}
	for _, ent in ipairs( ply.MCCollisionCarriers or {} ) do
		if IsValid( ent ) then out[#out + 1] = ent end
	end
	return out
end

function SV.EnsureCollisionCarriers( ply )
	if not IsValid( ply ) or not ply:IsPlayer() or ply:IsBot() then return end
	local carriers = validCarriers( ply )
	local want = carrierCount()
	if #carriers < want then
		for i = #carriers + 1, want do
			local ent = ents.Create( "mc_collision_carrier" )
			if not IsValid( ent ) then break end
			ent:SetPos( vector_origin )
			ent:Spawn()
			-- NW vars only after Spawn: values written before the entity spawns
			-- can miss the first client baseline (long-standing NW2 quirk), and
			-- the owning client filters carriers by MCCarrierOwner.
			ent:SetNWEntity( "MCCarrierOwner", ply )
			ent:SetNWInt( "MCCarrierIndex", i )
			hideCarrierFromOthers( ent, ply )
			carriers[#carriers + 1] = ent
		end
	end
	ply.MCCollisionCarriers = carriers
end

function SV.RemoveCollisionCarriers( ply )
	for _, ent in ipairs( ply.MCCollisionCarriers or {} ) do
		if IsValid( ent ) then ent:Remove() end
	end
	ply.MCCollisionCarriers = nil
end

hook.Add( "PlayerInitialSpawn", "mc_collision_carriers_spawn", function( ply )
	-- hide everyone else's carriers from the newcomer
	for _, other in ipairs( player.GetAll() ) do
		if other ~= ply then
			for _, ent in ipairs( other.MCCollisionCarriers or {} ) do
				if IsValid( ent ) then ent:SetPreventTransmit( ply, true ) end
			end
		end
	end
	timer.Simple( 0, function()
		if IsValid( ply ) then SV.EnsureCollisionCarriers( ply ) end
	end )
end )

-- cheap self-heal: respawn any carrier lost to cleanups/addon reloads
hook.Add( "PlayerSpawn", "mc_collision_carriers_ensure", function( ply )
	SV.EnsureCollisionCarriers( ply )
end )

hook.Add( "PostCleanupMap", "mc_collision_carriers_respawn", function()
	timer.Simple( 0, function()
		for _, ply in ipairs( player.GetAll() ) do
			SV.EnsureCollisionCarriers( ply )
		end
	end )
end )

hook.Add( "PlayerDisconnected", "mc_collision_carriers_remove", function( ply )
	SV.RemoveCollisionCarriers( ply )
end )
