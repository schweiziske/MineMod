--[[----------------------------------------------------------------------------
	Bounded ItemStack wire codec. Clients submit fixed inventory actions, never
	arbitrary stack payloads; this is for authoritative snapshots and deltas.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ItemStackRuntimeIdBits = 16
MC.ItemStackCountBits = 7
MC.ItemStackDamageBits = 24
MC.ItemStackComponentLengthBits = 15
MC.ItemStackNetComponentBytes = 16384

local function encodedComponents( components )
	if components == nil then return "" end
	local copied, err = MC.CopyItemComponents( components )
	if err then return nil, err end
	if copied == nil then return "" end
	local json = util and util.TableToJSON and util.TableToJSON( copied, false ) or nil
	if not json then return nil, "component_json_failed" end
	if #json > MC.ItemStackNetComponentBytes then return nil, "component_payload_too_large" end
	return json
end

function MC.WriteItemStackNet( stack )
	if MC.IsEmptyItemStack( stack ) then net.WriteBool( false ) return true end
	local normalized, err = MC.NormalizeItemStack( stack )
	if not normalized then return false, err end
	local definition = MC.GetItem( normalized.item )
	if not definition or definition.runtimeId == nil then return false, "item_registry_not_ready" end
	local components, componentError = encodedComponents( normalized.components )
	if not components then return false, componentError end

	net.WriteBool( true )
	net.WriteUInt( definition.runtimeId, MC.ItemStackRuntimeIdBits )
	net.WriteUInt( normalized.count, MC.ItemStackCountBits )
	net.WriteUInt( normalized.damage or 0, MC.ItemStackDamageBits )
	net.WriteUInt( #components, MC.ItemStackComponentLengthBits )
	if #components > 0 then net.WriteData( components, #components ) end
	return true
end

function MC.ReadItemStackNet()
	if not net.ReadBool() then return nil end
	local runtimeId = net.ReadUInt( MC.ItemStackRuntimeIdBits )
	local count = net.ReadUInt( MC.ItemStackCountBits )
	local damage = net.ReadUInt( MC.ItemStackDamageBits )
	local componentBytes = net.ReadUInt( MC.ItemStackComponentLengthBits )
	if componentBytes > MC.ItemStackNetComponentBytes then return nil, "component_payload_too_large" end
	local components
	if componentBytes > 0 then
		local json = net.ReadData( componentBytes )
		if type( json ) ~= "string" or #json ~= componentBytes then return nil, "component_payload_truncated" end
		components = util and util.JSONToTable and util.JSONToTable( json ) or nil
		if type( components ) ~= "table" then return nil, "component_json_invalid" end
	end
	local definition = MC.GetItem( runtimeId )
	if not definition then return nil, "unknown_runtime_item" end
	return MC.NormalizeItemStack( {
		item = definition.name,
		count = count,
		damage = damage,
		components = components,
	} )
end

function MC.InventoryDataStack( stack )
	return MC.ItemStackToData( stack )
end

function MC.InventoryStackFromData( data )
	return MC.ItemStackFromData( data )
end
