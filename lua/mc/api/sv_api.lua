--[[----------------------------------------------------------------------------
	MC : public API, server layer (v1).

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

function Player.CanEdit( ply )
	local sv = SV()
	return sv and sv.CanEdit and sv.CanEdit( ply ) == true or false
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

--------------------------------------------------------------------- API.Fire
local Fire = API.Fire

-- Returns ok, resultOrError.  result is a fresh table containing the committed
-- cell and selected fire type.  MCITEM deliberately cannot set arbitrary world
-- state through this surface.
function Fire.Ignite( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.IgnitePlayerAim then return false, "fire_api_unavailable" end
	local ok, resultOrError = sv.IgnitePlayerAim( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "ignite_failed" end
	return true, deepCopy( resultOrError )
end

-- Resolver-driven external flint-and-steel SWEPs use this entry point instead
-- of composing Fire.Ignite + Inventory.DamageSelected.  The game layer binds
-- the world write and selected-stack durability into one server transaction;
-- an inventory rejection leaves the world unchanged.
function Fire.UseFlintAndSteel( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.UseSelectedFlintAndSteel then return false, "fire_api_unavailable" end
	local ok, resultOrError = sv.UseSelectedFlintAndSteel( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "ignite_failed" end
	return true, deepCopy( resultOrError )
end

------------------------------------------------------------------- API.Shears
local Shears = API.Shears

-- Standalone external SWEP path: validates the player's current block aim and
-- performs only the constrained age=25 GrowingPlantHeadBlock transition.
function Shears.MaxAgePlant( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.MaxAgePlayerPlantAim then return false, "shears_api_unavailable" end
	local ok, resultOrError = sv.MaxAgePlayerPlantAim( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "shears_use_failed" end
	return true, deepCopy( resultOrError )
end

-- Inventory-proxy path: binds the age transition and selected shears damage
-- into the same pre-publication world transaction. Creative/infinite-material
-- mode preserves the selected stack exactly, matching ItemStack.hurtAndBreak.
function Shears.UseSelectedOnBlock( ply, context )
	local sv = SV()
	if not IsValid( ply ) or not ply.IsPlayer or not ply:IsPlayer() or not ply:Alive() then
		return false, "invalid_player"
	end
	if not sv or not sv.UseSelectedShearsOnBlock then return false, "shears_api_unavailable" end
	local ok, resultOrError = sv.UseSelectedShearsOnBlock( ply, deepCopy( context or {} ) )
	if ok ~= true then return false, resultOrError or "shears_use_failed" end
	return true, deepCopy( resultOrError )
end

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

local function rayDistancePastCell( origin, direction, bx, by, bz )
	if not MC.CellWorldMin then return nil end
	local base = MC.CellWorldMin( bx, by, bz )
	if not isvector( base ) then return nil end
	local blockSize = MC.BS or 36.5
	local epsilon = 1e-8
	local distance = math.huge
	if direction.x > epsilon then
		distance = math.min( distance, ( base.x + blockSize - origin.x ) / direction.x )
	elseif direction.x < -epsilon then
		distance = math.min( distance, ( base.x - origin.x ) / direction.x )
	end
	if direction.y > epsilon then
		distance = math.min( distance, ( base.y + blockSize - origin.y ) / direction.y )
	elseif direction.y < -epsilon then
		distance = math.min( distance, ( base.y - origin.y ) / direction.y )
	end
	if direction.z > epsilon then
		distance = math.min( distance, ( base.z + blockSize - origin.z ) / direction.z )
	elseif direction.z < -epsilon then
		distance = math.min( distance, ( base.z - origin.z ) / direction.z )
	end
	if distance == math.huge then return nil end
	return math.max( 0, distance ) + math.max( blockSize / 4096, 0.01 )
end

-- BucketItem clips block OUTLINE geometry in both modes. Pure liquid blocks
-- have an empty outline in Java, so skip them while retaining waterlogged
-- containers and every ordinary block selection shape.
local function bucketOutlineHit( eye, direction, reach )
	if not MC.TraceBlockRay or not MC.LiquidStateMetrics then return nil end
	local origin = eye
	local travelled = 0
	local blockSize = MC.BS or 36.5
	local maxSteps = math.ceil( reach / blockSize ) * 3 + 8
	for _ = 1, maxSteps do
		local remaining = reach - travelled
		if remaining <= 0 then break end
		local hit = MC.TraceBlockRay( origin, direction, remaining )
		if not hit then return nil end
		local kind, _, _, _, waterlogged = MC.LiquidStateMetrics( hit.StateId or 0 )
		if not kind or waterlogged == true then
			local localDistance = tonumber( hit.Distance )
				or isvector( hit.HitPos ) and hit.HitPos:Distance( origin ) or 0
			hit.Distance = travelled + localDistance
			hit.HitPos = eye + direction * hit.Distance
			hit.Fraction = reach > 0 and hit.Distance / reach or 0
			return hit
		end

		local advance = rayDistancePastCell( origin, direction, hit.bx, hit.by, hit.bz )
		if not advance then return nil end
		travelled = travelled + advance
		origin = eye + direction * travelled
	end
	return nil
end

local function bucketAim( ply, sourceOnly )
	if not validLiquidPlayer( ply ) then return nil, "invalid_player" end
	local eye = MC.EntityEyeWorldPos and MC.EntityEyeWorldPos( ply ) or ply:EyePos()
	local direction = ply:EyeAngles():Forward()
	if direction:LengthSqr() <= 0 then return nil, "invalid_ray" end
	direction:Normalize()
	local reach = MC.CurrentReach and MC.CurrentReach() or ( ( MC.BS or 36.5 ) * 5 )
	local outlineHit = bucketOutlineHit( eye, direction, reach )
	local worldObstruction = bucketWorldObstructionDistance( ply, eye, direction, reach )
	local obstructionTolerance = math.max( ( MC.BS or 36.5 ) / 4096, 0.01 )

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
		local blockSize = MC.BS or 36.5
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
	if reach > 0 and not MC.ReachAllowsEye( ply:EyePos(), bx, by, bz, reach ) then
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

------------------------------------------------------------------- API.Mining
-- Public, tool-agnostic survival mining. External SWEPs provide only an item
-- id/stack and their active weapon entity; MCSWEP remains authoritative for
-- reach, block state, vanilla speed, crack stages, loot and the transaction.
API.Mining = API.Mining or {}
local Mining = API.Mining

local function validMiningPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer()
end

local function normalizeMiningStack( input )
	if input == nil then return nil end
	if isstring( input ) then
		if input == "" then return nil, "invalid_item" end
		return { item = string.find( input, ":", 1, true ) and input or "minecraft:" .. input, count = 1 }
	end
	if not istable( input ) or not isstring( input.item ) or input.item == "" then return nil, "invalid_item" end
	return deepCopy( input )
end

function Mining.Start( ply, bx, by, bz, options )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.BeginMining then return false, "mining_api_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	options = istable( options ) and options or {}
	local stack, stackError = normalizeMiningStack( options.toolStack or options.item )
	if stackError then return false, stackError end
	local weapon = options.weapon
	if not IsValid( weapon ) then return false, "invalid_weapon" end
	return sv.BeginMining( ply, x, y, z, {
		external = true,
		toolStack = stack,
		weapon = weapon,
		sourceId = options.sourceId,
		sourceToken = options.sourceToken,
		requireAttackHeld = options.requireAttackHeld,
		requireAim = options.requireAim,
		modifiers = istable( options.modifiers ) and deepCopy( options.modifiers ) or nil,
		onCancel = isfunction( options.onCancel ) and options.onCancel or nil,
		onComplete = isfunction( options.onComplete ) and options.onComplete or nil,
		onDurabilityDamage = isfunction( options.onDurabilityDamage ) and options.onDurabilityDamage or nil,
		validate = isfunction( options.validate ) and options.validate or nil,
	} )
end

function Mining.Cancel( ply, reason )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.CancelMining then return false, "mining_api_unavailable" end
	return sv.CancelMining( ply, tostring( reason or "external_cancel" ) )
end

function Mining.Get( ply )
	local sv = SV()
	if not validMiningPlayer( ply ) then return nil, "invalid_player" end
	if not sv or not sv.GetMiningSession then return nil, "mining_api_unavailable" end
	return deepCopy( sv.GetMiningSession( ply ) )
end

function Mining.ProgressPerTick( ply, bx, by, bz, item, modifiers )
	if not validMiningPlayer( ply ) then return nil, "invalid_player" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return nil, "invalid_cell" end
	local stack, stackError = normalizeMiningStack( item )
	if stackError then return nil, stackError end
	local stateId = MC.GetBlockState and MC.GetBlockState( x, y, z ) or 0
	if stateId == 0 then return nil, "air" end
	if not MC.BlockMiningProgressPerTick then return nil, "mining_rules_unavailable" end
	local progress, err, mining, resolvedModifiers = MC.BlockMiningProgressPerTick(
		stateId, stack, ply, istable( modifiers ) and deepCopy( modifiers ) or nil )
	if not progress then return nil, err end
	return progress, nil, deepCopy( mining ), deepCopy( resolvedModifiers )
end

-- Resolve the vanilla block loot for an arbitrary state/tool without changing
-- the world.  Unlike player mining this mirrors BlockState#getDrops directly:
-- the loot table's own match_tool predicates decide correctness, so the
-- survival mining precheck is deliberately bypassed.  Returned stacks and
-- metadata are fresh copies.
function Mining.ResolveDrops( block, toolStack, context )
	local sv = SV()
	if not sv or not sv.ResolveBlockDrops then return nil, "mining_api_unavailable" end
	local stateId, stateError = resolveStateInput( block )
	if stateId == nil then return nil, stateError or "invalid_state" end
	if stateId == 0 then return {}, nil end
	local stack, stackError = normalizeMiningStack( toolStack )
	if stackError then return nil, stackError end
	local copy = istable( context ) and deepCopy( context ) or {}
	copy.skipCorrectToolCheck = true
	local drops, err, mining = sv.ResolveBlockDrops( stateId, stack, copy )
	if not drops then return nil, err or "block_loot_failed" end
	return deepCopy( drops ), err, deepCopy( mining )
end

function Mining.IsCreative( ply )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	return sv and sv.PlayerIsCreative and sv.PlayerIsCreative( ply ) == true or false
end

function Mining.BreakCreative( ply, bx, by, bz, options )
	local sv = SV()
	if not validMiningPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.TryCreativeBreak then return false, "mining_api_unavailable" end
	if not ( sv.PlayerIsCreative and sv.PlayerIsCreative( ply ) ) then return false, "not_creative" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.TryCreativeBreak( ply, x, y, z, istable( options ) and deepCopy( options ) or nil )
end

----------------------------------------------------------------- API.Inventory
API.Inventory = API.Inventory or {}
local Inventory = API.Inventory

local function validInventoryPlayer( ply )
	return IsValid( ply ) and ply.IsPlayer and ply:IsPlayer()
end

function Inventory.Get( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, "invalid_player" end
	if not sv or not sv.GetPlayerInventoryRecord then return nil, "inventory_api_unavailable" end
	local record = sv.GetPlayerInventoryRecord( ply )
	if not record then return nil, "inventory_not_loaded" end
	local result = { selected = record.selected, revision = record.container.revision, slots = {} }
	for slot = 0, 35 do result.slots[slot] = deepCopy( record.storage[slot + 1] ) end
	return result
end

function Inventory.GetSlot( ply, slot )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, "invalid_player" end
	slot = math.floor( tonumber( slot ) or -1 )
	if slot < 0 or slot > 35 then return nil, "invalid_slot" end
	if not sv or not sv.GetPlayerInventoryStack then return nil, "inventory_api_unavailable" end
	return deepCopy( sv.GetPlayerInventoryStack( ply, slot ) )
end

function Inventory.GetSelected( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, nil, "invalid_player" end
	if not sv or not sv.GetPlayerInventoryRecord or not sv.GetSelectedPlayerStack then
		return nil, nil, "inventory_api_unavailable"
	end
	local record = sv.GetPlayerInventoryRecord( ply, false )
	if not record then return nil, nil, "inventory_not_loaded" end
	return deepCopy( sv.GetSelectedPlayerStack( ply ) ), record.selected
end

function Inventory.Give( ply, item, count, components, damage )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return 0, nil, "invalid_player" end
	if not sv or not sv.InsertPlayerItem then return 0, nil, "inventory_api_unavailable" end
	local stack, err = MC.NewItemStack( item, count or 1, components, damage )
	if not stack then return 0, nil, err or "invalid_stack" end
	local remainder, result = sv.InsertPlayerItem( ply, stack, { reason = "api_give" } )
	if result == nil then return 0, stack, "inventory_insert_failed" end
	local remainingCount = remainder and remainder.count or 0
	return stack.count - remainingCount, deepCopy( remainder )
end

function Inventory.Remove( ply, item, count )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return 0, "invalid_player" end
	if not sv or not sv.RemovePlayerItem then return 0, "inventory_api_unavailable" end
	return sv.RemovePlayerItem( ply, item, count or 1, { reason = "api_remove" } )
end

function Inventory.Select( ply, slot )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.SetPlayerSelectedSlot then return false, "inventory_api_unavailable" end
	return sv.SetPlayerSelectedSlot( ply, slot, { reason = "api_select" } )
end

function Inventory.DamageSelected( ply, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, "invalid_player" end
	if not sv or not sv.DamageSelectedItem then return nil, false, "inventory_api_unavailable" end
	local result, broken, err = sv.DamageSelectedItem( ply, amount, deepCopy( context or {} ) )
	return deepCopy( result ), broken == true, err
end

-- Atomically applies a non-breaking durability use and extracts one complete
-- copy of the selected ItemStack.  Used by external trident implementations so
-- damage/components travel with the projectile and return unchanged on pickup.
-- Returns stack, infinite, mutationResult, err.  In infinite-material mode the
-- selected slot is unchanged and the returned projectile stack is still a copy.
function Inventory.TakeSelectedWithDurability( ply, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, nil, "invalid_player" end
	if not sv or not sv.TakeSelectedItemWithDurability then
		return nil, false, nil, "inventory_api_unavailable"
	end
	local stack, infinite, result, err = sv.TakeSelectedItemWithDurability(
		ply,
		amount,
		deepCopy( context or {} )
	)
	return deepCopy( stack ), infinite == true, deepCopy( result ), err
end

function Inventory.CanTakeSelectedWithDurability( ply, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, false, nil, "invalid_player" end
	if not sv or not sv.CanTakeSelectedItemWithDurability then
		return false, false, nil, "inventory_api_unavailable"
	end
	local allowed, infinite, stack, err = sv.CanTakeSelectedItemWithDurability(
		ply,
		amount,
		deepCopy( context or {} )
	)
	return allowed == true, infinite == true, deepCopy( stack ), err
end

function Inventory.ConsumeSelected( ply, amount, replacement, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, 0, nil, false, "invalid_player" end
	if not sv or not sv.ConsumeSelectedItem then return nil, 0, nil, false, "inventory_api_unavailable" end
	local result, consumed, overflow, infinite, err = sv.ConsumeSelectedItem(
		ply,
		amount,
		deepCopy( replacement ),
		deepCopy( context or {} )
	)
	return deepCopy( result ), consumed, deepCopy( overflow ), infinite == true, err
end

-- Atomically consumes a real item from mainhand/offhand, including in creative
-- mode. Intended for Java mechanics such as death protection whose source code
-- directly shrinks the held stack. Returns result, consumed, oldStack, err.
function Inventory.ConsumeHeld( ply, hand, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, 0, nil, "invalid_player" end
	if not sv or not sv.ConsumeHeldItem then return nil, 0, nil, "inventory_api_unavailable" end
	local copy = deepCopy( context or {} )
	copy.hand = hand
	local result, consumed, oldStack, err = sv.ConsumeHeldItem(
		ply,
		amount,
		copy
	)
	return deepCopy( result ), consumed, deepCopy( oldStack ), err
end

function Inventory.ReplaceSelected( ply, replacement, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, nil, "invalid_player" end
	if not sv or not sv.ReplaceSelectedItem then return nil, nil, "inventory_api_unavailable" end
	local result, stack, err = sv.ReplaceSelectedItem(
		ply, deepCopy( replacement ), deepCopy( context or {} ) )
	return deepCopy( result ), deepCopy( stack ), err
end

function Inventory.HasInfiniteMaterials( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.PlayerHasInfiniteMaterials then
		return false, "inventory_api_unavailable"
	end
	return sv.PlayerHasInfiniteMaterials( ply ) == true
end

function Inventory.Open( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.OpenPlayerInventory then return false, "inventory_api_unavailable" end
	return sv.OpenPlayerInventory( ply, "api" )
end

-- Projectile ammo for external bow/crossbow SWEPs. kind is "bow" (arrow /
-- spectral arrow) or "crossbow" (also firework rockets). Creative players
-- report ammo without owning any and never consume it.
function Inventory.HasAmmo( ply, kind )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.FindProjectileAmmo then return false, "inventory_api_unavailable" end
	if sv.PlayerHasInfiniteMaterials and sv.PlayerHasInfiniteMaterials( ply ) then return true end
	local _, stack, err = sv.FindProjectileAmmo( ply, kind )
	if not stack then return false, err end
	return true, nil, deepCopy( stack )
end

-- Selects the same complete ammo ItemStack the built-in projectile path would
-- use. Infinite-material players still prefer an owned arrow type; only an
-- actually empty inventory falls back to a generated normal arrow.
-- Returns stack, slot, infinite, generated, err.
function Inventory.SelectAmmo( ply, kind )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, nil, false, false, "invalid_player" end
	if not sv or not sv.SelectProjectileAmmo then return nil, nil, false, false, "inventory_api_unavailable" end
	local stack, slot, infinite, generated, err = sv.SelectProjectileAmmo( ply, kind )
	return deepCopy( stack ), slot, infinite == true, generated == true, err
end

-- Compatibility wrapper. Returns consumed, itemName, err, infinite, stack.
function Inventory.ConsumeAmmo( ply, kind, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return 0, nil, "invalid_player" end
	if not sv or not sv.ConsumeProjectileAmmo then return 0, nil, "inventory_api_unavailable" end
	local consumed, itemName, err, infinite, stack = sv.ConsumeProjectileAmmo(
		ply, kind, amount, deepCopy( context or {} )
	)
	return consumed, itemName, err, infinite, deepCopy( stack )
end

-- Atomically selects and (outside infinite-material mode) consumes projectile
-- ammunition. Returns stack, consumed, infinite, generated, err.
function Inventory.TakeAmmo( ply, kind, amount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, 0, false, false, "invalid_player" end
	if not sv or not sv.TakeProjectileAmmo then return nil, 0, false, false, "inventory_api_unavailable" end
	local stack, consumed, infinite, generated, err = sv.TakeProjectileAmmo(
		ply, kind, amount, deepCopy( context or {} )
	)
	return deepCopy( stack ), consumed, infinite == true, generated == true, err
end

-- Atomically selects one projectile and stores it in the selected crossbow's
-- charged_projectiles component. Returns stack, infinite, generated, result,
-- err. `kind="bow"` intentionally excludes firework rockets.
function Inventory.LoadCrossbowProjectile( ply, kind, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, false, nil, "invalid_player" end
	if not sv or not sv.LoadSelectedCrossbowProjectile then
		return nil, false, false, nil, "inventory_api_unavailable"
	end
	local stack, infinite, generated, result, err = sv.LoadSelectedCrossbowProjectile(
		ply,
		kind,
		deepCopy( context or {} )
	)
	return deepCopy( stack ), infinite == true, generated == true, deepCopy( result ), err
end

-- Atomically clears charged_projectiles and damages the selected crossbow.
-- The external projectile must be removed when this call fails.
function Inventory.CommitCrossbowShot( ply, durabilityAmount, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return nil, false, nil, false, "invalid_player" end
	if not sv or not sv.CommitSelectedCrossbowShot then
		return nil, false, nil, false, "inventory_api_unavailable"
	end
	local result, broken, projectile, infinite, err = sv.CommitSelectedCrossbowShot(
		ply,
		durabilityAmount,
		deepCopy( context or {} )
	)
	return deepCopy( result ), broken == true, deepCopy( projectile ), infinite == true, err
end

-- Public selected-item use bridge for resolver-driven external SWEPs. These
-- are the same state-machine functions used by mc_item_hand, but every call is
-- pinned to the caller-supplied active SWEP class. The private allowAnyWeapon
-- flag is never accepted without that exact-class assertion.
local function externalUseContext( ply, context )
	local copy = deepCopy( context or {} )
	local expectedClass = tostring( copy.expectedClass or "" )
	if expectedClass == "" then return nil, "expected_weapon_class_missing" end
	local weapon = IsValid( ply ) and ply.GetActiveWeapon and ply:GetActiveWeapon() or nil
	if not IsValid( weapon ) or not weapon.GetClass or weapon:GetClass() ~= expectedClass then
		return nil, "active_weapon_mismatch"
	end
	copy.expectedClass = expectedClass
	copy.allowAnyWeapon = true
	return copy
end

function Inventory.BeginSelectedUse( ply, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.BeginSelectedItemUse then return false, "inventory_api_unavailable" end
	local useContext, contextError = externalUseContext( ply, context )
	if not useContext then return false, contextError end
	return sv.BeginSelectedItemUse( ply, useContext )
end

function Inventory.TickSelectedUse( ply, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.TickSelectedItemUse then return false, "inventory_api_unavailable" end
	local useContext, contextError = externalUseContext( ply, context )
	if not useContext then return false, contextError end
	return sv.TickSelectedItemUse( ply, useContext )
end

function Inventory.ReleaseSelectedUse( ply, context )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.ReleaseSelectedItemUse then return false, "inventory_api_unavailable" end
	local useContext, contextError = externalUseContext( ply, context )
	if not useContext then return false, contextError end
	return sv.ReleaseSelectedItemUse( ply, useContext )
end

function Inventory.CancelSelectedUse( ply, reason )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.CancelSelectedItemUse then return false, "inventory_api_unavailable" end
	return sv.CancelSelectedItemUse( ply, tostring( reason or "external_cancelled" ) )
end

function Inventory.IsShieldDisabled( ply )
	local sv = SV()
	if not validInventoryPlayer( ply ) then return false, "invalid_player" end
	if not sv or not sv.IsPlayerShieldDisabled then return false, "inventory_api_unavailable" end
	return sv.IsPlayerShieldDisabled( ply ) == true, nil,
		math.max( 0, ( tonumber( ply:GetNWFloat( "mc_shield_disabled_until", 0 ) ) or 0 ) - CurTime() )
end

-- Spawn a world item drop (the same mc_item_drop entity block loot and player
-- drops use), so external addons never have to invent their own pickup entity.
-- options: { velocity = Vector, pickupDelay = seconds, lifetime = seconds
--            (<=0 means never expire), target = ply (owner-only pickup) }.
function Inventory.SpawnDrop( position, item, count, actor, options )
	local sv = SV()
	if not sv or not sv.SpawnItemDrop then return nil, "inventory_api_unavailable" end
	if not isvector( position ) then return nil, "invalid_position" end
	local stack, stackError = MC.NewItemStack( item, count or 1 )
	if not stack then return nil, stackError or "invalid_stack" end
	local ent, err = sv.SpawnItemDrop( position, stack, actor, deepCopy( options or {} ) )
	if not IsValid( ent ) then return nil, err or "item_drop_failed" end
	return ent
end

-- Full-ItemStack twin of SpawnDrop.  This is the path for damaged or component-
-- bearing items (thrown tridents, potion stacks, enchanted equipment, etc.).
function Inventory.SpawnDropStack( position, input, actor, options )
	local sv = SV()
	if not sv or not sv.SpawnItemDrop then return nil, "inventory_api_unavailable" end
	if not isvector( position ) then return nil, "invalid_position" end
	local stack, stackError = MC.NormalizeItemStack( deepCopy( input ) )
	if not stack then return nil, stackError or "invalid_stack" end
	local ent, err = sv.SpawnItemDrop( position, stack, actor, deepCopy( options or {} ) )
	if not IsValid( ent ) then return nil, err or "item_drop_failed" end
	return ent
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
-- definition takes OnScheduledTick / OnNeighborUpdate with the same contract as
-- a block handler, so an observer may return its own cells/schedule/updates.
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
