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

-- Blocks.java Properties.replaceable(), excluding snow's state-specific rule.
-- Collision/selection shape is deliberately not used as a replacement policy.
local REPLACEABLE = {}
for name in string.gmatch( "air water lava short_grass fern dead_bush bush short_dry_grass tall_dry_grass seagrass tall_seagrass fire soul_fire vine glow_lichen resin_clump light tall_grass large_fern structure_void void_air cave_air bubble_column warped_roots nether_sprouts crimson_roots leaf_litter hanging_roots", "%S+" ) do
	REPLACEABLE["minecraft:" .. name] = true
end

function MC.PlacementCanReplaceState( existingState, placedState )
	if existingState == 0 then return true end
	local oldId, newId = MC.BlockTypeForState( existingState ), MC.BlockTypeForState( placedState )
	local oldBlock, newBlock = MC.Blocks[oldId], MC.Blocks[newId]
	if not oldBlock or not newBlock then return false end
	if oldId == newId and oldBlock.orient == "slab" then
		return MC.GetStateProperty( existingState, "type" ) ~= "double"
			and MC.GetStateProperty( placedState, "type" ) == "double"
	end
	if oldBlock.mcid == "minecraft:snow" then
		local layers = MC.GetStateProperty( existingState, "layers" )
		if oldId == newId then return layers < 8 and MC.GetStateProperty( placedState, "layers" ) == layers + 1 end
		return layers == 1
	end
	return oldId ~= newId and REPLACEABLE[oldBlock.mcid] == true
end

function MC.PlacementUsesClickedCell( existingState, placedId, hit, bz )
	if existingState == 0 then return true end
	local oldId = MC.BlockTypeForState( existingState )
	local block = MC.Blocks[oldId]
	if not block then return false end
	if oldId == placedId and block.orient == "slab" then
		local half = MC.GetStateProperty( existingState, "type" )
		local normal = hit.HitNormal
		local aboveHalf = hit.HitPos.z / MC.API.Coords.BlockSize() - bz > 0.5
		return half == "bottom" and ( normal.z > 0 or normal.z == 0 and aboveHalf )
			or half == "top" and ( normal.z < 0 or normal.z == 0 and not aboveHalf )
	end
	if block.mcid == "minecraft:snow" then
		local layers = MC.GetStateProperty( existingState, "layers" )
		if oldId == placedId then return layers < 8 and hit.HitNormal.z > 0 end
		return layers == 1
	end
	return oldId ~= placedId and REPLACEABLE[block.mcid] == true
end

function MC.ResolveStackedPlacementState( bx, by, bz, stateId, hit )
	local existingState = MC.GetBlockState( bx, by, bz )
	local id = MC.BlockTypeForState( stateId )
	local block = MC.Blocks[id]
	if MC.BlockTypeForState( existingState ) == id then
		if block.orient == "slab" and MC.GetStateProperty( existingState, "type" ) ~= "double" then
			local combined = MC.StateWith( existingState, "type", "double" )
			return MC.StateWith( combined, "waterlogged", false ) or combined
		elseif block.mcid == "minecraft:snow" then
			return MC.StateWith( existingState, "layers", math.min( 8, MC.GetStateProperty( existingState, "layers" ) + 1 ) )
		end
	elseif block.orient == "slab" then
		local normal = hit.HitNormal
		local aboveHalf = hit.HitPos.z / MC.API.Coords.BlockSize() - bz > 0.5
		local half = normal.z < 0 or normal.z == 0 and aboveHalf
		return MC.StateWith( stateId, "type", half and "top" or "bottom" )
	end
	return stateId
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

-- SimpleWaterloggedBlock#getStateForPlacement: a block placed into source water
-- takes the water inside itself instead of deleting it. Blocks with no
-- waterlogged property just displace the fluid.
--
-- Java gates this on `fluidstate.getType() == Fluids.WATER`, which is only true
-- for a *source* FluidState -- flowing water reports Fluids.FLOWING_WATER and is
-- displaced. Lava is never absorbed.
local function resolveWaterloggedPlacementState( bx, by, bz, stateId )
	if not MC.StateWith or not MC.LiquidStateMetrics or not MC.GetBlockState then return stateId end
	local kind, _, level, falling, waterlogged = MC.LiquidStateMetrics( MC.GetBlockState( bx, by, bz ) or 0 )
	if kind ~= "water" or waterlogged == true then return stateId end
	if math.floor( tonumber( level ) or -1 ) ~= 0 or falling == true then return stateId end
	return MC.StateWith( stateId, "waterlogged", true ) or stateId
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

-- context carries placement intent that state providers need but cannot derive
-- from the cells alone -- currently secondaryUse (sneaking), which suppresses
-- the automatic double-chest merge. It MUST be stamped before the providers
-- run below, which is why it is a plan input rather than something the caller
-- patches onto plan.cells afterwards.
function MC.BuildPlacementStatePlan( bx, by, bz, stateId, context )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId <= 0 or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil end
	if MC.ResolveRedstonePlacementState then
		stateId = MC.ResolveRedstonePlacementState( stateId, bx, by, bz ) or stateId
	end
	stateId = resolveWaterloggedPlacementState( bx, by, bz, stateId )
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
	if istable( context ) and context.secondaryUse == true then
		for index = 1, primaryChangeCount do cells[index].secondaryUse = true end
	end
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
	-- A fluid block has no break plan, for the same reason an empty cell has
	-- none: LiquidBlock#getShape is Shapes.empty(), so there is nothing to break.
	-- Sitting here rather than in the server validator covers every consumer at
	-- once -- SV.Break, mining's preflight, and client break prediction -- and
	-- never burns the write cooldown on an attempt that cannot succeed. A bucket
	-- takes fluid out instead, through API.Liquid.
	if MC.CellIsFluidBlock and MC.CellIsFluidBlock( bx, by, bz ) then return nil end
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
