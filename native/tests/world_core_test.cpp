#include "../world_core.h"
#include <iostream>
#include <random>
#include <stdexcept>

using namespace mcmesh::world;
namespace {
void check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
template<class F> void rejects(F operation, const char* message) {
    bool rejected = false;
    try { operation(); } catch (const std::exception&) { rejected = true; }
    check(rejected, message);
}
std::shared_ptr<Catalog> catalog() {
    auto result = std::make_shared<Catalog>();
    result->states.resize(5);
    result->states[1] = {0, 15, 16, 0xef000, 9, 0.2f};
    result->states[2] = {15, 0, 1, 0x10f00, 16, 1.0f};
    result->states[3] = {0, 3, 2, 0x03000, 26, 0.8f};
    result->states[4] = {0, 1, 1, 0x01000, 34, 0.9f};
    return result;
}
Config small(bool streaming = false) {
    Config result;
    result.chunkSize = result.chunkHeight = 4;
    result.sectionSize = 2;
    result.blockSize = 47.25;
    result.streaming = streaming;
    result.minChunkZ = -2; result.maxChunkZ = 2;
    return result;
}
Mutation cell(const Config& cfg, Coord pos, uint32_t state) {
    Mutation result;
    result.chunk = cfg.chunkAt(pos);
    result.cells.push_back({cfg.localIndex(pos), state});
    return result;
}
std::unique_ptr<LightResult> rebuild(Store& store) {
    std::atomic<bool> cancel{false};
    auto result = rebuildLight(store.snapshot(), cancel);
    check(result != nullptr, "uncancelled light job vanished");
    check(!store.commit(*result).stale, "fresh light result was stale");
    return result;
}
void compareFull(Store& store) {
    auto source = std::make_shared<Snapshot>(*store.snapshot());
    source->light.clear();
    source->invalidLight.clear();
    std::atomic<bool> cancel{false};
    const auto expected = rebuildLight(source, cancel);
    const auto current = store.snapshot();
    check(current->light.size() == expected->chunks.size(), "incremental light domain differs from full rebuild");
    for (const auto& entry : expected->chunks) {
        const auto found = current->light.find(entry.first);
        check(found != current->light.end() && found->second->values == entry.second->values,
            "incremental propagation differs from full rebuild");
    }
}
void storage() {
    const auto cfg = small();
    const auto profiles = catalog();
    Store store(cfg, profiles);
    profiles->states[2].emission = 0;
    check(store.snapshot()->catalog->states[2].emission == 15, "caller mutated sealed catalog");
    check(floorDiv(-1, 4) == -1 && floorDiv(-4, 4) == -1 && floorDiv(-5, 4) == -2, "negative coordinates");
    for (Coord pos : {Coord{-1,-4,-5}, Coord{7,0,19}, Coord{-39,21,5}}) {
        check(cfg.cellAt(cfg.chunkAt(pos), cfg.localIndex(pos)) == pos, "cell addressing does not round-trip");
    }
    const Coord pos{-1,-4,-5};
    check(store.apply(0, {cell(cfg, pos, 1)}), "initial batch");
    const auto old = store.snapshot();
    check(store.apply(1, {cell(cfg, pos, 2)}), "second batch");
    check(old->state(pos) == 1 && store.state(pos) == 2, "COW snapshot changed");
    check(!store.apply(0, {cell(cfg, pos, 4)}) && store.state(pos) == 2, "stale mutation published");
    const auto revision = store.revision();
    auto bad = cell(cfg, {0,0,0}, 123);
    rejects([&] { store.apply(revision, {cell(cfg, pos, 4), bad}); }, "invalid batch accepted");
    check(store.revision() == revision && store.state(pos) == 2, "failed batch partially published");
    rejects([&] { store.apply(revision, {cell(cfg, pos, 4), cell(cfg, pos, 1)}); }, "duplicate chunks accepted");
    auto context = cell(cfg, pos, 2);
    context.cells.clear();
    context.contexts.push_back({cfg.localIndex(pos), false, catalog()->states[1]});
    check(store.apply(revision, {context}), "context mutation");
    check(store.snapshot()->profile(pos).opacity == 15 && old->profile(pos).opacity == 15, "context isolation");
    store.apply(store.revision(), {cell(cfg, pos, 4)});
    check(store.snapshot()->profile(pos).opacity == 1, "state change retained old context");
    bad = cell(cfg, {0,0,0}, 1);
    bad.terrainPresent = false;
    rejects([&] { store.apply(store.revision(), {bad}); }, "known-empty terrain accepted");
    bad.cells.clear();
    bad.contexts = {{0, false, catalog()->states[1]}};
    rejects([&] { store.apply(store.revision(), {bad}); }, "air context accepted");
    auto limited = small();
    limited.maxChunks = 1;
    Store atLimit(limited, catalog());
    atLimit.apply(0, {cell(limited, {0,0,0}, 1)});
    Mutation unload; unload.kind = Mutation::Kind::Unload;
    check(atLimit.apply(1, {cell(limited, {4,0,0}, 2), unload})
        && atLimit.chunkCount() == 1 && atLimit.state({4,0,0}) == 2, "mixed insert/unload at capacity");
}
void lighting() {
    auto cfg = small();
    Store store(cfg, catalog());
    store.apply(0, {cell(cfg, {-1,0,0}, 2)});
    const auto first = rebuild(store);
    check(first->scannedCells > 0 && store.light({-1,0,0}, false) == 15, "emitter source");
    check(store.light({0,0,0}, false) == 14 && store.light({12,0,0}, false) == 2
        && store.light({14,0,0}, false) == 0, "block flood across sparse chunk boundaries");
    check(store.light({0,0,0}, true) == 15, "empty columns must receive sky");
    check(rebuild(store)->scannedCells == 0, "unchanged world rescanned voxel lighting");
    store.apply(store.revision(), {cell(cfg, {-1,0,0}, 0)});
    rebuild(store);
    check(store.light({0,0,0}, false) == 0, "removed light retained propagation");
    compareFull(store);

    cfg.chunkSize = cfg.chunkHeight = 16; cfg.sectionSize = 8;
    Store water(cfg, catalog());
    Mutation basin;
    basin.kind = Mutation::Kind::Replace;
    for (int z = 12; z <= 15; ++z)
    for (int y = 0; y < 16; ++y)
    for (int x = 0; x < 16; ++x) basin.cells.push_back({cfg.localIndex({x,y,z}), 3});
    water.apply(0, {basin});
    rebuild(water);
    check(water.light({8,8,16}, true) == 15 && water.light({8,8,15}, true) == 13
        && water.light({8,8,14}, true) == 11 && water.light({8,8,13}, true) == 9
        && water.light({8,8,12}, true) == 7, "water did not attenuate direct sky by two per cell");
    water.apply(water.revision(), {cell(cfg, {8,8,14}, 2)});
    rebuild(water);
    check(water.light({9,8,14}, false) == 12, "block light incorrectly used water sky cost");
    compareFull(water);
    cfg.skyEnabled = false;
    Store noSky(cfg, catalog());
    noSky.apply(0, {cell(cfg, {0,0,0}, 1)});
    rebuild(noSky);
    check(noSky.light({0,0,0}, true) == 15, "disabled sky did not match Lua full-sky convention");
}
void streaming() {
    auto cfg = small(true);
    Store store(cfg, catalog());
    store.apply(0, {cell(cfg, {3,0,0}, 2)});
    rebuild(store);
    check(store.light({4,0,0}, false) == 0 && store.light({4,0,0}, true) == 0, "unknown stream chunk leaked light");
    auto mesh = store.meshSnapshot({0,0,0}, 1);
    auto unknown = mesh.read({4,0,0});
    check(!unknown.loaded() && unknown.word == 0xef000, "unknown L2 cell is not opaque and dark");
    rejects([&] { mesh.read({40,0,0}); }, "mesh read escaped its halo");
    Mutation empty;
    empty.kind = Mutation::Kind::Replace;
    empty.chunk = {1,0,0}; empty.terrainPresent = false;
    store.apply(store.revision(), {empty});
    check(!store.current(mesh), "new known neighbor did not invalidate mesh");
    rebuild(store);
    check(store.light({4,0,0}, false) == 14 && store.light({4,0,0}, true) == 15, "known sparse air blocked light");
    empty.kind = Mutation::Kind::Unload;
    store.apply(store.revision(), {empty});
    rebuild(store);
    mesh = store.meshSnapshot({0,0,0}, 1);
    check(store.current(mesh), "unloaded halo left permanent invalidation");
    Mutation distant;
    distant.chunk = {40,40,0}; distant.terrainPresent = false;
    store.apply(store.revision(), {distant});
    rebuild(store);
    check(store.snapshot()->invalidLight.empty(), "known-empty chunk retained invalid light forever");
}
void versions() {
    const auto cfg = small();
    Store store(cfg, catalog());
    store.apply(0, {cell(cfg, {0,0,0}, 2), cell(cfg, {100,0,0}, 2)});
    std::atomic<bool> cancel{false};
    auto original = rebuildLight(store.snapshot(), cancel);
    store.apply(store.revision(), {cell(cfg, {0,0,0}, 1)});
    const auto partial = store.commit(*original);
    check(partial.deferred > 0 && partial.committed > 0, "independent columns could not commit partially");
    check(!store.lightReady({0,0,0}) && store.lightReady({25,0,0}), "partial publication readiness");
    rebuild(store);
    compareFull(store);
    const auto mesh = store.meshSnapshot({25,0,0}, 0);
    store.apply(store.revision(), {cell(cfg, {0,0,0}, 4)});
    check(store.current(mesh), "distant edit invalidated unrelated mesh");
    store.apply(store.revision(), {cell(cfg, {100,0,0}, 1)});
    check(!store.current(mesh), "local edit failed to invalidate mesh");
    auto previous = rebuildLight(store.snapshot(), cancel);
    store.reset(cfg, catalog());
    check(store.commit(*previous).stale && !store.current(mesh), "old world survived reset");
    cancel = true;
    store.apply(0, {cell(cfg, {0,0,0}, 2)});
    check(!rebuildLight(store.snapshot(), cancel), "cancelled propagation completed");
    auto budget = cfg;
    budget.maxLightBytes = 1024;
    Store limited(budget, catalog());
    limited.apply(0, {cell(cfg, {0,0,0}, 2)});
    cancel = false;
    rejects([&] { rebuildLight(limited.snapshot(), cancel); }, "lighting ignored memory budget");
}
void configuration() {
    auto cfg = small();
    Store store(cfg, catalog());
    store.apply(0, {cell(cfg, {-1,0,0}, 2)});
    check(store.chunk({-1,0,0})->count == 1 && !store.chunk({20,0,0}), "chunk presence query");
    auto previous = rebuild(store);
    const auto source = store.chunk({-1,0,0});
    const auto epoch = store.epoch();
    auto invalid = cfg;
    invalid.chunkSize *= 2;
    rejects([&] { store.reconfigure(invalid); }, "geometry reconfiguration was accepted");
    check(store.epoch() == epoch && store.chunk({-1,0,0}) == source, "failed config changed ownership");
    cfg.streaming = true; cfg.minChunkZ = -1; cfg.maxChunkZ = 1; cfg.skyEnabled = false;
    store.reconfigure(cfg);
    check(store.chunk({-1,0,0}) == source && store.state({-1,0,0}) == 2
        && store.epoch() != epoch && store.commit(*previous).stale, "config did not retain states/reject old light");
    check(!store.known({20,0,0}) && store.known({20,0,2}), "new stream bounds ignored");
    rebuild(store);
    check(store.light({-1,0,0}, false) == 15 && store.light({-1,0,0}, true) == 15, "config light rebuild failed");

    cfg = small();
    LightDelta delta;
    delta.chunk = {-1,0,0};
    delta.changedBits.resize((cfg.cellCount() + 7) / 8);
    const Coord changed{-1,0,0};
    const auto li = cfg.localIndex(changed);
    delta.changedBits[li / 8] |= uint8_t(1u << (li % 8));
    const auto owners = affectedLightSections(cfg, {delta, delta});
    size_t count = 0;
    for (int z = -2; z <= 1; ++z)
    for (int y = -2; y <= 1; ++y)
    for (int x = -2; x <= 1; ++x) {
        const Coord chunk{x,y,z};
        const auto found = owners.find(chunk);
        for (unsigned s = 0; s < cfg.sectionCount(); ++s) {
            const int xy = cfg.chunkSize / cfg.sectionSize;
            const Coord lo{x * cfg.chunkSize + int(s % xy) * cfg.sectionSize - 2,
                y * cfg.chunkSize + int(s / xy % xy) * cfg.sectionSize - 2,
                z * cfg.chunkHeight + int(s / (xy * xy)) * cfg.sectionSize - 2};
            const bool expected = changed.x >= lo.x && changed.x < lo.x + cfg.sectionSize + 4
                && changed.y >= lo.y && changed.y < lo.y + cfg.sectionSize + 4
                && changed.z >= lo.z && changed.z < lo.z + cfg.sectionSize + 4;
            const bool present = found != owners.end()
                && std::find(found->second.begin(), found->second.end(), s) != found->second.end();
            check(expected == present, "light delta section halo mismatch");
            if (present) ++count;
        }
    }
    size_t actual = 0;
    for (const auto& owner : owners) actual += owner.second.size();
    check(count == actual, "duplicate/out-of-range light owners");
}
void incremental() {
    const auto cfg = small();
    Store store(cfg, catalog());
    std::mt19937 random(48172);
    for (int i = 0; i < 36; ++i) {
        Coord pos{int(random() % 24) - 12, int(random() % 12) - 6, int(random() % 12) - 6};
        auto edit = cell(cfg, pos, random() % 5);
        if (i % 7 == 0) { edit.kind = Mutation::Kind::Unload; edit.cells.clear(); }
        store.apply(store.revision(), {edit});
        rebuild(store);
        compareFull(store);
    }
}
}
int main() {
    try {
        storage(); lighting(); streaming(); versions(); configuration(); incremental();
        std::cout << "Persistent world: atomic batches, snapshots, streaming, water, incremental light, stale jobs and budgets passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
