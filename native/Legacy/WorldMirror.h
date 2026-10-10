#pragma once

#include "Module/Pch.h"
#include "Legacy/LegacyContext.h"
#include "World/ChunkKey.h"

#include <unordered_map>
#include <memory>

namespace mcmesh::worldstate
{
struct ChunkMirror
{
	uint32_t stateId[mcmesh::kCellsPerChunk];
	uint8_t	 blockLight[mcmesh::kCellsPerChunk]{};
	uint8_t	 skyLight[mcmesh::kCellsPerChunk]{};
	uint64_t version = 0;
	bool	 lightValid = false;
};

struct Status
{
	// 上一次标脏数量
	int		 LastApplyDirty;
	uint64_t BatchCalls = 0, BatchCells = 0, SetCellCalls = 0;
	double	 BatchLastMS = 0, BatchTotalMS = 0, SetCellLastUs = 0, SetCellTotalMS = 0;
	uint64_t LightRebuilds = 0, LightSources = 0, LightProcessed = 0, LightWritten = 0;
	uint64_t SkySources = 0, SkyProcessed = 0, SkyWritten = 0;
	double	 LightLastMS = 0, SkyLastMS = 0;
	uint64_t IncrementalLightUpdates = 0, IncrementalLightCells = 0;
	uint64_t AsyncPartialCommits = 0, AsyncDeferredChunks = 0;
	double	 IncrementalLightLastMS = 0;
};

inline std::unordered_map<uint64_t, std::unique_ptr<ChunkMirror>> g_world;
inline uint64_t													  g_worldVersion = 0;
inline bool														  g_lightFieldReady = false;
inline std::unordered_map<uint64_t, uint64_t>					  g_dirtyMask;	// chunkKey -> section 位掩码
inline std::vector<uint64_t>									  g_dirtyQueue; // 入过队的 chunkKey, FIFO
inline Status													  g_status;

using world::PackChunkKey;
using world::UnpackChunkKey;

// 检查
inline bool ChunkCoordValid(double c)
{ // 敌意输入: 先验范围再打包
	return c == floor(c) && c >= -1000000 && c <= 1000000;
}

// 前 3 个栈位读 chunk 坐标, 敌意输入校验; 失败返回 false 不动任何状态
static bool ReadChunkCoords(GarrysMod::Lua::ILuaBase *LUA, int &cx, int &cy, int &cz)
{
	for (int i = 1; i <= 3; ++i)
		if (!LUA->IsType(i, GarrysMod::Lua::Type::Number))
			return false;
	const double x = LUA->GetNumber(1), y = LUA->GetNumber(2), z = LUA->GetNumber(3);
	if (!ChunkCoordValid(x) || !ChunkCoordValid(y) || !ChunkCoordValid(z))
		return false;
	cx = int(x);
	cy = int(y);
	cz = int(z);
	return true;
}

// 将方块在chunk的局部坐标转换为所在的Section的Index
inline int SectionIndex(int lx, int ly, int lz)
{
	return (lx / g_promise.SS) + (ly / g_promise.SS) * g_promise.NSX + (lz / g_promise.SS) * g_promise.NSX * g_promise.NSX;
}

// 返回"是否新置位", ApplyChunk 用它累计 lastApplyDirty
static bool MarkSectionDirty(uint64_t chunkKey, int sx, int sy, int sz)
{
	auto		   g_nsx = g_promise.NSX;
	const int	   idx = sx + sy * g_nsx + sz * g_nsx * g_nsx;
	uint64_t	  &mask = g_dirtyMask[chunkKey];
	const uint64_t bit = 1ull << idx;
	if (mask & bit)
		return false;
	if (mask == 0)
		g_dirtyQueue.push_back(chunkKey); // 掩码 0->非0 才入队
	mask |= bit;
	return true;
}

static int MarkCellAndNeighborsDirty(int cx, int cy, int cz, int lx, int ly, int lz)
{
	const int ss = g_promise.SS, cs = g_promise.CS, ch = g_promise.CH;
	const int baseWX = cx * cs + lx, baseWY = cy * cs + ly, baseWZ = cz * ch + lz;
	int		  added = 0;
	// Conservative Chebyshev radius two. Mapping each influenced world cell
	// to a section naturally deduplicates within and across chunk borders.
	for (int dz = -2; dz <= 2; ++dz)
		for (int dy = -2; dy <= 2; ++dy)
			for (int dx = -2; dx <= 2; ++dx)
			{
				int			   wx = baseWX + dx, wy = baseWY + dy, wz = baseWZ + dz;
				int			   ncx = int(std::floor(double(wx) / cs)), ncy = int(std::floor(double(wy) / cs)), ncz = int(std::floor(double(wz) / ch));
				int			   nlx = wx - ncx * cs, nly = wy - ncy * cs, nlz = wz - ncz * ch;
				const uint64_t key = PackChunkKey(ncx, ncy, ncz);
				if (g_world.find(key) == g_world.end())
					continue;
				if (MarkSectionDirty(key, nlx / ss, nly / ss, nlz / ss))
					++added;
			}
	return added;
}

static inline int PopCount64(uint64_t v) // 手写, 避开 win32 没有 __popcnt64 的坑
{
	int n = 0;
	while (v)
	{
		v &= v - 1;
		++n;
	}
	return n;
}

static int MarkWholeChunkDirty(uint64_t chunkKey)
{
	const uint64_t all = (g_promise.SPC >= 64)
							 ? ~0ull
							 : ((1ull << g_promise.SPC) - 1);
	uint64_t	  &mask = g_dirtyMask[chunkKey];
	if (mask == 0 && all != 0)
		g_dirtyQueue.push_back(chunkKey);
	const int added = PopCount64(all & ~mask);
	mask |= all;
	return added;
}

// 邻 chunk 面向 (指定轴 sideSection 那一层) 的整排 section 标脏。
// 只对已镜像的邻居生效; 返回新增脏位数。
static int MarkNeighborFacePlaneDirty(int ncx, int ncy, int ncz, int axis, int sideSection)
{
	const uint64_t nkey = PackChunkKey(ncx, ncy, ncz);
	if (g_world.find(nkey) == g_world.end())
		return 0;
	int added = 0;
	if (axis == 0)
	{
		for (int sy = 0; sy < g_promise.NSX; ++sy)
			for (int sz = 0; sz < g_promise.NSZ; ++sz)
				if (MarkSectionDirty(nkey, sideSection, sy, sz))
					added++;
	}
	else if (axis == 1)
	{
		for (int sx = 0; sx < g_promise.NSX; ++sx)
			for (int sz = 0; sz < g_promise.NSZ; ++sz)
				if (MarkSectionDirty(nkey, sx, sideSection, sz))
					added++;
	}
	else
	{
		for (int sx = 0; sx < g_promise.NSX; ++sx)
			for (int sy = 0; sy < g_promise.NSX; ++sy)
				if (MarkSectionDirty(nkey, sx, sy, sideSection))
					added++;
	}
	return added;
}

// Chunk arrival/removal affects every loaded neighbour whose section bounds
// intersect the two-cell dependency halo, including edges and corners.
static int MarkNeighborsOfChunkDirty(int cx, int cy, int cz)
{
	int added = 0;
	for (int dz = -1; dz <= 1; ++dz)
		for (int dy = -1; dy <= 1; ++dy)
			for (int dx = -1; dx <= 1; ++dx)
			{
				if (!dx && !dy && !dz)
					continue;
				const uint64_t key = PackChunkKey(cx + dx, cy + dy, cz + dz);
				if (g_world.find(key) == g_world.end())
					continue;
				const int sx0 = dx > 0 ? 0 : (dx < 0 ? g_promise.NSX - 1 : 0), sx1 = dx ? sx0 : g_promise.NSX - 1;
				const int sy0 = dy > 0 ? 0 : (dy < 0 ? g_promise.NSX - 1 : 0), sy1 = dy ? sy0 : g_promise.NSX - 1;
				const int sz0 = dz > 0 ? 0 : (dz < 0 ? g_promise.NSZ - 1 : 0), sz1 = dz ? sz0 : g_promise.NSZ - 1;
				for (int sz = sz0; sz <= sz1; ++sz)
					for (int sy = sy0; sy <= sy1; ++sy)
						for (int sx = sx0; sx <= sx1; ++sx)
							if (MarkSectionDirty(key, sx, sy, sz))
								++added;
			}
	return added;
}

bool ApplyDenseStates(int cx, int cy, int cz, const uint32_t *states);
int	 ApplyChunk(GarrysMod::Lua::ILuaBase *LUA);
int	 CreateChunk(GarrysMod::Lua::ILuaBase *LUA);
int	 ApplyChunkCells(GarrysMod::Lua::ILuaBase *LUA);
int	 SetCell(GarrysMod::Lua::ILuaBase *LUA);
int	 GetCell(GarrysMod::Lua::ILuaBase *LUA);
int	 GetChunkCells(GarrysMod::Lua::ILuaBase *LUA);
int	 RebuildBlockLight(GarrysMod::Lua::ILuaBase *LUA);
int	 GetBlockLightChunk(GarrysMod::Lua::ILuaBase *LUA);
int	 GetSkyLightChunk(GarrysMod::Lua::ILuaBase *LUA);
int	 GetLightingHalo(GarrysMod::Lua::ILuaBase *LUA);
int	 GetChunkLightTile(GarrysMod::Lua::ILuaBase *LUA);
int	 StartBlockLightRebuild(GarrysMod::Lua::ILuaBase *LUA);
int	 PollBlockLightRebuild(GarrysMod::Lua::ILuaBase *LUA);
int	 CancelBlockLightRebuild(GarrysMod::Lua::ILuaBase *LUA);
void StopBlockLightWorker();
int	 UnloadChunk(GarrysMod::Lua::ILuaBase *LUA);
int	 ClearWorld(GarrysMod::Lua::ILuaBase *LUA);

int GetStats(GarrysMod::Lua::ILuaBase *LUA);
} // namespace mcmesh::worldstate
