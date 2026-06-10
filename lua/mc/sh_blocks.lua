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
	local generated = MC.GeneratedBlockNames or {}
	return def.disp or generated[def.mcid] or generated[def.name] or FixedDisp[def.name] or ( "方块 " .. tostring( def.name or def.mcid or def.id ) )
end

local function generatedBlockProperties( name, mcid )
	local generated = MC.GeneratedBlockProperties or {}
	if generated[mcid] then return generated[mcid] end
	if generated[name] then return generated[name] end
	if string.StartWith( mcid or "", "minecraft:" ) then
		return generated[string.sub( mcid, 11 )]
	end
	return nil
end

local function propertyNumber( value, fallback )
	value = tonumber( value )
	if value == nil then return fallback end
	return value
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

local function normalizeBoxes( boxes )
	if type( boxes ) ~= "table" then return nil end
	local out = {}
	if type( boxes[1] ) == "number" and type( boxes[6] ) == "number" then
		boxes = { boxes }
	end
	for _, box in ipairs( boxes ) do
		if type( box ) == "table" then
			local x0 = math.Clamp( tonumber( box[1] ) or 0, 0, 1 )
			local y0 = math.Clamp( tonumber( box[2] ) or 0, 0, 1 )
			local z0 = math.Clamp( tonumber( box[3] ) or 0, 0, 1 )
			local x1 = math.Clamp( tonumber( box[4] ) or 0, 0, 1 )
			local y1 = math.Clamp( tonumber( box[5] ) or 0, 0, 1 )
			local z1 = math.Clamp( tonumber( box[6] ) or 0, 0, 1 )
			if x1 > x0 and y1 > y0 and z1 > z0 then
				out[#out + 1] = { x0, y0, z0, x1, y1, z1 }
			end
		end
	end
	return #out > 0 and out or nil
end

local function normalizeBoxFaces( boxFaces )
	if type( boxFaces ) ~= "table" then return nil end
	local out = {}
	if type( boxFaces[1] ) == "table" and boxFaces[1].tile ~= nil then
		boxFaces = { boxFaces }
	end
	for boxIndex, faces in ipairs( boxFaces ) do
		if type( faces ) == "table" then
			local ofaces = {}
			for face, data in pairs( faces ) do
				if type( data ) == "table" then
					ofaces[tonumber( face ) or face] = {
						tile = tileValue( data.tile, 0 ),
						uv = data.uv,
						rot = math.floor( tonumber( data.rot ) or 0 ),
					}
				end
			end
			out[boxIndex] = ofaces
		end
	end
	return #out > 0 and out or nil
end

local function normalizeModelQuads( modelQuads )
	if type( modelQuads ) ~= "table" then return nil end
	local out = {}
	for _, quad in ipairs( modelQuads ) do
		if type( quad ) == "table" and type( quad.verts ) == "table" then
			local verts = {}
			for _, v in ipairs( quad.verts ) do
				if type( v ) == "table" then
					verts[#verts + 1] = {
						x = tonumber( v.x ) or 0,
						y = tonumber( v.y ) or 0,
						z = tonumber( v.z ) or 0,
						u = math.Clamp( tonumber( v.u ) or 0, 0, 1 ),
						v = math.Clamp( tonumber( v.v ) or 0, 0, 1 ),
					}
				end
			end
			if #verts == 4 then
				out[#out + 1] = {
					face = math.floor( tonumber( quad.face ) or 1 ),
					tile = tileValue( quad.tile, 0 ),
					uv = quad.uv,
					rot = math.floor( tonumber( quad.rot ) or 0 ),
					verts = verts,
				}
			end
		end
	end
	return #out > 0 and out or nil
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

-- the generator's name-based solid heuristic misfires on some families (its
-- 'bamboo' plant pattern catches the whole bamboo wood set), so force the
-- blocks that must collide. fences/gates/walls/panes always need collision.
local ForceSolidNames = {
	bamboo_planks = true,
	bamboo_mosaic = true,
	bamboo_block = true,
	stripped_bamboo_block = true,
	bamboo_stairs = true,
	bamboo_slab = true,
	bamboo_mosaic_stairs = true,
	bamboo_mosaic_slab = true,
}

