#include "Module/Pch.h"
#include "Legacy/PatchDecoder.h"
#include "Legacy/ChunkMeshBuilder.h"
#include "Legacy/ChunkMeshDraw.h"
#include "Legacy/ChunkMeshWorker.h"
#include "Legacy/LightAtlas.h"
#include "Legacy/BlockDefinitions.h"
#include "Legacy/WorldMirror.h"
#include "Legacy/BlobFormat.h"
#include "Legacy/BlockEmitters.h"

#include "tier0/platform.h"

#include <array>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <limits>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>

#include "mathlib/vmatrix.h"

using namespace GarrysMod::Lua;
using namespace mcmesh;
namespace ws = mcmesh::worldstate;

namespace
{
struct FaceCorner
{
	float ox, oy, oz;
	int	  uf, vf;
};
struct FaceDef
{
	float	   nx, ny, nz;
	int		   ox, oy, oz;
	FaceCorner c[4];
};

// cl_mesh_constants.lua:39-46，顺序 TOP,BOTTOM,XP,XN,YP,YN。
static const FaceDef FACES[6] = {
	{0, 0, 1, 0, 0, 1, {{0, 0, 1, 0, 1}, {1, 0, 1, 1, 1}, {1, 1, 1, 1, 0}, {0, 1, 1, 0, 0}}},
	{0, 0, -1, 0, 0, -1, {{0, 1, 0, 0, 1}, {1, 1, 0, 1, 1}, {1, 0, 0, 1, 0}, {0, 0, 0, 0, 0}}},
	{1, 0, 0, 1, 0, 0, {{1, 0, 0, 0, 1}, {1, 1, 0, 1, 1}, {1, 1, 1, 1, 0}, {1, 0, 1, 0, 0}}},
	{-1, 0, 0, -1, 0, 0, {{0, 1, 0, 0, 1}, {0, 0, 0, 1, 1}, {0, 0, 1, 1, 0}, {0, 1, 1, 0, 0}}},
	{0, 1, 0, 0, 1, 0, {{1, 1, 0, 0, 1}, {0, 1, 0, 1, 1}, {0, 1, 1, 1, 0}, {1, 1, 1, 0, 0}}},
	{0, -1, 0, 0, -1, 0, {{0, 0, 0, 0, 1}, {1, 0, 0, 1, 1}, {1, 0, 1, 1, 0}, {0, 0, 1, 0, 0}}},
};

static const int TRI[6] = {0, 2, 1, 0, 3, 2};

inline void RotatedUVFlags(int uf, int vf, int rot, bool flipU, bool flipV, int &ou, int &ov)
{
	rot &= 3;
	if (rot == 1)
	{
		int nu = vf, nv = 1 - uf;
		uf = nu;
		vf = nv;
	}
	else if (rot == 2)
	{
		uf = 1 - uf;
		vf = 1 - vf;
	}
	else if (rot == 3)
	{
		int nu = 1 - vf, nv = uf;
		uf = nu;
		vf = nv;
	}
	if (flipU)
		uf = 1 - uf;
	if (flipV)
		vf = 1 - vf;
	ou = uf;
	ov = vf;
}

inline void TileUV(int tile, double &u0, double &v0, double &u1, double &v1)
{
	const auto	&A = blockdefs::g_atlas;
	const auto	 region = blockdefs::RegionForTile(A, uint16_t(tile));
	const double px0 = region.x;
	const double py0 = region.y;
	const double inset = A.inset;
	u0 = (px0 + inset) / A.w;
	v0 = (py0 + inset) / A.h;
	u1 = (px0 + region.w - inset) / A.w;
	v1 = (py0 + region.h - inset) / A.h;
}

inline bool FaceVisible(uint16_t curId, uint16_t nbId, uint8_t nbOrient)
{
	if (nbId == 0)
		return true;
	const blockdefs::BlockDef *nd = blockdefs::FindDef(nbId);
	if (!nd)
		return true;
	if (nd->flags & blockdefs::FLAG_TRANSPARENT)
		return nbId != curId;
	if (!blockdefs::OrientFullCube(nd, nbOrient))
		return true;
	return false;
}

inline int PopCount64(uint64_t v)
{
	int n = 0;
	while (v)
	{
		v &= v - 1;
		++n;
	}
	return n;
}

inline int LowestSetBit(uint64_t mask)
{
	int bit = 0;
	while ((mask & 1) == 0)
	{
		mask >>= 1;
		++bit;
	}
	return bit;
}

inline bool Ready()
{
	auto defsLock = blockdefs::LockForRead();
	return g_promise.SS > 0 && blockdefs::g_loaded;
}

using GenerationArray = std::array<uint64_t, 64>;
std::unordered_map<uint64_t, GenerationArray> g_generations;
uint64_t									  g_nextGeneration = 0;
std::deque<mcmesh::meshworker::Result>		  g_readyResults;

bool DirtyBitSet(uint64_t key, int sec)
{
	auto it = ws::g_dirtyMask.find(key);
	return it != ws::g_dirtyMask.end() && (it->second & (1ull << sec)) != 0;
}

bool GenerationMatches(uint64_t key, int sec, uint64_t generation)
{
	auto it = g_generations.find(key);
	return it != g_generations.end() && it->second[sec] == generation;
}

int PushThinkResult(ILuaBase *LUA, size_t pending, int committed)
{
	LUA->CreateTable();
	LUA->PushNumber((double)pending);
	LUA->SetField(-2, "pending");
	LUA->PushNumber((double)committed);
	LUA->SetField(-2, "committed");
	if (mcmesh::meshbuild::g_detailedProfile.enabled && mcmesh::meshbuild::g_detailedProfile.latest.sequence != 0)
	{
		const auto &p = mcmesh::meshbuild::g_detailedProfile.latest;
		LUA->CreateTable();
#define MC_PROFILE_NUMBER(name, value) \
	LUA->PushNumber((double)(value));  \
	LUA->SetField(-2, name)
		MC_PROFILE_NUMBER("sequence", p.sequence);
		MC_PROFILE_NUMBER("budgetMS", p.budgetMS);
		MC_PROFILE_NUMBER("totalUs", p.totalUs);
		MC_PROFILE_NUMBER("budgetOverrunUs", p.budgetOverrunUs);
		MC_PROFILE_NUMBER("workerStartUs", p.workerStartUs);
		MC_PROFILE_NUMBER("collectUs", p.collectUs);
		MC_PROFILE_NUMBER("finalizeUs", p.finalizeUs);
		MC_PROFILE_NUMBER("queueWaitUs", p.queueWaitUs);
		MC_PROFILE_NUMBER("stageUs", p.stageUs);
		MC_PROFILE_NUMBER("allocateUs", p.allocateUs);
		MC_PROFILE_NUMBER("uploadUs", p.uploadUs);
		MC_PROFILE_NUMBER("replaceUs", p.replaceUs);
		MC_PROFILE_NUMBER("destroyUs", p.destroyUs);
		MC_PROFILE_NUMBER("dirtyScanUs", p.dirtyScanUs);
		MC_PROFILE_NUMBER("captureUs", p.captureUs);
		MC_PROFILE_NUMBER("enqueueUs", p.enqueueUs);
		MC_PROFILE_NUMBER("resultsCollected", p.resultsCollected);
		MC_PROFILE_NUMBER("resultsVisited", p.resultsVisited);
		MC_PROFILE_NUMBER("committed", p.committed);
		MC_PROFILE_NUMBER("stale", p.stale);
		MC_PROFILE_NUMBER("failed", p.failed);
		MC_PROFILE_NUMBER("captureAttempts", p.captureAttempts);
		MC_PROFILE_NUMBER("captureSuccess", p.captureSuccess);
		MC_PROFILE_NUMBER("enqueueAttempts", p.enqueueAttempts);
		MC_PROFILE_NUMBER("enqueueSuccess", p.enqueueSuccess);
		MC_PROFILE_NUMBER("enqueueRejected", p.enqueueRejected);
		MC_PROFILE_NUMBER("meshesCreated", p.meshesCreated);
		MC_PROFILE_NUMBER("meshesDestroyed", p.meshesDestroyed);
		MC_PROFILE_NUMBER("batchesUploaded", p.batchesUploaded);
		MC_PROFILE_NUMBER("verticesUploaded", p.verticesUploaded);
		MC_PROFILE_NUMBER("bytesUploaded", p.bytesUploaded);
		MC_PROFILE_NUMBER("dirtyBefore", p.dirtyBefore);
		MC_PROFILE_NUMBER("dirtyAfter", p.dirtyAfter);
		MC_PROFILE_NUMBER("workerJobsBefore", p.workerJobsBefore);
		MC_PROFILE_NUMBER("workerJobsAfter", p.workerJobsAfter);
		MC_PROFILE_NUMBER("workerActiveBefore", p.workerActiveBefore);
		MC_PROFILE_NUMBER("workerActiveAfter", p.workerActiveAfter);
		MC_PROFILE_NUMBER("workerResultsBefore", p.workerResultsBefore);
		MC_PROFILE_NUMBER("workerResultsAfter", p.workerResultsAfter);
		MC_PROFILE_NUMBER("readyBefore", p.readyBefore);
		MC_PROFILE_NUMBER("readyAfter", p.readyAfter);
		MC_PROFILE_NUMBER("outstandingBefore", p.outstandingBefore);
		MC_PROFILE_NUMBER("outstandingAfter", p.outstandingAfter);
		MC_PROFILE_NUMBER("resultBytesBefore", p.resultBytesBefore);
		MC_PROFILE_NUMBER("resultBytesAfter", p.resultBytesAfter);
#undef MC_PROFILE_NUMBER
		LUA->SetField(-2, "profile");
	}
	if (mcmesh::meshbuild::g_faulted)
	{
		LUA->PushBool(true);
		LUA->SetField(-2, "failed");
		LUA->PushString(mcmesh::meshbuild::g_faultReason);
		LUA->SetField(-2, "fault");
	}
	return 1;
}
} // namespace

