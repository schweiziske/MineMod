-- Shared deterministic layout helpers for the Minecraft-style block gallery.

MC = MC or {}

local EntryCache = {}
local SceneCatalogs = {}

-- Three curated specimen rows facing the camera; each entry rests on a terrace shelf
-- built by MC.DebugGalleryPromoDecorCells (samples land at zone z + 3).
local PROMO_ZONES = {
	{
		id = "rainbow", x = -15, y = 8, z = -2, columns = 16,
		blocks = {
			"minecraft:red_concrete", "minecraft:orange_concrete", "minecraft:yellow_concrete", "minecraft:lime_concrete",
			"minecraft:green_concrete", "minecraft:cyan_concrete", "minecraft:light_blue_concrete", "minecraft:blue_concrete",
			"minecraft:purple_concrete", "minecraft:magenta_concrete", "minecraft:pink_concrete", "minecraft:white_concrete",
			"minecraft:light_gray_concrete", "minecraft:gray_concrete", "minecraft:brown_concrete", "minecraft:black_concrete",
		},
	},
	{
		id = "classics", x = -15, y = 12, z = 0, columns = 16,
		blocks = {
			"minecraft:grass_block", "minecraft:oak_log", "minecraft:oak_planks", "minecraft:crafting_table",
			"minecraft:furnace", "minecraft:chest", "minecraft:bookshelf", "minecraft:tnt",
			"minecraft:bricks", "minecraft:stone_bricks", "minecraft:mossy_cobblestone", "minecraft:sandstone",
			"minecraft:sand", "minecraft:snow_block", "minecraft:packed_ice", "minecraft:obsidian",
		},
	},
	{
		id = "treasure", x = -15, y = 16, z = 2, columns = 16,
		blocks = {
			"minecraft:redstone_block", "minecraft:iron_block", "minecraft:gold_block", "minecraft:diamond_block",
			"minecraft:emerald_block", "minecraft:lapis_block", "minecraft:amethyst_block", "minecraft:copper_block",
			"minecraft:crying_obsidian", "minecraft:magma_block", "minecraft:glowstone", "minecraft:shroomlight",
			"minecraft:ochre_froglight", "minecraft:verdant_froglight", "minecraft:pearlescent_froglight", "minecraft:sea_lantern",
		},
	},
}

-- One-row "hotbar" of the cabin's building palette, laid out in front of the construction scene.
local BUILD_ZONES = {
	{
		id = "palette", x = -17, y = 2, z = -3, columns = 9,
		blocks = {
			"minecraft:oak_planks", "minecraft:spruce_log", "minecraft:stone_bricks",
			"minecraft:cobblestone", "minecraft:glass", "minecraft:bricks",
			"minecraft:glowstone", "minecraft:lantern", "minecraft:scaffolding",
		},
	},
}

local SCENE_ZONES = { promo = PROMO_ZONES, build = BUILD_ZONES }

