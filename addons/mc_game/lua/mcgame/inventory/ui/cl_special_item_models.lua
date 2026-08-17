-- Minecraft special-item GUI models that cannot be represented by a flat item
-- sprite or a normal block-state model. Geometry, UVs and display transforms are
-- taken from ChestModel, ShieldModel and the 26.2 item model JSON files.

if not CLIENT then return end

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Renderer = UI.ItemRenderer
if not Renderer or not Renderer.RegisterSpecialIconRenderer
	or not Renderer.RegisterSpecialWorldRenderer then return end

local TEXTURE_SIZE = 64
local MATERIAL_FLAGS = "alphatest vertexcolor vertexalpha nocull"
local ENTITY_GLINT_SCALE = 0.5

-- Lighting.Entry.ITEMS_3D after Lighting's Java 26.2 item-pose transform.
local LIGHT_3D_0 = Vector( -0.933439291, -0.262694713, -0.244300180 )
local LIGHT_3D_1 = Vector( -0.103571370, -0.976606837, 0.188446429 )
-- Lighting.Entry.ITEMS_FLAT. Shield's base item model declares
-- `gui_light: front`, while template_chest keeps the default side lighting.
local LIGHT_FLAT_0 = Vector( -0.222518981, -0.171498585, 0.959725762 )
local LIGHT_FLAT_1 = Vector( -0.215012134, -0.971825316, 0.096567789 )

-- The compact item-model catalog currently ships model nodes but not the base
-- files referenced only by special nodes. Keep exact vanilla GUI transforms as
-- fallbacks so special models do not silently render unrotated at scale 1.
local CHEST_DISPLAY = {
	gui = { rotation = { 30, 45, 0 }, translation = { 0, 0, 0 }, scale = { 0.625, 0.625, 0.625 } },
	ground = { rotation = { 0, 0, 0 }, translation = { 0, 3, 0 }, scale = { 0.25, 0.25, 0.25 } },
	thirdperson_righthand = { rotation = { 75, 315, 0 }, translation = { 0, 2.5, 0 }, scale = { 0.375, 0.375, 0.375 } },
	firstperson_righthand = { rotation = { 0, 315, 0 }, translation = { 0, 0, 0 }, scale = { 0.4, 0.4, 0.4 } },
}
local SHIELD_DISPLAY = {
	gui = { rotation = { 15, -25, -5 }, translation = { 2, 3, 0 }, scale = { 0.65, 0.65, 0.65 } },
	ground = { rotation = { 0, 0, 0 }, translation = { 2, 4, 2 }, scale = { 0.25, 0.25, 0.25 } },
	thirdperson_righthand = { rotation = { 0, 90, 0 }, translation = { 10, 6, -4 }, scale = { 1, 1, 1 } },
	thirdperson_lefthand = { rotation = { 0, 90, 0 }, translation = { 10, 6, 12 }, scale = { 1, 1, 1 } },
	firstperson_righthand = { rotation = { 0, 180, 5 }, translation = { -10, 1.75, -10 }, scale = { 1.25, 1.25, 1.25 } },
	firstperson_lefthand = { rotation = { 0, 180, 5 }, translation = { 10, 0, -10 }, scale = { 1.25, 1.25, 1.25 } },
}
local SHIELD_BLOCKING_DISPLAY = {
	gui = SHIELD_DISPLAY.gui,
	thirdperson_righthand = { rotation = { 45, 155, 0 }, translation = { -3.49, 11, -2 }, scale = { 1, 1, 1 } },
	thirdperson_lefthand = { rotation = { 45, 155, 0 }, translation = { 11.51, 7, 2.5 }, scale = { 1, 1, 1 } },
	firstperson_righthand = { rotation = { 0, 180, -5 }, translation = { -15, 3.25, -11 }, scale = { 1.25, 1.25, 1.25 } },
	firstperson_lefthand = { rotation = { 0, 180, -5 }, translation = { 5, 5, -11 }, scale = { 1.25, 1.25, 1.25 } },
}

