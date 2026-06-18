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
	local key = bx .. ":" .. by .. ":" .. bz
	if seen[key] then return end
	seen[key] = true
	cells[#cells + 1] = {
		bx = bx, by = by, bz = bz,
		id = id or 0,
		orient = orient or 0,
	}
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
	local cells = {}
	local seen = {}

	if MC.IsDoorBlock( id ) then
		local facing = MC.DoorOrientFacing( orient )
		local open = MC.DoorOrientOpen( orient )
		local hinge = MC.DoorOrientHinge( orient )
		local powered = MC.DoorOrientPowered( orient )
		addCell( cells, seen, bx, by, bz, id, MC.MakeDoorOrient( facing, "lower", open, hinge, powered ) )
		addCell( cells, seen, bx, by, bz + 1, id, MC.MakeDoorOrient( facing, "upper", open, hinge, powered ) )
	elseif MC.IsBedBlock( id ) then
		local facing = MC.BedOrientFacing( orient )
		local dx, dy = MC.HorizontalDirectionOffset( facing )
		addCell( cells, seen, bx, by, bz, id, MC.MakeBedOrient( facing, "foot" ) )
		addCell( cells, seen, bx + dx, by + dy, bz, id, MC.MakeBedOrient( facing, "head" ) )
	else
		addCell( cells, seen, bx, by, bz, id, orient )
	end

	return {
		bx = bx, by = by, bz = bz,
		id = id,
		orient = orient,
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
		if not MC.CanPreviewPlace( ply, cell.bx, cell.by, cell.bz, cell.id, cell.orient ) then return false end
	end
	return true
end
