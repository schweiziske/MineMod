-- Server-owned survival mining sessions. One 20 TPS pass touches only players
-- who are actively mining; the world is never scanned. Internal mc_item_hand
-- sessions and external MC.API.Mining sessions use the same authoritative path.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local TICK_INTERVAL = 1 / 20
local CREATIVE_DESTROY_DELAY_TICKS = 5
local CREATIVE_DESTROY_DELAY = CREATIVE_DESTROY_DELAY_TICKS * TICK_INTERVAL
SV.MiningSessions = SV.MiningSessions or {}
SV.CreativeDestroyStates = SV.CreativeDestroyStates or setmetatable( {}, { __mode = "k" } )

local function safeCall( callback, ... )
	if not isfunction( callback ) then return end
	local ok, err = pcall( callback, ... )
	if not ok then ErrorNoHalt( "[MC Mining] callback failed: " .. tostring( err ) .. "\n" ) end
end

local function copyStack( stack )
	if type( stack ) ~= "table" then return nil end
	if MC.CopyItemStack then return MC.CopyItemStack( stack ) end
	return table.Copy( stack )
end

local function creativeDestroyStack( ply, options )
	options = type( options ) == "table" and options or {}
	local stack = options.toolStack or options.stack
	if type( stack ) == "table" then return stack end
	if type( options.item ) == "string" and options.item ~= "" then
		return { item = string.find( options.item, ":", 1, true )
			and options.item or "minecraft:" .. options.item, count = 1 }
	end
	return SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
end

local function currentAimAllowsBlockAttack( ply, bx, by, bz )
	if not MC.PlayerBlockAim then return true, nil end
	local aim = MC.PlayerBlockAim( ply )
	if not aim or aim.bx ~= bx or aim.by ~= by or aim.bz ~= bz then return false, "aim_changed" end
	if MC.EntityOccludesBlockAim and MC.EntityOccludesBlockAim( ply, aim ) then
		return false, "entity_occluded"
	end
	return true, aim
end

local function publicSession( session )
	if not session then return nil end
	return {
		bx = session.bx, by = session.by, bz = session.bz,
		stateId = session.stateId,
		blockId = session.blockId,
		progress = session.progress,
		stage = session.stage,
		startedAt = session.startedAt,
		source = session.source,
		sourceId = session.sourceId,
		item = session.toolStack and session.toolStack.item or nil,
		weapon = IsValid( session.weapon ) and session.weapon or nil,
		mining = session.lastMining and table.Copy( session.lastMining ) or nil,
	}
end

local function sendStage( ply, session, stage )
	if not session then return end
	net.Start( "mc_mining_progress" )
		net.WriteEntity( ply )
		net.WriteInt( session.bx, MC.Net.COORD_BITS )
		net.WriteInt( session.by, MC.Net.COORD_BITS )
		net.WriteInt( session.bz, MC.Net.COORD_BITS )
		net.WriteUInt( stage == nil and 0 or math.Clamp( stage + 1, 1, 10 ), 4 )
	net.Broadcast()
end

local function selectedFingerprint( ply )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if record and record.session then return nil, "inventory_open" end
	local selected = record and math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 ) or 0
	local stack = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
	if not stack then return tostring( selected ) .. ":empty" end
	local components = MC.CanonicalItemComponents and MC.CanonicalItemComponents( stack.components ) or ""
	return table.concat( { tostring( selected ), stack.item, tostring( stack.damage or 0 ), components }, "\0" )
end

local function normalizeExternalOptions( options )
	if type( options ) ~= "table" or options.external ~= true then return nil end
	local stack = copyStack( options.toolStack )
	if not stack and isstring( options.item ) and options.item ~= "" then
		local item = string.find( options.item, ":", 1, true ) and options.item or "minecraft:" .. options.item
		stack = { item = item, count = 1 }
	end
	return {
		toolStack = stack,
		weapon = IsValid( options.weapon ) and options.weapon or nil,
		sourceId = tostring( options.sourceId or "external" ),
		sourceToken = tostring( options.sourceToken or ( IsValid( options.weapon ) and options.weapon:EntIndex() or "external" ) ),
		requireAttackHeld = options.requireAttackHeld ~= false,
		requireAim = options.requireAim ~= false,
		modifiers = type( options.modifiers ) == "table" and table.Copy( options.modifiers ) or nil,
		onCancel = isfunction( options.onCancel ) and options.onCancel or nil,
		onComplete = isfunction( options.onComplete ) and options.onComplete or nil,
		onDurabilityDamage = isfunction( options.onDurabilityDamage ) and options.onDurabilityDamage or nil,
		validate = isfunction( options.validate ) and options.validate or nil,
	}
