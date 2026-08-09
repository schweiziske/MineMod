--[[----------------------------------------------------------------------------
	MC item registry.

	Minecraft keeps blocks and items in separate registries.  A BlockItem points
	at a block, but an ItemStack always stores the item identity.  Keeping that
	boundary here prevents inventory data from inheriting legacy block IDs.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ItemAbsoluteMaxStack = 99
MC.PendingItems = MC.PendingItems or {}
MC.Items = MC.Items or {}
MC.ItemsByRuntimeId = MC.ItemsByRuntimeId or {}
MC.ItemsByBlockId = MC.ItemsByBlockId or {}
MC.ItemRegistryFrozen = MC.ItemRegistryFrozen or false
MC.ItemRegistryHash = MC.ItemRegistryHash or nil

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" )
end

local function normalizeName( value )
	local name = string.lower( trim( value ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	if not string.match( name, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return name
end

local function copyList( source )
	local result = {}
	for index, value in ipairs( source or {} ) do result[index] = tostring( value ) end
	return result
end

local function normalizedInteger( value, minimum, maximum, fallback )
	value = tonumber( value )
	if value == nil then return fallback end
	value = math.floor( value )
	if value < minimum or value > maximum then return nil end
	return value
end

function MC.NormalizeItemName( value )
	return normalizeName( value )
end

function MC.RegisterItem( definition )
	if MC.ItemRegistryFrozen then return nil, "registry_frozen" end
	if type( definition ) ~= "table" then return nil, "invalid_definition" end

	local name = normalizeName( definition.name or definition.id )
	if not name then return nil, "invalid_item_name" end
	if #name > 128 then return nil, "item_name_too_long" end
	if MC.PendingItems[name] then return nil, "duplicate_item" end

	local maxStack = normalizedInteger( definition.maxStack, 1, MC.ItemAbsoluteMaxStack, 64 )
	if not maxStack then return nil, "invalid_max_stack" end
	local maxDamage = normalizedInteger( definition.maxDamage, 0, 16777215, 0 )
	if not maxDamage then return nil, "invalid_max_damage" end
	if maxDamage > 0 then maxStack = 1 end

	local blockName = definition.block ~= nil and normalizeName( definition.block ) or nil
	if definition.block ~= nil and not blockName then return nil, "invalid_block_item" end
	local texture = trim( definition.texture )
	if texture == "" then texture = nil end
	if texture and not string.match( texture, "^[a-zA-Z0-9_./-]+$" ) then return nil, "invalid_item_texture" end

	local registered = {
		name = name,
		maxStack = maxStack,
		maxDamage = maxDamage,
		blockName = blockName,
		texture = texture,
		model = trim( definition.model ) ~= "" and trim( definition.model ) or nil,
		displayName = trim( definition.displayName ) ~= "" and trim( definition.displayName ) or nil,
		rarity = string.lower( trim( definition.rarity ~= nil and definition.rarity or "common" ) ),
		kind = string.lower( trim( definition.kind ~= nil and definition.kind or ( blockName and "block" or "item" ) ) ),
		tags = copyList( definition.tags ),
		source = trim( definition.source ) ~= "" and trim( definition.source ) or nil,
	}

	if registered.rarity ~= "common" and registered.rarity ~= "uncommon"
	and registered.rarity ~= "rare" and registered.rarity ~= "epic" then
		return nil, "invalid_rarity"
	end

	MC.PendingItems[name] = registered
	return registered
end

local function resolveBlockItem( definition )
	local target = definition.blockName or definition.name
	local resolved = MC.ResolveBlock and MC.ResolveBlock( target ) or nil
	if not resolved or resolved.id == 0 then return end
	definition.blockName = resolved.mcid
	definition.blockId = resolved.id
	definition.kind = "block"
	MC.ItemsByBlockId[resolved.id] = definition
	if not definition.displayName and resolved.block then
		definition.displayName = MC.BlockDisplayName and MC.BlockDisplayName( resolved.block, resolved.block.dispZH or resolved.block.disp )
			or resolved.block.dispZH or resolved.block.disp
	end
end

function MC.FinalizeItemRegistry()
	if MC.ItemRegistryFrozen then return #MC.ItemsByRuntimeId end

	if not MC.PendingItems["minecraft:air"] then
		MC.PendingItems["minecraft:air"] = {
			name = "minecraft:air", maxStack = 64, maxDamage = 0,
			kind = "item", rarity = "common", tags = {},
		}
	end

	local names = {}
	for name in pairs( MC.PendingItems ) do
		if name ~= "minecraft:air" then names[#names + 1] = name end
	end
	table.sort( names )

	local ordered = { "minecraft:air" }
	for _, name in ipairs( names ) do ordered[#ordered + 1] = name end
	if #ordered > 65535 then return nil, "too_many_items" end

	local byName, byRuntime, byBlock = {}, {}, {}
	MC.ItemsByBlockId = byBlock
	for arrayIndex, name in ipairs( ordered ) do
		local definition = MC.PendingItems[name]
		local runtimeId = arrayIndex - 1
		definition.runtimeId = runtimeId
		byName[name] = definition
		byRuntime[runtimeId] = definition
		if name ~= "minecraft:air" then resolveBlockItem( definition ) end
	end

	MC.Items = byName
	MC.ItemsByRuntimeId = byRuntime
	MC.ItemsByBlockId = byBlock

	local canonical = { "mc-item-registry-v1\n" }
	for runtimeId = 0, #ordered - 1 do
		local definition = byRuntime[runtimeId]
		canonical[#canonical + 1] = table.concat( {
			definition.name,
			tostring( definition.maxStack ),
			tostring( definition.maxDamage ),
			tostring( definition.blockName or "" ),
			tostring( definition.texture or "" ),
			tostring( definition.kind or "item" ),
		}, "\0" ) .. "\n"
	end
	canonical = table.concat( canonical )
	MC.ItemRegistryHash = util and util.SHA256 and util.SHA256( canonical )
		or util and util.CRC and util.CRC( canonical ) or canonical
	MC.ItemRegistryFrozen = true
	return #ordered
end

function MC.GetItem( value )
	if type( value ) == "table" and value.name then
		local name = normalizeName( value.name )
		return name and ( MC.Items[name] or MC.PendingItems[name] ) or nil
	end
	if type( value ) == "number" then
		return MC.ItemsByRuntimeId[math.floor( value )]
	end
	local name = normalizeName( value )
	return name and ( MC.Items[name] or MC.PendingItems[name] ) or nil
end

function MC.ResolveItem( value )
	local definition = MC.GetItem( value )
	if not definition then return nil end
	return {
		name = definition.name,
		runtimeId = definition.runtimeId,
		item = definition,
		blockId = definition.blockId,
	}
end

function MC.ItemForBlock( blockId )
	return MC.ItemsByBlockId[math.floor( tonumber( blockId ) or -1 )]
end

function MC.ItemForBlockState( stateId )
	local blockId = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	return blockId and MC.ItemForBlock( blockId ) or nil
end

function MC.ItemDisplayName( value )
	local definition = MC.GetItem( value )
	if not definition then return tostring( value or "" ) end
	if definition.displayName and definition.displayName ~= "" then return definition.displayName end
	if definition.blockId and MC.Blocks and MC.Blocks[definition.blockId] then
		local block = MC.Blocks[definition.blockId]
		return MC.BlockDisplayName and MC.BlockDisplayName( block, block.dispZH or block.disp ) or block.dispZH or block.disp
	end
	local path = string.match( definition.name, ":(.+)$" ) or definition.name
	return string.gsub( path, "_", " " )
end

function MC.ItemMaxStack( value )
	local definition = MC.GetItem( value )
	return definition and definition.maxStack or 0
end

function MC.ItemMaxDamage( value )
	local definition = MC.GetItem( value )
	return definition and definition.maxDamage or 0
end

if timer and timer.Simple then
	timer.Simple( 0, function()
		if not MC.ItemRegistryFrozen then
			local count, err = MC.FinalizeItemRegistry()
			if not count then
				local message = "[MC] item registry finalize failed: " .. tostring( err or "unknown" ) .. "\n"
				if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
			end
		end
	end )
end
