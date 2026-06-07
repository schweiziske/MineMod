--[[----------------------------------------------------------------------------
	MC : block registry + texture/blockstate mapping.

	Stored states mirror Minecraft blockstates:
	  oak_log: axis=x/y/z
	  furnace: facing=north/south/west/east
	  dispenser/observer: facing=down/up/north/south/west/east
------------------------------------------------------------------------------]]

MC = MC or {}

local T = MC.GeneratedTiles or {
	dirt = 0, grass_top = 1, grass_side = 2, stone = 3, cobblestone = 4,
	oak_planks = 5, oak_log = 6, oak_log_top = 7, sand = 8, glass = 9,
	bricks = 10, stone_bricks = 11, bedrock = 12, gold_block = 13, iron_block = 14,
	diamond_block = 15, tnt_side = 16, tnt_top = 17, tnt_bottom = 18,
	crafting_table_top = 19, crafting_table_side = 20, crafting_table_front = 21,
	obsidian = 22, glowstone = 23, netherrack = 24, snow = 25, oak_leaves = 26,
	pumpkin_side = 27, pumpkin_top = 28, melon_side = 29, melon_top = 30,
	bookshelf = 31, furnace_top = 32, furnace_side = 33, furnace_front = 34,
	dispenser_front = 35, dispenser_side = 36, dispenser_front_vertical = 37,
	observer_top = 38, observer_side = 39, observer_front = 40, observer_back = 41,
}
MC.Tiles = T
MC.TileNames = {}
for name, tile in pairs( T ) do MC.TileNames[tile] = name end

local FixedDisp = {
	grass = "草方块", dirt = "泥土", stone = "石头", cobblestone = "圆石",
	oak_planks = "橡木木板", oak_log = "橡木原木", sand = "沙子", glass = "玻璃",
	bricks = "红砖块", stone_bricks = "石砖", bedrock = "基岩", gold_block = "金块",
	iron_block = "铁块", diamond_block = "钻石块", tnt = "TNT", crafting_table = "工作台",
	obsidian = "黑曜石", glowstone = "荧石", netherrack = "下界岩", snow = "雪块",
	oak_leaves = "橡树树叶", pumpkin = "南瓜", melon = "西瓜", bookshelf = "书架",
	furnace = "熔炉", dispenser = "发射器", observer = "侦测器",
}

local function normalizeBlockKey( s )
	s = string.lower( tostring( s or "" ) )
	s = string.match( s, "^%s*(.-)%s*$" )
	return s
end

local function tileValue( value, fallback )
	if type( value ) == "number" then return value end
	if type( value ) == "string" and T[value] ~= nil then return T[value] end
	return fallback or 0
end

local function blockDisp( def )
	return def.disp or FixedDisp[def.name] or ( "方块 " .. tostring( def.name or def.mcid or def.id ) )
end

local function normalizeBaked( baked )
	if type( baked ) ~= "table" then return nil end
	local out = {}
	for orient, faces in pairs( baked ) do
		local ofaces = {}
		for face, data in pairs( faces ) do
			if type( data ) == "table" then
				ofaces[tonumber( face ) or face] = {
					tile = tileValue( data.tile, 0 ),
					rot = math.floor( tonumber( data.rot ) or 0 ),
					uv = data.uv,
					uvs = data.uvs,
				}
			end
		end
		out[tonumber( orient ) or orient] = ofaces
	end
	return out
end

MC.Blocks = {}
MC.BlockByName = {}
MC.BlockAliases = {}
MC.BlockHandlers = MC.BlockHandlers or {}

MC.BlockHandlers.furnace = MC.BlockHandlers.furnace or {
	OnUse = function( ply )
		if IsValid( ply ) then
			ply:ChatPrint( "[MC] 熔炉界面还没接物品系统，先占位。" )
		end
		return true
	end,
}

