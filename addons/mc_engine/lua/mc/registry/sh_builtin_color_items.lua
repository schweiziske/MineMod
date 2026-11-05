-- Expose the generated colour palette through the same public item/category
-- contracts as third-party blocks. Texture ids stay owned by the block atlas.
local API = MC.API
local CATEGORY = "mcswep:color_blocks"
local registrationError

local function accept( ok, result, stage )
	if ok then return true end
	registrationError = stage .. ":" .. tostring( result )
	return MC.Fault( "builtin_color_registration", "%s", registrationError )
end

local function registerColors()
	local colors = {}
	for _, id in ipairs( MC.BlockList ) do
		local block = MC.Blocks[id]
		if block.creativeCategory == "color_blocks" and string.StartWith( block.mcid, "mcswep:" ) then
			colors[#colors + 1] = block
		end
	end
	table.sort( colors, function( left, right ) return left.id < right.id end )
	if not accept( #colors > 0, "empty_palette", "catalog" ) then return end

	local ok, result = API.Creative.RegisterCategory( {
		id = CATEGORY,
		icon = colors[1].mcid,
		background = "items",
		showTitle = true,
		canScroll = true,
	} )
	if not accept( ok, result, "category" ) then return end
	for _, block in ipairs( colors ) do
		-- Explicit block-model identity sends GUI, held and dropped forms through
		-- the existing block-state mesh renderer and its runtime atlas bindings.
		-- No separate item PNG, material or pre-baked VTF is needed. The
		-- BlockItem takes its name from the colour block.
		ok, result = API.Items.Register( {
			id = block.mcid,
			block = block.mcid,
			model = "mcswep:block/" .. block.name,
			maxStack = 64,
			kind = "block",
			source = "mcswep",
		} )
		if not accept( ok, result, "item:" .. block.mcid ) then return end
		ok, result = API.Creative.RegisterBlock( CATEGORY, block.mcid )
		if not accept( ok, result, "creative:" .. block.mcid ) then return end
		ok, result = API.BlockLoot.RegisterDefaultBlockItem( block.mcid, block.mcid )
		if not accept( ok, result, "loot:" .. block.mcid ) then return end
	end
end

registerColors()
local ok, err = API._RegisterFreezeCallback( "mc.builtin.color_items", function()
	return registrationError == nil, registrationError
end )
MC.Check( ok, "builtin_color_freeze_callback", "%s", tostring( err ) )
