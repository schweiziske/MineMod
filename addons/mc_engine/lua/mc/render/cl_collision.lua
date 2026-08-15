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
-- Hysteresis: collision is built for a 6x6x6 region around an ANCHOR cell,
-- and the anchor only moves when the player leaves the 3x3x3 core around it.
-- Crouching, small steps and view jitter therefore never trigger rebuilds.
local CLIENT_PLAYER_COLLISION_BLOCK_SIZE = 6
local CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT = math.floor( ( CLIENT_PLAYER_COLLISION_BLOCK_SIZE - 1 ) / 2 )
local CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT = CLIENT_PLAYER_COLLISION_BLOCK_SIZE - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT - 1
local CLIENT_PLAYER_COLLISION_CORE_EXTENT = 1
local CLIENT_AIM_COLLISION_SLACK = 1
local PlayerCollisionAnchor
local AimCollisionAnchor
local AimCollisionAnchorCandidate
MC.NextBulkCollisionRebuildAt = MC.NextBulkCollisionRebuildAt or 0

function MC.ResetClientCollisionState()
	LastClientCollisionCenterKey = nil
	LastClientCollisionRadius = -1
	LastClientCollisionEnabled = nil
	LastClientCollisionAimKey = nil
	LastClientCollisionAABBKey = nil
	LastClientCollisionCrossChunk = nil
	LastClientCollisionRefreshFrame = nil
	PlayerCollisionAnchor = nil
	AimCollisionAnchor = nil
	AimCollisionAnchorCandidate = nil
	if MC.ReleaseAllClientCarrierCollision then MC.ReleaseAllClientCarrierCollision() end
	MC.CollisionCarrierAssignments = {}
	MC.CollisionCarriers = nil
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
	if MC.EntityWorldPos then pos = MC.EntityWorldPos( lp ) end
	local bx, by, bz = MC.WorldToCell( pos )

	-- re-anchor only when the player leaves the core around the anchor;
	-- inside the core the interest (and its key) is completely stable
	local a = PlayerCollisionAnchor
	if not a
	or math.abs( bx - a.bx ) > CLIENT_PLAYER_COLLISION_CORE_EXTENT
	or math.abs( by - a.by ) > CLIENT_PLAYER_COLLISION_CORE_EXTENT
	or math.abs( bz - a.bz ) > CLIENT_PLAYER_COLLISION_CORE_EXTENT then
		a = { bx = bx, by = by, bz = bz }
		PlayerCollisionAnchor = a
	end

	addClientCellNeighborhoodCollisionKeys( desired, a.bx, a.by, a.bz, CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT, false, CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT )
	local minBX = a.bx - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT
	local minBY = a.by - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT
	local minBZ = a.bz - CLIENT_PLAYER_COLLISION_NEGATIVE_EXTENT
	local maxBX = a.bx + CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT
	local maxBY = a.by + CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT
	local maxBZ = a.bz + CLIENT_PLAYER_COLLISION_POSITIVE_EXTENT
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
	local radius = clientCollisionAimRadius()

	-- same hysteresis as the player bubble: build slightly wider than the
	-- configured radius and only re-anchor when the aimed cell drifts out of
	-- the slack zone. Re-anchoring additionally requires the hit cell to hold
	-- still for two consecutive refreshes: duck view-height animation and
	-- prediction-correction view wobble walk the hit cell every frame, and
	-- chasing it would rebuild carrier collision (often the ground under the
	-- player) mid-prediction each frame, feeding the very prediction errors
	-- that move the view.
	local hit = MC.PlayerBlockAim and MC.PlayerBlockAim( lp, aimDist ) or nil
	if hit and hit.bx then
		local a = AimCollisionAnchor
		if not a
		or math.abs( hit.bx - a.bx ) > CLIENT_AIM_COLLISION_SLACK
		or math.abs( hit.by - a.by ) > CLIENT_AIM_COLLISION_SLACK
		or math.abs( hit.bz - a.bz ) > CLIENT_AIM_COLLISION_SLACK then
			local c = AimCollisionAnchorCandidate
			if not a or ( c and c.bx == hit.bx and c.by == hit.by and c.bz == hit.bz ) then
				AimCollisionAnchor = { bx = hit.bx, by = hit.by, bz = hit.bz }
				AimCollisionAnchorCandidate = nil
			else
				AimCollisionAnchorCandidate = { bx = hit.bx, by = hit.by, bz = hit.bz }
			end
		else
			AimCollisionAnchorCandidate = nil
		end
	end

	local a = AimCollisionAnchor
	if not a then return nil end
	local buildRadius = radius + CLIENT_AIM_COLLISION_SLACK
	local clampToHitChunk = radius <= 0 and not clientCollisionCrossChunkEnabled()
	addClientCellNeighborhoodCollisionKeys( desired, a.bx, a.by, a.bz, buildRadius, clampToHitChunk )
	local cx, cy, cz = MC.CellToChunk( a.bx, a.by, a.bz )
	return MC.ChunkKey( cx, cy, cz ) .. "|" .. a.bx .. ":" .. a.by .. ":" .. a.bz .. "|" .. buildRadius .. "|" .. aimDist .. "|" .. tostring( clampToHitChunk )
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

