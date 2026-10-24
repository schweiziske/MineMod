#include "Module/Pch.h"
#include "Legacy/ChunkMeshDraw.h"
#include "Render/Visibility/ChunkVisibilityQuery.h"
#include "Legacy/ChunkMeshBuilder.h"
#include "Legacy/WorldMirror.h"
#include "tier0/platform.h"
#include "mathlib/vmatrix.h"
#include <cmath>
#include <condition_variable>
#include <limits>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

using namespace mcmesh;
namespace ws = mcmesh::worldstate;
namespace mcmesh::meshbuild
{
inline int PopCount64(uint64_t inV)
{
	int n = 0;
	while (inV)
	{
		inV &= inV - 1;
		++n;
	}
	return n;
}

inline int LowestSetBit(uint64_t inMask)
{
	int bit = 0;
	while ((inMask & 1) == 0)
	{
		inMask >>= 1;
		++bit;
	}
	return bit;
}

struct ChunkMeshDraw::State
{
	// Main-thread-only visibility toggles and active frame; metadata mutex
	// protects copied CPU metadata. Cull mutex protects requests and completion.
	// These locks are never held together, and neither protects engine resources.
	std::unordered_set<uint64_t>					mHiddenChunks;
	std::mutex										mDrawMetadataMutex;
	std::unordered_map<uint64_t, DrawChunkMetadata> mDrawMetadata;
	std::atomic<uint64_t>							mOcclusionMetadataEpoch{1};
	std::mutex										mCullMutex;
	std::condition_variable							mCullCv;
	std::thread										mCullThread;
	bool											mCullRunning = false, mCullStop = false, mCullPending = false;
	bool											mCullCollectPending = false, mCullFailed = false;
	uint64_t										mCullNextSerial = 0;
	NativeDrawView									mCullRequest;
	std::shared_ptr<const NativeCullFrame>			mLatestCullFrame;
	std::shared_ptr<const NativeCullFrame>			mActiveCullFrame;
	std::string										mPendingVisibleKeys;

