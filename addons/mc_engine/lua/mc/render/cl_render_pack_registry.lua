-- L2 cold-path catalog, separate from the production shader variant registry.
MC = MC or {}
local Catalog = MC.RenderPackRegistry or {}
MC.RenderPackRegistry = Catalog
local Schema = MC.RenderPackSchema
local state = Catalog._state or {
	pack = {}, shader = {}, claims = {}, count = 0, claimCount = 0, generation = 0,
}
Catalog._state = state
state.builds = state.builds or {}
state.buildCount = state.buildCount or 0

local function copy( value )
	return Schema.Copy( value )
end

local function compatible( left, right )
	return left.abi == right.abi and left.layout == right.layout and left.adapter == right.adapter
end

local function claimsFor( def )
	local claims = {}
	local binding = Schema.Canonical( { abi = def.abi, layout = def.layout, adapter = def.adapter } )
	for _, program in pairs( def.programs ) do
		for _, stage in ipairs( { "vertex", "pixel" } ) do
			local key = "shaders/fxc/" .. program[stage] .. ".vcs"
			local signature = program[stage .. "Hash"] .. binding
			if claims[key] and claims[key] ~= signature then return nil, "program_conflict:" .. key end
			claims[key] = signature
		end
	end
	for _, resource in pairs( def.resources ) do
		local key = resource.path
		if claims[key] and claims[key] ~= resource.sha256 then return nil, "texture_conflict:" .. key end
		claims[key] = resource.sha256
	end
	return claims
end

local function register( kind, id, input, source, expectedBuild, builtin )
	if kind ~= "pack" and kind ~= "shader" then return false, "invalid_catalog_kind" end
	if not Schema.IsID( id ) then return false, "invalid_render_id" end
	if id:sub( 1, 3 ) == "mc:" and not builtin then return false, "reserved_render_namespace" end
	if builtin and id:sub( 1, 3 ) ~= "mc:" then return false, "invalid_builtin_namespace" end
	local def, canonical = Schema.Normalize( input )
	if not def then return false, canonical end
	if kind == "shader" and def.pipeline then return false, "processing_requires_pack_owner" end
	source = type( source ) == "string" and source or "unknown"
	local previous = state[kind][id]
	if expectedBuild ~= nil then
		if not previous then return false, "update_missing_definition" end
		if previous.definition.build ~= expectedBuild then return false, "stale_definition_update" end
	end
	if previous then
		if previous.canonical == canonical then return true, "unchanged" end
		if expectedBuild == nil then
			return false, "duplicate_render_id:" .. id .. " first=" .. previous.source .. " incoming=" .. source
		end
		if previous.definition.build == def.build then return false, "changed_definition_same_build" end
	elseif state.count >= 256 then
		return false, "catalog_definition_limit"
	end
	local buildKey = kind .. "/" .. id .. "/" .. def.build
	local knownBuild = state.builds[buildKey]
	if knownBuild and knownBuild ~= canonical then return false, "build_identity_conflict" end
	if not knownBuild and state.buildCount >= 1024 then return false, "catalog_build_limit" end
	local claims, err = claimsFor( def )
	if not claims then return false, err end
	local added = 0
	for path, signature in pairs( claims ) do
		local existing = state.claims[path]
		if existing and existing.signature ~= signature then
			return false, "resource_name_conflict:" .. path .. " first=" .. existing.source .. " incoming=" .. source
		end
		if not existing then added = added + 1 end
	end
	if state.claimCount + added > 4096 then return false, "catalog_resource_limit" end
	-- Commit only after every check. Keep historical physical-name claims:
	-- the engine can cache old binaries even after their Lua owners are gone.
	for path, signature in pairs( claims ) do
		if not state.claims[path] then state.claims[path] = { signature = signature, source = source } end
	end
	state.claimCount = state.claimCount + added
	if not knownBuild then
		state.builds[buildKey] = canonical
		state.buildCount = state.buildCount + 1
	end
	if not previous then state.count = state.count + 1 end
	state.generation = state.generation + 1
	state[kind][id] = { definition = def, canonical = canonical, source = source, revision = state.generation }
	return true, previous and "updated" or "registered"
end

function Catalog.Register( kind, id, input, source, expectedBuild )
	return register( kind, id, input, source, expectedBuild, false )
end

-- Engine-only entry point; the public API always rejects the reserved namespace.
function Catalog.RegisterBuiltin( kind, id, input, expectedBuild, source )
	return register( kind, id, input, source or "mc_engine/builtin", expectedBuild, true )
end

