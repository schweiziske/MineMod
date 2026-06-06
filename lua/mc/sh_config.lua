--[[----------------------------------------------------------------------------
	MC : shared configuration, ConVars, net strings, atlas geometry.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.Config = MC.Config or {}

------------------------------------------------------------------ world geometry
-- Units per block edge. 36.5u makes a GMod player roughly two MC blocks tall.
-- NOTE: changing this invalidates existing saves (positions are in blocks * size).
MC.Config.BlockSize = 36.5
MC.Config.DefaultReach = MC.Config.BlockSize * 5
-- Blocks per chunk edge. 16 == one Minecraft chunk slice. 16^3 = 4096 blocks/entity.
MC.Config.ChunkSize = 16

-- convenience locals mirrored onto MC for hot paths
MC.BS = MC.Config.BlockSize
MC.CS = MC.Config.ChunkSize
MC.ChunkWorld = MC.CS * MC.BS -- world units per chunk edge

------------------------------------------------------------------ atlas geometry
-- Must match _build/build_atlas.ps1 (TILE/COLS) and the produced atlas height.
MC.Atlas = {
	COLS = 16,
	ROWS = 4,
	TILE = 64,
	MATERIAL = "mc/atlas_365.png",
}
MC.Atlas.W = MC.Atlas.COLS * MC.Atlas.TILE
MC.Atlas.H = MC.Atlas.ROWS * MC.Atlas.TILE

------------------------------------------------------------------ net strings
if SERVER then
	if not MC.Config.NetStringsAdded then
		util.AddNetworkString( "mc_full" )  -- sv->cl : one chunk's blocks (initial sync / resync)
		util.AddNetworkString( "mc_set" )   -- sv->cl : single block change (id 0 = removed)
		util.AddNetworkString( "mc_clear" )  -- sv->cl : wipe everything
		MC.Config.NetStringsAdded = true
	end
end

-- Bit widths used by the net protocol (shared so both ends agree).
MC.Net = {
	COORD_BITS = 20, -- signed block coord (+-524288 blocks; far beyond any map)
	LOCAL_BITS = 12, -- local index 0..4095
	ID_BITS    = 8,  -- block id 0..255
	ORIENT_BITS = 3, -- Minecraft Direction ordinal / axis ordinal
	COUNT_BITS = 13, -- blocks per chunk 0..4096
}

------------------------------------------------------------------ server ConVars
if SERVER then
	local F = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.AdminOnly   = GetConVar( "mc_admin_only" ) or CreateConVar( "mc_admin_only", "0", F, "Only admins may place/break blocks" )
	MC.Config.WorldLimit  = GetConVar( "mc_world_limit" ) or CreateConVar( "mc_world_limit", "1024", F, "Max |block coordinate| from origin on each axis" )
	MC.Config.MaxBlocks   = GetConVar( "mc_max_blocks" ) or CreateConVar( "mc_max_blocks", "300000", F, "Global cap on total placed blocks; 0 = unlimited" )
	MC.Config.Reach       = GetConVar( "mc_reach" ) or CreateConVar( "mc_reach", tostring( MC.Config.DefaultReach ), F, "Max distance (units) a player may place/break from; 0 disables" )
	MC.Config.FillMax     = GetConVar( "mc_fill_max" ) or CreateConVar( "mc_fill_max", "32768", F, "Max blocks one /fill may modify; 0 = unlimited" )
	MC.Config.Autosave    = GetConVar( "mc_autosave" ) or CreateConVar( "mc_autosave", "120", F, "Seconds between autosaves (0 disables)" )

	if math.abs( MC.Config.Reach:GetFloat() - 8192 ) < 0.01 then
		MC.Config.Reach:SetFloat( MC.Config.DefaultReach )
	end
end
