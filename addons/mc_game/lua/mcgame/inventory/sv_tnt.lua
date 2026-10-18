-- Server-authoritative TNT block priming. Mirrors Java 26.2 TntBlock:
-- redstone/on-place, flint and steel, fire charge, burning projectiles,
-- unstable survival breaking, and fire consuming a TNT block.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

local function tntAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	return stateName( stateId ) == "minecraft:tnt", stateId
end

local function centerAt( bx, by, bz )
	local minimum = MC.CellWorldMin and MC.CellWorldMin( bx, by, bz )
		or Vector( bx * ( MC.BS or 36.5 ), by * ( MC.BS or 36.5 ), bz * ( MC.BS or 36.5 ) )
	local half = ( tonumber( MC.BS ) or 36.5 ) * 0.5
	return minimum + Vector( half, half, 0 )
end

local function createPendingPrimed( bx, by, bz, source )
	if not ents or not ents.Create then return nil, "primed_tnt_entity_unavailable" end
	local ent = ents.Create( "mc_primed_tnt" )
	if not IsValid( ent ) then return nil, "primed_tnt_entity_unavailable" end
	-- ApplyMinecraftExplosion forwards options.source as the damage inflictor.
	-- This marker lets BlockAttachedEntity#ignoreExplosion distinguish that exact
	-- direct source from the indirect actor fallback used by source-less blasts.
	ent.MCExplosionDirectSource = true
	local position = centerAt( bx, by, bz )
	if MC.SetEntityEnginePos then MC.SetEntityEnginePos( ent, position ) else ent:SetPos( position ) end
	ent:SetOwner( IsValid( source ) and source or NULL )
	ent.MCExplosionOwner = IsValid( source ) and source or nil
	ent:Spawn()
	ent:Activate()
	return ent
end

local function armPrimed( ent, bx, by, bz, source, options )
	options = istable( options ) and options or {}
	local fuse = math.max( 1, math.floor( tonumber( options.fuse ) or 80 ) )
	local armed, armError
	if ent.ArmMinecraftTnt then
		armed, armError = ent:ArmMinecraftTnt( {
			fuse = fuse,
			power = math.Clamp( tonumber( options.power ) or 4, 0, 128 ),
			velocity = options.velocity,
		} )
	else
		ent:SetFuseTicks( fuse )
		ent:SetExplosionPower( math.Clamp( tonumber( options.power ) or 4, 0, 128 ) )
		if ent.SetArmed then ent:SetArmed( true ) end
		armed = true
	end
	if armed ~= true then return false, armError or "primed_tnt_arm_failed" end
	if options.silent ~= true and MC.PlayJavaSoundEvent then
		local position = MC.EntityWorldPos and MC.EntityWorldPos( ent ) or ent:GetPos()
		MC.PlayJavaSoundEvent( "entity.tnt.primed", position, 1, 1, 80 )
	end
	return true, ent
end

local function spawnPrimed( bx, by, bz, source, options )
	local ent, createError = createPendingPrimed( bx, by, bz, source )
	if not ent then return nil, createError end
	local armed, armError = armPrimed( ent, bx, by, bz, source, options )
	if armed ~= true then ent:Remove() return nil, armError end
	return ent
end

function SV.SpawnPrimedTnt( bx, by, bz, source, options )
	return spawnPrimed(
		math.floor( tonumber( bx ) or 0 ),
		math.floor( tonumber( by ) or 0 ),
		math.floor( tonumber( bz ) or 0 ),
		source,
		options
	)
end