namespace mcmesh::meshbuild
{
static void RecordTime(TimeProfile &profile, double us)
{
	if (!std::isfinite(us) || us < 0)
		us = 0;
	++profile.calls;
	profile.lastUs = us;
	profile.totalUs += us;
	if (us > profile.maxUs)
		profile.maxUs = us;
}

static void MergeTimeProfile(TimeProfile &destination, const TimeProfile &source)
{
	if (source.calls == 0)
		return;
	destination.calls += source.calls;
	destination.lastUs = source.lastUs;
	destination.totalUs += source.totalUs;
	destination.maxUs = std::max(destination.maxUs, source.maxUs);
}

static size_t DirtySectionCount()
{
	size_t dirty = 0;
	for (const auto &kv : ws::g_dirtyMask)
		dirty += (size_t)PopCount64(kv.second);
	return dirty;
}

static void ResetDetailedProfile()
{
	const bool	   enabled = g_detailedProfile.enabled;
	const uint64_t generation = g_detailedProfile.generation + 1;
	g_detailedProfile = DetailedProfileState{};
	g_detailedProfile.enabled = enabled;
	g_detailedProfile.generation = generation == 0 ? 1 : generation;
	g_activeThinkProfile = nullptr;
}

static void RecordDetailedTime(TimeProfile &profile, double us)
{
	if (g_detailedProfile.enabled)
		RecordTime(profile, us);
}

static void RecordOperation(const char *kind, double us, TimeProfile &profile)
{
	if (!g_detailedProfile.enabled)
		return;
	RecordTime(profile, us);
	++g_detailedProfile.operationSequence;
	g_detailedProfile.lastOperation = kind;
	g_detailedProfile.lastOperationUs = std::isfinite(us) && us >= 0 ? us : 0;
}

bool CaptureSectionSnapshot(uint64_t chunkKey, int sec, SectionSnapshot &out)
{
	if (g_promise.SS <= 0 || sec < 0 || sec >= g_promise.SPC)
		return false;
	if (ws::g_world.find(chunkKey) == ws::g_world.end())
		return false;

	const int cs = g_promise.CS;
	const int ch = g_promise.CH;
	const int ss = g_promise.SS;
	const int nsx = g_promise.NSX;
	const int sx = sec % nsx;
	const int sy = (sec / nsx) % nsx;
	const int sz = sec / (nsx * nsx);

	out.section = sec;
	out.coreSize = ss;
	out.halo = 2;
	out.side = ss + 4;
	out.lx0 = sx * ss;
	out.ly0 = sy * ss;
	out.lz0 = sz * ss;
	const size_t cellCount = size_t(out.side) * size_t(out.side) * size_t(out.side);
	out.cells.assign(cellCount, SnapshotCell{});

	int cx, cy, cz;
	ws::UnpackChunkKey(chunkKey, cx, cy, cz);
	out.cx = cx;
	out.cy = cy;
	out.cz = cz;

	lightatlas::SlotRef lightSlot;
	if (!lightatlas::EnsureChunkSlot(chunkKey, lightSlot) || !lightatlas::EnsureChunkTileUploaded(chunkKey, lightSlot.slot, lightSlot.generation))
		return false;
	out.lightSlot = lightSlot.slot;
	out.lightGeneration = lightSlot.generation;

	for (int z = 0; z < out.side; ++z)
		for (int y = 0; y < out.side; ++y)
			for (int x = 0; x < out.side; ++x)
			{
				int lx = out.lx0 + x - out.halo;
				int ly = out.ly0 + y - out.halo;
				int lz = out.lz0 + z - out.halo;
				int ncx = cx, ncy = cy, ncz = cz;
				if (lx < 0)
				{
					--ncx;
					lx += cs;
				}
				else if (lx >= cs)
				{
					++ncx;
					lx -= cs;
				}
				if (ly < 0)
				{
					--ncy;
					ly += cs;
				}
				else if (ly >= cs)
				{
					++ncy;
					ly -= cs;
				}
				if (lz < 0)
				{
					--ncz;
					lz += ch;
				}
				else if (lz >= ch)
				{
					++ncz;
					lz -= ch;
				}

				auto wit = ws::g_world.find(ws::PackChunkKey(ncx, ncy, ncz));
				if (wit == ws::g_world.end())
					continue;
				const int	  li = lx + ly * cs + lz * cs * cs;
				SnapshotCell &cell = out.cells[size_t(x) + size_t(y) * out.side + size_t(z) * out.side * out.side];
				cell.stateId = wit->second->stateId[li];
				const blockdefs::StateDef *stateDef = blockdefs::FindState(cell.stateId);
				if (cell.stateId != 0 && !stateDef)
					return false;
				if (stateDef)
				{
					cell.id = stateDef->blockId;
					cell.orient = stateDef->orient;
				}
			}
	return true;
}

static bool CellOccludesSection(const SnapshotCell &cell)
{
	if (cell.stateId == 0 || cell.id == 0)
		return false;
	const blockdefs::BlockDef *definition = blockdefs::FindDef(cell.id);
	return definition && blockdefs::IsSolid(definition) && !blockdefs::IsTransparent(definition) && blockdefs::OrientFullCube(definition, cell.orient);
}

static SectionOcclusion BuildSectionOcclusion(const SectionSnapshot &snapshot)
{
	SectionOcclusion result;
	const int		 size = snapshot.coreSize;
	if (size <= 0 || snapshot.side != size + snapshot.halo * 2)
		return result;
	const int			 plane = size * size;
	const int			 volume = plane * size;
	std::vector<uint8_t> open(size_t(volume), 0);
	int					 occluders = 0;
	for (int z = 0; z < size; ++z)
		for (int y = 0; y < size; ++y)
			for (int x = 0; x < size; ++x)
			{
				const size_t snapshotIndex = size_t(x + snapshot.halo) + size_t(y + snapshot.halo) * snapshot.side + size_t(z + snapshot.halo) * snapshot.side * snapshot.side;
				const int	 localIndex = x + y * size + z * plane;
				const bool	 passable = !CellOccludesSection(snapshot.cells[snapshotIndex]);
				open[size_t(localIndex)] = passable ? 1 : 0;
				if (!passable)
					++occluders;
			}

	result.ready = true;
	if (occluders < plane)
	{
		result.visibleFrom.fill(kAllSectionFaces);
		return result;
	}
	if (occluders == volume)
		return result;

	std::vector<uint8_t> visited(size_t(volume), 0);
	std::vector<int>	 queue;
	queue.reserve(size_t(volume));
	for (int start = 0; start < volume; ++start)
	{
		if (!open[size_t(start)] || visited[size_t(start)])
			continue;
		const int startZ = start / plane;
		const int startRemainder = start - startZ * plane;
		const int startY = startRemainder / size;
		const int startX = startRemainder - startY * size;
		if (startX != 0 && startX != size - 1 && startY != 0 && startY != size - 1 && startZ != 0 && startZ != size - 1)
			continue;

		queue.clear();
		queue.push_back(start);
		visited[size_t(start)] = 1;
		uint8_t touchedFaces = 0;
		for (size_t head = 0; head < queue.size(); ++head)
		{
			const int index = queue[head];
			const int z = index / plane;
			const int remainder = index - z * plane;
			const int y = remainder / size;
			const int x = remainder - y * size;
			if (z == size - 1)
				touchedFaces |= 1u << 0;
			if (z == 0)
				touchedFaces |= 1u << 1;
			if (x == size - 1)
				touchedFaces |= 1u << 2;
			if (x == 0)
				touchedFaces |= 1u << 3;
			if (y == size - 1)
				touchedFaces |= 1u << 4;
			if (y == 0)
				touchedFaces |= 1u << 5;

			for (int direction = 0; direction < 6; ++direction)
			{
				const int nx = x + FACES[direction].ox;
				const int ny = y + FACES[direction].oy;
				const int nz = z + FACES[direction].oz;
				if (nx < 0 || nx >= size || ny < 0 || ny >= size || nz < 0 || nz >= size)
					continue;
				const int neighbor = nx + ny * size + nz * plane;
				if (!open[size_t(neighbor)] || visited[size_t(neighbor)])
					continue;
				visited[size_t(neighbor)] = 1;
				queue.push_back(neighbor);
			}
		}
		for (int face = 0; face < 6; ++face)
			if (touchedFaces & (1u << face))
				result.visibleFrom[face] |= touchedFaces;
	}
	return result;
}

bool BuildSectionVerts(const SectionSnapshot &snapshot, SectionBuild &out)
{
	out = SectionBuild{};
	out.lightSlot = snapshot.lightSlot;
	out.lightGeneration = snapshot.lightGeneration;
	if (snapshot.coreSize <= 0 || snapshot.halo != 2 || snapshot.side != snapshot.coreSize + 4)
	{
		out.ok = false;
		return false;
	}
	const size_t side = size_t(snapshot.side);
	if (side > 64 || snapshot.cells.size() != side * side * side)
	{
		out.ok = false;
		return false;
	}
	auto lock = blockdefs::LockForRead();
	if (!blockdefs::g_loaded || blockdefs::g_atlasPages.empty() || !blockdefs::g_atlas.valid || g_promise.AtlasMaterials.size() < blockdefs::g_atlasPages.size())
	{
		out.ok = false;
		return false;
	}
	out.occlusion = BuildSectionOcclusion(snapshot);
	try
	{
		out.ok = emitters::Build(snapshot, out);
	}
	catch (...)
	{
		out.ok = false;
	}
	return out.ok;
}

enum class MeshCreateStatus
{
	Empty,
	Created,
	Failed
};
struct MeshCreateResult
{
	MeshCreateStatus status = MeshCreateStatus::Failed;
	IMesh			*mesh = nullptr;
};

static MeshCreateResult CreateMeshFromBatch(IMatRenderContext *ctx, const VertexBatch &batch,
											IMaterial *mat, MeshDirectionalRanges &ranges, MeshStageStats *stats)
{
	ranges = MeshDirectionalRanges{};
	if (batch.vertices == 0)
		return {MeshCreateStatus::Empty, nullptr};
	if (batch.vertices > mcmesh::MAX_VERTEX_COUNT || (batch.vertices % 3) != 0)
		return {MeshCreateStatus::Failed, nullptr};
	size_t verifiedVertices = 0;
	for (const auto &group : batch.groups)
	{
		if ((group.size() % 3) != 0)
			return {MeshCreateStatus::Failed, nullptr};
		verifiedVertices += group.size();
	}
	if (verifiedVertices != batch.vertices)
		return {MeshCreateStatus::Failed, nullptr};
	if (!source::SupportsNativeMeshVertexFormat(mat))
		return {MeshCreateStatus::Failed, nullptr};
	if (!ctx)
		return {MeshCreateStatus::Failed, nullptr};

	const VertexFormat_t fmt = mat->GetVertexFormat();
	const double		 allocateT0 = stats ? Plat_FloatTime() : 0.0;
	IMesh				*mesh = ctx->CreateStaticMesh(fmt & ~VERTEX_FORMAT_COMPRESSED,
													  TEXTURE_GROUP_STATIC_VERTEX_BUFFER_OTHER, mat);
	if (stats)
		RecordTime(stats->allocate, (Plat_FloatTime() - allocateT0) * 1e6);
	if (!mesh)
		return {MeshCreateStatus::Failed, nullptr};

	const double uploadT0 = stats ? Plat_FloatTime() : 0.0;
	CMeshBuilder mb;
	mb.Begin(mesh, MATERIAL_TRIANGLES, (int)(batch.vertices / 3));
	int firstIndex = 0;
	for (int groupIndex = 0; groupIndex < kDirectionalGroupCount; ++groupIndex)
	{
		const auto &group = batch.groups[groupIndex];
		ranges.groups[groupIndex] = {firstIndex, (int)group.size()};
		for (const Vert &v : group)
		{
			mb.Position3f(v.pos[0], v.pos[1], v.pos[2]);
			mb.Normal3f(v.normal[0], v.normal[1], v.normal[2]);
			mb.TexCoord2f(0, v.u, v.v);
			mb.TexCoord2f(1, 0.0f, 0.0f);
			mb.Color4ub(v.rgba[0], v.rgba[1], v.rgba[2], v.rgba[3]);
			mb.AdvanceVertex();
		}
		firstIndex += (int)group.size();
	}
	mb.End();
	ranges.vertices = (int)batch.vertices;
	if (stats)
	{
		RecordTime(stats->upload, (Plat_FloatTime() - uploadT0) * 1e6);
		++stats->meshesCreated;
		++stats->batchesUploaded;
		stats->verticesUploaded += (uint64_t)batch.vertices;
		stats->bytesUploaded += (uint64_t)batch.vertices * sizeof(Vert);
	}
	return {MeshCreateStatus::Created, mesh};
}

static void DestroyMesh(IMatRenderContext *ctx, IMesh *&mesh, bool recordProfile)
{
	if (!mesh)
		return;
	const double t0 = recordProfile && g_detailedProfile.enabled ? Plat_FloatTime() : 0.0;
	if (ctx)
		ctx->DestroyStaticMesh(mesh);
	if (recordProfile && g_detailedProfile.enabled)
	{
		const double us = (Plat_FloatTime() - t0) * 1e6;
		RecordTime(g_detailedProfile.destroy, us);
		++g_detailedProfile.meshesDestroyed;
		if (g_activeThinkProfile)
		{
			g_activeThinkProfile->destroyUs += us;
			++g_activeThinkProfile->meshesDestroyed;
		}
	}
	mesh = nullptr;
}

static bool CreateMeshList(IMatRenderContext *ctx, const PassVerts &pass, bool translucent,
						   std::vector<IMesh *> &out, std::vector<IMaterial *> &outMaterials,
						   std::vector<MeshDirectionalRanges> &outRanges, MeshStageStats *stats)
{
	if (!ctx)
		return false;
	for (size_t page = 0; page < pass.pages.size(); ++page)
	{
		if (page >= g_promise.AtlasMaterials.size())
			return false;
		IMaterial *material = translucent
								  ? g_promise.AtlasMaterials[page].MatTranslucent
								  : g_promise.AtlasMaterials[page].MatOpaque;
		if (!source::SupportsNativeMeshVertexFormat(material))
			return false;
		for (const auto &batch : pass.pages[page].batches)
		{
			MeshDirectionalRanges ranges;
			MeshCreateResult	  made = CreateMeshFromBatch(ctx, batch, material, ranges, stats);
			if (made.status == MeshCreateStatus::Failed)
			{
				for (IMesh *&m : out)
					DestroyMesh(ctx, m, false);
				out.clear();
				outMaterials.clear();
				outRanges.clear();
				return false;
			}
			if (made.mesh)
			{
				out.push_back(made.mesh);
				outMaterials.push_back(material);
				outRanges.push_back(ranges);
			}
		}
	}
	return out.size() == outMaterials.size() && out.size() == outRanges.size();
}
static void DestroyMeshList(IMatRenderContext *ctx, std::vector<IMesh *> &list, bool recordProfile = true)
{
	for (IMesh *&m : list)
		DestroyMesh(ctx, m, recordProfile);
	list.clear();
}
static void SubtractEmitterStats(EmitterStats &total, const EmitterStats &part)
{
	for (size_t i = 0; i < 6; ++i)
	{
		total.blocks[i] = part.blocks[i] > total.blocks[i] ? 0 : total.blocks[i] - part.blocks[i];
		total.faces[i] = part.faces[i] > total.faces[i] ? 0 : total.faces[i] - part.faces[i];
	}
}
bool StageSectionMeshes(const SectionBuild &build, SectionMeshes &staged, MeshStageStats *stats)
{
	staged = SectionMeshes{};
	if (!source::GetMaterialSystem())
		return false;
	CMatRenderContextPtr ctx(source::GetMaterialSystem());
	if (!ctx)
		return false;
	try
	{
		if (!CreateMeshList(ctx, build.opaque, false, staged.opaque, staged.opaqueMaterials, staged.opaqueRanges, stats) || !CreateMeshList(ctx, build.translucent, true, staged.translucent, staged.translucentMaterials, staged.translucentRanges, stats) || (build.lodReady && !CreateMeshList(ctx, build.lodOpaque, false, staged.lodOpaque, staged.lodOpaqueMaterials, staged.lodOpaqueRanges, stats)))
		{
			DestroyMeshList(ctx, staged.opaque, false);
			DestroyMeshList(ctx, staged.translucent, false);
			DestroyMeshList(ctx, staged.lodOpaque, false);
			staged = SectionMeshes{};
			return false;
		}
		staged.opaqueVerts = (int)build.opaque.vertices;
		staged.translucentVerts = (int)build.translucent.vertices;
		staged.lodOpaqueVerts = (int)build.lodOpaque.vertices;
		staged.lodReady = build.lodReady;
		staged.lightSlot = build.lightSlot;
		staged.lightGeneration = build.lightGeneration;
		staged.emitters = build.emitters;
		staged.occlusion = build.occlusion;
		return true;
	}
	catch (...)
	{
		DestroyMeshList(ctx, staged.opaque, false);
		DestroyMeshList(ctx, staged.translucent, false);
		DestroyMeshList(ctx, staged.lodOpaque, false);
		staged = SectionMeshes{};
		return false;
	}
}

void DestroyStagedSectionMeshes(SectionMeshes &staged, bool recordProfile)
{
	if (staged.opaque.empty() && staged.translucent.empty() && staged.lodOpaque.empty())
	{
		staged = SectionMeshes{};
		return;
	}
	if (!source::GetMaterialSystem())
		return;
	CMatRenderContextPtr ctx(source::GetMaterialSystem());
	if (!ctx)
		return;
	DestroyMeshList(ctx, staged.opaque, recordProfile);
	DestroyMeshList(ctx, staged.translucent, recordProfile);
	DestroyMeshList(ctx, staged.lodOpaque, recordProfile);
	staged = SectionMeshes{};
}

bool CommitStagedSectionMeshes(uint64_t key, int sec, SectionMeshes &staged)
{
	const double commitT0 = Plat_FloatTime();
	try
	{
		// Publishing a mesh is also the atlas synchronization barrier.
		// Never expose a staged mesh whose slot was reassigned or whose
		// complete tile has not been uploaded yet.
		if (!lightatlas::EnsureChunkTileUploaded(key, staged.lightSlot, staged.lightGeneration))
			return false;
		auto		   inserted = g_meshes.try_emplace(key);
		SectionMeshes &live = inserted.first->second.section[sec];
		SectionMeshes  old = std::move(live);
		live = std::move(staged);
		SubtractEmitterStats(g_emitterStats, old.emitters);
		for (size_t i = 0; i < 6; ++i)
		{
			g_emitterStats.blocks[i] += live.emitters.blocks[i];
			g_emitterStats.faces[i] += live.emitters.faces[i];
		}
		RecordTime(g_meshCommitProfile, (Plat_FloatTime() - commitT0) * 1e6);
		if (g_detailedProfile.enabled)
		{
			const double us = (Plat_FloatTime() - commitT0) * 1e6;
			RecordTime(g_detailedProfile.replace, us);
			if (g_activeThinkProfile)
				g_activeThinkProfile->replaceUs += us;
		}
		const double destroyT0 = Plat_FloatTime();
		DestroyStagedSectionMeshes(old);
		RecordTime(g_meshDestroyProfile, (Plat_FloatTime() - destroyT0) * 1e6);
		GetChunkMeshDraw().RefreshMetadata(key);
		return true;
	}
	catch (...)
	{
		return false;
	}
}

void DestroyChunkMeshes(uint64_t chunkKey)
{
	auto it = g_meshes.find(chunkKey);
	if (it == g_meshes.end())
	{
		GetChunkMeshDraw().EraseMetadata(chunkKey);
		return;
	}
	if (!source::GetMaterialSystem())
	{
		GetChunkMeshDraw().EraseMetadata(chunkKey);
		return;
	}
	CMatRenderContextPtr ctx(source::GetMaterialSystem());
	if (!ctx)
	{
		GetChunkMeshDraw().EraseMetadata(chunkKey);
		return;
	}
	for (int i = 0; i < 64; ++i)
	{
		SubtractEmitterStats(g_emitterStats, it->second.section[i].emitters);
		DestroyMeshList(ctx, it->second.section[i].opaque);
		DestroyMeshList(ctx, it->second.section[i].translucent);
		DestroyMeshList(ctx, it->second.section[i].lodOpaque);
	}
	g_meshes.erase(it);
	GetChunkMeshDraw().EraseMetadata(chunkKey);
}

void DestroyAllMeshes()
{
	if (!source::GetMaterialSystem())
	{
		GetChunkMeshDraw().ClearMetadata();
		return;
	}
	CMatRenderContextPtr ctx(source::GetMaterialSystem());
	if (!ctx)
	{
		GetChunkMeshDraw().ClearMetadata();
		return;
	}
	for (auto &kv : g_meshes)
		for (int i = 0; i < 64; ++i)
		{
			SubtractEmitterStats(g_emitterStats, kv.second.section[i].emitters);
			DestroyMeshList(ctx, kv.second.section[i].opaque);
			DestroyMeshList(ctx, kv.second.section[i].translucent);
			DestroyMeshList(ctx, kv.second.section[i].lodOpaque);
		}
	g_meshes.clear();
	g_emitterStats = {};
	GetChunkMeshDraw().ClearMetadata();
}

void StopWorkers()
{
	const double operationT0 = g_detailedProfile.enabled ? Plat_FloatTime() : 0.0;
	GetChunkMeshDraw().StopWorker();
	meshworker::Stop();
	for (auto &result : g_readyResults)
		DestroyStagedSectionMeshes(result.stagedMeshes);
	g_readyResults.clear();
	g_generations.clear();
	if (g_detailedProfile.enabled)
		RecordTime(g_detailedProfile.workerStop, (Plat_FloatTime() - operationT0) * 1e6);
}

int Think(ILuaBase *LUA)
{
	if (!LUA->IsType(1, Type::Number))
	{
		LUA->PushBool(false);
		return 1;
	}
	double budgetMS = LUA->GetNumber(1);
	if (!std::isfinite(budgetMS) || budgetMS < 0 || budgetMS > 100)
	{
		LUA->PushBool(false);
		return 1;
	}
	if (!Ready())
		return PushThinkResult(LUA, 0, 0);
	if (g_faulted)
		return PushThinkResult(LUA, 0, 0);
	const double	   budgetSec = budgetMS / 1000.0;
	const double	   t0 = Plat_FloatTime();
	ThinkProfileSample sample;
	const bool		   profiling = g_detailedProfile.enabled;
	if (profiling)
	{
		sample.sequence = ++g_detailedProfile.nextThinkSequence;
		sample.budgetMS = budgetMS;
		sample.dirtyBefore = DirtySectionCount();
		const meshworker::Stats before = meshworker::GetStats();
		sample.workerJobsBefore = before.queuedJobs;
		sample.workerActiveBefore = before.activeJobs;
		sample.workerResultsBefore = before.queuedResults;
		sample.readyBefore = g_readyResults.size();
		sample.outstandingBefore = before.outstanding;
		sample.resultBytesBefore = before.resultBytes;
		g_activeThinkProfile = &sample;
	}

	const double workerStartT0 = profiling ? Plat_FloatTime() : 0.0;
	if (!meshworker::Start())
	{
		meshworker::Stop();
		g_faulted = true;
		g_faultReason = "worker_start_failed";
		g_activeThinkProfile = nullptr;
		return PushThinkResult(LUA, 0, 0);
	}
	if (!GetChunkMeshDraw().StartWorker())
	{
		meshworker::Stop();
		g_faulted = true;
		g_faultReason = "cull_worker_start_failed";
		g_activeThinkProfile = nullptr;
		return PushThinkResult(LUA, 0, 0);
	}
	if (profiling)
	{
		sample.workerStartUs = (Plat_FloatTime() - workerStartT0) * 1e6;
		RecordTime(g_detailedProfile.workerStart, sample.workerStartUs);
	}

	// Transfer ownership with a deque swap. No allocation can occur here, so
	// every outstanding/resultBytes reservation remains represented exactly once.
	const size_t readyBeforeCollect = g_readyResults.size();
	const double collectT0 = profiling ? Plat_FloatTime() : 0.0;
	meshworker::CollectResults(g_readyResults);
	if (profiling)
	{
		sample.collectUs = (Plat_FloatTime() - collectT0) * 1e6;
		sample.resultsCollected = g_readyResults.size() > readyBeforeCollect
									  ? (uint64_t)(g_readyResults.size() - readyBeforeCollect)
									  : 0;
		RecordTime(g_detailedProfile.collect, sample.collectUs);
	}

	int			 finalized = 0;
	const double finalizeT0 = profiling ? Plat_FloatTime() : 0.0;
	while (!g_readyResults.empty())
	{
		if (finalized > 0 && (Plat_FloatTime() - t0) >= budgetSec)
			break;
		meshworker::Result &result = g_readyResults.front();
		if (profiling)
		{
			++sample.resultsVisited;
			sample.queueWaitUs += result.queueWaitUs;
			RecordTime(g_detailedProfile.queueWait, result.queueWaitUs);
		}
		RecordTime(g_vertexBuildProfile, result.vertexBuildUs);
		if constexpr (meshworker::kWorkerCreatesMeshes)
		{
			RecordTime(g_meshStageProfile, result.meshStageUs);
			if (profiling)
			{
				sample.stageUs += result.meshStageUs;
				RecordTime(g_detailedProfile.stage, result.meshStageUs);
				MergeTimeProfile(g_detailedProfile.allocate, result.stageStats.allocate);
				MergeTimeProfile(g_detailedProfile.upload, result.stageStats.upload);
				sample.allocateUs += result.stageStats.allocate.totalUs;
				sample.uploadUs += result.stageStats.upload.totalUs;
				sample.meshesCreated += result.stageStats.meshesCreated;
				sample.batchesUploaded += result.stageStats.batchesUploaded;
				sample.verticesUploaded += result.stageStats.verticesUploaded;
				sample.bytesUploaded += result.stageStats.bytesUploaded;
				g_detailedProfile.meshesCreated += result.stageStats.meshesCreated;
				g_detailedProfile.batchesUploaded += result.stageStats.batchesUploaded;
				g_detailedProfile.verticesUploaded += result.stageStats.verticesUploaded;
				g_detailedProfile.bytesUploaded += result.stageStats.bytesUploaded;
			}
		}
		else if (result.ok)
		{
			const double stageT0 = Plat_FloatTime();
			result.meshesReady = StageSectionMeshes(result.build, result.stagedMeshes);
			result.meshStageUs = (Plat_FloatTime() - stageT0) * 1e6;
			RecordTime(g_meshStageProfile, result.meshStageUs);
			if (profiling)
			{
				sample.stageUs += result.meshStageUs;
				RecordTime(g_detailedProfile.stage, result.meshStageUs);
			}
			result.build = SectionBuild{};
			if (!result.meshesReady)
			{
				result.ok = false;
				result.meshCreateFailed = true;
			}
		}

		const bool chunkAlive = ws::g_world.find(result.chunkKey) != ws::g_world.end();
		const bool lightCurrent = chunkAlive && lightatlas::SlotMatches(result.chunkKey, result.lightSlot, result.lightGeneration) && result.stagedMeshes.lightSlot == result.lightSlot && result.stagedMeshes.lightGeneration == result.lightGeneration;
		// dirty bit 重新置位说明快照之后世界又变了；即使新 job 尚未投递也不能上屏。
		const bool current = chunkAlive && GenerationMatches(result.chunkKey, result.section, result.generation) && !DirtyBitSet(result.chunkKey, result.section) && lightCurrent;
		if (!current)
		{
			// jobsDropped 由 worker 统计队列丢弃；此处 stale 结果另行记账。
			DestroyStagedSectionMeshes(result.stagedMeshes);
			meshworker::RecordStaleDrop();
			meshworker::ReleaseResult(result.resultBytes);
			g_readyResults.pop_front();
			if (profiling)
				++sample.stale;
			continue;
		}

		if (!result.ok || !result.meshesReady)
		{
			const bool meshCreateFailed = result.meshCreateFailed;
			DestroyStagedSectionMeshes(result.stagedMeshes);
			meshworker::ReleaseResult(result.resultBytes);
			g_readyResults.pop_front();
			g_faulted = true;
			if (meshCreateFailed)
			{
				++g_meshCreateFailures;
				g_faultReason = "worker_mesh_create_failed";
			}
			else
				g_faultReason = "worker_build_failed";
			if (profiling)
				++sample.failed;
			break;
		}
		if (!CommitStagedSectionMeshes(result.chunkKey, result.section, result.stagedMeshes))
		{
			DestroyStagedSectionMeshes(result.stagedMeshes);
			meshworker::ReleaseResult(result.resultBytes);
			g_readyResults.pop_front();
			++g_meshCreateFailures;
			g_faulted = true;
			g_faultReason = "mesh_create_failed";
			if (profiling)
				++sample.failed;
			break;
		}
		g_lastBuildUs = result.buildUs;
		meshworker::ReleaseResult(result.resultBytes);
		g_readyResults.pop_front();
		++finalized;
		if (profiling)
			++sample.committed;
	}
	if (profiling)
	{
		sample.finalizeUs = (Plat_FloatTime() - finalizeT0) * 1e6;
		RecordTime(g_detailedProfile.finalize, sample.finalizeUs);
	}

	// 脏位是有界溢出缓冲。只有 job 成功入队后才清位；上限满则原位保留。
	const double dirtyScanT0 = profiling ? Plat_FloatTime() : 0.0;
	while (!g_faulted && !ws::g_dirtyQueue.empty())
	{
		const uint64_t key = ws::g_dirtyQueue.front();
		auto		   mit = ws::g_dirtyMask.find(key);
		if (mit == ws::g_dirtyMask.end() || mit->second == 0)
		{
			ws::g_dirtyQueue.erase(ws::g_dirtyQueue.begin());
			if (mit != ws::g_dirtyMask.end())
				ws::g_dirtyMask.erase(mit);
			continue;
		}
		if (ws::g_world.find(key) == ws::g_world.end())
		{
			ws::g_dirtyQueue.erase(ws::g_dirtyQueue.begin());
			ws::g_dirtyMask.erase(mit);
			continue;
		}

		const int		sec = LowestSetBit(mit->second);
		SectionSnapshot snapshot;
		const double	captureT0 = profiling ? Plat_FloatTime() : 0.0;
		if (profiling)
			++sample.captureAttempts;
		if (!CaptureSectionSnapshot(key, sec, snapshot))
		{
			if (profiling)
			{
				const double us = (Plat_FloatTime() - captureT0) * 1e6;
				sample.captureUs += us;
				RecordTime(g_detailedProfile.capture, us);
			}
			break;
		}
		if (profiling)
		{
			const double us = (Plat_FloatTime() - captureT0) * 1e6;
			sample.captureUs += us;
			++sample.captureSuccess;
			RecordTime(g_detailedProfile.capture, us);
		}

		GenerationArray &generations = g_generations[key];
		uint64_t		 generation = ++g_nextGeneration;
		if (generation == 0)
			generation = ++g_nextGeneration;
		meshworker::Job job;
		job.chunkKey = key;
		job.section = sec;
		job.generation = generation;
		job.profile = profiling;
		job.snapshot = std::move(snapshot);
		const double enqueueT0 = profiling ? Plat_FloatTime() : 0.0;
		if (profiling)
			++sample.enqueueAttempts;
		if (!meshworker::TryEnqueue(std::move(job)))
		{
			if (profiling)
			{
				const double us = (Plat_FloatTime() - enqueueT0) * 1e6;
				sample.enqueueUs += us;
				++sample.enqueueRejected;
				RecordTime(g_detailedProfile.enqueue, us);
			}
			break;
		}
		if (profiling)
		{
			const double us = (Plat_FloatTime() - enqueueT0) * 1e6;
			sample.enqueueUs += us;
			++sample.enqueueSuccess;
			RecordTime(g_detailedProfile.enqueue, us);
		}

		generations[sec] = generation;
		mit->second &= ~(1ull << sec);
		if (mit->second == 0)
		{
			ws::g_dirtyQueue.erase(ws::g_dirtyQueue.begin());
			ws::g_dirtyMask.erase(mit);
		}
	}

	g_lastThinkMS = (Plat_FloatTime() - t0) * 1000.0;
	int dirty = 0;
	for (const auto &kv : ws::g_dirtyMask)
		dirty += PopCount64(kv.second);
	const meshworker::Stats stats = meshworker::GetStats();
	const size_t			pending = size_t(dirty) + stats.outstanding;
	if (profiling)
	{
		sample.dirtyScanUs = (Plat_FloatTime() - dirtyScanT0) * 1e6 - sample.captureUs - sample.enqueueUs;
		if (sample.dirtyScanUs < 0)
			sample.dirtyScanUs = 0;
		sample.totalUs = (Plat_FloatTime() - t0) * 1e6;
		sample.budgetOverrunUs = std::max(0.0, sample.totalUs - budgetMS * 1000.0);
		sample.dirtyAfter = (size_t)dirty;
		sample.workerJobsAfter = stats.queuedJobs;
		sample.workerActiveAfter = stats.activeJobs;
		sample.workerResultsAfter = stats.queuedResults;
		sample.readyAfter = g_readyResults.size();
		sample.outstandingAfter = stats.outstanding;
		sample.resultBytesAfter = stats.resultBytes;
		RecordTime(g_detailedProfile.think, sample.totalUs);
		RecordTime(g_detailedProfile.dirtyScan, sample.dirtyScanUs);
		g_detailedProfile.peakDirty = std::max(g_detailedProfile.peakDirty, std::max(sample.dirtyBefore, sample.dirtyAfter));
		g_detailedProfile.peakWorkerJobs = std::max(g_detailedProfile.peakWorkerJobs, std::max(sample.workerJobsBefore, sample.workerJobsAfter));
		g_detailedProfile.peakWorkerResults = std::max(g_detailedProfile.peakWorkerResults, std::max(sample.workerResultsBefore, sample.workerResultsAfter));
		g_detailedProfile.peakReadyResults = std::max(g_detailedProfile.peakReadyResults, std::max(sample.readyBefore, sample.readyAfter));
		g_detailedProfile.peakOutstanding = std::max(g_detailedProfile.peakOutstanding, std::max(sample.outstandingBefore, sample.outstandingAfter));
		g_detailedProfile.peakResultBytes = std::max(g_detailedProfile.peakResultBytes, std::max(sample.resultBytesBefore, sample.resultBytesAfter));
		g_detailedProfile.latest = sample;
		g_activeThinkProfile = nullptr;
	}
	return PushThinkResult(LUA, pending, finalized);
}

int UnloadChunk(ILuaBase *LUA)
{
	int cx, cy, cz;
	if (!ws::ReadChunkCoords(LUA, cx, cy, cz))
	{
		LUA->PushBool(false);
		return 1;
	}
	const double   operationT0 = g_detailedProfile.enabled ? Plat_FloatTime() : 0.0;
	const uint64_t key = ws::PackChunkKey(cx, cy, cz);
	GetChunkMeshDraw().ForgetHidden(key);
	const size_t workerRemoved = meshworker::DiscardChunk(key);
	for (size_t i = 0; i < workerRemoved; ++i)
		meshworker::ReleaseResult();
	g_generations.erase(key);
	for (auto it = g_readyResults.begin(); it != g_readyResults.end();)
	{
		if (it->chunkKey == key)
		{
			DestroyStagedSectionMeshes(it->stagedMeshes);
			meshworker::ReleaseResult(it->resultBytes);
			meshworker::RecordStaleDrop();
			it = g_readyResults.erase(it);
		}
		else
			++it;
	}
	DestroyChunkMeshes(key);
	const int returns = ws::UnloadChunk(LUA);
	lightatlas::ReleaseChunk(key);
	lightatlas::RefreshChangedChunks({key});
	GetChunkMeshDraw().InvalidateMetadata();
	if (g_detailedProfile.enabled)
		RecordOperation("unload", (Plat_FloatTime() - operationT0) * 1e6, g_detailedProfile.unload);
	return returns;
}

void RefreshChunkDrawMetadata(uint64_t key)
{
	GetChunkMeshDraw().RefreshMetadata(key);
}

void InvalidateDirtyOcclusionMetadata()
{
	GetChunkMeshDraw().InvalidateMetadata();
}

int ApplyChunk(ILuaBase *LUA)
{
	int			 cx = 0, cy = 0, cz = 0;
	unsigned int len = 0;
	if (g_promise.SS <= 0 || g_faulted || !ws::ReadChunkCoords(LUA, cx, cy, cz))
	{
		LUA->PushBool(false);
		return 1;
	}
	const char *data = LUA->GetString(4, &len);
	if (!data || len != kStateBlobBytes || !blockdefs::Seal())
	{
		LUA->PushBool(false);
		return 1;
	}
	const int returns = ws::ApplyChunk(LUA);
	lightatlas::RefreshChangedChunks({ws::PackChunkKey(cx, cy, cz)});
	GetChunkMeshDraw().RefreshMetadata(ws::PackChunkKey(cx, cy, cz));
	GetChunkMeshDraw().InvalidateMetadata();
	return returns;
}

int CreateChunk(ILuaBase *LUA)
{
	int cx = 0, cy = 0, cz = 0;
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal() || !ws::ReadChunkCoords(LUA, cx, cy, cz))
	{
		LUA->PushBool(false);
		return 1;
	}
	const int returns = ws::CreateChunk(LUA);
	lightatlas::RefreshChangedChunks({ws::PackChunkKey(cx, cy, cz)});
	GetChunkMeshDraw().RefreshMetadata(ws::PackChunkKey(cx, cy, cz));
	GetChunkMeshDraw().InvalidateMetadata();
	return returns;
}

