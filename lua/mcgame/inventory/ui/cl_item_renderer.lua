-- Minecraft item-stack rendering shared by slots, hotbar and tooltips.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Renderer = {}
UI.ItemRenderer = Renderer

local function definitionFor( stackOrDefinition )
	if type( stackOrDefinition ) == "table" and stackOrDefinition.name and not stackOrDefinition.item then
		return stackOrDefinition
	end
	return MC.GetItem and MC.GetItem( type( stackOrDefinition ) == "table" and stackOrDefinition.item or stackOrDefinition ) or nil
end

function Renderer.Definition( stack )
	return definitionFor( stack )
end

function Renderer.MaterialForLayer( layer )
	if type( layer ) ~= "string" or layer == "" then return nil end
	if not string.match( layer, "%.png$" ) then layer = layer .. ".png" end
	return UI.GetMaterial( layer )
end

function Renderer.MaterialForDefinition( definition )
	if not definition then return nil end
	if definition.texture then return Renderer.MaterialForLayer( definition.texture ) end
	return nil
end

function Renderer.ModelPlan( stack, options )
	if MC.ResolveItemModel then
		return MC.ResolveItemModel( stack, options or {} )
	end
	local definition = definitionFor( stack )
	if definition and definition.texture then
		return { layers = { definition.texture }, kind = "flat", modelId = definition.model }
	end
	return { layers = {}, kind = "missing" }
end

