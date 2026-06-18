--[[----------------------------------------------------------------------------
	MC : client rendering

	Builds IMeshes per chunk from the voxel store with hidden-face culling and
	Minecraft-style directional face shading. Each chunk gets an opaque/cutout
	mesh list plus, when it contains translucent blocks, a separate translucent
	mesh list; both draw from PostDraw*Renderables hooks.
------------------------------------------------------------------------------]]

MC = MC or {}
if MC.ClientRenderLoaded and MC.FreeAllMeshes then
	MC.FreeAllMeshes()
end
MC.ClientRenderLoaded = true

local BS  = MC.BS
local CS  = MC.CS
local RENDER_SECTION_SIZE = 8
local RENDER_SECTIONS_XY = math.ceil( MC.CS / RENDER_SECTION_SIZE )
local RENDER_SECTIONS_Z = math.ceil( MC.CH / RENDER_SECTION_SIZE )

if MC.GeneratedAtlas then
	MC.Atlas.COLS = MC.GeneratedAtlas.COLS or MC.Atlas.COLS
	MC.Atlas.ROWS = MC.GeneratedAtlas.ROWS or MC.Atlas.ROWS
	MC.Atlas.TILE = MC.GeneratedAtlas.TILE or MC.Atlas.TILE
	MC.Atlas.PAD = MC.GeneratedAtlas.PAD or MC.Atlas.PAD
	MC.Atlas.STRIDE = MC.GeneratedAtlas.STRIDE or MC.Atlas.STRIDE
	MC.Atlas.MATERIAL = MC.GeneratedAtlas.MATERIAL or MC.Atlas.MATERIAL
	MC.Atlas.MATERIAL_TRANSLUCENT = MC.GeneratedAtlas.MATERIAL_TRANSLUCENT or MC.Atlas.MATERIAL_TRANSLUCENT
	MC.Atlas.W = MC.GeneratedAtlas.W or MC.Atlas.COLS * ( MC.Atlas.STRIDE or MC.Atlas.TILE )
	MC.Atlas.H = MC.GeneratedAtlas.H or MC.Atlas.ROWS * ( MC.Atlas.STRIDE or MC.Atlas.TILE )
end

local function atlasPngPath( path )
	path = path or "mc/atlas_365"
	path = path:gsub( "%.vmt$", "" )
	if path:sub( -4 ) == ".png" then return path end
	return path .. ".png"
end

-- single atlas material: alpha cutout (glass/leaves), vertex-shaded, backface-culled
MC.Material = Material( atlasPngPath( MC.Atlas.MATERIAL or "mc/atlas_365" ), "alphatest vertexcolor" )

-- second material over the same atlas pixels for translucent blocks: real alpha
-- blending in the translucent pass. GMod caches materials by path, so the build
-- writes a separate translucent atlas VMT/VTF instead of rebinding one texture
-- through two different flag sets.
local function translucentAtlasPath( path )
	path = path or "mc/atlas_365"
	return path:gsub( "%.png$", "" ) .. "_translucent"
end
local transPath = MC.Atlas.MATERIAL_TRANSLUCENT or translucentAtlasPath( MC.Atlas.MATERIAL )
MC.MaterialTranslucent = Material( atlasPngPath( transPath ), "translucent vertexcolor" )
if not MC.MaterialTranslucent or MC.MaterialTranslucent:IsError() then
	-- missing copy: fall back to the cutout material rather than drawing white
	MC.MaterialTranslucent = MC.Material
end

-- Opaque variant of the atlas for inventory icons. Semi-transparent blocks
-- (stained glass, tinted glass, ice, slime, honey) have low texel alpha that the
-- cutout material's alpha test discards, so their icons would render blank. This
-- is the cutout atlas minus $alphatest, so low-alpha texels are kept and the icon
-- shows the solid texture colour.
--
-- The atlas ships only as a PNG (no .vtf), so neither way of seeding $basetexture
-- works on its own: leaving it empty at creation renders a solid white square, and
-- a path string like "mc/atlas_365" is not the texture's cache key so it falls back
-- to a disk .vtf lookup that misses and draws the pink/black error checkerboard.
-- Point $basetexture at the registered name of the texture MC.Material already
-- loaded; the material system then resolves it from the texture cache (same texture,
-- no second copy) and the surface library binds it for 2D icon draws.
MC.MaterialIconOpaque = nil
do
	local baseTex = MC.Material and MC.Material.GetTexture and MC.Material:GetTexture( "$basetexture" )
	local baseName = baseTex and not baseTex:IsError() and baseTex.GetName and baseTex:GetName() or nil
	if baseName and baseName ~= "" then
		local mat = CreateMaterial( "mc_atlas_icon_opaque", "UnlitGeneric", {
			["$basetexture"] = baseName,
			["$vertexcolor"] = "1",
			["$nocull"] = "1",
			["$vertexalpha"] = "1",
		} )
		if mat and not mat:IsError() then
			mat:SetTexture( "$basetexture", baseTex )
			MC.MaterialIconOpaque = mat
		end
	end
end
if not MC.MaterialIconOpaque then
	-- atlas texture unavailable: fall back to the cutout material rather than
	-- drawing white/error icons (semi-transparent blocks just look blank)
	MC.MaterialIconOpaque = MC.Material
end

-- directional shading (modulates the texture via vertex colour)
local SH_TOP    = Color( 255, 255, 255 )
local SH_BOTTOM = Color( 130, 130, 130 )
local SH_X      = Color( 160, 160, 160 )
local SH_Y      = Color( 205, 205, 205 )

local N_UP    = Vector(  0,  0,  1 )
local N_DOWN  = Vector(  0,  0, -1 )
local N_XP    = Vector(  1,  0,  0 )
local N_XN    = Vector( -1,  0,  0 )
local N_YP    = Vector(  0,  1,  0 )
local N_YN    = Vector(  0, -1,  0 )

