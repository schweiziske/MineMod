-- Shared Player#getDestroySpeed and BlockBehaviour#getDestroyProgress.
-- The client predicts with the same tools/tags; the server still owns writes,
-- permissions, drops, durability and authoritative status-effect overrides.
MC = MC or {}

local catalog = util.JSONToTable( MC.GeneratedMiningPayload, false, true )
MC.GeneratedMiningPayload = nil
assert( type( catalog ) == "table" and type( catalog.mineable ) == "table"
	and type( catalog.minimumTier ) == "table" and type( catalog.swordMining ) == "table"
	and type( catalog.shearsSpeed ) == "table",
	"[MC Mining] generated mining catalog failed to load" )
local TOOL_TIER = { wood = 0, gold = 0, stone = 1, copper = 1, iron = 2, diamond = 3, netherite = 4 }
local MODIFIER_KEYS = {
	miningEfficiency = true, digSpeedAmplifier = true, miningFatigueAmplifier = true,
	blockBreakSpeed = true, submergedMiningSpeed = true, eyeInWater = true, onGround = true,
}

local function enchantmentLevel( stack, enchantment )
	local components = stack and stack.components
	local value = components and ( components["minecraft:enchantments"] or components.enchantments )
	if type( value ) ~= "table" then return 0 end
	local levels = type( value.levels ) == "table" and value.levels or value
	local direct = tonumber( levels[enchantment] or levels[string.match( enchantment, ":(.+)$" ) or ""] )
	if direct then return math.max( 0, math.floor( direct ) ) end
	for _, entry in pairs( levels ) do
		if type( entry ) == "table" and ( entry.id == enchantment or entry.enchantment == enchantment ) then
			return math.max( 0, math.floor( tonumber( entry.level or entry.lvl ) or 0 ) )
		end
	end
	return 0
end

function MC.MiningStackFingerprint( stack )
	if MC.IsEmptyItemStack( stack ) then return "empty" end
	-- sameDestroyTarget compares item and components, not count or slot number.
	return table.concat( { stack.item, tostring( stack.damage or 0 ),
		MC.CanonicalItemComponents( stack.components ) }, "\0" )
end

function MC.BlockMiningToolSpec( stateId, stack )
	local blockId = MC.BlockTypeForState( stateId )
	local block = MC.Blocks[blockId]
	local name = block and block.mcid
	local held = MC.ItemToolSpec( stack )
	local shears = stack and stack.item == "minecraft:shears"
	local requiredType = catalog.mineable[name]
	local requiredTier = catalog.minimumTier[name] or 0
	local requiresCorrect = MC.BlockRequiresCorrectTool( blockId ) == true
	local heldTier = held and ( TOOL_TIER[held.material] or -1 ) or -1
	local specialCorrect = name == "minecraft:cobweb" and stack
		and ( stack.item == "minecraft:shears" or held and held.type == "sword" )
	return {
		block = name, requiresCorrectTool = requiresCorrect,
		requiredType = requiredType, requiredTier = requiredTier,
		held = held, heldTier = heldTier,
		correctForDrops = not requiresCorrect or specialCorrect == true
			or ( held and held.type == requiredType and heldTier >= requiredTier ) == true,
		shears = shears == true,
		damagePerBlock = shears and name ~= "minecraft:fire" and name ~= "minecraft:soul_fire" and 1
			or held and held.damagePerBlock or 0,
	}
end

local function mergeModifiers( target, source )
	if type( source ) == "table" then
		for key in pairs( MODIFIER_KEYS ) do
			if source[key] ~= nil then target[key] = source[key] end
		end
	end
	return target
end

function MC.BlockMiningSpeed( stateId, stack, ply, overrides )
	local mining = MC.BlockMiningToolSpec( stateId, stack )
	if not mining.block then return nil, "unknown_block" end
	local speed, held = 1, mining.held
	if mining.shears then
		speed = catalog.shearsSpeed[mining.block] or 1
	elseif held and held.type == "sword" then
		if mining.block == "minecraft:cobweb" then speed = 15
		elseif catalog.swordMining.instantlyMines[mining.block] then speed = 3.402823466e38
		elseif catalog.swordMining.efficient[mining.block] then speed = 1.5 end
	elseif held and mining.requiredType == held.type then
		speed = held.miningSpeed or 1
	end
	local efficiency = enchantmentLevel( stack, "minecraft:efficiency" )
	local modifiers = {
		miningEfficiency = efficiency > 0 and efficiency * efficiency + 1 or 0,
		blockBreakSpeed = 1, submergedMiningSpeed = 0.2,
		eyeInWater = IsValid( ply ) and ply:WaterLevel() >= 3 or false,
		onGround = not IsValid( ply ) or ply:IsOnGround(),
	}
	if MC.RunEvent then
		mergeModifiers( modifiers, MC.RunEvent( "MC.PlayerMiningModifiers", ply, stateId, stack, table.Copy( modifiers ) ) )
	end
	mergeModifiers( modifiers, overrides )
	if speed > 1 then speed = speed + math.max( 0, tonumber( modifiers.miningEfficiency ) or 0 ) end
	local haste = tonumber( modifiers.digSpeedAmplifier )
	if haste and haste >= 0 then speed = speed * ( 1 + ( math.floor( haste ) + 1 ) * 0.2 ) end
	local fatigue = tonumber( modifiers.miningFatigueAmplifier )
	if fatigue and fatigue >= 0 then
		fatigue = math.floor( fatigue )
		speed = speed * ( fatigue == 0 and 0.3 or fatigue == 1 and 0.09 or fatigue == 2 and 0.0027 or 0.00081 )
	end
	speed = speed * math.max( 0, tonumber( modifiers.blockBreakSpeed ) or 1 )
	if modifiers.eyeInWater then speed = speed * math.max( 0, tonumber( modifiers.submergedMiningSpeed ) or 0.2 ) end
	if modifiers.onGround == false then speed = speed / 5 end
	return speed, nil, mining, modifiers
end

function MC.BlockMiningProgressPerTick( stateId, stack, ply, overrides )
	local blockId = MC.BlockTypeForState( stateId )
	if not blockId or not MC.Blocks[blockId] then return nil, "unknown_block" end
	local hardness = MC.BlockHardness( blockId )
	if hardness < 0 then return nil, "unbreakable" end
	local speed, err, mining, modifiers = MC.BlockMiningSpeed( stateId, stack, ply, overrides )
	if not speed then return nil, err end
	if hardness == 0 then return 1, nil, mining, modifiers end
	return speed / hardness / ( mining.correctForDrops and 30 or 100 ), nil, mining, modifiers
end
