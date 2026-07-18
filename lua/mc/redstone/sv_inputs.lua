-- Server-side physical redstone inputs. Active cells are tracked explicitly;
-- no world/chunk scan is performed during ticks.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local GetBlockState = MC.GetBlockState
local GetStateProperty = MC.GetStateProperty
local StateWith = MC.StateWith
local CellKey = MC.CellKey
local BS = MC.BS

local Active = {}
local ActiveIndex = {}
local ScanCursor = 1
local PlateNextCheckAt = {}

local cvScanBudget = CreateConVar( "mc_redstone_input_scan_budget", "256", FCVAR_ARCHIVE,
	"Maximum active pressure plates/daylight inputs checked per 0.1 second." )

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState( stateId )
	return schema and schema.name or nil
end

local function isPressurePlateName( name )
	return name and string.match( name, "_pressure_plate$" ) ~= nil
end

local function isTrackedInputName( name )
	return isPressurePlateName( name ) or name == "minecraft:daylight_detector"
		or name == "minecraft:detector_rail" or name == "minecraft:tripwire"
end

local function addActive( bx, by, bz )
	local key = CellKey( bx, by, bz )
	if ActiveIndex[key] then return false end
	local index = #Active + 1
	Active[index] = { key = key, bx = bx, by = by, bz = bz }
	ActiveIndex[key] = index
	return true
end

local function removeAt( index )
	local entry = Active[index]
	if not entry then return end
	local lastIndex = #Active
	local last = Active[lastIndex]
	Active[lastIndex] = nil
	ActiveIndex[entry.key] = nil
	if index < lastIndex then
		Active[index] = last
		ActiveIndex[last.key] = index
	end
	if ScanCursor > #Active then ScanCursor = 1 end
end

function SV.RegisterRedstonePhysicalInput( bx, by, bz )
	return addActive( math.floor( bx ), math.floor( by ), math.floor( bz ) )
end

local function entityTriggersPlate( entity, name )
	if not IsValid( entity ) or entity:IsWorld() then return false end
	if entity:IsPlayer() and entity:GetMoveType() == MOVETYPE_NOCLIP then return false end
	if entity.MCIgnoreBlockTriggers == true then return false end
	if name == "minecraft:stone_pressure_plate" or name == "minecraft:polished_blackstone_pressure_plate" then
		return entity:IsPlayer() or entity:IsNPC() or entity:IsNextBot()
	end
	return entity:GetMoveType() ~= MOVETYPE_NONE or entity:IsPlayer() or entity:IsNPC()
end

local function plateSignal( entry, stateId, name )
	local minimum = MC.CellWorldMin( entry.bx, entry.by, entry.bz )
	-- BasePressurePlateBlock.TOUCH_AABB: one pixel inset, four pixels tall.
	local inset = BS / 16
	local entities = ents.FindInBox(
		minimum + Vector( inset, inset, 0 ),
		minimum + Vector( BS - inset, BS - inset, BS * 0.25 )
	)
	local count = 0
	for index = 1, #entities do
		if entityTriggersPlate( entities[index], name ) then count = count + 1 end
	end
	if GetStateProperty( stateId, "power" ) ~= nil then
		local divisor = name == "minecraft:heavy_weighted_pressure_plate" and 10 or 1
		return math.min( 15, math.ceil( count / divisor ) )
	end
	return count > 0 and 15 or 0
end

local function pressurePlateSignalForState( stateId )
	local power = GetStateProperty( stateId, "power" )
	if power ~= nil then return math.max( 0, math.min( 15, tonumber( power ) or 0 ) ) end
	return GetStateProperty( stateId, "powered" ) == true and 15 or 0
end

local function pressurePlateCheckDelay( stateId )
	return GetStateProperty( stateId, "power" ) ~= nil and 0.5 or 1
end

local function heldPlateSignal( entry, stateId, detectedSignal )
	local key = entry.key
	local oldSignal = pressurePlateSignalForState( stateId )
	local now = CurTime()
	if detectedSignal > 0 then
		local nextCheck = PlateNextCheckAt[key]
		if oldSignal <= 0 or not nextCheck or now >= nextCheck then
			PlateNextCheckAt[key] = now + pressurePlateCheckDelay( stateId )
		end
		return detectedSignal, oldSignal
	end
	if oldSignal > 0 then
		local nextCheck = PlateNextCheckAt[key]
		if nextCheck and now < nextCheck then return oldSignal, oldSignal end
	end
	PlateNextCheckAt[key] = nil
	return 0, oldSignal
