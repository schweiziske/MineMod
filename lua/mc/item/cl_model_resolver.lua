--[[----------------------------------------------------------------------------
    Client-side resolver for Minecraft's item-model definition tree.

    The generated catalog contains the vanilla model/condition/range/select/
    composite graph.  This module turns a stack plus a small render context
    into a cached list of flat texture layers.  Unknown properties and special
    renderers deliberately fall back instead of inventing geometry.
------------------------------------------------------------------------------]]

if not CLIENT then return end

MC = MC or {}
MC.ItemModelResolver = MC.ItemModelResolver or {}

local Resolver = MC.ItemModelResolver
local staticCache = {}
local staticCacheCount = 0
local MAX_CACHE = 2048

local function finite( value )
	return type( value ) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function definitionFor( stackOrDefinition )
	if type( stackOrDefinition ) == "table" and stackOrDefinition.name and not stackOrDefinition.item then
		return stackOrDefinition
	end
	local item = type( stackOrDefinition ) == "table" and stackOrDefinition.item or stackOrDefinition
	return MC.GetItem and MC.GetItem( item ) or nil
end

local function componentsFor( stack, definition )
	if type( stack ) == "table" and type( stack.components ) == "table" then return stack.components end
	if type( definition ) == "table" and type( definition.components ) == "table" then return definition.components end
	return nil
end

local function componentValue( stack, definition, key )
	local components = componentsFor( stack, definition )
	if not components then return nil end
	local value = components[key]
	if value == nil and string.find( key, ":", 1, true ) == nil then value = components["minecraft:" .. key] end
	return value
end

local function propertyValue( property, stack, definition, options )
	options = options or {}
	local supplied = options.properties
	if type( supplied ) == "table" and supplied[property] ~= nil then return supplied[property] end
	if type( options[property] ) ~= "nil" then return options[property] end

	if property == "minecraft:using_item" then return options.using == true end
	if property == "minecraft:broken" then
		local maxDamage = tonumber( definition and definition.maxDamage ) or 0
		return maxDamage > 0 and ( tonumber( stack and stack.damage ) or 0 ) >= maxDamage
	end
	if property == "minecraft:damage" or property == "minecraft:damage_fraction" then
		local maxDamage = tonumber( definition and definition.maxDamage ) or 0
		if maxDamage <= 0 then return 0 end
		return math.Clamp( ( tonumber( stack and stack.damage ) or 0 ) / maxDamage, 0, 1 )
	end
	if property == "minecraft:use_duration" then
		if finite( options.useDuration ) then return options.useDuration end
		if finite( options.useProgress ) then return math.Clamp( options.useProgress, 0, 1 ) end
		return 0
	end
	if property == "minecraft:use_cycle" then
		if finite( options.useCycle ) then return options.useCycle end
		if finite( options.useProgress ) then return math.Clamp( options.useProgress, 0, 1 ) end
		return 0
	end
	if property == "minecraft:custom_model_data" then
		return options.customModelData ~= nil and options.customModelData or componentValue( stack, definition, property )
	end
	if property == "minecraft:has_component" then
		local component = options.component or options.hasComponent
		if component ~= nil then return component == true end
		-- The generated condition does not carry a component name in older
		-- resource versions; an explicit context is therefore required.
		return options.hasComponent == true
	end
	if property == "minecraft:context_dimension" then return options.dimension or "minecraft:overworld" end
	if property == "minecraft:charge_type" then
		return options.chargeType or componentValue( stack, definition, property)
	end
	if property == "minecraft:time" then
		if finite( options.time ) then return options.time end
		return 0
	end
	if property == "minecraft:crossbow/pull" then
		if finite( options.crossbowPull ) then return options.crossbowPull end
		return finite( options.useProgress ) and math.Clamp( options.useProgress, 0, 1 ) or 0
	end
	if property == "minecraft:compass" then return options.compass or 0 end
	if property == "minecraft:bundle/fullness" then return options.fullness or 0 end
	return componentValue( stack, definition, property )
end

local function sameWhen( value, when )
	if type( when ) == "table" then
		for _, candidate in ipairs( when ) do if sameWhen( value, candidate ) then return true end end
		return false
	end
	return value ~= nil and tostring( value ) == tostring( when )
end

local function emptyPlan()
	return { layers = {}, modelId = nil, kind = "missing", handheld = false, display = nil }
end

