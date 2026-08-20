-- ArmorStandRenderer/ArmorStandModel adapter.
-- Body geometry and pivots are copied from ArmorStandModel#createBodyLayer.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local MODEL_PARTS = {
	head = { pivot = { 0, 1, 0 }, box = { -1, -7, -1, 2, 7, 2 }, uv = { 0, 0 } },
	body = { pivot = { 0, 0, 0 }, box = { -6, 0, -1.5, 12, 3, 3 }, uv = { 0, 26 } },
	rightArm = { pivot = { -5, 2, 0 }, box = { -2, -2, -1, 2, 12, 2 }, uv = { 24, 0 } },
	leftArm = { pivot = { 5, 2, 0 }, box = { 0, -2, -1, 2, 12, 2 }, uv = { 32, 16 }, mirror = true },
	rightLeg = { pivot = { -1.9, 12, 0 }, box = { -1, 0, -1, 2, 11, 2 }, uv = { 8, 0 } },
	leftLeg = { pivot = { 1.9, 12, 0 }, box = { -1, 0, -1, 2, 11, 2 }, uv = { 40, 16 }, mirror = true },
	rightBodyStick = { pivot = { 0, 0, 0 }, box = { -3, 3, -1, 2, 7, 2 }, uv = { 16, 0 }, bodyPose = true },
	leftBodyStick = { pivot = { 0, 0, 0 }, box = { 1, 3, -1, 2, 7, 2 }, uv = { 48, 16 }, bodyPose = true },
	shoulderStick = { pivot = { 0, 0, 0 }, box = { -4, 10, -1, 8, 2, 2 }, uv = { 0, 48 }, bodyPose = true },
	basePlate = { pivot = { 0, 12, 0 }, box = { -6, 11, -6, 12, 1, 12 }, uv = { 0, 32 }, base = true },
}

local function material()
	return M.Material( "armorstand", "mc/entity/armorstand/armorstand.png" )
end

local function pose( ent, name )
	local getter = ent["GetArmorStand" .. name .. "Pose"]
	return getter and getter( ent ) or Angle( 0, 0, 0 )
end

local function modelBasis( ent )
	local yaw = tonumber( ent.GetArmorStandYaw and ent:GetArmorStandYaw() ) or 0
	local wobble = D.ArmorStandWiggleDegrees(
		( CurTime and CurTime() or 0 ) * 20,
		tonumber( ent.GetArmorStandLastHit and ent:GetArmorStandLastHit() ) or 0, 0 )
	local rotation = math.rad( 180 - yaw + wobble )
	-- LivingEntityRenderer maps model X/Y/Z through scale(-1,-1,1), then the
	-- Minecraft Y-up axis is mapped to Source Z-up.
	return Vector( -math.cos( rotation ), -math.sin( rotation ), 0 ),
		Vector( 0, 0, -1 ), Vector( -math.sin( rotation ), math.cos( rotation ), 0 )
end

local function partPoint( root, xAxis, yAxis, zAxis, x, y, z, unit )
	return root + xAxis * ( x * unit ) + yAxis * ( y * unit ) + zAxis * ( z * unit )
end

local function angleFromBasis( forward, up )
	local angle = forward:Angle()
	local referenceUp = angle:Up()
	local sine = referenceUp:Cross( up ):Dot( forward )
	local cosine = referenceUp:Dot( up )
	angle.r = math.deg( math.atan2( sine, cosine ) )
	return angle
end

local function cubeFaces( texU, texV, width, height, depth, mirror )
	local u0, u1 = texU, texU + depth
	local u2, u22 = u1 + width, u1 + width + width
	local u3, u4 = u2 + depth, u2 + depth + width
	local v0, v1, v2 = texV, texV + depth, texV + depth + height
	local faces = {
		down = { uv = { u1, v0, u2, v1 }, texture = "skin" },
		up = { uv = { u2, v0, u22, v1 }, texture = "skin" },
		west = { uv = { u0, v1, u1, v2 }, texture = "skin" },
		north = { uv = { u1, v1, u2, v2 }, texture = "skin" },
		east = { uv = { u2, v1, u3, v2 }, texture = "skin" },
		south = { uv = { u3, v1, u4, v2 }, texture = "skin" },
	}
	if mirror then
		faces.west, faces.east = faces.east, faces.west
	end
	return faces