int ApplyChunkCells(ILuaBase *LUA)
{
	int cx = 0, cy = 0, cz = 0;
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal() || !ws::ReadChunkCoords(LUA, cx, cy, cz))
	{
		LUA->PushBool(false);
		return 1;
	}
	const int returns = ws::ApplyChunkCells(LUA);
	lightatlas::RefreshChangedChunks({ws::PackChunkKey(cx, cy, cz)});
	GetChunkMeshDraw().RefreshMetadata(ws::PackChunkKey(cx, cy, cz));
	GetChunkMeshDraw().InvalidateMetadata();
	return returns;
}

int SetCell(ILuaBase *LUA)
{
	int cx = 0, cy = 0, cz = 0;
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal() || !ws::ReadChunkCoords(LUA, cx, cy, cz))
	{
		LUA->PushBool(false);
		return 1;
	}
	const int returns = ws::SetCell(LUA);
	// worldstate::SetCell returns its exact incremental light diff through
	// PushChangedLightTable(), which synchronously refreshes every affected
	// atlas halo tile. Rebuilding the source neighbourhood again here did
	// the same GPU upload twice for every interactive edit. Before the
	// light field is ready it returns only the success bool; keep the
	// conservative full-neighbour refresh for that startup/disabled case.
	if (returns < 2)
		lightatlas::RefreshChangedChunks({ws::PackChunkKey(cx, cy, cz)});
	GetChunkMeshDraw().RefreshMetadata(ws::PackChunkKey(cx, cy, cz));
	GetChunkMeshDraw().InvalidateMetadata();
	return returns;
}

