-- Shared wire state and deterministic hotbar operations. World targets and
-- creative permissions are resolved/validated by the server, never by the UI.
MC = MC or {}

MC.InventoryProtocolVersion = 3
MC.InventoryBackgroundAction = 65535

function MC.InventorySelectionIsNewer( value, previous )
	local distance = ( value - previous ) % 4294967296
	return distance > 0 and distance < 2147483648
end

function MC.InventoryActionIsNewer( value, previous )
	if previous == nil or previous == MC.InventoryBackgroundAction then return true end
	local distance = ( value - previous ) % MC.InventoryBackgroundAction
	return distance > 0 and distance <= 32767
end

function MC.MutateCreativeInventory( container, targetSlot, stack )
	if targetSlot == -3 then return true end -- catalog throw; no stored item is consumed
	if targetSlot == -2 then
		for _, slot in ipairs( container.slots ) do
			local ok, err = MC.InventorySlotSet( slot, nil )
			if not ok then return false, err end
		end
		return MC.ContainerSetCursor( container, nil )
	end
	if targetSlot >= 0 then return MC.ContainerSetStack( container, targetSlot, stack ) end
	return MC.ContainerSetCursor( container, stack )
end

function MC.WriteInventoryQuickCraftNet( quick )
	local indices = {}
	for index in pairs( quick.slots ) do indices[#indices + 1] = index end
	table.sort( indices )
	net.WriteUInt( quick.status, 2 )
	net.WriteUInt( quick.type, 2 )
	net.WriteUInt( #indices, 7 )
	for _, index in ipairs( indices ) do net.WriteUInt( index, 7 ) end
end

function MC.ReadInventoryQuickCraftNet( slotCount )
	local status, craftType, count = net.ReadUInt( 2 ), net.ReadUInt( 2 ), net.ReadUInt( 7 )
	local slots, err = {}, nil
	if status > 1 or craftType > 2 or count > slotCount then err = "invalid_quick_craft_state" end
	for _ = 1, count do
		local index = net.ReadUInt( 7 )
		if index >= slotCount or slots[index] then err = "invalid_quick_craft_slot" end
		slots[index] = true
	end
	if err then return nil, err end
	return { status = status, type = craftType, slots = slots }
end

local PICK_BLOCK_ALIASES = {
	["minecraft:wall_torch"] = "minecraft:torch",
	["minecraft:redstone_wall_torch"] = "minecraft:redstone_torch",
	["minecraft:soul_wall_torch"] = "minecraft:soul_torch",
	["minecraft:redstone_wire"] = "minecraft:redstone",
	["minecraft:tripwire"] = "minecraft:string",
}

function MC.InventoryPickStackForState( stateId )
	local definition = MC.ItemForBlockState( stateId )
	if not definition then
		local name = MC.API.Blocks.Name( stateId )
		local itemName = PICK_BLOCK_ALIASES[name]
		if not itemName and name then
			itemName = string.gsub( name, "_wall_hanging_sign$", "_hanging_sign" )
			itemName = string.gsub( itemName, "_wall_sign$", "_sign" )
			itemName = string.gsub( itemName, "_wall_banner$", "_banner" )
			itemName = string.gsub( itemName, "_wall_head$", "_head" )
			itemName = string.gsub( itemName, "_wall_skull$", "_skull" )
		end
		definition = itemName and MC.GetItem( itemName ) or nil
	end
	if not definition or definition.name == "minecraft:air" then return nil end
	return MC.CopyItemStack( { item = definition.name, count = 1 } )
end

local function enchanted( stack )
	local components = stack and stack.components
	local enchantments = components and ( components["minecraft:enchantments"] or components.enchantments )
	return type( enchantments ) == "table" and next( enchantments ) ~= nil
end

function MC.InventorySuitableHotbarSlot( container, selected )
	for offset = 0, 8 do
		local index = ( selected + offset ) % 9
		if MC.IsEmptyItemStack( MC.ContainerGetStack( container, index ) ) then return index end
	end
	for offset = 0, 8 do
		local index = ( selected + offset ) % 9
		if not enchanted( MC.ContainerGetStack( container, index ) ) then return index end
	end
	return selected
end

-- Inventory.findSlotMatchingItem / pickSlot / addAndPickItem (Java 26.2).
function MC.PickInventoryStack( container, selected, target, creative )
	if MC.IsEmptyItemStack( target ) then return true, selected end
	local found
	for index = 0, 35 do
		if MC.ItemStacksCanMerge( MC.ContainerGetStack( container, index ), target ) then found = index break end
	end
	if found and found < 9 then return true, found end
	if not found and creative ~= true then return true, selected end
	local destination = MC.InventorySuitableHotbarSlot( container, selected )
	local displaced = MC.ContainerGetStack( container, destination )
	local picked = found and MC.ContainerGetStack( container, found ) or target
	if found then
		local ok, err = MC.ContainerSetStack( container, found, displaced )
		if not ok then return false, selected, err end
	elseif not MC.IsEmptyItemStack( displaced ) then
		for index = 0, 35 do
			if MC.IsEmptyItemStack( MC.ContainerGetStack( container, index ) ) then
				local ok, err = MC.ContainerSetStack( container, index, displaced )
				if not ok then return false, selected, err end
				break
			end
		end
	end
	local ok, err = MC.ContainerSetStack( container, destination, picked )
	if not ok then return false, selected, err end
	return true, destination
end

-- A drag preview is a projection, not a stack mutation. The terminal
-- QUICK_CRAFT packet remains the only operation that distributes the items.
function MC.InventoryQuickCraftPreview( container )
	local quick, carried = container.quickCraft, container.cursor
	if quick.status ~= 1 or MC.IsEmptyItemStack( carried ) then return nil end
	local count = 0
	for _ in pairs( quick.slots ) do count = count + 1 end
	if count == 0 then return nil end
	local each = quick.type == 0 and math.floor( carried.count / count )
		or quick.type == 1 and 1 or MC.ItemStackMaxCount( carried )
	local preview, remaining = {}, carried.count
	for index in pairs( quick.slots ) do
		local slot = MC.ContainerGetSlot( container, index )
		local existing = MC.InventorySlotGet( slot )
		local before = existing and existing.count or 0
		local after = math.min( before + each, MC.InventorySlotLimit( slot, carried ) )
		preview[index] = MC.CopyItemStack( carried, after )
		remaining = remaining - ( after - before )
	end
	local cursor
	if quick.type == 2 then cursor = MC.CopyItemStack( carried, MC.ItemStackMaxCount( carried ) )
	elseif remaining > 0 then cursor = MC.CopyItemStack( carried, remaining ) end
	return { slots = preview, cursor = cursor }
end
