-- Persistent EntityEquipment-style storage and atomic mutations.  Equipment
-- stays separate from the 36-slot player container, matching Minecraft's
-- Inventory + EntityEquipment split while sharing one monotonic revision.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function currentRevision( record )
	return math.max(
		tonumber( record and record.revision ) or 0,
		tonumber( record and record.container and record.container.revision ) or 0,
		tonumber( record and record.session and record.session.container and record.session.container.revision ) or 0
	)
end

local function equipmentCopy( equipment )
	local copy = {}
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do copy[slot] = MC.CopyItemStack( equipment and equipment[slot] ) end
	return copy
end

local function changedSlots( record, snapshot )
	local changed = {}
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		if not MC.ItemStacksEqual( record.equipment and record.equipment[slot], snapshot and snapshot[slot] ) then
			changed[#changed + 1] = slot
		end
	end
	return changed
end

local function restoreEquipment( record, snapshot )
	record.equipment = record.equipment or {}
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do record.equipment[slot] = MC.CopyItemStack( snapshot and snapshot[slot] ) end
end

local function copyWithoutDamage( stack )
	if not stack then return nil end
	local copy = MC.CopyItemStack( stack )
	if copy then copy.damage = nil end
	return copy
end

-- Binding Curse prevents an actual equipment change, but durability updates
-- must still be allowed to replace the stack's damage value.  Comparing a
-- copy without damage gives the hook a precise "take" boundary instead of
-- accidentally treating every hit as an attempted armor removal.
local function equipmentChangeTakesStack( current, replacement )
	if not current then return false end
	if not replacement then return true end
	if MC.ItemStacksEqual then
		return not MC.ItemStacksEqual( copyWithoutDamage( current ), copyWithoutDamage( replacement ) )
	end
	return current.item ~= replacement.item
		or ( tonumber( current.count ) or 0 ) ~= ( tonumber( replacement.count ) or 0 )
end

local function canTakeEquipmentStack( ply, slot, current, replacement, context )
	if not equipmentChangeTakesStack( current, replacement ) then return true end
	if not hook or type( hook.Run ) ~= "function" then return true end
	local takeContext = {}
	for key, value in pairs( context or {} ) do takeContext[key] = value end
	takeContext.player = ply
	takeContext.newStack = MC.CopyItemStack( replacement )
	local called, result = pcall( hook.Run, "MC.CanTakeEquipmentStack", ply, slot, current, takeContext )
	if not called then return false, "equipment_take_hook_error" end
	if result == false then return false, "equipment_take_denied" end
	return true
end

local function modifiedDurabilityAmount( ply, stack, amount, context )
	amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if amount <= 0 then return amount end
	if SV.ModifyItemDurabilityDamage then
		return SV.ModifyItemDurabilityDamage( ply, stack, amount, context or {} )
	end
	if not hook or type( hook.Run ) ~= "function" then return amount end
	local called, result = pcall( hook.Run, "MC.ModifyItemDurabilityDamage", ply, stack, amount, context or {} )
	if not called or result == nil then return amount end
	if result == false then return 0 end
	local numeric = tonumber( result )
	return numeric and math.max( 0, math.floor( numeric ) ) or amount
end

local function skippedEquipmentDamageResult( record, slot, amount )
	return {
		ok = true,
		skipped = true,
		reason = "durability_ignored",
		revision = currentRevision( record ),
		changedSlots = {},
		slot = slot,
		amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) ),
	}, false
end

function SV.EquipmentSnapshot( record )
	return equipmentCopy( record and record.equipment )
end

function SV.PlayerEquipmentTotals( recordOrPlayer )
	local record = type( recordOrPlayer ) == "table" and recordOrPlayer.equipment and recordOrPlayer
		or SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( recordOrPlayer, false ) or nil
	local armor, toughness, knockback = 0, 0, 0
	for _, slot in ipairs( { "head", "chest", "legs", "feet" } ) do
		local stats = MC.ItemArmorStats and MC.ItemArmorStats( record and record.equipment and record.equipment[slot] ) or nil
		if stats then
			armor = armor + ( tonumber( stats.defense ) or 0 )
			toughness = toughness + ( tonumber( stats.toughness ) or 0 )
			knockback = knockback + ( tonumber( stats.knockbackResistance ) or 0 )
		end
	end
	return armor, toughness, math.Clamp( knockback, 0, 1 )