function MC.RegisterBlock( def )
	if not def or def.id == nil then return nil end
	local id = math.floor( tonumber( def.id ) or 0 )
	if id <= 0 then return nil end

	local name = normalizeBlockKey( def.name or ( def.mcid and string.match( def.mcid, "^minecraft:(.+)$" ) ) or id )
	local mcid = normalizeBlockKey( def.mcid or ( "minecraft:" .. name ) )
	local textures = def.textures or {}
	local top = tileValue( textures.top or def.top, 0 )
	local side = tileValue( textures.side or def.side, top )
	local bottom = tileValue( textures.bottom or def.bottom, top )
	local front = textures.front and tileValue( textures.front, side ) or nil
	local handler = def.handlers or ( def.handler and MC.BlockHandlers[def.handler] ) or nil
	if handler and handler.OnTick then MC.HasBlockTickHandlers = true end

	local b = {
		id = id,
		name = name,
		mcid = mcid,
		disp = blockDisp( { name = name, disp = def.disp, mcid = mcid, id = id } ),
		solid = def.solid ~= false,
		transparent = def.transparent == true,
		textures = { top = top, side = side, bottom = bottom, front = front },
		baked = normalizeBaked( def.baked ),
		stateRule = def.stateRule or def.orient,
		placeRule = def.placeRule or def.place,
		handlers = handler or {},
		aliases = def.aliases or {},
		defaultOrientName = def.defaultOrientName,

		-- Backward-compatible fields used by the renderer/UI.
		top = top,
		side = side,
		bottom = bottom,
		front = front,
		orient = def.stateRule or def.orient,
		place = def.placeRule or def.place,
	}

	MC.Blocks[id] = b
	MC.BlockByName[mcid] = b
	MC.BlockAliases[name] = b
	MC.BlockAliases[mcid] = b
	if string.StartWith( mcid, "minecraft:" ) then
		MC.BlockAliases[string.sub( mcid, 11 )] = b
	end
	for _, alias in ipairs( b.aliases ) do
		alias = normalizeBlockKey( alias )
		MC.BlockAliases[alias] = b
		if not string.StartWith( alias, "minecraft:" ) then
			MC.BlockAliases["minecraft:" .. alias] = b
		end
	end

	return b
end

