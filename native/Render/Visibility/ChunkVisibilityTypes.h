#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace mcmesh::meshbuild
{
struct NativeDrawView
{
	int		 mChunkSize = 0, mChunkHeight = 0, mSectionSize = 0, mSectionsX = 0, mSectionsZ = 0, mSectionCount = 0;
	double	 mBlockSize = 0;
	double	 mEye[3]{}, mForward[3]{}, mRight[3]{}, mUp[3]{};
	double	 mTanX = 0, mTanY = 0, mOffset[3]{}, mDistance = 0;
	double	 mLodStartChunks = 24.0, mLodStartDistance = 0;
	uint64_t mOcclusionEpoch = 0;
	bool	 mFrustum = true, mHorizontalDistance = false, mCollectKeys = false, mOcclusionCull = false, mLod = false;
};

struct NativeDrawResult
{
	uint64_t	mTestedChunks = 0, mDrawnChunks = 0, mDistanceCulled = 0, mFrustumCulled = 0;
	uint64_t	mTestedSections = 0, mVisibleChunks = 0, mVisibleSections = 0;
	uint64_t	mDrawnSections = 0, mMeshesDrawn = 0, mVerticesCandidate = 0, mVerticesDrawn = 0;
	uint64_t	mVerticesFullDetail = 0, mVerticesLodCulled = 0, mVerticesDirectionCulled = 0, mTrianglesDrawn = 0;
	uint64_t	mLodSectionsDrawn = 0, mLodMeshesDrawn = 0;
	uint64_t	mOcclusionTestedSections = 0, mOcclusionCulledSections = 0, mOcclusionCulledChunks = 0;
	uint64_t	mOcclusionComponentSections = 0, mOcclusionReachableSections = 0;
	bool		mDirectionalDraw = false, mOcclusionCull = false, mOcclusionApplied = false, mLod = false, mLodApplied = false;
	double		mElapsedUs = 0, mCullUs = 0, mLodStartChunks = 0;
	std::string mVisibleKeys;
};

struct DrawChunkMetadata
{
	uint64_t							   mKey = 0, mPassMask[2]{};
	int									   mCx = 0, mCy = 0, mCz = 0;
	bool								   mHidden = false;
	uint64_t							   mOcclusionReadyMask = 0, mLodReadyMask = 0;
	std::array<std::array<uint8_t, 6>, 64> mOcclusionVisibleFrom{};
};

struct VisibleDrawEntry
{
	uint64_t				mKey = 0, mSectionMask = 0, mLodMask = 0;
	int						mCx = 0, mCy = 0, mCz = 0;
	std::array<uint64_t, 6> mDirectionalMasks{};
};

struct NativeCullFrame
{
	uint64_t					  mSerial = 0;
	NativeDrawView				  mView;
	NativeDrawResult			  mPass[2];
	std::vector<VisibleDrawEntry> mVisible[2];
};

struct ChunkMeshDrawStats
{
	size_t	 mMetadataChunks = 0, mOcclusionReadySections = 0;
	bool	 mWorkerRunning = false, mPending = false, mFailed = false;
	uint64_t mSerial = 0, mRequestSerial = 0, mMetadataEpoch = 0;
};
} // namespace mcmesh::meshbuild