int GetCell(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushNil();
		return 1;
	}
	return ws::GetCell(LUA);
}

int GetChunkCells(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushNil();
		return 1;
	}
	return ws::GetChunkCells(LUA);
}

int RebuildBlockLight(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushBool(false);
		return 1;
	}
	const int returns = ws::RebuildBlockLight(LUA);
	lightatlas::RefreshAllAssigned();
	return returns;
}

int GetBlockLightChunk(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushNil();
		return 1;
	}
	return ws::GetBlockLightChunk(LUA);
}

int GetSkyLightChunk(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushNil();
		return 1;
	}
	return ws::GetSkyLightChunk(LUA);
}

int GetLightingHalo(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushNil();
		return 1;
	}
	return ws::GetLightingHalo(LUA);
}

int GetChunkLightTile(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushNil();
		return 1;
	}
	return ws::GetChunkLightTile(LUA);
}

int StartBlockLightRebuild(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted || !blockdefs::Seal())
	{
		LUA->PushBool(false);
		return 1;
	}
	return ws::StartBlockLightRebuild(LUA);
}

int PollBlockLightRebuild(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted)
	{
		LUA->PushBool(false);
		return 1;
	}
	return ws::PollBlockLightRebuild(LUA);
}

int CancelBlockLightRebuild(ILuaBase *LUA)
{
	if (g_promise.SS <= 0 || g_faulted)
	{
		LUA->PushBool(false);
		return 1;
	}
	return ws::CancelBlockLightRebuild(LUA);
}

