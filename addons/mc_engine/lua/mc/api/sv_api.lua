--[[----------------------------------------------------------------------------
	MC : public API, server layer (v2).

	Authoritative world writes, saves, presets, clusters. Same contract as the
	shared layer: validated inputs, "value|ok, err" returns, no live internal
	tables leaked, late binding to internals.

	Programmatic writes here are trusted server code: they skip player
	validation (reach/cooldown/admin). Player-authoritative paths live under
	MC.API.Player and DO run the full validation + veto hook chain.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.API = MC.API or {}

local API = MC.API
local World = API.World
local deepCopy = API.DeepCopy
local resolveStateInput = API.ResolveStateInput

local function SV()
	return MC.SV
end

local function cellCoords( bx, by, bz )
	local x, y, z = tonumber( bx ), tonumber( by ), tonumber( bz )
	if not x or not y or not z then return nil end
	if x ~= x or y ~= y or z ~= z then return nil end -- NaN
	return math.floor( x ), math.floor( y ), math.floor( z )
end

-- Accepts { bx=, by=, bz= } or array-form { x, y, z }; extra fields preserved.
local function normalizeCell( t )
	if not istable( t ) then return nil end
	local x, y, z = cellCoords( t.bx or t[1], t.by or t[2], t.bz or t[3] )
	if not x then return nil end
	return { bx = x, by = y, bz = z, nx = t.nx, ny = t.ny, nz = t.nz }
end

-- Options accepted from external callers for world writes; anything else is
-- dropped so internals can evolve without external code growing dependencies.
local WRITE_OPTION_KEYS = {
	actor = true, fx = true, fxIndex = true, fxLimit = true, handlers = true,
	blockUpdates = true, preventPlayerOverlap = true, priorityPhys = true,
	deferPhys = true, netPaced = true, stateStream = true, cellsPerMessage = true,
	compareCollision = true, blockEntity = true,
}

local function normalizeWriteOptions( opts )
	if opts == nil then return {} end
	if not istable( opts ) then return { actor = opts } end
	local out = {}
	for key, value in pairs( opts ) do
		if WRITE_OPTION_KEYS[key] then out[key] = value end
	end
	return out
end

local MINECRAFT_EXPLOSION_OPTION_KEYS = {
	source = true, actor = true,
	interaction = true, dropDecay = true, dropResources = true,
	interactsWithBlocks = true, createFire = true, affectsEntities = true,
	entityDamageScale = true,
}

local function normalizeMinecraftExplosionOptions( opts )
	if opts == nil then return {} end
	if not istable( opts ) then return { actor = opts } end
	local out = {}
	for key, value in pairs( opts ) do
		if MINECRAFT_EXPLOSION_OPTION_KEYS[key] then out[key] = value end
	end
	if out.entityDamageScale ~= nil
	and not isnumber( out.entityDamageScale ) and not isfunction( out.entityDamageScale ) then
		return nil, "invalid_entity_damage_scale"
	end
	if isnumber( out.entityDamageScale ) then
		out.entityDamageScale = math.max( 0, out.entityDamageScale )
	end
	return out
end

local function minecraftExplosionSummary( details )
	if not istable( details ) then return nil end
	local center = details.center
	return {
		center = isvector( center ) and Vector( center.x, center.y, center.z ) or nil,
		radius = tonumber( details.radius ) or 0,
		selectedCells = math.max( 0, math.floor( tonumber( details.blockCount ) or 0 ) ),
		removedBlocks = math.max( 0, math.floor( tonumber( details.removed ) or 0 ) ),
		damagedEntities = math.max( 0, math.floor( tonumber( details.damagedEntities ) or 0 ) ),
		entityHits = istable( details.entityHits ) and #details.entityHits or 0,
		createdFire = math.max( 0, math.floor( tonumber( details.createdFire ) or 0 ) ),
		recipients = math.max( 0, math.floor( tonumber( details.recipients ) or 0 ) ),
		fireError = details.fireError,
	}
end

--------------------------------------------------------------------- API.World
-- Set one cell. block: stateId | spec string | 0/"air"/nil (remove).
function World.SetBlock( bx, by, bz, block, opts )
	local sv = SV()
	if not sv or not sv.SetBlockState then return false, "world_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId, err = resolveStateInput( block )
	if not stateId and err then return false, err end
	local result = sv.SetBlockState( x, y, z, stateId, normalizeWriteOptions( opts ) )
	if result.ok ~= true then return false, result.error or "write_failed" end
	if result.changed == 0 then return false, "unchanged" end
	return true
end

function World.RemoveBlock( bx, by, bz, opts )
	return World.SetBlock( bx, by, bz, 0, opts )
end

-- Bulk write. cells: array of { bx, by, bz, block } (block as in SetBlock;
-- also accepts stateId / spec keys directly). Returns changed count.
function World.SetBlocks( cells, opts )
	local sv = SV()
	if not sv or not sv.SetBlocksBulk then return 0, "world_api_unavailable" end
	if not istable( cells ) or #cells == 0 then return 0, "empty_cells" end
	local normalized = {}
	for i, cell in ipairs( cells ) do
		if not istable( cell ) then return 0, "invalid_cell_" .. i end
		local x, y, z = cellCoords( cell.bx, cell.by, cell.bz )
		if not x then return 0, "invalid_cell_" .. i end
		local stateId, err = resolveStateInput( cell.block ~= nil and cell.block or cell.stateId or cell.spec )
		if not stateId and err then return 0, err .. "_" .. i end
		normalized[i] = { bx = x, by = y, bz = z, stateId = stateId, blockEntity = cell.blockEntity }
	end
	return sv.SetBlocksBulk( normalized, normalizeWriteOptions( opts ) )
end

function World.RemoveBlocks( cells, opts )
	local sv = SV()
	if not sv or not sv.RemoveBlocksBulk then return 0, "world_api_unavailable" end
	if not istable( cells ) or #cells == 0 then return 0, "empty_cells" end
	local normalized = {}
	for i, cell in ipairs( cells ) do
		if not istable( cell ) then return 0, "invalid_cell_" .. i end
		local x, y, z = cellCoords( cell.bx, cell.by, cell.bz )
		if not x then return 0, "invalid_cell_" .. i end
		normalized[i] = { bx = x, by = y, bz = z }
	end
	return sv.RemoveBlocksBulk( normalized, normalizeWriteOptions( opts ) )
end

-- Volume fill through the fast chunk pipeline (the /fill engine).
-- opts: actor, ignoreVolumeLimit (skip mc_fill_max), quiet (suppress the
-- per-call performance line). Returns the fill result
-- table { changed, chunks, added, removed, revision, ... } or nil, err.
function World.Fill( x1, y1, z1, x2, y2, z2, block, opts )
	local sv = SV()
	if not sv or not sv.FillVolume then return nil, "fill_api_unavailable" end
	local ax, ay, az = cellCoords( x1, y1, z1 )
	local bx, by, bz = cellCoords( x2, y2, z2 )
	if not ax or not bx then return nil, "invalid_cell" end
	local stateId, err = resolveStateInput( block )
	if not stateId and err then return nil, err end
	opts = istable( opts ) and opts or {}
	return sv.FillVolume( ax, ay, az, bx, by, bz, stateId, {
		actor = opts.actor,
		ignoreVolumeLimit = opts.ignoreVolumeLimit == true,
		quiet = opts.quiet == true,
	} )
end

-- Clear the whole voxel world and resync every player.
function World.Clear()
	local sv = SV()
	if not sv or not sv.ClearWorld then return false, "world_api_unavailable" end
	sv.ClearWorld()
	return true
end

-- Replace the block entity record at a cell (same state). The record is
-- validated by the registered block entity type before committing.
function World.SetBlockEntity( bx, by, bz, record, opts )
	local sv = SV()
	if not sv or not sv.SetBlockState then return false, "world_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId = MC.GetBlockState and MC.GetBlockState( x, y, z ) or 0
	if not stateId or stateId == 0 then return false, "air" end
	if record ~= nil and not istable( record ) then return false, "invalid_block_entity" end
	opts = normalizeWriteOptions( opts )
	opts.blockEntity = record ~= nil and record or false
	if opts.fx == nil then opts.fx = false end
	if opts.blockUpdates == nil then opts.blockUpdates = false end
	if opts.compareCollision == nil then opts.compareCollision = false end
	local result = sv.SetBlockState( x, y, z, stateId, opts )
	if result.ok ~= true then return false, result.error or "write_failed" end
	return true
end

-- Read-copy-update-write helper. The callback receives a private record copy
-- and may mutate it in place, return a replacement record, or return false to
-- abort. Persistence overlays and client projection are handled by the normal
-- block transaction; callers never touch chunk storage or SV.ChunkStore.
function World.UpdateBlockEntity( bx, by, bz, callback, opts )
	if not isfunction( callback ) then return false, "invalid_callback" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local record = API.World.GetBlockEntity( x, y, z )
	if not record then return false, "block_entity_missing" end
	local working = deepCopy( record )
	local ok, replacement, callbackError = pcall( callback, working )
	if not ok then return false, "callback_failed" end
	if replacement == false then return false, callbackError or "update_aborted" end
	if replacement ~= nil then
		if not istable( replacement ) then return false, "invalid_block_entity" end
		working = replacement
	end
	local written, writeError = World.SetBlockEntity( x, y, z, working, opts )
	if not written then return false, writeError end
	return true, deepCopy( working )
end

-- Minecraft-style block damage. Returns broken, status, damage, health.
function World.Damage( bx, by, bz, amount, opts )
	local sv = SV()
	if not sv or not sv.ApplyBlockDamage then return false, "damage_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.ApplyBlockDamage( x, y, z, amount, istable( opts ) and opts or { actor = opts } )
end

-- Explosion crater. Returns ok, brokenCount, radiusOrStatus.
function World.Explode( center, damage, opts )
	local sv = SV()
	if not sv or not sv.ApplyBlockExplosion then return false, 0, "damage_api_unavailable" end
	if not isvector( center ) then return false, 0, "invalid_center" end
	return sv.ApplyBlockExplosion( center, damage, istable( opts ) and opts or { actor = opts } )
end

-- Minecraft Explosion.BlockInteraction.TRIGGER_BLOCK. Uses Java's 16x16x16
-- boundary rays and calls only block onExplosionHit overrides; ordinary blocks
-- are never removed. Returns ok, triggeredBlockCount, selectedCellCountOrStatus.
function World.TriggerExplosion( center, radius, opts )
	local sv = SV()
	if not sv or not sv.TriggerBlockExplosion then return false, 0, "trigger_explosion_unavailable" end
	if not isvector( center ) then return false, 0, "invalid_center" end
	return sv.TriggerBlockExplosion( center, radius, istable( opts ) and opts or { actor = opts } )
end

-- Full Java 26.2 ServerExplosion pipeline: entity exposure/damage/knockback,
-- optional destructive block interaction, survival drops/TNT chaining, client
-- effects and optional post-destruction fire. `entityDamageScale` is either a
-- non-negative multiplier or callback(entity, vanillaDamage, center, radius)
-- returning one; this lets external mobs map Minecraft damage to their own HP
-- scale without reimplementing exposure or knockback. Returns a fresh summary,
-- never the engine's transaction/snapshot tables.
function World.MinecraftExplosion( center, radius, opts )
	local sv = SV()
	if not sv or not sv.ApplyMinecraftExplosion then
		return false, "minecraft_explosion_unavailable"
	end
	if not isvector( center ) then return false, "invalid_center" end
	local normalized, normalizeError = normalizeMinecraftExplosionOptions( opts )
	if not normalized then return false, normalizeError end
	local ok, resultOrError, failedDetails = sv.ApplyMinecraftExplosion( center, radius, normalized )
	if ok ~= true then return false, resultOrError, minecraftExplosionSummary( failedDetails ) end
	return true, minecraftExplosionSummary( resultOrError )
end

--------------------------------------------------------------- API.Explosion
-- Registration facade for game/content behavior layered on the engine's
-- ServerExplosion pipeline. Callback arguments are snapshots; live block,
-- schema, world and transaction tables never cross this boundary.
API.Explosion = API.Explosion or {}
local ExplosionAPI = API.Explosion

local function publicExplosionOptions( options )
	local copy = {}
	for key in pairs( MINECRAFT_EXPLOSION_OPTION_KEYS ) do
		if options and options[key] ~= nil then copy[key] = options[key] end
	end
	return copy
end

local function publicExplosionSnapshots( snapshots )
	local output = {}
	for index, snapshot in ipairs( snapshots or {} ) do
		output[index] = {
			bx = snapshot.bx, by = snapshot.by, bz = snapshot.bz,
			stateId = snapshot.stateId,
			name = snapshot.name,
			blockId = snapshot.blockId,
			blockEntity = deepCopy( snapshot.blockEntity ),
		}
	end
	return output
end

local function publicExplosionTransaction( transaction )
	if not istable( transaction ) then return nil end
	local changes = {}
	for index, change in ipairs( transaction.changes or {} ) do
		changes[index] = {
			bx = change.bx, by = change.by, bz = change.bz,
			oldStateId = change.oldStateId, stateId = change.stateId,
		}
	end
	return {
		ok = transaction.ok == true,
		changed = math.max( 0, math.floor( tonumber( transaction.changed ) or 0 ) ),
		error = transaction.error,
		changes = changes,
	}
end

function ExplosionAPI.RegisterBlockInteractionHandler( identifier, definition )
	local explosion = MC.Explosion
	if not explosion or not explosion.RegisterBlockInteractionHandler then
		return false, "explosion_integration_unavailable"
	end
	if not istable( definition ) or not isfunction( definition.Prepare )
		or not isfunction( definition.Commit ) then
		return false, "invalid_block_interaction_handler"
	end
	return explosion.RegisterBlockInteractionHandler( identifier, {
		Prepare = function( snapshots, radius, options )
			return definition.Prepare(
				publicExplosionSnapshots( snapshots ),
				radius,
				publicExplosionOptions( options )
			)
		end,
		Commit = function( plan, transaction, snapshots, radius, options )
			return definition.Commit(
				plan,
				publicExplosionTransaction( transaction ),
				publicExplosionSnapshots( snapshots ),
				radius,
				publicExplosionOptions( options )
			)
		end,
	} )
end

function ExplosionAPI.UnregisterBlockInteractionHandler( identifier )
	local explosion = MC.Explosion
	return explosion and explosion.UnregisterBlockInteractionHandler
		and explosion.UnregisterBlockInteractionHandler( identifier ) or false
end

function ExplosionAPI.RegisterKnockbackResistanceProvider( identifier, callback )
	local explosion = MC.Explosion
	if not explosion or not explosion.RegisterKnockbackResistanceProvider then
		return false, "explosion_integration_unavailable"
	end
	if not isfunction( callback ) then return false, "invalid_knockback_provider" end
	return explosion.RegisterKnockbackResistanceProvider( identifier, function( entity, center, radius, options )
		return callback( entity, center, radius, publicExplosionOptions( options ) )
	end )
end

function ExplosionAPI.UnregisterKnockbackResistanceProvider( identifier )
	local explosion = MC.Explosion
	return explosion and explosion.UnregisterKnockbackResistanceProvider
		and explosion.UnregisterKnockbackResistanceProvider( identifier ) or false
end

-- Broadcast place/break fx for a block without changing the world.
function World.PlayFx( kind, bx, by, bz, block )
	local sv = SV()
	if not sv or not sv.PlayBlockFx then return false, "fx_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId
	if block ~= nil then
		local resolved, err = resolveStateInput( block )
		if not resolved and err then return false, err end
		stateId = resolved
	else
		stateId = MC.GetBlockState and MC.GetBlockState( x, y, z ) or 0
	end
	if not stateId or stateId == 0 then return false, "air" end
	local id, orient = MC.LegacyFromState( stateId )
	return sv.PlayBlockFx( kind, id or 0, orient or 0, x, y, z, nil, stateId )
end

function World.CountBlocks()
	local sv = SV()
	return sv and sv.BlockCount or 0
end

-- Increments once per committed transaction; cheap change detector.
function World.GetRevision()
	local sv = SV()
	return sv and sv.BlockRevision or 0
end

-------------------------------------------------------------------- API.Player
-- Player-authoritative operations: full validation (admin, reach, cooldown,
-- bounds, block limit, overlap) plus the MC.CanPlayerEdit* veto hooks.
API.Player = API.Player or {}
local Player = API.Player

function Player.Place( ply, bx, by, bz, block )
	local sv = SV()
	if not sv or not sv.PlaceState then return false, "world_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId, err = resolveStateInput( block )
	if not stateId or stateId == 0 then return false, err or "invalid_state" end
	return sv.PlaceState( ply, x, y, z, stateId )
end

function Player.Break( ply, bx, by, bz )
	local sv = SV()
	if not sv or not sv.Break then return false, "world_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.Break( ply, x, y, z )
end

function Player.Use( ply, bx, by, bz )
	local sv = SV()
	if not sv or not sv.Use then return false, "world_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.Use( ply, x, y, z )
end

function Player.UseAimedBlock( ply )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then
		return false, "invalid_player"
	end
	if not sv or not sv.TryUseAimedBlock then return false, "use_api_unavailable" end
	return sv.TryUseAimedBlock( ply ) == true
end

function Player.CanEdit( ply )
	local sv = SV()
	return sv and sv.CanEdit and sv.CanEdit( ply ) == true or false
end

-- Read-only interaction reach check for game-layer containers. This does not
-- run edit vetoes or mutate the world; it only applies the engine's configured
-- reach in the active world adapter's continuous coordinate frame.
function Player.CanReachCell( ply, bx, by, bz )
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then
		return false, "invalid_player"
	end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	if not MC.ReachAllowsEye then return false, "reach_api_unavailable" end
	local reach = MC.CurrentReach and MC.CurrentReach()
		or ( MC.Config and MC.Config.DefaultReach ) or ( ( MC.BS or 36.5 ) * 5 )
	local eye = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ply ) or ply:EyePos()
	if MC.ReachAllowsEye( eye, x, y, z, reach ) ~= true then return false, "out_of_reach" end
	return true
end

-------------------------------------------------------------------- API.Liquid
-- Player-authoritative bucket operations.  These are intentionally narrower
-- than World.SetBlock: callers name a fluid kind, while the API owns source
-- checks, waterlogged transitions, aim-face targeting and player validation.
local Liquid = API.Liquid

local function validLiquidPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer() and ply:Alive()
end

local function normalizeLiquidKind( kind )
	kind = string.lower( tostring( kind or "" ) )
	kind = string.gsub( kind, "^minecraft:", "" )
	if kind == "water" or kind == "lava" then return kind end
	return nil
end

------------------------------------------------------------------ API.GameMode
local GameMode = API.GameMode

function GameMode.Set( ply, mode, actor )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then
		return false, "invalid_player"
	end
	if not sv or not sv.SetPlayerGameMode then return false, "game_mode_api_unavailable" end
	return sv.SetPlayerGameMode( ply, mode, actor )
end

-- The voxel world's own Source-side collision proxies. A bucket ray must pass
-- through these or it would be blocked by the very blocks it is aiming at.
local BUCKET_OWN_COLLISION = {
	mc_chunk = true,
	mc_chunk_phys = true,
	mc_collision_carrier = true,
}

local function bucketWorldObstructionDistance( ply, eye, direction, reach )
	if not util or not util.TraceLine then return nil end
	local traceData = {
		start = eye,
		endpos = eye + direction * reach,
		filter = function( entity )
			if entity == ply then return false end
			if not IsValid( entity ) then return true end
			if BUCKET_OWN_COLLISION[entity:GetClass()] == true then return false end
			-- Java's block clip ignores living entities. Physical props and map
			-- entities remain valid Source-world obstructions.
			if entity.IsPlayer and entity:IsPlayer() then return false end
			if entity.IsNPC and entity:IsNPC() then return false end
			if entity.IsNextBot and entity:IsNextBot() then return false end
			return true
		end,
	}
	if MASK_SHOT ~= nil then traceData.mask = MASK_SHOT end
	local trace = util.TraceLine( traceData )
	if not trace or trace.Hit ~= true then return nil end
	if isvector( trace.HitPos ) then return trace.HitPos:Distance( eye ) end
	return math.Clamp( tonumber( trace.Fraction ) or 1, 0, 1 ) * reach
end

-- BucketItem clips block OUTLINE geometry in both modes. Pure liquid blocks have
-- an empty outline in Java, so this is the same ClipContext.Fluid.NONE the
-- crosshair uses: waterlogged containers and every ordinary block selection
-- shape still stop the ray.
local function bucketOutlineHit( eye, direction, reach )
	if not MC.TraceBlockRay then return nil end
	return MC.TraceBlockRay( eye, direction, reach, MC.ClipFluidNone )
end

local function bucketAim( ply, sourceOnly )
	if not validLiquidPlayer( ply ) then return nil, "invalid_player" end
	local eye, eyeError = API.Coords.EntityEyeWorldPos( ply )
	if not eye then return nil, eyeError end
	local direction = ply:EyeAngles():Forward()
	if direction:LengthSqr() <= 0 then return nil, "invalid_ray" end
	direction:Normalize()
	local blockSize = API.Coords.BlockSize()
	local reach = MC.CurrentReach and MC.CurrentReach() or ( blockSize * 5 )
	local outlineHit = bucketOutlineHit( eye, direction, reach )
	local worldObstruction = bucketWorldObstructionDistance( ply, ply:EyePos(), direction, reach )
	local obstructionTolerance = math.max( blockSize / 4096, 0.01 )

	if sourceOnly == true then
		if not MC.LiquidStateMetrics or not MC.WorldToCell or not MC.GetBlockState
		or not MC.LiquidHeightAtCell or not MC.CellWorldMin then
			return nil, "trace_unavailable"
		end

		-- A waterlogged BucketPickup may be selected through its block OUTLINE even
		-- when the ray is above the contained fluid surface. Keep it as a candidate,
		-- but first let a nearer source-fluid shape win the combined Java clip.
		local outlineSource
		if outlineHit then
			local description = Liquid.GetBucketSource(
				outlineHit.bx, outlineHit.by, outlineHit.bz )
			outlineSource = description and description.source == true
				and description.waterlogged == true
		end

		-- Java combines Block.OUTLINE with Fluid.SOURCE_ONLY and takes the nearer
		-- shape. Sample the exact source-fluid height, while outlineHit blocks the
		-- ray at ordinary MC geometry and the Source trace blocks it at map/prop
		-- geometry. Flowing and pure-liquid block outlines are intentionally skipped.
		local step = math.max( blockSize / 128, 0.125 )
		local lastKey, stateId, kind, source
		for distance = 0, reach, step do
			if outlineHit and distance + obstructionTolerance >= outlineHit.Distance then break end
			if worldObstruction and distance + obstructionTolerance >= worldObstruction then break end
			local pos = eye + direction * distance
			local bx, by, bz = MC.WorldToCell( pos )
			local key = tostring( bx ) .. ":" .. tostring( by ) .. ":" .. tostring( bz )
			if key ~= lastKey then
				lastKey = key
				stateId = MC.GetBlockState( bx, by, bz ) or 0
				local level, falling, waterlogged
				kind, _, level, falling, waterlogged = MC.LiquidStateMetrics( stateId )
				source = kind and ( waterlogged == true
					or ( math.floor( tonumber( level ) or -1 ) == 0 and falling ~= true ) )
			end
			if source then
				local surface = MC.LiquidHeightAtCell( bx, by, bz, kind )
				local base = MC.CellWorldMin( bx, by, bz )
				local localZ = ( pos.z - base.z ) / blockSize
				if localZ >= -1e-4 and localZ <= surface + 1e-4 then
					return {
						Hit = true, HitMCBlock = true,
						bx = bx, by = by, bz = bz,
						StateId = stateId,
						HitPos = pos,
						Distance = distance,
					}
				end
			end
		end
		if outlineSource then
			if worldObstruction and worldObstruction + obstructionTolerance < outlineHit.Distance then
				return nil, "blocked"
			end
			return outlineHit
		end
		if outlineHit or worldObstruction then return nil, "blocked" end
		return nil, "miss"
	end
	if not outlineHit or outlineHit.HitMCBlock ~= true then return nil, "miss" end
	if worldObstruction and worldObstruction + obstructionTolerance < outlineHit.Distance then
		return nil, "blocked"
	end
	return outlineHit
end

local function hitNormalOffset( normal )
	if not isvector( normal ) then return nil end
	local ax, ay, az = math.abs( normal.x ), math.abs( normal.y ), math.abs( normal.z )
	if ax >= ay and ax >= az and ax > 0 then return normal.x >= 0 and 1 or -1, 0, 0 end
	if ay >= az and ay > 0 then return 0, normal.y >= 0 and 1 or -1, 0 end
	if az > 0 then return 0, 0, normal.z >= 0 and 1 or -1 end
	return nil
end

local function dewaterloggedState( stateId )
	if not MC.IsWaterloggedState or not MC.IsWaterloggedState( stateId ) then return nil end
	if not MC.StateWith then return nil end
	return MC.StateWith( stateId, "waterlogged", false )
end

local function sourceStateForKind( kind )
	local spread = kind == "water" and MC.WaterSpread or MC.LavaSpread
	if not spread or not spread.BlockStateForFluid then return nil end
	return spread.BlockStateForFluid( 8, false, true )
end

local function validatePlayerFluidPlacement( ply, bx, by, bz, addsBlock )
	local sv = SV()
	if not sv or not sv.CanEdit or not sv.WorldBoundsOK then return false, "world_api_unavailable" end

	-- Mirrors SV.Validate while keeping two distinct placement facts:
	-- protection hooks see a placement for every bucket empty, but the global
	-- non-air block cap only applies when the transaction adds a new occupied cell.
	local now = CurTime()
	if ( ply.mcNextOp or 0 ) > now then return false, "cooldown" end
	ply.mcNextOp = now + 0.03
	if not sv.CanEdit( ply ) then return false, "edit_rejected" end
	if MC.RunEvent and MC.RunEvent( "MC.CanPlayerEditCell", ply, bx, by, bz, true ) == false then
		return false, "cell_rejected"
	end

	local config = MC.Config
	local reach = config and config.Reach and config.Reach:GetFloat() or 0
	if reach > 0 and not MC.ReachAllowsEye( API.Coords.EntityEyeWorldPos( ply ), bx, by, bz, reach ) then
		return false, "out_of_reach"
	end
	if not sv.WorldBoundsOK( bx, by, bz ) then return false, "world_limit" end
	local maxBlocks = config and config.MaxBlocks and config.MaxBlocks:GetInt() or 0
	if addsBlock == true and maxBlocks > 0 and ( tonumber( sv.BlockCount ) or 0 ) >= maxBlocks then
		return false, "max_blocks"
	end
	return true
end

local function playerFluidWrite( ply, bx, by, bz, stateId, placing, addsBlock, skipValidation )
	local sv = SV()
	if not sv or not sv.Validate or not sv.SetBlockState then return false, "world_api_unavailable" end
	if skipValidation ~= true then
		local valid, validationError
		if placing == true then
			valid, validationError = validatePlayerFluidPlacement( ply, bx, by, bz, addsBlock == true )
		else
			valid = sv.Validate( ply, bx, by, bz, false ) == true
			validationError = valid and nil or "edit_rejected"
		end
		if not valid then return false, validationError end
	end
	local result = sv.SetBlockState( bx, by, bz, stateId, {
		actor = ply,
		priorityPhys = true,
		immediatePhys = true,
		fx = false,
		compareCollision = true,
	} )
	if not result or result.ok ~= true then return false, result and result.error or "write_failed" end
	if result.changed <= 0 then return false, "unchanged" end
	return true, result
end

local function validatedPlayerFluidWrite( ply, bx, by, bz, stateId, placing, addsBlock )
	return playerFluidWrite( ply, bx, by, bz, stateId, placing, addsBlock )
end

local function rollbackPlayerFluidWrite( ply, bx, by, bz, expectedStateId, restoreStateId )
	if ( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 ) ~= expectedStateId then
		return false, "rollback_state_changed"
	end
	return playerFluidWrite( ply, bx, by, bz, restoreStateId, false, false, true )
end

-- Removes only a source FluidState. Returns result { kind, bx/by/bz,
-- waterlogged, oldStateId, newStateId } or nil, err.
function Liquid.PickupSource( ply )
	local hit, hitError = bucketAim( ply, true )
	if not hit then return nil, hitError end
	local bx, by, bz = cellCoords( hit.bx, hit.by, hit.bz )
	if not bx then return nil, "invalid_cell" end
	local description, descriptionError = Liquid.GetBucketSource( bx, by, bz )
	if not description then return nil, descriptionError or "not_liquid" end
	if description.source ~= true then return nil, "not_source" end

	local nextStateId = 0
	if description.waterlogged then
		nextStateId = dewaterloggedState( description.stateId )
		if nextStateId == nil then return nil, "waterlogged_transition_unavailable" end
	end
	if ( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 ) ~= description.stateId then
		return nil, "state_changed"
	end
	local changed, writeError = validatedPlayerFluidWrite( ply, bx, by, bz, nextStateId, false, false )
	if not changed then return nil, writeError end
	return {
		kind = description.kind,
		bx = bx, by = by, bz = bz,
		waterlogged = description.waterlogged == true,
		oldStateId = description.stateId,
		newStateId = nextStateId,
	}
end

function Liquid.RollbackPickup( ply, result )
	if not istable( result ) then return false, "invalid_result" end
	return rollbackPlayerFluidWrite(
		ply, result.bx, result.by, result.bz, result.newStateId, result.oldStateId )
end

function Liquid.CommitPickup( ply, result )
	if not validLiquidPlayer( ply ) or not istable( result ) then return false, "invalid_result" end
	if MC.RunEvent then
		MC.RunEvent(
			"MC.PlayerPickedUpFluid", ply, result.kind, result.bx, result.by, result.bz,
			result.oldStateId, result.newStateId )
	end
	return true
end

-- Places a source using BucketItem's target rule: water first tries the hit
-- cell when it can be waterlogged; otherwise water/lava use the adjacent cell
-- selected by the hit face. Returns a result table or nil, err.
function Liquid.PlaceSource( ply, kind )
	kind = normalizeLiquidKind( kind )
	if not kind then return nil, "invalid_liquid_kind" end
	local hit, hitError = bucketAim( ply )
	if not hit then return nil, hitError end
	local hitX, hitY, hitZ = cellCoords( hit.bx, hit.by, hit.bz )
	if not hitX then return nil, "invalid_cell" end
	local hitStateId = MC.GetBlockState and MC.GetBlockState( hitX, hitY, hitZ ) or 0
	local spread = kind == "water" and MC.WaterSpread or MC.LavaSpread
	if not spread or not spread.CanHoldAny or not spread.CanHoldSpecific or not spread.PlaceFluidInState then
		return nil, "liquid_rules_unavailable"
	end

	local targetX, targetY, targetZ = hitX, hitY, hitZ
	local targetStateId, waterlogged, expectedStateId = nil, false, hitStateId
	local sneaking = ply.KeyDown and ply:KeyDown( IN_DUCK ) == true
	if kind == "water" and not sneaking and spread.WaterloggedState then
		targetStateId = spread.WaterloggedState( hitStateId )
		waterlogged = targetStateId ~= nil
	end

	if not targetStateId then
		local dx, dy, dz = hitNormalOffset( hit.HitNormal )
		if dx == nil then return nil, "invalid_hit_normal" end
		targetX, targetY, targetZ = hitX + dx, hitY + dy, hitZ + dz
		local existing = MC.GetBlockState and MC.GetBlockState( targetX, targetY, targetZ ) or 0
		expectedStateId = existing
		if not spread.CanHoldAny( existing, targetX, targetY, targetZ )
		or not spread.CanHoldSpecific( existing ) then return nil, "target_rejected" end
		targetStateId = spread.PlaceFluidInState( existing, 8, false, true )
		waterlogged = kind == "water" and targetStateId ~= sourceStateForKind( kind )
	end

	if not targetStateId or targetStateId == 0 then return nil, "source_state_unavailable" end
	if ( MC.GetBlockState and MC.GetBlockState( targetX, targetY, targetZ ) or 0 ) ~= expectedStateId then
		return nil, "state_changed"
	end
	local changed, writeError = validatedPlayerFluidWrite(
		ply, targetX, targetY, targetZ, targetStateId, true, expectedStateId == 0 )
	if not changed then return nil, writeError end
	return {
		kind = kind,
		bx = targetX, by = targetY, bz = targetZ,
		waterlogged = waterlogged == true,
		oldStateId = expectedStateId,
		stateId = targetStateId,
	}
end

function Liquid.RollbackPlacement( ply, result )
	if not istable( result ) then return false, "invalid_result" end
	return rollbackPlayerFluidWrite(
		ply, result.bx, result.by, result.bz, result.stateId, result.oldStateId )
end

function Liquid.CommitPlacement( ply, result )
	if not validLiquidPlayer( ply ) or not istable( result ) then return false, "invalid_result" end
	if MC.RunEvent then
		MC.RunEvent(
			"MC.PlayerPlacedFluid", ply, result.kind, result.bx, result.by, result.bz, result.stateId )
	end
	return true
end

-- Full world resync for one player (or every player when ply is nil).
function Player.Resync( ply )
	local sv = SV()
	if not sv or not sv.BeginSync then return false, "sync_api_unavailable" end
	local targets = IsValid( ply ) and { ply } or player.GetAll()
	for _, target in ipairs( targets ) do
		net.Start( "mc_clear" )
		net.Send( target )
		sv.BeginSync( target )
	end
	return true
end

--------------------------------------------------------------------- API.Saves
API.Saves = API.Saves or {}
local Saves = API.Saves

-- name nil -> default per-map save; otherwise a named slot.
-- Returns only ok, pathOrErr: the internal call also returns the raw save
-- payload (live storage on lazy worlds), which must not leak to callers.
function Saves.Save( name )
	local sv = SV()
	if not sv or not sv.Save then return false, "saves_api_unavailable" end
	local ok, pathOrErr = sv.Save( name )
	return ok, pathOrErr
end

function Saves.Load( name, resync )
	local sv = SV()
	if not sv or not sv.LoadSave then return false, "saves_api_unavailable" end
	if not isstring( name ) or name == "" then return false, "missing_save_name" end
	return sv.LoadSave( name, resync ~= false )
end

function Saves.Delete( name )
	local sv = SV()
	if not sv or not sv.DeleteSave then return false, "saves_api_unavailable" end
	return sv.DeleteSave( name )
end

-- Fresh array of { name, map, blocks, chunks, savedAtText, cover, path }.
-- Scans the disk: do not poll.
function Saves.List()
	local sv = SV()
	if not sv or not sv.SaveList then return {} end
	return sv.SaveList()
end

-- True across local, Workshop-cache, and legacy save roots.
function Saves.Exists( name )
	local sv = SV()
	if not sv or not sv.SaveSlotName then return false end
	local slot = sv.SaveSlotName( name )
	if not slot then return false end
	if sv.SaveExists then return sv.SaveExists( slot ) end
	if not sv.SaveSlotPath then return false end
	if file.Exists( sv.SaveSlotPath( slot ), "DATA" ) then return true end
	if not sv.LegacySaveSlotPath then return false end
	return file.Exists( sv.LegacySaveSlotPath( slot ), "DATA" )
end

------------------------------------------------------------------- API.Presets
API.Presets = API.Presets or {}
local Presets = API.Presets

-- Fresh array of { name, map, createdAtText, blocks, size, cover }.
function Presets.List()
	local sv = SV()
	if not sv or not sv.PresetList then return {} end
	return sv.PresetList()
end

-- Deep copy of the preset data (safe to keep/mutate) or nil, err.
function Presets.Get( name )
	local sv = SV()
	if not sv or not sv.LoadPreset then return nil, "presets_api_unavailable" end
	local data, err = sv.LoadPreset( name )
	if not data then return nil, err end
	return deepCopy( data )
end

-- Place a saved preset. ply may be nil (console: skips permission/cooldown).
-- origin: { bx, by, bz } or array { x, y, z }. opts: { overwrite, rotation 0..3 }.
function Presets.Place( ply, name, origin, opts )
	local sv = SV()
	if not sv or not sv.PlacePreset then return false, "presets_api_unavailable" end
	origin = normalizeCell( origin )
	if not origin then return false, "invalid_origin" end
	opts = istable( opts ) and opts or {}
	return sv.PlacePreset( ply, name, origin, opts.overwrite == true, opts.rotation )
end

-- Capture a world box into a named preset. anchor defaults to cornerA (may
-- carry nx/ny/nz as the reference face normal).
function Presets.SaveFromWorld( name, cornerA, cornerB, anchor, ply )
	local sv = SV()
	if not sv or not sv.SavePreset then return false, "presets_api_unavailable" end
	cornerA = normalizeCell( cornerA )
	cornerB = normalizeCell( cornerB )
	anchor = normalizeCell( anchor ) or cornerA
	if not cornerA or not cornerB then return false, "invalid_selection" end
	local ok, dataOrErr = sv.SavePreset( name, cornerA, cornerB, anchor, "", ply )
	if not ok then return false, dataOrErr end
	return true, deepCopy( dataOrErr )
end

function Presets.Delete( name )
	local sv = SV()
	if not sv or not sv.DeletePreset then return false, "presets_api_unavailable" end
	return sv.DeletePreset( name )
end

------------------------------------------------------------------- API.Cluster
API.Cluster = API.Cluster or {}
local Cluster = API.Cluster

-- Snapshot the non-air cells of a world box into a cluster record (does not
-- modify the world). Record: { size = {sx,sy,sz}, cells = flat quads }.
function Cluster.Capture( x1, y1, z1, x2, y2, z2 )
	local sv = SV()
	if not sv or not sv.CaptureClusterRecord then return nil, "cluster_api_unavailable" end
	local ax, ay, az = cellCoords( x1, y1, z1 )
	local bx, by, bz = cellCoords( x2, y2, z2 )
	if not ax or not bx then return nil, "invalid_cell" end
	return sv.CaptureClusterRecord( ax, ay, az, bx, by, bz )
end

-- Spawn a cluster entity from a record. opts: { angles, frozen (default
-- true), owner (player: grants CPPI ownership + label) }.
function Cluster.Spawn( record, pos, opts )
	local sv = SV()
	if not sv or not sv.SpawnCluster then return nil, "cluster_api_unavailable" end
	if not isvector( pos ) then return nil, "invalid_position" end
	if not MC.ClusterValidateRecord then return nil, "cluster_api_unavailable" end
	local recordCopy = deepCopy( record )
	local ok, err = MC.ClusterValidateRecord( recordCopy )
	if not ok then return nil, err end
	opts = istable( opts ) and opts or {}
	if opts.angles ~= nil and not isangle( opts.angles ) then return nil, "invalid_angles" end
	local owner = opts.owner
	local sid = IsValid( owner ) and owner.SteamID64 and owner:SteamID64() or nil
	local ent, spawnErr, convexCount = sv.SpawnCluster( recordCopy, pos, opts.angles, opts.frozen ~= false, sid )
	if not IsValid( ent ) then return nil, spawnErr, convexCount end
	if IsValid( owner ) and sv.AssignClusterOwner then sv.AssignClusterOwner( ent, owner ) end
	return ent
end

-- Place a cluster entity's blocks back onto the grid (entity is removed on
-- success). targetMin: { bx, by, bz } world cell of the record's min corner.
function Cluster.PlaceBack( ply, ent, targetMin, rotation )
	local sv = SV()
	if not sv or not sv.PlaceClusterAt then return false, "cluster_api_unavailable" end
	if not IsValid( ent ) or ent:GetClass() ~= "mc_block_cluster" then return false, "invalid_cluster" end
	if not istable( targetMin ) then return false, "invalid_target" end
	local x, y, z = cellCoords( targetMin.bx or targetMin[1], targetMin.by or targetMin[2], targetMin.bz or targetMin[3] )
	if not x then return false, "invalid_target" end
	return sv.PlaceClusterAt( ply, ent, { x, y, z }, tonumber( rotation ) or 0 )
