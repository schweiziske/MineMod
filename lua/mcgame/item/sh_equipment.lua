-- Minecraft equipment, armor and tool metadata shared by inventory, combat
-- and UI code.  Slot order follows InventoryMenu/EntityEquipment from out/;
-- values mirror ArmorMaterials, ToolMaterial and Items.java.

MC = MC or {}

MC.EquipmentSlotOrder = { "head", "chest", "legs", "feet", "offhand" }
MC.EquipmentSlotIds = { head = 0, chest = 1, legs = 2, feet = 3, offhand = 4 }
MC.EquipmentSlotsById = { [0] = "head", [1] = "chest", [2] = "legs", [3] = "feet", [4] = "offhand" }
MC.EquipmentMenuSlots = { head = 5, chest = 6, legs = 7, feet = 8, offhand = 45 }
MC.CreativeEquipmentMenuSlots = { head = 36, chest = 37, legs = 38, feet = 39, offhand = 40 }

local ARMOR_MATERIALS = {
	leather = { durability = 5, defense = { feet = 1, legs = 2, chest = 3, head = 1 }, toughness = 0, knockback = 0 },
	copper = { durability = 11, defense = { feet = 1, legs = 3, chest = 4, head = 2 }, toughness = 0, knockback = 0 },
	chainmail = { durability = 15, defense = { feet = 1, legs = 4, chest = 5, head = 2 }, toughness = 0, knockback = 0 },
	iron = { durability = 15, defense = { feet = 2, legs = 5, chest = 6, head = 2 }, toughness = 0, knockback = 0 },
	gold = { durability = 7, defense = { feet = 1, legs = 3, chest = 5, head = 2 }, toughness = 0, knockback = 0 },
	diamond = { durability = 33, defense = { feet = 3, legs = 6, chest = 8, head = 3 }, toughness = 2, knockback = 0 },
	turtle = { durability = 25, defense = { head = 2 }, toughness = 0, knockback = 0 },
	netherite = { durability = 37, defense = { feet = 3, legs = 6, chest = 8, head = 3 }, toughness = 3, knockback = 0.1 },
}

local TOOL_MATERIALS = {
	wooden = { key = "wood", speed = 2, attackBonus = 0 },
	stone = { key = "stone", speed = 4, attackBonus = 1 },
	copper = { key = "copper", speed = 5, attackBonus = 1 },
	iron = { key = "iron", speed = 6, attackBonus = 2 },
	diamond = { key = "diamond", speed = 8, attackBonus = 3 },
	golden = { key = "gold", speed = 12, attackBonus = 0 },
	netherite = { key = "netherite", speed = 9, attackBonus = 4 },
}

local TOOL_BASELINES = {
	sword = { damage = 3, speedModifier = -2.4, damagePerAttack = 1 },
	pickaxe = { damage = 1, speedModifier = -2.8, damagePerAttack = 2 },
	shovel = { damage = 1.5, speedModifier = -3.0, damagePerAttack = 2 },
}

local AXE_BASELINES = {
	wood = { 6, -3.2 }, stone = { 7, -3.2 }, copper = { 7, -3.2 },
	gold = { 6, -3.0 }, iron = { 6, -3.1 }, diamond = { 5, -3.0 }, netherite = { 5, -3.0 },
}

local HOE_BASELINES = {
	wood = { 0, -3.0 }, stone = { -1, -2.0 }, copper = { -1, -2.0 },
	gold = { 0, -3.0 }, iron = { -2, -1.0 }, diamond = { -3, 0 }, netherite = { -4, 0 },
}

local ARMOR_SUFFIXES = {
	["_helmet"] = "head",
	["_chestplate"] = "chest",
	["_leggings"] = "legs",
	["_boots"] = "feet",
}

local function component( stack, key )
	if type( stack ) ~= "table" or type( stack.components ) ~= "table" then return nil end
	local value = stack.components[key]
	if value == nil and not string.find( key, ":", 1, true ) then value = stack.components["minecraft:" .. key] end
	return value