end

function SV.UpdatePlayerEquipmentNetwork( record )
	local ply = record and record.owner
	if not IsValid( ply ) then return false end
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		local stack = record.equipment and record.equipment[slot] or nil
		local definition = stack and MC.GetItem( stack.item ) or nil
		local prefix = "mc_equipment_" .. slot .. "_"
		ply:SetNWString( prefix .. "item", definition and definition.name or "" )
		ply:SetNWInt( prefix .. "runtime", definition and definition.runtimeId or 0 )
		ply:SetNWInt( prefix .. "count", stack and stack.count or 0 )
		ply:SetNWInt( prefix .. "damage", stack and stack.damage or 0 )
		ply:SetNWBool( prefix .. "foil", stack and MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) or false )
	end
	local armor, toughness, knockback = SV.PlayerEquipmentTotals( record )
	ply:SetNWInt( "mc_armor", armor )
	ply:SetNWFloat( "mc_armor_toughness", toughness )
	ply:SetNWFloat( "mc_armor_knockback_resistance", knockback )
	return true
end

function SV.CommitEquipmentMutation( record, snapshot, context )
	if not record or type( record.equipment ) ~= "table" or type( snapshot ) ~= "table" then
		return nil, "invalid_equipment_mutation"
	end
	local changed = changedSlots( record, snapshot )
	if #changed == 0 then
		return { ok = true, revision = currentRevision( record ), changedSlots = {} }
	end
	local revision = currentRevision( record ) + 1
	record.revision = revision
	if record.container then record.container.revision = revision end
	if record.session and record.session.container then record.session.container.revision = revision end
	record.dirty = true
	SV.UpdatePlayerEquipmentNetwork( record )
	local result = { ok = true, revision = revision, changedSlots = changed, changed = {} }
	for _, slot in ipairs( changed ) do result.changed[slot] = MC.CopyItemStack( record.equipment[slot] ) end
	if SV.PublishEquipmentCommit then SV.PublishEquipmentCommit( record, result, context or {} ) end
	if MC.RunEvent then MC.RunEvent( "MC.EquipmentChanged", record.owner, changed, result, context or {} ) end
	return result
end

function SV.SetPlayerEquipmentStack( ply, slot, input, context )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply ) or nil
	if not record then return nil, "inventory_not_loaded" end
	slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or nil
	if not slot then return nil, "invalid_equipment_slot" end
	local stack, stackError = MC.NormalizeItemStack( input )
	if input ~= nil and not stack and stackError then return nil, stackError end
	if stack and not MC.ItemCanEquipInSlot( stack, slot ) then return nil, "equipment_slot_rejected" end
	local current = record.equipment and record.equipment[slot] or nil
	local canTake, takeError = canTakeEquipmentStack( ply, slot, current, stack, context )
	if not canTake then return nil, takeError or "equipment_take_denied" end
	local snapshot = SV.EquipmentSnapshot( record )
	record.equipment[slot] = stack and MC.CopyItemStack( stack, slot == "offhand" and stack.count or 1 ) or nil
	local result, commitError = SV.CommitEquipmentMutation( record, snapshot, context or { reason = "equipment_set" } )
	if not result then restoreEquipment( record, snapshot ) return nil, commitError end
	return result
end

