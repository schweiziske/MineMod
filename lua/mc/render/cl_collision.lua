-- Client collision interest and clientside prediction physics rebuilds.
-- Clientside collision is a small local prediction bubble; the server remains authoritative.
MC.ClientCollision = CreateClientConVar( "mc_client_collision", "1", true, false,
	"Build clientside block collision for smooth movement prediction (0 = server-only)" )
MC.ClientCollisionChunkSpan = CreateClientConVar( "mc_client_collision_chunk_span", tostring( MC.Config.ClientCollisionChunkSpan or 1 ), true, false,
	"Enable a small AABB around the local player for clientside prediction collision; 0 disables" )
MC.ClientCollisionDebug = MC.ClientCollisionDebug or CreateClientConVar( "mc_client_collision_debug", "0", true, false,
	"Print clientside prediction collision rebuild diagnostics" )
MC.ClientCollisionCrossChunk = MC.ClientCollisionCrossChunk or CreateClientConVar( "mc_client_collision_cross_chunk", "0", true, false,
	"Allow clientside prediction collision interest to spill into neighboring chunks" )
MC.ClientCollisionDefaultVersion = CreateClientConVar( "mc_client_collision_default_version", "0", true, false,
	"Internal migration marker for MC client collision defaults" )
MC.MeshRender = MC.MeshRender or CreateClientConVar( "mc_mesh_render", "1", true, false,
	"Draw MC chunk IMeshes (0 = hide meshes, collision unchanged)" )
MC.ClientCollisionInterest = MC.ClientCollisionInterest or {}
MC.ClientCollisionSignatures = MC.ClientCollisionSignatures or {}

local LastClientCollisionCenterKey
local LastClientCollisionRadius = -1
local LastClientCollisionEnabled = nil
local LastClientCollisionAimKey
local LastClientCollisionAABBKey
local LastClientCollisionCrossChunk = nil
local LastClientCollisionRefreshFrame
local CLIENT_PLAYER_COLLISION_BLOCK_SIZE = 4
local CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT = math.floor( ( CLIENT_PLAYER_COLLISION_BLOCK_SIZE - 1 ) / 2 )
local CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT = CLIENT_PLAYER_COLLISION_BLOCK_SIZE - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT - 1
MC.NextBulkCollisionRebuildAt = MC.NextBulkCollisionRebuildAt or 0

function MC.ResetClientCollisionState()
	LastClientCollisionCenterKey = nil
	LastClientCollisionRadius = -1
	LastClientCollisionEnabled = nil
	LastClientCollisionAimKey = nil
	LastClientCollisionAABBKey = nil
	LastClientCollisionCrossChunk = nil
	LastClientCollisionRefreshFrame = nil
	MC.ClientCollisionInterest = {}
	MC.ClientCollisionPlayerInterest = {}
	MC.ClientCollisionAimInterest = {}
	MC.ClientCollisionSignatures = {}
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PhysDirtyBulk = {}
	MC.PhysDirtyBulkOrder = {}
	MC.PhysDirtyBulkOrderHead = 1
	MC.ClientPhysRetryPending = {}
	MC.ClientPhysRetryAttempts = {}
	MC.ClientPhysBuiltSignatures = {}
	MC.ClientPhysBuiltHadObjects = {}
	MC.ClientPhysBuiltObjectCounts = {}
	MC.ClientPhysTargetSignatures = {}
	MC.ClientCollisionAABBDebugBoxes = {}
	MC.NextBulkCollisionRebuildAt = 0
end

local function clientCollisionEnabled()
	return MC.ClientCollision:GetBool()
end

function MC.ClientCollisionEnabled()
	return clientCollisionEnabled()
end

local function clientCollisionDebugEnabled()
	return MC.ClientCollisionDebug and MC.ClientCollisionDebug:GetBool()
end

local function shouldPrintClientPhysSkip( key, reason )
	MC.ClientPhysSkipPrintState = MC.ClientPhysSkipPrintState or {}
	local sig = tostring( key ) .. "|" .. tostring( reason )
	local now = CurTime()
	local state = MC.ClientPhysSkipPrintState[key]
	if state and state.sig == sig and now < state.nextPrint then return false end
	MC.ClientPhysSkipPrintState[key] = { sig = sig, nextPrint = now + 1.0 }
	return true