function Renderer.MaterialsForStack( stack, options )
	local plan = Renderer.ModelPlan( stack, options )
	local materials = {}
	for _, layer in ipairs( plan.layers or {} ) do
		local material = Renderer.MaterialForLayer( layer )
		if material then materials[#materials + 1] = material end
	end
	return materials, plan
end

local function blockIdFor( definition )
	if not definition then return nil end
	if definition.blockId then return definition.blockId end
	local resolved = MC.ResolveBlock and MC.ResolveBlock( definition.blockName or definition.name ) or nil
	return resolved and resolved.id or nil
end

local function blockStateFor( definition )
	if not MC.DefaultBlockState then return nil, nil end
	local blockId = blockIdFor( definition )
	if not blockId then return nil, nil end
	return MC.DefaultBlockState( blockId ), blockId
end

local function blockIconMaterial( blockId )
	if blockId and MC.IsTranslucentBlock and MC.IsTranslucentBlock( blockId ) then
		return MC.MaterialCreativeIconOpaque or MC.MaterialIconOpaque or MC.Material
	end
	return MC.MaterialCreativeIcon or MC.Material
end

local droppedBlockMeshes = {}
local DROP_TRIANGLES = { 1, 3, 2, 1, 4, 3 }

local function droppedBlockMaterial( translucent )
	local material = translucent and ( MC.MaterialTranslucent or MC.Material ) or MC.Material
	if not material or material.IsError and material:IsError() then return nil end
	return material
end

local function droppedBlockCullMode()
	local convar = MC.MeshCullMode
	local value = convar and convar.GetString and string.lower( tostring( convar:GetString() or "" ) ) or "ccw"
	if value == "ccw" or value == "counterclockwise" or value == "counter-clockwise" then
		return MATERIAL_CULLMODE_CCW or 0
	end
	return MATERIAL_CULLMODE_CW or 1
end

local function droppedTileUVRect( tile, uv )
	if not uv then return MC.TileUV( tile ) end
	local atlas = MC.Atlas
	if not atlas or not atlas.COLS or not atlas.W or not atlas.H then return MC.TileUV( tile ) end
	local col = tile % atlas.COLS
	local row = math.floor( tile / atlas.COLS )
	local stride = atlas.STRIDE or atlas.TILE
	local padding = atlas.PAD or 0
	local inset = atlas.INSET or 0.5
	local baseX = col * stride + padding
	local baseY = row * stride + padding
	local tileSize = atlas.TILE
	local u0 = baseX + ( tonumber( uv[1] ) or 0 ) / 16 * tileSize
	local v0 = baseY + ( tonumber( uv[2] ) or 0 ) / 16 * tileSize
	local u1 = baseX + ( tonumber( uv[3] ) or 16 ) / 16 * tileSize
	local v1 = baseY + ( tonumber( uv[4] ) or 16 ) / 16 * tileSize
	local uDirection = u1 >= u0 and 1 or -1
	local vDirection = v1 >= v0 and 1 or -1
	return ( u0 + inset * uDirection ) / atlas.W,
		( v0 + inset * vDirection ) / atlas.H,
		( u1 - inset * uDirection ) / atlas.W,
		( v1 - inset * vDirection ) / atlas.H
end

local function rotatedUV( u, v, rotation )
	rotation = math.floor( tonumber( rotation ) or 0 ) % 4
	if rotation == 1 then return v, 1 - u end
	if rotation == 2 then return 1 - u, 1 - v end
	if rotation == 3 then return 1 - v, u end
	return u, v
end

local function droppedBlockState( stack, options )
	local definition = definitionFor( stack )
	if not definition or definition.blockId == nil then return nil end
	local plan = Renderer.ModelPlan( stack, options or { displayContext = "ground" } )
	local modelId = tostring( plan and plan.modelId or "" )
	if not string.find( modelId, ":block/", 1, true ) then return nil end
	return blockStateFor( definition )
end

local function droppedBlockMesh( stateId, blockId )
	local cached = droppedBlockMeshes[stateId]
	if cached ~= nil then return cached ~= false and cached or nil end
	if not ( Mesh and MC.VisitStateVisualModels and MC.StateVisualModelData
		and MC.BlockModelSurface and MC.ModelQuadVertex and MC.TileUV ) then
		return nil
	end

	local vertices = {}
	local visitedModel = false
	local missingModel = false
	MC.VisitStateVisualModels( stateId, 0, 0, 0, function( modelId )
		visitedModel = true
		local model = MC.StateVisualModelData( modelId )
		if not model then
			missingModel = true
			return
		end
		for _, quad in ipairs( model and model.modelQuads or {} ) do
			local tile = MC.BlockModelSurface( model, quad )
			local atlasU0, atlasV0, atlasU1, atlasV1 = droppedTileUVRect( tile, quad.uv )
			local points, texture = {}, {}
			for index = 1, 4 do
				local x, y, z, u, v = MC.ModelQuadVertex( quad, index )
				u, v = rotatedUV( u, v, quad.rot )
				points[index] = Vector( x - 0.5, y - 0.5, z - 0.5 )
				texture[index] = {
					u = atlasU0 + ( atlasU1 - atlasU0 ) * u,
					v = atlasV0 + ( atlasV1 - atlasV0 ) * v,
				}
			end

			local edgeA, edgeB = points[3] - points[1], points[2] - points[1]
			local normal = edgeA:Cross( edgeB )
			if normal:LengthSqr() > 0.000001 then normal:Normalize() else normal = Vector( 0, 0, 1 ) end
			local face = MC.RenderMeshConstants and MC.RenderMeshConstants.FACES
				and MC.RenderMeshConstants.FACES[quad.face or 1] or nil
			local shade = face and face.sh or color_white
			local r, g, b = shade.r or 255, shade.g or 255, shade.b or 255
			local tintCode = MC.BlockStateTintCode
				and MC.BlockStateTintCode( stateId, blockId, quad.tintIndex or -1 ) or 0
			if tintCode ~= 0 and MC.BlockTintRGB then
				local tr, tg, tb = MC.BlockTintRGB( tintCode )
				r, g, b = r * tr / 255, g * tg / 255, b * tb / 255
			end
			local color = Color( math.floor( r + 0.5 ), math.floor( g + 0.5 ), math.floor( b + 0.5 ), 255 )
			for _, corner in ipairs( DROP_TRIANGLES ) do
				vertices[#vertices + 1] = {
					pos = points[corner], normal = normal,
					u = texture[corner].u, v = texture[corner].v, color = color,
				}
			end
		end
	end )
	if #vertices == 0 then
		-- A drop can render before generated model data finishes loading. Only
		-- cache a genuine empty model; transient misses must retry next frame.
		if visitedModel and not missingModel then droppedBlockMeshes[stateId] = false end
		return nil
	end

	local translucent = MC.IsTranslucentBlock and MC.IsTranslucentBlock( blockId ) == true
	local material = droppedBlockMaterial( translucent )
	if not material then return nil end
	local blockMesh = Mesh( material )
	blockMesh:BuildFromTriangles( vertices )
	cached = { mesh = blockMesh, translucent = translucent }
	droppedBlockMeshes[stateId] = cached
	return cached
end

function Renderer.DrawDroppedBlock( stack, position, angles, size, worldColor, options )
	local stateId, blockId = droppedBlockState( stack, options )
	if not stateId then return false end
	local cached = droppedBlockMesh( stateId, blockId )
	if not cached or not cached.mesh then return false end
	local material = droppedBlockMaterial( cached.translucent )
	if not material then return false end
	local matrix = Matrix()
	matrix:SetTranslation( position )
	matrix:SetAngles( angles )
	size = math.max( 0.01, tonumber( size ) or 12 )
	matrix:SetScale( Vector( size, size, size ) )
	worldColor = worldColor or color_white
	render.SetColorModulation( ( worldColor.r or 255 ) / 255,
		( worldColor.g or 255 ) / 255, ( worldColor.b or 255 ) / 255 )
	render.SetBlend( ( worldColor.a or 255 ) / 255 )
	local filtered = render.PushFilterMin and render.PushFilterMag and TEXFILTER and TEXFILTER.POINT
	if filtered then
		render.PushFilterMin( TEXFILTER.POINT )
		render.PushFilterMag( TEXFILTER.POINT )
	end
	if render.CullMode then render.CullMode( droppedBlockCullMode() ) end
	render.SetMaterial( material )
	cam.PushModelMatrix( matrix, true )
		cached.mesh:Draw()
	cam.PopModelMatrix()
	if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
	if filtered then
		render.PopFilterMag()
		render.PopFilterMin()
	end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	return true
end

local function clearDroppedBlockMeshes()
	for _, cached in pairs( droppedBlockMeshes ) do
		if cached and cached.mesh and cached.mesh.Destroy then cached.mesh:Destroy() end
	end
	droppedBlockMeshes = {}
end

hook.Add( "ShutDown", "mc_item_drop_block_meshes", clearDroppedBlockMeshes )
hook.Add( "OnReloaded", "mc_item_drop_block_meshes", clearDroppedBlockMeshes )

function Renderer.CanDraw( stack )
	return not MC.IsEmptyItemStack( stack ) and definitionFor( stack ) ~= nil
end

function Renderer.DrawIcon( stack, x, y, size, options )
	if not Renderer.CanDraw( stack ) then return false end
	options = options or {}
	local definition = definitionFor( stack )
	local materials, plan = Renderer.MaterialsForStack( stack, options )
	local drawn = false
	if #materials > 0 then
		UI.WithPointFiltering( function()
			for _, material in ipairs( materials ) do
				if UI.DrawTexture( material, x, y, size, size, nil, nil, nil, nil, options.worldColor ) then drawn = true end
			end
		end )
	elseif MC.DrawMinecraftBlockStateIcon then
		local stateId, blockId = blockStateFor( definition )
		if stateId then
			UI.WithPointFiltering( function()
				drawn = MC.DrawMinecraftBlockStateIcon( stateId, x, y, size, size,
					options.forceModel == true, blockIconMaterial( blockId ), options.worldColor ) == true
			end )
		end
	end
	if not drawn then
		-- Keep missing/custom item definitions visible and diagnosable without
		-- throwing from Paint; the checker is deliberately Minecraft-like.
		draw.RoundedBox( 0, x + size * 0.12, y + size * 0.12, size * 0.76, size * 0.76, Color( 180, 0, 180, 220 ) )
		surface.SetDrawColor( 30, 0, 30, 255 )
		surface.DrawRect( x + size * 0.20, y + size * 0.20, size * 0.18, size * 0.18 )
		surface.DrawRect( x + size * 0.62, y + size * 0.62, size * 0.18, size * 0.18 )
		drawn = true
	end
	return drawn
end

local function drawCount( stack, x, y, size, scale )
	if not stack or ( tonumber( stack.count ) or 0 ) <= 1 then return end
	local text = tostring( math.floor( tonumber( stack.count ) or 0 ) )
	UI.DrawText( text, x + size, y + size, scale, UI.Colors.text,
		TEXT_ALIGN_RIGHT, true, TEXT_ALIGN_BOTTOM )
end

local function drawDamage( stack, definition, x, y, size, scale )
	local maxDamage = tonumber( definition and definition.maxDamage ) or 0
	if maxDamage <= 0 then return end
	local info = MC.ItemDurabilityInfo and MC.ItemDurabilityInfo( stack ) or nil
	if not info or info.visible ~= true then return end
	local remaining = info and info.remaining or 1
	local barWidth = math.max( 2, size - 2 * scale )
	local barHeight = math.max( 1, scale )
	local barX, barY = x + scale, y + size - 2 * scale
	draw.RoundedBox( 0, barX, barY, barWidth, barHeight, Color( 0, 0, 0, 255 ) )
	local color = info and info.color or { r = 255, g = 0, b = 0 }
	draw.RoundedBox( 0, barX, barY, math.max( 1, math.floor( barWidth * remaining ) ), barHeight,
		Color( color.r, color.g, color.b, 255 ) )
end

function Renderer.DrawStack( stack, x, y, size, options )
	if MC.IsEmptyItemStack( stack ) then return false end
	options = options or {}
	local scale = tonumber( options.scale ) or math.max( 1, math.floor( size / 16 ) )
	local iconSize = tonumber( options.iconSize ) or size
	local definition = definitionFor( stack )
	if not definition then return false end
	Renderer.DrawIcon( stack, x + ( size - iconSize ) * 0.5, y + ( size - iconSize ) * 0.5, iconSize, options )
	drawDamage( stack, definition, x, y, size, scale )
	if options.drawCount ~= false then drawCount( stack, x, y, size, scale ) end
	return true
end

function Renderer.DisplayName( stack )
	local definition = definitionFor( stack )
	if not definition then return "" end
	return MC.ItemDisplayName and MC.ItemDisplayName( definition ) or tostring( definition.displayName or definition.name )
end

local DEFAULT_DISPLAY = {
	firstperson_righthand = { rotation = { 0, -90, 25 }, translation = { 1.13, 3.2, 1.13 }, scale = { 0.68, 0.68, 0.68 } },
	thirdperson_righthand = { rotation = { 0, 0, 0 }, translation = { 0, 3, 1 }, scale = { 0.55, 0.55, 0.55 } },
}

local function displayValues( plan, context )
	local display = type( plan.display ) == "table" and plan.display or nil
	local transform = display and display[context] or nil
	local leftHand = string.find( context, "lefthand", 1, true ) ~= nil
	if not transform and leftHand and display then
		local rightContext = string.gsub( context, "lefthand", "righthand", 1 )
		local right = display[rightContext]
		if right then
			local rotation = right.rotation or {}
			transform = {
				rotation = { tonumber( rotation[1] ) or 0, -( tonumber( rotation[2] ) or 0 ), -( tonumber( rotation[3] ) or 0 ) },
				translation = right.translation,
				scale = right.scale,
			}
		end
	end
	if not transform then
		local rightContext = string.gsub( context, "lefthand", "righthand", 1 )
		transform = DEFAULT_DISPLAY[rightContext] or DEFAULT_DISPLAY.firstperson_righthand
		if leftHand then
			local rotation = transform.rotation
			transform = {
				rotation = { rotation[1], -rotation[2], -rotation[3] },
				translation = transform.translation,
				scale = transform.scale,
			}
		end
	end
	return transform
end

local function rotatedAround( vector, axis, degrees )
	local radians = math.rad( tonumber( degrees ) or 0 )
	if math.abs( radians ) < 0.000001 then return vector end
	local cosine, sine = math.cos( radians ), math.sin( radians )
	return vector * cosine + axis:Cross( vector ) * sine + axis * axis:Dot( vector ) * ( 1 - cosine )
end

local function rotateBasis( xAxis, yAxis, zAxis, rotation )
	local x, y, z = tonumber( rotation[1] ) or 0, tonumber( rotation[2] ) or 0, tonumber( rotation[3] ) or 0
	if x ~= 0 then
		yAxis = rotatedAround( yAxis, xAxis, x )
		zAxis = rotatedAround( zAxis, xAxis, x )
	end
	if y ~= 0 then
		xAxis = rotatedAround( xAxis, yAxis, y )
		zAxis = rotatedAround( zAxis, yAxis, y )
	end
	if z ~= 0 then
		xAxis = rotatedAround( xAxis, zAxis, z )
		yAxis = rotatedAround( yAxis, zAxis, z )
	end
	return xAxis:GetNormalized(), yAxis:GetNormalized(), zAxis:GetNormalized()
end

function Renderer.HeldTransform( plan, displayContext, basePos, baseAng, baseSize )
	if not plan or not basePos or not baseAng then return nil end
	local transform = displayValues( plan, displayContext or "firstperson_righthand" )
	local rotation, translation, scale = transform.rotation or {}, transform.translation or {}, transform.scale or {}
	baseSize = math.max( tonumber( baseSize ) or 1, 0.001 )

	-- Minecraft item models use X/Y for the sprite and Z for its thickness.
	-- This basis makes the vanilla Y=-90 hand transform face back toward the camera.
	local leftHand = string.find( displayContext or "", "lefthand", 1, true ) ~= nil
	local xAxis = baseAng:Forward()
	local yAxis = baseAng:Up()
	local zAxis = leftHand and baseAng:Right() or -baseAng:Right()
	local pos = basePos
		+ xAxis * ( ( tonumber( translation[1] ) or 0 ) * baseSize / 16 )
		+ yAxis * ( ( tonumber( translation[2] ) or 0 ) * baseSize / 16 )
		+ zAxis * ( ( tonumber( translation[3] ) or 0 ) * baseSize / 16 )
	xAxis, yAxis, zAxis = rotateBasis( xAxis, yAxis, zAxis, rotation )
	if string.find( displayContext or "", "firstperson_", 1, true ) == 1 then
		-- Right- and left-hand JSON rotations face opposite sides of the sprite.
		-- Normalize their screen-space axes so the texture is not mirrored.
		if xAxis:Dot( baseAng:Right() ) < 0 then xAxis = -xAxis end
		if yAxis:Dot( baseAng:Up() ) < 0 then yAxis = -yAxis end
		if zAxis:Dot( baseAng:Forward() ) > 0 then zAxis = -zAxis end
	end
	return {
		pos = pos,
		xAxis = xAxis,
		yAxis = yAxis,
		normal = zAxis,
		width = baseSize * math.abs( tonumber( scale[1] ) or 1 ),
		height = baseSize * math.abs( tonumber( scale[2] ) or tonumber( scale[1] ) or 1 ),
		depthScale = math.abs( tonumber( scale[3] ) or 1 ),
	}
end

local function drawHeldLayer( material, transform, layerOffset, color )
	local center = transform.pos + transform.normal * layerOffset
	local x = transform.xAxis * ( transform.width * 0.5 )
	local y = transform.yAxis * ( transform.height * 0.5 )
	local topLeft = center - x + y
	local topRight = center + x + y
	local bottomRight = center + x - y
	local bottomLeft = center - x - y
	render.SetMaterial( material )

	-- DrawQuad assigns UVs from vertex order. The reverse-wound backside would
	-- therefore mirror the item when a no-cull material draws over the front.
	-- Bind UVs to the physical corners explicitly so both sides have one
	-- consistent Minecraft orientation.
	local function emit( position, u, v )
		mesh.Position( position )
		mesh.TexCoord( 0, u, v )
		mesh.Color( color.r, color.g, color.b, color.a )
		mesh.AdvanceVertex()
	end
	mesh.Begin( MATERIAL_QUADS, 2 )
	emit( topLeft, 0, 0 )
	emit( topRight, 1, 0 )
	emit( bottomRight, 1, 1 )
	emit( bottomLeft, 0, 1 )
	emit( bottomLeft, 0, 1 )
	emit( bottomRight, 1, 1 )
	emit( topRight, 1, 0 )
	emit( topLeft, 0, 0 )
	mesh.End()
end

function Renderer.DrawHeldItem( stack, pos, orientation, size, color, options )
	if not Renderer.CanDraw( stack ) or not pos or not orientation then return false end
	options = options or {}
	local modelOptions = {}
	for key, value in pairs( options ) do modelOptions[key] = value end
	modelOptions.displayContext = modelOptions.displayContext or "firstperson_righthand"
	local materials, plan = Renderer.MaterialsForStack( stack, modelOptions )
	if #materials == 0 then return false end
	color = color or Color( 255, 255, 255, 255 )
	-- Vector callers are world billboards (currently projectiles). Preserve that
	-- contract; Angle callers are hand anchors and receive Minecraft transforms.
	if isvector and isvector( orientation ) then
		local normal = orientation:GetNormalized()
		UI.WithPointFiltering( function()
			for index, material in ipairs( materials ) do
				render.SetMaterial( material )
				local offset = normal * ( ( index - 1 ) * 0.002 )
				render.DrawQuadEasy( pos + offset, normal, size, size, color, 0 )
				render.DrawQuadEasy( pos - offset, -normal, size, size, color, 180 )
			end
		end )
		return true
	end
	local baseAng
	if isangle and isangle( orientation ) then
		baseAng = Angle( orientation.p, orientation.y, orientation.r )
	end
	if not baseAng then return false end
	local transform = Renderer.HeldTransform( plan, modelOptions.displayContext, pos, baseAng, size )
	if not transform then return false end
	UI.WithPointFiltering( function()
		for index, material in ipairs( materials ) do
			drawHeldLayer( material, transform, ( index - 1 ) * 0.01 * transform.depthScale, color )
		end
	end )
	return true
end
