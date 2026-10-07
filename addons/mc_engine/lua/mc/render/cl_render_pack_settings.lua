-- Per-pack effect settings and sparse presets live in config/<pack>/. They are
-- never convars, so switching or removing packs leaves no client.vdf entries.
-- An undeclared key reads as off/0: the pack decides which effects exist.
MC = MC or {}
local Settings = MC.RenderPackSettings or { callbacks = {} }
MC.RenderPackSettings = Settings
local CONFIG_DIR = "mc/shaderpacks/config"
local loadedFor, specs, order, values = false, {}, {}, {}
local builtins, builtinOrder, defaultPreset = {}, {}, nil
local selected, origin, storedValues = nil, nil, {}

local function configDir( pack )
	return CONFIG_DIR .. "/" .. pack:gsub( "[^%w_%-]", "_" )
end

local function configPath( pack )
	return configDir( pack ) .. "/state.json"
end

local function validPresetName( name )
	if #name == 0 or #name > 128 or name ~= string.Trim( name )
		or name:find( '[%c/\\:*?"<>|]' ) or name:sub( -1 ) == "." then return false end
	local stem = name:match( "^([^%.]+)" )
	stem = stem and string.lower( string.Trim( stem ) )
	return string.lower( name ) ~= "state" and stem ~= "con" and stem ~= "prn" and stem ~= "aux"
		and stem ~= "nul" and not ( stem and ( stem:match( "^com[1-9]$" ) or stem:match( "^lpt[1-9]$" ) ) )
end

local function userReference( reference )
	if type( reference ) ~= "string" then return end
	local filename = reference:match( "^user:(.+)$" )
	if not filename then return end
	local name = filename:match( "^(.*)%.json$" )
	if name then
		if not validPresetName( name ) then return end
	else
		-- Old references omitted the prefix and extension of the hashed filename.
		if #filename > 64 or not filename:match( "^[a-z0-9_%-]+$" ) then return end
		filename = "preset_" .. filename .. ".json"
	end
	return "user:" .. string.lower( filename )
end

local function userPath( reference )
	local canonical = userReference( reference )
	if not canonical then return end
	return configDir( Settings.pack ) .. "/" .. canonical:sub( 6 )
end

local function copy( source )
	local result = {}
	for key, value in pairs( source ) do result[key] = value end
	return result
end

local function readJSON( path )
	local bytes = file.Read( path, "DATA" )
	if not bytes then return nil, "missing_file" end
	if #bytes > 65536 then return nil, "file_too_large" end
	local ok, document = pcall( util.JSONToTable, bytes, false, true )
	if not ok or type( document ) ~= "table" then return nil, "invalid_json" end
	return document
end

local function writeJSON( path, document )
	local bytes = util.TableToJSON( document, true )
	if not bytes then return false, "json_encode_failed" end
	file.CreateDir( configDir( Settings.pack ) )
	file.Write( path, bytes )
	if file.Read( path, "DATA" ) ~= bytes then
		MC.Fault( "render_pack_settings_write", "could not save %s", path )
		return false, "write_failed"
	end
	return true
end

local function saveState( reference, overrides, source )
	local state = { version = 1, preset = reference }
	if reference == "custom" then state.values, state.origin = overrides, source end
	return writeJSON( configPath( Settings.pack ), state )
end

local function resolve( overrides )
	local result = {}
	for key, spec in pairs( specs ) do
		local value = overrides[key]
		if value == nil then value = spec.default end
		result[key] = value
	end
	return result
end

local function readPreset( reference )
	if builtins[reference] then return builtins[reference] end
	local path = userPath( reference )
	if not path then return nil, "unknown_preset" end
	local document, err = readJSON( path )
	if not document then return nil, err end
	return MC.RenderPackSchema.Preset( document, specs )
end

