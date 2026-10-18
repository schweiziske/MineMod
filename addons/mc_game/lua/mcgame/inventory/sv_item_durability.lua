-- Server-authoritative durability mutations for the selected inventory item.

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV

local function infiniteMaterials( ply )
	return SV.PlayerHasInfiniteMaterials and SV.PlayerHasInfiniteMaterials( ply ) == true
end

-- External game layers (for example MCITEM's Unbreaking implementation) may
-- reduce the number of durability points consumed by one action.  The hook is
-- deliberately a scalar boundary: nil keeps the requested amount, false
-- cancels the durability mutation, and a number is clamped to a non-negative
-- integer by the authoritative inventory layer.
local function modifiedDurabilityAmount( ply, stack, amount, context )
	amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) )
	if amount <= 0 or not hook or type( hook.Run ) ~= "function" then return amount end
	local called, result = pcall( hook.Run, "MC.ModifyItemDurabilityDamage", ply, stack, amount, context or {} )
	if not called or result == nil then return amount end
	if result == false then return 0 end
	local numeric = tonumber( result )
	return numeric and math.max( 0, math.floor( numeric ) ) or amount
end

-- Kept public for the equipment durability path, which is loaded before this
-- file in mcgame_load.lua but calls the helper only after all modules exist.
function SV.ModifyItemDurabilityDamage( ply, stack, amount, context )
	return modifiedDurabilityAmount( ply, stack, amount, context )
end

local function skippedDurabilityResult( record, slotIndex, amount )
	return {
		ok = true,
		skipped = true,
		reason = "durability_ignored",
		revision = math.max( 0, math.floor( tonumber( record and record.revision ) or 0 ) ),
		changedSlots = {},
		slotIndex = slotIndex,
		amount = math.max( 0, math.floor( tonumber( amount ) or 0 ) ),
	}, false
end

function SV.DamageSelectedItem( ply, amount, context )
	context = context or {}
	amount = math.floor( tonumber( amount ) or 0 )
	if amount <= 0 or not IsValid( ply ) then return nil, false, "invalid_durability_amount" end
	local record, matchedSlotIndex, matchedStack, matchError = SV.SelectedStackMatches( ply, context )
	if not record then return nil, false, matchError end
	local slotIndex, stack = matchedSlotIndex, matchedStack
	local definition = stack and MC.GetItem( stack.item ) or nil
	local maxDamage = tonumber( definition and definition.maxDamage ) or 0
	if not stack or not definition or maxDamage <= 0 or MC.ItemIsUnbreakable( stack ) then
		return nil, false, "item_not_damageable"
	end
	if infiniteMaterials( ply ) then return nil, false, "infinite_materials" end
	local damagePerUse = MC.ItemToolDamagePerBlock( stack )
	if context.useToolScale == true and damagePerUse > 0 then amount = amount * damagePerUse end
	amount = math.floor( math.max( 0, tonumber( amount ) or 0 ) )
	amount = modifiedDurabilityAmount( ply, stack, amount, {
		player = ply,
		slot = context.hand or "mainhand",
		isArmor = false,
		reason = context.reason or "durability",
		context = context,
	} )
	if amount <= 0 then return skippedDurabilityResult( record, slotIndex, amount ) end
	amount = math.Clamp( amount, 1, 255 )
	local snapshot = SV.InteractionSnapshot( record, slotIndex == 40 )
	local currentDamage = math.max( 0, math.floor( tonumber( stack.damage ) or 0 ) )
	local newDamage = math.min( maxDamage, currentDamage + amount )
	local broken = newDamage >= maxDamage
	local replacement
	if not broken then replacement = MC.CopyItemStack( stack ) end
	if replacement then replacement.damage = newDamage > 0 and newDamage or nil end
	local ok, setError = SV.SetInteractionStack( record, slotIndex, replacement )
	if not ok then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, false, setError or "durability_mutation_failed"
	end
	local result, commitError = SV.CommitPlayerInventoryMutation( record, snapshot, {
		player = ply,
		reason = context.reason or "durability",
		actionId = context.actionId,
	} )
	if not result then
		SV.RestoreInteractionSnapshot( record, snapshot )
		return nil, false, commitError or "durability_commit_failed"
	end
	if MC.RunEvent then
		MC.RunEvent( "MC.ItemDurabilityChanged", ply, slotIndex, stack, replacement, newDamage, broken )
	end
	if broken and record.itemUse and record.itemUse.hand == ( context.hand or "mainhand" ) and SV.CancelSelectedItemUse then
		SV.CancelSelectedItemUse( ply, "selected_item_broken" )
	end
	return result, broken
end

MC.DamageSelectedItem = SV.DamageSelectedItem
