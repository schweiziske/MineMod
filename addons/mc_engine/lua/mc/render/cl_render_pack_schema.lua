-- L2 descriptor draft. Validation is CPU-only; it does not certify a GPU ABI.
MC = MC or {}
local Schema = {}
MC.RenderPackSchema = Schema
Schema.VERSION = 1

local function reject( reason )
	error( reason, 0 )
end

function Schema.IsID( value )
	return type( value ) == "string" and #value <= 128
		and value:match( "^[a-z0-9_%-]+:[a-z0-9_%-]+$" ) ~= nil
end

local function localID( value )
	return type( value ) == "string" and #value <= 64
		and value:match( "^[a-z0-9_%-]+$" ) ~= nil
end

local function hash( value )
	return type( value ) == "string" and #value == 64 and value:match( "^[a-f0-9]+$" ) ~= nil
end

local function positiveInteger( value )
	return type( value ) == "number" and value >= 1 and value <= 65535 and value == math.floor( value )
end

-- Reject metatables before traversal. Never invoke descriptor callbacks,
-- __pairs, __index or __tostring, including while reporting invalid input.
function Schema.Copy( input )
	local stack, nodes, bytes = {}, 0, 0
	local function copy( value, depth )
		nodes = nodes + 1
		if nodes > 8192 or depth > 16 then reject( "descriptor_limit" ) end
		local kind = type( value )
		if kind == "string" then
			bytes = bytes + #value
			if bytes > 262144 then reject( "descriptor_limit" ) end
			return value
		end
		if kind == "boolean" or kind == "nil" then return value end
		if kind == "number" then
			if value ~= value or value == math.huge or value == -math.huge then reject( "nonfinite_number" ) end
			return value
		end
		if kind ~= "table" then reject( "descriptor_not_data" ) end
		if getmetatable( value ) ~= nil then reject( "descriptor_metatable" ) end
		if stack[value] then reject( "descriptor_cycle" ) end
		stack[value] = true
		local result = {}
		for key, child in next, value do
			if type( key ) ~= "string" and type( key ) ~= "number" then reject( "invalid_data_key" ) end
			result[copy( key, depth + 1 )] = copy( child, depth + 1 )
		end
		stack[value] = nil
		return result
	end
	local ok, result = pcall( copy, input, 0 )
	if not ok then return nil, result end
	return result
end

