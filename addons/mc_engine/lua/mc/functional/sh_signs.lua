--[[----------------------------------------------------------------------------
	MC functional block: vanilla plain and hanging signs.

	StandingSignBlock, WallSignBlock, CeilingHangingSignBlock,
	WallHangingSignBlock and their Block Entities are the authoritative behavior
	references. Text is sparse Block Entity data; signs do not allocate GMod
	entities.
------------------------------------------------------------------------------]]

MC = MC or {}

local SIGN_TYPE = "minecraft:sign"
local HANGING_SIGN_TYPE = "minecraft:hanging_sign"
local PLAIN_MAX_LINE_WIDTH = 90
local HANGING_MAX_LINE_WIDTH = 60
local MAX_LINE_CODEPOINTS = 384
local FALLBACK_ADVANCE = 9

-- BitmapProvider derives advance from the right-most opaque pixel plus one.
-- These are the exact advances extracted from out's 8x8 ascii.png cells.
local ASCII_ADVANCES = string.char(
	4,2,4,6,6,6,6,2,4,4,4,6,2,6,2,6,
	6,6,6,6,6,6,6,6,6,6,2,2,5,6,5,6,
	7,6,6,6,6,6,6,6,6,4,6,6,6,6,6,6,
	6,6,6,6,6,6,6,6,6,6,6,4,6,4,6,6,
	3,6,6,6,6,6,5,6,6,2,6,5,3,6,6,6,
	6,6,6,6,4,6,6,6,6,6,6,4,2,4,7
)

local HorizontalOffset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
}

local function plainSignName( name )
	return isstring( name )
		and string.match( name, "_sign$" ) ~= nil
		and string.find( name, "hanging_sign", 1, true ) == nil
end

local function hangingSignName( name )
	return isstring( name ) and string.match( name, "_hanging_sign$" ) ~= nil
end

local function editableSignName( name )
	return plainSignName( name ) or hangingSignName( name )
end

function MC.IsPlainSignState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and plainSignName( schema.name ) or false
end

function MC.IsHangingSignState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and hangingSignName( schema.name ) or false
end

function MC.IsEditableSignState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and editableSignName( schema.name ) or false
end

function MC.SignMaxLineWidthForState( stateId )
	return MC.IsHangingSignState( stateId ) and HANGING_MAX_LINE_WIDTH or PLAIN_MAX_LINE_WIDTH
end

local function utf8Next( text, index )
	local first = string.byte( text, index )
	if not first then return nil end
	if first < 0x80 then return first, index + 1 end
	local needed, value
	if first >= 0xC2 and first <= 0xDF then needed, value = 1, first - 0xC0
	elseif first >= 0xE0 and first <= 0xEF then needed, value = 2, first - 0xE0
	elseif first >= 0xF0 and first <= 0xF4 then needed, value = 3, first - 0xF0
	else return nil end
	local nextIndex = index + needed + 1
	if nextIndex - 1 > #text then return nil end
	for offset = 1, needed do
		local byte = string.byte( text, index + offset )
		if not byte or byte < 0x80 or byte > 0xBF then return nil end
		value = value * 64 + byte - 0x80
	end
	if needed == 2 and value < 0x800 or needed == 3 and value < 0x10000
	or value >= 0xD800 and value <= 0xDFFF or value > 0x10FFFF then return nil end
	return value, nextIndex
end

function MC.SignGlyphAdvance( codepoint )
	if codepoint >= 32 and codepoint <= 126 then
		return string.byte( ASCII_ADVANCES, codepoint - 31 ) or FALLBACK_ADVANCE
	end
	return FALLBACK_ADVANCE
end

function MC.SignMeasureLine( text, maxWidth )
	if not isstring( text ) then return nil, nil, "invalid_line" end
	maxWidth = math.max( 1, math.floor( tonumber( maxWidth ) or PLAIN_MAX_LINE_WIDTH ) )
	local width, count, index = 0, 0, 1
	while index <= #text do
		local codepoint, nextIndex = utf8Next( text, index )
		if not codepoint then return nil, nil, "invalid_utf8" end
		if codepoint < 32 or codepoint == 127 then return nil, nil, "control_character" end
		count = count + 1
		if count > MAX_LINE_CODEPOINTS then return nil, nil, "line_too_long" end
		width = width + MC.SignGlyphAdvance( codepoint )
		if width > maxWidth then return width, count, "line_too_wide" end
		index = nextIndex
	end
	return width, count
