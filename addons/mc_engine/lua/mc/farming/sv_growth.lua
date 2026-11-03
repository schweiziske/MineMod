-- Minecraft Java 26.2 farmland hydration, crop growth and bonemeal behavior.
-- Random ticks enter through the shared block-update scheduler; this module
-- never scans MC.World and never depends on mc_game.

MC = MC or {}
MC.SV = MC.SV or {}

local Farming = MC.Farming
local SV = MC.SV
local Kind = MC.BlockUpdateKind

if not Farming or not Kind then return end

local AIR = MC.DefaultBlockState( "minecraft:air" ) or 0
local FARMLAND = "minecraft:farmland"
local PITCHER = "minecraft:pitcher_crop"
local SWEET_BERRY = "minecraft:sweet_berry_bush"
local NETHER_WART = "minecraft:nether_wart"

local function randomOneIn( divisor )
	divisor = math.max( 1, math.floor( tonumber( divisor ) or 1 ) )
	return math.random( divisor ) == 1
end

local function stateAt( bx, by, bz )
	return MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
end

local function stateNameAt( bx, by, bz )
	return Farming.StateName( stateAt( bx, by, bz ) )
end

-- Server lighting stores time-independent sky access. Java getRawBrightness
-- also subtracts the current sky darkening, so fold the shared day/night level
-- back in while retaining exact propagated block light.
local function rawBrightness( bx, by, bz )
	if not SV.SampleLighting then return 15 end
	local _, _, blockLight, skyLight = SV.SampleLighting( bx, by, bz, 0 )
	blockLight = math.Clamp( math.floor( tonumber( blockLight ) or 0 ), 0, 15 )
	skyLight = math.Clamp( math.floor( tonumber( skyLight ) or 0 ), 0, 15 )
	if MC.DayCycleSkyLevel then skyLight = math.min( skyLight, MC.DayCycleSkyLevel() ) end
	return math.max( blockLight, skyLight )
end

local function blockStateIsSolid( stateId )
	if not stateId or stateId == 0 then return false end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	return block ~= nil and block.solid ~= false
end

local function pitcherPairState( stateId, age, half )
	local nextState = MC.StateWith( stateId, "age", age )
	return nextState and MC.StateWith( nextState, "half", half ) or nil
end

local function samePitcherHalf( stateId, age, half )
	return Farming.StateName( stateId ) == PITCHER
		and tonumber( Farming.StateAge( stateId ) ) == tonumber( age )
		and MC.GetStateProperty( stateId, "half" ) == half
end

function Farming.CanSurvive( bx, by, bz, stateId )
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	stateId = math.floor( tonumber( stateId ) or -1 )
	local name = Farming.StateName( stateId )
	if not name then return false end

	if name == FARMLAND then
		local above = stateAt( bx, by, bz + 1 )
		return not blockStateIsSolid( above ) or Farming.MaintainsFarmlandState( above )
	end

	local below = stateAt( bx, by, bz - 1 )
	if Farming.Crops[name] or Farming.Stems[name] then
		return rawBrightness( bx, by, bz ) >= 8 and Farming.SupportsCropsState( below )
	end
	if Farming.AttachedStems[name] then
		return Farming.SupportsCropsState( below )
	end
	if name == NETHER_WART then
		return Farming.SupportsNetherWartState( below )
	end
	if name == SWEET_BERRY or name == "minecraft:torchflower" then
		return Farming.SupportsVegetationState( below )
	end
	if name == PITCHER then
		local age = tonumber( Farming.StateAge( stateId ) ) or 0
		local half = MC.GetStateProperty( stateId, "half" )
		if half == "upper" then
			return samePitcherHalf( below, age, "lower" )
		end
		if half ~= "lower" or rawBrightness( bx, by, bz ) < 8
		or not Farming.SupportsCropsState( below ) then return false end
		if age < 3 then return true end
		return samePitcherHalf( stateAt( bx, by, bz + 1 ), age, "upper" )
	end
	return false
end

