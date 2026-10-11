#include "Module/Pch.h"
#include "Resources/Source/PixelTextureStore.h"
#include "Resources/Source/PixelTexture.h"
#include "Render/Source/EngineContext.h"
#include "Mesh/LightPixels.h"
#include "public/materialsystem/imaterialvar.h"
#include "public/materialsystem/imaterialsystemhardwareconfig.h"
#include <cmath>
#include <chrono>
#include <stdexcept>

namespace mcmesh::pixelupload
{
namespace
{
PixelTextureStore sTextureStore;

/// GMod's queue drain and material lock are different barriers. Lock waits for
/// the active async job; GMOD_FlushQueue must first retire queued consumers.
class TexturePublicationScope
{
public:
	explicit TexturePublicationScope(uint64_t &ioBarrierCount, double &ioQueueDrainMS, double &ioMaterialLockMS)
		: mMaterialSystem(source::GetMaterialSystem())
	{
		CMatRenderContextPtr context(mMaterialSystem);
		const auto			 drain_started = std::chrono::steady_clock::now();
		context->GMOD_FlushQueue();
		const auto lock_started = std::chrono::steady_clock::now();
		ioQueueDrainMS += std::chrono::duration<double, std::milli>(lock_started - drain_started).count();
		mLock = mMaterialSystem->Lock();
		ioMaterialLockMS += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - lock_started).count();
		++ioBarrierCount;
	}
	~TexturePublicationScope() { mMaterialSystem->Unlock(mLock); }
	TexturePublicationScope(const TexturePublicationScope &) = delete;
	TexturePublicationScope &operator=(const TexturePublicationScope &) = delete;

private:
	IMaterialSystem *mMaterialSystem;
	MaterialLock_t	 mLock;
};
} // namespace

PixelTextureStore::PixelTextureStore() = default;
PixelTextureStore::~PixelTextureStore() = default;

PixelTextureStore &GetPixelTextureStore()
{
	return sTextureStore;
}

PixelTextureId ParsePixelTextureId(double inValue)
{
	if (!std::isfinite(inValue) || inValue < 1 || inValue > double(cMaxPixelTextureId) || inValue != std::floor(inValue))
		throw std::runtime_error("l2_texture_stale_handle");
	return PixelTextureId(inValue);
}

PixelTexture &PixelTextureStore::Find(PixelTextureId inId) const
{
	const auto found = mTextures.find(inId);
	if (found == mTextures.end())
		throw std::runtime_error("l2_texture_stale_handle");
	return *found->second;
}

PixelTextureStats PixelTextureStore::Create(int inWidth, int inHeight, bool inPointSample)
{
	auto *material_system = source::GetMaterialSystem();
	if (!material_system)
		throw std::runtime_error("l2_texture_create_arguments");
	if (inWidth < 1 || inWidth > 16384 || inHeight < 1 || inHeight > 16384)
		throw std::runtime_error("l2_texture_range");
	int	  code = 0;
	auto *hardware = material_system->GetHardwareConfig(MATERIALSYSTEM_HARDWARECONFIG_INTERFACE_VERSION, &code);
	if (!hardware || inWidth > hardware->MaxTextureWidth() || inHeight > hardware->MaxTextureHeight())
		throw std::runtime_error("l2_texture_device_limit");
	if (mSequence == cMaxPixelTextureId)
		throw std::runtime_error("l2_texture_handle_exhausted");

	TexturePublicationScope publication(mBarriers, mQueueDrainMS, mMaterialLockMS);
	auto					texture = std::make_unique<PixelTexture>(mSequence + 1, inWidth, inHeight);
	++mSequence;
	texture->Initialize(inPointSample);
	auto	   stats = texture->GetStats();
	const auto id = mSequence;
	mTextures.emplace(id, std::move(texture));
	return stats;
}

PixelTextureDimensions PixelTextureStore::GetDimensions(PixelTextureId inId) const
{
	return Find(inId).GetDimensions();
}

PixelTextureStats PixelTextureStore::GetTextureStats(PixelTextureId inId) const
{
	return Find(inId).GetStats();
}