	void								   RefreshDrawMetadata(uint64_t inKey);
	void								   InvalidateDirtyOcclusionMetadataInternal();
	void								   EraseDrawMetadata(uint64_t inKey);
	std::vector<DrawChunkMetadata>		   SnapshotDrawMetadata();
	std::shared_ptr<NativeCullFrame>	   BuildCullFrame(const NativeDrawView &inView, uint64_t inSerial);
	void								   CullWorkerMain();
	bool								   StartCullWorker();
	void								   StopCullWorker();
	uint64_t							   SubmitCullRequest(const NativeDrawView &inView);
	std::shared_ptr<const NativeCullFrame> LatestCullFrame();
	void								   PublishCullFrame(const std::shared_ptr<const NativeCullFrame> &inFrame);
	std::string							   TakePendingVisibleKeys();
	bool								   CullWorkerFailed();
	bool								   Draw(const NativeDrawView &inView, int inPass, NativeDrawResult &outResult);
};
void ChunkMeshDraw::State::RefreshDrawMetadata(uint64_t inKey)
{
	DrawChunkMetadata metadata;
	metadata.mKey = inKey;
	int cx, cy, cz;
	ws::UnpackChunkKey(inKey, cx, cy, cz);
	metadata.mCx = cx;
	metadata.mCy = cy;
	metadata.mCz = cz;
	metadata.mHidden = mHiddenChunks.find(inKey) != mHiddenChunks.end();
	auto it = mcmesh::meshbuild::g_meshes.find(inKey);
	if (it != mcmesh::meshbuild::g_meshes.end())
	{
		for (int sec = 0; sec < g_promise.SPC; ++sec)
		{
			const mcmesh::meshbuild::SectionMeshes &section = it->second.section[sec];
			if (!section.opaque.empty())
				metadata.mPassMask[0] |= 1ull << sec;
			if (!section.translucent.empty())
				metadata.mPassMask[1] |= 1ull << sec;
			if (section.lodReady && !section.lodOpaque.empty())
				metadata.mLodReadyMask |= 1ull << sec;
			if (section.occlusion.ready)
			{
				metadata.mOcclusionReadyMask |= 1ull << sec;
				metadata.mOcclusionVisibleFrom[sec] = section.occlusion.visibleFrom;
			}
		}
	}
	const bool					loaded = ws::g_world.find(inKey) != ws::g_world.end();
	std::lock_guard<std::mutex> lock(mDrawMetadataMutex);
	if (loaded || metadata.mPassMask[0] || metadata.mPassMask[1])
		mDrawMetadata[inKey] = metadata;
	else
		mDrawMetadata.erase(inKey);
}

void ChunkMeshDraw::State::InvalidateDirtyOcclusionMetadataInternal()
{
	bool changed = false;
	{
		std::lock_guard<std::mutex> lock(mDrawMetadataMutex);
		for (const auto &dirty : ws::g_dirtyMask)
		{
			const auto found = mDrawMetadata.find(dirty.first);
			if (found == mDrawMetadata.end())
				continue;
			const uint64_t old_mask = found->second.mOcclusionReadyMask;
			found->second.mOcclusionReadyMask &= ~dirty.second;
			changed = changed || old_mask != found->second.mOcclusionReadyMask;
		}
	}
	if (changed)
		mOcclusionMetadataEpoch.fetch_add(1, std::memory_order_relaxed);
}

void ChunkMeshDraw::State::EraseDrawMetadata(uint64_t inKey)
{
	std::lock_guard<std::mutex> lock(mDrawMetadataMutex);
	mDrawMetadata.erase(inKey);
}

std::vector<DrawChunkMetadata> ChunkMeshDraw::State::SnapshotDrawMetadata()
{
	std::vector<DrawChunkMetadata> snapshot;
	// Keep the metadata lock only while copying; all culling runs on the snapshot.
	std::lock_guard<std::mutex> lock(mDrawMetadataMutex);
	snapshot.reserve(mDrawMetadata.size());
	for (const auto &pair : mDrawMetadata)
		snapshot.push_back(pair.second);
	return snapshot;
}

std::shared_ptr<NativeCullFrame> ChunkMeshDraw::State::BuildCullFrame(const NativeDrawView &inView, uint64_t inSerial)
{
	const double started = Plat_FloatTime();
	auto		 frame = BuildChunkCullFrame(inView, inSerial, SnapshotDrawMetadata());
	// Preserve the compatibility statistic's inclusion of metadata copying.
	const double elapsed_us = (Plat_FloatTime() - started) * 1e6;
	frame->mPass[0].mCullUs = elapsed_us;
	frame->mPass[1].mCullUs = elapsed_us;
	return frame;
}

void ChunkMeshDraw::State::CullWorkerMain()
{
	for (;;)
	{
		NativeDrawView view;
		uint64_t	   serial = 0;
		{
			std::unique_lock<std::mutex> lock(mCullMutex);
			mCullCv.wait(lock, [this]
						 { return mCullStop || mCullPending; });
			if (mCullStop)
				return;
			view = mCullRequest;
			view.mCollectKeys = mCullCollectPending;
			mCullCollectPending = false;
			serial = mCullNextSerial;
			mCullPending = false;
		}
		std::shared_ptr<const NativeCullFrame> completed;
		try
		{
			completed = BuildCullFrame(view, serial);
		}
		catch (...)
		{
			std::lock_guard<std::mutex> lock(mCullMutex);
			mCullFailed = true;
			continue;
		}
		{
			std::lock_guard<std::mutex> lock(mCullMutex);
			if (!completed->mPass[0].mVisibleKeys.empty())
				mPendingVisibleKeys = completed->mPass[0].mVisibleKeys;
			if (!mLatestCullFrame || completed->mSerial >= mLatestCullFrame->mSerial)
				mLatestCullFrame = std::move(completed);
		}
	}
}

bool ChunkMeshDraw::State::StartCullWorker()
{
	std::lock_guard<std::mutex> lock(mCullMutex);
	if (mCullRunning)
		return true;
	mCullStop = false;
	mCullFailed = false;
	try
	{
		mCullThread = std::thread(&State::CullWorkerMain, this);
	}
	catch (...)
	{
		return false;
	}
	mCullRunning = true;
	return true;
}

void ChunkMeshDraw::State::StopCullWorker()
{
	{
		std::lock_guard<std::mutex> lock(mCullMutex);
		if (!mCullRunning)
		{
			mLatestCullFrame.reset();
			mActiveCullFrame.reset();
			mPendingVisibleKeys.clear();
			mCullCollectPending = false;
			mCullFailed = false;
			return;
		}
		mCullStop = true;
		mCullPending = false;
	}
	mCullCv.notify_all();
	if (mCullThread.joinable())
		mCullThread.join();
	std::lock_guard<std::mutex> lock(mCullMutex);
	mCullRunning = false;
	mCullStop = false;
	mCullCollectPending = false;
	mCullFailed = false;
	mLatestCullFrame.reset();
	mActiveCullFrame.reset();
	mPendingVisibleKeys.clear();
}

uint64_t ChunkMeshDraw::State::SubmitCullRequest(const NativeDrawView &inView)
{
	uint64_t serial = 0;
	{
		std::lock_guard<std::mutex> lock(mCullMutex);
		mCullRequest = inView;
		mCullCollectPending = mCullCollectPending || inView.mCollectKeys;
		++mCullNextSerial;
		if (mCullNextSerial == 0)
			++mCullNextSerial;
		serial = mCullNextSerial;
		mCullPending = true;
	}
	mCullCv.notify_one();
	return serial;
}

std::shared_ptr<const NativeCullFrame> ChunkMeshDraw::State::LatestCullFrame()
{
	std::lock_guard<std::mutex> lock(mCullMutex);
	return mLatestCullFrame;
}

void ChunkMeshDraw::State::PublishCullFrame(const std::shared_ptr<const NativeCullFrame> &inFrame)
{
	std::lock_guard<std::mutex> lock(mCullMutex);
	if (!inFrame->mPass[0].mVisibleKeys.empty())
		mPendingVisibleKeys = inFrame->mPass[0].mVisibleKeys;
	if (!mLatestCullFrame || inFrame->mSerial >= mLatestCullFrame->mSerial)
		mLatestCullFrame = inFrame;
}

std::string ChunkMeshDraw::State::TakePendingVisibleKeys()
{
	std::lock_guard<std::mutex> lock(mCullMutex);
	std::string					keys;
	keys.swap(mPendingVisibleKeys);
	return keys;
}

bool ChunkMeshDraw::State::CullWorkerFailed()
{
	std::lock_guard<std::mutex> lock(mCullMutex);
	return mCullFailed;
}

bool SameRenderFrame(const NativeDrawView &inA, const NativeDrawView &inB)
{
	return inA.mOffset[0] == inB.mOffset[0] && inA.mOffset[1] == inB.mOffset[1] && inA.mOffset[2] == inB.mOffset[2] && inA.mLod == inB.mLod && inA.mLodStartChunks == inB.mLodStartChunks && inA.mOcclusionCull == inB.mOcclusionCull && (!inA.mOcclusionCull || inA.mOcclusionEpoch == inB.mOcclusionEpoch) && inA.mChunkSize == inB.mChunkSize && inA.mChunkHeight == inB.mChunkHeight && inA.mSectionSize == inB.mSectionSize && inA.mSectionCount == inB.mSectionCount && inA.mBlockSize == inB.mBlockSize;
}

bool ChunkMeshDraw::State::Draw(const NativeDrawView &inView, int inPass, NativeDrawResult &outResult)
{
	if (!StartCullWorker() || CullWorkerFailed())
	{
		g_faulted = true;
		g_faultReason = "cull_worker_failed";
		return false;
	}

	std::shared_ptr<const NativeCullFrame> frame = mActiveCullFrame;
	if (inPass == 0 || !frame || !SameRenderFrame(frame->mView, inView))
	{
		const uint64_t serial = SubmitCullRequest(inView);
		frame = LatestCullFrame();
		// Startup and InfMap frame-offset jumps cannot consume an old coordinate frame.
		if (!frame || !SameRenderFrame(frame->mView, inView))
		{
			try
			{
				frame = BuildCullFrame(inView, serial);
				PublishCullFrame(frame);
			}
			catch (...)
			{
				g_faulted = true;
				g_faultReason = "cull_fallback_failed";
				return false;
			}
		}
		mActiveCullFrame = frame;
	}

	outResult = {};
	auto				   &result = outResult;
	const NativeDrawResult &cull_result = frame->mPass[inPass];
	result.mTestedChunks = cull_result.mTestedChunks;
	result.mDistanceCulled = cull_result.mDistanceCulled;
	result.mFrustumCulled = cull_result.mFrustumCulled;
	result.mTestedSections = cull_result.mTestedSections;
	result.mVisibleChunks = cull_result.mVisibleChunks;
	result.mVisibleSections = cull_result.mVisibleSections;
	result.mCullUs = cull_result.mCullUs;
	result.mDirectionalDraw = inPass == 0 && g_directionalDrawEnabled.load(std::memory_order_relaxed);
	result.mLod = inPass == 0 && frame->mView.mLod;
	result.mLodStartChunks = frame->mView.mLodStartChunks;
	result.mOcclusionCull = cull_result.mOcclusionCull;
	result.mOcclusionApplied = cull_result.mOcclusionApplied;
	result.mOcclusionTestedSections = cull_result.mOcclusionTestedSections;
	result.mOcclusionCulledSections = cull_result.mOcclusionCulledSections;
	result.mOcclusionCulledChunks = cull_result.mOcclusionCulledChunks;
	result.mOcclusionComponentSections = cull_result.mOcclusionComponentSections;
	result.mOcclusionReachableSections = cull_result.mOcclusionReachableSections;
	if (inPass == 0)
		result.mVisibleKeys = TakePendingVisibleKeys();

	const double		 started = Plat_FloatTime();
	CMatRenderContextPtr ctx(source::GetMaterialSystem()->GetRenderContext());
	if (!ctx)
	{
		return false;
	}
	IMaterial *bound_material = nullptr;
	ctx->MatrixMode(MATERIAL_MODEL);
	const double chunk_w = inView.mChunkSize * inView.mBlockSize;
	const double chunk_h = inView.mChunkHeight * inView.mBlockSize;

	// Rendering stays on this thread, but it only consumes the worker-built visible list.
	for (const VisibleDrawEntry &visible : frame->mVisible[inPass])
	{
		if (mHiddenChunks.find(visible.mKey) != mHiddenChunks.end())
			continue;
		auto chunk = g_meshes.find(visible.mKey);
		if (chunk == g_meshes.end())
			continue;
		const double origin_x = visible.mCx * chunk_w + frame->mView.mOffset[0];
		const double origin_y = visible.mCy * chunk_w + frame->mView.mOffset[1];
		const double origin_z = visible.mCz * chunk_h + frame->mView.mOffset[2];
		bool		 pushed = false, chunk_drawn = false;
		uint64_t	 section_mask = visible.mSectionMask;
		while (section_mask)
		{
			const int sec = LowestSetBit(section_mask);
			section_mask &= section_mask - 1;
			if (sec < 0 || sec >= inView.mSectionCount)
				continue;
			const SectionMeshes &section = chunk->second.section[sec];
			const uint64_t		 section_bit = 1ull << sec;
			const bool			 use_lod = inPass == 0 && result.mLod && (visible.mLodMask & section_bit) != 0 && section.lodReady && !section.lodOpaque.empty();
			const auto			&meshes = use_lod		? section.lodOpaque
										  : inPass == 0 ? section.opaque
														: section.translucent;
			const auto			&mesh_materials = use_lod		? section.lodOpaqueMaterials
												  : inPass == 0 ? section.opaqueMaterials
																: section.translucentMaterials;
			const auto			&mesh_ranges = use_lod		 ? section.lodOpaqueRanges
											   : inPass == 0 ? section.opaqueRanges
															 : section.translucentRanges;
			if (meshes.empty() || mesh_materials.size() != meshes.size())
				continue;
			if (!pushed)
			{
				VMatrix model;
				model.Init(
					1, 0, 0, float(origin_x),
					0, 1, 0, float(origin_y),
					0, 0, 1, float(origin_z),
					0, 0, 0, 1);
				ctx->PushMatrix();
				ctx->LoadMatrix(model);
				pushed = true;
			}
			const uint64_t meshes_before = result.mMeshesDrawn;
			const uint64_t full_section_vertices = inPass == 0 ? (uint64_t)section.opaqueVerts : (uint64_t)section.translucentVerts;
			const uint64_t section_vertices = use_lod ? (uint64_t)section.lodOpaqueVerts : full_section_vertices;
			result.mVerticesFullDetail += full_section_vertices;
			if (use_lod && full_section_vertices > section_vertices)
				result.mVerticesLodCulled += full_section_vertices - section_vertices;
			result.mVerticesCandidate += section_vertices;
			uint64_t selected_vertices = 0;
			if (result.mDirectionalDraw && mesh_ranges.size() == meshes.size())
			{
				for (size_t mesh_index = 0; mesh_index < meshes.size(); ++mesh_index)
				{
					IMesh *mesh = meshes[mesh_index];
					if (!mesh)
						continue;
					const MeshDirectionalRanges					 &ranges = mesh_ranges[mesh_index];
					std::array<CPrimList, kDirectionalGroupCount> lists;
					int											  list_count = 0;
					for (int group = 0; group < 6; ++group)
					{
						const DirectionalRange &range = ranges.groups[group];
						if ((visible.mDirectionalMasks[group] & section_bit) == 0 || range.indexCount <= 0)
							continue;
						lists[list_count++] = CPrimList(range.firstIndex, range.indexCount);
						selected_vertices += (uint64_t)range.indexCount;
					}
					const DirectionalRange &unassigned = ranges.groups[kUnassignedDirectionalGroup];
					if (unassigned.indexCount > 0)
					{
						lists[list_count++] = CPrimList(unassigned.firstIndex, unassigned.indexCount);
						selected_vertices += (uint64_t)unassigned.indexCount;
					}
					if (list_count > 0)
					{
						IMaterial *material = mesh_materials[mesh_index];
						if (!material)
							continue;
						if (material != bound_material)
						{
							ctx->Bind(material);
							bound_material = material;
						}
						mesh->Draw(lists.data(), list_count);
						++result.mMeshesDrawn;
						if (use_lod)
							++result.mLodMeshesDrawn;
					}
				}
			}
			else
			{
				for (size_t mesh_index = 0; mesh_index < meshes.size(); ++mesh_index)
				{
					IMesh	  *mesh = meshes[mesh_index];
					IMaterial *material = mesh_materials[mesh_index];
					if (!mesh || !material)
						continue;
					if (material != bound_material)
					{
						ctx->Bind(material);
						bound_material = material;
					}
					mesh->Draw();
					++result.mMeshesDrawn;
					if (use_lod)
						++result.mLodMeshesDrawn;
				}
				selected_vertices = section_vertices;
			}
			if (result.mMeshesDrawn != meshes_before)
			{
				++result.mDrawnSections;
				if (use_lod)
				{
					++result.mLodSectionsDrawn;
					result.mLodApplied = true;
				}
				result.mVerticesDrawn += selected_vertices;
				chunk_drawn = true;
			}
		}
		if (pushed)
			ctx->PopMatrix();
		if (chunk_drawn)
			++result.mDrawnChunks;
	}
	result.mElapsedUs = (Plat_FloatTime() - started) * 1e6;
	result.mVerticesDirectionCulled = result.mVerticesCandidate > result.mVerticesDrawn
										  ? result.mVerticesCandidate - result.mVerticesDrawn
										  : 0;

	return true;
}
namespace
{
ChunkMeshDraw sChunkMeshDraw;
}
ChunkMeshDraw &GetChunkMeshDraw()
{
	return sChunkMeshDraw;
}
ChunkMeshDraw::ChunkMeshDraw() : mState(std::make_unique<State>()) {}
ChunkMeshDraw::~ChunkMeshDraw()
{
	StopWorker();
}
void ChunkMeshDraw::RefreshMetadata(uint64_t inKey)
{
	mState->RefreshDrawMetadata(inKey);
}
void ChunkMeshDraw::InvalidateMetadata()
{
	mState->InvalidateDirtyOcclusionMetadataInternal();
}
void ChunkMeshDraw::EraseMetadata(uint64_t inKey)
{
	mState->EraseDrawMetadata(inKey);
}
void ChunkMeshDraw::StopWorker()
{
	mState->StopCullWorker();
}
bool ChunkMeshDraw::StartWorker()
{
	return mState->StartCullWorker();
}
void ChunkMeshDraw::ForgetHidden(uint64_t inKey)
{
	mState->mHiddenChunks.erase(inKey);
}
void ChunkMeshDraw::ClearHidden()
{
	mState->mHiddenChunks.clear();
}
void ChunkMeshDraw::SetHidden(uint64_t inKey, bool inHidden)
{
	if (inHidden)
		mState->mHiddenChunks.insert(inKey);
	else
		mState->mHiddenChunks.erase(inKey);
	RefreshMetadata(inKey);
}
void ChunkMeshDraw::ClearMetadata()
{
	std::lock_guard<std::mutex> lock(mState->mDrawMetadataMutex);
	mState->mDrawMetadata.clear();
}
bool ChunkMeshDraw::Draw(const NativeDrawView &inView, int inPass, NativeDrawResult &outResult)
{
	return mState->Draw(inView, inPass, outResult);
}
uint64_t ChunkMeshDraw::GetMetadataEpoch() const
{
	return mState->mOcclusionMetadataEpoch.load(std::memory_order_relaxed);
}
ChunkMeshDrawStats ChunkMeshDraw::GetStats() const
{
	ChunkMeshDrawStats stats;
	{
		std::lock_guard<std::mutex> lock(mState->mDrawMetadataMutex);
		stats.mMetadataChunks = mState->mDrawMetadata.size();
		for (const auto &[key, metadata] : mState->mDrawMetadata)
			stats.mOcclusionReadySections += size_t(PopCount64(metadata.mOcclusionReadyMask));
	}
	{
		std::lock_guard<std::mutex> lock(mState->mCullMutex);
		stats.mWorkerRunning = mState->mCullRunning;
		stats.mPending = mState->mCullPending;
		stats.mFailed = mState->mCullFailed;
		stats.mSerial = mState->mLatestCullFrame ? mState->mLatestCullFrame->mSerial : 0;
		stats.mRequestSerial = mState->mCullNextSerial;
	}
	stats.mMetadataEpoch = mState->mOcclusionMetadataEpoch.load(std::memory_order_relaxed);
	return stats;
}
bool ChunkMeshDraw::DrawChunk(int inX, int inY, int inZ, int inPass)
{
	CMatRenderContextPtr ctx(source::GetMaterialSystem()->GetRenderContext());
	if (!ctx)
	{
		return false;
	}
	auto it = g_meshes.find(ws::PackChunkKey(inX, inY, inZ));
	if (it != g_meshes.end())
		for (int i = 0; i < 64; ++i)
		{
			const auto &meshes = inPass == 0 ? it->second.section[i].opaque : it->second.section[i].translucent;
			for (IMesh *mesh : meshes)
			{
				if (mesh)
					mesh->Draw();
			}
		}
	return true;
}
} // namespace mcmesh::meshbuild
