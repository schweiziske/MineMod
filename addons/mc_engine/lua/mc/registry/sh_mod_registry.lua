--[[----------------------------------------------------------------------------
    MC mod registry primitives (engine layer).

    This is the small Lua equivalent of Minecraft's Identifier/ResourceKey and
    MappedRegistry pieces.  It deliberately knows nothing about game stacks,
    inventory, or mc_game.  The game layer consumes the neutral item/category
    contracts through MC.API.

    Numeric ids are process-local implementation details.  The Mod Registry
    v1.x entry uses canonical namespace:path strings; the older Blocks.Register
    facade remains a compatibility overload outside this module. Save code can
    ask BuildModRegistrySnapshot for the string<->runtime mapping metadata.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}

local function isTable( value ) return type( value ) == "table" end
local function isString( value ) return type( value ) == "string" end
local function isFunction( value ) return type( value ) == "function" end

local function finiteInteger( value, minimum )
	value = tonumber( value )
	if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
	if value ~= math.floor( value ) or ( minimum ~= nil and value < minimum ) then return nil end
	return value
end

local function trim( value )
	value = tostring( value or "" )
	return string.match( value, "^%s*(.-)%s*$" ) or ""
end

local function validNamespace( namespace )
	if namespace == ".." then return false end
	-- Identifier.isValidNamespace in the reference implementation accepts the
	-- empty string (the separator parser replaces an empty namespace with
	-- minecraft before it reaches a public key). Keep the low-level parser
	-- faithful; content registries apply the non-empty-path rule separately.
	return string.match( namespace, "^[a-z0-9_.%-]*$" ) ~= nil
end

local function validPath( path )
	-- The decompiled Identifier.isValidPath loop returns true for an empty
	-- string. This matters for API.Identifiers.Normalize (which mirrors the
	-- primitive exactly), even though a registrable block/item/category below
	-- must have a non-empty path.
	return string.match( path, "^[a-z0-9_%.%/%-]*$" ) ~= nil
end

-- Identifier.bySeparator semantics from the decompiled Minecraft source:
-- no namespace and an empty namespace both use minecraft; only the first colon
-- is structural, so a second colon remains in the path and is rejected.
function MC.NormalizeResourceLocation( value )
	if not isString( value ) then return nil, "invalid_identifier" end
	-- Identifier.parse does not trim or case-fold.  Keeping that behavior is
	-- important: an uppercase/whitespace key is a malformed resource location,
	-- not a second spelling of an existing key.
	local text = value
	local separator = string.find( text, ":", 1, true )
	local namespace, path
	if separator then
		namespace = string.sub( text, 1, separator - 1 )
		path = string.sub( text, separator + 1 )
		if namespace == "" then namespace = "minecraft" end
	else
		namespace, path = "minecraft", text
	end
	if not validNamespace( namespace ) or not validPath( path ) then
		return nil, "invalid_identifier"
	end
	return namespace .. ":" .. path
end

function MC.IdentifierParts( value )
	local canonical, err = MC.NormalizeResourceLocation( value )
	if not canonical then return nil, err end
	local namespace, path = string.match( canonical, "^([^:]+):(.*)$" )
	return { namespace = namespace, path = path, id = canonical }
end

-- Registry keys are stricter than the primitive Identifier parser: an empty
-- path is a valid low-level Identifier spelling but cannot identify content.
-- Keeping this distinction lets us copy the Java parser without accidentally
-- creating an unusable block/item/category key.
function MC.ValidateModContentIdentifier( value )
	local canonical, err = MC.NormalizeResourceLocation( value )
	if not canonical then return nil, err or "invalid_identifier" end
	local parts = MC.IdentifierParts( canonical )
	if not parts or parts.path == "" then return nil, "invalid_identifier" end
	if #canonical > 128 then return nil, "identifier_too_long" end
	return canonical
end

local Registry = MC.ModRegistry or {}
MC.ModRegistry = Registry
Registry.version = Registry.version or "1.0"
Registry.blocks = Registry.blocks or {}
Registry.blockOrder = Registry.blockOrder or {}
Registry.blockByRuntimeId = Registry.blockByRuntimeId or {}
Registry.nextBlockId = math.floor( tonumber( Registry.nextBlockId ) or 61001 )
Registry.creativeCategories = Registry.creativeCategories or {}
Registry.creativeOrder = Registry.creativeOrder or {}
Registry.creativeEntries = Registry.creativeEntries or {}
Registry.creativeBlockCategories = Registry.creativeBlockCategories or {}
Registry.creativeFrozen = Registry.creativeFrozen == true
-- CreativeModeTab slots are part of the vanilla layout, not addon-supplied
-- metadata: a public category never picks its own page/row/column.  Categories
-- have no unregister entry point, so slots only ever grow and a monotonic
-- cursor is an exact allocator.  See MC.API.Creative.RegisterCategory.
Registry.creativeSlotCursor = math.floor( tonumber( Registry.creativeSlotCursor ) or 0 )

MC.ModRegistryVersion = Registry.version
MC.ModBlockRegistryFrozen = MC.ModBlockRegistryFrozen == true

-- Preserve one pre-API built-in number without adding a numeric-id escape hatch
-- to the public definition schema.  The reservation is keyed by the exact table
-- created by sh_custom_blocks.lua, captured synchronously during the engine
-- include chain, and consumed once by the later public API call.  A separately
-- shipped addon cannot forge table identity or request its own fixed number.
local builtinRuntimeReservations = {}
do
	local definition = MC.MigratedBuiltinOakSlopeDefinition
	local runtimeId = finiteInteger( MC.MigratedBuiltinOakSlopeRuntimeId, 1 )
	if isTable( definition ) and runtimeId ~= nil then
		builtinRuntimeReservations[definition] = runtimeId
	end
	MC.MigratedBuiltinOakSlopeRuntimeId = nil
end

local function numericBlockInUse( id )
	if MC.Blocks and MC.Blocks[id] then return true end
	if Registry.blockByRuntimeId[id] then return true end
	for _, record in pairs( Registry.blocks ) do
		if tonumber( record.runtimeId ) == id then return true end
	end
	return false
end

local function nextBlockId()
	local maxId = 2 ^ ( ( MC.Net and MC.Net.ID_BITS ) or 16 ) - 1
	local id = math.max( 61001, Registry.nextBlockId )
	while id <= maxId and numericBlockInUse( id ) do id = id + 1 end
	if id > maxId then return nil end
	Registry.nextBlockId = id + 1
	return id
end

local function releaseUnusedBlockId( id )
	-- Registration is synchronous in GMod. If the most recently allocated id
	-- never became visible, put it back so a rejected definition cannot create
	-- load-order-dependent holes in the runtime mapping.
	if Registry.nextBlockId == id + 1 and not numericBlockInUse( id ) then
		Registry.nextBlockId = id
	end
end

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, child in pairs( value ) do out[copyValue( key, seen )] = copyValue( child, seen ) end
	return out
end

MC.ModRegistryCopy = copyValue

local function textureExists( value )
	if type( value ) == "number" then
		local tileNames = MC.TileNames or {}
		return value >= 0 and ( tileNames[value] ~= nil or value == 0 )
	end
	if not isString( value ) or trim( value ) == "" then return false end
	local tile = string.lower( trim( value ) )
	local tiles = MC.Tiles or MC.GeneratedTiles or {}
	if tiles[tile] ~= nil then return true end
	-- A generated tile table can be keyed by numeric id in a minimal test
	-- harness; accepting an explicit numeric-looking name is not safe, so do not
	-- infer existence from the string itself.
	return false
end

local function validTextureName( value )
	return isString( value ) and trim( value ) ~= ""
		and string.match( trim( value ), "^[a-z0-9_./%-]+$" ) ~= nil
end

local function validateTextureValue( value )
	if value == nil then return true end
	if type( value ) == "string" and not validTextureName( value ) then
		return nil, "invalid_texture"
	end
	if ( type( value ) ~= "string" and type( value ) ~= "number" ) or not textureExists( value ) then
		return nil, "missing_texture"
	end
	return true
end

-- Geometry is intentionally not validated as an arbitrary recursive object:
-- model paths, UV arrays, surface indices and handler payloads are not atlas
-- tiles. Walk only the known tile-bearing fields used by sh_blocks.lua.
local function validateGeometryTextures( value, seen, depth )
	if value == nil then return true end
	if type( value ) ~= "table" then return nil, "invalid_texture" end
	seen, depth = seen or {}, depth or 0
	if seen[value] then return true end
	if depth > 12 then return nil, "invalid_texture" end
	seen[value] = true
	for key, child in pairs( value ) do
		local field = string.lower( tostring( key ) )
		if field == "tile" or field == "texture" or field == "icon" then
			local ok, err = validateTextureValue( child )
			if not ok then return nil, err end
		elseif field == "textures" then
			if type( child ) ~= "table" then return nil, "invalid_texture" end
			for textureKey, textureValue in pairs( child ) do
				if type( textureValue ) ~= "table" then
					local ok, err = validateTextureValue( textureValue )
					if not ok then return nil, err end
				else
					local ok, err = validateGeometryTextures( textureValue, seen, depth + 1 )
					if not ok then return nil, err end
				end
			end
		elseif field == "modelquads" or field == "boxfaces"
			or field == "baked" or field == "modelvariants" or field == "faces"
			or field == "geometry" then
			if type( child ) == "table" then
				local ok, err = validateGeometryTextures( child, seen, depth + 1 )
				if not ok then return nil, err end
			end
		elseif type( child ) == "table" and field ~= "uv" and field ~= "uvs"
			and field ~= "verts" and field ~= "points" and field ~= "vertices"
			and field ~= "surface" then
			local ok, err = validateGeometryTextures( child, seen, depth + 1 )
			if not ok then return nil, err end
		end
	end
	return true
end

local function finiteNumber( value )
	value = tonumber( value )
	if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
	return value
end

local function validateBoxes( boxes )
	if boxes == nil then return true end
	if type( boxes ) ~= "table" then return nil, "invalid_shape" end
	if type( boxes[1] ) == "number" then boxes = { boxes } end
	if #boxes == 0 then return nil, "invalid_shape" end
	for _, box in ipairs( boxes ) do
		if type( box ) ~= "table" then return nil, "invalid_shape" end
		local values = {}
		for index = 1, 6 do
			values[index] = finiteNumber( box[index] )
			if values[index] == nil or values[index] < 0 or values[index] > 1 then
				return nil, "invalid_shape"
			end
		end
		if values[4] <= values[1] or values[5] <= values[2] or values[6] <= values[3] then
			return nil, "invalid_shape"
		end
	end
	return true
end

local function validateBoxFaces( boxFaces )
	if boxFaces == nil then return true end
	if type( boxFaces ) ~= "table" then return nil, "invalid_shape" end
	local groups = boxFaces
	if type( boxFaces[1] ) == "table" and boxFaces[1].tile ~= nil then groups = { boxFaces } end
	if #groups == 0 then return nil, "invalid_shape" end
	for _, faces in ipairs( groups ) do
		if type( faces ) ~= "table" or next( faces ) == nil then return nil, "invalid_shape" end
		for _, face in pairs( faces ) do
			if type( face ) ~= "table" then return nil, "invalid_shape" end
		end
	end
	return true
end

local function validateModelQuads( modelQuads )
	if modelQuads == nil then return true end
	if type( modelQuads ) ~= "table" or #modelQuads == 0 then return nil, "invalid_shape" end
	for _, quad in ipairs( modelQuads ) do
		if type( quad ) ~= "table" or type( quad.verts ) ~= "table" or #quad.verts ~= 4 then
			return nil, "invalid_shape"
		end
		for _, vertex in ipairs( quad.verts ) do
			if type( vertex ) ~= "table"
				or finiteNumber( vertex.x ) == nil or finiteNumber( vertex.y ) == nil
				or finiteNumber( vertex.z ) == nil then
				return nil, "invalid_shape"
			end
			if vertex.u ~= nil and finiteNumber( vertex.u ) == nil then return nil, "invalid_shape" end
			if vertex.v ~= nil and finiteNumber( vertex.v ) == nil then return nil, "invalid_shape" end
		end
	end
	return true
end

local function validateBakedModel( baked )
	if baked == nil then return true end
	if type( baked ) ~= "table" or next( baked ) == nil then return nil, "invalid_shape" end
	for _, faces in pairs( baked ) do
		if type( faces ) ~= "table" or next( faces ) == nil then return nil, "invalid_shape" end
		for _, face in pairs( faces ) do
			if type( face ) ~= "table" then return nil, "invalid_shape" end
		end
	end
	return true
end

local function validateModelVariants( variants )
	if variants == nil then return true end
	if type( variants ) ~= "table" or next( variants ) == nil then return nil, "invalid_shape" end
	for _, data in pairs( variants ) do
		if type( data ) ~= "table" or data.boxes == nil
			or data.boxFaces == nil or data.modelQuads == nil then
			return nil, "invalid_shape"
		end
		local boxesOK, boxesError = validateBoxes( data.boxes )
		if not boxesOK then return nil, boxesError end
		local facesOK, facesError = validateBoxFaces( data.boxFaces )
		if not facesOK then return nil, facesError end
		local quadsOK, quadsError = validateModelQuads( data.modelQuads )
		if not quadsOK then return nil, quadsError end
	end
	return true
end

local function validateConvexes( convexes )
	if convexes == nil then return true end
	if type( convexes ) ~= "table" or #convexes == 0 then return nil, "invalid_shape" end
	for _, convex in ipairs( convexes ) do
		if type( convex ) ~= "table" or #convex < 4 then return nil, "invalid_shape" end
		for _, point in ipairs( convex ) do
			if type( point ) ~= "table" then return nil, "invalid_shape" end
			for index = 1, 3 do
				local value = finiteNumber( point[index] ~= nil and point[index]
					or index == 1 and point.x or index == 2 and point.y or point.z )
				if value == nil or value < 0 or value > 1 then return nil, "invalid_shape" end
			end
		end
	end
	return true
end

function MC.ValidateModBlockDefinition( definition )
	if not isTable( definition ) then return nil, "invalid_definition" end
	-- Numeric identity is never part of the public schema.  In particular, do
	-- not accept the migration field used by an earlier prototype: fixed legacy
	-- ids are now reserved by private table identity above.
	if definition._builtinRuntimeId ~= nil then return nil, "invalid_definition" end
	if definition.id ~= nil and not isString( definition.id ) then return nil, "invalid_identifier" end
	-- Aliases and generated geometry are legacy/internal escape hatches.  They
	-- can overwrite another block's lookup key or bypass the public texture and
	-- shape validation, so a namespace registration must not smuggle them in.
	for _, internalField in ipairs( {
		"aliases", "generatedGeometry", "generatedCollisionConvexes", "modelSurfaces",
		"compactModel", "_modRegistry",
	} ) do
		if definition[internalField] ~= nil then return nil, "invalid_definition" end
	end
	-- Generated loot is game-owned and has no public registration adapter yet.
	-- Reject these fields instead of silently accepting metadata that the mining
	-- layer would ignore.
	if definition.drops ~= nil or definition.lootTable ~= nil or definition.loot_table ~= nil then
		return nil, "unsupported_loot_definition"
	end
	-- Names are translation keys (block.<namespace>.<path> unless
	-- translationKey says otherwise); the text is the addon's JSON.
	if definition.disp ~= nil or definition.dispZH ~= nil then return nil, "inline_name_unsupported" end
	if definition.translationKey ~= nil and not ( isString( definition.translationKey )
		and MC.I18n.ValidKey( definition.translationKey ) ) then
		return nil, "invalid_translation_key"
	end
	if definition.translationVars ~= nil and not isTable( definition.translationVars ) then
		return nil, "invalid_translation_vars"
	end
	-- `id` is the public spelling.  `mcid`/`name` remain compatibility aliases
	-- for the migrated legacy definition, but must not silently override an
	-- explicit public id.
	local rawId = ( isString( definition.id ) and definition.id or nil )
		or definition.mcid or definition.name
	local name, nameError = MC.ValidateModContentIdentifier( rawId )
	if not name then return nil, nameError or "invalid_identifier" end
	if Registry.blocks[name]
		or ( MC.CustomBlockDefs and MC.CustomBlockDefs[name] )
		or ( MC.ResolveBlock and MC.ResolveBlock( name ) ) then
		return nil, "duplicate_block"
	end

	local textures = definition.textures or {}
	if type( textures ) ~= "table" then return nil, "invalid_texture" end
	local top = textures.top ~= nil and textures.top or definition.top
	local side = textures.side ~= nil and textures.side or definition.side
	local bottom = textures.bottom ~= nil and textures.bottom or definition.bottom
	local front = textures.front ~= nil and textures.front or definition.front
	local particle = textures.particle ~= nil and textures.particle or definition.particle
	local icon = textures.icon ~= nil and textures.icon or definition.icon
	local supplied = { top, side, bottom, front, particle, icon }
	local anyTexture = false
	for _, value in ipairs( supplied ) do
		if value ~= nil then
			anyTexture = true
			local ok, textureError = validateTextureValue( value )
			if not ok then return nil, textureError end
		end
	end
	if not anyTexture then return nil, "missing_texture" end
	local geometryTextureOK, geometryTextureError = validateGeometryTextures( {
		modelQuads = definition.modelQuads,
		boxFaces = definition.boxFaces,
		baked = definition.baked,
		modelVariants = definition.modelVariants,
	}, nil, 0 )
	if not geometryTextureOK then return nil, geometryTextureError end

	local boxesOK, boxesError = validateBoxes( definition.boxes )
	if not boxesOK then return nil, boxesError end
	local facesOK, facesError = validateBoxFaces( definition.boxFaces )
	if not facesOK then return nil, facesError end
	local quadsOK, quadsError = validateModelQuads( definition.modelQuads )
	if not quadsOK then return nil, quadsError end
	local bakedOK, bakedError = validateBakedModel( definition.baked )
	if not bakedOK then return nil, bakedError end
	local variantsOK, variantsError = validateModelVariants( definition.modelVariants )
	if not variantsOK then return nil, variantsError end
	-- Legacy RegisterBlock has no separate collisionBoxes input.  Accepting it
	-- would make the public schema claim a shape that the runtime silently
	-- ignores, so require callers to use boxes or convexes explicitly.
	if definition.collisionBoxes ~= nil then return nil, "unsupported_collision_boxes" end
	if definition.convexes ~= nil and definition.collisionConvexes ~= nil then return nil, "invalid_shape" end
	local convexesOK, convexesError = validateConvexes( definition.collisionConvexes or definition.convexes )
	if not convexesOK then return nil, convexesError end
	local numericErrors = {
		hardness = "invalid_hardness",
		explosionResistance = "invalid_explosion_resistance",
		lightEmission = "invalid_light_emission",
	}
	for field, fieldError in pairs( numericErrors ) do
		if definition[field] ~= nil and finiteNumber( definition[field] ) == nil then
			return nil, fieldError
		end
	end
	if definition.lightEmission ~= nil then
		local light = finiteInteger( definition.lightEmission, 0 )
		if light == nil or light > 15 then return nil, "invalid_light_emission" end
	end
	if definition.castsAmbientOcclusion ~= nil and type( definition.castsAmbientOcclusion ) ~= "boolean" then
		return nil, "invalid_casts_ambient_occlusion"
	end
		if definition.castsShadow ~= nil and type( definition.castsShadow ) ~= "boolean" then
			return nil, "invalid_casts_shadow"
		end
	if definition.handlers ~= nil then
		if type( definition.handlers ) ~= "table" then return nil, "invalid_handlers" end
		local allowedHandlers = {
			CanUse = true, OnUse = true, OnPlace = true, OnBreak = true, OnTick = true,
			OnPlaced = true, OnRemoved = true, OnReplaced = true, OnStateChanged = true, OnMoved = true,
		}
		for key, callback in pairs( definition.handlers ) do
			if not allowedHandlers[key] or not isFunction( callback ) then
				return nil, "invalid_handlers"
			end
		end
	end
	return name
end

local function rememberBlock( block, canonical, runtimeId )
	if not block then return nil end
	canonical = canonical or MC.NormalizeResourceLocation( block.mcid or block.name )
	if not canonical then return nil end
	runtimeId = math.floor( tonumber( runtimeId or block.id ) or 0 )
	local record = Registry.blocks[canonical]
	if not record then
		record = { name = canonical, runtimeId = runtimeId, blockId = runtimeId }
		Registry.blocks[canonical] = record
		Registry.blockOrder[#Registry.blockOrder + 1] = canonical
	else
		record.runtimeId = runtimeId
		record.blockId = runtimeId
	end
	Registry.blockByRuntimeId[runtimeId] = canonical
	-- The network registry hash includes the process-local block mapping.  A
	-- save/persistence hash deliberately does not; invalidate only the network
	-- cache here so a later bootstrap refresh observes this entry.
	MC.ModRegistryNetworkHash = nil
	return record
end

function MC.ForgetModBlock( canonical, runtimeId )
	canonical = MC.NormalizeResourceLocation( canonical )
	if not canonical then return false end
	local record = Registry.blocks[canonical]
	runtimeId = finiteInteger( runtimeId or record and record.runtimeId, 0 ) or -1
	Registry.blocks[canonical] = nil
	if Registry.blockByRuntimeId[runtimeId] == canonical then Registry.blockByRuntimeId[runtimeId] = nil end
	for index = #Registry.blockOrder, 1, -1 do
		if Registry.blockOrder[index] == canonical then table.remove( Registry.blockOrder, index ) end
	end
	MC.ModRegistryNetworkHash = nil
	return record ~= nil
end

-- Index project/custom records that were registered by legacy bootstrap files
-- before this module was included. Vanilla names remain resolvable through the
-- normal block registry but are not copied into the mod snapshot.
if MC.Blocks then
	for id, block in pairs( MC.Blocks ) do
		local blockName = tostring( block and block.mcid or "" )
		local isMinecraft = string.sub( blockName, 1, 10 ) == "minecraft:"
		if type( block ) == "table" and ( block.custom == true or not isMinecraft ) then
			rememberBlock( block, nil, id )
		end
	end
end

function MC.RegisterModBlock( definition )
	if MC.ModBlockRegistryFrozen or MC.BlockStateRegistryFrozen then
		return nil, "registry_frozen"
	end
	local canonical, err = MC.ValidateModBlockDefinition( definition )
	if not canonical then return nil, err end
	if type( MC.RegisterCustomBlock ) ~= "function" then
		return nil, "block_registry_unavailable"
	end
	local requestedBuiltinId = builtinRuntimeReservations[definition]
	local requestedBuiltinName = requestedBuiltinId ~= nil and isString( definition.name )
		and definition.name ~= "" and definition.name or nil
	local runtimeId
	if requestedBuiltinId ~= nil then
		-- Only the migration shim may request a legacy number. Public addon
		-- definitions use namespace identity and receive an allocator-owned id.
		if numericBlockInUse( requestedBuiltinId ) then return nil, "legacy_runtime_id_occupied" end
		runtimeId = requestedBuiltinId
		Registry.nextBlockId = math.max( Registry.nextBlockId, runtimeId + 1 )
	else
		runtimeId = nextBlockId()
	end
	if not runtimeId then return nil, "too_many_blocks" end
	-- A frozen registry must own its values.  Copy nested schemas, geometry and
	-- handler tables so the caller cannot mutate a registered block later by
	-- retaining and editing the definition table it passed here.
	local prepared = copyValue( definition )
	prepared.id = runtimeId
	-- Public registrations use the canonical path as their legacy/internal
	-- spelling, so an addon cannot smuggle a second alias into the registry.
	-- The exact built-in migration table is the sole exception: preserving its
	-- old custom_oak_slope name keeps pre-API alias lookups byte-for-byte stable.
	prepared.name = requestedBuiltinName or string.match( canonical, "^[^:]+:(.+)$" ) or canonical
	prepared.mcid = canonical
	prepared.custom = true
	prepared._modRegistry = true
	local schemaWasPresent = MC.PendingBlockStateSchemas and MC.PendingBlockStateSchemas[canonical] ~= nil
	local block, registerError = MC.RegisterCustomBlock( prepared )
	if not block then
		-- RegisterCustomBlock validates the state schema before publishing the
		-- block itself, but its legacy queue tables may have been touched by a
		-- future implementation.  Keep the public failure atomic.
		if MC.CustomBlockDefs then MC.CustomBlockDefs[canonical] = nil end
		if MC.CustomBlockOrderSeen then MC.CustomBlockOrderSeen[canonical] = nil end
		for index = #( MC.CustomBlockOrder or {} ), 1, -1 do
			if MC.CustomBlockOrder[index] == canonical then table.remove( MC.CustomBlockOrder, index ) end
		end
		if not schemaWasPresent and MC.PendingBlockStateSchemas then
			MC.PendingBlockStateSchemas[canonical] = nil
			MC.BlockStateRegistryEffectiveHash = nil
		end
		releaseUnusedBlockId( runtimeId )
		return nil, registerError or "register_failed"
	end
	local record = rememberBlock( block, canonical, runtimeId )
	if not record then
		if MC.Blocks and MC.Blocks[runtimeId] == block then MC.Blocks[runtimeId] = nil end
		if MC.BlockByName and MC.BlockByName[canonical] == block then MC.BlockByName[canonical] = nil end
		if MC.BlockAliases then
			for alias, target in pairs( MC.BlockAliases ) do if target == block then MC.BlockAliases[alias] = nil end end
		end
		if MC.CustomBlockDefs then MC.CustomBlockDefs[canonical] = nil end
		if MC.CustomBlockOrderSeen then MC.CustomBlockOrderSeen[canonical] = nil end
		for index = #( MC.CustomBlockOrder or {} ), 1, -1 do
			if MC.CustomBlockOrder[index] == canonical then table.remove( MC.CustomBlockOrder, index ) end
		end
		if not schemaWasPresent and MC.PendingBlockStateSchemas then
			MC.PendingBlockStateSchemas[canonical] = nil
			MC.BlockStateRegistryEffectiveHash = nil
		end
		if MC.RefreshBlockList then MC.RefreshBlockList() end
		MC.ForgetModBlock( canonical, runtimeId )
		releaseUnusedBlockId( runtimeId )
		return nil, "register_failed"
	end
	-- Consume the private reservation only after the complete legacy+namespace
	-- publication succeeds. A failed/autorefreshed bootstrap may retry without
	-- silently losing the built-in's compatibility number or old name.
	if requestedBuiltinId ~= nil then builtinRuntimeReservations[definition] = nil end
	return {
		name = canonical,
		runtimeId = runtimeId,
		blockId = runtimeId,
		defaultStateId = MC.DefaultBlockState and MC.DefaultBlockState( runtimeId ) or nil,
	}
end

function MC.ModBlockRecord( value )
	local canonical = MC.ValidateModContentIdentifier( value )
	return canonical and Registry.blocks[canonical] or nil
end

function MC.ModBlockRuntimeId( value )
	local record = MC.ModBlockRecord( value )
	return record and record.runtimeId or nil
end

function MC.ModBlockNameForRuntimeId( value )
	value = tonumber( value )
	if value == nil or value ~= value or value == math.huge or value == -math.huge then return nil end
	return Registry.blockByRuntimeId[math.floor( value )]
end

local function shouldPersistBlock( record )
	local namespace = string.match( tostring( record and record.name or "" ), "^([^:]+):" )
	return record and ( namespace ~= "minecraft" or ( MC.Blocks and MC.Blocks[record.blockId] and MC.Blocks[record.blockId].custom == true ) )
end

function MC.BuildModRegistrySnapshot( stateSpecs )
	local blocks, states = {}, {}
	local usedStates, usedBlocks
	if type( stateSpecs ) == "table" then
		usedStates, usedBlocks = {}, {}
		for _, spec in ipairs( stateSpecs ) do
			if isString( spec ) then
				usedStates[spec] = true
				local blockName = string.match( spec, "^([^%[]+)" )
				blockName = blockName and MC.ValidateModContentIdentifier( blockName ) or nil
				if blockName then usedBlocks[blockName] = true end
			end
		end
	end
	for _, name in ipairs( Registry.blockOrder or {} ) do
		local record = Registry.blocks[name]
		if shouldPersistBlock( record ) and ( not usedBlocks or usedBlocks[name] ) then
			blocks[#blocks + 1] = {
				name = record.name,
				runtimeId = record.runtimeId,
				blockId = record.blockId,
			}
		end
	end
	if MC.BlockStateSchemaById and MC.FormatBlockState then
		local seen = {}
		for stateId, schema in pairs( MC.BlockStateSchemaById ) do
			if schema and shouldPersistBlock( Registry.blocks[schema.name] ) then
				local spec = MC.FormatBlockState( stateId )
				if spec and ( not usedStates or usedStates[spec] ) and not seen[spec] then
					seen[spec] = true
					states[#states + 1] = { spec = spec, runtimeId = stateId }
				end
			end
		end
		table.sort( states, function( left, right ) return left.spec < right.spec end )
	end
	table.sort( blocks, function( left, right ) return left.name < right.name end )
	return { version = "mod-registry-1", blocks = blocks, states = states }
end

function MC.ValidateModRegistrySnapshot( snapshot )
	if snapshot == nil then return true end -- old saves remain loadable
	if type( snapshot ) ~= "table" or snapshot.version ~= "mod-registry-1" then
		return false, "invalid_registry_snapshot"
	end
	if type( snapshot.blocks ) ~= "table" or type( snapshot.states ) ~= "table" then
		return false, "invalid_registry_snapshot"
	end
	local blockNames, blockRuntimeIds, blockIds = {}, {}, {}
	for _, entry in ipairs( snapshot.blocks or {} ) do
		if type( entry ) ~= "table" then return false, "invalid_registry_entry" end
		local name = MC.ValidateModContentIdentifier( entry and entry.name )
		local runtimeId = finiteInteger( entry.runtimeId, 0 )
		local blockId = finiteInteger( entry.blockId, 0 )
		if not name or name ~= entry.name
		or runtimeId == nil or blockId == nil then
			return false, "invalid_registry_entry"
		end
		if blockNames[name] or blockRuntimeIds[runtimeId] or blockIds[blockId] then return false, "duplicate_registry_entry" end
		blockNames[name], blockRuntimeIds[runtimeId], blockIds[blockId] = true, true, true
		if not ( MC.ResolveBlock and MC.ResolveBlock( name ) ) then
			return false, "missing_registry_entry:" .. name
		end
	end
	local stateSpecs, stateRuntimeIds = {}, {}
	for _, entry in ipairs( snapshot.states or {} ) do
		local runtimeId = type( entry ) == "table" and finiteInteger( entry.runtimeId, 0 ) or nil
		if type( entry ) ~= "table" or not isString( entry.spec ) or #entry.spec > 512
		or runtimeId == nil then
			return false, "invalid_registry_state_entry"
		end
		if stateSpecs[entry.spec] or stateRuntimeIds[runtimeId] then return false, "duplicate_registry_state_entry" end
		stateSpecs[entry.spec], stateRuntimeIds[runtimeId] = true, true
		local parsed = MC.ParseBlockState and MC.ParseBlockState( entry.spec ) or nil
		if not parsed then
			return false, "missing_registry_entry:" .. tostring( entry.spec )
		end
		local canonicalSpec = MC.FormatBlockState and MC.FormatBlockState( parsed ) or nil
		if canonicalSpec ~= entry.spec then return false, "noncanonical_registry_state:" .. tostring( entry.spec ) end
		local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( parsed ) or nil
		if not schema or not isString( schema.name ) then
			return false, "missing_registry_entry:" .. tostring( entry.spec )
		end
		-- Namespace spelling is not ownership.  A custom addon may deliberately
		-- use a minecraft: key in a compatibility world, so bind state entries to
		-- the snapshot's block table by registry ownership rather than by prefix.
		if Registry.blocks[schema.name] ~= nil and not blockNames[schema.name] then
			return false, "state_block_missing:" .. tostring( schema.name )
		end
	end
	return true
end

-- Convert saved numeric ids to the current process mapping without ever using
-- the old number as a lookup key. World palettes remain string-authoritative;
-- this helper is for importers/diagnostics that need an explicit remap report.
function MC.ResolveModRegistrySnapshot( snapshot )
	local ok, err = MC.ValidateModRegistrySnapshot( snapshot )
	if not ok then return nil, err end
	local blocks, blockIds, states = {}, {}, {}
	for _, entry in ipairs( snapshot.blocks or {} ) do
		local resolved = MC.ResolveBlock and MC.ResolveBlock( entry.name ) or nil
		if not resolved then return nil, "missing_registry_entry:" .. tostring( entry.name ) end
		blocks[tostring( entry.runtimeId )] = resolved.id
		blockIds[tostring( entry.blockId )] = resolved.id
	end
	for _, entry in ipairs( snapshot.states or {} ) do
		local stateId = MC.ParseBlockState and MC.ParseBlockState( entry.spec ) or nil
		if stateId == nil then return nil, "missing_registry_entry:" .. tostring( entry.spec ) end
		states[tostring( entry.runtimeId )] = stateId
	end
	return { version = "mod-registry-1", blocks = blocks, blockIds = blockIds, states = states }
end

function MC.FinalizeModCreativeRegistry()
	Registry.creativeFrozen = true
	MC.ModCreativeRegistryFrozen = true
	MC.ModBlockRegistryFrozen = true
	return true
end

MC.API.ModRegistryVersion = MC.API.ModRegistryVersion or Registry.version

-- The generated Minecraft report has its own immutable schema hash.  It is
-- useful for importer compatibility, but it is not enough for a live server
-- handshake once an addon contributes block-state schemas: a client carrying
-- only the vanilla report would otherwise pass the old hash and then decode a
-- different numeric state table.  Keep the generated hash untouched and
-- derive a second, effective hash from the canonical schema identities.  The
-- latter is deliberately independent of runtime block ids or registration
-- order; state ids are assigned by the sorted schema registry at freeze time.
local function registryHash( text )
	if type( util ) == "table" and type( util.SHA256 ) == "function" then
		return string.lower( tostring( util.SHA256( text ) or "" ) )
	end
	-- Pure-Lua test harnesses do not provide util.SHA256.  This is only a
	-- deterministic diagnostic fallback; live GMod always takes the SHA-256
	-- branch above.
	local a, b = 2166136261, 16777619
	for index = 1, #text do
		local byte = string.byte( text, index )
		a = ( ( a + byte ) * 16777619 ) % 4294967296
		b = ( b * 33 + byte ) % 4294967296
	end
	return string.format( "fallback-%08x%08x", a, b )
end

local function appendSchemaCanonicalLines( lines, name, schema )
	lines[#lines + 1] = "schema\0" .. tostring( name ) .. "\0" .. tostring( schema.stateCount or 1 ) .. "\n"
	for index, property in ipairs( schema.properties or {} ) do
		local values = {}
		for _, value in ipairs( property.canonicalValues or property.values or {} ) do
			values[#values + 1] = tostring( value )
		end
		local defaultIndex = schema.defaultIndexes and schema.defaultIndexes[index] or 1
		lines[#lines + 1] = table.concat( {
			"property", tostring( property.name or "" ), tostring( property.kind or "" ),
			table.concat( values, "," ), tostring( defaultIndex ),
		}, "\0" ) .. "\n"
	end
end

local function schemaCanonicalText()
	local schemas = MC.BlockStateRegistryFrozen and MC.BlockStateSchemaByName
		or MC.PendingBlockStateSchemas or MC.BlockStateSchemaByName or {}
	local names = {}
	for name in pairs( schemas ) do names[#names + 1] = tostring( name ) end
	table.sort( names )
	local lines = { "mc-effective-block-state-registry-v1\n" }
	for _, name in ipairs( names ) do
		local schema = schemas[name]
		-- Do not include blockId: it is a process-local legacy number and may
		-- change when addon load order changes. Canonical schema identity and
		-- property domains are the compatibility boundary.
		appendSchemaCanonicalLines( lines, name, schema )
	end
	return table.concat( lines )
end

-- Save compatibility is scoped to the content actually named by the save.
-- Network handshakes use the full effective registry hash below because they
-- exchange numeric state ids. Saves use strings, so installing an unrelated
-- addon must not make an otherwise resolvable world fail to load.
function MC.ModRegistrySnapshotHash( snapshot )
	if type( snapshot ) ~= "table" or snapshot.version ~= "mod-registry-1" then
		return nil, "invalid_registry_snapshot"
	end
	local schemas = MC.BlockStateRegistryFrozen and MC.BlockStateSchemaByName
		or MC.PendingBlockStateSchemas or MC.BlockStateSchemaByName or {}
	local names, seenNames = {}, {}
	for _, entry in ipairs( snapshot.blocks or {} ) do
		local name = type( entry ) == "table" and MC.ValidateModContentIdentifier( entry.name ) or nil
		if not name or name ~= entry.name then return nil, "invalid_registry_entry" end
		if not seenNames[name] then seenNames[name] = true; names[#names + 1] = name end
	end
	local stateSpecs, seenStates = {}, {}
	for _, entry in ipairs( snapshot.states or {} ) do
		local spec = type( entry ) == "table" and entry.spec or nil
		local stateId = isString( spec ) and MC.ParseBlockState and MC.ParseBlockState( spec ) or nil
		local schema = stateId ~= nil and MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
		if not schema or not isString( schema.name ) then
			return nil, "missing_registry_entry:" .. tostring( spec )
		end
		if not seenNames[schema.name] then seenNames[schema.name] = true; names[#names + 1] = schema.name end
		if not seenStates[spec] then seenStates[spec] = true; stateSpecs[#stateSpecs + 1] = spec end
	end
	table.sort( names )
	table.sort( stateSpecs )
	local lines = { "mc-mod-registry-persistence-v1\n" }
	for _, name in ipairs( names ) do
		local schema = schemas[name]
		if not schema then return nil, "missing_registry_entry:" .. tostring( name ) end
		appendSchemaCanonicalLines( lines, name, schema )
	end
	for _, spec in ipairs( stateSpecs ) do lines[#lines + 1] = "state\0" .. spec .. "\n" end
	return registryHash( table.concat( lines ) )
end

function MC.RefreshEffectiveBlockStateRegistryHash()
	local metadata = MC.BlockStateRegistryMetadata or MC.GeneratedStateMetadata or {}
	local hasAddonSchema = false
	local schemas = MC.BlockStateRegistryFrozen and MC.BlockStateSchemaByName
		or MC.PendingBlockStateSchemas or MC.BlockStateSchemaByName or {}
	for name in pairs( schemas ) do
		-- A public/custom registration may intentionally use the minecraft
		-- namespace. Registry ownership, not the namespace spelling, determines
		-- whether the effective hash must extend the generated vanilla hash.
		if Registry.blocks[tostring( name )] ~= nil then
			hasAddonSchema = true
			break
		end
	end
	MC.BlockStateRegistryEffectiveHash = hasAddonSchema and registryHash( schemaCanonicalText() )
		or tostring( metadata.schemaHash or "" )
	return MC.BlockStateRegistryEffectiveHash
end

function MC.GetEffectiveBlockStateRegistryHash()
	return MC.BlockStateRegistryEffectiveHash
		or MC.RefreshEffectiveBlockStateRegistryHash()
end

-- State ids are assigned from the canonical schema order, so the effective
-- schema hash above is intentionally independent of legacy block numbers.
-- Some older engine paths still carry a block id alongside a state (creative
-- selection and legacy projection are examples).  Their handshake therefore
-- needs a second hash that binds canonical block names to the current
-- process-local number.  This never enters save metadata: worlds remain
-- string-authoritative and can be remapped after an addon is reloaded.
local function networkRegistryCanonicalText()
	local lines = { "mc-mod-registry-network-v1\n", schemaCanonicalText() }
	local names = {}
	for name, record in pairs( Registry.blocks or {} ) do
		if type( record ) == "table" and isString( name ) then names[#names + 1] = name end
	end
	table.sort( names )
	for _, name in ipairs( names ) do
		local record = Registry.blocks[name]
		lines[#lines + 1] = "block-runtime\0" .. name .. "\0"
			.. tostring( finiteInteger( record.runtimeId, 0 ) or -1 ) .. "\n"
	end
	return table.concat( lines )
end

function MC.RefreshModRegistryNetworkHash()
	local hasCustomMapping = next( Registry.blocks or {} ) ~= nil
	if not hasCustomMapping then
		local metadata = MC.BlockStateRegistryMetadata or MC.GeneratedStateMetadata or {}
		MC.ModRegistryNetworkHash = tostring( metadata.schemaHash or "" )
	else
		MC.ModRegistryNetworkHash = registryHash( networkRegistryCanonicalText() )
	end
	return MC.ModRegistryNetworkHash
end

function MC.GetModRegistryNetworkHash()
	return MC.ModRegistryNetworkHash or MC.RefreshModRegistryNetworkHash()
end
