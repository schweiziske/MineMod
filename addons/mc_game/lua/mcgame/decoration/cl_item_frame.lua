-- ItemFrameRenderer, including the four block-model JSON variants.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local function F( u0, v0, u1, v1, texture )
	return { uv = { u0, v0, u1, v1 }, texture = texture }
end

-- These tables are a literal transcription of template_item_frame.json and
-- template_item_frame_map.json.  The texture names are the resolved parents
-- from item_frame.json/glow_item_frame.json.
local ORDINARY = {
	{ { 3, 3, 15.5 }, { 13, 13, 16 }, {
		north = F( 3, 3, 13, 13, "back" ), south = F( 3, 3, 13, 13, "back" ),
	} },
	{ { 2, 2, 15 }, { 14, 3, 16 }, {
		down = F( 2, 0, 14, 1, "wood" ), up = F( 2, 15, 14, 16, "wood" ),
		north = F( 2, 13, 14, 14, "wood" ), south = F( 2, 13, 14, 14, "wood" ),
		west = F( 15, 13, 16, 14, "wood" ), east = F( 0, 13, 1, 14, "wood" ),
	} },
	{ { 2, 13, 15 }, { 14, 14, 16 }, {
		down = F( 2, 0, 14, 1, "wood" ), up = F( 2, 15, 14, 16, "wood" ),
		north = F( 2, 2, 14, 3, "wood" ), south = F( 2, 2, 14, 3, "wood" ),
		west = F( 15, 2, 16, 3, "wood" ), east = F( 0, 2, 1, 3, "wood" ),
	} },
	{ { 2, 3, 15 }, { 3, 13, 16 }, {
		north = F( 13, 3, 14, 13, "wood" ), south = F( 2, 3, 3, 13, "wood" ),
		west = F( 15, 3, 16, 13, "wood" ), east = F( 0, 3, 1, 13, "wood" ),
	} },
	{ { 13, 3, 15 }, { 14, 13, 16 }, {
		north = F( 2, 3, 3, 13, "wood" ), south = F( 13, 3, 14, 13, "wood" ),
		west = F( 15, 3, 16, 13, "wood" ), east = F( 0, 3, 1, 13, "wood" ),
	} },
}

local MAP = {
	{ { 1, 1, 15.001 }, { 15, 15, 16 }, {
		north = F( 1, 1, 15, 15, "back" ), south = F( 1, 1, 15, 15, "back" ),
	} },
	{ { 0, 0, 15.001 }, { 16, 1, 16 }, {
		down = F( 0, 0, 16, 1, "wood" ), up = F( 0, 15, 16, 16, "wood" ),
		north = F( 0, 15, 16, 16, "wood" ), south = F( 0, 15, 16, 16, "wood" ),
		west = F( 15, 15, 16, 16, "wood" ), east = F( 0, 15, 1, 16, "wood" ),
	} },
	{ { 0, 15, 15.001 }, { 16, 16, 16 }, {
		down = F( 0, 0, 16, 1, "wood" ), up = F( 0, 15, 16, 16, "wood" ),
		north = F( 0, 0, 16, 1, "wood" ), south = F( 0, 0, 16, 1, "wood" ),
		west = F( 15, 0, 16, 1, "wood" ), east = F( 0, 0, 1, 1, "wood" ),
	} },
	{ { 0, 1, 15.001 }, { 1, 15, 16 }, {
		north = F( 15, 1, 16, 15, "wood" ), south = F( 0, 1, 1, 15, "wood" ),
		west = F( 15, 1, 16, 15, "wood" ), east = F( 0, 1, 1, 15, "wood" ),
	} },
	{ { 15, 1, 15.001 }, { 16, 15, 16 }, {
		north = F( 0, 1, 1, 15, "wood" ), south = F( 15, 1, 16, 15, "wood" ),
		west = F( 15, 1, 16, 15, "wood" ), east = F( 0, 1, 1, 15, "wood" ),
	} },
}