int ClearWorld(ILuaBase *LUA)
{
	patchdecode::CancelAll();
	const double operationT0 = g_detailedProfile.enabled ? Plat_FloatTime() : 0.0;
	GetChunkMeshDraw().StopWorker();
	const size_t workerRemoved = meshworker::DiscardAll();
	for (size_t i = 0; i < workerRemoved; ++i)
		meshworker::ReleaseResult();
	for (auto &result : g_readyResults)
	{
		DestroyStagedSectionMeshes(result.stagedMeshes);
		meshworker::ReleaseResult(result.resultBytes);
		meshworker::RecordStaleDrop();
	}
	g_readyResults.clear();
	g_generations.clear();
	GetChunkMeshDraw().ClearHidden();
	DestroyAllMeshes();
	blockdefs::Unseal();
	g_faulted = false;
	g_faultReason = "";
	g_lastThinkMS = 0;
	g_lastBuildUs = 0;
	g_meshCreateFailures = 0;
	g_emitterStats = {};
	g_resultBytes = 0;
	g_vertexBuildProfile = {};
	g_meshStageProfile = {};
	g_meshCommitProfile = {};
	g_meshDestroyProfile = {};
	const int returns = ws::ClearWorld(LUA);
	lightatlas::ClearWorld();
	if (g_detailedProfile.enabled)
		RecordOperation("clear", (Plat_FloatTime() - operationT0) * 1e6, g_detailedProfile.clear);
	return returns;
}

