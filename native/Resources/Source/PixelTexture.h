#pragma once

#include "Resources/PixelImage.h"
#include "Resources/Source/PixelTextureTypes.h"
#include "public/materialsystem/itexture.h"
#include <mutex>
#include <utility>

class IMaterial;
class IMaterialVar;
namespace mcmesh::l2
{
struct LightPixels;
class PixelTransaction;
} // namespace mcmesh::l2

namespace mcmesh::pixelupload
{
class PixelTextureStore;

/// One procedural texture, its immutable published rows and retained material
/// bindings. The store owns its lifetime; the engine borrows the regenerator.
/// All operations except RegenerateTextureBits run on the Lua/render thread.
class PixelTexture final : public ITextureRegenerator
{
public:
	PixelTexture(PixelTextureId inId, int inWidth, int inHeight);
	~PixelTexture();
	PixelTexture(const PixelTexture &) = delete;
	PixelTexture &operator=(const PixelTexture &) = delete;

	void RegenerateTextureBits(ITexture *inTexture, IVTFTexture *inVtf, Rect_t *inRequested) override;
	void Release() override {} // The store, rather than the engine, owns this callback.

private:
	friend class PixelTextureStore;
	struct MaterialBinding
	{
		IMaterial	 *mMaterial;
		IMaterialVar *mVariable;
		ITexture	 *mPrevious;
	};

	// Initialize, PublishPending and destruction require a drained, locked
	// material system. RestoreBindings and BindMaterial use the queued context.
	void Initialize(bool inPointSample);
	void PublishPending();
	bool OwnsBinding(const IMaterialVar *inVariable) const;
	void BindMaterial(IMaterial *inMaterial, IMaterialVar *inVariable);
	void RestoreBindings();

	PixelTextureDimensions	  GetDimensions() const { return {mWidth, mHeight}; }
	PixelTextureStats		  GetStats() const;
	std::pair<size_t, size_t> GetImageBytes() const;
	bool					  HasPending() const { return !mImage.pending.empty(); }
	void					  Stage(const std::vector<Span> &inSpans);
	void					  StageNative(const l2::LightPixels &inPixels, unsigned inFirst);
	void					  PrepareTransaction(const l2::PixelTransaction &inTransaction);
	// Transaction ranges are prevalidated; rollback may need new pending rows
	// after a prior Flush. This allocates ranges but does not revalidate pixels.
	void StageTransactionPixels(const l2::LightPixels &inPixels, unsigned inFirst);
	void PrepareNativeLocked(const l2::LightPixels &inPixels, unsigned inFirst);
	void StageNativeLocked(const l2::LightPixels &inPixels, unsigned inFirst);

	bool ValidateRegenerationLocked(IVTFTexture *inVtf, const Rect_t *inRequested, Rect_t &outRect);
	void CopyRectLocked(IVTFTexture *inVtf, const Rect_t &inRect);
	// Never hold mMutex during Download: it invokes this object's regenerator.
	void DownloadAndVerify(Rect_t *inRect, bool inCountDownload);

	PixelTextureId				 mId;
	int							 mWidth, mHeight;
	ITexture					*mTexture = nullptr;
	Image						 mImage;
	std::vector<MaterialBinding> mBindings;
	// Protects published image storage, callback counters and callback errors.
	// Only the owning thread mutates pending ranges, bindings and the handle.
	mutable std::mutex mMutex;
	uint64_t		   mCallbacks = 0, mDownloads = 0, mUploadedBytes = 0, mWrites = 0;
	const char		  *mError = nullptr; // Static error code; never points into a Lua value.
};
} // namespace mcmesh::pixelupload
