-- Client-side atlas layout profiles.
--
-- Block definitions keep stable logical tile ids. A profile may replace the
-- physical atlas geometry and remap those logical ids into a compact texture.
-- The mesh backend (Lua or Native) remains the sole owner of block geometry.

MC = MC or {}

local LAYOUT_FIELDS = { "COLS", "ROWS", "TILE", "PAD", "STRIDE", "W", "H", "INSET" }
local MAX_ATLAS_PAGES = 64

local function normalizeName( value )
	value = string.lower( tostring( value or "" ) )
	value = string.match( value, "^%s*(.-)%s*$" ) or ""
	if value == "" or #value > 64 or not string.match( value, "^[a-z0-9_%-]+$" ) then return nil end
	return value
end

local function normalizeOwner( value )
	value = string.lower( tostring( value or "" ) )
	value = string.match( value, "^%s*(.-)%s*$" ) or ""
	if value == "" or #value > 96 or not string.match( value, "^[a-z0-9_%.:%-]+$" ) then return nil end
	return value
end

local function integral( value, minimum, maximum )
	local number = tonumber( value )
	if not number or number ~= math.floor( number ) or number < minimum or number > maximum then return nil end
	return number
end

local function defaultLayoutSource()
	return MC.GeneratedAtlas or MC.Atlas or {}
end

local function copyLayout( source )
	return {
		COLS = source.COLS,
		ROWS = source.ROWS,
		TILE = source.TILE,
		PAD = source.PAD,
		STRIDE = source.STRIDE,
		W = source.W,
		H = source.H,
		INSET = source.INSET,
	}
end

local function normalizeMaterialPath( value )
	if value == nil then return nil end
	value = tostring( value or "" )
	value = string.match( value, "^%s*(.-)%s*$" ) or ""
	value = string.gsub( value, "\\", "/" )
	value = string.gsub( value, "%.vmt$", "" )
	value = string.gsub( value, "%.png$", "" )
	if value == "" or string.find( value, "..", 1, true ) then return nil end
	if not string.match( value, "^[a-zA-Z0-9_/%-]+$" ) then return nil end
	return value
end

MC.DefaultAtlasProfileLayout = MC.DefaultAtlasProfileLayout or copyLayout( defaultLayoutSource() )
MC.AtlasProfiles = MC.AtlasProfiles or {}
MC.AtlasProfileRevision = MC.AtlasProfileRevision or 0
MC.ActiveAtlasProfile = MC.ActiveAtlasProfile or "default"

local function normalizeLayout( source )
	if type( source ) ~= "table" then return nil, "invalid_atlas_profile_layout" end
	local cols = integral( source.COLS or source.cols, 1, 65535 )
	local rows = integral( source.ROWS or source.rows, 1, 65535 )
	local tile = integral( source.TILE or source.tile, 1, 65535 )
	local pad = integral( source.PAD or source.pad or 0, 0, 65535 )
	local stride = integral( source.STRIDE or source.stride or tile, 1, 65535 )
	local width = integral( source.W or source.width, 1, 65535 )
	local height = integral( source.H or source.height, 1, 65535 )
	local inset = tonumber( source.INSET or source.inset or 0.5 )
	if not ( cols and rows and tile and pad and stride and width and height )
	or not inset or inset < 0 or inset >= tile * 0.5 then
		return nil, "invalid_atlas_profile_layout"
	end
	if stride < tile + pad * 2 then return nil, "atlas_profile_stride_too_small" end
	if ( cols - 1 ) * stride + pad + tile > width
	or ( rows - 1 ) * stride + pad + tile > height then
		return nil, "atlas_profile_canvas_too_small"
	end

	local capacity = cols * rows
	if capacity > 65536 then return nil, "atlas_profile_capacity_too_large" end
	return {
		COLS = cols, ROWS = rows, TILE = tile, PAD = pad, STRIDE = stride,
		W = width, H = height, INSET = inset,
	}, math.min( capacity - 1, 4095 )
end

local function pageValue( rawPages, page )
	local value = rawPages[page]
	if value == nil and page > 0 then value = rawPages[page + 1] end
	return value
end