end

local function drawPart( root, baseX, baseY, baseZ, name, descriptor, angle,
	small, skin, color )
	local pivot, partScale = D.ArmorStandModelPartTransform( name, descriptor.pivot, small )
	local pivotUnit = M.BlockSize() / 16
	local unit = pivotUnit * partScale
	local pivotWorld = partPoint( root, baseX, baseY, baseZ,
		pivot.x, pivot.y, pivot.z, pivotUnit )
	local xAxis, yAxis, zAxis = D.ModelPartRenderBasis( baseX, baseY, baseZ, angle )
	local box = descriptor.box
	local from = { box[1], box[2], box[3] }
	local to = { box[1] + box[4], box[2] + box[5], box[3] + box[6] }
	if descriptor.mirror then from[1], to[1] = to[1], from[1] end
	-- M.Cuboid is block-model specific; ModelPart uses Y-down pixels, so emit
	-- its six faces directly in the posed ModelPart basis.
	local function p( x, y, z ) return partPoint( pivotWorld, xAxis, yAxis, zAxis, x, y, z, unit ) end
	local points = {
		p( from[1], from[2], from[3] ), p( to[1], from[2], from[3] ),
		p( to[1], to[2], from[3] ), p( from[1], to[2], from[3] ),
		p( from[1], from[2], to[3] ), p( to[1], from[2], to[3] ),
		p( to[1], to[2], to[3] ), p( from[1], to[2], to[3] ),
	}
	local faces = cubeFaces( descriptor.uv[1], descriptor.uv[2], box[4], box[5], box[6], descriptor.mirror )
	local corners = {
		down = { 6, 5, 1, 2 }, up = { 3, 4, 8, 7 }, west = { 1, 5, 8, 4 },
		north = { 2, 1, 4, 3 }, east = { 6, 2, 3, 7 }, south = { 5, 6, 7, 8 },
	}
	local drawn = false
	for name, order in pairs( corners ) do
		local uv = faces[name].uv
		local normalized = { uv[1] / 64, uv[2] / 64, uv[3] / 64, uv[4] / 64 }
		local polygon = { points[order[1]], points[order[2]], points[order[3]], points[order[4]] }
		if descriptor.mirror then polygon = { polygon[4], polygon[3], polygon[2], polygon[1] } end
		drawn = M.Quad( polygon,
			normalized, skin, color ) or drawn
	end
	return drawn
end

local function drawHandItem( ent, renderer, root, baseX, baseY, baseZ,
	arm, slot, small, color )
	local stack = ent:GetArmorStandSlot( slot )
	if not stack then return false end
	local armName = arm == "left" and "LeftArm" or "RightArm"
	local transform = D.ArmorStandHandTransform(
		arm, pose( ent, armName ), small, baseX, baseY, baseZ )
	local position = root + transform.position * M.BlockSize()
	return renderer.DrawHeldItem( stack, position,
		angleFromBasis( transform.xAxis, transform.yAxis ),
		M.BlockSize() * transform.scale, color, {
			displayContext = transform.displayContext,
			worldItem = true,
			parentBasis = {
				xAxis = transform.xAxis, yAxis = transform.yAxis, zAxis = transform.zAxis,
			},
		} ) == true
end

local function customName( ent )
	if not ent.GetArmorStandHasCustomName or ent:GetArmorStandHasCustomName() ~= true then return nil end
	if not ent.GetArmorStandCustomName then return nil end
	return tostring( ent:GetArmorStandCustomName() or "" )
end

local function drawName( ent, name, scale )
	if name == nil or name == "" or not cam or not cam.Start3D2D then return end
	local pos = ent:GetPos() + Vector( 0, 0, M.BlockSize() * 2.15 * scale )
	local eye = EyePos and EyePos() or pos + Vector( 1, 0, 0 )
	local angle = ( eye - pos ):Angle()
	angle:RotateAroundAxis( angle:Right(), 90 )
	angle:RotateAroundAxis( angle:Up(), -90 )
	cam.Start3D2D( pos, angle, 0.08 )
		draw.SimpleTextOutlined( name, "DermaDefault", 0, 0, color_white,
			TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, Color( 0, 0, 0, 180 ) )
	cam.End3D2D()
