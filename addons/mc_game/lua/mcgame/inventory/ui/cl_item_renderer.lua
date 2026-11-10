-- Minecraft item-stack rendering shared by slots, hotbar and tooltips.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Renderer = {}
UI.ItemRenderer = Renderer
Renderer.SpecialIconRenderers = {}
Renderer.SpecialWorldRenderers = {}

function Renderer.RegisterSpecialIconRenderer( typeName, callback )
	typeName = string.lower( tostring( typeName or "" ) )
	if typeName == "" then return false, "invalid_special_item_model_type" end
	if not isfunction( callback ) then return false, "invalid_special_item_model_renderer" end
	Renderer.SpecialIconRenderers[typeName] = callback
	return true
end

function Renderer.RegisterSpecialWorldRenderer( typeName, callback )
	typeName = string.lower( tostring( typeName or "" ) )
	if typeName == "" then return false, "invalid_special_item_model_type" end
	if not isfunction( callback ) then return false, "invalid_special_item_world_renderer" end
	Renderer.SpecialWorldRenderers[typeName] = callback
	return true
end

local function drawSpecialIcon( stack, plan, x, y, size, options )
	local special = plan and plan.special
	local typeName = type( special ) == "table" and string.lower( tostring( special.type or "" ) ) or ""
	local callback = Renderer.SpecialIconRenderers[typeName]
	if not callback then return false end
	local ok, result = pcall( callback, stack, plan, x, y, size, options or {} )
	if not ok then
		if ErrorNoHalt then ErrorNoHalt( "[MC Inventory] special item model " .. typeName
			.. " failed: " .. tostring( result ) .. "\n" ) end
		return false
	end
	if result == false or result == nil then return false end
	if isfunction( result ) then return true, result end
	if type( result ) == "table" then
		return result.drawn ~= false, result.drawMask,
			result.glintScaleU, result.glintScaleV,
			result.glintOriginU, result.glintOriginV
	end
	return result == true
end

local function drawSpecialWorld( stack, plan, pos, orientation, size, color, options )
	local special = plan and plan.special
	local typeName = type( special ) == "table" and string.lower( tostring( special.type or "" ) ) or ""
	local callback = Renderer.SpecialWorldRenderers[typeName]
	if not callback then return false end
	local ok, result = pcall( callback, stack, plan, pos, orientation, size, color, options or {} )
	if not ok then
		if ErrorNoHalt then ErrorNoHalt( "[MC Inventory] special world item model " .. typeName
			.. " failed: " .. tostring( result ) .. "\n" ) end
		return false
	end
	if type( result ) == "table" then return result.drawn ~= false end
	return result == true
end

local GLINT_STRENGTH = 0.75
local GLINT_SPEED = 0.5
local GLINT_JAVA_TEXTURE_SCALE = 8
-- Java 26.2 stitches items and blocks separately.  The default item atlas is
-- 1024x512 because mip-0 sprites still receive one border pixel from Stitcher.
-- Generated sprite metadata supplies the exact content origin and dimensions;
-- these constants are only a safe fallback for addon-only item textures.
local GLINT_ITEM_ATLAS_WIDTH = 1024
local GLINT_ITEM_ATLAS_HEIGHT = 512
local GLINT_ITEM_TEXTURE_SCALE_U = GLINT_JAVA_TEXTURE_SCALE * 16 / GLINT_ITEM_ATLAS_WIDTH
local GLINT_ITEM_TEXTURE_SCALE_V = GLINT_JAVA_TEXTURE_SCALE * 16 / GLINT_ITEM_ATLAS_HEIGHT
local GLINT_BLOCK_TEXTURE_SCALE = GLINT_JAVA_TEXTURE_SCALE * 16 / 1024
local GLINT_ROTATION = math.rad( 10 )
-- This renderer supplies moving UVs explicitly, so the PNG auto-material is
-- sufficient. Do not copy its texture into a white-backed material at
-- startup: Source may still expose the white placeholder while PNG loading is
-- pending, which would permanently turn the additive glint pass solid white.
local GLINT_MATERIAL = Material(
	"mc/misc/enchanted_glint_item.png",
	"smooth noclamp vertexcolor vertexalpha nocull"
)
local GLINT_COLOR = Color( math.floor( 255 * GLINT_STRENGTH + 0.5 ),
	math.floor( 255 * GLINT_STRENGTH + 0.5 ), math.floor( 255 * GLINT_STRENGTH + 0.5 ), 255 )
local GLINT_BLEND_AVAILABLE = render and render.OverrideBlend
	and BLEND_SRC_COLOR ~= nil and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil

local spriteMaskBitPowers = {}
for index = 0, 31 do spriteMaskBitPowers[index] = 2 ^ index end

local function spriteMaskForLayer( layer )
	if type( layer ) ~= "string" or layer == "" then return nil end
	layer = string.gsub( layer, "%.png$", "" )
	return MC.ItemSpriteMasks and MC.ItemSpriteMasks[layer]
		or MC.ItemBlockSpriteMasks and MC.ItemBlockSpriteMasks[layer] or nil
end

local function maskOpaque( mask, x, y )
	if not mask or not mask.rows or x < 0 or y < 0 or x >= mask.width or y >= mask.height then return false end
	local row = tonumber( mask.rows[y + 1] ) or 0
	return math.floor( row / spriteMaskBitPowers[x] ) % 2 == 1
end

local function hasFoil( stack )
	return MC.ItemStackHasFoil and MC.ItemStackHasFoil( stack ) == true
end