end

function Cluster.Break( ent, attacker )
	local sv = SV()
	if not sv or not sv.BreakCluster then return false, "cluster_api_unavailable" end
	if not IsValid( ent ) or ent:GetClass() ~= "mc_block_cluster" then return false, "invalid_cluster" end
	sv.BreakCluster( ent, attacker )
	return true
end

--------------------------------------------------------------------- API.Light
-- Server twin of the client sampler (same name and return shape on both
-- realms). skyLight here is heightmap-level (no lateral flood) and
-- time-independent; blockLight is exact opacity-aware propagation, O(1)
-- when no emitter is within 15 cells, cached otherwise. brightness is
-- linear level/15 (the client applies tone profiles on top).
API.Light = API.Light or {}

function API.Light.SampleCell( bx, by, bz, selfEmission )
	local sv = SV()
	if not sv or not sv.SampleLighting then return nil, "lighting_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	return sv.SampleLighting( x, y, z, selfEmission )
end

------------------------------------------------------------------- API.Farming
-- Vanilla-style crop placement/growth entry points. opts is reserved for
-- forward-compatible call-site metadata and must currently be a table when
-- supplied; validation/reach and all writes remain authoritative in MC.SV.
API.Farming = API.Farming or {}
local FarmingAPI = API.Farming