function SV.PrimeTntBlock( bx, by, bz, source, options )
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	local isTnt, stateId = tntAt( bx, by, bz )
	if not isTnt then return false, "not_tnt" end
	options = istable( options ) and options or {}
	-- Construct the entity first, but keep it unarmed and invisible until the
	-- authoritative voxel transaction succeeds. A failed removal can therefore
	-- never consume the block and then discover that the entity class is absent.
	local ent, createError = createPendingPrimed( bx, by, bz, source )
	if not ent then return false, createError end
	local result = SV.SetBlockState and SV.SetBlockState( bx, by, bz, 0, {
		-- TntBlock.useItemOn/removeBlock is not playerWillDestroy. Keeping actor
		-- nil also prevents an unstable TNT OnRemoved hook from double-priming.
		actor = nil,
		fx = false,
		handlers = options.handlers ~= false,
		compareCollision = true,
		priorityPhys = true,
		immediatePhys = true,
		beforePublish = options.beforePublish,
	} ) or nil
	if not result or result.ok ~= true or result.changed <= 0 then
		if IsValid( ent ) then ent:Remove() end
		return false, result and result.error or "tnt_remove_failed"
	end
	local armed, armError = armPrimed( ent, bx, by, bz, source, options )
	if armed ~= true then
		if IsValid( ent ) then ent:Remove() end
		return false, armError
	end
	return true, ent, result, stateId
end

-- SV.Validate CONSUMES a world-write cooldown (ply.mcNextOp = now + 0.03), so a
-- second call for the same press always fails. Reaching this through the block
-- OnUse handler means SV.Use has already validated this exact cell for this
-- exact player, and re-validating turned the whole interaction into
-- "ignite_rejected": right-clicking TNT did nothing at all, while sneaking
-- worked because that path skips SV.Use and validates only once.
-- Same class of bug as the SV.ValidateBreakTarget note in sv_world.lua.
local function selectedTntTarget( ply, alreadyValidated )
	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
	if not aim then return nil, "no_block_target" end
	local bx, by, bz = math.floor( aim.bx or 0 ), math.floor( aim.by or 0 ), math.floor( aim.bz or 0 )
	if not tntAt( bx, by, bz ) then return nil, "not_tnt" end
	if not alreadyValidated
	and ( not SV.Validate or not SV.Validate( ply, bx, by, bz, false ) ) then
		return nil, "ignite_rejected"
	end
	return { bx = bx, by = by, bz = bz }
end

local function useTntWithSelectedItem( ply, itemName, context )
	context = istable( context ) and context or {}
	if not SV.SelectedStackMatches then return false, "selected_item_unavailable" end
	local record, _, selected, matchError = SV.SelectedStackMatches( ply, {
		expectedItem = itemName,
		hand = context.hand,
		expectedClass = context.expectedClass,
		expectedStackHash = context.expectedStackHash,
	} )
	if not record then return false, matchError or "selected_item_unavailable" end
	local target, targetError = selectedTntTarget( ply, context.alreadyValidated == true )
	if not target then return false, targetError end
	local selectedHash = MC.ItemStackHash and MC.ItemStackHash( selected ) or nil
	local inventoryResult, broken, infinite
	local function mutateInventory()
		if itemName == "minecraft:flint_and_steel" then
			local result, didBreak, err = SV.DamageSelectedItem( ply, 1, {
				expectedItem = itemName,
				hand = context.hand,
				expectedClass = context.expectedClass,
				expectedStackHash = selectedHash,
				reason = context.reason or "tnt_flint_and_steel",
				actionId = context.actionId,
			} )
			if result then inventoryResult, broken = result, didBreak == true return true end
			if err == "infinite_materials" then infinite = true return true end
			return false, err or "durability_commit_failed"
		end
		local result, _, _, isInfinite, err = SV.ConsumeSelectedItem( ply, 1, nil, {
			expectedItem = itemName,
			hand = context.hand,
			expectedClass = context.expectedClass,
			expectedStackHash = selectedHash,
			reason = context.reason or "tnt_fire_charge",
			actionId = context.actionId,
		} )
		if result then inventoryResult, infinite = result, isInfinite == true return true end
		return false, err or "fire_charge_consume_failed"
	end
	local primed, entOrError = SV.PrimeTntBlock( target.bx, target.by, target.bz, ply, {
		beforePublish = mutateInventory,
	} )
	if not primed then return false, entOrError end
	return true, {
		entity = entOrError,
		inventory = inventoryResult,
		broken = broken == true,
		infinite = infinite == true,
	}
