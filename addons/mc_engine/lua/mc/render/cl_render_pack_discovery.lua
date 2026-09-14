-- Addon-owned JSON uses GMA-packable data_static via GAME, not writable DATA.
MC = MC or {}
local D = MC.RenderPackDiscovery or { files = {}, owners = {} }
MC.RenderPackDiscovery = D
local Catalog, Schema = MC.RenderPackRegistry, MC.RenderPackSchema
local ROOT = "data_static/mc/shaderpacks/"
local MAX_FILES, MAX_BYTES = 256, 262144
local FIELDS = { schema = true, kind = true, id = true, definition = true }

local function reject( code, path, message )
	error( { code = code, message = path .. ": " .. message }, 0 )
end

local function readDefinition( path )
	local size = file.Size( path, "GAME" )
	if type( size ) ~= "number" or size < 1 or size > MAX_BYTES then
		reject( "render_pack_json_size", path, "missing, empty or larger than 256 KiB" )
	end
	local bytes = file.Read( path, "GAME" )
	if type( bytes ) ~= "string" or #bytes ~= size then
		reject( "render_pack_json_read", path, "could not read the complete mounted JSON file" )
	end
	-- Preserve string keys such as numeric-looking local program/interface names.
	local ok, document = pcall( util.JSONToTable, bytes, false, true )
	if not ok or type( document ) ~= "table" then
		reject( "render_pack_json_parse", path, "invalid JSON object" )
	end
	for field in pairs( document ) do
		if not FIELDS[field] then reject( "render_pack_json_field", path, "unknown envelope field: " .. tostring( field ) ) end
	end
	if document.schema ~= 1 or ( document.kind ~= "pack" and document.kind ~= "shader" )
		or not Schema.IsID( document.id ) then
		reject( "render_pack_json_identity", path, "expected schema=1, kind=pack/shader and a namespaced id" )
	end
	local definition, err = Schema.Normalize( document.definition )
	if not definition then reject( "render_pack_json_definition", path, tostring( err ) ) end
	return document.kind, document.id, definition
end

local function loadDefinition( path )
	local kind, id, definition = readDefinition( path )
	local key, previous = kind .. "/" .. id, D.files[path]
	if previous and ( previous.kind ~= kind or previous.id ~= id ) then
		reject( "render_pack_json_identity_changed", path, "a registered file cannot change its kind/id during this session" )
	end
	if D.owners[key] and D.owners[key] ~= path then
		reject( "render_pack_json_duplicate", path, key .. " was already discovered in " .. D.owners[key] )
	end
	local expectedBuild
	if previous then expectedBuild = previous.build end
	local ok, status
	if kind == "pack" and id == "mc:vanilla" and path == ROOT .. "mc_vanilla.json" then
		ok, status = Catalog.RegisterBuiltin( kind, id, definition, expectedBuild, path )
	else
		ok, status = Catalog.Register( kind, id, definition, path, expectedBuild )
	end
	if not ok then reject( "render_pack_json_register", path, tostring( status ) ) end
	D.files[path] = { kind = kind, id = id, build = definition.build }
	D.owners[key] = path
	return status
end

local function attempt( fn, ... )
	local ok, result = pcall( fn, ... )
	if ok then return true, result end
	local code, message = "render_pack_discovery", tostring( result )
	if type( result ) == "table" then code, message = result.code, result.message end
	MC.Fault( code, "%s; active runtime unchanged", message )
	return false, message
end

local function dependencies()
	return MC.Check( file and file.Find and file.Size and file.Read and util and util.JSONToTable,
		"render_pack_discovery_api", "mounted GAME file discovery and JSON decoding are required" )
end

local function findPaths()
	local files = file.Find( ROOT .. "*.json", "GAME", "nameasc" )
	if type( files ) ~= "table" or #files > MAX_FILES then
		reject( "render_pack_discovery_limit", ROOT, "expected at most 256 JSON files" )
	end
	table.sort( files )
	local paths = {}
	for _, name in ipairs( files ) do
		if type( name ) ~= "string" or #name > 128 or not name:match( "^[a-z0-9_%-]+%.json$" ) then
			reject( "render_pack_json_filename", ROOT, "expected a lowercase flat JSON filename" )
		end
		paths[#paths + 1] = ROOT .. name
	end
	return paths
end

function D.Scan()
	if not dependencies() then return false, "render_pack_discovery_api" end
	local ok, paths = attempt( findPaths )
	if not ok then return false, paths end
	local result = { files = #paths, changed = 0, unchanged = 0, failed = 0 }
	for _, path in ipairs( paths ) do
		local loaded, status = attempt( loadDefinition, path )
		if not loaded then result.failed = result.failed + 1
		elseif status == "unchanged" then result.unchanged = result.unchanged + 1
		else result.changed = result.changed + 1 end
	end
	return result.failed == 0, result
end

function D.Reload( plan )
	if not dependencies() then return false, "render_pack_discovery_api" end
	local paths = {}
	for key in pairs( plan.owners ) do
		-- Explicit API registrations have no JSON source to reload.
		if D.owners[key] then paths[#paths + 1] = D.owners[key] end
	end
	table.sort( paths )
	for _, path in ipairs( paths ) do
		local ok, err = attempt( loadDefinition, path )
		if not ok then return false, err end
	end
	return true
end

MC.API.OnRegister( function() D.Scan() end )
