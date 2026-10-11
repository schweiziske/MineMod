#include "World/WorldTransport.h"
#include "Core/CpuWorkGate.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <stdexcept>
#include <thread>
#include <unordered_map>

namespace mcmesh::world
{
namespace
{
constexpr size_t cMaxStreamBytes = 64 * 1024 * 1024;
constexpr size_t cMaxReservedBytes = 256 * 1024 * 1024;
constexpr size_t cMaxJobs = 32, cMaxBatchBytes = 16 * 1024 * 1024;

void Require(bool inCondition, const char *inError)
{
	if (!inCondition)
		throw std::runtime_error(inError);
}

uint32_t ComputeCRC(const std::vector<std::vector<uint8_t>> &inParts, const std::atomic<bool> &inCancelled)
{
	static const auto crc_table = []
	{
		std::array<uint32_t, 256> table{};
		for (unsigned i = 0; i < table.size(); ++i)
		{
			uint32_t value = i;
			for (unsigned bit = 0; bit < 8; ++bit)
				value = (value >> 1) ^ ((value & 1) ? 0xedb88320u : 0);
			table[i] = value;
		}
		return table;
	}();
	uint32_t crc = 0xffffffffu;
	for (const auto &part : inParts)
	{
		Require(!inCancelled, "native_transport_cancelled");
		for (const auto byte : part)
			crc = crc_table[(crc ^ byte) & 255] ^ (crc >> 8);
	}
	return crc ^ 0xffffffffu;
}

/// Reads across fragments directly into final batch storage, releasing consumed
/// fragments. No full-size assembled snapshot plus per-batch copies are needed.
class FragmentReader
{
public:
	FragmentReader(std::vector<std::vector<uint8_t>> &ioParts, size_t inSize,
		const std::atomic<bool> &inCancelled) : mParts(ioParts), mRemaining(inSize), mCancelled(inCancelled) {}
	void Read(uint8_t *outBytes, size_t inCount)
	{
		Require(inCount <= mRemaining, "native_transport_truncated");
		mRemaining -= inCount;
		while (inCount)
		{
			Require(!mCancelled, "native_transport_cancelled");
			auto &part = mParts[mPart];
			const auto count = std::min(inCount, part.size() - mOffset);
			std::memcpy(outBytes, part.data() + mOffset, count);
			outBytes += count;
			inCount -= count;
			mOffset += count;
			if (mOffset == part.size())
			{
				std::vector<uint8_t>().swap(part);
				++mPart;
				mOffset = 0;
			}
		}
	}
	uint8_t U8()
	{
		uint8_t value;
		Read(&value, 1);
		return value;
	}
	uint32_t UInt(unsigned inBytes)
	{
		uint8_t bytes[4]{};
		Read(bytes, inBytes);
		return bytes[0] | (uint32_t(bytes[1]) << 8) | (uint32_t(bytes[2]) << 16) | (uint32_t(bytes[3]) << 24);
	}
	std::vector<uint8_t> Take(size_t inCount)
	{
		Require(inCount <= mRemaining, "native_transport_truncated");
		std::vector<uint8_t> bytes(inCount);
		Read(bytes.data(), inCount);
		return bytes;
	}
	size_t Remaining() const { return mRemaining; }

private:
	std::vector<std::vector<uint8_t>> &mParts;
	size_t mRemaining, mPart = 0, mOffset = 0;
	const std::atomic<bool> &mCancelled;
};

struct TransportJob
{
	uint64_t mId = 0;
	TransportInput mInput;
	TransportStatus mStatus;
	std::vector<std::vector<uint8_t>> mParts;
	std::vector<TransportBatch> mBatches;
	std::vector<uint8_t> mLegacy;
	std::string mCRC;
	std::atomic<bool> mCancelled{false};
	size_t mReservation = 0, mRetainedBytes = 0;
};

TransportStatus Validate(TransportJob &ioJob)
{
	const auto started = std::chrono::steady_clock::now();
	const auto &input = ioJob.mInput;
	TransportStatus status = ioJob.mStatus;
	if (!ioJob.mCRC.empty())
		Require(std::to_string(ComputeCRC(ioJob.mParts, ioJob.mCancelled)) == ioJob.mCRC, "native_transport_crc_mismatch");
	FragmentReader reader(ioJob.mParts, input.mTotalBytes, ioJob.mCancelled);
	if (!input.mSnapshot)
	{
		ioJob.mBatches.push_back({input.mPatch, reader.Take(input.mTotalBytes)});
		status.mBinary = true;
		status.mChunks = input.mPatch.chunks;
		status.mCells = input.mPatch.cells;
	}
	else
	{
		uint8_t magic[4];
		reader.Read(magic, 4);
		if (std::memcmp(magic, "MCSB", 4) != 0)
		{
			// Old servers can send compressed JSON even with the binary capability.
			ioJob.mLegacy.resize(input.mTotalBytes);
			std::memcpy(ioJob.mLegacy.data(), magic, 4);
			reader.Read(ioJob.mLegacy.data() + 4, reader.Remaining());
		}
		else
		{
			Require(reader.U8() == 1, "binary_snapshot_version_mismatch");
			const auto chunk_size = reader.U8(), chunk_height = reader.U8(), section_count = reader.U8();
			Require(chunk_size == input.mChunkSize && chunk_height == input.mChunkHeight
				&& section_count == input.mSectionCount, "binary_snapshot_geometry_mismatch");
			const auto batches = reader.UInt(2);
			status.mChunks = reader.UInt(4);
			status.mCells = reader.UInt(4);
			Require((batches == 0) == (status.mChunks == 0), "invalid_empty_binary_snapshot");
			Require(batches <= reader.Remaining() / 16, "truncated_binary_snapshot_batches");
			ioJob.mBatches.reserve(batches);
			uint64_t chunks = 0, cells = 0;
			for (unsigned i = 0; i < batches; ++i)
			{
				DecodeMetadata metadata;
				metadata.generation = input.mGeneration;
				metadata.revision = input.mRevision;
				metadata.compression = reader.U8();
				metadata.chunks = reader.UInt(2);
				metadata.rawBytes = reader.UInt(4);
				metadata.cells = reader.UInt(4);
				const auto payload_bytes = reader.UInt(4);
				Require(metadata.compression <= 1 && metadata.chunks >= 1 && metadata.chunks <= 64
					&& metadata.rawBytes >= 14 && metadata.rawBytes <= cMaxBatchBytes
					&& metadata.cells <= 131072 && payload_bytes > 0 && payload_bytes <= cMaxBatchBytes,
					"invalid_binary_snapshot_batch_header");
				ioJob.mBatches.push_back({metadata, reader.Take(payload_bytes)});
				chunks += metadata.chunks;
				cells += metadata.cells;
			}
			Require(reader.Remaining() == 0, "binary_snapshot_trailing_data");
			Require(chunks == status.mChunks && cells == status.mCells, "binary_snapshot_count_mismatch");
			status.mBinary = true;
		}
	}
	status.mBatches.reserve(ioJob.mBatches.size());
	for (const auto &batch : ioJob.mBatches)
		status.mBatches.push_back(batch.mMetadata);
	status.mValidateMS = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
	status.mState = ETransportState::Ready;
	return status;
}
} // namespace

struct WorldTransport::Impl
{
	// Protects registry, queue, statuses and accounting. Receiving buffers become
	// worker-exclusive at Seal; ready payloads become owner-exclusive at Take.
	mutable std::mutex mMutex;
	std::condition_variable mWake;
	std::unordered_map<uint64_t, std::shared_ptr<TransportJob>> mJobs;
	std::deque<std::shared_ptr<TransportJob>> mQueue;
	std::thread mThread;
	std::shared_ptr<core::CpuWorkGate> mGate = core::GetCpuWorkGate();
	uint64_t mNext = 1;
	size_t mReserved = 0, mRunning = 0;
	bool mStopping = false;

