--[[----------------------------------------------------------------------------
	MC functional block: vanilla standing and wall banners.

	Banners remain sparse Block Entity data. The base dye is derived from the
	block state; only ordered pattern layers and the optional custom name are
	persisted and synchronized.
------------------------------------------------------------------------------]]

MC = MC or {}

local BANNER_TYPE = "minecraft:banner"
local MAX_STORED_PATTERNS = 16
local MAX_PLAYER_PATTERNS = 6
local MAX_CUSTOM_NAME_BYTES = 256
local MAX_BANNER_EDIT_NET_BITS = 4096

local COLOR_ROWS = {
	{ "white", 249, 255, 254 },
	{ "orange", 249, 128, 29 },
	{ "magenta", 199, 78, 189 },
	{ "light_blue", 58, 179, 218 },
	{ "yellow", 254, 216, 61 },
	{ "lime", 128, 199, 31 },
	{ "pink", 243, 139, 170 },
	{ "gray", 71, 79, 82 },
	{ "light_gray", 157, 157, 151 },
	{ "cyan", 22, 156, 156 },
	{ "purple", 137, 50, 184 },
	{ "blue", 60, 68, 170 },
	{ "brown", 131, 84, 50 },
	{ "green", 94, 124, 22 },
	{ "red", 176, 46, 38 },
	{ "black", 29, 29, 33 },
}

local PATTERN_ASSETS = {
	"base",
	"square_bottom_left", "square_bottom_right", "square_top_left", "square_top_right",
	"stripe_bottom", "stripe_top", "stripe_left", "stripe_right", "stripe_center", "stripe_middle",
	"stripe_downright", "stripe_downleft", "small_stripes", "cross", "straight_cross",
	"triangle_bottom", "triangle_top", "triangles_bottom", "triangles_top",
	"diagonal_left", "diagonal_up_right", "diagonal_up_left", "diagonal_right",
	"circle", "rhombus", "half_vertical", "half_horizontal", "half_vertical_right",
	"half_horizontal_bottom", "border", "curly_border", "gradient", "gradient_up", "bricks",
	"globe", "creeper", "skull", "flower", "mojang", "piglin", "flow", "guster",
}

MC.BannerMaxStoredPatterns = MAX_STORED_PATTERNS
MC.BannerMaxPlayerPatterns = MAX_PLAYER_PATTERNS
MC.BannerColorNames = {}
MC.BannerColors = {}
MC.BannerPatternNames = {}
MC.BannerPatternAssets = {}

for index, row in ipairs( COLOR_ROWS ) do
	local name = row[1]
	MC.BannerColorNames[index] = name
	MC.BannerColors[name] = { index = index, name = name, r = row[2], g = row[3], b = row[4] }
end

for index, asset in ipairs( PATTERN_ASSETS ) do
	local name = "minecraft:" .. asset
	MC.BannerPatternNames[index] = name
	MC.BannerPatternAssets[name] = { index = index, name = name, asset = asset }
end

local function tableValue( value )
	return type( value ) == "table"
end

local function stringValue( value )
	return type( value ) == "string"
end

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" )
end

