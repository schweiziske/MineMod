--[[----------------------------------------------------------------------------
	MC : block update behavior registry.

	State storage describes what a block is. This registry attaches server-side
	behavior to a block-state family without putting callbacks on every state.
	The scheduler resolves names to state handlers lazily and caches by stateId.
------------------------------------------------------------------------------]]

MC = MC or {}

MC.BlockUpdateKind = MC.BlockUpdateKind or {}
local Kind = MC.BlockUpdateKind
Kind.NEIGHBOR = 1
Kind.SCHEDULED = 2
Kind.RANDOM = Kind.RANDOM or 3
local CallbackByKind = {
	[Kind.NEIGHBOR] = "OnNeighborUpdate",
	[Kind.SCHEDULED] = "OnScheduledTick",
	[Kind.RANDOM] = "OnRandomTick",
}

local HandlerByName = {}
local HandlerByState = {}
local StateHandlerByKey = {}
local StateHandlerOrder = {}
local HandlerCountByKind = {
	[Kind.NEIGHBOR] = 0,
	[Kind.SCHEDULED] = 0,
	[Kind.RANDOM] = 0,
}
local ListenerByKindState = {}

local function invalidateListenerCache()
	ListenerByKindState = {}
end

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
	local random = definition.OnRandomTick
	if neighbor ~= nil and type( neighbor ) ~= "function" then return nil, "invalid_neighbor_handler" end
	if scheduled ~= nil and type( scheduled ) ~= "function" then return nil, "invalid_scheduled_handler" end
	if random ~= nil and type( random ) ~= "function" then return nil, "invalid_random_handler" end
	if neighbor == nil and scheduled == nil and random == nil then return nil, "empty_handler" end
	return {
		name = name,
		OnNeighborUpdate = neighbor,
		OnScheduledTick = scheduled,
		OnRandomTick = random,
	}
end

local function removeHandlerCount( handler )
	if not handler then return end
	if handler.OnNeighborUpdate then HandlerCountByKind[Kind.NEIGHBOR] = HandlerCountByKind[Kind.NEIGHBOR] - 1 end
	if handler.OnScheduledTick then HandlerCountByKind[Kind.SCHEDULED] = HandlerCountByKind[Kind.SCHEDULED] - 1 end
	if handler.OnRandomTick then HandlerCountByKind[Kind.RANDOM] = HandlerCountByKind[Kind.RANDOM] - 1 end
end

local function addHandlerCount( handler )
	if handler.OnNeighborUpdate then HandlerCountByKind[Kind.NEIGHBOR] = HandlerCountByKind[Kind.NEIGHBOR] + 1 end
	if handler.OnScheduledTick then HandlerCountByKind[Kind.SCHEDULED] = HandlerCountByKind[Kind.SCHEDULED] + 1 end
	if handler.OnRandomTick then HandlerCountByKind[Kind.RANDOM] = HandlerCountByKind[Kind.RANDOM] + 1 end
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
	invalidateListenerCache()
	return handler
end

function MC.UnregisterBlockUpdateHandler( blockName )
	local name = normalizeBlockName( blockName )
	local previous = name and HandlerByName[name] or nil
	if not previous then return false end
	removeHandlerCount( previous )
	HandlerByName[name] = nil
	HandlerByState = {}
	invalidateListenerCache()
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
	invalidateListenerCache()
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
	invalidateListenerCache()
	return true
end

-- Observers are additive listeners. A block has at most ONE handler - that slot
-- is the block's canonical behavior and registering over it replaces it - but
-- any number of observers, which run afterwards in registration order.
--
-- This is what lets a separately shipped game layer attach behavior to engine
-- blocks (a scheduled tick on wheat, a neighbor reaction on water) without
-- displacing the engine's own handler for them. Observers get the same result
-- contract as handlers, so each one may return its own cells/schedule/updates.
--
-- Dispatch is per-state and cached, so states nobody observes cost one table
-- lookup and blocks with no listeners never enter the queue at all.
local ObserverByKey = {}
local ObserverOrder = {}
local ObserversByState = {}
local ObserverCountByKind = {
	[Kind.NEIGHBOR] = 0,
	[Kind.SCHEDULED] = 0,
	[Kind.RANDOM] = 0,
}

local function removeObserverCount( observer )
	if not observer then return end
	if observer.OnNeighborUpdate then ObserverCountByKind[Kind.NEIGHBOR] = ObserverCountByKind[Kind.NEIGHBOR] - 1 end
	if observer.OnScheduledTick then ObserverCountByKind[Kind.SCHEDULED] = ObserverCountByKind[Kind.SCHEDULED] - 1 end
	if observer.OnRandomTick then ObserverCountByKind[Kind.RANDOM] = ObserverCountByKind[Kind.RANDOM] - 1 end
