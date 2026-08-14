-- Public, read-only ItemStack helpers for separately shipped addons.
--
-- The game layer owns the normalized ItemStack representation.  External
-- addons must not call MC.GetItemCustomName / MC.ItemStackHash directly because
-- those are internal symbols with no compatibility guarantee.  These wrappers
-- deliberately return scalars only, so no live inventory/component table can
-- escape through the public API.

MC = MC or {}
MC.API = MC.API or {}
MC.API.ItemStack = MC.API.ItemStack or {}

local ItemStack = MC.API.ItemStack

-- Returns name, present, err.  An explicitly empty custom name is still
-- present, matching DataComponents.CUSTOM_NAME semantics.
function ItemStack.GetCustomName(stack)
	if not istable( stack ) then return nil, false, "invalid_stack" end
	if not isfunction( MC.GetItemCustomName ) then
		return nil, false, "item_stack_api_unavailable"
	end
	local value, present = MC.GetItemCustomName( stack )
	if present ~= true then return nil, false end
	return tostring( value or "" ), true
end

-- Stable hash of item id, count, damage and canonical components.  Consumers
-- use this as an optimistic-concurrency token in selected/held transactions.
function ItemStack.Hash(stack)
	if not istable( stack ) then return nil, "invalid_stack" end
	if not isfunction( MC.ItemStackHash ) then return nil, "item_stack_api_unavailable" end
	return tostring( MC.ItemStackHash( stack ) )
end

-- Returns the exact non-negative level stored in the normalized enchantments
-- component. This scalar wrapper keeps external addons away from the live
-- component representation while still allowing source-accurate behavior such
-- as Piercing arrows bypassing shields.
function ItemStack.GetEnchantmentLevel(stack, enchantment)
	if not istable( stack ) then return 0, "invalid_stack" end
	if not isstring( enchantment ) or enchantment == "" then return 0, "invalid_enchantment" end
	if not isfunction( MC.GetEnchantmentLevel ) then return 0, "item_stack_api_unavailable" end
	return math.max( 0, math.floor( tonumber( MC.GetEnchantmentLevel( stack, enchantment ) ) or 0 ) )
end
