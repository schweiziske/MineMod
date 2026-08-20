-- Source-backed equipment-layer metadata used by ArmorStandRenderer layers.
-- EquipmentClientInfo JSON is authoritative; this table contains only the
-- vanilla humanoid assets that exist under out/assets/minecraft/equipment/.

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local LEATHER_UNDYED = -6265536

local SINGLE_LAYER_ASSETS = {
	chainmail = true, copper = true, diamond = true, gold = true,
	iron = true, netherite = true,
}

local function armorLayers( texture )
	return {
		humanoid = { { texture = texture } },
		humanoid_leggings = { { texture = texture } },
	}
end

D.EquipmentClientInfo = D.EquipmentClientInfo or {
	leather = {
		humanoid = {
			{ texture = "leather", dyeable = LEATHER_UNDYED },
			{ texture = "leather_overlay" },
		},
		humanoid_leggings = {
			{ texture = "leather", dyeable = LEATHER_UNDYED },
			{ texture = "leather_overlay" },
		},
	},
	turtle_scute = { humanoid = { { texture = "turtle_scute" } } },
	elytra = { wings = { { texture = "elytra", usePlayerTexture = true } } },
}
for asset in pairs( SINGLE_LAYER_ASSETS ) do
	D.EquipmentClientInfo[asset] = D.EquipmentClientInfo[asset] or armorLayers( asset )
end

local function component( stack, name )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil, false end
	local namespaced = "minecraft:" .. name
	if components[namespaced] ~= nil then return components[namespaced], true end
	if components[name] ~= nil then return components[name], true end
	return nil, false
end

local function identifier( value )
	if type( value ) == "table" then
		value = value.id or value.asset_id or value.assetId or value.name or value.value
	end
	if type( value ) ~= "string" or value == "" then return nil end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	return string.lower( value )
end

local function path( value )
	value = identifier( value )
	if not value then return nil end
	return string.match( value, "^minecraft:(.+)$" )
end

local function fallbackAssetAndSlot( item )
	local itemPath = path( item )
	if not itemPath then return nil end
	if itemPath == "turtle_helmet" then return "turtle_scute", "head" end
	local materialNames = {
		leather = "leather", copper = "copper", chainmail = "chainmail",
		iron = "iron", diamond = "diamond", golden = "gold", netherite = "netherite",
	}
	local slots = { helmet = "head", chestplate = "chest", leggings = "legs", boots = "feet" }
	for material, asset in pairs( materialNames ) do
		for suffix, slot in pairs( slots ) do
			if itemPath == material .. "_" .. suffix then return asset, slot end
		end
	end
	return nil
end

function D.ArmorStandEquipmentAsset( stack, expectedSlot )
	if type( stack ) ~= "table" then return nil end
	expectedSlot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( expectedSlot ) or expectedSlot
	local equippable = select( 1, component( stack, "equippable" ) )
	if type( equippable ) == "table" then
		local slot = equippable.slot or equippable.equipment_slot or equippable.equipmentSlot
		slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or slot
		if slot ~= expectedSlot then return nil end
		local asset = path( equippable.asset_id or equippable.assetId or equippable.asset )
		return asset and D.EquipmentClientInfo[asset] and asset or nil
	end
	local asset, slot = fallbackAssetAndSlot( stack.item or stack.name )
	return slot == expectedSlot and D.EquipmentClientInfo[asset] and asset or nil
end

function D.ArmorStandEquipmentLayerType( slot )
	return slot == "legs" and "humanoid_leggings" or "humanoid"
end

function D.ArmorStandEquipmentLayers( stack, slot )
	local asset = D.ArmorStandEquipmentAsset( stack, slot )
	local layerType = D.ArmorStandEquipmentLayerType( slot )
	local info = asset and D.EquipmentClientInfo[asset] or nil
	return info and info[layerType] or nil, asset, layerType
end

local function rgb( value )
	if type( value ) == "table" then value = value.rgb or value.color or value.value end
	value = tonumber( value )
	if not value then return nil end
	return math.floor( value ) % 16777216
end