local function itemGlintTransform( layer )
	local mask = spriteMaskForLayer( layer )
	local width = math.max( tonumber( mask and mask.width ) or 16, 1 )
	local height = math.max( tonumber( mask and mask.height ) or 16, 1 )
	local atlasWidth = tonumber( mask and mask.atlasWidth )
		or tonumber( MC.ItemSpriteAtlasWidth ) or GLINT_ITEM_ATLAS_WIDTH
	local atlasHeight = tonumber( mask and mask.atlasHeight )
		or tonumber( MC.ItemSpriteAtlasHeight ) or GLINT_ITEM_ATLAS_HEIGHT
	local atlasX, atlasY = tonumber( mask and mask.atlasX ), tonumber( mask and mask.atlasY )
	if atlasX and atlasY and atlasWidth > 0 and atlasHeight > 0 then
		return GLINT_JAVA_TEXTURE_SCALE * width / atlasWidth,
			GLINT_JAVA_TEXTURE_SCALE * height / atlasHeight,
			GLINT_JAVA_TEXTURE_SCALE * atlasX / atlasWidth,
			GLINT_JAVA_TEXTURE_SCALE * atlasY / atlasHeight
	end
	return GLINT_ITEM_TEXTURE_SCALE_U, GLINT_ITEM_TEXTURE_SCALE_V, 0, 0
end

local function drawSpriteMaskRuns( mask, x, y, size )
	local width = math.max( math.floor( tonumber( mask and mask.width ) or 0 ), 0 )
	local height = math.max( math.floor( tonumber( mask and mask.height ) or 0 ), 0 )
	if width < 1 or height < 1 or width > 32 or height > 32 then return false end

	local pixelWidth, pixelHeight = size / width, size / height
	for rowIndex = 0, height - 1 do
		local column = 0
		while column < width do
			while column < width and not maskOpaque( mask, column, rowIndex ) do
				column = column + 1
			end
			local runStart = column
			while column < width and maskOpaque( mask, column, rowIndex ) do
				column = column + 1
			end
			if runStart < column then
				surface.DrawRect( x + runStart * pixelWidth, y + rowIndex * pixelHeight,
					( column - runStart ) * pixelWidth, pixelHeight )
			end
		end
	end
	return true
end

