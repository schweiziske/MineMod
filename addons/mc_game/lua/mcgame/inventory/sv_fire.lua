-- Server-authoritative flint-and-steel interaction for external item addons.
-- Placement mirrors Java 26.2 BaseFireBlock/FireBlock survival and state
-- selection. Nether-portal creation is deliberately absent because MCSWEP has
-- no portal subsystem; an unsupported portal frame must not make invalid fire
-- survive silently.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
SV.CombatDamageContexts = SV.CombatDamageContexts or setmetatable( {}, { __mode = "k" } )
SV.CombatDamageContextStacks = SV.CombatDamageContextStacks or setmetatable( {}, { __mode = "k" } )

-- EntityTakeDamage can expose a second Lua userdata wrapper for the same
-- underlying CTakeDamageInfo. Keep the direct weak-key lookup for the common
-- case and a synchronous per-target stack for that wrapper boundary.
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

local FIRE_CONTACT_INTERVAL = 0.5
local FIRE_SECONDS = 8
local FLAMMABLE = MC.GeneratedFireFlammableBlocks or {}

local function modifiedIgnitionSeconds( entity, seconds, context )
	seconds = math.max( 0, tonumber( seconds ) or 0 )
	context = istable( context ) and context or {}
	context.requestedIgnitionSeconds = context.requestedIgnitionSeconds or seconds
	local modified = MC.RunEvent and MC.RunEvent(
		"MC.ModifyEntityIgnitionDuration", entity, seconds, context ) or nil
	context.ignitionDurationModified = true
	if modified ~= nil then seconds = math.max( 0, tonumber( modified ) or seconds ) end
	context.modifiedIgnitionSeconds = seconds
	return seconds, context
end
local SOUL_BASE = {
	["minecraft:soul_sand"] = true,
	["minecraft:soul_soil"] = true,
}
local CAMPFIRE = {
	["minecraft:campfire"] = true,
	["minecraft:soul_campfire"] = true,
}
local CANDLE = { ["minecraft:candle"] = true }
local CANDLE_CAKE = { ["minecraft:candle_cake"] = true }
for _, colour in ipairs( {
	"white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
	"light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black",
} ) do
	CANDLE["minecraft:" .. colour .. "_candle"] = true
	CANDLE_CAKE["minecraft:" .. colour .. "_candle_cake"] = true
end

local FIRE_NEIGHBOURS = {
	{ property = "north", dx = 0, dy = -1, dz = 0 },
	{ property = "east", dx = 1, dy = 0, dz = 0 },
	{ property = "south", dx = 0, dy = 1, dz = 0 },
	{ property = "west", dx = -1, dy = 0, dz = 0 },
	{ property = "up", dx = 0, dy = 0, dz = 1 },
}
local SURVIVAL_NEIGHBOURS = {
	{ 0, -1, 0 }, { 1, 0, 0 }, { 0, 1, 0 },
	{ -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
}

local function blockMcidAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then return nil, stateId end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId )
		or MC.GetBlock and MC.GetBlock( bx, by, bz )
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	return block and block.mcid or nil, stateId
end

local function faceStep( aim )
	local normal = aim and ( aim.HitNormal or aim.Normal ) or nil
	if not normal then return 0, 0, 1 end
	local ax, ay, az = math.abs( normal.x or 0 ), math.abs( normal.y or 0 ), math.abs( normal.z or 0 )
	if ax >= ay and ax >= az then return normal.x >= 0 and 1 or -1, 0, 0 end
	if ay >= ax and ay >= az then return 0, normal.y >= 0 and 1 or -1, 0 end
	return 0, 0, normal.z >= 0 and 1 or -1
end

local function canLightState( stateId )
	if not stateId or stateId == 0 or not MC.GetStateProperty then return false end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	local mcid = block and block.mcid or nil
	if MC.GetStateProperty( stateId, "lit" ) ~= false then return false end
	if CAMPFIRE[mcid] or CANDLE[mcid] then
		return MC.GetStateProperty( stateId, "waterlogged" ) == false
	end
	return CANDLE_CAKE[mcid] == true
end

local function litState( stateId )
	if not canLightState( stateId ) or not MC.StateWith then return nil end
	return MC.StateWith( stateId, "lit", true )
end

-- Ignition and the FireBlock tick must agree on what keeps fire alive, or a
-- fire can be lit somewhere the very next tick deletes it. The engine owns
-- these rules (mc/functional/sv_fire_block.lua); the local bodies below are
-- only a fallback for an engine build that predates them.
local function isFlammableAt( bx, by, bz )
	if MC.FireIsFlammableAt then return MC.FireIsFlammableAt( bx, by, bz ) end
	local mcid = blockMcidAt( bx, by, bz )
	return mcid ~= nil and FLAMMABLE[mcid] == true