local DYE_COLORS = {
	white = Color( 249, 255, 254 ), orange = Color( 249, 128, 29 ),
	magenta = Color( 199, 78, 189 ), light_blue = Color( 58, 179, 218 ),
	yellow = Color( 254, 216, 61 ), lime = Color( 128, 199, 31 ),
	pink = Color( 243, 139, 170 ), gray = Color( 71, 79, 82 ),
	light_gray = Color( 157, 157, 151 ), cyan = Color( 22, 156, 156 ),
	purple = Color( 137, 50, 184 ), blue = Color( 60, 68, 170 ),
	brown = Color( 131, 84, 50 ), green = Color( 94, 124, 22 ),
	red = Color( 176, 46, 38 ), black = Color( 29, 29, 33 ),
}

local CHEST_TEXTURES = {
	normal = true, trapped = true, christmas = true, ender = true,
	copper = true, copper_exposed = true, copper_weathered = true,
	copper_oxidized = true,
}

local Materials = {}

local function modelMaterial( path )
	path = tostring( path or "" )
	if path == "" then return nil end
	local cached = Materials[path]
	if cached ~= nil then return cached ~= false and cached or nil end
	local material = Material( path, MATERIAL_FLAGS )
	if not material or material.IsError and material:IsError() then
		Materials[path] = false
		return nil
	end
	Materials[path] = material
	return material
end

local function componentValue( stack, name )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil end
	if components["minecraft:" .. name] ~= nil then return components["minecraft:" .. name] end
	return components[name]
end

local function identifierPath( value )
	if type( value ) == "table" then
		value = value.id or value.asset_id or value.assetId or value.name or value.value
	end
	value = string.lower( tostring( value or "" ) )
	value = string.gsub( value, "^minecraft:", "" )
	return value
end

local function dyeColor( value, fallback )
	return DYE_COLORS[identifierPath( value )] or fallback or color_white
end

