-- Responsive survival mining. Server transactions/corrections reconcile the
-- voxel plan; server progress for other miners remains purely presentational.
if not CLIENT then return end
MC = MC or {}

local TICK = 1 / 20
local nextContinueAt, wasHeld, blocked = 0, false, nil

local function sameCell( session, bx, by, bz )
	return session and session.bx == bx and session.by == by and session.bz == bz
end

local function inventoryHand( weapon )
	if not IsValid( weapon ) then return false end
	local class = weapon:GetClass()
	return class == "mc_item_hand" or class == "mc_inventory"
end

local function heldStack()
	local state = MC.ClientInventory
	return state and state.slots[( state.selected or 0 ) + 1] or nil
end

function MC.CancelClientMining()
	local session = MC.ClientMiningPrediction
	if session then MC.SetClientMiningCrack( LocalPlayer(), session.bx, session.by, session.bz, nil ) end
	MC.ClientMiningPrediction = nil
end

local function complete( session )
	-- Think can begin the crack before PrimaryAttack supplies the shared input
	-- command. Do not create an unidentifiable edit in that short window.
	if MC.ClientEditPredictionEnabled() and not session.commandNumber then return end
	session.completed = true
	if not session.instant then nextContinueAt = CurTime() + 5 * TICK end
	MC.PredictBreakBlock( session.bx, session.by, session.bz, LocalPlayer(), session.commandNumber )
	MC.SetClientMiningCrack( LocalPlayer(), session.bx, session.by, session.bz, nil )
end

function MC.BeginClientMining( weapon, bx, by, bz, initialPress, commandNumber )
	local ply = LocalPlayer()
	if not inventoryHand( weapon ) or weapon:GetOwner() ~= ply or MC.PlayerIsCreative( ply ) then return false end
	if MC.ClientInventory and MC.ClientInventory.session then return false end
	local stack, session = heldStack(), MC.ClientMiningPrediction
	local fingerprint = MC.MiningStackFingerprint( stack )
	if not initialPress and sameCell( blocked, bx, by, bz ) and blocked.fingerprint == fingerprint then return false end
	blocked = nil
	if sameCell( session, bx, by, bz ) and session.fingerprint == fingerprint and session.weapon == weapon
	and ( session.completed or session.stateId == MC.GetBlockState( bx, by, bz ) ) then
		-- Think may show the crack before the next predicted weapon command.
		-- Bind only that first command, which also starts the server session.
		if session.commandNumber == nil then
			session.commandNumber = commandNumber
			if not session.completed and ( session.instant or session.progress >= 1 ) then complete( session ) end
		end
		return true
	end
	MC.CancelClientMining()
	if not initialPress and CurTime() < nextContinueAt then return false end
	if not MC.CanPreviewBreak( ply, bx, by, bz ) then return false end
	local stateId = MC.GetBlockState( bx, by, bz )
	local speed = MC.BlockMiningProgressPerTick( stateId, stack, ply )
	if not speed then return false end
	session = { bx = bx, by = by, bz = bz, stateId = stateId, weapon = weapon,
		fingerprint = fingerprint, progress = 0, nextTickAt = CurTime() + TICK, instant = speed >= 1,
		commandNumber = commandNumber }
	MC.ClientMiningPrediction = session
	if session.instant then complete( session )
	else MC.SetClientMiningCrack( ply, bx, by, bz, 0 ) end
	return true
end

function MC.ReceiveClientMiningStage( miner, bx, by, bz, stage, completed, commandNumber )
	if miner ~= LocalPlayer() or not inventoryHand( miner:GetActiveWeapon() ) then return false end
	local session = MC.ClientMiningPrediction
	-- Late stages from an old target must neither resurrect it nor erase the
	-- crack at the new target. Local input owns the active crack immediately.
	if not sameCell( session, bx, by, bz ) then return true end
	-- A delayed cancellation from a previous press at this SAME cell must not
	-- stop the newer attempt. CUserCmd numbers match across predicted realms.
	if commandNumber and commandNumber ~= 0 and session.commandNumber ~= commandNumber then return true end
	if stage == nil then
		if not completed then blocked = { bx = bx, by = by, bz = bz, fingerprint = session.fingerprint } end
		MC.CancelClientMining()
	end
	return true
end

hook.Add( "Think", "mc_survival_mining_prediction", function()
	local ply = LocalPlayer()
	local weapon = IsValid( ply ) and ply:GetActiveWeapon() or nil
	local held = IsValid( ply ) and ply:Alive() and not ply:InVehicle() and inventoryHand( weapon )
		and ply:KeyDown( IN_ATTACK ) and not MC.PlayerIsCreative( ply )
		and not ( MC.ClientInventory and MC.ClientInventory.session )
		and not gui.IsGameUIVisible() and not vgui.CursorVisible()
	if not held then
		wasHeld, blocked = false, nil
		MC.CancelClientMining()
		return
	end
	local initialPress = not wasHeld
	wasHeld = true
	local aim = MC.PlayerBlockAim( ply )
	if not aim or MC.EntityOccludesBlockAim( ply, aim ) then blocked = nil MC.CancelClientMining() return end
	MC.BeginClientMining( weapon, aim.bx, aim.by, aim.bz, initialPress )
	local session = MC.ClientMiningPrediction
	if not session or session.completed or CurTime() < session.nextTickAt then return end
	local speed = MC.BlockMiningProgressPerTick( session.stateId, heldStack(), ply )
	if not speed then MC.CancelClientMining() return end
	local steps = math.floor( ( CurTime() - session.nextTickAt ) / TICK ) + 1
	session.nextTickAt = session.nextTickAt + steps * TICK
	session.progress = math.min( 1, session.progress + speed * steps )
	if session.progress >= 1 then complete( session )
	else MC.SetClientMiningCrack( ply, session.bx, session.by, session.bz, math.floor( session.progress * 10 ) ) end
end )