function SV.DamageEquipmentItem( ply, slot, amount, context )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or nil
	amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if not record or not slot or amount <= 0 then return nil, false, "invalid_equipment_damage" end
	local stack = record.equipment and record.equipment[slot] or nil
	local definition = stack and MC.GetItem( stack.item ) or nil
	local maximum = tonumber( definition and definition.maxDamage ) or 0
	if not stack or maximum <= 0 or MC.ItemIsUnbreakable( stack ) then return nil, false, "equipment_not_damageable" end
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) then return nil, false, "infinite_materials" end
	amount = modifiedDurabilityAmount( ply, stack, amount, {
		player = ply,
		slot = slot,
		isArmor = slot ~= "offhand",
		reason = context and context.reason or "equipment_damage",
		context = context,
	} )
	if amount <= 0 then return skippedEquipmentDamageResult( record, slot, amount ) end
	local snapshot = SV.EquipmentSnapshot( record )
	local damage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) ) + amount
	local broken = damage >= maximum
	local replacement
	if not broken then
		replacement = MC.CopyItemStack( stack )
		replacement.damage = damage
	end
	record.equipment[slot] = replacement
	local result, commitError = SV.CommitEquipmentMutation( record, snapshot, context or { reason = "equipment_damage" } )
	if not result then restoreEquipment( record, snapshot ) return nil, false, commitError end
	if broken then
		if record.itemUse and record.itemUse.kind == "shield"
		and ( record.itemUse.hand == "offhand" and slot == "offhand" )
		and SV.CancelSelectedItemUse then
			SV.CancelSelectedItemUse( ply, "shield_broken" )
		end
		if MC.RunEvent then MC.RunEvent( "MC.EquipmentBroken", ply, slot, stack ) end
	end
	return result, broken
end

