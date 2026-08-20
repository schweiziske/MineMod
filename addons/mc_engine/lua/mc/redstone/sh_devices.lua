-- Redstone-controlled vanilla block state behavior.

MC = MC or {}

local GetBlockState = MC.GetBlockState
local GetStateProperty = MC.GetStateProperty
local StateWith = MC.StateWith
local CellKey = MC.CellKey

local function schema( stateId )
	return MC.BlockStateSchemaForState( stateId )
end

local function stateName( stateId )
	local value = schema( stateId )
	return value and value.name or nil
end

local function withBoolean( stateId, propertyName, value )
	return StateWith( stateId, propertyName, value ) or stateId
end

local function powerAt( bx, by, bz )
	return MC.RedstoneBestNeighborSignal( bx, by, bz ) > 0
end

local function singleCell( context, stateId )
	if stateId == context.stateId then return nil end
	return { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = stateId } } }
end

local function poweredOpenUpdate( context )
	local powered = powerAt( context.bx, context.by, context.bz )
	local wasPowered = GetStateProperty( context.stateId, "powered" ) == true
	if powered == wasPowered then return nil end
	local nextState = withBoolean( context.stateId, "powered", powered )
	nextState = withBoolean( nextState, "open", powered )
	return singleCell( context, nextState )
end

