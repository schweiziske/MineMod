#pragma once
#include "World/WorldStore.h"
#include "Mesh/SectionWorker.h"

namespace mcmesh::world
{
struct MeshRecipe
{
	unsigned index = 0;
	bool	 model = false, blocking = false;
	size_t	 maxQuads = 0;
	int		 fluidIndex = -1;
	bool	 fluidOnly = false;
	unsigned shapeSelector = 0;
};
// Contains CPU values only. Lua material groups are numeric publication IDs.
class MeshInstances final : public l2::InstanceSource
{
public:
	MeshInstances(std::shared_ptr<const MeshSnapshot> inSnapshot, Coord inChunk, unsigned inSection,
				  std::unordered_map<uint32_t, MeshRecipe> inRecipes, bool inTopology,
				  std::unordered_map<uint32_t, bool> inBlockingStates = {});
	void   populate(l2::Input &input, const std::atomic<bool> &cancelled) const override;
	size_t maxQuads() const override { return quads_; }
	size_t bytes() const override;

private:
	std::shared_ptr<const MeshSnapshot>		 snapshot_;
	std::shared_ptr<const Section>			 section_;
	std::unordered_map<uint32_t, MeshRecipe> recipes_;
	// Complete visual classification for mixed Native/Lua geometry. Validated
	// against the immutable section histogram before the worker owns this input.
	std::unordered_map<uint32_t, bool> mBlockingStates;
	Coord									 chunk_, base_;
	size_t									 quads_ = 0;
	bool									 topology_ = false;
};
/// Worker-local dense profile view of one mesh halo. Shape and fluid queries in
/// the voxel loops become array reads; the snapshot keeps every profile alive.
/// Positions outside the halo fall back to the snapshot's own lookup.
class MeshProfileGrid final : public l2::FluidSource, public l2::ShapeSource
{
public:
	explicit MeshProfileGrid(std::shared_ptr<const MeshSnapshot> inSnapshot);
	const l2::FluidState &fluid(int x, int y, int z) const override { return GetProfile(x, y, z).fluid; }
	const l2::Shape		 &shape(int x, int y, int z) const override { return *GetProfile(x, y, z).shape; }
	static size_t		  Bytes(const MeshSnapshot &inSnapshot);

private:
	const Profile					   &GetProfile(int x, int y, int z) const;
	std::shared_ptr<const MeshSnapshot> mSnapshot;
	std::vector<const Profile *>		mProfiles;
};
l2::Topology meshTopology(std::vector<uint8_t> cells, unsigned size);
} // namespace mcmesh::world
