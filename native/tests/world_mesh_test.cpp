#include "../world_mesh.h"
#include <chrono>
#include <iostream>
#include <stdexcept>

using namespace mcmesh;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void light(world::Store& store) {
    std::atomic<bool> cancel{false};
    auto result = world::rebuildLight(store.snapshot(), cancel);
    check(!store.commit(*result).stale, "fresh lighting rejected");
}
world::Mutation edit(const world::Config& cfg, world::Coord pos, unsigned state) {
    world::Mutation result;
    result.chunk = cfg.chunkAt(pos);
    result.cells.push_back({cfg.localIndex(pos), state});
    return result;
}
l2::Cube cube() {
    l2::Cube result;
    result.block = 1;
    for (unsigned face = 0; face < 6; ++face) {
        auto& w = result.faces[face];
        w.geometry.face = face;
        w.geometry.flags = 9;
        for (unsigned c = 0; c < 4; ++c) {
            w.geometry.indices[c] = c;
            for (unsigned a = 0; a < 3; ++a) w.geometry.positions[c][a] = (c >> (a % 2)) & 1;
        }
        result.groups[face] = face + 1;
    }
    l2::validateCube(result);
    return result;
}
void wait(l2::WorkerPool& pool, uint64_t id) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (pool.state(id) != l2::JobState::Ready && pool.state(id) != l2::JobState::Failed) {
        check(std::chrono::steady_clock::now() < deadline, "mesh worker timed out");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
void topology() {
    auto open = world::meshTopology(std::vector<uint8_t>(64), 4);
    check(open.graphOpen && open.uniform == 63 && open.cells.empty(), "open topology");
    auto solid = world::meshTopology(std::vector<uint8_t>(64, 64), 4);
    check(!solid.graphOpen && solid.uniform == 64 && solid.faces[0] == 0, "solid topology");
    std::vector<uint8_t> cells(64, 64);
    for (unsigned x = 0; x < 4; ++x) cells[x + 4 * (1 + 4)] = 0;
    auto tunnel = world::meshTopology(cells, 4);
    check(!tunnel.graphOpen && !tunnel.uniform && tunnel.faces[2] == 12
        && tunnel.faces[3] == 12 && tunnel.faces[0] == 0 && tunnel.cells[20] == 12,
        "tunnel connectivity/face order");
    cells[42] = 0;
    auto closed = world::meshTopology(cells, 4);
    check(closed.cells[42] == 0 && closed.cells[41] == 64, "sealed pocket topology");
}
void worldMesh() {
    world::Config cfg;
    cfg.chunkSize = cfg.chunkHeight = 8; cfg.sectionSize = 4; cfg.blockSize = 47.25;
    auto catalog = std::make_shared<world::Catalog>();
    catalog->states.resize(2);
    catalog->states[1] = {0, 15, 16, 0xef000, 9, 0.2f};
    world::Store store(cfg, catalog);
    auto mutation = edit(cfg, {-4,1,1}, 1);
    mutation.cells.push_back({cfg.localIndex({-3,1,1}), 1});
    store.apply(0, {mutation});
    check(!store.meshReady({-1,0,0}, 1), "unlit section was ready");
    light(store);
    check(store.meshReady({-1,0,0}, 1), "lit section was deferred");
    store.apply(store.revision(), {edit(cfg, {240,0,0}, 1)});
    check(store.meshReady({-1,0,0}, 1) && !store.meshReady({30,0,0}, 0),
        "distant light work deferred independent section");
    light(store);
    auto snapshot = std::make_shared<world::MeshSnapshot>(store.meshSnapshot({-1,0,0}, 1));
    check(snapshot->world->chunks.at({-1,0,0})->sections[1]->counts.at(1) == 2, "state histogram");
    int origin[3] = {snapshot->origin.x,snapshot->origin.y,snapshot->origin.z};
    int dims[3] = {snapshot->dimensions.x,snapshot->dimensions.y,snapshot->dimensions.z};
    auto input = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, snapshot));
    input->blockSize = cfg.blockSize;
    input->cubes.push_back(cube());
    input->instances = std::make_shared<world::MeshInstances>(snapshot, world::Coord{-1,0,0}, 1,
        std::unordered_map<uint32_t, world::MeshRecipe>{{1, {0, false, true, 6}}}, true);
    check(input->instances->maxQuads() == 12, "histogram reservation");
    l2::WorkerPool pool;
    pool.start(2);
    const auto id = pool.submit(std::move(input));
    // Publishing new storage must not change an already queued worker's inputs.
    store.apply(store.revision(), {edit(cfg, {-3,1,1}, 0)});
    check(!store.meshReady({-1,0,0}, 1), "edited halo was ready");
    check(!store.current(*snapshot) && snapshot->read({-3,1,1}).renderClass == 9, "immutable mesh snapshot");
    check(store.chunk({-1,0,0})->sections[1]->counts.at(1) == 1, "delete histogram");
    wait(pool, id);
    auto result = pool.ready(id);
    check(result->error.empty(), result->error.c_str());
    check(result->sectionVoxels == 2 && result->sectionQuads == 10, "worker traversal/internal faces");
    check(result->topology.graphOpen && result->topology.cells[20] == 64, "worker topology publication");
    for (const auto& part : result->parts) {
        check(part.bounds[0] >= float(4 * cfg.blockSize) && part.bounds[3] <= float(6 * cfg.blockSize),
            "mesh transform used MC world coordinates or wrong block size");
    }
    pool.stop();
    light(store);
    // A known-air chunk outside the flood domain still supports implicit sky.
    world::Mutation air;
    air.kind = world::Mutation::Kind::Replace;
    air.chunk = {30,0,0}; air.terrainPresent = false;
    store.apply(store.revision(), {air}); light(store);
    auto sky = store.meshSnapshot(air.chunk, 0);
    check(sky.read({240,0,0}).sky() == 15, "known-air sky");
    store.apply(store.revision(), {edit(cfg, {240,0,80}, 1)});
    check(!store.current(sky) && sky.read({240,0,0}).sky() == 15, "implicit sky column invalidation");
    light(store);
    auto shaded = store.meshSnapshot(air.chunk, 0);
    check(shaded.read({240,0,0}).sky() == 0, "new distant roof ignored");
}
struct Air final : l2::CellSource {
    uint32_t neighbour = 0;
    l2::Cell read(int, int, int) const override { return {1048576u | 0xf0u, 1, neighbour}; }
    size_t bytes() const override { return sizeof(*this); }
};
void models() {
    auto model = std::make_shared<l2::Model>();
    model->block = 1;
    l2::ModelQuad quad;
    quad.work = cube().faces[0]; quad.cullFace = 1;
    quad.withoutAO = quad.work.geometry; quad.withoutAO.flags = 0;
    l2::ModelAlternative first;
    first.modelAO = false; first.quads.push_back(quad);
    model->groups.push_back({{first}, 1, 0});
    first.modelAO = true;
    model->groups.push_back({{first}, 2, 0});
    l2::validateModel(*model);
    check(model->maxQuads == 2, "multipart reservation");
    auto air = std::make_shared<Air>();
    const int origin[3] = {-2,-2,-2}, dims[3] = {5,5,5};
    const auto build = [&](bool leaves, uint32_t neighbour) {
        model->keepInternalFaces = leaves; air->neighbour = neighbour;
        l2::Input in(l2::Snapshot(origin, dims, air));
        in.models.push_back({model, 7});
        l2::Voxel voxel; voxel.model = true; in.voxels.push_back(voxel);
        in.snapshot.freeze();
        std::vector<unsigned> groups;
        std::atomic<bool> cancel{false};
        l2::expandVoxels(in, groups, cancel);
        if (in.parts.empty()) return size_t(0);
        check(groups[0] == 7, "model material group");
        for (const auto& work : in.parts[0]) check(work.geometry.flags == 0, "first selected part AO policy lost");
        return in.parts[0].size();
    };
    check(build(false, 0) == 2, "multipart faces");
    check(build(false, 11) == 0 && build(true, 11) == 2, "leaf internal face policy");
    check(build(true, 9) == 0, "leaf faces through opaque neighbours");
}
}
int main() {
    try {
        topology(); worldMesh(); models();
        std::cout << "World mesh: owned snapshots, histogram, transforms, sky invalidation, topology and models passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