local function frameMaterials( ent )
	local glow = ent.IsGlowMinecraftFrame and ent:IsGlowMinecraftFrame() == true
	local backName = glow and "glow_item_frame" or "item_frame"
	return {
		wood = M.Material( "frame_wood", "mc/block/birch_planks.png" ),
		back = M.Material( "frame_back_" .. backName,
			"mc/block/" .. backName .. ".png" ),
	}
end

local function frameItem( ent )
	return ent.GetMinecraftFrameItem and ent:GetMinecraftFrameItem() or nil
end

local function frameLight( ent, position )
	local glow = ent.IsGlowMinecraftFrame and ent:IsGlowMinecraftFrame() == true
	local r, g, b = 1, 1, 1
	if D.SampleDecorationLight then r, g, b = D.SampleDecorationLight( position, glow ) end
	return Color( math.floor( math.Clamp( tonumber( r ) or 1, 0, 1 ) * 255 + 0.5 ),
		math.floor( math.Clamp( tonumber( g ) or r or 1, 0, 1 ) * 255 + 0.5 ),
		math.floor( math.Clamp( tonumber( b ) or r or 1, 0, 1 ) * 255 + 0.5 ), 255 )
end

local function angleFromBasis( forward, up )
	-- DrawHeldItem's Angle path uses Forward as sprite X and Up as sprite Y.
	local angle = forward:Angle()
	local referenceUp = angle:Up()
	local sine = referenceUp:Cross( up ):Dot( forward )
	local cosine = referenceUp:Dot( up )
	angle.r = math.deg( math.atan2( sine, cosine ) )
	return angle
end

local function mapProvider( ent, stack )
	-- MapItemSavedData is intentionally an engine capability.  Unknown means
	-- no pixels/decorations, never fabricated map data.
	if MC.RunEvent then
		local result = MC.RunEvent( "MC.DecorationMapRenderData", ent, stack )
		if type( result ) == "table" then return result, "provider" end
	end
	return nil, "capability_missing"
end

local function decorationMaterial( value )
	if type( value ) ~= "string" then
		return value and not ( value.IsError and value:IsError() ) and value or nil
	end
	local suffix = util and util.CRC and util.CRC( value )
		or ( string.gsub( value, "[^%w_]", "_" ) ):sub( 1, 48 )
	return M.Material( "map_decoration_" .. suffix, value,
		"smooth noclamp vertexcolor vertexalpha translucent nocull" )
end

local function drawMapDecorations( mapCenter, xAxis, yAxis, normal, data )
	if type( data ) ~= "table" or type( data.decorations ) ~= "table" then return 0, 0 end
	local visible, named = 0, 0
	for _, decoration in ipairs( data.decorations ) do
		if D.DecorationMapVisibleOnFrame( decoration ) then
			visible = visible + 1
			local transform = D.DecorationMapDecorationTransform( decoration, visible )
			local rx, ry = M.RotateAxes( xAxis, yAxis, normal, transform.rotation )
			local p = mapCenter + xAxis * ( transform.x * M.BlockSize() )
				+ yAxis * ( transform.y * M.BlockSize() )
				+ rx * ( transform.shiftX * M.BlockSize() )
				+ ry * ( transform.shiftY * M.BlockSize() )
				+ normal * ( transform.outset * M.BlockSize() )
			local material = decorationMaterial( decoration.material )
			if material then
				M.Plane( p, rx, ry, transform.size * M.BlockSize(),
					transform.size * M.BlockSize(), material, color_white, decoration.uv )
			end
			local name = D.DecorationMapDecorationName( decoration )
			if name and R.ResolveDecorationMapNameMaterial then
				local nameMaterial, width = R.ResolveDecorationMapNameMaterial( name )
				if nameMaterial and width then
					local nameTransform = D.DecorationMapDecorationNameTransform( decoration, width )
					local namePosition = mapCenter
						+ xAxis * ( nameTransform.x * M.BlockSize() )
						+ yAxis * ( nameTransform.y * M.BlockSize() )
						+ normal * ( nameTransform.outset * M.BlockSize() )
					M.Plane( namePosition, xAxis, yAxis,
						nameTransform.width * M.BlockSize(), nameTransform.height * M.BlockSize(),
						nameMaterial, color_white )
					named = named + 1
				end
			end
		end
	end
	return visible, named