end

local function topFaceSturdyAt( bx, by, bz )
	if MC.FireTopFaceSturdyAt then return MC.FireTopFaceSturdyAt( bx, by, bz ) end
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then return false end
	local liquid = MC.Liquid
	if liquid and liquid.FaceSturdyForFlow then
		return liquid.FaceSturdyForFlow( stateId, bx, by, bz, liquid.FACE_TOP or 1 ) == true
	end
	return MC.BlockIsFullCubeForState
		and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true or false
end

local function normalFireCanSurvive( bx, by, bz )
	if MC.FireCanSurvive then return MC.FireCanSurvive( bx, by, bz ) end
	if topFaceSturdyAt( bx, by, bz - 1 ) then return true end
	for _, offset in ipairs( SURVIVAL_NEIGHBOURS ) do
		if isFlammableAt( bx + offset[1], by + offset[2], bz + offset[3] ) then return true end
	end
	return false
end

local function normalFireState( bx, by, bz )
	local stateId = MC.ParseBlockState and MC.ParseBlockState( "minecraft:fire" ) or nil
	if not stateId then return nil end
	-- FireBlock#getStateForPlacement returns the default state when the block
	-- below burns or has a sturdy upper face. Directional arms are only derived
	-- when a side/up neighbour is what keeps the fire alive.
	if isFlammableAt( bx, by, bz - 1 ) or topFaceSturdyAt( bx, by, bz - 1 ) then return stateId end
	if not MC.StateWith then return stateId end
	for _, neighbour in ipairs( FIRE_NEIGHBOURS ) do
		local burns = isFlammableAt( bx + neighbour.dx, by + neighbour.dy, bz + neighbour.dz )
		stateId = MC.StateWith( stateId, neighbour.property, burns ) or stateId
	end
	return stateId
end

local function fireStateAt( bx, by, bz )
	local belowMcid = blockMcidAt( bx, by, bz - 1 )
	if SOUL_BASE[belowMcid] then
		return MC.ParseBlockState and MC.ParseBlockState( "minecraft:soul_fire" ) or nil,
			"minecraft:soul_fire"
	end
	if not normalFireCanSurvive( bx, by, bz ) then return nil, "fire_cannot_survive" end
	return normalFireState( bx, by, bz ), "minecraft:fire"
end

local function ignitionResult( bx, by, bz, stateId, source, oldStateId )
	return {
		bx = bx, by = by, bz = bz,
		stateId = stateId,
		oldStateId = oldStateId or 0,
		source = source,
	}
end

local function commitState( ply, bx, by, bz, stateId, source, beforePublish )
	if not stateId or stateId == 0 then return false, "invalid_fire_state" end
	if not SV.PlaceState then return false, "world_api_unavailable" end
	local placed, transaction = SV.PlaceState( ply, bx, by, bz, stateId, {
		beforePublish = beforePublish,
		playerPlacementEvent = true,
	} )
	if placed ~= true then
		return false, transaction and transaction.error or "ignite_rejected"
	end
	if MC.RunEvent then MC.RunEvent( "MC.PlayerIgnitedBlock", ply, bx, by, bz, stateId, source ) end
	local result = ignitionResult( bx, by, bz, stateId, source, 0 )
	result.transaction = transaction
	return true, result
end

-- Internal helpers are named for focused regression tests and other MCSWEP
-- modules. External addons still use only MC.API.Fire.Ignite.
SV.CanLightBlockState = canLightState
SV.FireStateAt = fireStateAt

function SV.ResolvePlayerIgnition( ply, context )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	local reach = tonumber( context and context.reach )
	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply, reach ) or nil
	if not aim then return false, "no_block_target" end
	local bx, by, bz = math.floor( aim.bx or 0 ), math.floor( aim.by or 0 ), math.floor( aim.bz or 0 )
	local clickedState = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if clickedState == 0 then return false, "no_block_target" end

	local nextLit = litState( clickedState )
	if nextLit then
		if not SV.Validate or not SV.Validate( ply, bx, by, bz, false ) then return false, "ignite_rejected" end
		return true, ignitionResult( bx, by, bz, nextLit, "lit_property", clickedState )
	end

	local dx, dy, dz = faceStep( aim )
	local tx, ty, tz = bx + dx, by + dy, bz + dz
	if ( MC.GetBlockState and MC.GetBlockState( tx, ty, tz ) or 0 ) ~= 0 then return false, "target_not_air" end
	local fireState, fireNameOrError = fireStateAt( tx, ty, tz )
	if not fireState then return false, fireNameOrError or "fire_cannot_survive" end
	return true, ignitionResult( tx, ty, tz, fireState, fireNameOrError, 0 )
