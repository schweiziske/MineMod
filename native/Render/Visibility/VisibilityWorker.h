#pragma once

#include "Render/Visibility/VisibilityQuery.h"
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>

namespace mcmesh::l2draw
{
struct VisibilityWorkerStats
{
	uint64_t mRequests = 0, mCacheHits = 0, mCoalesced = 0, mScheduled = 0, mCompleted = 0;
	uint64_t mSynchronous = 0, mPortalTraversals = 0, mPortalCacheHits = 0;
	double	 mComputeMS = 0;
	unsigned mRunning = 0;
};

/// Owns a CPU worker and lane caches. Request/Resolve/Forget run on the render
/// thread; the evaluator runs without mMutex and must use only immutable inputs.
/// Stop joins the worker before clearing results; the caller excludes submissions.
class VisibilityWorker
{
public:
	using Evaluator = VisibilityFrame (*)(std::shared_ptr<const VisibilityScene>, std::shared_ptr<const VisibilityGraph>, const VisibilityView &, std::shared_ptr<const PortalMask>);
	explicit VisibilityWorker(Evaluator inEvaluator = Compute) : mEvaluator(inEvaluator) {}
	~VisibilityWorker() { Stop(); }
	VisibilityWorker(const VisibilityWorker &) = delete;
	VisibilityWorker &operator=(const VisibilityWorker &) = delete;

	std::shared_ptr<const VisibilityFrame> Request(uint64_t inLane, std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView);
	/// Fill a cold cache synchronously, then refresh before its envelope expires.
	std::shared_ptr<const VisibilityFrame> Resolve(uint64_t inLane, std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView, bool &outCached);
	void								   Forget(uint64_t inLane);
	void								   Stop();
	VisibilityWorkerStats				   GetStats() const;

private:
	struct Slot
	{
		std::shared_ptr<const VisibilityFrame> mPending, mRunning, mReady, mLatest;
		bool								   mQueued = false;
	};
	void								   Run();
	std::shared_ptr<Slot>				   GetSlotLocked(uint64_t inLane);
	std::shared_ptr<const VisibilityFrame> MakeRequestLocked(std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView);
	void								   ScheduleLocked(const std::shared_ptr<Slot> &inSlot, std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView);
	void								   PublishLocked(Slot &ioSlot, const std::shared_ptr<const VisibilityFrame> &inRequest, std::shared_ptr<const VisibilityFrame> inResult);

	// Protects slots (including their contents), queue, stop flag, stats and portal
	// cache. mThread is created by the render thread and joined by Stop.
	mutable std::mutex									mMutex;
	std::condition_variable								mWake;
	std::unordered_map<uint64_t, std::shared_ptr<Slot>> mSlots;
	std::deque<std::shared_ptr<Slot>>					mQueue;
	std::thread											mThread;
	bool												mStopping = false;
	Evaluator											mEvaluator;
	VisibilityWorkerStats								mStats;
	std::shared_ptr<const PortalMask>					mPortals;
};
} // namespace mcmesh::l2draw
