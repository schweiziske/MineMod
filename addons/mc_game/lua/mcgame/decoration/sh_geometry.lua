-- Coordinate/geometry helpers for decoration entities.  All values returned
-- here are in Minecraft world units; callers convert through MC.API.Coords.

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local function vector( x, y, z )
	if Vector then return Vector( x, y, z ) end
	return { x = x, y = y, z = z }
end

local function add( a, b ) return vector( a.x + b.x, a.y + b.y, a.z + b.z ) end
local function scale( a, n ) return vector( a.x * n, a.y * n, a.z * n ) end
local function dot( a, b ) return a.x * b.x + a.y * b.y + a.z * b.z end
local function cross( a, b )
	return vector( a.y * b.z - a.z * b.y,
		a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x )
end
local function length( value ) return math.sqrt( math.max( dot( value, value ), 0 ) ) end
local function normalized( value )
	local magnitude = length( value )
	return magnitude > 1.0e-12 and scale( value, 1 / magnitude ) or vector( 0, 0, 0 )
end
local function rotateAround( value, axis, degrees )
	local radians = math.rad( tonumber( degrees ) or 0 )
	if math.abs( radians ) < 1.0e-12 then return value end
	axis = normalized( axis )
	local cosine, sine = math.cos( radians ), math.sin( radians )
	return add( add( scale( value, cosine ), scale( cross( axis, value ), sine ) ),
		scale( axis, dot( axis, value ) * ( 1 - cosine ) ) )
end
local function combined( xAxis, yAxis, zAxis, x, y, z )
	return add( add( scale( xAxis, x ), scale( yAxis, y ) ), scale( zAxis, z ) )
end

local function rotationValue( rotation, axis )
	rotation = rotation or {}
	if axis == "x" then return tonumber( rotation.x ) or tonumber( rotation.p ) or tonumber( rotation[1] ) or 0 end
	if axis == "y" then return tonumber( rotation.y ) or tonumber( rotation[2] ) or 0 end
	return tonumber( rotation.z ) or tonumber( rotation.r ) or tonumber( rotation[3] ) or 0
end

-- ModelPart#translateAndRotate uses Quaternionf.rotationZYX(zRot,yRot,xRot).
-- Rotate the current local axes in that same Z, Y, X order.
function D.ModelPartRenderBasis( xAxis, yAxis, zAxis, rotation )
	xAxis = xAxis or vector( 1, 0, 0 )
	yAxis = yAxis or vector( 0, 1, 0 )
	zAxis = zAxis or vector( 0, 0, 1 )
	local zRot, yRot, xRot = rotationValue( rotation, "z" ),
		rotationValue( rotation, "y" ), rotationValue( rotation, "x" )
	if zRot ~= 0 then
		xAxis, yAxis = rotateAround( xAxis, zAxis, zRot ), rotateAround( yAxis, zAxis, zRot )
	end
	if yRot ~= 0 then
		xAxis, zAxis = rotateAround( xAxis, yAxis, yRot ), rotateAround( zAxis, yAxis, yRot )
	end
	if xRot ~= 0 then
		yAxis, zAxis = rotateAround( yAxis, xAxis, xRot ), rotateAround( zAxis, xAxis, xRot )
	end
	return normalized( xAxis ), normalized( yAxis ), normalized( zAxis )
end

-- ItemFrameRenderer#submit applies the frame direction rotations before the
-- block model and item are submitted.  Return those four model axes as plain
-- vectors so the renderer and the plain-Lua assertions share one derivation.
function D.DecorationRenderBasis( value )
	local d = D.Direction( value ) or D.Direction( "south" )
	local normal = vector( d.x, d.y, d.z )
	if not d.horizontal then
		return vector( -1, 0, 0 ),
			d.name == "up" and vector( 0, -1, 0 ) or vector( 0, 1, 0 ),
			vector( -d.x, -d.y, -d.z ), normal
	end
	local left = D.CounterClockwise( d )
	return vector( -left.x, -left.y, -left.z ), vector( 0, 0, 1 ),
		vector( -d.x, -d.y, -d.z ), normal
end

