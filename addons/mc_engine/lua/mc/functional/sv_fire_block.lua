--[[----------------------------------------------------------------------------
	MC : FireBlock / SoulFireBlock lifecycle on the block update scheduler.

	Java 26.2 FireBlock is two separate rules that both live on the tick:

	  * survival -- BaseFireBlock#updateShape drops the block to air the moment
	    canSurvive() fails, so fire never lingers in mid-air once whatever was
	    holding it up is gone.
	  * burnout  -- FireBlock#tick ages the fire 0..15 and eventually removes
	    it, which is why an unfed fire on stone goes out on its own.

	Ignition (flint and steel, explosions) already resolves the placement state
	elsewhere; this module owns what happens to fire afterwards. The survival
	helpers are published on MC so the game layer's ignition path and this
	module cannot drift apart.

	Deliberately NOT ported: fire spread to flammable neighbours
	(FireBlock#tick's trySpread half) and rain extinguishing. Spread is a
	separate feature with its own griefing surface, and MCSWEP has no weather
	state to ask isRaining() about.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local Kind = MC.BlockUpdateKind
if not Kind then error( "MC fire block dependencies are unavailable" ) end

local FIRE = "minecraft:fire"
local SOUL_FIRE = "minecraft:soul_fire"
-- FireBlock.AGE is 0..15; MAX_AGE is where the "burn out over stone" roll lives.
local MAX_AGE = 15
-- FireBlock#tick removes unfed fire once it has aged past this, even when the
-- block below is sturdy. Below it, sturdy ground alone keeps the fire.
local UNFED_SURVIVE_AGE = 3

-- BlockTags.SOUL_FIRE_BASE_BLOCKS
local SOUL_BASE = {
	["minecraft:soul_sand"] = true,
	["minecraft:soul_soil"] = true,
}

local SURVIVAL_NEIGHBOURS = {
	{ 0, -1, 0 }, { 1, 0, 0 }, { 0, 1, 0 },
	{ -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
}

local function airState()
	return MC.DefaultBlockState and MC.DefaultBlockState( "minecraft:air" ) or 0
end

local function fireTickEnabled()
	-- Stands in for the doFireTick gamerule.
	local cvar = MC.Config and MC.Config.FireTick or nil
	return not cvar or cvar:GetBool()
end

-- FireBlock#getFireTickDelay: 30 + random.nextInt(10) ticks. The scheduler runs
-- at 20 logic ticks per second, so delayTicks are Minecraft ticks 1:1.
function MC.FireTickDelay()
	return 30 + math.random( 0, 9 )
end

local function blockNameAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then return nil, stateId end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if schema and schema.name then return schema.name, stateId end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId )
		or MC.GetBlock and MC.GetBlock( bx, by, bz )
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	return block and block.mcid or nil, stateId
end

MC.FireBlockNameAt = blockNameAt

-- FireBlock#canBurn, membership only. Ignition/burn odds are only needed by the
-- spread half, which this module does not implement.
function MC.FireIsFlammableAt( bx, by, bz )
	local name = blockNameAt( bx, by, bz )
	local flammable = MC.GeneratedFireFlammableBlocks
	return name ~= nil and flammable ~= nil and flammable[name] == true
end

-- BlockState#isFaceSturdy( ..., Direction.UP )
function MC.FireTopFaceSturdyAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then return false end
	local liquid = MC.Liquid
	if liquid and liquid.FaceSturdyForFlow then
		return liquid.FaceSturdyForFlow( stateId, bx, by, bz, liquid.FACE_TOP or 1 ) == true
	end
	return MC.BlockIsFullCubeForState
		and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true or false
end

-- FireBlock#isValidFireLocation: any of the six neighbours can burn.
function MC.FireIsValidLocation( bx, by, bz )
	for index = 1, #SURVIVAL_NEIGHBOURS do
		local offset = SURVIVAL_NEIGHBOURS[index]
		if MC.FireIsFlammableAt( bx + offset[1], by + offset[2], bz + offset[3] ) then return true end
	end
	return false
end

-- FireBlock#canSurvive: sturdy ground underneath, or something adjacent to burn.
function MC.FireCanSurvive( bx, by, bz )
	if MC.FireTopFaceSturdyAt( bx, by, bz - 1 ) then return true end
	return MC.FireIsValidLocation( bx, by, bz )
end

-- SoulFireBlock#canSurvive is only about the block underneath.
function MC.SoulFireCanSurvive( bx, by, bz )
	return SOUL_BASE[blockNameAt( bx, by, bz - 1 )] == true
end

local function removeFire( context )
	return {
		cells = { { bx = context.bx, by = context.by, bz = context.bz, stateId = airState() } },
		compareCollision = true,
	}
end

local function burnoutSchedule( delayTicks )
	return { { delayTicks = delayTicks or MC.FireTickDelay(), kind = Kind.SCHEDULED } }
end

-- ScheduleBlockTick only deduplicates when the new due tick is not earlier than
-- the pending one. A neighbour update re-rolling 30..39 would therefore keep
-- pulling the burnout tick earlier, so every nearby block change made fire tick
-- faster than Minecraft does. Arming from the neighbour path uses the longest
-- delay: it still arms fire that has no tick yet, and can never outbid one.
local MAX_TICK_DELAY = 39

local function stateAge( stateId )
	return math.floor( tonumber( MC.GetStateProperty and MC.GetStateProperty( stateId, "age" ) ) or 0 )
end

--------------------------------------------------------------------- normal fire

-- BaseFireBlock#updateShape. A neighbour change is also what the transaction
-- posts for the fire's own cell right after it is placed, so this doubles as
-- "arm the burnout timer for freshly lit fire".
local function fireNeighborUpdate( context )
	if not MC.FireCanSurvive( context.bx, context.by, context.bz ) then
		return removeFire( context )
	end
	if not fireTickEnabled() then return nil end
	return { schedule = burnoutSchedule( MAX_TICK_DELAY ) }
end

-- FireBlock#tick, minus spread and rain.
local function fireScheduledTick( context )
	local bx, by, bz = context.bx, context.by, context.bz
	-- canSurvive, isValidFireLocation and the age-15 roll all ask about the same
	-- neighbourhood. Sample it once: each blockNameAt is a state read plus a
	-- schema lookup, and doing it three times per fire per tick was most of what
	-- this handler cost.
	local sturdyBelow = MC.FireTopFaceSturdyAt( bx, by, bz - 1 )
	local validLocation = MC.FireIsValidLocation( bx, by, bz )
	if not sturdyBelow and not validLocation then return removeFire( context ) end
	if not fireTickEnabled() then return nil end

	local age = stateAge( context.stateId )
	-- age + random.nextInt(3) / 2 in Java integer division: 0, 0 or 1.
	local nextAge = math.min( MAX_AGE, age + math.floor( math.random( 0, 2 ) / 2 ) )
	local aged = nil
	if nextAge ~= age and MC.StateWith then
		local nextState = MC.StateWith( context.stateId, "age", nextAge )
		if nextState and nextState ~= context.stateId then
			aged = { { bx = bx, by = by, bz = bz, stateId = nextState } }
		end
	end

	-- Nothing adjacent to burn: sturdy ground keeps young fire alive, but once
	-- it has aged past UNFED_SURVIVE_AGE it goes out regardless.
	if not validLocation then
		if not sturdyBelow or age > UNFED_SURVIVE_AGE then
			return removeFire( context )
		end
		return { cells = aged, schedule = burnoutSchedule(), blockUpdates = false }
	end

	-- Fully aged fire over non-burnable ground has a 1-in-4 chance to go out.
	if age == MAX_AGE and math.random( 4 ) == 1 and not MC.FireIsFlammableAt( bx, by, bz - 1 ) then
		return removeFire( context )
	end

	-- Ageing is bookkeeping: fire looks and behaves the same at every age, and
	-- nothing outside this handler reads it. Minecraft writes it with flag 4 for
	-- exactly that reason, so suppress the neighbour fan-out here too -- without
	-- this, every age step posted seven neighbour updates, and the one landing
	-- back on the fire itself re-armed its own tick.
	return { cells = aged, schedule = burnoutSchedule(), blockUpdates = false }
end

----------------------------------------------------------------------- soul fire

-- SoulFireBlock never ages: it burns as long as its base survives, so it only
-- needs the survival half.
local function soulFireNeighborUpdate( context )
	if MC.SoulFireCanSurvive( context.bx, context.by, context.bz ) then return nil end
	return removeFire( context )
end

MC.RegisterBlockUpdateHandler( FIRE, {
	OnNeighborUpdate = fireNeighborUpdate,
	OnScheduledTick = fireScheduledTick,
} )

MC.RegisterBlockUpdateHandler( SOUL_FIRE, {
	OnNeighborUpdate = soulFireNeighborUpdate,
} )