end

local function rememberClientPhysSkip( key, reason )
	MC.ClientPhysStats = MC.ClientPhysStats or {}
	MC.ClientPhysStats.lastClientPhysMode = "skip"
	MC.ClientPhysStats.lastClientPhysKey = key
	MC.ClientPhysStats.lastClientPhysChunkKey = tostring( key )
	MC.ClientPhysStats.lastClientPhysReason = reason
	MC.ClientPhysStats.lastClientPhysHadObject = false
	if clientCollisionDebugEnabled() and shouldPrintClientPhysSkip( key, reason ) then
		print( "[MC][client-phys] key=" .. tostring( key ) .. " skip=" .. tostring( reason ) )
	end
end

local function clearClientPhysRetry( key )
	if not key then return end
	if MC.ClientPhysRetryPending then MC.ClientPhysRetryPending[key] = nil end
	if MC.ClientPhysRetryAttempts then MC.ClientPhysRetryAttempts[key] = nil end
end

local function clearClientPhysBuildState( key )
	if not key then return end
	if MC.ClientPhysBuiltSignatures then MC.ClientPhysBuiltSignatures[key] = nil end
	if MC.ClientPhysBuiltHadObjects then MC.ClientPhysBuiltHadObjects[key] = nil end
	if MC.ClientPhysBuiltObjectCounts then MC.ClientPhysBuiltObjectCounts[key] = nil end
	if MC.ClientPhysTargetSignatures then MC.ClientPhysTargetSignatures[key] = nil end
end

local function scheduleClientPhysRetry( key, bounds, reason )
	if not key or not clientCollisionEnabled() then return end
	if not ( MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] ) then return end

	MC.ClientPhysRetryPending = MC.ClientPhysRetryPending or {}
	if MC.ClientPhysRetryPending[key] then return end

	MC.ClientPhysRetryAttempts = MC.ClientPhysRetryAttempts or {}
	local attempts = ( MC.ClientPhysRetryAttempts[key] or 0 ) + 1
	MC.ClientPhysRetryAttempts[key] = attempts
	MC.ClientPhysRetryPending[key] = true

	if MC.ClientPhysStats then
		MC.ClientPhysStats.lastClientPhysRetryKey = key
		MC.ClientPhysStats.lastClientPhysRetryReason = reason
		MC.ClientPhysStats.lastClientPhysRetryAttempts = attempts
	end

	local delay = attempts <= 2 and 0.05 or ( attempts <= 10 and 0.15 or 0.4 )
	timer.Simple( delay, function()
		if MC.ClientPhysRetryPending then MC.ClientPhysRetryPending[key] = nil end
		if not ( MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] ) then
			clearClientPhysRetry( key )
			return
		end
		if MC.MarkChunkPhysDirty then
			MC.MarkChunkPhysDirty( key, true, bounds )
		end
	end )
end

local function meshRenderingEnabled()
	return not MC.MeshRender or MC.MeshRender:GetBool()
end

concommand.Add( "mc_mesh_toggle", function()
	RunConsoleCommand( "mc_mesh_render", meshRenderingEnabled() and "0" or "1" )
end )

function MC.IsChunkInClientCollisionInterest( key )
	return MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] ~= nil
end

if RunConsoleCommand then
	local defaultVersion = MC.ClientCollisionDefaultVersion:GetInt()
	local configuredRadius = MC.ClientCollisionChunkSpan:GetInt()
	if defaultVersion < 1 and not MC.ClientCollision:GetBool() and configuredRadius <= 0 then
		RunConsoleCommand( "mc_client_collision", "1" )
		RunConsoleCommand( "mc_client_collision_chunk_span", tostring( MC.Config.ClientCollisionChunkSpan or 1 ) )
		configuredRadius = MC.Config.ClientCollisionChunkSpan or 1
	elseif defaultVersion < 2 and configuredRadius == 3 then
		RunConsoleCommand( "mc_client_collision_chunk_span", tostring( MC.Config.ClientCollisionChunkSpan or 1 ) )
	end
	if defaultVersion < 2 then
		RunConsoleCommand( "mc_client_collision_default_version", "2" )
	end
end

local function clientCollisionRadius()
	return math.Clamp( MC.ClientCollisionChunkSpan:GetInt(), 0, 32 )