end

function MC.ValidateSignLines( lines, maxWidth )
	if not istable( lines ) then return false, "invalid_lines" end
	local normalized = {}
	for index = 1, 4 do
		local line = lines[index]
		if not isstring( line ) then return false, "missing_line" end
		local _, _, err = MC.SignMeasureLine( line, maxWidth )
		if err then return false, err end
		normalized[index] = line
	end
	if lines[5] ~= nil then return false, "too_many_lines" end
	return true, normalized
end

local function defaultData()
	return { lines = { "", "", "", "" } }
end

local function normalizeData( data, maxWidth )
	if not istable( data ) then return nil, "invalid_sign_data" end
	local ok, lines = MC.ValidateSignLines( data.lines, maxWidth )
	if not ok then return nil, lines end
	return { lines = lines }
end

-- Generated schemas deliberately contain only block-state properties. Attach
-- the vanilla Block Entity type before the deferred immutable registry freeze.
for name, schema in pairs( MC.PendingBlockStateSchemas or {} ) do
	if hangingSignName( name ) then schema.blockEntityType = HANGING_SIGN_TYPE
	elseif plainSignName( name ) then schema.blockEntityType = SIGN_TYPE end
end

local function registerSignBlockEntityType( typeName, maxWidth )
	MC.RegisterBlockEntityType( {
		name = typeName,
		codecVersion = 1,
		affectsGeometry = false,
		affectsCollision = false,
		CreateDefault = function()
			return { type = typeName, codecVersion = 1, data = defaultData() }
		end,
		Validate = function( data )
			local normalized, err = normalizeData( data, maxWidth )
			return normalized ~= nil, err
		end,
		Encode = function( data )
			return normalizeData( data, maxWidth )
		end,
		Decode = function( data )
			return normalizeData( data, maxWidth )
		end,
	} )
end

registerSignBlockEntityType( SIGN_TYPE, PLAIN_MAX_LINE_WIDTH )
registerSignBlockEntityType( HANGING_SIGN_TYPE, HANGING_MAX_LINE_WIDTH )

local function facingForNormal( normal )
	if math.abs( normal.x or 0 ) >= math.abs( normal.y or 0 ) then
		return ( normal.x or 0 ) >= 0 and "east" or "west"
	end
	return ( normal.y or 0 ) >= 0 and "south" or "north"
end

local function standingRotation( ply )
	local forward = IsValid( ply ) and ply:EyeAngles():Forward() or nil
	if not forward then return 8 end
	local degrees = math.deg( math.atan2( -forward.x, forward.y ) ) + 180
	return math.floor( degrees * 16 / 360 + 0.5 ) % 16
end

local function cardinalRotation( rotation )
	return math.floor( ( ( tonumber( rotation ) or 0 ) + 2 ) / 4 ) % 4 * 4
end

local function rotationAxis( rotation )
	return cardinalRotation( rotation ) % 8 == 0 and "y" or "x"
end

local function facingAxis( facing )
	return ( facing == "east" or facing == "west" ) and "x" or "y"
end

local function secondaryUseActive( ply )
	return IsValid( ply ) and ply.KeyDown and ply:KeyDown( IN_SPEED ) == true
end

local function signFamilyNames( name )
	if hangingSignName( name ) then
		if string.match( name, "_wall_hanging_sign$" ) then
			return string.gsub( name, "_wall_hanging_sign$", "_hanging_sign" ), name, true
		end
		return name, string.gsub( name, "_hanging_sign$", "_wall_hanging_sign" ), true
	end
	if not plainSignName( name ) then return nil end
	if string.match( name, "_wall_sign$" ) then
		return string.gsub( name, "_wall_sign$", "_sign" ), name, false
	end
	return name, string.gsub( name, "_sign$", "_wall_sign" ), false
end

local function copyWaterlogged( sourceState, targetState )
	local waterlogged = MC.GetStateProperty and MC.GetStateProperty( sourceState, "waterlogged" ) or nil
	if waterlogged ~= nil then targetState = MC.StateWith( targetState, "waterlogged", waterlogged ) or targetState end
	return targetState
end

