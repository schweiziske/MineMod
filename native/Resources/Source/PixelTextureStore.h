#pragma once

#include "Resources/PixelImage.h"
#include "Resources/Source/PixelTextureTypes.h"
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace mcmesh::l2
{
struct LightPixels;
class PixelTransaction;
} // namespace mcmesh::l2

namespace mcmesh::pixelupload
{
class PixelTexture;

/// Owns numeric handles and all procedural pixel textures. Every public operation
/// runs on the Lua/render thread. The engine's regenerator only sees PixelTexture.
/// Module shutdown must retire consumers and call Shutdown before engine teardown.
class PixelTextureStore
{
public:
	PixelTextureStore();
	~PixelTextureStore();
	PixelTextureStore(const PixelTextureStore &) = delete;
	PixelTextureStore &operator=(const PixelTextureStore &) = delete;

	PixelTextureStats	   Create(int inWidth, int inHeight, bool inPointSample);
	PixelTextureDimensions GetDeviceLimits() const;
	PixelTextureDimensions GetDimensions(PixelTextureId inId) const;
	PixelTextureStats	   GetTextureStats(PixelTextureId inId) const;
	PixelTextureStoreStats GetStats() const;
	void				   Stage(PixelTextureId inId, const std::vector<Span> &inSpans);
	void				   Bind(PixelTextureId inId, const char *inMaterialName, const char *inParameter);
	void				   Release(PixelTextureId inId);
	/// No dirty textures: no barrier. Otherwise drain old consumers, lock the
	/// material system, publish CPU rows, then Download each dirty rectangle.
	void Flush();
	void Shutdown();
	void UploadNative(const l2::LightPixels &inPixels, PixelTextureId inId, unsigned inFirst);
	void UploadNative(l2::PixelTransaction &ioTransaction, PixelTextureId inId, bool inRestore);
	/// Publishes several relight transactions behind one queue barrier. Unchanged
	/// results are classified before anything is staged; a failure restores every
	/// drawn transaction and flushes once more before rethrowing.
	void UploadNativeBatch(const std::vector<l2::PixelTransaction *> &ioTransactions, PixelTextureId inId);

private:
	PixelTexture										   &Find(PixelTextureId inId) const;
	std::map<PixelTextureId, std::unique_ptr<PixelTexture>> mTextures;
	PixelTextureId											mSequence = 0;
	uint64_t												mBarriers = 0;
	double													mQueueDrainMS = 0, mMaterialLockMS = 0;
	uint64_t												mUnchangedRelights = 0, mUnchangedRelightTexels = 0;
	double													mRelightCompareMS = 0;
};

/// One module-owned store. Explicit Shutdown handles engine resource retirement.
PixelTextureStore &GetPixelTextureStore();
/// Boundary conversion for callers whose Lua handles are still stored as doubles.
PixelTextureId ParsePixelTextureId(double inValue);
} // namespace mcmesh::pixelupload
