--[[----------------------------------------------------------------------------
	MC : file-based localization.

	Every addon ships its own translations as JSON fragments below one shared
	virtual root, and nothing has to call a registration function:

	    data_static/mc/i18n/<namespace dirs...>/<unique file name>.json
	    { "locale": "zh_cn", "aliases": [ "zh" ], "entries": { "local.key": "..." } }

	The final key is the parent directories after the root, joined with ".",
	plus the entry key. The file name never takes part, so two addons can
	contribute to one namespace through differently named files. Personal
	overrides use the same format below DATA mc/i18n/overrides/ and load after
	every published fragment.

	Load order is the sorted full virtual path, published root first. When a
	later fragment repeats a (locale, final key) pair it wins and the pair is
	reported with both sources; equal text is still a duplicate. A broken file
	is a resource fault and contributes nothing.

	Lookup order: requested or current locale -> en_us -> the key itself.
	The available locales are whatever loaded with at least one entry; this
	file names no language besides the en_us base.
------------------------------------------------------------------------------]]

MC = MC or {}
local I18n = MC.I18n or {}
MC.I18n = I18n

local BASE_LOCALE = "en_us"
local RESOURCE_ROOT = "data_static/mc/i18n/"
local OVERRIDE_ROOT = "mc/i18n/overrides/"
I18n.BASE_LOCALE = BASE_LOCALE
I18n.RESOURCE_ROOT = RESOURCE_ROOT
I18n.OVERRIDE_ROOT = OVERRIDE_ROOT

-- Resource bounds. A fragment beyond any of them is rejected as a whole and
-- reported; nothing is truncated silently.
local LIMITS = {
	files = 4096,            -- JSON fragments below one root
	depth = 8,               -- namespace directories below a root
	pathBytes = 240,
	fileBytes = 1048576,
	entriesPerFile = 10000,  -- util.JSONToTable rejects documents over 15000 keys
	totalEntries = 524288,   -- every root and locale together
	keyBytes = 200,          -- final key, namespace included
	valueBytes = 8192,
	aliases = 16,
	localeBytes = 32,
}
I18n.LIMITS = LIMITS

local REPORT_PRINT_LIMIT = 50
local MISSING_LIMIT = 4096
local RESOLVE_DEPTH = 4

local ROOTS = {
	{ root = RESOURCE_ROOT, pathID = "GAME", kind = "published" },
	{ root = OVERRIDE_ROOT, pathID = "DATA", kind = "override" },
}

local EMPTY = {}

-- Published state; replaced as a whole by every load.
local dictionaries = {}
local sources = {}
local aliasTargets = {}
local localeList = {}
local baseDictionary = EMPTY
local lastReport = { generation = 0, errors = {}, conflicts = {}, aliasConflicts = {}, files = {}, locales = {}, entries = 0 }
local generation = 0

-- Current effective locale of this realm: the player's choice on the client,
-- the console language on the server.
local activeLocale = BASE_LOCALE
local activeDictionary = EMPTY

local missingByLocale = {}
local missingCount = 0
local debugMissing = false

local function trim( value )
	return ( string.match( value, "^%s*(.-)%s*$" ) )
end

-- Lowercase, "-" -> "_" and the shape a-z0-9 runs joined by single "_".
-- The canonical form is only a spelling; no list of languages is consulted.
local function canonicalLocale( value )
	if type( value ) ~= "string" then return nil end
	local locale = string.lower( trim( value ) )
	locale = string.gsub( locale, "%-", "_" )
	if #locale == 0 or #locale > LIMITS.localeBytes then return nil end
	if not string.find( locale, "^[a-z0-9_]+$" ) or string.find( locale, "__", 1, true )
		or string.sub( locale, 1, 1 ) == "_" or string.sub( locale, -1 ) == "_" then
		return nil
	end
	return locale
end
I18n.CanonicalLocale = canonicalLocale

-- Dot-separated segments of [A-Za-z0-9_-]; no empty segment anywhere.
local function validKey( key )
	return type( key ) == "string" and #key > 0 and #key <= LIMITS.keyBytes
		and string.find( key, "^[%w_%-%.]+$" ) ~= nil
		and string.sub( key, 1, 1 ) ~= "." and string.sub( key, -1 ) ~= "."
		and not string.find( key, "..", 1, true )
end
I18n.ValidKey = validKey