end

local function layerAnimation( ent )
	local now = CurTime and CurTime() or 0
	local createdAt = tonumber( ent.MCArmorStandAnimationCreatedAt )
	if not createdAt then
		createdAt = now
		ent.MCArmorStandAnimationCreatedAt = createdAt
	end
	local elytra = D.ArmorStandElytraAnimationAt( math.max( 0, now - createdAt ) * 20 )
	return {
		-- LivingEntityRenderer uses walkAnimationPos. The adapter ArmorStand is
		-- MOVETYPE_NONE, so its stationary source value remains zero.
		wornHeadAnimationPos = 0,
		elytraRotX = elytra.x, elytraRotY = elytra.y, elytraRotZ = elytra.z,
	}
end

function R.DrawArmorStand( ent )
	if not IsValid( ent ) or ent.IsArmorStandInvisible and ent:IsArmorStandInvisible() then return false end
	local skin = material()
	if not skin then return false end
	local position = M.RenderPosition( ent )
	if not position then return false end
	local root = position + Vector( 0, 0,
		D.ArmorStandRenderRootOffset() * M.BlockSize() )
	local marker = ent.IsArmorStandMarker and ent:IsArmorStandMarker() == true
	local small = ent.IsArmorStandSmall and ent:IsArmorStandSmall() == true
	local scale = small and 0.5 or 1
	-- Marker changes collision/render-type semantics, not model dimensions.
	-- ArmorStandRenderer still selects the big/small baked model.
	if marker then scale = small and 0.5 or 1 end
	local baseX, baseY, baseZ = modelBasis( ent )
	local animation = layerAnimation( ent )
	local color = color_white
	local drawn = false
	for name, descriptor in pairs( MODEL_PARTS ) do
		local visible = true
		if ( name == "leftArm" or name == "rightArm" )
		and not ( ent.ShowArmorStandArms and ent:ShowArmorStandArms() ) then visible = false end
		if descriptor.base and not ( ent.ShowArmorStandBasePlate and ent:ShowArmorStandBasePlate() ) then visible = false end
		if visible then
			local partPose = descriptor.bodyPose and pose( ent, "Body" )
				or name == "head" and pose( ent, "Head" )
				or name == "body" and pose( ent, "Body" )
				or name == "leftArm" and pose( ent, "LeftArm" )
				or name == "rightArm" and pose( ent, "RightArm" )
				or name == "leftLeg" and pose( ent, "LeftLeg" )
				or name == "rightLeg" and pose( ent, "RightLeg" )
				or Angle( 0, descriptor.base and -( ent:GetArmorStandYaw() or 0 ) or 0, 0 )
			drawn = drawPart( root, baseX, baseY, baseZ, name, descriptor, partPose,
				small, skin, color ) or drawn
		end
	end
	-- ArmorStandRenderer registers HumanoidArmorLayer before ItemInHandLayer.
	if R.DrawArmorStandArmor then
		drawn = R.DrawArmorStandArmor( ent, root, baseX, baseY, baseZ, small ) or drawn
	end
	-- ItemInHandLayer: translateToHand, X=-90, Y=180, (+/-1,2,-10)/16,
	-- then the third-person ItemTransform.  ArmorStand keeps adult offsets even
	-- when small; the transformed arm itself supplies the 0.5 child scale.
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if renderer and renderer.DrawHeldItem and ent.GetArmorStandSlot then
		drawn = drawHandItem( ent, renderer, root, baseX, baseY, baseZ,
			"right", "mainhand", small, color ) or drawn
		drawn = drawHandItem( ent, renderer, root, baseX, baseY, baseZ,
			"left", "offhand", small, color ) or drawn
	end
	-- ArmorStandRenderer layer order: WingsLayer, then CustomHeadLayer.
	if R.DrawArmorStandWings then
		drawn = R.DrawArmorStandWings( ent, root, baseX, baseY, baseZ, small, animation ) or drawn
	end
	if R.DrawArmorStandHeadLayer then
		drawn = R.DrawArmorStandHeadLayer( ent, root, baseX, baseY, baseZ, small, animation ) or drawn
	end
	drawName( ent, customName( ent ), math.max( scale, 0.5 ) )
	M.ResetState()
	return drawn
end