end

function SV.CommitPlayerIgnition( ply, plan, beforePublish )
	if not istable( plan ) then return false, "invalid_ignition_plan" end
	local bx, by, bz = math.floor( tonumber( plan.bx ) or 0 ),
		math.floor( tonumber( plan.by ) or 0 ), math.floor( tonumber( plan.bz ) or 0 )
	local stateId = math.floor( tonumber( plan.stateId ) or 0 )
	local oldStateId = math.floor( tonumber( plan.oldStateId ) or 0 )
	local source = tostring( plan.source or "")
	if stateId <= 0 or source == "" then return false, "invalid_ignition_plan" end

	if oldStateId == 0 then return commitState( ply, bx, by, bz, stateId, source, beforePublish ) end
	if not SV.SetBlockState then return false, "world_api_unavailable" end
	if ( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 ) ~= oldStateId then
		return false, "ignition_target_changed"
	end
	local transaction = SV.SetBlockState( bx, by, bz, stateId, {
		actor = ply,
		priorityPhys = true,
		blockUpdates = true,
		beforePublish = beforePublish,
	} )
	if not transaction or transaction.ok ~= true or transaction.changed <= 0 then
		return false, transaction and transaction.error or "ignite_rejected"
	end
	if MC.RunEvent then MC.RunEvent( "MC.PlayerIgnitedBlock", ply, bx, by, bz, stateId, source ) end
	local result = ignitionResult( bx, by, bz, stateId, source, oldStateId )
	result.transaction = transaction
	return true, result
end

function SV.IgnitePlayerAim( ply, context )
	local resolved, planOrError = SV.ResolvePlayerIgnition( ply, context )
	if resolved ~= true then return false, planOrError end
	return SV.CommitPlayerIgnition( ply, planOrError )
end

local function playFlintAndSteelSound( result )
	if not result or not MC.PlayJavaSoundEvent or not MC.CellWorldCenter then return end
	MC.PlayJavaSoundEvent(
		"item.flintandsteel.use",
		MC.CellWorldCenter( result.bx, result.by, result.bz ),
		1,
		0.8 + math.Rand( 0, 1 ) * 0.4,
		72
	)
end

function SV.UseSelectedFlintAndSteel( ply, context )
	context = istable( context ) and context or {}
	local matchContext = {
		expectedItem = "minecraft:flint_and_steel",
		expectedClass = context.expectedClass,
		expectedStackHash = context.expectedStackHash,
	}
	if not SV.SelectedStackMatches then return false, "selected_item_unavailable" end
	local record, _, selected, matchError = SV.SelectedStackMatches( ply, matchContext )
	if not record then return false, matchError or "selected_item_unavailable" end
	matchContext.expectedStackHash = MC.ItemStackHash and MC.ItemStackHash( selected ) or nil

	local resolved, planOrError = SV.ResolvePlayerIgnition( ply, context )
	if resolved ~= true then return false, planOrError end

	local durabilityResult, broken, infinite
	local function commitDurability()
		local result, didBreak, err = SV.DamageSelectedItem( ply, 1, {
			expectedItem = matchContext.expectedItem,
			expectedClass = matchContext.expectedClass,
			expectedStackHash = matchContext.expectedStackHash,
			reason = context.reason or "flint_and_steel_use",
			actionId = context.actionId,
		} )
		if result then
			durabilityResult, broken = result, didBreak == true
			return true, { durability = result, broken = broken, infinite = false }
		end
		if err == "infinite_materials" then
			infinite = true
			return true, { infinite = true, broken = false }
		end
		return false, err or "durability_commit_failed"
	end

	local committed, resultOrError = SV.CommitPlayerIgnition( ply, planOrError, commitDurability )
	if committed ~= true then return false, resultOrError end
	resultOrError.durability = durabilityResult
	resultOrError.broken = broken == true
	resultOrError.infinite = infinite == true
	playFlintAndSteelSound( resultOrError )
	return true, resultOrError
end

-- Projectile.mayInteract: player-owned projectiles respect world protection,
-- while ownerless/non-player projectiles retain Java's default mobGriefing=true
-- behavior. Reach and use cooldown are deliberately not revalidated here.
function SV.ProjectileMayInteract( projectile, bx, by, bz )
	local owner = IsValid( projectile ) and projectile:GetOwner() or nil
	if not IsValid( owner ) or not owner:IsPlayer() then return true end
	if SV.WorldBoundsOK and not SV.WorldBoundsOK( bx, by, bz ) then return false end
	if SV.CanEdit and not SV.CanEdit( owner ) then return false end
	if MC.RunEvent and MC.RunEvent( "MC.CanPlayerEditCell", owner, bx, by, bz, false ) == false then
		return false
	end
	return true