-- Exact, deterministic comparison; unlike a short hash this has no collisions.
function Schema.Canonical( value )
	local kind = type( value )
	if kind == "string" then return "s" .. #value .. ":" .. value end
	if kind == "number" then return "n" .. string.format( "%.17g", value ) .. ";" end
	if kind == "boolean" then return value and "true;" or "false;" end
	local entries = {}
	for key, child in next, value do
		entries[#entries + 1] = Schema.Canonical( key ) .. Schema.Canonical( child )
	end
	table.sort( entries )
	return "{" .. table.concat( entries ) .. "}"
end

local function fields( value, allowed, label )
	if type( value ) ~= "table" then reject( "invalid_" .. label ) end
	for key in pairs( value ) do
		if not allowed[key] then reject( "unknown_field:" .. label ) end
	end
end

local function map( value, idCheck, limit, label )
	if type( value ) ~= "table" then reject( "invalid_" .. label ) end
	local count = 0
	for key in pairs( value ) do
		if not idCheck( key ) then reject( "invalid_key:" .. label ) end
		count = count + 1
		if count > limit then reject( "limit:" .. label ) end
	end
	return count
end

local function array( value, limit, label )
	if type( value ) ~= "table" then reject( "invalid_" .. label ) end
	local count = 0
	for key in pairs( value ) do
		if not positiveInteger( key ) then reject( "invalid_array:" .. label ) end
		count = count + 1
	end
	if count > limit then reject( "limit:" .. label ) end
	for index = 1, count do
		if value[index] == nil then reject( "sparse_array:" .. label ) end
	end
	return count
end

local stages = { world_opaque = 1, world_cutout = 2, after_opaque = 3,
	world_translucent = 4, after_translucent = 5 }

local function texturePath( value )
	if type( value ) ~= "string" or #value > 240
		or not value:match( "^materials/[a-z0-9_/%-%.]+$" )
		or value:find( "..", 1, true ) or value:find( "//", 1, true ) then return false end
	for segment in value:gmatch( "[^/]+" ) do
		if segment == "." then return false end
	end
	return value:match( "%.png$" ) ~= nil or value:match( "%.vtf$" ) ~= nil
end

local function text( value, limit )
	return value == nil or type( value ) == "string" and #value <= limit
end

local function number( value )
	return type( value ) == "number" and value == value and value > -1e9 and value < 1e9
end

-- Player-adjustable effect settings. Values are stored per pack under DATA,
-- never as convars; array order is the display order.
local function validateSettings( def )
	if def.settingGroups == nil then def.settingGroups = {} end
	if def.settings == nil then def.settings = {} end
	local groups = {}
	array( def.settingGroups, 32, "setting_groups" )
	for _, group in ipairs( def.settingGroups ) do
		fields( group, { id = true, label = true, labelZH = true }, "setting_group" )
		if not localID( group.id ) or groups[group.id] or not text( group.label, 128 ) or not text( group.labelZH, 128 ) then
			reject( "invalid_setting_group" )
		end
		groups[group.id] = true
	end
	local keys = {}
	array( def.settings, 128, "settings" )
	for _, spec in ipairs( def.settings ) do
		fields( spec, { key = true, group = true, type = true, default = true, min = true, max = true, integer = true,
			choices = true, label = true, labelZH = true, help = true, helpZH = true }, "setting" )
		if not localID( spec.key ) or keys[spec.key] then reject( "invalid_setting_key" ) end
		keys[spec.key] = true
		if spec.group ~= nil and not groups[spec.group] then reject( "unknown_setting_group:" .. spec.key ) end
		if not text( spec.label, 128 ) or not text( spec.labelZH, 128 ) or not text( spec.help, 512 ) or not text( spec.helpZH, 512 ) then
			reject( "invalid_setting_text:" .. spec.key )
		end
		if spec.type == "bool" then
			if type( spec.default ) ~= "boolean" or spec.min ~= nil or spec.max ~= nil or spec.choices ~= nil or spec.integer ~= nil then
				reject( "invalid_bool_setting:" .. spec.key )
			end
		elseif spec.type == "number" then
			if not number( spec.min ) or not number( spec.max ) or spec.min >= spec.max or not number( spec.default )
				or spec.default < spec.min or spec.default > spec.max or spec.choices ~= nil
				or spec.integer ~= nil and type( spec.integer ) ~= "boolean" then
				reject( "invalid_number_setting:" .. spec.key )
			end
		elseif spec.type == "choice" then
			if spec.min ~= nil or spec.max ~= nil or spec.integer ~= nil then reject( "invalid_choice_setting:" .. spec.key ) end
			local found = false
			if array( spec.choices, 16, "setting_choices" ) == 0 then reject( "empty_setting_choices:" .. spec.key ) end
			for _, choice in ipairs( spec.choices ) do
				fields( choice, { value = true, label = true, labelZH = true }, "setting_choice" )
				if not number( choice.value ) or not text( choice.label, 128 ) or not text( choice.labelZH, 128 ) then
					reject( "invalid_setting_choice:" .. spec.key )
				end
				found = found or choice.value == spec.default
			end
			if not found then reject( "invalid_choice_default:" .. spec.key ) end
		else
			reject( "invalid_setting_type:" .. spec.key )
		end
	end
end

local function validate( def )
	fields( def, { schema = true, name = true, build = true, abi = true,
		layout = true, adapter = true, programs = true, resources = true,
		passes = true, implements = true, materialMaps = true, settings = true, settingGroups = true }, "definition" )
	if def.schema ~= Schema.VERSION then reject( "unsupported_descriptor_schema" ) end
	if type( def.name ) ~= "string" or #def.name == 0 or #def.name > 128 then reject( "invalid_name" ) end
	if not hash( def.build ) then reject( "invalid_build_fingerprint" ) end
	if not positiveInteger( def.abi ) or not Schema.IsID( def.layout )
		or not Schema.IsID( def.adapter ) then reject( "invalid_compatibility" ) end
	if map( def.programs, localID, 64, "programs" ) == 0 then reject( "empty_programs" ) end
	for _, program in pairs( def.programs ) do
		fields( program, { vertex = true, pixel = true, vertexHash = true, pixelHash = true }, "program" )
		for _, stage in ipairs( { "vertex", "pixel" } ) do
			local name = program[stage]
			if type( name ) ~= "string" or #name > 128 or not name:match( "^[a-z0-9_]+$" )
				or not name:match( stage == "vertex" and "_vs30$" or "_ps30$" )
				or not hash( program[stage .. "Hash"] ) then reject( "invalid_program:" .. stage ) end
		end
	end
	if def.resources == nil then def.resources = {} end
	-- Atlas variants plus standalone albedo/normal/ORM sets can exceed 64
	-- descriptors; loaded files and GPU texture versions keep separate budgets.
	map( def.resources, localID, 128, "resources" )
	for _, resource in pairs( def.resources ) do
		fields( resource, { path = true, sha256 = true, colorSpace = true }, "texture" )
		if not texturePath( resource.path ) or not hash( resource.sha256 )
			or ( resource.colorSpace ~= "linear" and resource.colorSpace ~= "srgb" ) then
			reject( "invalid_texture" )
		end
	end
	if def.materialMaps == nil then def.materialMaps = {} end
	map( def.materialMaps, localID, 64, "material_maps" )
	for _, material in pairs( def.materialMaps ) do
		fields( material, { albedo = true, normal = true, orm = true }, "material_map" )
		for _, semantic in ipairs( { "albedo", "normal", "orm" } ) do
			local resource = material[semantic]
			if not localID( resource ) or not def.resources[resource] then reject( "missing_material_map_resource" ) end
		end
	end
	validateSettings( def )
	if map( def.passes, localID, 64, "passes" ) == 0 then reject( "empty_passes" ) end
	for _, pass in pairs( def.passes ) do
		fields( pass, { stage = true, program = true, inputs = true }, "pass" )
		if not stages[pass.stage] or not localID( pass.program ) or not def.programs[pass.program] then
			reject( "invalid_pass_program_or_stage" )
		end
		if pass.inputs == nil then pass.inputs = {} end
		map( pass.inputs, localID, 8, "inputs" )
		for _, resource in pairs( pass.inputs ) do
			if not localID( resource ) or not def.resources[resource] then reject( "missing_pass_resource" ) end
		end
	end
	if map( def.implements, Schema.IsID, 64, "implements" ) == 0 then reject( "empty_implements" ) end
	for _, implementation in pairs( def.implements ) do
		fields( implementation, { contract = true, passes = true }, "implementation" )
		if not positiveInteger( implementation.contract ) then reject( "invalid_contract" ) end
		if array( implementation.passes, 32, "implementation_passes" ) == 0 then reject( "empty_implementation" ) end
		local seen, previousStage = {}, 0
		for _, name in ipairs( implementation.passes ) do
			if not localID( name ) or not def.passes[name] or seen[name] then reject( "invalid_implementation_pass" ) end
			seen[name] = true
			local stage = stages[def.passes[name].stage]
			if stage < previousStage then reject( "pass_stage_order" ) end
			previousStage = stage
		end
	end
	return def
end

function Schema.Normalize( input )
	local def, err = Schema.Copy( input )
	if not def then return nil, err or "invalid_definition" end
	local ok, result = pcall( validate, def )
	if not ok then return nil, result end
	-- Defaults must fit the same limits as public snapshots returned later.
	local bounded, limitError = Schema.Copy( result )
	if not bounded then return nil, limitError end
	return result, Schema.Canonical( result )
end

function Schema.Requests( input )
	local requests, err = Schema.Copy( input )
	if not requests then return nil, err or "invalid_requests" end
	local ok, result = pcall( function()
		if map( requests, localID, 128, "requests" ) == 0 then reject( "empty_requests" ) end
		for _, request in pairs( requests ) do
			fields( request, { interface = true, contract = true, shader = true }, "request" )
			if not Schema.IsID( request.interface ) or not positiveInteger( request.contract )
				or ( request.shader ~= nil and not Schema.IsID( request.shader ) ) then reject( "invalid_request" ) end
		end
		return requests
	end )
	if not ok then return nil, result end
	return result
end