function MC.SignSupportCell( bx, by, bz, stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema or not editableSignName( schema.name ) then return nil end
	if hangingSignName( schema.name ) then
		if string.match( schema.name, "_wall_hanging_sign$" ) then return nil end
		return bx, by, bz + 1
	end
	if not string.match( schema.name, "_wall_sign$" ) then return bx, by, bz - 1 end
	local offset = HorizontalOffset[MC.GetStateProperty( stateId, "facing" )]
	if not offset then return nil end
	return bx - offset[1], by - offset[2], bz - offset[3]
end

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

local function fullCubeAt( bx, by, bz, stateId )
	stateId = stateId or ( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 )
	if stateId == 0 then return false end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true then return true end
	local id, orient
	if MC.LegacyFromState then id, orient = MC.LegacyFromState( stateId ) end
	return id ~= nil and MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient or 0 ) == true or false
end

local FACE_EPSILON = 0.00001

local function collisionBoxesAt( bx, by, bz, stateId )
	local shape = MC.ResolveBlockStateCollision and MC.ResolveBlockStateCollision( stateId, bx, by, bz ) or nil
	return shape and shape.boxes or nil
end

local function bottomFaceCenterSupport( bx, by, bz, stateId )
	if fullCubeAt( bx, by, bz, stateId ) then return true end
	for _, box in ipairs( collisionBoxesAt( bx, by, bz, stateId ) or {} ) do
		if box[3] <= FACE_EPSILON and box[1] <= 0.5 and box[4] >= 0.5
		and box[2] <= 0.5 and box[5] >= 0.5 then return true end
	end
	return false
end

local function bottomFaceFull( bx, by, bz, stateId )
	if fullCubeAt( bx, by, bz, stateId ) then return true end
	for _, box in ipairs( collisionBoxesAt( bx, by, bz, stateId ) or {} ) do
		if box[3] <= FACE_EPSILON and box[1] <= FACE_EPSILON and box[2] <= FACE_EPSILON
		and box[4] >= 1 - FACE_EPSILON and box[5] >= 1 - FACE_EPSILON then return true end
	end
	return false
end

local function sideFaceFull( bx, by, bz, stateId, dx, dy )
	if fullCubeAt( bx, by, bz, stateId ) then return true end
	for _, box in ipairs( collisionBoxesAt( bx, by, bz, stateId ) or {} ) do
		if dx < 0 and box[4] >= 1 - FACE_EPSILON and box[2] <= FACE_EPSILON
		and box[5] >= 1 - FACE_EPSILON and box[3] <= FACE_EPSILON and box[6] >= 1 - FACE_EPSILON then return true end
		if dx > 0 and box[1] <= FACE_EPSILON and box[2] <= FACE_EPSILON
		and box[5] >= 1 - FACE_EPSILON and box[3] <= FACE_EPSILON and box[6] >= 1 - FACE_EPSILON then return true end
		if dy < 0 and box[5] >= 1 - FACE_EPSILON and box[1] <= FACE_EPSILON
		and box[4] >= 1 - FACE_EPSILON and box[3] <= FACE_EPSILON and box[6] >= 1 - FACE_EPSILON then return true end
		if dy > 0 and box[2] <= FACE_EPSILON and box[1] <= FACE_EPSILON
		and box[4] >= 1 - FACE_EPSILON and box[3] <= FACE_EPSILON and box[6] >= 1 - FACE_EPSILON then return true end
	end
	return false
end

local function sameHorizontalAxis( first, second )
	local firstX = first == "east" or first == "west"
	local secondX = second == "east" or second == "west"
	return firstX == secondX
end

local function hangingSideSupport( bx, by, bz, facing, dx, dy )
	local sx, sy = bx + dx, by + dy
	local supportState = MC.GetBlockState and MC.GetBlockState( sx, sy, bz ) or 0
	if sideFaceFull( sx, sy, bz, supportState, dx, dy ) then return true end
	local supportName = stateName( supportState )
	if not supportName or not string.match( supportName, "_wall_hanging_sign$" ) then return false end
	return sameHorizontalAxis( facing, MC.GetStateProperty( supportState, "facing" ) )
end

