--[[----------------------------------------------------------------------------
	MC : block update behavior registry.

	State storage describes what a block is. This registry attaches server-side
	behavior to a block-state family without putting callbacks on every state.
	The scheduler resolves names to state handlers lazily and caches by stateId.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.BlockUpdateKind = MC.BlockUpdateKind or {
	NEIGHBOR = 1,
	SCHEDULED = 2,
}

local Kind = MC.BlockUpdateKind
local CallbackByKind = {
	[Kind.NEIGHBOR] = "OnNeighborUpdate",
	[Kind.SCHEDULED] = "OnScheduledTick",
}

local HandlerByName = {}
local HandlerByState = {}
local StateHandlerByKey = {}
local StateHandlerOrder = {}
local HandlerCountByKind = {
	[Kind.NEIGHBOR] = 0,
	[Kind.SCHEDULED] = 0,
}

local function normalizeBlockName( value )
	local name = string.lower( string.match( tostring( value or "" ), "^%s*(.-)%s*$" ) )
	if name == "" then return nil end
	if not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	if not string.match( name, "^[a-z0-9_.-]+:[a-z0-9_./-]+$" ) then return nil end
	return name
end

local function normalizeDefinition( name, definition )
	if type( definition ) ~= "table" then return nil, "invalid_handler" end
	local neighbor = definition.OnNeighborUpdate
	local scheduled = definition.OnScheduledTick
	if neighbor ~= nil and type( neighbor ) ~= "function" then return nil, "invalid_neighbor_handler" end
	if scheduled ~= nil and type( scheduled ) ~= "function" then return nil, "invalid_scheduled_handler" end
	if neighbor == nil and scheduled == nil then return nil, "empty_handler" end
	return {
		name = name,
		OnNeighborUpdate = neighbor,
		OnScheduledTick = scheduled,
	}
end

local function removeHandlerCount( handler )
	if not handler then return end
	if handler.OnNeighborUpdate then HandlerCountByKind[Kind.NEIGHBOR] = HandlerCountByKind[Kind.NEIGHBOR] - 1 end
	if handler.OnScheduledTick then HandlerCountByKind[Kind.SCHEDULED] = HandlerCountByKind[Kind.SCHEDULED] - 1 end
end

local function addHandlerCount( handler )
	if handler.OnNeighborUpdate then HandlerCountByKind[Kind.NEIGHBOR] = HandlerCountByKind[Kind.NEIGHBOR] + 1 end
	if handler.OnScheduledTick then HandlerCountByKind[Kind.SCHEDULED] = HandlerCountByKind[Kind.SCHEDULED] + 1 end
end

function MC.IsBlockUpdateKind( kind )
	return CallbackByKind[tonumber( kind )] ~= nil
end

function MC.BlockUpdateCallbackName( kind )
	return CallbackByKind[tonumber( kind )]
end

function MC.HasBlockUpdateHandlers( kind )
	return ( HandlerCountByKind[tonumber( kind )] or 0 ) > 0
end

function MC.RegisterBlockUpdateHandler( blockName, definition )
	local name = normalizeBlockName( blockName )
	if not name then return nil, "invalid_block_name" end
	local handler, err = normalizeDefinition( name, definition )
	if not handler then return nil, err end
	local previous = HandlerByName[name]
	removeHandlerCount( previous )
	HandlerByName[name] = handler
	addHandlerCount( handler )
	-- Registrations are cold-path operations. Replacing the cache keeps hot-path
	-- state lookups to one table access after the first resolution.
	HandlerByState = {}
	return handler
end

function MC.UnregisterBlockUpdateHandler( blockName )
	local name = normalizeBlockName( blockName )
	local previous = name and HandlerByName[name] or nil
	if not previous then return false end
	removeHandlerCount( previous )
	HandlerByName[name] = nil
	HandlerByState = {}
	return true
end

-- State handlers cover cross-block families such as water FluidStates, where
-- the same behavior belongs to minecraft:water and every waterlogged state.
function MC.RegisterBlockUpdateStateHandler( key, matcher, definition )
	key = tostring( key or "" )
	if key == "" then return nil, "invalid_handler_key" end
	if type( matcher ) ~= "function" then return nil, "invalid_state_matcher" end
	local handler, err = normalizeDefinition( key, definition )
	if not handler then return nil, err end
	handler.MatchState = matcher
	local previous = StateHandlerByKey[key]
	if previous then
		removeHandlerCount( previous )
		for index = 1, #StateHandlerOrder do
			if StateHandlerOrder[index] == previous then StateHandlerOrder[index] = handler break end
		end
	else
		StateHandlerOrder[#StateHandlerOrder + 1] = handler
	end
	StateHandlerByKey[key] = handler
	addHandlerCount( handler )
	HandlerByState = {}
	return handler
end

function MC.UnregisterBlockUpdateStateHandler( key )
	key = tostring( key or "" )
	local previous = StateHandlerByKey[key]
	if not previous then return false end
	removeHandlerCount( previous )
	StateHandlerByKey[key] = nil
	for index = 1, #StateHandlerOrder do
		if StateHandlerOrder[index] == previous then table.remove( StateHandlerOrder, index ) break end
	end
	HandlerByState = {}
	return true
end

function MC.BlockUpdateHandlerForState( stateId )
	stateId = tonumber( stateId )
	if stateId == nil then return nil end
	local cached = HandlerByState[stateId]
	if cached ~= nil then return cached or nil end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local handler = schema and HandlerByName[schema.name] or nil
	if not handler and schema then
		for index = 1, #StateHandlerOrder do
			local candidate = StateHandlerOrder[index]
			if candidate.MatchState( stateId, schema ) == true then
				handler = candidate
				break
			end
		end
	end
	-- Before the state registry freezes, a missing schema may only mean that the
	-- deferred finalization timer has not run yet. Never make that miss permanent.
	if schema or MC.BlockStateRegistryFrozen then HandlerByState[stateId] = handler or false end
	return handler
end

function MC.BlockUpdateHandlerForName( blockName )
	local name = normalizeBlockName( blockName )
	return name and HandlerByName[name] or nil
end
