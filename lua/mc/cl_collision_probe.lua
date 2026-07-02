--[[----------------------------------------------------------------------------
	MC : pure clientside collision probe commands.
------------------------------------------------------------------------------]]

MC = MC or {}

local DEFAULT_CELL = { 10, 9, -334 }

local function normalizeCell( bx, by, bz )
	return math.floor( tonumber( bx ) or DEFAULT_CELL[1] ),
		math.floor( tonumber( by ) or DEFAULT_CELL[2] ),
		math.floor( tonumber( bz ) or DEFAULT_CELL[3] )
end

local function parseCellArgs( args )
	args = args or {}
	return normalizeCell( args[1], args[2], args[3] )
end

local function blockSize()
	return MC and MC.BS or 36.5
end

local function cellWorldMin( bx, by, bz )
	if MC and MC.CellWorldMin then return MC.CellWorldMin( bx, by, bz ) end
	local bs = blockSize()
	return Vector( bx * bs, by * bs, bz * bs )
end

local function cellWorldCenter( bx, by, bz )
	if MC and MC.CellWorldCenter then return MC.CellWorldCenter( bx, by, bz ) end
	local bs = blockSize()
	return Vector( bx * bs + bs * 0.5, by * bs + bs * 0.5, bz * bs + bs * 0.5 )
end

local function probeCellText( bx, by, bz )
	return string.format( "%d %d %d", bx, by, bz )
end

local function vectorText( v )
	if not v then return "nil" end
	return string.format( "%.3f %.3f %.3f", v.x, v.y, v.z )
end

local function angleText( a )
	if not a then return "nil" end
	return string.format( "%.3f %.3f %.3f", a.p, a.y, a.r )
end

function MC.SetPendingClientCollisionProbeCell( bx, by, bz )
	bx, by, bz = normalizeCell( bx, by, bz )
	local cell = {
		bx = bx,
		by = by,
		bz = bz,
		signature = probeCellText( bx, by, bz ),
		worldMin = cellWorldMin( bx, by, bz ),
	}
	MC.PendingClientCollisionProbeCell = cell
	return cell
end

function MC.ApplyPendingClientCollisionProbe( ent )
	local cell = MC.PendingClientCollisionProbeCell
	if not IsValid( ent ) or not cell then return false end

	MC.ClientCollisionProbeEntity = ent
	if not ent.ApplyProbeCell then return false end
	if ent.ProbeLocalSignature == cell.signature and IsValid( ent:GetPhysicsObject() ) then return true end

	local ok = ent:ApplyProbeCell( cell.bx, cell.by, cell.bz )
	if ok ~= false then ent.ProbeLocalSignature = cell.signature end
	return ok ~= false
end

local function activeProbeEntity()
	local ent = MC.ClientCollisionProbeEntity
	if IsValid( ent ) then
		MC.ApplyPendingClientCollisionProbe( ent )
		return ent
	end

	local best
	for _, candidate in ipairs( ents.FindByClass( "mc_client_collision_probe" ) ) do
		if IsValid( candidate ) then
			if candidate:EntIndex() > 0 then
				MC.ClientCollisionProbeEntity = candidate
				MC.ApplyPendingClientCollisionProbe( candidate )
				return candidate
			end
			best = best or candidate
		end
	end

	if IsValid( best ) then
		MC.ClientCollisionProbeEntity = best
		MC.ApplyPendingClientCollisionProbe( best )
	end
	return best
end

function MC.ClearClientCollisionProbe()
	if IsValid( MC.ClientCollisionProbeEntity ) then
		if MC.ClientCollisionProbeEntity:EntIndex() <= 0 then
			MC.ClientCollisionProbeEntity:Remove()
		else
			MC.ClientCollisionProbeEntity:PhysicsDestroy()
		end
	end
	MC.ClientCollisionProbeEntity = nil
	MC.PendingClientCollisionProbeCell = nil
end

function MC.SpawnLocalClientCollisionProbe( bx, by, bz )
	local cell = MC.SetPendingClientCollisionProbeCell( bx, by, bz )
	bx, by, bz = cell.bx, cell.by, cell.bz

	MC.ClearClientCollisionProbe()
	MC.PendingClientCollisionProbeCell = cell

	local ent = ents.CreateClientside( "mc_client_collision_probe" )
	if not IsValid( ent ) then
		print( "[MC probe] failed to create clientside entity mc_client_collision_probe" )
		return nil
	end

	MC.ClientCollisionProbeEntity = ent
	local ok = MC.ApplyPendingClientCollisionProbe( ent )
	local phys = ent:GetPhysicsObject()
	print( string.format(
		"[MC probe] created pure client entity at cell %s worldMin=%s phys=%s ok=%s",
		cell.signature,
		tostring( cell.worldMin ),
		tostring( IsValid( phys ) ),
		tostring( ok )
	) )
	return ent
