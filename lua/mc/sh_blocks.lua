--[[----------------------------------------------------------------------------
	MC : block registry + texture/blockstate mapping.

	Stored states mirror Minecraft blockstates:
	  oak_log: axis=x/y/z
	  furnace: facing=north/south/west/east
	  dispenser/observer: facing=down/up/north/south/west/east
------------------------------------------------------------------------------]]

MC = MC or {}

local bit_band, bit_rshift, bit_lshift = bit.band, bit.rshift, bit.lshift
local MODEL_SURFACE_TILE_MASK = 4095
local MODEL_SURFACE_TILE_SHIFT = 12

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

local function blockDisp( name, mcid, id, explicit )
	local generated = MC.GeneratedBlockNames or {}
	return explicit or generated[mcid] or generated[name] or FixedDisp[name] or ( "方块 " .. tostring( name or mcid or id ) )
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

local function generatedBlockLight( name, mcid )
	local generated = MC.GeneratedBlockLight or {}
	if generated[mcid] ~= nil then return generated[mcid] end
	if generated[name] ~= nil then return generated[name] end
	if string.StartWith( mcid or "", "minecraft:" ) then
		return generated[string.sub( mcid, 11 )]
	end
	return nil
end

local function generatedConnectionKind( name, mcid )
	local generated = MC.GeneratedBlockConnections or {}
	return generated[mcid] or generated[name]
end

-- true/false from Blocks.java (sh_generated_block_collision.lua); nil when the
-- block is unknown to the Minecraft source (plugin/custom registrations).
local function generatedBlockCollision( name, mcid )
	local generated = MC.GeneratedBlockCollision or {}
	if generated[mcid] ~= nil then return generated[mcid] end
	if generated[name] ~= nil then return generated[name] end
	if string.StartWith( mcid or "", "minecraft:" ) then
		return generated[string.sub( mcid, 11 )]
	end
	return nil
end

local function generatedBlockModelVariants( name, mcid )
	local generated = MC.GeneratedBlockModelVariants or {}
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

local function quadLightEmissionValue( value, tile )
	local emission = math.Clamp( math.floor( tonumber( value ) or 0 ), 0, 15 )
	if emission > 0 then return emission end
	if type( tile ) == "string" and string.find( tile, "_emissive", 1, true ) then return 15 end
	return 0
end

