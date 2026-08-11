-- Server-side Minecraft block loot evaluation. The source tables and mining
-- tags are generated from the bundled vanilla data, not maintained by hand.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local payload = MC.GeneratedBlockLootPayload
MC.GeneratedBlockLootPayload = nil

local catalog = type( payload ) == "string" and util.JSONToTable( payload, false, true ) or nil
if type( catalog ) ~= "table" then
	ErrorNoHalt( "[MC Loot] generated block loot catalog failed to load\n" )
end
SV.BlockLootCatalog = catalog

local TOOL_TIER = { wood = 0, gold = 0, stone = 1, copper = 1, iron = 2, diamond = 3, netherite = 4 }
local warned = {}

local function warnOnce( key, message )
	if warned[key] then return end
	warned[key] = true
	ErrorNoHalt( "[MC Loot] " .. message .. "\n" )
end

local function blockNameForState( stateId )
	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = blockId and MC.Blocks and MC.Blocks[blockId] or nil
	return block and block.mcid or nil, blockId
end

local function enchantmentLevel( stack, enchantment )
	local components = stack and stack.components
	local value = components and ( components["minecraft:enchantments"] or components.enchantments ) or nil
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

function MC.BlockMiningToolSpec( stateId, stack )
	local blockName, blockId = blockNameForState( stateId )
	local heldTool = MC.ItemToolSpec and MC.ItemToolSpec( stack ) or nil
	local requiredType = catalog and catalog.mineable and catalog.mineable[blockName] or nil
	local requiredTier = catalog and catalog.minimumTier and tonumber( catalog.minimumTier[blockName] ) or 0
	local requiresCorrect = MC.BlockRequiresCorrectTool and MC.BlockRequiresCorrectTool( blockId ) == true
	local heldTier = heldTool and ( TOOL_TIER[heldTool.material] or -1 ) or -1
	-- Cobweb is the vanilla exception defined by SwordItem/ShearsItem rather
	-- than the mineable block tags used by ordinary tools.
	local specialCorrect = blockName == "minecraft:cobweb" and stack
		and ( stack.item == "minecraft:shears" or heldTool and heldTool.type == "sword" )
	local correct = not requiresCorrect or specialCorrect == true
		or ( heldTool and heldTool.type == requiredType and heldTier >= requiredTier ) == true
	return {
		block = blockName,
		requiresCorrectTool = requiresCorrect,
		requiredType = requiredType,
		requiredTier = requiredTier,
		held = heldTool,
		heldTier = heldTier,
		correctForDrops = correct,
	}
end

local function testRange( value, range )
	value = tonumber( value ) or 0
	if type( range ) == "number" then return value == range end
	if type( range ) ~= "table" then return false end
	return ( range.min == nil or value >= tonumber( range.min ) )
		and ( range.max == nil or value <= tonumber( range.max ) )
end

local testCondition

local function matchTool( predicate, context )
	predicate = predicate or {}
	local stack = context.tool
	if predicate.items ~= nil then
		local matched = false
		local items = type( predicate.items ) == "table" and predicate.items or { predicate.items }
		for _, item in ipairs( items ) do
			if type( item ) == "string" and string.sub( item, 1, 1 ) == "#" then
				local members = catalog and catalog.itemTags and catalog.itemTags[string.sub( item, 2 )]
				if stack and members and members[stack.item] then matched = true break end
			elseif stack and stack.item == item then
				matched = true
				break
			end
		end
		if not matched then return false end
	end
	local predicates = predicate.predicates
	local enchantments = type( predicates ) == "table" and predicates["minecraft:enchantments"] or nil
	for _, requirement in ipairs( enchantments or {} ) do
		local names = requirement.enchantments
		if type( names ) ~= "table" then names = { names } end
		local matched = false
		for _, name in ipairs( names ) do
			if testRange( enchantmentLevel( stack, name ), requirement.levels or { min = 1 } ) then matched = true break end
		end
		if not matched then return false end
	end
	return true
end