local function doorUpdate( context )
	local powered = powerAt( context.bx, context.by, context.bz )
	local half = GetStateProperty( context.stateId, "half" )
	local otherZ = half == "upper" and context.bz - 1 or context.bz + 1
	local otherState = GetBlockState( context.bx, context.by, otherZ )
	if stateName( otherState ) == stateName( context.stateId ) and powerAt( context.bx, context.by, otherZ ) then powered = true end
	local cells = {}
	local function append( bz, stateId )
		if stateName( stateId ) ~= stateName( context.stateId ) then return end
		local nextState = withBoolean( stateId, "powered", powered )
		if powered ~= ( GetStateProperty( stateId, "powered" ) == true ) then
			nextState = withBoolean( nextState, "open", powered )
		end
		if nextState ~= stateId then cells[#cells + 1] = { bx = context.bx, by = context.by, bz = bz, stateId = nextState } end
	end
	append( context.bz, context.stateId )
	append( otherZ, otherState )
	if #cells == 0 then return nil end
	local blockSchema = schema( context.stateId )
	local lowerZ = half == "upper" and otherZ or context.bz
	return {
		cells = cells,
		compareCollision = true,
		afterTransaction = function( data, transaction )
			if not transaction or transaction.ok ~= true or ( transaction.changed or 0 ) <= 0 then return end
			if MC.PlayDoorToggleSound then
				MC.PlayDoorToggleSound( data.blockId, data.open, data.bx, data.by, data.bz )
			end
		end,
		afterTransactionData = {
			blockId = blockSchema and blockSchema.blockId,
			open = powered,
			bx = context.bx, by = context.by, bz = lowerZ,
		},
	}
end

local doorHandler = { OnNeighborUpdate = doorUpdate }
local poweredOpenHandler = { OnNeighborUpdate = poweredOpenUpdate }

for name in pairs( MC.BlockByName ) do
	if string.match( name, "_door$" ) then
		MC.RegisterBlockUpdateHandler( name, doorHandler )
	elseif string.match( name, "_trapdoor$" ) or string.match( name, "_fence_gate$" ) then
		MC.RegisterBlockUpdateHandler( name, poweredOpenHandler )
	end
end

local RailOffsets = {
	{ 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 },
	{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
	{ 1, 0, -1 }, { -1, 0, -1 }, { 0, 1, -1 }, { 0, -1, -1 },
}

local function isRailFamily( stateId, railName )
	return stateName( stateId ) == railName
end

-- Vanilla searches at most eight rail segments for a powered source.  This
-- fixed-size local BFS intentionally does not let powered rails latch forever.
local function railHasSource( bx, by, bz, railName )
	local qx, qy, qz, qd = { bx }, { by }, { bz }, { 0 }
	local seen = { [CellKey( bx, by, bz )] = true }
	local head, tail = 1, 1
	while head <= tail do
		local x, y, z, depth = qx[head], qy[head], qz[head], qd[head]
		head = head + 1
		if MC.RedstoneBestNeighborSignal( x, y, z ) > 0 then return true end
		if depth < 8 then
			for index = 1, 12 do
				local offset = RailOffsets[index]
				local nx, ny, nz = x + offset[1], y + offset[2], z + offset[3]
				local key = CellKey( nx, ny, nz )
				if not seen[key] and isRailFamily( GetBlockState( nx, ny, nz ), railName ) then
					seen[key] = true
					tail = tail + 1
					qx[tail], qy[tail], qz[tail], qd[tail] = nx, ny, nz, depth + 1
				end
			end
		end
	end
	return false
end

MC.RegisterBlockUpdateHandler( "minecraft:powered_rail", {
	OnNeighborUpdate = function( context )
		local powered = railHasSource( context.bx, context.by, context.bz, "minecraft:powered_rail" )
		return singleCell( context, withBoolean( context.stateId, "powered", powered ) )
	end,
} )

local function directPoweredHandler( propertyName, invert )
	return {
		OnNeighborUpdate = function( context )
			local powered = powerAt( context.bx, context.by, context.bz )
			if invert then powered = not powered end
			return singleCell( context, withBoolean( context.stateId, propertyName, powered ) )
		end,
	}
end

local HorizontalOffset = {
	north = { 0, -1 }, south = { 0, 1 }, west = { -1, 0 }, east = { 1, 0 },
}
local Opposite = { north = "south", south = "north", west = "east", east = "west" }

local function tripwireHookUpdate( context )
	local facingName = GetStateProperty( context.stateId, "facing" )
	local offset = HorizontalOffset[facingName]
	if not offset then return nil end
	local attached, powered, receiverDistance = true, false, 0
	local wireStates = {}
	for distance = 1, 41 do
		local x, y = context.bx + offset[1] * distance, context.by + offset[2] * distance
		local stateId = GetBlockState( x, y, context.bz )
		local name = stateName( stateId )
		if name == "minecraft:tripwire_hook" then
			if GetStateProperty( stateId, "facing" ) == Opposite[facingName] then receiverDistance = distance end
			break
		end
		if name ~= "minecraft:tripwire" then attached = false break end
		wireStates[distance] = stateId
		local armed = GetStateProperty( stateId, "disarmed" ) ~= true
		if not armed then attached = false end
		if armed and GetStateProperty( stateId, "powered" ) == true then powered = true end
	end
	attached = attached and receiverDistance > 1
	powered = powered and attached
	local cells = {}
	local ownState = withBoolean( context.stateId, "attached", attached )
	ownState = withBoolean( ownState, "powered", powered )
	if ownState ~= context.stateId then cells[#cells + 1] = { bx = context.bx, by = context.by, bz = context.bz, stateId = ownState } end
	if receiverDistance > 0 then
		local rx, ry = context.bx + offset[1] * receiverDistance, context.by + offset[2] * receiverDistance
		local receiver = GetBlockState( rx, ry, context.bz )
		local nextReceiver = withBoolean( receiver, "attached", attached )
		nextReceiver = withBoolean( nextReceiver, "powered", powered )
		if nextReceiver ~= receiver then cells[#cells + 1] = { bx = rx, by = ry, bz = context.bz, stateId = nextReceiver } end
		for distance = 1, receiverDistance - 1 do
			local wireState = wireStates[distance]
			if wireState then
				local nextWire = withBoolean( wireState, "attached", attached )
				if nextWire ~= wireState then
					cells[#cells + 1] = {
						bx = context.bx + offset[1] * distance,
						by = context.by + offset[2] * distance,
						bz = context.bz, stateId = nextWire,
					}
				end
			end
		end
	end
	return #cells > 0 and { cells = cells, compareCollision = false } or nil
end

MC.RegisterBlockUpdateHandler( "minecraft:tripwire_hook", { OnNeighborUpdate = tripwireHookUpdate } )
MC.RegisterBlockUpdateHandler( "minecraft:tripwire", {
	OnNeighborUpdate = function( context )
		local updates = {}
		for _, offset in pairs( HorizontalOffset ) do
			for distance = 1, 41 do
				local x, y = context.bx + offset[1] * distance, context.by + offset[2] * distance
				local name = stateName( GetBlockState( x, y, context.bz ) )
				if name == "minecraft:tripwire_hook" then
					updates[#updates + 1] = { bx = x, by = y, bz = context.bz }
					break
				elseif name ~= "minecraft:tripwire" then break end
			end
		end
		return #updates > 0 and { updates = updates } or nil
	end,
} )

MC.RegisterBlockUpdateHandler( "minecraft:activator_rail", {
	OnNeighborUpdate = function( context )
		local powered = railHasSource( context.bx, context.by, context.bz, "minecraft:activator_rail" )
		return singleCell( context, withBoolean( context.stateId, "powered", powered ) )
	end,
} )
MC.RegisterBlockUpdateHandler( "minecraft:hopper", directPoweredHandler( "enabled", true ) )

local function logisticsParityEnabled( name, context )
	return MC.RunEvent and MC.RunEvent( "MC.LogisticsParityEnabled", {
		source = "redstone_device", block = name,
		bx = context and context.bx, by = context and context.by, bz = context and context.bz,
	} ) == true or false
end

local function legacyTriggeredNeighbor( context )
	local powered = powerAt( context.bx, context.by, context.bz )
	local triggered = GetStateProperty( context.stateId, "triggered" ) == true
	if powered and not triggered then
		local nextState = withBoolean( context.stateId, "triggered", true )
		return {
			cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = nextState } },
			schedule = { { delayTicks = 4, expectedStateId = nextState } },
		}
	end
	return nil
end

local function parityTriggeredNeighbor( context )
	local powered = powerAt( context.bx, context.by, context.bz )
		or powerAt( context.bx, context.by, context.bz + 1 )
	local triggered = GetStateProperty( context.stateId, "triggered" ) == true
	if powered and not triggered then
		local nextState = withBoolean( context.stateId, "triggered", true )
		return {
			cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = nextState } },
			-- Java schedules by block, not by the exact triggered state.  Omitting
			-- expectedStateId preserves a four-tick pulse that falls before firing.
			schedule = { { delayTicks = 4 } },
		}
	elseif not powered and triggered then
		return singleCell( context, withBoolean( context.stateId, "triggered", false ) )
	end
	return nil
end

local function triggeredHandler( name, logisticsDevice )
	MC.RegisterBlockUpdateHandler( name, {
		OnNeighborUpdate = function( context )
			if logisticsDevice and logisticsParityEnabled( name, context ) then
				return parityTriggeredNeighbor( context )
			end
			return legacyTriggeredNeighbor( context )
		end,
		OnScheduledTick = function( context )
			if logisticsDevice and logisticsParityEnabled( name, context ) then return nil end
			if GetStateProperty( context.stateId, "triggered" ) ~= true then return nil end
			return singleCell( context, withBoolean( context.stateId, "triggered", false ) )
		end,
	} )
end

triggeredHandler( "minecraft:dispenser", true )
triggeredHandler( "minecraft:dropper", true )
triggeredHandler( "minecraft:crafter" )

MC.RegisterBlockUpdateHandler( "minecraft:note_block", {
	OnNeighborUpdate = function( context )
		local powered = powerAt( context.bx, context.by, context.bz )
		local wasPowered = GetStateProperty( context.stateId, "powered" ) == true
		if powered == wasPowered then return nil end
		if powered and SERVER and sound and sound.Play then
			local note = tonumber( GetStateProperty( context.stateId, "note" ) ) or 0
			local position = MC.CellWorldCenter( context.bx, context.by, context.bz )
			sound.Play( "buttons/button17.wav", position, 70, math.floor( 50 * 2 ^ ( note / 12 ) + 0.5 ), 0.8 )
		end
		return singleCell( context, withBoolean( context.stateId, "powered", powered ) )
	end,
} )

local copperBulbHandler = {
	OnNeighborUpdate = function( context )
		local powered = powerAt( context.bx, context.by, context.bz )
		local wasPowered = GetStateProperty( context.stateId, "powered" ) == true
		if powered == wasPowered then return nil end
		local nextState = withBoolean( context.stateId, "powered", powered )
		if powered then nextState = withBoolean( nextState, "lit", GetStateProperty( context.stateId, "lit" ) ~= true ) end
		return singleCell( context, nextState )
	end,
}

for name in pairs( MC.BlockByName ) do
	if string.match( name, "copper_bulb$" ) then MC.RegisterBlockUpdateHandler( name, copperBulbHandler ) end
end

function MC.RedstoneDeviceDiagnostics()
	return {
		poweredRail = MC.BlockUpdateHandlerForName( "minecraft:powered_rail" ) ~= nil,
		hopper = MC.BlockUpdateHandlerForName( "minecraft:hopper" ) ~= nil,
		dispenser = MC.BlockUpdateHandlerForName( "minecraft:dispenser" ) ~= nil,
		tnt = MC.BlockUpdateHandlerForName( "minecraft:tnt" ) ~= nil,
	}
end
