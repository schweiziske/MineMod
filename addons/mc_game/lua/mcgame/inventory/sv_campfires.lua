-- Server-authoritative four-slot campfire cooking.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local CAMPFIRE_SLOTS = MC.CampfireSlotCount and MC.CampfireSlotCount() or 4
local DOWSE_NET = "mc_campfire_dowse_fx"

util.AddNetworkString( DOWSE_NET )

local function mutableBlockEntity( bx, by, bz )
	local cx, cy, cz, localIndex = MC.CellToChunk( bx, by, bz )
	local chunk = MC.GetChunk( cx, cy, cz )
	return chunk and chunk.blockEntities and chunk.blockEntities[localIndex] or nil, chunk
end

local function recordFromCurrent( record )
	local storage = MC.CampfireStorageFromRecord( record )
	local data = record and record.data or {}
	local progress, totals = {}, {}
	for slot = 1, CAMPFIRE_SLOTS do
		progress[slot] = math.max( 0, math.floor( tonumber( data.cookingProgress and data.cookingProgress[slot] ) or 0 ) )
		totals[slot] = math.max( 0, math.floor( tonumber( data.cookingTotalTime and data.cookingTotalTime[slot] ) or 0 ) )
	end
	return storage, progress, totals
end

local function copyRecordWith( storage, progress, totals )
	return MC.CampfireRecordFromStorage( storage, progress, totals )
end

local function persistAfterTransaction( bx, by, bz )
	local record = mutableBlockEntity( bx, by, bz )
	if record then
		record.dirty = true
		SV.Dirty = true
		if SV.ChunkStore and SV.ChunkStore.RecordBlockEntityEdit then
			local saved, err = SV.ChunkStore.RecordBlockEntityEdit( bx, by, bz, record )
			if saved ~= true and ErrorNoHalt then
				ErrorNoHalt( "[MC Campfire] overlay write failed: " .. tostring( err or "unknown" ) .. "\n" )
			end
		end
	end
end