end

-- Server-owned projectile fire placement.  This is deliberately narrower than
-- World.SetBlock: the caller supplies an actual block-impact point/normal, and
-- this module owns clicked-cell validation, adjacent-air selection, edit
-- protection, BaseFireBlock state selection and the final transaction.
function SV.IgniteProjectileImpact( projectile, hitPos, hitNormal, context )
	if not IsValid( projectile ) then return false, "invalid_projectile" end
	if not isvector( hitPos ) or not isvector( hitNormal ) then return false, "invalid_impact" end
	if not MC.WorldToCell or not MC.GetBlockState then return false, "world_api_unavailable" end
	if not SV.SetBlockState then return false, "world_api_unavailable" end

	local normal = Vector( hitNormal.x, hitNormal.y, hitNormal.z )
	if normal:LengthSqr() <= 0.000001 then return false, "invalid_impact_normal" end
	normal:Normalize()
	local epsilon = math.max( ( MC.BS or 36.5 ) / 4096, 0.01 )
	local bx, by, bz = MC.WorldToCell( hitPos - normal * epsilon )
	if ( MC.GetBlockState( bx, by, bz ) or 0 ) == 0 then
		-- Source map/prop impacts are not Minecraft BlockHits and cannot create a
		-- voxel fire block merely because they happen to overlap an empty cell.
		return false, "no_minecraft_block_target"
	end

	local dx, dy, dz = faceStep( { HitNormal = normal } )
	local tx, ty, tz = bx + dx, by + dy, bz + dz
	if ( MC.GetBlockState( tx, ty, tz ) or 0 ) ~= 0 then return false, "target_not_air" end
	if not SV.ProjectileMayInteract( projectile, tx, ty, tz ) then return false, "edit_rejected" end

	local stateId, fireNameOrError = fireStateAt( tx, ty, tz )
	if not stateId then return false, fireNameOrError or "fire_cannot_survive" end
	local owner = projectile:GetOwner()
	local transaction = SV.SetBlockState( tx, ty, tz, stateId, {
		actor = IsValid( owner ) and owner:IsPlayer() and owner or nil,
		priorityPhys = true,
		compareCollision = true,
		blockUpdates = true,
	} )
	if not transaction or transaction.ok ~= true or transaction.changed <= 0 then
		return false, transaction and transaction.error or "ignite_rejected"
	end

	context = istable( context ) and context or {}
	return true, {
		bx = tx, by = ty, bz = tz,
		stateId = stateId,
		source = fireNameOrError,
		reason = tostring( context.reason or "projectile_impact" ),
		transaction = transaction,
	}
end

hook.Add( "MC.ProjectileImpact", "mc_campfire_burning_projectile", function( projectile, trace )
	if not IsValid( projectile ) or not trace or not trace.HitPos or not MC.WorldToCell then return end
	local burning = projectile:IsOnFire()
		or projectile.GetProjectileOnFire and projectile:GetProjectileOnFire() == true
		or projectile.MCOnFire == true
	if not burning then return end
	local normal = trace.HitNormal or vector_origin
	local bx, by, bz = MC.WorldToCell( trace.HitPos - normal * 0.5 )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	local info = MC.CampfireStateInfo and MC.CampfireStateInfo( stateId ) or nil
	if not info or not canLightState( stateId ) or not SV.ProjectileMayInteract( projectile, bx, by, bz ) then return end
	local nextState = MC.StateWith and MC.StateWith( stateId, "lit", true ) or nil
	if not nextState or nextState == stateId or not SV.SetBlockState then return end
	SV.SetBlockState( bx, by, bz, nextState, {
		actor = nil,
		fx = false,
		compareCollision = true,
		blockUpdates = true,
	} )
end )

local function contactInfo( stateId )
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	local name = block and block.mcid or nil
	if name == "minecraft:fire" then return 1, true, "minecraft:in_fire" end
	if name == "minecraft:soul_fire" then return 2, true, "minecraft:in_fire" end
	if name == "minecraft:campfire" or name == "minecraft:soul_campfire" then
		if not MC.GetStateProperty or MC.GetStateProperty( stateId, "lit" ) ~= true then return nil end
		return name == "minecraft:soul_campfire" and 2 or 1, false, "minecraft:campfire"
	end
	return nil
end