local function normalizePage( rawPage, page )
	if rawPage == nil and page == 0 then rawPage = { inheritDefault = true } end
	if type( rawPage ) ~= "table" then return nil, "invalid_atlas_profile_page" end
	local source = rawPage.inheritDefault == true and MC.DefaultAtlasProfileLayout
		or ( type( rawPage.layout ) == "table" and rawPage.layout or rawPage )
	local layout, mappedTileMaximum = normalizeLayout( source )
	if not layout then return nil, mappedTileMaximum end
	local opaquePath = normalizeMaterialPath( rawPage.opaque or rawPage.opaquePath or rawPage.material )
	local translucentPath = normalizeMaterialPath( rawPage.translucent or rawPage.translucentPath ) or opaquePath
	local materialProvider = type( rawPage.materialProvider ) == "function" and rawPage.materialProvider or nil
	local materialKey = tostring( rawPage.materialKey or rawPage.cacheKey or opaquePath or "default" )
	if #materialKey > 128 then return nil, "invalid_atlas_profile_page_material_key" end
	return {
		index = page,
		layout = layout,
		mappedTileMaximum = mappedTileMaximum,
		opaquePath = opaquePath,
		translucentPath = translucentPath,
		opaqueMaterial = rawPage.opaqueMaterial,
		translucentMaterial = rawPage.translucentMaterial,
		materialProvider = materialProvider,
		materialKey = materialKey,
	}
end

local function normalizeSurface( value, pages, label )
	local page, tile
	if type( value ) == "table" then
		page = integral( value.page or value.atlasPage or value[1] or 0, 0, MAX_ATLAS_PAGES - 1 )
		tile = integral( value.tile or value.physical or value[2], 0, 65535 )
	else
		page = 0
		tile = integral( value, 0, 65535 )
	end
	local pageDefinition = page and pages[page] or nil
	if not pageDefinition or tile == nil or tile > pageDefinition.mappedTileMaximum then
		return nil, label or "invalid_atlas_profile_surface"
	end
	return { page = page, tile = tile }
end