local function rebuildBlockList()
	MC.BlockList = {}
	for id in pairs( MC.Blocks ) do MC.BlockList[#MC.BlockList + 1] = id end
	table.sort( MC.BlockList )
	MC.MaxBlockID = MC.BlockList[#MC.BlockList] or 0
end

local function registerGeneratedBlocks()
	if not MC.GeneratedBlocks then return false end
	for _, def in ipairs( MC.GeneratedBlocks ) do
		MC.RegisterBlock( def )
	end
	return true
end

MC.Face = { TOP = 1, BOTTOM = 2, XP = 3, XN = 4, YP = 5, YN = 6 }
MC.Axis = { X = 0, Y = 1, Z = 2 }
MC.Direction = {
	DOWN = 0,
	UP = 1,
	NORTH = 2, -- Source -Y
	SOUTH = 3, -- Source +Y
	WEST = 4,  -- Source -X
	EAST = 5,  -- Source +X
}

local AxisName = { [0] = "x", [1] = "y", [2] = "z" }
local AxisValue = { x = MC.Axis.X, y = MC.Axis.Y, z = MC.Axis.Z }
local DirectionName = {
	[MC.Direction.DOWN] = "down",
	[MC.Direction.UP] = "up",
	[MC.Direction.NORTH] = "north",
	[MC.Direction.SOUTH] = "south",
	[MC.Direction.WEST] = "west",
	[MC.Direction.EAST] = "east",
}
local DirectionValue = {
	down = MC.Direction.DOWN,
	up = MC.Direction.UP,
	north = MC.Direction.NORTH,
	south = MC.Direction.SOUTH,
	west = MC.Direction.WEST,
	east = MC.Direction.EAST,
}

local function reverseValues( values )
	local out = {}
	for _, v in pairs( values ) do out[v] = true end
	return out
end

MC.OrientRules = {
	axis = {
		default = MC.Axis.Y,
		names = AxisName,
		values = AxisValue,
		allowed = reverseValues( AxisValue ),
		order = { MC.Axis.X, MC.Axis.Y, MC.Axis.Z },
	},
	facing = {
		default = MC.Direction.NORTH,
		names = DirectionName,
		values = DirectionValue,
		allowed = reverseValues( DirectionValue ),
		order = { MC.Direction.DOWN, MC.Direction.UP, MC.Direction.NORTH, MC.Direction.SOUTH, MC.Direction.WEST, MC.Direction.EAST },
	},
	horizontal_facing = {
		default = MC.Direction.NORTH,
		names = DirectionName,
		values = { north = MC.Direction.NORTH, south = MC.Direction.SOUTH, west = MC.Direction.WEST, east = MC.Direction.EAST },
		order = { MC.Direction.NORTH, MC.Direction.SOUTH, MC.Direction.WEST, MC.Direction.EAST },
	},
}
MC.OrientRules.horizontal_facing.allowed = reverseValues( MC.OrientRules.horizontal_facing.values )

if not registerGeneratedBlocks() then
	MC.RegisterBlock( { id = 1, name = "grass", mcid = "minecraft:grass_block", transparent = false, textures = { top = "grass_top", side = "grass_side", bottom = "dirt" }, aliases = { "minecraft:grass", "grass_block" } } )
	MC.RegisterBlock( { id = 2, name = "dirt", mcid = "minecraft:dirt", textures = { top = "dirt", side = "dirt", bottom = "dirt" } } )
	MC.RegisterBlock( { id = 3, name = "stone", mcid = "minecraft:stone", textures = { top = "stone", side = "stone", bottom = "stone" } } )
end

for _, b in pairs( MC.Blocks ) do
	if b.defaultOrientName then
		local rule = MC.OrientRules[b.orient]
		b.defaultOrient = rule and rule.values[b.defaultOrientName] or b.defaultOrient
	end
end

function MC.IsValidBlock( id )
	return id ~= nil and MC.Blocks[id] ~= nil
end

function MC.ResolveBlock( input )
	if input == nil then return nil end
	local s = normalizeBlockKey( input )
	if s == "0" or s == "air" or s == "minecraft:air" then return { id = 0, block = nil, mcid = "minecraft:air", name = "air" } end
	local id = tonumber( s )
	if id and math.floor( id ) == id then
		id = math.floor( id )
		return MC.IsValidBlock( id ) and { id = id, block = MC.Blocks[id], mcid = MC.Blocks[id].mcid, name = MC.Blocks[id].name } or nil
	end
	local b = MC.BlockAliases[s] or MC.BlockByName[s]
	if not b and not string.StartWith( s, "minecraft:" ) then
		b = MC.BlockByName["minecraft:" .. s] or MC.BlockAliases["minecraft:" .. s]
	end
	return b and { id = b.id, block = b, mcid = b.mcid, name = b.name } or nil
end

local function registerImportFallbackBlock( def )
	if MC.ResolveBlock( def.mcid ) then return end
	MC.RegisterBlock( def )
end

registerImportFallbackBlock( { id = 60001, name = "water", mcid = "minecraft:water", solid = false, transparent = true, textures = { top = "water_still", side = "water_still", bottom = "water_still" } } )
registerImportFallbackBlock( { id = 60002, name = "short_grass", mcid = "minecraft:short_grass", solid = false, transparent = true, textures = { top = "oak_leaves", side = "oak_leaves", bottom = "oak_leaves" } } )
registerImportFallbackBlock( { id = 60003, name = "tall_grass", mcid = "minecraft:tall_grass", solid = false, transparent = true, textures = { top = "oak_leaves", side = "oak_leaves", bottom = "oak_leaves" } } )
registerImportFallbackBlock( { id = 60004, name = "seagrass", mcid = "minecraft:seagrass", solid = false, transparent = true, textures = { top = "oak_leaves", side = "oak_leaves", bottom = "oak_leaves" } } )
registerImportFallbackBlock( { id = 60005, name = "tall_seagrass", mcid = "minecraft:tall_seagrass", solid = false, transparent = true, textures = { top = "oak_leaves", side = "oak_leaves", bottom = "oak_leaves" } } )
registerImportFallbackBlock( { id = 60006, name = "lava", mcid = "minecraft:lava", solid = false, transparent = true, textures = { top = "lava_still", side = "lava_still", bottom = "lava_still" } } )
registerImportFallbackBlock( { id = 60007, name = "glow_lichen", mcid = "minecraft:glow_lichen", solid = false, transparent = true, textures = { top = "glow_lichen", side = "glow_lichen", bottom = "glow_lichen" } } )
registerImportFallbackBlock( { id = 60008, name = "bush", mcid = "minecraft:bush", solid = false, transparent = true, textures = { top = "oak_leaves", side = "oak_leaves", bottom = "oak_leaves" } } )
registerImportFallbackBlock( { id = 60009, name = "flower", mcid = "minecraft:dandelion", solid = false, transparent = true, textures = { top = "oak_leaves", side = "oak_leaves", bottom = "oak_leaves" }, aliases = { "minecraft:poppy", "minecraft:white_tulip", "minecraft:pink_tulip", "minecraft:cornflower", "minecraft:oxeye_daisy", "minecraft:sunflower", "minecraft:firefly_bush" } } )

rebuildBlockList()

function MC.DefaultOrient( id )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	return rule and ( b.defaultOrient or rule.default ) or 0
end

function MC.NormalizeOrient( id, orient )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	if not rule then return 0 end
	if orient == nil then return MC.DefaultOrient( id ) end
	orient = math.floor( tonumber( orient ) or MC.DefaultOrient( id ) )
	return rule.allowed[orient] and orient or MC.DefaultOrient( id )
end

function MC.OrientToState( id, orient )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	if not rule then return "" end
	return rule.names[MC.NormalizeOrient( id, orient )] or ""
end

function MC.BlockStateText( id, orient )
	local b = MC.Blocks[id]
	if not b or not b.orient then return "" end
	local state = MC.OrientToState( id, orient )
	if state == "" then return "" end
	return ( b.orient == "axis" and "axis=" or "facing=" ) .. state
end

function MC.BlockStateHint( id )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	if not rule then return "" end
	local names = {}
	for _, value in ipairs( rule.order ) do names[#names + 1] = rule.names[value] end
	return ( b.orient == "axis" and "axis=" or "facing=" ) .. table.concat( names, "/" )
end

local function trim( s )
	return string.match( tostring( s or "" ), "^%s*(.-)%s*$" )
end

local function stateValue( b, state )
	if state == nil then return nil, true end
	state = string.lower( tostring( state ) )
	state = string.match( state, "^%s*%[(.-)%]%s*$" ) or state
	local key, value = string.match( state, "^%s*([%a_]+)%s*=%s*([%a_]+)%s*$" )
	if not key then return trim( state ), true end
	local want = b.orient == "axis" and "axis" or "facing"
	if key ~= want and not ( b.orient == "horizontal_facing" and key == "horizontal_facing" ) then return nil, false end
	return value, true
end

local function numericOrient( rule, state )
	local n = tonumber( state )
	if not n or math.floor( n ) ~= n or not rule.allowed[n] then return nil end
	return n
end

function MC.StateToOrient( id, state )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	if not rule then return 0 end
	if state == nil or state == "" then return MC.DefaultOrient( id ) end
	local n = numericOrient( rule, state )
	if n then return n end
	local value, validKey = stateValue( b, state )
	if not validKey or not value or value == "" then return MC.DefaultOrient( id ) end
	return rule.values[value] or MC.DefaultOrient( id )
end

function MC.IsOrientStateValid( id, state )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	if not rule then return state == nil or state == "" end
	if state == nil or state == "" then return true end
	if tonumber( state ) then return numericOrient( rule, state ) ~= nil end
	local value, validKey = stateValue( b, state )
	return validKey and value ~= nil and rule.values[value] ~= nil
end

local function parseBlockStateText( text )
	text = trim( text )
	local blockName, bracketState = string.match( text, "^([^%s%[]+)%s*%[(.-)%]%s*$" )
	if blockName then return trim( blockName ), bracketState end
	if string.find( text, "%[" ) or string.find( text, "%]" ) then
		return trim( string.match( text, "^([^%s%[]+)" ) or text ), "__invalid_bracket_state__"
	end
	local blockArg, stateArg = string.match( text, "^(%S+)%s+(.+)$" )
	if blockArg then return trim( blockArg ), stateArg end
	return text, nil
end

function MC.ParseBlockSpec( text )
	local blockArg, stateArg = parseBlockStateText( text )
	local resolved = MC.ResolveBlock( blockArg )
	if not resolved then return nil, nil, blockArg, "block" end
	if resolved.id == 0 then return 0, 0, "minecraft:air", nil, resolved end
	if stateArg ~= nil and not MC.IsOrientStateValid( resolved.id, stateArg ) then
		return resolved.id, nil, blockArg, "state", resolved
	end
	return resolved.id, MC.StateToOrient( resolved.id, stateArg ), blockArg, nil, resolved
end

function MC.BlockCanonicalName( id )
	local b = MC.Blocks[id]
	return b and b.mcid or "minecraft:air"
end

local function oppositeDirection( dir )
	if dir == MC.Direction.DOWN then return MC.Direction.UP end
	if dir == MC.Direction.UP then return MC.Direction.DOWN end
	if dir == MC.Direction.NORTH then return MC.Direction.SOUTH end
	if dir == MC.Direction.SOUTH then return MC.Direction.NORTH end
	if dir == MC.Direction.WEST then return MC.Direction.EAST end
	return MC.Direction.WEST
end

local function lookDirectionFromForward( forward )
	if not forward then return MC.Direction.SOUTH end
	local ax, ay, az = math.abs( forward.x ), math.abs( forward.y ), math.abs( forward.z )
	if az >= ax and az >= ay then return forward.z >= 0 and MC.Direction.UP or MC.Direction.DOWN end
	if ax > ay then return forward.x >= 0 and MC.Direction.EAST or MC.Direction.WEST end
	return forward.y >= 0 and MC.Direction.SOUTH or MC.Direction.NORTH
end

local function horizontalLookDirectionFromForward( forward )
	if not forward then return MC.Direction.NORTH end
	if math.abs( forward.x ) > math.abs( forward.y ) then return forward.x >= 0 and MC.Direction.EAST or MC.Direction.WEST end
	return forward.y >= 0 and MC.Direction.SOUTH or MC.Direction.NORTH
end

function MC.OrientForVectors( id, forward, hitNormal )
	local b = MC.Blocks[id]
	if not b or not b.orient then return 0 end
	if b.orient == "axis" then
		local n = hitNormal or Vector( 0, 0, 1 )
		if math.abs( n.x ) > 0.5 then return MC.Axis.X end
		if math.abs( n.y ) > 0.5 then return MC.Axis.Z end
		return MC.Axis.Y
	end
	if b.orient == "horizontal_facing" then
		return oppositeDirection( horizontalLookDirectionFromForward( forward ) )
	end
	if b.place == "look" then
		return lookDirectionFromForward( forward )
	end
	return oppositeDirection( lookDirectionFromForward( forward ) )
end

function MC.OrientForPlacement( ply, tr, id )
	local forward = IsValid( ply ) and ply:EyeAngles():Forward() or nil
	return MC.OrientForVectors( id, forward, tr and tr.HitNormal or nil )
end

local FaceToDir = {
	[MC.Face.TOP] = MC.Direction.UP,
	[MC.Face.BOTTOM] = MC.Direction.DOWN,
	[MC.Face.XP] = MC.Direction.EAST,
	[MC.Face.XN] = MC.Direction.WEST,
	[MC.Face.YP] = MC.Direction.SOUTH,
	[MC.Face.YN] = MC.Direction.NORTH,
}

local DirToFace = {
	[MC.Direction.UP] = MC.Face.TOP,
	[MC.Direction.DOWN] = MC.Face.BOTTOM,
	[MC.Direction.EAST] = MC.Face.XP,
	[MC.Direction.WEST] = MC.Face.XN,
	[MC.Direction.SOUTH] = MC.Face.YP,
	[MC.Direction.NORTH] = MC.Face.YN,
}

local function rotateYDir( dir, steps )
	steps = steps % 4
	for _ = 1, steps do
		if dir == MC.Direction.NORTH then dir = MC.Direction.EAST
		elseif dir == MC.Direction.EAST then dir = MC.Direction.SOUTH
		elseif dir == MC.Direction.SOUTH then dir = MC.Direction.WEST
		elseif dir == MC.Direction.WEST then dir = MC.Direction.NORTH
		end
	end
	return dir
end

local function rotateXDir( dir, steps )
	steps = steps % 4
	for _ = 1, steps do
		if dir == MC.Direction.NORTH then dir = MC.Direction.DOWN
		elseif dir == MC.Direction.DOWN then dir = MC.Direction.SOUTH
		elseif dir == MC.Direction.SOUTH then dir = MC.Direction.UP
		elseif dir == MC.Direction.UP then dir = MC.Direction.NORTH
		end
	end
	return dir
end

local function modelRotForFacing( orient )
	if orient == MC.Direction.EAST then return 0, 1 end
	if orient == MC.Direction.SOUTH then return 0, 2 end
	if orient == MC.Direction.WEST then return 0, 3 end
	return 0, 0
end

local function observerRotForFacing( orient )
	if orient == MC.Direction.DOWN then return 1, 0 end
	if orient == MC.Direction.UP then return 3, 0 end
	return modelRotForFacing( orient )
end

local function dispenserRotForFacing( orient )
	if orient == MC.Direction.DOWN then return 2, 0 end
	if orient == MC.Direction.UP then return 0, 0 end
	return modelRotForFacing( orient )
end

local function localFaceAfterModelRotation( face, xSteps, ySteps )
	local dir = FaceToDir[face]
	dir = rotateYDir( dir, -ySteps )
	dir = rotateXDir( dir, -xSteps )
	return DirToFace[dir]
end

local function orientableFace( frontTile, topTile, sideTile, face, orient )
	local _, ySteps = modelRotForFacing( orient )
	local localFace = localFaceAfterModelRotation( face, 0, ySteps )
	if localFace == MC.Face.YN then return frontTile, 0 end
	if localFace == MC.Face.TOP or localFace == MC.Face.BOTTOM then return topTile, ySteps end
	return sideTile, 0
end

local function dispenserFace( face, orient )
	local xSteps, ySteps = dispenserRotForFacing( orient )
	local localFace = localFaceAfterModelRotation( face, xSteps, ySteps )
	if orient == MC.Direction.UP or orient == MC.Direction.DOWN then
		if orient == MC.Direction.UP and face == MC.Face.TOP then return T.dispenser_front_vertical, 0 end
		if orient == MC.Direction.DOWN and face == MC.Face.BOTTOM then return T.dispenser_front_vertical, 2 end
		return T.furnace_top, 0
	end
	if localFace == MC.Face.YN then return T.dispenser_front, 0 end
	if localFace == MC.Face.TOP or localFace == MC.Face.BOTTOM then return T.furnace_top, ySteps end
	return T.furnace_side, 0
end

local function observerFace( face, orient )
	local xSteps, ySteps = observerRotForFacing( orient )
	local localFace = localFaceAfterModelRotation( face, xSteps, ySteps )
	if orient == MC.Direction.DOWN then
		if face == MC.Face.BOTTOM then return T.observer_front, 2 end
		if face == MC.Face.TOP then return T.observer_back, 2 end
		if face == MC.Face.YN or face == MC.Face.YP then return T.observer_top, 0 end
		return T.observer_side, 0
	end
	if orient == MC.Direction.UP then
		if face == MC.Face.TOP then return T.observer_front, 0 end
		if face == MC.Face.BOTTOM then return T.observer_back, 0 end
		if face == MC.Face.YN or face == MC.Face.YP then return T.observer_top, 0 end
		return T.observer_side, 0
	end
	if localFace == MC.Face.YN then return T.observer_front, 0 end
	if localFace == MC.Face.YP then return T.observer_back, 0 end
	if localFace == MC.Face.TOP or localFace == MC.Face.BOTTOM then return T.observer_top, ySteps end
	return T.observer_side, 0
end

local function pillarRotForAxis( axis )
	if axis == MC.Axis.X then return 1, 1 end
	if axis == MC.Axis.Z then return 1, 0 end
	return 0, 0
end

local function pillarFace( id, face, axis )
	local b = MC.Blocks[id]
	local xSteps, ySteps = pillarRotForAxis( axis )
	local localFace = localFaceAfterModelRotation( face, xSteps, ySteps )
	if localFace == MC.Face.TOP or localFace == MC.Face.BOTTOM then return b.top, 0 end
	return b.side, 0
end

function MC.BlockFace( id, face, orient )
	local b = MC.Blocks[id]
	if not b then return 0, 0 end
	orient = MC.NormalizeOrient( id, orient )

	if b.orient == "axis" then
		return pillarFace( id, face, orient )
	end

	if b.name == "observer" then return observerFace( face, orient ) end

	if b.orient == "facing" or b.orient == "horizontal_facing" then
		if b.name == "furnace" then return orientableFace( T.furnace_front, T.furnace_top, T.furnace_side, face, orient ) end
		if b.name == "dispenser" then return dispenserFace( face, orient ) end
		if b.front then return orientableFace( b.front, b.top, b.side, face, orient ) end
	end

	if face == MC.Face.TOP then return b.top, 0 end
	if face == MC.Face.BOTTOM then return b.bottom, 0 end
	return b.side, 0
end

function MC.BlockTile( id, face, orient )
	local tile = MC.BlockFace( id, face, orient )
	return tile
end

function MC.BlockIconTile( id )
	local b = MC.Blocks[id]
	if not b then return 0 end
	if b.name == "furnace" then return T.furnace_front end
	if b.name == "dispenser" then return T.dispenser_front end
	if b.name == "observer" then return T.observer_front end
	return b.side
end

function MC.TileUV( tile )
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local px0 = col * A.TILE
	local py0 = row * A.TILE
	local inset = A.INSET or 0.5
	return ( px0 + inset ) / A.W,
	       ( py0 + inset ) / A.H,
	       ( px0 + A.TILE - inset ) / A.W,
	       ( py0 + A.TILE - inset ) / A.H
end