end

function SV.UseTntWithFlintAndSteel( ply, context )
	return useTntWithSelectedItem( ply, "minecraft:flint_and_steel", context )
end

function SV.UseTntWithFireCharge( ply, context )
	return useTntWithSelectedItem( ply, "minecraft:fire_charge", context )
end

local oldFlint = SV.UseSelectedFlintAndSteel
SV.UseSelectedFlintAndSteel = function( ply, context )
	local used, result = SV.UseTntWithFlintAndSteel( ply, context )
	if used or result ~= "not_tnt" then return used, result end
	if oldFlint then return oldFlint( ply, context ) end
	return false, "fire_api_unavailable"
end

function SV.UseSelectedFireCharge( ply, context )
	local used, result = SV.UseTntWithFireCharge( ply, context )
	if used or result ~= "not_tnt" then return used, result end
	-- FireChargeItem uses the same fire placement rules, consumes one item and
	-- plays its own event. Keep the world+inventory transition atomic.
	context = istable( context ) and context or {}
	local record, _, selected, matchError = SV.SelectedStackMatches( ply, {
		expectedItem = "minecraft:fire_charge",
		hand = context.hand,
		expectedClass = context.expectedClass,
		expectedStackHash = context.expectedStackHash,
	} )
	if not record then return false, matchError end
	local resolved, planOrError = SV.ResolvePlayerIgnition( ply, context )
	if resolved ~= true then return false, planOrError end
	local selectedHash = MC.ItemStackHash and MC.ItemStackHash( selected ) or nil
	local inventoryResult, infinite
	local function consume()
		local result, _, _, isInfinite, err = SV.ConsumeSelectedItem( ply, 1, nil, {
			expectedItem = "minecraft:fire_charge",
			hand = context.hand,
			expectedClass = context.expectedClass,
			expectedStackHash = selectedHash,
			reason = context.reason or "fire_charge_use",
			actionId = context.actionId,
		} )
		if result then inventoryResult, infinite = result, isInfinite == true return true end
		return false, err or "fire_charge_consume_failed"
	end
	local committed, fireResult = SV.CommitPlayerIgnition( ply, planOrError, consume )
	if not committed then return false, fireResult end
	if MC.PlayJavaSoundEvent then
		MC.PlayJavaSoundEvent( "item.firecharge.use", MC.CellWorldCenter( fireResult.bx, fireResult.by, fireResult.bz ),
			1, 0.8 + math.Rand( 0, 1 ) * 0.4, 72 )
	end
	fireResult.inventory, fireResult.infinite = inventoryResult, infinite == true
	return true, fireResult
end