local function stillCampfire( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	return MC.CampfireStateInfo and MC.CampfireStateInfo( stateId ) or nil, stateId
end

function SV.WakeCampfire( bx, by, bz )
	local info, stateId = stillCampfire( bx, by, bz )
	if not info then return false end
	local record = MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil
	local storage, progress = recordFromCurrent( record )
	local active = false
	for slot = 1, CAMPFIRE_SLOTS do
		if not MC.IsEmptyItemStack( storage[slot] ) and ( info.lit or progress[slot] > 0 ) then active = true break end
	end
	if active and SV.ScheduleBlockTick then SV.ScheduleBlockTick( bx, by, bz, 1, nil, stateId ) end
	return active
end

function SV.UseCampfire( ply, bx, by, bz )
	local info, stateId = stillCampfire( bx, by, bz )
	if not info or not IsValid( ply ) or not ply:IsPlayer() then return false, "campfire_unavailable" end
	local held = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
	local recipe = held and MC.FindCookingRecipe and MC.FindCookingRecipe( held, "minecraft:campfire_cooking" ) or nil
	-- TRY_WITH_EMPTY_HAND: non-campfire inputs continue to their normal item or
	-- block placement path. Valid campfire inputs always consume the interaction,
	-- including the full-four-slot case.
	if not recipe then return false, "not_campfire_food" end
	local record = MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil
	if not record then return true, "campfire_block_entity_unavailable" end
	local storage, progress, totals = recordFromCurrent( record )
	local emptySlot
	for slot = 1, CAMPFIRE_SLOTS do if MC.IsEmptyItemStack( storage[slot] ) then emptySlot = slot break end end
	if not emptySlot then return true, "campfire_full" end

	local inventoryRecord = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	if not inventoryRecord or not inventoryRecord.container then return true, "inventory_not_loaded" end
	local infinite = SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true
	local snapshot
	if not infinite then
		snapshot = MC.ContainerSnapshot( inventoryRecord.container )
		local selected = MC.ContainerGetSlot( inventoryRecord.container, inventoryRecord.selected )
		local extracted = selected and MC.InventorySlotTake( selected, 1, { player = ply, reason = "campfire_place_food" } ) or nil
		if not extracted then return true, "selected_take_failed" end
	end

	storage[emptySlot] = MC.CopyItemStack( held, 1 )
	progress[emptySlot] = 0
	totals[emptySlot] = math.max( 1, math.floor( tonumber( recipe.cookingTime ) or 600 ) )
	local nextRecord = copyRecordWith( storage, progress, totals )
	local inventoryResult
	local function commitInventory()
		local committed, commitError = SV.CommitPlayerInventoryMutation( inventoryRecord, snapshot, {
			player = ply, reason = "campfire_place_food",
		} )
		if not committed then return false, commitError or "inventory_commit_failed" end
		inventoryResult = committed
		return true, committed
	end
	local result = SV.SetBlockState and SV.SetBlockState( bx, by, bz, stateId, {
		actor = ply, fx = false, compareCollision = true, blockEntity = nextRecord,
		beforePublish = snapshot and commitInventory or nil,
	} ) or nil
	if not result or result.ok ~= true or result.changed <= 0 then
		if snapshot then MC.ContainerRestore( inventoryRecord.container, snapshot ) end
		return true, result and result.error or "campfire_update_failed"
	end
	persistAfterTransaction( bx, by, bz )
	if SV.ScheduleBlockTick then SV.ScheduleBlockTick( bx, by, bz, 1, nil, stateId ) end
	return true, { slot = emptySlot - 1, recipe = recipe.id, inventory = inventoryResult }
end

local function emitDowseEffects( bx, by, bz, stateId, soundEvent, volume, pitch )
	local center = MC.CellWorldCenter and MC.CellWorldCenter( bx, by, bz ) or nil
	if center and MC.PlayJavaSoundEvent then
		MC.PlayJavaSoundEvent( soundEvent, center, volume, pitch, 72 )
	end
	net.Start( DOWSE_NET )
		net.WriteInt( bx, MC.Net and MC.Net.COORD_BITS or 20 )
		net.WriteInt( by, MC.Net and MC.Net.COORD_BITS or 20 )
		net.WriteInt( bz, MC.Net and MC.Net.COORD_BITS or 20 )
		net.WriteBool( MC.GetStateProperty and MC.GetStateProperty( stateId, "signal_fire" ) == true )
	if center then net.SendPVS( center ) else net.Broadcast() end
end

function SV.HandleCampfireStateTransition( context, oldStateId, newStateId )
	if not context or not MC.CampfireStateInfo then return false end
	-- Player bucket placement is a two-phase world/inventory operation exposed
	-- through MC.PlayerPlacedFluid only after its caller commits. Suppress the
	-- lifecycle-side effect here so a later inventory rollback cannot leave a
	-- ghost sound/particle burst. Natural water updates have no player actor.
	if IsValid( context.actor ) and context.actor.IsPlayer and context.actor:IsPlayer() then return false end
	local oldInfo = MC.CampfireStateInfo( oldStateId )
	local newInfo = MC.CampfireStateInfo( newStateId )
	if not oldInfo or not newInfo or oldInfo.lit ~= true or newInfo.lit == true then return false end
	local wasWaterlogged = MC.GetStateProperty and MC.GetStateProperty( oldStateId, "waterlogged" ) == true
	local isWaterlogged = MC.GetStateProperty and MC.GetStateProperty( newStateId, "waterlogged" ) == true
	if wasWaterlogged or not isWaterlogged then return false end
	-- CampfireBlock#placeLiquid plays GENERIC_EXTINGUISH_FIRE and calls dowse
	-- for both a bucket and naturally spreading water.
	emitDowseEffects( context.bx, context.by, context.bz, oldStateId,
		"entity.generic.extinguish_fire", 1, 1 )
	return true
end

function SV.DowseCampfireWithSelectedShovel( ply, bx, by, bz )
	local info, stateId = stillCampfire( bx, by, bz )
	if not info or info.lit ~= true then return false, "campfire_not_lit" end
	if not IsValid( ply ) or not ply:IsPlayer() or not ply:Alive() then return false, "invalid_player" end
	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
	if not aim or aim.bx ~= bx or aim.by ~= by or aim.bz ~= bz then return false, "campfire_target_changed" end
	local normal = aim.HitNormal or aim.Normal
	if normal and ( normal.z or 0 ) < -0.5 then return false, "campfire_bottom_face" end
	if not SV.Validate or not SV.Validate( ply, bx, by, bz, false ) then return false, "campfire_dowse_rejected" end
	local selected = SV.GetSelectedPlayerStack and SV.GetSelectedPlayerStack( ply ) or nil
	local tool = selected and MC.ItemToolSpec and MC.ItemToolSpec( selected ) or nil
	if not tool or tool.type ~= "shovel" then return false, "selected_item_mismatch" end
	local selectedHash = MC.ItemStackHash and MC.ItemStackHash( selected ) or nil
	local durabilityResult, broken, infinite
	local function commitDurability()
		local result, didBreak, err = SV.DamageSelectedItem( ply, 1, {
			expectedItem = selected.item,
			expectedStackHash = selectedHash,
			reason = "campfire_dowse",
		} )
		if result then durabilityResult, broken = result, didBreak == true return true, result end
		if err == "infinite_materials" then infinite = true return true, { infinite = true } end
		return false, err or "durability_commit_failed"
	end
	local nextState = MC.StateWith and MC.StateWith( stateId, "lit", false ) or nil
	if not nextState or nextState == stateId then return false, "campfire_unlit_state_unavailable" end
	local transaction = SV.SetBlockState and SV.SetBlockState( bx, by, bz, nextState, {
		actor = ply,
		fx = false,
		compareCollision = true,
		blockUpdates = true,
		beforePublish = commitDurability,
	} ) or nil
	if not transaction or transaction.ok ~= true or transaction.changed <= 0 then
		return false, transaction and transaction.error or "campfire_dowse_failed"
	end
	emitDowseEffects( bx, by, bz, stateId, "block.fire.extinguish", 0.5,
		2.6 + ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 0.8 )
	return true, {
		transaction = transaction,
		durability = durabilityResult,
		broken = broken == true,
		infinite = infinite == true,
	}
end

function SV.CampfireTickAt( context )
	local info, stateId = stillCampfire( context.bx, context.by, context.bz )
	if not info then return nil end
	local record = MC.GetBlockEntity and MC.GetBlockEntity( context.bx, context.by, context.bz ) or nil
	if not record then return nil end
	local storage, progress, totals = recordFromCurrent( record )
	local changed, keepTicking = false, false
	local completed = {}
	for slot = 1, CAMPFIRE_SLOTS do
		local stack = storage[slot]
		if not MC.IsEmptyItemStack( stack ) then
			if info.lit then
				progress[slot] = progress[slot] + 1
				changed = true
				if progress[slot] >= totals[slot] then
					local recipe = MC.FindCookingRecipe and MC.FindCookingRecipe( stack, "minecraft:campfire_cooking" ) or nil
					completed[#completed + 1] = recipe and MC.AssembleRecipe( recipe ) or MC.CopyItemStack( stack )
					storage[slot], progress[slot], totals[slot] = nil, 0, 0
				end
			elseif progress[slot] > 0 then
				progress[slot] = math.Clamp( progress[slot] - 2, 0, totals[slot] )
				changed = true
				if progress[slot] > 0 then keepTicking = true end
			end
		end
	end
	for slot = 1, CAMPFIRE_SLOTS do
		if not MC.IsEmptyItemStack( storage[slot] ) and ( info.lit or progress[slot] > 0 ) then
			keepTicking = true
			break
		end
	end
	if not changed then return nil end
	local nextRecord = copyRecordWith( storage, progress, totals )
	return {
		cells = { { bx = context.bx, by = context.by, bz = context.bz,
			stateId = stateId, blockEntity = nextRecord } },
		schedule = keepTicking and { { delayTicks = 1, expectedStateId = stateId } } or nil,
		afterTransactionData = { bx = context.bx, by = context.by, bz = context.bz, drops = completed },
		afterTransaction = function( data, transaction )
			if not transaction or transaction.ok ~= true then return end
			persistAfterTransaction( data.bx, data.by, data.bz )
			local pos = MC.CellWorldMin and MC.CellWorldMin( data.bx, data.by, data.bz )
				or MC.CellWorldCenter( data.bx, data.by, data.bz )
			for _, stack in ipairs( data.drops or {} ) do
				if stack and SV.SpawnItemDrop then SV.SpawnItemDrop( pos, stack, nil, { reason = "campfire_cooked" } ) end
			end
		end,
	}
end

hook.Add( "MC.PlayerPlacedFluid", "mc_campfire_water_dowse", function( _, kind, bx, by, bz, stateId )
	if kind ~= "water" or not MC.IsCampfireState or not MC.IsCampfireState( stateId ) then return end
	if MC.GetStateProperty( stateId, "waterlogged" ) ~= true
		or MC.GetStateProperty( stateId, "lit" ) == true then return end
	emitDowseEffects( bx, by, bz, stateId, "entity.generic.extinguish_fire", 1, 1 )
end )

function SV.DropCampfireContents( actor, bx, by, bz, blockEntity )
	local storage = MC.CampfireStorageFromRecord and MC.CampfireStorageFromRecord( blockEntity ) or {}
	local position = MC.CellWorldMin and MC.CellWorldMin( bx, by, bz ) or MC.CellWorldCenter( bx, by, bz )
	for slot = 1, CAMPFIRE_SLOTS do
		if not MC.IsEmptyItemStack( storage[slot] ) and SV.SpawnItemDrop then
			SV.SpawnItemDrop( position, MC.CopyItemStack( storage[slot] ), actor, { reason = "campfire_removed" } )
		end
	end
end

MC.RegisterBlockUpdateHandler( "minecraft:campfire", { OnScheduledTick = SV.CampfireTickAt } )
MC.RegisterBlockUpdateHandler( "minecraft:soul_campfire", { OnScheduledTick = SV.CampfireTickAt } )

local function warmChunk( _, cx, cy, cz )
	local chunk = cx and MC.GetChunk( cx, cy, cz ) or nil
	if not chunk or not chunk.blockEntities then return end
	for localIndex, record in pairs( chunk.blockEntities ) do
		if record.type == "minecraft:campfire" then
			local lx, ly, lz = MC.DecodeLocal( localIndex )
			SV.WakeCampfire( cx * MC.CS + lx, cy * MC.CS + ly, cz * MC.CH + lz )
		end
	end
end
hook.Add( "MC.ChunkHydrated", "mc_campfire_chunk_warm", warmChunk )
hook.Add( "MC.WorldLoaded", "mc_campfire_world_warm", function()
	for _, chunk in pairs( MC.World or {} ) do warmChunk( nil, chunk.cx, chunk.cy, chunk.cz ) end
end )
