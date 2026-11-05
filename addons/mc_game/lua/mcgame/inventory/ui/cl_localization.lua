local UI = MC.InventoryUI
local errorPanels = setmetatable( {}, { __mode = "k" } )

local function refreshError( panel )
	if panel.ErrorKey then
		panel.ErrorText = MC.T( panel.ErrorKey, panel.ErrorVars )
	end
end

-- Error codes remain diagnostic data; unknown codes still get a readable message.
function UI.SetError( panel, code, duration, key )
	code = tostring( code or "inventory_action_rejected" )
	local candidate = "inventory.error." .. code
	if not key then
		key = MC.I18n.Has( candidate, "en_us" ) and candidate or "inventory.error.action_failed"
	end
	panel.ErrorKey = key
	panel.ErrorVars = { code = code }
	panel.ErrorUntil = RealTime() + ( duration or 2.5 )
	errorPanels[panel] = true
	refreshError( panel )
end

MC.RegisterLanguageChanged( "mc_inventory_text", function()
	for panel in pairs( errorPanels ) do
		if IsValid( panel ) then refreshError( panel ) else errorPanels[panel] = nil end
	end
	local screen = UI.Screen
	if not IsValid( screen ) then return end
	if screen.Creative then screen:RefreshCreativeItems() screen:LayoutVisibleSlots() end
	if IsValid( screen.RecipeBook ) then
		screen.RecipeBook.SearchEntry:SetPlaceholderText( MC.T( "recipe_book.search" ) )
		screen.RecipeBook:RefreshEntries( true )
	end
end )