-- TntBlock#useItemOn: flint and steel / fire charge prime the block instead of
-- doing whatever the item normally does.
--
-- This used to read MC.BlockByName once at load time and silently do nothing if
-- the block was not registered yet. When that happened the handlers were simply
-- absent, so blockHasUse() said "no interaction here", the held flint and steel
-- fell through to its own ignition, and right-clicking TNT placed fire next to
-- it instead of priming it. Retry until the block exists, the way
-- mc_item_hand installs its food preflight.
local function installTntBlockHandlers()
	local tntBlock = MC.BlockByName and MC.BlockByName["minecraft:tnt"] or nil
	if not tntBlock then return false end
	if tntBlock.MCTntUseHandlersInstalled == true then return true end

	tntBlock.handlers = tntBlock.handlers or {}
	local previousRemoved = tntBlock.handlers.OnRemoved
	tntBlock.handlers.OnRemoved = function( context, stateId )
		if previousRemoved then previousRemoved( context, stateId ) end
		local actor = context.actor
		if not IsValid( actor ) or not actor:IsPlayer() then return end
		if SV.PlayerIsCreative and SV.PlayerIsCreative( actor ) then return end
		if MC.GetStateProperty and MC.GetStateProperty( stateId, "unstable" ) == true then
			spawnPrimed( context.bx, context.by, context.bz, actor )
		end
	end
	tntBlock.handlers.CanUse = function( stack )
		return stack and ( stack.item == "minecraft:flint_and_steel" or stack.item == "minecraft:fire_charge" ) or false
	end
	tntBlock.handlers.OnUse = function( ply, bx, by, bz, orient, blockId, useContext )
		local stack = SV.GetPlayerHandStack( ply, useContext and useContext.hand )
		if not stack then return false end
		-- SV.Use validated this cell for this player immediately before calling
		-- us, and that validation consumed the world-write cooldown.
		local context = { alreadyValidated = true, reason = "tnt_block_use", hand = useContext and useContext.hand }
		if stack.item == "minecraft:flint_and_steel" then return SV.UseTntWithFlintAndSteel( ply, context ) == true end
		if stack.item == "minecraft:fire_charge" then return SV.UseTntWithFireCharge( ply, context ) == true end
		return false
	end

	tntBlock.MCTntUseHandlersInstalled = true
	return true
end

if not installTntBlockHandlers() and timer then
	timer.Create( "mc_tnt_use_handlers", 0.5, 20, function()
		if installTntBlockHandlers() then timer.Remove( "mc_tnt_use_handlers" ) end
	end )
end
hook.Add( "OnReloaded", "mc_tnt_use_handlers", installTntBlockHandlers )

MC.RegisterBlockUpdateHandler( "minecraft:tnt", {
	OnNeighborUpdate = function( context )
		if MC.RedstoneBestNeighborSignal and MC.RedstoneBestNeighborSignal( context.bx, context.by, context.bz ) > 0 then
			SV.PrimeTntBlock( context.bx, context.by, context.bz, nil )
		end
		return nil
	end,
} )

-- Projectile#mayInteract delegates player-owned projectiles to the owner's
-- world-protection check, while ownerless projectiles are allowed (and mobs
-- are governed by mobGriefing in Java). MCSWEP has no mob-griefing gamerule,
-- so preserve its default-true behavior and apply the existing edit vetoes to
-- player owners without incorrectly re-running reach/cooldown validation at
-- the projectile's impact position.
local function projectileMayInteract( projectile, bx, by, bz )
	if SV.ProjectileMayInteract then return SV.ProjectileMayInteract( projectile, bx, by, bz ) end
	local owner = projectile:GetOwner()
	if not IsValid( owner ) or not owner:IsPlayer() then return true end
	if SV.WorldBoundsOK and not SV.WorldBoundsOK( bx, by, bz ) then return false end
	if SV.CanEdit and not SV.CanEdit( owner ) then return false end
	if MC.RunEvent and MC.RunEvent( "MC.CanPlayerEditCell", owner, bx, by, bz, false ) == false then
		return false
	end
	return true
end

hook.Add( "MC.ProjectileImpact", "mc_tnt_burning_projectile", function( projectile, trace )
	if not IsValid( projectile ) or not trace or not trace.HitPos or not MC.WorldToCell then return end
	local burning = projectile:IsOnFire()
		or projectile.GetProjectileOnFire and projectile:GetProjectileOnFire() == true
		or projectile.MCOnFire == true
	if not burning then return end
	local normal = trace.HitNormal or vector_origin
	local bx, by, bz = MC.WorldToCell( trace.HitPos - normal * 0.5 )
	if not tntAt( bx, by, bz ) then return end
	if not projectileMayInteract( projectile, bx, by, bz ) then return end
	local owner = projectile:GetOwner()
	SV.PrimeTntBlock( bx, by, bz, IsValid( owner ) and owner or nil )
end )

function SV.PrimeTntFromFire( bx, by, bz )
	return SV.PrimeTntBlock( bx, by, bz, nil )
end
