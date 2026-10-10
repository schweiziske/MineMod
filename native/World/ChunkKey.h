#pragma once
#include <cstdint>

namespace mcmesh::world
{
/// Compatibility chunk-key encoding: three biased 21-bit coordinates.
/// Callers validate the supported coordinate range before encoding.
inline uint64_t PackChunkKey(int inX, int inY, int inZ)
{
	const uint64_t x = uint64_t(uint32_t(inX + (1 << 20))) & 0x1FFFFF;
	const uint64_t y = uint64_t(uint32_t(inY + (1 << 20))) & 0x1FFFFF;
	const uint64_t z = uint64_t(uint32_t(inZ + (1 << 20))) & 0x1FFFFF;
	return x | (y << 21) | (z << 42);
}

inline void UnpackChunkKey(uint64_t inKey, int &outX, int &outY, int &outZ)
{
	outX = int(inKey & 0x1FFFFF) - (1 << 20);
	outY = int((inKey >> 21) & 0x1FFFFF) - (1 << 20);
	outZ = int((inKey >> 42) & 0x1FFFFF) - (1 << 20);
}
} // namespace mcmesh::world
