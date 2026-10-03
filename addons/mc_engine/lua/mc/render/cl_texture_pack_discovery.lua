-- Mounted data-only addons. The default atlas is a required bootstrap resource.
MC = MC or {}
local D = MC.TexturePackDiscovery or { files = {}, outputs = {} }
MC.TexturePackDiscovery = D
local ROOT = "data_static/mc/resourcepacks/"
local envelope = { schema = true, kind = true, id = true, definition = true }
local common = { title = true, description = true, preview = true, pbr = true }
local atlas = { opaque = true, translucent = true, icon = true, atlasProfile = true }
local source = { output = true }

local function requireValue( value, message )
	if not value then error( message, 0 ) end
	return value
end

local function validID( value )
	return type( value ) == "string" and #value <= 64 and value:match( "^[a-z0-9_%-]+$" )
end

local function materialPath( value )
	return type( value ) == "string" and #value <= 240 and value:match( "^[a-z0-9_/%-]+$" )
		and value:sub( 1, 1 ) ~= "/" and not value:find( "//", 1, true )
end

local function read( path )
	local size = file.Size( path, "GAME" )
	requireValue( type( size ) == "number" and size > 0 and size <= 262144, "missing or oversized JSON" )
	local bytes = file.Read( path, "GAME" )
	requireValue( type( bytes ) == "string" and #bytes == size, "incomplete JSON read" )
	local document = util.JSONToTable( bytes, false, true )
	requireValue( type( document ) == "table", "invalid JSON object" )
	for key in pairs( document ) do requireValue( envelope[key], "unknown envelope field: " .. tostring( key ) ) end
	requireValue( document.schema == 1 and validID( document.id )
		and ( document.kind == "atlas" or document.kind == "source" ), "expected schema=1, kind=atlas/source and lowercase id" )
	local def = document.definition
	requireValue( type( def ) == "table", "definition must be an object" )
	local fields = document.kind == "atlas" and atlas or source
	for key in pairs( def ) do requireValue( common[key] or fields[key], "unknown definition field: " .. tostring( key ) ) end
	for key, limit in pairs( { title = 128, description = 1024 } ) do
		requireValue( def[key] == nil or type( def[key] ) == "string" and #def[key] <= limit
			and not def[key]:find( "%z" ), "invalid " .. key )
	end
	if def.preview ~= nil then requireValue( materialPath( def.preview ), "invalid preview path" ) end
	if document.kind == "atlas" then
		requireValue( materialPath( def.opaque ), "invalid opaque path" )
		for _, key in ipairs( { "translucent", "icon" } ) do
			if def[key] ~= nil then requireValue( materialPath( def[key] ), "invalid " .. key .. " path" ) end
		end
		if def.atlasProfile ~= nil then requireValue( validID( def.atlasProfile ), "invalid atlas profile" ) end
		if def.pbr ~= nil then
			requireValue( type( def.pbr ) == "table", "atlas pbr must contain normal and orm paths" )
			for key in pairs( def.pbr ) do requireValue( key == "normal" or key == "orm", "unknown pbr channel" ) end
			requireValue( materialPath( def.pbr.normal ) and materialPath( def.pbr.orm ), "invalid pbr paths" )
		end
	else
		requireValue( def.pbr == nil or type( def.pbr ) == "boolean", "source pbr must be boolean" )
		requireValue( def.output == nil or validID( def.output ), "invalid output id" )
	end
	local output = def.output or document.id
	if output == "default" then
		requireValue( document.kind == "atlas" and document.id == "default" and path == ROOT .. "default.json",
			"default is reserved for default.json" )
		requireValue( def.atlasProfile == nil or def.atlasProfile == "default", "default must use the engine layout" )
	end
	return document, bytes, output
end

function D.Default()
	local ok, document = pcall( read, ROOT .. "default.json" )
	requireValue( ok, "Required mc_texturepack_default addon unavailable: " .. tostring( document ) )
	requireValue( document.id == "default" and document.kind == "atlas", "default.json must declare the default atlas" )
	return document.definition
end

function D.IsPublicPack( name )
	return D.outputs[name] ~= nil
end

local function load( path, kind )
	local document, bytes, output = read( path )
	if document.kind ~= kind then return "skipped" end
	local previous = D.files[path]
	requireValue( not previous or previous.id == document.id and previous.kind == document.kind
		and previous.output == output, "registered kind/id/output cannot change before restart" )
	requireValue( not D.outputs[output] or D.outputs[output] == path, "duplicate output: " .. output )
	for otherPath, entry in pairs( D.files ) do
		requireValue( otherPath == path or entry.id ~= document.id, "duplicate id: " .. document.id )
	end
	local owner = "texturepack." .. document.id
	local registered
	if kind == "atlas" then
		registered = MC.TexturePackDefinitionOwner( output ) == owner
	else
		local pack = MC.AtlasBaker.packs[document.id]
		registered = pack and pack.owner == owner
	end
	if previous and previous.bytes == bytes and registered then return "unchanged" end
	local ok, err
	if kind == "atlas" then
		-- Reject missing files before the registry can replace a usable definition.
		for _, key in ipairs( { "opaque", "translucent", "icon" } ) do
			local value = document.definition[key]
			if value then requireValue( file.Exists( "materials/" .. value .. ".png", "GAME" ), "missing atlas: " .. value ) end
		end
		ok, err = MC.RegisterTexturePack( document.id, document.definition, owner )
	else
		ok, err = MC.AtlasBaker.RegisterSourcePack( document.id, document.definition, owner )
	end
	requireValue( ok, tostring( err ) )
	D.files[path] = { id = document.id, kind = kind, output = output, bytes = bytes }
	D.outputs[output] = path
	return "changed"
end

function D.Scan( kind )
	if kind == nil then
		local atlases, atlasResult = D.Scan( "atlas" )
		local sources, sourceResult = D.Scan( "source" )
		return atlases and sources, { atlas = atlasResult, source = sourceResult }
	end
	local names = file.Find( ROOT .. "*.json", "GAME", "nameasc" )
	if type( names ) ~= "table" or #names > 256 then
		MC.Fault( "texture_pack_discovery", "expected at most 256 mounted JSON descriptors" )
		return false, "texture_pack_discovery_limit"
	end
	table.sort( names )
	local result = { changed = 0, unchanged = 0, skipped = 0, failed = 0 }
	for _, name in ipairs( names ) do
		local ok, status = pcall( function()
			requireValue( type( name ) == "string" and #name <= 128 and name:match( "^[a-z0-9_%-]+%.json$" ), "invalid filename" )
			return load( ROOT .. name, kind )
		end )
		if ok then result[status] = result[status] + 1
		else
			result.failed = result.failed + 1
			MC.Fault( "texture_pack_discovery", "%s: %s; previous registration retained", tostring( name ), tostring( status ) )
		end
	end
	return result.failed == 0, result
end

-- Atlas discovery runs before the first material selection; sources need the baker.
MC.API.OnRegister( function() D.Scan( "source" ) end )