end

local function pressurePlatePitch( name, pressed )
	if name == "minecraft:stone_pressure_plate" or name == "minecraft:polished_blackstone_pressure_plate" then
		return pressed and 0.6 or 0.5
	end
	if name == "minecraft:light_weighted_pressure_plate" or name == "minecraft:heavy_weighted_pressure_plate" then
		return pressed and 0.75 or 0.65
	end
	return pressed and 0.8 or 0.7
end

local function playPressurePlateSound( entry, name, pressed )
	MC.PlayRedstoneSound( "mc/random/click.ogg", entry.bx, entry.by, entry.bz, 0.3, pressurePlatePitch( name, pressed ) )
end

local function updateEntry( entry )
	local stateId = GetBlockState( entry.bx, entry.by, entry.bz )
	local name = stateName( stateId )
	if not isTrackedInputName( name ) then return false end
	if name == "minecraft:daylight_detector" then
		local signal = MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
		if GetStateProperty( stateId, "inverted" ) == true then signal = 15 - signal end
		local nextState = StateWith( stateId, "power", math.max( 0, math.min( 15, signal ) ) ) or stateId
		if nextState ~= stateId then
			SV.ApplyBlockTransaction( {
				{ bx = entry.bx, by = entry.by, bz = entry.bz, stateId = nextState },
			}, { actor = nil, fx = false, netMode = "bulk", compareCollision = false } )
		end
		return true
	end
	if name == "minecraft:detector_rail" then
		local minimum = MC.CellWorldMin( entry.bx, entry.by, entry.bz )
		local entities = ents.FindInBox( minimum, minimum + Vector( BS, BS, BS * 0.75 ) )
		local powered = false
		for index = 1, #entities do
			local entity = entities[index]
			local class = IsValid( entity ) and entity:GetClass() or ""
			if string.find( class, "minecart", 1, true ) or string.find( class, "vehicle", 1, true ) then
				powered = true
				break
			end
		end
		local nextState = StateWith( stateId, "powered", powered ) or stateId
		if nextState ~= stateId then
			SV.ApplyBlockTransaction( {
				{ bx = entry.bx, by = entry.by, bz = entry.bz, stateId = nextState },
			}, { actor = nil, fx = false, netMode = "bulk", compareCollision = false } )
		end
		return true
	end
	if name == "minecraft:tripwire" then
		local minimum = MC.CellWorldMin( entry.bx, entry.by, entry.bz )
		local entities = ents.FindInBox(
			minimum + Vector( BS * 0.05, BS * 0.05, 0 ),
			minimum + Vector( BS * 0.95, BS * 0.95, BS * 0.35 )
		)
		local powered = false
		for index = 1, #entities do
			if entityTriggersPlate( entities[index], "minecraft:tripwire" ) then powered = true break end
		end
		local nextState = StateWith( stateId, "powered", powered ) or stateId
		if nextState ~= stateId then
			SV.ApplyBlockTransaction( {
				{ bx = entry.bx, by = entry.by, bz = entry.bz, stateId = nextState },
			}, { actor = nil, fx = false, netMode = "bulk", compareCollision = false } )
		end
		return true
	end
	local signal, oldSignal = heldPlateSignal( entry, stateId, plateSignal( entry, stateId, name ) )
	local nextState
	if GetStateProperty( stateId, "power" ) ~= nil then
		nextState = StateWith( stateId, "power", signal ) or stateId
	else
		nextState = StateWith( stateId, "powered", signal > 0 ) or stateId
	end
	if nextState ~= stateId then
		local result = SV.ApplyBlockTransaction( {
			{ bx = entry.bx, by = entry.by, bz = entry.bz, stateId = nextState },
		}, { actor = nil, fx = false, netMode = "bulk", compareCollision = true } )
		if result and result.ok == true and ( result.changed or 0 ) > 0 and ( oldSignal > 0 ) ~= ( signal > 0 ) then
			playPressurePlateSound( entry, name, signal > 0 )
		end
	end
	return true
