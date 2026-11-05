-- MCSWEP Mod Registry v1.x minimal example.
--
-- This file is documentation/sample code, not included by the MCSWEP loader.
-- Copy it into a third-party addon's shared autorun directory (and rename the
-- namespace) to register one block, one item, and one CreativeModeTab-shaped
-- category without editing MCSWEP.
--
-- Display text is not written here. Copy examples/data_static/ into the root of
-- the same addon as well: its JSON files under data_static/mc/i18n/ provide the
-- translation keys this file uses (see docs/localization.md).

local function registerExampleContent( context )
	local api = context and context.api or MC and MC.API
	if not api then return false, "api_unavailable" end

	local blockOK, block = api.Blocks.RegisterNamespaced( {
		id = "example:polished_basalt",
		textures = { top = "stone", side = "stone", bottom = "stone" },
		boxes = { { 0, 0, 0, 1, 1, 1 } },
		hardness = 1.5,
		explosionResistance = 6,
		creativeCategory = "example:building",
	} )
	if not blockOK then
		ErrorNoHalt( "[mod-api-example] block registration failed: " .. tostring( block ) .. "\n" )
		return
	end

	local itemOK, item = api.Items.Register( {
		id = "example:polished_basalt",
		block = "example:polished_basalt",
		maxStack = 64,
		-- This deliberately reuses a shipped material so the sample works
		-- without adding an asset to the MCSWEP addon.
		texture = "mc/item/apple",
		-- No name here either: a BlockItem shows its block's name,
		-- block.example.polished_basalt.
		kind = "block",
	} )
	if not itemOK then
		ErrorNoHalt( "[mod-api-example] item registration failed: " .. tostring( item ) .. "\n" )
		return
	end

	local lootOK, loot = api.BlockLoot.RegisterDefaultBlockItem( "example:polished_basalt" )
	if not lootOK then
		ErrorNoHalt( "[mod-api-example] block loot registration failed: " .. tostring( loot ) .. "\n" )
		return
	end

	-- The tab slot is assigned by the registry; a definition never picks its own
	-- page/row/column, so two addons shipped separately cannot collide.
	-- The tab title is the key itemGroup.example.building, derived from the id.
	local categoryOK, category = api.Creative.RegisterCategory( {
		id = "example:building",
		icon = "example:polished_basalt",
		showTitle = true,
		canScroll = true,
	} )
	if not categoryOK then
		ErrorNoHalt( "[mod-api-example] category registration failed: " .. tostring( category ) .. "\n" )
		return
	end

	local entryOK, entryError = api.Creative.RegisterBlock( "example:building", "example:polished_basalt" )
	if not entryOK then
		ErrorNoHalt( "[mod-api-example] category block entry failed: " .. tostring( entryError ) .. "\n" )
		return
	end
	-- The block entry resolves the same-name BlockItem registered above.  Do
	-- not also RegisterItem for the same stack: vanilla CreativeModeTab rejects
	-- duplicate type+component stacks when it builds a category.
	return true
end

local manifest = {
	id = "example",
	version = "1.0.0",
	depends = {
		mcswep = ">=1.0 <2.0",
	},
	environment = "*",
	entrypoints = {
		main = registerExampleContent,
	},
}

if MC and MC.API and MC.API.RegisterManifest then
	local ok, err = MC.API.RegisterManifest( manifest )
	if not ok then ErrorNoHalt( "[mod-api-example] manifest registration failed: " .. tostring( err ) .. "\n" ) end
else
	hook.Add( "MC.APIAvailable", "mod_api_example_manifest", function()
		if not MC.API.RegisterManifest then
			ErrorNoHalt( "[mod-api-example] MCSWEP manifest API is unavailable\n" )
			return
		end
		local ok, err = MC.API.RegisterManifest( manifest )
		if not ok then ErrorNoHalt( "[mod-api-example] manifest registration failed: " .. tostring( err ) .. "\n" ) end
	end )
end

local function reportExampleReady()
	if not MC or not MC.API then return end
	local block = MC.API.Blocks.Resolve( "example:polished_basalt" )
	local item = MC.API.Items.Resolve( "example:polished_basalt" )
	print( "[mod-api-example] ready", block and block.name, item and item.name )
end

if MC and MC.API and MC.API.OnReady then
	MC.API.OnReady( reportExampleReady )
else
	hook.Add( "MC.APIReady", "mod_api_example_ready", reportExampleReady )
end