end

function MC.RequestServerCollisionProbe( bx, by, bz )
	local cell = MC.SetPendingClientCollisionProbeCell( bx, by, bz )
	bx, by, bz = cell.bx, cell.by, cell.bz
	local ent = ents.CreateClientside( "mc_client_collision_probe" )
	ent:Spawn()
	ent:ApplyProbeCell( bx, by, bz )
	-- if not net then
	-- 	print( "[MC probe] net library is unavailable; cannot request server-backed probe" )
	-- 	return
	-- end

	-- net.Start( "mc_collision_probe_create" )
	-- 	net.WriteInt( bx, 32 )
	-- 	net.WriteInt( by, 32 )
	-- 	net.WriteInt( bz, 32 )
	-- net.SendToServer()

	print( string.format( "[MC probe] requested server-backed probe at cell %s", probeCellText( bx, by, bz ) ) )
end

function MC.RequestClearServerCollisionProbe()
	if net then
		net.Start( "mc_collision_probe_clear" )
		net.SendToServer()
	end
end

net.Receive( "mc_collision_probe_bound", function()
	local ent = net.ReadEntity()
	local cell = MC.PendingClientCollisionProbeCell

	if IsValid( ent ) then
		MC.ClientCollisionProbeEntity = ent
		local ok = MC.ApplyPendingClientCollisionProbe( ent )
		print( string.format(
			"[MC probe] bound network entity entIndex=%s localCell=%s ok=%s",
			tostring( ent:EntIndex() ),
			cell and cell.signature or "nil",
			tostring( ok )
		) )
	else
		print( string.format(
			"[MC probe] server probe bind arrived before entity; waiting for class scan localCell=%s",
			cell and cell.signature or "nil"
		) )
	end
end )

local function playerHull()
	local ply = LocalPlayer()
	if IsValid( ply ) then
		return ply:OBBMins(), ply:OBBMaxs(), ply
	end
	return Vector( -16, -16, 0 ), Vector( 16, 16, 72 ), nil
end

function MC.TestClientCollisionProbe( bx, by, bz )
	local ent = activeProbeEntity()
	if bx ~= nil or not IsValid( ent ) then
		if bx ~= nil then MC.RequestServerCollisionProbe( bx, by, bz ) end
		print( "[MC probe] no active probe entity to test yet; run mc_client_collision_probe and wait for the server entity" )
		return nil
	end
	if not IsValid( ent ) then return nil end

	local cell = ent.ProbeCell or {}
	bx, by, bz = cell.bx or DEFAULT_CELL[1], cell.by or DEFAULT_CELL[2], cell.bz or DEFAULT_CELL[3]

	local bs = blockSize()
	local mins, maxs, ply = playerHull()
	local center = cellWorldCenter( bx, by, bz )
	local start = center + Vector( 0, 0, bs * 3 )
	local finish = center - Vector( 0, 0, bs * 3 )
	local tr = util.TraceHull( {
		start = start,
		endpos = finish,
		mins = mins,
		maxs = maxs,
		mask = MASK_PLAYERSOLID,
		filter = function( hitEnt )
			return hitEnt ~= ply
		end,
	} )

	print( string.format(
		"[MC probe] hull test cell=%s hit=%s hitWorld=%s ent=%s class=%s hitPos=%s start=%s end=%s",
		probeCellText( bx, by, bz ),
		tostring( tr.Hit ),
		tostring( tr.HitWorld ),
		tostring( tr.Entity ),
		IsValid( tr.Entity ) and tr.Entity:GetClass() or "nil",
		tostring( tr.HitPos ),
		tostring( start ),
		tostring( finish )
	) )

	return tr
end

