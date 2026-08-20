-- HumanoidArmorLayer/EquipmentLayerRenderer adapter for armor stands.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local PARTS = {
	head = { pivot = { 0, 1, 0 }, box = { -4, -8, -4, 8, 8, 8 }, uv = { 0, 0 }, pose = "Head" },
	hat = { pivot = { 0, 1, 0 }, box = { -4, -8, -4, 8, 8, 8 }, uv = { 32, 0 }, pose = "Head", transform = "head" },
	body = { pivot = { 0, 0, 0 }, box = { -4, 0, -2, 8, 12, 4 }, uv = { 16, 16 }, pose = "Body" },
	rightArm = { pivot = { -5, 2, 0 }, box = { -3, -2, -2, 4, 12, 4 }, uv = { 40, 16 }, pose = "RightArm" },
	leftArm = { pivot = { 5, 2, 0 }, box = { -1, -2, -2, 4, 12, 4 }, uv = { 40, 16 }, pose = "LeftArm", mirror = true },
	rightLeg = { pivot = { -1.9, 11, 0 }, box = { -2, 0, -2, 4, 12, 4 }, uv = { 0, 16 }, pose = "RightLeg" },
	leftLeg = { pivot = { 1.9, 11, 0 }, box = { -2, 0, -2, 4, 12, 4 }, uv = { 0, 16 }, pose = "LeftLeg", mirror = true },
}

local function pose( ent, name )
	local getter = ent["GetArmorStand" .. name .. "Pose"]
	return getter and getter( ent ) or Angle( 0, 0, 0 )
end

local function material( layerType, texture )
	local key = "armor_equipment_" .. layerType .. "_" .. texture
	return M.Material( key, "mc/entity/equipment/" .. layerType .. "/" .. texture .. ".png" )
end

local function colorForRGB( rgb )
	rgb = math.floor( tonumber( rgb ) or 16777215 ) % 16777216
	return Color( math.floor( rgb / 65536 ) % 256,
		math.floor( rgb / 256 ) % 256, rgb % 256, 255 )
end

local function partOrigin( root, baseX, baseY, baseZ, descriptor, small )
	local partName = descriptor.transform
		or descriptor.pose == "LeftArm" and "leftArm"
		or descriptor.pose == "RightArm" and "rightArm"
		or descriptor.pose == "LeftLeg" and "leftLeg"
		or descriptor.pose == "RightLeg" and "rightLeg"
		or string.lower( descriptor.pose or "body" )
	local pivot, scale = D.ArmorStandModelPartTransform( partName, descriptor.pivot, small )
	local unit = M.BlockSize() / 16
	return root + baseX * ( pivot.x * unit ) + baseY * ( pivot.y * unit )
		+ baseZ * ( pivot.z * unit ), scale
end

local function drawPart( ent, root, baseX, baseY, baseZ, slot, partName,
	materialValue, color, small, options )
	local descriptor = PARTS[partName]
	if not descriptor then return false end
	local origin, partScale = partOrigin( root, baseX, baseY, baseZ, descriptor, small )
	local xAxis, yAxis, zAxis = D.ModelPartRenderBasis(
		baseX, baseY, baseZ, pose( ent, descriptor.pose ) )
	return M.DrawModelCube( origin, xAxis, yAxis, zAxis, {
		box = descriptor.box, uv = descriptor.uv, mirror = descriptor.mirror,
		grow = D.ArmorStandArmorDeformation( slot, partName ),
	}, materialValue, color, {
		unit = M.BlockSize() / 16 * partScale,
		textureWidth = 64, textureHeight = 32,
		uvTransform = options and options.uvTransform or nil,
	} )
end

local function drawGeometry( ent, root, baseX, baseY, baseZ, slot,
	materialValue, color, small, options )
	local drawn = false
	for _, partName in ipairs( D.ArmorStandArmorParts( slot ) ) do
		drawn = drawPart( ent, root, baseX, baseY, baseZ, slot, partName,
			materialValue, color, small, options ) or drawn
	end
	return drawn
end

local GLINT_ROTATION = math.rad( 10 )
local GLINT_SCALE = 0.16
local GLINT_STRENGTH = 0.5
local GLINT_MATERIAL = Material( "mc/misc/enchanted_glint_armor.png",
	"smooth noclamp vertexcolor vertexalpha nocull" )
local GLINT_BLEND_AVAILABLE = render and render.OverrideBlend
	and BLEND_SRC_COLOR ~= nil and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil

local function glintUV( u, v )
	local now = RealTime and RealTime() or ( CurTime and CurTime() or 0 )
	local millis = now * 1000 * 8
	local offsetU = -( millis % 110000 ) / 110000
	local offsetV = ( millis % 30000 ) / 30000
	local cosine, sine = math.cos( GLINT_ROTATION ), math.sin( GLINT_ROTATION )
	u, v = u * GLINT_SCALE, v * GLINT_SCALE
	return u * cosine - v * sine + offsetU, u * sine + v * cosine + offsetV
end

local function beginGlint()
	if GLINT_BLEND_AVAILABLE then
		render.OverrideBlend( true, BLEND_SRC_COLOR, BLEND_ONE, BLENDFUNC_ADD,
			BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD )
	end
	render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
	render.SetBlend( 1 )
end

local function endGlint()
	if GLINT_BLEND_AVAILABLE then render.OverrideBlend( false ) end
	render.SetColorModulation( 1, 1, 1 )
	render.SetBlend( 1 )
end

-- EquipmentLayerRenderer uses the same armorEntityGlint pass for HUMANOID and
-- WINGS layers. Expose the single Source-backed pass to cl_armor_wings.lua.
R.EquipmentGlint = {
	material = GLINT_MATERIAL,
	uv = glintUV,
	begin = beginGlint,
	finish = endGlint,
}

local function drawArmorPiece( ent, root, baseX, baseY, baseZ, slot, small )
	local stack = ent:GetArmorStandSlot( slot )
	local layers, _, layerType = D.ArmorStandEquipmentLayers( stack, slot )
	if not layers then return false end
	local renderFoil = MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) == true
	local drawn = false
	for _, layer in ipairs( layers ) do
		local rgb = D.EquipmentLayerRGB( stack, layer )
		local layerMaterial = rgb and material( layerType, layer.texture ) or nil
		if layerMaterial then
			drawn = drawGeometry( ent, root, baseX, baseY, baseZ, slot,
				layerMaterial, colorForRGB( rgb ), small ) or drawn
			if renderFoil and GLINT_MATERIAL and not ( GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() ) then
				beginGlint()
				drawGeometry( ent, root, baseX, baseY, baseZ, slot,
					GLINT_MATERIAL, color_white, small, { uvTransform = glintUV } )
				endGlint()
			end
			renderFoil = false
		end
	end
	return drawn
end

function R.DrawArmorStandArmor( ent, root, baseX, baseY, baseZ, small )
	if not ent.GetArmorStandSlot then return false end
	local drawn = false
	-- HumanoidArmorLayer#submit order is chest, legs, feet, head.
	for _, slot in ipairs( { "chest", "legs", "feet", "head" } ) do
		drawn = drawArmorPiece( ent, root, baseX, baseY, baseZ, slot, small ) or drawn
	end
	return drawn
end
