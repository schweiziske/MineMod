#pragma once

#include "World/WorldDecoder.h"
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mcmesh::world
{
enum class ETransportState
{
	Receiving,
	Queued,
	Running,
	Ready,
	Failed
};

struct TransportInput
{
	bool mSnapshot = false;
	uint32_t mGeneration = 0, mRevision = 0;
	unsigned mPartCount = 0, mPartBytes = 0;
	size_t mTotalBytes = 0;
	unsigned mChunkSize = 0, mChunkHeight = 0, mSectionCount = 0;
	DecodeMetadata mPatch;
};

struct TransportStatus
{
	ETransportState mState = ETransportState::Receiving;
	std::string mError;
	unsigned mReceivedParts = 0;
	size_t mReceivedBytes = 0;
	bool mBinary = false;
	uint32_t mChunks = 0, mCells = 0;
	// Metadata only. Payload ownership never crosses back into Lua for MCSB/MCB9.
	std::vector<DecodeMetadata> mBatches;
	double mValidateMS = 0;
};

struct TransportBatch
{
	DecodeMetadata mMetadata;
	std::vector<uint8_t> mPayload;
};

struct TransportStats
{
	size_t mJobs = 0, mRunning = 0, mReservedBytes = 0, mRetainedBytes = 0;
};

/// Owner-thread ingress; one joined CPU worker validates CRC and MCSB framing.
/// Wire buffers are independent of world epochs: resetting the destination
/// world preserves a received snapshot. Resync/ownership changes cancel them;
/// batch submission binds bytes to the then-current world/catalog version.
class WorldTransport
{
public:
	WorldTransport();
	~WorldTransport();
	WorldTransport(const WorldTransport &) = delete;
	WorldTransport &operator=(const WorldTransport &) = delete;
	uint64_t Begin(const TransportInput &inInput);
	TransportStatus Accept(uint64_t inId, unsigned inPart, const uint8_t *inBytes, size_t inLength);
	void Seal(uint64_t inId, const std::string &inCRC);
	TransportStatus Poll(uint64_t inId) const;
	/// Consumes the batch exactly once; submit failure requires cancelling ingress.
	TransportBatch TakeBatch(uint64_t inId, unsigned inBatch);
	/// Explicit compatibility path, allowed only for a validated legacy snapshot.
	std::vector<uint8_t> TakeLegacy(uint64_t inId);
	void Release(uint64_t inId);
	void CancelAll();
	TransportStats GetStats() const;

private:
	struct Impl;
	std::unique_ptr<Impl> mImpl;
};
} // namespace mcmesh::world