int Shutdown(ILuaBase *LUA)
{
	patchdecode::Shutdown();
	const bool	 profiling = g_detailedProfile.enabled;
	const double operationT0 = profiling ? Plat_FloatTime() : 0.0;
	StopWorkers();
	ws::StopBlockLightWorker();
	DestroyAllMeshes();
	blockdefs::Clear();
	g_faulted = false;
	g_faultReason = "";
	g_lastThinkMS = 0;
	g_lastBuildUs = 0;
	g_meshCreateFailures = 0;
	g_emitterStats = {};
	g_resultBytes = 0;
	g_vertexBuildProfile = {};
	g_meshStageProfile = {};
	g_meshCommitProfile = {};
	g_meshDestroyProfile = {};
	ws::g_world.clear();
	ws::g_dirtyMask.clear();
	ws::g_dirtyQueue.clear();
	GetChunkMeshDraw().ClearHidden();
	ws::g_status = {};
	g_promise = {};
	lightatlas::Shutdown();
	if (profiling)
		RecordOperation("shutdown", (Plat_FloatTime() - operationT0) * 1e6, g_detailedProfile.shutdown);
	g_detailedProfile.enabled = false;
	return 0;
}

int SetProfiling(ILuaBase *LUA)
{
	if (!LUA->IsType(1, Type::Bool))
	{
		LUA->PushBool(false);
		return 1;
	}
	const bool reset = LUA->Top() >= 2;
	if (reset && !LUA->IsType(2, Type::Bool))
	{
		LUA->PushBool(false);
		return 1;
	}
	const bool enabled = LUA->GetBool(1);
	const bool shouldReset = reset && LUA->GetBool(2);
	if (shouldReset)
		ResetDetailedProfile();
	g_detailedProfile.enabled = enabled;
	g_activeThinkProfile = nullptr;
	LUA->PushBool(true);
	return 1;
}

int SetSimpleGreedy(ILuaBase *LUA)
{
	if (!LUA->IsType(1, Type::Bool))
	{
		LUA->PushBool(false);
		return 1;
	}
	const bool enabled = LUA->GetBool(1);
	if (enabled == g_simpleGreedyEnabled)
	{
		LUA->PushBool(true);
		return 1;
	}

	StopWorkers();
	g_simpleGreedyEnabled = enabled;
	for (const auto &chunk : ws::g_world)
		ws::MarkWholeChunkDirty(chunk.first);
	GetChunkMeshDraw().InvalidateMetadata();
	LUA->PushBool(true);
	return 1;
}

int SetDirectionalDraw(ILuaBase *LUA)
{
	if (!LUA->IsType(1, Type::Bool))
	{
		LUA->PushBool(false);
		return 1;
	}
	g_directionalDrawEnabled.store(LUA->GetBool(1), std::memory_order_relaxed);
	LUA->PushBool(true);
	return 1;
}

int SetOcclusionCull(ILuaBase *LUA)
{
	if (!LUA->IsType(1, Type::Bool))
	{
		LUA->PushBool(false);
		return 1;
	}
	g_occlusionCullEnabled.store(LUA->GetBool(1), std::memory_order_relaxed);
	LUA->PushBool(true);
	return 1;
}

int SetLod(ILuaBase *inLua)
{
	if (!inLua->IsType(1, Type::Bool) || !inLua->IsType(2, Type::Number))
	{
		inLua->PushBool(false);
		return 1;
	}
	const double start_chunks = inLua->GetNumber(2);
	if (!std::isfinite(start_chunks) || start_chunks < 0 || start_chunks > 4096)
	{
		inLua->PushBool(false);
		return 1;
	}
	const bool enabled = inLua->GetBool(1);
	if (enabled && !g_lodBuildEnabled)
	{
		StopWorkers();
		g_lodBuildEnabled = true;
		for (const auto &chunk : ws::g_world)
			ws::MarkWholeChunkDirty(chunk.first);
		GetChunkMeshDraw().InvalidateMetadata();
	}
	g_lodStartChunks.store(start_chunks, std::memory_order_relaxed);
	g_lodDrawEnabled.store(enabled, std::memory_order_relaxed);
	inLua->PushBool(true);
	return 1;
}

