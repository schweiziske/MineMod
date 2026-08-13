-- Pixel tooltip renderer.  It is drawn by the owning inventory screen so it
-- stays above every child panel and remains inside the current resolution.

MC = MC or {}
MC.InventoryUI = MC.InventoryUI or {}

local UI = MC.InventoryUI
local Tooltip = {}
UI.Tooltip = Tooltip
local ENCHANTMENT_GRAY = Color( 170, 170, 170, 255 )
local CURSE_RED = Color( 255, 85, 85, 255 )

local function vanillaItemText( key, fallback )
	local catalog = MC.GeneratedInventoryText and MC.GeneratedInventoryText[key] or nil
	if type( catalog ) ~= "table" then return fallback end
	local language = MC.Language and MC.Language() or "en_us"
	return catalog[language] or catalog.en_us or fallback
end

local function formatVanillaText( template, ... )
	local ok, value = pcall( string.format, tostring( template or "" ), ... )
	return ok and value or tostring( template or "" )
end

local function componentValue( stack, key )
	local components = type( stack ) == "table" and stack.components or nil
	if type( components ) ~= "table" then return nil end
	if components[key] ~= nil then return components[key] end
	local namespaced = string.find( key, ":", 1, true ) and key or "minecraft:" .. key
	return components[namespaced]
end

local function tooltipVisible( stack, stored )
	local component = componentValue( stack, stored and "stored_enchantments" or "enchantments" )
	if type( component ) ~= "table" then return true end
	if component.show_in_tooltip ~= nil then return component.show_in_tooltip == true end
	if component.showInTooltip ~= nil then return component.showInTooltip == true end
	return true
end

local function enchantmentLines( stack )
	if not MC.GetItemEnchantments then return {} end
	local stored = stack.item == "minecraft:enchanted_book"
	if not tooltipVisible( stack, stored ) then return {} end
	local levels = MC.GetItemEnchantments( stack, stored )
	if type( levels ) ~= "table" or next( levels ) == nil then return {} end
	local ordered = MCITEM and MCITEM.OrderedEnchantmentIds
		and MCITEM.OrderedEnchantmentIds( levels ) or {}
	if #ordered == 0 then
		for id in pairs( levels ) do ordered[#ordered + 1] = id end
		table.sort( ordered )
	end
	local result = {}
	for _, id in ipairs( ordered ) do
		local level = tonumber( levels[id] ) or 0
		if level > 0 then
			local text = MCITEM and MCITEM.EnchantmentLevelName
				and MCITEM.EnchantmentLevelName( id, level ) or tostring( id ) .. " " .. tostring( level )
			local curse = MCITEM and MCITEM.IsCurseEnchantment and MCITEM.IsCurseEnchantment( id ) == true
			result[#result + 1] = { text = text, color = curse and CURSE_RED or ( UI.Colors.textDim or ENCHANTMENT_GRAY ) }
		end
	end
	return result
end

function Tooltip.LinesForStack( stack )
	if MC.IsEmptyItemStack( stack ) then return {} end
	local definition = MC.GetItem and MC.GetItem( stack.item ) or nil
	if not definition then return {} end
	local lines = {
		{ text = UI.ItemRenderer.DisplayName( stack ), color = UI.RarityColor( definition.rarity ) },
	}
	for _, line in ipairs( enchantmentLines( stack ) ) do lines[#lines + 1] = line end
	local maxDamage = tonumber( definition.maxDamage ) or 0
	if maxDamage > 0 then
		local damage = math.Clamp( math.floor( tonumber( stack.damage ) or 0 ), 0, maxDamage )
		lines[#lines + 1] = {
			text = formatVanillaText( vanillaItemText( "durability", "Durability: %s / %s" ), maxDamage - damage, maxDamage ),
			color = UI.Colors.text,
		}
	end
	return lines
end

function Tooltip.DrawLines( lines, mouseX, mouseY, scale )
	if type( lines ) ~= "table" or #lines == 0 then return end
	scale = math.max( 1, tonumber( scale ) or 1 )
	local padding, lineHeight = 4 * scale, 10 * scale
	local width = 0
	for _, line in ipairs( lines ) do width = math.max( width, UI.MeasureText( line.text, scale ) ) end
	local boxW, boxH = width + padding * 2, #lines * lineHeight + padding * 2 - 2 * scale
	local x, y = mouseX + 12 * scale, mouseY - 12 * scale
	if x + boxW > ScrW() - scale then x = mouseX - boxW - 12 * scale end
	if y + boxH > ScrH() - scale then y = ScrH() - boxH - scale end
	x, y = math.max( scale, x ), math.max( scale, y )

	draw.RoundedBox( 0, x, y, boxW, boxH, UI.Colors.tooltipBackground )
	surface.SetDrawColor( UI.Colors.tooltipBorder )
	surface.DrawRect( x - scale, y + scale, scale, boxH - 2 * scale )
	surface.DrawRect( x + boxW, y + scale, scale, boxH - 2 * scale )
	surface.DrawRect( x + scale, y - scale, boxW - 2 * scale, scale )
	surface.DrawRect( x + scale, y + boxH, boxW - 2 * scale, scale )
	surface.SetDrawColor( UI.Colors.tooltipBorderBright )
	surface.DrawRect( x, y, scale, boxH )
	surface.DrawRect( x + boxW - scale, y, scale, boxH )

	for index, line in ipairs( lines ) do
		UI.DrawText( line.text, x + padding, y + padding + ( index - 1 ) * lineHeight, scale, line.color or UI.Colors.text, TEXT_ALIGN_LEFT, true )
	end
end

function Tooltip.DrawStack( stack, mouseX, mouseY, scale )
	Tooltip.DrawLines( Tooltip.LinesForStack( stack ), mouseX, mouseY, scale )
end