function MC.DumpClientCollisionProbe()
	local ent = activeProbeEntity()
	if not IsValid( ent ) then
		print( "[MC probe] no clientside collision probe exists; run mc_client_collision_probe first" )
		return nil
	end
	MC.ApplyPendingClientCollisionProbe( ent )

	local cell = ent.ProbeCell or MC.PendingClientCollisionProbeCell or {}
	local phys = ent:GetPhysicsObject()
	local aabbMins, aabbMaxs = ent:WorldSpaceAABB()
	local data = {
		cell = probeCellText( cell.bx or DEFAULT_CELL[1], cell.by or DEFAULT_CELL[2], cell.bz or DEFAULT_CELL[3] ),
		class = ent:GetClass(),
		entIndex = ent:EntIndex(),
		pos = ent:GetPos(),
		ang = ent:GetAngles(),
		solid = ent:GetSolid(),
		moveType = ent:GetMoveType(),
		collisionGroup = ent:GetCollisionGroup(),
		obbMins = ent:OBBMins(),
		obbMaxs = ent:OBBMaxs(),
		aabbMins = aabbMins,
		aabbMaxs = aabbMaxs,
		hasApplyProbeCell = type( ent.ApplyProbeCell ) == "function",
		physValid = IsValid( phys ),
		physPos = IsValid( phys ) and phys:GetPos() or nil,
		physAngles = IsValid( phys ) and phys:GetAngles() or nil,
		physMotionEnabled = IsValid( phys ) and phys:IsMotionEnabled(),
	}

	print( string.format(
		"[MC probe dump] cell=%s class=%s entIndex=%s hasApplyProbeCell=%s pos=(%s) ang=(%s)",
		data.cell,
		tostring( data.class ),
		tostring( data.entIndex ),
		tostring( data.hasApplyProbeCell ),
		vectorText( data.pos ),
		angleText( data.ang )
	) )
	print( string.format(
		"[MC probe dump] solid=%s movetype=%s collisionGroup=%s obb=(%s)->(%s) worldAABB=(%s)->(%s)",
		tostring( data.solid ),
		tostring( data.moveType ),
		tostring( data.collisionGroup ),
		vectorText( data.obbMins ),
		vectorText( data.obbMaxs ),
		vectorText( data.aabbMins ),
		vectorText( data.aabbMaxs )
	) )
	print( string.format(
		"[MC probe dump] physValid=%s physMotionEnabled=%s physPos=(%s) physAngles=(%s)",
		tostring( data.physValid ),
		tostring( data.physMotionEnabled ),
		vectorText( data.physPos ),
		angleText( data.physAngles )
	) )

	return data
end

concommand.Add( "mc_client_collision_probe", function( _, _, args )
	MC.RequestServerCollisionProbe( parseCellArgs( args ) )
end, nil, "Create a server-backed MC collision probe at block coords; defaults to 10 9 -334." )

concommand.Add( "mc_client_collision_probe_local", function( _, _, args )
	MC.SpawnLocalClientCollisionProbe( parseCellArgs( args ) )
end, nil, "Create a pure clientside MC collision probe for EntIndex -1 comparison." )

concommand.Add( "mc_client_collision_probe_clear", function()
	MC.RequestClearServerCollisionProbe()
	MC.ClearClientCollisionProbe()
	print( "[MC probe] cleared local probe state and requested server clear" )
end, nil, "Remove the MC collision probe." )

concommand.Add( "mc_client_collision_probe_test", function( _, _, args )
	local bx, by, bz
	if args and args[1] ~= nil then
		bx, by, bz = parseCellArgs( args )
	end
	MC.TestClientCollisionProbe( bx, by, bz )
end, nil, "Trace a player hull through the pure clientside MC collision probe." )

concommand.Add( "mc_client_collision_probe_dump", function()
	MC.DumpClientCollisionProbe()
end, nil, "Print data for the current pure clientside MC collision probe entity." )


concommand.Add( "mc_client_collision_dump", function()
	MC.DumpClientCollision()
end, nil, "Print data for the current pure clientside MC collision probe entity." )

concommand.Add( "mc_client_collision_dump_sch", function()
	MC.DumpClientCollision_sch()
end, nil, "Print data for the current pure clientside MC collision probe entity." )

function MC.DumpClientCollision()


	for _, ent in ipairs( ents.FindByClass( "mc_chunk" ) ) do
		//local phys = ent:GetPhysicsObject()
		local data = {
			pos = ent:GetPos(),
			ang = ent:GetAngles(),
		}

		print( string.format(
			"[MC probe dump] pos=%s ang=%s",
			vectorText( data.pos ),
			angleText( data.ang )
		) )


		return data
	end

end

function MC.DumpClientCollision_sch()


	for _, ent in ipairs( ents.FindByClass( "mc_client_collision_probe" ) ) do
		local phys = ent:GetPhysicsObject()
		local data = {
			pos = ent:GetPos(),
			ang = ent:GetAngles(),
		}

		print( string.format(
			"[MC probe dump] pos=%s ang=%s",
			vectorText( data.pos ),
			angleText( data.ang )
		) )


		return data
	end

end

hook.Add( "ShouldCollide", "ForceProbeCellCollision", function( ent1, ent2 )
    -- 如果其中一个是你的网格实体，强制允许碰撞，覆盖引擎默认的 !IsClientCreated() 过滤
    if ent1:GetClass() == "mc_client_collision_probe" or ent2:IsPlayer() then
        return true 
    end
end )