int GetStats(ILuaBase *LUA)
{
	int		  opaqueMeshCount = 0, translucentMeshCount = 0, lodOpaqueMeshCount = 0, lodReadySections = 0;
	long long opaqueVertCount = 0, translucentVertCount = 0, lodOpaqueVertCount = 0;
	for (const auto &kv : g_meshes)
		for (int i = 0; i < 64; ++i)
		{
			const SectionMeshes &sm = kv.second.section[i];
			if (!sm.opaque.empty())
			{
				opaqueMeshCount += (int)sm.opaque.size();
				opaqueVertCount += sm.opaqueVerts;
			}
			if (!sm.translucent.empty())
			{
				translucentMeshCount += (int)sm.translucent.size();
				translucentVertCount += sm.translucentVerts;
			}
			if (sm.lodReady && !sm.lodOpaque.empty())
				++lodReadySections;
			if (!sm.lodOpaque.empty())
			{
				lodOpaqueMeshCount += (int)sm.lodOpaque.size();
				lodOpaqueVertCount += sm.lodOpaqueVerts;
			}
		}
	const int		meshCount = opaqueMeshCount + translucentMeshCount + lodOpaqueMeshCount;
	const long long vertCount = opaqueVertCount + translucentVertCount + lodOpaqueVertCount;

	int dirty = 0;
	for (const auto &kv : ws::g_dirtyMask)
		dirty += PopCount64(kv.second);
	const meshworker::Stats stats = meshworker::GetStats();
	const size_t			pending = size_t(dirty) + stats.outstanding;
	const auto				draw_stats = GetChunkMeshDraw().GetStats();
	const auto				drawMetadataChunks = draw_stats.mMetadataChunks;
	const auto				occlusionReadySections = draw_stats.mOcclusionReadySections;
	const auto				cullWorkerRunning = draw_stats.mWorkerRunning;
	const auto				cullPending = draw_stats.mPending;
	const auto				cullFailed = draw_stats.mFailed;
	const auto				cullSerial = draw_stats.mSerial;
	const auto				cullRequestSerial = draw_stats.mRequestSerial;

	LUA->CreateTable();
	LUA->PushNumber((double)ws::g_world.size());
	LUA->SetField(-2, "mirrorChunks");
	LUA->PushNumber((double)meshCount);
	LUA->SetField(-2, "meshes");
	LUA->PushNumber((double)vertCount);
	LUA->SetField(-2, "vertices");
	LUA->PushBool(g_directionalDrawEnabled.load(std::memory_order_relaxed));
	LUA->SetField(-2, "directionalDraw");
	LUA->PushBool(g_occlusionCullEnabled.load(std::memory_order_relaxed));
	LUA->SetField(-2, "occlusionCull");
	LUA->PushBool(g_lodDrawEnabled.load(std::memory_order_relaxed));
	LUA->SetField(-2, "lod");
	LUA->PushBool(g_lodBuildEnabled);
	LUA->SetField(-2, "lodBuildEnabled");
	LUA->PushNumber(g_lodStartChunks.load(std::memory_order_relaxed));
	LUA->SetField(-2, "lodStartChunks");
	LUA->PushNumber(opaqueMeshCount);
	LUA->SetField(-2, "opaqueMeshes");
	LUA->PushNumber(translucentMeshCount);
	LUA->SetField(-2, "translucentMeshes");
	LUA->PushNumber(lodOpaqueMeshCount);
	LUA->SetField(-2, "lodOpaqueMeshes");
	LUA->PushNumber(lodReadySections);
	LUA->SetField(-2, "lodReadySections");
	LUA->PushNumber((double)opaqueVertCount);
	LUA->SetField(-2, "opaqueVertices");
	LUA->PushNumber((double)translucentVertCount);
	LUA->SetField(-2, "translucentVertices");
	LUA->PushNumber((double)lodOpaqueVertCount);
	LUA->SetField(-2, "lodOpaqueVertices");
	LUA->PushNumber((double)g_meshCreateFailures);
	LUA->SetField(-2, "meshCreateFailures");
	LUA->PushBool(g_faulted);
	LUA->SetField(-2, "faulted");
	LUA->PushString(g_faultReason);
	LUA->SetField(-2, "faultReason");
	LUA->PushNumber((double)pending);
	LUA->SetField(-2, "pendingSections");
	LUA->PushNumber(g_lastBuildUs);
	LUA->SetField(-2, "lastBuildUs");
	LUA->PushNumber(g_lastThinkMS);
	LUA->SetField(-2, "lastThinkMS");
	LUA->PushNumber(stats.workerCount);
	LUA->SetField(-2, "workerCount");
	LUA->PushNumber((double)stats.maxInFlight);
	LUA->SetField(-2, "maxInFlight");
	LUA->PushBool(stats.workerCreatesMeshes);
	LUA->SetField(-2, "workerCreatesMeshes");
	LUA->PushNumber((double)stats.queuedJobs);
	LUA->SetField(-2, "queuedJobs");
	LUA->PushNumber((double)stats.activeJobs);
	LUA->SetField(-2, "activeJobs");
	LUA->PushNumber((double)stats.outstanding);
	LUA->SetField(-2, "outstanding");
	LUA->PushNumber((double)stats.queuedResults);
	LUA->SetField(-2, "workerQueuedResults");
	LUA->PushNumber((double)g_readyResults.size());
	LUA->SetField(-2, "readyResults");
	LUA->PushNumber((double)(stats.queuedResults + g_readyResults.size()));
	LUA->SetField(-2, "queuedResults");
	LUA->PushNumber((double)stats.jobsEnqueued);
	LUA->SetField(-2, "jobsEnqueued");
	LUA->PushNumber((double)stats.jobsDropped);
	LUA->SetField(-2, "jobsDropped");
	LUA->PushNumber((double)stats.resultBytes);
	LUA->SetField(-2, "resultBytes");
	LUA->PushBool(cullWorkerRunning);
	LUA->SetField(-2, "cullWorkerRunning");
	LUA->PushBool(cullPending);
	LUA->SetField(-2, "cullPending");
	LUA->PushBool(cullFailed);
	LUA->SetField(-2, "cullFailed");
	LUA->PushNumber((double)drawMetadataChunks);
	LUA->SetField(-2, "drawMetadataChunks");
	LUA->PushNumber((double)occlusionReadySections);
	LUA->SetField(-2, "occlusionReadySections");
	LUA->PushNumber((double)cullSerial);
	LUA->SetField(-2, "cullSerial");
	LUA->PushNumber((double)cullRequestSerial);
	LUA->SetField(-2, "cullRequestSerial");
	auto pushProfile = [LUA](const char *prefix, const TimeProfile &p)
	{
		const std::string base(prefix);
		LUA->PushNumber((double)p.calls);
		LUA->SetField(-2, (base + "Calls").c_str());
		LUA->PushNumber(p.lastUs);
		LUA->SetField(-2, (base + "LastUs").c_str());
		LUA->PushNumber(p.calls ? p.totalUs / (double)p.calls : 0.0);
		LUA->SetField(-2, (base + "AvgUs").c_str());
		LUA->PushNumber(p.maxUs);
		LUA->SetField(-2, (base + "MaxUs").c_str());
		LUA->PushNumber(p.totalUs / 1000.0);
		LUA->SetField(-2, (base + "TotalMS").c_str());
	};
	pushProfile("vertexBuild", g_vertexBuildProfile);
	pushProfile("meshStage", g_meshStageProfile);
	pushProfile("meshCommit", g_meshCommitProfile);
	pushProfile("meshDestroy", g_meshDestroyProfile);
	LUA->PushBool(true);
	LUA->SetField(-2, "profilingSupported");
	LUA->PushBool(g_detailedProfile.enabled);
	LUA->SetField(-2, "profilingEnabled");
	LUA->PushNumber((double)g_detailedProfile.generation);
	LUA->SetField(-2, "profilingGeneration");
	LUA->CreateTable();
	auto pushNestedProfile = [LUA](const char *name, const TimeProfile &p)
	{
		LUA->CreateTable();
		LUA->PushNumber((double)p.calls);
		LUA->SetField(-2, "calls");
		LUA->PushNumber(p.lastUs);
		LUA->SetField(-2, "lastUs");
		LUA->PushNumber(p.calls ? p.totalUs / (double)p.calls : 0.0);
		LUA->SetField(-2, "avgUs");
		LUA->PushNumber(p.maxUs);
		LUA->SetField(-2, "maxUs");
		LUA->PushNumber(p.totalUs / 1000.0);
		LUA->SetField(-2, "totalMS");
		LUA->SetField(-2, name);
	};
	LUA->PushBool(g_detailedProfile.enabled);
	LUA->SetField(-2, "enabled");
	LUA->PushNumber((double)g_detailedProfile.generation);
	LUA->SetField(-2, "generation");
	LUA->PushNumber((double)g_detailedProfile.operationSequence);
	LUA->SetField(-2, "operationSequence");
	LUA->PushString(g_detailedProfile.lastOperation);
	LUA->SetField(-2, "lastOperation");
	LUA->PushNumber(g_detailedProfile.lastOperationUs);
	LUA->SetField(-2, "lastOperationUs");
	LUA->PushNumber((double)g_detailedProfile.meshesCreated);
	LUA->SetField(-2, "meshesCreated");
	LUA->PushNumber((double)g_detailedProfile.meshesDestroyed);
	LUA->SetField(-2, "meshesDestroyed");
	LUA->PushNumber((double)g_detailedProfile.batchesUploaded);
	LUA->SetField(-2, "batchesUploaded");
	LUA->PushNumber((double)g_detailedProfile.verticesUploaded);
	LUA->SetField(-2, "verticesUploaded");
	LUA->PushNumber((double)g_detailedProfile.bytesUploaded);
	LUA->SetField(-2, "bytesUploaded");
	LUA->PushNumber((double)g_detailedProfile.peakDirty);
	LUA->SetField(-2, "peakDirty");
	LUA->PushNumber((double)g_detailedProfile.peakWorkerJobs);
	LUA->SetField(-2, "peakWorkerJobs");
	LUA->PushNumber((double)g_detailedProfile.peakWorkerResults);
	LUA->SetField(-2, "peakWorkerResults");
	LUA->PushNumber((double)g_detailedProfile.peakReadyResults);
	LUA->SetField(-2, "peakReadyResults");
	LUA->PushNumber((double)g_detailedProfile.peakOutstanding);
	LUA->SetField(-2, "peakOutstanding");
	LUA->PushNumber((double)g_detailedProfile.peakResultBytes);
	LUA->SetField(-2, "peakResultBytes");
	LUA->CreateTable();
	const ThinkProfileSample &latest = g_detailedProfile.latest;
	LUA->PushNumber((double)latest.sequence);
	LUA->SetField(-2, "sequence");
	LUA->PushNumber(latest.budgetMS);
	LUA->SetField(-2, "budgetMS");
	LUA->PushNumber(latest.totalUs);
	LUA->SetField(-2, "totalUs");
	LUA->PushNumber(latest.budgetOverrunUs);
	LUA->SetField(-2, "budgetOverrunUs");
	LUA->PushNumber(latest.stageUs);
	LUA->SetField(-2, "stageUs");
	LUA->PushNumber(latest.allocateUs);
	LUA->SetField(-2, "allocateUs");
	LUA->PushNumber(latest.uploadUs);
	LUA->SetField(-2, "uploadUs");
	LUA->PushNumber((double)latest.verticesUploaded);
	LUA->SetField(-2, "verticesUploaded");
	LUA->PushNumber((double)latest.bytesUploaded);
	LUA->SetField(-2, "bytesUploaded");
	LUA->PushNumber(latest.replaceUs);
	LUA->SetField(-2, "replaceUs");
	LUA->PushNumber(latest.destroyUs);
	LUA->SetField(-2, "destroyUs");
	LUA->PushNumber(latest.captureUs);
	LUA->SetField(-2, "captureUs");
	LUA->PushNumber(latest.enqueueUs);
	LUA->SetField(-2, "enqueueUs");
	LUA->PushNumber((double)latest.readyBefore);
	LUA->SetField(-2, "readyBefore");
	LUA->PushNumber((double)latest.readyAfter);
	LUA->SetField(-2, "readyAfter");
	LUA->PushNumber((double)latest.outstandingBefore);
	LUA->SetField(-2, "outstandingBefore");
	LUA->PushNumber((double)latest.outstandingAfter);
	LUA->SetField(-2, "outstandingAfter");
	LUA->SetField(-2, "latest");
	LUA->CreateTable();
	pushNestedProfile("think", g_detailedProfile.think);
	pushNestedProfile("workerStart", g_detailedProfile.workerStart);
	pushNestedProfile("collect", g_detailedProfile.collect);
	pushNestedProfile("finalize", g_detailedProfile.finalize);
	pushNestedProfile("queueWait", g_detailedProfile.queueWait);
	pushNestedProfile("stage", g_detailedProfile.stage);
	pushNestedProfile("allocate", g_detailedProfile.allocate);
	pushNestedProfile("upload", g_detailedProfile.upload);
	pushNestedProfile("replace", g_detailedProfile.replace);
	pushNestedProfile("destroy", g_detailedProfile.destroy);
	pushNestedProfile("dirtyScan", g_detailedProfile.dirtyScan);
	pushNestedProfile("capture", g_detailedProfile.capture);
	pushNestedProfile("enqueue", g_detailedProfile.enqueue);
	pushNestedProfile("unload", g_detailedProfile.unload);
	pushNestedProfile("clear", g_detailedProfile.clear);
	pushNestedProfile("shutdown", g_detailedProfile.shutdown);
	pushNestedProfile("workerStop", g_detailedProfile.workerStop);
	LUA->SetField(-2, "phases");
	LUA->SetField(-2, "profiling");
	LUA->PushNumber((double)ws::g_status.LastApplyDirty);
	LUA->SetField(-2, "lastApplyDirty");
	LUA->PushNumber((double)ws::g_status.BatchCalls);
	LUA->SetField(-2, "nativeBatchCalls");
	LUA->PushNumber((double)ws::g_status.BatchCells);
	LUA->SetField(-2, "nativeBatchCells");
	LUA->PushNumber(ws::g_status.BatchLastMS);
	LUA->SetField(-2, "nativeBatchLastMS");
	LUA->PushNumber(ws::g_status.BatchTotalMS);
	LUA->SetField(-2, "nativeBatchTotalMS");
	LUA->PushNumber((double)ws::g_status.SetCellCalls);
	LUA->SetField(-2, "nativeSetCellCalls");
	LUA->PushNumber(ws::g_status.SetCellLastUs);
	LUA->SetField(-2, "nativeSetCellLastUs");
	LUA->PushNumber(ws::g_status.SetCellTotalMS);
	LUA->SetField(-2, "nativeSetCellTotalMS");
	LUA->PushNumber((double)ws::g_status.LightRebuilds);
	LUA->SetField(-2, "nativeLightRebuilds");
	LUA->PushNumber(ws::g_status.LightLastMS);
	LUA->SetField(-2, "nativeLightLastMS");
	LUA->PushNumber((double)ws::g_status.LightSources);
	LUA->SetField(-2, "nativeLightSources");
	LUA->PushNumber((double)ws::g_status.LightProcessed);
	LUA->SetField(-2, "nativeLightProcessed");
	LUA->PushNumber((double)ws::g_status.LightWritten);
	LUA->SetField(-2, "nativeLightWritten");
	LUA->PushNumber(ws::g_status.SkyLastMS);
	LUA->SetField(-2, "nativeSkyLastMS");
	LUA->PushNumber((double)ws::g_status.SkySources);
	LUA->SetField(-2, "nativeSkySources");
	LUA->PushNumber((double)ws::g_status.SkyProcessed);
	LUA->SetField(-2, "nativeSkyProcessed");
	LUA->PushNumber((double)ws::g_status.SkyWritten);
	LUA->SetField(-2, "nativeSkyWritten");
	LUA->PushNumber((double)ws::g_status.IncrementalLightUpdates);
	LUA->SetField(-2, "nativeIncrementalLightUpdates");
	LUA->PushNumber((double)ws::g_status.IncrementalLightCells);
	LUA->SetField(-2, "nativeIncrementalLightCells");
	LUA->PushNumber(ws::g_status.IncrementalLightLastMS);
	LUA->SetField(-2, "nativeIncrementalLightLastMS");
	LUA->PushNumber((double)ws::g_status.AsyncPartialCommits);
	LUA->SetField(-2, "nativeAsyncPartialCommits");
	LUA->PushNumber((double)ws::g_status.AsyncDeferredChunks);
	LUA->SetField(-2, "nativeAsyncDeferredChunks");
	LUA->PushBool(ws::g_lightFieldReady);
	LUA->SetField(-2, "nativeLightFieldReady");
	LUA->PushNumber((double)ws::g_worldVersion);
	LUA->SetField(-2, "nativeWorldVersion");
	LUA->PushNumber((double)blockdefs::g_counts.states);
	LUA->SetField(-2, "stateDefinitions");
	LUA->PushNumber((double)blockdefs::g_atlasPages.size());
	LUA->SetField(-2, "atlasPages");
	LUA->PushBool(blockdefs::g_lightEmission.size() == blockdefs::g_states.size() && blockdefs::g_lightOpacity.size() == blockdefs::g_states.size());
	LUA->SetField(-2, "lightDefinitionsLoaded");
	LUA->PushBool(blockdefs::g_visual.loaded);
	LUA->SetField(-2, "generatedCatalogLoaded");
	LUA->PushNumber((double)blockdefs::g_visual.catalogStateCount);
	LUA->SetField(-2, "generatedCatalogStates");
	LUA->PushNumber((double)blockdefs::g_visual.plans.size());
	LUA->SetField(-2, "generatedPlans");
	LUA->PushNumber((double)blockdefs::g_visual.models.size());
	LUA->SetField(-2, "generatedModels");
	LUA->PushNumber((double)blockdefs::g_visual.geometries.size());
	LUA->SetField(-2, "generatedGeometries");
	LUA->PushNumber((double)blockdefs::g_visual.surfaceSets.size());
	LUA->SetField(-2, "generatedSurfaceSets");
	LUA->PushNumber((double)blockdefs::g_visual.tintSlotCount);
	LUA->SetField(-2, "generatedTintSlots");
	static const char *emitterNames[6] = {"fullCube", "cross", "model", "shape", "connection", "liquid"};
	LUA->CreateTable();
	for (int i = 0; i < 6; ++i)
	{
		LUA->CreateTable();
		LUA->PushNumber((double)g_emitterStats.blocks[i]);
		LUA->SetField(-2, "blocks");
		LUA->PushNumber((double)g_emitterStats.faces[i]);
		LUA->SetField(-2, "faces");
		LUA->SetField(-2, emitterNames[i]);
	}
	LUA->SetField(-2, "emitters");
	return 1;
}

