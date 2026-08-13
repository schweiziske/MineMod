--[[----------------------------------------------------------------------------
	Persistent, server-authoritative player inventories.

	The 36 non-equipment slots follow Minecraft Inventory: 0..8 hotbar and
	9..35 main storage. Armor/offhand live in a separate EntityEquipment-style
	table, matching the boundary used by the reference sources in out/.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local INVENTORY_SIZE = 36
local SAVE_VERSION = 1
local SAVE_ROOT = "mc/player_inventories"
local SAVE_INTERVAL = 30

SV.PlayerInventories = SV.PlayerInventories or {}

local function persistentEnabled()
	return not MC.Config.InventoryPersist or MC.Config.InventoryPersist:GetBool()
end

local function safeOwnerId( ply )
	if not IsValid( ply ) then return nil end
	local steamId = ply.SteamID64 and tostring( ply:SteamID64() or "" ) or ""
	if string.match( steamId, "^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$" ) then return steamId end
	if ply.IsBot and ply:IsBot() then return "bot_" .. tostring( ply:EntIndex() ) end
	return nil
end

local function finalPath( ownerId ) return SAVE_ROOT .. "/" .. ownerId .. ".json" end
local function tempPath( ownerId ) return SAVE_ROOT .. "/" .. ownerId .. "_tmp.json" end
local function backupPath( ownerId ) return SAVE_ROOT .. "/" .. ownerId .. "_backup.json" end

local function playerSlotDefinitions( storage )
	local definitions = {}
	for index = 0, INVENTORY_SIZE - 1 do
		definitions[#definitions + 1] = {
			index = index,
			storage = storage,
			storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
	end
	return definitions
end

local function playerHotbarIndices()
	local indices = {}
	for index = 0, 8 do indices[index + 1] = index end
	return indices
end

local function changedStackMap( container, changedSlots )
	local changed = {}
	for _, index in ipairs( changedSlots ) do changed[index] = MC.CopyItemStack( MC.ContainerGetStack( container, index ) ) end
	return changed
end

local function updateHeldNetwork( record, context )
	local ply = record and record.owner
	if not IsValid( ply ) then return end
	local selected = math.Clamp( math.floor( tonumber( record.selected ) or 0 ), 0, 8 )
	local stack = record.storage[selected + 1]
	local definition = stack and MC.GetItem( stack.item ) or nil
	ply:SetNWInt( "mc_inventory_selected", selected )
	ply:SetNWString( "mc_selected_item", definition and definition.name or "" )
	ply:SetNWInt( "mc_selected_item_count", stack and stack.count or 0 )
	ply:SetNWInt( "mc_selected_item_damage", stack and stack.damage or 0 )
	ply:SetNWInt( "mc_selected_item_runtime", definition and definition.runtimeId or 0 )
	ply:SetNWInt( "mc_selected_block", definition and definition.blockId or 0 )
	ply:SetNWBool( "mc_selected_item_foil", stack and MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) or false )
	if MC.RunEvent then
		MC.RunEvent( "MC.PlayerHeldItemChanged", ply, selected, MC.CopyItemStack( stack ), context or {} )
	end
end

SV.UpdatePlayerHeldNetwork = updateHeldNetwork

local function onContainerCommit( record, container, result, context )
	record.revision = container.revision
	record.dirty = true
	local selectedChanged = false
	for _, index in ipairs( result.changedSlots or {} ) do
		if index == record.selected then selectedChanged = true break end
	end
	if selectedChanged then updateHeldNetwork( record, context ) end
	if type( SV.PublishPlayerInventoryCommit ) == "function" then
		SV.PublishPlayerInventoryCommit( record, result, context or {} )
	end
end

local function normalizedEquipment( equipment )
	local result = {}
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		local stack = equipment and equipment[slot] or nil
		if not MC.IsEmptyItemStack( stack ) and MC.ItemCanEquipInSlot( stack, slot ) then
			result[slot] = MC.CopyItemStack( stack, slot == "offhand" and stack.count or 1 )
		end
	end
	return result
end

local function newRecord( ply, storage, selected, carried, equipment )
	local record = {
		owner = ply,
		ownerId = safeOwnerId( ply ),
		storage = storage or {},
		selected = math.Clamp( math.floor( tonumber( selected ) or 0 ), 0, 8 ),
		carried = MC.CopyItemStack( carried ),
		equipment = normalizedEquipment( equipment ),
		revision = 0,
		dirty = false,
		loadedAt = SysTime and SysTime() or 0,
	}
	local container, err = MC.NewInventoryContainer( {
		id = 1,
		kind = "player",
		revision = 0,
		slots = playerSlotDefinitions( record.storage ),
		hotbarSlots = playerHotbarIndices(),
		transferRules = {
			hotbar = { targets = { "main" } },
			main = { targets = { "hotbar" } },
		},
		onCommit = function( committedContainer, result, context )
			onContainerCommit( record, committedContainer, result, context )
		end,
	} )
	if not container then return nil, err end
	record.container = container
	return record
end

local function decodeSavedRecord( ply, data )
	if type( data ) ~= "table" or math.floor( tonumber( data.version ) or -1 ) ~= SAVE_VERSION then
		return nil, "unsupported_inventory_save"
	end
	local storage, seen = {}, {}
	for _, entry in ipairs( data.items or {} ) do
		local slot = math.floor( tonumber( entry and entry.slot ) or -1 )
		if slot >= 0 and slot < INVENTORY_SIZE and not seen[slot] then
			seen[slot] = true
			local stack = MC.InventoryStackFromData( entry.stack )
			if stack then storage[slot + 1] = stack end
		end
	end
	local equipment, equipmentSeen = {}, {}
	for _, entry in ipairs( data.equipment or {} ) do
		local slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( entry and entry.slot ) or nil
		if slot and not equipmentSeen[slot] then
			equipmentSeen[slot] = true
			local stack = MC.InventoryStackFromData( entry.stack )
			if stack and MC.ItemCanEquipInSlot( stack, slot ) then
				equipment[slot] = MC.CopyItemStack( stack, slot == "offhand" and stack.count or 1 )
			end
		end
	end
	local carried = MC.InventoryStackFromData( data.carried )
	return newRecord( ply, storage, data.selected, carried, equipment )
end

local function readRecord( ply )
	if not persistentEnabled() then return newRecord( ply ) end
	local ownerId = safeOwnerId( ply )
	if not ownerId or string.StartWith( ownerId, "bot_" ) then return newRecord( ply ) end
	local path = finalPath( ownerId )
	if not file.Exists( path, "DATA" ) then return newRecord( ply ) end
	local raw = file.Read( path, "DATA" )
	local data = raw and util.JSONToTable( raw ) or nil
	local record, err = decodeSavedRecord( ply, data )
	if record then return record end
	local message = "[MC Inventory] ignored invalid save " .. path .. ": " .. tostring( err or "invalid_json" ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
	return newRecord( ply )
end

local function encodedRecord( record )
	local data = {
		version = SAVE_VERSION,
		itemRegistry = tostring( MC.ItemRegistryHash or "" ),
		selected = record.selected,
		items = {},
		equipment = {},
	}
	for slot = 0, INVENTORY_SIZE - 1 do
		local stack = record.storage[slot + 1]
		if not MC.IsEmptyItemStack( stack ) then
			data.items[#data.items + 1] = { slot = slot, stack = MC.InventoryDataStack( stack ) }
		end
	end
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		local stack = record.equipment and record.equipment[slot] or nil
		if not MC.IsEmptyItemStack( stack ) then
			data.equipment[#data.equipment + 1] = { slot = slot, stack = MC.InventoryDataStack( stack ) }
		end
	end
	local carried = record.container and record.container.cursor or record.carried
	if not MC.IsEmptyItemStack( carried ) then data.carried = MC.InventoryDataStack( carried ) end
	local json = util.TableToJSON( data, true )
	if not json then return nil, "inventory_json_failed" end
	if #json > 1024 * 1024 then return nil, "inventory_save_too_large" end
	return json
end

function SV.SavePlayerInventory( plyOrRecord, force )
	local record = type( plyOrRecord ) == "table" and plyOrRecord.storage and plyOrRecord
		or SV.PlayerInventories[plyOrRecord]
	if not record then return false, "inventory_not_loaded" end
	if not persistentEnabled() or not record.ownerId or string.StartWith( record.ownerId, "bot_" ) then
		record.dirty = false
		return true
	end
	if not force and record.dirty ~= true then return true end
	local json, encodeError = encodedRecord( record )
	if not json then return false, encodeError end
	file.CreateDir( SAVE_ROOT )
	local final = finalPath( record.ownerId )
	local temporary = tempPath( record.ownerId )
	local backup = backupPath( record.ownerId )
	if file.Exists( temporary, "DATA" ) then file.Delete( temporary ) end
	file.Write( temporary, json )
	if file.Read( temporary, "DATA" ) ~= json then
		if file.Exists( temporary, "DATA" ) then file.Delete( temporary ) end
		return false, "inventory_write_verify_failed"
	end
	if file.Exists( backup, "DATA" ) then file.Delete( backup ) end
	if file.Exists( final, "DATA" ) then file.Rename( final, backup ) end
	file.Rename( temporary, final )
	if not file.Exists( final, "DATA" ) then
		if file.Exists( backup, "DATA" ) then file.Rename( backup, final ) end
		return false, "inventory_commit_failed"
	end
	if file.Exists( backup, "DATA" ) then file.Delete( backup ) end
	record.dirty = false
	record.lastSavedAt = SysTime and SysTime() or 0
	return true
end

function SV.LoadPlayerInventory( ply )
	if not IsValid( ply ) or not ply:IsPlayer() then return nil, "invalid_player" end
	local existing = SV.PlayerInventories[ply]
	if existing then return existing end
	if not MC.ItemRegistryFrozen and MC.FinalizeItemRegistry then
		local _, err = MC.FinalizeItemRegistry()
		if err then return nil, err end
	end
	local record, err = readRecord( ply )
	if not record then return nil, err end
	SV.PlayerInventories[ply] = record
	updateHeldNetwork( record, { reason = "inventory_load" } )
	if SV.UpdatePlayerEquipmentNetwork then SV.UpdatePlayerEquipmentNetwork( record ) end
	return record
end

function SV.GetPlayerInventoryRecord( ply, create )
	local record = SV.PlayerInventories[ply]
	if not record and create ~= false then record = SV.LoadPlayerInventory( ply ) end
	return record
end

function SV.GetPlayerInventoryContainer( ply, create )
	local record = SV.GetPlayerInventoryRecord( ply, create )
	return record and record.container or nil
end

function SV.GetPlayerInventoryStack( ply, slot )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	slot = math.floor( tonumber( slot ) or -1 )
	return record and slot >= 0 and slot < INVENTORY_SIZE and MC.CopyItemStack( record.storage[slot + 1] ) or nil
end

function SV.GetSelectedPlayerStack( ply )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	return record and MC.CopyItemStack( record.storage[record.selected + 1] ) or nil
end

function SV.GetPlayerEquipmentStack( ply, slot )
	local record = SV.GetPlayerInventoryRecord( ply, false )
	slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or nil
	return record and slot and MC.CopyItemStack( record.equipment and record.equipment[slot] ) or nil
end

function SV.PlayerHasInfiniteMaterials( ply )
	if MC.RunEvent then
		local allowed = MC.RunEvent( "MC.PlayerHasInfiniteMaterials", ply )
		if allowed ~= nil then return allowed == true end
	end
	return SV.PlayerIsCreative and SV.PlayerIsCreative( ply ) == true
end

function SV.SetPlayerSelectedSlot( ply, selected, context )
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return false, "inventory_not_loaded" end
	selected = math.floor( tonumber( selected ) or -1 )
	if selected < 0 or selected > 8 then return false, "invalid_hotbar_slot" end
	if record.selected == selected then return true end
	record.selected = selected
	record.lastAttackAt = CurTime and CurTime() or record.lastAttackAt
	record.dirty = true
	updateHeldNetwork( record, context or { reason = "selected" } )
	if type( SV.PublishPlayerInventorySelection ) == "function" then
		SV.PublishPlayerInventorySelection( record, context or {} )
	end
	return true
end

function SV.CommitPlayerInventoryMutation( record, snapshot, context )
	local container = record and record.container
	if not container or not snapshot then return nil, "invalid_inventory_mutation" end
	local changedSlots = MC.ContainerChangedSlots( container, snapshot )
	local cursorChanged = not MC.ItemStacksEqual( container.cursor, snapshot.cursor )
	if #changedSlots == 0 and not cursorChanged then
		return { ok = true, revision = container.revision, changedSlots = {}, changed = {}, cursor = MC.CopyItemStack( container.cursor ), drops = {} }
	end
	container.revision = container.revision + 1
	local result = {
		ok = true,
		revision = container.revision,
		changedSlots = changedSlots,
		changed = changedStackMap( container, changedSlots ),
		cursorChanged = cursorChanged,
		cursor = MC.CopyItemStack( container.cursor ),
		drops = {},
	}
	onContainerCommit( record, container, result, context or {} )
	return result
end

function SV.InsertPlayerItem( ply, input, context )
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return nil, "inventory_not_loaded" end
	local stack, err = MC.NormalizeItemStack( input )
	if not stack then return nil, err or "invalid_stack" end
	local container = record.container
	local snapshot = MC.ContainerSnapshot( container )
	local selectedSlot = MC.ContainerGetSlot( container, record.selected )
	if selectedSlot then
		local selectedStack = MC.InventorySlotGet( selectedSlot )
		if selectedStack and MC.ItemStacksCanMerge( selectedStack, stack ) then
			stack = select( 1, MC.InventorySlotInsert( selectedSlot, stack, stack.count, context or {} ) )
		end
	end
	local targets = {}
	for slot = 0, INVENTORY_SIZE - 1 do targets[#targets + 1] = slot end
	stack = select( 1, MC.ContainerMoveStackTo( container, stack, targets, context or {} ) )
	local result = SV.CommitPlayerInventoryMutation( record, snapshot, context or { reason = "insert" } )
	return MC.CopyItemStack( stack ), result
end

function SV.RemovePlayerItem( ply, matcher, amount, context )
	local record = SV.GetPlayerInventoryRecord( ply )
	if not record then return 0, "inventory_not_loaded" end
	amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if amount == 0 then return 0 end
	local matchFunction
	if type( matcher ) == "function" then matchFunction = matcher
	else
		local definition = MC.GetItem( matcher )
		if not definition then return 0, "unknown_item" end
		matchFunction = function( stack ) return stack and stack.item == definition.name end
	end
	local snapshot = MC.ContainerSnapshot( record.container )
	local removed = 0
	for slot = 0, INVENTORY_SIZE - 1 do
		if removed >= amount then break end
		local inventorySlot = MC.ContainerGetSlot( record.container, slot )
		local stack = MC.InventorySlotGet( inventorySlot )
		if stack and matchFunction( stack, slot ) then
			local extracted = MC.InventorySlotTake( inventorySlot, math.min( stack.count, amount - removed ), context or {} )
			if extracted then removed = removed + extracted.count end
		end
	end
	SV.CommitPlayerInventoryMutation( record, snapshot, context or { reason = "remove" } )
	return removed
end

function SV.PlayerInventoryState( record )
	local state = {
		version = SAVE_VERSION,
		revision = record.container.revision,
		selected = record.selected,
		registryHash = tostring( MC.ItemRegistryHash or "" ),
		items = {},
		equipment = {},
	}
	for slot = 0, INVENTORY_SIZE - 1 do
		local stack = record.storage[slot + 1]
		if stack then state.items[#state.items + 1] = { slot = slot, stack = MC.InventoryDataStack( stack ) } end
	end
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		local stack = record.equipment and record.equipment[slot] or nil
		if stack then state.equipment[#state.equipment + 1] = { slot = slot, stack = MC.InventoryDataStack( stack ) } end
	end
	return state
end

hook.Add( "PlayerInitialSpawn", "mc_player_inventory_load", function( ply )
	timer.Simple( 0, function()
		if not IsValid( ply ) then return end
		local record = SV.LoadPlayerInventory( ply )
		if record and SV.SendPlayerInventorySnapshot then SV.SendPlayerInventorySnapshot( ply, "initial" ) end
	end )
end )

hook.Add( "PlayerDisconnected", "mc_player_inventory_save", function( ply )
	local record = SV.PlayerInventories[ply]
	if not record then return end
	if record.session and SV.ClosePlayerInventory then
		-- Return transient crafting inputs/cursor before the persistence hook
		-- serializes the 36-slot player inventory.
		SV.ClosePlayerInventory( ply, "disconnect" )
	end
	SV.SavePlayerInventory( record, true )
	SV.PlayerInventories[ply] = nil
end )

hook.Add( "ShutDown", "mc_player_inventory_shutdown_save", function()
	for _, record in pairs( SV.PlayerInventories ) do
		if record.session and SV.ClosePlayerInventory then SV.ClosePlayerInventory( record.owner, "shutdown" ) end
		SV.SavePlayerInventory( record, true )
	end
end )

timer.Create( "mc_player_inventory_autosave", SAVE_INTERVAL, 0, function()
	for _, record in pairs( SV.PlayerInventories ) do
		if record.dirty then SV.SavePlayerInventory( record, false ) end
	end
end )

timer.Simple( 0, function()
	for _, ply in ipairs( player.GetAll() ) do
		local record = SV.LoadPlayerInventory( ply )
		if record and SV.SendPlayerInventorySnapshot then SV.SendPlayerInventorySnapshot( ply, "reload" ) end
	end
end )
