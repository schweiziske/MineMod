-- Optional logical-world adapter. The base addon keeps ordinary Source
-- coordinates and disabled streaming; integrations such as minecraft_infmap
-- opt in without replacing the dynamic-chunk store or network transport.
MC = MC or {}

-- Registrations belong to this loader generation. Re-including MC after an
-- optional bridge was removed must not preserve its adapter or streaming
-- owner through the global MC table.
MC.WorldAdapters = {}
MC.ActiveWorldAdapterName = nil
MC.ActiveWorldAdapter = nil
MC.ActiveChunkStreamingOwner = nil
MC.ActiveChunkStreamingOptions = nil
if SERVER and MC.Config and MC.Config.ChunkStreaming and MC.Config.ChunkStreaming.SetBool then
	MC.Config.ChunkStreaming:SetBool( false )
end

local function identity( value ) return value end

-- InfMap's own loader uses the second underscore-delimited map token as its
-- activation contract (for example gm_infmap). Keep the MC core fail-closed:
-- a stale adapter left in the Lua state must never hijack an ordinary map.
local function isInfMapWorld()
	if not game or not game.GetMap then return false end
	local mapName = string.lower( tostring( game.GetMap() or "" ) )
	return string.Explode( "_", mapName )[2] == "infmap"
end

function MC.IsInfMapWorld()
	return isInfMapWorld()
end

function MC.WorldAdapterAllowed( name )
	if tostring( name or "" ) == "infmap" then return isInfMapWorld() end
	return true
end

function MC.RegisterWorldAdapter( name, adapter )
	if not isstring( name ) or name == "" or not istable( adapter ) then return false end
	MC.WorldAdapters[name] = adapter
	return true
end

function MC.UnregisterWorldAdapter( name, adapter )
	if not isstring( name ) or name == "" then return false end
	local registered = MC.WorldAdapters[name]
	if adapter ~= nil and registered ~= adapter then return false end
	if MC.ActiveWorldAdapterName == name then MC.DeactivateWorldAdapter( name ) end
	MC.WorldAdapters[name] = nil
	return registered ~= nil
end

function MC.ActivateWorldAdapter( name )
	if not MC.WorldAdapterAllowed( name ) then return false, "adapter_map_mismatch" end
	local adapter = MC.WorldAdapters[name]
	if not adapter then return false, "unknown_world_adapter" end
	if MC.ActiveWorldAdapterName == name then return true end
	MC.ActiveWorldAdapterName = name
	MC.ActiveWorldAdapter = adapter
	hook.Run( "MCWorldAdapterChanged", name, adapter )
	return true
end

function MC.DeactivateWorldAdapter( name )
	if name ~= nil and MC.ActiveWorldAdapterName ~= name then return false end
	if not MC.ActiveWorldAdapter then return true end
	local previous = MC.ActiveWorldAdapterName
	local previousAdapter = MC.ActiveWorldAdapter
	MC.ActiveWorldAdapterName = nil
	MC.ActiveWorldAdapter = nil
	if MC.ActiveChunkStreamingOwner == "minecraft_infmap" and MC.DisableChunkStreaming then
		MC.DisableChunkStreaming( "minecraft_infmap" )
	end
	hook.Run( "MCWorldAdapterChanged", nil, nil, previous, previousAdapter )
	return true
end

local function activeAdapter()
	local name = MC.ActiveWorldAdapterName
	local adapter = MC.ActiveWorldAdapter
	if not name or not adapter then return nil end
	if MC.WorldAdapters[name] ~= adapter or not MC.WorldAdapterAllowed( name ) then
		MC.DeactivateWorldAdapter( name )
		return nil
	end
	if isfunction( adapter.IsAvailable ) then
		local ok, available = pcall( adapter.IsAvailable, adapter )
		if not ok or available ~= true then
			MC.DeactivateWorldAdapter( name )
			return nil
		end
	end
	return adapter, name
end

function MC.GetWorldAdapter()
	return activeAdapter()
end

function MC.IsWorldAdapterActive( name )
	local adapter, activeName = activeAdapter()
	return adapter ~= nil and ( name == nil or activeName == name )
end

function MC.ValidateWorldAdapter()
	local hadAdapter = MC.ActiveWorldAdapter ~= nil
	activeAdapter()
	return hadAdapter and MC.ActiveWorldAdapter == nil
end

local function adapterCall( method, fallback, ... )
	local adapter = activeAdapter()
	local fn = adapter and adapter[method]
	if fn then return fn( adapter, ... ) end
	return fallback( ... )
end

function MC.WorldToRenderPos( pos )
	return adapterCall( "WorldToRenderPos", identity, pos )
end

function MC.RenderToWorldPos( pos )
	return adapterCall( "RenderToWorldPos", identity, pos )
end

