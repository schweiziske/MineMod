--[[----------------------------------------------------------------------------
	MC : shared multi-cell block placement/break plans.

	No state is mutated here. Server authority and client prediction both consume
	the same cell plans so doors/beds do not split across realms.
------------------------------------------------------------------------------]]

MC = MC or {}

local DirectionOffset = {
	[MC.Direction.NORTH] = { 0, -1, 0 },
	[MC.Direction.SOUTH] = { 0, 1, 0 },
	[MC.Direction.WEST] = { -1, 0, 0 },
	[MC.Direction.EAST] = { 1, 0, 0 },
}

function MC.IsDoorBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.orient == "door" or false
end

function MC.IsBedBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.orient == "bed" or false
end

function MC.HorizontalDirectionOffset( facing )
	local off = DirectionOffset[facing] or DirectionOffset[MC.Direction.NORTH]
	return off[1], off[2], off[3]
end

local function addCell( cells, seen, bx, by, bz, id, orient )
	local key = MC.CellKey( bx, by, bz )
	if seen[key] then return seen[key] end
	local cell = {
		bx = bx, by = by, bz = bz,
		id = id or 0,
		orient = orient or 0,
	}
	seen[key] = cell
	cells[#cells + 1] = cell
	return cell
end

local function addStateCell( cells, seen, bx, by, bz, stateId )
	local key = MC.CellKey( bx, by, bz )
	if seen[key] then return seen[key] end
	local id, orient = MC.LegacyFromState( stateId )
	if id == nil then return nil, "state_missing_block" end
	local cell = {
		bx = bx, by = by, bz = bz,
		stateId = stateId,
		id = id,
		orient = orient or 0,
	}
	seen[key] = cell
	cells[#cells + 1] = cell
	return cell
end

function MC.PrimaryPartOrient( id, orient )
	orient = MC.NormalizeOrient( id, orient )
	if MC.IsDoorBlock( id ) then
		return MC.MakeDoorOrient(
			MC.DoorOrientFacing( orient ),
			"lower",
			MC.DoorOrientOpen( orient ),
			MC.DoorOrientHinge( orient ),
			MC.DoorOrientPowered( orient )
		)
	end
	if MC.IsBedBlock( id ) then
		return MC.MakeBedOrient( MC.BedOrientFacing( orient ), "foot" )
	end
	return orient
end

function MC.BuildPlacementPlan( bx, by, bz, id, orient )
	if not MC.IsValidBlock or not MC.IsValidBlock( id ) then return nil end
	orient = MC.PrimaryPartOrient( id, orient )
	local stateId = MC.StateFromLegacy and MC.StateFromLegacy( id, orient ) or nil
	if not stateId then return nil end
	return MC.BuildPlacementStatePlan( bx, by, bz, stateId )
end

local FacingDirection = {
	north = MC.Direction.NORTH,
	south = MC.Direction.SOUTH,
	west = MC.Direction.WEST,
	east = MC.Direction.EAST,
}

MC.PlacementStateUpdateProviders = MC.PlacementStateUpdateProviders or {}
MC.PlacementStateUpdateProviderOrder = MC.PlacementStateUpdateProviderOrder or {}

local function rebuildPlacementStateProviderOrder()
	local order = {}
	for id, entry in pairs( MC.PlacementStateUpdateProviders ) do
		order[#order + 1] = { id = id, priority = entry.priority, build = entry.build }
	end
	table.sort( order, function( left, right )
		if left.priority == right.priority then return left.id < right.id end
		return left.priority > right.priority
	end )
	MC.PlacementStateUpdateProviderOrder = order
end

function MC.RegisterPlacementStateUpdateProvider( id, build, priority )
	id = tostring( id or "" )
	if id == "" or #id > 128 then return false, "invalid_provider_id" end
	if not isfunction( build ) then return false, "invalid_provider" end
	MC.PlacementStateUpdateProviders[id] = {
		build = build,
		priority = math.Clamp( math.floor( tonumber( priority ) or 0 ), -32768, 32767 ),
	}
	rebuildPlacementStateProviderOrder()
	return true
end

function MC.UnregisterPlacementStateUpdateProvider( id )
	id = tostring( id or "" )
	if not MC.PlacementStateUpdateProviders[id] then return false end
	MC.PlacementStateUpdateProviders[id] = nil
	rebuildPlacementStateProviderOrder()
	return true
end

local function stateWith( stateId, property, value )
	local nextState, err = MC.StateWith( stateId, property, value )
	if not nextState then return nil, err or "invalid_part_state" end
	return nextState
end

local function mergeStateUpdate( cells, seen, update )
	local key = MC.CellKey( update.bx, update.by, update.bz )
	local cell = seen[key]
	local id, orient = MC.LegacyFromState( update.stateId )
	if id == nil then return nil end
	if cell then
		cell.stateId = update.stateId
		cell.id = id
		cell.orient = orient or 0
		return cell
	end
	cell = addStateCell( cells, seen, update.bx, update.by, update.bz, update.stateId )
	if cell then cell.updateExisting = true end
	return cell
end

local function appendRedstoneUpdates( cells, seen, changeCount )
	if not MC.BuildRedstoneWireStateUpdates then return end
	local updates = MC.BuildRedstoneWireStateUpdates( cells, changeCount )
	for index = 1, #updates do mergeStateUpdate( cells, seen, updates[index] ) end
end

local function appendBlockConnectionUpdates( cells, seen, changeCount )
	if not MC.BuildBlockConnectionStateUpdates then return end
	local updates = MC.BuildBlockConnectionStateUpdates( cells, changeCount )
	for index = 1, #updates do mergeStateUpdate( cells, seen, updates[index] ) end
end

local function appendRailUpdates( cells, seen, changeCount )
	if not MC.BuildRailStateUpdates then return end
	local updates = MC.BuildRailStateUpdates( cells, changeCount )
	for index = 1, #updates do mergeStateUpdate( cells, seen, updates[index] ) end
end

local function placementProviderInput( cells )
	local copy = {}
	for index, cell in ipairs( cells ) do
		copy[index] = {
			bx = cell.bx, by = cell.by, bz = cell.bz,
			stateId = cell.stateId, id = cell.id, orient = cell.orient,
			updateExisting = cell.updateExisting == true,
			-- Placed while sneaking. ChestBlock#getStateForPlacement suppresses
			-- the automatic double-chest merge when isSecondaryUseActive(), so
			-- connection providers need this context, not just the cells.
			secondaryUse = cell.secondaryUse == true,
		}
	end
	return copy
end

local function appendRegisteredStateUpdates( cells, seen, changeCount )
	for _, entry in ipairs( MC.PlacementStateUpdateProviderOrder or {} ) do
		local called, updates = pcall( entry.build, placementProviderInput( cells ), changeCount )
		if not called then
			if ErrorNoHalt then
				ErrorNoHalt( "[MC] placement state provider " .. entry.id .. " failed: " .. tostring( updates ) .. "\n" )
			end
		elseif updates ~= nil and not istable( updates ) then
			if ErrorNoHalt then
				ErrorNoHalt( "[MC] placement state provider " .. entry.id .. " returned a non-table result\n" )
			end
		else
			for _, update in ipairs( updates or {} ) do
				local bx = math.floor( tonumber( update.bx ) or 0 )
				local by = math.floor( tonumber( update.by ) or 0 )
				local bz = math.floor( tonumber( update.bz ) or 0 )
				local stateId = math.floor( tonumber( update.stateId ) or -1 )
				if MC.IsValidBlockState and MC.IsValidBlockState( stateId ) then
					mergeStateUpdate( cells, seen, { bx = bx, by = by, bz = bz, stateId = stateId } )
				end
			end
		end
	end
end

local function appendNeighbourStateUpdates( cells, seen, changeCount )
	if not MC.BuildNeighbourStateUpdates then return end
	local updates = MC.BuildNeighbourStateUpdates( cells, changeCount )
	for index = 1, #updates do mergeStateUpdate( cells, seen, updates[index] ) end
end

function MC.BuildPlacementStatePlan( bx, by, bz, stateId )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId <= 0 or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil end
	if MC.ResolveRedstonePlacementState then
		stateId = MC.ResolveRedstonePlacementState( stateId, bx, by, bz ) or stateId
	end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	if id == nil or not MC.IsValidBlock or not MC.IsValidBlock( id ) then return nil end
	if MC.FaceAttachedCanSurvive and not MC.FaceAttachedCanSurvive( bx, by, bz, stateId ) then return nil end
	if MC.IsBannerState and MC.IsBannerState( stateId )
	and MC.BannerCanSurvive and not MC.BannerCanSurvive( bx, by, bz, stateId ) then return nil end
	local cells = {}
	local seen = {}

	if MC.IsDoorBlock( id ) then
		local lower = stateWith( stateId, "half", "lower" )
		local upper = stateWith( stateId, "half", "upper" )
		if not lower or not upper then return nil end
		if not addStateCell( cells, seen, bx, by, bz, lower ) then return nil end
		if not addStateCell( cells, seen, bx, by, bz + 1, upper ) then return nil end
	elseif MC.IsBedBlock( id ) then
		local facingName = MC.GetStateProperty and MC.GetStateProperty( stateId, "facing" ) or "north"
		local facing = FacingDirection[tostring( facingName )] or MC.Direction.NORTH
		local dx, dy = MC.HorizontalDirectionOffset( facing )
		local foot = stateWith( stateId, "part", "foot" )
		local head = stateWith( stateId, "part", "head" )
		if not foot or not head then return nil end
		if not addStateCell( cells, seen, bx, by, bz, foot ) then return nil end
		if not addStateCell( cells, seen, bx + dx, by + dy, bz, head ) then return nil end
	else
		if not addStateCell( cells, seen, bx, by, bz, stateId ) then return nil end
	end
	local primaryChangeCount = #cells
	appendRegisteredStateUpdates( cells, seen, primaryChangeCount )
	appendBlockConnectionUpdates( cells, seen, primaryChangeCount )
	appendRedstoneUpdates( cells, seen, primaryChangeCount )
	appendRailUpdates( cells, seen, primaryChangeCount )
	appendNeighbourStateUpdates( cells, seen, primaryChangeCount )

	local _, orient = MC.LegacyFromState( cells[1].stateId )
	return {
		bx = bx, by = by, bz = bz,
		id = id,
		orient = orient or 0,
		stateId = cells[1].stateId,
		cells = cells,
	}
end

local function matchingDoorPart( id, orient, facing, half, open, hinge, powered )
	return id ~= 0
		and MC.IsDoorBlock( id )
		and MC.DoorOrientFacing( orient ) == facing
		and MC.DoorOrientHalf( orient ) == half
		and MC.DoorOrientOpen( orient ) == open
		and MC.DoorOrientHinge( orient ) == hinge
		and MC.DoorOrientPowered( orient ) == powered
end

local function matchingBedPart( id, orient, facing, part )
	return id ~= 0
		and MC.IsBedBlock( id )
		and MC.BedOrientFacing( orient ) == facing
		and MC.BedOrientPart( orient ) == part
end

function MC.BuildBreakPlan( bx, by, bz )
	local id = MC.GetBlock( bx, by, bz )
	if id == 0 then return nil end
	local orient = MC.GetBlockOrient( bx, by, bz )
	local cells = {}
	local seen = {}
	addCell( cells, seen, bx, by, bz, 0, 0 )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or nil
	local pistonX, pistonY, pistonZ
	if MC.PistonBreakPartner then
		pistonX, pistonY, pistonZ = MC.PistonBreakPartner( bx, by, bz, stateId )
	end
	if pistonX ~= nil then addCell( cells, seen, pistonX, pistonY, pistonZ, 0, 0 ) end

	if MC.IsDoorBlock( id ) then
		local facing = MC.DoorOrientFacing( orient )
		local half = MC.DoorOrientHalf( orient )
		local open = MC.DoorOrientOpen( orient )
		local hinge = MC.DoorOrientHinge( orient )
		local powered = MC.DoorOrientPowered( orient )
		local otherZ = half == "upper" and bz - 1 or bz + 1
		local wantHalf = half == "upper" and "lower" or "upper"
		local otherId = MC.GetBlock( bx, by, otherZ )
		local otherOrient = MC.GetBlockOrient( bx, by, otherZ )
		if matchingDoorPart( otherId, otherOrient, facing, wantHalf, open, hinge, powered ) then
			addCell( cells, seen, bx, by, otherZ, 0, 0 )
		end
	elseif MC.IsBedBlock( id ) then
		local facing = MC.BedOrientFacing( orient )
		local part = MC.BedOrientPart( orient )
		local dx, dy = MC.HorizontalDirectionOffset( facing )
		local otherX = part == "head" and bx - dx or bx + dx
		local otherY = part == "head" and by - dy or by + dy
		local wantPart = part == "head" and "foot" or "head"
		local otherId = MC.GetBlock( otherX, otherY, bz )
		local otherOrient = MC.GetBlockOrient( otherX, otherY, bz )
		if matchingBedPart( otherId, otherOrient, facing, wantPart ) then
			addCell( cells, seen, otherX, otherY, bz, 0, 0 )
		end
	end
	local primaryChangeCount = #cells
	appendRegisteredStateUpdates( cells, seen, primaryChangeCount )
	appendBlockConnectionUpdates( cells, seen, primaryChangeCount )
	appendRedstoneUpdates( cells, seen, primaryChangeCount )
	appendRailUpdates( cells, seen, primaryChangeCount )
	appendNeighbourStateUpdates( cells, seen, primaryChangeCount )

	return {
		bx = bx, by = by, bz = bz,
		id = id,
		orient = orient,
		cells = cells,
	}
end

function MC.CanPreviewPlacePlan( ply, plan )
	if not plan or not plan.cells or not MC.CanPreviewPlace then return false end
	for _, cell in ipairs( plan.cells ) do
		if not cell.updateExisting and not MC.CanPreviewPlace( ply, cell.bx, cell.by, cell.bz, cell.id, cell.orient, cell.stateId ) then return false end
	end
	return true
end
