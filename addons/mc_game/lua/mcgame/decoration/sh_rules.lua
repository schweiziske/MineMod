-- Source-verified rules shared by the hanging-entity implementations.
--
-- This file deliberately contains no entity or engine internals.  It is also
-- usable by the repository's plain-Lua assertions: geometry is expressed in
-- Minecraft block units and all world queries are injected by the caller.

MC = MC or {}
MC.Decoration = MC.Decoration or {}

local D = MC.Decoration

D.Constants = D.Constants or {
	wallOffset = 0.46875, -- Painting/ItemFrame#calculateBoundingBox
	depth = 0.0625,
	frameWidth = 0.75,
	frameHeight = 0.75,
	mapWidth = 1.0,
	mapHeight = 1.0,
	frameRotations = 8,
	armorStandWobbleTime = 5,
	armorStandMaxHealth = 20,
	armorStandIgniteSeconds = 5,
	armorStandIgniteDamage = 0.15,
	armorStandBurnDamage = 4,
	armorStandWidth = 0.5,
	armorStandHeight = 1.975,
	armorStandEyeHeight = 1.7775,
	armorStandPlaceVolume = 0.75,
	armorStandPlacePitch = 0.8,
	glowFrameMinimumBlockLight = 5,
	armorStandFeetOffset = 0.1,
	armorStandLegsOffset = 0.4,
	armorStandChestOffset = 0.9,
	armorStandHeadOffset = 1.6,
	armorStandSmallScale = 0.5,
	armorStandSmallEyeHeight = 0.9875,
	armorStandDisableTakingOffset = 8,
	armorStandDisablePuttingOffset = 16,
	armorStandFlagSmall = 1,
	armorStandFlagShowArms = 4,
	armorStandFlagNoBasePlate = 8,
	armorStandFlagMarker = 16,
}

local C = D.Constants

-- The switch is intentionally dark by default.  Keeping it here, rather than
-- in an entity file, makes every entry point (hand, proxy, and direct API)
-- obey the same default-off policy.
if CreateConVar then
	local flags = FCVAR_ARCHIVE or 0
	if SERVER and bit and bit.bor then
		flags = bit.bor( flags, FCVAR_REPLICATED or 0, FCVAR_NOTIFY or 0 )
	end
	D.EnableConVar = GetConVar and GetConVar( "mc_gameplay_parity_decorations" )
		or CreateConVar( "mc_gameplay_parity_decorations", "0", flags,
			"Enable source-verified Painting/ArmorStand/ItemFrame parity." )
end

function D.Enabled()
	local cv = D.EnableConVar
	if not cv and GetConVar then cv = GetConVar( "mc_gameplay_parity_decorations" ) end
	return cv and cv.GetBool and cv:GetBool() == true or false
end

D.ItemKinds = D.ItemKinds or {
	["minecraft:painting"] = "painting",
	["minecraft:item_frame"] = "item_frame",
	["minecraft:glow_item_frame"] = "glow_item_frame",
	["minecraft:armor_stand"] = "armor_stand",
}

-- Direction names use the same coordinate convention as the voxel API:
-- x/east, y/south, z/up.  Direction ids follow Direction.java's 3-D data
-- values, which are what HangingEntity packets carry.
D.Directions = D.Directions or {
	DOWN = { name = "down", id = 0, x = 0, y = 0, z = -1, axis = "z", horizontal = false },
	UP = { name = "up", id = 1, x = 0, y = 0, z = 1, axis = "z", horizontal = false },
	NORTH = { name = "north", id = 2, x = 0, y = -1, z = 0, axis = "y", horizontal = true },
	SOUTH = { name = "south", id = 3, x = 0, y = 1, z = 0, axis = "y", horizontal = true },
	WEST = { name = "west", id = 4, x = -1, y = 0, z = 0, axis = "x", horizontal = true },
	EAST = { name = "east", id = 5, x = 1, y = 0, z = 0, axis = "x", horizontal = true },
}