-- FaceInfo.java vertex order. CuboidFace.R0 assigns UVs by vertex index as
-- (minU,minV), (minU,maxV), (maxU,maxV), (maxU,minV).
local BLOCK_MODEL_FACE_CORNERS = {
	down = { { 0, 0, 1 }, { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, 1 } },
	up = { { 0, 1, 0 }, { 0, 1, 1 }, { 1, 1, 1 }, { 1, 1, 0 } },
	north = { { 1, 1, 0 }, { 1, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 } },
	south = { { 0, 1, 1 }, { 0, 0, 1 }, { 1, 0, 1 }, { 1, 1, 1 } },
	west = { { 0, 1, 0 }, { 0, 0, 0 }, { 0, 0, 1 }, { 0, 1, 1 } },
	east = { { 1, 1, 1 }, { 1, 0, 1 }, { 1, 0, 0 }, { 1, 1, 0 } },
}

function D.BlockModelFaceVertices( face, from, to )
	local corners = BLOCK_MODEL_FACE_CORNERS[face]
	if not corners then return nil end
	local output = {}
	for index, corner in ipairs( corners ) do
		output[index] = vector(
			corner[1] == 0 and from[1] or to[1],
			corner[2] == 0 and from[2] or to[2],
			corner[3] == 0 and from[3] or to[3] )
	end
	return output
end

-- HumanoidModel.BABY_TRANSFORMER is BabyModelTransform(true, 16, 0,
-- 2, 2, 24, { "head" }). BabyModelTransform#apply translates each top-level
-- PartPose and then scales both its pivot and cubes.  The head scale is
-- 1.5 / babyHeadScale = 0.75; every other ArmorStandModel part uses 0.5.
function D.ArmorStandModelPartTransform( partName, pivot, small )
	pivot = pivot or { x = 0, y = 0, z = 0 }
	if small ~= true then return vector( pivot.x or pivot[1] or 0,
		pivot.y or pivot[2] or 0, pivot.z or pivot[3] or 0 ), 1 end
	local head = partName == "head"
	local partScale = head and 0.75 or 0.5
	local yOffset = head and 16 or 24
	return vector( ( pivot.x or pivot[1] or 0 ) * partScale,
		( ( pivot.y or pivot[2] or 0 ) + yOffset ) * partScale,
		( pivot.z or pivot[3] or 0 ) * partScale ), partScale
end

-- ArmorStandModel#translateToHand delegates to HumanoidModel#translateToHand,
-- then ItemInHandLayer applies X=-90, Y=180 and the adult ArmorStand offsets
-- (+/-1, 2, -10)/16.  Small stands keep those adult offsets, but the arm's
-- BABY_TRANSFORMER xScale=0.5 scales both the translation and submitted item.
function D.ArmorStandHandTransform( arm, rotation, small, baseX, baseY, baseZ )
	local left = arm == "left" or arm == "offhand"
	local partName = left and "leftArm" or "rightArm"
	local pivot = left and { 5, 2, 0 } or { -5, 2, 0 }
	local transformedPivot, partScale = D.ArmorStandModelPartTransform( partName, pivot, small )
	baseX = baseX or vector( 1, 0, 0 )
	baseY = baseY or vector( 0, 1, 0 )
	baseZ = baseZ or vector( 0, 0, 1 )
	local xAxis, yAxis, zAxis = D.ModelPartRenderBasis( baseX, baseY, baseZ, rotation )
	-- PoseStack.mulPose(Axis.XP.rotationDegrees(-90)), then Axis.YP(180).
	yAxis, zAxis = rotateAround( yAxis, xAxis, -90 ), rotateAround( zAxis, xAxis, -90 )
	xAxis, zAxis = rotateAround( xAxis, yAxis, 180 ), rotateAround( zAxis, yAxis, 180 )
	xAxis, yAxis, zAxis = normalized( xAxis ), normalized( yAxis ), normalized( zAxis )
	local position = combined( baseX, baseY, baseZ,
		transformedPivot.x / 16, transformedPivot.y / 16, transformedPivot.z / 16 )
	local side = left and -1 or 1
	position = add( position, combined( xAxis, yAxis, zAxis,
		side * partScale / 16, 2 * partScale / 16, -10 * partScale / 16 ) )
	return {
		position = position, xAxis = xAxis, yAxis = yAxis, zAxis = zAxis,
		scale = partScale,
		displayContext = left and "thirdperson_lefthand" or "thirdperson_righthand",
	}