function SV.DamagePlayerArmor( ply, amount, context )
	local record = SV.GetPlayerInventoryRecord and SV.GetPlayerInventoryRecord( ply, false ) or nil
	amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if not record or amount <= 0 then return nil, {}, "invalid_armor_damage" end
	if SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) then return nil, {}, "infinite_materials" end
	local snapshot = SV.EquipmentSnapshot( record )
	local broken = {}
	local changed = false
	for _, slot in ipairs( { "head", "chest", "legs", "feet" } ) do
		local stack = record.equipment and record.equipment[slot] or nil
		local definition = stack and MC.GetItem( stack.item ) or nil
		local maximum = tonumber( definition and definition.maxDamage ) or 0
		if stack and maximum > 0 and not MC.ItemIsUnbreakable( stack ) then
			local applied = modifiedDurabilityAmount( ply, stack, amount, {
				player = ply,
				slot = slot,
				isArmor = true,
				reason = context and context.reason or "armor_damage",
				context = context,
			} )
			if applied > 0 then
				changed = true
				local damage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) ) + applied
				if damage >= maximum then
					record.equipment[slot] = nil
					broken[#broken + 1] = { slot = slot, stack = MC.CopyItemStack( stack ) }
				else
					local replacement = MC.CopyItemStack( stack )
					replacement.damage = damage
					record.equipment[slot] = replacement
				end
			end
		end
	end
	if not changed then return skippedEquipmentDamageResult( record, "armor", amount ) end
	local result, commitError = SV.CommitEquipmentMutation( record, snapshot, context or { reason = "armor_damage" } )
	if not result then restoreEquipment( record, snapshot ) return nil, {}, commitError end
	for _, entry in ipairs( broken ) do
		if MC.RunEvent then MC.RunEvent( "MC.EquipmentBroken", ply, entry.slot, entry.stack ) end
	end
	return result, broken
end

local function playerSlotDefinitions( record )
	local slots, playerMenuMap, menuPlayerMap, hotbar = {}, {}, {}, {}
	for index = 0, 35 do
		slots[#slots + 1] = {
			index = index,
			storage = record.storage,
			storageIndex = index + 1,
			group = index < 9 and "hotbar" or "main",
		}
		playerMenuMap[index], menuPlayerMap[index] = index, index
		if index < 9 then hotbar[index + 1] = index end
	end
	return slots, playerMenuMap, menuPlayerMap, hotbar
end

local function creativeEquipmentSlot( record, slot, menuIndex )
	return {
		index = menuIndex,
		storage = record.equipment,
		storageIndex = slot,
		group = slot == "offhand" and "offhand" or "armor_" .. slot,
		maxStack = slot == "offhand" and ( MC.ItemAbsoluteMaxStack or 99 ) or 1,
		mayPlace = function( _, stack ) return MC.ItemCanEquipInSlot( stack, slot ) end,
		meta = { role = "equipment", equipmentSlot = slot },
	}
end

local function creativeQuickMoveTargets( fallbackGroup )
	return function( _, source )
		local equipmentSlot = MC.ItemEquipmentSlot and MC.ItemEquipmentSlot( source ) or nil
		local targets = {}
		if equipmentSlot and equipmentSlot ~= "offhand" then
			targets[#targets + 1] = "armor_" .. equipmentSlot
		elseif equipmentSlot == "offhand" then
			targets[#targets + 1] = "offhand"
		end
		targets[#targets + 1] = fallbackGroup
		return targets
	end
end

function SV.BuildCreativeInventoryMenu( ply, record )
	if not record or not record.container then return nil, "inventory_not_loaded" end
	local slots, playerMenuMap, menuPlayerMap, hotbar = playerSlotDefinitions( record )
	local equipmentMenuMap = {}
	for _, slot in ipairs( MC.EquipmentSlotOrder or {} ) do
		local menuIndex = MC.CreativeEquipmentMenuSlots and MC.CreativeEquipmentMenuSlots[slot] or nil
		if menuIndex == nil then return nil, "creative_equipment_map_missing" end
		slots[#slots + 1] = creativeEquipmentSlot( record, slot, menuIndex )
		equipmentMenuMap[slot] = menuIndex
	end
	local menu, menuError = MC.NewInventoryContainer( {
		id = record.container.id,
		kind = "player",
		revision = currentRevision( record ),
		slots = slots,
		hotbarSlots = hotbar,
		transferRules = {
			main = { resolve = creativeQuickMoveTargets( "hotbar" ) },
			hotbar = { resolve = creativeQuickMoveTargets( "main" ) },
			armor_head = { targets = { "hotbar", "main" } },
			armor_chest = { targets = { "hotbar", "main" } },
			armor_legs = { targets = { "hotbar", "main" } },
			armor_feet = { targets = { "hotbar", "main" } },
			offhand = { targets = { "hotbar", "main" } },
		},
		context = { player = ply, creative = true },
	} )
	if not menu then return nil, menuError end
	menu.playerMenuMap = playerMenuMap
	menu.menuPlayerMap = menuPlayerMap
	menu.equipmentMenuMap = equipmentMenuMap
	menu.onCommit = function( committed, result, context )
		local playerChanged, equipmentChanged, selectedChanged = false, false, false
		for _, index in ipairs( result.changedSlots or {} ) do
			local playerIndex = menuPlayerMap[index]
			if playerIndex ~= nil then
				playerChanged = true
				if playerIndex == record.selected then selectedChanged = true end
			end
			for _, equipmentIndex in pairs( equipmentMenuMap ) do
				if index == equipmentIndex then equipmentChanged = true break end
			end
		end
		record.container.revision = math.max( record.container.revision, committed.revision )
		record.revision = record.container.revision
		if playerChanged or equipmentChanged then record.dirty = true end
		if selectedChanged and SV.UpdatePlayerHeldNetwork then SV.UpdatePlayerHeldNetwork( record ) end
		if equipmentChanged and SV.UpdatePlayerEquipmentNetwork then SV.UpdatePlayerEquipmentNetwork( record ) end
		if equipmentChanged and MC.RunEvent then
			MC.RunEvent( "MC.EquipmentChanged", record.owner, nil, result, context or {} )
		end
		if SV.PublishActiveInventoryCommit then SV.PublishActiveInventoryCommit( record, result, context or {} ) end
	end
	return menu, 0
end

timer.Simple( 0, function()
	for _, record in pairs( SV.PlayerInventories or {} ) do SV.UpdatePlayerEquipmentNetwork( record ) end
end )