end

function SV.CancelMining( ply, reason )
	local session = SV.MiningSessions[ply]
	if not session then return false end
	SV.MiningSessions[ply] = nil
	sendStage( ply, session, nil )
	local snapshot = publicSession( session )
	safeCall( session.onCancel, ply, snapshot, reason or "cancelled" )
	if MC.RunEvent then MC.RunEvent( "MC.PlayerMiningCancelled", ply, snapshot, reason or "cancelled" ) end
	return true
end

function SV.GetMiningSession( ply )
	return publicSession( SV.MiningSessions[ply] )
end

-- MultiPlayerGameMode uses destroyDelay = 5 after every creative block break.
-- A fresh attack press still breaks immediately; only continueDestroyBlock is
-- throttled.  Keeping this state on the player makes mc_item_hand and external
-- MCITEM proxy SWEPs obey the same cadence even when the selected SWEP changes.
function SV.TryCreativeBreak( ply, bx, by, bz, options )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	if not ( SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) ) then return false, "not_creative" end
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	options = istable( options ) and options or {}
	local stack = creativeDestroyStack( ply, options )
	if MC.ItemCanDestroyBlocksInCreative and not MC.ItemCanDestroyBlocksInCreative( stack ) then
		if SV.CancelMining then SV.CancelMining( ply, "creative_item_cannot_destroy" ) end
		return false, "creative_item_cannot_destroy"
	end
	local aimAllowed, aimError = currentAimAllowsBlockAttack( ply, bx, by, bz )
	if not aimAllowed then
		if SV.CancelMining then SV.CancelMining( ply, aimError ) end
		return false, aimError
	end

	local now = CurTime()
	local state = SV.CreativeDestroyStates[ply]
	if not state then
		state = { nextContinueAt = 0 }
		SV.CreativeDestroyStates[ply] = state
	end
	if options.initialPress ~= true and now < ( state.nextContinueAt or 0 ) then
		return false, "creative_destroy_delay", state.nextContinueAt
	end

	state.nextContinueAt = now + CREATIVE_DESTROY_DELAY
	if SV.CancelMining then SV.CancelMining( ply, "creative_break" ) end
	if not SV.Break then return false, "break_api_unavailable" end
	return SV.Break( ply, bx, by, bz, { damageTool = false } )
end