-- face table. slot: 1=top tile, 2=bottom tile, 3=side tile
-- c = four corners as { offX, offY, offZ, uFlag, vFlag } (a,b,c,d), drawn a,b,c + a,c,d
local FACES = {
	{ n = N_UP,   sh = SH_TOP,    slot = 1, off = {  0,  0,  1 }, c = { {0,0,1,0,1}, {1,0,1,1,1}, {1,1,1,1,0}, {0,1,1,0,0} } },
	{ n = N_DOWN, sh = SH_BOTTOM, slot = 2, off = {  0,  0, -1 }, c = { {0,1,0,0,1}, {1,1,0,1,1}, {1,0,0,1,0}, {0,0,0,0,0} } },
	{ n = N_XP,   sh = SH_X,      slot = 3, off = {  1,  0,  0 }, c = { {1,0,0,0,1}, {1,1,0,1,1}, {1,1,1,1,0}, {1,0,1,0,0} } },
	{ n = N_XN,   sh = SH_X,      slot = 3, off = { -1,  0,  0 }, c = { {0,1,0,0,1}, {0,0,0,1,1}, {0,0,1,1,0}, {0,1,1,0,0} } },
	{ n = N_YP,   sh = SH_Y,      slot = 3, off = {  0,  1,  0 }, c = { {1,1,0,0,1}, {0,1,0,1,1}, {0,1,1,1,0}, {1,1,1,0,0} } },
	{ n = N_YN,   sh = SH_Y,      slot = 3, off = {  0, -1,  0 }, c = { {0,0,0,0,1}, {1,0,0,1,1}, {1,0,1,1,0}, {0,0,1,0,0} } },
}
-- Source's front-face winding is opposite the corner order above.
local TRI = { 1, 3, 2, 1, 4, 3 }

local VERT_LIMIT = 64998 -- multiple of 6, under the 65535 IMesh vertex cap

MC.Meshes      = MC.Meshes or {}      -- key -> { IMesh, ... } (opaque/cutout pass)
MC.MeshesTrans = MC.MeshesTrans or {} -- key -> { IMesh, ... } (translucent pass)
MC.MeshSections = MC.MeshSections or {} -- key -> sectionIndex -> { opaque = {}, translucent = {} }
MC.MeshDirty = MC.MeshDirty or {}  -- key -> true
MC.MeshDirtyRateLimited = MC.MeshDirtyRateLimited or {} -- key -> true for explosion-driven mesh rebuilds
MC.ChunkEnts = MC.ChunkEnts or {}  -- key -> mc_chunk entity (clientside physics owner)
MC.PhysDirty = MC.PhysDirty or {}  -- key -> true while a clientside collision rebuild is being fired
MC.PhysDirtyPriority = MC.PhysDirtyPriority or {} -- key -> true for priority rebuild diagnostics
MC.PhysDirtyBulk = MC.PhysDirtyBulk or {} -- key -> true when bulk client collision rebuild is throttled
MC.PhysDirtyBulkOrder = MC.PhysDirtyBulkOrder or {}
MC.ClientPhysRetryPending = MC.ClientPhysRetryPending or {}
MC.ClientPhysRetryAttempts = MC.ClientPhysRetryAttempts or {}
MC.RenderStats = MC.RenderStats or {}
MC.ClientPhysStats = MC.ClientPhysStats or {}
MC.ClientPhysBuiltSignatures = MC.ClientPhysBuiltSignatures or {}
MC.ClientPhysBuiltHadObjects = MC.ClientPhysBuiltHadObjects or {}
MC.ClientPhysBuiltObjectCounts = MC.ClientPhysBuiltObjectCounts or {}
MC.ClientPhysTargetSignatures = MC.ClientPhysTargetSignatures or {}

-- Clientside collision is a small local prediction bubble; the server remains authoritative.
MC.ClientCollision = CreateClientConVar( "mc_client_collision", "1", true, false,
	"Build clientside block collision for smooth movement prediction (0 = server-only)" )
MC.ClientCollisionChunkSpan = CreateClientConVar( "mc_client_collision_chunk_span", tostring( MC.Config.ClientCollisionChunkSpan or 1 ), true, false,
	"Chunk radius around the local player that builds clientside prediction collision; 0 disables" )
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
local NextExplosionMeshBuildAt = 0
local NextBulkCollisionRebuildAt = 0

function MC.ResetClientCollisionState()
	LastClientCollisionCenterKey = nil
	LastClientCollisionRadius = -1
	LastClientCollisionEnabled = nil
	LastClientCollisionAimKey = nil
	LastClientCollisionAABBKey = nil
	LastClientCollisionCrossChunk = nil
	LastClientCollisionRefreshFrame = nil
	MC.ClientCollisionInterest = {}
	MC.ClientCollisionSignatures = {}
	MC.PhysDirty = {}
	MC.PhysDirtyPriority = {}
	MC.PhysDirtyBulk = {}
	MC.PhysDirtyBulkOrder = {}
	MC.ClientPhysRetryPending = {}
	MC.ClientPhysRetryAttempts = {}
	MC.ClientPhysBuiltSignatures = {}
	MC.ClientPhysBuiltHadObjects = {}
	MC.ClientPhysBuiltObjectCounts = {}
	MC.ClientPhysTargetSignatures = {}
	MC.ClientCollisionAABBDebugBoxes = {}
	NextBulkCollisionRebuildAt = 0
end

local function clientCollisionEnabled()
	return MC.ClientCollision:GetBool()
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

local function addClientCellNeighborhoodCollisionKeys( desired, bx, by, bz, radius, clampToHitChunk )
	radius = math.max( 0, math.floor( tonumber( radius ) or 0 ) )
	local onlyCX, onlyCY, onlyCZ
	if clampToHitChunk then
		onlyCX, onlyCY, onlyCZ = MC.CellToChunk( bx, by, bz )
	end
	addClientChunkLocalBoundsCollisionInterest( desired,
		bx - radius, by - radius, bz - radius,
		bx + radius, by + radius, bz + radius,
		false, onlyCX, onlyCY, onlyCZ )
end

local function addClientAABBCollisionInterest( desired, mins, maxs, blockPad, onlyCX, onlyCY, onlyCZ )
	if not mins or not maxs then return nil end
	blockPad = math.max( 1, math.floor( tonumber( blockPad ) or 1 ) )
	local minBX = math.floor( mins.x / MC.BS ) - blockPad
	local minBY = math.floor( mins.y / MC.BS ) - blockPad
	local minBZ = math.floor( mins.z / MC.BS ) - blockPad
	local maxBX = math.floor( maxs.x / MC.BS ) + blockPad
	local maxBY = math.floor( maxs.y / MC.BS ) + blockPad
	local maxBZ = math.floor( maxs.z / MC.BS ) + blockPad
	addClientChunkLocalBoundsCollisionInterest( desired, minBX, minBY, minBZ, maxBX, maxBY, maxBZ, true, onlyCX, onlyCY, onlyCZ )
	return minBX, minBY, minBZ, maxBX, maxBY, maxBZ
end

