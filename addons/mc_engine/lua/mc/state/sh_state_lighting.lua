-- Pinned Java registry scalars, independent of visual/material/collision flags.
-- Profiles are borrowed/read-only and indexed by the mixed-radix state ID.
MC = MC or {}
local L = { ready = false }
MC.VanillaStateLighting = L
local floor, byte = math.floor, string.byte
local byCode, stateMap, stateCount = {}, "", 0
local fields = { "emission", "dampening", "emissive", "shade", "viewBlocking", "solidRender", "fullCollision",
	"skyPass", "shapeOcclusion", "dynamicShape", "viewContext", "collisionContext" }

local function integer( value, maximum )
	return type( value ) == "number" and value >= 0 and value <= maximum and value == floor( value )
end

local function initialize()
	local data, metadata = MC.GeneratedStateLighting, MC.GeneratedStateMetadata
	if not MC.Check( type( data ) == "table" and type( metadata ) == "table", "vanilla_state_catalog_missing",
		"generated state lighting and schema metadata must load first" ) then return false end
	if not MC.Check( data.formatVersion == 1 and data.schemaHash == metadata.schemaHash
		and data.minecraftId == metadata.minecraftId and data.stateCount == metadata.stateCount,
		"vanilla_state_catalog_version", "lighting catalog does not match the generated state registry" ) then return false end
	if not MC.Check( type( data.map ) == "string" and #data.map == data.stateCount
		and type( data.fields ) == "table" and #data.fields == #fields and type( data.profiles ) == "table"
		and type( data.alphabet ) == "string" and #data.profiles <= #data.alphabet,
		"vanilla_state_catalog_format", "invalid compact lighting catalog" ) then return false end
	for i = 1, #fields do
		if not MC.Check( data.fields[i] == fields[i], "vanilla_state_catalog_fields", "wrong field at %s", i ) then return false end
	end
	local pending = {}
	for i = 1, #data.profiles do
		local raw, p = data.profiles[i], {}
		if not MC.Check( type( raw ) == "table" and #raw == #fields, "vanilla_state_catalog_profile", "invalid profile %s", i ) then return false end
		for j = 1, #fields do p[fields[j]] = raw[j] end
		local valid = integer( p.emission, 15 ) and integer( p.dampening, 15 )
			and type( p.shade ) == "number" and p.shade >= 0 and p.shade <= 1
		for j = 1, 7 do
			local field = ( { "emissive", "viewBlocking", "solidRender", "fullCollision", "skyPass", "shapeOcclusion", "dynamicShape" } )[j]
			valid = valid and type( p[field] ) == "boolean"
		end
		valid = valid and ( p.viewContext == "none" or p.viewContext == "shulker" )
			and ( p.collisionContext == "none" or p.collisionContext == "shulker" or p.collisionContext == "moving_piston" )
			and ( p.viewContext ~= "shulker" or p.collisionContext == "shulker" )
		local code = byte( data.alphabet, i )
		if not MC.Check( valid and pending[code] == nil, "vanilla_state_catalog_profile", "invalid/duplicate profile %s", i ) then return false end
		pending[code] = p
	end
	for i = 1, #data.map do
		if not MC.Check( pending[byte( data.map, i )] ~= nil, "vanilla_state_catalog_index", "unknown profile for state %s", i - 1 ) then return false end
	end
	byCode, stateMap, stateCount = pending, data.map, data.stateCount
	L.ready, L.stateCount, L.minecraftId, L.schemaHash = true, stateCount, data.minecraftId, data.schemaHash
	MC.GeneratedStateLighting = nil
	return true
end

function L.Contains( stateId )
	return L.ready and integer( stateId, stateCount - 1 )
end

function L.Get( stateId )
	if not MC.Check( L.Contains( stateId ), "vanilla_state_missing", "no pinned lighting properties for state %s", tostring( stateId ) ) then return nil end
	return byCode[byte( stateMap, stateId + 1 )]
end

-- false explicitly means no live block entity. nil is an unknown context.
function L.Resolve( stateId, context, output )
	local p = L.Get( stateId )
	if not p then return nil end
	local kind = p.collisionContext
	if kind == "none" or context == false then return p end
	local full, view = p.fullCollision, p.viewBlocking
	if kind == "shulker" then
		if not MC.Check( type( context ) == "table" and type( context.closed ) == "boolean"
			and type( context.progress ) == "number" and context.progress >= 0 and context.progress <= 1,
			"vanilla_shulker_context", "shulker state %s needs closed status and tick progress", stateId ) then return nil end
		full, view = context.progress == 0, context.closed
	elseif kind == "moving_piston" then
		if not MC.Check( type( context ) == "table" and type( context.fullCollision ) == "boolean",
			"vanilla_piston_context", "moving piston state %s needs contextual collision fullness", stateId ) then return nil end
		full = context.fullCollision
	end
	output = output or {}
	for i = 1, #fields do local field = fields[i] output[field] = p[field] end
	output.fullCollision, output.viewBlocking, output.shade = full, view, full and 0.2 or 1
	return output
end

initialize()

-- L2 also samples addon states, including neighbours of ordinary vanilla faces.
-- Keep the pinned catalog strict; custom profiles follow the registered visual
-- and collision contracts instead of pretending to be a generated Java state.
local Runtime = { ready = L.ready }
MC.StateLighting = Runtime
local customProfiles = {}
local visualRevision, registry
local customDynamicFields = { "fullCube", "hasCollision", "translucent", "lightEmission", "lightOpacity" }

function Runtime.Prepare()
	if registry ~= MC.BlockStateSchemaById or visualRevision ~= MC.BlockStateVisualRevision then
		customProfiles = {}
		registry = MC.BlockStateSchemaById
		visualRevision = MC.BlockStateVisualRevision
	end
	return Runtime.ready
end

function Runtime.Get( stateId, bx, by, bz )
	if L.Contains( stateId ) then return L.Get( stateId ) end
	local cached = customProfiles[stateId]
	if cached then return cached end
	local schema = registry and registry[stateId]
	if not MC.Check( schema and schema.generated ~= true and MC.Blocks[schema.blockId] ~= nil,
		"state_lighting_missing", "no registered custom lighting source for state %s", tostring( stateId ) ) then return nil end
	local visual, err = MC.ResolveBlockStateVisual( stateId, bx, by, bz )
	if not MC.Check( visual ~= nil, "state_lighting_visual", "state %s: %s", stateId, tostring( err ) ) then return nil end
	local full = MC.BlockVisualHasCollision( visual, bx, by, bz )
		and MC.BlockVisualIsFullCube( visual, bx, by, bz )
	local opaque = full and visual.block.transparent ~= true
		and not MC.BlockVisualIsTranslucent( visual, bx, by, bz )
	local emission = MC.BlockVisualLightEmission( visual, bx, by, bz )
	local dampening = MC.BlockVisualLightOpacity( visual, bx, by, bz )
	local visualResolver = MC.BlockStateVisualResolvers[schema.name]
	local collisionResolver = MC.BlockStateCollisionResolvers and MC.BlockStateCollisionResolvers[schema.name]
	local dynamic = visual.cacheable == false
		or ( visualResolver ~= nil and visualResolver.positionDependent == true )
		or ( collisionResolver ~= nil and collisionResolver.positionDependent == true )
		or MC.BlockCollisionDependsOnNeighbours( visual.id )
	-- Function-valued visual properties may depend on coordinates even if the
	-- visual object itself is cached.
	for i = 1, #customDynamicFields do
		dynamic = dynamic or type( visual[customDynamicFields[i]] ) == "function"
	end
	local p = {
		emission = emission, dampening = dampening, emissive = false,
		shade = full and 0.2 or 1, viewBlocking = opaque, solidRender = opaque, fullCollision = full,
		skyPass = dampening == 0, shapeOcclusion = not full, dynamicShape = dynamic,
		viewContext = "none", collisionContext = "none",
	}
	if not dynamic then customProfiles[stateId] = p end
	return p
end

Runtime.Resolve = L.Resolve