-- Returns a valid value for the spec, or nil. Strings come from commands.
local function coerce( spec, value )
	if spec.type == "bool" then
		if value == true or value == 1 or value == "1" or value == "true" then return true end
		if value == false or value == 0 or value == "0" or value == "false" then return false end
		return nil
	end
	local number = tonumber( value )
	if not number or number ~= number or number == math.huge or number == -math.huge then return nil end
	if spec.type == "choice" then
		for _, choice in ipairs( spec.choices ) do
			if choice.value == number then return number end
		end
		return nil
	end
	if spec.integer then number = math.floor( number + 0.5 ) end
	return math.min( spec.max, math.max( spec.min, number ) )
end

local function notify( key )
	local list = Settings.callbacks[key]
	if not list then return end
	for id, callback in pairs( list ) do
		local ok, err = pcall( callback, key, values[key] )
		if not ok then MC.Fault( "render_pack_setting_callback", "%s/%s: %s", key, tostring( id ), tostring( err ) ) end
	end
end

local function publish( nextValues, reference, source, overrides )
	local previous = values
	values, selected, origin, storedValues = nextValues, reference, source, overrides or {}
	-- All consumers see the final combination, including inside their callbacks.
	for _, key in ipairs( order ) do
		if previous[key] ~= values[key] then notify( key ) end
	end
	hook.Run( "MCRenderPackPresetChanged", Settings.pack, true )
end

