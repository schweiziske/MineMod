-- One real built-in consumer intentionally uses the complete public
-- registration path.  Besides the block itself, the game inventory needs a
-- real BlockItem and the neutral creative registry needs an explicit category
-- entry; the legacy block.creativeCategory field is only meaningful to the
-- engine-only fallback UI.

MC = MC or {}

local BLOCK_ID = "mcswep:oak_slope"
local CATEGORY_ID = "mcswep:slopes"

local function canonicalBlockName( block )
	if type( block ) ~= "table" then return nil end
	local value = block.mcid or block.name
	if MC.NormalizeResourceLocation then
		return MC.NormalizeResourceLocation( value )
	end
	return type( value ) == "string" and value or nil
end

local function slopeDisplayName( block, language )
	if MC.BlockDisplayName then
		return MC.BlockDisplayName( block, block and ( block.dispZH or block.disp or block.name ), language )
	end
	return block and ( block.dispZH or block.disp or block.name ) or ""
end

-- The generated MCSWEP slope catalog is an engine-owned block list, not a
-- second hand-maintained item list.  Build the public category from the live
-- records so every generated slope (including future generated variants) gets
-- the same-name BlockItem and neutral CreativeModeTab entry automatically.
local function listMCSwepSlopes()
	local records, seen = {}, {}
	local ids = {}
	for _, id in ipairs( MC.BlockList or {} ) do ids[#ids + 1] = id end
	if #ids == 0 and type( MC.Blocks ) == "table" then
		for id in pairs( MC.Blocks ) do ids[#ids + 1] = id end
	end
	for _, id in ipairs( ids ) do
		local block = MC.Blocks and MC.Blocks[id] or nil
		local canonical = canonicalBlockName( block )
		local path = canonical and string.match( canonical, "^mcswep:(.+)$" ) or nil
		if path and ( block.creativeCategory == "slopes" or string.match( path, "_slope$" ) )
		and not seen[canonical] then
			seen[canonical] = true
			records[#records + 1] = { name = canonical, block = block, runtimeId = id }
		end
	end
	-- The migrated consumer is registered through the public API just above. In
	-- a minimal/late test harness BlockList may not have been rebuilt yet, but it
	-- still belongs to the complete slope category.
	if not seen[BLOCK_ID] then
		local resolved = MC.ResolveBlock and MC.ResolveBlock( BLOCK_ID ) or nil
		records[#records + 1] = {
			name = BLOCK_ID,
			block = resolved and resolved.block or nil,
			runtimeId = resolved and resolved.id or nil,
		}
	end
	table.sort( records, function( left, right ) return left.name < right.name end )
	return records
end

local function migrationFailed( stage, reason )
	local message = "[MC] built-in oak slope " .. tostring( stage )
		.. " registration failed: " .. tostring( reason ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
	MC.MigratedBuiltinOakSlopeRegistrationError = {
		stage = tostring( stage ),
		reason = tostring( reason ),
	}
	return false
end

local function registerBuiltinOakSlope()
	local api = MC.API
	local definition = MC.MigratedBuiltinOakSlopeDefinition
	if not api or not api.Blocks or not definition then return end

	local blockOK, block = api.Blocks.RegisterNamespaced( definition )
	if not blockOK then return migrationFailed( "block", block ) end
	MC.MigratedBuiltinOakSlopeRegistration = block

	if not api.Items or not api.Items.Register then return migrationFailed( "BlockItem", "item_api_unavailable" ) end
	local itemOK, item = api.Items.Register( {
		id = BLOCK_ID,
		block = BLOCK_ID,
		maxStack = 64,
		kind = "block",
		displayName = "Custom Oak Slope",
		displayNameZH = "自定义橡木斜坡",
		source = "mcswep",
	} )
	if not itemOK then return migrationFailed( "BlockItem", item or "item_api_unavailable" ) end
	MC.MigratedBuiltinOakSlopeItemRegistration = item

	if not api.Creative or not api.Creative.RegisterCategory or not api.Creative.RegisterBlock then
		return migrationFailed( "creative category", "creative_api_unavailable" )
	end
	-- No row/column/page here: the slot is the registry's to assign, and this
	-- built-in consumer is bound by the same rule as any third-party addon.
	-- It registers during the engine include chain, so it lands on the first
	-- allocated slot.
	local categoryOK, category = api.Creative.RegisterCategory( {
			id = CATEGORY_ID,
			title = "Slopes",
			titleZH = "斜坡",
			icon = BLOCK_ID,
			background = "items",
			showTitle = true,
			canScroll = true,
		} )
	if not categoryOK then
		return migrationFailed( "creative category", category or "creative_api_unavailable" )
	end

	local entryOK, entryError = api.Creative.RegisterBlock( CATEGORY_ID, BLOCK_ID )
	if not entryOK then return migrationFailed( "creative entry", entryError ) end
	MC.MigratedBuiltinOakSlopeCreativeRegistration = {
		category = category,
		block = BLOCK_ID,
	}

	if not api.Items.Register then return migrationFailed( "slope catalog", "item_api_unavailable" ) end
	local slopeRecords = listMCSwepSlopes()
	local registeredNames = {}
	for _, record in ipairs( slopeRecords ) do
		if record.name ~= BLOCK_ID then
			local block = record.block
			local itemOK, item = api.Items.Register( {
				id = record.name,
				block = record.name,
				maxStack = 64,
				kind = "block",
				displayName = slopeDisplayName( block, "en_us" ),
				displayNameZH = slopeDisplayName( block, "zh_cn" ),
				source = "mcswep",
			} )
			if not itemOK then
				return migrationFailed( "slope BlockItem " .. record.name, item or "item_api_unavailable" )
			end
			local entryOK, entryError = api.Creative.RegisterBlock( CATEGORY_ID, record.name )
			if not entryOK then
				return migrationFailed( "slope creative entry " .. record.name, entryError )
			end
		end
		registeredNames[#registeredNames + 1] = record.name
	end
	MC.MigratedBuiltinSlopeRegistrationNames = registeredNames
	MC.MigratedBuiltinSlopeRegistrationCount = #registeredNames
	return true
end

registerBuiltinOakSlope()
MC.MigratedBuiltinOakSlopeDefinition = nil