testCondition = function( condition, context )
	if type( condition ) ~= "table" then return true end
	local kind = condition.condition
	if kind == "minecraft:survives_explosion" then return true end
	if kind == "minecraft:match_tool" then return matchTool( condition.predicate, context ) end
	if kind == "minecraft:inverted" then return not testCondition( condition.term, context ) end
	if kind == "minecraft:any_of" then
		for _, term in ipairs( condition.terms or {} ) do if testCondition( term, context ) then return true end end
		return false
	end
	if kind == "minecraft:random_chance" then return math.Rand( 0, 1 ) < ( tonumber( condition.chance ) or 0 ) end
	if kind == "minecraft:table_bonus" then
		local level = enchantmentLevel( context.tool, condition.enchantment or "minecraft:fortune" )
		local chances = condition.chances or {}
		return math.Rand( 0, 1 ) < ( tonumber( chances[math.min( level + 1, #chances )] ) or 0 )
	end
	if kind == "minecraft:block_state_property" then
		if condition.block and condition.block ~= context.block then return false end
		for property, wanted in pairs( condition.properties or {} ) do
			local actual = MC.GetStateProperty and MC.GetStateProperty( context.stateId, property ) or nil
			if tostring( actual ) ~= tostring( wanted ) then return false end
		end
		return true
	end
	if kind == "minecraft:entity_properties" then
		return type( condition.predicate ) == "table" and next( condition.predicate ) == nil
	end
	if kind == "minecraft:location_check" then
		local predicate = condition.predicate or {}
		local blockPredicate = predicate.block
		if type( blockPredicate ) ~= "table" then return true end
		local bx = ( context.bx or 0 ) + math.floor( tonumber( condition.offsetX ) or 0 )
		local by = ( context.by or 0 ) + math.floor( tonumber( condition.offsetY ) or 0 )
		local bz = ( context.bz or 0 ) + math.floor( tonumber( condition.offsetZ ) or 0 )
		local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
		local actualName = blockNameForState( stateId )
		local wantedBlocks = type( blockPredicate.blocks ) == "table" and blockPredicate.blocks or { blockPredicate.blocks }
		if blockPredicate.blocks ~= nil then
			local matched = false
			for _, wanted in ipairs( wantedBlocks ) do if actualName == wanted then matched = true break end end
			if not matched then return false end
		end
		for property, wanted in pairs( blockPredicate.state or {} ) do
			local actual = MC.GetStateProperty and MC.GetStateProperty( stateId, property ) or nil
			if tostring( actual ) ~= tostring( wanted ) then return false end
		end
		return true
	end
	warnOnce( "condition:" .. tostring( kind ), "unsupported condition " .. tostring( kind ) .. "; treating it as failed" )
	return false
end

local function conditionsPass( conditions, context )
	for _, condition in ipairs( conditions or {} ) do
		if not testCondition( condition, context ) then return false end
	end
	return true
end

local function numberProvider( provider )
	if type( provider ) == "number" then return provider end
	if type( provider ) ~= "table" then return tonumber( provider ) or 0 end
	local kind = provider.type
	if kind == "minecraft:uniform" then
		local minimum, maximum = numberProvider( provider.min ), numberProvider( provider.max )
		return math.random( math.floor( minimum ), math.floor( maximum ) )
	end
	if kind == "minecraft:binomial" then
		local total, probability, value = math.floor( numberProvider( provider.n ) ), numberProvider( provider.p ), 0
		for _ = 1, total do if math.Rand( 0, 1 ) < probability then value = value + 1 end end
		return value
	end
	return tonumber( provider.value ) or 0
end

local function applyFunction( stack, fn, context )
	if type( stack ) ~= "table" or type( fn ) ~= "table" then return stack end
	if not conditionsPass( fn.conditions, context ) then return stack end
	local kind = fn["function"]
	if kind == "minecraft:explosion_decay" then return stack end
	if kind == "minecraft:set_count" then
		local count = math.floor( numberProvider( fn.count ) )
		stack.count = fn.add == true and stack.count + count or count
		return stack
	end
	if kind == "minecraft:limit_count" then
		local limit = fn.limit or {}
		stack.count = math.Clamp( stack.count, tonumber( limit.min ) or 0, tonumber( limit.max ) or stack.count )
		return stack
	end
	if kind == "minecraft:apply_bonus" then
		local level = enchantmentLevel( context.tool, fn.enchantment or "minecraft:fortune" )
		if level <= 0 then return stack end
		if fn.formula == "minecraft:ore_drops" then
			local bonus = math.max( 0, math.random( 0, level + 1 ) - 1 )
			stack.count = stack.count * ( bonus + 1 )
		elseif fn.formula == "minecraft:uniform_bonus_count" then
			stack.count = stack.count + math.random( 0, level * math.floor( tonumber( fn.parameters and fn.parameters.bonusMultiplier ) or 1 ) )
		elseif fn.formula == "minecraft:binomial_with_bonus_count" then
			local extra = math.floor( tonumber( fn.parameters and fn.parameters.extra ) or 0 )
			local probability = tonumber( fn.parameters and fn.parameters.probability ) or 0
			for _ = 1, level + extra do if math.Rand( 0, 1 ) < probability then stack.count = stack.count + 1 end end
		end
		return stack
	end
	if kind == "minecraft:copy_state" or kind == "minecraft:copy_components" then return stack end
	warnOnce( "function:" .. tostring( kind ), "unsupported function " .. tostring( kind ) .. "; leaving the stack unchanged" )
	return stack
end

local function applyFunctions( stack, functions, context )
	for _, fn in ipairs( functions or {} ) do stack = applyFunction( stack, fn, context ) end
	return stack
end

local function evaluateEntry( entry, context )
	if type( entry ) ~= "table" or not conditionsPass( entry.conditions, context ) then return nil, false end
	if entry.type == "minecraft:alternatives" then
		for _, child in ipairs( entry.children or {} ) do
			local stacks, selected = evaluateEntry( child, context )
			if selected then return stacks, true end
		end
		return {}, true
	end
	if entry.type == "minecraft:item" then
		local stack = MC.NewItemStack and MC.NewItemStack( entry.name, 1 ) or nil
		if not stack then
			warnOnce( "item:" .. tostring( entry.name ), "loot item is not registered: " .. tostring( entry.name ) )
			return {}, true
		end
		stack = applyFunctions( stack, entry.functions, context )
		return stack.count > 0 and { stack } or {}, true
	end
	if entry.type == "minecraft:dynamic" then return {}, true end
	warnOnce( "entry:" .. tostring( entry.type ), "unsupported entry " .. tostring( entry.type ) )
	return {}, true
end

local function appendStacks( output, stacks )
	for _, stack in ipairs( stacks or {} ) do
		local maximum = MC.ItemStackMaxCount and MC.ItemStackMaxCount( stack ) or 64
		local remaining = math.max( 0, math.floor( tonumber( stack.count ) or 0 ) )
		while remaining > 0 do
			local count = math.min( remaining, math.max( 1, maximum ) )
			output[#output + 1] = MC.CopyItemStack( stack, count )
			remaining = remaining - count
		end
	end
end

local function applyFunctionsToStacks( stacks, functions, context )
	for _, stack in ipairs( stacks or {} ) do applyFunctions( stack, functions, context ) end
	return stacks
end

function SV.ResolveBlockDrops( stateId, toolStack, context )
	context = context or {}
	local mining = MC.BlockMiningToolSpec( stateId, toolStack )
	if not mining.block then return {}, "unknown_block" end
	if not mining.correctForDrops then return {}, "incorrect_tool" end
	local lootTable = catalog and catalog.tables and catalog.tables[mining.block] or nil
	if not lootTable then return {}, "missing_loot_table" end
	context.stateId, context.block, context.tool = stateId, mining.block, toolStack
	local output = {}
	for _, pool in ipairs( lootTable.pools or {} ) do
		if conditionsPass( pool.conditions, context ) then
			local rolls = math.max( 0, math.floor( numberProvider( pool.rolls or 1 ) ) )
			for _ = 1, rolls do
				for _, entry in ipairs( pool.entries or {} ) do
					local stacks, selected = evaluateEntry( entry, context )
					if selected then
						applyFunctionsToStacks( stacks, pool.functions, context )
						applyFunctionsToStacks( stacks, lootTable.functions, context )
						appendStacks( output, stacks )
						break
					end
				end
			end
		end
	end
	return output, nil, mining
end