-- EquipmentLayerRenderer#getColorForLayer: non-dyeable is opaque white;
-- dyeable uses DYED_COLOR, then color_when_undyed, and skips when both absent.
function D.EquipmentLayerRGB( stack, layer )
	if type( layer ) ~= "table" then return nil end
	if layer.dyeable == nil then return 16777215 end
	local dyed = rgb( select( 1, component( stack, "dyed_color" ) ) )
	return dyed or rgb( layer.dyeable )
end

function D.ArmorStandArmorParts( slot )
	local source = ({
		head = { "head", "hat" },
		chest = { "body", "leftArm", "rightArm" },
		legs = { "body", "leftLeg", "rightLeg" },
		feet = { "leftLeg", "rightLeg" },
	})[slot]
	if not source then return {} end
	local output = {}
	for index, value in ipairs( source ) do output[index] = value end
	return output
end

-- LayerDefinitions uses outer=1.0 and inner=0.5. ArmorStandArmorModel then
-- extends every leg by -0.1 and the head's hat child by +0.5.
function D.ArmorStandArmorDeformation( slot, part )
	local deformation = slot == "legs" and 0.5 or 1.0
	if part == "leftLeg" or part == "rightLeg" then deformation = deformation - 0.1 end
	if part == "hat" then deformation = deformation + 0.5 end
	return deformation
end

local SKULL_TYPES = {
	["minecraft:skeleton_skull"] = "skeleton",
	["minecraft:wither_skeleton_skull"] = "wither_skeleton",
	["minecraft:zombie_head"] = "zombie",
	["minecraft:creeper_head"] = "creeper",
	["minecraft:dragon_head"] = "dragon",
	["minecraft:piglin_head"] = "piglin",
	["minecraft:player_head"] = "player",
}

function D.ArmorStandSkullType( stack )
	return SKULL_TYPES[identifier( type( stack ) == "table" and ( stack.item or stack.name ) or stack )]
end

function D.ArmorStandHeadLayerKind( stack )
	if D.ArmorStandSkullType( stack ) then return "skull" end
	if D.ArmorStandEquipmentAsset( stack, "head" ) then return "armor" end
	return type( stack ) == "table" and "item" or nil
end

-- CustomHeadLayer applies the small model's transformed head before its own
-- skull/item transform.  Values are ModelPart pixels/scale, not Source units.
function D.ArmorStandHeadTransform( small )
	local pivot, scale = D.ArmorStandModelPartTransform( "head", { 0, 1, 0 }, small )
	return { pivot = pivot, scale = scale }
end

-- PiglinHeadModel#setupAnim.  The animation value is the parent's
-- wornHeadAnimationPos; ArmorStand is stationary in the game adapter, so its
-- normal value is zero, but keeping the full formula avoids baking an observed
-- pose into the renderer.
function D.PiglinHeadEarRotations( animationPos )
	animationPos = tonumber( animationPos ) or 0
	local left = -( math.cos( animationPos * math.pi * 0.2 * 1.2 ) + 2.5 ) * 0.2
	local right = ( math.cos( animationPos * math.pi * 0.2 ) + 2.5 ) * 0.2
	return left, right
end

-- DragonHeadModel#createHeadLayer/#setupAnim. PartPose.scaled(0.75) scales
-- both the head pivot and the cubes before the jaw child is applied.
function D.DragonHeadAnimation( animationPos )
	animationPos = tonumber( animationPos ) or 0
	return {
		headOffsetY = -7.986666 * 0.75,
		headScale = 0.75,
		jawXRot = ( math.sin( animationPos * math.pi * 0.2 ) + 1 ) * 0.2,
	}
end

-- ElytraModel.BABY_TRANSFORMER is MeshTransformer.scaling(0.5).  That
-- transformer scales the model root and then translates it by 24.016*(1-f),
-- while WingsLayer's +Z 0.125 translation remains outside the model scale.
function D.ArmorStandElytraTransform( small )
	local scale = small == true and 0.5 or 1
	return { scale = scale, yOffset = 24.016 * ( 1 - scale ), zOffset = 0.125 }
end

