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

local function blockStateFor( definition )
	if not definition or not definition.blockId or not MC.DefaultBlockState then return nil end
	return MC.DefaultBlockState( definition.blockId )
		or MC.DefaultBlockState( definition.blockName )
end

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
				if UI.DrawTexture( material, x, y, size, size ) then drawn = true end
			end
		end )
	elseif definition.blockId and MC.DrawMinecraftBlockStateIcon then
		local stateId = blockStateFor( definition )
		if stateId then
			UI.WithPointFiltering( function()
				drawn = MC.DrawMinecraftBlockStateIcon( stateId, x, y, size, size, options.forceModel == true ) == true
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
	UI.DrawText( text, x + size - scale, y + size - 9 * scale, scale, UI.Colors.text, TEXT_ALIGN_RIGHT, true )
end

local function drawDamage( stack, definition, x, y, size, scale )
	local maxDamage = tonumber( definition and definition.maxDamage ) or 0
	if maxDamage <= 0 then return end
	local damage = math.Clamp( tonumber( stack.damage ) or 0, 0, maxDamage )
	local remaining = 1 - damage / maxDamage
	local barWidth = math.max( 2, size - 2 * scale )
	local barHeight = math.max( 1, scale )
	local barX, barY = x + scale, y + size - 2 * scale
	draw.RoundedBox( 0, barX, barY, barWidth, barHeight, Color( 0, 0, 0, 255 ) )
	local red = math.floor( 255 * ( 1 - remaining ) )
	local green = math.floor( 255 * remaining )
	draw.RoundedBox( 0, barX, barY, math.max( 1, math.floor( barWidth * remaining ) ), barHeight, Color( red, green, 0, 255 ) )
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

function Renderer.DrawHeldItem( stack, pos, normal, size, color )
	if not Renderer.CanDraw( stack ) or not pos or not normal then return false end
	local materials = Renderer.MaterialsForStack( stack, { displayContext = "firstperson_righthand" } )
	if #materials == 0 then return false end
	color = color or Color( 255, 255, 255, 255 )
	for index, material in ipairs( materials ) do
		render.SetMaterial( material )
		local offset = normal * ( ( index - 1 ) * 0.002 )
		render.DrawQuadEasy( pos + offset, normal, size, size, color, 0 )
		render.DrawQuadEasy( pos - offset, -normal, size, size, color, 180 )
	end
	return true
end
