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
-- Minecraft-style chunk section: 16x16 horizontally, 384 blocks vertically.
-- Z is not globally clamped; sections are addressed by their chunk Z.
MC.Config.ChunkSize = 16
MC.Config.ChunkHeight = 384

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
		"mc_set",
		"mc_clear",
	} ) do
		util.AddNetworkString( name )
	end
end

-- Bit widths used by the net protocol (shared so both ends agree).
MC.Net = {
	COORD_BITS = 20, -- signed block coord (+-524288 blocks; far beyond any map)
	LOCAL_BITS = 17, -- local index 0..98303 (16*16*384-1)
	ID_BITS    = 16, -- block id 0..65535
	ORIENT_BITS = 3, -- Minecraft Direction ordinal / axis ordinal
	COUNT_BITS = 17, -- blocks per chunk section 0..98304
}

MC.Config.SyncCellsPerPart = 1024
MC.Config.SyncMessagesPerTick = 4

------------------------------------------------------------------ server ConVars
if SERVER then
	local F = bit.bor( FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED )
	MC.Config.AdminOnly   = GetConVar( "mc_admin_only" ) or CreateConVar( "mc_admin_only", "0", F, "Only admins may place/break blocks" )
	MC.Config.WorldLimit  = GetConVar( "mc_world_limit" ) or CreateConVar( "mc_world_limit", "1024", F, "Max |block coordinate| from origin on each axis" )
	MC.Config.MaxBlocks   = GetConVar( "mc_max_blocks" ) or CreateConVar( "mc_max_blocks", "300000", F, "Global cap on total placed blocks; 0 = unlimited" )
	MC.Config.Reach       = GetConVar( "mc_reach" ) or CreateConVar( "mc_reach", tostring( MC.Config.DefaultReach ), F, "Max distance (units) a player may place/break from; 0 disables" )
	MC.Config.FillMax     = GetConVar( "mc_fill_max" ) or CreateConVar( "mc_fill_max", "32768", F, "Max blocks one /fill may modify; 0 = unlimited" )
	MC.Config.ImportMax   = GetConVar( "mc_import_max" ) or CreateConVar( "mc_import_max", "0", F, "Max blocks one mc_import may load; 0 = unlimited" )
	MC.Config.Autosave    = GetConVar( "mc_autosave" ) or CreateConVar( "mc_autosave", "120", F, "Seconds between autosaves (0 disables)" )

	if math.abs( MC.Config.Reach:GetFloat() - 8192 ) < 0.01 then
		MC.Config.Reach:SetFloat( MC.Config.DefaultReach )
	end
end
