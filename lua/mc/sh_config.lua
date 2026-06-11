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
-- Minecraft-style chunk section: 16x16 horizontally, 32 blocks vertically.
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
	COLS = 16,
	ROWS = 31,
	TILE = 64,
	INSET = 0.5,
	MATERIAL = "mc/atlas_365.png",
}
MC.Atlas.W = MC.Atlas.COLS * MC.Atlas.TILE
MC.Atlas.H = MC.Atlas.ROWS * MC.Atlas.TILE

------------------------------------------------------------------ net strings
if SERVER then
	for _, name in ipairs( {
		"mc_full",
		"mc_full_begin",
		"mc_full_part",
		"mc_full_end",
		"mc_full_ack",
		"mc_set",
		"mc_set_bulk",
		"mc_fx",
		"mc_clear",
	} ) do
		util.AddNetworkString( name )
	end
end

-- Bit widths used by the net protocol (shared so both ends agree).
MC.Net = {
	COORD_BITS = 20, -- signed block coord (+-524288 blocks; far beyond any map)
	LOCAL_BITS = 13, -- local index 0..8191 (16*16*32-1)
	ID_BITS    = 16, -- block id 0..65535
	ORIENT_BITS = 3, -- Minecraft Direction ordinal / axis ordinal
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

MC.Config.SyncCellsPerPart = 8192
MC.Config.SyncMessagesPerTick = 12
MC.Config.SyncReliableBudget = 196608
MC.Config.SyncFrameMS = 4
MC.Config.SyncInFlightLimit = 524288

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
	MC.Config.SyncCells   = GetConVar( "mc_sync_cells_per_part" ) or CreateConVar( "mc_sync_cells_per_part", tostring( MC.Config.SyncCellsPerPart ), F, "Blocks per streamed sync net message" )
	MC.Config.SyncMsgs    = GetConVar( "mc_sync_messages_per_tick" ) or CreateConVar( "mc_sync_messages_per_tick", tostring( MC.Config.SyncMessagesPerTick ), F, "Streamed sync net messages per 0.05s tick" )
	MC.Config.SyncBudget  = GetConVar( "mc_sync_reliable_budget" ) or CreateConVar( "mc_sync_reliable_budget", tostring( MC.Config.SyncReliableBudget ), F, "Approx max reliable sync bytes per 0.05s tick" )
	MC.Config.SyncFast    = GetConVar( "mc_sync_fast" ) or CreateConVar( "mc_sync_fast", "1", F, "Use ack-windowed fast full-map sync" )
	MC.Config.SyncFrame   = GetConVar( "mc_sync_frame_ms" ) or CreateConVar( "mc_sync_frame_ms", tostring( MC.Config.SyncFrameMS ), F, "Approx server CPU milliseconds spent streaming full sync each tick" )
	MC.Config.SyncWindow  = GetConVar( "mc_sync_inflight_limit" ) or CreateConVar( "mc_sync_inflight_limit", tostring( MC.Config.SyncInFlightLimit ), F, "Max unacknowledged full-sync bytes per syncing client" )
	MC.Config.BlockDamage = GetConVar( "mc_block_damage" ) or CreateConVar( "mc_block_damage", "1", F, "Allow GMod damage to break MC blocks" )
	MC.Config.BlockHealthScale = GetConVar( "mc_block_health_scale" ) or CreateConVar( "mc_block_health_scale", "20", F, "Block health multiplier applied to Minecraft hardness" )
	MC.Config.BlockDamageDecay = GetConVar( "mc_block_damage_decay" ) or CreateConVar( "mc_block_damage_decay", "5", F, "Seconds before partial block damage is forgotten" )
	MC.Config.BlockExplosionScale = GetConVar( "mc_block_explosion_scale" ) or CreateConVar( "mc_block_explosion_scale", "0.04", F, "GMod blast damage to Minecraft explosion radius scale" )
	MC.Config.BlockExplosionMaxRadius = GetConVar( "mc_block_explosion_max_radius" ) or CreateConVar( "mc_block_explosion_max_radius", "8", F, "Maximum Minecraft-style block explosion radius" )
	MC.Config.BlockExplosionMaxBlocks = GetConVar( "mc_block_explosion_max_blocks" ) or CreateConVar( "mc_block_explosion_max_blocks", "4096", F, "Maximum MC blocks one GMod explosion may destroy; 0 = unlimited" )

	local reach = MC.Config.Reach:GetFloat()
	if math.abs( reach - 8192 ) < 0.01 or math.abs( reach - 182.5 ) < 0.01 then
		MC.Config.Reach:SetFloat( MC.Config.DefaultReach )
	end
end