end

local function clientCollisionAimRadius()
	local convar = GetConVar and GetConVar( "mc_client_collision_aim_radius" ) or nil
	if convar and convar.GetInt then
		return math.Clamp( convar:GetInt(), 0, 8 )
	end
	local value = MC.Config and MC.Config.ClientCollisionAimRadius
	if istable( value ) and value.GetInt then
		return math.Clamp( value:GetInt(), 0, 8 )
	end
	return math.Clamp( math.floor( tonumber( value ) or 1 ), 0, 8 )
end

local function clientCollisionCrossChunkEnabled()
	return MC.ClientCollisionCrossChunk and MC.ClientCollisionCrossChunk:GetBool() == true
end

local function clientCollisionWindowSpan()
	return clientCollisionRadius()
end

local function collisionAimDistance()
	local convar = GetConVar and GetConVar( "mc_collision_aim_distance" ) or nil
	if convar and convar.GetFloat then
		return math.Clamp( convar:GetFloat(), MC.BS, MC.BS * 512 )
	end
	local value = MC.Config and MC.Config.CollisionAimDistance
	return math.Clamp( tonumber( value ) or MC.BS * 64, MC.BS, MC.BS * 512 )
end

local function clientLocalCollisionBoundsTouch( a, b )
	return a[1] <= b[4] + 1 and a[4] + 1 >= b[1]
		and a[2] <= b[5] + 1 and a[5] + 1 >= b[2]
		and a[3] <= b[6] + 1 and a[6] + 1 >= b[3]
end

