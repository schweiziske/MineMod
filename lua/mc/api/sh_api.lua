--[[----------------------------------------------------------------------------
	MC : public API, shared layer (v1).

	The ONLY supported surface for external addons. Everything in MC.API:
	- late-binds to internals at call time (load order and autorefresh safe)
	- validates its inputs and returns "value|ok, err" instead of throwing
	- never leaks live internal tables (results are fresh copies)

	Block currency is the block-state id. Anywhere a "block" argument is
	accepted it may be:
	  number  -> a valid block-state id (NOT a legacy block id)
	  string  -> a blockstate spec: "stone", "minecraft:oak_stairs[facing=north]"
	  0 / nil / "air" -> air (removal)

	Events (hook.Run) fired by the core are listed in MC.API.Events.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}

local API = MC.API

API.VERSION = 1

-------------------------------------------------------------------- event core
-- Core write paths call these; they exist on both realms. Listener errors are
-- contained so a broken external addon can never abort a world transaction.
function MC.EventHasListeners( name )
	local registry = hook.GetTable()
	local listeners = registry and registry[name]
	return listeners ~= nil and next( listeners ) ~= nil
end

function MC.RunEvent( name, ... )
	local ok, result = pcall( hook.Run, name, ... )
	if not ok then
		local message = "[MC] event listener error in " .. tostring( name ) .. ": " .. tostring( result ) .. "\n"
		if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
		return nil
	end
	return result
end

------------------------------------------------------------------- ready state
local readyCallbacks = {}

function API.IsReady()
	return API._ready == true
end

-- Runs cb immediately if the API is ready, otherwise queues it. This is the
-- load-order safe way for an external addon to start using MC.API.
function API.OnReady( cb )
	if not isfunction( cb ) then return false end
	if API._ready then
		local ok, err = pcall( cb )
		if not ok then ErrorNoHalt( "[MC] API.OnReady callback error: " .. tostring( err ) .. "\n" ) end
		return true
	end
	readyCallbacks[#readyCallbacks + 1] = cb
	return true
end

-- Called once by the loader after the block/state registries have frozen.
function API._FireReady()
	if API._ready then return end
	API._ready = true
	MC.RunEvent( "MC.APIReady", API.VERSION )
	local queued = readyCallbacks
	readyCallbacks = {}
	for _, cb in ipairs( queued ) do
		local ok, err = pcall( cb )
		if not ok then ErrorNoHalt( "[MC] API.OnReady callback error: " .. tostring( err ) .. "\n" ) end
	end
end

--------------------------------------------------------------------- utilities
local function deepCopy( value, seen )
	if type( value ) ~= "table" then return value end
	seen = seen or {}
	if seen[value] then return seen[value] end
	local out = {}
	seen[value] = out
	for key, item in pairs( value ) do out[deepCopy( key, seen )] = deepCopy( item, seen ) end
	return out
end

API.DeepCopy = deepCopy

local function cellCoord( v )
	v = tonumber( v )
	if v == nil or v ~= v then return nil end -- reject nil and NaN
	return math.floor( v )
end

local function cellCoords( bx, by, bz )
	local x, y, z = cellCoord( bx ), cellCoord( by ), cellCoord( bz )
	if not x or not y or not z then return nil end
	return x, y, z
end

local function airStateId()
	if MC.StateFromLegacy then
		local stateId = MC.StateFromLegacy( 0, 0 )
		if stateId then return stateId end
	end
	return 0
end

-- Shared "block argument" resolver; see the header contract.
local function resolveStateInput( block )
	if block == nil or block == 0 or block == "air" or block == "minecraft:air" then
		return airStateId()
	end
	if isnumber( block ) then
		local stateId = math.floor( block )
		if MC.IsValidBlockState and MC.IsValidBlockState( stateId ) then return stateId end
		return nil, "invalid_state"
	end
	if isstring( block ) then
		if not MC.ParseBlockState then return nil, "state_registry_unavailable" end
		local stateId, err = MC.ParseBlockState( block )
		if not stateId then return nil, err or "invalid_state" end
		return stateId
	end
	return nil, "invalid_block_argument"
end

API.ResolveStateInput = resolveStateInput

-------------------------------------------------------------------- API.Coords
-- THREE distinct spaces exist; mixing them is the most common API mistake:
--   MC world space   the voxel world's own continuous frame. All cell math
--                    below, and every bx/by/bz in this API, live here.
--   engine space     what ent:GetPos() / EyePos() / traces return. Identical
--                    to world space on a normal map, but on InfMap worlds the
--                    active world adapter re-origins it per player, so the
--                    same engine vector means different cells for different
--                    players.
--   render space     world space shifted for drawing only (client).
-- Convert engine -> world with EngineToCell / EntityCell, never by handing a
-- raw ent:GetPos() to WorldToCell.
API.Coords = API.Coords or {}
local Coords = API.Coords

function Coords.BlockSize()
	return MC.BS or 36.5
end

-- MC world-space Vector -> integer cell coords.
function Coords.WorldToCell( pos )
	if not isvector( pos ) then return nil, nil, nil end
	return MC.WorldToCell( pos )
end

-- Engine-space Vector -> integer cell coords. context is the player/entity the
-- position came from; on InfMap worlds it selects the right origin offset, and
-- omitting it silently reads the wrong cell far from the map centre.
function Coords.EngineToCell( pos, context )
	if not isvector( pos ) then return nil, nil, nil end
	local worldPos = MC.EngineToWorldPos and MC.EngineToWorldPos( pos, context ) or pos
	return MC.WorldToCell( worldPos )
end

-- Cell an entity currently occupies (feet). InfMap-safe.
function Coords.EntityCell( ent )
	if not IsValid( ent ) then return nil, nil, nil end
	local worldPos = MC.EntityWorldPos and MC.EntityWorldPos( ent ) or ent:GetPos()
	return MC.WorldToCell( worldPos )
end

-- Cell an entity is looking from (eyes). InfMap-safe.
function Coords.EntityEyeCell( ent )
	if not IsValid( ent ) then return nil, nil, nil end
	local worldPos = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ent ) or ent:EyePos()
	return MC.WorldToCell( worldPos )
end

-- Min corner / center of a cell in MC world units.
function Coords.CellMin( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	return MC.CellWorldMin( x, y, z )
end

function Coords.CellCenter( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	return MC.CellWorldCenter( x, y, z )
end

-- Render-space counterparts. Only correct inside a client render hook of the
-- current frame; use these (not CellMin/CellCenter) to draw on InfMap worlds.
function Coords.CellRenderMin( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	if not MC.CellRenderMin then return MC.CellWorldMin( x, y, z ) end
	return MC.CellRenderMin( x, y, z )
end

function Coords.CellRenderCenter( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	if not MC.CellRenderCenter then return MC.CellWorldCenter( x, y, z ) end
	return MC.CellRenderCenter( x, y, z )
end

function Coords.CellToChunk( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil end
	return MC.CellToChunk( x, y, z )
end

--------------------------------------------------------------------- API.World
API.World = API.World or {}
local World = API.World

-- stateId at a cell; 0 = air. Never returns nil.
function World.GetBlockState( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return 0 end
	local stateId = MC.GetBlockState and MC.GetBlockState( x, y, z ) or 0
	return stateId or 0
end

function World.IsAir( bx, by, bz )
	return World.GetBlockState( bx, by, bz ) == 0
end

-- Fresh info table: { stateId, id, orient, name, mcid, spec }; nil for air.
function World.GetBlockInfo( bx, by, bz )
	local stateId = World.GetBlockState( bx, by, bz )
	if stateId == 0 then return nil end
	local id, orient = 0, 0
	if MC.LegacyFromState then
		id, orient = MC.LegacyFromState( stateId )
		id, orient = id or 0, orient or 0
	end
	local block = MC.Blocks and MC.Blocks[id] or nil
	local spec = MC.FormatBlockState and MC.FormatBlockState( stateId ) or nil
	return {
		stateId = stateId,
		id = id,
		orient = orient,
		name = block and block.name or nil,
		mcid = block and block.mcid or nil,
		spec = spec,
	}
end

-- Iterate every NON-AIR cell in the inclusive cell box, chunk-aware (skips
-- missing chunks wholesale). cb( bx, by, bz, stateId ); return false to stop.
--
-- Returns ok, skippedChunks. A chunk is skipped when it is not resident: on
-- lazy MCB4 worlds it may not be hydrated from disk yet, and on the client
-- horizontal column streaming only keeps chunks near the player. Both look
-- exactly like "all air" from in here, so ANY caller drawing a gameplay
-- conclusion from an empty result must check skippedChunks > 0 first.
function World.ForEachBlock( x1, y1, z1, x2, y2, z2, cb )
	if not isfunction( cb ) then return false, "invalid_callback" end
	local ax, ay, az = cellCoords( x1, y1, z1 )
	local bx2, by2, bz2 = cellCoords( x2, y2, z2 )
	if not ax or not bx2 then return false, "invalid_cell" end
	local minx, maxx = math.min( ax, bx2 ), math.max( ax, bx2 )
	local miny, maxy = math.min( ay, by2 ), math.max( ay, by2 )
	local minz, maxz = math.min( az, bz2 ), math.max( az, bz2 )
	if not MC.GetChunk or not MC.GetChunkBlockStateByLocalIndex then return false, "world_unavailable" end

	local CS, CH = MC.CS or 16, MC.CH or 32
	local skipped = 0
	for cz = math.floor( minz / CH ), math.floor( maxz / CH ) do
		for cy = math.floor( miny / CS ), math.floor( maxy / CS ) do
			for cx = math.floor( minx / CS ), math.floor( maxx / CS ) do
				local chunk = MC.GetChunk( cx, cy, cz )
				if not chunk then
					-- "Known empty" is loaded and really is air; anything else
					-- is an absence we cannot see through.
					if not ( MC.IsChunkLoaded and MC.IsChunkLoaded( cx, cy, cz ) ) then
						skipped = skipped + 1
					end
				else
					local x0, xEnd = math.max( minx, cx * CS ), math.min( maxx, cx * CS + CS - 1 )
					local y0, yEnd = math.max( miny, cy * CS ), math.min( maxy, cy * CS + CS - 1 )
					local z0, zEnd = math.max( minz, cz * CH ), math.min( maxz, cz * CH + CH - 1 )
					for bz = z0, zEnd do
						local rowZ = ( bz - cz * CH ) * CS * CS
						for by = y0, yEnd do
							local row = rowZ + ( by - cy * CS ) * CS
							for bxi = x0, xEnd do
								local stateId = MC.GetChunkBlockStateByLocalIndex( chunk, bxi - cx * CS + row )
								if stateId and stateId ~= 0 then
									if cb( bxi, by, bz, stateId ) == false then return true, skipped end
								end
							end
						end
					end
				end
			end
		end
	end
	return true, skipped
end

-- Fresh shape info for a world cell (selection boxes, collision, extent).
-- Box/convex tables are copies: safe to keep and mutate.
function World.GetCellShape( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	if not MC.GetBlockShapeInfo then return nil, "shape_api_unavailable" end
	local id = MC.GetBlock and MC.GetBlock( x, y, z ) or 0
	if id == 0 then return nil end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( x, y, z ) or 0
	local info = MC.GetBlockShapeInfo( id, orient, x, y, z )
	if not info then return nil end
	return {
		bx = x, by = y, bz = z,
		id = info.id,
		orient = info.orient,
		boxes = deepCopy( info.boxes ),
		collisionBoxes = deepCopy( info.collisionBoxes ),
		collisionConvexes = deepCopy( info.collisionConvexes ),
		extentLo = info.extentLo,
		extentHi = info.extentHi,
		hasCollision = info.hasCollision,
		fullCube = info.fullCube,
	}
end

-- Voxel-only ray trace (does not hit map/prop geometry). Result is a fresh
-- table: { bx, by, bz, StateId, HitPos, HitNormal, ... } or nil.
function World.TraceRay( startPos, dir, maxDist )
	if not isvector( startPos ) or not isvector( dir ) then return nil, "invalid_ray" end
	if not MC.TraceBlockRay then return nil, "trace_unavailable" end
	return MC.TraceBlockRay( startPos, dir, tonumber( maxDist ) or 0 )
end

function World.PlayerAim( ply, reach )
	if not IsValid( ply ) then return nil, "invalid_player" end
	if not MC.PlayerBlockAim then return nil, "trace_unavailable" end
	return MC.PlayerBlockAim( ply, tonumber( reach ) )
end

-- True when the cell's chunk is loaded (present in the world or known
-- empty). On lazy-loaded large worlds a false here means "not hydrated yet,
-- don't draw gameplay conclusions" - GetBlockState cannot tell that apart
-- from air on its own.
function World.IsCellLoaded( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x or not MC.IsChunkLoaded or not MC.CellToChunk then return false end
	local cx, cy, cz = MC.CellToChunk( x, y, z )
	return MC.IsChunkLoaded( cx, cy, cz ) == true
end

function World.IsChunkLoaded( cx, cy, cz )
	local x, y, z = cellCoords( cx, cy, cz )
	if not x or not MC.IsChunkLoaded then return false end
	return MC.IsChunkLoaded( x, y, z ) == true
end

-- Heightmap-level sky access; no lateral flood into overhangs. The realms
-- intentionally differ in strictness: the SERVER (authoritative for
-- gameplay) blocks on light opacity > 0 (leaves and water count as cover),
-- while the CLIENT reuses the render sky column, which only blocks on
-- opacity >= 15 (full cubes). Glass (opacity 0) never blocks on either.
function World.CanSeeSky( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	if SERVER then
		if not MC.SV or not MC.SV.CanSeeSky then return false, "lighting_unavailable" end
		return MC.SV.CanSeeSky( x, y, z )
	end
	if not MC.SkyExposedAt then return false, "lighting_unavailable" end
	return MC.SkyExposedAt( x, y, z ) == true
end

-- Read-only deep copy of the block entity record at a cell (or nil).
function World.GetBlockEntity( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	if not MC.GetBlockEntity then return nil, "block_entity_api_unavailable" end
	return MC.GetBlockEntity( x, y, z )
end

-------------------------------------------------------------------- API.Blocks
API.Blocks = API.Blocks or {}
local Blocks = API.Blocks

-- Accepts id / "stone" / "minecraft:stone" / alias. Fresh result table.
function Blocks.Resolve( input )
	if not MC.ResolveBlock then return nil, "block_registry_unavailable" end
	local resolved = MC.ResolveBlock( input )
	if not resolved then return nil, "unknown_block" end
	local defaultStateId = MC.DefaultBlockState and MC.DefaultBlockState( resolved.id ) or nil
	return {
		id = resolved.id,
		name = resolved.name,
		mcid = resolved.mcid,
		defaultStateId = defaultStateId,
	}
end

function Blocks.ParseState( spec )
	return resolveStateInput( spec )
end

function Blocks.FormatState( stateId )
	if not MC.FormatBlockState then return nil, "state_registry_unavailable" end
	return MC.FormatBlockState( stateId )
end

function Blocks.IsValidState( stateId )
	return MC.IsValidBlockState and MC.IsValidBlockState( stateId ) == true or false
end

-- Legacy block id owning a state (nil for invalid states).
function Blocks.StateBlockId( stateId )
	return MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
end

function Blocks.DefaultState( input )
	if not MC.DefaultBlockState then return nil, "state_registry_unavailable" end
	if isstring( input ) or isnumber( input ) then
		local stateId = MC.DefaultBlockState( input )
		if stateId then return stateId end
	end
	return nil, "unknown_block"
end

function Blocks.GetProperty( stateId, propertyName )
	if not MC.GetStateProperty then return nil, "state_registry_unavailable" end
	return MC.GetStateProperty( stateId, propertyName )
end

function Blocks.WithProperty( stateId, propertyName, value )
	if not MC.StateWith then return nil, "state_registry_unavailable" end
	return MC.StateWith( stateId, propertyName, value )
end

-- Localized display name. Numbers are ambiguous (legacy block ids and state
-- ids share the same integer range): a number naming a registered block is
-- treated as a BLOCK id. For state ids use DisplayNameForState.
function Blocks.DisplayName( idOrStateId )
	local block = MC.Blocks and MC.Blocks[idOrStateId] or nil
	if not block and MC.IsValidBlockState and MC.IsValidBlockState( idOrStateId ) and MC.BlockTypeForState then
		local id = MC.BlockTypeForState( idOrStateId )
		block = id and MC.Blocks and MC.Blocks[id] or nil
	end
	if not block then return nil, "unknown_block" end
	return MC.BlockDisplayName and MC.BlockDisplayName( block ) or block.name
end

function Blocks.DisplayNameForState( stateId )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil, "invalid_state" end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	if not block then return nil, "unknown_block" end
	return MC.BlockDisplayName and MC.BlockDisplayName( block ) or block.name
end

function Blocks.Hardness( id )
	return MC.BlockHardness and MC.BlockHardness( id ) or 1
end

function Blocks.RequiresCorrectTool( id )
	return MC.BlockRequiresCorrectTool and MC.BlockRequiresCorrectTool( id ) == true
end

function Blocks.ExplosionResistance( id )
	return MC.BlockExplosionResistance and MC.BlockExplosionResistance( id ) or 1
end

function Blocks.LightEmission( id )
	return MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
end

-- Per-state light opacity 0..15 (0 = fully transparent like glass, 15 = a
-- full opaque cube). Pass bx/by/bz for connection-dependent shapes.
function Blocks.LightOpacity( stateId, bx, by, bz )
	if not MC.BlockLightOpacityForState then return 15 end
	return MC.BlockLightOpacityForState( stateId, bx, by, bz )
end

local NARROW_CONNECTIONS = {
	fence = true, fence_gate = true, wall = true, pane = true, bars = true, pipe6 = true,
}
local RULE_KINDS = {
	stairs = "stairs", slab = "slab", door = "door", trapdoor = "trapdoor", bed = "bed",
}

-- Coarse shape classification for pathfinding/AI. One of:
--   "air"      empty cell state
--   "liquid"   water/lava source or flow (waterlogged blocks keep their own kind)
--   "narrow"   thin-but-tall colliders: fence / fence_gate / wall / pane / bars / pipe6
--              (block movement but cannot be stood on top of like a full cube)
--   "door" | "trapdoor" | "bed" | "stairs" | "slab"
--   "slope"    convex-collision ramp blocks
--   "none"     no collision at all (torch, flowers, rails, ladders, ...)
--   "full"     full opaque-collision cube
--   "partial"  everything else with a reduced collision box
function Blocks.Kind( stateId )
	if not MC.IsValidBlockState or not MC.IsValidBlockState( stateId ) then return nil, "invalid_state" end
	if stateId == 0 then return "air" end
	local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or nil
	local block = id and MC.Blocks and MC.Blocks[id] or nil
	if not block then return nil, "unknown_block" end
	if MC.IsLiquidBlock and MC.IsLiquidBlock( id ) then return "liquid" end
	if block.connection and NARROW_CONNECTIONS[block.connection] then return "narrow" end
	local ruleKind = block.stateRule and RULE_KINDS[block.stateRule]
	if ruleKind then return ruleKind end
	if block.collisionConvexes then return "slope" end
	if MC.BlockHasCollision and not MC.BlockHasCollision( id ) then return "none" end
	if MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId ) then return "full" end
	return "partial"
end

-- Fresh array of every registered block id.
function Blocks.List()
	local out = {}
	for i, id in ipairs( MC.BlockList or {} ) do out[i] = id end
	return out
end

-- Register a custom block. MUST be called during file load (autorun include
-- time) or inside hook "MC.APIAvailable" - the registry freezes on the first
-- tick after load. See docs/api.md for the definition table fields.
-- Returns true, blockId (the live registry record is deliberately not leaked).
function Blocks.Register( def )
	if not istable( def ) then return nil, "invalid_definition" end
	if MC.BlockStateRegistryFrozen then return nil, "registry_frozen" end
	if not MC.RegisterCustomBlock then return nil, "block_registry_unavailable" end
	local block = MC.RegisterCustomBlock( def )
	if not block then return nil, "register_failed" end
	return true, block.id or def.id
end

local HANDLER_KEYS = {
	OnUse = true, OnPlace = true, OnBreak = true, OnTick = true,
	OnPlaced = true, OnRemoved = true, OnReplaced = true, OnStateChanged = true, OnMoved = true,
}

-- Attach/replace lifecycle handlers on an existing block after load.
-- Pass false for a key to clear that handler. Validates everything first so
-- a rejected call never applies a partial set.
function Blocks.SetHandlers( nameOrId, handlers )
	if not istable( handlers ) then return false, "invalid_handlers" end
	local resolved = MC.ResolveBlock and MC.ResolveBlock( nameOrId ) or nil
	local block = resolved and MC.Blocks and MC.Blocks[resolved.id] or nil
	if not block then return false, "unknown_block" end
	for key, fn in pairs( handlers ) do
		if not HANDLER_KEYS[key] then return false, "unknown_handler_" .. tostring( key ) end
		if fn ~= false and not isfunction( fn ) then return false, "invalid_handler_" .. tostring( key ) end
	end
	block.handlers = block.handlers or {}
	for key, fn in pairs( handlers ) do
		block.handlers[key] = fn ~= false and fn or nil
	end
	if handlers.OnTick then MC.HasBlockTickHandlers = true end
	return true
end

function Blocks.RegisterUpdateHandler( blockName, definition )
	if not MC.RegisterBlockUpdateHandler then return false, "block_update_api_unavailable" end
	local handler, err = MC.RegisterBlockUpdateHandler( blockName, definition )
	if not handler then return false, err or "register_failed" end
	return true
end

function Blocks.UnregisterUpdateHandler( blockName )
	if not MC.UnregisterBlockUpdateHandler then return false end
	return MC.UnregisterBlockUpdateHandler( blockName ) == true
end

-- Update handler bound by STATE MATCHER instead of block name - for behavior
-- that covers a state family (the water fluid handler matches every
-- waterlogged state this way). matcher( stateId, schema ) -> boolean runs
-- once per stateId and is cached, so it must be pure and rely only on
-- immutable data. key is your own unique id; registering the same key
-- replaces the previous handler, first matching handler in order wins.
function Blocks.RegisterStateUpdateHandler( key, matcher, definition )
	if not MC.RegisterBlockUpdateStateHandler then return false, "block_update_api_unavailable" end
	if not isfunction( matcher ) then return false, "invalid_state_matcher" end
	local handler, err = MC.RegisterBlockUpdateStateHandler( key, matcher, definition )
	if not handler then return false, err or "register_failed" end
	return true
end

function Blocks.UnregisterStateUpdateHandler( key )
	if not MC.UnregisterBlockUpdateStateHandler then return false end
	return MC.UnregisterBlockUpdateStateHandler( key ) == true
end

function Blocks.RegisterBlockEntityType( definition )
	if not MC.RegisterBlockEntityType then return false, "block_entity_api_unavailable" end
	local registered, err = MC.RegisterBlockEntityType( definition )
	if not registered then return false, err or "register_failed" end
	return true
end

------------------------------------------------------------------ API.Redstone
API.Redstone = API.Redstone or {}
local Redstone = API.Redstone

-- Best redstone power reaching a cell from any neighbor (0..15).
function Redstone.GetPower( bx, by, bz )
	local x, y, z = cellCoords( bx, by, bz )
	if not x or not MC.RedstoneBestNeighborSignal then return 0 end
	return MC.RedstoneBestNeighborSignal( x, y, z )
end

-- Power offered TO the cell by its neighbor at offset (dx,dy,dz), 0..15.
-- (MC.RedstoneSignalAt asks what a cell EMITS, so the neighbor is sampled
-- with the offset reversed - same convention as RedstoneBestNeighborSignal.)
function Redstone.GetPowerToward( bx, by, bz, dx, dy, dz )
	local x, y, z = cellCoords( bx, by, bz )
	local ox, oy, oz = cellCoords( dx, dy, dz )
	if not x or not ox or not MC.RedstoneSignalAt then return 0 end
	return MC.RedstoneSignalAt( x + ox, y + oy, z + oz, -ox, -oy, -oz )
end

function Redstone.RegisterEmitter( blockName, emitter )
	if not MC.RegisterRedstoneSignalEmitter then return false, "redstone_api_unavailable" end
	local registered, err = MC.RegisterRedstoneSignalEmitter( blockName, emitter )
	if not registered then return false, err or "register_failed" end
	return true
end

function Redstone.RegisterDirectEmitter( blockName, emitter )
	if not MC.RegisterRedstoneDirectSignalEmitter then return false, "redstone_api_unavailable" end
	local registered, err = MC.RegisterRedstoneDirectSignalEmitter( blockName, emitter )
	if not registered then return false, err or "register_failed" end
	return true
end

-------------------------------------------------------------------- API.Liquid
API.Liquid = API.Liquid or {}
local Liquid = API.Liquid

-- Fresh table { kind, level, falling, waterlogged } or nil when not liquid.
function Liquid.GetAt( bx, by, bz )
	local stateId = World.GetBlockState( bx, by, bz )
	if stateId == 0 or not MC.LiquidStateMetrics then return nil end
	local kind, _, level, falling, waterlogged = MC.LiquidStateMetrics( stateId )
	if not kind then return nil end
	return { kind = kind, level = level, falling = falling == true, waterlogged = waterlogged == true }
end

-- Liquid contact at an exact world position (fresh table or nil).
function Liquid.AtPos( pos )
	if not isvector( pos ) or not MC.LiquidAtPos then return nil end
	return MC.LiquidAtPos( pos )
end

function Liquid.PlayerEye( ply )
	if not IsValid( ply ) or not MC.PlayerEyeLiquid then return nil end
	return MC.PlayerEyeLiquid( ply )
end

------------------------------------------------------------------ API.DayCycle
API.DayCycle = API.DayCycle or {}
local DayCycle = API.DayCycle

function DayCycle.GetTicks()
	return MC.DayCycleTicks and MC.DayCycleTicks() or 0
end

function DayCycle.IsEnabled()
	return MC.DayCycleEnabled and MC.DayCycleEnabled() == true or false
end

function DayCycle.IsPaused()
	return MC.DayCyclePaused and MC.DayCyclePaused() == true or false
end

-- Sky light LEVEL 0..15 for the current time (the nonlinear MC mapping;
-- SkyBrightness() is the 0..1 render brightness, not this).
function DayCycle.SkyLevel()
	return MC.DayCycleSkyLevel and MC.DayCycleSkyLevel() or 15
end

-- Fresh Vector pointing TOWARD the sun, plus elevation (cosine, -1..1;
-- positive = sun above the horizon).
function DayCycle.SunVector()
	if not MC.DayCycleSunVector then return Vector( 0, 0, 1 ), 1 end
	local dir, elevation = MC.DayCycleSunVector()
	return Vector( dir ), elevation
end

function DayCycle.NightAmount()
	return MC.DayCycleNightAmount and MC.DayCycleNightAmount() or 0
end

function DayCycle.IsNight()
	return DayCycle.NightAmount() >= 0.5
end

function DayCycle.SkyBrightness()
	return MC.DayCycleSkyBrightness and MC.DayCycleSkyBrightness() or 1
end

function DayCycle.CelestialAngle()
	return MC.DayCycleCelestialAngle and MC.DayCycleCelestialAngle() or 0
end

-- Server only; 0..23999 Minecraft ticks (0 = sunrise, 6000 = noon).
function DayCycle.SetTicks( ticks )
	if not SERVER then return false, "server_only" end
	if not MC.DayCycle or not MC.DayCycle.SetTime then return false, "daycycle_unavailable" end
	ticks = tonumber( ticks )
	if not ticks then return false, "invalid_ticks" end
	MC.DayCycle.SetTime( math.floor( ticks ) % ( MC.DAYCYCLE_TICKS_PER_DAY or 24000 ) )
	return true
end

-------------------------------------------------------------------- API.Events
-- Documentation of every event the core fires (hook.Run). Listen with
-- hook.Add( name, id, fn ). "veto" events deny the action when a listener
-- returns false.
API.Events = {
	["MC.APIAvailable"] = { realm = "shared", args = "version", desc = "MC has finished loading; registries still open - register custom blocks here" },
	["MC.APIReady"] = { realm = "shared", args = "version", desc = "registries frozen; the full API is usable" },
	["MC.BlocksChanged"] = { realm = "server", args = "changes{bx,by,bz,stateId,oldStateId,kind}[], revision, actor", desc = "one committed world transaction; kind: placed|removed|replaced|state_changed|block_entity_changed (not fired by /fill volume fills or mc_import raw imports)" },
	["MC.CanPlayerEdit"] = { realm = "server", args = "ply", desc = "veto: return false to deny all world editing for this player action" },
	["MC.CanPlayerEditCell"] = { realm = "server", args = "ply, bx, by, bz, placing", desc = "veto: return false to deny a player place/break/use at a cell" },
	["MC.PlayerPlacedBlock"] = { realm = "server", args = "ply, bx, by, bz, stateId", desc = "player placement committed" },
	["MC.PlayerBrokeBlock"] = { realm = "server", args = "ply, bx, by, bz, oldStateId", desc = "player break committed" },
	["MC.PlayerUsedBlock"] = { realm = "server", args = "ply, bx, by, bz, stateId", desc = "player right-click used a block (OnUse returned true)" },
	["MC.BlockDamaged"] = { realm = "server", args = "bx, by, bz, id, damage, health, actor", desc = "block took damage but survived" },
	["MC.BlocksExploded"] = { realm = "server", args = "center, radius, cells{bx,by,bz}[], broken, actor", desc = "explosion removed blocks" },
	["MC.WorldFilled"] = { realm = "server", args = "fill{x1,y1,z1,x2,y2,z2,stateId,changed}, actor", desc = "a volume fill committed (chunk-level; not in MC.BlocksChanged)" },
	["MC.WorldCleared"] = { realm = "server", args = "", desc = "the voxel world was cleared" },
	["MC.PreWorldLoad"] = { realm = "server", args = "path, name", desc = "a save is about to replace the world (last chance to read the old one)" },
	["MC.WorldLoaded"] = { realm = "server", args = "path, name, blockCount", desc = "a save finished loading" },
	["MC.WorldSaved"] = { realm = "server", args = "path, slotName", desc = "the world was written to disk" },
	["MC.SaveDeleted"] = { realm = "server", args = "slotName", desc = "a named save was deleted" },
	["MC.PresetPlaced"] = { realm = "server", args = "ply, name, origin{bx,by,bz}, rotation, changed, overwrite", desc = "a building preset was placed" },
	["MC.PresetSaved"] = { realm = "server", args = "name, ply", desc = "a building preset was saved" },
	["MC.PresetDeleted"] = { realm = "server", args = "name", desc = "a building preset was deleted" },
	["MC.ClusterSpawned"] = { realm = "server", args = "ent, record", desc = "a block-cluster entity spawned (convert, save load or API)" },
	["MC.ClusterConverted"] = { realm = "server", args = "ply, ent, blockCount", desc = "a player converted world blocks into a cluster entity" },
	["MC.ClusterPasted"] = { realm = "server", args = "ply, ent, changed", desc = "a cluster was placed back onto the grid (ent removes right after)" },
	["MC.ClusterBroken"] = { realm = "server", args = "ent, attacker", desc = "a cluster entity broke (blocks are lost)" },
	["MC.PlayerWorldSynced"] = { realm = "server", args = "ply, revision", desc = "a player finished applying the world snapshot" },
	["MC.ChunkHydrated"] = { realm = "server", args = "key, cx, cy, cz", desc = "a lazy-world chunk finished loading from disk (raw storage writes, no per-block events)" },
	["MC.StateRevisionApplied"] = { realm = "client", args = "generation, revision", desc = "the client applied one authoritative state revision" },
	["MC.WorkshopBaseReady"] = { realm = "server", args = "generation, workshopId, contentHash", desc = "all required players finished loading the approved Workshop base world" },
	["MC.ChestOpenCountChanged"] = { realm = "server", args = "bx, by, bz, openCount", desc = "a chest block entity opener count changed" },
	["MC.PlayerHasInfiniteMaterials"] = { realm = "server", args = "ply", desc = "query: return true/false to override whether inventory mutations consume materials" },
	["MC.PlayerGameModeChanged"] = { realm = "server", args = "ply, oldMode, newMode, actor", desc = "a player's authoritative Minecraft game mode changed" },
	["MC.PlayerMiningStarted"] = { realm = "server", args = "ply, session", desc = "a server-authoritative survival mining session started" },
	["MC.PlayerMiningCancelled"] = { realm = "server", args = "ply, session, reason", desc = "an unfinished survival mining session was cancelled" },
	["MC.PlayerMinedBlock"] = { realm = "server", args = "ply, bx, by, bz, oldStateId, drop, transaction", desc = "a survival mining session completed and committed its block transaction" },
	["MC.ItemDurabilityChanged"] = { realm = "server", args = "ply, slot, oldStack, newStack, damage, broken", desc = "the selected item took authoritative durability damage" },
	["MC.ItemUseStarted"] = { realm = "server", args = "ply, stack, useState", desc = "a held-item use state started" },
	["MC.ItemConsumed"] = { realm = "server", args = "ply, stack, foodData, infinite", desc = "a consumable finished its authoritative use" },
	["MC.ItemUsed"] = { realm = "server", args = "ply, stack, context", desc = "a non-consumable held item completed use" },
	["MC.BowFired"] = { realm = "server", args = "ply, projectile, power, broken", desc = "a bow fired a server-owned projectile" },
	["MC.CrossbowCharged"] = { realm = "server", args = "ply, ammoStack", desc = "a crossbow stored its authoritative charged projectile" },
	["MC.CrossbowFired"] = { realm = "server", args = "ply, projectile, power, broken", desc = "a charged crossbow fired" },
	["MC.TridentThrown"] = { realm = "server", args = "ply, projectile", desc = "a trident projectile was thrown" },
	["MC.ProjectileThrown"] = { realm = "server", args = "ply, projectile, itemName", desc = "a throwable item created a server-owned projectile" },
	["MC.ProjectileImpact"] = { realm = "server", args = "projectile, trace, hitEntity, definition", desc = "a Minecraft projectile resolved its authoritative impact" },
	["MC.EquipmentChanged"] = { realm = "shared", args = "server: ply, changedSlots, result, context; client: changedSlots, revision, state", desc = "authoritative equipment state changed" },
	["MC.EquipmentBroken"] = { realm = "server", args = "ply, equipmentSlot, oldStack", desc = "an equipped item broke" },
	["MC.ShieldDisabled"] = { realm = "server", args = "ply, seconds, reason", desc = "blocking was disabled for a cooldown" },
	["MC.ShieldBlockedDamage"] = { realm = "server", args = "ply, attacker, blockedDamage, hand", desc = "an active shield blocked incoming damage" },
	["MC.PlayerAttackedEntity"] = { realm = "server", args = "ply, target, metadata", desc = "the Minecraft hand completed an authoritative melee attack" },
}