local function collectClientPlayerAABBCollisionInterestKeys( lp, desired )
	if not IsValid( lp ) then return nil end
	local mins, maxs = lp:WorldSpaceAABB()
	if not mins or not maxs then return nil end
	local onlyCX, onlyCY, onlyCZ
	if not clientCollisionCrossChunkEnabled() then
		local pos = lp.WorldSpaceCenter and lp:WorldSpaceCenter() or lp:GetPos()
		local bx, by, bz = MC.WorldToCell( pos )
		onlyCX, onlyCY, onlyCZ = MC.CellToChunk( bx, by, bz )
	end
	local minBX, minBY, minBZ, maxBX, maxBY, maxBZ = addClientAABBCollisionInterest( desired, mins, maxs, 1, onlyCX, onlyCY, onlyCZ )
	local minCX, minCY, minCZ = MC.CellToChunk( minBX, minBY, minBZ )
	local maxCX, maxCY, maxCZ = MC.CellToChunk( maxBX, maxBY, maxBZ )
	local sigMinKey = onlyCX ~= nil and MC.ChunkKey( onlyCX, onlyCY, onlyCZ ) or MC.ChunkKey( minCX, minCY, minCZ )
	local sigMaxKey = onlyCX ~= nil and sigMinKey or MC.ChunkKey( maxCX, maxCY, maxCZ )
	return sigMinKey .. "|" .. sigMaxKey
		.. "|" .. minBX .. ":" .. minBY .. ":" .. minBZ .. "|" .. maxBX .. ":" .. maxBY .. ":" .. maxBZ
end

local function collectClientAimCollisionInterestKeys( lp, desired )
	if not IsValid( lp ) then return nil end
	local aimDist = collisionAimDistance()
	local hit = MC.PlayerBlockAim and MC.PlayerBlockAim( lp, aimDist ) or nil
	if not hit or not hit.bx then return nil end
	local radius = clientCollisionAimRadius()
	local clampToHitChunk = not clientCollisionCrossChunkEnabled()
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
	local desired = {}

	if enabled and radius > 0 and IsValid( lp ) then
		local pos = lp.WorldSpaceCenter and lp:WorldSpaceCenter() or lp:GetPos()
		local bx, by, bz = MC.WorldToCell( pos )
		local cx, cy, cz = MC.CellToChunk( bx, by, bz )
		centerKey = MC.ChunkKey( cx, cy, cz )
		aabbKey = collectClientPlayerAABBCollisionInterestKeys( lp, desired )
		aimKey = collectClientAimCollisionInterestKeys( lp, desired )
	end

	if not force and centerKey == LastClientCollisionCenterKey
	and radius == LastClientCollisionRadius and enabled == LastClientCollisionEnabled
	and crossChunk == LastClientCollisionCrossChunk
	and aimKey == LastClientCollisionAimKey and aabbKey == LastClientCollisionAABBKey then
		return
	end

	local old = MC.ClientCollisionInterest or {}
	MC.ClientCollisionInterest = desired
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

-- should the face between `cur` and neighbour `nb` be drawn?
local function sameLiquidKind( cur, nb )
	if not MC.LiquidKind then return false end
	local curKind = MC.LiquidKind( cur )
	if not curKind then return false end
	return curKind == MC.LiquidKind( nb )
end

local function visible( cur, nb, nbOrient )
	if nb == 0 then return true end
	if sameLiquidKind( cur, nb ) then return false end
	local d = MC.Blocks[nb]
	if d and d.transparent then return nb ~= cur end
	if MC.BlockIsFullCube and not MC.BlockIsFullCube( nb, nbOrient ) then return true end
	return false
end

------------------------------------------------------------------ mesh lifecycle
local function destroyMeshList( store, key )
	local list = store[key]
	if not list then return end
	for i = 1, #list do
		if list[i] then list[i]:Destroy() end
	end
	store[key] = nil
end

local function destroySectionMeshList( list )
	if not list then return end
	for i = 1, #list do
		if list[i] then list[i]:Destroy() end
	end
end

local function sectionIndexForLocal( lx, ly, lz )
	local sx = math.floor( lx / RENDER_SECTION_SIZE )
	local sy = math.floor( ly / RENDER_SECTION_SIZE )
	local sz = math.floor( lz / RENDER_SECTION_SIZE )
	return sx + sy * RENDER_SECTIONS_XY + sz * RENDER_SECTIONS_XY * RENDER_SECTIONS_XY + 1
end

local function rebuildFlatMeshLists( key )
	local sections = MC.MeshSections[key]
	if not sections then
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
		return
	end
	local opaque, translucent = {}, {}
	local totalSections = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
	for i = 1, totalSections do
		local section = sections[i]
		if section then
			for j = 1, #( section.opaque or {} ) do opaque[#opaque + 1] = section.opaque[j] end
			for j = 1, #( section.translucent or {} ) do translucent[#translucent + 1] = section.translucent[j] end
		end
	end
	MC.Meshes[key] = #opaque > 0 and opaque or nil
	MC.MeshesTrans[key] = #translucent > 0 and translucent or nil
end

function MC.FreeChunkMesh( key )
	if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	local sections = MC.MeshSections[key]
	if sections then
		for _, section in pairs( sections ) do
			destroySectionMeshList( section.opaque )
			destroySectionMeshList( section.translucent )
		end
		MC.MeshSections[key] = nil
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
		return
	end
	destroyMeshList( MC.Meshes, key )
	destroyMeshList( MC.MeshesTrans, key )
end

local DecodeLocal = MC.DecodeLocal

local function rotatedUVFlags( uf, vf, rot, flipU, flipV )
	rot = rot % 4
	if rot == 1 then uf, vf = vf, 1 - uf
	elseif rot == 2 then uf, vf = 1 - uf, 1 - vf
	elseif rot == 3 then uf, vf = 1 - vf, uf end
	if flipU then uf = 1 - uf end
	if flipV then vf = 1 - vf end
	return uf, vf
end

local function tileUVRect( tile, uv )
	if not uv then return MC.TileUV( tile ) end
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	local baseX = col * stride + pad
	local baseY = row * stride + pad
	local u0 = baseX + ( tonumber( uv[1] ) or 0 ) / 16 * A.TILE + inset
	local v0 = baseY + ( tonumber( uv[2] ) or 0 ) / 16 * A.TILE + inset
	local u1 = baseX + ( tonumber( uv[3] ) or 16 ) / 16 * A.TILE - inset
	local v1 = baseY + ( tonumber( uv[4] ) or 16 ) / 16 * A.TILE - inset
	return u0 / A.W, v0 / A.H, u1 / A.W, v1 / A.H
end