local function clientPhysBuildSignature( key, bounds, chunk )
	chunk = chunk or ( MC.World and MC.World[key] )
	local version = chunk and chunk.collisionVersion or 0
	local count = chunk and chunk.count or 0
	local signature = tostring( version ) .. "|" .. tostring( count ) .. "|" .. clientCollisionBoundsSignature( bounds )
	MC.ClientPhysTargetSignatures = MC.ClientPhysTargetSignatures or {}
	MC.ClientPhysTargetSignatures[key] = signature
	return signature
end

--------------------------------------------------------------- carrier pool
-- Client prediction collision lives on per-player mc_collision_carrier
-- entities (spawned server-side, transmitted only to their owner, never
-- removed while connected). Each carrier holds one page of world-space
-- convexes; a chunk's interest collision may span several carriers.

local CARRIER_CLASS = "mc_collision_carrier"

local function scanLocalCollisionCarriers( lp )
	local out = {}
	for _, ent in ipairs( ents.FindByClass( CARRIER_CLASS ) ) do
		if IsValid( ent ) and ent:EntIndex() > 0 then
			-- Carriers are SetPreventTransmit-hidden from every client except
			-- their owner, so any carrier this client can see is its own. An
			-- unresolved MCCarrierOwner var (NULL) just means the NW value has
			-- not arrived yet; rejecting it would shrink the pool.
			local owner = ent:GetNWEntity( "MCCarrierOwner" )
			if owner == lp or not IsValid( owner ) then
				out[#out + 1] = ent
			end
		end
	end
	table.sort( out, function( a, b )
		return a:GetNWInt( "MCCarrierIndex", 0 ) < b:GetNWInt( "MCCarrierIndex", 0 )
	end )
	MC.CollisionCarriers = out
	return out
end

local function localCollisionCarriers()
	local lp = LocalPlayer()
	if not IsValid( lp ) then return nil end

	local cached = MC.CollisionCarriers
	if cached and #cached > 0 then
		local ok = true
		for i = 1, #cached do
			if not IsValid( cached[i] ) then ok = false break end
		end
		if ok then return cached end
	end

	return scanLocalCollisionCarriers( lp )
end

local function releaseCarrierCollisionForChunk( key )
	local assigned = MC.CollisionCarrierAssignments and MC.CollisionCarrierAssignments[key]
	if assigned then
		for _, ent in ipairs( assigned ) do
			if IsValid( ent ) then ent:PhysicsDestroy() end
		end
		MC.CollisionCarrierAssignments[key] = nil
	end
	if MC.ClientCollisionAABBDebugBoxes then
		MC.ClientCollisionAABBDebugBoxes[key] = nil
	end
	if MC.ClientCarrierConvexPages then
		MC.ClientCarrierConvexPages[key] = nil
	end
end

function MC.ReleaseAllClientCarrierCollision()
	for key in pairs( MC.CollisionCarrierAssignments or {} ) do
		releaseCarrierCollisionForChunk( key )
	end
	MC.CollisionCarrierAssignments = {}
end

local function acquireCarriersForChunk( key, count )
	MC.CollisionCarrierAssignments = MC.CollisionCarrierAssignments or {}
	local carriers = localCollisionCarriers()
	if not carriers or #carriers == 0 then return nil, "no_carriers" end

	local inUse = {}
	for otherKey, list in pairs( MC.CollisionCarrierAssignments ) do
		if otherKey ~= key then
			for _, ent in ipairs( list ) do
				inUse[ent] = true
			end
		end
	end

	-- keep current assignment where possible, top up from the free pool
	local assigned = {}
	for _, ent in ipairs( MC.CollisionCarrierAssignments[key] or {} ) do
		if IsValid( ent ) and #assigned < count then
			assigned[#assigned + 1] = ent
			inUse[ent] = true
		end
	end
	local function topUpFromPool()
		for _, ent in ipairs( carriers ) do
			if #assigned >= count then break end
			if not inUse[ent] then
				assigned[#assigned + 1] = ent
				inUse[ent] = true
			end
		end
	end
	topUpFromPool()

	-- Carriers stream in over several snapshots around join/cleanup, and the
	-- pool cache never invalidates on its own (carriers stay valid for the
	-- whole session). A shortfall must therefore rescan once before reporting
	-- exhaustion, or a frozen partial cache keeps this chunk exhausted forever.
	if #assigned < count then
		local lp = LocalPlayer()
		if IsValid( lp ) then
			carriers = scanLocalCollisionCarriers( lp )
			topUpFromPool()
		end
	end

	-- strip physics from carriers this chunk no longer needs
	for _, ent in ipairs( MC.CollisionCarrierAssignments[key] or {} ) do
		local kept = false
		for _, a in ipairs( assigned ) do
			if a == ent then kept = true break end
		end
		if not kept and IsValid( ent ) then ent:PhysicsDestroy() end
	end

	if #assigned < count then
		MC.CollisionCarrierAssignments[key] = nil
		for _, ent in ipairs( assigned ) do
			if IsValid( ent ) then ent:PhysicsDestroy() end
		end
		return nil, "carrier_pool_exhausted"
	end

	MC.CollisionCarrierAssignments[key] = assigned
	return assigned
end

local function carrierObjectCount( key )
	local count = 0
	for _, ent in ipairs( ( MC.CollisionCarrierAssignments and MC.CollisionCarrierAssignments[key] ) or {} ) do
		if IsValid( ent ) and IsValid( ent:GetPhysicsObject() ) then
			count = count + 1
		end
	end
	return count
end

local function rememberCarrierAABBDebugBoxes( key, origin, boxes )
	MC.ClientCollisionAABBDebugBoxes = MC.ClientCollisionAABBDebugBoxes or {}
	if not boxes or #boxes == 0 then
		MC.ClientCollisionAABBDebugBoxes[key] = nil
		return
	end
	local bs = MC.BS
	local out = {}
	for i, b in ipairs( boxes ) do
		out[i] = {
			mins = origin + Vector( b[1] * bs, b[2] * bs, b[3] * bs ),
			maxs = origin + Vector( b[4] * bs, b[5] * bs, b[6] * bs ),
		}
	end
	MC.ClientCollisionAABBDebugBoxes[key] = out
end

-- returns ok, reason, convexCount, pageCount
local function buildCarrierCollisionForChunk( key, chunk, bounds )
	if not MC.BuildChunkCollisionConvexGroups then return false, "builder_missing", 0, 0 end
	local groups, totalConvexes, boxes, customConvexes = MC.BuildChunkCollisionConvexGroups( chunk, bounds )
	local origin = MC.ChunkRenderOrigin and MC.ChunkRenderOrigin( chunk.cx, chunk.cy, chunk.cz )
		or MC.ChunkWorldOrigin( chunk.cx, chunk.cy, chunk.cz )
	rememberCarrierAABBDebugBoxes( key, origin, boxes )
	if MC.ClientPhysStats then
		MC.ClientPhysStats.lastClientPhysBoxes = boxes and #boxes or 0
		MC.ClientPhysStats.lastClientPhysCustomConvexes = customConvexes and #customConvexes or 0
		MC.ClientPhysStats.lastClientPhysConvexes = totalConvexes
	end

	local convexes = {}
	for _, group in ipairs( groups ) do
		for _, convex in ipairs( group.convexes ) do
			local shifted = {}
			for i, p in ipairs( convex ) do
				shifted[i] = Vector( p.x + origin.x, p.y + origin.y, p.z + origin.z )
			end
			convexes[#convexes + 1] = shifted
		end
	end

	if #convexes == 0 then
		releaseCarrierCollisionForChunk( key )
		return true, nil, 0, 0
	end

	local limit = math.max( 1, math.floor( 511) )
	local pages = {}
	for first = 1, #convexes, limit do
		local page = {}
		for i = first, math.min( #convexes, first + limit - 1 ) do
			page[#page + 1] = convexes[i]
		end
		pages[#pages + 1] = page
	end

	local carriers, reason = acquireCarriersForChunk( key, #pages )
	if not carriers then
		return false, reason or "no_carriers", #convexes, #pages
	end

	for i, page in ipairs( pages ) do
		if not carriers[i]:ApplyCarrierConvexes( page ) then
			releaseCarrierCollisionForChunk( key )
			return false, "carrier_apply_failed", #convexes, #pages
		end
	end
	MC.ClientCarrierConvexPages = MC.ClientCarrierConvexPages or {}
	MC.ClientCarrierConvexPages[key] = pages
	return true, nil, #convexes, #pages
end

local function shiftCarrierConvexPages( pages, dx, dy, dz )
	for _, page in ipairs( pages or {} ) do
		for _, convex in ipairs( page ) do
			for _, point in ipairs( convex ) do
				point.x = point.x + dx
				point.y = point.y + dy
				point.z = point.z + dz
			end
		end
	end
end

local function shiftClientCollisionDebugBoxes( key, dx, dy, dz )
	local boxes = MC.ClientCollisionAABBDebugBoxes and MC.ClientCollisionAABBDebugBoxes[key]
	if not boxes then return end
	for _, box in ipairs( boxes ) do
		box.mins.x = box.mins.x + dx
		box.mins.y = box.mins.y + dy
		box.mins.z = box.mins.z + dz
		box.maxs.x = box.maxs.x + dx
		box.maxs.y = box.maxs.y + dy
		box.maxs.z = box.maxs.z + dz
	end
end

local function clientPhysAlreadyBuilt( key, chunk, bounds )
	local built = MC.ClientPhysBuiltSignatures and MC.ClientPhysBuiltSignatures[key]
	if not built then return false end
	if built ~= clientPhysBuildSignature( key, bounds, chunk ) then return false end
	local builtObjects = MC.ClientPhysBuiltObjectCounts and MC.ClientPhysBuiltObjectCounts[key] or 0
	return carrierObjectCount( key ) >= builtObjects
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
		if MC.EntityWorldPos then pos = MC.EntityWorldPos( lp ) end
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
		for key in pairs( old ) do
			releaseCarrierCollisionForChunk( key )
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
			releaseCarrierCollisionForChunk( key )
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
	-- Never refresh anchors or rebuild carrier physics while the engine
	-- replays already-predicted commands: collision must stay identical
	-- across re-prediction, or the replay diverges from the original run and
	-- the resulting prediction errors shake the view.
	if IsFirstTimePredicted and not IsFirstTimePredicted() then return end
	MC.RefreshClientCollisionInterest()
end )

-- Adapter activation/deactivation changes the coordinate space of every
-- world-space carrier convex. Drop the old pages and rebuild the current
-- interest in the new frame; ordinary maps therefore never inherit InfMap
-- collision after the bridge is removed or disabled.
hook.Remove( "MCWorldAdapterChanged", "mc_client_collision_adapter_frame" )
hook.Add( "MCWorldAdapterChanged", "mc_client_collision_adapter_frame", function()
	MC.ResetClientCollisionState()
	timer.Simple( 0, function()
		if MC.RefreshClientCollisionInterest then MC.RefreshClientCollisionInterest( true ) end
	end )
end )


local function rebuildChunkPhys( key, enabled, bounds )
	MC.ClientPhysStats = MC.ClientPhysStats or {}
	local chunk = MC.World and MC.World[key] or nil
	if not enabled then
		releaseCarrierCollisionForChunk( key )
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		clearClientPhysBuildState( key )
		return true
	end
	if not ( MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] ) then
		rememberClientPhysSkip( key, "not_interest" )
		releaseCarrierCollisionForChunk( key )
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		clearClientPhysBuildState( key )
		return true
	end
	-- Missing chunk data and empty chunks must release carrier collision NOW.
	-- Emptied chunks are removed from MC.World outright (_SetBlockStateStorageRaw),
	-- so breaking the last block of a chunk arrives here as "not chunk"; keeping
	-- the old carrier pages would leave the removed block solid for the owning
	-- client only (invisible ghost collision -> endless prediction errors on that
	-- spot). Interest is deliberately KEPT: MarkCellPhysNeighbours only marks keys
	-- present in the interest table, so stripping the key would make the next
	-- block placed in this chunk build no client collision until an AABB/aim
	-- anchor change forces a full interest refresh. No retry needed either: every
	-- path that (re)creates a chunk marks phys dirty itself (net cell edits,
	-- predicted edits and rollbacks, HTTP/state chunk loads).
	if not chunk or not chunk.count or chunk.count <= 0 then
		rememberClientPhysSkip( key, chunk and "empty_chunk" or "no_world" )
		releaseCarrierCollisionForChunk( key )
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		clearClientPhysBuildState( key )
		return true
	end

	-- Every rebuild covers the whole current AABB/aim interest of this chunk;
	-- narrow edit bounds only serve as the dirty trigger. Collision is baked
	-- onto per-player carrier entities, one page of convexes each.
	local buildBounds = ( MC.ClientCollisionInterest and MC.ClientCollisionInterest[key] ) or bounds
	if clientPhysAlreadyBuilt( key, chunk, buildBounds ) then
		MC.ClientPhysStats.lastClientPhysMode = "skip"
		MC.ClientPhysStats.lastClientPhysKey = key
		MC.ClientPhysStats.lastClientPhysChunkKey = tostring( key )
		MC.ClientPhysStats.lastClientPhysReason = "already_built"
		MC.ClientPhysStats.lastClientPhysObjectCount = carrierObjectCount( key )
		MC.ClientPhysStats.lastClientPhysHadObject = MC.ClientPhysStats.lastClientPhysObjectCount > 0
		MC.PhysDirty[key] = nil
		MC.PhysDirtyPriority[key] = nil
		if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
		clearClientPhysRetry( key )
		return true
	end

	local buildStart = SysTime()
	local signature = clientPhysBuildSignature( key, buildBounds, chunk )
	local ok, reason, convexCount, pageCount = buildCarrierCollisionForChunk( key, chunk, buildBounds )
	MC.ClientPhysStats.lastClientPhysMode = "carriers"
	MC.ClientPhysStats.lastClientPhysBuildMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
	MC.ClientPhysStats.lastClientPhysKey = key
	MC.ClientPhysStats.lastClientPhysChunkKey = tostring( key )
	MC.ClientPhysStats.lastClientPhysBounds = buildBounds and #buildBounds or "full"
	MC.ClientPhysStats.lastClientPhysObjectCount = carrierObjectCount( key )
	MC.ClientPhysStats.lastClientPhysHadObject = MC.ClientPhysStats.lastClientPhysObjectCount > 0
	if clientCollisionDebugEnabled() then
		print( string.format(
			"[MC][client-phys-build] key=%s ms=%s bounds=%s boxes=%s custom=%s convexes=%s worldConvexes=%s carriers=%s carrierPhys=%s ok=%s reason=%s",
			tostring( key ),
			tostring( MC.ClientPhysStats.lastClientPhysBuildMS ),
			tostring( MC.ClientPhysStats.lastClientPhysBounds ),
			tostring( MC.ClientPhysStats.lastClientPhysBoxes ),
			tostring( MC.ClientPhysStats.lastClientPhysCustomConvexes ),
			tostring( MC.ClientPhysStats.lastClientPhysConvexes ),
			tostring( convexCount ),
			tostring( pageCount ),
			tostring( MC.ClientPhysStats.lastClientPhysObjectCount ),
			tostring( ok ~= false ),
			tostring( reason )
		) )
	end
	if not ok then
		clearClientPhysBuildState( key )
		MC.ClientPhysStats.lastClientPhysReason = reason or "rebuild_failed"
		scheduleClientPhysRetry( key, buildBounds, reason or "rebuild_failed" )
		return false
	end
	MC.ClientPhysStats.lastClientPhysReason = nil
	MC.ClientPhysBuiltSignatures = MC.ClientPhysBuiltSignatures or {}
	MC.ClientPhysBuiltHadObjects = MC.ClientPhysBuiltHadObjects or {}
	MC.ClientPhysBuiltObjectCounts = MC.ClientPhysBuiltObjectCounts or {}
	MC.ClientPhysBuiltSignatures[key] = signature
	MC.ClientPhysBuiltHadObjects[key] = pageCount > 0
	MC.ClientPhysBuiltObjectCounts[key] = pageCount

	MC.PhysDirty[key] = nil
	MC.PhysDirtyPriority[key] = nil
	if MC.PhysDirtyBulk then MC.PhysDirtyBulk[key] = nil end
	clearClientPhysRetry( key )
	return true
end

-- Floating-origin transitions translate already-built convex pages instead of
-- rescanning voxels and regrouping collision on every InfMap partition change.
function MC.RebaseClientCollisionFrame( delta )
	if not delta then return false, "missing_delta" end
	local dx = tonumber( delta.x ) or 0
	local dy = tonumber( delta.y ) or 0
	local dz = tonumber( delta.z ) or 0
	if dx == 0 and dy == 0 and dz == 0 then
		return true, { rebased = 0, rebuilt = 0 }
	end

	local started = SysTime()
	local failed = {}
	local rebased = 0
	for key, carriers in pairs( MC.CollisionCarrierAssignments or {} ) do
		local pages = MC.ClientCarrierConvexPages and MC.ClientCarrierConvexPages[key]
		local valid = pages and #pages == #carriers
		if valid then
			shiftCarrierConvexPages( pages, dx, dy, dz )
			shiftClientCollisionDebugBoxes( key, dx, dy, dz )
			for index, carrier in ipairs( carriers ) do
				if not IsValid( carrier ) or not carrier.ApplyCarrierConvexes
				or not carrier:ApplyCarrierConvexes( pages[index] ) then
					valid = false
					break
				end
			end
		end
		if valid then rebased = rebased + 1
		else failed[#failed + 1] = key end
	end

	local rebuilt = 0
	for _, key in ipairs( failed ) do
		releaseCarrierCollisionForChunk( key )
		clearClientPhysBuildState( key )
		if rebuildChunkPhys( key, clientCollisionEnabled() ) then rebuilt = rebuilt + 1 end
	end

	MC.ClientPhysStats = MC.ClientPhysStats or {}
	MC.ClientPhysStats.lastFrameRebaseMS = math.Round( ( SysTime() - started ) * 1000, 3 )
	MC.ClientPhysStats.lastFrameRebaseChunks = rebased
	MC.ClientPhysStats.lastFrameRebaseFallbacks = #failed
	MC.ClientPhysStats.lastFrameRebaseDelta = Vector( dx, dy, dz )
	return #failed == 0, { rebased = rebased, rebuilt = rebuilt, failed = #failed }
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
