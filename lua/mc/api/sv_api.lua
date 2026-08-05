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
-- opts: actor, ignoreVolumeLimit (skip mc_fill_max). Returns the fill result
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

-- True for both save layouts. SaveSlotPath is the directory manifest
-- (data/mc/saves/<name>/manifest.json); older slots are a single .dat and
-- stay loadable, so reporting them as missing here would contradict
-- Saves.Load, which falls back to the legacy path too.
function Saves.Exists( name )
	local sv = SV()
	if not sv or not sv.SaveSlotName or not sv.SaveSlotPath then return false end
	local slot = sv.SaveSlotName( name )
	if not slot then return false end
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
-- slot per cell with no ownership, so this cancels whoever's tick is there
-- (observers rely on exactly that); returns false when nothing was pending.
function Schedule.CancelBlockTick( bx, by, bz )
	local sv = SV()
	if not sv or not sv.CancelBlockTick then return false, "scheduler_unavailable" end
	local x, y, z = cellCoords( bx, by, bz )
	if not x then return false, "invalid_cell" end
	return sv.CancelBlockTick( x, y, z ) == true
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