local function tileUVPoint( tile, uv )
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	local u = tonumber( uv and uv[1] ) or 0
	local v = tonumber( uv and uv[2] ) or 0
	local px = col * stride + pad + u / 16 * A.TILE
	local py = row * stride + pad + v / 16 * A.TILE
	if u <= 0 then px = px + inset elseif u >= 16 then px = px - inset end
	if v <= 0 then py = py + inset elseif v >= 16 then py = py - inset end
	return px / A.W, py / A.H
end

local function bakedFaceData( id, face, orient )
	local b = MC.Blocks[id]
	if not b or not b.baked then return nil end
	local baked = b.baked[orient] or b.baked[MC.DefaultOrient( id )] or b.baked[0]
	return baked and baked[face] or nil
end

local EPS = 0.0001

local BOX_FACE_CORNERS = {
	[1] = function( b ) return { { b[1], b[2], b[6] }, { b[4], b[2], b[6] }, { b[4], b[5], b[6] }, { b[1], b[5], b[6] } } end,
	[2] = function( b ) return { { b[1], b[5], b[3] }, { b[4], b[5], b[3] }, { b[4], b[2], b[3] }, { b[1], b[2], b[3] } } end,
	[3] = function( b ) return { { b[4], b[2], b[3] }, { b[4], b[5], b[3] }, { b[4], b[5], b[6] }, { b[4], b[2], b[6] } } end,
	[4] = function( b ) return { { b[1], b[5], b[3] }, { b[1], b[2], b[3] }, { b[1], b[2], b[6] }, { b[1], b[5], b[6] } } end,
	[5] = function( b ) return { { b[4], b[5], b[3] }, { b[1], b[5], b[3] }, { b[1], b[5], b[6] }, { b[4], b[5], b[6] } } end,
	[6] = function( b ) return { { b[1], b[2], b[3] }, { b[4], b[2], b[3] }, { b[4], b[2], b[6] }, { b[1], b[2], b[6] } } end,
}

local BOX_UV_FLAGS = {
	{ 0, 1 },
	{ 1, 1 },
	{ 1, 0 },
	{ 0, 0 },
}

local function rotateModelXY( x, y, steps )
	steps = steps % 4
	if steps == 1 then return 1 - y, x end
	if steps == 2 then return 1 - x, 1 - y end
	if steps == 3 then return y, 1 - x end
	return x, y
end

local function rotateModelXZ( y, z, steps )
	steps = steps % 4
	if steps == 1 then return 1 - z, y end
	if steps == 2 then return 1 - y, 1 - z end
	if steps == 3 then return z, 1 - y end
	return y, z
end

local function rotateModelFaceZ( face, steps )
	steps = steps % 4
	for _ = 1, steps do
		if face == MC.Face.YN then face = MC.Face.XP
		elseif face == MC.Face.XP then face = MC.Face.YP
		elseif face == MC.Face.YP then face = MC.Face.XN
		elseif face == MC.Face.XN then face = MC.Face.YN end
	end
	return face
end

local function rotateModelFaceX( face, steps )
	steps = steps % 4
	for _ = 1, steps do
		if face == MC.Face.YN then face = MC.Face.BOTTOM
		elseif face == MC.Face.BOTTOM then face = MC.Face.YP
		elseif face == MC.Face.YP then face = MC.Face.TOP
		elseif face == MC.Face.TOP then face = MC.Face.YN end
	end
	return face
end

local function modelOrientSteps( b, orient )
	if not b then return 0, 0 end
	orient = MC.NormalizeOrient( b.id, orient )
	if b.orient == "axis" then
		if orient == MC.Axis.X then return 1, 1 end
		if orient == MC.Axis.Z then return 1, 0 end
		return 0, 0
	end
	if b.orient ~= "horizontal_facing" and b.orient ~= "facing" and b.orient ~= "door" and b.orient ~= "bed" then return 0, 0 end
	if b.orient == "facing" then
		if orient == MC.Direction.DOWN then return 1, 0 end
		if orient == MC.Direction.UP then return 3, 0 end
	end
	if b.orient == "door" or b.orient == "bed" then
		orient = MC.BlockHorizontalFacingForOrient and MC.BlockHorizontalFacingForOrient( b, orient ) or orient
	end
	if orient == MC.Direction.EAST then return 0, 1 end
	if orient == MC.Direction.SOUTH then return 0, 2 end
	if orient == MC.Direction.WEST then return 0, 3 end
	return 0, 0
end

local function rotatedModelQuads( b, orient )
	local data = MC.BlockModelData and MC.BlockModelData( b, orient ) or b
	if not data or not data.modelQuads then return nil end
	local xSteps, zSteps = modelOrientSteps( b, orient )
	if xSteps == 0 and zSteps == 0 then return data.modelQuads end
	data._rotatedModelQuads = data._rotatedModelQuads or {}
	local cacheKey = xSteps .. ":" .. zSteps
	if data._rotatedModelQuads[cacheKey] then return data._rotatedModelQuads[cacheKey] end
	local out = {}
	for qi, quad in ipairs( data.modelQuads ) do
		local verts = {}
		for vi, v in ipairs( quad.verts or {} ) do
			local y, z = rotateModelXZ( v.y, v.z, xSteps )
			local x
			x, y = rotateModelXY( v.x, y, zSteps )
			verts[vi] = { x = x, y = y, z = v.z, u = v.u, v = v.v }
			verts[vi].z = z
		end
		out[qi] = {
			face = rotateModelFaceZ( rotateModelFaceX( quad.face or MC.Face.TOP, xSteps ), zSteps ),
			tile = quad.tile,
			uv = quad.uv,
			rot = quad.rot or 0,
			verts = verts,
		}
	end
	data._rotatedModelQuads[cacheKey] = out
	return out
end

local function cornerUV16( face, c )
	if face == MC.Face.TOP then return { c[1] * 16, ( 1 - c[2] ) * 16 } end
	if face == MC.Face.BOTTOM then return { c[1] * 16, c[2] * 16 } end
	if face == MC.Face.XP then return { c[2] * 16, ( 1 - c[3] ) * 16 } end
	if face == MC.Face.XN then return { ( 1 - c[2] ) * 16, ( 1 - c[3] ) * 16 } end
	if face == MC.Face.YP then return { ( 1 - c[1] ) * 16, ( 1 - c[3] ) * 16 } end
	return { c[1] * 16, ( 1 - c[3] ) * 16 }
end

local function paneSideTile( b )
	if not b or not b.name then return b and b.side or 0 end
	-- bar blocks (iron_bars, copper_bars variants) keep their own lattice texture
	if b.connection == "bars" then return b.side end
	if b.name == "glass_pane" and MC.Tiles and MC.Tiles.glass then return MC.Tiles.glass end
	local glassName = string.match( b.name, "^(.*_stained_glass)_pane$" )
	if glassName and MC.Tiles and MC.Tiles[glassName] ~= nil then return MC.Tiles[glassName] end
	return b.side