function MC.SignCanSurvive( bx, by, bz, stateId )
	local name = stateName( stateId )
	if hangingSignName( name ) then
		if not string.match( name, "_wall_hanging_sign$" ) then
			local supportState = MC.GetBlockState and MC.GetBlockState( bx, by, bz + 1 ) or 0
			return bottomFaceCenterSupport( bx, by, bz + 1, supportState )
				or hangingSignName( stateName( supportState ) )
		end
		local facing = MC.GetStateProperty( stateId, "facing" )
		if facing == "north" or facing == "south" then
			return hangingSideSupport( bx, by, bz, facing, -1, 0 )
				or hangingSideSupport( bx, by, bz, facing, 1, 0 )
		end
		if facing == "east" or facing == "west" then
			return hangingSideSupport( bx, by, bz, facing, 0, -1 )
				or hangingSideSupport( bx, by, bz, facing, 0, 1 )
		end
		return false
	end
	local sx, sy, sz = MC.SignSupportCell( bx, by, bz, stateId )
	if sx == nil then return false end
	local supportState = MC.GetBlockState and MC.GetBlockState( sx, sy, sz ) or 0
	return fullCubeAt( sx, sy, sz, supportState )
end

local function hangingWallFacing( hitNormal, ply )
	local forward = IsValid( ply ) and ply:EyeAngles():Forward() or nil
	local nx, ny = tonumber( hitNormal and hitNormal.x ) or 0, tonumber( hitNormal and hitNormal.y ) or 0
	-- Wall hanging signs project out from the clicked face and are held at their
	-- two side ends, so their facing axis must be perpendicular to that face.
	if math.abs( nx ) >= math.abs( ny ) then
		local towardPlayer = forward and -forward.y or 1
		return towardPlayer >= 0 and "south" or "north"
	end
	local towardPlayer = forward and -forward.x or 1
	return towardPlayer >= 0 and "east" or "west"
end


local function ceilingHangingPlacement( targetState, ply, bx, by, bz )
	local rotation = standingRotation( ply )
	local supportState = bx ~= nil and MC.GetBlockState and MC.GetBlockState( bx, by, bz + 1 ) or 0
	local supportName = stateName( supportState )
	local secondary = secondaryUseActive( ply )
	local attached = not bottomFaceFull( bx or 0, by or 0, ( bz or 0 ) + 1, supportState ) or secondary

	-- CeilingHangingSignBlock preserves the two outer chains when it is below a
	-- compatible hanging sign and the player is not forcing secondary placement.
	if hangingSignName( supportName ) and not secondary then
		local playerAxis = rotationAxis( rotation )
		if string.match( supportName, "_wall_hanging_sign$" ) then
			if facingAxis( MC.GetStateProperty( supportState, "facing" ) ) == playerAxis then attached = false end
		else
			local supportRotation = tonumber( MC.GetStateProperty( supportState, "rotation" ) )
			if supportRotation and supportRotation % 4 == 0 and rotationAxis( supportRotation ) == playerAxis then
				attached = false
			end
		end
	end

	-- The outer-chain model is cardinal. The centered attachment keeps all 16
	-- rotation segments, matching context rotation + 180 in Minecraft.
	rotation = attached and rotation or cardinalRotation( rotation )
	targetState = MC.StateWith( targetState, "rotation", rotation )
	return targetState and MC.StateWith( targetState, "attached", attached ) or nil
end

local function placementSupportAllowsHit( bx, by, bz, stateId, hitNormal, hanging, ceiling )
	if bx == nil or not MC.GetBlockState then return true end
	local nx = math.Round( tonumber( hitNormal and hitNormal.x ) or 0 )
	local ny = math.Round( tonumber( hitNormal and hitNormal.y ) or 0 )
	local nz = math.Round( tonumber( hitNormal and hitNormal.z ) or 0 )
	local sx, sy, sz = bx - nx, by - ny, bz - nz
	local supportState = MC.GetBlockState( sx, sy, sz ) or 0
	if supportState == 0 then return false end
	if not hanging then return fullCubeAt( sx, sy, sz, supportState ) end
	local supportName = stateName( supportState )
	if ceiling then
		return bottomFaceCenterSupport( sx, sy, sz, supportState ) or hangingSignName( supportName )
	end
	if fullCubeAt( sx, sy, sz, supportState ) then return true end
	return string.match( supportName or "", "_wall_hanging_sign$" ) ~= nil
		and sameHorizontalAxis( MC.GetStateProperty( stateId, "facing" ),
			MC.GetStateProperty( supportState, "facing" ) )
end