local DIRECTIONS_BY_ID = {}
for _, direction in pairs( D.Directions ) do DIRECTIONS_BY_ID[direction.id] = direction end

function D.Direction( value )
	if type( value ) == "table" and value.name and value.x then return value end
	if type( value ) == "number" then return DIRECTIONS_BY_ID[math.floor( value )] end
	local key = string.upper( tostring( value or "" ) )
	return D.Directions[key]
end

function D.DirectionName( value )
	local direction = D.Direction( value )
	return direction and direction.name or nil
end

function D.DirectionId( value )
	local direction = D.Direction( value )
	return direction and direction.id or nil
end

function D.DirectionFromNormal( normal )
	if normal == nil then return nil end
	local x, y, z = tonumber( normal.x ) or 0, tonumber( normal.y ) or 0, tonumber( normal.z ) or 0
	if math.abs( x ) >= math.abs( y ) and math.abs( x ) >= math.abs( z ) and math.abs( x ) > 0.5 then
		return D.Direction( x > 0 and "east" or "west" )
	end
	if math.abs( y ) >= math.abs( z ) and math.abs( y ) > 0.5 then
		return D.Direction( y > 0 and "south" or "north" )
	end
	if math.abs( z ) > 0.5 then return D.Direction( z > 0 and "up" or "down" ) end
	return nil
end

function D.Opposite( value )
	local direction = D.Direction( value )
	if not direction then return nil end
	local opposites = {
		["north"] = "south", ["south"] = "north",
		["east"] = "west", ["west"] = "east",
		["up"] = "down", ["down"] = "up",
	}
	local opposite = opposites[direction.name]
	return D.Direction( opposite )
end

-- Direction#getCounterClockWise for the horizontal directions, expressed in
-- the Source x/y plane.  This is used for the even-size painting offset.
function D.CounterClockwise( value )
	local direction = D.Direction( value )
	if not direction or not direction.horizontal then return nil end
	local leftByDirection = {
		 north = "west", west = "south", south = "east", east = "north",
	}
	local left = leftByDirection[direction.name]
	return D.Direction( left )
end

local function component( stack, key )
	if type( stack ) ~= "table" or type( stack.components ) ~= "table" then return nil end
	local value = stack.components[key]
	if value == nil and string.find( key, ":", 1, true ) == nil then
		value = stack.components["minecraft:" .. key]
	end
	return value
end

local function componentIdentifier( value )
	if type( value ) == "string" then return value end
	if type( value ) ~= "table" then return nil end
	return value.id or value.name or value.value or value.asset_id or value.assetId
end

function D.ItemName( stackOrName )
	if type( stackOrName ) == "table" then return tostring( stackOrName.item or stackOrName.name or "" ) end
	return tostring( stackOrName or "" )
end

function D.ItemKind( stackOrName )
	local name = D.ItemName( stackOrName )
	if name ~= "" and not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return D.ItemKinds[name], name
end

function D.IsDecorationItem( stackOrName )
	return D.ItemKind( stackOrName ) ~= nil
end

function D.PaintingVariantFromStack( stack )
	-- DataComponents.PAINTING_VARIANT is registered as
	-- `minecraft:painting/variant` in DataComponents.java.  Accept the old
	-- underscore spelling only as a compatibility read for pre-parity stacks.
	local value = component( stack, "painting/variant" )
	if value == nil then value = component( stack, "painting_variant" ) end
	local id = componentIdentifier( value )
	if not id or id == "" then return nil end
	if not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
	return string.lower( id )
end

function D.HasMap( stack )
	return component( stack, "map_id" ) ~= nil
end