local function normalizePatternName( value )
	if not stringValue( value ) then return nil end
	local name = string.lower( trim( value ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return MC.BannerPatternAssets[name] and name or nil
end

local function normalizeColorName( value )
	if not stringValue( value ) then return nil end
	local name = string.lower( trim( value ) )
	name = string.gsub( name, "^minecraft:", "" )
	return MC.BannerColors[name] and name or nil
end

local function normalizeCustomName( value )
	if value == nil or value == "" then return nil end
	if not stringValue( value ) then return nil, "invalid_custom_name" end
	if #value > MAX_CUSTOM_NAME_BYTES then return nil, "custom_name_too_long" end
	if string.find( value, "[%z\1-\31\127]" ) then return nil, "custom_name_control_character" end
	return value
end

function MC.ValidateBannerLayers( layers, maxLayers )
	if not tableValue( layers ) then return false, "invalid_banner_layers" end
	maxLayers = math.Clamp and math.Clamp( math.floor( tonumber( maxLayers ) or MAX_STORED_PATTERNS ), 0, MAX_STORED_PATTERNS )
		or math.max( 0, math.min( MAX_STORED_PATTERNS, math.floor( tonumber( maxLayers ) or MAX_STORED_PATTERNS ) ) )
	local count, maximumIndex = 0, 0
	for key in pairs( layers ) do
		if type( key ) ~= "number" or key < 1 or math.floor( key ) ~= key then
			return false, "invalid_banner_layer_index"
		end
		count = count + 1
		maximumIndex = math.max( maximumIndex, key )
	end
	if count ~= maximumIndex then return false, "sparse_banner_layers" end
	if count > maxLayers then return false, "too_many_banner_layers" end

	local normalized = {}
	for index = 1, count do
		local layer = layers[index]
		if not tableValue( layer ) then return false, "invalid_banner_layer" end
		for key in pairs( layer ) do
			if key ~= "pattern" and key ~= "color" then return false, "invalid_banner_layer_field" end
		end
		local pattern = normalizePatternName( layer.pattern )
		if not pattern then return false, "unknown_banner_pattern" end
		local color = normalizeColorName( layer.color )
		if not color then return false, "unknown_banner_color" end
		normalized[index] = { pattern = pattern, color = color }
	end
	return true, normalized
end

function MC.NormalizeBannerData( data, maxLayers )
	if not tableValue( data ) then return nil, "invalid_banner_data" end
	for key in pairs( data ) do
		if key ~= "patterns" and key ~= "customName" then return nil, "invalid_banner_field" end
	end
	local ok, patterns = MC.ValidateBannerLayers( data.patterns or {}, maxLayers or MAX_STORED_PATTERNS )
	if not ok then return nil, patterns end
	local customName, nameError = normalizeCustomName( data.customName )
	if nameError then return nil, nameError end
	return { patterns = patterns, customName = customName }
end

local function stripNamespace( name )
	return string.gsub( tostring( name or "" ), "^minecraft:", "" )
end

local function bannerColorFromName( name )
	name = stripNamespace( name )
	local color = string.match( name, "^([a-z_]+)_wall_banner$" )
		or string.match( name, "^([a-z_]+)_banner$" )
	return color and MC.BannerColors[color] and color or nil
end

local function bannerName( name )
	return bannerColorFromName( name ) ~= nil
end

local function wallBannerName( name )
	return bannerName( name ) and string.match( stripNamespace( name ), "_wall_banner$" ) ~= nil
end

function MC.IsBannerState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and bannerName( schema.name ) or false
end

function MC.IsWallBannerState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and wallBannerName( schema.name ) or false
end

function MC.BannerBaseColorForState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and bannerColorFromName( schema.name ) or nil
end

for name, schema in pairs( MC.PendingBlockStateSchemas or {} ) do
	if bannerName( name ) then schema.blockEntityType = BANNER_TYPE end
end

if MC.RegisterBlockEntityType then
	MC.RegisterBlockEntityType( {
		name = BANNER_TYPE,
		codecVersion = 1,
		affectsGeometry = false,
		affectsCollision = false,
		CreateDefault = function()
			return { type = BANNER_TYPE, codecVersion = 1, data = { patterns = {} } }
		end,
		Validate = function( data )
			local normalized, err = MC.NormalizeBannerData( data, MAX_STORED_PATTERNS )
			return normalized ~= nil, err
		end,
		Encode = function( data ) return MC.NormalizeBannerData( data, MAX_STORED_PATTERNS ) end,
		Decode = function( data ) return MC.NormalizeBannerData( data, MAX_STORED_PATTERNS ) end,
		CollectComponents = function( data )
			local normalized, err = MC.NormalizeBannerData( data, MAX_STORED_PATTERNS )
			if not normalized then return nil, err end
			local components = {}
			if #normalized.patterns > 0 then components["minecraft:banner_patterns"] = normalized.patterns end
			if normalized.customName then components["minecraft:custom_name"] = normalized.customName end
			return next( components ) and components or nil
		end,
	} )
end

local HorizontalOffset = {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
}

local function bannerFamilyNames( name )
	if not bannerName( name ) then return nil end
	if wallBannerName( name ) then
		return string.gsub( name, "_wall_banner$", "_banner" ), name
	end
	return name, string.gsub( name, "_banner$", "_wall_banner" )
end

local function facingForNormal( normal )
	local nx, ny = tonumber( normal and normal.x ) or 0, tonumber( normal and normal.y ) or 0
	if math.abs( nx ) >= math.abs( ny ) then return nx >= 0 and "east" or "west" end
	return ny >= 0 and "south" or "north"
end

local function standingRotation( ply )
	local forward = IsValid and IsValid( ply ) and ply.EyeAngles and ply:EyeAngles():Forward() or nil
	if not forward then return 8 end
	local atan2 = math.atan2 or math.atan
	local degrees = math.deg( atan2( -forward.x, forward.y ) ) + 180
	return math.floor( degrees * 16 / 360 + 0.5 ) % 16
end

local function fullCubeAt( bx, by, bz, stateId )
	stateId = stateId or ( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 )
	if stateId == 0 then return false end
	if MC.Liquid and MC.Liquid.StateSolid then return MC.Liquid.StateSolid( stateId, bx, by, bz ) == true end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true then return true end
	local id, orient
	if MC.LegacyFromState then id, orient = MC.LegacyFromState( stateId ) end
	return id ~= nil and MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient or 0 ) == true or false
end

function MC.BannerSupportCell( bx, by, bz, stateId )
	if not MC.IsBannerState( stateId ) then return nil end
	if not MC.IsWallBannerState( stateId ) then return bx, by, bz - 1 end
	local offset = HorizontalOffset[MC.GetStateProperty and MC.GetStateProperty( stateId, "facing" ) or nil]
	if not offset then return nil end
	return bx - offset[1], by - offset[2], bz
end

function MC.BannerCanSurvive( bx, by, bz, stateId )
	local sx, sy, sz = MC.BannerSupportCell( bx, by, bz, stateId )
	if sx == nil then return false end
	return fullCubeAt( sx, sy, sz )
end

function MC.ResolveBannerPlacementState( stateId, hitNormal, ply, bx, by, bz )
	stateId = math.floor( tonumber( stateId ) or -1 )
	if stateId < 1 then return stateId end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local groundName, wallName
	if schema then groundName, wallName = bannerFamilyNames( schema.name ) end
	if not groundName then return stateId end
	local normalZ = tonumber( hitNormal and hitNormal.z ) or 0
	if normalZ < -0.5 then return nil, "banner_ceiling_unsupported" end
	local targetName = normalZ > 0.5 and groundName or wallName
	local targetSchema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName[targetName] or nil
	if not targetSchema then return nil, "banner_state_missing" end
	local targetState = targetSchema.defaultStateId
	if targetName == groundName then
		targetState = MC.StateWith and MC.StateWith( targetState, "rotation", standingRotation( ply ) ) or nil
	else
		targetState = MC.StateWith and MC.StateWith( targetState, "facing", facingForNormal( hitNormal ) ) or nil
	end
	if not targetState then return nil, "banner_orientation_invalid" end
	if bx ~= nil and not MC.BannerCanSurvive( bx, by, bz, targetState ) then return nil, "banner_unsupported" end
	return targetState
end

local unsupportedUpdate = {
	OnNeighborUpdate = function( context )
		if context.sourceX == context.bx and context.sourceY == context.by
		and context.sourceZ == context.bz and not context.sources then return nil end
		if MC.BannerCanSurvive( context.bx, context.by, context.bz, context.stateId ) then return nil end
		local air = MC.DefaultBlockState and MC.DefaultBlockState( "minecraft:air" ) or 0
		return { dropResources = true, cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = air } } }
	end,
}

