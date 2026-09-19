-- Shared registration bridge from the survival addon into the public engine
-- surface. Nothing in mc_engine needs to know these event or network names.

MC = MC or {}

local API = MC.API
if not API then return end

local GAME_OWNER = "mc.game"

API.RegisterEvents( GAME_OWNER, {
	["MC.UseItemOnEntity"] = { realm = "shared", args = "ply, target, stack, context", desc = "selected-item entity interaction query/action" },
	["MC.TryPlaceDecoration"] = { realm = "shared", args = "ply, stack, hit, context", desc = "query/action: place a source-verified decoration entity" },
	["MC.PlayerIgnitedBlock"] = { realm = "server", args = "ply, bx, by, bz, stateId, source", desc = "a game-layer ignition interaction committed" },
	["MC.ModifyEntityIgnitionDuration"] = { realm = "server", args = "entity, seconds, context", desc = "query: modify a new entity ignition duration before it is applied" },
	["MC.IgniteEntity"] = { realm = "server", args = "entity, seconds, context", desc = "query: handle or reject Minecraft item/projectile ignition" },
	["MC.ChestOpenCountChanged"] = { realm = "server", args = "bx, by, bz, openCount", desc = "a chest opener count changed" },
	["MC.PlayerHasInfiniteMaterials"] = { realm = "server", args = "ply", desc = "query: override whether game inventory mutations consume materials" },
	["MC.PlayerHeldItemChanged"] = { realm = "server", args = "ply, selectedSlot, stack, context", desc = "the selected hotbar stack changed" },
	["MC.CreativeStacksAPIReady"] = { realm = "shared", args = "creativeStacksAPI", desc = "the complete creative ItemStack catalog API is available" },
	["MC.CreativeStackProvidersChanged"] = { realm = "shared", args = "providerId", desc = "a creative ItemStack provider changed" },
	["MC.ItemsAPIReady"] = { realm = "shared", args = "itemsAPI", desc = "the public namespace-based item registry adapter is available" },
	["MC.PlayerMiningModifiers"] = { realm = "shared", args = "ply, stateId, stack, defaults", desc = "query: predicted and authoritative mining attribute/status overrides" },
	["MC.HandSwingModifiers"] = { realm = "client", args = "ply, weapon, defaults", desc = "query: held-item mining swing modifiers" },
	["MC.PlayerMiningStarted"] = { realm = "server", args = "ply, session", desc = "a survival mining session started" },
	["MC.PlayerMiningCancelled"] = { realm = "server", args = "ply, session, reason", desc = "a survival mining session was cancelled" },
	["MC.PlayerMinedBlock"] = { realm = "server", args = "ply, bx, by, bz, oldStateId, drops, transaction, dropError, session, durabilityDamage", desc = "a survival mining session committed" },
	["MC.BlockExperienceAwarded"] = { realm = "server", args = "ply, bx, by, bz, experience, context", desc = "survival mining awarded block experience" },
	["MC.ItemDurabilityChanged"] = { realm = "server", args = "ply, slot, oldStack, newStack, damage, broken", desc = "an inventory item took durability damage" },
	["MC.SelectedItemConsumed"] = { realm = "server", args = "ply, slot, oldStack, amount, replacement, result", desc = "the selected stack was consumed" },
	["MC.SelectedItemReplaced"] = { realm = "server", args = "ply, slot, oldStack, newStack, result", desc = "the selected stack was replaced" },
	["MC.SelectedItemTakenWithDurability"] = { realm = "server", args = "ply, slot, oldStack, extractedStack, durabilityDamage, infinite, result", desc = "a selected stack was extracted after durability use" },
	["MC.ItemUseStarted"] = { realm = "server", args = "ply, stack, useState", desc = "a held-item use started" },
	["MC.ItemUseFinished"] = { realm = "server", args = "ply, reason", desc = "a held-item use completed" },
	["MC.ItemUseCancelled"] = { realm = "server", args = "ply, reason", desc = "a held-item use was cancelled" },
	["MC.ItemConsumed"] = { realm = "server", args = "ply, stack, foodData, infinite", desc = "a consumable finished" },
	["MC.ItemUsed"] = { realm = "server", args = "ply, stack, context", desc = "a non-consumable selected item completed use" },
	["MC.BowFired"] = { realm = "server", args = "ply, projectile, power, broken", desc = "a bow fired" },
	["MC.CrossbowCharged"] = { realm = "server", args = "ply, ammoStack", desc = "a crossbow stored a projectile" },
	["MC.CrossbowFired"] = { realm = "server", args = "ply, projectile, power, broken", desc = "a crossbow fired" },
	["MC.TridentThrown"] = { realm = "server", args = "ply, projectile", desc = "a trident was thrown" },
	["MC.ProjectileThrown"] = { realm = "server", args = "ply, projectile, itemName", desc = "a throwable item created a projectile" },
	["MC.ProjectileImpact"] = { realm = "server", args = "projectile, trace, hitEntity, definition", desc = "a game projectile resolved an impact" },
	["MC.EquipmentChanged"] = { realm = "shared", args = "server/client equipment change payload", desc = "authoritative equipment state changed" },
	["MC.EquipmentBroken"] = { realm = "server", args = "ply, equipmentSlot, oldStack", desc = "an equipped item broke" },
	["MC.ShieldDisabled"] = { realm = "server", args = "ply, seconds, reason", desc = "shield blocking was disabled" },
	["MC.ShieldBlockedDamage"] = { realm = "server", args = "ply, attacker, blockedDamage, hand", desc = "a shield blocked damage" },
	["MC.ShieldBypass"] = { realm = "server", args = "ply, damageInfo, metadata", desc = "query: bypass an active shield" },
	["MC.HeldItemConsumed"] = { realm = "server", args = "ply, hand, oldStack, amount, mutationResult", desc = "a held main/off-hand stack was consumed" },
	["MC.DeathProtectionBypass"] = { realm = "server", args = "ply, damageInfo, metadata", desc = "query: bypass held death protection" },
	["MC.DeathProtectionTriggered"] = { realm = "server", args = "ply, hand, stack, damageInfo, metadata", desc = "held death protection triggered" },
	["MC.PlayerAttackedEntity"] = { realm = "server", args = "ply, target, metadata", desc = "the Minecraft hand completed a melee attack" },
	["MC.EntityDropsEnabled"] = { realm = "server", args = "", desc = "query: return false to suppress decoration/entity item drops" },
	["MC.DecorationPlaced"] = { realm = "server", args = "ply, entity, stack, context", desc = "a decoration entity was placed from a game item" },
	["MC.DecorationAnalogOutputChanged"] = { realm = "shared", args = "entity, output, previous", desc = "a decoration entity's comparator-like analog output changed" },
	["MC.EntityAnalogOutputAt"] = { realm = "shared", args = "bx, by, bz, dx, dy, dz, context", desc = "query: entity-provided comparator analog output in one target cell" },
	["MC.EntityAnalogOutputChanged"] = { realm = "server", args = "entity, bx, by, bz, output, previous", desc = "an entity-provided comparator analog output changed at a cell" },
	["MC.LogisticsParityEnabled"] = { realm = "shared", args = "context", desc = "query: return true only when the default-off logistics parity branch may run" },
	["MC.BlockAnalogOutputAt"] = { realm = "shared", args = "bx, by, bz, context", desc = "query: optional block-container comparator analog output" },
	["MC.BlockAnalogOutputChanged"] = { realm = "server", args = "bx, by, bz, output, previous, context", desc = "a block-container comparator analog output changed" },
	["MC.BlockPhysicsMobEffectQuery"] = { realm = "shared", args = "entity, effectId", desc = "query: optional external MobEffect presence for source-verified block physics; nil falls back to no effect" },
	["MC.BlockPhysicsEquipmentEnchantmentLevel"] = { realm = "shared", args = "entity, slot, enchantmentId", desc = "query: optional equipment enchantment level for block physics; nil falls back to zero" },
	["MC.PistonMovementCommitted"] = { realm = "server", args = "payload { bx,by,bz,extending,dx,dy,dz,movements[] }", desc = "engine piston transaction committed; movements contain sanitized source/destination cells" },
	["MC.ItemEntityDamaged"] = { realm = "server", args = "entity, damageTypeId, damage, oldHealth, newHealth, source", desc = "a gameplay-parity ItemEntity accepted Minecraft damage" },
	["MC.ItemEntityDestroyed"] = { realm = "server", args = "entity, stack, damageTypeId, source", desc = "a gameplay-parity ItemEntity was destroyed" },
	["MC.DecorationMapRemoved"] = { realm = "server", args = "entity, stack", desc = "a framed map left an item frame and must be removed from map saved-data tracking" },
	["MC.DecorationMapRenderData"] = { realm = "client", args = "entity, stack", desc = "query: return a cached material/texture, or 128x128 RGBA pixels with stable cacheKey/mapId + revision; decorations require renderOnFrame" },
	["MC.DecorationGameEvent"] = { realm = "server", args = "entity, gameEventId, actor, context", desc = "a decoration emitted an authoritative Minecraft GameEvent" },
} )