local function refresh()
	local runtime = MC.RenderPackRuntime
	local active = runtime and runtime.active or nil
	if active == loadedFor then return end
	loadedFor, specs, order, values = active, {}, {}, {}
	builtins, builtinOrder, defaultPreset = {}, {}, nil
	selected, origin, storedValues = nil, nil, {}
	Settings.pack, Settings.groups = nil, {}
	local loadError
	if active then
		local owner = active.plan and active.plan.owners["pack/" .. active.pack]
		local definition = owner and owner.definition
		Settings.pack, Settings.groups = active.pack, definition and definition.settingGroups or {}
		for index, spec in ipairs( definition and definition.settings or {} ) do
			specs[spec.key], order[index] = spec, spec.key
		end
		for _, preset in ipairs( definition and definition.presets or {} ) do
			local reference = "builtin:" .. preset.id
			builtins[reference], builtinOrder[#builtinOrder + 1] = preset, reference
		end
		if #builtinOrder == 0 then
			builtins["builtin:default"] = { label = "Default", labelZH = "默认", values = {} }
			builtinOrder[1], defaultPreset = "builtin:default", "builtin:default"
		else
			defaultPreset = "builtin:" .. definition.defaultPreset
		end
		selected, storedValues = defaultPreset, builtins[defaultPreset].values
		values = resolve( storedValues )
		local state, err = readJSON( configPath( active.pack ) )
		if state then
			if state.version ~= 1 or type( state.preset ) ~= "string" then
				loadError = "invalid_state"
			elseif state.preset == "custom" then
				local document
				document, err = MC.RenderPackSchema.Preset( { version = 1, name = "Custom", values = state.values }, specs )
				if document then
					storedValues, selected = document.values, "custom"
					if builtins[state.origin] then origin = state.origin
					else origin = userReference( state.origin ) end
					values = resolve( storedValues )
				else loadError = err end
			else
				local preset
				preset, err = readPreset( state.preset )
				if preset then
					selected = userReference( state.preset ) or state.preset
					storedValues, values = preset.values, resolve( preset.values )
				else loadError = err end
			end
		elseif err ~= "missing_file" then loadError = err end
	end
	-- A pack switch changes every value at once; listeners re-read them.
	for key in pairs( Settings.callbacks ) do notify( key ) end
	hook.Run( "MCRenderPackSettingsChanged", Settings.pack )
	if loadError then
		MC.Fault( "render_pack_settings_file", "%s: %s; using default preset", configPath( Settings.pack ), loadError )
	end
end

Settings.Refresh = refresh

function Settings.Get( key )
	refresh()
	return values[key]
end

function Settings.Spec( key )
	refresh()
	return specs[key]
end

-- Ordered keys of the active pack, for listings and a future settings UI.
function Settings.Keys()
	refresh()
	return order
end

function Settings.CurrentPreset()
	refresh()
	return selected, origin
end

function Settings.DefaultPreset()
	refresh()
	return defaultPreset
end

function Settings.Presets()
	refresh()
	local result = {}
	if not Settings.pack then return result end
	for _, reference in ipairs( builtinOrder ) do
		local preset = builtins[reference]
		result[#result + 1] = { value = reference, label = preset.label or preset.id, labelZH = preset.labelZH, builtin = true }
	end
	local names = file.Find( configDir( Settings.pack ) .. "/*.json", "DATA", "nameasc" )
	for _, name in ipairs( names ) do
		local reference = userReference( "user:" .. name )
		if reference then
			local preset, err = readPreset( reference )
			if preset then
				result[#result + 1] = { value = reference, label = preset.name, builtin = false }
			else
				MC.Fault( "render_pack_preset_file", "%s: %s", name, tostring( err ) )
			end
		end
	end
	return result
end

function Settings.ApplyPreset( reference )
	refresh()
	if not Settings.pack then return false, "no_active_pack" end
	reference = userReference( reference ) or reference
	local preset, err = readPreset( reference )
	if not preset then return false, err end
	local nextValues = resolve( preset.values )
	local ok
	ok, err = saveState( reference )
	if not ok then return false, err end
	publish( nextValues, reference, nil, preset.values )
	return true
end

function Settings.Set( key, raw )
	refresh()
	local spec = specs[key]
	if not spec then return false, "unknown_setting" end
	local value = coerce( spec, raw )
	if value == nil then return false, "invalid_value" end
	if values[key] == value then return true, value end
	local overrides = copy( storedValues )
	for name, current in pairs( values ) do overrides[name] = current end
	overrides[key] = value
	local source = origin
	if selected ~= "custom" then source = selected end
	local document, err = MC.RenderPackSchema.Preset( { version = 1, name = "Custom", values = overrides }, specs )
	if not document then return false, err end
	local ok
	ok, err = saveState( "custom", overrides, source )
	if not ok then return false, err end
	storedValues, selected, origin, values[key] = overrides, "custom", source, value
	notify( key )
	hook.Run( "MCRenderPackSettingChanged", Settings.pack, key, value )
	hook.Run( "MCRenderPackPresetChanged", Settings.pack, false )
	return true, value
end

function Settings.Reset( key )
	refresh()
	if key ~= nil then return false, "single_setting_reset_removed" end
	if not Settings.pack then return false, "no_active_pack" end
	return Settings.ApplyPreset( defaultPreset )
end

function Settings.SavePreset( name, overwrite )
	refresh()
	if not Settings.pack then return false, "no_active_pack" end
	if type( name ) ~= "string" then return false, "invalid_name" end
	name = string.Trim( name )
	if not validPresetName( name ) then return false, "invalid_name" end
	local reference = "user:" .. string.lower( name ) .. ".json"
	local previous
	for _, entry in ipairs( Settings.Presets() ) do
		if not entry.builtin and entry.value ~= reference and string.lower( entry.label ) == string.lower( name ) then
			previous = entry.value
			break
		end
	end
	local path = userPath( reference )
	if ( previous or file.Exists( path, "DATA" ) ) and overwrite ~= true then return false, "preset_exists" end
	-- A saved preset need only override declared defaults, regardless of type.
	local overrides = {}
	for key, value in pairs( storedValues ) do
		if not specs[key] then overrides[key] = value end
	end
	for key, value in pairs( values ) do
		if value ~= specs[key].default then overrides[key] = value end
	end
	local document, err = MC.RenderPackSchema.Preset( { version = 1, name = name, values = overrides }, specs )
	if not document then return false, err end
	local ok
	ok, err = writeJSON( path, document )
	if not ok then return false, err end
	ok, err = Settings.ApplyPreset( reference )
	if not ok then return false, err end
	-- Remove the old filename only after both the new file and selection are saved.
	if previous and previous ~= reference then return Settings.DeletePreset( previous, true ) end
	return true
end

function Settings.DeletePreset( reference, confirmed )
	refresh()
	if not Settings.pack then return false, "no_active_pack" end
	reference = userReference( reference ) or reference
	local path = userPath( reference )
	if not path then return false, "read_only_preset" end
	if confirmed ~= true then return false, "confirmation_required" end
	if not file.Exists( path, "DATA" ) then return false, "unknown_preset" end
	if selected == reference then
		local ok, err = Settings.Reset()
		if not ok then return false, err end
	end
	file.Delete( path )
	if file.Exists( path, "DATA" ) then
		MC.Fault( "render_pack_preset_delete", "could not delete %s", path )
		return false, "delete_failed"
	end
	hook.Run( "MCRenderPackPresetChanged", Settings.pack, false )
	return true
end

-- Same shape as cvars.AddChangeCallback; also runs when the active pack changes.
function Settings.OnChange( key, id, callback )
	local list = Settings.callbacks[key]
	if not list then list = {} Settings.callbacks[key] = list end
	list[id] = callback
end

-- Drop-in for a ConVar object in effect code: GetBool/GetFloat/GetInt read the
-- active pack's value every call, so pack switches need no rebinding.
local Handle = {}
Handle.__index = Handle
function Handle:GetBool()
	local value = Settings.Get( self.key )
	return value == true or type( value ) == "number" and value ~= 0
end
function Handle:GetFloat()
	local value = Settings.Get( self.key )
	if value == true then return 1 end
	return type( value ) == "number" and value or 0
end
function Handle:GetInt()
	return math.floor( self:GetFloat() )
end

function Settings.Handle( key )
	return setmetatable( { key = key }, Handle )
end

-- Rows for the mc_config "shader pack" category: the pack selector, then the
-- active pack's settings under their group headings. Rebuilt on every open.
local function text( en, zh ) return { label = en, labelZH = zh } end

function Settings.ConfigItems()
	refresh()
	local runtime = MC.RenderPackRuntime
	local packs = {}
	for _, entry in ipairs( MC.RenderPackRegistry.List( "pack" ) ) do
		packs[#packs + 1] = { value = entry.id, label = entry.name .. "  (" .. entry.id .. ")" }
	end
	local items = { {
		name = "mc_render_pack select", kind = "choice", choices = packs,
		label = "Shader pack", labelZH = "光影包",
		help = "Switches immediately and is remembered for the next join.",
		helpZH = "立即切换，下次进入时沿用。",
		get = function() return runtime.Selected() end,
		set = function( value )
			local ok, err = runtime.Choose( value )
			if not ok then MC.Fault( "render_pack_select", "%s: %s", tostring( value ), tostring( err ) ) end
		end,
	} }
	if Settings.pack then
		items[#items + 1] = { name = "mc_render_pack_preset", kind = "preset",
			label = "Preset", labelZH = "预设", get = Settings.CurrentPreset }
	end
	local groupNames, counts, previous = {}, {}, nil
	for _, group in ipairs( Settings.groups ) do groupNames[group.id] = group end
	for _, key in ipairs( order ) do
		local group = specs[key].group or ""
		counts[group] = ( counts[group] or 0 ) + 1
	end
	if Settings.pack and #order == 0 then
		local heading = text( "This pack has no adjustable settings", "这个光影包没有可调设置" )
		heading.kind, heading.count = "heading", ""
		items[#items + 1] = heading
	end
	for _, key in ipairs( order ) do
		local spec = specs[key]
		local group = spec.group or ""
		if group ~= previous then
			local named = groupNames[group] or {}
			local heading = text( named.label or group, named.labelZH )
			heading.kind, heading.count = "heading", counts[group]
			items[#items + 1] = heading
			previous = group
		end
		local range = spec.type == "number" and string.format( " (%g – %g)", spec.min, spec.max ) or ""
		local item = { name = "mc_render_pack_set " .. key, kind = spec.type,
			label = spec.label or key, labelZH = spec.labelZH,
			help = ( spec.help or "" ) .. range, helpZH = ( spec.helpZH or spec.help or "" ) .. range,
			get = function() return values[key] end,
			set = function( value ) return Settings.Set( key, value ) end }
		if spec.type == "choice" then
			item.choices = {}
			for index, choice in ipairs( spec.choices ) do
				item.choices[index] = { value = choice.value, label = choice.label or tostring( choice.value ), labelZH = choice.labelZH }
			end
		end
		items[#items + 1] = item
	end
	return items
end

local function describe( key )
	local spec, value = specs[key], values[key]
	local range = spec.type == "number" and string.format( " [%g..%g]", spec.min, spec.max ) or ""
	if spec.type == "choice" then
		local list = {}
		for index, choice in ipairs( spec.choices ) do list[index] = tostring( choice.value ) end
		range = " {" .. table.concat( list, "," ) .. "}"
	end
	local label = MC.Language and MC.Language() == "zh_cn" and spec.labelZH or spec.label
	return string.format( "%-24s = %-8s default %s%s  %s", key, tostring( value ), tostring( spec.default ), range, label or "" )
end

local function completeKeys( command, arguments )
	local prefix = arguments:match( "^%s*(%S*)$" )
	if not prefix then return end
	local result = {}
	for _, key in ipairs( Settings.Keys() ) do
		if key:sub( 1, #prefix ) == prefix then result[#result + 1] = command .. " " .. key end
	end
	return result
end

concommand.Add( "mc_render_pack_settings", function()
	refresh()
	if not Settings.pack then print( "[MC render pack] no active pack" ) return end
	print( "[MC render pack] " .. Settings.pack .. " settings (" .. configPath( Settings.pack ) .. ")" )
	print( "  preset: " .. tostring( selected ) )
	for _, key in ipairs( order ) do print( "  " .. describe( key ) ) end
end )

concommand.Add( "mc_render_pack_set", function( _, _, args )
	refresh()
	local key = args[1]
	if not key then print( "usage: mc_render_pack_set <key> [value]" ) return end
	if not specs[key] then print( "[MC render pack] unknown setting " .. key .. " for " .. tostring( Settings.pack ) ) return end
	if args[2] == nil then print( "  " .. describe( key ) ) return end
	local ok, result = Settings.Set( key, args[2] )
	print( ok and "  " .. describe( key ) or "[MC render pack] " .. key .. ": " .. result )
end, completeKeys )

concommand.Add( "mc_render_pack_reset", function( _, _, args )
	local ok, err = Settings.Reset( args[1] )
	print( ok and "[MC render pack] restored " .. defaultPreset or "[MC render pack] " .. tostring( err ) )
end )

concommand.Add( "mc_render_pack_preset", function( _, _, args )
	local action, argument, ok, err = args[1], args[2]
	if action == "apply" then ok, err = Settings.ApplyPreset( argument )
	elseif action == "save" then ok, err = Settings.SavePreset( argument, args[3] == "confirm" )
	elseif action == "delete" then ok, err = Settings.DeletePreset( argument, args[3] == "confirm" )
	elseif action == nil or action == "list" then
		local current = Settings.CurrentPreset()
		print( "[MC render pack] preset: " .. tostring( current ) )
		for _, preset in ipairs( Settings.Presets() ) do print( "  " .. preset.value .. "  " .. preset.label ) end
		return
	else print( 'usage: mc_render_pack_preset list | apply <id> | save "<name>" [confirm] | delete <id> confirm' ) return end
	print( ok and "[MC render pack] preset saved/applied" or "[MC render pack] " .. tostring( err ) )
end )