local function mergeClientLocalCollisionBounds( list, bound )
	local merged = bound
	local i = 1
	while i <= #list do
		local cur = list[i]
		if clientLocalCollisionBoundsTouch( cur, merged ) then
			merged = {
				math.min( cur[1], merged[1] ),
				math.min( cur[2], merged[2] ),
				math.min( cur[3], merged[3] ),
				math.max( cur[4], merged[4] ),
				math.max( cur[5], merged[5] ),
				math.max( cur[6], merged[6] ),
			}
			table.remove( list, i )
		else
			i = i + 1
		end
	end
	list[#list + 1] = merged
	return merged
end

local function addClientChunkLocalBoundsCollisionInterest( desired, minBX, minBY, minBZ, maxBX, maxBY, maxBZ, mergeBounds, onlyCX, onlyCY, onlyCZ )
	if mergeBounds == nil then mergeBounds = true end
	local minCX, minCY, minCZ = MC.CellToChunk( minBX, minBY, minBZ )
	local maxCX, maxCY, maxCZ = MC.CellToChunk( maxBX, maxBY, maxBZ )
	if onlyCX ~= nil then
		minCX, maxCX = onlyCX, onlyCX
		minCY, maxCY = onlyCY, onlyCY
		minCZ, maxCZ = onlyCZ, onlyCZ
	end
	for cz = minCZ, maxCZ do
		for cy = minCY, maxCY do
			for cx = minCX, maxCX do
				local bound = {
					math.max( 0, minBX - cx * MC.CS ),
					math.max( 0, minBY - cy * MC.CS ),
					math.max( 0, minBZ - cz * MC.CH ),
					math.min( MC.CS - 1, maxBX - cx * MC.CS ),
					math.min( MC.CS - 1, maxBY - cy * MC.CS ),
					math.min( MC.CH - 1, maxBZ - cz * MC.CH ),
				}
				if bound[1] <= bound[4] and bound[2] <= bound[5] and bound[3] <= bound[6] then
					local key = MC.ChunkKey( cx, cy, cz )
					local list = desired[key]
					if not list then
						list = {}
						desired[key] = list
					end
					if mergeBounds then
						mergeClientLocalCollisionBounds( list, bound )
					else
						list[#list + 1] = bound
					end
				end
			end
		end
	end
end

local function addClientCellNeighborhoodCollisionKeys( desired, bx, by, bz, radius, clampToHitChunk, positiveRadius )
	radius = math.max( 0, math.floor( tonumber( radius ) or 0 ) )
	positiveRadius = positiveRadius == nil and radius or math.max( 0, math.floor( tonumber( positiveRadius ) or 0 ) )
	local onlyCX, onlyCY, onlyCZ
	if clampToHitChunk then
		onlyCX, onlyCY, onlyCZ = MC.CellToChunk( bx, by, bz )
	end
	addClientChunkLocalBoundsCollisionInterest( desired,
		bx - radius, by - radius, bz - radius,
		bx + positiveRadius, by + positiveRadius, bz + positiveRadius,
		false, onlyCX, onlyCY, onlyCZ )
end

local function collectClientPlayerAABBCollisionInterestKeys( lp, desired, radius )
	if not IsValid( lp ) then return nil end
	radius = math.max( 0, math.floor( tonumber( radius ) or 0 ) )
	local pos = lp:GetPos()
	local bx, by, bz = MC.WorldToCell( pos )
	addClientCellNeighborhoodCollisionKeys( desired, bx, by, bz, CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT, false, CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT )
	local minBX = bx - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT
	local minBY = by - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT
	local minBZ = bz - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT
	local maxBX = bx + CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT
	local maxBY = by + CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT
	local maxBZ = bz + CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT
	local minCX, minCY, minCZ = MC.CellToChunk( minBX, minBY, minBZ )
	local maxCX, maxCY, maxCZ = MC.CellToChunk( maxBX, maxBY, maxBZ )
	local spanX, spanY, spanZ = maxBX - minBX + 1, maxBY - minBY + 1, maxBZ - minBZ + 1
	return MC.ChunkKey( minCX, minCY, minCZ ) .. "|" .. MC.ChunkKey( maxCX, maxCY, maxCZ )
		.. "|" .. minBX .. ":" .. minBY .. ":" .. minBZ .. "|" .. maxBX .. ":" .. maxBY .. ":" .. maxBZ
		.. "|size|" .. spanX .. ":" .. spanY .. ":" .. spanZ .. "|gate|" .. radius
end

local function collectClientAimCollisionInterestKeys( lp, desired )
	if not IsValid( lp ) then return nil end
	local aimDist = collisionAimDistance()
	local hit = MC.PlayerBlockAim and MC.PlayerBlockAim( lp, aimDist ) or nil
	if not hit or not hit.bx then return nil end
	local radius = clientCollisionAimRadius()
	local clampToHitChunk = radius <= 0 and not clientCollisionCrossChunkEnabled()
	addClientCellNeighborhoodCollisionKeys( desired, hit.bx, hit.by, hit.bz, radius, clampToHitChunk )
	local cx, cy, cz = MC.CellToChunk( hit.bx, hit.by, hit.bz )
	return MC.ChunkKey( cx, cy, cz ) .. "|" .. hit.bx .. ":" .. hit.by .. ":" .. hit.bz .. "|" .. radius .. "|" .. aimDist .. "|" .. tostring( clampToHitChunk )
end

local function clientCollisionBoundsSignature( bounds )
	if not bounds then return "" end
	local parts = {}
	for i, b in ipairs( bounds ) do
		parts[i] = table.concat( b, "," )
	end
	table.sort( parts )
	return table.concat( parts, ";" )
end

local function mergeClientCollisionInterestSets( target, source )
	if not source then return end
	for key, bounds in pairs( source ) do
		local list = target[key]
		if not list then
			list = {}
			target[key] = list
		end
		for _, bound in ipairs( bounds ) do
			list[#list + 1] = {
				bound[1], bound[2], bound[3],
				bound[4], bound[5], bound[6],
			}
		end
	end
end

local function clientCollisionSubchunkBoundsForKey( subkey )
	local sx, sy, sz = tostring( subkey or "" ):match( "^(-?%d+):(-?%d+):(-?%d+)$" )
	if not sx then return nil end
	local size = math.max( 1, math.floor( tonumber( MC.CollisionSubchunkSize ) or 8 ) )
	local x0 = math.max( 0, tonumber( sx ) * size )
	local y0 = math.max( 0, tonumber( sy ) * size )
	local z0 = math.max( 0, tonumber( sz ) * size )
	return {
		x0,
		y0,
		z0,
		math.min( MC.CS - 1, x0 + size - 1 ),
		math.min( MC.CS - 1, y0 + size - 1 ),
		math.min( MC.CH - 1, z0 + size - 1 ),
	}
end

local function clientLocalBoundsTouch( a, b )
	return a[1] <= b[4] and a[4] >= b[1]
		and a[2] <= b[5] and a[5] >= b[2]
		and a[3] <= b[6] and a[6] >= b[3]
end

local function clientNetworkSubchunkInBounds( ent, key, bounds )
	if not IsValid( ent ) or ent:GetNWString( "MCChunkKey", "" ) ~= tostring( key ) then return false end
	if not bounds then return true end
	local sub = clientCollisionSubchunkBoundsForKey( ent:GetNWString( "MCSubchunkKey", "" ) )
	if not sub then return false end
	for _, bound in ipairs( bounds ) do
		if clientLocalBoundsTouch( sub, bound ) then return true end
	end
	return false
end

local function clientNetworkSubchunkPhysSummary( key, bounds )
	local total = 0
	local missing = 0
	for _, subchunk in ipairs( ents.FindByClass( "mc_chunk_phys" ) ) do
		if clientNetworkSubchunkInBounds( subchunk, key, bounds ) then
			total = total + 1
			if not IsValid( subchunk:GetPhysicsObject() ) then
				missing = missing + 1
			end
		end
	end
	return total, missing
end

local function clientPhysBuildSignature( key, bounds, chunk )
	chunk = chunk or ( MC.World and MC.World[key] )
	local version = chunk and chunk.collisionVersion or 0
	local count = chunk and chunk.count or 0
	local signature = tostring( version ) .. "|" .. tostring( count ) .. "|" .. clientCollisionBoundsSignature( bounds )
	MC.ClientPhysTargetSignatures = MC.ClientPhysTargetSignatures or {}
	MC.ClientPhysTargetSignatures[key] = signature
	return signature
end

local function clientPhysObjectCount( ent )
	if not IsValid( ent ) then return 0 end
	local count = IsValid( ent:GetPhysicsObject() ) and 1 or 0
	for _, subchunk in ipairs( ent.PhysicsSubchunks or {} ) do
		if IsValid( subchunk ) and IsValid( subchunk:GetPhysicsObject() ) then
			count = count + 1
		end
	end
	return count
end

local function clientPhysHasObject( ent )
	return clientPhysObjectCount( ent ) > 0
end

local function clientPhysAlreadyBuilt( key, chunk, ent, bounds )
	local built = MC.ClientPhysBuiltSignatures and MC.ClientPhysBuiltSignatures[key]
	if not built then return false end
	if built ~= clientPhysBuildSignature( key, bounds, chunk ) then return false end
	local networkTotal, networkMissing = clientNetworkSubchunkPhysSummary( key, bounds )
	if MC.ClientPhysStats then
		MC.ClientPhysStats.lastClientPhysNetworkSubchunks = networkTotal
		MC.ClientPhysStats.lastClientPhysMissingSubchunks = networkMissing
	end
	if networkTotal > 0 then
		return networkMissing == 0
	end
	local builtObjects = MC.ClientPhysBuiltObjectCounts and MC.ClientPhysBuiltObjectCounts[key] or 0
	if builtObjects > 0 then
		return IsValid( ent ) and IsValid( ent:GetPhysicsObject() ) and clientPhysObjectCount( ent ) >= builtObjects
	end
	return true
end

function MC.RefreshClientCollisionInterest( force )

	local frame = FrameNumber and FrameNumber() or RealTime()
	if not force and LastClientCollisionRefreshFrame == frame then return end
	LastClientCollisionRefreshFrame = frame
	local enabled = clientCollisionEnabled()
	local radius = clientCollisionRadius()
	local crossChunk = clientCollisionCrossChunkEnabled()
	local lp = LocalPlayer()
	local centerKey
	local aimKey
	local aabbKey
	local playerDesired = {}
	local aimDesired = {}
	local desired = {}

	if enabled and radius > 0 and IsValid( lp ) then
		local pos = lp:GetPos()
		local bx, by, bz = MC.WorldToCell( pos )
		local cx, cy, cz = MC.CellToChunk( bx, by, bz )
		centerKey = MC.ChunkKey( cx, cy, cz )
		aabbKey = collectClientPlayerAABBCollisionInterestKeys( lp, playerDesired, radius )
		aimKey = collectClientAimCollisionInterestKeys( lp, aimDesired )
	end
	mergeClientCollisionInterestSets( desired, playerDesired )
	mergeClientCollisionInterestSets( desired, aimDesired )

	if not force and centerKey == LastClientCollisionCenterKey
	and radius == LastClientCollisionRadius and enabled == LastClientCollisionEnabled
	and crossChunk == LastClientCollisionCrossChunk
	and aimKey == LastClientCollisionAimKey and aabbKey == LastClientCollisionAABBKey then
		return
	end

	local old = MC.ClientCollisionInterest or {}
	MC.ClientCollisionInterest = desired
	MC.ClientCollisionPlayerInterest = playerDesired
	MC.ClientCollisionAimInterest = aimDesired
	LastClientCollisionCenterKey = centerKey
	LastClientCollisionRadius = radius
	LastClientCollisionEnabled = enabled
	LastClientCollisionCrossChunk = crossChunk
	LastClientCollisionAimKey = aimKey
	LastClientCollisionAABBKey = aabbKey

	if not enabled then
		for key, e in pairs( old ) do
			local ent = MC.ChunkEnts and MC.ChunkEnts[key]
			if IsValid( ent ) then
				if ent.ClearClientCollisionAABBDebugBoxes then ent:ClearClientCollisionAABBDebugBoxes() end
				if ent.ClearPhysicsSubchunks then ent:ClearPhysicsSubchunks() end
				ent:PhysicsDestroy()
			end
			MC.PhysDirty[key] = nil
			MC.PhysDirtyPriority[key] = nil
			if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
			MC.ClientCollisionSignatures[key] = nil
			clearClientPhysBuildState( key )
		end
		MC.PhysDirtyBulkOrder = {}
		MC.PhysDirtyBulkOrderHead = 1
		MC.ClientCollisionAABBDebugBoxes = {}
		return
	end

	for key in pairs( old ) do
		if not desired[key] then
			local e = MC.ChunkEnts and MC.ChunkEnts[key]
			if IsValid( e ) then
				if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
				if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
				e:PhysicsDestroy()
			end
			MC.PhysDirty[key] = nil
			MC.PhysDirtyPriority[key] = nil
			if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
			MC.ClientCollisionSignatures[key] = nil
			clearClientPhysBuildState( key )
		end
	end

	for key, bounds in pairs( desired ) do
		local oldSig = MC.ClientCollisionSignatures[key]
		local newSig = clientCollisionBoundsSignature( bounds )
		if not ( MC.World and MC.World[key] ) then
			if MC.QueueHttpChunk then MC.QueueHttpChunk( key ) end
			MC.ClientCollisionSignatures[key] = nil
			clearClientPhysBuildState( key )
			rememberClientPhysSkip( key, "no_world" )
		elseif not old[key] or oldSig ~= newSig then
			MC.ClientCollisionSignatures[key] = newSig
			MC.MarkChunkPhysDirty( key, true )
		else
			MC.ClientCollisionSignatures[key] = newSig
		end
	end
end

cvars.AddChangeCallback( "mc_client_collision", function()
	MC.RefreshClientCollisionInterest( true )
end, "mc" )

cvars.AddChangeCallback( "mc_client_collision_chunk_span", function()
	MC.RefreshClientCollisionInterest( true )
end, "mc" )

cvars.AddChangeCallback( "mc_client_collision_aim_radius", function()
	MC.RefreshClientCollisionInterest( true )
end, "mc" )

cvars.AddChangeCallback( "mc_client_collision_cross_chunk", function()
	MC.RefreshClientCollisionInterest( true )
end, "mc" )

cvars.AddChangeCallback( "mc_collision_aim_distance", function()
	MC.RefreshClientCollisionInterest( true )
end, "mc" )

hook.Remove( "SetupMove", "mc_client_collision_interest_move" )
hook.Add( "SetupMove", "mc_client_collision_interest_move", function( ply )
	if not IsValid( ply ) or ply ~= LocalPlayer() then return end
	MC.RefreshClientCollisionInterest()
end )


local function findNetworkChunkShell( key, chunk )
	local existing = MC.ChunkEnts and MC.ChunkEnts[key] or nil
	if IsValid( existing ) and existing:EntIndex() > 0 then return existing end

	for _, candidate in ipairs( ents.FindByClass( "mc_chunk" ) ) do
		if IsValid( candidate ) and candidate:EntIndex() > 0 then
			if candidate:GetNWString( "MCChunkKey", "" ) == tostring( key ) then
				MC.ChunkEnts[key] = candidate
				return candidate
			end
			if chunk then
				local expected = MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz )
				if candidate:GetPos():DistToSqr( expected ) <= 1 then
					candidate.ChunkKey = key
					candidate.cx, candidate.cy, candidate.cz = chunk.cx, chunk.cy, chunk.cz
					MC.ChunkEnts[key] = candidate
					return candidate
				end
			end
		end
	end
	return nil
end

local function rebuildChunkPhys( key, enabled, bounds )
	local chunk = MC.World and MC.World[key] or nil
	local e = MC.ChunkEnts[key]
	if not enabled then
		if IsValid( e ) then
			if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
			if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
			e:PhysicsDestroy()
		end
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		clearClientPhysBuildState( key )
		return true
	end
	if enabled and not ( MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] ) then
		rememberClientPhysSkip( key, "not_interest" )
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		clearClientPhysBuildState( key )
		return true
	end
	if enabled and IsValid( e ) and e:EntIndex() <= 0 then
		e = nil
	end
	if not chunk then
		rememberClientPhysSkip( key, "no_world" )
		clearClientPhysBuildState( key )
		scheduleClientPhysRetry( key, bounds, "no_world" )
		return false
	end
	if not chunk.count or chunk.count <= 0 then
		if MC.ClientCollisionInterest then MC.ClientCollisionInterest[key] = nil end
		if IsValid( e ) then
			if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
			if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
			e:PhysicsDestroy()
		end
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		clearClientPhysBuildState( key )
		return true
	end

	if not IsValid( e ) then
		e = findNetworkChunkShell( key, chunk )
		if IsValid( e ) then
			if e.ChunkKey and e.ChunkKey ~= key and MC.ChunkEnts[e.ChunkKey] == e then
				MC.ChunkEnts[e.ChunkKey] = nil
			end
			e:SetModel( "models/hunter/blocks/cube025x025x025.mdl" )
			e.cx, e.cy, e.cz = chunk.cx, chunk.cy, chunk.cz
			e.ChunkKey = key
			e:SetPos( MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz ) )
			e:SetAngles( Angle( 0, 0, 0 ) )
			e:SetRenderBounds( Vector( 0, 0, 0 ), Vector( MC.ChunkWorld, MC.ChunkWorld, MC.ChunkWorldH ) )
			e:SetMoveType( MOVETYPE_VPHYSICS )
			e:SetSolid( SOLID_VPHYSICS )
			e:EnableCustomCollisions( true )
			e:SetNoDraw( false )
			MC.ChunkEnts[key] = e
		end
	end
	if IsValid( e ) then
		if enabled then
			local buildBounds = bounds or ( MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] )
			if clientPhysAlreadyBuilt( key, chunk, e, buildBounds ) then
				MC.ClientPhysStats.lastClientPhysMode = "skip"
				MC.ClientPhysStats.lastClientPhysKey = key
				MC.ClientPhysStats.lastClientPhysChunkKey = tostring( key )
				MC.ClientPhysStats.lastClientPhysReason = "already_built"
				MC.ClientPhysStats.lastClientPhysHadObject = clientPhysHasObject( e )
				MC.ClientPhysStats.lastClientPhysObjectCount = clientPhysObjectCount( e )
				MC.PhysDirty[key] = nil
				MC.PhysDirtyPriority[key] = nil
				if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
				clearClientPhysRetry( key )
				return true
			end
			local buildStart = SysTime()
			local signature = clientPhysBuildSignature( key, buildBounds, chunk )
			local ok, reason = e:RebuildPhysics( buildBounds )
			MC.ClientPhysStats.lastClientPhysBuildMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
			MC.ClientPhysStats.lastClientPhysKey = key
			MC.ClientPhysStats.lastClientPhysBounds = buildBounds and #buildBounds or "full"
			MC.ClientPhysStats.lastClientPhysHadObject = clientPhysHasObject( e )
			MC.ClientPhysStats.lastClientPhysObjectCount = clientPhysObjectCount( e )
			local networkTotal, networkMissing = clientNetworkSubchunkPhysSummary( key, buildBounds )
			MC.ClientPhysStats.lastClientPhysNetworkSubchunks = networkTotal
			MC.ClientPhysStats.lastClientPhysMissingSubchunks = networkMissing
			if clientCollisionDebugEnabled() then
				print( string.format(
					"[MC][client-phys-build] key=%s ms=%s bounds=%s mode=%s boxes=%s custom=%s convexes=%s subchunks=%s subchunkPhys=%s mainPhys=%s ok=%s reason=%s network=%s missing=%s",
					tostring( key ),
					tostring( MC.ClientPhysStats.lastClientPhysBuildMS ),
					tostring( MC.ClientPhysStats.lastClientPhysBounds ),
					tostring( MC.ClientPhysStats.lastClientPhysMode ),
					tostring( MC.ClientPhysStats.lastClientPhysBoxes ),
					tostring( MC.ClientPhysStats.lastClientPhysCustomConvexes ),
					tostring( MC.ClientPhysStats.lastClientPhysConvexes ),
					tostring( MC.ClientPhysStats.lastClientPhysSubchunks ),
					tostring( MC.ClientPhysStats.lastClientPhysSubchunkObjects ),
					tostring( MC.ClientPhysStats.lastClientPhysMainObject ),
					tostring( ok ~= false ),
					tostring( reason ),
					tostring( networkTotal ),
					tostring( networkMissing )
				) )
			end
			if ok == false then
				clearClientPhysBuildState( key )
				MC.ClientPhysStats.lastClientPhysReason = reason or "rebuild_failed"
				scheduleClientPhysRetry( key, buildBounds, reason or "rebuild_failed" )
				return false
			end
			MC.ClientPhysBuiltSignatures = MC.ClientPhysBuiltSignatures or {}
			MC.ClientPhysBuiltHadObjects = MC.ClientPhysBuiltHadObjects or {}
			MC.ClientPhysBuiltObjectCounts = MC.ClientPhysBuiltObjectCounts or {}
			MC.ClientPhysBuiltSignatures[key] = signature
			MC.ClientPhysBuiltHadObjects[key] = clientPhysHasObject( e )
			MC.ClientPhysBuiltObjectCounts[key] = clientPhysObjectCount( e )
		else
			if MC.ClientCollisionInterest then MC.ClientCollisionInterest[key] = nil end
			if e.ClearClientCollisionAABBDebugBoxes then e:ClearClientCollisionAABBDebugBoxes() end
			if e.ClearPhysicsSubchunks then e:ClearPhysicsSubchunks() end
			e:PhysicsDestroy()
			clearClientPhysBuildState( key )
		end
	else
		rememberClientPhysSkip( key, "no_chunk_ent" )
		clearClientPhysBuildState( key )
		scheduleClientPhysRetry( key, bounds, "no_chunk_ent" )
		return false
	end

	MC.PhysDirty[key] = nil
	MC.PhysDirtyPriority[key] = nil
	if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
	clearClientPhysRetry( key )
	return true
end

function MC.RebuildChunkPhys( key, enabled, bounds )
	return rebuildChunkPhys( key, enabled, bounds )
end

function MC.MarkChunkPhysDirty( key, priority, bounds )
	if not key then return end
	if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
	if priority then
		MC.PhysDirty[key] = true
		MC.PhysDirtyPriority[key] = true
	else
		MC.PhysDirty[key] = true
		MC.PhysDirtyPriority[key] = nil
	end
	rebuildChunkPhys( key, clientCollisionEnabled(), bounds )
end

function MC.MarkChunkPhysDirtyBulk( key )
	if not key then return end
	MC.PhysDirty[key] = true
	MC.PhysDirtyPriority[key] = nil
	MC.PhysDirtyBulk = MC.PhysDirtyBulk or {}
	MC.PhysDirtyBulkOrder = MC.PhysDirtyBulkOrder or {}
	MC.PhysDirtyBulkOrderHead = MC.PhysDirtyBulkOrderHead or 1
	if not MC.PhysDirtyBulk[key] then
		MC.PhysDirtyBulk[key] = true
		MC.PhysDirtyBulkOrder[#MC.PhysDirtyBulkOrder + 1] = key
	end
end