function Catalog.Get( kind, id )
	if kind ~= "pack" and kind ~= "shader" then return nil, "invalid_catalog_kind" end
	if not Schema.IsID( id ) then return nil, "invalid_render_id" end
	local entry = state[kind][id]
	if not entry then return nil, "render_definition_missing:" .. id end
	return copy( entry.definition )
end

function Catalog.Revision( kind, id )
	local entries = state[kind]
	local entry = entries and entries[id]
	return entry and entry.revision
end

function Catalog.List( kind )
	local result = {}
	for id, entry in pairs( state[kind] ) do
		result[#result + 1] = { id = id, name = entry.definition.name, build = entry.definition.build,
			source = entry.source, revision = entry.revision }
	end
	table.sort( result, function( a, b ) return a.id < b.id end )
	return result
end

function Catalog.Status()
	return { schema = Schema.VERSION, generation = state.generation,
		definitions = state.count, resourceNames = state.claimCount, builds = state.buildCount, gpuReady = false,
		phase = "catalog_only" }
end

function Catalog.Plan( packID, input )
	if not Schema.IsID( packID ) then return nil, "invalid_render_id" end
	local pack = state.pack[packID]
	if not pack then return nil, "render_pack_missing:" .. packID end
	local requests, err = Schema.Requests( input )
	if not requests then return nil, err end
	local plan = { pack = packID, generation = state.generation, gpuReady = false,
		phase = "metadata_only", owners = {}, requests = {} }
	local keys = {}
	for key in pairs( requests ) do keys[#keys + 1] = key end
	table.sort( keys )
	local function owner( kind, id, entry )
		local key = kind .. "/" .. id
		if not plan.owners[key] then
			plan.owners[key] = { id = id, kind = kind, revision = entry.revision,
				definition = copy( entry.definition ) }
		end
		return key
	end
	owner( "pack", packID, pack )
	for _, key in ipairs( keys ) do
		local request = requests[key]
		local entry, kind, id = pack, "pack", packID
		if request.shader then
			kind, id = "shader", request.shader
			entry = state.shader[id]
			if not entry then return nil, "explicit_shader_missing:" .. id end
			if not compatible( pack.definition, entry.definition ) then return nil, "explicit_shader_incompatible:" .. id end
		end
		local implementation = entry.definition.implements[request.interface]
		if not implementation or implementation.contract ~= request.contract then
			return nil, "interface_not_implemented:" .. id .. ":" .. request.interface
		end
		plan.requests[key] = { owner = owner( kind, id, entry ), interface = request.interface,
			contract = request.contract, passes = copy( implementation.passes ), explicit = request.shader ~= nil }
	end
	return plan
end

function Catalog.IsCurrent( plan )
	for _, owner in pairs( plan.owners ) do
		local entry = state[owner.kind][owner.id]
		if not entry or entry.revision ~= owner.revision then return false end
	end
	return true
end

MC.API = MC.API or {}
MC.API.Render = MC.API.Render or {}
local API = MC.API.Render

local function callerSource()
	local info = debug.getinfo( 3, "Sl" )
	return info and ( info.short_src .. ":" .. info.currentline ) or "unknown"
end

function API.RegisterPack( id, definition )
	return Catalog.Register( "pack", id, definition, callerSource() )
end

function API.RegisterShader( id, definition )
	return Catalog.Register( "shader", id, definition, callerSource() )
end

function API.UpdatePack( id, definition, expectedBuild )
	if type( expectedBuild ) ~= "string" then return false, "expected_build_required" end
	return Catalog.Register( "pack", id, definition, callerSource(), expectedBuild )
end

function API.UpdateShader( id, definition, expectedBuild )
	if type( expectedBuild ) ~= "string" then return false, "expected_build_required" end
	return Catalog.Register( "shader", id, definition, callerSource(), expectedBuild )
end

function API.GetPack( id ) return Catalog.Get( "pack", id ) end
function API.GetShader( id ) return Catalog.Get( "shader", id ) end
function API.ListPacks() return Catalog.List( "pack" ) end
function API.ListShaders() return Catalog.List( "shader" ) end
function API.PlanPack( id, requests ) return Catalog.Plan( id, requests ) end
function API.GetPackStatus() return Catalog.Status() end

concommand.Add( "mc_render_packs", function()
	local status = Catalog.Status()
	print( string.format( "[MC packs] phase=%s generation=%d definitions=%d resourceNames=%d gpuReady=false",
		status.phase, status.generation, status.definitions, status.resourceNames ) )
	for _, kind in ipairs( { "pack", "shader" } ) do
		for _, entry in ipairs( Catalog.List( kind ) ) do
			print( string.format( "[MC packs] %s %s build=%s source=%s",
				kind, entry.id, entry.build, entry.source ) )
		end
	end
end )