local function farmingOptionsValid( opts )
	return opts == nil or istable( opts )
end

function FarmingAPI.CanSurvive( bx, by, bz, state )
	local farming = MC.Farming
	if not farming or not farming.CanSurvive then return false, "farming_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId, err = resolveStateInput( state )
	if stateId == nil then return false, err or "invalid_state" end
	return farming.CanSurvive( x, y, z, stateId ) == true
end

function FarmingAPI.Plant( ply, bx, by, bz, state, opts )
	local farming = MC.Farming
	if not farming or not farming.Plant then return false, "farming_api_unavailable" end
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then
		return false, "invalid_player"
	end
	if not farmingOptionsValid( opts ) then return false, "invalid_options" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local stateId, err = resolveStateInput( state )
	if stateId == nil then return false, err or "invalid_state" end
	local ok, result = farming.Plant( ply, x, y, z, stateId, opts )
	if ok ~= true then return false, result or "placement_rejected" end
	return true, deepCopy( result )
end

function FarmingAPI.ApplyBonemeal( ply, bx, by, bz, opts )
	local farming = MC.Farming
	if not farming or not farming.ApplyBonemeal then return false, "farming_api_unavailable" end
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() then
		return false, "invalid_player"
	end
	if not farmingOptionsValid( opts ) then return false, "invalid_options" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local ok, result = farming.ApplyBonemeal( ply, x, y, z, opts )
	if ok ~= true then return false, result or "bonemeal_rejected" end
	return true, deepCopy( result )
