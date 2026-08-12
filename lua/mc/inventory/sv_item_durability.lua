-- Server-authoritative durability mutations for the selected inventory item.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function infiniteMaterials( ply )
	return SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true
end

local function selectedSlot( record )
	local index = math.Clamp( math.floor( tonumber( record and record.selected ) or 0 ), 0, 8 )
	return index, record and MC.ContainerGetSlot( record.container, index ) or nil
end

function SV.DamageSelectedItem( ply, amount, context )
	context = context or {}
	amount = math.floor( tonumber( amount ) or 0 )
	if amount <= 0 or not IsValid( ply ) then return nil, false, "invalid_durability_amount" end
	local record, matchedSlotIndex, matchedStack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, false, matchError end
	local slotIndex, slot = selectedSlot( record )
	local stack = matchedSlotIndex == slotIndex and matchedStack or slot and MC.InventorySlotGet( slot ) or nil
	local definition = stack and MC.GetItem( stack.item ) or nil
	local maxDamage = tonumber( definition and definition.maxDamage ) or 0
	if not stack or not definition or maxDamage <= 0 or MC.ItemIsUnbreakable( stack ) then
		return nil, false, "item_not_damageable"
	end
	if infiniteMaterials( ply ) then return nil, false, "infinite_materials" end
	local damagePerUse = MC.ItemToolDamagePerBlock( stack )
	if context.useToolScale == true and damagePerUse > 0 then amount = amount * damagePerUse end
	amount = math.Clamp( amount, 1, 255 )
	local snapshot = MC.ContainerSnapshot( record.container )
	local currentDamage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) )
	local newDamage = math.min( maxDamage, currentDamage + amount )
	local broken = newDamage >= maxDamage
	local replacement
	if not broken then replacement = MC.CopyItemStack( stack ) end
	if replacement then replacement.damage = newDamage > 0 and newDamage or nil end
	local ok, setError = MC.ContainerSetStack( record.container, slotIndex, replacement )
	if not ok then
		MC.ContainerRestore( record.container, snapshot )
		return nil, false, setError or "durability_mutation_failed"
	end
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "durability",
		actionId = context.actionId,
	} )
	if not result then
		MC.ContainerRestore( record.container, snapshot )
		return nil, false, commitError or "durability_commit_failed"
	end
	if MC.RunEvent then
		MC.RunEvent( "MC.ItemDurabilityChanged", ply, slotIndex, stack, replacement, newDamage, broken )
	end
	if broken and record.itemUse and record.itemUse.hand ~= "offhand" and SV.CancelSelectedItemUse then
		SV.CancelSelectedItemUse( ply, "selected_item_broken" )
	end
	return result, broken
end

MC.DamageSelectedItem = SV.DamageSelectedItem
