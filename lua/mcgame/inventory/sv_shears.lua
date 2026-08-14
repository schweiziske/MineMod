-- Server-authoritative ShearsItem#useOn bridge for Java 26.2
-- GrowingPlantHeadBlock. Entity shearing remains in MCITEM/BMB because those
-- entities belong to the external addon; this module owns only voxel state and
-- the selected ItemStack transaction.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local MAX_AGE = 25
local GROWING_PLANT_HEADS = {
	["minecraft:cave_vines"] = true,
	["minecraft:kelp"] = true,
	["minecraft:twisting_vines"] = true,
	["minecraft:weeping_vines"] = true,
}

local function blockMcid( stateId )
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	return block and block.mcid or nil
end

local function resultTable( plan )
	return {
		bx = plan.bx, by = plan.by, bz = plan.bz,
		oldStateId = plan.oldStateId,
		stateId = plan.stateId,
		mcid = plan.mcid,
		oldAge = plan.oldAge,
		age = MAX_AGE,
	}
end

function SV.ResolvePlayerShearsPlantAim( ply, context )
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	local reach = tonumber( context and context.reach )
	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply, reach ) or nil
	if not aim then return false, "no_block_target" end
	local bx, by, bz = math.floor( aim.bx or 0 ), math.floor( aim.by or 0 ), math.floor( aim.bz or 0 )
	local oldStateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if oldStateId == 0 then return false, "no_block_target" end
	local mcid = blockMcid( oldStateId )
	if not GROWING_PLANT_HEADS[mcid] then return false, "not_growing_plant_head" end
	local age = MC.GetStateProperty and tonumber( MC.GetStateProperty( oldStateId, "age" ) ) or nil
	if age == nil then return false, "growing_plant_age_unavailable" end
	if age >= MAX_AGE then return false, "growing_plant_max_age" end
	if not SV.Validate or not SV.Validate( ply, bx, by, bz, false ) then return false, "shears_rejected" end
	local stateId = MC.StateWith and MC.StateWith( oldStateId, "age", MAX_AGE ) or nil
	if not stateId or stateId == oldStateId then return false, "max_age_state_unavailable" end
	return true, {
		bx = bx, by = by, bz = bz,
		oldStateId = oldStateId,
		stateId = stateId,
		mcid = mcid,
		oldAge = age,
	}
end

function SV.CommitPlayerShearsPlant( ply, plan, beforePublish )
	if not istable( plan ) then return false, "invalid_shears_plan" end
	local bx, by, bz = math.floor( tonumber( plan.bx ) or 0 ),
		math.floor( tonumber( plan.by ) or 0 ), math.floor( tonumber( plan.bz ) or 0 )
	local oldStateId = math.floor( tonumber( plan.oldStateId ) or 0 )
	local stateId = math.floor( tonumber( plan.stateId ) or 0 )
	if oldStateId <= 0 or stateId <= 0 or not GROWING_PLANT_HEADS[plan.mcid] then
		return false, "invalid_shears_plan"
	end
	if ( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 ) ~= oldStateId then
		return false, "shears_target_changed"
	end
	if not SV.SetBlockState then return false, "world_api_unavailable" end
	local transaction = SV.SetBlockState( bx, by, bz, stateId, {
		actor = ply,
		priorityPhys = true,
		blockUpdates = true,
		beforePublish = beforePublish,
	} )
	if not transaction or transaction.ok ~= true or transaction.changed <= 0 then
		return false, transaction and transaction.error or "shears_write_failed"
	end
	local result = resultTable( plan )
	result.transaction = transaction
	return true, result
end

local function playCropSound( result )
	if not result or not MC.PlayJavaSoundEvent or not MC.CellWorldCenter then return end
	MC.PlayJavaSoundEvent(
		"block.growing_plant.crop",
		MC.CellWorldCenter( result.bx, result.by, result.bz ),
		1,
		1,
		72
	)
end

function SV.MaxAgePlayerPlantAim( ply, context )
	local resolved, planOrError = SV.ResolvePlayerShearsPlantAim( ply, context )
	if resolved ~= true then return false, planOrError end
	local committed, resultOrError = SV.CommitPlayerShearsPlant( ply, planOrError )
	if committed then playCropSound( resultOrError ) end
	return committed, resultOrError
end

function SV.UseSelectedShearsOnBlock( ply, context )
	context = istable( context ) and context or {}
	local matchContext = {
		expectedItem = "minecraft:shears",
		expectedClass = context.expectedClass,
		expectedStackHash = context.expectedStackHash,
	}
	if not SV.SelectedStackMatches then return false, "selected_item_unavailable" end
	local record, _, selected, matchError = SV.SelectedStackMatches( ply, matchContext )
	if not record then return false, matchError or "selected_item_unavailable" end
	matchContext.expectedStackHash = MC.ItemStackHash and MC.ItemStackHash( selected ) or nil

	local resolved, planOrError = SV.ResolvePlayerShearsPlantAim( ply, context )
	if resolved ~= true then return false, planOrError end

	local durabilityResult, broken, infinite
	local function commitDurability()
		local result, didBreak, err = SV.DamageSelectedItem( ply, 1, {
			expectedItem = matchContext.expectedItem,
			expectedClass = matchContext.expectedClass,
			expectedStackHash = matchContext.expectedStackHash,
			reason = context.reason or "shears_growing_plant",
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

	local committed, resultOrError = SV.CommitPlayerShearsPlant( ply, planOrError, commitDurability )
	if committed ~= true then return false, resultOrError end
	resultOrError.durability = durabilityResult
	resultOrError.broken = broken == true
	resultOrError.infinite = infinite == true
	playCropSound( resultOrError )
	return true, resultOrError
end