end

function FarmingAPI.TryTrample( entity, bx, by, bz, fallDistance, opts )
	local sv = SV()
	if not sv or not sv.TryTrampleFarmland then return false, "farming_api_unavailable" end
	if not IsValid( entity ) then return false, "invalid_entity" end
	if not farmingOptionsValid( opts ) then return false, "invalid_options" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	fallDistance = tonumber( fallDistance )
	if not fallDistance or fallDistance ~= fallDistance then return false, "invalid_fall_distance" end
	local ok, result = sv.TryTrampleFarmland( entity, x, y, z, fallDistance, opts )
	if ok ~= true then return false, result or "trample_rejected" end
	return true, deepCopy( result )
end

------------------------------------------------------------------ API.Schedule
-- Block update scheduler access for custom functional blocks.
API.Schedule = API.Schedule or {}
local Schedule = API.Schedule

-- Run the cell's OnScheduledTick handler after delayTicks (20 TPS ticks).
function Schedule.BlockTick( bx, by, bz, delayTicks, expectedStateId )
	local sv = SV()
	if not sv or not sv.ScheduleBlockTick then return false, "scheduler_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.ScheduleBlockTick( x, y, z, delayTicks, nil, expectedStateId )
end

-- Enqueue an immediate neighbor-update for the cell's handler.
function Schedule.BlockUpdate( bx, by, bz )
	local sv = SV()
	if not sv or not sv.EnqueueBlockUpdate then return false, "scheduler_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.EnqueueBlockUpdate( x, y, z )
