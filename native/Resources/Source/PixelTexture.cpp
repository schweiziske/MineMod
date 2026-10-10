#include "Module/Pch.h"
#include "Resources/Source/PixelTexture.h"
#include "Render/Source/EngineContext.h"
#include "Mesh/LightPixels.h"
#include "public/materialsystem/imaterialvar.h"
#include "public/vtf/vtf.h"
#include <array>
#include <chrono>
#include <cstring>
#include <stdexcept>

namespace mcmesh::pixelupload
{
namespace
{
// Five physical rows contain four corner rows and one AO row. These mappings
// preserve the shader's existing address layout: corner 0/1, AO 2, corner 3/4.
constexpr double	cCornerRowScale = 1.25;
constexpr double	cCornerRowOffset = 0.625;
constexpr double	cOcclusionRowScale = 5;
constexpr double	cOcclusionRowOffset = 2;
std::array<Span, 2> NativeSpans(const l2::LightPixels &inPixels, unsigned inFirst)
{
	return {{{inFirst * 4, inPixels.corners.data(), inPixels.corners.size(), cCornerRowScale, cCornerRowOffset},
			 {inFirst, inPixels.occlusion.data(), inPixels.occlusion.size(), cOcclusionRowScale, cOcclusionRowOffset}}};
}
} // namespace

PixelTexture::PixelTexture(PixelTextureId inId, int inWidth, int inHeight)
	: mId(inId), mWidth(inWidth), mHeight(inHeight), mImage(inWidth, inHeight) {}

PixelTexture::~PixelTexture()
{
	for (auto &binding : mBindings)
	{
		if (binding.mPrevious)
			binding.mPrevious->Release();
		binding.mMaterial->DecrementReferenceCount();
	}
	if (mTexture)
	{
		mTexture->SetTextureRegenerator(nullptr);
		mTexture->Release();
		mTexture->DeleteIfUnreferenced();
	}
}

void PixelTexture::Initialize(bool inPointSample)
{
	const std::string name = "mc_l2_pixels_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "_" + std::to_string(mId);
	int				  flags = TEXTUREFLAGS_CLAMPS | TEXTUREFLAGS_CLAMPT | TEXTUREFLAGS_NOLOD | TEXTUREFLAGS_NOMIP | TEXTUREFLAGS_PROCEDURAL | TEXTUREFLAGS_EIGHTBITALPHA | TEXTUREFLAGS_SINGLECOPY;
	if (inPointSample)
		flags |= TEXTUREFLAGS_POINTSAMPLE;
	mTexture = source::GetMaterialSystem()->CreateProceduralTexture(name.c_str(), TEXTURE_GROUP_OTHER,
																	mWidth, mHeight, IMAGE_FORMAT_RGBA8888, flags);
	if (!mTexture || mTexture->IsError())
		throw std::runtime_error("l2_texture_creation_failed");
	if (mTexture->GetActualWidth() != mWidth || mTexture->GetActualHeight() != mHeight)
		throw std::runtime_error("l2_texture_engine_resized");
	mTexture->SetTextureRegenerator(this);
	DownloadAndVerify(nullptr, false);
}

bool PixelTexture::ValidateRegenerationLocked(IVTFTexture *inVtf, const Rect_t *inRequested, Rect_t &outRect)
{
	if (!inVtf || inVtf->Width() != mWidth || inVtf->Height() != mHeight || inVtf->MipCount() != 1)
	{
		mError = "l2_texture_vtf_layout";
		return false;
	}
	const auto format = inVtf->Format();
	if (format != IMAGE_FORMAT_RGBA8888 && format != IMAGE_FORMAT_BGRA8888)
	{
		mError = "l2_texture_vtf_format";
		return false;
	}
	outRect = inRequested ? *inRequested : Rect_t{0, 0, mWidth, mHeight};
	if (outRect.x < 0 || outRect.y < 0 || outRect.width <= 0 || outRect.height <= 0 || outRect.x > mWidth - outRect.width || outRect.y > mHeight - outRect.height)
	{
		mError = "l2_texture_vtf_rect";
		return false;
	}
	if (!inVtf->ImageData(0, 0, 0) || inVtf->RowSizeInBytes(0) < mWidth * 4)
	{
		mError = "l2_texture_vtf_data";
		return false;
	}
	return true;
}

void PixelTexture::CopyRectLocked(IVTFTexture *inVtf, const Rect_t &inRect)
{
	auto	  *data = inVtf->ImageData(0, 0, 0);
	const int  pitch = inVtf->RowSizeInBytes(0);
	const bool rgba = inVtf->Format() == IMAGE_FORMAT_RGBA8888;
	for (int y = inRect.y; y < inRect.y + inRect.height; ++y)
	{
		const auto &row = mImage.row(y);
		auto	   *dest = data + size_t(y) * pitch + inRect.x * 4;
		if (row.empty())
		{
			std::memset(dest, 0, size_t(inRect.width) * 4);
			continue;
		}
		const auto *source = reinterpret_cast<const uint8_t *>(row.data() + inRect.x);
		if (rgba)
			std::memcpy(dest, source, size_t(inRect.width) * 4);
		else
			for (int x = 0; x < inRect.width; ++x, source += 4, dest += 4)
			{
				dest[0] = source[2];
				dest[1] = source[1];
				dest[2] = source[0];
				dest[3] = source[3];
			}
	}
	mUploadedBytes += size_t(inRect.width) * inRect.height * 4;
}

void PixelTexture::RegenerateTextureBits(ITexture *, IVTFTexture *inVtf, Rect_t *inRequested)
{
	std::lock_guard<std::mutex> lock(mMutex);
	++mCallbacks;
	Rect_t rect;
	if (ValidateRegenerationLocked(inVtf, inRequested, rect))
		CopyRectLocked(inVtf, rect);
}

void PixelTexture::DownloadAndVerify(Rect_t *inRect, bool inCountDownload)
{
	uint64_t before;
	{
		std::lock_guard<std::mutex> lock(mMutex);
		mError = nullptr;
		before = mCallbacks;
	}
	mTexture->Download(inRect);
	std::lock_guard<std::mutex> lock(mMutex);
	if (inCountDownload)
		++mDownloads;
	if (mError)
		throw std::runtime_error(mError);
	if (mCallbacks == before)
		throw std::runtime_error("l2_texture_regenerator_not_called");
}

void PixelTexture::PublishPending()
{
	// Plan rectangles before changing published rows. Keep pending data on any
	// failure so the caller's existing transaction can retry or restore it.
	const auto rects = mImage.rectangles();
	{
		std::lock_guard<std::mutex> lock(mMutex);
		mImage.publish();
	}
	for (const auto &area : rects)
	{
		Rect_t rect{area.x, area.y, area.width, area.height};
		DownloadAndVerify(&rect, true);
	}
	mImage.pending.clear();
}

bool PixelTexture::OwnsBinding(const IMaterialVar *inVariable) const
{
	for (const auto &binding : mBindings)
		if (binding.mVariable == inVariable)
			return true;
	return false;
}

void PixelTexture::BindMaterial(IMaterial *inMaterial, IMaterialVar *inVariable)
{
	if (!OwnsBinding(inVariable))
	{
		mBindings.push_back({inMaterial, inVariable, inVariable->GetTextureValue()});
		inMaterial->IncrementReferenceCount();
		if (mBindings.back().mPrevious)
			mBindings.back().mPrevious->AddRef();
	}
	inVariable->SetTextureValue(mTexture);
}

void PixelTexture::RestoreBindings()
{
	for (auto &binding : mBindings)
		if (binding.mVariable->GetTextureValue() == mTexture)
			binding.mVariable->SetTextureValue(binding.mPrevious);
}

PixelTextureStats PixelTexture::GetStats() const
{
	std::lock_guard<std::mutex> lock(mMutex);
	PixelTextureStats			stats;
	stats.mId = mId;
	stats.mWidth = mWidth;
	stats.mHeight = mHeight;
	stats.mBackingBytes = mImage.backingBytes();
	stats.mPendingBytes = mImage.pendingBytes();
	stats.mCallbacks = mCallbacks;
	stats.mDownloads = mDownloads;
	stats.mUploadedBytes = mUploadedBytes;
	stats.mWrites = mWrites;
	stats.mEngineBytes = mTexture->GetApproximateVidMemBytes();
	stats.mFlags = mTexture->GetFlags();
	stats.mName = mTexture->GetName();
	return stats;
}

std::pair<size_t, size_t> PixelTexture::GetImageBytes() const
{
	std::lock_guard<std::mutex> lock(mMutex);
	return {mImage.backingBytes(), mImage.pendingBytes()};
}

void PixelTexture::Stage(const std::vector<Span> &inSpans)
{
	std::lock_guard<std::mutex> lock(mMutex);
	mImage.stage(inSpans);
	++mWrites;
}

void PixelTexture::PrepareNativeLocked(const l2::LightPixels &inPixels, unsigned inFirst)
{
	l2::validatePixelRange(inPixels, mWidth, mHeight, inFirst);
	for (const auto &span : NativeSpans(inPixels, inFirst))
		mImage.prepare(span);
}

void PixelTexture::StageNativeLocked(const l2::LightPixels &inPixels, unsigned inFirst)
{
	for (const auto &span : NativeSpans(inPixels, inFirst))
		mImage.stagePrepared(span);
	++mWrites;
}

void PixelTexture::StageNative(const l2::LightPixels &inPixels, unsigned inFirst)
{
	std::lock_guard<std::mutex> lock(mMutex);
	PrepareNativeLocked(inPixels, inFirst);
	StageNativeLocked(inPixels, inFirst);
}

void PixelTexture::PrepareTransaction(const l2::PixelTransaction &inTransaction)
{
	std::lock_guard<std::mutex> lock(mMutex);
	for (const auto &update : inTransaction.updates())
		PrepareNativeLocked(*update.next, update.first);
}

void PixelTexture::StageTransactionPixels(const l2::LightPixels &inPixels, unsigned inFirst)
{
	std::lock_guard<std::mutex> lock(mMutex);
	for (const auto &span : NativeSpans(inPixels, inFirst))
		mImage.prepare(span);
	StageNativeLocked(inPixels, inFirst);
}
} // namespace mcmesh::pixelupload