local function cropGrowthSpeed( blockName, bx, by, bz )
	local speed = 1
	for dx = -1, 1 do
		for dy = -1, 1 do
			local contribution = 0
			local support = stateAt( bx + dx, by + dy, bz - 1 )
			if Farming.StateName( support ) == FARMLAND then
				contribution = 1
				if ( tonumber( MC.GetStateProperty( support, "moisture" ) ) or 0 ) > 0 then
					contribution = 3
				end
			end
			if dx ~= 0 or dy ~= 0 then contribution = contribution / 4 end
			speed = speed + contribution
		end
	end

	local sameX = stateNameAt( bx - 1, by, bz ) == blockName
		or stateNameAt( bx + 1, by, bz ) == blockName
	local sameY = stateNameAt( bx, by - 1, bz ) == blockName
		or stateNameAt( bx, by + 1, bz ) == blockName
	if sameX and sameY then return speed / 2 end
	for _, offset in ipairs( { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } ) do
		if stateNameAt( bx + offset[1], by + offset[2], bz ) == blockName then
			return speed / 2
		end
	end
	return speed
end

Farming.GetGrowthSpeed = cropGrowthSpeed

local function growthSucceeded( blockName, bx, by, bz )
	local speed = cropGrowthSpeed( blockName, bx, by, bz )
	return randomOneIn( math.floor( 25 / speed ) + 1 )
end

local function replaceCell( context, stateId, dropResources )
	return {
		dropResources = dropResources == true,
		cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = stateId } },
		compareCollision = true,
	}
end

local function unsupportedCropUpdate( context )
	local name = Farming.StateName( context.stateId )
	local attached = Farming.AttachedStems[name]
	if attached then
		if not Farming.CanSurvive( context.bx, context.by, context.bz, context.stateId ) then
			return replaceCell( context, AIR, true )
		end
		local facing = Farming.StateFacing( context.stateId )
		local offset = Farming.HorizontalDirections[facing]
		if offset and stateNameAt( context.bx + offset[1], context.by + offset[2], context.bz ) ~= attached.fruit then
			local stem = MC.DefaultBlockState( attached.stem )
			stem = stem and MC.StateWith( stem, "age", 7 ) or nil
			if stem then return replaceCell( context, stem, false ) end
		end
		return nil
	end

	if Farming.CanSurvive( context.bx, context.by, context.bz, context.stateId ) then return nil end
	local dropResources = true
	if name == PITCHER and MC.GetStateProperty( context.stateId, "half" ) == "upper" then
		dropResources = false
	end
	return replaceCell( context, AIR, dropResources )
end

local function farmlandNeighborUpdate( context )
	return {
		schedule = { { delayTicks = 1, expectedStateId = context.stateId } },
	}
end

local function farmlandScheduledTick( context )
	if Farming.CanSurvive( context.bx, context.by, context.bz, context.stateId ) then return nil end
	local dirt = MC.DefaultBlockState( "minecraft:dirt" )
	return dirt and replaceCell( context, dirt, false ) or nil
end

local function nearWater( bx, by, bz )
	if not MC.LiquidStateMetrics then return false end
	for dx = -4, 4 do
		for dy = -4, 4 do
			for dz = 0, 1 do
				local kind = MC.LiquidStateMetrics( stateAt( bx + dx, by + dy, bz + dz ) )
				if kind == "water" then return true end
			end
		end
	end
	return false
end

local function farmlandRandomTick( context )
	local moisture = tonumber( MC.GetStateProperty( context.stateId, "moisture" ) ) or 0
	-- Java also hydrates from isRainingAt(pos.above()). MineMod currently has no
	-- authoritative weather/rain state, so water is the only producer here.
	if nearWater( context.bx, context.by, context.bz ) then
		if moisture >= 7 then return nil end
		local hydrated = MC.StateWith( context.stateId, "moisture", 7 )
		return hydrated and replaceCell( context, hydrated, false ) or nil
	end
	if moisture > 0 then
		local drying = MC.StateWith( context.stateId, "moisture", moisture - 1 )
		return drying and replaceCell( context, drying, false ) or nil
	end
	if Farming.MaintainsFarmlandState( stateAt( context.bx, context.by, context.bz + 1 ) ) then return nil end
	local dirt = MC.DefaultBlockState( "minecraft:dirt" )
	return dirt and replaceCell( context, dirt, false ) or nil