-- Publish the game-owned adapters through the engine's capability table.  The
-- engine never reaches into these tables; separately shipped addons can wait
-- for the capability instead of probing mcgame internals.
if API.RegisterCapability then
	API.RegisterCapability( "mc.game.items", 1, API.Items or {}, GAME_OWNER )
	API.RegisterCapability( "mc.game.creative", 1, API.Creative or {}, GAME_OWNER )
	API.RegisterCapability( "mc.game.block_loot", 1, API.BlockLoot or {}, GAME_OWNER )
	API.RegisterCapability( "mc.game.config", 1, API.Config or {}, GAME_OWNER )
end

API.Network.Register( GAME_OWNER, {
	"mc_inventory_sync_begin", "mc_inventory_sync_part", "mc_inventory_sync_end",
	"mc_inventory_delta", "mc_inventory_open_request", "mc_inventory_open",
	"mc_inventory_action", "mc_inventory_menu_button", "mc_inventory_creative_pick",
	"mc_inventory_close", "mc_inventory_resync", "mc_inventory_select",
	"mc_inventory_recipe_place", "mc_equipment_delta", "mc_block_use_request",
	"mc_enchanting_state", "mc_anvil_state", "mc_anvil_rename",
	"mc_merchant_state", "mc_merchant_select",
	"mc_decoration_armor_stand_break_particles",
	"mc_brewing_state", "mc_furnace_state", "mc_campfire_dowse_fx",
	"mc_chest_open_state", "mc_mining_progress",
	"mc_minecraft_vehicle_interact", "mc_inventory_proxy_world_interact",
} )

