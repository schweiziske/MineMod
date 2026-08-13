--[[----------------------------------------------------------------------------
	MC ItemStack value operations.

	Stacks are plain serializable tables.  Empty slots are represented by nil;
	all public helpers also accept minecraft:air/count=0 inputs and normalize
	them to nil.  Components are bounded JSON-like data, the GLua equivalent of
	Minecraft's data component patch/NBT payload.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ItemComponentLimits = MC.ItemComponentLimits or {
	maxDepth = 8,
	maxEntries = 256,
	maxStringBytes = 4096,
	maxEncodedBytes = 16384,
}

local function copyPlainValue( value, state, depth )
	local valueType = type( value )
	if valueType == "nil" or valueType == "boolean" then return value end
	if valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return nil, "invalid_component_number" end
		return value
	end
	if valueType == "string" then
		if #value > state.limits.maxStringBytes then return nil, "component_string_too_long" end
		return value
	end
	if valueType ~= "table" then return nil, "invalid_component_type" end
	if depth >= state.limits.maxDepth then return nil, "component_depth_exceeded" end
	if state.seen[value] then return nil, "component_cycle" end

	state.seen[value] = true
	local output = {}
	for key, item in pairs( value ) do
		local keyType = type( key )
		if keyType ~= "string" and keyType ~= "number" then
			state.seen[value] = nil
			return nil, "invalid_component_key"
		end
		if keyType == "number" and ( key ~= key or key == math.huge or key == -math.huge or math.floor( key ) ~= key ) then
			state.seen[value] = nil
			return nil, "invalid_component_key"
		end
		state.entries = state.entries + 1
		if state.entries > state.limits.maxEntries then
			state.seen[value] = nil
			return nil, "component_entries_exceeded"
		end
		local copied, err = copyPlainValue( item, state, depth + 1 )
		if err then
			state.seen[value] = nil
			return nil, err
		end
		output[key] = copied
	end
	state.seen[value] = nil
	return output
end

local function canonicalValue( value, output, state, depth )
	local valueType = type( value )
	if valueType == "nil" then output[#output + 1] = "n" return true end
	if valueType == "boolean" then output[#output + 1] = value and "b1" or "b0" return true end
	if valueType == "number" then output[#output + 1] = "d" .. string.format( "%.17g", value ) return true end
	if valueType == "string" then output[#output + 1] = "s" .. #value .. ":" .. value return true end
	if valueType ~= "table" or depth >= MC.ItemComponentLimits.maxDepth or state.seen[value] then return false end

	state.seen[value] = true
	local keys = {}
	for key in pairs( value ) do keys[#keys + 1] = key end
	table.sort( keys, function( a, b )
		local ta, tb = type( a ), type( b )
		if ta ~= tb then return ta < tb end
		return a < b
	end )
	output[#output + 1] = "t" .. #keys .. "{"
	for _, key in ipairs( keys ) do
		if not canonicalValue( key, output, state, depth + 1 )
		or not canonicalValue( value[key], output, state, depth + 1 ) then
			state.seen[value] = nil
			return false
		end
	end
	output[#output + 1] = "}"
	state.seen[value] = nil
	return true
end

function MC.CopyItemComponents( components )
	if components == nil then return nil end
	if type( components ) ~= "table" then return nil, "invalid_components" end
	local state = { limits = MC.ItemComponentLimits, seen = {}, entries = 0 }
	local copied, err = copyPlainValue( components, state, 0 )
	if not copied then return nil, err end
	local encoded = MC.CanonicalItemComponents( copied )
	if not encoded then return nil, "component_encode_failed" end
	if #encoded > MC.ItemComponentLimits.maxEncodedBytes then return nil, "component_payload_too_large" end
	if next( copied ) == nil then return nil end
	return copied
end

function MC.CanonicalItemComponents( components )
	if components == nil then return "" end
	local output = {}
	if not canonicalValue( components, output, { seen = {} }, 0 ) then return nil end
	return table.concat( output )
end

function MC.ItemComponentsEqual( left, right )
	if left == right then return true end
	return MC.CanonicalItemComponents( left ) == MC.CanonicalItemComponents( right )
end

function MC.IsEmptyItemStack( stack )
	return type( stack ) ~= "table" or ( tonumber( stack.count ) or 0 ) <= 0
		or stack.item == nil or stack.item == "minecraft:air" or stack.item == "air"
end

function MC.NormalizeItemStack( input, options )
	options = options or {}
	if input == nil then return nil end
	if type( input ) == "string" then input = { item = input, count = 1 } end
	if type( input ) ~= "table" then return nil, "invalid_stack" end

	local definition = MC.GetItem and MC.GetItem( input.item or input.id or input.name ) or nil
	if not definition then return nil, "unknown_item" end
	if definition.name == "minecraft:air" then return nil end

	local count = tonumber( input.count )
	if count == nil then count = 1 end
	if math.floor( count ) ~= count then return nil, "invalid_count" end
	count = math.floor( count )
	if count <= 0 then return nil end
	local maxStack = definition.maxStack or 64
	if count > maxStack and options.allowOversized ~= true then return nil, "stack_too_large" end
	if count > ( MC.ItemAbsoluteMaxStack or 99 ) then return nil, "stack_absolute_limit" end

	local damage = tonumber( input.damage ) or 0
	if math.floor( damage ) ~= damage or damage < 0 then return nil, "invalid_damage" end
	damage = math.floor( damage )
	if definition.maxDamage <= 0 and damage ~= 0 then return nil, "item_not_damageable" end
	if definition.maxDamage > 0 and damage > definition.maxDamage then return nil, "damage_exceeded" end

	local components, componentError = MC.CopyItemComponents( input.components )
	if componentError then return nil, componentError end
	return {
		item = definition.name,
		count = count,
		damage = damage > 0 and damage or nil,
		components = components,
	}
end

function MC.NewItemStack( item, count, components, damage )
	return MC.NormalizeItemStack( {
		item = item,
		count = count or 1,
		components = components,
		damage = damage,
	} )
end

function MC.CopyItemStack( stack, count )
	if MC.IsEmptyItemStack( stack ) then return nil end
	return {
		item = stack.item,
		count = count ~= nil and math.floor( tonumber( count ) or 0 ) or stack.count,
		damage = stack.damage,
		components = MC.CopyItemComponents( stack.components ),
	}
end

function MC.ItemStackMaxCount( stack )
	if MC.IsEmptyItemStack( stack ) then return 0 end
	local definition = MC.GetItem and MC.GetItem( stack.item ) or nil
	return definition and definition.maxStack or 0
end

function MC.ItemStackMaxDamage( stack )
	if MC.IsEmptyItemStack( stack ) then return 0 end
	local definition = MC.GetItem and MC.GetItem( stack.item ) or nil
	return definition and definition.maxDamage or 0
end

function MC.ItemStacksEqual( left, right, ignoreCount )
	if MC.IsEmptyItemStack( left ) then return MC.IsEmptyItemStack( right ) end
	if MC.IsEmptyItemStack( right ) then return false end
	if left.item ~= right.item or ( tonumber( left.damage ) or 0 ) ~= ( tonumber( right.damage ) or 0 ) then return false end
	if not ignoreCount and left.count ~= right.count then return false end
	return MC.ItemComponentsEqual( left.components, right.components )
end

function MC.ItemStacksCanMerge( left, right )
	return not MC.IsEmptyItemStack( left ) and not MC.IsEmptyItemStack( right )
		and MC.ItemStacksEqual( left, right, true )
end

function MC.SplitItemStack( stack, amount )
	if MC.IsEmptyItemStack( stack ) then return nil, nil end
	amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if amount <= 0 then return MC.CopyItemStack( stack ), nil end
	local taken = math.min( stack.count, amount )
	local extracted = MC.CopyItemStack( stack, taken )
	local remainingCount = stack.count - taken
	local remaining = remainingCount > 0 and MC.CopyItemStack( stack, remainingCount ) or nil
	return remaining, extracted
end

function MC.ItemStackWithCount( stack, count )
	count = math.floor( tonumber( count ) or 0 )
	if MC.IsEmptyItemStack( stack ) or count <= 0 then return nil end
	if count > MC.ItemStackMaxCount( stack ) then return nil, "stack_too_large" end
	return MC.CopyItemStack( stack, count )
end

function MC.ItemStackHash( stack )
	if MC.IsEmptyItemStack( stack ) then return "0" end
	local canonical = table.concat( {
		stack.item,
		tostring( stack.count ),
		tostring( stack.damage or 0 ),
		MC.CanonicalItemComponents( stack.components ) or "",
	}, "\0" )
	return util and util.CRC and util.CRC( canonical ) or canonical
end

-- ItemStack.hasFoil() in Java 26.2.  The explicit component is intentionally
-- checked before every fallback: `false` is not the same as absence and must
-- suppress enchantments as well as an item's built-in foil state.
local DEFAULT_FOIL_ITEMS = {
	["minecraft:enchanted_golden_apple"] = true,
	["minecraft:experience_bottle"] = true,
	["minecraft:written_book"] = true,
	["minecraft:nether_star"] = true,
	["minecraft:enchanted_book"] = true,
	["minecraft:end_crystal"] = true,
	["minecraft:debug_stick"] = true,
}

local function stackComponentPresence( stack, key )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil, false end
	if components[key] ~= nil then return components[key], true end
	if string.find( key, ":", 1, true ) == nil then
		local namespaced = "minecraft:" .. key
		if components[namespaced] ~= nil then return components[namespaced], true end
	end
	return nil, false
end

local function enchantmentLevelPresent( value )
	if type( value ) == "number" then return value > 0 end
	if type( value ) ~= "table" then return false end
	local level = tonumber( value.level or value.lvl )
	if level then return level > 0 end
	for key, entry in pairs( value ) do
		if key ~= "show_in_tooltip" and key ~= "showInTooltip" and enchantmentLevelPresent( entry ) then
			return true
		end
	end
	return false
end

function MC.ItemStackHasFoil( stack )
	if MC.IsEmptyItemStack( stack ) then return false end
	local override, hasOverride = stackComponentPresence( stack, "enchantment_glint_override" )
	if hasOverride and type( override ) == "boolean" then return override end

	local enchantments = select( 1, stackComponentPresence( stack, "enchantments" ) )
	if type( enchantments ) == "table" then
		local levels = type( enchantments.levels ) == "table" and enchantments.levels or enchantments
		if enchantmentLevelPresent( levels ) then return true end
	end

	local item = tostring( stack.item or "" )
	if not string.find( item, ":", 1, true ) then item = "minecraft:" .. item end
	if DEFAULT_FOIL_ITEMS[item] then return true end
	if item == "minecraft:compass" then
		local _, hasLodestoneTracker = stackComponentPresence( stack, "lodestone_tracker" )
		if hasLodestoneTracker then return true end
	end
	return false
end

function MC.ItemStackToData( stack )
	return MC.CopyItemStack( stack )
end

function MC.ItemStackFromData( data )
	return MC.NormalizeItemStack( data )
end