function D.StackHasEnchantment( stack, enchantmentId )
	local wanted = tostring( enchantmentId or "" )
	if wanted == "" then return false end
	if not string.find( wanted, ":", 1, true ) then wanted = "minecraft:" .. wanted end
	local value = component( stack, "enchantments" )
	if type( value ) ~= "table" then return false end
	local levels = type( value.levels ) == "table" and value.levels or value
	for identifier, entry in pairs( levels ) do
		local id, level = identifier, entry
		if type( identifier ) == "number" and type( entry ) == "table" then
			id = entry.id or entry.enchantment or entry.name
			level = entry.level or entry.lvl or entry[2]
		elseif type( entry ) == "table" then
			level = entry.level or entry.lvl or entry[1]
		end
		id = tostring( id or "" )
		if id ~= "" and not string.find( id, ":", 1, true ) then id = "minecraft:" .. id end
		if id == wanted and ( tonumber( level ) or 0 ) > 0 then return true end
	end
	return false
end

-- Dimensions are copied from out/data/minecraft/painting_variant/*.json.  The
-- placeable list below is copied in tag order; earth/fire/water/wind are
-- intentionally absent because the tag excludes them even though their JSON
-- files exist.
D.PaintingVariants = D.PaintingVariants or {
	alban={1,1}, aztec={1,1}, aztec2={1,1}, backyard={3,4}, baroque={2,2},
	bomb={1,1}, bouquet={3,3}, burning_skull={4,4}, bust={2,2}, cavebird={3,3},
	changing={4,2}, cotan={3,3}, courbet={2,1}, creebet={2,1}, dennis={3,3},
	donkey_kong={4,3}, earth={2,2}, endboss={3,3}, fern={3,3}, fighters={4,2},
	finding={4,2}, fire={2,2}, graham={1,2}, humble={2,2}, kebab={1,1},
	lowmist={4,2}, match={2,2}, meditative={1,1}, orb={4,4}, owlemons={3,3},
	passage={4,2}, pigscene={4,4}, plant={1,1}, pointer={4,4}, pond={3,4},
	pool={2,1}, prairie_ride={1,2}, sea={2,1}, skeleton={4,3}, skull_and_roses={2,2},
	stage={2,2}, sunflowers={3,3}, sunset={2,1}, tides={3,3}, unpacked={4,4},
	void={2,2}, wanderer={1,2}, wasteland={1,1}, water={2,2}, wind={2,2}, wither={2,2},
}

D.PaintingPlaceable = D.PaintingPlaceable or {
	"kebab", "aztec", "alban", "aztec2", "bomb", "plant", "wasteland", "pool",
	"courbet", "sea", "sunset", "creebet", "wanderer", "graham", "match", "bust",
	"stage", "void", "skull_and_roses", "wither", "fighters", "pointer", "pigscene",
	"burning_skull", "skeleton", "donkey_kong", "baroque", "humble", "meditative",
	"prairie_ride", "unpacked", "backyard", "bouquet", "cavebird", "changing", "cotan",
	"endboss", "fern", "finding", "lowmist", "orb", "owlemons", "passage", "pond",
	"sunflowers", "tides", "dennis",
}

local function shortVariant( value )
	value = string.lower( tostring( value or "" ) )
	return string.match( value, "^[^:]+:(.+)$" ) or value
end

function D.PaintingVariant( value )
	local key = shortVariant( value )
	local size = D.PaintingVariants[key]
	if not size then return nil end
	return { name = "minecraft:" .. key, key = key, width = size[1], height = size[2], area = size[1] * size[2] }
end

function D.PaintingVariantsForPlaceable()
	local output = {}
	for index, key in ipairs( D.PaintingPlaceable ) do
		local variant = D.PaintingVariant( key )
		if variant then output[index] = variant end
	end
	return output
end

-- Painting#create: filter by survives(), retain only the largest area, then
-- choose uniformly from the retained list.  `randomIndex(count)` is injected
-- so tests can assert candidate order without relying on math.random state.
function D.SelectPaintingVariant( survives, randomIndex )
	if type( survives ) ~= "function" then return nil, "survival_query_missing" end
	local valid, largest = {}, 0
	for _, variant in ipairs( D.PaintingVariantsForPlaceable() ) do
		if survives( variant ) == true then
			if variant.area > largest then largest = variant.area; valid = { variant }
			elseif variant.area == largest then valid[#valid + 1] = variant end
		end
	end
	if #valid == 0 then return nil, "no_surviving_variant" end
	local index = randomIndex and randomIndex( #valid ) or math.random( #valid )
	index = math.max( 1, math.min( #valid, math.floor( tonumber( index ) or 1 ) ) )
	return valid[index], valid
end

function D.PaintingGeometry( width, height, direction )
	local d = D.Direction( direction )
	if not d then return nil, "invalid_direction" end
	local left = D.CounterClockwise( d ) or { x = 0, y = 0, z = 0 }
	local horizontalOffset = width % 2 == 0 and 0.5 or 0
	local verticalOffset = height % 2 == 0 and 0.5 or 0
	-- The game-layer coordinate adapter uses x/east, y/south, z/up.  Build
	-- the AABB from the wall normal and its counter-clockwise lateral basis;
	-- this is the direct coordinate equivalent of Painting.java's axis branch
	-- after Minecraft's Y-up axis is mapped to Source Z-up.
	local sizeX = math.abs( d.x ) * C.depth + math.abs( left.x ) * width
	local sizeY = math.abs( d.y ) * C.depth + math.abs( left.y ) * width
	local sizeZ = math.abs( d.z ) * C.depth + height
	return {
		direction = d.name,
		centerOffset = {
			x = -d.x * C.wallOffset + left.x * horizontalOffset,
			y = -d.y * C.wallOffset + left.y * horizontalOffset,
			z = -d.z * C.wallOffset + verticalOffset,
		},
		size = { x = sizeX, y = sizeY, z = sizeZ },
		width = width, height = height,
	}
end

function D.FrameGeometry( direction, hasMap, ordinaryPopBox )
	local d = D.Direction( direction )
	if not d then return nil, "invalid_direction" end
	local width = hasMap and C.mapWidth or C.frameWidth
	local height = hasMap and C.mapHeight or C.frameHeight
	if ordinaryPopBox then width, height = C.frameWidth, C.frameHeight end
	local left = D.CounterClockwise( d ) or { x = 0, y = 0, z = 0 }
	local sizeX, sizeY, sizeZ
	if d.axis == "z" then
		-- ItemFrame accepts floor/ceiling faces too.  In that case the Java
		-- AABB is width x depth x width; maps use the same value for both axes.
		sizeX, sizeY, sizeZ = width, height, C.depth
	else
		sizeX = math.abs( d.x ) * C.depth + math.abs( left.x ) * width
		sizeY = math.abs( d.y ) * C.depth + math.abs( left.y ) * width
		sizeZ = height
	end
	return {
		direction = d.name,
		centerOffset = { x = -d.x * C.wallOffset, y = -d.y * C.wallOffset, z = -d.z * C.wallOffset },
		size = { x = sizeX, y = sizeY, z = sizeZ },
		width = width, height = height,
	}
end

function D.AnalogOutput( stack, rotation )
	if type( stack ) ~= "table" or ( tonumber( stack.count ) or 0 ) <= 0 then return 0 end
	return math.floor( tonumber( rotation ) or 0 ) % C.frameRotations + 1
end

function D.NormalizeRotation( rotation )
	return math.floor( tonumber( rotation ) or 0 ) % C.frameRotations
end

-- ItemFrame#hurtServer has two observably different paths. A non-fixed frame
-- first applies Entity#isInvulnerableToBase, then removes a contained item for
-- every non-explosion source. Only an empty/exploded frame reaches
-- BlockAttachedEntity#hurtServer, where MOB_GRIEFING is checked.
function D.ItemFrameDamageDecision( context )
	context = type( context ) == "table" and context or {}
	local creative = context.creative == true
	local bypasses = context.bypassesInvulnerability == true
	local baseInvulnerable = context.removed == true
		or context.invulnerable == true and not bypasses and not creative
		or context.fireImmuneHit == true
		or context.fallImmuneHit == true

	if context.fixed == true then
		if not bypasses and not creative then
			return { action = "reject", accepted = false, damageTool = false }
		end
		if baseInvulnerable then
			return { action = "reject", accepted = false, damageTool = false }
		end
	else
		if baseInvulnerable then
			return { action = "reject", accepted = false, damageTool = false }
		end
		if context.hasItem == true and context.explosion ~= true then
			return { action = "remove_item", accepted = true, damageTool = false }
		end
	end

	-- BlockAttachedEntity#hurtServer checks this only after the frame-specific
	-- item-removal branch above.
	if context.mob == true and context.mobGriefing == false then
		return { action = "reject", accepted = false, damageTool = false }
	end
	return { action = "destroy", accepted = true, damageTool = false }
end

-- BlockAttachedEntity#hurtServer is the complete damage path for paintings
-- and the delegated empty/exploded item-frame branch. Entity's base
-- invulnerability check happens before MOB_GRIEFING, and a removed entity is
-- still reported as an accepted hit only when it passed that base check and
-- was removed between the check and the kill branch. The pure adapter receives
-- one snapshot, so `removed` belongs to isInvulnerableToBase and rejects.
function D.BlockAttachedDamageDecision( context )
	context = type( context ) == "table" and context or {}
	local creative = context.creative == true
	local bypasses = context.bypassesInvulnerability == true
	local baseInvulnerable = context.removed == true
		or context.invulnerable == true and not bypasses and not creative
		or context.fireImmuneHit == true
		or context.fallImmuneHit == true
	if baseInvulnerable then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.mob == true and context.mobGriefing == false then
		return { action = "reject", accepted = false, damageTool = false }
	end
	return { action = "destroy", accepted = true, damageTool = false }
end

function D.IsDiode( blockInfo )
	local name = type( blockInfo ) == "table" and ( blockInfo.mcid or blockInfo.name ) or blockInfo
	name = string.lower( tostring( name or "" ) )
	return name == "minecraft:repeater" or name == "minecraft:comparator"

end

-- BlockState#isSolid as implemented by the engine's authoritative shape
-- helper and BlockBehaviour's 0.7291666666666666 threshold.  The caller passes
-- the fresh result of MC.API.World.GetCellShape; no engine table is accessed.
function D.ShapeIsSolid( shape )
	if type( shape ) ~= "table" then return false end
	if shape.fullCube == true then return true end
	local boxes = shape.collisionBoxes or shape.boxes
	local convexes = shape.collisionConvexes or shape.convexes
	if ( type( boxes ) ~= "table" or #boxes == 0 )
	and ( type( convexes ) ~= "table" or #convexes == 0 ) then return false end
	local minX, minY, minZ, maxX, maxY, maxZ = 1, 1, 1, 0, 0, 0
	local function includeBox( box )
		if type( box ) == "table" then
			minX, minY, minZ = math.min( minX, box[1] or 1 ), math.min( minY, box[2] or 1 ), math.min( minZ, box[3] or 1 )
			maxX, maxY, maxZ = math.max( maxX, box[4] or 0 ), math.max( maxY, box[5] or 0 ), math.max( maxZ, box[6] or 0 )
		end
	end
	for _, box in ipairs( boxes or {} ) do includeBox( box ) end
	-- Convex records in the public shape API may be represented as a list of
	-- vertices or as an AABB-like six-number record.  Include every numeric
	-- coordinate when deriving VoxelShape#bounds; an absent/opaque convex is
	-- deliberately not promoted to solid.
	for _, convex in ipairs( convexes or {} ) do
		if type( convex ) == "table" then
			if #convex >= 6 and type( convex[1] ) == "number" then
				includeBox( convex )
			else
				for _, vertex in ipairs( convex ) do
					if type( vertex ) == "table" then
						local x, y, z = tonumber( vertex.x or vertex[1] ), tonumber( vertex.y or vertex[2] ), tonumber( vertex.z or vertex[3] )
						if x and y and z then
							minX, minY, minZ = math.min( minX, x ), math.min( minY, y ), math.min( minZ, z )
							maxX, maxY, maxZ = math.max( maxX, x ), math.max( maxY, y ), math.max( maxZ, z )
						end
					end
				end
			end
		end
	end
	local size = ( maxX - minX + maxY - minY + maxZ - minZ ) / 3
	return size >= 0.7291666666666666 or maxZ - minZ >= 1
end

D.BlockStateSolidThreshold = 0.7291666666666666

-- ArmorStandItem#useOn builds EntityTypes.ARMOR_STAND dimensions at
-- Vec3.atBottomCenterOf(blockPos). This helper keeps the exact Source-unit
-- AABB calculation pure and testable before an entity is spawned.
function D.ArmorStandPlacementBounds( position, blockSize )
	if type( position ) ~= "table" then return nil, nil end
	local bs = math.max( 0.001, tonumber( blockSize ) or 36.5 )
	local half = C.armorStandWidth * bs * 0.5
	local height = C.armorStandHeight * bs
	local minimum = { x = ( position.x or 0 ) - half, y = ( position.y or 0 ) - half, z = position.z or 0 }
	local maximum = { x = ( position.x or 0 ) + half, y = ( position.y or 0 ) + half, z = ( position.z or 0 ) + height }
	return minimum, maximum
end

D.ArmorStandDefaultPoses = D.ArmorStandDefaultPoses or {
	head = { x = 0, y = 0, z = 0 }, body = { x = 0, y = 0, z = 0 },
	leftArm = { x = -10, y = 0, z = -10 }, rightArm = { x = -15, y = 0, z = 10 },
	leftLeg = { x = -1, y = 0, z = -1 }, rightLeg = { x = 1, y = 0, z = 1 },
}

function D.ArmorStandFlag( flags, bitValue )
	return bit and bit.band and bit.band( math.floor( tonumber( flags ) or 0 ), bitValue ) ~= 0
		or math.floor( tonumber( flags ) or 0 ) % ( bitValue * 2 ) >= bitValue
end

function D.ArmorStandDisabled( disabledSlots, slot, taking, showArms )
	local id = ({ mainhand = 0, offhand = 5, feet = 1, legs = 2, chest = 3, head = 4 })[slot]
	if id == nil then return true end
	local mask = math.floor( tonumber( disabledSlots ) or 0 )
	local function hasBit( bitIndex )
		if bit and bit.band then return bit.band( mask, 2 ^ bitIndex ) ~= 0 end
		return mask % ( 2 ^ ( bitIndex + 1 ) ) >= 2 ^ bitIndex
	end
	if hasBit( id ) then return true end
	if taking == true and hasBit( id + C.armorStandDisableTakingOffset ) then return true end
	if taking == false and hasBit( id + C.armorStandDisablePuttingOffset ) then return true end
	return ( slot == "mainhand" or slot == "offhand" ) and showArms ~= true
end

function D.ArmorStandClickedSlot( y, small, hasItem, mainhandEmpty, offhandHasItem )
	y = tonumber( y ) or 0
	local feetTop = 0.1 + ( small and 0.8 or 0.45 )
	local chestBottom = 0.9 + ( small and 0.3 or 0 )
	local chestTop = 0.9 + ( small and 1.0 or 0.7 )
	local legsTop = 0.4 + ( small and 1.0 or 0.8 )
	if y >= 0.1 and y < feetTop and hasItem.feet then return "feet" end
	if y >= chestBottom and y < chestTop and hasItem.chest then return "chest" end
	if y >= 0.4 and y < legsTop and hasItem.legs then return "legs" end
	if y >= 1.6 and hasItem.head then return "head" end
	if mainhandEmpty and offhandHasItem then return "offhand" end
	return "mainhand"
end

function D.ArmorStandQuantizedYaw( rotation )
	local value = ( tonumber( rotation ) or 0 ) - 180
	value = ( value + 180 ) % 360 - 180
	return math.floor( ( value + 22.5 ) / 45 ) * 45
end

function D.ArmorStandWiggleDegrees( currentTick, lastHitTick, partialTick )
	local age = ( tonumber( currentTick ) or 0 ) - ( tonumber( lastHitTick ) or 0 )
		+ ( tonumber( partialTick ) or 0 )
	if age < 0 or age >= C.armorStandWobbleTime then return 0 end
	return math.sin( age / 1.5 * math.pi ) * 3
end

-- ArmorStand#hurtServer is deliberately represented as a pure decision
-- function.  The entity wrapper supplies the side effects (sounds, drops,
-- removal and health mutation), while this function keeps every branch and
-- threshold tied to the Java method visible to source/runtime assertions.
function D.ArmorStandDamageDecision( context )
	context = type( context ) == "table" and context or {}
	-- ArmorStand#hurtServer order is observable: MOB_GRIEFING, then the
	-- bypass tag (which kills without drops), then ordinary invulnerability /
	-- invisible / marker checks. Keep these tests in source order.
	if context.removed then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.mob and context.mobGriefing == false then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.bypassesInvulnerability then
		-- ArmorStand#hurtServer calls kill() directly for this tag.  It does not
		-- call brokenByAnything, so equipment remains attached and no drops run.
		return { action = "kill", accepted = false, damageTool = false }
	end
	if context.invulnerable then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.invisible or context.marker then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.explosion then
		return { action = "break_anything", accepted = false, damageTool = false }
	end
	if context.ignites then
		if context.onFire then
			return { action = "cause_damage", amount = C.armorStandIgniteDamage,
				accepted = false, damageTool = false }
		end
		return { action = "ignite", seconds = C.armorStandIgniteSeconds,
			accepted = false, damageTool = false }
	end
	if context.burns and ( tonumber( context.health ) or C.armorStandMaxHealth ) > 0.5 then
		return { action = "cause_damage", amount = C.armorStandBurnDamage,
			accepted = false, damageTool = false }
	end
	local allowIncremental = context.canBreak == true
	local alwaysKills = context.alwaysKills == true
	if not allowIncremental and not alwaysKills then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.playerMayBuild == false then
		return { action = "reject", accepted = false, damageTool = false }
	end
	if context.creative then
		-- The creative branch only plays the break effects and kills. It does not
		-- call brokenByPlayer/brokenByAnything, hence no stand or equipment drops.
		return { action = "creative_break", accepted = true, damageTool = true }
	end
	local now = tonumber( context.gameTick ) or 0
	local last = tonumber( context.lastHit ) or 0
	if not alwaysKills and now - last > C.armorStandWobbleTime then
		return { action = "wobble", accepted = true, damageTool = true }
	end
	-- The non-creative second hit calls brokenByPlayer, even when the source is
	-- an ALWAYS_KILLS_ARMOR_STANDS projectile; that method adds the stand item,
	-- then brokenByAnything handles equipment.
	return { action = "break_player", accepted = true, damageTool = true }
end

-- MCITEM owns the Vanishing Curse hook.  A missing/failed hook is
-- intentionally permissive: only an explicit false veto suppresses a drop.
function D.ShouldDropEquipmentStack( actor, stack, context )
	if not stack then return false end
	if hook and hook.Run then
		local ok, result = pcall( hook.Run, "MC.ShouldDropItemStackOnDeath", actor, stack, context or {} )
		if ok and result == false then return false end
	end
	return true
end

-- Public, read-only query surface for other game-layer modules.  The engine
-- receives only the capability registration in sh_engine_bridge.lua.
D.PublicAPI = D.PublicAPI or {
	Constants = C,
	ItemKind = D.ItemKind,
	PaintingVariant = D.PaintingVariant,
	SelectPaintingVariant = D.SelectPaintingVariant,
	FrameAnalogOutput = D.AnalogOutput,
	NormalizeRotation = D.NormalizeRotation,
}