local function lerp( amount, first, second )
	return first + amount * ( second - first )
end

-- ElytraAnimationState#tick target selection. ArmorStand cannot crouch or
-- fall-fly, but the complete source formula is kept here and tested so the
-- default branch cannot silently drift from the Java implementation.
function D.ElytraAnimationTargets( input )
	input = input or {}
	if input.fallFlying == true then
		local movement = input.movement or {}
		local x, y, z = tonumber( movement.x or movement[1] ) or 0,
			tonumber( movement.y or movement[2] ) or 0,
			tonumber( movement.z or movement[3] ) or 0
		local ratio = 1
		if y < 0 then
			local magnitude = math.sqrt( x * x + y * y + z * z )
			if magnitude > 0 then ratio = 1 - ( -y / magnitude ) ^ 1.5 end
		end
		return lerp( ratio, math.pi / 12, math.pi / 9 ), 0,
			lerp( ratio, -math.pi / 12, -math.pi / 2 )
	end
	if input.crouching == true then return math.pi * 2 / 9, 0.08726646, -math.pi / 4 end
	return math.pi / 12, 0, -math.pi / 12
end

function D.NewElytraAnimationState()
	return { rotX = 0, rotY = 0, rotZ = 0, rotXOld = 0, rotYOld = 0, rotZOld = 0 }
end

local function advanceElytraAxis( value, target, ticks )
	local currentDecay = 0.7 ^ ticks
	local oldDecay = ticks == 1 and 1 or 0.7 ^ ( ticks - 1 )
	return target + ( value - target ) * oldDecay,
		target + ( value - target ) * currentDecay
end

-- ElytraAnimationState applies `(target-current)*0.3` once per Minecraft tick.
-- The closed form preserves that exact recurrence without looping after an
-- armor stand has spent a long time outside the render PVS.
function D.AdvanceElytraAnimation( state, ticks, input )
	state = state or D.NewElytraAnimationState()
	ticks = math.max( 0, math.floor( tonumber( ticks ) or 0 ) )
	if ticks == 0 then return state end
	local targetX, targetY, targetZ = D.ElytraAnimationTargets( input )
	state.rotXOld, state.rotX = advanceElytraAxis( state.rotX or 0, targetX, ticks )
	state.rotYOld, state.rotY = advanceElytraAxis( state.rotY or 0, targetY, ticks )
	state.rotZOld, state.rotZ = advanceElytraAxis( state.rotZ or 0, targetZ, ticks )
	return state
end

function D.SampleElytraAnimation( state, partialTicks )
	state = state or D.NewElytraAnimationState()
	partialTicks = tonumber( partialTicks ) or 0
	return {
		x = lerp( partialTicks, state.rotXOld or 0, state.rotX or 0 ),
		y = lerp( partialTicks, state.rotYOld or 0, state.rotY or 0 ),
		z = lerp( partialTicks, state.rotZOld or 0, state.rotZ or 0 ),
	}
end

function D.ArmorStandElytraAnimationAt( elapsedTicks )
	elapsedTicks = math.max( tonumber( elapsedTicks ) or 0, 0 )
	local wholeTicks = math.floor( elapsedTicks )
	local state = D.AdvanceElytraAnimation( D.NewElytraAnimationState(), wholeTicks )
	return D.SampleElytraAnimation( state, elapsedTicks - wholeTicks )
end

function D.ArmorStandElytraSpec( stack )
	if type( stack ) ~= "table" then return nil end
	local equippable = select( 1, component( stack, "equippable" ) )
	if type( equippable ) == "table" then
		local slot = equippable.slot or equippable.equipment_slot or equippable.equipmentSlot
		slot = MC.NormalizeEquipmentSlot and MC.NormalizeEquipmentSlot( slot ) or slot
		local asset = path( equippable.asset_id or equippable.assetId or equippable.asset )
		if slot == "chest" and asset and D.EquipmentClientInfo[asset]
		and D.EquipmentClientInfo[asset].wings then return asset end
		return nil
	end
	return identifier( stack.item or stack.name ) == "minecraft:elytra" and "elytra" or nil
end