end

local function cropRandomTick( context )
	local name = Farming.StateName( context.stateId )
	local definition = Farming.Crops[name]
	if not definition then return nil end
	if definition.randomSkipDivisor and randomOneIn( definition.randomSkipDivisor ) then return nil end
	if rawBrightness( context.bx, context.by, context.bz ) < 9 then return nil end
	local age = tonumber( Farming.StateAge( context.stateId ) ) or 0
	if age >= definition.maxAge or not growthSucceeded( name, context.bx, context.by, context.bz ) then return nil end
	local nextAge = age + 1
	local nextState
	if definition.matureBlock and nextAge >= definition.maxAge then
		nextState = MC.DefaultBlockState( definition.matureBlock )
	else
		nextState = Farming.WithAge( context.stateId, nextAge )
	end
	return nextState and replaceCell( context, nextState, false ) or nil
end

local function stemFruitCells( bx, by, bz, stemStateId, definition )
	local direction = Farming.HorizontalDirectionOrder[math.random( #Farming.HorizontalDirectionOrder )]
	local offset = Farming.HorizontalDirections[direction]
	local fruitX, fruitY = bx + offset[1], by + offset[2]
	if stateAt( fruitX, fruitY, bz ) ~= AIR
		or not Farming.SupportsVegetationState( stateAt( fruitX, fruitY, bz - 1 ) ) then return nil end
	local fruit = MC.DefaultBlockState( definition.fruit )
	local attached = MC.DefaultBlockState( definition.attached )
	attached = attached and MC.StateWith( attached, "facing", direction ) or nil
	if not fruit or not attached then return nil end
	return {
		{ bx = fruitX, by = fruitY, bz = bz, stateId = fruit },
		{ bx = bx, by = by, bz = bz, stateId = attached },
	}
end

local function stemRandomTick( context )
	local name = Farming.StateName( context.stateId )
	local definition = Farming.Stems[name]
	if not definition or rawBrightness( context.bx, context.by, context.bz ) < 9
		or not growthSucceeded( name, context.bx, context.by, context.bz ) then return nil end
	local age = tonumber( Farming.StateAge( context.stateId ) ) or 0
	if age < 7 then
		local nextState = Farming.WithAge( context.stateId, age + 1 )
		return nextState and replaceCell( context, nextState, false ) or nil
	end
	local cells = stemFruitCells( context.bx, context.by, context.bz, context.stateId, definition )
	return cells and { cells = cells, compareCollision = true } or nil
end

local function sweetBerryRandomTick( context )
	local age = tonumber( Farming.StateAge( context.stateId ) ) or 0
	if age >= 3 or not randomOneIn( 5 )
		or rawBrightness( context.bx, context.by, context.bz + 1 ) < 9 then return nil end
	local nextState = Farming.WithAge( context.stateId, age + 1 )
	return nextState and replaceCell( context, nextState, false ) or nil
end

local function netherWartRandomTick( context )
	local age = tonumber( Farming.StateAge( context.stateId ) ) or 0
	if age >= 3 or not randomOneIn( 10 ) then return nil end
	local nextState = Farming.WithAge( context.stateId, age + 1 )
	return nextState and replaceCell( context, nextState, false ) or nil
end

local function pitcherGrowthCells( bx, by, bz, lowerState, increase )
	local age = tonumber( Farming.StateAge( lowerState ) ) or 0
	local nextAge = math.min( 4, age + math.max( 0, math.floor( increase or 0 ) ) )
	if nextAge <= age or rawBrightness( bx, by, bz ) < 8
		or not Farming.SupportsCropsState( stateAt( bx, by, bz - 1 ) ) then return nil end
	local above = stateAt( bx, by, bz + 1 )
	if nextAge >= 3 and above ~= AIR and Farming.StateName( above ) ~= PITCHER then return nil end
	local lower = pitcherPairState( lowerState, nextAge, "lower" )
	if not lower then return nil end
	local cells = { { bx = bx, by = by, bz = bz, stateId = lower } }
	if nextAge >= 3 then
		local upper = pitcherPairState( lowerState, nextAge, "upper" )
		if not upper then return nil end
		cells[#cells + 1] = { bx = bx, by = by, bz = bz + 1, stateId = upper }
	end
	return cells
end

local function pitcherRandomTick( context )
	local name = Farming.StateName( context.stateId )
	if name ~= PITCHER or not growthSucceeded( name, context.bx, context.by, context.bz ) then return nil end
	local cells = pitcherGrowthCells( context.bx, context.by, context.bz, context.stateId, 1 )
	return cells and { cells = cells, compareCollision = true } or nil
end

local function applyBonemealCells( actor, cells, beforePublish )
	local result = SV.ApplyBlockTransaction( cells, {
		actor = actor,
		fx = false,
		netMode = "bulk",
		priorityPhys = true,
		immediatePhys = true,
		compareCollision = true,
		beforePublish = beforePublish,
	} )
	if not result or result.ok ~= true then return false, result and result.error or "write_failed" end
	return true, result
end

local function resolvePitcherLower( bx, by, bz, stateId )
	if Farming.StateName( stateId ) ~= PITCHER then return nil end
	if MC.GetStateProperty( stateId, "half" ) == "lower" then return bx, by, bz, stateId end
	local lower = stateAt( bx, by, bz - 1 )
	if Farming.StateName( lower ) == PITCHER and MC.GetStateProperty( lower, "half" ) == "lower" then
		return bx, by, bz - 1, lower
	end
	return nil
end

function Farming.ApplyBonemeal( actor, bx, by, bz, options )
	if not IsValid( actor ) or not actor.IsPlayer or not actor:IsPlayer() then return false, "invalid_player" end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	if not SV.Validate or SV.Validate( actor, bx, by, bz, false, { action = "modify", reason = "bonemeal" } ) ~= true then
		return false, "edit_rejected"
	end
	local stateId = stateAt( bx, by, bz )
	local name = Farming.StateName( stateId )
	local definition = Farming.Crops[name]
	local cells

	if definition then
		local age = tonumber( Farming.StateAge( stateId ) ) or 0
		if age >= definition.maxAge then return false, "not_bonemealable" end
		local increase = math.random( definition.boneMin, definition.boneMax )
		if definition.boneDivisor then increase = math.floor( increase / definition.boneDivisor ) end
		local nextAge = math.min( definition.maxAge, age + increase )
		local nextState = definition.matureBlock and nextAge >= definition.maxAge
			and MC.DefaultBlockState( definition.matureBlock ) or Farming.WithAge( stateId, nextAge )
		if not nextState then return false, "growth_state_unavailable" end
		cells = { { bx = bx, by = by, bz = bz, stateId = nextState } }
	elseif Farming.Stems[name] then
		local age = tonumber( Farming.StateAge( stateId ) ) or 0
		if age >= 7 then return false, "not_bonemealable" end
		local nextAge = math.min( 7, age + math.random( 2, 5 ) )
		local nextStem = Farming.WithAge( stateId, nextAge )
		if not nextStem then return false, "growth_state_unavailable" end
		cells = { { bx = bx, by = by, bz = bz, stateId = nextStem } }
		-- StemBlock.performBonemeal calls randomTick immediately after reaching 7;
		-- that extra call still includes the normal growth-speed probability.
		if nextAge == 7 and rawBrightness( bx, by, bz ) >= 9
		and growthSucceeded( name, bx, by, bz ) then
			cells = stemFruitCells( bx, by, bz, nextStem, Farming.Stems[name] ) or cells
		end
	elseif name == SWEET_BERRY then
		local age = tonumber( Farming.StateAge( stateId ) ) or 0
		if age >= 3 then return false, "not_bonemealable" end
		local nextState = Farming.WithAge( stateId, math.min( 3, age + 1 ) )
		cells = nextState and { { bx = bx, by = by, bz = bz, stateId = nextState } } or nil
	elseif name == PITCHER then
		local lowerX, lowerY, lowerZ, lowerState = resolvePitcherLower( bx, by, bz, stateId )
		if not lowerX or ( tonumber( Farming.StateAge( lowerState ) ) or 0 ) >= 4 then
			return false, "not_bonemealable"
		end
		cells = pitcherGrowthCells( lowerX, lowerY, lowerZ, lowerState, 1 )
	else
		return false, "not_bonemealable"
	end

	if not cells then return false, "growth_blocked" end
	return applyBonemealCells( actor, cells, options and options.beforePublish )
end

function Farming.Plant( actor, bx, by, bz, stateId, options )
	if not IsValid( actor ) or not actor.IsPlayer or not actor:IsPlayer() then return false, "invalid_player" end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	if stateAt( bx, by, bz ) ~= AIR then return false, "target_occupied" end
	local initial, stateError = Farming.InitialPlantState( stateId )
	if not initial then return false, stateError end
	if not Farming.CanSurvive( bx, by, bz, initial ) then return false, "cannot_survive" end
	local planted, result = SV.PlaceState( actor, bx, by, bz, initial, {
		compareCollision = true,
		fx = true,
		beforePublish = options and options.beforePublish,
	} )
	if not planted then
		return false, istable( result ) and result.error or "placement_rejected"
	end
	return true, {
		bx = bx, by = by, bz = bz,
		stateId = initial,
		revision = result and result.revision or nil,
	}
end

local cropHandler = { OnNeighborUpdate = unsupportedCropUpdate }

MC.RegisterBlockUpdateHandler( FARMLAND, {
	OnNeighborUpdate = farmlandNeighborUpdate,
	OnScheduledTick = farmlandScheduledTick,
	OnRandomTick = farmlandRandomTick,
} )

for name in pairs( Farming.Crops ) do MC.RegisterBlockUpdateHandler( name, cropHandler ) end
for name in pairs( Farming.Stems ) do MC.RegisterBlockUpdateHandler( name, cropHandler ) end
for name in pairs( Farming.AttachedStems ) do MC.RegisterBlockUpdateHandler( name, cropHandler ) end
for _, name in ipairs( { SWEET_BERRY, NETHER_WART, PITCHER, "minecraft:torchflower" } ) do
	MC.RegisterBlockUpdateHandler( name, cropHandler )
end

MC.RegisterBlockUpdateObserver( "mc:farming_crop_random", function( stateId, schema )
	local definition = schema and Farming.Crops[schema.name] or nil
	return definition ~= nil and ( tonumber( Farming.StateAge( stateId ) ) or 0 ) < definition.maxAge
end, { OnRandomTick = cropRandomTick } )

MC.RegisterBlockUpdateObserver( "mc:farming_stem_random", function( _, schema )
	return schema ~= nil and Farming.Stems[schema.name] ~= nil
end, { OnRandomTick = stemRandomTick } )

MC.RegisterBlockUpdateObserver( "mc:farming_sweet_berry_random", function( stateId, schema )
	return schema ~= nil and schema.name == SWEET_BERRY
		and ( tonumber( Farming.StateAge( stateId ) ) or 0 ) < 3
end, { OnRandomTick = sweetBerryRandomTick } )

MC.RegisterBlockUpdateObserver( "mc:farming_nether_wart_random", function( stateId, schema )
	return schema ~= nil and schema.name == NETHER_WART
		and ( tonumber( Farming.StateAge( stateId ) ) or 0 ) < 3
end, { OnRandomTick = netherWartRandomTick } )

MC.RegisterBlockUpdateObserver( "mc:farming_pitcher_random", function( stateId, schema )
	return schema ~= nil and schema.name == PITCHER
		and MC.GetStateProperty( stateId, "half" ) == "lower"
		and ( tonumber( Farming.StateAge( stateId ) ) or 0 ) < 4
end, { OnRandomTick = pitcherRandomTick } )