function MC.WorldRenderTransform( pos )
	local adapter = activeAdapter()
	if adapter and adapter.WorldRenderTransform then
		return adapter:WorldRenderTransform( pos )
	end
	return MC.WorldToRenderPos( pos ), nil, nil
end

function MC.WorldFrameSettled()
	local adapter = activeAdapter()
	if adapter and adapter.WorldFrameSettled then
		return adapter:WorldFrameSettled() ~= false
	end
	return true
end

-- True when the active adapter replaces the spherical chunk distance test.
-- Without one, batch renderers may apply the plain distance limit themselves.
function MC.ChunkDrawDistanceCustom()
	local adapter = activeAdapter()
	return adapter ~= nil and adapter.ChunkDrawDistanceVisible ~= nil
end

function MC.ChunkDrawDistanceVisible( dx, dy, dz, maxDistSq )
	maxDistSq = tonumber( maxDistSq ) or 0
	if maxDistSq <= 0 then return true end
	local adapter = activeAdapter()
	if adapter and adapter.ChunkDrawDistanceVisible then
		local visible = adapter:ChunkDrawDistanceVisible( dx, dy, dz, maxDistSq )
		if visible ~= nil then return visible == true end
	end
	return dx * dx + dy * dy + dz * dz <= maxDistSq
end

function MC.EngineToWorldPos( pos, context )
	return adapterCall( "EngineToWorldPos", identity, pos, context )
end

function MC.MoveOriginWorldPos( ply, pos )
	local adapter = activeAdapter()
	if adapter and adapter.MoveOriginWorldPos then return adapter:MoveOriginWorldPos( ply, pos ) end
	return MC.EngineToWorldPos( pos, ply )
end

function MC.EntityWorldPos( ent )
	local adapter = activeAdapter()
	if adapter and adapter.EntityWorldPos then return adapter:EntityWorldPos( ent ) end
	return IsValid( ent ) and ent:GetPos() or vector_origin
end

function MC.EntityEyeWorldPos( ent )
	local adapter = activeAdapter()
	if adapter and adapter.EntityEyeWorldPos then return adapter:EntityEyeWorldPos( ent ) end
	return IsValid( ent ) and ent:EyePos() or vector_origin
end

function MC.EntityWorldAABB( ent )
	local adapter = activeAdapter()
	if adapter and adapter.EntityWorldAABB then return adapter:EntityWorldAABB( ent ) end
	if not IsValid( ent ) then return vector_origin, vector_origin end
	return ent:WorldSpaceAABB()
end

local function protocolCoordinateLimit()
	local bits = MC.Net and tonumber( MC.Net.COORD_BITS ) or 20
	return 2 ^ ( math.max( 2, math.floor( bits ) ) - 1 ) - 1
end

function MC.WorldCoordinateLimit( configuredLimit )
	local protocolLimit = protocolCoordinateLimit()
	local limit = math.max( 0, math.floor( tonumber( configuredLimit ) or protocolLimit ) )
	local adapter = activeAdapter()
	if adapter and adapter.WorldCoordinateLimit then
		local adapted = tonumber( adapter:WorldCoordinateLimit( limit, protocolLimit ) )
		if adapted ~= nil then
			return math.min( protocolLimit, math.max( 0, math.floor( adapted ) ) )
		end
	end
	return math.min( limit, protocolLimit )
end

function MC.WorldBoundsOK( bx, by, bz, configuredLimit )
	bx, by, bz = tonumber( bx ), tonumber( by ), tonumber( bz )
	if bx == nil or by == nil or bz == nil then return false end
	local protocolLimit = protocolCoordinateLimit()
	local protocolMinimum = -protocolLimit - 1
	if bx < protocolMinimum or bx > protocolLimit
	or by < protocolMinimum or by > protocolLimit
	or bz < protocolMinimum or bz > protocolLimit then
		return false
	end
	local adapter = activeAdapter()
	if adapter and adapter.WorldBoundsOK then
		local allowed = adapter:WorldBoundsOK( bx, by, bz, configuredLimit, protocolLimit )
		if allowed ~= nil then return allowed == true end
	end
	local limit = MC.WorldCoordinateLimit( configuredLimit )
	-- Preserve the base addon's ordinary-map contract: mc_world_limit is a
	-- horizontal build boundary. Adapters may override all three axes above.
	return math.abs( bx ) <= limit and math.abs( by ) <= limit
end

function MC.EntityEnginePos( ent )
	local adapter = activeAdapter()
	if adapter and adapter.EntityEnginePos then return adapter:EntityEnginePos( ent ) end
	return IsValid( ent ) and ent:GetPos() or vector_origin
end

function MC.SetEntityEnginePos( ent, pos )
	local adapter = activeAdapter()
	if adapter and adapter.SetEntityEnginePos then return adapter:SetEntityEnginePos( ent, pos ) end
	if IsValid( ent ) then ent:SetPos( pos ) return true end
	return false
end