local function shouldForceSolid( name )
	return name == "iron_bars"
		or ForceSolidNames[name] == true
		or string.find( name, "_bars$", 1, false ) ~= nil
		or string.find( name, "_pane$", 1, false ) ~= nil
		or string.find( name, "_fence$", 1, false ) ~= nil
		or string.find( name, "_fence_gate$", 1, false ) ~= nil
		or string.find( name, "_wall$", 1, false ) ~= nil
end

function MC.RegisterBlock( def )
	if not def or def.id == nil then return nil end
	local id = math.floor( tonumber( def.id ) or 0 )
	if id <= 0 then return nil end

	local name = normalizeBlockKey( def.name or ( def.mcid and string.match( def.mcid, "^minecraft:(.+)$" ) ) or id )
	local mcid = normalizeBlockKey( def.mcid or ( "minecraft:" .. name ) )
	local generatedSoundTypes = MC.GeneratedBlockSoundTypes or {}
	local generatedNoTerrainParticles = MC.GeneratedNoTerrainParticles or {}
	local generatedProps = generatedBlockProperties( name, mcid ) or {}
	local textures = def.textures or {}
	local top = tileValue( textures.top or def.top, 0 )
	local side = tileValue( textures.side or def.side, top )
	local bottom = tileValue( textures.bottom or def.bottom, top )
	local front = textures.front and tileValue( textures.front, side ) or nil
	local particle = tileValue( textures.particle or def.particle, side )
	local icon = textures.icon and tileValue( textures.icon, side ) or nil
	local handler = def.handlers or ( def.handler and MC.BlockHandlers[def.handler] ) or nil
	if handler and handler.OnTick then MC.HasBlockTickHandlers = true end

	local b = {
		id = id,
		name = name,
		mcid = mcid,
		disp = blockDisp( { name = name, disp = def.disp, mcid = mcid, id = id } ),
		solid = shouldForceSolid( name ) or def.solid ~= false,
		transparent = def.transparent == true,
		shape = def.shape,
		boxes = normalizeBoxes( def.boxes ),
		boxFaces = normalizeBoxFaces( def.boxFaces ),
		modelQuads = normalizeModelQuads( def.modelQuads ),
		soundType = def.soundType or generatedSoundTypes[mcid] or generatedSoundTypes[name] or "STONE",
		spawnTerrainParticles = def.spawnTerrainParticles ~= false and generatedNoTerrainParticles[mcid] ~= true,
		hardness = propertyNumber( def.hardness, propertyNumber( generatedProps.hardness, 1 ) ),
		explosionResistance = propertyNumber( def.explosionResistance, propertyNumber( generatedProps.explosionResistance, propertyNumber( generatedProps.hardness, 1 ) ) ),
		textures = { top = top, side = side, bottom = bottom, front = front, particle = particle, icon = icon },
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
		particle = particle,
		icon = icon,
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

local SlabTypeName = { [0] = "bottom", [1] = "top", [2] = "double" }
local SlabTypeValue = { bottom = 0, top = 1, double = 2 }
local StairFacingByOrient = {
	[0] = MC.Direction.NORTH,
	[1] = MC.Direction.SOUTH,
	[2] = MC.Direction.WEST,
	[3] = MC.Direction.EAST,
	[4] = MC.Direction.NORTH,
	[5] = MC.Direction.SOUTH,
	[6] = MC.Direction.WEST,
	[7] = MC.Direction.EAST,
}
local StairOrientByFacing = {
	[MC.Direction.NORTH] = 0,
	[MC.Direction.SOUTH] = 1,
	[MC.Direction.WEST] = 2,
	[MC.Direction.EAST] = 3,
}
local StairHalfByOrient = {
	[0] = "bottom",
	[1] = "bottom",
	[2] = "bottom",
	[3] = "bottom",
	[4] = "top",
	[5] = "top",
	[6] = "top",
	[7] = "top",
}

function MC.MakeStairOrient( facing, half )
	local base = StairOrientByFacing[facing] or StairOrientByFacing[MC.Direction.NORTH]
	return ( half == "top" and 4 or 0 ) + base
end

function MC.StairOrientFacing( orient )
	return StairFacingByOrient[MC.NormalizeOrient and math.floor( tonumber( orient ) or 0 ) or orient] or MC.Direction.NORTH
end

function MC.StairOrientHalf( orient )
	return StairHalfByOrient[math.floor( tonumber( orient ) or 0 )] or "bottom"
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
	slab = {
		default = 0,
		names = SlabTypeName,
		values = SlabTypeValue,
		allowed = { [0] = true, [1] = true, [2] = true },
		order = { 0, 1, 2 },
	},
	stairs = {
		default = 0,
		allowed = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true },
		order = { 0, 1, 2, 3, 4, 5, 6, 7 },
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

function MC.BlockHardness( id )
	local b = MC.Blocks[tonumber( id ) or -1]
	if not b then return 1 end
	return tonumber( b.hardness ) or 1
end

function MC.BlockExplosionResistance( id )
	local b = MC.Blocks[tonumber( id ) or -1]
	if not b then return 1 end
	local resistance = tonumber( b.explosionResistance )
	if resistance ~= nil then return resistance end
	return tonumber( b.hardness ) or 1
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
	if b.orient == "slab" then
		return SlabTypeName[MC.NormalizeOrient( id, orient )] or "bottom"
	end
	return rule.names[MC.NormalizeOrient( id, orient )] or ""
end

function MC.BlockStateText( id, orient )
	local b = MC.Blocks[id]
	if not b or not b.orient then return "" end
	if b.orient == "slab" then
		return "type=" .. ( SlabTypeName[MC.NormalizeOrient( id, orient )] or "bottom" )
	end
	if b.orient == "stairs" then
		orient = MC.NormalizeOrient( id, orient )
		local facing = DirectionName[StairFacingByOrient[orient] or MC.Direction.NORTH] or "north"
		local half = StairHalfByOrient[orient] or "bottom"
		return "facing=" .. facing .. ",half=" .. half
	end
	local state = MC.OrientToState( id, orient )
	if state == "" then return "" end
	return ( b.orient == "axis" and "axis=" or "facing=" ) .. state
end

function MC.BlockStateHint( id )
	local b = MC.Blocks[id]
	local rule = b and MC.OrientRules[b.orient]
	if not rule then return "" end
	if b.orient == "slab" then return "type=bottom/top/double" end
	if b.orient == "stairs" then return "facing=north/south/west/east,half=bottom/top" end
	local names = {}
	for _, value in ipairs( rule.order ) do names[#names + 1] = rule.names[value] end
	return ( b.orient == "axis" and "axis=" or "facing=" ) .. table.concat( names, "/" )
end

local function trim( s )
	return string.match( tostring( s or "" ), "^%s*(.-)%s*$" )
end

local function parseStateMap( state )
	if state == nil then return nil end
	state = string.lower( tostring( state ) )
	state = string.match( state, "^%s*%[(.-)%]%s*$" ) or state
	local map = {}
	local saw = false
	for part in string.gmatch( state, "[^,]+" ) do
		local key, value = string.match( part, "^%s*([%a_]+)%s*=%s*([%a_]+)%s*$" )
		if key and value then
			map[key] = value
			saw = true
		end
	end
	return saw and map or nil
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
	local map = parseStateMap( state )
	if b.orient == "slab" then
		return map and SlabTypeValue[map.type or map.half] or SlabTypeValue[trim( state )] or MC.DefaultOrient( id )
	end
	if b.orient == "stairs" then
		local facing = map and DirectionValue[map.facing]
		if not StairOrientByFacing[facing] then facing = nil end
		local half = map and map.half or "bottom"
		if half ~= "top" then half = "bottom" end
		return facing and MC.MakeStairOrient( facing, half ) or MC.DefaultOrient( id )
	end
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
	local map = parseStateMap( state )
	if b.orient == "slab" then
		if map then return SlabTypeValue[map.type or map.half] ~= nil end
		return SlabTypeValue[trim( string.lower( tostring( state ) ) )] ~= nil
	end
	if b.orient == "stairs" then
		if not map then return false end
		local facing = DirectionValue[map.facing]
		local half = map.half or "bottom"
		return StairOrientByFacing[facing] ~= nil and ( half == "bottom" or half == "top" )
	end
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

local function placementHalfFromTrace( tr )
	if not tr then return "bottom" end
	local n = tr.HitNormal
	if n then
		if n.z < -0.5 then return "top" end
		if n.z > 0.5 then return "bottom" end
	end
	if tr.HitPos then
		local z = tr.HitPos.z / MC.BS
		local frac = z - math.floor( z )
		return frac > 0.5 and "top" or "bottom"
	end
	return "bottom"
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
	local b = MC.Blocks[id]
	if b and b.orient == "slab" then
		return placementHalfFromTrace( tr ) == "top" and 1 or 0
	end
	if b and b.orient == "stairs" then
		local facing = horizontalLookDirectionFromForward( forward )
		return MC.MakeStairOrient( facing, placementHalfFromTrace( tr ) )
	end
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
	if b.icon then return b.icon end
	if b.name == "furnace" then return T.furnace_front end
	if b.name == "dispenser" then return T.dispenser_front end
	if b.name == "observer" then return T.observer_front end
	return b.side
end

local function paneParticleTile( b )
	if not b or not b.name then return b and ( b.particle or b.side ) or 0 end
	if b.name == "iron_bars" or string.find( b.name, "_bars$", 1, false ) then return b.particle or b.side end
	if b.name == "glass_pane" and T.glass then return T.glass end
	local glassName = string.match( b.name, "^(.*_stained_glass)_pane$" )
	if glassName and T[glassName] ~= nil then return T[glassName] end
	return b.particle or b.side
end

function MC.BlockParticleTile( id )
	local b = MC.Blocks[id]
	if not b then return 0 end
	if MC.IsPaneBlock and MC.IsPaneBlock( id ) then return paneParticleTile( b ) end
	return b.particle or MC.BlockIconTile( id )
end

local FullBlockBox = { { 0, 0, 0, 1, 1, 1 } }

local function rotateXY( x, y, steps )
	steps = steps % 4
	if steps == 1 then return 1 - y, x end
	if steps == 2 then return 1 - x, 1 - y end
	if steps == 3 then return y, 1 - x end
	return x, y
end

local function rotateBoxZ( box, steps )
	if steps == 0 then return box end
	local minX, minY = 1, 1
	local maxX, maxY = 0, 0
	for _, p in ipairs( {
		{ box[1], box[2] },
		{ box[4], box[2] },
		{ box[1], box[5] },
		{ box[4], box[5] },
	} ) do
		local x, y = rotateXY( p[1], p[2], steps )
		if x < minX then minX = x end
		if y < minY then minY = y end
		if x > maxX then maxX = x end
		if y > maxY then maxY = y end
	end
	return { minX, minY, box[3], maxX, maxY, box[6] }
end

local function rotateBoxX( box, steps )
	if steps == 0 then return box end
	local minY, minZ = 1, 1
	local maxY, maxZ = 0, 0
	for _, p in ipairs( {
		{ box[2], box[3] },
		{ box[5], box[3] },
		{ box[2], box[6] },
		{ box[5], box[6] },
	} ) do
		local y, z = rotateXY( p[1], p[2], steps )
		if y < minY then minY = y end
		if z < minZ then minZ = z end
		if y > maxY then maxY = y end
		if z > maxZ then maxZ = z end
	end
	return { box[1], minY, minZ, box[4], maxY, maxZ }
end

local function horizontalOrientSteps( orient )
	if orient == MC.Direction.EAST then return 1 end
	if orient == MC.Direction.SOUTH then return 2 end
	if orient == MC.Direction.WEST then return 3 end
	return 0
end

local function modelBoxes( b, orient )
	if not b.boxes then return nil end
	local xSteps, zSteps = 0, 0
	if b.orient == "axis" then
		xSteps, zSteps = pillarRotForAxis( MC.NormalizeOrient( b.id, orient ) )
	elseif b.orient == "horizontal_facing" or b.orient == "facing" then
		orient = MC.NormalizeOrient( b.id, orient )
		if b.orient == "facing" and orient == MC.Direction.DOWN then
			xSteps = 1
		elseif b.orient == "facing" and orient == MC.Direction.UP then
			xSteps = 3
		else
			zSteps = horizontalOrientSteps( orient )
		end
	end
	if xSteps == 0 and zSteps == 0 then return b.boxes end
	b._rotatedBoxes = b._rotatedBoxes or {}
	local cacheKey = xSteps .. ":" .. zSteps
	if b._rotatedBoxes[cacheKey] then return b._rotatedBoxes[cacheKey] end
	local out = {}
	for i, box in ipairs( b.boxes ) do
		out[i] = rotateBoxZ( rotateBoxX( box, xSteps ), zSteps )
	end
	b._rotatedBoxes[cacheKey] = out
	return out
end

local FenceGateBoxes = FullBlockBox

local function fenceGateBoxes( orient )
	local steps = horizontalOrientSteps( MC.NormalizeOrient and orient or 0 )
	if steps == 0 then return FenceGateBoxes end
	local out = {}
	for i, box in ipairs( FenceGateBoxes ) do
		out[i] = rotateBoxZ( box, steps )
	end
	return out
end

local function stairBoxes( orient )
	local facing = StairFacingByOrient[orient] or MC.Direction.NORTH
	local top = StairHalfByOrient[orient] == "top"
	local boxes = {}
	if top then
		boxes[#boxes + 1] = { 0, 0, 0.5, 1, 1, 1 }
		if facing == MC.Direction.NORTH then boxes[#boxes + 1] = { 0, 0, 0, 1, 0.5, 0.5 }
		elseif facing == MC.Direction.SOUTH then boxes[#boxes + 1] = { 0, 0.5, 0, 1, 1, 0.5 }
		elseif facing == MC.Direction.WEST then boxes[#boxes + 1] = { 0, 0, 0, 0.5, 1, 0.5 }
		else boxes[#boxes + 1] = { 0.5, 0, 0, 1, 1, 0.5 } end
	else
		boxes[#boxes + 1] = { 0, 0, 0, 1, 1, 0.5 }
		if facing == MC.Direction.NORTH then boxes[#boxes + 1] = { 0, 0, 0.5, 1, 0.5, 1 }
		elseif facing == MC.Direction.SOUTH then boxes[#boxes + 1] = { 0, 0.5, 0.5, 1, 1, 1 }
		elseif facing == MC.Direction.WEST then boxes[#boxes + 1] = { 0, 0, 0.5, 0.5, 1, 1 }
		else boxes[#boxes + 1] = { 0.5, 0, 0.5, 1, 1, 1 } end
	end
	return boxes
end

local function isFenceName( name )
	return name and string.find( name, "_fence$", 1, false ) ~= nil
end

local function isFenceGateName( name )
	return name and string.find( name, "_fence_gate$", 1, false ) ~= nil
end

local function isWallName( name )
	return name and string.find( name, "_wall$", 1, false ) ~= nil
end

-- pane-style blocks: glass panes plus the bar families (iron_bars and the
-- copper_bars variants all end in _bars)
local function isPaneName( name )
	if not name then return false end
	return name == "iron_bars"
		or string.find( name, "_pane$", 1, false ) ~= nil
		or string.find( name, "_bars$", 1, false ) ~= nil
end

function MC.IsFenceBlock( id )
	local b = MC.Blocks[id]
	return b and isFenceName( b.name ) or false
end

function MC.IsPaneBlock( id )
	local b = MC.Blocks[id]
	return b and isPaneName( b.name ) or false
end

-- vanilla translucent render layer: real alpha blending instead of alpha cutout.
-- exact names only ("ice" must not catch packed_ice/blue_ice, which are opaque).
local TranslucentNames = {
	tinted_glass = true,
	ice = true,
	frosted_ice = true,
	slime_block = true,
	honey_block = true,
}

local function isTranslucentName( name )
	if not name then return false end
	if TranslucentNames[name] then return true end
	return string.find( name, "stained_glass", 1, true ) ~= nil
end

function MC.IsTranslucentBlock( id )
	local b = MC.Blocks[id]
	return b ~= nil and b.transparent == true and isTranslucentName( b.name )
end

local function fenceConnectsToBlock( id, orient )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return false end
	if isFenceName( b.name ) or isFenceGateName( b.name ) or isWallName( b.name ) or isPaneName( b.name ) then return true end
	if b.solid == false then return false end
	return MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) or not b.shape
end

local function fenceConnectsToCell( bx, by, bz )
	if bx == nil or not MC.GetBlock then return false end
	local id = MC.GetBlock( bx, by, bz )
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return fenceConnectsToBlock( id, orient )
end

-- connection boxes carry part/dir tags so the renderer can pick per-face
-- textures; physics/outline consumers only read the numeric bounds.
local function fenceBoxes( bx, by, bz )
	local boxes = {
		{ 0.375, 0.375, 0, 0.625, 0.625, 1, part = "post" },
	}

	if bx == nil or by == nil or bz == nil then return boxes end

	if fenceConnectsToCell( bx, by - 1, bz ) then
		boxes[#boxes + 1] = { 0.4375, 0, 0.375, 0.5625, 0.5625, 0.5625, part = "arm", dir = "yn" }
		boxes[#boxes + 1] = { 0.4375, 0, 0.75, 0.5625, 0.5625, 0.9375, part = "arm", dir = "yn" }
	end
	if fenceConnectsToCell( bx, by + 1, bz ) then
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.375, 0.5625, 1, 0.5625, part = "arm", dir = "yp" }
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.75, 0.5625, 1, 0.9375, part = "arm", dir = "yp" }
	end
	if fenceConnectsToCell( bx - 1, by, bz ) then
		boxes[#boxes + 1] = { 0, 0.4375, 0.375, 0.5625, 0.5625, 0.5625, part = "arm", dir = "xn" }
		boxes[#boxes + 1] = { 0, 0.4375, 0.75, 0.5625, 0.5625, 0.9375, part = "arm", dir = "xn" }
	end
	if fenceConnectsToCell( bx + 1, by, bz ) then
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.375, 1, 0.5625, 0.5625, part = "arm", dir = "xp" }
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.75, 1, 0.5625, 0.9375, part = "arm", dir = "xp" }
	end

	return boxes
end

local function paneConnectsToBlock( id, orient )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return false end
	if isPaneName( b.name ) or isFenceName( b.name ) or isFenceGateName( b.name ) or isWallName( b.name ) then return true end
	if b.solid == false then return false end
	return MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) or not b.shape
end

local function paneConnectsToCell( bx, by, bz )
	if bx == nil or not MC.GetBlock then return false end
	local id = MC.GetBlock( bx, by, bz )
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return paneConnectsToBlock( id, orient )
end

local function paneBoxes( bx, by, bz )
	local boxes = {
		{ 0.4375, 0.4375, 0, 0.5625, 0.5625, 1, part = "post" },
	}

	if bx == nil or by == nil or bz == nil then return boxes end

	if paneConnectsToCell( bx, by - 1, bz ) then
		boxes[#boxes + 1] = { 0.4375, 0, 0, 0.5625, 0.4375, 1, part = "arm", dir = "yn" }
	end
	if paneConnectsToCell( bx, by + 1, bz ) then
		boxes[#boxes + 1] = { 0.4375, 0.5625, 0, 0.5625, 1, 1, part = "arm", dir = "yp" }
	end
	if paneConnectsToCell( bx - 1, by, bz ) then
		boxes[#boxes + 1] = { 0, 0.4375, 0, 0.4375, 0.5625, 1, part = "arm", dir = "xn" }
	end
	if paneConnectsToCell( bx + 1, by, bz ) then
		boxes[#boxes + 1] = { 0.5625, 0.4375, 0, 1, 0.5625, 1, part = "arm", dir = "xp" }
	end

	return boxes
end

-- Collision for pane-style blocks should be a small number of continuous strips.
-- Rendering still uses paneBoxes() above so edge/end textures stay Minecraft-like.
local function paneCollisionBoxes( bx, by, bz )
	if bx == nil or by == nil or bz == nil then
		return { { 0.4375, 0.4375, 0, 0.5625, 0.5625, 1 } }
	end

	local yn = paneConnectsToCell( bx, by - 1, bz )
	local yp = paneConnectsToCell( bx, by + 1, bz )
	local xn = paneConnectsToCell( bx - 1, by, bz )
	local xp = paneConnectsToCell( bx + 1, by, bz )
	local boxes = {}

	if yn or yp then
		boxes[#boxes + 1] = { 0.4375, yn and 0 or 0.4375, 0, 0.5625, yp and 1 or 0.5625, 1 }
	end
	if xn or xp then
		boxes[#boxes + 1] = { xn and 0 or 0.4375, 0.4375, 0, xp and 1 or 0.5625, 0.5625, 1 }
	end
	if #boxes == 0 then
		boxes[1] = { 0.4375, 0.4375, 0, 0.5625, 0.5625, 1 }
	end

	return boxes
end

function MC.BlockBoxes( id, orient, bx, by, bz )
	local b = MC.Blocks[id]
	if not b then return nil end
	if b.shape == "slab" then
		orient = MC.NormalizeOrient( id, orient )
		if orient == 1 then return { { 0, 0, 0.5, 1, 1, 1 } } end
		if orient == 2 then return FullBlockBox end
		return { { 0, 0, 0, 1, 1, 0.5 } }
	end
	if b.shape == "stairs" then
		return stairBoxes( MC.NormalizeOrient( id, orient ) )
	end
	if isFenceName( b.name ) then
		return fenceBoxes( bx, by, bz )
	end
	if isFenceGateName( b.name ) then
		return fenceGateBoxes( MC.NormalizeOrient( id, orient ) )
	end
	if isWallName( b.name ) then
		return FullBlockBox
	end
	if isPaneName( b.name ) then
		return paneBoxes( bx, by, bz )
	end
	if b.shape == "model" then
		return modelBoxes( b, orient )
	end
	return FullBlockBox
end

-- collision wants fewer, fatter convexes than rendering: vanilla fence
-- collision is a solid wall per direction (the twin rails are visual only),
-- and Source's multiconvex builder is unhappy with many thin slivers.
function MC.BlockCollisionBoxes( id, orient, bx, by, bz )
	local b = MC.Blocks[id]
	if b and isFenceName( b.name ) and bx ~= nil and by ~= nil and bz ~= nil then
		local boxes = {
			{ 0.375, 0.375, 0, 0.625, 0.625, 1 },
		}
		if fenceConnectsToCell( bx, by - 1, bz ) then
			boxes[#boxes + 1] = { 0.4375, 0, 0.375, 0.5625, 0.5625, 0.9375 }
		end
		if fenceConnectsToCell( bx, by + 1, bz ) then
			boxes[#boxes + 1] = { 0.4375, 0.4375, 0.375, 0.5625, 1, 0.9375 }
		end
		if fenceConnectsToCell( bx - 1, by, bz ) then
			boxes[#boxes + 1] = { 0, 0.4375, 0.375, 0.5625, 0.5625, 0.9375 }
		end
		if fenceConnectsToCell( bx + 1, by, bz ) then
			boxes[#boxes + 1] = { 0.4375, 0.4375, 0.375, 1, 0.5625, 0.9375 }
		end
		return boxes
	end
	if b and isPaneName( b.name ) and bx ~= nil and by ~= nil and bz ~= nil then
		return paneCollisionBoxes( bx, by, bz )
	end
	return MC.BlockBoxes( id, orient, bx, by, bz )
end

function MC.BlockIsFullCube( id, orient )
	local b = MC.Blocks[id]
	if not b or b.solid == false then return false end
	if not b.shape then return true end
	local boxes = MC.BlockBoxes( id, orient )
	return boxes and #boxes == 1
		and boxes[1][1] == 0 and boxes[1][2] == 0 and boxes[1][3] == 0
		and boxes[1][4] == 1 and boxes[1][5] == 1 and boxes[1][6] == 1
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
