--[[----------------------------------------------------------------------------
	MC : shared configuration, ConVars, net strings, atlas geometry.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Config = MC.Config or {}

------------------------------------------------------------------ world geometry
-- Units per block edge. 36.5u keeps the Minecraft scale slightly above Source's half-step edge.
-- NOTE: changing this invalidates existing saves (positions are in blocks * size).
MC.Config.BlockSize = 36.5
MC.Config.DefaultReach = MC.Config.BlockSize * 5
MC.Config.PlayerHullWidth = MC.Config.BlockSize * 0.6
MC.Config.PlayerHullHeight = MC.Config.BlockSize * 1.8
MC.Config.PlayerDuckHeight = MC.Config.BlockSize * 1.5
MC.Config.PlayerViewHeight = MC.Config.BlockSize * 1.62
MC.Config.PlayerDuckViewHeight = MC.Config.BlockSize * 1.27
MC.Config.PlayerJumpPower = 240
-- Minecraft-style chunk section: 16x16x32 blocks.
-- Z is not globally clamped; sections are addressed by their chunk Z.
MC.Config.ChunkSize = 16
MC.Config.ChunkHeight = 32

-- convenience locals mirrored onto MC for hot paths
MC.BS = MC.Config.BlockSize
MC.CS = MC.Config.ChunkSize
MC.CH = MC.Config.ChunkHeight
MC.ChunkWorld = MC.CS * MC.BS
MC.ChunkWorldH = MC.CH * MC.BS

------------------------------------------------------------------ atlas geometry
-- Must match _build/build_atlas.ps1 (TILE/COLS) and the produced atlas height.
MC.Atlas = {
	COLS = 32,
	ROWS = 40,
	TILE = 64,
	PAD = 4,
	STRIDE = 72,
	W = 4096,
	H = 4096,
	INSET = 0.5,
	MATERIAL = "mc/atlas_365",
	MATERIAL_TRANSLUCENT = "mc/atlas_365_translucent",
}

------------------------------------------------------------------ net strings
if SERVER then
	for _, name in ipairs( {
		"mc_full",
		"mc_full_begin",
		"mc_full_part",
		"mc_full_end",
		"mc_full_ack",
		"mc_snapshot_begin",
		"mc_snapshot_part",
		"mc_snapshot_ack",
		"mc_http_manifest",
		"mc_http_chunk",
		"mc_http_chunk_bulk",
		"mc_http_failed",
		"mc_unload_chunk",
		"mc_set",
		"mc_set_bulk",
		"mc_fx",
		"mc_clear",
		"mc_collision_debug_req",
		"mc_collision_debug",
		"mc_save_list_req",
		"mc_save_list_data",
		"mc_save_action",
		"mc_save_cover_begin",
		"mc_save_cover_part",
		"mc_save_cover_req",
		"mc_save_cover_download_begin",
		"mc_save_cover_download_part",
		"mc_preset_list_req",
		"mc_preset_list_data",
		"mc_preset_save",
		"mc_preset_load_req",
		"mc_preset_data",
		"mc_preset_data_part",
		"mc_preset_place",
		"mc_preset_cover_begin",
		"mc_preset_cover_part",
		"mc_preset_cover_req",
		"mc_preset_cover_download_begin",
		"mc_preset_cover_download_part",
	} ) do
		util.AddNetworkString( name )
	end
end

-- Bit widths used by the net protocol (shared so both ends agree).
MC.Net = {
	COORD_BITS = 20, -- signed block coord (+-524288 blocks; far beyond any map)
	LOCAL_BITS = 13, -- local index 0..8191 (16*16*32-1)
	ID_BITS    = 16, -- block id 0..65535
	ORIENT_BITS = 4, -- block state nibble; doors need facing + half + opened
	COUNT_BITS = 14, -- blocks per chunk section 0..8192
}

local SYNC_MESSAGE_OVERHEAD_BYTES = 64
local SYNC_CELL_BITS = MC.Net.LOCAL_BITS + MC.Net.ID_BITS + MC.Net.ORIENT_BITS

function MC.EstimateSyncBeginBytes()
	return math.ceil( ( MC.Net.COORD_BITS * 3 + MC.Net.COUNT_BITS ) / 8 ) + SYNC_MESSAGE_OVERHEAD_BYTES
end

function MC.EstimateSyncPartBytes( cells )
	cells = math.max( 0, math.floor( tonumber( cells ) or 0 ) )
	local bits = MC.Net.COORD_BITS * 3 + MC.Net.COUNT_BITS + cells * SYNC_CELL_BITS
	return math.ceil( bits / 8 ) + SYNC_MESSAGE_OVERHEAD_BYTES
end

function MC.EstimateSyncEndBytes()
	return math.ceil( ( MC.Net.COORD_BITS * 3 ) / 8 ) + SYNC_MESSAGE_OVERHEAD_BYTES
end

function MC.SyncCellsForByteBudget( bytes )
	bytes = math.floor( tonumber( bytes ) or 0 )
	local bits = ( bytes - SYNC_MESSAGE_OVERHEAD_BYTES ) * 8 - MC.Net.COORD_BITS * 3 - MC.Net.COUNT_BITS
	if bits < SYNC_CELL_BITS then return 0 end
	return math.floor( bits / SYNC_CELL_BITS )
end

MC.Config.SyncCellsPerPart = 2048
MC.Config.SyncMessagesPerTick = 4
MC.Config.SyncReliableBudget = 32768
MC.Config.SyncFrameMS = 4
MC.Config.SyncInFlightLimit = 65536
MC.Config.SyncSnapshot = 1
MC.Config.SyncSnapshotPartBytes = 32768
MC.Config.ChunkHTTPEnabled = 0
MC.Config.ChunkHTTPBaseURL = ""
MC.Config.ClientCollisionChunkSpan = 1
MC.Config.StreamChunkSpanXY = 0
MC.Config.StreamChunkSpanZ = 0
MC.Config.ServerCollisionChunkSpan = 0
MC.Config.ServerCollisionAABBPadding = MC.Config.BlockSize
MC.Config.CollisionAimDistance = MC.Config.BlockSize * 64
MC.Config.ServerCollisionAimRadius = 1
MC.Config.ClientCollisionAimRadius = 1
MC.Config.LargeWorldLazyLoad = 0
MC.Config.LargeWorldChunkThreshold = 2048
MC.Config.SyncSnapshotMaxChunks = 0
MC.Config.ChunkStorePartCache = 8
MC.Config.ChunkStoreLoadsPerTick = 8
MC.Config.ChunkStoreFrameMS = 3
MC.Config.ServerCollisionHotSpan = 2
MC.Config.ServerCollisionLookaheadTime = 0.5
MC.Config.ServerCollisionLookaheadMax = 4
MC.Config.ExplosionMeshSectionsPerFrame = 4
MC.Config.ExplosionMeshInterval = 0.12
MC.Config.BulkCollisionChunksPerInterval = 1
MC.Config.BulkCollisionInterval = 0.12

------------------------------------------------------------------ server ConVars
if SERVER then
	local F = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.AdminOnly   = GetConVar( "mc_admin_only" ) or CreateConVar( "mc_admin_only", "0", F, "Only admins may place/break blocks" )
	MC.Config.WorldLimit  = GetConVar( "mc_world_limit" ) or CreateConVar( "mc_world_limit", "1024", F, "Max |block coordinate| from origin on each axis" )
	MC.Config.MaxBlocks   = GetConVar( "mc_max_blocks" ) or CreateConVar( "mc_max_blocks", "0", F, "Global cap on total placed blocks; 0 = unlimited" )
	MC.Config.Reach       = GetConVar( "mc_reach" ) or CreateConVar( "mc_reach", tostring( MC.Config.DefaultReach ), F, "Max distance (units) a player may place/break from; 0 disables" )
	MC.Config.FillMax     = GetConVar( "mc_fill_max" ) or CreateConVar( "mc_fill_max", "32768", F, "Max blocks one /fill may modify; 0 = unlimited" )
	MC.Config.ImportMax   = GetConVar( "mc_import_max" ) or CreateConVar( "mc_import_max", "0", F, "Max blocks one mc_import may load; 0 = unlimited" )
	MC.Config.Autosave    = GetConVar( "mc_autosave" ) or CreateConVar( "mc_autosave", "0", F, "Seconds between autosaves (0 disables)" )
	MC.Config.SavePublic  = GetConVar( "mc_save_public" ) or CreateConVar( "mc_save_public", "0", F, "Allow non-admin players to list/load/save MC saves; delete remains admin-only" )
	MC.Config.SyncCells   = GetConVar( "mc_sync_cells_per_part" ) or CreateConVar( "mc_sync_cells_per_part", tostring( MC.Config.SyncCellsPerPart ), F, "Blocks per streamed sync net message" )
	MC.Config.SyncMsgs    = GetConVar( "mc_sync_messages_per_tick" ) or CreateConVar( "mc_sync_messages_per_tick", tostring( MC.Config.SyncMessagesPerTick ), F, "Streamed sync net messages per 0.05s tick" )
	MC.Config.SyncBudget  = GetConVar( "mc_sync_reliable_budget" ) or CreateConVar( "mc_sync_reliable_budget", tostring( MC.Config.SyncReliableBudget ), F, "Approx max reliable sync bytes per 0.05s tick" )
	MC.Config.SyncFast    = GetConVar( "mc_sync_fast" ) or CreateConVar( "mc_sync_fast", "1", F, "Use ack-windowed fast full-map sync" )
	MC.Config.SyncFrame   = GetConVar( "mc_sync_frame_ms" ) or CreateConVar( "mc_sync_frame_ms", tostring( MC.Config.SyncFrameMS ), F, "Approx server CPU milliseconds spent streaming full sync each tick" )
	MC.Config.SyncWindow  = GetConVar( "mc_sync_inflight_limit" ) or CreateConVar( "mc_sync_inflight_limit", tostring( MC.Config.SyncInFlightLimit ), F, "Max unacknowledged full-sync bytes per syncing client" )
	MC.Config.SyncSnapshot = GetConVar( "mc_sync_snapshot" ) or CreateConVar( "mc_sync_snapshot", tostring( MC.Config.SyncSnapshot ), F, "Sync clients by sending one compressed save snapshot, then incremental edits" )
	MC.Config.SyncSnapshotPartBytes = GetConVar( "mc_sync_snapshot_part_bytes" ) or CreateConVar( "mc_sync_snapshot_part_bytes", tostring( MC.Config.SyncSnapshotPartBytes ), F, "Bytes per snapshot sync net part" )
	MC.Config.SyncSnapshotMaxChunks = GetConVar( "mc_sync_snapshot_max_chunks" ) or CreateConVar( "mc_sync_snapshot_max_chunks", tostring( MC.Config.SyncSnapshotMaxChunks ), F, "Legacy setting; full snapshot burst sync ignores this limit" )
	MC.Config.ChunkHTTPEnabled = GetConVar( "mc_chunk_http_enabled" ) or CreateConVar( "mc_chunk_http_enabled", tostring( MC.Config.ChunkHTTPEnabled ), F, "Allow clients to fetch lazy-save base chunks over HTTP instead of GMod net" )
	MC.Config.ChunkHTTPBaseURL = GetConVar( "mc_chunk_http_base_url" ) or CreateConVar( "mc_chunk_http_base_url", tostring( MC.Config.ChunkHTTPBaseURL ), F, "HTTP root URL serving garrysmod/data for mc lazy save manifests and parts" )
	MC.Config.StreamChunkSpanXY = GetConVar( "mc_stream_chunk_span_xy" ) or CreateConVar( "mc_stream_chunk_span_xy", tostring( MC.Config.StreamChunkSpanXY ), F, "Legacy client chunk range sync span; direct full sync ignores this" )
	MC.Config.StreamChunkSpanZ = GetConVar( "mc_stream_chunk_span_z" ) or CreateConVar( "mc_stream_chunk_span_z", tostring( MC.Config.StreamChunkSpanZ ), F, "Legacy vertical chunk range sync span; direct full sync ignores this" )
	MC.Config.LargeWorldLazyLoad = GetConVar( "mc_large_world_lazy_load" ) or CreateConVar( "mc_large_world_lazy_load", tostring( MC.Config.LargeWorldLazyLoad ), F, "Legacy lazy v8 chunk loading toggle; direct server loading is the default" )
	MC.Config.LargeWorldChunkThreshold = GetConVar( "mc_large_world_chunk_threshold" ) or CreateConVar( "mc_large_world_chunk_threshold", tostring( MC.Config.LargeWorldChunkThreshold ), F, "Chunk count at or above which imported saves should use lazy streaming behavior" )
	MC.Config.ChunkStorePartCache = GetConVar( "mc_chunk_store_part_cache" ) or CreateConVar( "mc_chunk_store_part_cache", tostring( MC.Config.ChunkStorePartCache ), F, "Maximum v8 lazy-save part files cached in memory" )
	MC.Config.ChunkStoreLoadsPerTick = GetConVar( "mc_chunk_store_loads_per_tick" ) or CreateConVar( "mc_chunk_store_loads_per_tick", tostring( MC.Config.ChunkStoreLoadsPerTick ), F, "Maximum lazy chunk hydrations per store tick" )
	MC.Config.ChunkStoreFrame = GetConVar( "mc_chunk_store_frame_ms" ) or CreateConVar( "mc_chunk_store_frame_ms", tostring( MC.Config.ChunkStoreFrameMS ), F, "Approximate lazy chunk hydration time budget per tick in milliseconds" )
	MC.Config.ServerCollisionChunkSpan = GetConVar( "mc_server_collision_chunk_span" ) or CreateConVar( "mc_server_collision_chunk_span", tostring( MC.Config.ServerCollisionChunkSpan ), F, "Extra chunk radius around server collision AABBs" )
	MC.Config.ServerCollisionAABBPadding = GetConVar( "mc_server_collision_aabb_padding" ) or CreateConVar( "mc_server_collision_aabb_padding", tostring( MC.Config.ServerCollisionAABBPadding ), F, "Source-unit padding around player/entity AABBs that keep MC chunk collision active" )
	MC.Config.CollisionAimDistance = GetConVar( "mc_collision_aim_distance" ) or CreateConVar( "mc_collision_aim_distance", tostring( MC.Config.CollisionAimDistance ), F, "Trace distance in Source units for aimed-block collision interest; independent of build reach" )
	MC.Config.ServerCollisionAimRadius = GetConVar( "mc_server_collision_aim_radius" ) or CreateConVar( "mc_server_collision_aim_radius", tostring( MC.Config.ServerCollisionAimRadius ), F, "Block radius around each player's aimed MC block that keeps chunk collision active" )
	MC.Config.ClientCollisionAimRadius = GetConVar( "mc_client_collision_aim_radius" ) or CreateConVar( "mc_client_collision_aim_radius", tostring( MC.Config.ClientCollisionAimRadius ), F, "Block radius around each player's aimed MC block used by client prediction collision" )
	MC.Config.ServerCollisionHotSpan = GetConVar( "mc_server_collision_hot_span" ) or CreateConVar( "mc_server_collision_hot_span", tostring( MC.Config.ServerCollisionHotSpan ), F, "Velocity lookahead chunk span for server collision interest" )
	MC.Config.ServerCollisionLookaheadTime = GetConVar( "mc_server_collision_lookahead_time" ) or CreateConVar( "mc_server_collision_lookahead_time", tostring( MC.Config.ServerCollisionLookaheadTime ), F, "Seconds of entity velocity lookahead for server collision interest" )
	MC.Config.ServerCollisionLookaheadMax = GetConVar( "mc_server_collision_lookahead_max" ) or CreateConVar( "mc_server_collision_lookahead_max", tostring( MC.Config.ServerCollisionLookaheadMax ), F, "Maximum chunk radius reached by velocity lookahead collision interest" )
	MC.Config.ExplosionMeshSectionsPerFrame = GetConVar( "mc_explosion_mesh_sections_per_frame" ) or CreateConVar( "mc_explosion_mesh_sections_per_frame", tostring( MC.Config.ExplosionMeshSectionsPerFrame ), F, "Client mesh rebuild sections per interval for explosion block edits" )
	MC.Config.ExplosionMeshInterval = GetConVar( "mc_explosion_mesh_interval" ) or CreateConVar( "mc_explosion_mesh_interval", tostring( MC.Config.ExplosionMeshInterval ), F, "Seconds between client mesh rebuild batches for explosion block edits" )
	MC.Config.BulkCollisionChunksPerInterval = GetConVar( "mc_bulk_collision_chunks_per_interval" ) or CreateConVar( "mc_bulk_collision_chunks_per_interval", tostring( MC.Config.BulkCollisionChunksPerInterval ), F, "Server collision chunks rebuilt per interval for explosion/preset edits" )
	MC.Config.BulkCollisionInterval = GetConVar( "mc_bulk_collision_interval" ) or CreateConVar( "mc_bulk_collision_interval", tostring( MC.Config.BulkCollisionInterval ), F, "Seconds between server collision rebuild batches for explosion/preset edits" )
	MC.Config.BlockDamage = GetConVar( "mc_block_damage" ) or CreateConVar( "mc_block_damage", "1", F, "Allow GMod damage to break MC blocks" )
	MC.Config.BlockHealthScale = GetConVar( "mc_block_health_scale" ) or CreateConVar( "mc_block_health_scale", "20", F, "Block health multiplier applied to Minecraft hardness" )
	MC.Config.BlockDamageDecay = GetConVar( "mc_block_damage_decay" ) or CreateConVar( "mc_block_damage_decay", "5", F, "Seconds before partial block damage is forgotten" )
	MC.Config.BlockExplosionScale = GetConVar( "mc_block_explosion_scale" ) or CreateConVar( "mc_block_explosion_scale", "0.04", F, "GMod blast damage to Minecraft explosion radius scale" )
	MC.Config.BlockExplosionMaxRadius = GetConVar( "mc_block_explosion_max_radius" ) or CreateConVar( "mc_block_explosion_max_radius", "8", F, "Maximum Minecraft-style block explosion radius" )
	MC.Config.BlockExplosionMaxBlocks = GetConVar( "mc_block_explosion_max_blocks" ) or CreateConVar( "mc_block_explosion_max_blocks", "4096", F, "Maximum MC blocks one GMod explosion may destroy; 0 = unlimited" )
	MC.Config.PresetMaxBlocks = GetConVar( "mc_preset_max_blocks" ) or CreateConVar( "mc_preset_max_blocks", "100000", F, "Max non-air blocks one MC preset may save/place; 0 = unlimited" )

	local reach = MC.Config.Reach:GetFloat()
	if math.abs( reach - 8192 ) < 0.01 or math.abs( reach - 182.5 ) < 0.01 then
		MC.Config.Reach:SetFloat( MC.Config.DefaultReach )
	end
end
