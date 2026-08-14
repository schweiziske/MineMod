-- Minecraft item-stack rendering shared by slots, hotbar and tooltips.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Renderer = {}
UI.ItemRenderer = Renderer

local GLINT_STRENGTH = 0.75
local GLINT_SPEED = 0.5
local GLINT_TEXTURE_SCALE = 8
local GLINT_ROTATION = math.rad( 10 )
local GLINT_MATERIAL = Material( "mc/misc/enchanted_glint_item.png", "smooth noclamp vertexcolor vertexalpha nocull" )
local GLINT_COLOR = Color( math.floor( 255 * GLINT_STRENGTH + 0.5 ),
	math.floor( 255 * GLINT_STRENGTH + 0.5 ), math.floor( 255 * GLINT_STRENGTH + 0.5 ), 255 )
local GLINT_BLEND_AVAILABLE = render and render.OverrideBlend
	and BLEND_SRC_COLOR ~= nil and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil

local function hasFoil( stack )
	return MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) == true
end

local function glintUV( u, v, textureScale )
	local elapsed = ( CurTime and CurTime() or 0 ) * 1000 * GLINT_SPEED * 8
	local offsetU = -( elapsed % 110000 ) / 110000
	local offsetV = ( elapsed % 30000 ) / 30000
	local cosine, sine = math.cos( GLINT_ROTATION ), math.sin( GLINT_ROTATION )
	textureScale = textureScale or GLINT_TEXTURE_SCALE
	return ( u * cosine - v * sine ) * textureScale + offsetU,
		( u * sine + v * cosine ) * textureScale + offsetV
end

local function beginGlintBlend()
	if not GLINT_BLEND_AVAILABLE then return false end
	render.OverrideBlend( true,
		BLEND_SRC_COLOR, BLEND_ONE, BLENDFUNC_ADD,
		BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD )
	return true
end

local function endGlintBlend( active )
	if active then render.OverrideBlend( false ) end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
end

local function drawGlintSurfaceRect( x, y, width, height )
	if not GLINT_MATERIAL or GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() then return false end
	surface.SetMaterial( GLINT_MATERIAL )
	surface.SetDrawColor( GLINT_COLOR.r, GLINT_COLOR.g, GLINT_COLOR.b, GLINT_COLOR.a )
	local u0, v0 = glintUV( 0, 0, GLINT_TEXTURE_SCALE )
	local u1, v1 = glintUV( 1, 0, GLINT_TEXTURE_SCALE )
	local u2, v2 = glintUV( 1, 1, GLINT_TEXTURE_SCALE )
	local u3, v3 = glintUV( 0, 1, GLINT_TEXTURE_SCALE )
	surface.DrawPoly( {
		{ x = x, y = y, u = u0, v = v0 },
		{ x = x + width, y = y, u = u1, v = v1 },
		{ x = x + width, y = y + height, u = u2, v = v2 },
		{ x = x, y = y + height, u = u3, v = v3 },
	} )
	return true
end

local function drawIconGlint( stack, drawMask, x, y, size )
	if not hasFoil( stack ) or not isfunction( drawMask ) or not render or not render.SetStencilEnable then return false end
	render.ClearStencil()
	render.SetStencilEnable( true )
	render.SetStencilWriteMask( 255 )
	render.SetStencilTestMask( 255 )
	render.SetStencilReferenceValue( 1 )
	render.SetStencilCompareFunction( STENCIL_ALWAYS )
	render.SetStencilPassOperation( STENCIL_REPLACE )
	render.SetStencilFailOperation( STENCIL_KEEP )
	render.SetStencilZFailOperation( STENCIL_KEEP )
	if render.OverrideColorWriteEnable then render.OverrideColorWriteEnable( true, false ) end
	if render.OverrideAlphaWriteEnable then render.OverrideAlphaWriteEnable( true, false ) end
	drawMask()
	if render.OverrideAlphaWriteEnable then render.OverrideAlphaWriteEnable( false, false ) end
	if render.OverrideColorWriteEnable then render.OverrideColorWriteEnable( false, false ) end
	render.SetStencilCompareFunction( STENCIL_EQUAL )
	render.SetStencilPassOperation( STENCIL_KEEP )
	local blended = beginGlintBlend()
	drawGlintSurfaceRect( x, y, size, size )
	endGlintBlend( blended )
	render.SetStencilEnable( false )
	render.ClearStencil()
	return true
