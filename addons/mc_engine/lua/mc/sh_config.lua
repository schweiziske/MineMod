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
MC.Config.CollisionSubchunkSize = 8

-- convenience locals mirrored onto MC for hot paths
MC.BS = MC.Config.BlockSize
MC.CS = MC.Config.ChunkSize
MC.CH = MC.Config.ChunkHeight
MC.CollisionSubchunkSize = MC.Config.CollisionSubchunkSize
MC.ChunkWorld = MC.CS * MC.BS
MC.ChunkWorldH = MC.CH * MC.BS

------------------------------------------------------------------ atlas geometry
-- Must match _build/build_atlas.ps1 (TILE/COLS) and the produced atlas size.
-- 56 padded columns keep ~1280 tiles inside a 4096x2048 canvas instead of
-- wasting ~60% of a 4096x4096 one; sh_generated_tiles.lua overrides these.
MC.Atlas = {
	COLS = 56,
	ROWS = 23,
	TILE = 64,
	PAD = 4,
	STRIDE = 72,
	W = 4096,
	H = 2048,
	INSET = 0.5,
	MATERIAL = "mc/atlas_365",
	MATERIAL_TRANSLUCENT = "mc/atlas_365_translucent",
	MATERIAL_PROGRAMMER_ART = "mc/atlas_365_programmer_art",
	MATERIAL_PROGRAMMER_ART_TRANSLUCENT = "mc/atlas_365_programmer_art_translucent",
}

------------------------------------------------------------------ reliable transport pacing
-- All large state payloads (join snapshots, ordered streams, Chunk hydration,
-- paced legacy bulk messages and preset downloads) share this one queue.
MC.Config.SyncMessagesPerTick = 4
MC.Config.SyncReliableBudget = 3400
MC.Config.SyncFrameMS = 4
MC.Config.SyncInFlightLimit = 32768
MC.Config.FillBatchCells = 4096
MC.Config.FillBatchChunks = 16
MC.Config.FillBatchInterval = 0.05
MC.Config.ChunkHTTPEnabled = 0
MC.Config.ChunkHTTPBaseURL = ""
MC.Config.ClientCollisionChunkSpan = 1
MC.Config.StreamChunkSpanXY = 8
MC.Config.StreamChunkSpanZ = 0
MC.Config.ChunkStreaming = 0
MC.Config.StreamUnloadMargin = 2
MC.Config.StreamColumnsPerBatch = 1
MC.Config.StreamMaxPatchChunks = 16
MC.Config.StreamMaxPatchCells = 32768
MC.Config.StreamInterval = 0.3
MC.Config.BinaryChunkPatch = 1
MC.Config.BinaryNetProfile = 0
MC.Config.ServerCollision = 1
MC.Config.ServerCollisionChunkSpan = 0
MC.Config.ServerCollisionAABBPadding = MC.Config.BlockSize
MC.Config.CollisionAimDistance = MC.Config.BlockSize * 512
MC.Config.ServerCollisionAimRadius = 1
MC.Config.ClientCollisionAimRadius = 1
MC.Config.LargeWorldLazyLoad = 0
MC.Config.LargeWorldChunkThreshold = 2048
MC.Config.ChunkStorePartCache = 8
MC.Config.ChunkStoreLoadsPerTick = 8
MC.Config.ChunkStoreFrameMS = 3
MC.Config.ServerCollisionHotSpan = 2
MC.Config.ServerCollisionLookaheadTime = 0.5
MC.Config.ServerCollisionLookaheadMax = 4
MC.Config.BulkCollisionChunksPerInterval = 1
MC.Config.BulkCollisionInterval = 0.12

