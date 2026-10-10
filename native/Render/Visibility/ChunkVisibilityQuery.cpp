#include "Render/Visibility/ChunkVisibilityQuery.h"
#include "World/ChunkKey.h"
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <utility>

namespace mcmesh::meshbuild
{
namespace
{
constexpr uint8_t cAllSectionFaces = 0x3f;
unsigned		  CountBits(uint64_t inValue)
{
	unsigned count = 0;
	while (inValue)
	{
		inValue &= inValue - 1;
		++count;
	}
	return count;
}
using SectionMaskMap = std::unordered_map<uint64_t, uint64_t>;
using SectionEntryMap = std::unordered_map<uint64_t, std::array<uint8_t, 64>>;
using DrawMetadataLookup = std::unordered_map<uint64_t, const DrawChunkMetadata *>;
struct SectionQueueEntry
{
	int		mX = 0, mY = 0, mZ = 0;
	uint8_t mIncoming = 0;
};
struct OcclusionTraversal
{
	bool		   mRequested = false, mApplied = false;
	SectionMaskMap mComponent, mReachable;
	uint64_t	   mComponentSections = 0, mReachableSections = 0;
};

constexpr int	  cOcclusionDX[6] = {0, 0, 1, -1, 0, 0};
constexpr int	  cOcclusionDY[6] = {0, 0, 0, 0, 1, -1};
constexpr int	  cOcclusionDZ[6] = {1, -1, 0, 0, 0, 0};
constexpr int	  cOcclusionOpposite[6] = {1, 0, 3, 2, 5, 4};
constexpr uint8_t cOcclusionCameraEntry = 0x40;

void AppendI32LE(std::string &ioBytes, int inValue)
{
	const uint32_t v = uint32_t(int32_t(inValue));
	ioBytes.push_back(char(v & 0xff));
	ioBytes.push_back(char((v >> 8) & 0xff));
	ioBytes.push_back(char((v >> 16) & 0xff));
	ioBytes.push_back(char((v >> 24) & 0xff));
}

bool AABBInFrustum(const NativeDrawView &inView, double inX, double inY, double inZ,
				   double inHx, double inHy, double inHz)
{
	if (!inView.mFrustum)
		return true;
	const double dx = inX - inView.mEye[0], dy = inY - inView.mEye[1], dz = inZ - inView.mEye[2];
	const double normals[5][3] = {
		{inView.mForward[0], inView.mForward[1], inView.mForward[2]},
		{inView.mRight[0] + inView.mForward[0] * inView.mTanX, inView.mRight[1] + inView.mForward[1] * inView.mTanX, inView.mRight[2] + inView.mForward[2] * inView.mTanX},
		{-inView.mRight[0] + inView.mForward[0] * inView.mTanX, -inView.mRight[1] + inView.mForward[1] * inView.mTanX, -inView.mRight[2] + inView.mForward[2] * inView.mTanX},
		{inView.mUp[0] + inView.mForward[0] * inView.mTanY, inView.mUp[1] + inView.mForward[1] * inView.mTanY, inView.mUp[2] + inView.mForward[2] * inView.mTanY},
		{-inView.mUp[0] + inView.mForward[0] * inView.mTanY, -inView.mUp[1] + inView.mForward[1] * inView.mTanY, -inView.mUp[2] + inView.mForward[2] * inView.mTanY},
	};
	for (const auto &n : normals)
	{
		const double radius = inHx * std::abs(n[0]) + inHy * std::abs(n[1]) + inHz * std::abs(n[2]);
		if (n[0] * dx + n[1] * dy + n[2] * dz < -radius)
			return false;
	}
	return true;
}

bool AABBInDistance(const NativeDrawView &inView, double inX, double inY, double inZ,
					double inHx, double inHy, double inHz)
{
	if (inView.mDistance <= 0)
		return true;
	const double slack = inView.mHorizontalDistance ? std::sqrt(inHx * inHx + inHy * inHy)
													: std::sqrt(inHx * inHx + inHy * inHy + inHz * inHz);
	const double limit = inView.mDistance + slack;
	const double dx = inX - inView.mEye[0], dy = inY - inView.mEye[1], dz = inZ - inView.mEye[2];
	return inView.mHorizontalDistance ? dx * dx + dy * dy <= limit * limit
									  : dx * dx + dy * dy + dz * dz <= limit * limit;
}

double DistanceSquaredToAABB(const NativeDrawView &inView,
							 double inMinX, double inMinY, double inMinZ, double inMaxX, double inMaxY, double inMaxZ)
{
	const double dx = inView.mEye[0] < inMinX	? inMinX - inView.mEye[0]
					  : inView.mEye[0] > inMaxX ? inView.mEye[0] - inMaxX
												: 0.0;
	const double dy = inView.mEye[1] < inMinY	? inMinY - inView.mEye[1]
					  : inView.mEye[1] > inMaxY ? inView.mEye[1] - inMaxY
												: 0.0;
	const double dz = inView.mEye[2] < inMinZ	? inMinZ - inView.mEye[2]
					  : inView.mEye[2] > inMaxZ ? inView.mEye[2] - inMaxZ
												: 0.0;
	return dx * dx + dy * dy + dz * dz;
}

int FloorDiv(int inValue, int inDivisor)
{
	int quotient = inValue / inDivisor;
	if (inValue % inDivisor < 0)
		--quotient;
	return quotient;
}

bool ResolveSection(const NativeDrawView &inView, const DrawMetadataLookup &inLookup, int inX, int inY, int inZ,
					const DrawChunkMetadata *&outMetadata, int &outSection)
{
	const int cx = FloorDiv(inX, inView.mSectionsX);
	const int cy = FloorDiv(inY, inView.mSectionsX);
	const int cz = FloorDiv(inZ, inView.mSectionsZ);
	if (cx < -1000000 || cx > 1000000 || cy < -1000000 || cy > 1000000 || cz < -1000000 || cz > 1000000)
		return false;
	const auto found = inLookup.find(world::PackChunkKey(cx, cy, cz));
	if (found == inLookup.end())
		return false;
	const int sx = inX - cx * inView.mSectionsX;
	const int sy = inY - cy * inView.mSectionsX;
	const int sz = inZ - cz * inView.mSectionsZ;
	outSection = sx + sy * inView.mSectionsX + sz * inView.mSectionsX * inView.mSectionsX;
	if (outSection < 0 || outSection >= inView.mSectionCount || outSection >= 64)
		return false;
	outMetadata = found->second;
	return outMetadata != nullptr;
}

bool SectionInCullBounds(const NativeDrawView &inView, int inX, int inY, int inZ)
{
	const double size = inView.mSectionSize * inView.mBlockSize;
	const double half = size * 0.5;
	const double center_x = inX * size + inView.mOffset[0] + half;
	const double center_y = inY * size + inView.mOffset[1] + half;
	const double center_z = inZ * size + inView.mOffset[2] + half;
	return AABBInDistance(inView, center_x, center_y, center_z, half, half, half) && AABBInFrustum(inView, center_x, center_y, center_z, half, half, half);
}

bool MarkSection(SectionMaskMap &ioSections, uint64_t inKey, int inSection)
{
	const uint64_t bit = 1ull << inSection;
	uint64_t	  &mask = ioSections[inKey];
	if (mask & bit)
		return false;
	mask |= bit;
	return true;
}

bool HasSection(const SectionMaskMap &inSections, uint64_t inKey, int inSection)
{
	const auto found = inSections.find(inKey);
	return found != inSections.end() && (found->second & (1ull << inSection)) != 0;
}

OcclusionTraversal BuildOcclusionTraversal(const NativeDrawView					&inView,
										   const std::vector<DrawChunkMetadata> &inMetadataSnapshot)
{
	OcclusionTraversal traversal;
	traversal.mRequested = inView.mOcclusionCull;
	if (!inView.mOcclusionCull || inMetadataSnapshot.empty())
		return traversal;

	DrawMetadataLookup lookup;
	lookup.reserve(inMetadataSnapshot.size() * 2 + 1);
	for (const DrawChunkMetadata &metadata : inMetadataSnapshot)
		lookup.emplace(metadata.mKey, &metadata);

	const double	 section_size = inView.mSectionSize * inView.mBlockSize;
	const double	 local_x = (inView.mEye[0] - inView.mOffset[0]) / section_size;
	const double	 local_y = (inView.mEye[1] - inView.mOffset[1]) / section_size;
	const double	 local_z = (inView.mEye[2] - inView.mOffset[2]) / section_size;
	constexpr double min_coord = double(std::numeric_limits<int>::min()) + 2.0;
	constexpr double max_coord = double(std::numeric_limits<int>::max()) - 2.0;
	if (local_x < min_coord || local_x > max_coord || local_y < min_coord || local_y > max_coord || local_z < min_coord || local_z > max_coord)
		return traversal;
	const int camera_x = int(std::floor(local_x));
	const int camera_y = int(std::floor(local_y));
	const int camera_z = int(std::floor(local_z));

	const DrawChunkMetadata *camera_metadata = nullptr;
	int						 camera_section = 0;
	if (!ResolveSection(inView, lookup, camera_x, camera_y, camera_z, camera_metadata, camera_section))
		return traversal;

	traversal.mComponent.reserve(inMetadataSnapshot.size() * 2 + 1);
	std::vector<SectionQueueEntry> queue;
	queue.reserve(inMetadataSnapshot.size() * 4 + 16);
	MarkSection(traversal.mComponent, camera_metadata->mKey, camera_section);
	++traversal.mComponentSections;
	queue.push_back({camera_x, camera_y, camera_z, 0});
	for (size_t head = 0; head < queue.size(); ++head)
	{
		const SectionQueueEntry current = queue[head];
		for (int direction = 0; direction < 6; ++direction)
		{
			const int nx = current.mX + cOcclusionDX[direction];
			const int ny = current.mY + cOcclusionDY[direction];
			const int nz = current.mZ + cOcclusionDZ[direction];
			if (!SectionInCullBounds(inView, nx, ny, nz))
				continue;
			const DrawChunkMetadata *neighbor_metadata = nullptr;
			int						 neighbor_section = 0;
			if (!ResolveSection(inView, lookup, nx, ny, nz, neighbor_metadata, neighbor_section))
				continue;
			if (!MarkSection(traversal.mComponent, neighbor_metadata->mKey, neighbor_section))
				continue;
			++traversal.mComponentSections;
			queue.push_back({nx, ny, nz, 0});
		}
	}

	SectionEntryMap entries;
	entries.reserve(traversal.mComponent.size() * 2 + 1);
	traversal.mReachable.reserve(traversal.mComponent.size() * 2 + 1);
	queue.clear();
	queue.push_back({camera_x, camera_y, camera_z, cOcclusionCameraEntry});
	for (size_t head = 0; head < queue.size(); ++head)
	{
		const SectionQueueEntry	 current = queue[head];
		const DrawChunkMetadata *metadata = nullptr;
		int						 section = 0;
		if (!ResolveSection(inView, lookup, current.mX, current.mY, current.mZ, metadata, section) || !HasSection(traversal.mComponent, metadata->mKey, section))
			continue;

		uint8_t		 &seen_entries = entries[metadata->mKey][section];
		const uint8_t fresh_entries = uint8_t(current.mIncoming & ~seen_entries);
		if (!fresh_entries)
			continue;
		seen_entries = uint8_t(seen_entries | fresh_entries);
		if (MarkSection(traversal.mReachable, metadata->mKey, section))
			++traversal.mReachableSections;

		uint8_t	   exits = (fresh_entries & cOcclusionCameraEntry) ? cAllSectionFaces : 0;
		const bool ready = (metadata->mOcclusionReadyMask & (1ull << section)) != 0;
		for (int entry = 0; entry < 6; ++entry)
		{
			if ((fresh_entries & (1u << entry)) == 0)
				continue;
			exits = uint8_t(exits | (ready
										 ? metadata->mOcclusionVisibleFrom[section][entry]
										 : cAllSectionFaces));
		}
		for (int direction = 0; direction < 6; ++direction)
		{
			if ((exits & (1u << direction)) == 0)
				continue;
			const int				 nx = current.mX + cOcclusionDX[direction];
			const int				 ny = current.mY + cOcclusionDY[direction];
			const int				 nz = current.mZ + cOcclusionDZ[direction];
			const DrawChunkMetadata *neighbor_metadata = nullptr;
			int						 neighbor_section = 0;
			if (!ResolveSection(inView, lookup, nx, ny, nz, neighbor_metadata, neighbor_section) || !HasSection(traversal.mComponent, neighbor_metadata->mKey, neighbor_section))
				continue;
			queue.push_back({nx, ny, nz, uint8_t(1u << cOcclusionOpposite[direction])});
		}
	}

	traversal.mApplied = true;
	return traversal;
}

} // namespace
std::shared_ptr<NativeCullFrame> BuildChunkCullFrame(const NativeDrawView &inView, uint64_t inSerial, const std::vector<DrawChunkMetadata> &inMetadataSnapshot)
{
	// Validate the request once; adjacency/section loops consume this contract.
	if (inView.mSectionCount < 1 || inView.mSectionCount > 64 || inView.mSectionSize < 1 || inView.mSectionsX < 1 || inView.mSectionsX > 64 || inView.mSectionsZ < 1 || inView.mSectionsZ > 64 || inView.mSectionsX * inView.mSectionsX * inView.mSectionsZ != inView.mSectionCount || int64_t(inView.mSectionSize) * inView.mSectionsX != inView.mChunkSize || int64_t(inView.mSectionSize) * inView.mSectionsZ != inView.mChunkHeight || !std::isfinite(inView.mBlockSize) || inView.mBlockSize <= 0)
		throw std::invalid_argument("invalid legacy cull configuration");
	auto frame = std::make_shared<NativeCullFrame>();
	frame->mSerial = inSerial;
	frame->mView = inView;
	const auto				 started = std::chrono::steady_clock::now();
	const double			 chunk_w = inView.mChunkSize * inView.mBlockSize;
	const double			 chunk_h = inView.mChunkHeight * inView.mBlockSize;
	const double			 chunk_half_w = chunk_w * 0.5, chunk_half_h = chunk_h * 0.5;
	const double			 section_size = inView.mSectionSize * inView.mBlockSize;
	const double			 section_half = section_size * 0.5;
	const OcclusionTraversal occlusion = BuildOcclusionTraversal(inView, inMetadataSnapshot);
	for (int pass = 0; pass < 2; ++pass)
	{
		frame->mPass[pass].mOcclusionCull = occlusion.mRequested;
		frame->mPass[pass].mOcclusionApplied = occlusion.mApplied;
		frame->mPass[pass].mOcclusionComponentSections = occlusion.mComponentSections;
		frame->mPass[pass].mOcclusionReachableSections = occlusion.mReachableSections;
	}

	frame->mVisible[0].reserve(inMetadataSnapshot.size());
	frame->mVisible[1].reserve(inMetadataSnapshot.size() / 4 + 1);
	if (inView.mCollectKeys)
		frame->mPass[0].mVisibleKeys.reserve(inMetadataSnapshot.size() * 12);
	for (const DrawChunkMetadata &metadata : inMetadataSnapshot)
	{
		if (metadata.mHidden)
			continue;
		const double origin_x = metadata.mCx * chunk_w + inView.mOffset[0];
		const double origin_y = metadata.mCy * chunk_w + inView.mOffset[1];
		const double origin_z = metadata.mCz * chunk_h + inView.mOffset[2];
		const double center_x = origin_x + chunk_half_w, center_y = origin_y + chunk_half_w, center_z = origin_z + chunk_half_h;
		for (int pass = 0; pass < 2; ++pass)
		{
			uint64_t section_mask = metadata.mPassMask[pass];
			if (!section_mask)
				continue;
			NativeDrawResult &result = frame->mPass[pass];
			++result.mTestedChunks;
			result.mTestedSections += CountBits(section_mask);
			if (!AABBInDistance(inView, center_x, center_y, center_z, chunk_half_w, chunk_half_w, chunk_half_h))
			{
				++result.mDistanceCulled;
				continue;
			}
			if (!AABBInFrustum(inView, center_x, center_y, center_z, chunk_half_w, chunk_half_w, chunk_half_h))
			{
				++result.mFrustumCulled;
				continue;
			}
			uint64_t				frustum_visible_mask = 0;
			uint64_t				lod_mask = 0;
			std::array<uint64_t, 6> directional_masks{};
			for (int sec = 0; sec < inView.mSectionCount; ++sec)
			{
				if ((section_mask & (1ull << sec)) == 0)
					continue;
				const int	 sx = sec % inView.mSectionsX;
				const int	 sy = (sec / inView.mSectionsX) % inView.mSectionsX;
				const int	 sz = sec / (inView.mSectionsX * inView.mSectionsX);
				const double min_x = origin_x + sx * section_size;
				const double min_y = origin_y + sy * section_size;
				const double min_z = origin_z + sz * section_size;
				const double max_x = min_x + section_size;
				const double max_y = min_y + section_size;
				const double max_z = min_z + section_size;
				if (!AABBInFrustum(inView, min_x + section_half, min_y + section_half, min_z + section_half,
								   section_half, section_half, section_half))
					continue;
				const uint64_t section_bit = 1ull << sec;
				frustum_visible_mask |= section_bit;
				if (pass == 0 && inView.mLod && (metadata.mLodReadyMask & section_bit) != 0 && DistanceSquaredToAABB(inView, min_x, min_y, min_z, max_x, max_y, max_z) >= inView.mLodStartDistance * inView.mLodStartDistance)
					lod_mask |= section_bit;
				if (inView.mEye[2] >= min_z)
					directional_masks[0] |= section_bit; // +Z
				if (inView.mEye[2] <= max_z)
					directional_masks[1] |= section_bit; // -Z
				if (inView.mEye[0] >= min_x)
					directional_masks[2] |= section_bit; // +X
				if (inView.mEye[0] <= max_x)
					directional_masks[3] |= section_bit; // -X
				if (inView.mEye[1] >= min_y)
					directional_masks[4] |= section_bit; // +Y
				if (inView.mEye[1] <= max_y)
					directional_masks[5] |= section_bit; // -Y
			}
			if (!frustum_visible_mask)
			{
				++result.mFrustumCulled;
				continue;
			}
			if (pass == 0 && inView.mCollectKeys)
			{
				AppendI32LE(result.mVisibleKeys, metadata.mCx);
				AppendI32LE(result.mVisibleKeys, metadata.mCy);
				AppendI32LE(result.mVisibleKeys, metadata.mCz);
			}

			uint64_t visible_mask = frustum_visible_mask;
			if (occlusion.mApplied)
			{
				uint64_t   component_mask = 0;
				const auto component = occlusion.mComponent.find(metadata.mKey);
				if (component != occlusion.mComponent.end())
					component_mask = component->second;
				const uint64_t tested_mask = visible_mask & component_mask;
				result.mOcclusionTestedSections += CountBits(tested_mask);
				if (tested_mask)
				{
					uint64_t   reachable_mask = 0;
					const auto reachable = occlusion.mReachable.find(metadata.mKey);
					if (reachable != occlusion.mReachable.end())
						reachable_mask = reachable->second;
					const uint64_t culled_mask = tested_mask & ~reachable_mask;
					result.mOcclusionCulledSections += CountBits(culled_mask);
					visible_mask &= ~culled_mask;
				}
			}
			if (!visible_mask)
			{
				++result.mOcclusionCulledChunks;
				continue;
			}
			for (uint64_t &mask : directional_masks)
				mask &= visible_mask;
			++result.mVisibleChunks;
			result.mVisibleSections += CountBits(visible_mask);
			VisibleDrawEntry entry;
			entry.mKey = metadata.mKey;
			entry.mSectionMask = visible_mask;
			entry.mLodMask = lod_mask & visible_mask;
			entry.mCx = metadata.mCx;
			entry.mCy = metadata.mCy;
			entry.mCz = metadata.mCz;
			entry.mDirectionalMasks = directional_masks;
			frame->mVisible[pass].push_back(std::move(entry));
		}
	}
	const double elapsed_us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - started).count();
	frame->mPass[0].mCullUs = elapsed_us;
	frame->mPass[1].mCullUs = elapsed_us;
	return frame;
}

} // namespace mcmesh::meshbuild