if API.HandWeapon then
	API.HandWeapon.ConfigureBaseClasses( GAME_OWNER, "mc_item_hand", "mc_inventory" )
end

local BANNER_COLORS = {
	white = true, orange = true, magenta = true, light_blue = true,
	yellow = true, lime = true, pink = true, gray = true, light_gray = true,
	cyan = true, purple = true, blue = true, brown = true, green = true,
	red = true, black = true,
}

local function componentValue( components, name )
	if type( components ) ~= "table" then return nil end
	return components["minecraft:" .. name] ~= nil and components["minecraft:" .. name] or components[name]
end

local function componentName( value )
	if type( value ) == "string" then return value end
	if type( value ) ~= "table" then return nil end
	return value.id or value.asset_id or value.assetId or value.name or value.value
end

local function customName( value )
	if type( value ) == "string" then return value end
	if type( value ) == "table" and type( value.text ) == "string" then return value.text end
	return value
end

function MC.BannerRecordFromItemStack( stack )
	if type( stack ) ~= "table" then return nil, "not_banner_item" end
	local itemName = tostring( stack.item or "")
	local color = string.match( itemName, "^minecraft:([a-z_]+)_banner$" )
	if not color or not BANNER_COLORS[color] then return nil, "not_banner_item" end
	local rawPatterns = componentValue( stack.components, "banner_patterns" ) or {}
	if type( rawPatterns.layers ) == "table" then rawPatterns = rawPatterns.layers end
	if type( rawPatterns ) ~= "table" then return nil, "invalid_banner_layers" end
	local rawCount, rawMaximum = 0, 0
	for key in pairs( rawPatterns ) do
		if type( key ) ~= "number" or key < 1 or math.floor( key ) ~= key then
			return nil, "invalid_banner_layer_index"
		end
		rawCount, rawMaximum = rawCount + 1, math.max( rawMaximum, key )
	end
	if rawCount ~= rawMaximum then return nil, "sparse_banner_layers" end
	local layers = {}
	for index, layer in ipairs( rawPatterns ) do
		if type( layer ) ~= "table" then return nil, "invalid_banner_layer" end
		layers[index] = { pattern = componentName( layer.pattern ), color = componentName( layer.color ) }
	end
	local data, err = API.Banners.NormalizeData( {
		patterns = layers,
		customName = customName( componentValue( stack.components, "custom_name" ) ),
	}, API.Banners.MaxStoredPatterns() )
	if not data then return nil, err end
	return { type = "minecraft:banner", codecVersion = 1, data = data }
end

function MC.BannerComponentsFromRecord( record )
	if type( record ) ~= "table" or record.type ~= "minecraft:banner" then
		return nil, "invalid_banner_record"
	end
	local data, err = API.Banners.NormalizeData( record.data, API.Banners.MaxStoredPatterns() )
	if not data then return nil, err end
	local components = {}
	if #data.patterns > 0 then components["minecraft:banner_patterns"] = data.patterns end
	if data.customName then components["minecraft:custom_name"] = data.customName end
	return next( components ) and components or nil
end

function MC.BannerItemStackFromRecord( stateId, record, count )
	if not API.Banners.IsState( stateId ) then return nil, "not_banner_state" end
	local blockName, nameError = API.Blocks.Name( stateId )
	if not blockName then return nil, nameError end
	local itemName = API.Banners.IsWallState( stateId )
		and string.gsub( blockName, "_wall_banner$", "_banner" ) or blockName
	local components, err = MC.BannerComponentsFromRecord( record )
	if err then return nil, err end
	return MC.NewItemStack( itemName, count or 1, components )
end