------------------------------------------------------------------ server ConVars
if SERVER then
	local F = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.AdminOnly   = GetConVar( "mc_admin_only" ) or CreateConVar( "mc_admin_only", "0", F, "Only admins may place/break blocks" )
	MC.Config.WorldLimit  = GetConVar( "mc_world_limit" ) or CreateConVar( "mc_world_limit", "1024", F, "Max |block coordinate| from origin on each axis" )
	MC.Config.MaxBlocks   = GetConVar( "mc_max_blocks" ) or CreateConVar( "mc_max_blocks", "0", F, "Global cap on total placed blocks; 0 = unlimited" )
	MC.Config.Reach       = GetConVar( "mc_reach" ) or CreateConVar( "mc_reach", tostring( MC.Config.DefaultReach ), F, "Max distance (units) a player may place/break from; 0 disables" )
	MC.Config.FillMax     = GetConVar( "mc_fill_max" ) or CreateConVar( "mc_fill_max", "100000", F, "Max blocks one /fill may modify; 0 = unlimited" )
	MC.Config.FillBatchCells = GetConVar( "mc_fill_batch_cells" ) or CreateConVar( "mc_fill_batch_cells", tostring( MC.Config.FillBatchCells ), F, "Max /fill cells applied per server batch" )
	MC.Config.FillBatchChunks = GetConVar( "mc_fill_batch_chunks" ) or CreateConVar( "mc_fill_batch_chunks", tostring( MC.Config.FillBatchChunks ), F, "Max chunks touched per /fill server batch" )
	MC.Config.FillBatchInterval = GetConVar( "mc_fill_batch_interval" ) or CreateConVar( "mc_fill_batch_interval", tostring( MC.Config.FillBatchInterval ), F, "Seconds between /fill server batches" )
	MC.Config.ImportMax   = GetConVar( "mc_import_max" ) or CreateConVar( "mc_import_max", "0", F, "Max blocks one mc_import may load; 0 = unlimited" )
	MC.Config.Autosave    = GetConVar( "mc_autosave" ) or CreateConVar( "mc_autosave", "0", F, "Seconds between autosaves (0 disables)" )
	MC.Config.SavePublic  = GetConVar( "mc_save_public" ) or CreateConVar( "mc_save_public", "0", F, "Allow non-admin players to list/load/save MC saves; delete remains admin-only" )
	MC.Config.WorkshopManage = GetConVar( "mc_workshop_manage" ) or CreateConVar( "mc_workshop_manage", "0", F, "Who may publish/import MC Workshop worlds: 0 superadmins, 1 admins, 2 everyone", 0, 2 )
	MC.Config.PresetPublic = GetConVar( "mc_preset_public" ) or CreateConVar( "mc_preset_public", "0", F, "Allow non-admin players to list/load/save/place MC presets" )
	MC.Config.ClusterPublic = GetConVar( "mc_cluster_public" ) or CreateConVar( "mc_cluster_public", "0", F, "Allow non-admin players to use the MC structure grabber" )
	MC.Config.SyncMsgs    = GetConVar( "mc_sync_messages_per_tick" ) or CreateConVar( "mc_sync_messages_per_tick", tostring( MC.Config.SyncMessagesPerTick ), F, "Maximum queued reliable state messages sent per player per 0.05s tick", 1, 16 )
	MC.Config.SyncBudget  = GetConVar( "mc_sync_reliable_budget" ) or CreateConVar( "mc_sync_reliable_budget", tostring( MC.Config.SyncReliableBudget ), F, "Hard queued reliable state byte budget per player per 0.05s tick", 1024, 8192 )
	MC.Config.SyncFrame   = GetConVar( "mc_sync_frame_ms" ) or CreateConVar( "mc_sync_frame_ms", tostring( MC.Config.SyncFrameMS ), F, "Approx server CPU milliseconds spent streaming full sync each tick" )
	MC.Config.SyncWindow  = GetConVar( "mc_sync_inflight_limit" ) or CreateConVar( "mc_sync_inflight_limit", tostring( MC.Config.SyncInFlightLimit ), F, "Maximum acknowledged reliable state bytes in flight per player", 8192, 65536 )

	-- Migrate the old misleading defaults. They were displayed as 32/64KB even
	-- though the old sender silently clamped or bypassed them on different paths.
	if MC.Config.SyncBudget:GetInt() == 32768 then MC.Config.SyncBudget:SetInt( MC.Config.SyncReliableBudget ) end
	if MC.Config.SyncWindow:GetInt() == 65536 then MC.Config.SyncWindow:SetInt( MC.Config.SyncInFlightLimit ) end
	MC.Config.ChunkHTTPEnabled = GetConVar( "mc_chunk_http_enabled" ) or CreateConVar( "mc_chunk_http_enabled", tostring( MC.Config.ChunkHTTPEnabled ), F, "Allow clients to fetch lazy-save base chunks over HTTP instead of GMod net" )
	MC.Config.ChunkHTTPBaseURL = GetConVar( "mc_chunk_http_base_url" ) or CreateConVar( "mc_chunk_http_base_url", tostring( MC.Config.ChunkHTTPBaseURL ), F, "HTTP root URL serving garrysmod/data for mc lazy save manifests and parts" )
	MC.Config.ChunkStreaming = GetConVar( "mc_chunk_streaming" ) or CreateConVar( "mc_chunk_streaming", tostring( MC.Config.ChunkStreaming ), F, "Enable server-authoritative horizontal chunk-column streaming" )
	MC.Config.StreamChunkSpanXY = GetConVar( "mc_stream_chunk_span_xy" ) or CreateConVar( "mc_stream_chunk_span_xy", tostring( MC.Config.StreamChunkSpanXY ), F, "Horizontal subscribed column radius (entire vertical column is sent)", 0, 32 )
	MC.Config.StreamUnloadMargin = GetConVar( "mc_stream_unload_margin" ) or CreateConVar( "mc_stream_unload_margin", tostring( MC.Config.StreamUnloadMargin ), F, "Extra column radius retained before unloading", 0, 16 )
	MC.Config.StreamColumnsPerBatch = GetConVar( "mc_stream_columns_per_batch" ) or CreateConVar( "mc_stream_columns_per_batch", tostring( MC.Config.StreamColumnsPerBatch ), F, "Maximum newly subscribed columns queued per streaming interval", 1, 64 )
	MC.Config.StreamMaxPatchChunks = GetConVar( "mc_stream_max_patch_chunks" ) or CreateConVar( "mc_stream_max_patch_chunks", tostring( MC.Config.StreamMaxPatchChunks ), F, "Maximum non-empty chunks in one streaming hydration patch", 1, 64 )
	MC.Config.StreamMaxPatchCells = GetConVar( "mc_stream_max_patch_cells" ) or CreateConVar( "mc_stream_max_patch_cells", tostring( MC.Config.StreamMaxPatchCells ), F, "Maximum non-air cells in one streaming hydration patch", 1024, 131072 )
	MC.Config.StreamInterval = GetConVar( "mc_stream_interval" ) or CreateConVar( "mc_stream_interval", tostring( MC.Config.StreamInterval ), F, "Seconds between server column-interest updates", 0.1, 2 )
	MC.Config.BinaryChunkPatch = GetConVar( "mc_binary_chunk_patch" ) or CreateConVar( "mc_binary_chunk_patch", tostring( MC.Config.BinaryChunkPatch ), F, "Use palette/packed-word binary Section hydration instead of terrain JSON" )
	MC.Config.BinaryNetProfile = GetConVar( "mc_binary_net_profile" ) or CreateConVar( "mc_binary_net_profile", tostring( MC.Config.BinaryNetProfile ), F, "Collect server Binary Section encode, compression, queue and net.Send timings" )
	MC.Config.StreamChunkSpanZ = GetConVar( "mc_stream_chunk_span_z" ) or CreateConVar( "mc_stream_chunk_span_z", tostring( MC.Config.StreamChunkSpanZ ), F, "Reserved for future 3D-radius streaming; mode 1 always sends whole columns" )
	MC.Config.LargeWorldLazyLoad = GetConVar( "mc_large_world_lazy_load" ) or CreateConVar( "mc_large_world_lazy_load", tostring( MC.Config.LargeWorldLazyLoad ), F, "Legacy lazy v8 chunk loading toggle; direct server loading is the default" )
	MC.Config.LargeWorldChunkThreshold = GetConVar( "mc_large_world_chunk_threshold" ) or CreateConVar( "mc_large_world_chunk_threshold", tostring( MC.Config.LargeWorldChunkThreshold ), F, "Chunk count at or above which imported saves should use lazy streaming behavior" )
	MC.Config.ChunkStorePartCache = GetConVar( "mc_chunk_store_part_cache" ) or CreateConVar( "mc_chunk_store_part_cache", tostring( MC.Config.ChunkStorePartCache ), F, "Maximum v8 lazy-save part files cached in memory" )
	MC.Config.ChunkStoreLoadsPerTick = GetConVar( "mc_chunk_store_loads_per_tick" ) or CreateConVar( "mc_chunk_store_loads_per_tick", tostring( MC.Config.ChunkStoreLoadsPerTick ), F, "Maximum lazy chunk hydrations per store tick" )
	MC.Config.ChunkStoreFrame = GetConVar( "mc_chunk_store_frame_ms" ) or CreateConVar( "mc_chunk_store_frame_ms", tostring( MC.Config.ChunkStoreFrameMS ), F, "Approximate lazy chunk hydration time budget per tick in milliseconds" )
	MC.Config.ServerCollision = GetConVar( "mc_server_collision" ) or CreateConVar( "mc_server_collision", tostring( MC.Config.ServerCollision ), F, "Enable server-authoritative MC collision construction" )
	MC.Config.ServerCollisionChunkSpan = GetConVar( "mc_server_collision_chunk_span" ) or CreateConVar( "mc_server_collision_chunk_span", tostring( MC.Config.ServerCollisionChunkSpan ), F, "Extra chunk radius around server collision AABBs" )
	MC.Config.ServerCollisionAABBPadding = GetConVar( "mc_server_collision_aabb_padding" ) or CreateConVar( "mc_server_collision_aabb_padding", tostring( MC.Config.ServerCollisionAABBPadding ), F, "Source-unit padding around player/entity AABBs that keep MC chunk collision active" )
	MC.Config.CollisionAimDistance = GetConVar( "mc_collision_aim_distance" ) or CreateConVar( "mc_collision_aim_distance", tostring( MC.Config.CollisionAimDistance ), F, "Trace distance in Source units for aimed-block collision interest; independent of build reach" )
	MC.Config.ServerCollisionAimRadius = GetConVar( "mc_server_collision_aim_radius" ) or CreateConVar( "mc_server_collision_aim_radius", tostring( MC.Config.ServerCollisionAimRadius ), F, "Block radius around each player's aimed MC block that keeps chunk collision active" )
	MC.Config.ClientCollisionAimRadius = GetConVar( "mc_client_collision_aim_radius" ) or CreateConVar( "mc_client_collision_aim_radius", tostring( MC.Config.ClientCollisionAimRadius ), F, "Block radius around each player's aimed MC block used by client prediction collision" )
	MC.Config.ServerCollisionHotSpan = GetConVar( "mc_server_collision_hot_span" ) or CreateConVar( "mc_server_collision_hot_span", tostring( MC.Config.ServerCollisionHotSpan ), F, "Velocity lookahead chunk span for server collision interest" )
	MC.Config.ServerCollisionLookaheadTime = GetConVar( "mc_server_collision_lookahead_time" ) or CreateConVar( "mc_server_collision_lookahead_time", tostring( MC.Config.ServerCollisionLookaheadTime ), F, "Seconds of entity velocity lookahead for server collision interest" )
	MC.Config.ServerCollisionLookaheadMax = GetConVar( "mc_server_collision_lookahead_max" ) or CreateConVar( "mc_server_collision_lookahead_max", tostring( MC.Config.ServerCollisionLookaheadMax ), F, "Maximum chunk radius reached by velocity lookahead collision interest" )
	MC.Config.BulkCollisionChunksPerInterval = GetConVar( "mc_bulk_collision_chunks_per_interval" ) or CreateConVar( "mc_bulk_collision_chunks_per_interval", tostring( MC.Config.BulkCollisionChunksPerInterval ), F, "Server collision chunks rebuilt per interval for explosion/preset edits" )
	MC.Config.BulkCollisionInterval = GetConVar( "mc_bulk_collision_interval" ) or CreateConVar( "mc_bulk_collision_interval", tostring( MC.Config.BulkCollisionInterval ), F, "Seconds between server collision rebuild batches for explosion/preset edits" )
	MC.Config.BlockUpdatesEnabled = GetConVar( "mc_block_updates_enabled" ) or CreateConVar( "mc_block_updates_enabled", "1", F, "Enable queued neighbor updates and scheduled block ticks" )
	-- Hot-reloading from the pre-redstone build keeps the already-created ConVar's
	-- old internal default of 0. Migrate only that legacy instance; a ConVar
	-- created by the new build has default 1 and remains under administrator control.
	if MC.Config.BlockUpdatesEnabled.GetDefault
	and MC.Config.BlockUpdatesEnabled:GetDefault() == "0"
	and not MC.Config.BlockUpdatesEnabled:GetBool() then
		MC.Config.BlockUpdatesEnabled:SetBool( true )
	end
	MC.Config.BlockDamage = GetConVar( "mc_block_damage" ) or CreateConVar( "mc_block_damage", "1", F, "Allow GMod damage to break MC blocks" )
	MC.Config.BlockHealthScale = GetConVar( "mc_block_health_scale" ) or CreateConVar( "mc_block_health_scale", "20", F, "Block health multiplier applied to Minecraft hardness" )
	MC.Config.BlockDamageDecay = GetConVar( "mc_block_damage_decay" ) or CreateConVar( "mc_block_damage_decay", "5", F, "Seconds before partial block damage is forgotten" )
	MC.Config.BlockExplosionScale = GetConVar( "mc_block_explosion_scale" ) or CreateConVar( "mc_block_explosion_scale", "0.04", F, "GMod blast damage to Minecraft explosion radius scale" )
	MC.Config.BlockExplosionMaxRadius = GetConVar( "mc_block_explosion_max_radius" ) or CreateConVar( "mc_block_explosion_max_radius", "8", F, "Maximum Minecraft-style block explosion radius" )
	MC.Config.BlockExplosionMaxBlocks = GetConVar( "mc_block_explosion_max_blocks" ) or CreateConVar( "mc_block_explosion_max_blocks", "4096", F, "Maximum MC blocks one GMod explosion may destroy; 0 = unlimited" )
	MC.Config.BlockExplosionFxLimit = GetConVar( "mc_block_explosion_fx_limit" ) or CreateConVar( "mc_block_explosion_fx_limit", "16", F, "Max block break particle/sound effects broadcast per explosion; 0 = none" )
	MC.Config.PresetMaxBlocks = GetConVar( "mc_preset_max_blocks" ) or CreateConVar( "mc_preset_max_blocks", "100000", F, "Max non-air blocks one MC preset may save/place; 0 = unlimited" )
	MC.Config.UseInteract = GetConVar( "mc_use_interact" ) or CreateConVar( "mc_use_interact", "1", F, "Right-click on an aimed usable MC block interacts with it regardless of the held weapon; the E key never interacts with blocks" )
	MC.Config.InventoryPersist = GetConVar( "mc_inventory_persist" ) or CreateConVar( "mc_inventory_persist", "1", F, "Persist Minecraft-style player inventories by SteamID64" )
	MC.Config.InventoryActionRate = GetConVar( "mc_inventory_action_rate" ) or CreateConVar( "mc_inventory_action_rate", "80", F, "Maximum authoritative inventory actions accepted per player each second", 10, 200 )
	MC.Config.InventoryCreative = GetConVar( "mc_inventory_creative" ) or CreateConVar( "mc_inventory_creative", "1", F, "Allow Minecraft creative clone/catalog actions in the item inventory" )
	MC.Config.KeepInventory = GetConVar( "mc_keep_inventory" ) or CreateConVar( "mc_keep_inventory", "0", F, "Keep Minecraft inventory and equipment after death" )

	local reach = MC.Config.Reach:GetFloat()
	if math.abs( reach - 8192 ) < 0.01 or math.abs( reach - 182.5 ) < 0.01 then
		MC.Config.Reach:SetFloat( MC.Config.DefaultReach )
	end
end
