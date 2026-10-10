#include "Render/Visibility/VisibilityQuery.h"
#include "Render/Visibility/VisibilityGraph.h"
#include "Render/Visibility/VisibilityMath.h"
#include <chrono>
#include <cmath>
#include <stdexcept>
#include <utility>
namespace mcmesh::l2draw
{
ERejectReason TestBounds(const VisibilityBounds &inBounds, const Vec &inOrigin, const VisibilityView &inView, bool inTestDistance)
{
	const Vec	 center = {inOrigin[0] + inBounds.mCenter[0] - inView.mEye[0],
						   inOrigin[1] + inBounds.mCenter[1] - inView.mEye[1], inOrigin[2] + inBounds.mCenter[2] - inView.mEye[2]};
	const double d = detail::Length(center);
	if (inTestDistance && inView.mDistance > 0 && d > inView.mDistance + inBounds.mRadius + inView.mMoveBudget)
		return ERejectReason::Distance;
	// For every point p in the box: |(n'-n).p| <= |n'-n| * (|center|+radius).
	// This envelope safely covers both camera translation and rotation.
	const double slack = inView.mMoveBudget + inView.mNormalBudget * (d + inBounds.mRadius);
	for (unsigned i = 0; i < inView.mPlaneCount; ++i)
	{
		const auto &n = inView.mPlanes[i];
		double		value = slack;
		for (unsigned a = 0; a < 3; ++a)
			value += n[a] * center[a] + std::abs(n[a]) * inBounds.mHalf[a];
		if (value < 0)
			return ERejectReason::Frustum;
	}
	return ERejectReason::None;
}
VisibilityFrame Compute(std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView,
						std::shared_ptr<const PortalMask> inPortals)
{
	const auto		start = std::chrono::steady_clock::now();
	VisibilityFrame frame;
	frame.mScene = std::move(inScene);
	frame.mGraph = std::move(inGraph);
	frame.mView = inView;
	if (inView.mPortals)
	{
		if (!frame.mGraph)
			throw std::runtime_error("missing Native visibility graph");
		if (!inPortals || !inPortals->Matches(frame.mGraph.get(), inView))
		{
			auto mask = std::make_shared<PortalMask>();
			mask->mGraph = frame.mGraph;
			mask->mRoot = inView.mRoot;
			mask->mSeed = inView.mSeed;
			mask->mCell = inView.mPortalCell;
			mask->mSeen = FindReachable(*frame.mGraph, inView, mask->mVisited);
			inPortals = std::move(mask);
		}
		frame.mPortals = std::move(inPortals);
	}
	frame.mChunks.resize(frame.mScene->mChunks.size());
	for (size_t i = 0; i < frame.mChunks.size(); ++i)
	{
		const auto &chunk = *frame.mScene->mChunks[i];
		auto	   &result = frame.mChunks[i];
		result.mReject = TestBounds(chunk.mBounds, chunk.mOrigin, inView, true);
		if (result.mReject != ERejectReason::None)
			continue;
		unsigned base = 0;
		bool	 registered = false;
		if (inView.mPortals)
		{
			const auto found = frame.mGraph->mBases.find(chunk.mKey);
			if (found != frame.mGraph->mBases.end())
			{
				registered = true;
				base = found->second;
			}
		}
		result.mSections.resize(chunk.mSections.size());
		for (size_t s = 0; s < chunk.mSections.size(); ++s)
		{
			const auto &section = chunk.mSections[s];
			auto	   &reason = result.mSections[s];
			if (section.mBounded)
				reason = TestBounds(section.mBounds, chunk.mOrigin, inView, false);
			if (reason == ERejectReason::None && registered && section.mBounded && !section.mProtrudes)
			{
				const auto id = base + section.mIndex;
				if (id >= frame.mPortals->mSeen.size() || !frame.mGraph->mNodes[id].mLive)
					throw std::runtime_error("Native visibility section is outside its graph");
				if (!frame.mPortals->mSeen[id])
					reason = ERejectReason::Portal;
			}
		}
	}
	frame.mMilliseconds = std::chrono::duration<double, std::milli>(
							  std::chrono::steady_clock::now() - start)
							  .count();
	return frame;
}
bool Covers(const VisibilityFrame &inFrame, const VisibilityScene *inScene, const VisibilityGraph *inGraph, const VisibilityView &inView)
{
	const auto &old = inFrame.mView;
	if (inFrame.mScene.get() != inScene || inFrame.mGraph.get() != inGraph || old.mPortals != inView.mPortals ||
		old.mRoot != inView.mRoot || old.mSeed != inView.mSeed || old.mPlaneCount != inView.mPlaneCount ||
		old.mDistance != inView.mDistance || detail::Length(detail::Subtract(old.mEye, inView.mEye)) > old.mMoveBudget)
		return false;
	if (inView.mPortals && inGraph && inGraph->mSpatial && old.mPortalCell != inView.mPortalCell)
		return false;
	for (unsigned i = 0; i < inView.mPlaneCount; ++i)
		if (detail::Length(detail::Subtract(old.mPlanes[i], inView.mPlanes[i])) > old.mNormalBudget)
			return false;
	return true;
}
bool IsDirectionVisible(unsigned inGroup, const float inBounds[6], const Vec &inEye, double inMargin)
{
	if (inGroup == 6)
		return true;
	const unsigned axis = inGroup < 2 ? 2 : inGroup < 4 ? 0
														: 1;
	return inGroup & 1 ? inEye[axis] <= inBounds[axis + 3] + inMargin : inEye[axis] >= inBounds[axis] - inMargin;
}

} // namespace mcmesh::l2draw
