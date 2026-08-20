-- Source-verified logistics rules for gameplay-parity checkpoint 5.
-- Values remain in Minecraft cells/tick until a Source boundary explicitly
-- converts them, so constants can be compared directly with decompiled code.

MC = MC or {}
MC.LogisticsParity = MC.LogisticsParity or {}

local L = MC.LogisticsParity

L.Constants = L.Constants or {
	tickSeconds = 1 / 20,
	hopperSlots = 5,
	dispenserSlots = 9,
	hopperInitialCooldown = -1,
	hopperTransferCooldown = 8,
	dispenserTriggerDelay = 4,
	hopperSuckMinX = 0,
	hopperSuckMinY = 0,
	hopperSuckMinZ = 11 / 16,
	hopperSuckMaxX = 1,
	hopperSuckMaxY = 1,
	hopperSuckMaxZ = 2,
	defaultDispensePositionScale = 0.7,
	defaultDispenseVerticalOffset = 0.125,
	defaultDispenseHorizontalOffset = 0.15625,
	defaultDispenseAccuracy = 6,
	defaultDispensePowerMinimum = 0.2,
	defaultDispensePowerRange = 0.1,
	defaultDispenseVerticalMean = 0.2,
	defaultDispenseTriangleUnit = 0.0172275,
	projectilePositionVerticalOffset = 0.1,
	projectilePower = 1.1,
	projectileUncertainty = 6,
	potionProjectilePower = 1.375,
	potionProjectileUncertainty = 3,
	fireworkPositionScale = 0.5000099999997474,
	fireworkPower = 0.5,
	fireworkUncertainty = 1,
	chargePositionScale = 1,
	chargeTriangleDeviation = 0.11485,
	emptyContainerEvent = 1001,
	defaultDispenseEvent = 1000,
	defaultProjectileEvent = 1002,
	fireworkEvent = 1004,
	fireChargeEvent = 1018,
	windChargeEvent = 1051,
}

local C = L.Constants

if CreateConVar then
	local flags = FCVAR_ARCHIVE or 0
	if SERVER and bit and bit.bor then
		flags = bit.bor( flags, FCVAR_REPLICATED or 0, FCVAR_NOTIFY or 0 )
	end
	L.EnableConVar = GetConVar and GetConVar( "mc_gameplay_parity_logistics" )
		or CreateConVar( "mc_gameplay_parity_logistics", "0", flags,
			"Enable source-verified hopper, dispenser and dropper logistics." )
end

function L.Enabled()
	local cv = L.EnableConVar
	if not cv and GetConVar then cv = GetConVar( "mc_gameplay_parity_logistics" ) end
	return cv and cv.GetBool and cv:GetBool() == true or false
end

local function clamp( value, minimum, maximum )
	value = tonumber( value ) or minimum
	return math.max( minimum, math.min( maximum, value ) )
end

function L.NormalizeDirection( direction )
	direction = string.lower( tostring( direction or "" ) )
	return L.DirectionOffsets[direction] and direction or nil
end

L.DirectionOffsets = L.DirectionOffsets or {
	north = { 0, -1, 0 }, south = { 0, 1, 0 },
	west = { -1, 0, 0 }, east = { 1, 0, 0 },
	up = { 0, 0, 1 }, down = { 0, 0, -1 },
}

L.OppositeDirections = L.OppositeDirections or {
	north = "south", south = "north", west = "east", east = "west",
	up = "down", down = "up",
}

function L.DirectionOffset( direction )
	local offset = L.DirectionOffsets[L.NormalizeDirection( direction )]
	if not offset then return nil end
	return offset[1], offset[2], offset[3]
end

function L.OppositeDirection( direction )
	return L.OppositeDirections[L.NormalizeDirection( direction )]
end

local FURNACE_SLOTS = {
	up = { 0 }, down = { 2, 1 },
	north = { 1 }, south = { 1 }, west = { 1 }, east = { 1 },
}

local BREWING_SLOTS = {
	up = { 3 }, down = { 0, 1, 2, 3 },
	north = { 0, 1, 2, 4 }, south = { 0, 1, 2, 4 },
	west = { 0, 1, 2, 4 }, east = { 0, 1, 2, 4 },
}