local function spawnBlockDrops( ply, session, stacks )
	if not SV.SpawnItemDrop then return {} end
	local position = MC.CellWorldCenter and MC.CellWorldCenter( session.bx, session.by, session.bz )
		or Vector( session.bx * MC.BS, session.by * MC.BS, session.bz * MC.BS )
	local entities = {}
	for _, stack in ipairs( stacks or {} ) do
		local entity = SV.SpawnItemDrop( position, stack, ply, { pickupDelay = 0.5 } )
		if entity then entities[#entities + 1] = entity end
	end
	return entities
end

local function damageMiningTool( ply, session, oldStateId )
	local hardness = MC.BlockHardness and MC.BlockHardness( session.blockId ) or 1
	if hardness == 0 then return 0 end
	local mining = session.lastMining or ( MC.BlockMiningToolSpec and MC.BlockMiningToolSpec( oldStateId, session.toolStack ) )
	local damage = mining and mining.held
		and math.max( 0, math.floor( tonumber( mining.held.damagePerBlock ) or 0 ) ) or 0
	if damage <= 0 then return 0 end
	if session.source == "inventory" then
		if SV.DamageSelectedItem then SV.DamageSelectedItem( ply, 1, { reason = "mine", useToolScale = true } ) end
	else
		safeCall( session.onDurabilityDamage, ply, damage, {
			reason = "mine",
			bx = session.bx, by = session.by, bz = session.bz,
			stateId = oldStateId,
			item = session.toolStack and session.toolStack.item or nil,
			weapon = session.weapon,
			mining = mining and table.Copy( mining ) or nil,
		} )
	end
	return damage
end

local function completeMining( ply, session )
	local oldStateId = MC.GetBlockState and MC.GetBlockState( session.bx, session.by, session.bz ) or 0
	local stacks, dropError = {}, "block_loot_unavailable"
	if SV.ResolveBlockDrops then
		stacks, dropError = SV.ResolveBlockDrops( oldStateId, session.toolStack, {
			player = ply,
			bx = session.bx, by = session.by, bz = session.bz,
			blockEntity = MC.GetBlockEntity
				and MC.GetBlockEntity( session.bx, session.by, session.bz ) or nil,
		} )
	end
	local broke, result = SV.Break( ply, session.bx, session.by, session.bz, { damageTool = false } )
	if not broke then
		SV.CancelMining( ply, "break_rejected" )
		return false
	end
	SV.MiningSessions[ply] = nil
	sendStage( ply, session, nil )
	local drops = spawnBlockDrops( ply, session, stacks )
	local durabilityDamage = damageMiningTool( ply, session, oldStateId )
	local snapshot = publicSession( session )
	local completion = {
		oldStateId = oldStateId,
		drops = drops,
		transaction = result,
		dropError = dropError,
		durabilityDamage = durabilityDamage,
	}
	safeCall( session.onComplete, ply, snapshot, completion )
	if MC.RunEvent then
		MC.RunEvent( "MC.PlayerMinedBlock", ply, session.bx, session.by, session.bz,
			oldStateId, drops, result, dropError, snapshot, durabilityDamage )
	end
	return true
end

function SV.BeginMining( ply, bx, by, bz, options )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	if SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) then return false, "creative_mode" end
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then SV.CancelMining( ply, "air" ) return false, "air" end

	local external = normalizeExternalOptions( options )
	local requireAim = not external or external.requireAim
	if requireAim then
		local aimAllowed, aimError = currentAimAllowsBlockAttack( ply, bx, by, bz )
		if not aimAllowed then return false, aimError end
	end
	local source = external and "external" or "inventory"
	local sourceToken = external and external.sourceToken or "inventory"
	local existing = SV.MiningSessions[ply]
	if existing and existing.bx == bx and existing.by == by and existing.bz == bz
		and existing.stateId == stateId and existing.source == source and existing.sourceToken == sourceToken then
		return true, publicSession( existing )
	end
	if existing then SV.CancelMining( ply, "target_changed" ) end

	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or MC.GetBlock( bx, by, bz )
	local progressPerTick, progressError, mining
	if MC.BlockMiningProgressPerTick then
		progressPerTick, progressError, mining = MC.BlockMiningProgressPerTick(
			stateId,
			external and external.toolStack or ( SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil ),
			ply,
			external and external.modifiers or nil
		)
	else
		progressError = "mining_rules_unavailable"
	end
	if not progressPerTick then return false, progressError end
	local plan, validationError
	if SV.ValidateBreakTarget then
		plan, validationError = SV.ValidateBreakTarget( ply, bx, by, bz )
	else
		validationError = "break_validation_unavailable"
	end
	if not plan then return false, validationError end

	local fingerprint
	local toolStack
	if external then
		toolStack = external.toolStack
	else
		fingerprint, validationError = selectedFingerprint( ply )
		if not fingerprint then return false, validationError end
		toolStack = copyStack( SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil )
	end

	local session = {
		bx = bx, by = by, bz = bz,
		stateId = stateId,
		blockId = blockId,
		progress = 0,
		stage = -1,
		selectedFingerprint = fingerprint,
		toolStack = toolStack,
		startedAt = CurTime(),
		source = source,
		sourceId = external and external.sourceId or "mc_item_hand",
		sourceToken = sourceToken,
		weapon = external and external.weapon or nil,
		requireAttackHeld = not external or external.requireAttackHeld,
		requireAim = not external or external.requireAim,
		modifiers = external and external.modifiers or nil,
		onCancel = external and external.onCancel or nil,
		onComplete = external and external.onComplete or nil,
		onDurabilityDamage = external and external.onDurabilityDamage or nil,
		validate = external and external.validate or nil,
		lastMining = mining,
	}
	SV.MiningSessions[ply] = session
	local snapshot = publicSession( session )
	if MC.RunEvent then MC.RunEvent( "MC.PlayerMiningStarted", ply, snapshot ) end
	if progressPerTick >= 1 then
		session.progress = 1
		session.lastMining = mining
		completeMining( ply, session )
	end
	return true, snapshot