function MC.PhysicsEnginePos( phys )
	local adapter = activeAdapter()
	if adapter and adapter.PhysicsEnginePos then return adapter:PhysicsEnginePos( phys ) end
	return IsValid( phys ) and phys:GetPos() or vector_origin
end

function MC.SetPhysicsEnginePos( phys, pos )
	local adapter = activeAdapter()
	if adapter and adapter.SetPhysicsEnginePos then return adapter:SetPhysicsEnginePos( phys, pos ) end
	if IsValid( phys ) and phys.SetPos then phys:SetPos( pos ) return true end
	return false
end

function MC.CellRenderMin( bx, by, bz )
	return MC.WorldToRenderPos( Vector( bx * MC.BS, by * MC.BS, bz * MC.BS ) )
end

function MC.CellRenderCenter( bx, by, bz )
	local half = MC.BS * 0.5
	return MC.WorldToRenderPos( Vector( bx * MC.BS + half, by * MC.BS + half, bz * MC.BS + half ) )
end

function MC.ChunkRenderOrigin( cx, cy, cz )
	return MC.WorldToRenderPos( Vector( cx * MC.ChunkWorld, cy * MC.ChunkWorld, cz * MC.ChunkWorldH ) )
end

function MC.InvalidateWorldFrame()
	local changed = MC.RefreshChunkRenderFrame and MC.RefreshChunkRenderFrame() or false
	hook.Run( "MCWorldFrameInvalidated", changed )
	return changed
end

local function copyOptions( options )
	local out = {}
	for key, value in pairs( istable( options ) and options or {} ) do out[key] = value end
	return out
end

local function setConVarNumber( cv, value, integer )
	if not SERVER or not cv or value == nil then return end
	value = tonumber( value )
	if value == nil then return end
	if integer and cv.SetInt then cv:SetInt( math.floor( value ) )
	elseif cv.SetFloat then cv:SetFloat( value ) end
end

local function applyStreamingOptions( options )
	local config = MC.Config or {}
	setConVarNumber( config.StreamChunkSpanXY, options.radius, true )
	setConVarNumber( config.StreamUnloadMargin, options.unloadMargin, true )
	setConVarNumber( config.StreamColumnsPerBatch,
		options.columnsPerBatch or options.requestBatch, true )
	setConVarNumber( config.StreamMaxPatchChunks, options.maxPatchChunks, true )
	setConVarNumber( config.StreamMaxPatchCells, options.maxPatchCells, true )
	setConVarNumber( config.StreamInterval,
		options.viewUpdateInterval or options.requestInterval, false )
	setConVarNumber( config.ChunkStoreLoadsPerTick, options.storeLoadsPerTick, true )
	setConVarNumber( config.ChunkStoreFrame, options.storeFrameMS, false )
	setConVarNumber( config.SyncMsgs,
		options.syncMessagesPerTick or options.reliableMessagesPerTick, true )
	setConVarNumber( config.SyncBudget,
		options.syncReliableBudget or options.reliableBudget, true )
	setConVarNumber( config.SyncFrame,
		options.syncFrameMS or options.reliableFrameMS, false )
	setConVarNumber( config.SyncWindow,
		options.syncInFlightLimit or options.reliableWindow, true )
end

function MC.EnableChunkStreaming( owner, options )
	owner = tostring( owner or "" )
	if owner == "" then return false, "invalid_owner" end
	if owner == "minecraft_infmap" and not MC.IsWorldAdapterActive( "infmap" ) then
		return false, "streaming_adapter_inactive"
	end
	if MC.ActiveChunkStreamingOwner and MC.ActiveChunkStreamingOwner ~= owner then
		return false, "streaming_owned"
	end
	MC.ActiveChunkStreamingOwner = owner
	MC.ActiveChunkStreamingOptions = copyOptions( options )
	if SERVER then
		applyStreamingOptions( MC.ActiveChunkStreamingOptions )
		local cv = MC.Config and MC.Config.ChunkStreaming
		if cv and cv.SetBool then cv:SetBool( true ) end
	end
	return true
end

function MC.DisableChunkStreaming( owner )
	if owner ~= nil and MC.ActiveChunkStreamingOwner ~= tostring( owner ) then return false end
	MC.ActiveChunkStreamingOwner = nil
	MC.ActiveChunkStreamingOptions = nil
	if SERVER then
		local cv = MC.Config and MC.Config.ChunkStreaming
		if cv and cv.SetBool then cv:SetBool( false ) end
	end
	return true
end

function MC.ChunkStreamingEnabled()
	local cv = MC.Config and MC.Config.ChunkStreaming
	if MC.ActiveChunkStreamingOwner == "minecraft_infmap"
	and not MC.IsWorldAdapterActive( "infmap" ) then return false end
	return MC.ActiveChunkStreamingOwner ~= nil and cv and cv.GetBool and cv:GetBool() == true or false
end

function MC.GetChunkStreamingOptions()
	return MC.ActiveChunkStreamingOptions
end