end

-- Cancel the pending scheduled tick at a cell. The scheduler keeps ONE tick
-- slot per cell per update kind with no ownership, so this cancels whoever's
-- tick is there - minecraft:observer blocks rely on exactly that. It is NOT a
-- way to detach a Schedule.Observe listener; use Schedule.Unobserve for that.
-- Returns false when nothing was pending.
function Schedule.CancelBlockTick( bx, by, bz )
	local sv = SV()
	if not sv or not sv.CancelBlockTick then return false, "scheduler_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.CancelBlockTick( x, y, z ) == true
end

-- Attach behavior to a block WITHOUT taking over its handler slot.
--
-- match is a block name ("minecraft:wheat") or a function( stateId, schema ).
-- definition takes OnScheduledTick / OnNeighborUpdate / OnRandomTick with the
-- same context and { cells, schedule, updates } contract as a block handler.
-- Random callbacks share the scheduler's callback/cell budgets and isolation.
-- The block's own handler runs first; observers follow in registration order.
--
-- Use this rather than a broadcast hook: per-block updates run thousands of
-- times a second under liquids and redstone, so dispatch is filtered by state
-- and cached. States nobody observes cost one table lookup.
function Schedule.Observe( key, match, definition )
	if not MC.RegisterBlockUpdateObserver then return false, "scheduler_unavailable" end
	local observer, err = MC.RegisterBlockUpdateObserver( key, match, definition )
	if not observer then return false, err or "invalid_observer" end
	return true
end

function Schedule.Unobserve( key )
	if not MC.UnregisterBlockUpdateObserver then return false, "scheduler_unavailable" end
	return MC.UnregisterBlockUpdateObserver( key ) == true
end

-- Pulse a redstone target block or lightning rod at the cell.
function API.Redstone.Pulse( bx, by, bz, power, durationTicks )
	local sv = SV()
	if not sv or not sv.PulseRedstoneTarget then return false, "redstone_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	local ok, reason = sv.PulseRedstoneTarget( x, y, z, power, durationTicks )
	if not ok and reason == "not_target" and sv.PulseLightningRod then
		return sv.PulseLightningRod( x, y, z, durationTicks )
	end
	return ok, reason
end