end

local function drawMap( center, xAxis, yAxis, normal, ent, stack, rotation, color )
	local mapCenter = center - normal * ( 0.4375 * M.BlockSize() )
	xAxis, yAxis = M.RotateAxes( xAxis, yAxis, normal, ( rotation % 4 ) * 90 + 180 )
	local data, status = mapProvider( ent, stack )
	local material, textureStatus, pixelCount, cacheKey, revision
	if data and R.ResolveDecorationMapMaterial then
		material, textureStatus, pixelCount, cacheKey, revision =
			R.ResolveDecorationMapMaterial( data, stack, ent )
	end
	local textureCenter = mapCenter + normal * ( D.DecorationMapTextureOutset() * M.BlockSize() )
	local drawn = false
	if material then
		drawn = M.Plane( textureCenter, xAxis, yAxis, M.BlockSize(), M.BlockSize(),
			material, color, data and data.uv ) == true
	else
		-- No saved-data capability: keep a conservative parchment surface. When
		-- real RGBA data exists its transparent pixels reveal the frame model,
		-- matching MapTextureManager rather than this fallback.
		local background = M.Material( "map_background", "mc/map/map_background.png" )
		drawn = background and M.Plane( textureCenter, xAxis, yAxis,
			M.BlockSize(), M.BlockSize(), background, color ) == true or false
		textureStatus = textureStatus or ( background and status or "background_missing" )
	end
	local decorationCount, namedDecorations = drawMapDecorations(
		mapCenter, xAxis, yAxis, normal, data )
	R.LastMapRenderStatus = {
		status = status, textureStatus = textureStatus, pixelCount = pixelCount or 0,
		cacheKey = cacheKey, revision = revision, decorationCount = decorationCount,
		namedDecorationCount = namedDecorations,
	}
	return drawn, textureStatus or status
end

function R.DrawItemFrame( ent )
	if not IsValid( ent ) then return false end
	local position = M.RenderPosition( ent )
	if not position then return false end
	local worldPosition = M.WorldPosition( ent ) or position
	local xAxis, yAxis, _, normal = M.Basis( M.Direction( ent ) )
	local bs = M.BlockSize()
	-- ItemFrameRenderer translates the entity centre by direction*0.46875 before
	-- submitting the block model.  The old renderer omitted this translation.
	local anchor = position + normal * ( 0.46875 * bs )
	local materials = frameMaterials( ent )
	local color = frameLight( ent, worldPosition )
	local map = ent.HasFramedMinecraftMap and ent:HasFramedMinecraftMap() == true
	local model = map and MAP or ORDINARY
	local drawn = false
	if not ( ent.GetDecorationInvisible and ent:GetDecorationInvisible() == true ) then
		for _, element in ipairs( model ) do
			drawn = M.Cuboid( anchor, xAxis, yAxis, normal,
				element[1], element[2], element[3], materials, color ) or drawn
		end
	end
	local item = frameItem( ent )
	if item then
		local rotation = ent.GetFrameRotation and ent:GetFrameRotation() or 0
		if map then
			local ok = drawMap( anchor, xAxis, yAxis, normal, ent, item, rotation, color )
			drawn = ok or drawn
		else
			local rx, ry = M.RotateAxes( xAxis, yAxis, normal, rotation * 45 )
			local itemCenter = anchor - normal *
				( ( ent.GetDecorationInvisible and ent:GetDecorationInvisible() ) and 0.5 or 0.4375 ) * bs
			local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
			if renderer and renderer.DrawHeldItem then
				drawn = renderer.DrawHeldItem( item, itemCenter, angleFromBasis( rx, ry ),
					bs * 0.5, color, { displayContext = "fixed", worldItem = true } ) or drawn
			end
		end
	end
	M.ResetState()
	return drawn
end
