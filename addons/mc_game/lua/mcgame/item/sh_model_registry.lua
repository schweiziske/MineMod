--[[----------------------------------------------------------------------------
    Generated Minecraft item-model catalog.

    The JSON is generated from out/assets/minecraft at build time and shipped
    as bounded Lua string parts.  Only the client parses the catalog; the
    server keeps the generated hash so inventory handshakes can detect a
    client using a different resource set without carrying render data over
    net messages.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.ItemModelCatalog = MC.ItemModelCatalog or nil
MC.ItemModelFiles = MC.ItemModelFiles or {}
MC.ItemModelCatalogStats = MC.ItemModelCatalogStats or {
	items = 0,
	models = 0,
	parts = 0,
	bytes = 0,
	loaded = false,
}

local function modelIdentifier( value )
	if type( value ) ~= "string" then return nil end
	if #value < 1 or #value > 192 then return nil end
	if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
	if not string.match( value, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return string.lower( value )
end

local function finiteNumber( value )
	return type( value ) == "number" and value == value
		and value ~= math.huge and value ~= -math.huge
end

if CLIENT then
	local MAX_PARTS = 64
	local MAX_PART_BYTES = 96 * 1024
	local MAX_TOTAL_BYTES = 2 * 1024 * 1024
	local MAX_ITEMS = 4096
	local MAX_MODELS = 8192
	local MAX_NODE_DEPTH = 32
	local MAX_BRANCHES = 512
	local MAX_LAYERS = 8

	local function validScalar( value, depth )
		local valueType = type( value )
		if valueType == "nil" or valueType == "string" or valueType == "boolean" then
			return valueType ~= "string" or #value <= 192
		end
		if valueType == "number" then return finiteNumber( value ) end
		if valueType ~= "table" or depth >= MAX_NODE_DEPTH then return false end
		local count = 0
		for key, item in pairs( value ) do
			count = count + 1
			if count > MAX_BRANCHES then return false end
			if type( key ) ~= "number" and type( key ) ~= "string" then return false end
			if not validScalar( item, depth + 1 ) then return false end
		end
		return true
	end

	local function validNode( node, depth )
		if type( node ) ~= "table" or depth > MAX_NODE_DEPTH then return false end
		local nodeType = node.t
		if nodeType == "missing" or nodeType == "unknown" then return true end
		if nodeType == "model" then return modelIdentifier( node.m ) ~= nil end
		if nodeType == "condition" then
			return type( node.p ) == "string" and #node.p <= 192
				and validNode( node.y, depth + 1 ) and validNode( node.n, depth + 1 )
		end
		if nodeType == "range" then
			if type( node.p ) ~= "string" or #node.p > 192 or not finiteNumber( node.s or 1 ) then return false end
			if type( node.e ) ~= "table" or #node.e > MAX_BRANCHES then return false end
			for _, entry in ipairs( node.e ) do
				if type( entry ) ~= "table" or not finiteNumber( entry.v ) or not validNode( entry.n, depth + 1 ) then return false end
			end
			return validNode( node.f, depth + 1 )
		end
		if nodeType == "select" then
			if type( node.p ) ~= "string" or #node.p > 192 or type( node.c ) ~= "table" or #node.c > MAX_BRANCHES then return false end
			for _, case in ipairs( node.c ) do
				if type( case ) ~= "table" or not validScalar( case.w, depth + 1 ) or not validNode( case.n, depth + 1 ) then return false end
			end
			return validNode( node.f, depth + 1 )
		end
		if nodeType == "composite" then
			if type( node.n ) ~= "table" or #node.n > MAX_LAYERS then return false end
			for _, child in ipairs( node.n ) do if not validNode( child, depth + 1 ) then return false end end
			return true
		end
		if nodeType == "special" then
			return ( node.b == nil or modelIdentifier( node.b ) ~= nil ) and validScalar( node.m, depth + 1 )
		end
		return false
	end

	local function entryCount( value )
		local count = 0
		for _ in pairs( value or {} ) do count = count + 1 end
		return count
	end

	function MC.LoadGeneratedItemModelPayload( parts )
		if type( parts ) ~= "table" then return false, "invalid_item_model_parts" end
		local partCount = #parts
		if partCount < 1 or partCount > MAX_PARTS then return false, "invalid_item_model_part_count" end
		local totalBytes, entries = 0, {}
		for index = 1, partCount do
			local encoded = parts[index]
			if type( encoded ) ~= "string" or #encoded < 2 or #encoded > MAX_PART_BYTES then
				return false, "invalid_item_model_part"
			end
			totalBytes = totalBytes + #encoded
			if totalBytes > MAX_TOTAL_BYTES then return false, "item_model_catalog_too_large" end
			local decoded = util and util.JSONToTable and util.JSONToTable( encoded ) or nil
			if type( decoded ) ~= "table" then return false, "item_model_part_json_invalid" end
			for _, entry in ipairs( decoded ) do
				if type( entry ) ~= "table" then return false, "invalid_item_model_entry" end
				entries[#entries + 1] = entry
			end
		end

		local items, models = {}, {}
		for _, entry in ipairs( entries ) do
			if entry.i ~= nil then
				local itemId = modelIdentifier( entry.i )
				if not itemId or items[itemId] then return false, "duplicate_item_model_item" end
				local data = entry.d
				if type( data ) ~= "table" or not validNode( data.root, 0 ) then return false, "invalid_item_model_root" end
				items[itemId] = { root = data.root }
			elseif entry.m ~= nil then
				local modelId = modelIdentifier( entry.m )
				if not modelId or models[modelId] then return false, "duplicate_item_model_file" end
				local data = entry.d
				if type( data ) ~= "table" or type( data.layers ) ~= "table" or #data.layers > MAX_LAYERS
				or ( data.kind ~= "flat" and data.kind ~= "block" and data.kind ~= "special" and data.kind ~= "missing" and data.kind ~= "cycle" ) then
					return false, "invalid_item_model_file"
				end
				for _, layer in ipairs( data.layers ) do
					if layer ~= nil and ( type( layer ) ~= "string" or #layer > 192 ) then return false, "invalid_item_model_layer" end
				end
				models[modelId] = data
			else
				return false, "unknown_item_model_entry"
			end
		end
		if entryCount( items ) > MAX_ITEMS or entryCount( models ) > MAX_MODELS then return false, "item_model_catalog_limits" end

		MC.ItemModelFiles = models
		MC.ItemModelCatalog = {
			version = MC.GeneratedItemModelSourceVersion,
			items = items,
			models = models,
			hash = tostring( MC.ItemModelRegistryHash or "" ),
		}
		MC.ItemModelCatalogStats = {
			items = entryCount( items ),
			models = entryCount( models ),
			parts = partCount,
			bytes = totalBytes,
			loaded = true,
		}
		return true
	end
else
	-- Shared callers can still ask for a model file and receive nil on the
	-- server.  Render payloads are intentionally never parsed there.
	function MC.LoadGeneratedItemModelPayload()
		return false, "client_only_item_model_catalog"
	end
end

function MC.GetItemModelDefinition( item )
	if not CLIENT or not MC.ItemModelCatalog then return nil end
	local definition = type( item ) == "table" and item or ( MC.GetItem and MC.GetItem( item ) )
	local name = definition and definition.name or modelIdentifier( item )
	if not name then return nil end
	local record = MC.ItemModelCatalog.items[name]
	if record and record.root then return record.root end
	if definition and definition.model then return { t = "model", m = modelIdentifier( definition.model ) } end
	return nil
end

function MC.GetItemModelFile( modelId )
	if not CLIENT or not MC.ItemModelFiles then return nil end
	modelId = modelIdentifier( modelId )
	return modelId and MC.ItemModelFiles[modelId] or nil
end

function MC.GetItemModelCatalogStats()
	local stats = MC.ItemModelCatalogStats or {}
	return {
		items = tonumber( stats.items ) or 0,
		models = tonumber( stats.models ) or 0,
		parts = tonumber( stats.parts ) or 0,
		bytes = tonumber( stats.bytes ) or 0,
		loaded = stats.loaded == true,
		hash = tostring( MC.ItemModelRegistryHash or "" ),
	}
end

