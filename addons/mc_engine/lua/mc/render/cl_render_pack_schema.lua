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

local function validate( def )
	fields( def, { schema = true, name = true, build = true, abi = true,
		layout = true, adapter = true, programs = true, resources = true,
		passes = true, implements = true }, "definition" )
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
	map( def.resources, localID, 64, "resources" )
	for _, resource in pairs( def.resources ) do
		fields( resource, { path = true, sha256 = true, colorSpace = true }, "texture" )
		if not texturePath( resource.path ) or not hash( resource.sha256 )
			or ( resource.colorSpace ~= "linear" and resource.colorSpace ~= "srgb" ) then
			reject( "invalid_texture" )
		end
	end
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
