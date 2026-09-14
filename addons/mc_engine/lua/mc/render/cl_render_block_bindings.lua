-- Client render selection does not alter shared block/world properties.
MC = MC or {}
local B = MC.RenderBlockBindings or { definitions = {}, generation = 0 }
MC.RenderBlockBindings = B
local Schema = MC.RenderPackSchema
local DEFAULT = { interface = "mc:terrain", contract = 1 }

function B.Get( id )
	return B.definitions[id] or DEFAULT
end

function B.Key( id )
	return B.definitions[id] and ( "block_" .. id ) or "terrain"
end

function B.Snapshot()
	local requests = { terrain = DEFAULT }
	local keys = {}
	for id, request in pairs( B.definitions ) do
		keys[id] = "block_" .. id
		requests[keys[id]] = request
	end
	local snapshot, err = Schema.Copy( requests )
	if not snapshot then return nil, err end
	return snapshot, keys, B.generation
end

local function bind( id, request, expected )
	if type( id ) ~= "number" or id < 1 or id ~= math.floor( id ) or not MC.Blocks[id] then
		return false, "invalid_block_id"
	end
	local requests, err = Schema.Requests( { block = request } )
	if not requests then return false, err end
	local value, previous = requests.block, B.definitions[id]
	local canonical = Schema.Canonical( value )
	if expected ~= nil and ( not previous or Schema.Canonical( previous ) ~= expected ) then
		return false, "stale_block_render_binding"
	end
	if previous then
		if Schema.Canonical( previous ) == canonical then return true, canonical end
		if expected == nil then return false, "duplicate_block_render_binding" end
	else
		local count = 0
		for _ in pairs( B.definitions ) do count = count + 1 end
		if count >= 127 then return false, "block_render_binding_limit" end
	end
	B.definitions[id] = value
	B.generation = B.generation + 1
	return true, canonical
end

function MC.API.Render.BindBlock( id, request )
	return bind( id, request )
end

function MC.API.Render.UpdateBlockBinding( id, request, expected )
	if type( expected ) ~= "string" then return false, "expected_binding_required" end
	return bind( id, request, expected )
end

function MC.API.Render.GetBlockBinding( id )
	if type( id ) ~= "number" or not MC.Blocks[id] then return nil, "invalid_block_id" end
	local definition = B.Get( id )
	local result, err = Schema.Copy( definition )
	if not result then return nil, err end
	return result, Schema.Canonical( definition )
end