PixelTextureStoreStats PixelTextureStore::GetStats() const
{
	PixelTextureStoreStats stats;
	stats.mBarriers = mBarriers;
	stats.mQueueDrainMS = mQueueDrainMS;
	stats.mMaterialLockMS = mMaterialLockMS;
	stats.mUnchangedRelights = mUnchangedRelights;
	stats.mUnchangedRelightTexels = mUnchangedRelightTexels;
	stats.mRelightCompareMS = mRelightCompareMS;
	stats.mTextures = mTextures.size();
	for (const auto &[id, texture] : mTextures)
	{
		const auto bytes = texture->GetImageBytes();
		stats.mResidentBytes += bytes.first;
		stats.mPendingBytes += bytes.second;
	}
	return stats;
}

void PixelTextureStore::Stage(PixelTextureId inId, const std::vector<Span> &inSpans)
{
	Find(inId).Stage(inSpans);
}

void PixelTextureStore::Bind(PixelTextureId inId, const char *inMaterialName, const char *inParameter)
{
	auto &texture = Find(inId);
	auto *material = source::GetMaterialSystem()->FindMaterial(inMaterialName, TEXTURE_GROUP_OTHER, false);
	if (!material || material->IsErrorMaterial())
		throw std::runtime_error("l2_texture_binding_material");
	bool  found = false;
	auto *variable = material->FindVar(inParameter, &found, false);
	if (!found || !variable || !variable->IsTexture())
		throw std::runtime_error("l2_texture_binding_parameter");
	for (const auto &[id, owner] : mTextures)
		if (owner.get() != &texture && owner->OwnsBinding(variable))
			throw std::runtime_error("l2_texture_binding_owned");
	texture.BindMaterial(material, variable);
}

void PixelTextureStore::Release(PixelTextureId inId)
{
	// Restore with the normal queued context BEFORE taking the lock. Mutations
	// under Lock do not update the engine's queued material copy correctly.
	Find(inId).RestoreBindings();
	TexturePublicationScope publication(mBarriers, mQueueDrainMS, mMaterialLockMS);
	mTextures.erase(inId);
}

void PixelTextureStore::Flush()
{
	bool dirty = false;
	for (const auto &[id, texture] : mTextures)
		if (texture->HasPending())
			dirty = true;
	if (!dirty)
		return;

	TexturePublicationScope publication(mBarriers, mQueueDrainMS, mMaterialLockMS);
	for (auto &[id, texture] : mTextures)
		if (texture->HasPending())
			texture->PublishPending();
}

void PixelTextureStore::Shutdown()
{
	if (mTextures.empty())
		return;
	for (auto &[id, texture] : mTextures)
		texture->RestoreBindings();
	TexturePublicationScope publication(mBarriers, mQueueDrainMS, mMaterialLockMS);
	mTextures.clear();
}

void PixelTextureStore::UploadNative(const l2::LightPixels &inPixels, PixelTextureId inId, unsigned inFirst)
{
	Find(inId).StageNative(inPixels, inFirst);
}

void PixelTextureStore::UploadNative(l2::PixelTransaction &ioTransaction, PixelTextureId inId, bool inRestore)
{
	auto &texture = Find(inId);
	ioTransaction.validate();
	if (!inRestore)
	{
		const auto compare_started = std::chrono::steady_clock::now();
		const bool unchanged = texture.MatchesPublished(ioTransaction);
		mRelightCompareMS += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - compare_started).count();
		if (unchanged)
		{
			// The target already contains the complete result. Retain transaction
			// validation/publication semantics without staging or a queue barrier.
			ioTransaction.draw([](const std::shared_ptr<const l2::LightPixels> &, unsigned) {});
			++mUnchangedRelights;
			for (const auto &update : ioTransaction.updates())
				mUnchangedRelightTexels += update.next->occlusion.size() * 5;
			return;
		}
	}
	texture.PrepareTransaction(ioTransaction);
	auto stage = [&](const std::shared_ptr<const l2::LightPixels> &inPixels, unsigned inFirst)
	{
		texture.StageTransactionPixels(*inPixels, inFirst);
	};
	auto flush = [this]
	{
		Flush();
	};
	if (inRestore)
		ioTransaction.restore(stage, flush);
	else
		ioTransaction.draw(stage, flush);
}
} // namespace mcmesh::pixelupload
