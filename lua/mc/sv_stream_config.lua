--[[----------------------------------------------------------------------------
	Server-side streaming/config helpers.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.SV = MC.SV or {}

local SV = MC.SV
local C = MC.Config

local Config = SV.StreamConfig or {}
SV.StreamConfig = Config

function Config.SyncFastEnabled()
	return not C.SyncFast or C.SyncFast:GetBool()
end

function Config.SyncCellsPerPart()
	if C.SyncCells then
		return math.Clamp( C.SyncCells:GetInt(), 1, MC.CS * MC.CS * MC.CH )
	end
	return C.SyncCellsPerPart or 2048
end

function Config.SyncMessagesPerTick()
	if C.SyncMsgs then
		return math.Clamp( C.SyncMsgs:GetInt(), 1, Config.SyncFastEnabled() and 128 or 16 )
	end
	return C.SyncMessagesPerTick or 4
end

function Config.SyncReliableBudget()
	if C.SyncBudget then
		return math.Clamp( C.SyncBudget:GetInt(), 8192, Config.SyncFastEnabled() and 65536 or 52000 )
	end
	return C.SyncReliableBudget or 32768
end

function Config.SyncFrameSeconds()
	if not Config.SyncFastEnabled() then return nil end
	if C.SyncFrame then
		return math.Clamp( C.SyncFrame:GetFloat(), 0.25, 20 ) / 1000
	end
	return ( C.SyncFrameMS or 4 ) / 1000
end

function Config.SyncInFlightLimit()
	if not Config.SyncFastEnabled() then return math.huge end
	if C.SyncWindow then
		return math.Clamp( C.SyncWindow:GetInt(), 32768, 131072 )
	end
	return C.SyncInFlightLimit or 65536
end

function Config.SyncSnapshotEnabled()
	if C.SyncSnapshot then return C.SyncSnapshot:GetBool() end
	return ( C.SyncSnapshot or 1 ) ~= 0
end

function Config.SyncSnapshotPartBytes()
	if C.SyncSnapshotPartBytes then
		return math.Clamp( C.SyncSnapshotPartBytes:GetInt(), 4096, 60000 )
	end
	return C.SyncSnapshotPartBytes or 32768
end

function Config.SyncSnapshotMaxChunks()
	if C.SyncSnapshotMaxChunks then
		return math.max( 0, C.SyncSnapshotMaxChunks:GetInt() )
	end
	return MC.Config.SyncSnapshotMaxChunks or 2048
end

function Config.LazyLoadEnabled()
	if C.LargeWorldLazyLoad then return C.LargeWorldLazyLoad:GetBool() end
	return ( MC.Config.LargeWorldLazyLoad or 1 ) ~= 0
end

function Config.LargeWorldLazyBlockThreshold()
	if C.LargeWorldLazyBlockThreshold and C.LargeWorldLazyBlockThreshold.GetInt then
		return math.max( 0, C.LargeWorldLazyBlockThreshold:GetInt() )
	end
	return math.max( 0, math.floor( tonumber( MC.Config.LargeWorldLazyBlockThreshold ) or 50000000 ) )
end

function Config.HttpChunkDeliveryEnabled()
	if C.ChunkHTTPEnabled then return C.ChunkHTTPEnabled:GetBool() end
	return ( MC.Config.ChunkHTTPEnabled or 0 ) ~= 0
end

function Config.HttpChunkDeliveryPreferred()
	if C.ChunkHTTPPrefer and C.ChunkHTTPPrefer.GetBool then return C.ChunkHTTPPrefer:GetBool() end
	return ( tonumber( MC.Config.ChunkHTTPPrefer ) or 1 ) ~= 0
end

function Config.HttpChunkBaseURL()
	local url
	if C.ChunkHTTPBaseURL and C.ChunkHTTPBaseURL.GetString then
		url = C.ChunkHTTPBaseURL:GetString()
	else
		url = MC.Config.ChunkHTTPBaseURL
	end
	url = string.Trim( tostring( url or "" ) )
	return string.gsub( url, "/+$", "" )
end

function Config.FastNetChunkDeliveryEnabled()
	if C.FastNetChunkEnabled then return C.FastNetChunkEnabled:GetBool() end
	return ( MC.Config.FastNetChunkEnabled or 1 ) ~= 0
end

function Config.FastNetChunkPayloadBytes()
	if C.FastNetChunkPayloadBytes then
		return math.Clamp( C.FastNetChunkPayloadBytes:GetInt(), 4096, 60000 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetChunkPayloadBytes ) or 56000 ), 4096, 60000 )
end

function Config.FastNetChunkMaxBatch()
	if C.FastNetChunkMaxBatch then
		return math.Clamp( C.FastNetChunkMaxBatch:GetInt(), 1, 64 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetChunkMaxBatch ) or 8 ), 1, 64 )
end

function Config.FastNetMessagesPerTick()
	if C.FastNetMessagesPerTick then
		return math.Clamp( C.FastNetMessagesPerTick:GetInt(), 1, 128 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetMessagesPerTick ) or 16 ), 1, 128 )
end

function Config.FastNetReliableBudget()
	if C.FastNetReliableBudget then
		return math.Clamp( C.FastNetReliableBudget:GetInt(), 32768, 1048576 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetReliableBudget ) or 524288 ), 32768, 1048576 )
