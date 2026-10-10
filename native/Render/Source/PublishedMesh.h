#pragma once

#include "Render/Source/MeshResource.h"
#include "Mesh/LightPixels.h"
#include "World/WorldStore.h"
#include <memory>
#include <unordered_map>

namespace mcmesh::source
{
class MeshPublication;

struct RetainedLight
{
	std::shared_ptr<const std::vector<l2::LightWork>> mWork;
	world::GeometryStamp							  mGeometry;
	size_t											  mBytes;
	RetainedLight(const l2::Part &inPart, const world::MeshSnapshot &inSource);
};

/// Lua owns this facade. It owns its Source mesh, retained sampling work and
/// pixel slot. Scene objects only borrow DrawResource while retaining userdata.
/// Destroy invalidates transactions before releasing data; it is idempotent.
/// All operations run on the Lua/render thread.
class PublishedMesh
{
public:
	explicit PublishedMesh(MeshPublication &inOwner);
	~PublishedMesh();
	PublishedMesh(const PublishedMesh &) = delete;
	PublishedMesh						 &operator=(const PublishedMesh &) = delete;
	void								  Upload(const l2::Part &inPart, unsigned inFirst, const std::string &inMaterialName,
												 const world::MeshSnapshot *inSource, bool inNativePixels);
	void								  Destroy();
	bool								  IsValid() const { return mResource.IsValid(); }
	DrawResource						 &GetDrawResource() { return mResource.GetDrawResource(); }
	const RetainedLight					 *GetLighting() const { return mLighting.get(); }
	const std::shared_ptr<l2::PixelSlot> &GetPixels() const { return mPixels; }

private:
	friend class MeshPublication;
	MeshPublication				  &mOwner;
	MeshResource				   mResource;
	std::unique_ptr<RetainedLight> mLighting;
	std::shared_ptr<l2::PixelSlot> mPixels;
	PublishedMesh				  *mPrevious = nullptr, *mNext = nullptr;
};

struct MeshPublicationStats
{
	uint64_t mLiveMeshes = 0;
	size_t	 mRetainedLightBytes = 0;
	int64_t	 mMeshPixelBytes = 0;
	size_t	 mLiveTransactions = 0;
};

/// Tracks live userdata-owned meshes for orderly module shutdown; does not own
/// userdata. Owns transactions, whose pointers are borrowed by Lua until Finish
/// or ReleaseTransaction. Shutdown invalidates payloads but keeps Lua handles
/// alive for their eventual GC. Must outlive every PublishedMesh facade.
class MeshPublication
{
public:
	MeshPublicationStats  GetStats() const;
	l2::PixelTransaction *AdoptTransaction(std::unique_ptr<l2::PixelTransaction> inTransaction);
	void				  ReleaseTransaction(l2::PixelTransaction *inTransaction);
	void				  FinishTransaction(l2::PixelTransaction &ioTransaction, bool inCommit);
	void				  Shutdown();

private:
	friend class PublishedMesh;
	void																			  Attach(PublishedMesh &ioMesh);
	void																			  Detach(PublishedMesh &ioMesh);
	PublishedMesh																	 *mFirstMesh = nullptr; // Borrowed until Destroy/GC.
	MeshPublicationStats															  mStats;
	std::unordered_map<l2::PixelTransaction *, std::unique_ptr<l2::PixelTransaction>> mTransactions;
};

MeshPublication &GetMeshPublication();
} // namespace mcmesh::source