local function normalizeBaked( baked )
	if type( baked ) ~= "table" then return nil end
	local out = {}
	for orient, faces in pairs( baked ) do
		local ofaces = {}
		for face, data in pairs( faces ) do
			if type( data ) == "table" then
				local lightEmission = quadLightEmissionValue( data.lightEmission or data.light_emission, data.tile )
				ofaces[tonumber( face ) or face] = {
					tile = tileValue( data.tile, 0 ),
					rot = math.floor( tonumber( data.rot ) or 0 ),
					uv = data.uv,
					uvs = data.uvs,
					tintIndex = math.floor( tonumber( data.tintIndex or data.tintindex ) or -1 ),
					lightEmission = lightEmission,
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
					local lightEmission = quadLightEmissionValue( data.lightEmission or data.light_emission, data.tile )
					ofaces[tonumber( face ) or face] = {
						tile = tileValue( data.tile, 0 ),
						uv = data.uv,
						rot = math.floor( tonumber( data.rot ) or 0 ),
						tintIndex = math.floor( tonumber( data.tintIndex or data.tintindex ) or -1 ),
						lightEmission = lightEmission,
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
				local lightEmission = quadLightEmissionValue( quad.lightEmission or quad.light_emission, quad.tile )
				out[#out + 1] = {
					face = math.floor( tonumber( quad.face ) or 1 ),
					tile = tileValue( quad.tile, 0 ),
					uv = quad.uv,
					rot = math.floor( tonumber( quad.rot ) or 0 ),
					tintIndex = math.floor( tonumber( quad.tintIndex or quad.tintindex ) or -1 ),
					lightEmission = lightEmission,
					verts = verts,
				}
			end
		end
	end
	return #out > 0 and out or nil
end

local function normalizeCollisionConvexes( convexes )
	if type( convexes ) ~= "table" then return nil end
	local out = {}
	for _, convex in ipairs( convexes ) do
		if type( convex ) == "table" then
			local points = {}
			for _, p in ipairs( convex ) do
				if type( p ) == "table" then
					local x = tonumber( p.x or p[1] )
					local y = tonumber( p.y or p[2] )
					local z = tonumber( p.z or p[3] )
					if x and y and z then
						points[#points + 1] = {
							math.Clamp( x, 0, 1 ),
							math.Clamp( y, 0, 1 ),
							math.Clamp( z, 0, 1 ),
						}
					end
				end
			end
			if #points >= 4 then out[#out + 1] = points end
		end
	end
	return #out > 0 and out or nil
end

local function normalizeModelVariantData( data )
	if type( data ) ~= "table" then return nil end
	local boxes = normalizeBoxes( data.boxes )
	local boxFaces = normalizeBoxFaces( data.boxFaces )
	local modelQuads = normalizeModelQuads( data.modelQuads )
	if not boxes or not boxFaces or not modelQuads then return nil end
	return { boxes = boxes, boxFaces = boxFaces, modelQuads = modelQuads }
end

local function normalizeModelVariants( variants )
	if type( variants ) ~= "table" then return nil end
	local out = {}
	for key, data in pairs( variants ) do
		local normalized = normalizeModelVariantData( data )
		if normalized then out[key] = normalized end
	end
	return next( out ) and out or nil
end

function MC.PackBlockModelSurface( tile, lightEmission )
	tile = math.floor( tonumber( tile ) or 0 )
	lightEmission = math.Clamp( math.floor( tonumber( lightEmission ) or 0 ), 0, 15 )
	return tile + bit_lshift( lightEmission, MODEL_SURFACE_TILE_SHIFT )
end

function MC.BlockModelSurface( block, data )
	if not data then return 0, 0 end
	local surface = data.surface
	local surfaces = block and block.modelSurfaces
	if surface and surfaces then
		local packed = surfaces[surface] or 0
		return bit_band( packed, MODEL_SURFACE_TILE_MASK ), bit_rshift( packed, MODEL_SURFACE_TILE_SHIFT )
	end
	return data.tile or 0, data.lightEmission or 0
end

function MC.ModelQuadVertex( quad, index )
	local vertices = quad and quad.verts
	if not vertices then return 0, 0, 0, 0, 0 end
	if type( vertices[1] ) == "number" then
		local offset = ( index - 1 ) * 5
		return vertices[offset + 1] or 0, vertices[offset + 2] or 0, vertices[offset + 3] or 0,
			vertices[offset + 4] or 0, vertices[offset + 5] or 0
	end
	local vertex = vertices[index]
	if not vertex then return 0, 0, 0, 0, 0 end
	return vertex.x or vertex[1] or 0, vertex.y or vertex[2] or 0, vertex.z or vertex[3] or 0,
		vertex.u or vertex[4] or 0, vertex.v or vertex[5] or 0
end

MC.Blocks = {}
MC.BlockByName = {}
MC.BlockAliases = {}
MC.BlockHandlers = MC.BlockHandlers or {}

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

local function shouldForceSolid( name, mcid )
	local kind = generatedConnectionKind( name, mcid )
	return kind == "fence"
		or kind == "fence_gate"
		or kind == "wall"
		or kind == "pane"
		or kind == "bars"
		or kind == "pipe6"
		or ForceSolidNames[name] == true
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
	local generatedLight = generatedBlockLight( name, mcid )
	local generatedVariants = generatedBlockModelVariants( name, mcid )
	local connectionKind = def.connection or generatedConnectionKind( name, mcid )
	local textures = def.textures or {}
	local top = tileValue( textures.top or def.top, 0 )
	local side = tileValue( textures.side or def.side, top )
	local bottom = tileValue( textures.bottom or def.bottom, top )
	local frontValue = textures.front or def.front
	local front = frontValue ~= nil and tileValue( frontValue, side ) or nil
	local particle = tileValue( textures.particle or def.particle, side )
	local iconValue = textures.icon or def.icon
	local icon = iconValue ~= nil and tileValue( iconValue, side ) or nil
	local generatedGeometry = def.generatedGeometry

	-- vanilla collision truth beats the generator's name-based solid heuristic
	-- (its substring patterns misfire on mushroom blocks, coral blocks, eggs,
	-- pots, beds, doors, ...); def.solid only decides blocks the source lacks.
	local solid = generatedBlockCollision( name, mcid )
	if solid == nil then solid = def.solid ~= false end
	local stateRule = def.stateRule or def.orient
	if string.match( name, "_door$" ) then
		stateRule = "door"
	elseif string.match( name, "_trapdoor$" ) then
		stateRule = "trapdoor"
	elseif string.match( name, "_bed$" ) then
		stateRule = "bed"
	end
	local handlerName = def.handler
	if not handlerName and stateRule == "door" then handlerName = "door" end
	if not handlerName and stateRule == "trapdoor" then handlerName = "trapdoor" end
	local handler = def.handlers or ( handlerName and MC.BlockHandlers[handlerName] ) or nil
	if handler and handler.OnTick then MC.HasBlockTickHandlers = true end

	local displayName = blockDisp( name, mcid, id, def.disp )
	local b = {
		id = id,
		name = name,
		mcid = mcid,
		disp = displayName,
		dispZH = displayName,
		solid = shouldForceSolid( name, mcid ) or solid,
		transparent = def.transparent == true,
		shape = def.shape,
		custom = def.custom == true,
		creativeCategory = def.creativeCategory,
		boxes = generatedGeometry and generatedGeometry.boxes or normalizeBoxes( def.boxes ),
		boxFaces = generatedGeometry and generatedGeometry.boxFaces or normalizeBoxFaces( def.boxFaces ),
		modelQuads = generatedGeometry and generatedGeometry.modelQuads or normalizeModelQuads( def.modelQuads ),
		modelVariants = generatedGeometry and generatedGeometry.modelVariants or normalizeModelVariants( def.modelVariants or generatedVariants ),
		modelSurfaces = def.modelSurfaces,
		compactModel = generatedGeometry and generatedGeometry.compact == true or false,
		collisionConvexes = def.generatedCollisionConvexes or normalizeCollisionConvexes( def.collisionConvexes or def.convexes ),
		connection = connectionKind,
		soundType = def.soundType or generatedSoundTypes[mcid] or generatedSoundTypes[name] or "STONE",
		spawnTerrainParticles = def.spawnTerrainParticles ~= false and generatedNoTerrainParticles[mcid] ~= true,
		hardness = propertyNumber( def.hardness, propertyNumber( generatedProps.hardness, 1 ) ),
		explosionResistance = propertyNumber( def.explosionResistance, propertyNumber( generatedProps.explosionResistance, propertyNumber( generatedProps.hardness, 1 ) ) ),
		lightEmission = math.Clamp( propertyNumber( def.lightEmission, generatedLight or 0 ), 0, 15 ),
		textures = { top = top, side = side, bottom = bottom, front = front, particle = particle, icon = icon },
		baked = generatedGeometry and generatedGeometry.baked or normalizeBaked( def.baked ),
		stateSchema = def.stateSchema or def.blockStateSchema,
		stateRule = stateRule,
		placeRule = def.placeRule or def.place,
		iconSource = def.iconSource,
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
		orient = stateRule,
		place = def.placeRule or def.place,
	}
	if MC.BlockDisplayName then b.disp = MC.BlockDisplayName( b, displayName ) end

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

function MC.RefreshBlockList()
	rebuildBlockList()
end

local function registerGeneratedBlocks()
	local catalog = MC.GeneratedBlockCatalog
	if not catalog or type( catalog.rows ) ~= "table" then return false end
	local rows = catalog.rows
	-- RegisterBlock never retains the input definition itself. Reuse one staging
	-- record instead of allocating 1197 short-lived keyed tables during startup.
	local definition = {}
	for index = 1, #rows do
		local row = rows[index]
		local flags = row[4] or 0
		local geometry = catalog.geometry[row[13] or 0]
		local surface = catalog.surfaces[row[14] or 0]
		local mcidLocal = row[3] or row[2]
		definition.id = row[1]
		definition.name = row[2]
		definition.mcid = "minecraft:" .. mcidLocal
		definition.solid = bit_band( flags, 1 ) ~= 0
		definition.transparent = bit_band( flags, 2 ) ~= 0
		definition.top = row[5]
		definition.side = row[6]
		definition.bottom = row[7]
		definition.front = row[8] and row[8] >= 0 and row[8] or nil
		definition.icon = row[9] and row[9] >= 0 and row[9] or nil
		definition.stateRule = catalog.stateRules[row[10] or 0]
		definition.placeRule = catalog.placeRules[row[11] or 0]
		definition.shape = catalog.shapes[row[12] or 0]
		definition.generatedGeometry = geometry
		definition.modelSurfaces = surface
		definition.defaultOrientName = catalog.defaultOrients[row[15] or 0]
		definition.handler = catalog.handlers[row[16] or 0]
		definition.aliases = row[17] or nil
		MC.RegisterBlock( definition )
	end
	MC.GeneratedBlockDefinitionCount = #rows
	MC.GeneratedBlockCatalogStats = {
		blocks = #rows,
		geometryTemplates = #catalog.geometry,
		surfaceSets = #catalog.surfaces,
	}
	MC.GeneratedBlockCatalog = nil
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

local HorizontalPartFacingByBase = {
	[0] = MC.Direction.NORTH,
	[1] = MC.Direction.SOUTH,
	[2] = MC.Direction.WEST,
	[3] = MC.Direction.EAST,
}
local HorizontalPartBaseByFacing = {
	[MC.Direction.NORTH] = 0,
	[MC.Direction.SOUTH] = 1,
	[MC.Direction.WEST] = 2,
	[MC.Direction.EAST] = 3,
}
local function horizontalPartBase( facing )
	return HorizontalPartBaseByFacing[facing] or HorizontalPartBaseByFacing[MC.Direction.NORTH]
end

local function horizontalPartFacing( orient )
	return HorizontalPartFacingByBase[math.floor( tonumber( orient ) or 0 ) % 4] or MC.Direction.NORTH
end

function MC.MakeDoorOrient( facing, half, open, hinge, powered )
	return horizontalPartBase( facing )
		+ ( half == "upper" and 4 or 0 )
		+ ( open and 8 or 0 )
		+ ( hinge == "right" and 16 or 0 )
		+ ( powered and 32 or 0 )
end

function MC.DoorOrientFacing( orient )
	return horizontalPartFacing( orient )
end

function MC.DoorOrientHalf( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 4 ) % 2 == 1 and "upper" or "lower"
end

function MC.DoorOrientOpen( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 8 ) % 2 == 1
end

function MC.DoorOrientHinge( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 16 ) % 2 == 1 and "right" or "left"
end

function MC.DoorOrientPowered( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 32 ) % 2 == 1
end

function MC.DoorModelVariantKey( orient )
	return table.concat( {
		MC.DoorOrientHalf( orient ),
		MC.DoorOrientHinge( orient ),
		MC.DoorOrientOpen( orient ) and "open" or "closed",
	}, "_" )
end

function MC.MakeTrapdoorOrient( facing, half, open, powered )
	return horizontalPartBase( facing )
		+ ( half == "top" and 4 or 0 )
		+ ( open and 8 or 0 )
		+ ( powered and 16 or 0 )
end

function MC.TrapdoorOrientFacing( orient )
	return horizontalPartFacing( orient )
end

function MC.TrapdoorOrientHalf( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 4 ) % 2 == 1 and "top" or "bottom"
end

function MC.TrapdoorOrientOpen( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 8 ) % 2 == 1
end

function MC.TrapdoorOrientPowered( orient )
	return math.floor( ( tonumber( orient ) or 0 ) / 16 ) % 2 == 1
end

function MC.TrapdoorModelVariantKey( orient )
	if MC.TrapdoorOrientOpen( orient ) then return "open" end
	return MC.TrapdoorOrientHalf( orient ) == "top" and "top" or "bottom"
end

function MC.MakeBedOrient( facing, part )
	return horizontalPartBase( facing ) + ( part == "head" and 4 or 0 )
end

function MC.BedOrientFacing( orient )
	return horizontalPartFacing( orient )
end

function MC.BedOrientPart( orient )
	return math.floor( tonumber( orient ) or 0 ) >= 4 and "head" or "foot"
end

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
local DoorOrientAllowed = {}
local DoorOrientOrder = {}
for i = 0, 63 do
	DoorOrientAllowed[i] = true
	DoorOrientOrder[#DoorOrientOrder + 1] = i
end
local TrapdoorOrientAllowed = {}
local TrapdoorOrientOrder = {}
for i = 0, 31 do
	TrapdoorOrientAllowed[i] = true
	TrapdoorOrientOrder[#TrapdoorOrientOrder + 1] = i
end

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
	door = {
		default = 0,
		allowed = DoorOrientAllowed,
		order = DoorOrientOrder,
	},
	trapdoor = {
		default = 0,
		allowed = TrapdoorOrientAllowed,
		order = TrapdoorOrientOrder,
	},
	bed = {
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

-- the generator collapses all-conditional multiparts (huge mushroom blocks) to
-- their first face plane: a 1/32 sliver model. Vanilla's default state has every
-- face enabled -- a plain opaque full cube -- so rebuild them as full blocks.
for _, fixName in ipairs( { "brown_mushroom_block", "red_mushroom_block", "mushroom_stem" } ) do
	local b = MC.BlockAliases[fixName]
	if b and b.shape == "model" then
		MC.RegisterBlock( {
			id = b.id, name = b.name, mcid = b.mcid,
			solid = true, transparent = false,
			textures = { top = b.top, side = b.side, bottom = b.bottom, icon = b.icon },
		} )
	end
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

if MC.RegisterPendingCustomBlocks then MC.RegisterPendingCustomBlocks() end
rebuildBlockList()
if MC.RefreshBlockDisplayNames then MC.RefreshBlockDisplayNames() end

-- These generated maps are staging indexes used only while the initial block
-- records above are normalized. Every value needed at runtime now lives on a
-- registered block. Keeping the staging maps would retain thousands of
-- duplicate string keys and property tables for the entire session.
MC.GeneratedBlockProperties = nil
MC.GeneratedBlockLight = nil
MC.GeneratedBlockCollision = nil
MC.GeneratedBlockModelVariants = nil
MC.GeneratedBlockConnections = nil
MC.GeneratedBlockNames = nil
MC.GeneratedBlockSoundTypes = nil
MC.GeneratedNoTerrainParticles = nil
MC.GeneratedBlockRegistrationTablesReleased = true

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
	if b.orient == "door" then
		orient = MC.NormalizeOrient( id, orient )
		return "facing=" .. ( DirectionName[MC.DoorOrientFacing( orient )] or "north" ) ..
			",half=" .. MC.DoorOrientHalf( orient ) ..
			",hinge=" .. MC.DoorOrientHinge( orient ) ..
			",open=" .. tostring( MC.DoorOrientOpen( orient ) ) ..
			",powered=" .. tostring( MC.DoorOrientPowered( orient ) )
	end
	if b.orient == "trapdoor" then
		orient = MC.NormalizeOrient( id, orient )
		return "facing=" .. ( DirectionName[MC.TrapdoorOrientFacing( orient )] or "north" ) ..
			",half=" .. MC.TrapdoorOrientHalf( orient ) ..
			",open=" .. tostring( MC.TrapdoorOrientOpen( orient ) ) ..
			",powered=" .. tostring( MC.TrapdoorOrientPowered( orient ) )
	end
	if b.orient == "bed" then
		orient = MC.NormalizeOrient( id, orient )
		return ( DirectionName[MC.BedOrientFacing( orient )] or "north" ) .. "," .. MC.BedOrientPart( orient )
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
	if b.orient == "door" then
		orient = MC.NormalizeOrient( id, orient )
		local facing = DirectionName[MC.DoorOrientFacing( orient )] or "north"
		return "facing=" .. facing .. ",half=" .. MC.DoorOrientHalf( orient ) ..
			",hinge=" .. MC.DoorOrientHinge( orient ) ..
			",open=" .. tostring( MC.DoorOrientOpen( orient ) ) ..
			",powered=" .. tostring( MC.DoorOrientPowered( orient ) )
	end
	if b.orient == "trapdoor" then
		orient = MC.NormalizeOrient( id, orient )
		local facing = DirectionName[MC.TrapdoorOrientFacing( orient )] or "north"
		return "facing=" .. facing .. ",half=" .. MC.TrapdoorOrientHalf( orient ) ..
			",open=" .. tostring( MC.TrapdoorOrientOpen( orient ) ) ..
			",powered=" .. tostring( MC.TrapdoorOrientPowered( orient ) )
	end
	if b.orient == "bed" then
		orient = MC.NormalizeOrient( id, orient )
		local facing = DirectionName[MC.BedOrientFacing( orient )] or "north"
		return "facing=" .. facing .. ",part=" .. MC.BedOrientPart( orient )
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
	if b.orient == "door" then return "facing=north/south/west/east,half=lower/upper,hinge=left/right,open=true/false,powered=true/false" end
	if b.orient == "trapdoor" then return "facing=north/south/west/east,half=top/bottom,open=true/false,powered=true/false" end
	if b.orient == "bed" then return "facing=north/south/west/east,part=foot/head" end
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

local function stateBool( value, default )
	if value == nil then return default end
	value = string.lower( tostring( value ) )
	if value == "true" or value == "open" or value == "opened" then return true end
	if value == "false" or value == "closed" then return false end
	return default
end

local function stateBoolValid( value )
	if value == nil then return true end
	value = string.lower( tostring( value ) )
	return value == "true" or value == "false" or value == "open" or value == "opened" or value == "closed"
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
	if b.orient == "door" then
		local facing = map and DirectionValue[map.facing] or DirectionValue[trim( state )]
		if not HorizontalPartBaseByFacing[facing] then facing = nil end
		local half = map and map.half or "lower"
		if half ~= "upper" then half = "lower" end
		local hinge = map and map.hinge or "left"
		if hinge ~= "right" then hinge = "left" end
		local open = map and stateBool( map.opened or map.open, false ) or false
		local powered = map and stateBool( map.powered, false ) or false
		return facing and MC.MakeDoorOrient( facing, half, open, hinge, powered ) or MC.DefaultOrient( id )
	end
	if b.orient == "trapdoor" then
		local facing = map and DirectionValue[map.facing] or DirectionValue[trim( state )]
		if not HorizontalPartBaseByFacing[facing] then facing = nil end
		local half = map and map.half or "bottom"
		if half ~= "top" then half = "bottom" end
		local open = map and stateBool( map.opened or map.open, false ) or false
		local powered = map and stateBool( map.powered, false ) or false
		return facing and MC.MakeTrapdoorOrient( facing, half, open, powered ) or MC.DefaultOrient( id )
	end
	if b.orient == "bed" then
		local facing = map and DirectionValue[map.facing] or DirectionValue[trim( state )]
		if not HorizontalPartBaseByFacing[facing] then facing = nil end
		local part = map and map.part or "foot"
		if part ~= "head" then part = "foot" end
		return facing and MC.MakeBedOrient( facing, part ) or MC.DefaultOrient( id )
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
	if b.orient == "door" then
		if map then
			local facing = DirectionValue[map.facing]
			local half = map.half or "lower"
			local open = map.opened or map.open
			local hinge = map.hinge or "left"
			local powered = map.powered
			return HorizontalPartBaseByFacing[facing] ~= nil
				and ( half == "lower" or half == "upper" )
				and ( hinge == "left" or hinge == "right" )
				and stateBoolValid( open )
				and stateBoolValid( powered )
		end
		return HorizontalPartBaseByFacing[DirectionValue[trim( string.lower( tostring( state ) ) )]] ~= nil
	end
	if b.orient == "trapdoor" then
		if map then
			local facing = DirectionValue[map.facing]
			local half = map.half or "bottom"
			local open = map.opened or map.open
			local powered = map.powered
			return HorizontalPartBaseByFacing[facing] ~= nil
				and ( half == "bottom" or half == "top" )
				and stateBoolValid( open )
				and stateBoolValid( powered )
		end
		return HorizontalPartBaseByFacing[DirectionValue[trim( string.lower( tostring( state ) ) )]] ~= nil
	end
	if b.orient == "bed" then
		if map then
			local facing = DirectionValue[map.facing]
			local part = map.part or "foot"
			return HorizontalPartBaseByFacing[facing] ~= nil and ( part == "foot" or part == "head" )
		end
		return HorizontalPartBaseByFacing[DirectionValue[trim( string.lower( tostring( state ) ) )]] ~= nil
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

local function doorSideDirections( facing )
	if facing == MC.Direction.NORTH then return MC.Direction.WEST, MC.Direction.EAST end
	if facing == MC.Direction.SOUTH then return MC.Direction.EAST, MC.Direction.WEST end
	if facing == MC.Direction.WEST then return MC.Direction.SOUTH, MC.Direction.NORTH end
	return MC.Direction.NORTH, MC.Direction.SOUTH
end

local function doorNeighbourSolid( bx, by, bz )
	local id = MC.GetBlock and MC.GetBlock( bx, by, bz ) or 0
	if id == 0 then return false end
	if MC.BlockIsFullCube then return MC.BlockIsFullCube( id, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0 ) == true end
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.solid == true and not b.shape and not b.connection or false
end

local function doorNeighbourIsLowerDoor( bx, by, bz )
	local id = MC.GetBlock and MC.GetBlock( bx, by, bz ) or 0
	if id == 0 then return false end
	local b = MC.Blocks and MC.Blocks[id]
	if not b or b.orient ~= "door" then return false end
	return MC.DoorOrientHalf( MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0 ) == "lower"
end

local function localDoorClickXZ( tr, bx, by )
	if not tr or not tr.HitPos or not MC.BS then return 0.5, 0.5 end
	local wx = tr.HitPos.x / MC.BS
	local wy = tr.HitPos.y / MC.BS
	return wx - ( tonumber( bx ) or math.floor( wx ) ), wy - ( tonumber( by ) or math.floor( wy ) )
end

local function doorHingeFromPlacement( tr, bx, by, bz, facing )
	local leftDir, rightDir = doorSideDirections( facing )
	local ldx, ldy = 0, 0
	local rdx, rdy = 0, 0
	if MC.HorizontalDirectionOffset then
		ldx, ldy = MC.HorizontalDirectionOffset( leftDir )
		rdx, rdy = MC.HorizontalDirectionOffset( rightDir )
	end
	local leftSolid = doorNeighbourSolid( bx + ldx, by + ldy, bz ) and 1 or 0
	leftSolid = leftSolid + ( doorNeighbourSolid( bx + ldx, by + ldy, bz + 1 ) and 1 or 0 )
	local rightSolid = doorNeighbourSolid( bx + rdx, by + rdy, bz ) and 1 or 0
	rightSolid = rightSolid + ( doorNeighbourSolid( bx + rdx, by + rdy, bz + 1 ) and 1 or 0 )
	local solidBlockBalance = -leftSolid + rightSolid
	local doorLeft = doorNeighbourIsLowerDoor( bx + ldx, by + ldy, bz )
	local doorRight = doorNeighbourIsLowerDoor( bx + rdx, by + rdy, bz )

	if ( doorLeft and not doorRight ) or solidBlockBalance > 0 then return "right" end
	if ( doorRight and not doorLeft ) or solidBlockBalance < 0 then return "left" end

	local clickX, clickY = localDoorClickXZ( tr, bx, by )
	if facing == MC.Direction.NORTH then return clickX > 0.5 and "right" or "left" end
	if facing == MC.Direction.SOUTH then return clickX < 0.5 and "right" or "left" end
	if facing == MC.Direction.WEST then return clickY < 0.5 and "right" or "left" end
	return clickY > 0.5 and "right" or "left"
end

local function directionFromHitNormal( n )
	if not n then return MC.Direction.UP end
	if n.z > 0.5 then return MC.Direction.UP end
	if n.z < -0.5 then return MC.Direction.DOWN end
	if math.abs( n.x ) > math.abs( n.y ) then return n.x >= 0 and MC.Direction.EAST or MC.Direction.WEST end
	return n.y >= 0 and MC.Direction.SOUTH or MC.Direction.NORTH
end

local function isHorizontalDirection( dir )
	return dir == MC.Direction.NORTH
		or dir == MC.Direction.SOUTH
		or dir == MC.Direction.WEST
		or dir == MC.Direction.EAST
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
		local facing = horizontalLookDirectionFromForward( forward )
		if b.place == "look" then return facing end
		return oppositeDirection( facing )
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
	if b and b.orient == "door" then
		local facing = horizontalLookDirectionFromForward( forward )
		local hinge = doorHingeFromPlacement( tr, tr and tr.MCBlockX or 0, tr and tr.MCBlockY or 0, tr and tr.MCBlockZ or 0, facing )
		return MC.MakeDoorOrient( facing, "lower", false, hinge, false )
	end
	if b and b.orient == "trapdoor" then
		local clickedFace = directionFromHitNormal( tr and tr.HitNormal or nil )
		if isHorizontalDirection( clickedFace ) then
			return MC.MakeTrapdoorOrient( clickedFace, placementHalfFromTrace( tr ), false, false )
		end
		local facing = oppositeDirection( horizontalLookDirectionFromForward( forward ) )
		local half = clickedFace == MC.Direction.UP and "bottom" or "top"
		return MC.MakeTrapdoorOrient( facing, half, false, false )
	end
	if b and b.orient == "bed" then
		return MC.MakeBedOrient( horizontalLookDirectionFromForward( forward ), "foot" )
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
	if b.connection == "bars" then return b.particle or b.side end
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
local CrossBlockBoxes

local function clamp01( v )
	return math.max( 0, math.min( 1, v ) )
end

local function addCrossTraceBox( boxes, x0, y0, x1, y1, width )
	boxes[#boxes + 1] = {
		clamp01( math.min( x0, x1 ) - width ),
		clamp01( math.min( y0, y1 ) - width ),
		0,
		clamp01( math.max( x0, x1 ) + width ),
		clamp01( math.max( y0, y1 ) + width ),
		1,
	}
end

local function buildCrossBlockBoxes()
	local boxes = {}
	local a, c = 0.08, 0.92
	local step = ( c - a ) / 4
	local width = 0.035
	for i = 0, 3 do
		local x0 = a + i * step
		local x1 = a + ( i + 1 ) * step
		addCrossTraceBox( boxes, x0, x0, x1, x1, width )
		addCrossTraceBox( boxes, x0, 1 - x0, x1, 1 - x1, width )
	end
	return boxes
end

CrossBlockBoxes = buildCrossBlockBoxes()

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

function MC.BlockModelData( blockOrId, orient )
	local b = type( blockOrId ) == "table" and blockOrId or MC.Blocks[blockOrId]
	if not b then return nil end
	if b.modelVariants then
		if b.orient == "door" then
			local key = MC.DoorModelVariantKey( orient )
			if b.modelVariants[key] then return b.modelVariants[key] end
			if MC.DoorOrientHalf( orient ) == "upper" then return b.modelVariants.upper or b end
			return b
		end
		if b.orient == "trapdoor" then
			local key = MC.TrapdoorModelVariantKey( orient )
			if key == "open" and b.modelVariants.open then return b.modelVariants.open end
			if key == "top" and b.modelVariants.top then return b.modelVariants.top end
			if key == "bottom" and b.modelVariants.bottom then return b.modelVariants.bottom end
			if b.modelVariants[key] then return b.modelVariants[key] end
			if MC.TrapdoorOrientHalf( orient ) == "top" then return b.modelVariants.top or b end
			return b.modelVariants.bottom or b
		end
		if b.orient == "bed" and MC.BedOrientPart( orient ) == "head" then
			return b.modelVariants.head or b
		end
		if b.orient == "facing" then
			-- hopper-style blocks bake a dedicated down/up model because the
			-- vertical vanilla model is not a rotation of the horizontal one
			orient = MC.NormalizeOrient( b.id, orient )
			if orient == MC.Direction.DOWN and b.modelVariants.down then return b.modelVariants.down end
			if orient == MC.Direction.UP and b.modelVariants.up then return b.modelVariants.up end
			return b
		end
	end
	return b
end

function MC.BlockHorizontalFacingForOrient( blockOrId, orient )
	local b = type( blockOrId ) == "table" and blockOrId or MC.Blocks[blockOrId]
	if not b then return MC.Direction.NORTH end
	orient = MC.NormalizeOrient( b.id, orient )
	if b.orient == "door" then return MC.DoorOrientFacing( orient ) end
	if b.orient == "trapdoor" then return MC.TrapdoorOrientFacing( orient ) end
	if b.orient == "bed" then return MC.BedOrientFacing( orient ) end
	return orient
end

local function modelBoxes( b, orient )
	local data = MC.BlockModelData( b, orient )
	if not data or not data.boxes then return nil end
	local xSteps, zSteps = 0, 0
	if b.orient == "axis" then
		xSteps, zSteps = pillarRotForAxis( MC.NormalizeOrient( b.id, orient ) )
	elseif b.orient == "horizontal_facing" or b.orient == "facing" or b.orient == "door" or b.orient == "trapdoor" or b.orient == "bed" then
		orient = MC.NormalizeOrient( b.id, orient )
		if b.orient == "facing" and orient == MC.Direction.DOWN then
			-- a baked down/up variant is already vertical; only rotate when we
			-- have to reuse the horizontal model
			xSteps = ( b.modelVariants and b.modelVariants.down ) and 0 or 1
		elseif b.orient == "facing" and orient == MC.Direction.UP then
			xSteps = ( b.modelVariants and b.modelVariants.up ) and 0 or 3
		else
			zSteps = horizontalOrientSteps( MC.BlockHorizontalFacingForOrient( b, orient ) )
		end
	end
	if xSteps == 0 and zSteps == 0 then return data.boxes end
	data._rotatedBoxes = data._rotatedBoxes or {}
	local cacheKey = xSteps * 4 + zSteps
	if data._rotatedBoxes[cacheKey] then return data._rotatedBoxes[cacheKey] end
	local out = {}
	for i, box in ipairs( data.boxes ) do
		out[i] = rotateBoxZ( rotateBoxX( box, xSteps ), zSteps )
	end
	data._rotatedBoxes[cacheKey] = out
	return out
end

local function modelConvexRotationSteps( b, orient )
	local xSteps, zSteps = 0, 0
	if b.orient == "axis" then
		xSteps, zSteps = pillarRotForAxis( MC.NormalizeOrient( b.id, orient ) )
	elseif b.orient == "horizontal_facing" or b.orient == "facing" or b.orient == "door" or b.orient == "trapdoor" or b.orient == "bed" then
		orient = MC.NormalizeOrient( b.id, orient )
		if b.orient == "facing" and orient == MC.Direction.DOWN then
			xSteps = 1
		elseif b.orient == "facing" and orient == MC.Direction.UP then
			xSteps = 3
		else
			zSteps = horizontalOrientSteps( MC.BlockHorizontalFacingForOrient( b, orient ) )
		end
	end
	return xSteps, zSteps
end

local function rotateConvexPointX( p, steps )
	if steps == 0 then return p end
	local y, z = rotateXY( p[2], p[3], steps )
	return { p[1], y, z }
end

local function rotateConvexPointZ( p, steps )
	if steps == 0 then return p end
	local x, y = rotateXY( p[1], p[2], steps )
	return { x, y, p[3] }
end

function MC.BlockCollisionConvexes( id, orient, bx, by, bz )
	local b = MC.Blocks[id]
	if not b or not b.collisionConvexes then return nil end
	local xSteps, zSteps = modelConvexRotationSteps( b, orient )
	if xSteps == 0 and zSteps == 0 then return b.collisionConvexes end
	b._rotatedCollisionConvexes = b._rotatedCollisionConvexes or {}
	local cacheKey = xSteps * 4 + zSteps
	if b._rotatedCollisionConvexes[cacheKey] then return b._rotatedCollisionConvexes[cacheKey] end

	local out = {}
	for ci, convex in ipairs( b.collisionConvexes ) do
		local points = {}
		for pi, p in ipairs( convex ) do
			points[pi] = rotateConvexPointZ( rotateConvexPointX( p, xSteps ), zSteps )
		end
		out[ci] = points
	end
	b._rotatedCollisionConvexes[cacheKey] = out
	return out
end

local function isPaneKind( kind )
	return kind == "pane" or kind == "bars"
end

function MC.IsFenceBlock( id )
	local b = MC.Blocks[id]
	return b and b.connection == "fence" or false
end

function MC.IsPaneBlock( id )
	local b = MC.Blocks[id]
	return b and isPaneKind( b.connection ) or false
end

function MC.IsWallBlock( id )
	local b = MC.Blocks[id]
	return b and b.connection == "wall" or false
end

function MC.BlockCollisionDependsOnNeighbours( id )
	local b = MC.Blocks[id]
	if not b then return false end
	return b.connection == "fence"
		or isPaneKind( b.connection )
		or b.connection == "wall"
		or b.connection == "pipe6"
		or ( MC.NeighbourDependentShapes and MC.NeighbourDependentShapes[b.shape] == true )
end

function MC.BlockLightEmission( id )
	id = math.floor( tonumber( id ) or 0 )
	if id == 0 then return 0 end
	local b = MC.Blocks[id]
	return b and math.Clamp( math.floor( tonumber( b.lightEmission ) or 0 ), 0, 15 ) or 0
end

function MC.BlockLightOpacity( id, orient )
	id = math.floor( tonumber( id ) or 0 )
	if id == 0 then return 0 end
	local b = MC.Blocks[id]
	if not b then return 15 end
	local name = b.name or ""
	if name == "tinted_glass" then return 15 end
	if name == "water" then return 3 end
	if name == "lava" then return 15 end
	if string.find( name, "leaves", 1, true ) then return 1 end
	if b.transparent == true or b.solid == false then return 0 end
	if MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) then return 15 end
	return 0
end

function MC.BlockAllowsLight( id, orient )
	return MC.BlockLightOpacity( id, orient ) < 15
end

-- vanilla translucent render layer: real alpha blending instead of alpha cutout.
-- exact names only ("ice" must not catch packed_ice/blue_ice, which are opaque).
local TranslucentNames = {
	tinted_glass = true,
	ice = true,
	frosted_ice = true,
	slime_block = true,
	honey_block = true,
	water = true,
	lava = true,
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
	if b.connection == "fence" or b.connection == "fence_gate" or b.connection == "wall" or isPaneKind( b.connection ) then return true end
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

-- Collision wants continuous strips, not every visual rail. This keeps dense
-- fence builds from generating thousands of multiconvex pieces per chunk.
local function fenceCollisionBoxes( bx, by, bz )
	if bx == nil or by == nil or bz == nil then
		return { { 0.375, 0.375, 0, 0.625, 0.625, 1 } }
	end

	local yn = fenceConnectsToCell( bx, by - 1, bz )
	local yp = fenceConnectsToCell( bx, by + 1, bz )
	local xn = fenceConnectsToCell( bx - 1, by, bz )
	local xp = fenceConnectsToCell( bx + 1, by, bz )
	local boxes = {}

	if yn or yp then
		boxes[#boxes + 1] = { 0.375, yn and 0 or 0.375, 0, 0.625, yp and 1 or 0.625, 1 }
	end
	if xn or xp then
		boxes[#boxes + 1] = { xn and 0 or 0.375, 0.375, 0, xp and 1 or 0.625, 0.625, 1 }
	end
	if #boxes == 0 then
		boxes[1] = { 0.375, 0.375, 0, 0.625, 0.625, 1 }
	end

	return boxes
end

local function paneConnectsToBlock( id, orient )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return false end
	if isPaneKind( b.connection ) or b.connection == "fence" or b.connection == "fence_gate" or b.connection == "wall" then return true end
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

local function wallConnectsToBlock( id, orient )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return false end
	if b.connection == "wall" or b.connection == "fence" or b.connection == "fence_gate" or isPaneKind( b.connection ) then return true end
	if b.solid == false then return false end
	return MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) or not b.shape
end

local function wallConnectsToCell( bx, by, bz )
	if bx == nil or not MC.GetBlock then return false end
	local id = MC.GetBlock( bx, by, bz )
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return wallConnectsToBlock( id, orient )
end

local function wallBoxes( bx, by, bz )
	local boxes = {
		{ 0.25, 0.25, 0, 0.75, 0.75, 1, part = "post" },
	}

	if bx == nil or by == nil or bz == nil then return boxes end

	if wallConnectsToCell( bx, by - 1, bz ) then
		boxes[#boxes + 1] = { 0.3125, 0, 0, 0.6875, 0.5, 0.875, part = "arm", dir = "yn" }
	end
	if wallConnectsToCell( bx, by + 1, bz ) then
		boxes[#boxes + 1] = { 0.3125, 0.5, 0, 0.6875, 1, 0.875, part = "arm", dir = "yp" }
	end
	if wallConnectsToCell( bx - 1, by, bz ) then
		boxes[#boxes + 1] = { 0, 0.3125, 0, 0.5, 0.6875, 0.875, part = "arm", dir = "xn" }
	end
	if wallConnectsToCell( bx + 1, by, bz ) then
		boxes[#boxes + 1] = { 0.5, 0.3125, 0, 1, 0.6875, 0.875, part = "arm", dir = "xp" }
	end

	return boxes
end

local function wallCollisionBoxes( bx, by, bz )
	if bx == nil or by == nil or bz == nil then
		return { { 0.25, 0.25, 0, 0.75, 0.75, 1 } }
	end

	local yn = wallConnectsToCell( bx, by - 1, bz )
	local yp = wallConnectsToCell( bx, by + 1, bz )
	local xn = wallConnectsToCell( bx - 1, by, bz )
	local xp = wallConnectsToCell( bx + 1, by, bz )
	local boxes = {
		{ 0.25, 0.25, 0, 0.75, 0.75, 1 },
	}

	if yn or yp then
		boxes[#boxes + 1] = { 0.3125, yn and 0 or 0.25, 0, 0.6875, yp and 1 or 0.75, 0.875 }
	end
	if xn or xp then
		boxes[#boxes + 1] = { xn and 0 or 0.25, 0.3125, 0, xp and 1 or 0.75, 0.6875, 0.875 }
	end

	return boxes
end

local function pipe6ConnectsToBlock( id, dir )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return false end
	if b.connection == "pipe6" or b.name == "chorus_flower" then return true end
	return dir == MC.Direction.DOWN and b.name == "end_stone"
end

local function pipe6ConnectsToCell( bx, by, bz, dir )
	if bx == nil or not MC.GetBlock then return false end
	return pipe6ConnectsToBlock( MC.GetBlock( bx, by, bz ), dir )
end

local function pipe6Boxes( bx, by, bz )
	local boxes = {
		{ 0.25, 0.25, 0.25, 0.75, 0.75, 0.75, part = "core" },
	}

	if bx == nil or by == nil or bz == nil then return boxes end

	if pipe6ConnectsToCell( bx, by - 1, bz, MC.Direction.NORTH ) then
		boxes[#boxes + 1] = { 0.25, 0, 0.25, 0.75, 0.25, 0.75, part = "arm", dir = "yn" }
	end
	if pipe6ConnectsToCell( bx, by + 1, bz, MC.Direction.SOUTH ) then
		boxes[#boxes + 1] = { 0.25, 0.75, 0.25, 0.75, 1, 0.75, part = "arm", dir = "yp" }
	end
	if pipe6ConnectsToCell( bx - 1, by, bz, MC.Direction.WEST ) then
		boxes[#boxes + 1] = { 0, 0.25, 0.25, 0.25, 0.75, 0.75, part = "arm", dir = "xn" }
	end
	if pipe6ConnectsToCell( bx + 1, by, bz, MC.Direction.EAST ) then
		boxes[#boxes + 1] = { 0.75, 0.25, 0.25, 1, 0.75, 0.75, part = "arm", dir = "xp" }
	end
	if pipe6ConnectsToCell( bx, by, bz - 1, MC.Direction.DOWN ) then
		boxes[#boxes + 1] = { 0.25, 0.25, 0, 0.75, 0.75, 0.25, part = "arm", dir = "zn" }
	end
	if pipe6ConnectsToCell( bx, by, bz + 1, MC.Direction.UP ) then
		boxes[#boxes + 1] = { 0.25, 0.25, 0.75, 0.75, 0.75, 1, part = "arm", dir = "zp" }
	end

	return boxes
end

local CONNECTION_YN, CONNECTION_YP = 1, 2
local CONNECTION_XN, CONNECTION_XP = 4, 8
local CONNECTION_ZN, CONNECTION_ZP = 16, 32

MC.ConnectionMaskBits = MC.ConnectionMaskBits or {
	yn = CONNECTION_YN,
	yp = CONNECTION_YP,
	xn = CONNECTION_XN,
	xp = CONNECTION_XP,
	zn = CONNECTION_ZN,
	zp = CONNECTION_ZP,
}

local function maskHas( mask, flag )
	return math.floor( ( tonumber( mask ) or 0 ) / flag ) % 2 == 1
end

local ConnectionMaskCache = {
	fence = {},
	pane = {},
	wall = {},
	pipe6 = {},
}

local function normalizeConnectionKind( kind )
	if kind == "bars" then return "pane" end
	return kind
end

local function computeBlockConnectionMask( kind, bx, by, bz )
	if bx == nil or by == nil or bz == nil then return 0 end
	local mask = 0
	if kind == "fence" then
		if fenceConnectsToCell( bx, by - 1, bz ) then mask = mask + CONNECTION_YN end
		if fenceConnectsToCell( bx, by + 1, bz ) then mask = mask + CONNECTION_YP end
		if fenceConnectsToCell( bx - 1, by, bz ) then mask = mask + CONNECTION_XN end
		if fenceConnectsToCell( bx + 1, by, bz ) then mask = mask + CONNECTION_XP end
	elseif kind == "pane" or kind == "bars" then
		if paneConnectsToCell( bx, by - 1, bz ) then mask = mask + CONNECTION_YN end
		if paneConnectsToCell( bx, by + 1, bz ) then mask = mask + CONNECTION_YP end
		if paneConnectsToCell( bx - 1, by, bz ) then mask = mask + CONNECTION_XN end
		if paneConnectsToCell( bx + 1, by, bz ) then mask = mask + CONNECTION_XP end
	elseif kind == "wall" then
		if wallConnectsToCell( bx, by - 1, bz ) then mask = mask + CONNECTION_YN end
		if wallConnectsToCell( bx, by + 1, bz ) then mask = mask + CONNECTION_YP end
		if wallConnectsToCell( bx - 1, by, bz ) then mask = mask + CONNECTION_XN end
		if wallConnectsToCell( bx + 1, by, bz ) then mask = mask + CONNECTION_XP end
	elseif kind == "pipe6" then
		if pipe6ConnectsToCell( bx, by - 1, bz, MC.Direction.NORTH ) then mask = mask + CONNECTION_YN end
		if pipe6ConnectsToCell( bx, by + 1, bz, MC.Direction.SOUTH ) then mask = mask + CONNECTION_YP end
		if pipe6ConnectsToCell( bx - 1, by, bz, MC.Direction.WEST ) then mask = mask + CONNECTION_XN end
		if pipe6ConnectsToCell( bx + 1, by, bz, MC.Direction.EAST ) then mask = mask + CONNECTION_XP end
		if pipe6ConnectsToCell( bx, by, bz - 1, MC.Direction.DOWN ) then mask = mask + CONNECTION_ZN end
		if pipe6ConnectsToCell( bx, by, bz + 1, MC.Direction.UP ) then mask = mask + CONNECTION_ZP end
	end
	return mask
end

function MC.BlockConnectionMask( kind, bx, by, bz )
	kind = normalizeConnectionKind( kind )
	if bx == nil or by == nil or bz == nil then return 0 end
	local bucket = ConnectionMaskCache[kind]
	if not bucket then return computeBlockConnectionMask( kind, bx, by, bz ) end
	local xBucket = bucket[bx]
	if not xBucket then
		xBucket = {}
		bucket[bx] = xBucket
	end
	local yBucket = xBucket[by]
	if not yBucket then
		yBucket = {}
		xBucket[by] = yBucket
	end
	local cached = yBucket[bz]
	if cached ~= nil then return cached end
	cached = computeBlockConnectionMask( kind, bx, by, bz )
	yBucket[bz] = cached
	return cached
end

function MC.ClearBlockConnectionMaskCache( bx, by, bz )
	if bx == nil or by == nil or bz == nil then return end
	for _, bucket in pairs( ConnectionMaskCache ) do
		local xBucket = bucket[bx]
		local yBucket = xBucket and xBucket[by]
		if yBucket then yBucket[bz] = nil end
	end
end

local ConnectionBoxesCache = {
	fence = {},
	pane = {},
	wall = {},
	pipe6 = {},
}

local function buildFenceBoxesForMask( mask )
	local boxes = {
		{ 0.375, 0.375, 0, 0.625, 0.625, 1, part = "post" },
	}
	if maskHas( mask, CONNECTION_YN ) then
		boxes[#boxes + 1] = { 0.4375, 0, 0.375, 0.5625, 0.5625, 0.5625, part = "arm", dir = "yn" }
		boxes[#boxes + 1] = { 0.4375, 0, 0.75, 0.5625, 0.5625, 0.9375, part = "arm", dir = "yn" }
	end
	if maskHas( mask, CONNECTION_YP ) then
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.375, 0.5625, 1, 0.5625, part = "arm", dir = "yp" }
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.75, 0.5625, 1, 0.9375, part = "arm", dir = "yp" }
	end
	if maskHas( mask, CONNECTION_XN ) then
		boxes[#boxes + 1] = { 0, 0.4375, 0.375, 0.5625, 0.5625, 0.5625, part = "arm", dir = "xn" }
		boxes[#boxes + 1] = { 0, 0.4375, 0.75, 0.5625, 0.5625, 0.9375, part = "arm", dir = "xn" }
	end
	if maskHas( mask, CONNECTION_XP ) then
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.375, 1, 0.5625, 0.5625, part = "arm", dir = "xp" }
		boxes[#boxes + 1] = { 0.4375, 0.4375, 0.75, 1, 0.5625, 0.9375, part = "arm", dir = "xp" }
	end
	return boxes
end

local function buildPaneBoxesForMask( mask )
	local boxes = {
		{ 0.4375, 0.4375, 0, 0.5625, 0.5625, 1, part = "post" },
	}
	if maskHas( mask, CONNECTION_YN ) then boxes[#boxes + 1] = { 0.4375, 0, 0, 0.5625, 0.4375, 1, part = "arm", dir = "yn" } end
	if maskHas( mask, CONNECTION_YP ) then boxes[#boxes + 1] = { 0.4375, 0.5625, 0, 0.5625, 1, 1, part = "arm", dir = "yp" } end
	if maskHas( mask, CONNECTION_XN ) then boxes[#boxes + 1] = { 0, 0.4375, 0, 0.4375, 0.5625, 1, part = "arm", dir = "xn" } end
	if maskHas( mask, CONNECTION_XP ) then boxes[#boxes + 1] = { 0.5625, 0.4375, 0, 1, 0.5625, 1, part = "arm", dir = "xp" } end
	return boxes
end

local function buildWallBoxesForMask( mask )
	local boxes = {
		{ 0.25, 0.25, 0, 0.75, 0.75, 1, part = "post" },
	}
	if maskHas( mask, CONNECTION_YN ) then boxes[#boxes + 1] = { 0.3125, 0, 0, 0.6875, 0.5, 0.875, part = "arm", dir = "yn" } end
	if maskHas( mask, CONNECTION_YP ) then boxes[#boxes + 1] = { 0.3125, 0.5, 0, 0.6875, 1, 0.875, part = "arm", dir = "yp" } end
	if maskHas( mask, CONNECTION_XN ) then boxes[#boxes + 1] = { 0, 0.3125, 0, 0.5, 0.6875, 0.875, part = "arm", dir = "xn" } end
	if maskHas( mask, CONNECTION_XP ) then boxes[#boxes + 1] = { 0.5, 0.3125, 0, 1, 0.6875, 0.875, part = "arm", dir = "xp" } end
	return boxes
end

local function buildPipe6BoxesForMask( mask )
	local boxes = {
		{ 0.25, 0.25, 0.25, 0.75, 0.75, 0.75, part = "core" },
	}
	if maskHas( mask, CONNECTION_YN ) then boxes[#boxes + 1] = { 0.25, 0, 0.25, 0.75, 0.25, 0.75, part = "arm", dir = "yn" } end
	if maskHas( mask, CONNECTION_YP ) then boxes[#boxes + 1] = { 0.25, 0.75, 0.25, 0.75, 1, 0.75, part = "arm", dir = "yp" } end
	if maskHas( mask, CONNECTION_XN ) then boxes[#boxes + 1] = { 0, 0.25, 0.25, 0.25, 0.75, 0.75, part = "arm", dir = "xn" } end
	if maskHas( mask, CONNECTION_XP ) then boxes[#boxes + 1] = { 0.75, 0.25, 0.25, 1, 0.75, 0.75, part = "arm", dir = "xp" } end
	if maskHas( mask, CONNECTION_ZN ) then boxes[#boxes + 1] = { 0.25, 0.25, 0, 0.75, 0.75, 0.25, part = "arm", dir = "zn" } end
	if maskHas( mask, CONNECTION_ZP ) then boxes[#boxes + 1] = { 0.25, 0.25, 0.75, 0.75, 0.75, 1, part = "arm", dir = "zp" } end
	return boxes
end

function MC.ConnectionBlockBoxes( kind, mask )
	kind = normalizeConnectionKind( kind )
	mask = math.floor( tonumber( mask ) or 0 )
	local bucket = ConnectionBoxesCache[kind]
	if not bucket then return nil end
	local cached = bucket[mask]
	if cached then return cached end
	if kind == "fence" then cached = buildFenceBoxesForMask( mask )
	elseif kind == "pane" then cached = buildPaneBoxesForMask( mask )
	elseif kind == "wall" then cached = buildWallBoxesForMask( mask )
	elseif kind == "pipe6" then cached = buildPipe6BoxesForMask( mask ) end
	bucket[mask] = cached
	return cached
end

local ConnectionCollisionBoxesCache = {
	fence = {},
	pane = {},
	wall = {},
}

local function buildFenceCollisionBoxesForMask( mask )
	local yn, yp = maskHas( mask, CONNECTION_YN ), maskHas( mask, CONNECTION_YP )
	local xn, xp = maskHas( mask, CONNECTION_XN ), maskHas( mask, CONNECTION_XP )
	local boxes = {}
	if yn or yp then boxes[#boxes + 1] = { 0.375, yn and 0 or 0.375, 0, 0.625, yp and 1 or 0.625, 1 } end
	if xn or xp then boxes[#boxes + 1] = { xn and 0 or 0.375, 0.375, 0, xp and 1 or 0.625, 0.625, 1 } end
	if #boxes == 0 then boxes[1] = { 0.375, 0.375, 0, 0.625, 0.625, 1 } end
	return boxes
end

local function buildPaneCollisionBoxesForMask( mask )
	local yn, yp = maskHas( mask, CONNECTION_YN ), maskHas( mask, CONNECTION_YP )
	local xn, xp = maskHas( mask, CONNECTION_XN ), maskHas( mask, CONNECTION_XP )
	local boxes = {}
	if yn or yp then boxes[#boxes + 1] = { 0.4375, yn and 0 or 0.4375, 0, 0.5625, yp and 1 or 0.5625, 1 } end
	if xn or xp then boxes[#boxes + 1] = { xn and 0 or 0.4375, 0.4375, 0, xp and 1 or 0.5625, 0.5625, 1 } end
	if #boxes == 0 then boxes[1] = { 0.4375, 0.4375, 0, 0.5625, 0.5625, 1 } end
	return boxes
end

local function buildWallCollisionBoxesForMask( mask )
	local yn, yp = maskHas( mask, CONNECTION_YN ), maskHas( mask, CONNECTION_YP )
	local xn, xp = maskHas( mask, CONNECTION_XN ), maskHas( mask, CONNECTION_XP )
	local boxes = {
		{ 0.25, 0.25, 0, 0.75, 0.75, 1 },
	}
	if yn or yp then boxes[#boxes + 1] = { 0.3125, yn and 0 or 0.25, 0, 0.6875, yp and 1 or 0.75, 0.875 } end
	if xn or xp then boxes[#boxes + 1] = { xn and 0 or 0.25, 0.3125, 0, xp and 1 or 0.75, 0.6875, 0.875 } end
	return boxes
end

function MC.ConnectionBlockCollisionBoxes( kind, mask )
	kind = normalizeConnectionKind( kind )
	mask = math.floor( tonumber( mask ) or 0 )
	local bucket = ConnectionCollisionBoxesCache[kind]
	if not bucket then return nil end
	local cached = bucket[mask]
	if cached then return cached end
	if kind == "fence" then cached = buildFenceCollisionBoxesForMask( mask )
	elseif kind == "pane" then cached = buildPaneCollisionBoxesForMask( mask )
	elseif kind == "wall" then cached = buildWallCollisionBoxesForMask( mask ) end
	bucket[mask] = cached
	return cached
end

local FullBlockCollisionNames = {
	cauldron = true,
	water_cauldron = true,
	lava_cauldron = true,
	powder_snow_cauldron = true,
}

local function fenceGateCollisionBoxes( b, orient )
	local boxes = modelBoxes( b, MC.NormalizeOrient( b.id, orient ) )
	if not boxes or #boxes == 0 then return boxes end

	local x0, y0, z0 = 1, 1, 1
	local x1, y1, z1 = 0, 0, 0
	for _, box in ipairs( boxes ) do
		x0 = math.min( x0, box[1] )
		y0 = math.min( y0, box[2] )
		z0 = math.min( z0, box[3] )
		x1 = math.max( x1, box[4] )
		y1 = math.max( y1, box[5] )
		z1 = math.max( z1, box[6] )
	end

	return { { x0, y0, z0, x1, y1, z1 } }
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
		return MC.StairBoxes( id, orient, bx, by, bz )
	end
	if b.shape == "cross" then
		return CrossBlockBoxes
	end
	if b.connection == "fence" then
		return MC.ConnectionBlockBoxes( "fence", MC.BlockConnectionMask( "fence", bx, by, bz ) )
	end
	if b.connection == "fence_gate" then
		return modelBoxes( b, MC.NormalizeOrient( id, orient ) )
	end
	if b.connection == "wall" then
		return MC.ConnectionBlockBoxes( "wall", MC.BlockConnectionMask( "wall", bx, by, bz ) )
	end
	if isPaneKind( b.connection ) then
		return MC.ConnectionBlockBoxes( "pane", MC.BlockConnectionMask( "pane", bx, by, bz ) )
	end
	if b.connection == "pipe6" then
		return MC.ConnectionBlockBoxes( "pipe6", MC.BlockConnectionMask( "pipe6", bx, by, bz ) )
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
	if MC.IsLadderBlock and MC.IsLadderBlock( id ) then
		return nil
	end
	if b and b.collisionConvexes then
		return nil
	end
	if b and FullBlockCollisionNames[ b.name ] then
		return FullBlockBox
	end
	if b and b.connection == "fence_gate" then
		return fenceGateCollisionBoxes( b, orient )
	end
	if b and b.connection == "fence" and bx ~= nil and by ~= nil and bz ~= nil then
		return MC.ConnectionBlockCollisionBoxes( "fence", MC.BlockConnectionMask( "fence", bx, by, bz ) )
	end
	if b and isPaneKind( b.connection ) and bx ~= nil and by ~= nil and bz ~= nil then
		return MC.ConnectionBlockCollisionBoxes( "pane", MC.BlockConnectionMask( "pane", bx, by, bz ) )
	end
	if b and b.connection == "wall" and bx ~= nil and by ~= nil and bz ~= nil then
		return MC.ConnectionBlockCollisionBoxes( "wall", MC.BlockConnectionMask( "wall", bx, by, bz ) )
	end
	return MC.BlockBoxes( id, orient, bx, by, bz )
end

function MC.BlockHasCollision( id )
	id = math.floor( tonumber( id ) or 0 )
	local b = MC.Blocks[id]
	return b ~= nil and b.solid ~= false
end

function MC.GetBlockCollisionBoxes( id, orient, bx, by, bz )
	id = math.floor( tonumber( id ) or 0 )
	if not MC.BlockHasCollision( id ) then return nil end
	return MC.BlockCollisionBoxes( id, orient, bx, by, bz )
end

local BlockExtentCache = {}

local function boxesExtent( boxes )
	if not boxes or #boxes == 0 then return nil, nil end
	local lo, hi = math.huge, -math.huge
	for _, box in ipairs( boxes ) do
		if box[3] < lo then lo = box[3] end
		if box[6] > hi then hi = box[6] end
	end
	if lo == math.huge or hi == -math.huge then return nil, nil end
	return lo, hi
end

local function convexesExtent( convexes )
	if not convexes or #convexes == 0 then return nil, nil end
	local lo, hi = math.huge, -math.huge
	for _, convex in ipairs( convexes ) do
		for _, point in ipairs( convex ) do
			local z = point[3] or point.z
			if z then
				if z < lo then lo = z end
				if z > hi then hi = z end
			end
		end
	end
	if lo == math.huge or hi == -math.huge then return nil, nil end
	return lo, hi
end

function MC.GetBlockExtent( id, orient, bx, by, bz )
	id = math.floor( tonumber( id ) or 0 )
	if id == 0 or not MC.BlockHasCollision( id ) then return nil, nil end
	orient = MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or math.floor( tonumber( orient ) or 0 )

	local cacheable = bx == nil and by == nil and bz == nil
	local cache = cacheable and BlockExtentCache[id] or nil
	local cached = cache and cache[orient] or nil
	if cached then
		if cached.empty then return nil, nil end
		return cached.lo, cached.hi
	end

	local lo, hi = boxesExtent( MC.GetBlockCollisionBoxes( id, orient, bx, by, bz ) )
	if lo == nil and MC.BlockCollisionConvexes then
		lo, hi = convexesExtent( MC.BlockCollisionConvexes( id, orient, bx, by, bz ) )
	end

	if cacheable then
		if not cache then
			cache = {}
			BlockExtentCache[id] = cache
		end
		cache[orient] = lo == nil and { empty = true } or { lo = lo, hi = hi }
	end
	return lo, hi
end

function MC.GetBlockShapeInfo( id, orient, bx, by, bz )
	id = math.floor( tonumber( id ) or 0 )
	if id == 0 then return nil end
	orient = MC.NormalizeOrient and MC.NormalizeOrient( id, orient ) or math.floor( tonumber( orient ) or 0 )
	local boxes = MC.BlockBoxes( id, orient, bx, by, bz )
	local collisionBoxes = MC.GetBlockCollisionBoxes( id, orient, bx, by, bz )
	local collisionConvexes = ( not collisionBoxes and MC.BlockHasCollision( id ) and MC.BlockCollisionConvexes )
		and MC.BlockCollisionConvexes( id, orient, bx, by, bz ) or nil
	local lo, hi = MC.GetBlockExtent( id, orient, bx, by, bz )
	return {
		id = id,
		orient = orient,
		boxes = boxes,
		collisionBoxes = collisionBoxes,
		collisionConvexes = collisionConvexes,
		extentLo = lo,
		extentHi = hi,
		hasCollision = lo ~= nil,
		fullCube = MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) or false,
	}
end

function MC.BlockIsFullCube( id, orient )
	local b = MC.Blocks[id]
	if not b or b.solid == false then return false end
	if b.collisionConvexes then return false end
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
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local px0 = col * stride + pad
	local py0 = row * stride + pad
	local inset = A.INSET or 0.5
	return ( px0 + inset ) / A.W,
	       ( py0 + inset ) / A.H,
	       ( px0 + A.TILE - inset ) / A.W,
	       ( py0 + A.TILE - inset ) / A.H
end