end

-- Pure ItemTransform#apply adapter used by assertions.  The held-item renderer
-- consumes the same parent basis; its centred sprite mesh already incorporates
-- ItemTransform's final translate(-0.5,-0.5,-0.5).
function D.ApplyArmorStandItemDisplayTransform( parent, transform, leftHand )
	if type( parent ) ~= "table" then return nil end
	transform = transform or {}
	local rotation = transform.rotation or {}
	local translation = transform.translation or {}
	local itemScale = transform.scale or {}
	local translationX = tonumber( translation.x ) or tonumber( translation[1] ) or 0
	local rotationY = tonumber( rotation.y ) or tonumber( rotation[2] ) or 0
	local rotationZ = tonumber( rotation.z ) or tonumber( rotation[3] ) or 0
	if leftHand == true then
		translationX, rotationY, rotationZ = -translationX, -rotationY, -rotationZ
	end
	local rotationX = tonumber( rotation.x ) or tonumber( rotation[1] ) or 0
	local translationY = tonumber( translation.y ) or tonumber( translation[2] ) or 0
	local translationZ = tonumber( translation.z ) or tonumber( translation[3] ) or 0
	local parentScale = tonumber( parent.scale ) or 1
	local position = add( parent.position, combined( parent.xAxis, parent.yAxis, parent.zAxis,
		translationX * parentScale / 16, translationY * parentScale / 16,
		translationZ * parentScale / 16 ) )
	local xAxis, yAxis, zAxis = parent.xAxis, parent.yAxis, parent.zAxis
	-- ItemTransform uses Quaternionf.rotationXYZ.
	if rotationX ~= 0 then
		yAxis, zAxis = rotateAround( yAxis, xAxis, rotationX ), rotateAround( zAxis, xAxis, rotationX )
	end
	if rotationY ~= 0 then
		xAxis, zAxis = rotateAround( xAxis, yAxis, rotationY ), rotateAround( zAxis, yAxis, rotationY )
	end
	if rotationZ ~= 0 then
		xAxis, yAxis = rotateAround( xAxis, zAxis, rotationZ ), rotateAround( yAxis, zAxis, rotationZ )
	end
	return {
		position = position, xAxis = normalized( xAxis ), yAxis = normalized( yAxis ),
		zAxis = normalized( zAxis ),
		scale = vector( parentScale * ( tonumber( itemScale.x ) or tonumber( itemScale[1] ) or 1 ),
			parentScale * ( tonumber( itemScale.y ) or tonumber( itemScale[2] ) or 1 ),
			parentScale * ( tonumber( itemScale.z ) or tonumber( itemScale[3] ) or 1 ) ),
	}
end

-- LivingEntityRenderer#submit: scale(-1,-1,1), then translate Y by -1.501.
-- With ModelPart's positive-down Y this places model Y=24 at +0.001 blocks.
function D.ArmorStandRenderRootOffset()
	return 1.501
end

function D.ArmorStandBreakingParticleParameters( small )
	local entityScale = small == true and 0.5 or 1
	local width = D.Constants.armorStandWidth * entityScale
	local height = D.Constants.armorStandHeight * entityScale
	return {
		block = "minecraft:oak_planks",
		count = 10,
		centerY = height * ( 2 / 3 ),
		xDist = width / 4,
		yDist = height / 4,
		zDist = width / 4,
		speed = 0.05,
	}
end

function D.CellCenter( bx, by, bz )
	local coords = MC.API and MC.API.Coords
	return coords and coords.CellCenter and coords.CellCenter( bx, by, bz ) or nil
end

function D.EnginePositionFromWorld( worldPosition, reference )
	if not worldPosition then return nil end
	local coords = MC.API and MC.API.Coords
	local referenceWorld = coords and coords.EntityWorldPos and coords.EntityWorldPos( reference ) or nil
	if referenceWorld and IsValid and IsValid( reference ) and reference.GetPos then
		local enginePosition = reference:GetPos()
		return add( enginePosition, vector(
			worldPosition.x - referenceWorld.x,
			worldPosition.y - referenceWorld.y,
			worldPosition.z - referenceWorld.z ) )
	end
	return worldPosition
