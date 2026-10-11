#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace mcmesh::pixelupload
{
using PixelTextureId = uint64_t;
inline constexpr PixelTextureId cMaxPixelTextureId = 9007199254740991ULL;
inline constexpr unsigned		cPixelTextureVersion = 2;

struct PixelTextureDimensions
{
	int mWidth = 0, mHeight = 0;
};

struct PixelTextureStats : PixelTextureDimensions
{
	PixelTextureId mId = 0;
	size_t		   mBackingBytes = 0, mPendingBytes = 0;
	uint64_t	   mCallbacks = 0, mDownloads = 0, mUploadedBytes = 0, mWrites = 0;
	int			   mEngineBytes = 0, mFlags = 0;
	std::string	   mName;
};

struct PixelTextureStoreStats
{
	uint64_t mBarriers = 0;
	size_t	 mResidentBytes = 0, mPendingBytes = 0, mTextures = 0;
	// Cumulative main-thread wall time, including waits; never GPU timings.
	double	 mQueueDrainMS = 0, mMaterialLockMS = 0;
	uint64_t mUnchangedRelights = 0, mUnchangedRelightTexels = 0;
	double	 mRelightCompareMS = 0;
};
} // namespace mcmesh::pixelupload