	std::shared_ptr<TransportJob> FindLocked(uint64_t inId) const
	{
		const auto found = mJobs.find(inId);
		Require(found != mJobs.end(), "unknown_native_transport");
		return found->second;
	}
	void Run()
	{
		for (;;)
		{
			std::shared_ptr<TransportJob> job;
			{
				std::unique_lock<std::mutex> lock(mMutex);
				mWake.wait(lock, [&] { return mStopping || !mQueue.empty(); });
				if (mStopping)
					return;
				job = mQueue.front();
				mQueue.pop_front();
				job->mStatus.mState = ETransportState::Running;
				++mRunning;
			}
			TransportStatus status;
			{
				auto permit = mGate->Acquire(core::ECpuWorkClass::Decode, job->mCancelled);
				try
				{
					Require(bool(permit), "native_transport_cancelled");
					status = Validate(*job);
				}
				catch (const std::exception &error)
				{
					status.mState = ETransportState::Failed;
					status.mError = error.what();
					std::vector<TransportBatch>().swap(job->mBatches);
					std::vector<uint8_t>().swap(job->mLegacy);
				}
				std::vector<std::vector<uint8_t>>().swap(job->mParts);
			}
			{
				std::lock_guard<std::mutex> lock(mMutex);
				--mRunning;
				if (job->mCancelled)
					mReserved -= job->mReservation;
				else
				{
					job->mRetainedBytes = job->mLegacy.size();
					for (const auto &batch : job->mBatches)
						job->mRetainedBytes += batch.mPayload.size();
					job->mStatus = std::move(status);
					const auto reservation = job->mRetainedBytes
						+ job->mBatches.capacity() * sizeof(TransportBatch)
						+ job->mStatus.mBatches.capacity() * sizeof(DecodeMetadata);
					mReserved -= job->mReservation - reservation;
					job->mReservation = reservation;
				}
			}
		}
	}
};

WorldTransport::WorldTransport() : mImpl(std::make_unique<Impl>()) {}
WorldTransport::~WorldTransport()
{
	CancelAll();
	{
		std::lock_guard<std::mutex> lock(mImpl->mMutex);
		mImpl->mStopping = true;
	}
	mImpl->mWake.notify_all();
	if (mImpl->mThread.joinable())
		mImpl->mThread.join();
}

uint64_t WorldTransport::Begin(const TransportInput &inInput)
{
	Require(inInput.mTotalBytes >= 4 && inInput.mTotalBytes <= cMaxStreamBytes
		&& inInput.mPartCount > 0 && inInput.mPartCount <= 65535
		&& inInput.mPartBytes > 0 && inInput.mPartBytes <= 65535
		&& inInput.mPartCount <= inInput.mTotalBytes
		&& inInput.mTotalBytes <= size_t(inInput.mPartCount) * inInput.mPartBytes, "invalid_native_transport_header");
	if (!inInput.mSnapshot)
		Require(inInput.mTotalBytes <= cMaxBatchBytes && inInput.mPatch.compression <= 1
			&& inInput.mPatch.rawBytes >= 14 && inInput.mPatch.rawBytes <= cMaxBatchBytes
			&& inInput.mPatch.chunks >= 1 && inInput.mPatch.chunks <= 64
			&& inInput.mPatch.cells <= 131072, "invalid_native_transport_patch");
	auto job = std::make_shared<TransportJob>();
	job->mInput = inInput;
	job->mReservation = inInput.mTotalBytes * 2
		+ size_t(inInput.mPartCount) * sizeof(std::vector<uint8_t>)
		+ std::min<size_t>(65535, inInput.mTotalBytes / 15) * (sizeof(TransportBatch) + sizeof(DecodeMetadata));
	job->mParts.resize(inInput.mPartCount);
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	Require(mImpl->mJobs.size() < cMaxJobs && job->mReservation <= cMaxReservedBytes - mImpl->mReserved,
		"native_transport_queue_full");
	job->mId = mImpl->mNext++;
	mImpl->mJobs.emplace(job->mId, job);
	mImpl->mReserved += job->mReservation;
	return job->mId;
}

TransportStatus WorldTransport::Accept(uint64_t inId, unsigned inPart, const uint8_t *inBytes, size_t inLength)
{
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	auto job = mImpl->FindLocked(inId);
	Require(job->mStatus.mState == ETransportState::Receiving && inPart < job->mParts.size()
		&& inLength > 0 && inLength <= job->mInput.mPartBytes, "invalid_native_transport_part");
	auto &part = job->mParts[inPart];
	if (part.empty())
	{
		Require(inLength <= job->mInput.mTotalBytes - job->mStatus.mReceivedBytes, "native_transport_too_large");
		part.assign(inBytes, inBytes + inLength);
		++job->mStatus.mReceivedParts;
		job->mStatus.mReceivedBytes += inLength;
		job->mRetainedBytes += inLength;
	}
	else
		Require(part.size() == inLength && std::memcmp(part.data(), inBytes, inLength) == 0,
			"native_transport_duplicate_mismatch");
	return job->mStatus;
}

void WorldTransport::Seal(uint64_t inId, const std::string &inCRC)
{
	Require(inCRC.empty() || (inCRC.size() <= 10
		&& std::all_of(inCRC.begin(), inCRC.end(), [](char inByte) { return inByte >= '0' && inByte <= '9'; })),
		"invalid_native_transport_crc");
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	auto job = mImpl->FindLocked(inId);
	Require(job->mStatus.mState == ETransportState::Receiving
		&& job->mStatus.mReceivedParts == job->mInput.mPartCount
		&& job->mStatus.mReceivedBytes == job->mInput.mTotalBytes, "native_transport_incomplete");
	job->mCRC = inCRC;
	if (!mImpl->mThread.joinable())
		mImpl->mThread = std::thread([this]
		{
			mImpl->Run();
		});
	mImpl->mQueue.push_back(job);
	job->mStatus.mState = ETransportState::Queued;
	mImpl->mWake.notify_one();
}

TransportStatus WorldTransport::Poll(uint64_t inId) const
{
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	return mImpl->FindLocked(inId)->mStatus;
}

TransportBatch WorldTransport::TakeBatch(uint64_t inId, unsigned inBatch)
{
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	auto job = mImpl->FindLocked(inId);
	Require(job->mStatus.mState == ETransportState::Ready && job->mStatus.mBinary
		&& inBatch < job->mBatches.size() && !job->mBatches[inBatch].mPayload.empty(), "native_transport_batch_unavailable");
	job->mRetainedBytes -= job->mBatches[inBatch].mPayload.size();
	job->mReservation -= job->mBatches[inBatch].mPayload.size();
	mImpl->mReserved -= job->mBatches[inBatch].mPayload.size();
	TransportBatch batch{job->mBatches[inBatch].mMetadata, {}};
	batch.mPayload.swap(job->mBatches[inBatch].mPayload);
	return batch;
}

std::vector<uint8_t> WorldTransport::TakeLegacy(uint64_t inId)
{
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	auto job = mImpl->FindLocked(inId);
	Require(job->mStatus.mState == ETransportState::Ready && !job->mStatus.mBinary
		&& !job->mLegacy.empty(), "native_transport_legacy_unavailable");
	job->mRetainedBytes = 0;
	job->mReservation -= job->mLegacy.size();
	mImpl->mReserved -= job->mLegacy.size();
	std::vector<uint8_t> bytes;
	bytes.swap(job->mLegacy);
	return bytes;
}

void WorldTransport::Release(uint64_t inId)
{
	std::shared_ptr<TransportJob> job;
	{
		std::lock_guard<std::mutex> lock(mImpl->mMutex);
		const auto found = mImpl->mJobs.find(inId);
		if (found == mImpl->mJobs.end())
			return;
		job = found->second;
		job->mCancelled = true;
		if (job->mStatus.mState != ETransportState::Running)
		{
			mImpl->mQueue.erase(std::remove(mImpl->mQueue.begin(), mImpl->mQueue.end(), job), mImpl->mQueue.end());
			mImpl->mReserved -= job->mReservation;
		}
		mImpl->mJobs.erase(found);
	}
	mImpl->mGate->NotifyCancellation();
}

void WorldTransport::CancelAll()
{
	std::unordered_map<uint64_t, std::shared_ptr<TransportJob>> discarded;
	{
		std::lock_guard<std::mutex> lock(mImpl->mMutex);
		for (const auto &entry : mImpl->mJobs)
		{
			entry.second->mCancelled = true;
			if (entry.second->mStatus.mState != ETransportState::Running)
				mImpl->mReserved -= entry.second->mReservation;
		}
		discarded.swap(mImpl->mJobs);
		mImpl->mQueue.clear();
	}
	mImpl->mGate->NotifyCancellation();
}

TransportStats WorldTransport::GetStats() const
{
	std::lock_guard<std::mutex> lock(mImpl->mMutex);
	TransportStats stats{mImpl->mJobs.size(), mImpl->mRunning, mImpl->mReserved, 0};
	for (const auto &entry : mImpl->mJobs)
		stats.mRetainedBytes += entry.second->mRetainedBytes;
	return stats;
}
} // namespace mcmesh::world
