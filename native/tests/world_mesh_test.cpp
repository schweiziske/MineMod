#include "../world_mesh.h"
#include <chrono>
#include <iostream>
#include <limits>
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
void snapshotMemory() {
    world::Config cfg;
    cfg.chunkSize = cfg.chunkHeight = 8; cfg.sectionSize = 4;
    auto catalog = std::make_shared<world::Catalog>();
    catalog->states.resize(2);
    world::Store store(cfg, catalog);
    auto mutation = edit(cfg, {1,1,1}, 1);
    mutation.cells.push_back({cfg.localIndex({1,1,5}), 1});
    store.apply(0, {mutation});
    auto first = store.meshSnapshot({0,0,0}, 0, true);
    l2::MemoryUsage a;
    first.memoryUsage(a);
    const auto rawCount = a.shared.size();
    a.normalize();
    check(a.shared.size() < rawCount, "chunk/column aliases were not deduplicated");
    const auto contains = [](const l2::MemoryUsage& usage, const void* owner) {
        for (const auto& entry : usage.shared) if (entry.owner.get() == owner) return true;
        return false;
    };
    check(contains(a, first.world->catalog.get()), "sealed catalog omitted from shared footprint");
    const auto oldChunk = first.world->chunks.at({0,0,0});
    store.apply(store.revision(), {edit(cfg, {2,1,1}, 1)});
    auto second = store.meshSnapshot({0,0,0}, 0, true);
    const auto newChunk = second.world->chunks.at({0,0,0});
    l2::MemoryUsage b;
    second.memoryUsage(b);
    b.normalize();
    check(oldChunk != newChunk && contains(a, oldChunk.get()) && contains(b, newChunk.get()),
        "different chunk revisions shared an accounting identity");
    check(oldChunk->sections[4] == newChunk->sections[4]
        && contains(a, oldChunk->sections[4].get()) && contains(b, oldChunk->sections[4].get()),
        "unchanged section not shared across chunk revisions");
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
    bool blocked = false;
    try { store.meshSnapshot({-1,0,0}, 1); } catch (const std::exception&) { blocked = true; }
    check(blocked, "strict snapshot accepted pending lighting");
    auto pending = store.meshSnapshot({-1,0,0}, 1, true);
    check(store.geometryCurrent(pending) && !store.current(pending)
        && pending.read({-3,1,1}).renderClass == 0, "edit geometry waited for lighting or used old terrain");
    check(!store.geometryCurrent(*snapshot), "deferred lighting accepted old terrain");
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
    auto pendingSource = std::make_shared<const world::MeshSnapshot>(pending);
    auto pendingInput = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, pendingSource));
    pendingInput->blockSize = cfg.blockSize;
    pendingInput->cubes.push_back(cube());
    pendingInput->instances = std::make_shared<world::MeshInstances>(pendingSource, world::Coord{-1,0,0}, 1,
        std::unordered_map<uint32_t, world::MeshRecipe>{{1, {0, false, true, 6}}}, true);
    const auto pendingId = pool.submit(std::move(pendingInput));
    wait(pool, pendingId);
    const auto pendingResult = pool.ready(pendingId);
    check(pendingResult->error.empty(), pendingResult->error.c_str());
    check(pendingResult->sectionVoxels == 1 && pendingResult->sectionQuads == 6
        && !store.meshReady({-1,0,0}, 1), "edit worker waited for lighting or built obsolete terrain");
    pool.stop();
    light(store);
    check(store.geometryCurrent(pending), "light publication invalidated edit geometry");
    check(store.current(store.meshSnapshot({-1,0,0}, 1)), "settled relight snapshot was stale");
    // A known-air chunk outside the flood domain still supports implicit sky.
    world::Mutation air;
    air.kind = world::Mutation::Kind::Replace;
    air.chunk = {30,0,0}; air.terrainPresent = false;
    store.apply(store.revision(), {air}); light(store);
    auto sky = store.meshSnapshot(air.chunk, 0);
    check(sky.read({240,0,0}).sky() == 15, "known-air sky");
    store.apply(store.revision(), {edit(cfg, {240,0,80}, 1)});
    check(!store.current(sky) && sky.read({240,0,0}).sky() == 15, "implicit sky column invalidation");
    check(store.geometryCurrent(sky), "distant shadow invalidated unchanged geometry");
    light(store);
    auto shaded = store.meshSnapshot(air.chunk, 0);
    check(shaded.read({240,0,0}).sky() == 0, "new distant roof ignored");
    check(store.geometryCurrent(sky) && !store.current(sky), "lighting-only publication lost dependency separation");
    store.reconfigure(cfg);
    check(!store.geometryCurrent(sky), "world reconfiguration accepted old geometry");
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
std::shared_ptr<l2::Model> stairModel() {
    auto model = std::make_shared<l2::Model>();
    model->block = 1; model->shapeSelector = 1;
    l2::ModelGroup group;
    for (unsigned variant = 0; variant < 5; ++variant) {
        l2::ModelAlternative alternative;
        l2::ModelQuad quad;
        quad.work = cube().faces[0]; quad.work.command.tint = variant;
        quad.withoutAO = quad.work.geometry;
        alternative.quads.push_back(quad);
        group.alternatives.push_back(alternative);
    }
    model->groups.push_back(group);
    l2::validateModel(*model);
    return model;
}
void shapeValidation() {
    const auto rejected = [](auto fn) {
        try { fn(); } catch (const std::exception&) { return true; }
        return false;
    };
    l2::Shape shape;
    shape.validate();
    shape.selector = 1;
    check(rejected([&] { shape.validate(); }), "missing stair variants accepted");
    shape.stair = 0; shape.variants.resize(5);
    shape.validate();
    shape.variants[0].push_back({0,0,0,1,1,std::numeric_limits<double>::infinity()});
    check(rejected([&] { shape.validate(); }), "nonfinite render box accepted");
    auto model = stairModel();
    model->groups[0].alternatives.pop_back();
    check(rejected([&] { l2::validateModel(*model); }), "shape variant count mismatch accepted");
    model = stairModel();
    auto& quad = model->groups[0].alternatives[0].quads[0];
    quad.shapeCull = true; quad.box = {0,0,0,1,1,1};
    check(rejected([&] { l2::validateModel(*model); }), "shape cull without face accepted");
    quad.cullFace = 1; quad.box[3] = -1;
    check(rejected([&] { l2::validateModel(*model); }), "inverted shape cull accepted");
    quad.box[3] = 1;
    l2::validateModel(*model);
    const int origin[] = {-2,-2,-2}, dims[] = {5,5,5};
    l2::Input input(l2::Snapshot(origin, dims, std::make_shared<Air>()));
    input.models.push_back({model, 1});
    check(rejected([&] { input.reservation(); }), "missing world shape source accepted");
    const l2::ShapeBox full{0,0,0,1,1,1};
    constexpr int offsets[6][3] = {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}};
    for (unsigned face = 0; face < 6; ++face) {
        const unsigned split = face / 2 == 1 ? 1 : 0;
        auto first = full, second = full;
        first[split+3] = second[split] = 0.5;
        check(l2::shapeCovered(full, face, {first,second}, offsets[face]), "split face union not covered");
        first[split+3] = 0.4;
        check(!l2::shapeCovered(full, face, {first,second}, offsets[face]), "gap in face union ignored");
        const int wrongOffset[] = {0,0,0};
        check(!l2::shapeCovered(full, face, {full}, wrongOffset), "wrong neighbour offset covered face");
    }
}
void shapes() {
    world::Config cfg;
    cfg.chunkSize = cfg.chunkHeight = 8; cfg.sectionSize = 4; cfg.blockSize = 47.25;
    cfg.skyEnabled = false;
    auto catalog = std::make_shared<world::Catalog>();
    catalog->states.resize(3);
    for (unsigned state : {1u, 2u}) {
        auto shape = std::make_shared<l2::Shape>();
        shape->selector = 1; shape->stair = state == 1 ? 0 : 2;
        shape->variants.resize(5); shape->validate();
        catalog->states[state].shape = shape;
        catalog->states[state].renderClass = state * 8;
    }
    world::Store store(cfg, catalog);
    store.apply(0, {edit(cfg, {-4,0,1}, 1), edit(cfg, {-4,-1,1}, 2)});
    light(store);
    auto model = stairModel();
    const auto make = [&](std::shared_ptr<const world::MeshSnapshot> snapshot) {
        const int origin[] = {snapshot->origin.x,snapshot->origin.y,snapshot->origin.z};
        const int dims[] = {snapshot->dimensions.x,snapshot->dimensions.y,snapshot->dimensions.z};
        auto input = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, snapshot));
        input->shapeSource = snapshot; input->blockSize = cfg.blockSize; input->retainLighting = true;
        input->models.push_back({model, 7});
        input->instances = std::make_shared<world::MeshInstances>(snapshot, world::Coord{-1,0,0}, 1,
            std::unordered_map<uint32_t, world::MeshRecipe>{{1, {0, true, false, 1, -1, false, 1}}}, true);
        return input;
    };
    auto snapshot = std::make_shared<world::MeshSnapshot>(store.meshSnapshot({-1,0,0}, 1));
    l2::WorkerPool pool;
    pool.start(2);
    const auto oldId = pool.submit(make(snapshot));
    store.apply(store.revision(), {edit(cfg, {-4,-1,1}, 0)});
    check(!store.geometryCurrent(*snapshot) && snapshot->shape(-4,-1,1).stair == 2,
        "shape halo edit mutated queued snapshot");
    light(store);
    auto updated = std::make_shared<world::MeshSnapshot>(store.meshSnapshot({-1,0,0}, 1));
    const auto newId = pool.submit(make(updated));
    snapshot.reset(); updated.reset();
    for (const auto id : {oldId, newId}) {
        wait(pool, id);
        const auto result = pool.ready(id);
        check(result->error.empty(), result->error.c_str());
        check(result->sectionVoxels == 1 && result->sectionQuads == 1 && result->parts.size() == 1,
            "shape worker emitted wrong section");
        const auto& part = result->parts[0];
        check(part.group == 7 && part.lighting && part.lighting->size() == 1, "shape lighting/material missing");
        check(part.lighting->at(0).command.tint == (id == oldId ? 3u : 0u), "immutable stair variant selection");
        check(part.bounds[0] >= float(4 * cfg.blockSize) && part.bounds[3] <= float(5 * cfg.blockSize),
            "shape geometry not chunk-local");
    }
    pool.stop();
    check(pool.stats().bytes == 0, "shape worker disposal leaked");
    auto mutation = edit(cfg, {-4,0,1}, 1);
    auto profile = catalog->states[1];
    profile.shape = l2::emptyShape();
    mutation.contexts.push_back({cfg.localIndex({-4,0,1}), false, profile});
    store.apply(store.revision(), {mutation}); light(store);
    bool rejected = false;
    try { make(std::make_shared<world::MeshSnapshot>(store.meshSnapshot({-1,0,0}, 1))); }
    catch (const std::exception& e) { rejected = std::string(e.what()) == "model/context shape selector mismatch"; }
    check(rejected, "context shape selector mismatch reached worker");
}
void fluids() {
    world::Config cfg;
    cfg.chunkSize = cfg.chunkHeight = 8; cfg.sectionSize = 4; cfg.blockSize = 47.25;
    cfg.skyEnabled = false;
    auto catalog = std::make_shared<world::Catalog>();
    catalog->states.resize(5);
    for (auto& profile : catalog->states) {
        profile.fluid.ready = true;
        l2::compileFluidCoverage(profile.fluid, false, true, {});
    }
    for (unsigned state : {1u, 2u, 3u}) {
        auto& profile = catalog->states[state];
        profile.fluid.kind = state == 3 ? 2 : 1;
        profile.fluid.height = 8.0 / 9;
        profile.renderClass = state * 8 + 6;
    }
    auto& wet = catalog->states[2];
    wet.fluid.blocksMotion = true;
    l2::compileFluidCoverage(wet.fluid, false, false, {{0,0,0,1,1,0.5}});
    catalog->states[4].emission = 15;
    world::Store store(cfg, catalog);
    auto mutation = edit(cfg, {-4,1,1}, 1);
    mutation.cells.push_back({cfg.localIndex({-2,2,1}), 2});
    mutation.cells.push_back({cfg.localIndex({-1,3,1}), 3});
    store.apply(0, {mutation});
    light(store);
    auto model = std::make_shared<l2::Model>();
    model->block = 2;
    l2::ModelAlternative alternative;
    l2::ModelQuad quad;
    quad.work = cube().faces[0]; quad.withoutAO = quad.work.geometry;
    alternative.quads.push_back(quad);
    model->groups.push_back({{alternative}, 0, 0});
    l2::validateModel(*model);
    const std::unordered_map<uint32_t, world::MeshRecipe> recipes{
        {1, {0, false, false, 6, 0, true}},
        {2, {0, true, false, 7, 0, false}},
        {3, {0, false, false, 6, 1, true}},
    };
    const auto make = [&](std::shared_ptr<const world::MeshSnapshot> snapshot) {
        const int origin[3] = {snapshot->origin.x, snapshot->origin.y, snapshot->origin.z};
        const int dims[3] = {snapshot->dimensions.x, snapshot->dimensions.y, snapshot->dimensions.z};
        auto in = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, snapshot));
        in->blockSize = cfg.blockSize; in->retainLighting = true; in->maxQuads = 2;
        in->fluidSource = snapshot;
        in->models.push_back({model, 11});
        for (unsigned kind : {1u, 2u}) {
            l2::FluidRecipe fluid;
            fluid.kind = uint8_t(kind); fluid.group = 20 + kind; fluid.flow = true;
            fluid.offset = 0.001; fluid.shade.fill(255);
            for (auto& tile : fluid.tiles) tile.scale[0] = tile.scale[1] = 1.0 / 16;
            in->fluids.push_back(fluid);
        }
        in->instances = std::make_shared<world::MeshInstances>(snapshot, world::Coord{-1,0,0}, 1, recipes, true);
        check(in->instances->maxQuads() == 19, "fluid/host histogram reservation");
        return in;
    };
    auto snapshot = std::make_shared<world::MeshSnapshot>(store.meshSnapshot({-1,0,0}, 1));
    auto input = make(snapshot);
    std::atomic<bool> cancelled{true};
    input->instances->populate(*input, cancelled);
    check(input->voxels.empty(), "cancelled fluid traversal emitted instances");
    l2::WorkerPool pool;
    pool.start(2);
    const auto id = pool.submit(std::move(input));
    store.apply(store.revision(), {edit(cfg, {-5,1,1}, 4)});
    check(snapshot->read({-5,1,1}).fluidEmission == 0, "fluid job read mutable light state");
    light(store);
    wait(pool, id);
    auto result = pool.ready(id);
    check(result->error.empty(), result->error.c_str());
    check(result->sectionVoxels == 4 && result->sectionQuads > 12, "missing pure fluid or host overlay");
    check(result->topology.uniform == 63, "fluid/partial host blocked topology");
    unsigned hostQuads = 0, waterQuads = 0, lavaQuads = 0;
    for (const auto& part : result->parts) {
        check(part.quads.size() <= 2 && part.lighting && part.lighting->size() == part.quads.size(),
            "split fluid part lost retained light");
        if (part.group == 11) hostQuads += unsigned(part.quads.size());
        else if (part.group == 21) waterQuads += unsigned(part.quads.size());
        else if (part.group == 22) lavaQuads += unsigned(part.quads.size());
        else check(false, "fluid routed to unexpected material");
        for (const auto& work : *part.lighting)
            check((work.geometry.mode == 3) == (part.group != 11), "host/fluid light recipe mixed");
        check(part.bounds[0] >= float(4 * cfg.blockSize) && part.bounds[3] <= float(8 * cfg.blockSize),
            "fluid transform was not chunk-local");
    }
    check(hostQuads == 1 && waterQuads == 11 && lavaQuads == 6, "wrong fluid/host faces");
    auto updated = std::make_shared<world::MeshSnapshot>(store.meshSnapshot({-1,0,0}, 1));
    auto relight = make(updated), full = make(updated);
    relight->instances.reset(); relight->models.clear(); relight->fluids.clear(); relight->fluidSource.reset();
    relight->retainLighting = false;
    for (const auto& part : result->parts) relight->relight.push_back(part.lighting);
    std::vector<std::vector<uint32_t>> before;
    for (const auto& part : result->parts) before.push_back(part.pixels);
    pool.cancel(id); result.reset();
    const auto relightId = pool.submit(std::move(relight)), fullId = pool.submit(std::move(full));
    wait(pool, relightId); wait(pool, fullId);
    const auto relit = pool.ready(relightId), rebuilt = pool.ready(fullId);
    check(relit->error.empty() && rebuilt->error.empty(), "fluid relight/full build failed");
    check(relit->relight && !relit->sectionVoxels && !relit->sectionQuads && relit->topology.cells.empty(),
        "fluid relight regenerated geometry/topology");
    check(relit->parts.size() == rebuilt->parts.size(), "fluid relight lost split parts");
    bool changed = false;
    for (size_t i = 0; i < relit->parts.size(); ++i) {
        const auto& a = relit->parts[i];
        const auto& b = rebuilt->parts[i];
        check(a.quads.empty() && !a.lighting, "fluid relight retained/generated geometry");
        check(a.pixels == b.pixels && a.occlusion == b.occlusion, "fluid relight differs from full rebuild");
        if (b.group == 21 && a.pixels != before[i]) changed = true;
    }
    check(changed, "fluid relight did not exercise changed illumination");
    pool.stop();
    check(pool.stats().bytes == 0, "fluid worker disposal leaked");
}
}
int main() {
    try {
        snapshotMemory(); topology(); worldMesh(); models(); shapeValidation(); shapes(); fluids();
        std::cout << "World mesh: owned snapshots, histogram, transforms, sky invalidation, topology, models, shapes and fluids/relight passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