local function flatSlots( size )
	local slots = {}
	for slot = 0, math.max( 0, math.floor( tonumber( size ) or 0 ) ) - 1 do
		slots[#slots + 1] = slot
	end
	return slots
end

local function copySlots( slots )
	local copied = {}
	for index = 1, #slots do copied[index] = slots[index] end
	return copied
end

function L.SlotsForFace( kind, direction, size )
	kind = tostring( kind or "" )
	direction = L.NormalizeDirection( direction )
	local slots
	if kind == "furnace" or kind == "blast_furnace" then slots = direction and FURNACE_SLOTS[direction]
	elseif kind == "brewing_stand" then slots = direction and BREWING_SLOTS[direction] end
	return slots and copySlots( slots ) or flatSlots( size )
end

function L.CanTakeThroughFace( kind, slot, stack, direction )
	kind, slot = tostring( kind or "" ), math.floor( tonumber( slot ) or -1 )
	direction = L.NormalizeDirection( direction )
	local item = type( stack ) == "table" and tostring( stack.item or "" ) or ""
	if ( kind == "furnace" or kind == "blast_furnace" ) and direction == "down" and slot == 1 then
		return item == "minecraft:water_bucket" or item == "minecraft:bucket"
	end
	if kind == "brewing_stand" and slot == 3 then return item == "minecraft:glass_bottle" end
	return true
end

function L.ContainerAnalogOutput( storage, size, maximumForStack )
	size = math.max( 0, math.floor( tonumber( size ) or 0 ) )
	if size == 0 then return 0 end
	local total = 0
	for slot = 1, size do
		local stack = type( storage ) == "table" and storage[slot] or nil
		local count = type( stack ) == "table" and math.max( 0, math.floor( tonumber( stack.count ) or 0 ) ) or 0
		if count > 0 then
			local maximum = maximumForStack and maximumForStack( stack )
				or MC.ItemStackMaxCount and MC.ItemStackMaxCount( stack ) or 64
			maximum = math.max( 1, math.floor( tonumber( maximum ) or 64 ) )
			total = total + count / maximum
		end
	end
	total = total / size
	return math.floor( total * 14 ) + ( total > 0 and 1 or 0 )
end

local function stackPresent( stack )
	if MC.IsEmptyItemStack then return not MC.IsEmptyItemStack( stack ) end
	return type( stack ) == "table" and ( tonumber( stack.count ) or 0 ) > 0
end

function L.ReservoirSlot( storage, size, nextInt )
	size = math.max( 0, math.floor( tonumber( size ) or 0 ) )
	if type( nextInt ) ~= "function" then return -1 end
	local selected, replaceOdds = -1, 1
	for slot = 0, size - 1 do
		if stackPresent( type( storage ) == "table" and storage[slot + 1] or nil ) then
			local roll = math.floor( tonumber( nextInt( replaceOdds )) or -1 )
			if roll == 0 then selected = slot end
			replaceOdds = replaceOdds + 1
		end
	end
	return selected
end

function L.BlocksPerTickToSource( value, blockSize )
	return ( tonumber( value ) or 0 ) * ( tonumber( blockSize ) or 0 ) / C.tickSeconds
end

function L.DefaultDispensePosition( bx, by, bz, direction )
	local dx, dy, dz = L.DirectionOffset( direction )
	if not dx then return nil end
	local x = ( tonumber( bx ) or 0 ) + 0.5 + dx * C.defaultDispensePositionScale
	local y = ( tonumber( by ) or 0 ) + 0.5 + dy * C.defaultDispensePositionScale
	local z = ( tonumber( bz ) or 0 ) + 0.5 + dz * C.defaultDispensePositionScale
	if dz ~= 0 then z = z - C.defaultDispenseVerticalOffset
	else z = z - C.defaultDispenseHorizontalOffset end
	return x, y, z
end

function L.DefaultDispenseVelocityMeans( direction, randomUnit )
	local dx, dy, dz = L.DirectionOffset( direction )
	if not dx then return nil end
	local unit = clamp( randomUnit, 0, 1 )
	local power = unit * C.defaultDispensePowerRange + C.defaultDispensePowerMinimum
	return dx * power, dy * power, C.defaultDispenseVerticalMean + dz * power,
		C.defaultDispenseTriangleUnit * C.defaultDispenseAccuracy
end

L.DoesNotBlockHoppers = L.DoesNotBlockHoppers or {
	["minecraft:bee_nest"] = true,
	["minecraft:beehive"] = true,
}

function L.BlockStopsHopperItems( blockName, fullCollision )
	return fullCollision == true and L.DoesNotBlockHoppers[tostring( blockName or "")] ~= true
end

