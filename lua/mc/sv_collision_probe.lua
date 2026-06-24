--[[----------------------------------------------------------------------------
	MC : server-backed collision probe commands.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local DEFAULT_CELL = { 10, 9, -334 }

util.AddNetworkString( "mc_collision_probe_create" )
util.AddNetworkString( "mc_collision_probe_clear" )
util.AddNetworkString( "mc_collision_probe_bound" )

local function parseCellArgs( args, offset )
	args = args or {}
	offset = offset or 0
	return math.floor( tonumber( args[1 + offset] ) or DEFAULT_CELL[1] ),
		math.floor( tonumber( args[2 + offset] ) or DEFAULT_CELL[2] ),
		math.floor( tonumber( args[3 + offset] ) or DEFAULT_CELL[3] )
end

local function canUseProbe( ply )
	if not IsValid( ply ) then return true end
	if SV.CanEdit then return SV.CanEdit( ply ) end
	return ply:IsAdmin()
end

local function printProbe( ply, msg )
	if IsValid( ply ) then
		ply:PrintMessage( HUD_PRINTCONSOLE, "[MC probe] " .. msg )
	else
		MsgN( "[MC probe] " .. msg )
	end
end

local function sendProbeBinding( ply, ent )
	if not IsValid( ply ) or not IsValid( ent ) then return end
	timer.Simple( 0, function()
		if not IsValid( ply ) or not IsValid( ent ) then return end
		net.Start( "mc_collision_probe_bound" )
			net.WriteEntity( ent )
		net.Send( ply )
	end )
end

function SV.ClearCollisionProbe()
	if IsValid( SV.CollisionProbeEntity ) then
		SV.CollisionProbeEntity:Remove()
	end
	SV.CollisionProbeEntity = nil
end

function SV.SpawnCollisionProbe( ply, bx, by, bz )
	if not canUseProbe( ply ) then return nil end

	bx, by, bz = math.floor( tonumber( bx ) or DEFAULT_CELL[1] ),
		math.floor( tonumber( by ) or DEFAULT_CELL[2] ),
		math.floor( tonumber( bz ) or DEFAULT_CELL[3] )

	SV.ClearCollisionProbe()

	local ent = ents.Create( "mc_client_collision_probe" )
	if not IsValid( ent ) then
		printProbe( ply, "failed to create server entity mc_client_collision_probe" )
		return nil
	end

	ent:Spawn()
	ent:Activate()
	local ok = ent.ApplyProbeCell and ent:ApplyProbeCell( bx, by, bz )
	SV.CollisionProbeEntity = ent

	printProbe( ply, string.format(
		"created server-backed entity at cell %d %d %d entIndex=%s phys=%s ok=%s",
		bx, by, bz,
		tostring( ent:EntIndex() ),
		tostring( IsValid( ent:GetPhysicsObject() ) ),
		tostring( ok )
	) )
	sendProbeBinding( ply, ent )
	return ent
end

net.Receive( "mc_collision_probe_create", function( _len, ply )
	local bx = net.ReadInt( 32 )
	local by = net.ReadInt( 32 )
	local bz = net.ReadInt( 32 )
	SV.SpawnCollisionProbe( ply, bx, by, bz )
end )

net.Receive( "mc_collision_probe_clear", function( _len, ply )
	if not canUseProbe( ply ) then return end
	SV.ClearCollisionProbe()
	printProbe( ply, "cleared server-backed collision probe" )
end )

concommand.Add( "mc_client_collision_probe_server", function( ply, _cmd, args )
	local bx, by, bz = parseCellArgs( args )
	SV.SpawnCollisionProbe( ply, bx, by, bz )
end )

concommand.Add( "mc_client_collision_probe_server_clear", function( ply )
	if not canUseProbe( ply ) then return end
	SV.ClearCollisionProbe()
	printProbe( ply, "cleared server-backed collision probe" )
end )