local function sceneCatalog( mode )
	if SceneCatalogs[mode] then return SceneCatalogs[mode] end
	local catalog = { entries = {}, positions = {}, zones = {} }
	for zoneIndex, zone in ipairs( SCENE_ZONES[mode] or {} ) do
		local used = { definition = zone, count = 0, index = zoneIndex }
		catalog.zones[#catalog.zones + 1] = used
		for _, name in ipairs( zone.blocks ) do
			local stateId = MC.DefaultBlockState and MC.DefaultBlockState( name ) or nil
			if stateId and stateId ~= 0 then
				local localIndex = used.count
				used.count = used.count + 1
				catalog.entries[#catalog.entries + 1] = stateId
				catalog.positions[#catalog.positions + 1] = {
					x = zone.x + ( localIndex % zone.columns ) * 2,
					y = zone.y + math.floor( localIndex / zone.columns ) * 2,
					z = zone.z,
					column = localIndex % zone.columns,
					row = math.floor( localIndex / zone.columns ),
					zone = zone.id,
				}
			end
		end
	end
	SceneCatalogs[mode] = catalog
	return catalog
end

local function normalizedMode( mode )
	mode = string.lower( tostring( mode or "blocks" ) )
	if mode == "states" or mode == "promo" or mode == "build" then return mode end
	return "blocks"
end

function MC.DebugGalleryEntries( mode )
	mode = normalizedMode( mode )
	local cached = EntryCache[mode]
	if cached then return cached end

	local entries = {}
	if SCENE_ZONES[mode] then
		entries = sceneCatalog( mode ).entries
	elseif mode == "states" then
		for stateId = 1, math.max( 0, ( MC.BlockStateCount or 0 ) - 1 ) do
			local schema = MC.BlockStateSchemaById and MC.BlockStateSchemaById[stateId]
			if schema and schema.blockId ~= nil and schema.blockId ~= 0 then
				entries[#entries + 1] = stateId
			end
		end
	else
		local schemas = {}
		for blockId, schema in pairs( MC.BlockStateSchemas or {} ) do
			if blockId ~= 0 and schema and schema.defaultStateId then schemas[#schemas + 1] = schema end
		end
		table.sort( schemas, function( a, b )
			if a.firstStateId ~= b.firstStateId then return a.firstStateId < b.firstStateId end
			return tostring( a.name ) < tostring( b.name )
		end )
		for _, schema in ipairs( schemas ) do entries[#entries + 1] = schema.defaultStateId end
	end

	EntryCache[mode] = entries
	return entries
end

function MC.DebugGalleryPromoPosition( mode, index )
	return sceneCatalog( normalizedMode( mode ) ).positions[math.floor( tonumber( index ) or 0 )]
end

local DecorCache = {}

local function decorBuilder()
	local cells = {}
	local taken = {}
	local function add( x, y, z, name )
		local stateId = MC.DefaultBlockState and MC.DefaultBlockState( name ) or nil
		if not stateId or stateId == 0 then return end
		local key = x .. ":" .. y .. ":" .. z
		if taken[key] then return end
		taken[key] = true
		cells[#cells + 1] = { x = x, y = y, z = z, stateId = stateId }
	end
	local function pick( names )
		for _, name in ipairs( names ) do
			local stateId = MC.DefaultBlockState and MC.DefaultBlockState( name ) or nil
			if stateId and stateId ~= 0 then return name end
		end
		return names[#names]
	end
	return cells, taken, add, pick
end

local MEADOW_FLOWERS = {
	"minecraft:poppy", "minecraft:dandelion", "minecraft:cornflower",
	"minecraft:oxeye_daisy", "minecraft:red_tulip",
}

local function cloudStamp( add, cloudBlock, x0, y0, z0 )
	for y = y0, y0 + 1 do
		for dx = 0, 5 do add( x0 + dx, y, z0, cloudBlock ) end
		for dx = 1, 3 do add( x0 + dx, y, z0 + 1, cloudBlock ) end
	end
end

local function promoDecor( add, pick, taken )

	-- Three stepped terraces the specimen rows rest on; sea lanterns are inset into each front face.
	local tiers = {
		{ y = 8, top = 0, body = "minecraft:smooth_stone", glowZ = 0 },
		{ y = 12, top = 2, body = "minecraft:polished_andesite", glowZ = 1 },
		{ y = 16, top = 4, body = "minecraft:stone_bricks", glowZ = 3 },
	}
	for _, tier in ipairs( tiers ) do
		for x = -16, 16 do
			for z = 0, tier.top do
				add( x, tier.y, z, z == tier.glowZ and x % 8 == 0 and "minecraft:sea_lantern" or tier.body )
			end
		end
	end

	-- Central floating grass island hero, hovering between the terraces and the rainbow.
	add( 0, 24, 7, "minecraft:glowstone" )
	for y = 19, 29 do
		for x = -6, 6 do
			local radius = x * x + ( y - 24 ) * ( y - 24 )
			if radius <= 26 then
				add( x, y, 10, "minecraft:grass_block" )
				add( x, y, 9, "minecraft:dirt" )
				if radius <= 14 then add( x, y, 8, "minecraft:stone" ) end
				if radius <= 5 then add( x, y, 7, "minecraft:stone" ) end
				if radius <= 1 then add( x, y, 6, "minecraft:cobblestone" ) end
			end
		end
	end
	for z = 11, 14 do add( 0, 24, z, "minecraft:oak_log" ) end
	for z = 13, 14 do
		for y = 22, 26 do
			for x = -2, 2 do
				if not ( math.abs( x ) == 2 and math.abs( y - 24 ) == 2 ) then add( x, y, z, "minecraft:oak_leaves" ) end
			end
		end
	end
	for y = 23, 25 do
		for x = -1, 1 do add( x, y, 15, "minecraft:oak_leaves" ) end
	end
	add( 0, 24, 16, "minecraft:oak_leaves" )
	add( -1, 24, 16, "minecraft:oak_leaves" )
	add( 1, 24, 16, "minecraft:oak_leaves" )
	add( 0, 23, 16, "minecraft:oak_leaves" )
	add( 0, 25, 16, "minecraft:oak_leaves" )
	add( -1, 23, 11, "minecraft:torch" )
	add( -4, 24, 11, "minecraft:lantern" )
	add( 2, 22, 11, "minecraft:poppy" )
	add( -3, 26, 11, "minecraft:dandelion" )
	add( 1, 27, 11, "minecraft:cornflower" )
	add( 3, 25, 11, "minecraft:red_tulip" )

	-- Rainbow arch backdrop framing the island, two blocks thick for stronger shadows.
	local rainbow = {
		"minecraft:red_concrete", "minecraft:orange_concrete", "minecraft:yellow_concrete",
		"minecraft:lime_concrete", "minecraft:light_blue_concrete", "minecraft:purple_concrete",
	}
	for y = 31, 32 do
		for x = -17, 17 do
			for z = 0, 17 do
				local ring = math.floor( math.sqrt( x * x + z * z ) + 0.5 )
				if ring >= 11 and ring <= 16 then add( x, y, z, rainbow[17 - ring] ) end
			end
		end
	end

	-- Creeper face billboard on the left lawn.
	local creeperFace = {
		"00000000",
		"01100110",
		"01100110",
		"00011000",
		"00111100",
		"00111100",
		"00100100",
		"00100100",
	}
	for rowIndex, row in ipairs( creeperFace ) do
		local z = #creeperFace - rowIndex
		for columnIndex = 1, #row do
			local x = -26 + columnIndex
			add( x, 29, z, string.sub( row, columnIndex, columnIndex ) == "1" and "minecraft:black_concrete"
				or ( ( x * 3 + z * 5 ) % 4 == 0 and "minecraft:green_concrete" or "minecraft:lime_concrete" ) )
		end
	end

	-- Nether portal vignette on the right lawn.
	for y = 28, 30 do
		for x = 17, 22 do add( x, y, 0, "minecraft:netherrack" ) end
	end
	add( 18, 29, 5, "minecraft:crying_obsidian" )
	add( 21, 29, 1, "minecraft:crying_obsidian" )
	for z = 1, 5 do
		for x = 18, 21 do
			local frame = x == 18 or x == 21 or z == 1 or z == 5
			add( x, 29, z, frame and "minecraft:obsidian" or "minecraft:purple_stained_glass" )
		end
	end

	-- Lawn props: standing lanterns, a pumpkin patch and sunflowers on the open sides.
	for _, side in ipairs( { -1, 1 } ) do
		add( side * 19, 9, 0, "minecraft:lantern" )
		add( side * 22, 18, 0, "minecraft:lantern" )
	end
	add( -21, 15, 0, "minecraft:pumpkin" )
	add( -19, 14, 0, "minecraft:pumpkin" )
	add( -20, 17, 0, "minecraft:pumpkin" )
	add( 19, 14, 0, "minecraft:sunflower" )
	add( 20, 16, 0, "minecraft:sunflower" )
	add( 18, 17, 0, "minecraft:sunflower" )

	-- Meadow floor with a stone walkway leading into the scene, then a deterministic flower sprinkle.
	for y = 2, 32 do
		for x = -25, 25 do
			if math.abs( x ) <= 2 and y <= 7 then
				add( x, y, -1, math.abs( x ) == 2 and "minecraft:polished_andesite" or "minecraft:stone_bricks" )
			else
				add( x, y, -1, "minecraft:grass_block" )
			end
		end
	end
	local meadowFlowers = MEADOW_FLOWERS
	for y = 2, 32 do
		for x = -25, 25 do
			if not ( math.abs( x ) <= 2 and y <= 7 ) and not taken[x .. ":" .. y .. ":0"] then
				local hash = ( x * 41 + y * 61 ) % 37
				if hash == 0 then
					add( x, y, 0, meadowFlowers[( x * 3 + y ) % #meadowFlowers + 1] )
				elseif hash == 19 then
					add( x, y, 0, "minecraft:short_grass" )
				end
			end
		end
	end

	-- Chunky wool clouds framing the sky.
	local cloudBlock = pick( { "minecraft:white_wool", "minecraft:white_concrete" } )
	cloudStamp( add, cloudBlock, -24, 26, 14 )
	cloudStamp( add, cloudBlock, 17, 24, 15 )
	cloudStamp( add, cloudBlock, -9, 30, 18 )
end

-- Half-built cozy cabin construction site: the timber frame is complete, the plank
-- walls taper off to the right where the posing player is still laying courses.
local function constructionDecor( add, pick, taken )
	-- Reserve the palette-row cells so the meadow sprinkle cannot overwrite gallery entries.
	for x = -17, -1, 2 do taken[x .. ":2:0"] = true end

	-- Corner posts, top plate and exposed ceiling beams of the timber frame.
	for _, corner in ipairs( { { -6, 12 }, { 6, 12 }, { -6, 20 }, { 6, 20 } } ) do
		for z = 0, 4 do add( corner[1], corner[2], z, "minecraft:spruce_log" ) end
	end
	for y = 12, 20 do add( -6, y, 4, "minecraft:spruce_log" ) end
	for x = -6, 1 do
		add( x, 12, 4, "minecraft:spruce_log" )
		add( x, 20, 4, "minecraft:spruce_log" )
	end
	for y = 13, 19 do
		add( -3, y, 4, "minecraft:spruce_log" )
		add( 0, y, 4, "minecraft:spruce_log" )
	end

	-- Front wall: finished on the left, stepped unfinished courses on the right, door at x = 0.
	local frontTops = { [-5] = 3, [-4] = 3, [-3] = 3, [-2] = 3, [-1] = 3, [0] = 3, [1] = 3, [2] = 2, [3] = 2, [4] = 1, [5] = 1 }
	for x = -5, 5 do
		if x ~= 0 then add( x, 12, 0, "minecraft:stone_bricks" ) end
		for z = 1, frontTops[x] do
			if not ( x == 0 and z <= 1 ) then
				add( x, 12, z, ( x == -4 or x == -3 ) and z == 2 and "minecraft:glass" or "minecraft:oak_planks" )
			end
		end
	end

	-- Back and left walls are done; the right wall only has its first course so far.
	for x = -5, 5 do
		add( x, 20, 0, "minecraft:stone_bricks" )
		for z = 1, 3 do add( x, 20, z, ( x == 1 or x == 2 ) and z == 2 and "minecraft:glass" or "minecraft:oak_planks" ) end
	end
	for y = 13, 19 do
		add( -6, y, 0, "minecraft:stone_bricks" )
		for z = 1, 3 do add( -6, y, z, ( y == 15 or y == 17 ) and z == 2 and "minecraft:glass" or "minecraft:oak_planks" ) end
		add( 6, y, 0, "minecraft:stone_bricks" )
		if y <= 15 then add( 6, y, 1, "minecraft:oak_planks" ) end
	end

	-- Roof: only the left patch of planks has been laid.
	for y = 11, 21 do
		for x = -7, -3 do add( x, y, 5, "minecraft:spruce_planks" ) end
	end

	-- Interior: workstations along the back wall, warm light spilling out of the open half.
	add( -5, 19, 0, "minecraft:bookshelf" )
	add( -4, 19, 0, "minecraft:furnace" )
	add( -3, 19, 0, "minecraft:crafting_table" )
	add( -2, 19, 0, "minecraft:chest" )
	add( -1, 19, 0, "minecraft:barrel" )
	add( -5, 16, 4, "minecraft:lantern" )
	add( 1, 13, 0, "minecraft:torch" )
	add( 2, 16, -1, "minecraft:glowstone" )

	-- Builder's torches on the unfinished courses, scaffolding bridge along the low wall.
	add( 3, 12, 3, "minecraft:torch" )
	add( 5, 12, 2, "minecraft:torch" )
	add( 6, 17, 1, "minecraft:torch" )
	for y = 13, 17 do
		for z = 0, 3 do
			if y == 13 or y == 17 or z == 3 then add( 8, y, z, "minecraft:scaffolding" ) end
		end
	end

	-- Material stockpiles in the yard.
	for x = 12, 13 do
		for y = 5, 6 do
			add( x, y, 0, "minecraft:oak_planks" )
			add( x, y, 1, "minecraft:oak_planks" )
		end
	end
	for x = 9, 11 do
		for y = 8, 9 do add( x, y, 0, "minecraft:spruce_log" ) end
	end
	add( 10, 8, 1, "minecraft:spruce_log" )
	add( 10, 9, 1, "minecraft:spruce_log" )
	for _, heap in ipairs( { { 14, 8 }, { 15, 8 }, { 14, 9 }, { 15, 9 } } ) do
		add( heap[1], heap[2], 0, "minecraft:cobblestone" )
	end
	add( 15, 8, 1, "minecraft:cobblestone" )
	add( 9, 4, 0, "minecraft:stone_bricks" )
	add( 9, 5, 0, "minecraft:stone_bricks" )
	add( 9, 4, 1, "minecraft:stone_bricks" )
	add( 11, 4, 0, "minecraft:glass" )
	add( 11, 4, 1, "minecraft:glass" )
	add( 16, 5, 0, "minecraft:bricks" )
	add( 16, 5, 1, "minecraft:bricks" )
	add( 16, 18, 0, "minecraft:hay_block" )
	add( 16, 19, 0, "minecraft:hay_block" )

	-- Campfire rest corner and lanterns by the door.
	add( 13, 2, 0, "minecraft:campfire" )
	add( 11, 2, 0, "minecraft:spruce_log" )
	add( 15, 2, 0, "minecraft:spruce_log" )
	add( 3, 10, 0, "minecraft:lantern" )
	add( -8, 12, 0, "minecraft:lantern" )

	-- Oak tree on the back-left lawn for a long shadow across the meadow.
	for z = 0, 3 do add( -13, 23, z, "minecraft:oak_log" ) end
	for z = 2, 3 do
		for y = 21, 25 do
			for x = -15, -11 do
				if not ( math.abs( x + 13 ) == 2 and math.abs( y - 23 ) == 2 ) then add( x, y, z, "minecraft:oak_leaves" ) end
			end
		end
	end
	for y = 22, 24 do
		for x = -14, -12 do add( x, y, 4, "minecraft:oak_leaves" ) end
	end
	add( -13, 23, 5, "minecraft:oak_leaves" )
	add( -12, 23, 5, "minecraft:oak_leaves" )
	add( -14, 23, 5, "minecraft:oak_leaves" )
	add( -13, 22, 5, "minecraft:oak_leaves" )
	add( -13, 24, 5, "minecraft:oak_leaves" )
	add( -10, 18, 0, "minecraft:oak_sapling" )

	-- Cabin plank floor, stone threshold, then the meadow with a worn path to the door.
	for y = 13, 19 do
		for x = -5, 5 do add( x, y, -1, "minecraft:oak_planks" ) end
	end
	add( 0, 12, -1, "minecraft:stone_bricks" )
	for y = 0, 28 do
		for x = -18, 18 do
			if math.abs( x ) <= 1 and y <= 11 then
				add( x, y, -1, ( x * 7 + y * 11 ) % 5 == 0 and "minecraft:gravel" or "minecraft:dirt_path" )
			else
				add( x, y, -1, "minecraft:grass_block" )
			end
		end
	end
	-- Keep the foreground apron around the palette row clean; sprinkle only past it.
	for y = 4, 28 do
		for x = -18, 18 do
			if not ( math.abs( x ) <= 1 and y <= 11 ) and not taken[x .. ":" .. y .. ":0"] then
				local hash = ( x * 41 + y * 61 ) % 41
				if hash == 0 then
					add( x, y, 0, MEADOW_FLOWERS[( x * 3 + y ) % #MEADOW_FLOWERS + 1] )
				elseif hash == 21 then
					add( x, y, 0, "minecraft:short_grass" )
				end
			end
		end
	end

	-- Wool clouds drifting over the site.
	local cloudBlock = pick( { "minecraft:white_wool", "minecraft:white_concrete" } )
	cloudStamp( add, cloudBlock, -17, 22, 12 )
	cloudStamp( add, cloudBlock, 10, 25, 14 )
end

local DECOR_BUILDERS = { promo = promoDecor, build = constructionDecor }

function MC.DebugGalleryPromoDecorCells( descriptor )
	local mode = descriptor and normalizedMode( descriptor.mode ) or nil
	local builder = mode and DECOR_BUILDERS[mode] or nil
	if not builder then return {} end
	if DecorCache[mode] then return DecorCache[mode] end
	local cells, taken, add, pick = decorBuilder()
	builder( add, pick, taken )
	if #cells > 0 then DecorCache[mode] = cells end
	return cells
end

function MC.DebugGalleryEntryState( descriptor, index )
	if not descriptor then return nil end
	return MC.DebugGalleryEntries( descriptor.mode )[math.floor( tonumber( index ) or 0 )]
end

function MC.DebugGalleryCell( descriptor, index, baseLayer )
	if not descriptor then return nil end
	index = math.floor( tonumber( index ) or 0 )
	local sceneMode = normalizedMode( descriptor.mode )
	if SCENE_ZONES[sceneMode] then
		local position = MC.DebugGalleryPromoPosition( sceneMode, index )
		if not position then return nil end
		local bx = math.floor( tonumber( descriptor.originX ) or 0 )
			+ position.x * math.floor( tonumber( descriptor.columnX ) or 1 )
			+ position.y * math.floor( tonumber( descriptor.rowX ) or 0 )
		local by = math.floor( tonumber( descriptor.originY ) or 0 )
			+ position.x * math.floor( tonumber( descriptor.columnY ) or 0 )
			+ position.y * math.floor( tonumber( descriptor.rowY ) or 1 )
		local bz = ( baseLayer and math.floor( tonumber( descriptor.baseZ ) or 0 )
			or math.floor( tonumber( descriptor.sampleZ ) or 0 ) ) + position.z
		return bx, by, bz, position.column, position.row, 0
	end
	local columns = math.max( 1, math.floor( tonumber( descriptor.columns ) or 1 ) )
	local spacing = math.max( 1, math.floor( tonumber( descriptor.spacing ) or 1 ) )
	local rowsPerLayer = math.max( 1, math.floor( tonumber( descriptor.rowsPerLayer ) or math.ceil( ( descriptor.count or 1 ) / columns ) ) )
	local layerCapacity = columns * rowsPerLayer
	local layerHeight = math.max( 1, math.floor( tonumber( descriptor.layerHeight ) or 1 ) )
	if index < 1 or index > math.max( 0, math.floor( tonumber( descriptor.count ) or 0 ) ) then return nil end

	local ordinal = index - 1
	local layer = math.floor( ordinal / layerCapacity )
	local layerOrdinal = ordinal % layerCapacity
	local column = layerOrdinal % columns
	local row = math.floor( layerOrdinal / columns )
	local columnStep = column * spacing
	local rowStep = row * spacing
	local bx = math.floor( tonumber( descriptor.originX ) or 0 )
		+ columnStep * math.floor( tonumber( descriptor.columnX ) or 1 )
		+ rowStep * math.floor( tonumber( descriptor.rowX ) or 0 )
	local by = math.floor( tonumber( descriptor.originY ) or 0 )
		+ columnStep * math.floor( tonumber( descriptor.columnY ) or 0 )
		+ rowStep * math.floor( tonumber( descriptor.rowY ) or 1 )
	local bz = ( baseLayer and math.floor( tonumber( descriptor.baseZ ) or 0 )
		or math.floor( tonumber( descriptor.sampleZ ) or 0 ) ) + layer * layerHeight
	return bx, by, bz, column, row, layer
end

function MC.DebugGalleryIndexAtCell( descriptor, bx, by, bz )
	if not descriptor then return nil end
	bx, by, bz = math.floor( tonumber( bx ) or 0 ), math.floor( tonumber( by ) or 0 ), math.floor( tonumber( bz ) or 0 )
	local sceneMode = normalizedMode( descriptor.mode )
	if SCENE_ZONES[sceneMode] then
		local dx = bx - math.floor( tonumber( descriptor.originX ) or 0 )
		local dy = by - math.floor( tonumber( descriptor.originY ) or 0 )
		local localX = dx * math.floor( tonumber( descriptor.columnX ) or 1 )
			+ dy * math.floor( tonumber( descriptor.columnY ) or 0 )
		local localY = dx * math.floor( tonumber( descriptor.rowX ) or 0 )
			+ dy * math.floor( tonumber( descriptor.rowY ) or 1 )
		local baseZ = math.floor( tonumber( descriptor.baseZ ) or 0 )
		local sampleZ = math.floor( tonumber( descriptor.sampleZ ) or 0 )
		for index, position in ipairs( sceneCatalog( sceneMode ).positions ) do
			if position.x == localX and position.y == localY then
				if bz == baseZ + position.z then return index, true, 0 end
				if bz == sampleZ + position.z then return index, false, 0 end
			end
		end
		return nil
	end
	local baseZ = math.floor( tonumber( descriptor.baseZ ) or 0 )
	local sampleZ = math.floor( tonumber( descriptor.sampleZ ) or 0 )
	local columns = math.max( 1, math.floor( tonumber( descriptor.columns ) or 1 ) )
	local rowsPerLayer = math.max( 1, math.floor( tonumber( descriptor.rowsPerLayer ) or math.ceil( ( descriptor.count or 1 ) / columns ) ) )
	local layerCapacity = columns * rowsPerLayer
	local layerHeight = math.max( 1, math.floor( tonumber( descriptor.layerHeight ) or 1 ) )
	local layerCount = math.max( 1, math.ceil( math.max( 0, descriptor.count or 0 ) / layerCapacity ) )
	local layer, aimedAtBase
	local baseDelta = bz - baseZ
	if baseDelta >= 0 and baseDelta % layerHeight == 0 then
		local candidate = baseDelta / layerHeight
		if candidate < layerCount then
			layer = candidate
			aimedAtBase = true
		end
	end
	local sampleDelta = bz - sampleZ
	if layer == nil and sampleDelta >= 0 and sampleDelta % layerHeight == 0 then
		local candidate = sampleDelta / layerHeight
		if candidate < layerCount then layer = candidate end
	end
	if layer == nil or layer >= layerCount then return nil end

	local dx = bx - math.floor( tonumber( descriptor.originX ) or 0 )
	local dy = by - math.floor( tonumber( descriptor.originY ) or 0 )
	local columnX = math.floor( tonumber( descriptor.columnX ) or 1 )
	local columnY = math.floor( tonumber( descriptor.columnY ) or 0 )
	local rowX = math.floor( tonumber( descriptor.rowX ) or 0 )
	local rowY = math.floor( tonumber( descriptor.rowY ) or 1 )
	local spacing = math.max( 1, math.floor( tonumber( descriptor.spacing ) or 1 ) )
	local columnDistance = dx * columnX + dy * columnY
	local rowDistance = dx * rowX + dy * rowY
	if columnDistance < 0 or rowDistance < 0 then return nil end
	if columnDistance % spacing ~= 0 or rowDistance % spacing ~= 0 then return nil end

	local column = columnDistance / spacing
	local row = rowDistance / spacing
	if column >= columns then return nil end
	if row >= rowsPerLayer then return nil end
	local index = layer * layerCapacity + row * columns + column + 1
	if index > math.max( 0, math.floor( tonumber( descriptor.count ) or 0 ) ) then return nil end
	return index, aimedAtBase == true, layer
end

function MC.DebugGalleryBounds( descriptor )
	if not descriptor or ( descriptor.count or 0 ) < 1 then return nil end
	local sceneMode = normalizedMode( descriptor.mode )
	if SCENE_ZONES[sceneMode] then
		local minX, minY, minZ, maxX, maxY, maxZ
		local function includeLocal( x, y, z )
			local worldX = descriptor.originX + x * descriptor.columnX + y * descriptor.rowX
			local worldY = descriptor.originY + x * descriptor.columnY + y * descriptor.rowY
			local worldZ = descriptor.baseZ + z
			minX, maxX = minX and math.min( minX, worldX ) or worldX, maxX and math.max( maxX, worldX ) or worldX
			minY, maxY = minY and math.min( minY, worldY ) or worldY, maxY and math.max( maxY, worldY ) or worldY
			minZ, maxZ = minZ and math.min( minZ, worldZ ) or worldZ, maxZ and math.max( maxZ, worldZ ) or worldZ
		end
		for _, position in ipairs( sceneCatalog( sceneMode ).positions ) do
			includeLocal( position.x, position.y, position.z )
			includeLocal( position.x, position.y, position.z + descriptor.sampleZ - descriptor.baseZ )
		end
		for _, cell in ipairs( MC.DebugGalleryPromoDecorCells( descriptor ) ) do includeLocal( cell.x, cell.y, cell.z ) end
		return minX, minY, minZ, maxX, maxY, maxZ
	end
	local columns = math.max( 1, descriptor.columns )
	local rows = math.ceil( descriptor.count / columns )
	local rowsPerLayer = math.max( 1, math.floor( tonumber( descriptor.rowsPerLayer ) or rows ) )
	local layerCapacity = columns * rowsPerLayer
	local layerCount = math.max( 1, math.ceil( descriptor.count / layerCapacity ) )
	local footprintRows = math.min( rows, rowsPerLayer )
	local lastColumn = math.min( descriptor.columns, descriptor.count ) - 1
	local lastRow = footprintRows - 1
	local spacing = descriptor.spacing
	local corners = {
		{ 0, 0 },
		{ lastColumn * spacing, 0 },
		{ 0, lastRow * spacing },
		{ lastColumn * spacing, lastRow * spacing },
	}
	local minX, maxX, minY, maxY
	for _, corner in ipairs( corners ) do
		local x = descriptor.originX + corner[1] * descriptor.columnX + corner[2] * descriptor.rowX
		local y = descriptor.originY + corner[1] * descriptor.columnY + corner[2] * descriptor.rowY
		minX, maxX = minX and math.min( minX, x ) or x, maxX and math.max( maxX, x ) or x
		minY, maxY = minY and math.min( minY, y ) or y, maxY and math.max( maxY, y ) or y
	end
	local topOffset = ( layerCount - 1 ) * math.max( 1, math.floor( tonumber( descriptor.layerHeight ) or 1 ) )
	return minX, minY, math.min( descriptor.baseZ, descriptor.sampleZ ),
		maxX, maxY, math.max( descriptor.baseZ, descriptor.sampleZ ) + topOffset
end