end

local function seedPlayerFeet()
	local players = player.GetAll()
	for index = 1, #players do
		local bx, by, bz = MC.WorldToCell( players[index]:GetPos() )
		for dz = -1, 0 do
			local stateId = GetBlockState( bx, by, bz + dz )
			if isPressurePlateName( stateName( stateId ) ) then addActive( bx, by, bz + dz ) end
		end
	end
end

local function scanInputs()
	seedPlayerFeet()
	local count = #Active
	if count == 0 then return end
	local budget = math.max( 1, cvScanBudget:GetInt() )
	local processed = 0
	while processed < budget and #Active > 0 do
		if ScanCursor > #Active then ScanCursor = 1 end
		local entry = Active[ScanCursor]
		if updateEntry( entry ) then ScanCursor = ScanCursor + 1 else removeAt( ScanCursor ) end
		processed = processed + 1
		if processed >= count then break end
	end
end

local function installPressurePlate( name, block )
	local handlers = block.handlers or {}
	block.handlers = handlers
	local previousPlaced = handlers.OnPlaced
	local previousRemoved = handlers.OnRemoved
	handlers.OnPlaced = function( context, stateId )
		if previousPlaced then previousPlaced( context, stateId ) end
		addActive( context.bx, context.by, context.bz )
	end
	handlers.OnRemoved = function( context, stateId )
		if previousRemoved then previousRemoved( context, stateId ) end
		local index = ActiveIndex[CellKey( context.bx, context.by, context.bz )]
		if index then removeAt( index ) end
		PlateNextCheckAt[CellKey( context.bx, context.by, context.bz )] = nil
	end
	local previousUpdate = MC.BlockUpdateHandlerForName( name )
	MC.RegisterBlockUpdateHandler( name, {
		OnNeighborUpdate = function( context )
			addActive( context.bx, context.by, context.bz )
			if MC.FaceAttachedCanSurvive
			and not MC.FaceAttachedCanSurvive( context.bx, context.by, context.bz, context.stateId ) then
				return { cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = 0 } }, compareCollision = true }
			end
			return previousUpdate and previousUpdate.OnNeighborUpdate and previousUpdate.OnNeighborUpdate( context ) or nil
		end,
		OnScheduledTick = previousUpdate and previousUpdate.OnScheduledTick or nil,
	} )
end

for name, block in pairs( MC.BlockByName ) do
	if isPressurePlateName( name ) then installPressurePlate( name, block ) end
end

local detectorRailBlock = MC.BlockByName["minecraft:detector_rail"]
if detectorRailBlock then installPressurePlate( "minecraft:detector_rail", detectorRailBlock ) end
local tripwireBlock = MC.BlockByName["minecraft:tripwire"]
if tripwireBlock then installPressurePlate( "minecraft:tripwire", tripwireBlock ) end

local daylightBlock = MC.BlockByName["minecraft:daylight_detector"]
if daylightBlock then
	local handlers = daylightBlock.handlers or {}
	daylightBlock.handlers = handlers
	local previousPlaced = handlers.OnPlaced
	handlers.OnPlaced = function( context, stateId )
		if previousPlaced then previousPlaced( context, stateId ) end
		addActive( context.bx, context.by, context.bz )
	end
	handlers.OnUse = function( ply, bx, by, bz )
		local stateId = GetBlockState( bx, by, bz )
		if stateName( stateId ) ~= "minecraft:daylight_detector" then return false end
		local nextState = StateWith( stateId, "inverted", GetStateProperty( stateId, "inverted" ) ~= true ) or stateId
		local result = SV.ApplyBlockTransaction( {
			{ bx = bx, by = by, bz = bz, stateId = nextState },
		}, { actor = ply, fx = false, netMode = "bulk", compareCollision = false } )
		addActive( bx, by, bz )
		return result and result.ok == true and result.changed > 0 or false
	end
	MC.RegisterBlockUpdateHandler( "minecraft:daylight_detector", {
		OnNeighborUpdate = function( context ) addActive( context.bx, context.by, context.bz ) end,
	} )
end

timer.Remove( "mc_redstone_physical_inputs" )
timer.Create( "mc_redstone_physical_inputs", 0.1, 0, scanInputs )

