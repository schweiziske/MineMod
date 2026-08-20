-- CustomHeadLayer and vanilla SkullModel adapters for armor stands.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local SKULL_TEXTURES = {
	skeleton = "mc/entity/skeleton/skeleton.png",
	wither_skeleton = "mc/entity/skeleton/wither_skeleton.png",
	zombie = "mc/entity/zombie/zombie.png",
	creeper = "mc/entity/creeper/creeper.png",
	dragon = "mc/entity/enderdragon/dragon.png",
	piglin = "mc/entity/piglin/piglin.png",
	player = "mc/entity/player/slim/steve.png",
}

local function pose( ent )
	local getter = ent.GetArmorStandHeadPose
	return getter and getter( ent ) or Angle( 0, 0, 0 )
end

local function headBasis( ent, root, baseX, baseY, baseZ, small )
	local transform = D.ArmorStandHeadTransform( small )
	local unit = M.BlockSize() / 16
	local pivot = transform.pivot
	local origin = root + baseX * ( pivot.x * unit ) + baseY * ( pivot.y * unit )
		+ baseZ * ( pivot.z * unit )
	local xAxis, yAxis, zAxis = D.ModelPartRenderBasis( baseX, baseY, baseZ, pose( ent ) )
	return origin, xAxis, yAxis, zAxis, transform.scale
end

local function drawCube( origin, xAxis, yAxis, zAxis, scale, material, cube, textureSize )
	return M.DrawModelCube( origin, xAxis, yAxis, zAxis, cube, material, color_white, {
		unit = M.BlockSize() / 16 * scale,
		textureWidth = textureSize[1], textureHeight = textureSize[2],
	} )
end

local function drawSimpleSkull( kind, origin, xAxis, yAxis, zAxis, scale, material )
	local textureSize = ( kind == "player" or kind == "zombie" )
		and { 64, 64 } or { 64, 32 }
	local drawn = drawCube( origin, xAxis, yAxis, zAxis, scale, material,
		{ box = { -4, -8, -4, 8, 8, 8 }, uv = { 0, 0 }, grow = 0 }, textureSize )
	if kind == "player" or kind == "zombie" then
		drawn = drawCube( origin, xAxis, yAxis, zAxis, scale, material,
			{ box = { -4, -8, -4, 8, 8, 8 }, uv = { 32, 0 }, grow = 0.25 }, textureSize ) or drawn
	end
	return drawn
end

local function drawPiglinSkull( origin, xAxis, yAxis, zAxis, scale, material, animationPos )
	local drawn = false
	for _, cube in ipairs( {
		{ box = { -5, -8, -4, 10, 8, 8 }, uv = { 0, 0 } },
		{ box = { -2, -4, -5, 4, 4, 1 }, uv = { 31, 1 } },
		{ box = { 2, -2, -5, 1, 2, 1 }, uv = { 2, 4 } },
		{ box = { -3, -2, -5, 1, 2, 1 }, uv = { 2, 0 } },
	} ) do drawn = drawCube( origin, xAxis, yAxis, zAxis, scale, material, cube, { 64, 64 } ) or drawn end
	local function ear( pivot, angle, cube )
		local earOrigin = origin + xAxis * ( pivot[1] / 16 * M.BlockSize() * scale )
			+ yAxis * ( pivot[2] / 16 * M.BlockSize() * scale )
		local ex, ey, ez = D.ModelPartRenderBasis( xAxis, yAxis, zAxis, Angle( 0, 0, angle ) )
		return drawCube( earOrigin, ex, ey, ez, scale, material, cube, { 64, 64 } )
	end
	local leftRotation, rightRotation = D.PiglinHeadEarRotations( animationPos )
	drawn = ear( { 4.5, -6 }, math.deg( leftRotation ),
		{ box = { 0, 0, -2, 1, 5, 4 }, uv = { 51, 6 } } ) or drawn
	drawn = ear( { -4.5, -6 }, math.deg( rightRotation ),
		{ box = { -1, 0, -2, 1, 5, 4 }, uv = { 39, 6 } } ) or drawn
	return drawn
end

