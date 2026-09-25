-- Per-pack effect settings. A pack declares them in definition.settings; the
-- player's changes persist in data/mc/shaderpacks/config/<pack>.json. They are
-- never convars, so switching or removing packs leaves no client.vdf entries.
-- An undeclared key reads as off/0: the pack decides which effects exist.
MC = MC or {}
local Settings = MC.RenderPackSettings or { callbacks = {} }
MC.RenderPackSettings = Settings
local CONFIG_DIR = "mc/shaderpacks/config"
local loadedFor, specs, order, values, stored = false, {}, {}, {}, {}

local function configPath( pack )
	return CONFIG_DIR .. "/" .. pack:gsub( "[^%w_%-]", "_" ) .. ".json"
end

-- Returns a valid value for the spec, or nil. Strings come from commands.
local function coerce( spec, value )
	if spec.type == "bool" then
		if value == true or value == 1 or value == "1" or value == "true" then return true end
		if value == false or value == 0 or value == "0" or value == "false" then return false end
		return nil
	end
	local number = tonumber( value )
	if not number or number ~= number then return nil end
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

local function refresh()
	local runtime = MC.RenderPackRuntime
	local active = runtime and runtime.active or nil
	if active == loadedFor then return end
	loadedFor, specs, order, values, stored = active, {}, {}, {}, {}
	Settings.pack, Settings.groups = nil, {}
	if active then
		local owner = active.plan and active.plan.owners["pack/" .. active.pack]
		local definition = owner and owner.definition
		Settings.pack, Settings.groups = active.pack, definition and definition.settingGroups or {}
		for index, spec in ipairs( definition and definition.settings or {} ) do
			specs[spec.key], order[index] = spec, spec.key
		end
		local path = configPath( active.pack )
		local content = file.Read( path, "DATA" )
		if content then
			local decoded = util.JSONToTable( content )
			if type( decoded ) == "table" then stored = decoded
			else MC.Fault( "render_pack_settings_file", "%s is not a JSON object; defaults are used", path ) end
		end
	end
	for key, spec in pairs( specs ) do
		local value = stored[key]
		if value ~= nil then value = coerce( spec, value ) end
		if value == nil then value = spec.default end
		values[key] = value
	end
	-- A pack switch changes every value at once; listeners re-read them.
	for key in pairs( Settings.callbacks ) do notify( key ) end
	hook.Run( "MCRenderPackSettingsChanged", Settings.pack )
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

local function save()
	file.CreateDir( CONFIG_DIR )
	file.Write( configPath( Settings.pack ), util.TableToJSON( stored, true ) )
end

function Settings.Set( key, raw )
	refresh()
	local spec = specs[key]
	if not spec then return false, "unknown_setting" end
	local value = coerce( spec, raw )
	if value == nil then return false, "invalid_value" end
	-- Unknown keys in the file are kept: another build of the pack may use them.
	stored[key], values[key] = value, value
	save()
	notify( key )
	return true, value
end

function Settings.Reset( key )
	refresh()
	if not Settings.pack then return false, "no_active_pack" end
	for name, spec in pairs( specs ) do
		if key == nil or name == key then
			stored[name], values[name] = nil, spec.default
		end
	end
	if key ~= nil and not specs[key] then return false, "unknown_setting" end
	save()
	for name in pairs( specs ) do
		if key == nil or name == key then notify( name ) end
	end
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
			set = function( value ) Settings.Set( key, value ) end }
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
	print( ok and "[MC render pack] reset " .. ( args[1] or "all settings" ) or "[MC render pack] " .. tostring( err ) )
end, completeKeys )
