-- Emergency/admin cleanup for standalone flowing or out-of-bounds water.
-- Work is chunked across timer ticks so a runaway water field does not turn
-- cleanup into another long server hitch.

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local CLEANUP_INTERVAL = 0.05
local CHUNKS_PER_STEP = 8
local SCAN_TIME_BUDGET = 0.002
local CELLS_PER_TRANSACTION = 1024
local NET_CELLS_PER_MESSAGE = 256
local CleanupJob
local cvClearFlowing = CreateConVar( "mc_water_clear_flowing", "0", 0,
	"Set to 1 to remove standalone flowing water while preserving source and waterlogged blocks." )

local function notify( ply, message )
	MsgN( "[MC water cleanup] " .. message )
	if IsValid( ply ) then ply:PrintMessage( HUD_PRINTCONSOLE, "[MC water cleanup] " .. message ) end
end

local function standaloneWaterState( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	if not schema or schema.name ~= "minecraft:water" then return false, nil end
	local level = MC.GetStateProperty and MC.GetStateProperty( stateId, "level" ) or nil
	return true, math.floor( tonumber( level ) or 0 )
end

local function shouldRemoveWater( job, bx, by, bz, stateId )
	local standalone, level = standaloneWaterState( stateId )
	if not standalone then return false end
	if job.mode == "flowing" then return level ~= 0 end
	return not SV.WorldBoundsOK( bx, by, bz )
end

local function collectChunkWater( job, chunk )
	local cells = job.pending or {}
	local firstCount = #cells
	MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
		if shouldRemoveWater( job, bx, by, bz, stateId ) then
			cells[#cells + 1] = { bx = bx, by = by, bz = bz }
		end
	end )
	job.scannedChunks = job.scannedChunks + 1
	if #cells > firstCount then
		job.pending = cells
		job.pendingIndex = job.pendingIndex or 1
	end
end

local function removePendingBatch( job )
	local pending = job.pending
	if not pending then return false end
	local first = job.pendingIndex
	local last = math.min( #pending, first + CELLS_PER_TRANSACTION - 1 )
	local batch = {}
	for index = first, last do batch[#batch + 1] = pending[index] end
	local changed, err = SV.RemoveBlocksBulk( batch, {
		actor = nil,
		fx = false,
		handlers = false,
		blockUpdates = false,
		compareCollision = true,
		deferPhys = true,
		netPaced = true,
		cellsPerMessage = NET_CELLS_PER_MESSAGE,
	} )
	if err then
		notify( job.ply, "failed: " .. tostring( err ) )
		CleanupJob = nil
		return true
	end
	job.removed = job.removed + ( changed or 0 )
	job.pendingIndex = last + 1
	if job.pendingIndex > #pending then
		job.pending = nil
		job.pendingIndex = nil
	end
	return true
end

local function finishCleanup( job )
	SV.Dirty = job.removed > 0 or SV.Dirty
	notify( job.ply, "finished; mode=" .. job.mode .. " removed=" .. job.removed .. " scannedChunks=" .. job.scannedChunks )
	CleanupJob = nil
end

local function cleanupStep()
	local job = CleanupJob
	if not job then return end
	if removePendingBatch( job ) then return end

	local scanned = 0
	local deadline = SysTime() + SCAN_TIME_BUDGET
	while scanned < CHUNKS_PER_STEP and job.keyIndex <= #job.keys do
		local key = job.keys[job.keyIndex]
		job.keyIndex = job.keyIndex + 1
		scanned = scanned + 1
		local chunk = MC.GetChunkByKey( key )
		if chunk then collectChunkWater( job, chunk ) end
		-- Once a matching chunk has been found, start deleting it on the next
		-- step instead of accumulating water from many dense chunks at once.
		if job.pending or SysTime() >= deadline then break end
	end
	if job.pending then return end
	if job.keyIndex > #job.keys then finishCleanup( job ) end
end

local function startWaterCleanup( ply, mode )
	if CleanupJob then return false, "cleanup_already_running" end
	mode = mode == "flowing" and "flowing" or "out_of_bounds"
	if SV.ClearBlockUpdates then SV.ClearBlockUpdates() end
	local keys = {}
	for key in pairs( MC.World or {} ) do keys[#keys + 1] = key end
	CleanupJob = {
		ply = IsValid( ply ) and ply or nil,
		mode = mode,
		keys = keys,
		keyIndex = 1,
		removed = 0,
		scannedChunks = 0,
	}
	notify( ply, "started; mode=" .. mode .. " coordinateLimit=" .. tostring( SV.WorldCoordinateLimit and SV.WorldCoordinateLimit() or "?" )
		.. " chunks=" .. #keys )
	return true
end

function SV.StartOutOfBoundsWaterCleanup( ply )
	return startWaterCleanup( ply, "out_of_bounds" )
end

function SV.StartFlowingWaterCleanup( ply )
	return startWaterCleanup( ply, "flowing" )
end

timer.Remove( "mc_water_oob_cleanup" )
timer.Create( "mc_water_oob_cleanup", CLEANUP_INTERVAL, 0, cleanupStep )

concommand.Add( "mc_water_prune_oob", function( ply )
	if IsValid( ply ) and not ply:IsAdmin() then return end
	local ok, err = SV.StartOutOfBoundsWaterCleanup( ply )
	if not ok then notify( ply, tostring( err ) ) end
end )

cvars.RemoveChangeCallback( "mc_water_clear_flowing", "mc_water_clear_flowing_trigger" )
cvars.AddChangeCallback( "mc_water_clear_flowing", function( _, _, newValue )
	if tonumber( newValue ) == 0 then return end
	local ok, err = SV.StartFlowingWaterCleanup()
	if not ok then notify( nil, tostring( err ) ) end
	timer.Simple( 0, function()
		if cvClearFlowing and cvClearFlowing:GetInt() ~= 0 then RunConsoleCommand( "mc_water_clear_flowing", "0" ) end
	end )
end, "mc_water_clear_flowing_trigger" )
