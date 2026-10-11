#pragma once

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>

namespace mcmesh::core
{
enum class ECpuWorkClass : unsigned
{
	Visibility,
	Decode,
	Lighting,
	Mesh,
	Count
};
inline constexpr size_t cCpuWorkClassCount = size_t(ECpuWorkClass::Count);

struct CpuWorkStats
{
	unsigned mLimit = 0, mActive = 0, mPeakActive = 0, mQueued = 0;
	uint64_t mAdmitted = 0, mCancelled = 0;
	// Cumulative background admission wall time; not main-thread or GPU time.
	double mWaitMS = 0;
	std::array<unsigned, cCpuWorkClassCount> mActiveByClass{}, mQueuedByClass{};
};

class CpuWorkGate;

/// Releases a background execution slot on every exit, including exceptions.
/// The gate owner must outlive the permit; worker owners retain the shared gate
/// until their threads have joined. An empty permit means cancellation.
class CpuWorkPermit
{
public:
	CpuWorkPermit() = default;
	~CpuWorkPermit();
	CpuWorkPermit(const CpuWorkPermit &) = delete;
	CpuWorkPermit &operator=(const CpuWorkPermit &) = delete;
	CpuWorkPermit(CpuWorkPermit &&inOther) noexcept;
	CpuWorkPermit &operator=(CpuWorkPermit &&inOther) noexcept;
	explicit operator bool() const { return mGate != nullptr; }
	void Reset() noexcept;

private:
	friend class CpuWorkGate;
	CpuWorkPermit(CpuWorkGate &inGate, ECpuWorkClass inClass) : mGate(&inGate), mClass(inClass) {}
	CpuWorkGate *mGate = nullptr;
	ECpuWorkClass mClass = ECpuWorkClass::Mesh;
};

/// One shared limit for Native decode, lighting, visibility and mesh CPU work.
/// Acquire is worker-only: it may wait, and must be called without owner locks.
/// Existing workers retain their queues and stop/join ownership. This gate owns
/// no threads and never accesses Lua, engine objects or a caller's mutable data.
class CpuWorkGate
{
public:
	explicit CpuWorkGate(unsigned inLimit = 0);
	CpuWorkGate(const CpuWorkGate &) = delete;
	CpuWorkGate &operator=(const CpuWorkGate &) = delete;
	unsigned GetLimit() const { return mLimit; }
	CpuWorkPermit Acquire(ECpuWorkClass inClass, const std::atomic<bool> &inCancelled);
	/// Call after setting any cancellation flag used by a waiting Acquire.
	void NotifyCancellation() noexcept;
	CpuWorkStats GetStats() const;

private:
	friend class CpuWorkPermit;
	struct Waiter
	{
		Waiter *mNext = nullptr;
	};
	struct Queue
	{
		Waiter *mFirst = nullptr, *mLast = nullptr;
	};
	size_t SelectTurnLocked() const;
	void RemoveWaiterLocked(size_t inClass, Waiter &inWaiter);
	void Release(ECpuWorkClass inClass) noexcept;
	const unsigned mLimit;
	// Protects all queues, the fairness cursor and statistics. Never call back
	// into an owner while holding this mutex; computation runs after unlocking.
	mutable std::mutex mMutex;
	std::condition_variable mWake;
	std::array<Queue, cCpuWorkClassCount> mQueues{};
	size_t mTurn = 0;
	CpuWorkStats mStats;
};

/// Module-wide gate; each worker owner retains it through stop/join.
std::shared_ptr<CpuWorkGate> GetCpuWorkGate();
} // namespace mcmesh::core