if MC.RegisterBlockUpdateHandler then
	for name in pairs( MC.BlockByName or {} ) do
		if bannerName( name ) then MC.RegisterBlockUpdateHandler( name, unsupportedUpdate ) end
	end
end

if SERVER then
	MC.SV = MC.SV or {}
	local SV = MC.SV
	local EditRates = setmetatable( {}, { __mode = "k" } )

	local function editRateAllowed( ply )
		local now = CurTime()
		local rate = EditRates[ply]
		if not rate or now - rate.startedAt >= 1 then
			EditRates[ply] = { startedAt = now, count = 1 }
			return true
		end
		if rate.count >= 8 then return false end
		rate.count = rate.count + 1
		return true
	end

	local function inRange( ply, bx, by, bz )
		if not IsValid( ply ) or not ply:IsPlayer() then return false end
		local reach = MC.CurrentReach and MC.CurrentReach() or ( ( MC.BS or 36.5 ) * 4 )
		return MC.ReachAllowsEye and MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, reach ) == true
	end

	local function bannerRecord( bx, by, bz )
		local stateId = MC.GetBlockState( bx, by, bz )
		if not MC.IsBannerState( stateId ) then return nil, nil, "not_banner" end
		local record = MC.GetBlockEntity and MC.GetBlockEntity( bx, by, bz ) or nil
		if record then return record, stateId end
		local result = SV.SetBlockState( bx, by, bz, stateId, {
			fx = false, blockUpdates = false, compareCollision = false,
		} )
		if not result or result.ok ~= true then return nil, stateId, result and result.error or "banner_record_failed" end
		return MC.GetBlockEntity( bx, by, bz ), stateId
	end

	function SV.SetBannerPatterns( ply, bx, by, bz, layers, customName )
		bx, by, bz = tonumber( bx ), tonumber( by ), tonumber( bz )
		if not bx or not by or not bz or bx ~= math.floor( bx ) or by ~= math.floor( by ) or bz ~= math.floor( bz ) then
			return false, "invalid_cell"
		end
		if SV.WorldBoundsOK and not SV.WorldBoundsOK( bx, by, bz ) then return false, "world_bounds" end
		local playerEdit = IsValid( ply )
		if ply ~= nil and not playerEdit then return false, "invalid_player" end
		if playerEdit then
			if not editRateAllowed( ply ) then return false, "rate_limited" end
			if not inRange( ply, bx, by, bz ) then return false, "out_of_range" end
			if SV.CanEdit and not SV.CanEdit( ply ) then return false, "edit_denied" end
			if MC.RunEvent and MC.RunEvent( "MC.CanPlayerEditCell", ply, bx, by, bz, true ) == false then
				return false, "cell_edit_denied"
			end
		end
		local data, dataError = MC.NormalizeBannerData( {
			patterns = layers or {}, customName = customName,
		}, playerEdit and MAX_PLAYER_PATTERNS or MAX_STORED_PATTERNS )
		if not data then return false, dataError end
		local record, stateId, recordError = bannerRecord( bx, by, bz )
		if not record then return false, recordError or "not_banner" end
		record.data = data
		local result = SV.SetBlockState( bx, by, bz, stateId, {
			actor = ply,
			blockEntity = record,
			fx = false,
			blockUpdates = false,
			compareCollision = false,
		} )
		if not result or result.ok ~= true then return false, result and result.error or "banner_update_failed" end
		return true, result.revision
	end

	net.Receive( "mc_banner_update", function( length, ply )
		if length > MAX_BANNER_EDIT_NET_BITS then return end
		local bx = net.ReadInt( MC.Net.COORD_BITS )
		local by = net.ReadInt( MC.Net.COORD_BITS )
		local bz = net.ReadInt( MC.Net.COORD_BITS )
		local count = net.ReadUInt( 3 )
		if count > MAX_PLAYER_PATTERNS then return end
		local layers = {}
		for index = 1, count do
			local pattern = MC.BannerPatternNames[net.ReadUInt( 6 ) + 1]
			local color = MC.BannerColorNames[net.ReadUInt( 4 ) + 1]
			if not pattern or not color then return end
			layers[index] = { pattern = pattern, color = color }
		end
		local customName = net.ReadBool() and net.ReadString() or nil
		SV.SetBannerPatterns( ply, bx, by, bz, layers, customName )
	end )
end

function MC.RequestBannerUpdate( bx, by, bz, layers, customName )
	if not CLIENT or not net then return false, "client_only" end
	local data, err = MC.NormalizeBannerData( { patterns = layers or {}, customName = customName }, MAX_PLAYER_PATTERNS )
	if not data then return false, err end
	bx, by, bz = tonumber( bx ), tonumber( by ), tonumber( bz )
	if not bx or not by or not bz or bx ~= math.floor( bx ) or by ~= math.floor( by ) or bz ~= math.floor( bz ) then
		return false, "invalid_cell"
	end
	net.Start( "mc_banner_update" )
		net.WriteInt( bx, MC.Net.COORD_BITS )
		net.WriteInt( by, MC.Net.COORD_BITS )
		net.WriteInt( bz, MC.Net.COORD_BITS )
		net.WriteUInt( #data.patterns, 3 )
		for _, layer in ipairs( data.patterns ) do
			net.WriteUInt( MC.BannerPatternAssets[layer.pattern].index - 1, 6 )
			net.WriteUInt( MC.BannerColors[layer.color].index - 1, 4 )
		end
		net.WriteBool( data.customName ~= nil )
		if data.customName then net.WriteString( data.customName ) end
	net.SendToServer()
	return true
end
