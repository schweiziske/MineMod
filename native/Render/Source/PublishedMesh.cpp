#include "Module/Pch.h"
#include "Render/Source/PublishedMesh.h"
#include "Mesh/SectionWorker.h"
#include <utility>

namespace mcmesh::source
{
namespace
{
MeshPublication sMeshPublication;
}

MeshPublication &GetMeshPublication()
{
	return sMeshPublication;
}

RetainedLight::RetainedLight(const l2::Part &inPart, const world::MeshSnapshot &inSource)
	: mWork(inPart.lighting), mGeometry(inSource),
	  mBytes(sizeof(*this) + mGeometry.bytes() + mWork->capacity() * sizeof(l2::LightWork)) {}

PublishedMesh::PublishedMesh(MeshPublication &inOwner) : mOwner(inOwner) {}
PublishedMesh::~PublishedMesh()
{
	Destroy();
}

void PublishedMesh::Upload(const l2::Part &inPart, unsigned inFirst, const std::string &inMaterialName,
						   const world::MeshSnapshot *inSource, bool inNativePixels)
{
	l2::require(!IsValid(), "Native L2 mesh already uploaded");
	// Allocate all retained state before touching the engine or registry.
	std::unique_ptr<RetainedLight> lighting;
	if (inSource && inPart.lighting)
		lighting = std::make_unique<RetainedLight>(inPart, *inSource);
	std::shared_ptr<l2::PixelSlot> pixels;
	if (inNativePixels)
	{
		pixels = std::make_shared<l2::PixelSlot>();
		pixels->pixels = inPart.pixels;
	}
	mResource.Upload(inPart, inFirst, inMaterialName);
	mLighting = std::move(lighting);
	mPixels = std::move(pixels);
	mOwner.Attach(*this);
}

void PublishedMesh::Destroy()
{
	if (!IsValid())
		return;
	mOwner.Detach(*this);
	if (mPixels)
	{
		mPixels->live = false;
		mPixels->pixels.reset();
		mPixels.reset();
	}
	mLighting.reset();
	mResource.Destroy();
}

void MeshPublication::Attach(PublishedMesh &ioMesh)
{
	ioMesh.mNext = mFirstMesh;
	if (mFirstMesh)
		mFirstMesh->mPrevious = &ioMesh;
	mFirstMesh = &ioMesh;
	++mStats.mLiveMeshes;
	if (ioMesh.mLighting)
		mStats.mRetainedLightBytes += ioMesh.mLighting->mBytes;
	if (ioMesh.mPixels)
		mStats.mMeshPixelBytes += int64_t(ioMesh.mPixels->pixels->bytes());
}

void MeshPublication::Detach(PublishedMesh &ioMesh)
{
	if (ioMesh.mPrevious)
		ioMesh.mPrevious->mNext = ioMesh.mNext;
	else
		mFirstMesh = ioMesh.mNext;
	if (ioMesh.mNext)
		ioMesh.mNext->mPrevious = ioMesh.mPrevious;
	ioMesh.mPrevious = ioMesh.mNext = nullptr;
	--mStats.mLiveMeshes;
	if (ioMesh.mLighting)
		mStats.mRetainedLightBytes -= ioMesh.mLighting->mBytes;
	if (ioMesh.mPixels)
		mStats.mMeshPixelBytes -= int64_t(ioMesh.mPixels->pixels->bytes());
}

MeshPublicationStats MeshPublication::GetStats() const
{
	auto stats = mStats;
	stats.mLiveTransactions = mTransactions.size();
	return stats;
}

l2::PixelTransaction *MeshPublication::AdoptTransaction(std::unique_ptr<l2::PixelTransaction> inTransaction)
{
	auto *transaction = inTransaction.get();
	mTransactions.emplace(transaction, std::move(inTransaction));
	return transaction;
}

void MeshPublication::ReleaseTransaction(l2::PixelTransaction *inTransaction)
{
	mTransactions.erase(inTransaction);
}

void MeshPublication::FinishTransaction(l2::PixelTransaction &ioTransaction, bool inCommit)
{
	if (inCommit)
		mStats.mMeshPixelBytes += ioTransaction.commit();
	else
		ioTransaction.discard();
	ReleaseTransaction(&ioTransaction);
}

void MeshPublication::Shutdown()
{
	while (mFirstMesh)
		mFirstMesh->Destroy();
	for (auto &[transaction, owned] : mTransactions)
		owned->shutdown();
}
} // namespace mcmesh::source
