-- Phase 5 Minecraft import orchestration: read, preflight, limit, stage, commit.

MC = MC or {}
MC.Import = MC.Import or {}
MC.SV = MC.SV or {}

local Import, SV = MC.Import, MC.SV
local Config = MC.Config or {}
local Host = SV.WorldImportHost

local function convarInt( value, fallback )
	if value and value.GetInt then return value:GetInt() end
	return math.floor( tonumber( value ) or fallback or 0 )
end

local function finalBlockCount( plan, mode )
	if mode ~= "append" then return plan.cellCount end
	local total = SV.BlockCount or 0
	for _, chunk in ipairs( plan.chunks ) do
		for _, cell in ipairs( chunk.cells ) do
			local lx, ly, lz = MC.DecodeLocal( cell.localIndex )
			local bx = chunk.cx * MC.CS + lx
			local by = chunk.cy * MC.CS + ly
			local bz = chunk.cz * MC.CH + lz
			if MC.GetBlockState( bx, by, bz ) == 0 then total = total + 1 end
		end
	end
	return total
end

function SV.ImportWorldBundle( manifest, path, options )
	options = istable( options ) and options or {}
	local source, openError = Import.OpenBundle( manifest, path )
	if not source then return nil, openError end
	local plan, preflightError, errorIndex = Import.Preflight( source, {
		unknownPolicy = options.unknownPolicy or Import.UNKNOWN_POLICY_REJECT,
		worldBoundsOK = Host.worldBoundsOK,
	} )
	if not plan then return nil, preflightError, errorIndex end

	local importMax = math.max( 0, convarInt( Config.ImportMax, 0 ) )
	if importMax > 0 and plan.cellCount > importMax then return nil, "import_limit_exceeded" end
	local mode = options.mode == "append" and "append" or "replace"
	local projectedCount = finalBlockCount( plan, mode )
	local maxBlocks = math.max( 0, convarInt( Config.MaxBlocks, 0 ) )
	if maxBlocks > 0 and projectedCount > maxBlocks then return nil, "max_blocks_exceeded" end

	local sink = Import.CreateWorldSink( { mode = mode } )
	local called, wrote, writeError = pcall( sink.WritePlan, sink, plan )
	if not called or wrote ~= true then
		sink:Rollback()
		return nil, called and ( writeError or "import_write_failed" ) or tostring( wrote )
	end
	local committed, commitError = sink:Commit()
	if committed ~= true then sink:Rollback() return nil, commitError or "import_commit_failed" end

	return {
		imported = plan.cellCount,
		total = SV.BlockCount,
		expected = istable( manifest.stats ) and tonumber( manifest.stats.blocks ) or plan.cellCount,
		skippedUnknown = 0,
		skippedBounds = 0,
		skippedLimit = 0,
		lossSummary = Import.LossSummary( manifest ),
		dataVersion = manifest.source and manifest.source.dataVersion,
	}
end

function SV.ImportWorldPath( path, options )
	local source, openError = Import.ReadBundle( path )
	if not source then return nil, openError end
	return SV.ImportWorldBundle( source.manifest, source.path, options )
end
