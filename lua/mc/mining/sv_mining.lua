-- Server-owned survival mining sessions. One 20 TPS pass touches only players
-- who are actively mining; the world is never scanned.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local TICK_INTERVAL = 1 / 20
SV.MiningSessions = SV.MiningSessions or {}

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

local function handProgressPerTick( blockId )
	local hardness = MC.BlockHardness and MC.BlockHardness( blockId ) or 1
	if hardness < 0 then return nil, "unbreakable" end
	if hardness == 0 then return 1 end
	local divisor = MC.BlockRequiresCorrectTool and MC.BlockRequiresCorrectTool( blockId ) and 100 or 30
	return 1 / hardness / divisor
end

function SV.CancelMining( ply, reason )
	local session = SV.MiningSessions[ply]
	if not session then return false end
	SV.MiningSessions[ply] = nil
	sendStage( ply, session, nil )
	if MC.RunEvent then MC.RunEvent( "MC.PlayerMiningCancelled", ply, session, reason or "cancelled" ) end
	return true
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

local function completeMining( ply, session )
	local oldStateId = MC.GetBlockState and MC.GetBlockState( session.bx, session.by, session.bz ) or 0
	local toolStack = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
	local stacks, dropError = {}, "block_loot_unavailable"
	if SV.ResolveBlockDrops then
		stacks, dropError = SV.ResolveBlockDrops( oldStateId, toolStack, {
			player = ply,
			bx = session.bx, by = session.by, bz = session.bz,
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
	if MC.RunEvent then MC.RunEvent( "MC.PlayerMinedBlock", ply, session.bx, session.by, session.bz, oldStateId, drops, result, dropError ) end
	return true
end

function SV.BeginMining( ply, bx, by, bz )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	if SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) then return false, "creative_mode" end
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then SV.CancelMining( ply, "air" ) return false, "air" end

	local existing = SV.MiningSessions[ply]
	if existing and existing.bx == bx and existing.by == by and existing.bz == bz and existing.stateId == stateId then
		return true, existing
	end
	if existing then SV.CancelMining( ply, "target_changed" ) end
	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or MC.GetBlock( bx, by, bz )
	local progressPerTick, progressError = handProgressPerTick( blockId )
	if not progressPerTick then return false, progressError end
	local plan, validationError
	if SV.ValidateBreakTarget then
		plan, validationError = SV.ValidateBreakTarget( ply, bx, by, bz )
	else
		validationError = "break_validation_unavailable"
	end
	if not plan then return false, validationError end
	local fingerprint, fingerprintError = selectedFingerprint( ply )
	if not fingerprint then return false, fingerprintError end

	local session = {
		bx = bx, by = by, bz = bz,
		stateId = stateId,
		blockId = blockId,
		progress = 0,
		progressPerTick = progressPerTick,
		stage = -1,
		selectedFingerprint = fingerprint,
		startedAt = CurTime(),
	}
	SV.MiningSessions[ply] = session
	if MC.RunEvent then MC.RunEvent( "MC.PlayerMiningStarted", ply, session ) end
	return true, session
end

local function sessionStillValid( ply, session )
	if not IsValid( ply ) or not ply:Alive() or ply:InVehicle() then return false, "player_invalid" end
	if SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) then return false, "creative_mode" end
	if not ply:KeyDown( IN_ATTACK ) then return false, "released" end
	local weapon = ply:GetActiveWeapon()
	if not IsValid( weapon ) or weapon:GetClass() ~= "mc_item_hand" then return false, "weapon_changed" end
	if MC.GetBlockState( session.bx, session.by, session.bz ) ~= session.stateId then return false, "block_changed" end
	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
	if not aim or aim.bx ~= session.bx or aim.by ~= session.by or aim.bz ~= session.bz then return false, "aim_changed" end
	local fingerprint, fingerprintError = selectedFingerprint( ply )
	if not fingerprint or fingerprint ~= session.selectedFingerprint then return false, fingerprintError or "held_item_changed" end
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
			session.progress = math.min( 1, session.progress + session.progressPerTick )
			local stage = math.Clamp( math.floor( session.progress * 10 ), 0, 9 )
			if stage ~= session.stage then
				session.stage = stage
				sendStage( ply, session, stage )
			end
			if session.progress >= 1 then completeMining( ply, session ) end
		end
	end
end )

hook.Add( "PlayerDeath", "mc_cancel_mining_on_death", function( ply ) SV.CancelMining( ply, "death" ) end )
hook.Add( "PlayerDisconnected", "mc_cancel_mining_on_disconnect", function( ply ) SV.CancelMining( ply, "disconnect" ) end )