local function damageableLivingEntity( entity )
	if not IsValid( entity ) then return false end
	if entity:IsPlayer() then return entity:Alive() and entity:GetMoveType() ~= MOVETYPE_NOCLIP end
	if entity:IsNPC() or entity:IsNextBot() then return entity.Health and entity:Health() > 0 end
	return false
end

local function entityContactCells( entity )
	local minimum, maximum
	if MC.EntityWorldAABB then minimum, maximum = MC.EntityWorldAABB( entity )
	else minimum, maximum = entity:WorldSpaceAABB() end
	local epsilon = math.max( ( MC.BS or 36.5 ) / 4096, 0.01 )
	local minX, minY, minZ = MC.WorldToCell( minimum + Vector( epsilon, epsilon, epsilon ) )
	local maxX, maxY, maxZ = MC.WorldToCell( maximum - Vector( epsilon, epsilon, epsilon ) )
	return minX, minY, minZ, maxX, maxY, maxZ
end

local function applyFireContact( entity, damage, ignite, damageTypeId )
	-- BMB scans minecraft:fire/soul_fire itself and owns the corresponding
	-- Minecraft fire state. Letting this generic Source adapter also Ignite and
	-- damage it creates two flame renderers and two damage clocks. Campfires use
	-- ignite=false and still keep their independent contact damage below.
	if entity.IsBMBMob == true and ignite then
		entity.MCNextFireContactDamage = nil
		return
	end
	local current = CurTime()
	if current < ( entity.MCNextFireContactDamage or 0 ) then return end
	entity.MCNextFireContactDamage = current + FIRE_CONTACT_INTERVAL
	-- BaseFireBlock applies FIRE_IGNITE before its in-fire damage callback.
	if ignite and entity.Ignite then
		local ignitionContext = {
			source = "fire_block",
			damageTypeId = tostring( damageTypeId or "minecraft:in_fire" ),
			environmental = true,
		}
		local seconds = modifiedIgnitionSeconds( entity, FIRE_SECONDS, ignitionContext )
		if seconds > 0 then
			-- Let game-layer consumers (Fire Protection/BMB's independent fire
			-- clock) handle the same ignition boundary used by projectiles.  A
			-- listener returning false is an explicit rejection and must not fall
			-- through to Source Ignite; only an absent listener (nil) preserves
			-- the legacy Source fallback for addons that do not provide a clock.
			local handled
			if MC.RunEvent then
				handled = MC.RunEvent( "MC.IgniteEntity", entity, seconds, ignitionContext )
			end
			if handled == nil then entity:Ignite( seconds, 0 ) end
		end
	end
	local info = DamageInfo()
	info:SetDamage( damage )
	info:SetDamageType( DMG_BURN or DMG_SLOWBURN or 8 )
	info:SetAttacker( game.GetWorld() )
	info:SetInflictor( game.GetWorld() )
	info:SetDamagePosition( entity:WorldSpaceCenter() )
	local metadata = {
		damageTypeId = tostring( damageTypeId or "minecraft:in_fire" ),
		environmental = true,
	}
	SV.PushCombatDamageContext( entity, info, metadata )
	local wasEnvironmental = entity.BMBEnvironmentalDamageActive
	if entity.IsBMBMob == true then entity.BMBEnvironmentalDamageActive = true end
	local ok, err = pcall( entity.TakeDamageInfo, entity, info )
	SV.PopCombatDamageContext( entity, info, metadata )
	if IsValid( entity ) and entity.IsBMBMob == true then
		entity.BMBEnvironmentalDamageActive = wasEnvironmental
	end
	if not ok then ErrorNoHalt( "[MC] fire contact damage failed: " .. tostring( err ) .. "\n" ) end
end

local function scanFireContacts()
	if not MC.WorldToCell or not MC.GetBlockState then return end
	for _, entity in ipairs( ents.GetAll() ) do
		if damageableLivingEntity( entity ) then
			local minX, minY, minZ, maxX, maxY, maxZ = entityContactCells( entity )
			local bestDamage, shouldIgnite, bestDamageTypeId
			for bx = minX, maxX do
				for by = minY, maxY do
					for bz = minZ, maxZ do
						local damage, ignite, damageTypeId = contactInfo( MC.GetBlockState( bx, by, bz ) )
						if damage and ( not bestDamage or damage > bestDamage ) then
							bestDamage, shouldIgnite, bestDamageTypeId = damage, ignite, damageTypeId
						end
					end
				end
			end
			if bestDamage then
				applyFireContact( entity, bestDamage, shouldIgnite, bestDamageTypeId )
			end
		end
	end
end

timer.Create( "mc_fire_campfire_entity_contact", 0.1, 0, scanFireContacts )