local function drawDragonSkull( origin, xAxis, yAxis, zAxis, scale, material, animationPos )
	local animation = D.DragonHeadAnimation( animationPos )
	local headScale = scale * animation.headScale
	local headOrigin = origin + yAxis * ( animation.headOffsetY / 16 * M.BlockSize() * scale )
	local drawn = false
	for _, cube in ipairs( {
		{ box = { -6, -1, -24, 12, 5, 16 }, uv = { 176, 44 } },
		{ box = { -8, -8, -10, 16, 16, 16 }, uv = { 112, 30 } },
		{ box = { -5, -12, -4, 2, 4, 6 }, uv = { 0, 0 }, mirror = true },
		{ box = { -5, -3, -22, 2, 2, 4 }, uv = { 112, 0 }, mirror = true },
		{ box = { 3, -12, -4, 2, 4, 6 }, uv = { 0, 0 } },
		{ box = { 3, -3, -22, 2, 2, 4 }, uv = { 112, 0 } },
	} ) do drawn = drawCube( headOrigin, xAxis, yAxis, zAxis, headScale, material, cube, { 256, 256 } ) or drawn end
	local jawOrigin = headOrigin + yAxis * ( 4 / 16 * M.BlockSize() * headScale )
		+ zAxis * ( -8 / 16 * M.BlockSize() * headScale )
	local jawX, jawY, jawZ = D.ModelPartRenderBasis( xAxis, yAxis, zAxis,
		Angle( math.deg( animation.jawXRot ), 0, 0 ) )
	drawn = drawCube( jawOrigin, jawX, jawY, jawZ, headScale, material,
		{ box = { -6, 0, -16, 12, 4, 16 }, uv = { 176, 65 } }, { 256, 256 } ) or drawn
	return drawn
end

local function drawSkull( ent, stack, root, baseX, baseY, baseZ, small, animationPos )
	local kind = D.ArmorStandSkullType( stack )
	local texture = kind and SKULL_TEXTURES[kind]
	local material = texture and M.Material( "armor_skull_" .. kind, texture ) or nil
	if not material then return false end
	local origin, xAxis, yAxis, zAxis, scale = headBasis( ent, root, baseX, baseY, baseZ, small )
	-- CustomHeadLayer skull branch: translateToHead, then uniform 1.1875.
	scale = scale * 1.1875
	if kind == "piglin" then
		return drawPiglinSkull( origin, xAxis, yAxis, zAxis, scale, material, animationPos )
	end
	if kind == "dragon" then
		return drawDragonSkull( origin, xAxis, yAxis, zAxis, scale, material, animationPos )
	end
	return drawSimpleSkull( kind, origin, xAxis, yAxis, zAxis, scale, material )
end

local function drawHeadItem( ent, stack, root, baseX, baseY, baseZ, small )
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer or not renderer.DrawHeldItem then return false end
	local origin, xAxis, yAxis, zAxis, scale = headBasis( ent, root, baseX, baseY, baseZ, small )
	-- translate(0,-0.25,0), Y=180, scale(0.625,-0.625,-0.625).
	origin = origin + yAxis * ( -0.25 * M.BlockSize() * scale )
	xAxis, zAxis = -xAxis, -zAxis
	yAxis, zAxis = -yAxis, -zAxis
	local angle = xAxis:Angle()
	local referenceUp = angle:Up()
	angle.r = math.deg( math.atan2( referenceUp:Cross( yAxis ):Dot( xAxis ), referenceUp:Dot( yAxis ) ) )
	return renderer.DrawHeldItem( stack, origin, angle, M.BlockSize() * scale * 0.625,
		color_white, { displayContext = "head", worldItem = true,
			parentBasis = { xAxis = xAxis, yAxis = yAxis, zAxis = zAxis } } ) == true
end

function R.DrawArmorStandHeadLayer( ent, root, baseX, baseY, baseZ, small, animation )
	if not ent.GetArmorStandSlot then return false end
	local stack = ent:GetArmorStandSlot( "head" )
	local kind = D.ArmorStandHeadLayerKind( stack )
	if kind == "skull" then
		return drawSkull( ent, stack, root, baseX, baseY, baseZ, small,
			animation and animation.wornHeadAnimationPos or 0 )
	end
	if kind == "item" then return drawHeadItem( ent, stack, root, baseX, baseY, baseZ, small ) end
	return false
end