local function appendLayers( target, source )
	for _, layer in ipairs( source.layers or {} ) do
		if type( layer ) == "string" and #layer > 0 and #target < 8 then target[#target + 1] = layer end
	end
end

local function mergePlans( plans )
	local result = emptyPlan()
	result.kind = "flat"
	for _, plan in ipairs( plans ) do
		if plan then
			appendLayers( result.layers, plan )
			result.modelId = result.modelId or plan.modelId
			result.handheld = result.handheld or plan.handheld == true
			result.display = result.display or plan.display
			if plan.kind == "special" and result.kind == "flat" then result.kind = "special" end
			if plan.kind == "block" and #result.layers == 0 then result.kind = "block" end
		end
	end
	return result
end

local function resolveNode( node, stack, definition, options, depth )
	if type( node ) ~= "table" or depth > 32 then return emptyPlan() end
	local nodeType = node.t
	if nodeType == "model" then
		local modelId = tostring( node.m or "" )
		local file = MC.GetItemModelFile and MC.GetItemModelFile( modelId ) or nil
		if not file then
			return { layers = {}, modelId = modelId ~= "" and modelId or nil,
				kind = string.find( modelId, ":block/", 1, true ) and "block" or "missing" }
		end
		local plan = {
			layers = {}, modelId = modelId, kind = file.kind or "missing",
			handheld = file.handheld == true, display = file.display,
		}
		appendLayers( plan.layers, file )
		return plan
	end
	if nodeType == "condition" then
		local value = propertyValue( tostring( node.p or "" ), stack, definition, options )
		local truth = value == true
		return resolveNode( truth and node.y or node.n, stack, definition, options, depth + 1 )
	end
	if nodeType == "range" then
		local value = tonumber( propertyValue( tostring( node.p or "" ), stack, definition, options ) ) or 0
		value = value * ( tonumber( node.s ) or 1 )
		local selected
		for _, entry in ipairs( node.e or {} ) do
			if tonumber( entry.v ) and value >= tonumber( entry.v ) then selected = entry.n else break end
		end
		return resolveNode( selected or node.f, stack, definition, options, depth + 1 )
	end
	if nodeType == "select" then
		local value = propertyValue( tostring( node.p or "" ), stack, definition, options )
		for _, case in ipairs( node.c or {} ) do
			if sameWhen( value, case.w ) then return resolveNode( case.n, stack, definition, options, depth + 1 ) end
		end
		return resolveNode( node.f, stack, definition, options, depth + 1 )
	end
	if nodeType == "composite" then
		local plans = {}
		for _, child in ipairs( node.n or {} ) do plans[#plans + 1] = resolveNode( child, stack, definition, options, depth + 1 ) end
		return mergePlans( plans )
	end
	if nodeType == "special" then
		return { layers = {}, modelId = node.b, kind = "special", special = node.m }
	end
	return emptyPlan()
end

local function cacheKey( stack, definition, options )
	if type( options ) == "table" and ( type( options.properties ) == "table" or options.time ~= nil
		or options.compass ~= nil or options.fullness ~= nil or options.useProgress ~= nil ) then return nil end
	local context = tostring( options and options.displayContext or "gui" )
	local using = options and options.using == true and "1" or "0"
	local broken = options and options.broken == true and "1" or "0"
	return table.concat( { definition and definition.name or "", tostring( stack and stack.damage or 0 ), context, using, broken }, "|" )
end

function Resolver.Resolve( stackOrDefinition, options )
	options = options or {}
	local definition = definitionFor( stackOrDefinition )
	if not definition then return emptyPlan() end
	local stack = type( stackOrDefinition ) == "table" and stackOrDefinition.item and stackOrDefinition or nil
	local key = cacheKey( stack, definition, options )
	if key and staticCache[key] then return staticCache[key] end
	local root = MC.GetItemModelDefinition and MC.GetItemModelDefinition( definition ) or nil
	local plan = root and resolveNode( root, stack, definition, options, 0 ) or emptyPlan()
	if #plan.layers == 0 and definition.texture then
		plan.layers = { definition.texture }
		plan.kind = "flat"
	end
	if key then
		if staticCacheCount >= MAX_CACHE then staticCache, staticCacheCount = {}, 0 end
		staticCache[key], staticCacheCount = plan, staticCacheCount + 1
	end
	return plan
end

function Resolver.ClearCache()
	staticCache, staticCacheCount = {}, 0
end

function MC.ResolveItemModel( stackOrDefinition, options ) return Resolver.Resolve( stackOrDefinition, options ) end