int DebugBuildSection(ILuaBase *LUA)
{
	int cx, cy, cz;
	if (!ws::ReadChunkCoords(LUA, cx, cy, cz))
		return 0;
	if (!LUA->IsType(4, Type::Number))
		return 0;
	const double secD = LUA->GetNumber(4);
	if (!std::isfinite(secD) || secD != std::floor(secD) || secD < 0 || secD >= g_promise.SPC)
		return 0;
	if (!Ready())
		return 0;

	SectionSnapshot snapshot;
	if (!CaptureSectionSnapshot(ws::PackChunkKey(cx, cy, cz), (int)secD, snapshot))
		return 0;
	SectionBuild scratch;
	const double t0 = Plat_FloatTime();
	if (!BuildSectionVerts(snapshot, scratch))
		return 0;
	const double us = (Plat_FloatTime() - t0) * 1e6;
	const int	 faces = scratch.opaque.faces + scratch.translucent.faces;
	const size_t verts = scratch.opaque.vertices + scratch.translucent.vertices;

	LUA->CreateTable();
	LUA->PushNumber(faces);
	LUA->SetField(-2, "faces");
	LUA->PushNumber((double)verts);
	LUA->SetField(-2, "verts");
	LUA->PushNumber(scratch.opaque.faces);
	LUA->SetField(-2, "opaqueFaces");
	LUA->PushNumber((double)scratch.opaque.vertices);
	LUA->SetField(-2, "opaqueVerts");
	LUA->PushNumber(scratch.translucent.faces);
	LUA->SetField(-2, "translucentFaces");
	LUA->PushNumber((double)scratch.translucent.vertices);
	LUA->SetField(-2, "translucentVerts");
	LUA->PushBool(scratch.lodReady);
	LUA->SetField(-2, "lodReady");
	LUA->PushNumber(scratch.lodOpaque.faces);
	LUA->SetField(-2, "lodOpaqueFaces");
	LUA->PushNumber((double)scratch.lodOpaque.vertices);
	LUA->SetField(-2, "lodOpaqueVerts");
	LUA->PushNumber(us);
	LUA->SetField(-2, "buildUs");
	static const char *emitterNames[6] = {"fullCube", "cross", "model", "shape", "connection", "liquid"};
	LUA->CreateTable();
	for (int i = 0; i < 6; ++i)
	{
		LUA->PushNumber((double)scratch.emitters.faces[i]);
		LUA->SetField(-2, emitterNames[i]);
	}
	LUA->SetField(-2, "emitterFaces");
	return 1;
}
} // namespace mcmesh::meshbuild