function MC.ResolveSignPlacementState( stateId, hitNormal, ply, bx, by, bz )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 1 then return stateId end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local groundName, wallName, hanging
	if schema then groundName, wallName, hanging = signFamilyNames( schema.name ) end
	if not groundName then return stateId end
	local normalZ = tonumber( hitNormal and hitNormal.z ) or 1
	if not hanging and normalZ < -0.5 then return nil, "sign_ceiling_unsupported" end
	if hanging and normalZ > 0.5 then return nil, "hanging_sign_floor_unsupported" end
	local ceiling = hanging and normalZ < -0.5
	local targetName
	if hanging then targetName = ceiling and groundName or wallName
	else targetName = normalZ > 0.5 and groundName or wallName end
	local targetSchema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[targetName] or nil
	if not targetSchema then return nil, "sign_state_missing" end
	local targetState = copyWaterlogged( stateId, targetSchema.defaultStateId )
	if targetName == groundName then
		targetState = hanging and ceilingHangingPlacement( targetState, ply, bx, by, bz )
			or MC.StateWith( targetState, "rotation", standingRotation( ply ) )
	else
		targetState = MC.StateWith( targetState, "facing",
			hanging and hangingWallFacing( hitNormal or {}, ply ) or facingForNormal( hitNormal or {} ) )
	end
	if not targetState then return nil, "sign_orientation_invalid" end
	if not placementSupportAllowsHit( bx, by, bz, targetState, hitNormal, hanging, ceiling ) then
		return nil, "sign_unsupported"
	end
	return targetState
end

local unsupportedUpdate = {
	OnNeighborUpdate = function( context )
		-- The generic transaction scheduler also enqueues the changed cell itself.
		-- Minecraft sign updateShape checks support-neighbour changes, not the
		-- sign's own placement/text transaction. Placement was already validated
		-- against the clicked face, so do not immediately delete it on self-update.
		if context.sourceX == context.bx and context.sourceY == context.by
		and context.sourceZ == context.bz and not context.sources then return nil end
		if MC.SignCanSurvive( context.bx, context.by, context.bz, context.stateId ) then return nil end
		local air = MC.DefaultBlockState and MC.DefaultBlockState( "minecraft:air" ) or 0
		return { dropResources = true, cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = air } } }
	end,
}

for name in pairs( MC.BlockByName or {} ) do
	if editableSignName( name ) then MC.RegisterBlockUpdateHandler( name, unsupportedUpdate ) end
end

-- The client must also know these blocks consume secondary attack; otherwise
-- it would predict an adjacent placement while the server opens the editor.
for _, id in ipairs( MC.BlockList or {} ) do
	local block = MC.Blocks[id]
	if block and editableSignName( block.mcid ) then
		block.handlers = block.handlers or {}
		if CLIENT then block.handlers.OnUse = function() return true end end
	end
end