local function iconSpriteMaskCallback( layers, x, y, size )
	local masks = {}
	for _, layer in ipairs( layers or {} ) do
		local mask = spriteMaskForLayer( layer )
		if mask then masks[#masks + 1] = mask end
	end
	if #masks == 0 then return nil end

	return function()
		-- Stencil writes happen for every submitted fragment, including fully
		-- transparent texels. Draw the generated opaque-pixel runs instead of
		-- re-submitting the texture's full rectangle.
		-- Color/alpha writes are disabled by drawIconGlint while this callback
		-- runs. Keep submitted pixels opaque so Source cannot discard them before
		-- the stencil pass records their silhouette.
		surface.SetDrawColor( 255, 255, 255, 255 )
		for _, mask in ipairs( masks ) do
			drawSpriteMaskRuns( mask, x, y, size )
		end
	end
end

local function glintUV( u, v, textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	-- Vanilla drives this transform from wall-clock milliseconds.  RealTime
	-- keeps the shimmer moving even when simulation time is paused or scaled.
	local now = RealTime and RealTime() or ( CurTime and CurTime() or 0 )
	local elapsed = now * 1000 * GLINT_SPEED * 8
	local offsetU = -( elapsed % 110000 ) / 110000
	local offsetV = ( elapsed % 30000 ) / 30000
	local cosine, sine = math.cos( GLINT_ROTATION ), math.sin( GLINT_ROTATION )
	textureScaleU = textureScaleU or GLINT_ITEM_TEXTURE_SCALE_U
	textureScaleV = textureScaleV or GLINT_ITEM_TEXTURE_SCALE_V
	local atlasU = u * textureScaleU + ( textureOriginU or 0 )
	local atlasV = v * textureScaleV + ( textureOriginV or 0 )
	return atlasU * cosine - atlasV * sine + offsetU,
		atlasU * sine + atlasV * cosine + offsetV
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

function Renderer.DrawSpecialWorldGlint( stack, callback,
	textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	if not hasFoil( stack ) or not isfunction( callback )
		or not GLINT_MATERIAL or GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() then return false end
	local blended = beginGlintBlend()
	render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
	render.SetBlend( 1 )
	local ok, result = pcall( callback, GLINT_MATERIAL, function( u, v )
		return glintUV( u, v, textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	end )
	endGlintBlend( blended )
	if not ok then
		if ErrorNoHalt then ErrorNoHalt( "[MC Inventory] special world glint failed: "
			.. tostring( result ) .. "\n" ) end
		return false
	end
	return result ~= false
end

local function drawGlintSurfaceRect( x, y, width, height,
	textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	if not GLINT_MATERIAL or GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() then return false end
	surface.SetMaterial( GLINT_MATERIAL )
	surface.SetDrawColor( GLINT_COLOR.r, GLINT_COLOR.g, GLINT_COLOR.b, GLINT_COLOR.a )
	local u0, v0 = glintUV( 0, 0, textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	local u1, v1 = glintUV( 1, 0, textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	local u2, v2 = glintUV( 1, 1, textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	local u3, v3 = glintUV( 0, 1, textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	surface.DrawPoly( {
		{ x = x, y = y, u = u0, v = v0 },
		{ x = x + width, y = y, u = u1, v = v1 },
		{ x = x + width, y = y + height, u = u2, v = v2 },
		{ x = x, y = y + height, u = u3, v = v3 },
	} )
	return true
end

local function drawIconGlint( stack, drawMask, x, y, size,
	textureScaleU, textureScaleV, textureOriginU, textureOriginV )
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
	drawGlintSurfaceRect( x, y, size, size,
		textureScaleU, textureScaleV, textureOriginU, textureOriginV )
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

local blockLayerMaterials = {}

local function blockLayerTexture( layer )
	local source = MC.MaterialHeldBlock
	if not MC.Check( source and MC.TileUV, "item_block_layer_atlas", "Missing item atlas for %s", layer ) then return nil end
	local texture = source:GetTexture( "$basetexture" )
	if not MC.Check( texture and not texture:IsError(), "item_block_layer_texture", "Missing item texture for %s", layer ) then return nil end
	return texture
end

local function bindBlockLayer( entry, texture )
	if not texture then return false end
	local u0, v0, u1, v1 = MC.TileUV( entry.tile )
	local transform = Matrix()
	transform:SetField( 1, 1, u1 - u0 )
	transform:SetField( 2, 2, v1 - v0 )
	transform:SetField( 1, 4, u0 )
	transform:SetField( 2, 4, v0 )
	entry.material:SetTexture( "$basetexture", texture )
	entry.material:SetMatrix( "$basetexturetransform", transform )
	if MC.ResourceGeneration then MC.ResourceGeneration.TrackMaterial( entry.material ) end
	return true
end

local function blockLayerMaterial( layer, tileName, worldItem )
	local key = layer .. ( worldItem and "|world" or "|icon" )
	local cached = blockLayerMaterials[key]
	if cached then return cached.material end
	local tile = MC.Tiles and MC.Tiles[tileName]
	if not MC.Check( tile ~= nil, "item_block_layer_tile", "Unknown block sprite %s", layer ) then return nil end
	local texture = blockLayerTexture( layer )
	if not texture then return nil end
	-- VGUI keeps the mapping dimensions from material creation. Seed with the
	-- real atlas and separate sizes so cached 1x1 bootstrap materials cannot
	-- collapse DrawTexturedRect's UVs after the atlas becomes available.
	local name = "mc_item_block_layer_" .. tile .. ( worldItem and "_world" or "_icon" )
		.. "_mapping_v1_" .. texture:Width() .. "x" .. texture:Height()
	local material = CreateMaterial( name, "UnlitGeneric", {
		["$basetexture"] = texture:GetName(), ["$vertexcolor"] = "1", ["$vertexalpha"] = "1",
		["$nocull"] = worldItem and "0" or "1", ["$alphatest"] = "1", ["$alphatestreference"] = "0.5",
		["$hdrcolorscale"] = tostring( UI.WorldItemHDRColorScale or 1 ),
	} )
	if not MC.Check( material and not material:IsError(), "item_block_layer_material", "Cannot create block sprite material %s", layer ) then return nil end
	cached = { layer = layer, tile = tile, material = material, worldItem = worldItem }
	if not bindBlockLayer( cached, texture ) then return nil end
	blockLayerMaterials[key] = cached
	return material
end

hook.Add( "MC.TexturePackChanged", "mc_item_block_layers", function()
	-- Prepared drops retain these material handles across resource-pack changes.
	-- UI draws resolve again so a changed atlas size gets matching VGUI mapping.
	for key, entry in pairs( blockLayerMaterials ) do
		if entry.worldItem then
			bindBlockLayer( entry, blockLayerTexture( entry.layer ) )
		else
			blockLayerMaterials[key] = nil
		end
	end
end )

function Renderer.MaterialForLayer( layer, worldItem )
	if type( layer ) ~= "string" or layer == "" then return nil end
	local tileName = string.match( layer, "^mc/block/([a-z0-9_/%-]+)$" )
	if tileName then return blockLayerMaterial( layer, tileName, worldItem == true ) end
	-- Explicit Source materials (such as the 128px GMod logo) already name a
	-- complete resource; only bare item texture paths need the PNG extension.
	if not string.match( layer, "%.png$" ) and not string.match( layer, "%.vmt$" ) then
		layer = layer .. ".png"
	end
	if worldItem == true and UI.GetWorldItemMaterial then return UI.GetWorldItemMaterial( layer ) end
	return UI.GetMaterial( layer )
end

function Renderer.MaterialForDefinition( definition )
	if not definition then return nil end
	if definition.texture then return Renderer.MaterialForLayer( definition.texture ) end
	return nil
end

function Renderer.ModelPlan( stack, options )
	local weapon = MC.SpawnmenuWeapons and MC.SpawnmenuWeapons.Record( stack )
	if weapon then
		if not weapon.plan then
			local path = weapon.icon
			local definition = list.Get( "Weapon" )[weapon.class]
			if definition and type( definition.IconOverride ) == "string" and definition.IconOverride ~= "" then
				path = definition.IconOverride
			end
			local material = Material( path, "smooth" )
			if material:IsError() then
				-- Match ContentIcon's support for old VGUI/entities VMT icons.
				path = string.gsub( path, "entities/", "VGUI/entities/" )
				path = string.gsub( path, "%.png$", "" )
				material = Material( path, "smooth" )
			end
			if material:IsError() then
				path = "icon16/gun.png"
				material = Material( path, "smooth" )
			end
			weapon.plan = { layers = { path }, kind = "flat" }
			weapon.materials = { material }
		end
		return weapon.plan
	end
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
	local weapon = MC.SpawnmenuWeapons and MC.SpawnmenuWeapons.Record( stack )
	if weapon then return weapon.materials, plan end
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
	-- Use the same single-level atlas as held blocks; POINT alone still allows
	-- a mipmapped world texture to choose a lower-resolution level.
	local source = translucent and MC.MaterialHeldBlockTranslucent or MC.MaterialHeldBlock
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
			["$hdrcolorscale"] = tostring( UI.WorldItemHDRColorScale or 1 ),
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
	if material.SetFloat then material:SetFloat( "$hdrcolorscale", UI.WorldItemHDRColorScale or 1 ) end
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
	-- Resource packs can use packed sprite regions rather than a uniform grid.
	-- Share the world's atlas addressing instead of sampling an unrelated slot.
	return MC.TileUV( tile, uv )
end

local function rotatedUV( u, v, rotation )
	rotation = math.floor( tonumber( rotation ) or 0 ) % 4
	if rotation == 1 then return v, 1 - u end
	if rotation == 2 then return 1 - u, 1 - v end
	if rotation == 3 then return 1 - v, u end
	return u, v
end

local function droppedBlockState( stack, options, plan )
	local definition = definitionFor( stack )
	if not definition or definition.blockId == nil then return nil end
	plan = plan or Renderer.ModelPlan( stack, options or { displayContext = "ground" } )
	local modelId = tostring( plan and plan.modelId or "" )
	-- Block-shaped item models also live under item/ (fences and panes).
	-- Keep flat sprites and special entity renderers on their own paths.
	if plan.kind ~= "block" and not string.find( modelId, ":block/", 1, true ) then return nil end
	return blockStateFor( definition )
end

local function droppedBlockMesh( stateId, blockId )
	local cached = droppedBlockMeshes[stateId]
	if cached ~= nil then return cached ~= false and cached or nil end
	if not MC.Check( Mesh and MC.VisitStateVisualModels and MC.StateVisualModelData
		and MC.BlockModelSurface and MC.ModelQuadVertex and MC.TileUV,
		"item_drop_mesh_dependencies", "Missing dropped block mesh dependency (state %s)", stateId ) then
		return nil
	end

	local vertices, glintVertices = {}, {}
	local visitedModel = false
	local missingModel = false
	MC.VisitStateVisualModels( stateId, 0, 0, 0, function( modelId )
		visitedModel = true
		local model = MC.StateVisualModelData( modelId )
		if not model then
			MC.Fault( "item_drop_model_missing", "Missing dropped block model %s for state %s", modelId, stateId )
			missingModel = true
			return
		end
		for _, quad in ipairs( model and model.modelQuads or {} ) do
			local tile = MC.BlockModelSurface( model, quad )
			local atlasU0, atlasV0, atlasU1, atlasV1 = droppedTileUVRect( tile, quad.uv )
			local points, texture, glintTexture = {}, {}, {}
			local quadUV = quad.uv
			local localU0 = ( tonumber( quadUV and quadUV[1] ) or 0 ) / 16
			local localV0 = ( tonumber( quadUV and quadUV[2] ) or 0 ) / 16
			local localU1 = ( tonumber( quadUV and quadUV[3] ) or 16 ) / 16
			local localV1 = ( tonumber( quadUV and quadUV[4] ) or 16 ) / 16
			for index = 1, 4 do
				local x, y, z, u, v = MC.ModelQuadVertex( quad, index )
				u, v = rotatedUV( u, v, quad.rot )
				points[index] = Vector( x - 0.5, y - 0.5, z - 0.5 )
				texture[index] = {
					u = atlasU0 + ( atlasU1 - atlasU0 ) * u,
					v = atlasV0 + ( atlasV1 - atlasV0 ) * v,
				}
				glintTexture[index] = {
					u = localU0 + ( localU1 - localU0 ) * u,
					v = localV0 + ( localV1 - localV0 ) * v,
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
					u = glintTexture[corner].u, v = glintTexture[corner].v,
				}
			end
		end
	end )
	if #vertices == 0 then
		MC.Fault( "item_drop_mesh_empty", "No dropped block vertices for state %s (block %s, visited %s)",
			stateId, blockId, tostring( visitedModel ) )
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

local function drawDynamicGlintTriangles( vertices,
	textureScaleU, textureScaleV, textureOriginU, textureOriginV )
	if type( vertices ) ~= "table" or #vertices < 3
		or not GLINT_MATERIAL or GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() then return false end
	render.SetMaterial( GLINT_MATERIAL )
	mesh.Begin( MATERIAL_TRIANGLES, #vertices / 3 )
	for _, vertex in ipairs( vertices ) do
		local u, v = glintUV( vertex.u or 0, vertex.v or 0,
			textureScaleU, textureScaleV, textureOriginU, textureOriginV )
		mesh.Position( vertex.pos )
		if vertex.normal then mesh.Normal( vertex.normal ) end
		mesh.TexCoord( 0, u, v )
		mesh.Color( 255, 255, 255, 255 )
		mesh.AdvanceVertex()
	end
	mesh.End()
	return true
end

local droppedBlockDrawMatrix = Matrix()
local droppedBlockDrawScale = Vector( 1, 1, 1 )
local itemMeshLightColor = Vector( 1, 1, 1 )

-- IMesh draws consume the material modulation directly. Model-renderer
-- colour modulation alone does not reliably reach these cached meshes.
local function bindItemMeshColor( material, color )
	local previous = material:GetVector( "$color2" )
	itemMeshLightColor.x, itemMeshLightColor.y, itemMeshLightColor.z =
		color.r / 255, color.g / 255, color.b / 255
	material:SetVector( "$color2", itemMeshLightColor )
	render.SetColorModulation( 1, 1, 1 )
	return previous
end

local itemMeshWhite = Vector( 1, 1, 1 )

function Renderer.DrawDroppedBlock( stack, position, angles, size, worldColor, options, prepared )
	if prepared and ( prepared.stack ~= stack or prepared.options ~= options ) then prepared = nil end
	local stateId, blockId
	if prepared then stateId, blockId = prepared.stateId, prepared.blockId
	else stateId, blockId = droppedBlockState( stack, options ) end
	if not stateId then return false end
	local cached = droppedBlockMesh( stateId, blockId )
	if not cached or not cached.mesh then return false end
	local material = droppedBlockMaterial( cached.translucent )
	if not material then return false end
	local matrix = droppedBlockDrawMatrix
	matrix:Identity()
	matrix:SetTranslation( position )
	matrix:SetAngles( angles )
	size = math.max( 0.01, tonumber( size ) or 12 )
	droppedBlockDrawScale.x, droppedBlockDrawScale.y, droppedBlockDrawScale.z = size, size, size
	matrix:SetScale( droppedBlockDrawScale )
	worldColor = worldColor or color_white
	local previousColor = bindItemMeshColor( material, worldColor )
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
	material:SetVector( "$color2", previousColor or itemMeshWhite )
	-- The base atlas is intentionally nearest-filtered.  Vanilla's glint texture
	-- carries blur:true, so its pass must happen after the POINT filter is gone.
	if filtered then
		render.PopFilterMag()
		render.PopFilterMin()
		filtered = false
	end
	local foil
	if prepared then foil = prepared.foil else foil = hasFoil( stack ) end
	if foil and GLINT_MATERIAL and not ( GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() ) then
		local blended = beginGlintBlend()
		render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
		render.SetBlend( 1 )
		cam.PushModelMatrix( matrix, true )
			drawDynamicGlintTriangles( droppedBlockGlintGeometry[stateId],
				GLINT_BLOCK_TEXTURE_SCALE, GLINT_BLOCK_TEXTURE_SCALE )
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

-- Explicit diagnostic pass: inspect the nearest block drop without adding
-- metadata checks or logging to every drawn copy/vertex.
concommand.Add( "mc_item_drop_debug", function()
	local nearest, distance
	local eye = EyePos()
	for _, ent in ipairs( ents.FindByClass( "mc_item_drop" ) ) do
		local definition = MC.GetItem( ent:GetItemName() )
		if definition and definition.blockId then
			local candidate = ent:GetPos():DistToSqr( eye )
			if not distance or candidate < distance then nearest, distance = ent, candidate end
		end
	end
	if not nearest then print( "[MC item drop] No networked block drop found" ) return end
	MC.Try( "item_drop_debug", function()
		local cached = nearest.MCDropVisual
		local stack = cached and cached.stack or { item = nearest:GetItemName(), count = nearest:GetItemCount() }
		local options = { displayContext = "ground", worldItem = true }
		local plan = Renderer.ModelPlan( stack, options )
		local stateId, blockId = droppedBlockState( stack, options, plan )
		print( "[MC item drop]", nearest, stack.item, "kind", plan.kind, "model", plan.modelId,
			"state", stateId, "block", blockId, "draw reached", cached ~= nil, "position", nearest:GetPos() )
		if not stateId then return end
		local record = droppedBlockMesh( stateId, blockId )
		local material = record and droppedBlockMaterial( record.translucent )
		local texture = material and material:GetTexture( "$basetexture" )
		print( "[MC item drop] mesh", record and record.mesh, "vertices",
			#( droppedBlockGlintGeometry[stateId] or {} ), "material", material,
			"texture", texture, "cull", droppedBlockCullMode(), "atlas", MC.AtlasProfileName() )
	end )
end )

function Renderer.CanDraw( stack )
	return not MC.IsEmptyItemStack( stack ) and definitionFor( stack ) ~= nil
end

local doorIconOffsets = setmetatable( {}, { __mode = "k" } )
local doorIconPoly = {
	{ x = 0, y = 0, u = 0, v = 0 }, { x = 0, y = 0, u = 1, v = 0 },
	{ x = 0, y = 0, u = 1, v = 1 }, { x = 0, y = 0, u = 0, v = 1 },
}

local function doorIconOffset( definition, plan )
	if not string.match( definition.name or "", "_door$" ) or #plan.layers ~= 1 then return nil end
	local mask = spriteMaskForLayer( plan.layers[1] )
	if not mask then return nil end
	local cached = doorIconOffsets[mask]
	if cached then return cached end
	-- Masks are validated when the generated catalog loads. Scan once per
	-- mask, then reuse the normalized offset at every inventory/HUD scale.
	local width, height = mask.width, mask.height
	local minX, minY, maxX, maxY = width, height, 0, 0
	for rowIndex = 0, height - 1 do
		local row = mask.rows[rowIndex + 1]
		for column = 0, width - 1 do
			if math.floor( row / spriteMaskBitPowers[column] ) % 2 == 1 then
				minX, minY = math.min( minX, column ), math.min( minY, rowIndex )
				maxX, maxY = math.max( maxX, column + 1 ), math.max( maxY, rowIndex + 1 )
			end
		end
	end
	if maxX <= minX or maxY <= minY then return nil end
	cached = { x = 0.5 - ( minX + maxX ) / ( 2 * width ),
		y = 0.5 - ( minY + maxY ) / ( 2 * height ) }
	doorIconOffsets[mask] = cached
	return cached
end

local function drawDoorIcon( material, x, y, size, color )
	-- Explicit edge UVs preserve the full 16x16 canvas without the textured
	-- rectangle helper's texel inset. Reuse the polygon instead of allocating
	-- vertices each Paint; the alpha-mask offset centers the visible door.
	local a, b, c, d = doorIconPoly[1], doorIconPoly[2], doorIconPoly[3], doorIconPoly[4]
	a.x, a.y, b.x, b.y = x, y, x + size, y
	c.x, c.y, d.x, d.y = x + size, y + size, x, y + size
	surface.SetMaterial( material )
	surface.SetDrawColor( color.r or 255, color.g or 255, color.b or 255, color.a or 255 )
	surface.DrawPoly( doorIconPoly )
end

function Renderer.DrawIcon( stack, x, y, size, options )
	if not Renderer.CanDraw( stack ) then return false end
	options = options or {}
	local definition = definitionFor( stack )
	local materials, plan = Renderer.MaterialsForStack( stack, options )
	local drawn = false
	local drawMask
	local layeredItemGlint = false
	local glintTextureScaleU, glintTextureScaleV
	local glintTextureOriginU, glintTextureOriginV
	if plan.kind == "special" then
		drawn, drawMask, glintTextureScaleU, glintTextureScaleV,
			glintTextureOriginU, glintTextureOriginV =
			drawSpecialIcon( stack, plan, x, y, size, options )
	end
	if not drawn and #materials > 0 then
		local gui = plan.display and plan.display.gui
		local translation = gui and gui.translation
		if translation then
			-- Item-model translations use sixteenths of the GUI canvas, with
			-- positive Y pointing up. Share the result with the foil mask/pass.
			x = x + ( translation[1] or 0 ) * size / 16
			y = y - ( translation[2] or 0 ) * size / 16
		end
		local offset = doorIconOffset( definition, plan )
		if offset then x, y = x + offset.x * size, y + offset.y * size end
		drawMask = function()
			UI.WithPointFiltering( function()
				for index, material in ipairs( materials ) do
					local color = Renderer.LayerColor( stack, plan, index, options.worldColor )
					if offset then
						drawDoorIcon( material, x, y, size, color )
					else
						UI.DrawTexture( material, x, y, size, size, nil, nil, nil, nil, color )
					end
				end
			end )
		end
		layeredItemGlint = true
		drawMask()
		drawn = true
	elseif not drawn and MC.DrawMinecraftBlockStateIcon then
		local stateId, blockId = blockStateFor( definition )
		if stateId then
			glintTextureScaleU = GLINT_BLOCK_TEXTURE_SCALE
			glintTextureScaleV = GLINT_BLOCK_TEXTURE_SCALE
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
	if drawn and drawMask then
		if layeredItemGlint and hasFoil( stack ) then
			-- Vanilla's foil consumer sees every BakedQuad independently.  Keep
			-- multi-layer icons separate so each texture contributes with its own
			-- item-atlas UV window instead of sharing layer 1's phase.
			for _, layer in ipairs( plan.layers or {} ) do
				local layerMask = iconSpriteMaskCallback( { layer }, x, y, size )
				if layerMask then
					local scaleU, scaleV, originU, originV = itemGlintTransform( layer )
					drawIconGlint( stack, layerMask, x, y, size,
						scaleU, scaleV, originU, originV )
				end
			end
		else
			drawIconGlint( stack, drawMask, x, y, size,
				glintTextureScaleU, glintTextureScaleV,
				glintTextureOriginU, glintTextureOriginV )
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
	UI.DrawText( text, x + 17 * scale, y + 9 * scale, scale, UI.Colors.text,
		TEXT_ALIGN_RIGHT, true, TEXT_ALIGN_TOP )
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

-- locale (default: the interface language) reaches every name lookup below;
-- a player's custom name and a GMod weapon title are shown as they are.
function Renderer.DisplayName( stack, locale )
	local definition = definitionFor( stack )
	if not definition then return "" end
	local customName, hasCustomName
	if MC.GetItemCustomName then customName, hasCustomName = MC.GetItemCustomName( stack ) end
	if hasCustomName then return customName end
	local weapon = MC.SpawnmenuWeapons and MC.SpawnmenuWeapons.Record( stack )
	if weapon then return language.GetPhrase( weapon.title ) end
	local enchantedBookName = MCITEM and MCITEM.EnchantedBookDisplayName
		and MCITEM.EnchantedBookDisplayName( stack, locale ) or nil
	if enchantedBookName and enchantedBookName ~= "" then return enchantedBookName end
	local potionName = MC.PotionContents and MC.PotionContents.DisplayName
		and MC.PotionContents.DisplayName( stack, locale ) or nil
	if potionName and potionName ~= "" then return potionName end
	return MC.ItemDisplayName( definition, locale )
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
		transform = display[rightContext]
	end
	if not transform then
		local rightContext = string.gsub( context, "lefthand", "righthand", 1 )
		transform = DEFAULT_DISPLAY[rightContext] or DEFAULT_DISPLAY.firstperson_righthand
	end
	if not leftHand then return transform end

	-- ItemTransform.apply(leftHand) mirrors the selected transform even when a
	-- model provides an explicit *_lefthand entry: translation X and rotations
	-- Y/Z are negated after context selection. Keeping this in one place also
	-- makes right-hand fallback transforms obey the same vanilla rule.
	local rotation = transform.rotation or {}
	local translation = transform.translation or {}
	transform = {
		rotation = {
			tonumber( rotation[1] ) or 0,
			-( tonumber( rotation[2] ) or 0 ),
			-( tonumber( rotation[3] ) or 0 ),
		},
		translation = {
			-( tonumber( translation[1] ) or 0 ),
			tonumber( translation[2] ) or 0,
			tonumber( translation[3] ) or 0,
		},
		scale = transform.scale,
	}
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

function Renderer.HeldTransform( plan, displayContext, basePos, baseAng, baseSize, parentBasis )
	if not plan or not basePos or not baseAng then return nil end
	local transform = displayValues( plan, displayContext or "firstperson_righthand" )
	local rotation, translation, scale = transform.rotation or {}, transform.translation or {}, transform.scale or {}
	baseSize = math.max( tonumber( baseSize ) or 1, 0.001 )

	-- Minecraft item models use X/Y for the sprite and Z for its thickness.
	-- This basis makes the vanilla Y=-90 hand transform face back toward the camera.
	local leftHand = string.find( displayContext or "", "lefthand", 1, true ) ~= nil
	local explicitBasis = type( parentBasis ) == "table"
		and parentBasis.xAxis and parentBasis.yAxis and parentBasis.zAxis
	local xAxis = explicitBasis and parentBasis.xAxis:GetNormalized() or baseAng:Forward()
	local yAxis = explicitBasis and parentBasis.yAxis:GetNormalized() or baseAng:Up()
	local zAxis = explicitBasis and parentBasis.zAxis:GetNormalized()
		or ( leftHand and baseAng:Right() or -baseAng:Right() )
	local pos = basePos
		+ xAxis * ( ( tonumber( translation[1] ) or 0 ) * baseSize / 16 )
		+ yAxis * ( ( tonumber( translation[2] ) or 0 ) * baseSize / 16 )
		+ zAxis * ( ( tonumber( translation[3] ) or 0 ) * baseSize / 16 )
	xAxis, yAxis, zAxis = rotateBasis( xAxis, yAxis, zAxis, rotation )
	if not explicitBasis and string.find( displayContext or "", "firstperson_", 1, true ) == 1 then
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

local function mcWeaponsFirstPersonTransform( plan, displayContext, basePos, baseAng, baseSize, _view )
	local display = displayValues( plan, displayContext )
	local rotation, translation, scale = display.rotation or {}, display.translation or {}, display.scale or {}
	-- ItemInHandRenderer first applies its arm pose, then ItemTransform.apply()
	-- performs T(translation) * rotationXYZ * scale * T(-0.5). basePos/baseAng
	-- are that exact parent pose. Minecraft camera-space X/Y/Z map to Source
	-- Right/Up/-Forward; displayValues() has already applied the left-hand fix.
	local baseXAxis, baseYAxis, baseZAxis = baseAng:Right(), baseAng:Up(), -baseAng:Forward()
	local pos = basePos
		+ baseXAxis * ( ( tonumber( translation[1] ) or 0 ) * baseSize / 16 )
		+ baseYAxis * ( ( tonumber( translation[2] ) or 0 ) * baseSize / 16 )
		+ baseZAxis * ( ( tonumber( translation[3] ) or 0 ) * baseSize / 16 )
	local xAxis, yAxis, zAxis = rotateBasis( baseXAxis, baseYAxis, baseZAxis, rotation )
	return {
		pos = pos,
		xAxis = xAxis,
		yAxis = yAxis,
		normal = zAxis,
		width = baseSize * math.abs( tonumber( scale[1] ) or 0.68 ),
		height = baseSize * math.abs( tonumber( scale[2] ) or tonumber( scale[1] ) or 0.68 ),
		depthScale = math.abs( tonumber( scale[3] ) or 0.68 ),
		depth = baseSize * math.abs( tonumber( scale[3] ) or 0.68 ),
	}
end

function Renderer.SpecialWorldTransform( plan, displayContext, basePos, baseAng, baseSize, options, fallbackDisplay )
	if not plan or not basePos or not baseAng then return nil end
	local transformPlan = plan
	if type( fallbackDisplay ) == "table" then
		local merged = {}
		for key, value in pairs( fallbackDisplay ) do merged[key] = value end
		for key, value in pairs( type( plan.display ) == "table" and plan.display or {} ) do merged[key] = value end
		transformPlan = {
			display = merged,
			modelId = plan.modelId,
			kind = plan.kind,
			special = plan.special,
		}
	end
	options = options or {}
	if type( options.mcWeaponsView ) == "table"
	and string.find( displayContext or "", "firstperson_", 1, true ) == 1 then
		return mcWeaponsFirstPersonTransform( transformPlan, displayContext,
			basePos, baseAng, baseSize, options.mcWeaponsView )
	end
	return Renderer.HeldTransform( transformPlan, displayContext, basePos, baseAng, baseSize,
		options.parentBasis )
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

local spriteDrawPosition = Vector( 0, 0, 0 )
local spriteDrawForward = Vector( 0, 0, 0 )
local spriteDrawRight = Vector( 0, 0, 0 )
local spriteDrawUp = Vector( 0, 0, 0 )

local function drawExtrudedHeldLayer( layer, material, transform, layerOffset, color )
	local spriteMesh = heldSpriteMesh( layer, material )
	if not spriteMesh then return false end
	local matrix = heldSpriteDrawMatrix
	local pos, x, y, n = transform.pos, transform.xAxis, transform.yAxis, transform.normal
	spriteDrawPosition.x, spriteDrawPosition.y, spriteDrawPosition.z =
		pos.x + n.x * layerOffset, pos.y + n.y * layerOffset, pos.z + n.z * layerOffset
	spriteDrawForward.x, spriteDrawForward.y, spriteDrawForward.z =
		x.x * transform.width, x.y * transform.width, x.z * transform.width
	matrix:SetTranslation( spriteDrawPosition )
	matrix:SetForward( spriteDrawForward )
	-- Source matrices expose a world-space Right vector, but their local +Y
	-- column is Left. Negate here so the sprite's local +Y remains Minecraft up.
	spriteDrawRight.x, spriteDrawRight.y, spriteDrawRight.z =
		-y.x * transform.height, -y.y * transform.height, -y.z * transform.height
	spriteDrawUp.x, spriteDrawUp.y, spriteDrawUp.z =
		n.x * transform.depth, n.y * transform.depth, n.z * transform.depth
	matrix:SetRight( spriteDrawRight )
	matrix:SetUp( spriteDrawUp )
	local previousColor = bindItemMeshColor( material, color )
	render.SetBlend( ( color.a or 255 ) / 255 )
	render.SetMaterial( material )
	if render.CullMode then
		local determinant = ( x.y * y.z - x.z * y.y ) * n.x
			+ ( x.z * y.x - x.x * y.z ) * n.y + ( x.x * y.y - x.y * y.x ) * n.z
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
	material:SetVector( "$color2", previousColor or itemMeshWhite )
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

local function drawHeldLayers( materials, stack, plan, transform, color )
	for index = 1, #materials do
		local material = materials[index]
		local layer = plan.layers and plan.layers[index] or nil
		local offset = ( index - 1 ) * 0.01 * transform.depthScale
		local layerColor = Renderer.LayerColor( stack, plan, index, color )
		if not drawExtrudedHeldLayer( layer, material, transform, offset, layerColor ) then
			drawFlatHeldLayer( material, transform, offset, layerColor )
		end
	end
end

local groundOrientation = Angle( 0, 0, 0 )

-- A drop owns this prepared context until its network stack or model changes.
-- Resolve materials/JSON transforms once, rather than once per stack copy.
function Renderer.PrepareDroppedItem( stack, options )
	local materials, plan = Renderer.MaterialsForStack( stack, options )
	local stateId, blockId = droppedBlockState( stack, options, plan )
	local prepared = {
		stack = stack, options = options, materials = materials, plan = plan,
		stateId = stateId, blockId = blockId, foil = hasFoil( stack ),
	}
	if plan.kind ~= "special" and #materials > 0 then
		prepared.unitTransform = Renderer.HeldTransform( plan, "ground", vector_origin, groundOrientation, 1 )
		prepared.transform = {
			pos = Vector( 0, 0, 0 ), xAxis = Vector( 0, 0, 0 ),
			yAxis = Vector( 0, 0, 0 ), normal = Vector( 0, 0, 0 ),
		}
	end
	prepared.drawLayers = function()
		drawHeldLayers( materials, stack, plan, prepared.transform, prepared.color )
	end
	return prepared
end

local function rotateDropAxis( output, input, c, s )
	output.x, output.y, output.z = input.x * c - input.y * s, input.x * s + input.y * c, input.z
end

local function droppedHeldTransform( prepared, pos, orientation, size )
	local unit, transform = prepared.unitTransform, prepared.transform
	if not unit or orientation.p ~= 0 or orientation.r ~= 0 then return nil end
	if prepared.yaw ~= orientation.y then
		prepared.yaw = orientation.y
		local radians = orientation.y * math.pi / 180
		prepared.cosYaw, prepared.sinYaw = math.cos( radians ), math.sin( radians )
	end
	local c, s = prepared.cosYaw, prepared.sinYaw
	local offset = unit.pos
	transform.pos.x, transform.pos.y, transform.pos.z =
		pos.x + ( offset.x * c - offset.y * s ) * size,
		pos.y + ( offset.x * s + offset.y * c ) * size, pos.z + offset.z * size
	rotateDropAxis( transform.xAxis, unit.xAxis, c, s )
	rotateDropAxis( transform.yAxis, unit.yAxis, c, s )
	rotateDropAxis( transform.normal, unit.normal, c, s )
	transform.width, transform.height, transform.depth = unit.width * size, unit.height * size, unit.depth * size
	transform.depthScale = unit.depthScale
	return transform
end

function Renderer.DrawHeldItem( stack, pos, orientation, size, color, options, prepared )
	if not Renderer.CanDraw( stack ) or not pos or not orientation then return false end
	options = options or {}
	if prepared and ( prepared.stack ~= stack or prepared.options ~= options ) then prepared = nil end
	local modelOptions, materials, plan
	if prepared then
		modelOptions, materials, plan = options, prepared.materials, prepared.plan
	else
		modelOptions = {}
		for key, value in pairs( options ) do modelOptions[key] = value end
		modelOptions.displayContext = modelOptions.displayContext or "firstperson_righthand"
		modelOptions.worldItem = true
		materials, plan = Renderer.MaterialsForStack( stack, modelOptions )
	end
	color = color or color_white
	if plan.kind == "special"
	and drawSpecialWorld( stack, plan, pos, orientation, size, color, modelOptions ) then
		return true
	end
	if #materials == 0 then return false end
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
					local glintScaleU, glintScaleV, glintOriginU, glintOriginV =
						itemGlintTransform( layer )
					local matrix = heldSpriteDrawMatrix
					matrix:SetTranslation( pos + offset )
					matrix:SetForward( x * size )
					matrix:SetRight( -y * size )
					matrix:SetUp( normal * math.max( size * 0.02, 0.001 ) )
					cam.PushModelMatrix( matrix, true )
						drawDynamicGlintTriangles( geometry,
							glintScaleU, glintScaleV, glintOriginU, glintOriginV )
					cam.PopModelMatrix()
				end
			end
			endGlintBlend( blended )
		end
		return true
	end
	local baseAng
	if isangle and isangle( orientation ) then
		baseAng = orientation
	end
	if not baseAng then return false end
	local transform
	if prepared then transform = droppedHeldTransform( prepared, pos, baseAng, size ) end
	if not transform and type( modelOptions.mcWeaponsView ) == "table" then
		transform = mcWeaponsFirstPersonTransform( plan, modelOptions.displayContext, pos, baseAng, size,
			modelOptions.mcWeaponsView )
	elseif not transform then
		transform = Renderer.HeldTransform( plan, modelOptions.displayContext, pos, baseAng, size,
			modelOptions.parentBasis )
	end
	if not transform then return false end
	if prepared then
		prepared.transform, prepared.color = transform, color
		UI.WithPointFiltering( prepared.drawLayers )
	else
		UI.WithPointFiltering( function() drawHeldLayers( materials, stack, plan, transform, color ) end )
	end
	local foil
	if prepared then foil = prepared.foil else foil = hasFoil( stack ) end
	if foil and GLINT_MATERIAL and not ( GLINT_MATERIAL.IsError and GLINT_MATERIAL:IsError() ) then
		local blended = beginGlintBlend()
		if render.CullMode then render.CullMode( droppedBlockCullMode() ) end
		render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
		render.SetBlend( 1 )
		for index = 1, #materials do
			local layer = plan.layers and plan.layers[index] or nil
			local offset = ( index - 1 ) * 0.01 * transform.depthScale + 0.001
			local geometry = glintGeometryForLayer( layer )
			if geometry then
				local glintScaleU, glintScaleV, glintOriginU, glintOriginV =
					itemGlintTransform( layer )
				local matrix = heldSpriteDrawMatrix
				matrix:SetTranslation( transform.pos + transform.normal * offset )
				matrix:SetForward( transform.xAxis * transform.width )
				matrix:SetRight( -transform.yAxis * transform.height )
				matrix:SetUp( transform.normal * transform.depth )
				render.SetColorModulation( GLINT_STRENGTH, GLINT_STRENGTH, GLINT_STRENGTH )
				render.SetBlend( 1 )
				cam.PushModelMatrix( matrix, true )
					drawDynamicGlintTriangles( geometry,
						glintScaleU, glintScaleV, glintOriginU, glintOriginV )
				cam.PopModelMatrix()
			end
		end
		endGlintBlend( blended )
		if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
	end
	return true
end
