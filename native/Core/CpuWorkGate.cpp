#include "Core/CpuWorkGate.h"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <stdexcept>
#include <thread>
#include <utility>

namespace mcmesh::core
{
namespace
{
// Weighted round robin prioritizes view refresh without starving map work.
constexpr std::array<ECpuWorkClass, 6> cDispatchOrder{
	ECpuWorkClass::Visibility, ECpuWorkClass::Decode, ECpuWorkClass::Visibility,
	ECpuWorkClass::Lighting, ECpuWorkClass::Visibility, ECpuWorkClass::Mesh};
unsigned SelectLimit(unsigned inLimit)
{
	if (inLimit)
		return inLimit;
	const auto hardware = std::thread::hardware_concurrency();
	return std::clamp(hardware > 2 ? hardware - 2 : 1u, 1u, 8u);
}
} // namespace

CpuWorkPermit::~CpuWorkPermit()
{
	Reset();
}
CpuWorkPermit::CpuWorkPermit(CpuWorkPermit &&inOther) noexcept
	: mGate(std::exchange(inOther.mGate, nullptr)), mClass(inOther.mClass)
{
}
CpuWorkPermit &CpuWorkPermit::operator=(CpuWorkPermit &&inOther) noexcept
{
	if (this != &inOther)
	{
		Reset();
		mGate = std::exchange(inOther.mGate, nullptr);
		mClass = inOther.mClass;
	}
	return *this;
}
void CpuWorkPermit::Reset() noexcept
{
	if (auto *gate = std::exchange(mGate, nullptr))
		gate->Release(mClass);
}
CpuWorkGate::CpuWorkGate(unsigned inLimit) : mLimit(SelectLimit(inLimit))
{
	mStats.mLimit = mLimit;
}
std::shared_ptr<CpuWorkGate> GetCpuWorkGate()
{
	static auto gate = std::make_shared<CpuWorkGate>();
	return gate;
}
size_t CpuWorkGate::SelectTurnLocked() const
{
	for (size_t offset = 0; offset < cDispatchOrder.size(); ++offset)
	{
		const auto turn = (mTurn + offset) % cDispatchOrder.size();
		if (mQueues[size_t(cDispatchOrder[turn])].mFirst)
			return turn;
	}
	return cDispatchOrder.size();
}
void CpuWorkGate::RemoveWaiterLocked(size_t inClass, Waiter &inWaiter)
{
	auto &queue = mQueues[inClass];
	Waiter *previous = nullptr;
	auto *current = queue.mFirst;
	while (current != &inWaiter)
	{
		assert(current != nullptr);
		previous = current;
		current = current->mNext;
	}
	if (previous)
		previous->mNext = current->mNext;
	else
		queue.mFirst = current->mNext;
	if (queue.mLast == current)
		queue.mLast = previous;
	--mStats.mQueued;
	--mStats.mQueuedByClass[inClass];
}
CpuWorkPermit CpuWorkGate::Acquire(ECpuWorkClass inClass, const std::atomic<bool> &inCancelled)
{
	const auto work_class = size_t(inClass);
	if (work_class >= cCpuWorkClassCount)
		throw std::invalid_argument("invalid Native CPU work class");
	const auto started = std::chrono::steady_clock::now();
	Waiter waiter;
	std::unique_lock<std::mutex> lock(mMutex);
	if (inCancelled.load(std::memory_order_relaxed))
	{
		++mStats.mCancelled;
		return {};
	}
	auto &queue = mQueues[work_class];
	if (queue.mLast)
		queue.mLast->mNext = &waiter;
	else
		queue.mFirst = &waiter;
	queue.mLast = &waiter;
	++mStats.mQueued;
	++mStats.mQueuedByClass[work_class];
	try
	{
		mWake.wait(lock, [&]
		{
			if (inCancelled.load(std::memory_order_relaxed))
				return true;
			if (mStats.mActive >= mLimit || queue.mFirst != &waiter)
				return false;
			const auto turn = SelectTurnLocked();
			return turn < cDispatchOrder.size() && cDispatchOrder[turn] == inClass;
		});
	}
	catch (...)
	{
		RemoveWaiterLocked(work_class, waiter);
		mWake.notify_all();
		throw;
	}
	mStats.mWaitMS += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
	const bool cancelled = inCancelled.load(std::memory_order_relaxed);
	const auto turn = cancelled ? 0 : SelectTurnLocked();
	RemoveWaiterLocked(work_class, waiter);
	if (cancelled)
		++mStats.mCancelled;
	else
	{
		mTurn = (turn + 1) % cDispatchOrder.size();
		++mStats.mActive;
		++mStats.mActiveByClass[work_class];
		++mStats.mAdmitted;
		mStats.mPeakActive = std::max(mStats.mPeakActive, mStats.mActive);
	}
	mWake.notify_all();
	return cancelled ? CpuWorkPermit{} : CpuWorkPermit(*this, inClass);
}
void CpuWorkGate::Release(ECpuWorkClass inClass) noexcept
{
	std::lock_guard<std::mutex> lock(mMutex);
	assert(mStats.mActive > 0 && mStats.mActiveByClass[size_t(inClass)] > 0);
	--mStats.mActive;
	--mStats.mActiveByClass[size_t(inClass)];
	mWake.notify_all();
}
void CpuWorkGate::NotifyCancellation() noexcept
{
	// Pair notification with the predicate mutex to avoid a lost cancellation
	// between a waiter's predicate evaluation and entering the wait.
	std::lock_guard<std::mutex> lock(mMutex);
	mWake.notify_all();
}
CpuWorkStats CpuWorkGate::GetStats() const
{
	std::lock_guard<std::mutex> lock(mMutex);
	return mStats;
}
} // namespace mcmesh::core