end

local function itemName( stackOrDefinition )
	if type( stackOrDefinition ) == "table" then
		return stackOrDefinition.item or stackOrDefinition.name
	end
	return stackOrDefinition
end

local function pathName( stackOrDefinition )
	return string.match( tostring( itemName( stackOrDefinition ) or "" ), "^[^:]+:(.+)$" )
		or tostring( itemName( stackOrDefinition ) or "" )
end

function MC.NormalizeEquipmentSlot( slot )
	if type( slot ) == "number" then return MC.EquipmentSlotsById[math.floor( slot )] end
	slot = string.lower( tostring( slot or "" ) )
	if slot == "helmet" then slot = "head" end
	if slot == "chestplate" then slot = "chest" end
	if slot == "leggings" then slot = "legs" end
	if slot == "boots" then slot = "feet" end
	return MC.EquipmentSlotIds[slot] ~= nil and slot or nil
end

function MC.ItemEquipmentSlot( stackOrDefinition )
	local equippable = component( stackOrDefinition, "equippable" )
	if type( equippable ) == "table" then
		local slot = MC.NormalizeEquipmentSlot( equippable.slot or equippable.equipment_slot or equippable.equipmentSlot )
		if slot then return slot end
	elseif type( equippable ) == "string" then
		local slot = MC.NormalizeEquipmentSlot( equippable )
		if slot then return slot end
	end
	local name = pathName( stackOrDefinition )
	if name == "shield" then return "offhand" end
	if name == "elytra" then return "chest" end
	if name == "turtle_helmet" then return "head" end
	for suffix, slot in pairs( ARMOR_SUFFIXES ) do
		if string.sub( name, -#suffix ) == suffix then return slot end
	end
	if string.match( name, "_head$" ) or string.match( name, "_skull$" )
		or name == "carved_pumpkin" or name == "player_head" then return "head" end
	return nil
end

function MC.ItemCanEquipInSlot( stack, slot )
	slot = MC.NormalizeEquipmentSlot( slot )
	if not slot or MC.IsEmptyItemStack( stack ) then return false end
	if slot == "offhand" then return true end
	return MC.ItemEquipmentSlot( stack ) == slot
end

local function armorMaterialForName( name )
	if string.sub( name, 1, 8 ) == "leather_" then return "leather" end
	if string.sub( name, 1, 7 ) == "copper_" then return "copper" end
	if string.sub( name, 1, 10 ) == "chainmail_" then return "chainmail" end
	if string.sub( name, 1, 5 ) == "iron_" then return "iron" end
	if string.sub( name, 1, 7 ) == "golden_" then return "gold" end
	if string.sub( name, 1, 8 ) == "diamond_" then return "diamond" end
	if name == "turtle_helmet" then return "turtle" end
	if string.sub( name, 1, 10 ) == "netherite_" then return "netherite" end
	return nil
end

function MC.ItemArmorStats( stackOrDefinition )
	local slot = MC.ItemEquipmentSlot( stackOrDefinition )
	if not slot or slot == "offhand" then return nil end
	local name = pathName( stackOrDefinition )
	local materialName = armorMaterialForName( name )
	local material = materialName and ARMOR_MATERIALS[materialName] or nil
	if not material then return nil end
	return {
		slot = slot,
		material = materialName,
		defense = tonumber( material.defense[slot] ) or 0,
		toughness = tonumber( material.toughness ) or 0,
		knockbackResistance = tonumber( material.knockback ) or 0,
	}
end

local function toolIdentity( stackOrDefinition )
	local name = pathName( stackOrDefinition )
	for prefix, material in pairs( TOOL_MATERIALS ) do
		local marker = prefix .. "_"
		if string.sub( name, 1, #marker ) == marker then
			local toolType = string.sub( name, #marker + 1 )
			if TOOL_BASELINES[toolType] or toolType == "axe" or toolType == "hoe" then
				return toolType, material
			end
		end
	end
	return nil, nil
end

function MC.ItemToolSpec( stackOrDefinition )
	local toolType, material = toolIdentity( stackOrDefinition )
	if not toolType then return nil end
	local baseline = TOOL_BASELINES[toolType]
	if toolType == "axe" then baseline = AXE_BASELINES[material.key]
	elseif toolType == "hoe" then baseline = HOE_BASELINES[material.key] end
	if not baseline then return nil end
	local damageBaseline = tonumber( baseline.damage or baseline[1] ) or 0
	local speedModifier = tonumber( baseline.speedModifier or baseline[2] ) or 0
	return {
		type = toolType,
		material = material.key,
		miningSpeed = material.speed,
		attackDamage = 1 + damageBaseline + material.attackBonus,
		attackSpeed = math.max( 0.1, 4 + speedModifier ),
		damagePerAttack = tonumber( baseline.damagePerAttack ) or ( toolType == "sword" and 1 or 2 ),
		-- ToolMaterial#applySwordProperties constructs Tool(..., damagePerBlock=2);
		-- ordinary tool properties use damagePerBlock=1.
		damagePerBlock = toolType == "sword" and 2 or 1,
		disableBlockingSeconds = toolType == "axe" and 5 or 0,
	}
end

function MC.ItemAttackSpec( stackOrDefinition )
	local tool = MC.ItemToolSpec( stackOrDefinition )
	if tool then return tool end
	local name = pathName( stackOrDefinition )
	if name == "trident" then
		return { type = "trident", attackDamage = 9, attackSpeed = 1.1, damagePerAttack = 1, disableBlockingSeconds = 0 }
	end
	return { type = "hand", attackDamage = 1, attackSpeed = 4, damagePerAttack = 0, disableBlockingSeconds = 0 }
end

function MC.ItemShieldSpec( stackOrDefinition )
	if pathName( stackOrDefinition ) ~= "shield" then return nil end
	return {
		blockDelay = 0.25,
		horizontalAngle = 90,
		damageThreshold = 3,
		damageBase = 1,
		damageFactor = 1,
	}
end

function MC.ArmorDamageAfterAbsorb( damage, armor, toughness )
	damage = math.max( 0, tonumber( damage ) or 0 )
	armor = math.Clamp( tonumber( armor ) or 0, 0, 20 )
	toughness = math.max( 0, tonumber( toughness ) or 0 )
	local toughnessScale = 2 + toughness / 4
	local effective = math.Clamp( armor - damage / toughnessScale, armor * 0.2, 20 )
	return damage * ( 1 - effective / 25 )
end

function MC.ArmorDurabilityDamageForHit( damage )
	return math.max( 1, math.floor( math.max( 0, tonumber( damage ) or 0 ) / 4 ) )
end

function MC.ItemAttackStrengthScale( elapsed, attackSpeed )
	attackSpeed = math.max( 0.1, tonumber( attackSpeed ) or 4 )
	elapsed = tonumber( elapsed )
	if elapsed == nil then return 1 end
	return math.Clamp( elapsed / ( 1 / attackSpeed ), 0, 1 )
end

function MC.ItemAttackDamageAtStrength( baseDamage, strength )
	baseDamage = math.max( 0, tonumber( baseDamage ) or 0 )
	strength = math.Clamp( tonumber( strength ) or 0, 0, 1 )
	return baseDamage * ( 0.2 + strength * strength * 0.8 )
end

function MC.ItemShieldDurabilityDamage( stackOrDefinition, blockedDamage )
	local spec = MC.ItemShieldSpec( stackOrDefinition )
	blockedDamage = math.max( 0, tonumber( blockedDamage ) or 0 )
	if not spec or blockedDamage < ( tonumber( spec.damageThreshold ) or 0 ) then return 0 end
	return math.max( 0, math.floor( ( tonumber( spec.damageBase ) or 0 )
		+ ( tonumber( spec.damageFactor ) or 0 ) * blockedDamage ) )
end