end

-- connection-arm direction tag -> the face at the open end of that arm
local ARM_END_FACE = {
	yn = MC.Face.YN,
	yp = MC.Face.YP,
	xn = MC.Face.XN,
	xp = MC.Face.XP,
}
local PANE_ARM_EDGE_UV = { 7, 0, 9, 7 }

local function dynamicShapeFaceData( b, face, box )
	if not b then return nil end
	if b.connection == "pipe6" then
		return { tile = b.side, rot = 0 }
	end
	if MC.IsPaneBlock and MC.IsPaneBlock( b.id ) then
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then
			if box and box.part == "arm" then
				return { tile = b.top, rot = 0, uv = PANE_ARM_EDGE_UV }
			end
			return { tile = b.top, rot = 0 }
		end
		-- the open end of an arm shows the pane edge strip, like Minecraft's
		-- cullfaced #edge face on the pane side models
		if box and box.part == "arm" and ARM_END_FACE[box.dir] == face then
			return { tile = b.top, rot = 0 }
		end
		return { tile = paneSideTile( b ), rot = 0 }
	end
	if MC.IsFenceBlock and MC.IsFenceBlock( b.id ) then
		return { tile = b.side, rot = 0 }
	end
	return nil
end

local function rectForFace( box, face )
	if face == MC.Face.TOP or face == MC.Face.BOTTOM then return box[1], box[4], box[2], box[5] end
	if face == MC.Face.XP or face == MC.Face.XN then return box[2], box[5], box[3], box[6] end
	return box[1], box[4], box[3], box[6]
end

local function facePlane( box, face )
	if face == MC.Face.TOP then return box[6] end
	if face == MC.Face.BOTTOM then return box[3] end
	if face == MC.Face.XP then return box[4] end
	if face == MC.Face.XN then return box[1] end
	if face == MC.Face.YP then return box[5] end
	return box[2]
end

local function coverRectForBox( box, face, plane, ox, oy, oz )
	local x0, y0, z0 = box[1] + ox, box[2] + oy, box[3] + oz
	local x1, y1, z1 = box[4] + ox, box[5] + oy, box[6] + oz
	if face == MC.Face.TOP and math.abs( z0 - plane ) <= EPS then return x0, x1, y0, y1 end
	if face == MC.Face.BOTTOM and math.abs( z1 - plane ) <= EPS then return x0, x1, y0, y1 end
	if face == MC.Face.XP and math.abs( x0 - plane ) <= EPS then return y0, y1, z0, z1 end
	if face == MC.Face.XN and math.abs( x1 - plane ) <= EPS then return y0, y1, z0, z1 end
	if face == MC.Face.YP and math.abs( y0 - plane ) <= EPS then return x0, x1, z0, z1 end
	if face == MC.Face.YN and math.abs( y1 - plane ) <= EPS then return x0, x1, z0, z1 end
	return nil
end