end

local function definitionFor( stackOrDefinition )
	if type( stackOrDefinition ) == "table" and stackOrDefinition.name and not stackOrDefinition.item then
		return stackOrDefinition
	end
	return MC.GetItem and MC.GetItem( type( stackOrDefinition ) == "table" and stackOrDefinition.item or stackOrDefinition ) or nil
end

function Renderer.Definition( stack )
	return definitionFor( stack )
end

function Renderer.MaterialForLayer( layer, worldItem )
	if type( layer ) ~= "string" or layer == "" then return nil end
	if not string.match( layer, "%.png$" ) then layer = layer .. ".png" end
	if worldItem == true and UI.GetWorldItemMaterial then return UI.GetWorldItemMaterial( layer ) end
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
		local material = Renderer.MaterialForLayer( layer, options and options.worldItem == true )
		if material then materials[#materials + 1] = material end
	end
	return materials, plan
end

local function multiplyColor( left, right )
	left, right = left or color_white, right or color_white
	return Color(
		math.floor( ( left.r or 255 ) * ( right.r or 255 ) / 255 + 0.5 ),
		math.floor( ( left.g or 255 ) * ( right.g or 255 ) / 255 + 0.5 ),
		math.floor( ( left.b or 255 ) * ( right.b or 255 ) / 255 + 0.5 ),
		math.floor( ( left.a or 255 ) * ( right.a or 255 ) / 255 + 0.5 )
	)
end

function Renderer.LayerColor( stack, plan, index, baseColor )
	baseColor = baseColor or color_white
	local layer = plan and plan.layers and plan.layers[index] or nil
	if layer == "mc/item/potion_overlay" and MC.PotionContents and MC.PotionContents.Color then
		return multiplyColor( baseColor, MC.PotionContents.Color( stack ) )
	end
	return baseColor
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
local droppedBlockGlintGeometry = {}
local DROP_TRIANGLES = { 1, 3, 2, 1, 4, 3 }

local droppedBlockMaterials = {}

local function droppedBlockMaterial( translucent )
	local source = translucent and ( MC.MaterialTranslucent or MC.Material ) or MC.Material
	if not source or source.IsError and source:IsError() then return nil end
	if not ( CreateMaterial and source.GetTexture ) then return source end
	local texture = source:GetTexture( "$basetexture" )
	local textureName = texture and texture.GetName and texture:GetName() or nil
	if not textureName or textureName == "" or texture.IsError and texture:IsError() then return source end

	local key = translucent and "translucent" or "opaque"
	local material = droppedBlockMaterials[key]
	if not material or material.IsError and material:IsError() then
		local params = {
			["$basetexture"] = textureName,
			["$vertexcolor"] = "1",
			["$nocull"] = "0",
			["$hdrcolorscale"] = tostring( UI.WorldItemHDRColorScale or 0.25 ),
		}
		if translucent then
			params["$translucent"] = "1"
		else
			params["$alphatest"] = "1"
			params["$alphatestreference"] = "0.5"
		end
		material = CreateMaterial( "mc_item_drop_hdr_" .. key .. "_v3", "UnlitGeneric", params )
		if not material or material:IsError() then return source end
		droppedBlockMaterials[key] = material
	end
	material:SetTexture( "$basetexture", texture )
	if material.SetFloat then material:SetFloat( "$hdrcolorscale", UI.WorldItemHDRColorScale or 0.25 ) end
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
	tile = MC.ResolveAtlasTile and MC.ResolveAtlasTile( tile ) or tile
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

	local vertices, glintVertices = {}, {}
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
				glintVertices[#glintVertices + 1] = {
					pos = points[corner], normal = normal,
					u = texture[corner].u, v = texture[corner].v,
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
	droppedBlockGlintGeometry[stateId] = glintVertices
	cached = { mesh = blockMesh, translucent = translucent }
	droppedBlockMeshes[stateId] = cached
	return cached
end

local function drawDynamicGlintTriangles( vertices )
	if type( vertices ) ~= "table" or #vertices < 3
		or not GLINT_MATERIAL or GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() then return false end
	render.SetMaterial( GLINT_MATERIAL )
	mesh.Begin( MATERIAL_TRIANGLES, #vertices / 3 )
	for _, vertex in ipairs( vertices ) do
		local u, v = glintUV( vertex.u or 0, vertex.v or 0, GLINT_TEXTURE_SCALE )
		mesh.Position( vertex.pos )
		if vertex.normal then mesh.Normal( vertex.normal ) end
		mesh.TexCoord( 0, u, v )
		mesh.Color( 255, 255, 255, 255 )
		mesh.AdvanceVertex()
	end
	mesh.End()
	return true
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
	-- The base atlas is intentionally nearest-filtered.  Vanilla's glint texture
	-- carries blur:true, so its pass must happen after the POINT filter is gone.
	if filtered then
		render.PopFilterMag()
		render.PopFilterMin()
		filtered = false
	end
	if hasFoil( stack ) and GLINT_MATERIAL and not ( GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() ) then
		local blended = beginGlintBlend()
		render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
		render.SetBlend( 1 )
		cam.PushModelMatrix( matrix, true )
			drawDynamicGlintTriangles( droppedBlockGlintGeometry[stateId] )
		cam.PopModelMatrix()
		endGlintBlend( blended )
	end
	if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	return true
end

local function clearDroppedBlockMeshes()
	for _, cached in pairs( droppedBlockMeshes ) do
		if cached and cached.mesh and cached.mesh.Destroy then cached.mesh:Destroy() end
	end
	droppedBlockMeshes = {}
	droppedBlockGlintGeometry = {}
end

hook.Add( "ShutDown", "mc_item_drop_block_meshes", clearDroppedBlockMeshes )
hook.Add( "OnReloaded", "mc_item_drop_block_meshes", clearDroppedBlockMeshes )
hook.Add( "MC.AtlasProfileChanged", "mc_item_drop_block_meshes", clearDroppedBlockMeshes )

function Renderer.CanDraw( stack )
	return not MC.IsEmptyItemStack( stack ) and definitionFor( stack ) ~= nil
end

function Renderer.DrawIcon( stack, x, y, size, options )
	if not Renderer.CanDraw( stack ) then return false end
	options = options or {}
	local definition = definitionFor( stack )
	local materials, plan = Renderer.MaterialsForStack( stack, options )
	local drawn = false
	local drawMask
	if #materials > 0 then
		drawMask = function()
			UI.WithPointFiltering( function()
				for index, material in ipairs( materials ) do
					local color = Renderer.LayerColor( stack, plan, index, options.worldColor )
					UI.DrawTexture( material, x, y, size, size, nil, nil, nil, nil, color )
				end
			end )
		end
		drawMask()
		drawn = true
	elseif MC.DrawMinecraftBlockStateIcon then
		local stateId, blockId = blockStateFor( definition )
		if stateId then
			drawMask = function()
				UI.WithPointFiltering( function()
					MC.DrawMinecraftBlockStateIcon( stateId, x, y, size, size,
						options.forceModel == true, blockIconMaterial( blockId ), options.worldColor )
				end )
			end
			drawMask()
			drawn = true
		end
	end
	if drawn and drawMask then drawIconGlint( stack, drawMask, x, y, size ) end
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
	local customName, hasCustomName
	if MC.GetItemCustomName then customName, hasCustomName = MC.GetItemCustomName( stack ) end
	if hasCustomName then return customName end
	local enchantedBookName = MCITEM and MCITEM.EnchantedBookDisplayName
		and MCITEM.EnchantedBookDisplayName( stack ) or nil
	if enchantedBookName and enchantedBookName ~= "" then return enchantedBookName end
	local potionName = MC.PotionContents and MC.PotionContents.DisplayName
		and MC.PotionContents.DisplayName( stack ) or nil
	if potionName and potionName ~= "" then return potionName end
	return MC.ItemDisplayName and MC.ItemDisplayName( definition ) or tostring( definition.displayName or definition.name )
end

local DEFAULT_DISPLAY = {
	firstperson_righthand = { rotation = { 0, -90, 25 }, translation = { 1.13, 3.2, 1.13 }, scale = { 0.68, 0.68, 0.68 } },
	thirdperson_righthand = { rotation = { 0, 0, 0 }, translation = { 0, 3, 1 }, scale = { 0.55, 0.55, 0.55 } },
	ground = { rotation = { 0, 0, 0 }, translation = { 0, 2, 0 }, scale = { 0.5, 0.5, 0.5 } },
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
		depth = baseSize * math.abs( tonumber( scale[3] ) or 1 ),
	}
end

local function mcWeaponsFirstPersonTransform( plan, displayContext, basePos, baseAng, baseSize, view )
	local display = displayValues( plan, displayContext )
	local rotation, scale = display.rotation or {}, display.scale or {}
	local leftHand = string.find( displayContext or "", "lefthand", 1, true ) ~= nil
	local side = leftHand and -1 or 1
	local defaultRotation = DEFAULT_DISPLAY.firstperson_righthand.rotation
	local ang = Angle( baseAng.p, baseAng.y, baseAng.r )
	local pitch = ( tonumber( view.pitch ) or -3 )
		+ ( tonumber( rotation[1] ) or defaultRotation[1] ) - defaultRotation[1]
	local yaw = side * ( tonumber( view.yaw ) or 110 )
		+ ( tonumber( rotation[2] ) or side * defaultRotation[2] ) - side * defaultRotation[2]
	local roll = side * ( tonumber( view.roll ) or 20 )
		+ ( tonumber( rotation[3] ) or side * defaultRotation[3] ) - side * defaultRotation[3]
	ang:RotateAroundAxis( ang:Up(), yaw )
	ang:RotateAroundAxis( ang:Right(), pitch )
	ang:RotateAroundAxis( ang:Forward(), roll )
	return {
		pos = basePos,
		-- MC_weapons' compiled item models map model (X,Y,Z) to MC (Z,X,Y).
		xAxis = -ang:Right(),
		yAxis = ang:Up(),
		normal = ang:Forward(),
		width = baseSize * math.abs( tonumber( scale[1] ) or 0.68 ),
		height = baseSize * math.abs( tonumber( scale[2] ) or tonumber( scale[1] ) or 0.68 ),
		depthScale = math.abs( tonumber( scale[3] ) or 0.68 ),
		depth = baseSize * math.abs( tonumber( scale[3] ) or 0.68 ),
	}
end

local function drawFlatHeldLayer( material, transform, layerOffset, color )
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

local heldSpriteMeshes = {}
local glintSpriteGeometry = {}
local heldSpriteDrawMatrix = Matrix()
local SPRITE_HALF_DEPTH = 1 / 32
local bitPowers = {}
for index = 0, 31 do bitPowers[index] = 2 ^ index end

local function spriteMaskForLayer( layer )
	if type( layer ) ~= "string" or layer == "" then return nil end
	layer = string.gsub( layer, "%.png$", "" )
	return MC.ItemSpriteMasks and MC.ItemSpriteMasks[layer] or nil
end

local function maskOpaque( mask, x, y )
	if x < 0 or y < 0 or x >= mask.width or y >= mask.height then return false end
	local row = tonumber( mask.rows[y + 1] ) or 0
	return math.floor( row / bitPowers[x] ) % 2 == 1
end

local function appendVertex( target, position, normal, u, v )
	target[#target + 1] = { pos = position, normal = normal, u = u, v = v, color = color_white }
end

local function appendQuad( target, a, b, c, d, normal, au, av, bu, bv, cu, cv, du, dv )
	appendVertex( target, a, normal, au, av )
	appendVertex( target, c, normal, cu, cv )
	appendVertex( target, b, normal, bu, bv )
	appendVertex( target, a, normal, au, av )
	appendVertex( target, d, normal, du, dv )
	appendVertex( target, c, normal, cu, cv )
end

local function appendSolidUVQuad( target, a, b, c, d, normal, u, v )
	appendQuad( target, a, b, c, d, normal, u, v, u, v, u, v, u, v )
end

local function appendMaskedFaces( vertices, mask, width, height, front, back )
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if maskOpaque( mask, x, y ) then
				local x0, x1 = x / width - 0.5, ( x + 1 ) / width - 0.5
				local y1, y0 = 0.5 - y / height, 0.5 - ( y + 1 ) / height
				local u0, u1 = x / width, ( x + 1 ) / width
				local v0, v1 = y / height, ( y + 1 ) / height
				appendQuad( vertices,
					Vector( x0, y0, front ), Vector( x1, y0, front ),
					Vector( x1, y1, front ), Vector( x0, y1, front ), Vector( 0, 0, 1 ),
					u0, v1, u1, v1, u1, v0, u0, v0 )
				appendQuad( vertices,
					Vector( x0, y0, back ), Vector( x0, y1, back ),
					Vector( x1, y1, back ), Vector( x1, y0, back ), Vector( 0, 0, -1 ),
					u0, v1, u0, v0, u1, v0, u1, v1 )
			end
		end
	end
end

local function appendMaskedSides( vertices, mask, width, height, front, back )
	for y = 0, height - 1 do
		for x = 0, width - 1 do
			if maskOpaque( mask, x, y ) then
				local x0, x1 = x / width - 0.5, ( x + 1 ) / width - 0.5
				local y1, y0 = 0.5 - y / height, 0.5 - ( y + 1 ) / height
				local u, v = ( x + 0.5 ) / width, ( y + 0.5 ) / height
				if not maskOpaque( mask, x - 1, y ) then
					appendSolidUVQuad( vertices, Vector( x0, y1, back ), Vector( x0, y0, back ),
						Vector( x0, y0, front ), Vector( x0, y1, front ), Vector( -1, 0, 0 ), u, v )
				end
				if not maskOpaque( mask, x + 1, y ) then
					appendSolidUVQuad( vertices, Vector( x1, y0, back ), Vector( x1, y1, back ),
						Vector( x1, y1, front ), Vector( x1, y0, front ), Vector( 1, 0, 0 ), u, v )
				end
				if not maskOpaque( mask, x, y - 1 ) then
					appendSolidUVQuad( vertices, Vector( x1, y1, back ), Vector( x0, y1, back ),
						Vector( x0, y1, front ), Vector( x1, y1, front ), Vector( 0, 1, 0 ), u, v )
				end
				if not maskOpaque( mask, x, y + 1 ) then
					appendSolidUVQuad( vertices, Vector( x0, y0, back ), Vector( x1, y0, back ),
						Vector( x1, y0, front ), Vector( x0, y0, front ), Vector( 0, -1, 0 ), u, v )
				end
			end
		end
	end
end

local function buildHeldSpriteMesh( layer, material )
	local mask = spriteMaskForLayer( layer )
	if not mask or not Mesh or not material or material.IsError and material:IsError() then return nil end
	local width, height = tonumber( mask.width ) or 0, tonumber( mask.height ) or 0
	if width < 1 or height < 1 or width > 32 or height > 32 then return nil end

	local vertices = {}
	local front = SPRITE_HALF_DEPTH
	local back = -SPRITE_HALF_DEPTH
	local bottomLeft = Vector( -0.5, -0.5, front )
	local bottomRight = Vector( 0.5, -0.5, front )
	local topRight = Vector( 0.5, 0.5, front )
	local topLeft = Vector( -0.5, 0.5, front )
	appendQuad( vertices, bottomLeft, bottomRight, topRight, topLeft, Vector( 0, 0, 1 ),
		0, 1, 1, 1, 1, 0, 0, 0 )
	appendQuad( vertices,
		Vector( -0.5, -0.5, back ), Vector( -0.5, 0.5, back ),
		Vector( 0.5, 0.5, back ), Vector( 0.5, -0.5, back ), Vector( 0, 0, -1 ),
		0, 1, 0, 0, 1, 0, 1, 1 )

	appendMaskedSides( vertices, mask, width, height, front, back )

	local spriteMesh = Mesh( material )
	spriteMesh:BuildFromTriangles( vertices )
	return spriteMesh
end

local function heldSpriteMesh( layer, material )
	local key = string.gsub( tostring( layer or "" ), "%.png$", "" )
	local cached = heldSpriteMeshes[key]
	if cached == false then return nil end
	if cached and cached.material == material and cached.mesh then return cached.mesh end
	if cached and cached.mesh and cached.mesh.Destroy then cached.mesh:Destroy() end
	local spriteMesh = buildHeldSpriteMesh( key, material )
	heldSpriteMeshes[key] = spriteMesh and { material = material, mesh = spriteMesh } or false
	return spriteMesh
end

local function glintGeometryForLayer( layer )
	local key = string.gsub( tostring( layer or "" ), "%.png$", "" )
	local cached = glintSpriteGeometry[key]
	if cached == false then return nil end
	if cached then return cached end
	local mask = spriteMaskForLayer( key )
	local width, height = tonumber( mask and mask.width ) or 0, tonumber( mask and mask.height ) or 0
	if width < 1 or height < 1 or width > 32 or height > 32 then
		glintSpriteGeometry[key] = false
		return nil
	end
	local vertices = {}
	-- Keep the pass in the sprite silhouette and offset it slightly beyond the
	-- base front/back surfaces to prevent first/third-person depth fighting.
	appendMaskedFaces( vertices, mask, width, height,
		SPRITE_HALF_DEPTH + 0.0005, -SPRITE_HALF_DEPTH - 0.0005 )
	appendMaskedSides( vertices, mask, width, height,
		SPRITE_HALF_DEPTH + 0.0005, -SPRITE_HALF_DEPTH - 0.0005 )
	glintSpriteGeometry[key] = vertices
	return vertices
end

local function drawExtrudedHeldLayer( layer, material, transform, layerOffset, color )
	local spriteMesh = heldSpriteMesh( layer, material )
	if not spriteMesh then return false end
	local matrix = heldSpriteDrawMatrix
	matrix:SetTranslation( transform.pos + transform.normal * layerOffset )
	matrix:SetForward( transform.xAxis * transform.width )
	-- Source matrices expose a world-space Right vector, but their local +Y
	-- column is Left. Negate here so the sprite's local +Y remains Minecraft up.
	matrix:SetRight( -transform.yAxis * transform.height )
	matrix:SetUp( transform.normal * transform.depth )
	render.SetColorModulation( ( color.r or 255 ) / 255, ( color.g or 255 ) / 255, ( color.b or 255 ) / 255 )
	render.SetBlend( ( color.a or 255 ) / 255 )
	render.SetMaterial( material )
	if render.CullMode then
		local determinant = transform.xAxis:Cross( transform.yAxis ):Dot( transform.normal )
		local mirrored = determinant < 0
		local cullMode = droppedBlockCullMode()
		if mirrored then
			cullMode = cullMode == ( MATERIAL_CULLMODE_CCW or 0 )
				and ( MATERIAL_CULLMODE_CW or 1 ) or ( MATERIAL_CULLMODE_CCW or 0 )
		end
		render.CullMode( cullMode )
	end
	cam.PushModelMatrix( matrix, true )
		spriteMesh:Draw()
	cam.PopModelMatrix()
	if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	return true
end

local function clearHeldSpriteMeshes()
	for _, cached in pairs( heldSpriteMeshes ) do
		if cached and cached.mesh and cached.mesh.Destroy then cached.mesh:Destroy() end
	end
	heldSpriteMeshes = {}
	glintSpriteGeometry = {}
end

hook.Add( "ShutDown", "mc_item_held_sprite_meshes", clearHeldSpriteMeshes )
hook.Add( "OnReloaded", "mc_item_held_sprite_meshes", clearHeldSpriteMeshes )

function Renderer.DrawHeldItem( stack, pos, orientation, size, color, options )
	if not Renderer.CanDraw( stack ) or not pos or not orientation then return false end
	options = options or {}
	local modelOptions = {}
	for key, value in pairs( options ) do modelOptions[key] = value end
	modelOptions.displayContext = modelOptions.displayContext or "firstperson_righthand"
	modelOptions.worldItem = true
	local materials, plan = Renderer.MaterialsForStack( stack, modelOptions )
	if #materials == 0 then return false end
	color = color or Color( 255, 255, 255, 255 )
	-- Vector callers are world billboards (currently projectiles). Preserve that
	-- contract; Angle callers are hand anchors and receive Minecraft transforms.
	if isvector and isvector( orientation ) then
		local normal = orientation:GetNormalized()
		local x = Vector( 0, 0, 1 ):Cross( normal )
		if x:LengthSqr() < 0.000001 then x = Vector( 1, 0, 0 ) else x:Normalize() end
		local y = normal:Cross( x ):GetNormalized()
		UI.WithPointFiltering( function()
			for index, material in ipairs( materials ) do
				render.SetMaterial( material )
				local offset = normal * ( ( index - 1 ) * 0.002 )
				local layerColor = Renderer.LayerColor( stack, plan, index, color )
				render.DrawQuadEasy( pos + offset, normal, size, size, layerColor, 0 )
				render.DrawQuadEasy( pos - offset, -normal, size, size, layerColor, 180 )
			end
		end )
		if hasFoil( stack ) and GLINT_MATERIAL and not ( GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() ) then
			local blended = beginGlintBlend()
			render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
			render.SetBlend( 1 )
			for index = 1, #materials do
				local offset = normal * ( ( index - 1 ) * 0.002 + 0.001 )
				local layer = plan.layers and plan.layers[index] or nil
				local geometry = glintGeometryForLayer( layer )
				if geometry then
					local matrix = heldSpriteDrawMatrix
					matrix:SetTranslation( pos + offset )
					matrix:SetForward( x * size )
					matrix:SetRight( -y * size )
					matrix:SetUp( normal * math.max( size * 0.02, 0.001 ) )
					cam.PushModelMatrix( matrix, true )
						drawDynamicGlintTriangles( geometry )
					cam.PopModelMatrix()
				end
			end
			endGlintBlend( blended )
		end
		return true
	end
	local baseAng
	if isangle and isangle( orientation ) then
		baseAng = Angle( orientation.p, orientation.y, orientation.r )
	end
	if not baseAng then return false end
	local transform
	if type( modelOptions.mcWeaponsView ) == "table" then
		transform = mcWeaponsFirstPersonTransform( plan, modelOptions.displayContext, pos, baseAng, size,
			modelOptions.mcWeaponsView )
	else
		transform = Renderer.HeldTransform( plan, modelOptions.displayContext, pos, baseAng, size )
	end
	if not transform then return false end
	UI.WithPointFiltering( function()
		for index, material in ipairs( materials ) do
			local layer = plan.layers and plan.layers[index] or nil
			local offset = ( index - 1 ) * 0.01 * transform.depthScale
			local layerColor = Renderer.LayerColor( stack, plan, index, color )
			if not drawExtrudedHeldLayer( layer, material, transform, offset, layerColor ) then
				drawFlatHeldLayer( material, transform, offset, layerColor )
			end
		end
	end )
	if hasFoil( stack ) and GLINT_MATERIAL and not ( GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() ) then
		local blended = beginGlintBlend()
		if render.CullMode then render.CullMode( droppedBlockCullMode() ) end
		render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
		render.SetBlend( 1 )
		for index = 1, #materials do
			local layer = plan.layers and plan.layers[index] or nil
			local offset = ( index - 1 ) * 0.01 * transform.depthScale + 0.001
			local geometry = glintGeometryForLayer( layer )
			if geometry then
				local matrix = heldSpriteDrawMatrix
				matrix:SetTranslation( transform.pos + transform.normal * offset )
				matrix:SetForward( transform.xAxis * transform.width )
				matrix:SetRight( -transform.yAxis * transform.height )
				matrix:SetUp( transform.normal * transform.depth )
				render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
				render.SetBlend( 1 )
				cam.PushModelMatrix( matrix, true )
					drawDynamicGlintTriangles( geometry )
				cam.PopModelMatrix()
			end
		end
		endGlintBlend( blended )
		if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
	end
	return true
end