end

function Config.FastNetInFlightLimit()
	if C.FastNetInFlightLimit then
		return math.Clamp( C.FastNetInFlightLimit:GetInt(), 65536, 4194304 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetInFlightLimit ) or 2097152 ), 65536, 4194304 )
end

function Config.FastNetFrameSeconds()
	if C.FastNetFrame then
		return math.Clamp( C.FastNetFrame:GetFloat(), 0.25, 30 ) / 1000
	end
	return math.Clamp( tonumber( MC.Config.FastNetFrameMS ) or 12, 0.25, 30 ) / 1000
end

function Config.FastNetReprioritizeInterval()
	if C.FastNetReprioritize then
		return math.Clamp( C.FastNetReprioritize:GetFloat(), 0, 2 )
	end
	return math.Clamp( tonumber( MC.Config.FastNetReprioritizeInterval ) or 0.1, 0, 2 )
end

function Config.FastNetProbeClientCacheEnabled()
	if C.FastNetProbeClientCache and C.FastNetProbeClientCache.GetBool then
		return C.FastNetProbeClientCache:GetBool()
	end
	return ( tonumber( MC.Config.FastNetProbeClientCache ) or 1 ) ~= 0
end

function Config.FastNetPrewarmPerTick()
	if C.FastNetPrewarmPerTick and C.FastNetPrewarmPerTick.GetInt then
		return math.Clamp( C.FastNetPrewarmPerTick:GetInt(), 0, 4096 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetPrewarmPerTick ) or 96 ), 0, 4096 )
end

function Config.FastNetPrewarmFrameSeconds()
	if C.FastNetPrewarmFrame and C.FastNetPrewarmFrame.GetFloat then
		return math.Clamp( C.FastNetPrewarmFrame:GetFloat(), 0, 30 ) / 1000
	end
	return math.Clamp( tonumber( MC.Config.FastNetPrewarmFrameMS ) or 4, 0, 30 ) / 1000
end

function Config.FastNetPrewarmPartsPerTick()
	if C.FastNetPrewarmPartsPerTick and C.FastNetPrewarmPartsPerTick.GetInt then
		return math.Clamp( C.FastNetPrewarmPartsPerTick:GetInt(), 0, 256 )
	end
	return math.Clamp( math.floor( tonumber( MC.Config.FastNetPrewarmPartsPerTick ) or 8 ), 0, 256 )
end

function Config.FastNetAdaptiveWindowEnabled()
	if C.FastNetAdaptiveWindow and C.FastNetAdaptiveWindow.GetBool then return C.FastNetAdaptiveWindow:GetBool() end
	return ( tonumber( MC.Config.FastNetAdaptiveWindow ) or 1 ) ~= 0
end

function Config.FastNetWindowMaxScale()
	if C.FastNetWindowMaxScale and C.FastNetWindowMaxScale.GetFloat then
		return math.Clamp( C.FastNetWindowMaxScale:GetFloat(), 1, 4 )
	end
	return math.Clamp( tonumber( MC.Config.FastNetWindowMaxScale ) or 2, 1, 4 )
end

local function readChunkSpan( cv, fallback, maxValue )
	if cv and cv.GetInt then
		return math.Clamp( cv:GetInt(), 0, maxValue )
	end
	return math.Clamp( math.floor( tonumber( fallback ) or 0 ), 0, maxValue )
end

function Config.StreamChunkSpanXY()
	return readChunkSpan( C.StreamChunkSpanXY, MC.Config.StreamChunkSpanXY or 16, 64 )
end

function Config.StreamChunkSpanZ()
	return readChunkSpan( C.StreamChunkSpanZ, MC.Config.StreamChunkSpanZ or 4, 64 )
end

function Config.ServerCollisionSpan()
	return readChunkSpan( C.ServerCollisionChunkSpan, MC.Config.ServerCollisionChunkSpan or 4, 32 )
end

function Config.CollisionHotSpan()
	if C.ServerCollisionHotSpan then
		return readChunkSpan( C.ServerCollisionHotSpan, MC.Config.ServerCollisionHotSpan or 2, 16 )
	end
	return Config.ServerCollisionSpan()
end

function Config.CollisionLookaheadTime()
	if C.ServerCollisionLookaheadTime then
		return math.Clamp( C.ServerCollisionLookaheadTime:GetFloat(), 0, 2 )
	end
	return MC.Config.ServerCollisionLookaheadTime or 0.5
end

function Config.CollisionLookaheadMax()
	return readChunkSpan( C.ServerCollisionLookaheadMax, MC.Config.ServerCollisionLookaheadMax or 4, 16 )
end

function Config.CollisionBuildsPerTick()
	if C.ServerCollisionBuildsPerTick then
		return math.Clamp( C.ServerCollisionBuildsPerTick:GetInt(), 1, 64 )
	end
	return MC.Config.ServerCollisionBuildsPerTick or 2
end

function Config.CollisionEmergencyBuildsPerTick()
	if C.ServerCollisionEmergencyBuildsPerTick then
		return math.Clamp( C.ServerCollisionEmergencyBuildsPerTick:GetInt(), 1, 128 )
	end
	return MC.Config.ServerCollisionEmergencyBuildsPerTick or 8
end
