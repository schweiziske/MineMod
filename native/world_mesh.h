#pragma once
#include "world_core.h"
#include "l2_worker.h"

namespace mcmesh::world {
struct MeshRecipe {
    unsigned index = 0;
    bool model = false, blocking = false;
    size_t maxQuads = 0;
    int fluidIndex = -1;
    bool fluidOnly = false;
    unsigned shapeSelector = 0;
};
// Contains CPU values only. Lua material groups are numeric publication IDs.
class MeshInstances final : public l2::InstanceSource {
public:
    MeshInstances(std::shared_ptr<const MeshSnapshot> snapshot, Coord chunk, unsigned section,
        std::unordered_map<uint32_t, MeshRecipe> recipes, bool topology);
    void populate(l2::Input& input, const std::atomic<bool>& cancelled) const override;
    size_t maxQuads() const override { return quads_; }
    size_t bytes() const override;
private:
    std::shared_ptr<const MeshSnapshot> snapshot_;
    std::shared_ptr<const Section> section_;
    std::unordered_map<uint32_t, MeshRecipe> recipes_;
    Coord chunk_, base_;
    size_t quads_ = 0;
    bool topology_ = false;
};
l2::Topology meshTopology(std::vector<uint8_t> cells, unsigned size);
}
