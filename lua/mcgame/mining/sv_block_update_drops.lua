-- Java Block.updateOrDestroy support-loss loot bridge.
--
-- The engine scheduler exposes only an opaque two-phase result-effect registry.
-- This game-layer adapter resolves normal block loot while the old state and
-- Block Entity still exist, then creates item entities only after the voxel
-- transaction has committed successfully.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function reportDropError( stage, message )
	local output = "[MCGame] block-update drop " .. tostring( stage ) .. " failed: " .. tostring( message ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( output ) else print( output ) end
end

local function prepareSupportLossDrops( result, cells )
	if result.dropResources ~= true or not isfunction( SV.ResolveBlockDrops ) then return nil end

	-- ApplyBlockTransaction is last-write-wins for duplicate cells. Mirror that
	-- normalization so an earlier air request cannot drop a block when the final
	-- request for the same cell keeps or replaces it.
	local requestedByKey = {}
	for index = 1, #cells do
		local cell = cells[index]
		if type( cell ) == "table" and cell.stateId ~= nil then
			local bx = math.floor( tonumber( cell.bx ) or 0 )
			local by = math.floor( tonumber( cell.by ) or 0 )
			local bz = math.floor( tonumber( cell.bz ) or 0 )
			requestedByKey[MC.CellKey( bx, by, bz )] = {
				bx = bx, by = by, bz = bz,
				stateId = math.floor( tonumber( cell.stateId ) or -1 ),
			}
		end
	end

	local plans
	for key, requested in pairs( requestedByKey ) do
		if requested.stateId == 0 then
			local oldStateId = MC.GetBlockState( requested.bx, requested.by, requested.bz )
			if oldStateId and oldStateId ~= 0 then
				local ok, stacks = pcall( SV.ResolveBlockDrops, oldStateId, nil, {
					bx = requested.bx, by = requested.by, bz = requested.bz,
					blockEntity = MC.GetBlockEntity
						and MC.GetBlockEntity( requested.bx, requested.by, requested.bz ) or nil,
				} )
				if not ok then
					reportDropError( "resolve", stacks )
				elseif type( stacks ) == "table" and #stacks > 0 then
					plans = plans or {}
					plans[key] = { oldStateId = oldStateId, stacks = stacks }
				end
			end
		end
	end
	return plans
end

local function commitSupportLossDrops( plans, transaction )
	if not plans or not transaction or type( transaction.changes ) ~= "table"
		or not isfunction( SV.SpawnItemDrop ) then return end
	for index = 1, #transaction.changes do
		local change = transaction.changes[index]
		local key = MC.CellKey( change.bx, change.by, change.bz )
		local plan = plans[key]
		if plan and change.stateId == 0 and change.oldStateId == plan.oldStateId then
			local position = MC.CellWorldCenter
				and MC.CellWorldCenter( change.bx, change.by, change.bz ) or nil
			if position then
				for stackIndex = 1, #plan.stacks do
					local ok, spawnError = pcall( SV.SpawnItemDrop, position, plan.stacks[stackIndex], nil, {
						pickupDelay = 0.5,
						reason = "block_update_support_loss",
					} )
					if not ok then reportDropError( "spawn", spawnError ) end
				end
			end
		end
	end
end

if not SV.RegisterBlockUpdateResultEffect then
	reportDropError( "register", "block_update_result_effect_registry_unavailable" )
	return
end

local registered, registerError = SV.RegisterBlockUpdateResultEffect( "mcgame_normal_block_resources", {
	Prepare = prepareSupportLossDrops,
	Commit = commitSupportLossDrops,
} )
if registered ~= true then reportDropError( "register", registerError ) end
