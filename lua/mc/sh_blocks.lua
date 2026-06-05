--[[----------------------------------------------------------------------------
	MC : block registry + atlas tile mapping.

	Tile indices MUST match the order produced by _build/build_atlas.ps1.
	(index = column + row*COLS in materials/mc/atlas.png)
------------------------------------------------------------------------------]]

MC = MC or {}

-- atlas tile indices (0-based) -------------------------------------------------
local T = {
	dirt = 0, grass_top = 1, grass_side = 2, stone = 3, cobblestone = 4,
	oak_planks = 5, oak_log = 6, oak_log_top = 7, sand = 8, glass = 9,
	bricks = 10, stone_bricks = 11, bedrock = 12, gold_block = 13, iron_block = 14,
	diamond_block = 15, tnt_side = 16, tnt_top = 17, tnt_bottom = 18,
	crafting_table_top = 19, crafting_table_side = 20, crafting_table_front = 21,
	obsidian = 22, glowstone = 23, netherrack = 24, snow = 25, oak_leaves = 26,
	pumpkin_side = 27, pumpkin_top = 28, melon_side = 29, melon_top = 30,
	bookshelf = 31,
}
MC.Tiles = T

-- block definitions ------------------------------------------------------------
-- per id: { name, disp, top, bottom, side, [transparent] }
-- "transparent" blocks (glass/leaves) use alpha cutout and don't hide faces of
-- neighbouring different blocks.
local function blk( name, disp, top, side, bottom, transparent )
	return {
		name = name,
		disp = disp,
		top = top,
		side = side,
		bottom = bottom or top,
		transparent = transparent or false,
	}
end

MC.Blocks = {
	[1]  = blk( "grass",          "草方块",   T.grass_top,         T.grass_side,           T.dirt ),
	[2]  = blk( "dirt",           "泥土",     T.dirt,              T.dirt,                 T.dirt ),
	[3]  = blk( "stone",          "石头",     T.stone,             T.stone,                T.stone ),
	[4]  = blk( "cobblestone",    "圆石",     T.cobblestone,       T.cobblestone,          T.cobblestone ),
	[5]  = blk( "oak_planks",     "橡木木板", T.oak_planks,        T.oak_planks,           T.oak_planks ),
	[6]  = blk( "oak_log",        "橡木原木", T.oak_log_top,       T.oak_log,              T.oak_log_top ),
	[7]  = blk( "sand",           "沙子",     T.sand,              T.sand,                 T.sand ),
	[8]  = blk( "glass",          "玻璃",     T.glass,             T.glass,                T.glass, true ),
	[9]  = blk( "bricks",         "红砖块",   T.bricks,            T.bricks,               T.bricks ),
	[10] = blk( "stone_bricks",   "石砖",     T.stone_bricks,      T.stone_bricks,         T.stone_bricks ),
	[11] = blk( "bedrock",        "基岩",     T.bedrock,           T.bedrock,              T.bedrock ),
	[12] = blk( "gold_block",     "金块",     T.gold_block,        T.gold_block,           T.gold_block ),
	[13] = blk( "iron_block",     "铁块",     T.iron_block,        T.iron_block,           T.iron_block ),
	[14] = blk( "diamond_block",  "钻石块",   T.diamond_block,     T.diamond_block,        T.diamond_block ),
	[15] = blk( "tnt",            "TNT",      T.tnt_top,           T.tnt_side,             T.tnt_bottom ),
	[16] = blk( "crafting_table", "工作台",   T.crafting_table_top, T.crafting_table_side, T.oak_planks ),
	[17] = blk( "obsidian",       "黑曜石",   T.obsidian,          T.obsidian,             T.obsidian ),
	[18] = blk( "glowstone",      "荧石",     T.glowstone,         T.glowstone,            T.glowstone ),
	[19] = blk( "netherrack",     "下界岩",   T.netherrack,        T.netherrack,           T.netherrack ),
	[20] = blk( "snow",           "雪块",     T.snow,              T.snow,                 T.snow ),
	[21] = blk( "oak_leaves",     "橡树树叶", T.oak_leaves,        T.oak_leaves,           T.oak_leaves, true ),
	[22] = blk( "pumpkin",        "南瓜",     T.pumpkin_top,       T.pumpkin_side,         T.pumpkin_top ),
	[23] = blk( "melon",          "西瓜",     T.melon_top,         T.melon_side,           T.melon_top ),
	[24] = blk( "bookshelf",      "书架",     T.oak_planks,        T.bookshelf,            T.oak_planks ),
}

-- ordered id list for palette / selection
MC.BlockList = {}
for id in pairs( MC.Blocks ) do MC.BlockList[#MC.BlockList + 1] = id end
table.sort( MC.BlockList )
MC.MaxBlockID = MC.BlockList[#MC.BlockList]

--- Is this a valid, placeable block id?
function MC.IsValidBlock( id )
	return id ~= nil and MC.Blocks[id] ~= nil
end

--- Resolve the atlas tile for a block face.
-- face: 1 = +Z(top), 2 = -Z(bottom), 3..6 = sides
function MC.BlockTile( id, face )
	local b = MC.Blocks[id]
	if not b then return 0 end
	if face == 1 then return b.top end
	if face == 2 then return b.bottom end
	return b.side
end

--- UV rectangle for a tile (half-texel inset to avoid bleeding under filtering).
-- returns u0, v0, u1, v1
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