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
	return MC.CellKey( bx, by, bz )
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
	local tick = engine.TickCount()
	for key, seenTick in pairs( SV.RecentExplosions ) do
		if tick > seenTick then SV.RecentExplosions[key] = nil end
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

function SV.ApplyBlockExplosion( center, damage, options )
	if not damageEnabled() then return false, 0, 0 end
	if not center then return false, 0, 0 end
	options = options or {}
	if not actorCanDamage( damageActor( options ), options ) then return false, 0, "forbidden" end

	if options.key then
		-- one blast reaches many chunk entities within the same tick; dedupe those
		-- repeats only. A time window here would also swallow distinct explosions
		-- (e.g. stacked TNT detonating at the same spot in quick succession).
		local tick = engine.TickCount()
		if SV.RecentExplosions[options.key] == tick then
			return false, 0, "duplicate"
		end
		SV.RecentExplosions[options.key] = tick
	end

	local radius = explosionRadiusForDamage( damage )
	if radius <= 0 then return false, 0, radius end

	local maxBlocks = math.max( 0, conVarInt( C.BlockExplosionMaxBlocks, 4096 ) )
	local cx, cy, cz = center.x / MC.BS, center.y / MC.BS, center.z / MC.BS
	local cells, order = {}, {}
	local stopped = false

	-- per-explosion cell cache: all ~1350 rays re-sample the same cells near the
	-- center, and the sub-block march revisits each cell several times per ray, so
	-- block/property lookups dominate. Resolve each cell once per explosion.
	local floor = math.floor
	local sqrt = math.sqrt
	local rand = math.Rand
	local cellKey = MC.CellKey
	local getBlock = MC.GetBlock
	local resistanceOf = MC.BlockExplosionResistance
	local hardnessOf = MC.BlockHardness
	local stepCost = {}  -- cellKey -> power cost per sample step (0 = air)
	local breakable = {} -- cellKey -> block may be destroyed

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
					local len = sqrt( dx * dx + dy * dy + dz * dz )
					if len > 0 then
						local sx = dx / len * EXPLOSION_STEP
						local sy = dy / len * EXPLOSION_STEP
						local sz = dz / len * EXPLOSION_STEP
						local power = radius * ( 0.7 + rand( 0, 0.6 ) )
						local x, y, z = cx, cy, cz

						while power > 0 do
							local bx, by, bz = floor( x ), floor( y ), floor( z )
							local key = cellKey( bx, by, bz )
							local cost = stepCost[key]
							if cost == nil then
								local id = getBlock( bx, by, bz )
								if id == 0 then
									cost = 0
								else
									local explosionResistance = resistanceOf and resistanceOf( id ) or 1
									cost = ( explosionResistance + 0.3 ) * EXPLOSION_STEP
									breakable[key] = ( hardnessOf and hardnessOf( id ) or 1 ) >= 0
								end
								stepCost[key] = cost
							end
							if cost > 0 then
								power = power - cost
								if power > 0 and breakable[key] and not cells[key] then
									cells[key] = { bx = bx, by = by, bz = bz }
									order[#order + 1] = key
									if maxBlocks > 0 and #order >= maxBlocks then
										stopped = true
										break
									end
								end
							end

							x = x + sx
							y = y + sy
							z = z + sz
							power = power - EXPLOSION_AIR_COST
						end
					end
				end
			end
		end
	end

	local removals = {}
	for _, key in ipairs( order ) do
		local cell = cells[key]
		removals[#removals + 1] = cell
	end
	local broken = SV.RemoveBlocksBulk( removals, {
		actor = damageActor( options ),
		fx = options.fx ~= false,
		fxLimit = math.max( 0, conVarInt( C.BlockExplosionFxLimit, 16 ) ),
		handlers = options.handlers,
		priorityPhys = false,
		explosionMeshThrottle = true,
		deferPhys = true,
	} )

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
	local bx, by, bz = MC.WorldToCell( tr.HitPos + inward * TRACE_INSET )
	if MC.GetBlock( bx, by, bz ) ~= 0 then return bx, by, bz end
	-- shallow-angle hits can inset along the shot direction into air; the
	-- surface normal always points out of the block that was actually hit
	if tr.HitNormal and tr.HitNormal.LengthSqr and tr.HitNormal:LengthSqr() > 0.0001 then
		local nx, ny, nz = MC.WorldToCell( tr.HitPos - tr.HitNormal * TRACE_INSET )
		if MC.GetBlock( nx, ny, nz ) ~= 0 then return nx, ny, nz end
	end
	return bx, by, bz
end

local function vectorUsable( v )
	return v and v.LengthSqr and v:LengthSqr() > 0.0001
end

local function isChunkCollisionOwner( ent )
	if not IsValid( ent ) then return false end
	local class = ent:GetClass()
	return class == "mc_chunk" or class == "mc_chunk_phys"
end

-- march from pos along dir and return the first non-air cell, or nil
local function firstSolidCellAlong( pos, dir, maxBlocks )
	if not vectorUsable( dir ) then return nil end
	local step = Vector( dir.x, dir.y, dir.z )
	step:Normalize()
	step:Mul( MC.BS * 0.5 )
	local probe = Vector( pos.x, pos.y, pos.z )
	for _ = 1, maxBlocks * 2 do
		local bx, by, bz = MC.WorldToCell( probe )
		if MC.GetBlock( bx, by, bz ) ~= 0 then return bx, by, bz end
		probe:Add( step )
	end
	return nil
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

	if vectorUsable( pos ) then
		local force = dmg:GetDamageForce()
		if vectorUsable( force ) then
			force = Vector( force.x, force.y, force.z )
			force:Normalize()
			local bx, by, bz = MC.WorldToCell( pos + force * TRACE_INSET )
			if MC.GetBlock( bx, by, bz ) ~= 0 then return bx, by, bz end
		end
		local bx, by, bz = MC.WorldToCell( pos )
		if MC.GetBlock( bx, by, bz ) ~= 0 then return bx, by, bz end
		-- the reported point sits on the surface but maps to air (typical for
		-- impact/melee damage with no useful force direction): probe toward the
		-- chunk for the nearest solid cell
		if IsValid( ent ) and ent.NearestPoint then
			local sx, sy, sz = firstSolidCellAlong( pos, ent:NearestPoint( pos ) - pos, 3 )
			if sx then return sx, sy, sz end
		end
		return bx, by, bz
	end

	-- no damage position at all (scripted ent:TakeDamage, fire, crush, ...):
	-- approach the chunk from the inflictor/attacker and take the first solid cell
	local inflictor = dmg:GetInflictor()
	local from
	if IsValid( inflictor ) and not isChunkCollisionOwner( inflictor ) then
		from = inflictor:GetPos()
	elseif IsValid( attacker ) and not isChunkCollisionOwner( attacker ) then
		from = attacker.EyePos and attacker:EyePos() or attacker:GetPos()
	end
	if not from or not IsValid( ent ) or not ent.NearestPoint then return nil end

	local target = ent:NearestPoint( from )
	return firstSolidCellAlong( target, target - from, 16 )
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
	if not isChunkCollisionOwner( ent ) then return false end
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
	if not isChunkCollisionOwner( ent ) then return false end
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
