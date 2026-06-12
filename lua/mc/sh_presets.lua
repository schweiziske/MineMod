--[[----------------------------------------------------------------------------
	MC : shared preset transform helpers.

	Presets are saved in grid coordinates relative to the captured min corner.
	Rotation is a 0..3 quarter-turn around the saved anchor cell on the Z axis.
------------------------------------------------------------------------------]]

MC = MC or {}

local function int( value, default )
	return math.floor( tonumber( value ) or default or 0 )
end

function MC.PresetNormalizeRotation( rotation )
	return int( rotation, 0 ) % 4
end

function MC.PresetRotationDegrees( rotation )
	return MC.PresetNormalizeRotation( rotation ) * 90
end

local function rotateXY( x, y, rotation )
	rotation = MC.PresetNormalizeRotation( rotation )
	if rotation == 1 then return -y, x end
	if rotation == 2 then return -x, -y end
	if rotation == 3 then return y, -x end
	return x, y
end

local function anchorXYZ( data )
	local anchor = data and data.anchor or {}
	return int( anchor[1], 0 ), int( anchor[2], 0 ), int( anchor[3], 0 )
end

function MC.PresetRotateLocalCell( data, dx, dy, dz, rotation )
	local ax, ay = anchorXYZ( data )
	local rx, ry = rotateXY( int( dx, 0 ) - ax, int( dy, 0 ) - ay, rotation )
	return ax + rx, ay + ry, int( dz, 0 )
end

function MC.PresetRotateAnchorNormal( data, rotation )
	local anchor = data and data.anchor or {}
	local nx, ny = rotateXY( int( anchor[4], 0 ), int( anchor[5], 0 ), rotation )
	return nx, ny, int( anchor[6], 1 )
end

local HorizontalClockwise = {}

local function rebuildDirectionTables()
	if not MC.Direction then return end
	HorizontalClockwise[MC.Direction.NORTH] = MC.Direction.EAST
	HorizontalClockwise[MC.Direction.EAST] = MC.Direction.SOUTH
	HorizontalClockwise[MC.Direction.SOUTH] = MC.Direction.WEST
	HorizontalClockwise[MC.Direction.WEST] = MC.Direction.NORTH
end

function MC.PresetRotateHorizontalDirection( dir, rotation )
	if not MC.Direction then return dir end
	if not HorizontalClockwise[MC.Direction.NORTH] then rebuildDirectionTables() end
	dir = int( dir, 0 )
	for _ = 1, MC.PresetNormalizeRotation( rotation ) do
		dir = HorizontalClockwise[dir] or dir
	end
	return dir
end

function MC.PresetRotateBlockOrient( id, orient, rotation )
	rotation = MC.PresetNormalizeRotation( rotation )
	local b = MC.Blocks and MC.Blocks[id] or nil
	if not b then return 0 end

	orient = MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or int( orient, 0 )
	if rotation == 0 then return orient end

	if b.orient == "axis" then
		if rotation % 2 == 1 then
			if orient == MC.Axis.X then return MC.Axis.Z end
			if orient == MC.Axis.Z then return MC.Axis.X end
		end
		return orient
	end

	if b.orient == "horizontal_facing" then
		return MC.PresetRotateHorizontalDirection( orient, rotation )
	end

	if b.orient == "facing" then
		return MC.PresetRotateHorizontalDirection( orient, rotation )
	end

	if b.orient == "stairs" then
		return MC.MakeStairOrient(
			MC.PresetRotateHorizontalDirection( MC.StairOrientFacing( orient ), rotation ),
			MC.StairOrientHalf( orient )
		)
	end

	if b.orient == "door" then
		return MC.MakeDoorOrient(
			MC.PresetRotateHorizontalDirection( MC.DoorOrientFacing( orient ), rotation ),
			MC.DoorOrientHalf( orient ),
			MC.DoorOrientOpen( orient )
		)
	end

	if b.orient == "bed" then
		return MC.MakeBedOrient(
			MC.PresetRotateHorizontalDirection( MC.BedOrientFacing( orient ), rotation ),
			MC.BedOrientPart( orient )
		)
	end

	return orient
end

local function originXYZ( origin )
	return int( origin and origin.bx, 0 ), int( origin and origin.by, 0 ), int( origin and origin.bz, 0 )
end

function MC.PresetCells( data, origin, rotation )
	local out = {}
	if not data or type( data.cells ) ~= "table" then return out end

	local ox, oy, oz = originXYZ( origin )
	for _, cell in ipairs( data.cells ) do
		local dx = int( cell[1], 0 )
		local dy = int( cell[2], 0 )
		local dz = int( cell[3], 0 )
		local id = int( cell[4], 0 )
		local tx, ty, tz = MC.PresetRotateLocalCell( data, dx, dy, dz, rotation )
		out[#out + 1] = {
			bx = ox + tx,
			by = oy + ty,
			bz = oz + tz,
			dx = tx,
			dy = ty,
			dz = tz,
			id = id,
			orient = MC.PresetRotateBlockOrient( id, cell[5], rotation ),
		}
	end
	return out
end

function MC.PresetClearCells( data, origin, rotation )
	local out = {}
	local size = data and data.size or {}
	local sx = math.max( 0, int( size[1], 0 ) )
	local sy = math.max( 0, int( size[2], 0 ) )
	local sz = math.max( 0, int( size[3], 0 ) )
	local ox, oy, oz = originXYZ( origin )

	for dz = 0, sz - 1 do
		for dy = 0, sy - 1 do
			for dx = 0, sx - 1 do
				local tx, ty, tz = MC.PresetRotateLocalCell( data, dx, dy, dz, rotation )
				out[#out + 1] = {
					bx = ox + tx,
					by = oy + ty,
					bz = oz + tz,
				}
			end
		end
	end
	return out
end
