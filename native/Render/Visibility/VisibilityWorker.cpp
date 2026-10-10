#include "Render/Visibility/VisibilityWorker.h"
#include "Render/Visibility/VisibilityMath.h"
#include <exception>
#include <utility>
namespace mcmesh::l2draw
{
std::shared_ptr<const VisibilityFrame> VisibilityWorker::Request(uint64_t inLane, std::shared_ptr<const VisibilityScene> inScene,
																 std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView)
{
	std::lock_guard<std::mutex> lock(mMutex);
	++mStats.mRequests;
	auto entry = GetSlotLocked(inLane);
	auto result = entry->mReady;
	if (result && Covers(*result, inScene.get(), inGraph.get(), inView))
	{
		++mStats.mCacheHits;
		return result;
	}
	ScheduleLocked(entry, std::move(inScene), std::move(inGraph), inView);
	return nullptr;
}
std::shared_ptr<VisibilityWorker::Slot> VisibilityWorker::GetSlotLocked(uint64_t inLane)
{
	auto &entry = mSlots[inLane];
	if (!entry)
		entry = std::make_shared<Slot>();
	return entry;
}
std::shared_ptr<const VisibilityFrame> VisibilityWorker::MakeRequestLocked(std::shared_ptr<const VisibilityScene> inScene,
																		   std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView)
{
	auto request = std::make_shared<VisibilityFrame>();
	request->mScene = std::move(inScene);
	request->mGraph = std::move(inGraph);
	request->mView = inView;
	if (inView.mPortals && mPortals && mPortals->Matches(request->mGraph.get(), inView))
		request->mPortals = mPortals;
	return request;
}
void VisibilityWorker::ScheduleLocked(const std::shared_ptr<Slot> &inSlot, std::shared_ptr<const VisibilityScene> inScene,
									  std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView)
{
	if (inSlot->mPending && Covers(*inSlot->mPending, inScene.get(), inGraph.get(), inView))
	{
		++mStats.mCoalesced;
		return;
	}
	if (inSlot->mRunning && Covers(*inSlot->mRunning, inScene.get(), inGraph.get(), inView))
	{
		inSlot->mPending.reset();
		inSlot->mLatest = inSlot->mRunning;
		++mStats.mCoalesced;
		return;
	}
	if (!mThread.joinable())
	{
		mStopping = false;
		mThread = std::thread(&VisibilityWorker::Run, this);
	}
	auto request = MakeRequestLocked(std::move(inScene), std::move(inGraph), inView);
	if (!inSlot->mQueued)
	{
		mQueue.push_back(inSlot);
		inSlot->mQueued = true;
		++mStats.mScheduled;
	}
	inSlot->mLatest = inSlot->mPending = std::move(request);
	mWake.notify_one();
}
std::shared_ptr<const VisibilityFrame> VisibilityWorker::Resolve(uint64_t inLane, std::shared_ptr<const VisibilityScene> inScene,
																 std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView, bool &outCached)
{
	std::shared_ptr<Slot>				   entry;
	std::shared_ptr<const VisibilityFrame> request;
	{
		std::lock_guard<std::mutex> lock(mMutex);
		++mStats.mRequests;
		entry = GetSlotLocked(inLane);
		const auto &ready = entry->mReady;
		outCached = ready && Covers(*ready, inScene.get(), inGraph.get(), inView);
		if (outCached)
		{
			++mStats.mCacheHits;
			const auto &old = ready->mView;
			bool		refresh = detail::Length(detail::Subtract(old.mEye, inView.mEye)) > old.mMoveBudget * 0.5;
			for (unsigned i = 0; i < inView.mPlaneCount && !refresh; ++i)
				refresh = detail::Length(detail::Subtract(old.mPlanes[i], inView.mPlanes[i])) > old.mNormalBudget * 0.5;
			if (refresh)
				ScheduleLocked(entry, std::move(inScene), std::move(inGraph), inView);
			return ready;
		}
		// There is no usable frame after a scene/portal change or teleport.
		// Compute the required envelope once; don't also queue the same work.
		request = MakeRequestLocked(std::move(inScene), std::move(inGraph), inView);
		entry->mPending.reset();
		entry->mLatest = request;
		++mStats.mSynchronous;
	}
	auto result = std::make_shared<VisibilityFrame>(mEvaluator(request->mScene, request->mGraph, request->mView, request->mPortals));
	{
		std::lock_guard<std::mutex> lock(mMutex);
		PublishLocked(*entry, request, result);
	}
	return result;
}
void VisibilityWorker::PublishLocked(Slot &ioSlot, const std::shared_ptr<const VisibilityFrame> &inRequest, std::shared_ptr<const VisibilityFrame> inResult)
{
	mStats.mComputeMS += inResult->mMilliseconds;
	if (inResult->mPortals)
	{
		if (inResult->mPortals == inRequest->mPortals)
			++mStats.mPortalCacheHits;
		else
			++mStats.mPortalTraversals;
	}
	// A late background result must not overwrite a newer synchronous frame.
	if (ioSlot.mLatest != inRequest)
		return;
	if (inResult->mPortals)
		mPortals = inResult->mPortals;
	ioSlot.mReady = std::move(inResult);
}
void VisibilityWorker::Forget(uint64_t inLane)
{
	std::lock_guard<std::mutex> lock(mMutex);
	const auto					found = mSlots.find(inLane);
	if (found != mSlots.end())
	{
		found->second->mPending.reset();
		found->second->mLatest.reset();
		mSlots.erase(found);
	}
}
void VisibilityWorker::Stop()
{
	{
		std::lock_guard<std::mutex> lock(mMutex);
		mStopping = true;
		mQueue.clear();
		mWake.notify_all();
	}
	if (mThread.joinable())
		mThread.join();
	std::lock_guard<std::mutex> lock(mMutex);
	mSlots.clear();
	mPortals.reset();
}
VisibilityWorkerStats VisibilityWorker::GetStats() const
{
	std::lock_guard<std::mutex> lock(mMutex);
	return mStats;
}
void VisibilityWorker::Run()
{
	for (;;)
	{
		std::shared_ptr<Slot>				   slot;
		std::shared_ptr<const VisibilityFrame> request;
		{
			std::unique_lock<std::mutex> lock(mMutex);
			mWake.wait(lock, [&]
					   { return mStopping || !mQueue.empty(); });
			if (mStopping)
				return;
			slot = mQueue.front();
			mQueue.pop_front();
			slot->mQueued = false;
			request = std::move(slot->mPending);
			slot->mRunning = request;
			if (request)
				++mStats.mRunning;
		}
		if (!request)
			continue;
		auto result = std::make_shared<VisibilityFrame>();
		try
		{
			*result = mEvaluator(request->mScene, request->mGraph, request->mView, request->mPortals);
		}
		catch (const std::exception &e)
		{
			*result = *request;
			result->mError = e.what();
		}
		catch (...)
		{
			*result = *request;
			result->mError = "unknown Native visibility worker failure";
		}
		{
			std::lock_guard<std::mutex> lock(mMutex);
			slot->mRunning.reset();
			PublishLocked(*slot, request, std::move(result));
			--mStats.mRunning;
			++mStats.mCompleted;
		}
	}
}
} // namespace mcmesh::l2draw
