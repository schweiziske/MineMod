--[[----------------------------------------------------------------------------
	MC : shared preset transform helpers.

	Presets are saved in grid coordinates relative to the captured min corner.
	Rotation is a 0..3 quarter-turn around the saved anchor cell on the Z axis.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.PRESET_MAX_JSON_BYTES = 32 * 1024 * 1024

function MC.DecodePresetJSON( json )
	if type( json ) ~= "string" or #json > MC.PRESET_MAX_JSON_BYTES then return nil end
	-- A preset uses several JSON keys per block, exceeding GMod's default
	-- 15,000-key limit well before the preset block limit is reached.
	return util.JSONToTable( json, true )
end

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
			MC.DoorOrientOpen( orient ),
			MC.DoorOrientHinge( orient ),
			MC.DoorOrientPowered( orient )
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

local HorizontalFacingClockwise = {
	north = "east",
	east = "south",
	south = "west",
	west = "north",
}

function MC.PresetRotateState( stateId, rotation )
	rotation = MC.PresetNormalizeRotation( rotation )
	stateId = int( stateId, -1 )
	if rotation == 0 or not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return stateId end

	local facing = MC.GetStateProperty and MC.GetStateProperty( stateId, "facing" ) or nil
	if HorizontalFacingClockwise[facing] then
		for _ = 1, rotation do facing = HorizontalFacingClockwise[facing] end
		stateId = MC.StateWith( stateId, "facing", facing ) or stateId
	end

	local axis = MC.GetStateProperty and MC.GetStateProperty( stateId, "axis" ) or nil
	if rotation % 2 == 1 and ( axis == "x" or axis == "z" ) then
		stateId = MC.StateWith( stateId, "axis", axis == "x" and "z" or "x" ) or stateId
	end

	local signRotation = MC.GetStateProperty and MC.GetStateProperty( stateId, "rotation" ) or nil
	if tonumber( signRotation ) then
		stateId = MC.StateWith( stateId, "rotation", ( int( signRotation, 0 ) + rotation * 4 ) % 16 ) or stateId
	end

	-- Connection-style states (fences, walls, panes, redstone wire, multiface
	-- blocks) store one property per horizontal side. Move those values with
	-- the structure instead of leaving their north/east/south/west labels behind.
	local cardinal = { "north", "east", "south", "west" }
	local cardinalValues = {}
	local hasCardinal = false
	for index = 1, 4 do
		local value = MC.GetStateProperty and MC.GetStateProperty( stateId, cardinal[index] ) or nil
		if value ~= nil then
			cardinalValues[index] = value
			hasCardinal = true
		end
	end
	if hasCardinal then
		for index = 1, 4 do
			local value = cardinalValues[index]
			if value ~= nil then
				local target = cardinal[( index - 1 + rotation ) % 4 + 1]
				stateId = MC.StateWith( stateId, target, value ) or stateId
			end
		end
	end
	return stateId
end

function MC.PresetCellState( cell )
	if type( cell ) ~= "table" then return nil, "invalid_preset_cell" end
	local savedState = cell[6] or cell.state
	if savedState ~= nil and savedState ~= "" and MC.ParseBlockState then
		local stateId, err = MC.ParseBlockState( savedState )
		if stateId then return stateId end
		return nil, err or "invalid_saved_state"
	end
	if not MC.StateFromLegacy then return nil, "state_registry_unavailable" end
	local stateId, _, err = MC.StateFromLegacy( int( cell[4], 0 ), int( cell[5], 0 ) )
	return stateId, err
end

local function originXYZ( origin )
	return int( origin and origin.bx, 0 ), int( origin and origin.by, 0 ), int( origin and origin.bz, 0 )
end

function MC.PresetCells( data, origin, rotation )
	local out = {}
	if not data or type( data.cells ) ~= "table" then return out end

	local ox, oy, oz = originXYZ( origin )
	local specs, rotations, projections = {}, {}, {}
	for _, cell in ipairs( data.cells ) do
		local dx = int( cell[1], 0 )
		local dy = int( cell[2], 0 )
		local dz = int( cell[3], 0 )
		local savedId = int( cell[4], 0 )
		local spec = cell[6] or cell.state
		local cacheSpec = type( spec ) == "string" and spec ~= ""
		local cached = cacheSpec and specs[spec] or nil
		local stateId, stateError
		if cached then
			stateId, stateError = cached[1], cached[2]
		else
			stateId, stateError = MC.PresetCellState( cell )
			if cacheSpec then specs[spec] = { stateId, stateError } end
		end
		if stateId then
			local rotated = rotations[stateId]
			if rotated == nil then
				rotated = MC.PresetRotateState( stateId, rotation )
				rotations[stateId] = rotated
			end
			stateId = rotated
		end
		local id, orient
		if stateId and MC.LegacyFromState then
			local projection = projections[stateId]
			if not projection then
				id, orient = MC.LegacyFromState( stateId )
				projection = { id, orient }
				projections[stateId] = projection
			end
			id, orient = projection[1], projection[2]
		end
		id = int( id, savedId )
		orient = orient ~= nil and orient or MC.PresetRotateBlockOrient( id, cell[5], rotation )
		local tx, ty, tz = MC.PresetRotateLocalCell( data, dx, dy, dz, rotation )
		out[#out + 1] = {
			bx = ox + tx,
			by = oy + ty,
			bz = oz + tz,
			dx = tx,
			dy = ty,
			dz = tz,
			id = id,
			orient = orient,
			stateId = stateId,
			stateError = stateError,
		}
	end
	return out
end

-- Inclusive block-cell bounds; quarter turns retain an axis-aligned box.
function MC.PresetBounds( data, origin, rotation )
	local size = data and data.size or {}
	local sx, sy, sz = int( size[1], 0 ), int( size[2], 0 ), int( size[3], 0 )
	if sx < 1 or sy < 1 or sz < 1 then return nil end
	local ox, oy, oz = originXYZ( origin )
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	for _, corner in ipairs( { { 0, 0 }, { sx - 1, 0 }, { 0, sy - 1 }, { sx - 1, sy - 1 } } ) do
		local x, y = MC.PresetRotateLocalCell( data, corner[1], corner[2], 0, rotation )
		minX, minY = math.min( minX, x ), math.min( minY, y )
		maxX, maxY = math.max( maxX, x ), math.max( maxY, y )
	end
	return ox + minX, oy + minY, oz, ox + maxX, oy + maxY, oz + sz - 1
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

local bundledCatalog, bundledCatalogTime
local BUNDLED_PRESET_ROOT = "data_static/mc/presets/"

-- Mounted addon content, not player DATA. Limits are derived from this
-- validated catalog only; a saved preset cannot declare itself bundled.
function MC.GetBundledPresetCatalog()
	local path = BUNDLED_PRESET_ROOT .. "catalog.json"
	if not file.Exists( path, "GAME" ) then return {} end
	local revision = file.Time( path, "GAME" ) or 0
	if bundledCatalog and bundledCatalogTime == revision then return bundledCatalog end
	local raw = file.Read( path, "GAME" )
	local document = raw and util.JSONToTable( raw )
	if type( document ) ~= "table" or document.v ~= 1 or type( document.presets ) ~= "table" then
		if MC.Fault then MC.Fault( "bundled_preset_catalog", "Invalid catalog: %s", path ) end
		return {}
	end
	local catalog, seen = {}, {}
	for _, entry in ipairs( document.presets ) do
		if type( entry ) ~= "table" then
			if MC.Fault then MC.Fault( "bundled_preset_catalog", "Invalid entry in %s", path ) end
			return {}
		end
		local size = type( entry.size ) == "table" and entry.size or {}
		local sx, sy, sz = int( size[1], 0 ), int( size[2], 0 ), int( size[3], 0 )
		local blocks = int( entry.blocks, 0 )
		local valid = type( entry.name ) == "string" and #entry.name <= 64
			and string.match( entry.name, "^builtin_[a-z0-9_%-]+$" ) and not seen[entry.name]
			and type( entry.file ) == "string" and string.match( entry.file, "^[a-z0-9_%-]+%.json$" )
			and type( entry.cover ) == "string" and string.match( entry.cover, "^mc/preset_covers/[a-z0-9_%-]+%.jpg$" )
			and type( entry.titleKey ) == "string" and string.match( entry.titleKey, "^[a-z0-9_%.]+$" )
			and sx > 0 and sy > 0 and sz > 0 and sx <= 65535 and sy <= 65535 and sz <= 65535
			and blocks > 0 and blocks <= sx * sy * sz
		if not valid then
			if MC.Fault then MC.Fault( "bundled_preset_catalog", "Invalid entry in %s", path ) end
			return {}
		end
		seen[entry.name] = true
		catalog[#catalog + 1] = {
			name = entry.name, path = BUNDLED_PRESET_ROOT .. entry.file,
			cover = entry.cover, titleKey = entry.titleKey, bundled = true,
			map = entry.map or "unknown", blocks = blocks, size = { sx, sy, sz },
			volume = sx * sy * sz, createdAtText = entry.createdAtText or "?",
		}
	end
	bundledCatalog, bundledCatalogTime = catalog, revision
	return catalog
end

function MC.GetBundledPresetDefinition( name )
	for _, entry in ipairs( MC.GetBundledPresetCatalog() ) do
		if entry.name == name then return entry end
	end
end
