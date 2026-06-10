--[[----------------------------------------------------------------------------
	MC : GMod damage bridge for chunk-backed blocks.

	Blocks still live only in MC.World. This module maps entity damage on the
	mc_chunk collision owner back to block cells and then uses MC.SV writes.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config or {}

SV.BlockDamage = SV.BlockDamage or {}
SV.RecentTraceDamage = SV.RecentTraceDamage or {}
SV.RecentExplosions = SV.RecentExplosions or {}

local TRACE_INSET = 1
local EXPLOSION_GRID = 15
local EXPLOSION_STEP = 0.3
local EXPLOSION_AIR_COST = 0.22500001

local function conVarBool( cv, fallback )
	if not cv then return fallback end
	return cv:GetBool()
end

local function conVarFloat( cv, fallback )
	if not cv then return fallback end
	return cv:GetFloat()
end

local function conVarInt( cv, fallback )
	if not cv then return fallback end
	return cv:GetInt()
end

local function damageEnabled()
	return conVarBool( C.BlockDamage, true )
end

local function damageActor( options )
	options = options or {}
	return options.actor or options.attacker or nil
end

local function actorCanDamage( actor, options )
	if options and options.ignorePermissions then return true end
	if not IsValid( actor ) or not actor:IsPlayer() then return true end
	if C.AdminOnly and C.AdminOnly:GetBool() and not actor:IsAdmin() then return false end
	return true
end

local function blockDamageKey( bx, by, bz )
	return bx .. ":" .. by .. ":" .. bz
end

local function blockHealth( id )
	local hardness = MC.BlockHardness and MC.BlockHardness( id ) or 1
	if hardness < 0 then return math.huge end
	local scale = math.max( 0, conVarFloat( C.BlockHealthScale, 20 ) )
	return math.max( 1, hardness * scale )
end

local function clearExpiredDamage()
	local now = CurTime()
	for key, rec in pairs( SV.BlockDamage ) do
		if not rec or now >= ( rec.expire or 0 ) then
			SV.BlockDamage[key] = nil
		end
	end
	for key, expire in pairs( SV.RecentTraceDamage ) do
		if now >= expire then SV.RecentTraceDamage[key] = nil end
	end
	for key, expire in pairs( SV.RecentExplosions ) do
		if now >= expire then SV.RecentExplosions[key] = nil end
	end
end
timer.Create( "mc_block_damage_decay", 1, 0, clearExpiredDamage )

function SV.ApplyBlockDamage( bx, by, bz, amount, options )
	if not damageEnabled() then return false, "disabled" end
	options = options or {}
	amount = tonumber( amount ) or 0
	if amount <= 0 then return false, "no_damage" end

	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 then return false, "air" end
	if not actorCanDamage( damageActor( options ), options ) then return false, "forbidden" end

	local hardness = MC.BlockHardness and MC.BlockHardness( id ) or 1
	if hardness < 0 then return false, "unbreakable" end

	local health = blockHealth( id )
	local key = blockDamageKey( bx, by, bz )
	local now = CurTime()
	local rec = SV.BlockDamage[key]
	if not rec or rec.id ~= id or now >= ( rec.expire or 0 ) then
		rec = { id = id, damage = 0 }
	end
	rec.damage = rec.damage + amount
	rec.expire = now + math.max( 0, conVarFloat( C.BlockDamageDecay, 5 ) )

	if rec.damage + 0.0001 < health then
		SV.BlockDamage[key] = rec
		return false, "damaged", rec.damage, health
	end

	SV.BlockDamage[key] = nil
	local ok, err = SV.RemoveBlock( bx, by, bz, {
		actor = damageActor( options ),
		fx = options.fx ~= false,
		handlers = options.handlers,
		priorityPhys = options.priorityPhys == true,
	} )
	if not ok then return false, err or "remove_failed" end
	return true, "broken", rec.damage, health
end

local function explosionRadiusForDamage( damage )
	local radius = ( tonumber( damage ) or 0 ) * conVarFloat( C.BlockExplosionScale, 0.04 )
	local maxRadius = math.max( 0, conVarFloat( C.BlockExplosionMaxRadius, 8 ) )
	return math.Clamp( radius, 0, maxRadius )
end

local function addExplosionCell( cells, order, bx, by, bz, maxBlocks )
	local key = blockDamageKey( bx, by, bz )
	if cells[key] then return false end
	cells[key] = { bx = bx, by = by, bz = bz }
	order[#order + 1] = key
	return maxBlocks > 0 and #order >= maxBlocks
end

function SV.ApplyBlockExplosion( center, damage, options )
	if not damageEnabled() then return false, 0, 0 end
	if not center then return false, 0, 0 end
	options = options or {}
	if not actorCanDamage( damageActor( options ), options ) then return false, 0, "forbidden" end

	if options.key then
		local now = CurTime()
		if SV.RecentExplosions[options.key] and SV.RecentExplosions[options.key] > now then
			return false, 0, "duplicate"
		end
		SV.RecentExplosions[options.key] = now + 0.25
	end

	local radius = explosionRadiusForDamage( damage )
	if radius <= 0 then return false, 0, radius end

	local maxBlocks = math.max( 0, conVarInt( C.BlockExplosionMaxBlocks, 4096 ) )
	local cx, cy, cz = center.x / MC.BS, center.y / MC.BS, center.z / MC.BS
	local cells, order = {}, {}
	local stopped = false

	for xx = 0, EXPLOSION_GRID do
		if stopped then break end
		for yy = 0, EXPLOSION_GRID do
			if stopped then break end
			for zz = 0, EXPLOSION_GRID do
				if stopped then break end
				if xx == 0 or xx == EXPLOSION_GRID or yy == 0 or yy == EXPLOSION_GRID or zz == 0 or zz == EXPLOSION_GRID then
					local dx = xx / EXPLOSION_GRID * 2 - 1
					local dy = yy / EXPLOSION_GRID * 2 - 1
					local dz = zz / EXPLOSION_GRID * 2 - 1
					local len = math.sqrt( dx * dx + dy * dy + dz * dz )
					if len > 0 then
						dx, dy, dz = dx / len, dy / len, dz / len
						local power = radius * ( 0.7 + math.Rand( 0, 0.6 ) )
						local x, y, z = cx, cy, cz

						while power > 0 do
							local bx, by, bz = math.floor( x ), math.floor( y ), math.floor( z )
							local id = MC.GetBlock( bx, by, bz )
							if id ~= 0 then
								local explosionResistance = MC.BlockExplosionResistance and MC.BlockExplosionResistance( id ) or 1
								power = power - ( explosionResistance + 0.3 ) * EXPLOSION_STEP
								local hardness = MC.BlockHardness and MC.BlockHardness( id ) or 1
								if power > 0 and hardness >= 0 then
									stopped = addExplosionCell( cells, order, bx, by, bz, maxBlocks )
									if stopped then break end
								end
							end

							x = x + dx * EXPLOSION_STEP
							y = y + dy * EXPLOSION_STEP
							z = z + dz * EXPLOSION_STEP
							power = power - EXPLOSION_AIR_COST
						end
					end
				end
			end
		end
	end

	local broken = 0
	for _, key in ipairs( order ) do
		local cell = cells[key]
		local ok = SV.RemoveBlock( cell.bx, cell.by, cell.bz, {
			actor = damageActor( options ),
			fx = options.fx ~= false,
			handlers = options.handlers,
			priorityPhys = false,
		} )
		if ok then broken = broken + 1 end
	end

	return broken > 0, broken, radius
end

local function damageSignature( bx, by, bz, dmg )
	local attacker = dmg:GetAttacker()
	local inflictor = dmg:GetInflictor()
	local attackerId = IsValid( attacker ) and attacker:EntIndex() or 0
	local inflictorId = IsValid( inflictor ) and inflictor:EntIndex() or 0
	return table.concat( {
		bx, by, bz,
		math.floor( ( dmg:GetDamage() or 0 ) * 100 ),
		attackerId,
		inflictorId,
	}, ":" )
end

local function cellFromTrace( tr, dir )
	if not tr or not tr.HitPos then return nil end
	local inward
	if dir and dir.LengthSqr and dir:LengthSqr() > 0.0001 then
		inward = Vector( dir.x, dir.y, dir.z )
		inward:Normalize()
	elseif tr.HitNormal and tr.HitNormal.LengthSqr and tr.HitNormal:LengthSqr() > 0.0001 then
		inward = -tr.HitNormal
	else
		inward = Vector( 0, 0, 0 )
	end
	return MC.WorldToCell( tr.HitPos + inward * TRACE_INSET )
end

local function vectorUsable( v )
	return v and v.LengthSqr and v:LengthSqr() > 0.0001
end

local function cellFromDamageInfo( ent, dmg )
	local attacker = dmg:GetAttacker()
	if IsValid( attacker ) and attacker:IsPlayer() and MC.PlayerBlockAim then
		local hit = MC.PlayerBlockAim( attacker )
		if hit then return hit.bx, hit.by, hit.bz end
	end

	local pos = dmg:GetDamagePosition()
	if not vectorUsable( pos ) and dmg.GetReportedPosition then
		pos = dmg:GetReportedPosition()
	end
	if not vectorUsable( pos ) then return nil end

	local force = dmg:GetDamageForce()
	if vectorUsable( force ) then
		force = Vector( force.x, force.y, force.z )
		force:Normalize()
		pos = pos + force * TRACE_INSET
	end
	return MC.WorldToCell( pos )
end

local function explosionCenter( ent, dmg )
	local center = dmg:GetDamagePosition()
	if not vectorUsable( center ) and dmg.GetReportedPosition then
		center = dmg:GetReportedPosition()
	end
	local inflictor = dmg:GetInflictor()
	if not vectorUsable( center ) and IsValid( inflictor ) then
		center = inflictor:GetPos()
	end
	if not vectorUsable( center ) and IsValid( ent ) then
		center = ent:GetPos()
	end
	return center
end

local function explosionSignature( ent, dmg, center )
	local attacker = dmg:GetAttacker()
	local inflictor = dmg:GetInflictor()
	local attackerId = IsValid( attacker ) and attacker:EntIndex() or 0
	local inflictorId = IsValid( inflictor ) and inflictor:EntIndex() or 0
	return table.concat( {
		"blast",
		attackerId,
		inflictorId,
		math.floor( center.x ),
		math.floor( center.y ),
		math.floor( center.z ),
		math.floor( ( dmg:GetDamage() or 0 ) * 10 ),
	}, ":" )
end

function SV.HandleChunkTraceDamage( ent, dmg, dir, tr )
	if not IsValid( ent ) or ent:GetClass() ~= "mc_chunk" then return false end
	if dmg:IsDamageType( DMG_BLAST ) then return false end
	local bx, by, bz = cellFromTrace( tr, dir )
	if not bx then return false end
	local sig = damageSignature( bx, by, bz, dmg )
	SV.RecentTraceDamage[sig] = CurTime() + 0.08
	return SV.ApplyBlockDamage( bx, by, bz, dmg:GetDamage(), {
		actor = dmg:GetAttacker(),
		inflictor = dmg:GetInflictor(),
	} )
end

function SV.HandleChunkDamage( ent, dmg )
	if not IsValid( ent ) or ent:GetClass() ~= "mc_chunk" then return false end
	if not damageEnabled() then return false end

	if dmg:IsDamageType( DMG_BLAST ) then
		local center = explosionCenter( ent, dmg )
		if not center then return false end
		return SV.ApplyBlockExplosion( center, dmg:GetDamage(), {
			actor = dmg:GetAttacker(),
			inflictor = dmg:GetInflictor(),
			key = explosionSignature( ent, dmg, center ),
		} )
	end

	local bx, by, bz = cellFromDamageInfo( ent, dmg )
	if not bx then return false end
	local sig = damageSignature( bx, by, bz, dmg )
	if SV.RecentTraceDamage[sig] and SV.RecentTraceDamage[sig] > CurTime() then
		return false, "duplicate"
	end
	return SV.ApplyBlockDamage( bx, by, bz, dmg:GetDamage(), {
		actor = dmg:GetAttacker(),
		inflictor = dmg:GetInflictor(),
	} )
end