end

function D.WorldFromEntity( entity )
	local coords = MC.API and MC.API.Coords
	return coords and coords.EntityWorldPos and coords.EntityWorldPos( entity ) or nil
end

function D.SizeToEngine( size )
	local coords = MC.API and MC.API.Coords
	local blockSize = coords and coords.BlockSize and coords.BlockSize() or 36.5
	return vector( size.x * blockSize, size.y * blockSize, size.z * blockSize )
end

function D.CenterForGeometry( bx, by, bz, geometry )
	local center = D.CellCenter( bx, by, bz )
	if not center or not geometry then return nil end
	return add( center, D.SizeToEngine( geometry.centerOffset ) )
end

function D.AABBForGeometry( bx, by, bz, geometry )
	local center = D.CenterForGeometry( bx, by, bz, geometry )
	if not center then return nil end
	local size = D.SizeToEngine( geometry.size )
	local half = scale( size, 0.5 )
	return center - half, center + half, center
end

function D.SupportCells( bx, by, bz, width, height, direction )
	-- HangingEntity#calculateSupportBox is derived from the actual entity AABB:
	--   getBoundingBox().move(direction.step().mul(-0.5)).deflate(1.0E-7)
	-- BlockPos.betweenClosedStream then visits every block intersecting that box.
	-- Work in block-centre coordinates (the Source adapter maps Minecraft's Y
	-- axis to local Z, hence the explicit geometry helper) instead of assuming a
	-- rectangular width/height grid.  This matters for even-sized paintings and
	-- for the half-block wall offset.
	local d = D.Direction( direction )
	if not d then return {} end
	local geometry = D.PaintingGeometry( tonumber( width ) or 0, tonumber( height ) or 0, d )
	if not geometry then return {} end
	local centre = geometry.centerOffset or { x = 0, y = 0, z = 0 }
	centre = {
		x = centre.x - d.x * 0.5,
		y = centre.y - d.y * 0.5,
		z = centre.z - d.z * 0.5,
	}
	local half = {
		x = ( geometry.size.x or 0 ) * 0.5,
		y = ( geometry.size.y or 0 ) * 0.5,
		z = ( geometry.size.z or 0 ) * 0.5,
	}
	local epsilon = 1.0e-7
	local function range( minimum, maximum )
		-- `centre` is relative to Vec3.atCenterOf(pos), so convert to the
		-- lower-corner coordinate before applying BlockPos.betweenClosed.
		minimum = minimum + 0.5 + epsilon
		maximum = maximum + 0.5 - epsilon
		local first = math.floor( minimum )
		local last = math.floor( maximum )
		if last < first then last = first end
		return first, last
	end
	local x1, x2 = range( centre.x - half.x, centre.x + half.x )
	local y1, y2 = range( centre.y - half.y, centre.y + half.y )
	local z1, z2 = range( centre.z - half.z, centre.z + half.z )
	local output = {}
	for x = x1, x2 do
		for y = y1, y2 do
			for z = z1, z2 do
				output[#output + 1] = { bx = math.floor( bx + x ), by = math.floor( by + y ), bz = math.floor( bz + z ) }
			end
		end
	end
	return output
end

function D.FrameSupportCell( bx, by, bz, direction )
	local d = D.Opposite( direction )
	return { bx = bx + d.x, by = by + d.y, bz = bz + d.z }
end

function D.LocalClickY( entity, hitPosition )
	if not entity or not hitPosition then return 0 end
	local origin = entity:GetPos()
	local scaleValue = entity.GetDecorationScale and entity:GetDecorationScale() or 1
	local blockSize = MC.API and MC.API.Coords and MC.API.Coords.BlockSize and MC.API.Coords.BlockSize() or 36.5
	return ( hitPosition.z - origin.z ) / math.max( 0.0001, blockSize * scaleValue )
end

function D.NormalizedDirectionFromEntity( entity )
	if not entity then return nil end
	return D.Direction( entity.GetDecorationDirection and entity:GetDecorationDirection() or "south" )
end
