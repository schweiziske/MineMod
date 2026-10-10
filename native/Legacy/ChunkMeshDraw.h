#pragma once
#include "Render/Visibility/ChunkVisibilityTypes.h"
#include <memory>

namespace mcmesh::meshbuild
{
/// Owns compatibility-renderer metadata, cull worker and frame caches. Main
/// thread APIs never expose its mutexes or mutable containers. Worker requests
/// copy coordinate configuration; only immutable CPU metadata crosses threads.
/// Draw runs on the render thread and borrows meshes from the legacy registry.
class ChunkMeshDraw
{
public:
	ChunkMeshDraw();
	~ChunkMeshDraw();
	ChunkMeshDraw(const ChunkMeshDraw &) = delete;
	ChunkMeshDraw	  &operator=(const ChunkMeshDraw &) = delete;
	void			   RefreshMetadata(uint64_t inKey);
	void			   InvalidateMetadata();
	void			   EraseMetadata(uint64_t inKey);
	void			   ClearMetadata();
	void			   SetHidden(uint64_t inKey, bool inHidden);
	void			   ForgetHidden(uint64_t inKey);
	void			   ClearHidden();
	bool			   StartWorker();
	void			   StopWorker();
	ChunkMeshDrawStats GetStats() const;
	uint64_t		   GetMetadataEpoch() const;
	bool			   Draw(const NativeDrawView &inView, int inPass, NativeDrawResult &outResult);
	bool			   DrawChunk(int inX, int inY, int inZ, int inPass);

private:
	struct State;
	std::unique_ptr<State> mState;
};
ChunkMeshDraw &GetChunkMeshDraw();
} // namespace mcmesh::meshbuild
