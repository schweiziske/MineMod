--[[----------------------------------------------------------------------------
    MineMod addon manifests (engine layer).

    This is the small Lua counterpart of the useful part of Fabric's
    fabric.mod.json: an addon id/version, dependency ranges, realm selection,
    and entrypoint callbacks.  It deliberately does not load files, install
    hooks, or import the upper gameplay layer.  Entrypoints are functions supplied by the addon
    and are dispatched in the existing register phase immediately before the
    shared registry freeze.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}

local API = MC.API
local manifests = API._manifests or {}
API._manifests = manifests
API.ManifestVersion = API.ManifestVersion or "1"

local function isTable( value ) return type( value ) == "table" end
local function isString( value ) return type( value ) == "string" end
local function isFunction( value ) return type( value ) == "function" end

local function trim( value )
	return string.match( tostring( value or "" ), "^%s*(.-)%s*$" ) or ""
end

local function copyValue( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, child in pairs( value ) do
		out[copyValue( key, seen )] = copyValue( child, seen )
	end
	return out
end

-- Manifest ids are namespace keys, not namespace:path content ids.  The
-- character rule and the special ".." rejection are the same namespace rule
-- used by Identifier/ResourceLocation in sh_mod_registry.lua.
local function normalizeManifestId( value )
	if not isString( value ) then return nil, "invalid_manifest_id" end
	if value == "" or #value > 128 then return nil, "invalid_manifest_id" end
	if value == ".." or not string.match( value, "^[a-z0-9_.%-]+$" ) then
		return nil, "invalid_manifest_id"
	end
	return value
end

local function parseVersion( value )
	if not isString( value ) then return nil end
	value = trim( value )
	if value == "" or #value > 128 then return nil end
	local plus = string.find( value, "+", 1, true )
	local withoutBuild, build = value, nil
	if plus then
		if string.find( value, "+", plus + 1, true ) then return nil end
		withoutBuild, build = string.sub( value, 1, plus - 1 ), string.sub( value, plus + 1 )
		if build == "" or not string.match( build, "^[A-Za-z0-9_.%-]+$" ) then return nil end
	end
	local core, pre = withoutBuild, nil
	local dash = string.find( withoutBuild, "-", 1, true )
	if dash then
		core = string.sub( withoutBuild, 1, dash - 1 )
		pre = string.sub( withoutBuild, dash + 1 )
		if pre == "" or not string.match( pre, "^[A-Za-z0-9_.%-]+$" ) then return nil end
	end
	local numbers = {}
	if core == "" then return nil end
	for part in string.gmatch( core .. ".", "([^%.]*)%." ) do
		if part == "" or not string.match( part, "^%d+$" ) then return nil end
		numbers[#numbers + 1] = tonumber( part )
	end
	if #numbers == 0 then return nil end
	return { text = value, numbers = numbers, prerelease = pre, build = build }
end

local function compareVersions( left, right )
	local a, b = parseVersion( left ), parseVersion( right )
	if not a or not b then return nil end
	local count = math.max( #a.numbers, #b.numbers )
	for index = 1, count do
		local av, bv = a.numbers[index] or 0, b.numbers[index] or 0
		if av < bv then return -1 end
		if av > bv then return 1 end
	end
	if a.prerelease == nil and b.prerelease ~= nil then return 1 end
	if a.prerelease ~= nil and b.prerelease == nil then return -1 end
	if a.prerelease == b.prerelease then return 0 end
	if a.prerelease == nil or b.prerelease == nil then return a.prerelease and -1 or 1 end
	local ai, bi = {}, {}
	for part in string.gmatch( a.prerelease, "[^%.]+" ) do ai[#ai + 1] = part end
	for part in string.gmatch( b.prerelease, "[^%.]+" ) do bi[#bi + 1] = part end
	for index = 1, math.max( #ai, #bi ) do
		local av, bv = ai[index], bi[index]
		if av == nil then return -1 end
		if bv == nil then return 1 end
		local an, bn = tonumber( av ), tonumber( bv )
		if an and bn then
			if an < bn then return -1 end
			if an > bn then return 1 end
		elseif an and not bn then
			return -1
		elseif not an and bn then
			return 1
		elseif av < bv then
			return -1
		elseif av > bv then
			return 1
		end
	end
	return 0
end

local function numericPrefix( value )
	local numbers = {}
	if not isString( value ) or value == "" then return nil end
	for part in string.gmatch( value .. ".", "([^%.]*)%." ) do
		if not string.match( part, "^%d+$" ) then return nil end
		numbers[#numbers + 1] = tonumber( part )
	end
	return #numbers > 0 and numbers or nil
end

local function hasNumericPrefix( candidate, prefix )
	if #candidate.numbers < #prefix then return false end
	for index, value in ipairs( prefix ) do
		if candidate.numbers[index] ~= value then return false end
	end
	return true
end

local function compareWith( candidate, operator, target )
	local comparison = compareVersions( candidate.text, target )
	if comparison == nil then return nil end
	if operator == ">=" then return comparison >= 0 end
	if operator == ">" then return comparison > 0 end
	if operator == "<=" then return comparison <= 0 end
	if operator == "<" then return comparison < 0 end
	return comparison == 0
end

local function rangeTokenMatches( candidate, token )
	if token == "*" or string.lower( token ) == "x" then return true end
	local tilde = string.sub( token, 1, 1 ) == "~"
	local body = tilde and string.sub( token, 2 ) or token
	if body == "" then return nil, "invalid_dependency_range" end

	-- Fabric uses values such as "~26.2-" for a release line.  Treat the
	-- numeric prefix before the trailing dash as the compatible line, including
	-- prereleases/build metadata on that line.
	if tilde and string.sub( body, -1 ) == "-" then
		local prefix = numericPrefix( string.sub( body, 1, -2 ) )
		if not prefix then return nil, "invalid_dependency_range" end
		return hasNumericPrefix( candidate, prefix )
	end

	-- Wildcard prefixes (1.x, 1.2.x) are useful for addon manifests and are
	-- equivalent to the corresponding numeric prefix.
	if string.match( body, "[%.]([xX*])$" ) or body == "x" or body == "X" then
		local prefixText = string.gsub( body, "[%.]?[xX%*]$", "" )
		local prefix = numericPrefix( prefixText )
		if not prefix then return nil, "invalid_dependency_range" end
		return hasNumericPrefix( candidate, prefix )
	end

	local operator = "="
	for _, candidateOperator in ipairs( { ">=", "<=", ">", "<", "=" } ) do
		if string.sub( body, 1, #candidateOperator ) == candidateOperator then
			operator = candidateOperator
			body = string.sub( body, #candidateOperator + 1 )
			break
		end
	end
	if body == "" then return nil, "invalid_dependency_range" end
	if tilde and operator ~= "=" then return nil, "invalid_dependency_range" end
	if string.sub( body, -1 ) == "-" then
		local prefix = numericPrefix( string.sub( body, 1, -2 ) )
		if not prefix then return nil, "invalid_dependency_range" end
		if operator ~= "=" then return nil, "invalid_dependency_range" end
		return hasNumericPrefix( candidate, prefix )
	end
	local target = parseVersion( body )
	if not target then return nil, "invalid_dependency_range" end
	if tilde then
		-- A normal tilde range stays on the target's major/minor line and must
		-- not select a version older than its lower bound.
		local prefixLength = math.min( 2, #target.numbers )
		local prefix = {}
		for index = 1, prefixLength do prefix[index] = target.numbers[index] end
		local lower = compareVersions( candidate.text, target.text )
		return lower ~= nil and lower >= 0 and hasNumericPrefix( candidate, prefix )
	end
	return compareWith( candidate, operator, target.text )
end

local function rangeAlternatives( range )
	local out = {}
	local start = 1
	while true do
		local separator = string.find( range, "||", start, true )
		local alternative = trim( string.sub( range, start, separator and separator - 1 or #range ) )
		if alternative == "" or string.find( alternative, "|", 1, true ) then return nil end
		out[#out + 1] = alternative
		if not separator then break end
		start = separator + 2
	end
	return out
end

local function validateRange( range )
	if not isString( range ) then return false end
	range = trim( range )
	if range == "" then return false end
	local alternatives = rangeAlternatives( range )
	if not alternatives then return false end
	for _, alternative in ipairs( alternatives ) do
		local found = false
		alternative = string.gsub( alternative, ",", " " )
		for token in string.gmatch( alternative, "%S+" ) do
			-- Ask the same matcher used at evaluation time to parse the token.
			-- A nil result is the unambiguous malformed-token signal; false is
			-- a valid range that simply does not match version 0.
			local _, tokenError = rangeTokenMatches( { text = "0", numbers = { 0 } }, token )
			if tokenError then return false end
			found = true
		end
		if not found then return false end
	end
	return true
end

local function rangeMatches( version, range )
	local candidate = parseVersion( version )
	if not candidate or not validateRange( range ) then return false end
	for _, rawAlternative in ipairs( rangeAlternatives( trim( range ) ) or {} ) do
		local alternative = string.gsub( rawAlternative, ",", " " )
		local all = true
		local found = false
		for token in string.gmatch( trim( alternative ), "%S+" ) do
			found = true
			local matched = rangeTokenMatches( candidate, token )
			if matched ~= true then all = false; break end
		end
		if found and all then return true end
	end
	return false
end

local function currentRealm()
	if SERVER == true then return "server" end
	if CLIENT == true then return "client" end
	return "shared"
end

local function environmentMatches( environment )
	return environment == "*" or environment == currentRealm() or currentRealm() == "shared"
end

local function normalizeEnvironment( value )
	value = value == nil and "*" or string.lower( trim( value ) )
	if value ~= "*" and value ~= "client" and value ~= "server" then
		return nil, "invalid_manifest_environment"
	end
	return value
end

local function entrypointList( value )
	if isFunction( value ) then return { value } end
	if not isTable( value ) or #value == 0 then return nil, "invalid_manifest_entrypoint" end
	local out = {}
	local count = 0
	for key in pairs( value ) do
		if type( key ) ~= "number" or key < 1 or key ~= math.floor( key ) or key > #value then
			return nil, "invalid_manifest_entrypoint"
		end
		count = count + 1
	end
	if count ~= #value then return nil, "invalid_manifest_entrypoint" end
	for index = 1, #value do
		if not isFunction( value[index] ) then return nil, "invalid_manifest_entrypoint" end
		out[index] = value[index]
	end
	return out
end

local function normalizeEntrypoints( raw, environment )
	if raw == nil then return {} end
	if not isTable( raw ) then return nil, "invalid_manifest_entrypoints" end
	local out = {}
	for name, value in pairs( raw ) do
		if name ~= "main" and name ~= "shared" and name ~= "client" and name ~= "server" then
			return nil, "invalid_manifest_entrypoint_name"
		end
		if ( name == "client" and environment == "server" )
			or ( name == "server" and environment == "client" ) then
			return nil, "entrypoint_environment_mismatch"
		end
		local list, err = entrypointList( value )
		if not list then return nil, err end
		out[name] = list
	end
	return out
end

local function dependencyId( value )
	local id, err = normalizeManifestId( value )
	return id, err
end

local function publicManifest( record )
	local entrypoints = {}
	for name, callbacks in pairs( record.entrypoints or {} ) do entrypoints[name] = #callbacks end
	return {
		id = record.id,
		version = record.version,
		environment = record.environment,
		depends = copyValue( record.depends ),
		entrypoints = entrypoints,
		active = environmentMatches( record.environment ),
		builtin = record.builtin == true,
	}
end

local function report( message )
	if ErrorNoHalt then ErrorNoHalt( "[MC] " .. tostring( message ) .. "\n" ) else print( "[MC] " .. tostring( message ) ) end
end

local function dependencyStatus( providerId, range, consumerId )
	local id, idError = dependencyId( providerId )
	if not id then return false, idError end
	if not validateRange( range ) then return false, "invalid_dependency_range" end
	local provider = manifests[id]
	if not provider then return false, "manifest_dependency_missing:" .. id end
	if not environmentMatches( provider.environment ) then
		return false, "manifest_dependency_environment:" .. id
	end
	if not rangeMatches( provider.version, range ) then
		return false, "manifest_dependency_version:" .. id
	end
	return true
end

API._ManifestVersionSatisfies = rangeMatches
API._ManifestDependencyStatus = dependencyStatus

local function validateManifest( definition )
	if not isTable( definition ) then return nil, "invalid_manifest" end
	local id, idError = normalizeManifestId( definition.id )
	if not id then return nil, idError end
	local version = trim( definition.version )
	if not parseVersion( version ) then return nil, "invalid_manifest_version" end
	local environment, environmentError = normalizeEnvironment( definition.environment )
	if not environment then return nil, environmentError end
	local depends = {}
	if definition.depends ~= nil then
		if not isTable( definition.depends ) then return nil, "invalid_manifest_depends" end
		for rawId, range in pairs( definition.depends ) do
			local dep, depError = dependencyId( rawId )
			if not dep then return nil, depError end
			if dep == id then return nil, "manifest_self_dependency" end
			if not validateRange( range ) then return nil, "invalid_dependency_range" end
			depends[dep] = trim( range )
		end
	end
	local entrypoints, entrypointError = normalizeEntrypoints( definition.entrypoints, environment )
	if not entrypoints then return nil, entrypointError end
	return {
		id = id,
		version = version,
		environment = environment,
		depends = depends,
		entrypoints = entrypoints,
		builtin = false,
	}
end

function API.RegisterManifest( definition )
	if MC.BlockStateRegistryFrozen or API._freezeStarted or API._ready or API._manifestDispatchStarted or API._manifestDispatchDone
		or MC.ModBlockRegistryFrozen or MC.ModCreativeRegistryFrozen then
		return false, "registry_frozen"
	end
	local record, err = validateManifest( definition )
	if not record then return false, err end
	if manifests[record.id] then return false, "duplicate_manifest" end
	manifests[record.id] = record
	return true, publicManifest( record )
end

function API.GetManifest( id )
	local normalized, err = normalizeManifestId( id )
	if not normalized then return nil, err end
	local record = manifests[normalized]
	if not record then return nil, "manifest_unavailable" end
	return publicManifest( record )
end

function API.ListManifests()
	local ids = {}
	for id in pairs( manifests ) do ids[#ids + 1] = id end
	table.sort( ids )
	local out = {}
	for _, id in ipairs( ids ) do out[#out + 1] = publicManifest( manifests[id] ) end
	return out
end

-- The engine itself is a provider.  Its manifest version follows the existing
-- ModRegistryVersion string, so `depends = { mcswep = ">=1.0" }` and
-- `MC.API.Require( "mcswep", ">=1.0" )` are the same check.
if not manifests.mcswep then
	manifests.mcswep = {
		id = "mcswep",
		version = tostring( API.ModRegistryVersion or MC.ModRegistryVersion or "1.0" ),
		environment = "*",
		depends = {},
		entrypoints = {},
		builtin = true,
	}
end

local function sortedManifestIds()
	local ids = {}
	for id in pairs( manifests ) do ids[#ids + 1] = id end
	table.sort( ids )
	return ids
end

function API._FireManifestEntrypoints()
	if API._manifestDispatchDone then return API._manifestFailure == nil, API._manifestFailure end
	if MC.BlockStateRegistryFrozen or API._freezeStarted or API._ready then return false, "registry_frozen" end
	API._manifestDispatchStarted = true
	local state, order = {}, {}
	local function visit( id )
		if state[id] == 1 then return false, "manifest_dependency_cycle:" .. id end
		if state[id] == 2 then return true end
		local record = manifests[id]
		if not record then return false, "manifest_dependency_missing:" .. id end
		if not environmentMatches( record.environment ) then
			state[id] = 2
			return true
		end
		state[id] = 1
		local dependencyIds = {}
		for dependency in pairs( record.depends or {} ) do dependencyIds[#dependencyIds + 1] = dependency end
		table.sort( dependencyIds )
		for _, dependency in ipairs( dependencyIds ) do
			local range = record.depends[dependency]
			local ok, err = dependencyStatus( dependency, range, id )
			if not ok then return false, tostring( id ) .. ":" .. tostring( err ) end
			local visited, visitError = visit( dependency )
			if not visited then return false, visitError end
		end
		state[id] = 2
		order[#order + 1] = id
		return true
	end

	for _, id in ipairs( sortedManifestIds() ) do
		local record = manifests[id]
		if record and environmentMatches( record.environment ) then
			local ok, err = visit( id )
			if not ok then
				API._manifestFailure = "manifest_bootstrap_failed:" .. tostring( err )
				API._manifestDispatchDone = true
				report( API._manifestFailure )
				return false, API._manifestFailure
			end
		end
	end

	for _, id in ipairs( order ) do
		local record = manifests[id]
		if record and not record.builtin then
			local callbacks = {}
			local entrypointNames = { "main", "shared" }
			local realm = currentRealm()
			if realm ~= "shared" then entrypointNames[#entrypointNames + 1] = realm end
			for _, name in ipairs( entrypointNames ) do
				for _, callback in ipairs( record.entrypoints[name] or {} ) do callbacks[#callbacks + 1] = callback end
			end
			for _, callback in ipairs( callbacks ) do
				local context = {
					api = API,
					manifest = publicManifest( record ),
					realm = currentRealm(),
				}
				local ok, result, reason = pcall( callback, context )
				if not ok or result == false then
					local detail = not ok and result or reason or "entrypoint_returned_false"
					API._manifestFailure = "manifest_bootstrap_failed:" .. record.id .. ":" .. tostring( detail )
					API._manifestDispatchDone = true
					report( API._manifestFailure )
					return false, API._manifestFailure
				end
			end
		end
	end

	API._manifestDispatchDone = true
	return true
end
