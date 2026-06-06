--[[----------------------------------------------------------------------------
	MC : block registry + texture/blockstate mapping.

	Stored states mirror Minecraft blockstates:
	  oak_log: axis=x/y/z
	  furnace: facing=north/south/west/east
	  dispenser/observer: facing=down/up/north/south/west/east
------------------------------------------------------------------------------]]

MC = MC or {}

local T = {
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

local function blk( name, disp, top, side, bottom, transparent, orient, place )
	return {
		name = name,
		disp = disp,
		top = top,
		side = side,
		bottom = bottom or top,
		transparent = transparent or false,
		orient = orient,
		place = place,
	}
end

MC.Blocks = {
	[1]  = blk( "grass",          "草方块",     T.grass_top,         T.grass_side,          T.dirt ),
	[2]  = blk( "dirt",           "泥土",       T.dirt,              T.dirt,                T.dirt ),
	[3]  = blk( "stone",          "石头",       T.stone,             T.stone,               T.stone ),
	[4]  = blk( "cobblestone",    "圆石",       T.cobblestone,       T.cobblestone,         T.cobblestone ),
	[5]  = blk( "oak_planks",     "橡木木板",   T.oak_planks,        T.oak_planks,          T.oak_planks ),
	[6]  = blk( "oak_log",        "橡木原木",   T.oak_log_top,       T.oak_log,             T.oak_log_top, false, "axis" ),
	[7]  = blk( "sand",           "沙子",       T.sand,              T.sand,                T.sand ),
	[8]  = blk( "glass",          "玻璃",       T.glass,             T.glass,               T.glass, true ),
	[9]  = blk( "bricks",         "红砖块",     T.bricks,            T.bricks,              T.bricks ),
	[10] = blk( "stone_bricks",   "石砖",       T.stone_bricks,      T.stone_bricks,        T.stone_bricks ),
	[11] = blk( "bedrock",        "基岩",       T.bedrock,           T.bedrock,             T.bedrock ),
	[12] = blk( "gold_block",     "金块",       T.gold_block,        T.gold_block,          T.gold_block ),
	[13] = blk( "iron_block",     "铁块",       T.iron_block,        T.iron_block,          T.iron_block ),
	[14] = blk( "diamond_block",  "钻石块",     T.diamond_block,     T.diamond_block,       T.diamond_block ),
	[15] = blk( "tnt",            "TNT",            T.tnt_top,           T.tnt_side,            T.tnt_bottom ),
	[16] = blk( "crafting_table", "工作台",     T.crafting_table_top, T.crafting_table_side, T.oak_planks ),
	[17] = blk( "obsidian",       "黑曜石",     T.obsidian,          T.obsidian,            T.obsidian ),
	[18] = blk( "glowstone",      "荧石",       T.glowstone,         T.glowstone,           T.glowstone ),
	[19] = blk( "netherrack",     "下界岩",     T.netherrack,        T.netherrack,          T.netherrack ),
	[20] = blk( "snow",           "雪块",       T.snow,              T.snow,                T.snow ),
	[21] = blk( "oak_leaves",     "橡树树叶",   T.oak_leaves,        T.oak_leaves,          T.oak_leaves, true ),
	[22] = blk( "pumpkin",        "南瓜",       T.pumpkin_top,       T.pumpkin_side,        T.pumpkin_top ),
	[23] = blk( "melon",          "西瓜",       T.melon_top,         T.melon_side,          T.melon_top ),
	[24] = blk( "bookshelf",      "书架",       T.oak_planks,        T.bookshelf,           T.oak_planks ),
	[25] = blk( "furnace",        "熔炉",       T.furnace_top,       T.furnace_side,        T.furnace_top, false, "horizontal_facing" ),
	[26] = blk( "dispenser",      "发射器",     T.dispenser_side,    T.dispenser_side,      T.dispenser_side, false, "facing", "look_opposite" ),
	[27] = blk( "observer",       "侦测器",     T.observer_top,      T.observer_side,       T.observer_top, false, "facing", "look" ),
}

MC.BlockList = {}
for id in pairs( MC.Blocks ) do MC.BlockList[#MC.BlockList + 1] = id end
table.sort( MC.BlockList )
MC.MaxBlockID = MC.BlockList[#MC.BlockList]

function MC.IsValidBlock( id )
	return id ~= nil and MC.Blocks[id] ~= nil
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
MC.Blocks[27].defaultOrient = MC.Direction.SOUTH

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
	if key ~= want then return nil, false end
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

local function axisEndFace( axis, face )
	if axis == MC.Axis.X then return face == MC.Face.XP or face == MC.Face.XN end
	if axis == MC.Axis.Z then return face == MC.Face.YP or face == MC.Face.YN end
	return face == MC.Face.TOP or face == MC.Face.BOTTOM
end

local function axisSideRot( axis, face )
	if axis == MC.Axis.X then return 1 end
	if axis == MC.Axis.Z and ( face == MC.Face.XP or face == MC.Face.XN ) then return 1 end
	return 0
end

local function facingFrontFace( orient )
	if orient == MC.Direction.UP then return MC.Face.TOP end
	if orient == MC.Direction.DOWN then return MC.Face.BOTTOM end
	if orient == MC.Direction.NORTH then return MC.Face.YN end
	if orient == MC.Direction.SOUTH then return MC.Face.YP end
	if orient == MC.Direction.WEST then return MC.Face.XN end
	return MC.Face.XP
end

local function observerFace( face, orient )
	if orient == MC.Direction.NORTH then
		if face == MC.Face.YN then return T.observer_front, 0 end
		if face == MC.Face.YP then return T.observer_back, 0 end
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then return T.observer_top, 0 end
		return T.observer_side, 0
	end
	if orient == MC.Direction.SOUTH then
		if face == MC.Face.YP then return T.observer_front, 0 end
		if face == MC.Face.YN then return T.observer_back, 0 end
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then return T.observer_top, 2 end
		return T.observer_side, 0
	end
	if orient == MC.Direction.WEST then
		if face == MC.Face.XN then return T.observer_front, 0 end
		if face == MC.Face.XP then return T.observer_back, 0 end
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then return T.observer_top, 1 end
		return T.observer_side, 0
	end
	if orient == MC.Direction.EAST then
		if face == MC.Face.XP then return T.observer_front, 0 end
		if face == MC.Face.XN then return T.observer_back, 0 end
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then return T.observer_top, 3 end
		return T.observer_side, 0
	end
	if orient == MC.Direction.DOWN then
		if face == MC.Face.BOTTOM then return T.observer_front, 2 end
		if face == MC.Face.TOP then return T.observer_back, 2 end
		if face == MC.Face.YN or face == MC.Face.YP then return T.observer_top, 0 end
		return T.observer_side, 0
	end
	if face == MC.Face.TOP then return T.observer_front, 0 end
	if face == MC.Face.BOTTOM then return T.observer_back, 0 end
	if face == MC.Face.YN or face == MC.Face.YP then return T.observer_top, 0 end
	return T.observer_side, 0
end

function MC.BlockFace( id, face, orient )
	local b = MC.Blocks[id]
	if not b then return 0, 0 end
	orient = MC.NormalizeOrient( id, orient )

	if b.orient == "axis" then
		return axisEndFace( orient, face ) and b.top or b.side, axisEndFace( orient, face ) and 0 or axisSideRot( orient, face )
	end

	if b.name == "observer" then return observerFace( face, orient ) end

	if b.orient == "facing" or b.orient == "horizontal_facing" then
		local front = facingFrontFace( orient )
		if face == front then
			if b.name == "furnace" then return T.furnace_front, 0 end
			if b.name == "dispenser" then
				if front == MC.Face.TOP or front == MC.Face.BOTTOM then return T.dispenser_front_vertical, front == MC.Face.BOTTOM and 2 or 0 end
				return T.dispenser_front, 0
			end
		end
		if face == MC.Face.TOP then return b.top, 0 end
		if face == MC.Face.BOTTOM then return b.bottom, 0 end
		return b.side, 0
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
	local inset = 0.5
	return ( px0 + inset ) / A.W,
	       ( py0 + inset ) / A.H,
	       ( px0 + A.TILE - inset ) / A.W,
	       ( py0 + A.TILE - inset ) / A.H
end