local function multiplyColor( left, right, shade )
	left, right = left or color_white, right or color_white
	shade = math.Clamp( tonumber( shade ) or 1, 0, 1 )
	return Color(
		math.Clamp( math.floor( ( left.r or 255 ) * ( right.r or 255 ) / 255 * shade + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( ( left.g or 255 ) * ( right.g or 255 ) / 255 * shade + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( ( left.b or 255 ) * ( right.b or 255 ) / 255 * shade + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( ( left.a or 255 ) * ( right.a or 255 ) / 255 + 0.5 ), 0, 255 )
	)
end

local function rotatedAround( vector, axis, degrees )
	local radians = math.rad( tonumber( degrees ) or 0 )
	if math.abs( radians ) < 0.000001 then return vector end
	local cosine, sine = math.cos( radians ), math.sin( radians )
	return vector * cosine + axis:Cross( vector ) * sine
		+ axis * axis:Dot( vector ) * ( 1 - cosine )
end

local function rotationBasis( rotation )
	rotation = type( rotation ) == "table" and rotation or {}
	local axisX, axisY, axisZ = Vector( 1, 0, 0 ), Vector( 0, 1, 0 ), Vector( 0, 0, 1 )
	local rx, ry, rz = tonumber( rotation[1] ) or 0, tonumber( rotation[2] ) or 0,
		tonumber( rotation[3] ) or 0
	if rx ~= 0 then
		axisY = rotatedAround( axisY, axisX, rx )
		axisZ = rotatedAround( axisZ, axisX, rx )
	end
	if ry ~= 0 then
		axisX = rotatedAround( axisX, axisY, ry )
		axisZ = rotatedAround( axisZ, axisY, ry )
	end
	if rz ~= 0 then
		axisX = rotatedAround( axisX, axisZ, rz )
		axisY = rotatedAround( axisY, axisZ, rz )
	end
	return axisX:GetNormalized(), axisY:GetNormalized(), axisZ:GetNormalized()
end

local function displayTransform( plan, context, fallback )
	context = tostring( context or "gui" )
	local model = MC.GetItemModelFile and MC.GetItemModelFile( plan and plan.modelId ) or nil
	local displays = type( model ) == "table" and type( model.display ) == "table" and model.display
		or type( plan and plan.display ) == "table" and plan.display or nil
	local display = type( displays ) == "table" and displays[context] or nil
	if not display and type( fallback ) == "table" then
		display = fallback.rotation and fallback or fallback[context]
	end
	display = type( display ) == "table" and display or {}
	return display.rotation or {}, display.translation or {}, display.scale or {}
end

local function modelTransform( plan, localScale, fallbackDisplay, context )
	local rotation, translation, scale = displayTransform( plan, context or "gui", fallbackDisplay )
	local axisX, axisY, axisZ = rotationBasis( rotation )
	localScale = type( localScale ) == "table" and localScale or { 1, 1, 1 }
	local sx, sy, sz = tonumber( scale[1] ) or 1, tonumber( scale[2] ) or 1,
		tonumber( scale[3] ) or 1
	local lx, ly, lz = tonumber( localScale[1] ) or 1, tonumber( localScale[2] ) or 1,
		tonumber( localScale[3] ) or 1
	local tx, ty, tz = ( tonumber( translation[1] ) or 0 ) / 16,
		( tonumber( translation[2] ) or 0 ) / 16, ( tonumber( translation[3] ) or 0 ) / 16

	local function point( x, y, z )
		-- ItemTransform.apply is T * Rxyz * S * T(-0.5), followed by the
		-- special renderer's local transform (the shield uses 1,-1,-1).
		x, y, z = x / 16 * lx - 0.5, y / 16 * ly - 0.5, z / 16 * lz - 0.5
		x, y, z = x * sx, y * sy, z * sz
		local rotated = axisX * x + axisY * y + axisZ * z
		return Vector( rotated.x + tx, rotated.y + ty, rotated.z + tz )
	end

	local function normal( x, y, z )
		-- Inverse-transpose for the two scale operations; all current vanilla
		-- values are uniform, but retaining the full rule avoids mirrored normals.
		x = x / ( lx * ( sx ~= 0 and sx or 1 ) )
		y = y / ( ly * ( sy ~= 0 and sy or 1 ) )
		z = z / ( lz * ( sz ~= 0 and sz or 1 ) )
		local rotated = axisX * x + axisY * y + axisZ * z
		return rotated:GetNormalized()
	end

	return point, normal
end

local function faceShade( normal, light0, light1 )
	light0, light1 = light0 or LIGHT_3D_0, light1 or LIGHT_3D_1
	local diffuse = math.max( light0:Dot( normal ), 0 ) + math.max( light1:Dot( normal ), 0 )
	return math.min( 1, diffuse * 0.6 + 0.4 )
end

local function rotatePartX( value, pivotY, pivotZ, radians )
	if not radians or math.abs( radians ) < 0.000001 then return value end
	local y, z = value.y - pivotY, value.z - pivotZ
	local cosine, sine = math.cos( radians ), math.sin( radians )
	return Vector( value.x, y * cosine - z * sine + pivotY,
		y * sine + z * cosine + pivotZ )
end

local function appendBox( faces, transformPoint, transformNormal, box, light0, light1, keepBackfaces )
	local x0, x1 = box.x, box.x + box.width
	local y0, y1 = box.y, box.y + box.height
	local z0, z1 = box.z, box.z + box.depth
	local angle = tonumber( box.rotateX ) or 0

	local function point( x, y, z )
		local value = rotatePartX( Vector( x, y, z ), box.pivotY or 0, box.pivotZ or 0, angle )
		return transformPoint( value.x, value.y, value.z )
	end
	local function normal( x, y, z )
		local value = rotatePartX( Vector( x, y, z ), 0, 0, angle )
		return transformNormal( value.x, value.y, value.z )
	end

	local t0, t1, t2, t3 = point( x0, y0, z0 ), point( x1, y0, z0 ),
		point( x1, y1, z0 ), point( x0, y1, z0 )
	local l0, l1, l2, l3 = point( x0, y0, z1 ), point( x1, y0, z1 ),
		point( x1, y1, z1 ), point( x0, y1, z1 )
	local u0, u1 = box.texU, box.texU + box.depth
	local u2, u22 = u1 + box.width, u1 + box.width * 2
	local u3, u4 = u2 + box.depth, u2 + box.depth + box.width
	local v0, v1, v2 = box.texV, box.texV + box.depth, box.texV + box.depth + box.height

	local function add( a, b, c, d, au, av, bu, bv, nx, ny, nz )
		local transformedNormal = normal( nx, ny, nz )
		-- GuiItemAtlas renders these entity models with normal back-face culling
		-- and a depth buffer.  surface.DrawPoly has neither here, so discard the
		-- faces pointing away from the +Z GUI camera before painter sorting.
		if not keepBackfaces and transformedNormal.z <= 0.000001 then return end
		faces[#faces + 1] = {
			depth = ( a.z + b.z + c.z + d.z ) * 0.25,
			shade = faceShade( transformedNormal, light0, light1 ),
			normal = transformedNormal,
			vertices = {
				{ x = a.x, y = a.y, z = a.z, u = bu / TEXTURE_SIZE, v = av / TEXTURE_SIZE },
				{ x = b.x, y = b.y, z = b.z, u = au / TEXTURE_SIZE, v = av / TEXTURE_SIZE },
				{ x = c.x, y = c.y, z = c.z, u = au / TEXTURE_SIZE, v = bv / TEXTURE_SIZE },
				{ x = d.x, y = d.y, z = d.z, u = bu / TEXTURE_SIZE, v = bv / TEXTURE_SIZE },
			},
		}
	end

	add( l1, l0, t0, t1, u1, v0, u2, v1, 0, -1, 0 )
	add( t2, t3, l3, l2, u2, v1, u22, v0, 0, 1, 0 )
	add( t0, l0, l3, t3, u0, v1, u1, v2, -1, 0, 0 )
	add( t1, t0, t3, t2, u1, v1, u2, v2, 0, 0, -1 )
	add( l1, t1, t2, l2, u2, v1, u3, v2, 1, 0, 0 )
	add( l0, l1, l2, l3, u3, v1, u4, v2, 0, 0, 1 )
end

local function localModelTransform( localScale )
	localScale = type( localScale ) == "table" and localScale or { 1, 1, 1 }
	local lx, ly, lz = tonumber( localScale[1] ) or 1, tonumber( localScale[2] ) or 1,
		tonumber( localScale[3] ) or 1
	local function point( x, y, z )
		return Vector( x / 16 * lx - 0.5, y / 16 * ly - 0.5, z / 16 * lz - 0.5 )
	end
	local function normal( x, y, z )
		local value = Vector(
			x / ( lx ~= 0 and lx or 1 ),
			y / ( ly ~= 0 and ly or 1 ),
			z / ( lz ~= 0 and lz or 1 )
		)
		return value:GetNormalized()
	end
	return point, normal
end

local function appendChestFaces( faces, transformPoint, transformNormal, special, keepBackfaces )
	appendBox( faces, transformPoint, transformNormal,
		{ x = 1, y = 0, z = 1, width = 14, height = 10, depth = 14, texU = 0, texV = 19 },
		nil, nil, keepBackfaces )
	local openness = math.Clamp( tonumber( special and special.openness ) or 0, 0, 1 )
	local lidAngle = -openness * math.pi * 0.5
	appendBox( faces, transformPoint, transformNormal, {
		x = 1, y = 9, z = 1, width = 14, height = 5, depth = 14, texU = 0, texV = 0,
		rotateX = lidAngle, pivotY = 9, pivotZ = 1,
	}, nil, nil, keepBackfaces )
	appendBox( faces, transformPoint, transformNormal, {
		x = 7, y = 7, z = 15, width = 2, height = 4, depth = 1, texU = 0, texV = 0,
		rotateX = lidAngle, pivotY = 9, pivotZ = 1,
	}, nil, nil, keepBackfaces )
end

local function appendShieldFaces( faces, transformPoint, transformNormal, keepBackfaces )
	appendBox( faces, transformPoint, transformNormal,
		{ x = -6, y = -11, z = -2, width = 12, height = 22, depth = 1, texU = 0, texV = 0 },
		LIGHT_FLAT_0, LIGHT_FLAT_1, keepBackfaces )
	appendBox( faces, transformPoint, transformNormal,
		{ x = -1, y = -3, z = -1, width = 2, height = 6, depth = 6, texU = 26, texV = 0 },
		LIGHT_FLAT_0, LIGHT_FLAT_1, keepBackfaces )
end

local function projectFaces( faces, x, y, size )
	local centerX, centerY = x + size * 0.5, y + size * 0.5
	for _, face in ipairs( faces ) do
		for _, vertex in ipairs( face.vertices ) do
			vertex.x = centerX + vertex.x * size
			vertex.y = centerY - vertex.y * size
		end
	end
	-- The GUI camera looks from +Z toward the model.  Match the depth buffer by
	-- painting the smallest (furthest) Z first and the largest (nearest) Z last.
	table.sort( faces, function( first, second ) return first.depth < second.depth end )
	return faces
end

local function drawModelLayers( faces, layers, worldColor )
	UI.WithPointFiltering( function()
		-- Finish all translucent/tinted layers of a far face before moving to the
		-- next near face.  Drawing one whole model per texture would allow a far
		-- shield-pattern face to overwrite an already painted near base face.
		for _, face in ipairs( faces ) do
			for _, layer in ipairs( layers ) do
				if layer.material then
					surface.SetMaterial( layer.material )
					local color = multiplyColor( layer.color, worldColor, face.shade )
					surface.SetDrawColor( color.r, color.g, color.b, color.a )
					surface.DrawPoly( face.vertices )
				end
			end
		end
	end )
end

local function resultFor( faces, layers, maskLayers, options )
	local worldColor = options and options.worldColor or color_white
	drawModelLayers( faces, layers, worldColor )
	return {
		drawn = true,
		drawMask = function() drawModelLayers( faces, maskLayers or layers, worldColor ) end,
		glintScaleU = ENTITY_GLINT_SCALE,
		glintScaleV = ENTITY_GLINT_SCALE,
	}
end

local function worldPoint( transform, vertex, normal, offset )
	return transform.pos
		+ transform.xAxis * ( vertex.x * transform.width )
		+ transform.yAxis * ( vertex.y * transform.height )
		+ transform.normal * ( vertex.z * transform.depth )
		+ normal * offset
end

local function worldNormal( transform, localNormal )
	local width = math.max( math.abs( tonumber( transform.width ) or 0 ), 0.000001 )
	local height = math.max( math.abs( tonumber( transform.height ) or 0 ), 0.000001 )
	local depth = math.max( math.abs( tonumber( transform.depth ) or 0 ), 0.000001 )
	return (
		transform.xAxis * ( localNormal.x / width )
		+ transform.yAxis * ( localNormal.y / height )
		+ transform.normal * ( localNormal.z / depth )
	):GetNormalized()
end

local function visibleWorldFaces( faces, transform )
	local view = render and render.GetViewSetup and render.GetViewSetup() or nil
	local cameraPos = view and view.origin or ( EyePos and EyePos() or nil )
	local visible = {}
	for _, face in ipairs( faces ) do
		local normal = worldNormal( transform, face.normal )
		local center = Vector( 0, 0, 0 )
		for _, vertex in ipairs( face.vertices ) do
			center = center + worldPoint( transform, vertex, normal, 0 )
		end
		center = center * 0.25
		-- The shared pixel material is intentionally nocull because the same
		-- texture also serves 2D inventory polygons. Reproduce Minecraft's model
		-- back-face culling here so first-person depth-test-without-write cannot
		-- let hidden chest/shield faces paint over the visible shell.
		if not cameraPos or normal:Dot( cameraPos - center ) > 0.000001 then
			local cameraDelta = cameraPos and cameraPos - center or nil
			visible[#visible + 1] = {
				face = face,
				normal = normal,
				distanceSq = cameraDelta and cameraDelta:Dot( cameraDelta ) or 0,
			}
		end
	end
	-- The first-person hand pass intentionally depth-tests without writing to
	-- the world depth buffer. Minecraft still gives the special model its own
	-- depth buffer, so reproduce that ordering after culling: distant visible
	-- faces are submitted first and nearer lid/lock faces finish the shell.
	if cameraPos then
		table.sort( visible, function( first, second )
			return first.distanceSq > second.distanceSq
		end )
	end
	return visible
end

local function drawWorldLayers( faces, layers, transform, worldColor )
	if not mesh or not mesh.Begin or not render or not render.SetMaterial then return false end
	worldColor = worldColor or color_white
	local layerStep = math.max( transform.width, transform.height, transform.depth, 1 ) * 0.0005
	local visible = visibleWorldFaces( faces, transform )
	if #visible == 0 then return false end
	local drawn = false
	UI.WithPointFiltering( function()
		for layerIndex, layer in ipairs( layers ) do
			if layer.material then
				render.SetMaterial( layer.material )
				mesh.Begin( MATERIAL_QUADS, #visible )
				for _, entry in ipairs( visible ) do
					local face, normal = entry.face, entry.normal
					local offset = ( layerIndex - 1 ) * layerStep
					local color = multiplyColor( layer.color, worldColor, face.shade )
					for _, vertex in ipairs( face.vertices ) do
						mesh.Position( worldPoint( transform, vertex, normal, offset ) )
						if mesh.Normal then mesh.Normal( normal ) end
						mesh.TexCoord( 0, vertex.u, vertex.v )
						mesh.Color( color.r, color.g, color.b, color.a )
						mesh.AdvanceVertex()
					end
				end
				mesh.End()
			end
		end
		drawn = true
	end )
	return drawn
end

local function drawWorldGlintFaces( faces, transform, material, uvTransform, offset )
	if not material or not isfunction( uvTransform ) then return false end
	local visible = visibleWorldFaces( faces, transform )
	if #visible == 0 then return false end
	render.SetMaterial( material )
	mesh.Begin( MATERIAL_QUADS, #visible )
	for _, entry in ipairs( visible ) do
		local face, normal = entry.face, entry.normal
		for _, vertex in ipairs( face.vertices ) do
			local u, v = uvTransform( vertex.u, vertex.v )
			mesh.Position( worldPoint( transform, vertex, normal, offset ) )
			if mesh.Normal then mesh.Normal( normal ) end
			mesh.TexCoord( 0, u, v )
			mesh.Color( 255, 255, 255, 255 )
			mesh.AdvanceVertex()
		end
	end
	mesh.End()
	return true
end

local function specialWorldTransform( plan, pos, orientation, size, options, fallbackDisplay )
	if not Renderer.SpecialWorldTransform or not orientation
		or not isfunction( orientation.Forward ) then return nil end
	options = options or {}
	return Renderer.SpecialWorldTransform( plan, options.displayContext or "firstperson_righthand",
		pos, orientation, size, options, fallbackDisplay )
end

local function chestTextureName( value )
	local name = identifierPath( value )
	name = string.gsub( name, "^textures/entity/chest/", "" )
	name = string.gsub( name, "%.png$", "" )
	return CHEST_TEXTURES[name] and name or nil
end

local function drawChestIcon( _, plan, x, y, size, options )
	local special = plan and plan.special or nil
	local texture = chestTextureName( special and special.texture )
	if not texture then return false end
	local material = modelMaterial( "mc/entity/chest/" .. texture .. ".png" )
	if not material then return false end

	local transformPoint, transformNormal = modelTransform( plan, nil, CHEST_DISPLAY )
	local faces = {}
	appendChestFaces( faces, transformPoint, transformNormal, special, false )
	projectFaces( faces, x, y, size )
	local layers = { { material = material, color = color_white } }
	return resultFor( faces, layers, layers, options )
end

local function drawChestWorld( _, plan, pos, orientation, size, color, options )
	local special = plan and plan.special or nil
	local texture = chestTextureName( special and special.texture )
	if not texture then return false end
	local material = modelMaterial( "mc/entity/chest/" .. texture .. ".png" )
	if not material then return false end
	local transform = specialWorldTransform( plan, pos, orientation, size, options, CHEST_DISPLAY )
	if not transform then return false end
	local transformPoint, transformNormal = localModelTransform()
	local faces = {}
	appendChestFaces( faces, transformPoint, transformNormal, special, true )
	return drawWorldLayers( faces, { { material = material, color = color_white } }, transform, color )
end

local function shieldPatternLayers( stack )
	local baseColorValue = componentValue( stack, "base_color" )
	local rawPatterns = componentValue( stack, "banner_patterns" ) or {}
	if type( rawPatterns ) == "table" and type( rawPatterns.layers ) == "table" then
		rawPatterns = rawPatterns.layers
	end
	if type( rawPatterns ) ~= "table" then rawPatterns = {} end
	local patterned = baseColorValue ~= nil or #rawPatterns > 0
	if not patterned then
		local material = modelMaterial( "mc/entity/shield/shield_base_nopattern.png" )
		return material and { { material = material, color = color_white } } or nil
	end

	local baseMaterial = modelMaterial( "mc/entity/shield/shield_base.png" )
	local fieldMaterial = modelMaterial( "mc/entity/shield/base.png" )
	if not baseMaterial or not fieldMaterial then return nil end
	local layers = {
		{ material = baseMaterial, color = color_white },
		{ material = fieldMaterial, color = dyeColor( baseColorValue, DYE_COLORS.white ) },
	}
	for index, pattern in ipairs( rawPatterns ) do
		if index > 16 then break end
		if type( pattern ) == "table" then
			local patternName = identifierPath( pattern.pattern )
			if string.match( patternName, "^[a-z0-9_]+$" ) then
				local material = modelMaterial( "mc/entity/shield/" .. patternName .. ".png" )
				if material then
					layers[#layers + 1] = { material = material, color = dyeColor( pattern.color ) }
				end
			end
		end
	end
	return layers
end

local function drawShieldIcon( stack, plan, x, y, size, options )
	local layers = shieldPatternLayers( stack )
	if not layers then return false end
	local transformPoint, transformNormal = modelTransform(
		plan, { 1, -1, -1 }, SHIELD_DISPLAY )
	local faces = {}
	appendShieldFaces( faces, transformPoint, transformNormal, false )
	projectFaces( faces, x, y, size )
	return resultFor( faces, layers, { layers[1] }, options )
end

local function drawShieldWorld( stack, plan, pos, orientation, size, color, options )
	local layers = shieldPatternLayers( stack )
	if not layers then return false end
	local blocking = tostring( plan and plan.modelId or "" ) == "minecraft:item/shield_blocking"
	local fallbackDisplay = blocking and SHIELD_BLOCKING_DISPLAY or SHIELD_DISPLAY
	local transform = specialWorldTransform( plan, pos, orientation, size, options, fallbackDisplay )
	if not transform then return false end
	local transformPoint, transformNormal = localModelTransform( { 1, -1, -1 } )
	local faces = {}
	appendShieldFaces( faces, transformPoint, transformNormal, true )
	local drawn = drawWorldLayers( faces, layers, transform, color )
	if drawn and Renderer.DrawSpecialWorldGlint then
		local glintOffset = math.max( transform.width, transform.height, transform.depth, 1 )
			* 0.0005 * ( #layers + 0.5 )
		Renderer.DrawSpecialWorldGlint( stack, function( material, uvTransform )
			return drawWorldGlintFaces( faces, transform, material, uvTransform, glintOffset )
		end, ENTITY_GLINT_SCALE, ENTITY_GLINT_SCALE )
	end
	return drawn
end

Renderer.RegisterSpecialIconRenderer( "minecraft:chest", drawChestIcon )
Renderer.RegisterSpecialIconRenderer( "minecraft:shield", drawShieldIcon )
Renderer.RegisterSpecialWorldRenderer( "minecraft:chest", drawChestWorld )
Renderer.RegisterSpecialWorldRenderer( "minecraft:shield", drawShieldWorld )
