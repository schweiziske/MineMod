-- WingsLayer/ElytraModel adapter for armor stands.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local WINGS = {
	left = { pivot = { 5, 0, 0 },
		box = { -10, 0, 0, 10, 20, 2 }, uv = { 22, 0 } },
	right = { pivot = { -5, 0, 0 },
		box = { 0, 0, 0, 10, 20, 2 }, uv = { 22, 0 }, mirror = true },
}

local function material( asset )
	return M.Material( "armor_wings_" .. asset, "mc/entity/equipment/wings/" .. asset .. ".png" )
end

local function wingRotation( side, animation )
	animation = animation or {}
	local xRot = tonumber( animation.elytraRotX ) or math.pi / 12
	local yRot = tonumber( animation.elytraRotY ) or 0
	local zRot = tonumber( animation.elytraRotZ ) or -math.pi / 12
	if side == "right" then yRot, zRot = -yRot, -zRot end
	return Angle( math.deg( xRot ), math.deg( yRot ), math.deg( zRot ) )
end

local function drawWing( root, baseX, baseY, baseZ, side, descriptor, small,
		animation, materialValue, color, options )
	local transform = D.ArmorStandElytraTransform( small )
	local unit = M.BlockSize() / 16 * transform.scale
	local pivot = descriptor.pivot
	local origin = root + baseZ * ( transform.zOffset * M.BlockSize() )
		+ baseY * ( transform.yOffset / 16 * M.BlockSize() )
		+ baseX * ( pivot[1] * unit ) + baseY * ( pivot[2] * unit )
		+ baseZ * ( pivot[3] * unit )
	local xAxis, yAxis, zAxis = D.ModelPartRenderBasis(
		baseX, baseY, baseZ, wingRotation( side, animation ) )
	return M.DrawModelCube( origin, xAxis, yAxis, zAxis, {
		box = descriptor.box, uv = descriptor.uv, mirror = descriptor.mirror, grow = 1.0,
	}, materialValue, color, { unit = unit, textureWidth = 64, textureHeight = 32,
		uvTransform = options and options.uvTransform or nil } )
end

local function drawBothWings( root, baseX, baseY, baseZ, small, animation,
		materialValue, color, options )
	local drawn = drawWing( root, baseX, baseY, baseZ, "left", WINGS.left,
		small, animation, materialValue, color, options )
	drawn = drawWing( root, baseX, baseY, baseZ, "right", WINGS.right,
		small, animation, materialValue, color, options ) or drawn
	return drawn
end

function R.DrawArmorStandWings( ent, root, baseX, baseY, baseZ, small, animation )
	if not ent.GetArmorStandSlot then return false end
	local stack = ent:GetArmorStandSlot( "chest" )
	local asset = D.ArmorStandElytraSpec( stack )
	local layer = asset and D.EquipmentClientInfo[asset] and D.EquipmentClientInfo[asset].wings
	local materialValue = layer and layer[1] and material( layer[1].texture ) or nil
	if not materialValue then return false end
	local drawn = drawBothWings( root, baseX, baseY, baseZ, small, animation,
		materialValue, color_white )
	local glint = R.EquipmentGlint
	if MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) == true
	and glint and glint.material and not ( glint.material.IsError and glint.material:IsError() ) then
		glint.begin()
		drawBothWings( root, baseX, baseY, baseZ, small, animation,
			glint.material, color_white, { uvTransform = glint.uv } )
		glint.finish()
	end
	return drawn
end