end

local function addObserverCount( observer )
	if observer.OnNeighborUpdate then ObserverCountByKind[Kind.NEIGHBOR] = ObserverCountByKind[Kind.NEIGHBOR] + 1 end
	if observer.OnScheduledTick then ObserverCountByKind[Kind.SCHEDULED] = ObserverCountByKind[Kind.SCHEDULED] + 1 end
	if observer.OnRandomTick then ObserverCountByKind[Kind.RANDOM] = ObserverCountByKind[Kind.RANDOM] + 1 end
end

-- match is either a block name ("minecraft:wheat") or a
-- function( stateId, schema ) predicate for cross-block families.
function MC.RegisterBlockUpdateObserver( key, match, definition )
	key = tostring( key or "" )
	if key == "" then return nil, "invalid_observer_key" end
	local matcher
	if isfunction( match ) then
		matcher = match
	else
		local name = normalizeBlockName( match )
		if not name then return nil, "invalid_block_name" end
		matcher = function( _, schema ) return schema ~= nil and schema.name == name end
	end
	local observer, err = normalizeDefinition( key, definition )
	if not observer then return nil, err end
	observer.MatchState = matcher

	local previous = ObserverByKey[key]
	if previous then
		removeObserverCount( previous )
		for index = 1, #ObserverOrder do
			if ObserverOrder[index] == previous then ObserverOrder[index] = observer break end
		end
	else
		ObserverOrder[#ObserverOrder + 1] = observer
	end
	ObserverByKey[key] = observer
	addObserverCount( observer )
	ObserversByState = {}
	invalidateListenerCache()
	return observer
end

function MC.UnregisterBlockUpdateObserver( key )
	key = tostring( key or "" )
	local previous = ObserverByKey[key]
	if not previous then return false end
	removeObserverCount( previous )
	ObserverByKey[key] = nil
	for index = 1, #ObserverOrder do
		if ObserverOrder[index] == previous then table.remove( ObserverOrder, index ) break end
	end
	ObserversByState = {}
	invalidateListenerCache()
	return true
end

function MC.HasBlockUpdateObservers( kind )
	return ( ObserverCountByKind[tonumber( kind )] or 0 ) > 0
end

-- Anything at all that wants this update kind. Enqueue gates must use this, not
-- HasBlockUpdateHandlers: an observer-only block still needs its updates queued.
function MC.HasBlockUpdateListeners( kind )
	kind = tonumber( kind )
	return ( HandlerCountByKind[kind] or 0 ) > 0 or ( ObserverCountByKind[kind] or 0 ) > 0
end

-- Returns the ordered observer list for a state, or nil when there is none.
function MC.BlockUpdateObserversForState( stateId )
	stateId = tonumber( stateId )
	if stateId == nil then return nil end
	local cached = ObserversByState[stateId]
	if cached ~= nil then return cached or nil end
	if #ObserverOrder == 0 then return nil end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local matched
	for index = 1, #ObserverOrder do
		local candidate = ObserverOrder[index]
		if candidate.MatchState( stateId, schema ) == true then
			matched = matched or {}
			matched[#matched + 1] = candidate
		end
	end
	-- Same caveat as handlers: before the state registry freezes a missing schema
	-- may only mean the deferred finalization timer has not run yet.
	if schema or MC.BlockStateRegistryFrozen then ObserversByState[stateId] = matched or false end
	return matched
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

-- Hot-path query used by queue admission and the random-tick sampler. It
-- answers for one concrete state and callback kind, including additive
-- observers, and caches the result once the state registry is stable.
function MC.BlockStateHasUpdateListener( stateId, kind )
	stateId = tonumber( stateId )
	kind = tonumber( kind )
	local callbackName = stateId ~= nil and CallbackByKind[kind] or nil
	if not callbackName then return false end
	local byState = ListenerByKindState[kind]
	if not byState then
		byState = {}
		ListenerByKindState[kind] = byState
	end
	local cached = byState[stateId]
	if cached ~= nil then return cached == true end

	local handler = MC.BlockUpdateHandlerForState( stateId )
	local matched = handler ~= nil and handler[callbackName] ~= nil
	if not matched then
		local observers = MC.BlockUpdateObserversForState( stateId )
		for index = 1, observers and #observers or 0 do
			if observers[index][callbackName] then
				matched = true
				break
			end
		end
	end
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if matched or schema or MC.BlockStateRegistryFrozen then byState[stateId] = matched == true end
	return matched == true
end