if SERVER then
	MC.SV = MC.SV or {}
	local SV = MC.SV
	local Editors = setmetatable( {}, { __mode = "v" } )

	local function signRecord( bx, by, bz )
		local stateId = MC.GetBlockState( bx, by, bz )
		if not MC.IsEditableSignState( stateId ) then return nil end
		local record = MC.GetBlockEntity( bx, by, bz )
		if record then return record, stateId end
		local result = SV.SetBlockState( bx, by, bz, stateId, {
			fx = false, blockUpdates = false, compareCollision = false,
		} )
		if not result or result.ok ~= true then return nil end
		return MC.GetBlockEntity( bx, by, bz ), stateId
	end

	local function inRange( ply, bx, by, bz )
		if not IsValid( ply ) or not ply:IsPlayer() then return false end
		local reach = MC.CurrentReach and MC.CurrentReach() or ( ( MC.BS or 36.5 ) * 4 )
		return MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, reach ) == true
	end

	local function playerSelectedHangingSign( ply, selectedBlockID )
		selectedBlockID = math.floor( tonumber( selectedBlockID ) or -1 )
		local explicit = MC.Blocks and MC.Blocks[selectedBlockID] or nil
		if explicit and hangingSignName( explicit.mcid ) then return true end
		local selectedState = math.floor( tonumber( ply:GetNWInt( "mc_block_state", -1 ) ) or -1 )
		if selectedState >= 0 and MC.IsHangingSignState( selectedState ) then return true end
		local selectedID = math.floor( tonumber( ply:GetNWInt( "mc_block", -1 ) ) or -1 )
		local selected = MC.Blocks and MC.Blocks[selectedID] or nil
		return selected and hangingSignName( selected.mcid ) or false
	end

	local function hitNormalAxis( normal )
		local ax = math.abs( tonumber( normal and normal.x ) or 0 )
		local ay = math.abs( tonumber( normal and normal.y ) or 0 )
		local az = math.abs( tonumber( normal and normal.z ) or 0 )
		if az >= ax and az >= ay then return "z" end
		return ax >= ay and "x" or "y"
	end

	local function shouldChainHangingSign( ply, bx, by, bz, stateId, selectedBlockID )
		if not MC.IsHangingSignState( stateId )
		or not playerSelectedHangingSign( ply, selectedBlockID ) then return false end
		local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
		if not aim or aim.bx ~= bx or aim.by ~= by or aim.bz ~= bz then return false end
		local name = stateName( stateId )
		if string.match( name or "", "_wall_hanging_sign$" ) then
			-- WallHangingSignBlock edits only the two broad text faces. Hitting an
			-- edge, top or bottom while holding another hanging sign chains it.
			return hitNormalAxis( aim.HitNormal ) ~= facingAxis( MC.GetStateProperty( stateId, "facing" ) )
		end
		-- CeilingHangingSignBlock chains only from its lower face.
		return ( tonumber( aim.HitNormal and aim.HitNormal.z ) or 0 ) < -0.5
	end

	function SV.OpenSignEditor( ply, bx, by, bz )
		bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
		if not inRange( ply, bx, by, bz ) or SV.CanEdit and not SV.CanEdit( ply ) then return false end
		local record = signRecord( bx, by, bz )
		if not record then return false end
		local key = MC.CellKey( bx, by, bz )
		local editor = Editors[key]
		if IsValid( editor ) and editor ~= ply and inRange( editor, bx, by, bz ) then return true end
		Editors[key] = ply
		net.Start( "mc_sign_open" )
			net.WriteInt( bx, MC.Net.COORD_BITS )
			net.WriteInt( by, MC.Net.COORD_BITS )
			net.WriteInt( bz, MC.Net.COORD_BITS )
			for index = 1, 4 do net.WriteString( record.data.lines[index] or "" ) end
		net.Send( ply )
		return true
	end

	net.Receive( "mc_sign_update", function( _, ply )
		local bx = net.ReadInt( MC.Net.COORD_BITS )
		local by = net.ReadInt( MC.Net.COORD_BITS )
		local bz = net.ReadInt( MC.Net.COORD_BITS )
		local lines = { net.ReadString(), net.ReadString(), net.ReadString(), net.ReadString() }
		local key = MC.CellKey( bx, by, bz )
		if Editors[key] ~= ply then return end
		Editors[key] = nil
		if not inRange( ply, bx, by, bz ) or SV.CanEdit and not SV.CanEdit( ply ) then return end
		local record, stateId = signRecord( bx, by, bz )
		if not record then return end
		local ok, normalized = MC.ValidateSignLines( lines, MC.SignMaxLineWidthForState( stateId ) )
		if not ok then return end
		record.data = { lines = normalized }
		SV.SetBlockState( bx, by, bz, stateId, {
			actor = ply,
			blockEntity = record,
			fx = false,
			blockUpdates = false,
			compareCollision = false,
		} )
	end )

	hook.Add( "PlayerDisconnected", "mc_sign_release_editor", function( ply )
		for key, editor in pairs( Editors ) do if editor == ply then Editors[key] = nil end end
	end )

	for _, id in ipairs( MC.BlockList or {} ) do
		local block = MC.Blocks[id]
		if block and editableSignName( block.mcid ) then
			block.handlers.OnUse = function( ply, bx, by, bz, _, selectedBlockID )
				local stateId = MC.GetBlockState( bx, by, bz )
				-- Chaining is a placement gesture: only callers that declare the
				-- held block (the placer SWEP) may trigger it. A nil selection is a
				-- pure interaction (+use key) and must always open the editor.
				if selectedBlockID ~= nil and shouldChainHangingSign( ply, bx, by, bz, stateId, selectedBlockID ) then return false end
				return SV.OpenSignEditor( ply, bx, by, bz )
			end
			block.handlers.OnPlaced = function( context )
				if IsValid( context.actor ) then SV.OpenSignEditor( context.actor, context.bx, context.by, context.bz ) end
			end
		end
	end
end
