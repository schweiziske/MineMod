--[[----------------------------------------------------------------------------
	MC block-state network protocol constants and message registry.

	This file is deliberately independent from the transport implementation.  It
	is shared before sh_config.lua so every sender, receiver and byte estimator
	uses one authoritative set of bit widths.
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net or {}
MC.Net = Net

-- Protocol 8 adds server-authoritative horizontal column streaming and ordered
-- revision skip/pending control payloads.
Net.PROTOCOL_VERSION = 8
Net.MIN_PROTOCOL_VERSION = 8

-- Shared coordinate and collection widths.
Net.COORD_BITS = 20          -- signed block/chunk coordinate payloads
Net.LOCAL_BITS = 13          -- legacy 16*16*32 chunk-local index
Net.SECTION_LOCAL_BITS = 12  -- 16*16*16 section-local index
Net.COUNT_BITS = 14          -- legacy count, retained for existing transports
Net.SECTION_COUNT_BITS = 13  -- 0..4096 cells

-- State protocol widths.  Twenty bits leave room for 1,048,576 global states,
-- well above the current 32,366 generated vanilla states plus custom content.
Net.STATE_ID_BITS = 20
Net.REVISION_BITS = 32       -- monotonically increasing world edit revision
Net.GENERATION_BITS = 32     -- chunk incarnation; rejects stale queued packets
Net.CAPABILITY_BITS = 16
Net.MAX_STATE_BULK_CELLS = 768 -- stays comfortably below GMod's net message limit
Net.BLOCK_ENTITY_PAYLOAD_MAX = 32768
Net.STATE_TRANSACTION_PAYLOAD_MAX = 56000
Net.STATE_SNAPSHOT_PART_BYTES = 30000
Net.STATE_STREAM_PART_BYTES = 30000
Net.MAX_STATE_STREAM_CELLS = 4294967295 -- no artificial cap; bounded only by the 32-bit wire count
Net.CHUNK_PATCH_PART_BYTES = 30000
Net.CHUNK_PATCH_MAX_BYTES = 16777216
Net.MAX_STREAM_COLUMNS = 64
Net.MAX_STREAM_VERTICAL_CHUNKS = 1024

Net.TransactionFlag = {
	CORRECTION = 0x01,
	MESH_RATE_LIMITED = 0x02,
	COALESCED_BULK = 0x04,
}

Net.BlockEntityOp = {
	NONE = 0,
	REMOVE = 1,
	UPSERT = 2,
}

-- Legacy projection widths remain available until every old transport caller
-- has migrated.  They are compatibility fields, not authoritative state data.
Net.ID_BITS = 16
Net.ORIENT_BITS = 6

Net.MAX_STATE_ID = 2 ^ Net.STATE_ID_BITS - 1
Net.MAX_REVISION = 2 ^ Net.REVISION_BITS - 1
Net.MAX_GENERATION = 2 ^ Net.GENERATION_BITS - 1

Net.Capability = {
	STATE_ID = 0x0001,
	SECTION_PALETTE = 0x0002,
	STATE_SNAPSHOT = 0x0004,
	BLOCK_ENTITY_ENVELOPE = 0x0008,
	REGISTRY_HASH = 0x0010,
	STATE_STREAM = 0x0020,
	CHUNK_HYDRATION = 0x0040,
	BINARY_CHUNK_PATCH = 0x0080,
	BINARY_STATE_SNAPSHOT = 0x0100,
}

Net.REQUIRED_CAPABILITIES = bit.bor(
	Net.Capability.STATE_ID,
	Net.Capability.SECTION_PALETTE,
	Net.Capability.STATE_SNAPSHOT,
	Net.Capability.BLOCK_ENTITY_ENVELOPE,
	Net.Capability.REGISTRY_HASH,
	Net.Capability.STATE_STREAM,
	Net.Capability.CHUNK_HYDRATION
)

function Net.HasCapability( mask, capability )
	return bit.band( tonumber( mask ) or 0, capability ) ~= 0
end

function Net.ValidateStateId( stateId )
	stateId = tonumber( stateId )
	return stateId ~= nil and stateId >= 0 and stateId <= Net.MAX_STATE_ID and stateId % 1 == 0
end

-- Keep all network-string allocation centralized. The state-aware protocol is
-- the only full-map transport; removed legacy names must not be reintroduced.
Net.MessageNames = {
	"mc_http_manifest", "mc_http_chunk", "mc_http_chunk_bulk", "mc_http_failed",
	"mc_unload_chunk", "mc_set", "mc_set_bulk", "mc_set_bulk_fast",
	"mc_reliable_ack", "mc_fx", "mc_creative_place_anim", "mc_creative_break_anim",
	"mc_clear", "mc_collision_debug_req", "mc_collision_debug",
	"mc_save_list_req", "mc_save_list_data", "mc_save_action",
	"mc_save_cover_begin", "mc_save_cover_part", "mc_save_cover_ack", "mc_save_cover_req",
	"mc_save_cover_download_begin", "mc_save_cover_download_part",
	"mc_workshop_export_request", "mc_workshop_export_begin", "mc_workshop_export_part",
	"mc_workshop_load_request", "mc_workshop_load_approval",
	"mc_workshop_upload_begin", "mc_workshop_upload_part", "mc_workshop_shared_ready", "mc_workshop_upload_result",
	"mc_workshop_base_announce", "mc_workshop_base_ready",
	"mc_workshop_dirty_target", "mc_workshop_base_applied",
	"mc_workshop_bind_id", "mc_workshop_bind_result",
	"mc_preset_list_req", "mc_preset_list_data", "mc_preset_save", "mc_preset_load_req",
	"mc_preset_data", "mc_preset_data_part", "mc_preset_place",
	"mc_preset_cover_begin", "mc_preset_cover_part", "mc_preset_cover_ack",
	"mc_preset_cover_req", "mc_preset_cover_download_begin", "mc_preset_cover_download_part",
	"mc_sign_open", "mc_sign_update", "mc_banner_update",
	"mc_mining_progress",

	"mc_cluster_convert", "mc_cluster_data_req", "mc_cluster_data",
	"mc_cluster_paste", "mc_cluster_break",

	-- Server-authoritative item inventory/container protocol.
	"mc_inventory_sync_begin", "mc_inventory_sync_part", "mc_inventory_sync_end",
	"mc_inventory_delta", "mc_inventory_open_request", "mc_inventory_open",
	"mc_inventory_action", "mc_inventory_creative_pick", "mc_inventory_close", "mc_inventory_resync", "mc_inventory_select",
	"mc_inventory_recipe_place", "mc_equipment_delta",

	-- Phase 4 state-aware transport.
	"mc_state_hello", "mc_state_hello_ack",
	"mc_state_set", "mc_state_set_bulk",
	"mc_state_chunk_stream", "mc_state_bulk_group_end",
	"mc_state_chunk_patch_begin", "mc_state_chunk_patch_part", "mc_state_chunk_patch_end",
	"mc_state_binary_patch_begin", "mc_state_binary_patch_part", "mc_state_binary_patch_end",
	"mc_stream_columns", "mc_stream_patch_pending", "mc_state_revision_skip",
	"mc_state_snapshot_begin", "mc_state_snapshot_part", "mc_state_snapshot_end",
	"mc_state_snapshot_ack",
	"mc_state_resync_request",
}

if SERVER then
	for _, name in ipairs( Net.MessageNames ) do
		util.AddNetworkString( name )
	end
end