end

local function sessionStillValid( ply, session )
	if not IsValid( ply ) or not ply:Alive() or ply:InVehicle() then return false, "player_invalid" end
	if SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) then return false, "creative_mode" end
	if session.requireAttackHeld and not ply:KeyDown( IN_ATTACK ) then return false, "released" end
	local weapon = ply:GetActiveWeapon()
	if session.source == "inventory" then
		if not IsValid( weapon ) or weapon:GetClass() ~= "mc_item_hand" then return false, "weapon_changed" end
		local fingerprint, fingerprintError = selectedFingerprint( ply )
		if not fingerprint or fingerprint ~= session.selectedFingerprint then return false, fingerprintError or "held_item_changed" end
	else
		if not IsValid( session.weapon ) or weapon ~= session.weapon then return false, "weapon_changed" end
		if session.validate then
			local ok, allowed, reason = pcall( session.validate, ply, publicSession( session ) )
			if not ok then return false, "external_validation_error" end
			if allowed == false then return false, tostring( reason or "external_cancel" ) end
		end
	end
	if MC.GetBlockState( session.bx, session.by, session.bz ) ~= session.stateId then return false, "block_changed" end
	if session.requireAim then
		local aimAllowed, aimError = currentAimAllowsBlockAttack( ply, session.bx, session.by, session.bz )
		if not aimAllowed then return false, aimError end
	end
	local reach = MC.CurrentReach and MC.CurrentReach() or ( MC.BS or 36.5 ) * 5
	local eye = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ply ) or ply:EyePos()
	if reach > 0 and not MC.ReachAllowsEye( eye, session.bx, session.by, session.bz, reach ) then return false, "out_of_reach" end
	return true
end

timer.Create( "mc_survival_mining_tick", TICK_INTERVAL, 0, function()
	for ply, session in pairs( SV.MiningSessions ) do
		local valid, reason = sessionStillValid( ply, session )
		if not valid then
			SV.CancelMining( ply, reason )
		else
			local progressPerTick, progressError, mining = MC.BlockMiningProgressPerTick
				and MC.BlockMiningProgressPerTick( session.stateId, session.toolStack, ply, session.modifiers )
			if not progressPerTick then
				SV.CancelMining( ply, progressError or "mining_rules_unavailable" )
			else
				session.lastMining = mining
				session.progress = math.min( 1, session.progress + progressPerTick )
				local stage = math.Clamp( math.floor( session.progress * 10 ), 0, 9 )
				if stage ~= session.stage then
					session.stage = stage
					sendStage( ply, session, stage )
				end
				if session.progress >= 1 then completeMining( ply, session ) end
			end
		end
	end
end )

hook.Add( "PlayerDeath", "mc_cancel_mining_on_death", function( ply ) SV.CancelMining( ply, "death" ) end )
hook.Add( "PlayerDeath", "mc_clear_creative_destroy_delay_on_death", function( ply )
	SV.CreativeDestroyStates[ply] = nil
end )
hook.Add( "PlayerDisconnected", "mc_cancel_mining_on_disconnect", function( ply )
	SV.CancelMining( ply, "disconnect" )
	SV.CreativeDestroyStates[ply] = nil
end )
hook.Add( "MC.PlayerGameModeChanged", "mc_clear_creative_destroy_delay_on_mode_change", function( ply )
	SV.CreativeDestroyStates[ply] = nil
end )