local function normalizeDefinition( name, definition, owner )
	if type( definition ) ~= "table" then return nil, "invalid_atlas_profile_definition" end
	local pages, pageCount = {}, 0
	if type( definition.pages ) == "table" then
		local highest = 0
		for rawPage in pairs( definition.pages ) do
			local page = integral( rawPage, 0, MAX_ATLAS_PAGES - 1 )
			if page == nil then return nil, "invalid_atlas_profile_page_index" end
			highest = math.max( highest, page )
		end
		pageCount = highest + 1
		for page = 0, highest do
			local normalized, err = normalizePage( pageValue( definition.pages, page ), page )
			if not normalized then return nil, err end
			pages[page] = normalized
		end
	else
		local normalized, err = normalizePage( definition, 0 )
		if not normalized then return nil, err end
		pages[0], pageCount = normalized, 1
	end

	local rawMap = definition.tiles or definition.tileMap or definition.map or {}
	if type( rawMap ) ~= "table" then return nil, "invalid_atlas_profile_tile_map" end
	local tileMap, logicalTiles = {}, {}
	for rawLogical, rawPhysical in pairs( rawMap ) do
		local logical = integral( rawLogical, 0, 65535 )
		local physical = select( 1, normalizeSurface( rawPhysical, pages, "invalid_atlas_profile_tile_mapping" ) )
		if not logical or not physical then return nil, "invalid_atlas_profile_tile_mapping" end
		tileMap[logical] = physical
		logicalTiles[#logicalTiles + 1] = logical
	end
	table.sort( logicalTiles )

	local rawFallback = definition.fallbackTile
	if rawFallback == nil then rawFallback = definition.fallback end
	if rawFallback == nil then rawFallback = definition.blankTile end
	local fallbackSurface = rawFallback ~= nil
		and select( 1, normalizeSurface( rawFallback, pages, "invalid_atlas_profile_fallback" ) ) or nil
	if rawFallback ~= nil and fallbackSurface == nil then return nil, "invalid_atlas_profile_fallback" end

	local keyParts = { name, "pages=" .. tostring( pageCount ) }
	for page = 0, pageCount - 1 do
		local p, layout = pages[page], pages[page].layout
		keyParts[#keyParts + 1] = table.concat( {
			"p" .. page, tostring( layout.COLS ), tostring( layout.ROWS ),
			tostring( layout.TILE ), tostring( layout.PAD ), tostring( layout.STRIDE ),
			tostring( layout.W ), tostring( layout.H ), tostring( layout.INSET ),
			p.materialKey,
		}, "," )
	end
	keyParts[#keyParts + 1] = fallbackSurface == nil and "identity"
		or ( "fallback=" .. fallbackSurface.page .. ">" .. fallbackSurface.tile )
	for _, logical in ipairs( logicalTiles ) do
		local surface = tileMap[logical]
		keyParts[#keyParts + 1] = tostring( logical ) .. ">" .. surface.page .. ">" .. surface.tile
	end
	return {
		name = name,
		owner = owner,
		layout = pages[0].layout,
		pages = pages,
		pageCount = pageCount,
		tileMap = tileMap,
		fallbackSurface = fallbackSurface,
		fallbackTile = fallbackSurface and fallbackSurface.tile or nil,
		cacheKey = table.concat( keyParts, ":" ),
	}
end

local defaultProfile = assert( normalizeDefinition( "default", MC.DefaultAtlasProfileLayout, "mc" ) )
MC.AtlasProfiles.default = defaultProfile

for name, definition in pairs( MC.AtlasProfiles ) do
	if name ~= "default" then
		local normalizedName = normalizeName( name )
		local owner = type( definition ) == "table" and normalizeOwner( definition.owner ) or nil
		local normalized = normalizedName == name and owner
			and select( 1, normalizeDefinition( name, definition, owner ) ) or nil
		if normalized then MC.AtlasProfiles[name] = normalized else MC.AtlasProfiles[name] = nil end
	end
end

local function applyLayout( profile )
	MC.Atlas = MC.Atlas or {}
	for _, field in ipairs( LAYOUT_FIELDS ) do MC.Atlas[field] = profile.layout[field] end
	MC.ActiveAtlasProfile = profile.name
	MC.ActiveAtlasProfileKey = profile.cacheKey
end

local activeAtLoad = MC.AtlasProfiles[MC.ActiveAtlasProfile] or defaultProfile
applyLayout( activeAtLoad )

function MC.NormalizeAtlasProfileName( value )
	return normalizeName( value )
end

function MC.AtlasProfileName()
	return MC.ActiveAtlasProfile or "default"
end

function MC.AtlasProfileCacheKey()
	local profile = MC.AtlasProfiles[MC.ActiveAtlasProfile] or defaultProfile
	return profile.cacheKey
end

function MC.AtlasProfileDefinitionOwner( name )
	name = normalizeName( name )
	local profile = name and MC.AtlasProfiles[name] or nil
	return profile and profile.owner or nil
end

function MC.AtlasProfileExists( name )
	name = normalizeName( name )
	return name ~= nil and MC.AtlasProfiles[name] ~= nil
end

function MC.ResolveAtlasTile( tile )
	local _, physical = MC.ResolveAtlasSurface( tile )
	return physical
end

function MC.ResolveAtlasSurface( tile )
	tile = math.floor( tonumber( tile ) or 0 )
	local profile = MC.AtlasProfiles[MC.ActiveAtlasProfile] or defaultProfile
	local mapped = profile.tileMap[tile]
	if mapped ~= nil then return mapped.page, mapped.tile, profile.pages[mapped.page].layout end
	if profile.fallbackSurface ~= nil then
		local fallback = profile.fallbackSurface
		return fallback.page, fallback.tile, profile.pages[fallback.page].layout
	end
	return 0, tile, profile.pages[0].layout
end

function MC.AtlasPageCount()
	local profile = MC.AtlasProfiles[MC.ActiveAtlasProfile] or defaultProfile
	return profile.pageCount or 1
end

function MC.AtlasPageDefinition( page )
	page = integral( page, 0, MAX_ATLAS_PAGES - 1 )
	local profile = MC.AtlasProfiles[MC.ActiveAtlasProfile] or defaultProfile
	return page and profile.pages[page] or nil
end

function MC.AtlasPageLayout( page )
	local definition = MC.AtlasPageDefinition( page )
	return definition and definition.layout or nil
end

function MC.AtlasPageMaterial( page, translucent )
	local definition = MC.AtlasPageDefinition( page )
	if not definition then return nil, "atlas_page_not_registered" end
	if page == 0 then
		local resolver = MC.NativeChunkMaterial or MC.CurrentChunkMaterial
		local material = resolver and resolver( translucent == true )
			or ( translucent and MC.MaterialTranslucent or MC.Material )
		return material
	end
	if definition.materialProvider then
		local ok, material = pcall( definition.materialProvider, translucent == true, page,
			MC.AtlasProfiles[MC.ActiveAtlasProfile] or defaultProfile )
		if ok and material then return material end
		return nil, ok and "atlas_page_material_unavailable" or tostring( material )
	end
	local direct = translucent and definition.translucentMaterial or definition.opaqueMaterial
	if direct then return direct end
	local path = translucent and definition.translucentPath or definition.opaquePath
	if not path or not Material then return nil, "atlas_page_material_unavailable" end
	local material = Material( path )
	if not material or ( material.IsError and material:IsError() ) then
		return nil, "atlas_page_material_error"
	end
	return material
end

local function markLuaMeshesDirty()
	local marked = 0
	for key, chunk in pairs( MC.World or {} ) do
		if chunk and ( chunk.count or 0 ) > 0 and MC.MarkChunkDirty then
			MC.MarkChunkDirty( key )
			marked = marked + 1
		end
	end
	return marked
end

local function refreshRenderer( reason )
	local native = MC.NativeChunkBackend
	if native and native.ReconfigureDefinitions then
		local ok, result = native.ReconfigureDefinitions( reason )
		if ok then return true, result end
		if ErrorNoHalt then
			ErrorNoHalt( "[MC] native atlas profile reconfigure failed: " .. tostring( result ) .. "\n" )
		end
		return false, result
	end
	return true, "lua_meshes_queued_" .. tostring( markLuaMeshesDirty() )
end

function MC.SetAtlasProfile( value )
	local name = normalizeName( value ) or "default"
	local profile = MC.AtlasProfiles[name]
	if not profile then return false, "atlas_profile_not_registered" end
	if MC.ActiveAtlasProfile == name and MC.ActiveAtlasProfileKey == profile.cacheKey then
		applyLayout( profile )
		return true, name, true
	end

	local previous = MC.ActiveAtlasProfile or "default"
	applyLayout( profile )
	MC.AtlasProfileRevision = MC.AtlasProfileRevision + 1
	local nativeOK, nativeResult = refreshRenderer( "atlas profile " .. previous .. " -> " .. name )
	if hook and hook.Run then hook.Run( "MC.AtlasProfileChanged", name, previous, nativeOK, nativeResult ) end
	return true, name, nativeOK, nativeResult
end

function MC.RegisterAtlasProfile( name, definition, owner )
	name = normalizeName( name )
	owner = normalizeOwner( owner )
	if not name or name == "default" then return false, "invalid_atlas_profile_name" end
	if not owner or owner == "mc" then return false, "invalid_atlas_profile_owner" end
	local existing = MC.AtlasProfiles[name]
	if existing and existing.owner ~= owner then return false, "owned_by_" .. tostring( existing.owner ) end
	local stored, err = normalizeDefinition( name, definition, owner )
	if not stored then return false, err end
	MC.AtlasProfiles[name] = stored
	MC.AtlasProfileRevision = MC.AtlasProfileRevision + 1
	if MC.ActiveAtlasProfile == name then MC.SetAtlasProfile( name ) end
	if hook and hook.Run then hook.Run( "MC.AtlasProfileRegistered", name, owner ) end
	return true, name
end

function MC.UnregisterAtlasProfile( name, owner )
	name = normalizeName( name )
	owner = normalizeOwner( owner )
	if not name or name == "default" or not owner then return false, "invalid_atlas_profile_owner" end
	local existing = MC.AtlasProfiles[name]
	if not existing then return false, "not_registered" end
	if existing.owner ~= owner then return false, "owner_mismatch" end
	if MC.ActiveAtlasProfile == name then MC.SetAtlasProfile( "default" ) end
	MC.AtlasProfiles[name] = nil
	MC.AtlasProfileRevision = MC.AtlasProfileRevision + 1
	if hook and hook.Run then hook.Run( "MC.AtlasProfileUnregistered", name, owner ) end
	return true
end

function MC.UnregisterAtlasProfileOwner( owner )
	owner = normalizeOwner( owner )
	if not owner then return 0 end
	local names = {}
	for name, profile in pairs( MC.AtlasProfiles ) do
		if name ~= "default" and profile.owner == owner then names[#names + 1] = name end
	end
	table.sort( names )
	if MC.AtlasProfiles[MC.ActiveAtlasProfile]
	and MC.AtlasProfiles[MC.ActiveAtlasProfile].owner == owner then
		MC.SetAtlasProfile( "default" )
	end
	for _, name in ipairs( names ) do MC.AtlasProfiles[name] = nil end
	if #names > 0 then MC.AtlasProfileRevision = MC.AtlasProfileRevision + 1 end
	if #names > 0 and hook and hook.Run then hook.Run( "MC.AtlasProfileOwnerUnregistered", owner, #names ) end
	return #names
end

function MC.ListAtlasProfiles()
	local result = {}
	for name, profile in pairs( MC.AtlasProfiles ) do
		result[#result + 1] = {
			name = name,
			owner = profile.owner,
			active = name == MC.ActiveAtlasProfile,
			COLS = profile.layout.COLS,
			ROWS = profile.layout.ROWS,
			TILE = profile.layout.TILE,
			PAD = profile.layout.PAD,
			STRIDE = profile.layout.STRIDE,
			W = profile.layout.W,
			H = profile.layout.H,
			pageCount = profile.pageCount or 1,
			fallbackTile = profile.fallbackTile,
			fallbackPage = profile.fallbackSurface and profile.fallbackSurface.page or nil,
		}
	end
	table.sort( result, function( left, right ) return left.name < right.name end )
	return result
end
