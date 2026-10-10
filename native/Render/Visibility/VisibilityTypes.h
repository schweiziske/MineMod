#pragma once

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace mcmesh::l2draw
{
using Vec = std::array<double, 3>;
using Cell = std::array<int, 3>;

struct VisibilityBounds
{
	Vec	   mCenter{}, mHalf{};
	double mRadius = 0;
};

struct VisibilitySection
{
	VisibilityBounds mBounds;
	unsigned		 mIndex = 0;
	bool			 mBounded = false, mProtrudes = false;
};

struct VisibilityChunk
{
	double						   mKey = 0;
	Vec							   mOrigin{};
	VisibilityBounds			   mBounds;
	std::vector<VisibilitySection> mSections;
};

/// Immutable CPU geometry snapshot. Retained by visibility requests and results.
struct VisibilityScene
{
	std::vector<std::shared_ptr<const VisibilityChunk>> mChunks;
};

struct PortalComponent
{
	uint8_t					mMask = 0;
	std::array<uint64_t, 6> mTargets{};
};

struct PortalNode
{
	Cell					mPosition{};
	std::array<unsigned, 6> mNeighbors{};
	std::array<uint8_t, 6>	mExits{};
	// Build-boundary inputs; the bridge releases these after linking components.
	std::array<std::vector<uint8_t>, 6> mBoundary;
	std::array<uint64_t, 6>				mEntries{};
	std::vector<PortalComponent>		mComponents;
	bool								mLive = false;
};

/// Build on the caller thread, then publish as const. Node zero is the exterior.
struct VisibilityGraph
{
	std::vector<PortalNode>				 mNodes;
	std::unordered_map<double, unsigned> mBases;
	bool								 mSpatial = false;
	Cell								 mLower{}, mSize{};
	// Zero denotes an open, unregistered section at this position.
	std::vector<unsigned> mGrid;
};

/// Camera and conservative reuse budgets in the same coordinate space as the scene.
struct VisibilityView
{
	Vec				   mEye{};
	Cell			   mPortalCell{};
	std::array<Vec, 5> mPlanes{};
	unsigned		   mPlaneCount = 0, mRoot = 0;
	uint8_t			   mSeed = 63;
	bool			   mPortals = false;
	double			   mDistance = 0, mMoveBudget = 0, mNormalBudget = 0.12;
};

enum class ERejectReason : uint8_t
{
	None,
	Distance,
	Frustum,
	Portal
};

struct VisibleChunk
{
	ERejectReason			   mReject = ERejectReason::None;
	std::vector<ERejectReason> mSections;
};

struct PortalMask
{
	std::shared_ptr<const VisibilityGraph> mGraph;
	unsigned							   mRoot = 0;
	uint8_t								   mSeed = 63;
	Cell								   mCell{};
	unsigned							   mVisited = 0;
	std::vector<uint8_t>				   mSeen;

	bool Matches(const VisibilityGraph *inGraph, const VisibilityView &inView) const
	{
		return mGraph.get() == inGraph && mRoot == inView.mRoot && mSeed == inView.mSeed &&
			   (!inGraph->mSpatial || mCell == inView.mPortalCell);
	}
};

/// Pure CPU result. Owns its inputs; workers never retain Lua or Source resources.
struct VisibilityFrame
{
	std::shared_ptr<const VisibilityScene> mScene;
	std::shared_ptr<const VisibilityGraph> mGraph;
	VisibilityView						   mView;
	std::shared_ptr<const PortalMask>	   mPortals;
	std::vector<VisibleChunk>			   mChunks;
	std::string							   mError;
	double								   mMilliseconds = 0;
};
} // namespace mcmesh::l2draw