local function validDirectory( name )
	return type( name ) == "string" and string.find( name, "^[a-z0-9_%-]+$" ) ~= nil
end

local function validFileName( name )
	return type( name ) == "string" and string.find( name, "^[a-z0-9_%-][a-z0-9_%-%.]*%.json$" ) ~= nil
end

------------------------------------------------------------------ discovery

local function addError( report, source, reason )
	report.errors[#report.errors + 1] = { source = source, reason = reason }
end

-- Every JSON fragment below one root with the namespace its directories form.
-- The list is sorted by the full virtual path, which is the only definition
-- of "loaded later": file enumeration and autorun order never decide it.
local function listFragments( root, report )
	local fragments = {}
	local full = false
	local function walk( relative, namespace, depth )
		local files, directories = file.Find( root.root .. relative .. "*", root.pathID )
		if type( files ) ~= "table" or type( directories ) ~= "table" then
			addError( report, root.pathID .. ":" .. root.root .. relative, "directory listing failed" )
			return
		end
		for _, name in ipairs( files ) do
			local path = root.root .. relative .. name
			if not validFileName( name ) then
				addError( report, root.pathID .. ":" .. path, "file name must be lowercase [a-z0-9_.-] and end in .json" )
			elseif #path > LIMITS.pathBytes then
				addError( report, root.pathID .. ":" .. path, "path longer than " .. LIMITS.pathBytes .. " bytes" )
			elseif #fragments >= LIMITS.files then
				if not full then addError( report, root.pathID .. ":" .. root.root, "more than " .. LIMITS.files .. " files" ) end
				full = true
			else
				fragments[#fragments + 1] = { path = path, namespace = namespace }
			end
		end
		for _, name in ipairs( directories ) do
			local child = root.pathID .. ":" .. root.root .. relative .. name .. "/"
			if not validDirectory( name ) then
				addError( report, child, "directory name must be lowercase [a-z0-9_-]" )
			elseif depth >= LIMITS.depth then
				addError( report, child, "more than " .. LIMITS.depth .. " namespace directories" )
			else
				walk( relative .. name .. "/", namespace == "" and name or namespace .. "." .. name, depth + 1 )
			end
		end
	end
	walk( "", "", 0 )
	table.sort( fragments, function( a, b ) return a.path < b.path end )
	return fragments
end

local function readDocument( path, pathID )
	local size = file.Size( path, pathID )
	if type( size ) ~= "number" or size < 0 then return nil, "file is not readable" end
	if size > LIMITS.fileBytes then return nil, "file larger than " .. LIMITS.fileBytes .. " bytes" end
	local bytes = file.Read( path, pathID )
	if type( bytes ) ~= "string" then return nil, "file read failed" end
	if string.sub( bytes, 1, 3 ) == "\239\187\191" then bytes = string.sub( bytes, 4 ) end
	-- Keep numeric-looking entry keys as strings.
	local ok, document = pcall( util.JSONToTable, bytes, false, true )
	if not ok or type( document ) ~= "table" then
		return nil, "not a valid JSON object (syntax error, or over the decoder's 15000-key limit)"
	end
	return document
end

local DOCUMENT_FIELDS = { locale = true, aliases = true, entries = true }

-- Validates one decoded fragment. Any defect rejects the whole file.
local function parseFragment( document, namespace )
	if document[1] ~= nil then return nil, "the document must be a JSON object, not an array" end
	for field in pairs( document ) do
		if not DOCUMENT_FIELDS[field] then
			return nil, "unknown top-level field '" .. tostring( field ) .. "'"
		end
	end
	local locale = canonicalLocale( document.locale )
	if not locale then return nil, "'locale' is missing or not a locale identifier" end

	local aliases = {}
	if document.aliases ~= nil then
		if type( document.aliases ) ~= "table" then return nil, "'aliases' must be an array of locale identifiers" end
		local count = 0
		for _ in pairs( document.aliases ) do count = count + 1 end
		if count > LIMITS.aliases then return nil, "more than " .. LIMITS.aliases .. " aliases" end
		for index = 1, count do
			local alias = canonicalLocale( document.aliases[index] )
			if not alias then return nil, "alias #" .. index .. " is not a locale identifier" end
			aliases[index] = alias
		end
	end

	local entries = document.entries
	if type( entries ) ~= "table" then return nil, "'entries' must be an object of strings" end
	local keys = {}
	for key, value in pairs( entries ) do
		if not validKey( key ) then return nil, "invalid entry key '" .. tostring( key ) .. "'" end
		if type( value ) ~= "string" then return nil, "entry '" .. key .. "' is not a string" end
		if #value > LIMITS.valueBytes then return nil, "entry '" .. key .. "' is longer than " .. LIMITS.valueBytes .. " bytes" end
		keys[#keys + 1] = key
		if #keys > LIMITS.entriesPerFile then return nil, "more than " .. LIMITS.entriesPerFile .. " entries" end
	end
	table.sort( keys )

	local finalKeys = {}
	for index, key in ipairs( keys ) do
		-- Entry keys are always relative to the directory namespace.
		local final = namespace == "" and key or namespace .. "." .. key
		if #final > LIMITS.keyBytes then return nil, "final key '" .. final .. "' is longer than " .. LIMITS.keyBytes .. " bytes" end
		finalKeys[index] = final
	end
	return { locale = locale, aliases = aliases, keys = keys, finalKeys = finalKeys, entries = entries }
end

------------------------------------------------------------------ catalog build

local function buildCatalog()
	local report = {
		generation = generation + 1,
		errors = {}, conflicts = {}, aliasConflicts = {}, files = {}, locales = {}, entries = 0,
	}
	local nextDictionaries, nextSources = {}, {}
	local nextAliases, aliasSources = {}, {}
	local total = 0

	for _, root in ipairs( ROOTS ) do
		for _, fragmentPath in ipairs( listFragments( root, report ) ) do
			local source = root.pathID .. ":" .. fragmentPath.path
			local document, err = readDocument( fragmentPath.path, root.pathID )
			local fragment
			if document then fragment, err = parseFragment( document, fragmentPath.namespace ) end
			if not fragment then
				addError( report, source, err )
			elseif total + #fragment.keys > LIMITS.totalEntries then
				addError( report, source, "loading it would exceed " .. LIMITS.totalEntries .. " entries" )
			else
				total = total + #fragment.keys
				local locale = fragment.locale
				local dictionary = nextDictionaries[locale]
				local origin = nextSources[locale]
				if not dictionary then
					dictionary, origin = {}, {}
					nextDictionaries[locale], nextSources[locale] = dictionary, origin
				end
				for index, key in ipairs( fragment.keys ) do
					local final = fragment.finalKeys[index]
					local text = fragment.entries[key]
					local previous = origin[final]
					if previous then
						report.conflicts[#report.conflicts + 1] = {
							locale = locale, key = final, previous = previous, current = source,
							sameText = dictionary[final] == text,
						}
					end
					dictionary[final], origin[final] = text, source
				end
				for _, alias in ipairs( fragment.aliases ) do
					if alias ~= locale then
						local previous = nextAliases[alias]
						if previous and previous ~= locale then
							report.aliasConflicts[#report.aliasConflicts + 1] = {
								alias = alias, previous = previous, previousSource = aliasSources[alias],
								current = locale, source = source,
							}
						end
						nextAliases[alias], aliasSources[alias] = locale, source
					end
				end
				report.files[#report.files + 1] = {
					source = source, kind = root.kind, locale = locale, entries = #fragment.keys,
				}
			end
		end
	end

	local locales = {}
	for locale, dictionary in pairs( nextDictionaries ) do
		if next( dictionary ) ~= nil then locales[#locales + 1] = locale end
	end
	table.sort( locales )
	report.locales = locales
	report.entries = total
	return nextDictionaries, nextSources, nextAliases, locales, report
end

------------------------------------------------------------------ active locale

local resolveActive

-- "auto" matches the canonical game language against the loaded locales,
-- then against the aliases that the fragments declared. An explicit setting
-- is kept as chosen even if no fragment provides it; lookups then fall back to
-- the base locale and installing the resources later restores the choice.
local function resolveSetting( setting, gameLanguage )
	if setting ~= "auto" then return setting end
	local wanted = canonicalLocale( gameLanguage )
	if wanted then
		if dictionaries[wanted] and next( dictionaries[wanted] ) ~= nil then return wanted end
		local aliased = aliasTargets[wanted]
		if aliased and dictionaries[aliased] and next( dictionaries[aliased] ) ~= nil then return aliased end
	end
	return BASE_LOCALE
end

-- Normalizes a language setting. Returns setting, valid.
local function canonicalSetting( value )
	if type( value ) ~= "string" then return "auto", false end
	local text = string.lower( trim( value ) )
	if text == "" or text == "auto" then return "auto", true end
	local locale = canonicalLocale( text )
	if locale then return locale, true end
	return "auto", false
end
I18n.CanonicalSetting = canonicalSetting

local changeCallbacks = MC.LanguageCallbacks or {}
MC.LanguageCallbacks = changeCallbacks
local phraseBindings = {}

local function applyPhrase( phrase, binding )
	local text
	if binding.producer then
		local ok, result = pcall( binding.producer, activeLocale )
		if not ok or type( result ) ~= "string" then
			MC.Fault( "i18n_phrase_producer", "%s: %s", phrase, tostring( result ) )
			return
		end
		text = result
	else
		text = I18n.Resolve( binding.key, binding.vars )
	end
	language.Add( phrase, text )
end

local function refreshPhrases()
	if not CLIENT or not language or not language.Add then return end
	for phrase, binding in pairs( phraseBindings ) do applyPhrase( phrase, binding ) end
end

local function fireLanguageChanged( reason )
	refreshPhrases()
	local names = {}
	for name in pairs( changeCallbacks ) do names[#names + 1] = name end
	table.sort( names )
	for _, name in ipairs( names ) do
		local callback = changeCallbacks[name]
		if callback then MC.Try( "i18n_language_callback", callback, activeLocale, reason ) end
	end
	if hook and hook.Run then hook.Run( "MC.LanguageChanged", activeLocale, reason ) end
end

------------------------------------------------------------------ load + report

local function printReport( report )
	local realm = SERVER and "server" or "client"
	MsgN( string.format( "[MC i18n] %s: %d file(s), %d entries, locales [%s]; %d error(s), %d duplicate key(s)",
		realm, #report.files, report.entries, table.concat( report.locales, ", " ),
		#report.errors, #report.conflicts ) )
	for index, err in ipairs( report.errors ) do
		if index > REPORT_PRINT_LIMIT then
			MsgN( string.format( "[MC i18n]   ... %d more error(s); mc_i18n_report lists all", #report.errors - REPORT_PRINT_LIMIT ) )
			break
		end
		MsgN( "[MC i18n]   resource error: " .. err.source .. ": " .. tostring( err.reason ) )
	end
	for index, conflict in ipairs( report.conflicts ) do
		if index > REPORT_PRINT_LIMIT then
			MsgN( string.format( "[MC i18n]   ... %d more duplicate(s); mc_i18n_report lists all", #report.conflicts - REPORT_PRINT_LIMIT ) )
			break
		end
		MsgN( string.format( "[MC i18n]   duplicate %s %s: %s, then %s wins%s", conflict.locale, conflict.key,
			conflict.previous, conflict.current, conflict.sameText and " (same text)" or "" ) )
	end
	for _, conflict in ipairs( report.aliasConflicts ) do
		MsgN( string.format( "[MC i18n]   alias %s: %s (%s), then %s (%s) wins", conflict.alias,
			conflict.previous, conflict.previousSource, conflict.current, conflict.source ) )
	end
end

-- Rebuilds every dictionary from the visible files. Queries keep reading the
-- previous dictionaries until the new set is complete.
function I18n.Reload( reason )
	local nextDictionaries, nextSources, nextAliases, locales, report = buildCatalog()
	generation = report.generation
	dictionaries, sources, aliasTargets, localeList = nextDictionaries, nextSources, nextAliases, locales
	baseDictionary = dictionaries[BASE_LOCALE] or EMPTY
	lastReport = report
	missingByLocale, missingCount = {}, 0
	resolveActive( reason or "reload", true )
	printReport( report )
	if #report.errors > 0 then
		MC.Fault( "i18n_resource_invalid", "%d localization resource error(s), first: %s: %s",
			#report.errors, report.errors[1].source, tostring( report.errors[1].reason ) )
	end
	return report
end

------------------------------------------------------------------ queries

local function noteMissing( key, locale, fellBack )
	local bucket = missingByLocale[locale]
	if bucket == nil then
		bucket = {}
		missingByLocale[locale] = bucket
	end
	if bucket[key] ~= nil or missingCount >= MISSING_LIMIT then return end
	missingCount = missingCount + 1
	bucket[key] = fellBack and "base" or "key"
	if debugMissing then
		MsgN( string.format( "[MC i18n] %s missing %s (%s)", locale, key, fellBack and "used en_us" or "showed the key" ) )
	end
end

-- {name} takes vars.name; {1}, {2}, ... take the array part of vars, which
-- is how converted Minecraft templates (%s, %1$s) receive their arguments.
local interpolationVars
local function replacePlaceholder( name )
	local value = interpolationVars[name]
	if value == nil and string.find( name, "^%d+$" ) then value = interpolationVars[tonumber( name )] end
	if value == nil then return nil end
	return tostring( value )
end

local function interpolate( text, vars )
	local previous = interpolationVars
	interpolationVars = vars
	text = string.gsub( text, "{([%w_]+)}", replacePlaceholder )
	interpolationVars = previous
	return text
end

local function dictionaryFor( locale )
	if locale == nil then return activeDictionary, activeLocale end
	local dictionary = dictionaries[locale]
	if dictionary then return dictionary, locale end
	local canonical = canonicalLocale( locale )
	if canonical and dictionaries[canonical] then return dictionaries[canonical], canonical end
	return nil, canonical or tostring( locale )
end

-- MC.T( key, vars, locale ): the text of key in locale (default: current),
-- else in en_us, else the key itself. vars fills {name} placeholders.
function MC.T( key, vars, locale )
	local dictionary, resolved = dictionaryFor( locale )
	local text = dictionary and dictionary[key]
	if text == nil then
		text = baseDictionary[key]
		if text == nil then
			if type( key ) ~= "string" then
				MC.Fault( "i18n_invalid_key", "MC.T received %s instead of a key", type( key ) )
				return tostring( key )
			end
			noteMissing( key, resolved, false )
			text = key
		elseif resolved ~= BASE_LOCALE then
			noteMissing( key, resolved, true )
		end
	end
	if vars ~= nil then
		if type( vars ) ~= "table" then
			MC.Fault( "i18n_vars_not_table", "MC.T(%s) received %s instead of a vars table", tostring( key ), type( vars ) )
		elseif string.find( text, "{", 1, true ) then
			text = interpolate( text, vars )
		end
	end
	return text
end

-- A message spec is a key or { key = "...", vars = { name = value | spec } };
-- nested specs are translated in the same locale before interpolation.
local resolveSpec

-- Returns vars itself, or a copy whose nested specs are already translated.
local function resolveVars( vars, locale, depth )
	local resolved
	for name, value in pairs( vars ) do
		if type( value ) == "table" then
			if not resolved then
				resolved = {}
				for copyName, copyValue in pairs( vars ) do resolved[copyName] = copyValue end
			end
			if depth < RESOLVE_DEPTH then
				resolved[name] = resolveSpec( value, locale, depth + 1 )
			else
				MC.Fault( "i18n_spec_too_deep", "message spec nested deeper than %d levels", RESOLVE_DEPTH )
				resolved[name] = "?"
			end
		end
	end
	return resolved or vars
end

resolveSpec = function( spec, locale, depth )
	if type( spec ) == "string" then return MC.T( spec, nil, locale ) end
	if type( spec ) ~= "table" or type( spec.key ) ~= "string" then
		MC.Fault( "i18n_invalid_spec", "expected a key or { key = ..., vars = ... }, got %s", type( spec ) )
		return "?"
	end
	local vars = spec.vars
	if type( vars ) == "table" then vars = resolveVars( vars, locale, depth ) end
	return MC.T( spec.key, vars, locale )
end

function I18n.Resolve( keyOrSpec, vars, locale )
	if type( keyOrSpec ) == "string" then
		if type( vars ) == "table" then vars = resolveVars( vars, locale, 0 ) end
		return MC.T( keyOrSpec, vars, locale )
	end
	return resolveSpec( keyOrSpec, locale, 0 )
end

-- Count variants are explicit keys: <key>.one for a count of 1, <key>.other
-- for everything else. The locale that has either variant decides, so a
-- language without a singular form only needs <key>.other.
function I18n.TranslateCount( key, count, vars, locale )
	local dictionary = dictionaryFor( locale )
	local form = key .. ( count == 1 and ".one" or ".other" )
	local other = key .. ".other"
	local chosen
	if dictionary and dictionary[form] then chosen = form
	elseif dictionary and dictionary[other] then chosen = other
	elseif baseDictionary[form] then chosen = form
	elseif baseDictionary[other] then chosen = other
	else chosen = form end
	local merged = { count = count }
	if type( vars ) == "table" then
		for name, value in pairs( vars ) do merged[name] = value end
	end
	return I18n.Resolve( chosen, merged, locale )
end

-- Translation key of registered content, Minecraft's descriptionId form:
-- <kind>.<namespace>.<path> with "/" in the path read as ".", so
-- ContentKey( "block", "minecraft:oak_log" ) is "block.minecraft.oak_log".
-- An identifier without a namespace is in minecraft. Returns nil when the
-- identifier cannot form a valid key.
function I18n.ContentKey( kind, identifier )
	if type( kind ) ~= "string" or type( identifier ) ~= "string" then return nil end
	local namespace, path = string.match( identifier, "^([^:]+):(.+)$" )
	if not namespace then namespace, path = "minecraft", identifier end
	local key = kind .. "." .. namespace .. "." .. string.gsub( path, "/", "." )
	if not validKey( key ) then return nil end
	return key
end

function I18n.Has( key, locale )
	local dictionary = dictionaryFor( locale )
	return dictionary ~= nil and dictionary[key] ~= nil
end

function I18n.Language()
	return activeLocale
end
MC.Language = I18n.Language

function I18n.Locales()
	local copy = {}
	for index, locale in ipairs( localeList ) do copy[index] = locale end
	return copy
end

function I18n.IsLoaded( locale )
	local dictionary = dictionaries[locale]
	return dictionary ~= nil and next( dictionary ) ~= nil
end

-- "auto" is a selection mode, then every loaded locale by its identifier.
function I18n.LanguageOptions()
	local options = { { value = "auto", label = "auto" } }
	for _, locale in ipairs( localeList ) do
		options[#options + 1] = { value = locale, label = locale }
	end
	return options
end

function I18n.Generation()
	return generation
end

function I18n.Source( key, locale )
	local _, resolved = dictionaryFor( locale )
	local origin = sources[resolved]
	return origin and origin[key] or nil
end

local function copyTable( value )
	if type( value ) ~= "table" then return value end
	local result = {}
	for key, child in pairs( value ) do result[key] = copyTable( child ) end
	return result
end

function I18n.Report()
	local report = copyTable( lastReport )
	report.realm = SERVER and "server" or "client"
	report.language = activeLocale
	report.missing = I18n.MissingKeys()
	return report
end

-- Keys a query could not find in its locale since the last load:
-- { [locale] = { [key] = "base" | "key" } }, "base" meaning en_us answered.
function I18n.MissingKeys( locale )
	if locale ~= nil then return copyTable( missingByLocale[locale] or {} ) end
	return copyTable( missingByLocale )
end

function MC.RegisterLanguageChanged( name, callback )
	if type( name ) == "function" then
		callback = name
		name = tostring( callback )
	end
	if type( callback ) ~= "function" then return false end
	changeCallbacks[tostring( name )] = callback
	return true
end
I18n.RegisterLanguageChanged = MC.RegisterLanguageChanged

function I18n.UnregisterLanguageChanged( name )
	changeCallbacks[tostring( name )] = nil
end

------------------------------------------------------------------ realms

if CLIENT then
	MC.LanguageConVar = MC.LanguageConVar or CreateClientConVar( "mc_language", "auto", true, true,
		"MC interface language: auto follows gmod_language, or a loaded locale such as en_us" )
	local debugConVar = CreateClientConVar( "mc_i18n_debug", "0", true, false,
		"Print each localization key that falls back to en_us or to the key (once per key)" )
	debugMissing = debugConVar:GetBool()
	cvars.AddChangeCallback( "mc_i18n_debug", function( _, _, value )
		debugMissing = tobool( value )
	end, "mc_i18n_debug" )

	local gameLanguageConVar = GetConVar( "gmod_language" )
	local lastGameLanguage

	local function gameLanguage()
		return gameLanguageConVar and gameLanguageConVar:GetString() or ""
	end

	function I18n.LanguageSetting()
		return ( canonicalSetting( MC.LanguageConVar:GetString() ) )
	end

	resolveActive = function( reason, force )
		lastGameLanguage = gameLanguage()
		local resolved = resolveSetting( I18n.LanguageSetting(), lastGameLanguage )
		local changed = resolved ~= activeLocale
		activeLocale = resolved
		activeDictionary = dictionaries[resolved] or EMPTY
		if changed or force then fireLanguageChanged( reason ) end
	end

	-- Stores the setting as chosen; an unloaded locale stays selected and the
	-- lookups use en_us until a fragment for it appears.
	function I18n.SetLanguage( setting )
		local canonical, valid = canonicalSetting( setting )
		if not valid then return nil, "invalid_locale" end
		RunConsoleCommand( "mc_language", canonical )
		return canonical
	end

	cvars.RemoveChangeCallback( "mc_language", "mc_i18n_language" )
	cvars.AddChangeCallback( "mc_language", function( _, _, value )
		local canonical, valid = canonicalSetting( value )
		if valid and canonical ~= value then
			RunConsoleCommand( "mc_language", canonical )
			return
		end
		if not valid then
			MsgN( "[MC i18n] mc_language " .. tostring( value ) .. " is not a locale identifier; using auto" )
		end
		resolveActive( "setting" )
	end, "mc_i18n_language" )

	-- The engine reports gmod_language changes through this callback; the one
	-- second check only covers a client that changes it without notifying Lua.
	cvars.RemoveChangeCallback( "gmod_language", "mc_i18n_game_language" )
	cvars.AddChangeCallback( "gmod_language", function()
		resolveActive( "game_language" )
	end, "mc_i18n_game_language" )
	timer.Create( "mc_i18n_game_language", 1, 0, function()
		if gameLanguage() ~= lastGameLanguage then resolveActive( "game_language" ) end
	end )

	-- Registers a Garry's Mod phrase ("#phrase" in labels, PrintName, undo
	-- text) that follows the current language and every reload.
	function I18n.BindPhrase( phrase, key, vars )
		if type( phrase ) ~= "string" or phrase == "" then return false end
		phraseBindings[phrase] = { key = key, vars = vars }
		applyPhrase( phrase, phraseBindings[phrase] )
		return true
	end

	function I18n.BindPhraseProducer( phrase, producer )
		if type( phrase ) ~= "string" or phrase == "" or type( producer ) ~= "function" then return false end
		phraseBindings[phrase] = { producer = producer }
		applyPhrase( phrase, phraseBindings[phrase] )
		return true
	end
else
	local consoleConVar = GetConVar( "mc_console_language" ) or CreateConVar( "mc_console_language", BASE_LOCALE,
		FCVAR_ARCHIVE, "Language of MC server console text: a locale loaded on this server, or auto" )

	function I18n.LanguageSetting()
		return ( canonicalSetting( consoleConVar:GetString() ) )
	end

	resolveActive = function( reason, force )
		-- The server has no game language of its own; auto means en_us.
		local resolved = resolveSetting( I18n.LanguageSetting(), BASE_LOCALE )
		local changed = resolved ~= activeLocale
		activeLocale = resolved
		activeDictionary = dictionaries[resolved] or EMPTY
		if changed or force then fireLanguageChanged( reason ) end
	end

	cvars.RemoveChangeCallback( "mc_console_language", "mc_i18n_console_language" )
	cvars.AddChangeCallback( "mc_console_language", function()
		resolveActive( "setting" )
	end, "mc_i18n_console_language" )

	function I18n.SetLanguage()
		return nil, "client_only"
	end

	-- What this server would show the player; its own files decide, not the
	-- player's machine. Player-facing text is sent as key + vars instead.
	function I18n.LanguageForPlayer( ply )
		if not IsValid( ply ) or not ply.GetInfo then return activeLocale end
		local setting = canonicalSetting( ply:GetInfo( "mc_language" ) )
		return resolveSetting( setting, ply:GetInfo( "gmod_language" ) )
	end
end

-- The console language of this realm: mc_console_language on the server,
-- the player's interface language on a client.
function I18n.ConsoleLanguage()
	return activeLocale
end

function I18n.TranslateConsole( key, vars )
	return I18n.Resolve( key, vars, activeLocale )
end

if CLIENT then
	function I18n.LanguageForPlayer()
		return activeLocale
	end
end

------------------------------------------------------------------ commands

local function printLines( lines, ply )
	for _, line in ipairs( lines ) do
		if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, line ) else MsgN( line ) end
	end
end

local function reportLines()
	local report = I18n.Report()
	local lines = {
		string.format( "[MC i18n] %s generation %d, language %s (setting %s)", report.realm,
			report.generation, report.language, I18n.LanguageSetting() ),
		string.format( "[MC i18n] locales: %s", table.concat( report.locales, ", " ) ),
	}
	for _, entry in ipairs( report.files ) do
		lines[#lines + 1] = string.format( "  %-8s %-7s %5d  %s", entry.kind, entry.locale, entry.entries, entry.source )
	end
	for _, err in ipairs( report.errors ) do
		lines[#lines + 1] = "  error: " .. err.source .. ": " .. tostring( err.reason )
	end
	for _, conflict in ipairs( report.conflicts ) do
		lines[#lines + 1] = string.format( "  duplicate %s %s: %s, then %s wins%s", conflict.locale, conflict.key,
			conflict.previous, conflict.current, conflict.sameText and " (same text)" or "" )
	end
	for _, conflict in ipairs( report.aliasConflicts ) do
		lines[#lines + 1] = string.format( "  alias %s: %s (%s), then %s (%s) wins", conflict.alias,
			conflict.previous, conflict.previousSource, conflict.current, conflict.source )
	end
	return lines
end

local function missingLines()
	local lines = {}
	local locales = {}
	for locale in pairs( missingByLocale ) do locales[#locales + 1] = locale end
	table.sort( locales )
	for _, locale in ipairs( locales ) do
		local keys = {}
		for key in pairs( missingByLocale[locale] ) do keys[#keys + 1] = key end
		table.sort( keys )
		lines[#lines + 1] = string.format( "[MC i18n] %s: %d missing key(s)", locale, #keys )
		for _, key in ipairs( keys ) do
			lines[#lines + 1] = "  " .. key .. ( missingByLocale[locale][key] == "base" and "  (en_us used)" or "  (key shown)" )
		end
	end
	if #lines == 0 then lines[1] = "[MC i18n] no missing keys recorded since the last load" end
	return lines
end

if CLIENT then
	concommand.Add( "mc_i18n_reload", function() I18n.Reload( "reload" ) end, nil,
		"Reload the MC localization files visible to this client" )
	concommand.Add( "mc_i18n_report", function() printLines( reportLines() ) end, nil,
		"List the loaded MC localization files, errors and duplicate keys" )
	concommand.Add( "mc_i18n_missing", function() printLines( missingLines() ) end, nil,
		"List MC localization keys that fell back since the last load" )

	local function languageLines()
		local lines = { string.format( "[MC] mc_language = %s (current %s)", I18n.LanguageSetting(), activeLocale ) }
		for _, option in ipairs( I18n.LanguageOptions() ) do lines[#lines + 1] = "[MC]   " .. option.value end
		return lines
	end

	concommand.Add( "mc_lang", function( _, _, args )
		local requested = args and args[1] or ""
		if trim( requested ) == "" or requested == "?" or requested == "help" then
			printLines( languageLines() )
			return
		end
		if not I18n.SetLanguage( requested ) then
			MsgN( "[MC] " .. tostring( requested ) .. " is not a locale identifier" )
			printLines( languageLines() )
		end
	end, function( commandName, stringArgs )
		local needle = string.lower( trim( stringArgs or "" ) )
		local suggestions = {}
		for _, option in ipairs( I18n.LanguageOptions() ) do
			if needle == "" or string.find( option.value, needle, 1, true ) then
				suggestions[#suggestions + 1] = commandName .. " " .. option.value
			end
		end
		return suggestions
	end, "Set the MC interface language: auto or a loaded locale" )
else
	local function allowed( ply )
		return not IsValid( ply ) or ply:IsSuperAdmin()
	end

	concommand.Add( "mc_i18n_reload_sv", function( ply )
		if not allowed( ply ) then return end
		I18n.Reload( "reload" )
		printLines( { "[MC i18n] server localization reloaded; mc_i18n_report_sv for details" }, ply )
	end, nil, "Reload the MC localization files visible to the server" )
	concommand.Add( "mc_i18n_report_sv", function( ply )
		if not allowed( ply ) then return end
		printLines( reportLines(), ply )
	end, nil, "List the server's MC localization files, errors and duplicate keys" )
	concommand.Add( "mc_i18n_missing_sv", function( ply )
		if not allowed( ply ) then return end
		printLines( missingLines(), ply )
	end, nil, "List MC localization keys the server could not find since the last load" )
end

I18n.Reload( "startup" )