function SV.RedstoneInputDiagnostics()
	return { active = #Active, cursor = ScanCursor, budget = cvScanBudget:GetInt() }
end

function SV.PulseRedstoneTarget( bx, by, bz, power, durationTicks )
	local stateId = GetBlockState( bx, by, bz )
	if stateName( stateId ) ~= "minecraft:target" then return false, "not_target" end
	power = math.max( 1, math.min( 15, math.floor( tonumber( power ) or 15 ) ) )
	local nextState = StateWith( stateId, "power", power ) or stateId
	local result = SV.ApplyBlockTransaction( {
		{ bx = bx, by = by, bz = bz, stateId = nextState },
	}, { actor = nil, fx = false, netMode = "bulk", compareCollision = false } )
	if not result or result.ok ~= true then return false, result and result.error or "transaction_failed" end
	SV.ScheduleBlockTick( bx, by, bz, durationTicks or 20, MC.BlockUpdateKind.SCHEDULED, nextState )
	return true, power
end

MC.RegisterBlockUpdateHandler( "minecraft:target", {
	OnScheduledTick = function( context )
		if ( tonumber( GetStateProperty( context.stateId, "power" ) ) or 0 ) <= 0 then return nil end
		return { cells = { {
			bx = context.bx, by = context.by, bz = context.bz,
			stateId = StateWith( context.stateId, "power", 0 ) or context.stateId,
		} } }
	end,
} )

function SV.PulseLightningRod( bx, by, bz, durationTicks )
	local stateId = GetBlockState( bx, by, bz )
	if stateName( stateId ) ~= "minecraft:lightning_rod" then return false, "not_lightning_rod" end
	local nextState = StateWith( stateId, "powered", true ) or stateId
	local result = SV.ApplyBlockTransaction( {
		{ bx = bx, by = by, bz = bz, stateId = nextState },
	}, { actor = nil, fx = false, netMode = "bulk", compareCollision = false } )
	if not result or result.ok ~= true then return false, result and result.error or "transaction_failed" end
	SV.ScheduleBlockTick( bx, by, bz, durationTicks or 8, MC.BlockUpdateKind.SCHEDULED, nextState )
	return true
end

MC.RegisterBlockUpdateHandler( "minecraft:lightning_rod", {
	OnScheduledTick = function( context )
		if GetStateProperty( context.stateId, "powered" ) ~= true then return nil end
		return { cells = { {
			bx = context.bx, by = context.by, bz = context.bz,
			stateId = StateWith( context.stateId, "powered", false ) or context.stateId,
		} } }
	end,
} )

local SensorByCell = {}
local SensorBuckets = {}
local addSensor

function SV.ClearRedstoneRuntime()
	Active = {}
	ActiveIndex = {}
	ScanCursor = 1
	SensorByCell = {}
	SensorBuckets = {}
	PlateNextCheckAt = {}
end

function SV.RebuildRedstoneRuntime()
	SV.ClearRedstoneRuntime()
	local seenChunks = {}
	for _, chunk in pairs( MC.World or {} ) do
		if chunk and not seenChunks[chunk] then
			seenChunks[chunk] = true
			MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
				local name = stateName( stateId )
				if isTrackedInputName( name ) then addActive( bx, by, bz ) end
				if name == "minecraft:sculk_sensor" or name == "minecraft:calibrated_sculk_sensor" then
					addSensor( bx, by, bz )
				end
			end )
		end
	end
	return #Active
end