local function addEdge( list, value, lo, hi )
	if value > lo + EPS and value < hi - EPS then list[#list + 1] = value end
end

local function pointInRect( a, b, r )
	return a >= r[1] - EPS and a <= r[2] + EPS and b >= r[3] - EPS and b <= r[4] + EPS
end

local function rectCovered( a0, a1, b0, b1, covers )
	if #covers == 0 then return false end
	local as = { a0, a1 }
	local bs = { b0, b1 }
	for _, r in ipairs( covers ) do
		addEdge( as, math.max( a0, math.min( a1, r[1] ) ), a0, a1 )
		addEdge( as, math.max( a0, math.min( a1, r[2] ) ), a0, a1 )
		addEdge( bs, math.max( b0, math.min( b1, r[3] ) ), b0, b1 )
		addEdge( bs, math.max( b0, math.min( b1, r[4] ) ), b0, b1 )
	end
	table.sort( as )
	table.sort( bs )
	for ai = 1, #as - 1 do
		for bi = 1, #bs - 1 do
			local ma = ( as[ai] + as[ai + 1] ) * 0.5
			local mb = ( bs[bi] + bs[bi + 1] ) * 0.5
			local ok = false
			for _, r in ipairs( covers ) do
				if pointInRect( ma, mb, r ) then ok = true break end
			end
			if not ok then return false end
		end
	end
	return true
end

local function coveredByBoxes( targetBox, face, boxes, ox, oy, oz )
	local plane = facePlane( targetBox, face )
	local a0, a1, b0, b1 = rectForFace( targetBox, face )
	local covers = {}
	for _, box in ipairs( boxes or {} ) do
		if box ~= targetBox then
			local ca0, ca1, cb0, cb1 = coverRectForBox( box, face, plane, ox or 0, oy or 0, oz or 0 )
			if ca0 and ca1 > a0 + EPS and ca0 < a1 - EPS and cb1 > b0 + EPS and cb0 < b1 - EPS then
				covers[#covers + 1] = { math.max( a0, ca0 ), math.min( a1, ca1 ), math.max( b0, cb0 ), math.min( b1, cb1 ) }
			end
		end
	end
	return rectCovered( a0, a1, b0, b1, covers )
end

local function shapeFaceCovered( cur, box, face, boxes, bx, by, bz )
	if coveredByBoxes( box, face, boxes, 0, 0, 0 ) then return true end
	local plane = facePlane( box, face )
	local off = FACES[face].off
	if ( face == MC.Face.TOP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.BOTTOM and math.abs( plane ) > EPS )
	or ( face == MC.Face.XP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.XN and math.abs( plane ) > EPS )
	or ( face == MC.Face.YP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.YN and math.abs( plane ) > EPS ) then
		return false
	end
	local nb = MC.GetBlock( bx + off[1], by + off[2], bz + off[3] )
	if nb == 0 then return false end
	if sameLiquidKind( cur, nb ) then return true end
	local d = MC.Blocks[nb]
	if d and d.transparent and not ( MC.IsPaneBlock and MC.IsPaneBlock( nb ) ) then return false end
	local nbOrient = MC.GetBlockOrient( bx + off[1], by + off[2], bz + off[3] )
	return coveredByBoxes( box, face, MC.BlockBoxes( nb, nbOrient, bx + off[1], by + off[2], bz + off[3] ), off[1], off[2], off[3] )
end

function MC.BuildChunkMesh( key, sectionIndex )
	local buildStart = SysTime()
	if not sectionIndex then
		MC.FreeChunkMesh( key )
	end

	local chunk = MC.GetChunkByKey( key )
	if not chunk or chunk.count == 0 then
		if sectionIndex then
			local sections = MC.MeshSections[key]
			local old = sections and sections[sectionIndex]
			if old then
				destroySectionMeshList( old.opaque )
				destroySectionMeshList( old.translucent )
				sections[sectionIndex] = nil
				rebuildFlatMeshLists( key )
			end
		else
			MC.FreeChunkMesh( key )
		end
		MC.RenderStats.lastMeshBuildMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
		MC.RenderStats.lastMeshKey = key
		MC.RenderStats.lastMeshSection = sectionIndex or "full"
		MC.RenderStats.lastMeshBlocks = 0
		MC.RenderStats.lastOpaqueMeshes = 0
		MC.RenderStats.lastTranslucentMeshes = 0
		return
	end

	local bxo = chunk.cx * CS
	local byo = chunk.cy * CS
	local bzo = chunk.cz * MC.CH
	chunk.orients = chunk.orients or {}

	local sectionBuffers = {}
	local cur

	local function newMeshBuffer( material )
		return { list = {}, verts = {}, nv = 0, material = material }
	end

	local function buffersForLocal( lx, ly, lz )
		local index = sectionIndexForLocal( lx, ly, lz )
		if sectionIndex and index ~= sectionIndex then return nil end
		local buffers = sectionBuffers[index]
		if not buffers then
			buffers = {
				opaque = newMeshBuffer( MC.Material ),
				translucent = newMeshBuffer( MC.MaterialTranslucent ),
			}
			sectionBuffers[index] = buffers
		end
		return buffers
	end

	local function flush( buf )
		if buf.nv == 0 then return end
		local m = Mesh( buf.material )
		m:BuildFromTriangles( buf.verts )
		buf.list[#buf.list + 1] = m
		buf.verts = {}
		buf.nv = 0
	end

	local function push( vert )
		local nv = cur.nv + 1
		cur.nv = nv
		cur.verts[nv] = vert
		if nv >= VERT_LIMIT then flush( cur ) end
	end

	local function appendMeshList( out, list )
		for i = 1, #list do
			out[#out + 1] = list[i]
		end
	end

	local function flushSectionBuffers()
		local opaqueMeshes = {}
		local translucentMeshes = {}
		local totalSections = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = sectionBuffers[i]
			if buffers then
				flush( buffers.opaque )
				flush( buffers.translucent )
				appendMeshList( opaqueMeshes, buffers.opaque.list )
				appendMeshList( translucentMeshes, buffers.translucent.list )
			end
		end
		return opaqueMeshes, translucentMeshes
	end

	local function emitQuad( corners, normal, color, tile )
		for t = 1, 6 do
			local cn = corners[TRI[t]]
			local u, v = tileUVPoint( tile, { cn[4], cn[5] } )
			push( {
				pos    = Vector( cn[1], cn[2], cn[3] ),
				normal = normal,
				u      = u,
				v      = v,
				color  = color,
			} )
		end
	end

	local function emitCrossBlock( id, wx, wy, wz )
		local b = MC.Blocks[id]
		local tile = b and b.side or 0
		local z0, z1 = wz, wz + BS
		local a, c = 0.08 * BS, 0.92 * BS
		local p1 = {
			{ wx + a, wy + a, z0, 0, 16 },
			{ wx + c, wy + c, z0, 16, 16 },
			{ wx + c, wy + c, z1, 16, 0 },
			{ wx + a, wy + a, z1, 0, 0 },
		}
		local p2 = {
			{ wx + c, wy + a, z0, 0, 16 },
			{ wx + a, wy + c, z0, 16, 16 },
			{ wx + a, wy + c, z1, 16, 0 },
			{ wx + c, wy + a, z1, 0, 0 },
		}
		emitQuad( p1, N_YP, SH_TOP, tile )
		emitQuad( { p1[4], p1[3], p1[2], p1[1] }, N_YN, SH_TOP, tile )
		emitQuad( p2, N_XP, SH_TOP, tile )
		emitQuad( { p2[4], p2[3], p2[2], p2[1] }, N_XN, SH_TOP, tile )
	end

	local function emitModelBlock( b, orient, wx, wy, wz )
		local quads = rotatedModelQuads( b, orient )
		if not quads then return false end
		local mirrorU = b.orient == "door"
		for _, quad in ipairs( quads ) do
			local face = FACES[quad.face or MC.Face.TOP] or FACES[MC.Face.TOP]
			local u0, v0, u1, v1 = tileUVRect( quad.tile or 0, quad.uv )
			for t = 1, 6 do
				local vert = quad.verts[TRI[t]]
				local uf, vf = rotatedUVFlags( vert.u or 0, vert.v or 0, quad.rot or 0 )
				if mirrorU then uf = 1 - uf end
				push( {
					pos    = Vector( wx + vert.x * BS, wy + vert.y * BS, wz + vert.z * BS ),
					normal = face.n,
					u      = uf == 1 and u1 or u0,
					v      = vf == 1 and v1 or v0,
					color  = face.sh,
				} )
			end
		end
		return true
	end

	for li, id in pairs( chunk.blocks ) do
		local orient = MC.NormalizeOrient( id, chunk.orients[li] )
		local lx, ly, lz = DecodeLocal( li )
		local buffers = buffersForLocal( lx, ly, lz )
		if not buffers then continue end
		local bx, by, bz = bxo + lx, byo + ly, bzo + lz
		local wx, wy, wz = lx * BS, ly * BS, lz * BS

		cur = ( MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) ) and buffers.translucent or buffers.opaque

		local b = MC.Blocks[id]
		if b and b.shape == "cross" then
			emitCrossBlock( id, wx, wy, wz )
		elseif b and b.shape == "model" and not ( ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) or b.connection == "pipe6" ) and emitModelBlock( b, orient, wx, wy, wz ) then
			-- rendered from exact Minecraft model quads; boxes remain for collision/outline
		elseif MC.BlockIsFullCube( id, orient ) then
			for f = 1, 6 do
				local face = FACES[f]
				local o = face.off
				local nbx, nby, nbz = bx + o[1], by + o[2], bz + o[3]
				if visible( id, MC.GetBlock( nbx, nby, nbz ), MC.GetBlockOrient( nbx, nby, nbz ) ) then
					local baked = bakedFaceData( id, f, orient )
					local tile, rot, flipU, flipV
					local u0, v0, u1, v1
					if baked then
						tile = baked.tile
						rot = baked.rot or 0
						u0, v0, u1, v1 = tileUVRect( tile, baked.uv )
					else
						tile, rot, flipU, flipV = MC.BlockFace( id, f, orient )
						u0, v0, u1, v1 = MC.TileUV( tile )
					end
					local corners = face.c
					local nrm, col = face.n, face.sh

					for t = 1, 6 do
						local cn = corners[ TRI[t] ]
						local u, v
						if baked and baked.uvs then
							u, v = tileUVPoint( tile, baked.uvs[TRI[t]] )
						else
							local uf, vf = rotatedUVFlags( cn[4], cn[5], rot or 0, flipU, flipV )
							u = uf == 1 and u1 or u0
							v = vf == 1 and v1 or v0
						end
						push( {
							pos    = Vector( wx + cn[1] * BS, wy + cn[2] * BS, wz + cn[3] * BS ),
							normal = nrm,
							u      = u,
							v      = v,
							color  = col,
						} )
					end
				end
			end
		else
			-- fence/pane/pipe boxes come from the runtime connection logic, so their
			-- indices do not line up with the generator's static boxFaces list;
			-- only the centre post (box 1) may take static face data
			local isPipe6Shape = b and b.connection == "pipe6"
			local isConnShape = ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) or isPipe6Shape
			local boxes = MC.BlockBoxes( id, orient, bx, by, bz )
			for boxIndex, box in ipairs( boxes or {} ) do
				for f = 1, 6 do
					if not shapeFaceCovered( id, box, f, boxes, bx, by, bz ) then
						local face = FACES[f]
						local modelFaces = b and b.boxFaces
						if isPipe6Shape then modelFaces = nil end
						local fd = modelFaces and modelFaces[boxIndex] and modelFaces[boxIndex][f]
						if isConnShape and boxIndex > 1 then fd = nil end
						local dynamicFd = dynamicShapeFaceData( b, f, box )
						if not modelFaces or fd or dynamicFd then
							fd = fd or dynamicFd
							local tile = fd and fd.tile or MC.BlockFace( id, f, orient )
							local u0, v0, u1, v1
							if fd and fd.uv then
								u0, v0, u1, v1 = tileUVRect( tile, fd.uv )
							end
							local corners = BOX_FACE_CORNERS[f]( box )
							local nrm, col = face.n, face.sh
							for t = 1, 6 do
								local ci = TRI[t]
								local cn = corners[ci]
								local u, v
								if fd and fd.uv then
									local flags = BOX_UV_FLAGS[ci]
									local uf, vf = rotatedUVFlags( flags[1], flags[2], fd.rot or 0 )
									u = uf == 1 and u1 or u0
									v = vf == 1 and v1 or v0
								else
									u, v = tileUVPoint( tile, cornerUV16( f, cn ) )
								end
								push( {
									pos    = Vector( wx + cn[1] * BS, wy + cn[2] * BS, wz + cn[3] * BS ),
									normal = nrm,
									u      = u,
									v      = v,
									color  = col,
								} )
							end
						end
					end
				end
			end
		end
	end

	local opaqueMeshes, translucentMeshes = flushSectionBuffers()

	if sectionIndex then
		MC.MeshSections[key] = MC.MeshSections[key] or {}
		local old = MC.MeshSections[key][sectionIndex]
		if old then
			destroySectionMeshList( old.opaque )
			destroySectionMeshList( old.translucent )
		end
		if #opaqueMeshes > 0 or #translucentMeshes > 0 then
			MC.MeshSections[key][sectionIndex] = { opaque = opaqueMeshes, translucent = translucentMeshes }
		else
			MC.MeshSections[key][sectionIndex] = nil
		end
		rebuildFlatMeshLists( key )
	else
		MC.MeshSections[key] = {}
		local totalSections = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = sectionBuffers[i]
			if buffers then
				MC.MeshSections[key][i] = {
					opaque = buffers.opaque.list,
					translucent = buffers.translucent.list,
				}
			end
		end
		rebuildFlatMeshLists( key )
	end
	MC.RenderStats.lastMeshBuildMS = math.Round( ( SysTime() - buildStart ) * 1000, 3 )
	MC.RenderStats.lastMeshKey = key
	MC.RenderStats.lastMeshSection = sectionIndex or "full"
	MC.RenderStats.lastMeshBlocks = chunk.count or 0
	MC.RenderStats.lastOpaqueMeshes = #opaqueMeshes
	MC.RenderStats.lastTranslucentMeshes = #translucentMeshes
end

------------------------------------------------------------------------- drawing
local function drawMeshList( list, material )
	if not list then return end
	render.SetMaterial( material )
	for i = 1, #list do
		list[i]:Draw()
	end
end

function MC.DrawChunk( key )
	drawMeshList( MC.Meshes[key], MC.Material )
end

function MC.DrawChunkTranslucent( key )
	drawMeshList( MC.MeshesTrans[key], MC.MaterialTranslucent )
end

local function drawAllChunks( store, drawFn )
	for key, list in pairs( store or {} ) do
		if list then
			local c = MC.GetChunkByKey( key )
			if c then
				local mat = Matrix()
				mat:SetTranslation( MC.ChunkWorldOrigin( c.cx, c.cy, c.cz ) )
				cam.PushModelMatrix( mat )
					drawFn( key )
				cam.PopModelMatrix()
			end
		end
	end
end

hook.Remove( "PostDrawOpaqueRenderables", "mc_draw_chunks" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_draw_chunks" )
hook.Add( "PostDrawOpaqueRenderables", "mc_draw_chunks", function()
	if not meshRenderingEnabled() then return end
	drawAllChunks( MC.Meshes, MC.DrawChunk )
end )
-- translucent blocks only; the bulk of the world stays in the opaque pass above
hook.Add( "PostDrawTranslucentRenderables", "mc_draw_chunks", function()
	if not meshRenderingEnabled() then return end
	drawAllChunks( MC.MeshesTrans, MC.DrawChunkTranslucent )
end )

------------------------------------------------------------------- dirty tracking
function MC.MarkChunkDirty( key )
	MC.MeshDirty[key] = true
	MC.MeshDirtyRateLimited[key] = nil
end

local function markChunkSectionDirty( key, sectionIndex, rateLimited )
	if not key or not sectionIndex then return end
	if MC.MeshDirty[key] == true then
		if not rateLimited then MC.MeshDirtyRateLimited[key] = nil end
		return
	end
	local sections = MC.MeshDirty[key]
	if not sections then
		sections = {}
		MC.MeshDirty[key] = sections
	end
	MC.MeshDirty[key][sectionIndex] = true
	if rateLimited then
		if MC.MeshDirtyRateLimited[key] ~= false then
			MC.MeshDirtyRateLimited[key] = true
		end
	else
		MC.MeshDirtyRateLimited[key] = nil
	end
end

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
	if not MC.PhysDirtyBulk[key] then
		MC.PhysDirtyBulk[key] = true
		MC.PhysDirtyBulkOrder[#MC.PhysDirtyBulkOrder + 1] = key
	end
end

-- a block changed: its own chunk and any chunk owning a face-neighbour cell
-- may need a rebuild (boundary faces).
function MC.MarkDirty( bx, by, bz, rateLimited )
	local function mark( x, y, z )
		local cx, cy, cz, li = MC.CellToChunk( x, y, z )
		local lx, ly, lz = DecodeLocal( li )
		local key = MC.ChunkKey( cx, cy, cz )
		local sectionIndex = sectionIndexForLocal( lx, ly, lz )
		markChunkSectionDirty( key, sectionIndex, rateLimited == true )
	end
	mark( bx, by, bz )
	mark( bx + 1, by, bz ) ; mark( bx - 1, by, bz )
	mark( bx, by + 1, bz ) ; mark( bx, by - 1, bz )
	mark( bx, by, bz + 1 ) ; mark( bx, by, bz - 1 )
end

local function chunkDistanceScore( key )
	local lp = LocalPlayer()
	if not IsValid( lp ) then return 0 end
	local cx, cy, cz = MC.ChunkKeyToCoords( key )
	if not cx then return math.huge end
	local pos = lp.WorldSpaceCenter and lp:WorldSpaceCenter() or lp:GetPos()
	local bx, by, bz = MC.WorldToCell( pos )
	local pcx, pcy, pcz = MC.CellToChunk( bx, by, bz )
	local dx, dy, dz = cx - pcx, cy - pcy, cz - pcz
	return dx * dx + dy * dy + dz * dz * 2
end

local function nextDirtyMeshKeys()
	local keys = {}
	for key in pairs( MC.MeshDirty ) do
		keys[#keys + 1] = key
	end
	table.sort( keys, function( a, b )
		return chunkDistanceScore( a ) < chunkDistanceScore( b )
	end )
	return keys
end

local function explosionMeshSectionBudget()
	local cvar = GetConVar and GetConVar( "mc_explosion_mesh_sections_per_frame" ) or nil
	local budget = cvar and cvar:GetInt() or ( MC.Config.ExplosionMeshSectionsPerFrame or 4 )
	budget = math.floor( tonumber( budget ) or 0 )
	if budget <= 0 then return math.huge end
	return budget
end

local function explosionMeshInterval()
	local cvar = GetConVar and GetConVar( "mc_explosion_mesh_interval" ) or nil
	local interval = cvar and cvar:GetFloat() or ( MC.Config.ExplosionMeshInterval or 0.12 )
	return math.max( 0, tonumber( interval ) or 0.12 )
end

local function bulkCollisionInterval()
	local cvar = GetConVar and GetConVar( "mc_bulk_collision_interval" ) or nil
	local interval = cvar and cvar:GetFloat() or ( MC.Config.BulkCollisionInterval or 0.12 )
	return math.max( 0, tonumber( interval ) or 0.12 )
end

local function bulkCollisionChunksPerInterval()
	local cvar = GetConVar and GetConVar( "mc_bulk_collision_chunks_per_interval" ) or nil
	local count = cvar and cvar:GetInt() or ( MC.Config.BulkCollisionChunksPerInterval or 1 )
	return math.max( 1, math.floor( tonumber( count ) or 1 ) )
end

local function flushBulkCollisionQueue()
	local now = CurTime()
	if now < ( NextBulkCollisionRebuildAt or 0 ) then return end
	local order = MC.PhysDirtyBulkOrder or {}
	local bulk = MC.PhysDirtyBulk or {}
	local limit = bulkCollisionChunksPerInterval()
	local built = 0

	while built < limit and #order > 0 do
		local key = table.remove( order, 1 )
		if bulk[key] and MC.PhysDirty[key] then
			rebuildChunkPhys( key, clientCollisionEnabled() )
			built = built + 1
		else
			bulk[key] = nil
		end
	end

	if built > 0 then
		NextBulkCollisionRebuildAt = now + bulkCollisionInterval()
	end
end

local function buildDirtyMeshKey( key, sections, rateLimited, budget )
	if sections == true then
		if rateLimited and budget <= 0 then return 0 end
		MC.BuildChunkMesh( key )
		MC.MeshDirty[key] = nil
		MC.MeshDirtyRateLimited[key] = nil
		return 1
	end

	local built = 0
	for sectionIndex in pairs( sections ) do
		if rateLimited and built >= budget then break end
		MC.BuildChunkMesh( key, sectionIndex )
		sections[sectionIndex] = nil
		built = built + 1
	end

	if next( sections ) == nil then
		MC.MeshDirty[key] = nil
		MC.MeshDirtyRateLimited[key] = nil
	else
		MC.MeshDirty[key] = sections
	end
	return built
end

-- rebuild dirty meshes; explosion-driven edits are section-budgeted on a fixed
-- interval so one blast cannot force every affected mesh to rebuild at once.
hook.Remove( "Think", "mc_meshbuild" )
hook.Add( "Think", "mc_meshbuild", function()
	if next( MC.MeshDirty ) then
		local now = CurTime()
		local allowExplosionMesh = now >= NextExplosionMeshBuildAt
		local explosionBudget = allowExplosionMesh and explosionMeshSectionBudget() or 0
		local builtExplosionMesh = false
		for _, key in ipairs( nextDirtyMeshKeys() ) do
			local sections = MC.MeshDirty[key]
			local rateLimited = MC.MeshDirtyRateLimited[key] == true
			if rateLimited and not allowExplosionMesh then continue end
			local built = buildDirtyMeshKey( key, sections, rateLimited, explosionBudget )
			if rateLimited then
				if built > 0 then builtExplosionMesh = true end
				explosionBudget = explosionBudget - built
				if explosionBudget <= 0 then break end
			end
		end
		if builtExplosionMesh then
			NextExplosionMeshBuildAt = now + explosionMeshInterval()
		end
	end
	flushBulkCollisionQueue()
end )

-- free all meshes (used by mc_clear)
function MC.FreeAllMeshes()
	for key in pairs( MC.Meshes ) do MC.FreeChunkMesh( key ) end
	for key in pairs( MC.MeshesTrans ) do MC.FreeChunkMesh( key ) end
	MC.MeshDirtyRateLimited = {}
	if MC.ResetClientCollisionState then MC.ResetClientCollisionState() end
end
