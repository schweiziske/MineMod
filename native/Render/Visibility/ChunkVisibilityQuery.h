#pragma once
#include "Render/Visibility/ChunkVisibilityTypes.h"

namespace mcmesh::meshbuild
{
/// Compatibility section culling on immutable CPU values. Coordinate dimensions
/// and scale come from the captured view; never reads the active engine/world.
std::shared_ptr<NativeCullFrame> BuildChunkCullFrame(const NativeDrawView &inView, uint64_t inSerial,
													 const std::vector<DrawChunkMetadata> &inMetadata);
} // namespace mcmesh::meshbuild