local function sensorBucketKey( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return MC.ChunkKey( cx, cy, cz ), cx, cy, cz
end

addSensor = function( bx, by, bz )
	local key = CellKey( bx, by, bz )
	if SensorByCell[key] then return end
	local bucketKey = sensorBucketKey( bx, by, bz )
	local bucket = SensorBuckets[bucketKey]
	if not bucket then bucket = {}; SensorBuckets[bucketKey] = bucket end
	local record = { key = key, bx = bx, by = by, bz = bz, bucketKey = bucketKey, bucketIndex = #bucket + 1 }
	bucket[record.bucketIndex] = record
	SensorByCell[key] = record
end

local function removeSensor( record )
	local bucket = SensorBuckets[record.bucketKey]
	if bucket then
		local last = bucket[#bucket]
		bucket[#bucket] = nil
		if record.bucketIndex <= #bucket then
			bucket[record.bucketIndex] = last
			last.bucketIndex = record.bucketIndex
		end
		if #bucket == 0 then SensorBuckets[record.bucketKey] = nil end
	end
	SensorByCell[record.key] = nil
end

local function sensorScheduledTick( context )
	local phase = GetStateProperty( context.stateId, "sculk_sensor_phase" )
	if phase == "active" then
		local nextState = StateWith( context.stateId, "power", 0 ) or context.stateId
		nextState = StateWith( nextState, "sculk_sensor_phase", "cooldown" ) or nextState
		return {
			cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = nextState } },
			schedule = { { delayTicks = 10, expectedStateId = nextState } },
		}
	end
	if phase == "cooldown" then
		return { cells = { {
			bx = context.bx, by = context.by, bz = context.bz,
			stateId = StateWith( context.stateId, "sculk_sensor_phase", "inactive" ) or context.stateId,
		} } }
	end
	return nil
end

local function installSensor( name )
	local block = MC.BlockByName[name]
	if not block then return end
	local handlers = block.handlers or {}
	block.handlers = handlers
	local previousPlaced, previousRemoved = handlers.OnPlaced, handlers.OnRemoved
	handlers.OnPlaced = function( context, stateId )
		if previousPlaced then previousPlaced( context, stateId ) end
		addSensor( context.bx, context.by, context.bz )
	end
	handlers.OnRemoved = function( context, stateId )
		if previousRemoved then previousRemoved( context, stateId ) end
		local record = SensorByCell[CellKey( context.bx, context.by, context.bz )]
		if record then removeSensor( record ) end
	end
	local previousUpdate = MC.BlockUpdateHandlerForName( name )
	MC.RegisterBlockUpdateHandler( name, {
		OnNeighborUpdate = function( context )
			addSensor( context.bx, context.by, context.bz )
			return previousUpdate and previousUpdate.OnNeighborUpdate and previousUpdate.OnNeighborUpdate( context ) or nil
		end,
		OnScheduledTick = sensorScheduledTick,
	} )
end

installSensor( "minecraft:sculk_sensor" )
installSensor( "minecraft:calibrated_sculk_sensor" )

hook.Remove( "EntityEmitSound", "mc_redstone_sculk_sensor" )
hook.Add( "EntityEmitSound", "mc_redstone_sculk_sensor", function( soundData )
	if next( SensorByCell ) == nil then return end
	local position = soundData.Pos
	if not position and IsValid( soundData.Entity ) then position = soundData.Entity:GetPos() end
	if not position then return end
	local bx, by, bz = MC.WorldToCell( position )
	local _, cx, cy, cz = sensorBucketKey( bx, by, bz )
	local maxDistance = BS * 8
	local maxDistanceSquared = maxDistance * maxDistance
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				local bucket = SensorBuckets[MC.ChunkKey( cx + dx, cy + dy, cz + dz )]
				if bucket then
					for index = 1, #bucket do
						local record = bucket[index]
						local stateId = GetBlockState( record.bx, record.by, record.bz )
						local phase = GetStateProperty( stateId, "sculk_sensor_phase" )
						if phase == "inactive" then
							local center = MC.CellWorldCenter( record.bx, record.by, record.bz )
							local distanceSquared = center:DistToSqr( position )
							if distanceSquared <= maxDistanceSquared then
								local power = math.max( 1, 15 - math.floor( math.sqrt( distanceSquared ) / maxDistance * 15 ) )
								local nextState = StateWith( stateId, "power", power ) or stateId
								nextState = StateWith( nextState, "sculk_sensor_phase", "active" ) or nextState
								local result = SV.ApplyBlockTransaction( {
									{ bx = record.bx, by = record.by, bz = record.bz, stateId = nextState },
								}, { actor = nil, fx = false, netMode = "bulk", compareCollision = false } )
								if result and result.ok == true then
									SV.ScheduleBlockTick( record.bx, record.by, record.bz, 40, MC.BlockUpdateKind.SCHEDULED, nextState )
								end
							end
						end
					end
				end
			end
		end
	end
end )
