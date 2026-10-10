#include "../l2_worker.h"
#include <chrono>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <map>
#include <limits>
#include <tuple>

using namespace mcmesh::l2;
namespace {
void check(bool value, const char* reason) { if (!value) throw std::runtime_error(reason); }
const auto mainThread = std::this_thread::get_id();
Cell read(void*, int x, int y, int z) {
    check(std::this_thread::get_id() == mainThread, "worker invoked the live reader");
    return {1048576u + unsigned((x + y + z) & 15) * 17, 1.0f};
}
std::unique_ptr<Input> input(unsigned count = 10000, bool frozen = true) {
    int origin[3]{}, dims[3] = {5,5,5};
    auto in = std::make_unique<Input>(Snapshot(origin, dims, read, nullptr));
    Work work;
    work.geometry.face = 0; work.geometry.flags = 9;
    for (unsigned c = 0; c < 4; ++c) work.geometry.indices[c] = c;
    for (unsigned a = 0; a < 3; ++a) work.command.source[a] = 2;
    if (frozen) prefetch(work.geometry, work.command, in->snapshot);
    in->parts.emplace_back(count, work);
    return in;
}
void wait(WorkerPool& pool, uint64_t id) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (;;) {
        const auto state = pool.state(id);
        if (state == JobState::Ready || state == JobState::Failed) return;
        check(std::chrono::steady_clock::now() < deadline, "worker timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}
struct VoxelFixture {
    std::map<std::tuple<int, int, int>, uint32_t> classes;
    uint32_t defaultClass = 0;
    unsigned reads = 0;
    static Cell read(void* data, int x, int y, int z) {
        check(std::this_thread::get_id() == mainThread, "voxel worker called Lua reader");
        auto& f = *static_cast<VoxelFixture*>(data);
        ++f.reads;
        const auto it = f.classes.find({x,y,z});
        return {1048576u + unsigned((x + y + z) & 15) * 17, 1.0f,
            it == f.classes.end() ? f.defaultClass : it->second};
    }
    std::unique_ptr<Input> make(bool directional = false) {
        int origin[3] = {-2,-2,-2}, dims[3] = {12,12,12};
        auto in = std::make_unique<Input>(Snapshot(origin, dims, read, this));
        Cube cube;
        cube.block = 1;
        for (unsigned face = 0; face < 6; ++face) {
            auto& w = cube.faces[face];
            w.geometry.face = face;
            w.geometry.flags = 9;
            for (unsigned c = 0; c < 4; ++c) {
                w.geometry.indices[c] = c;
                for (unsigned a = 0; a < 3; ++a) w.geometry.positions[c][a] = (c >> (a % 2)) & 1;
            }
            cube.groups[face] = directional ? face + 1 : 1;
        }
        in->cubes.push_back(cube);
        in->voxels.push_back({});
        return in;
    }
};
void voxels() {
    constexpr int offsets[6][3] = {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}};
    std::atomic<bool> cancel{false};
    VoxelFixture canonical;
    const auto cube = canonical.make()->cubes[0];
    validateCube(cube);
    const auto reject = [&](auto mutate) {
        auto bad = cube;
        mutate(bad);
        bool rejected = false;
        try { validateCube(bad); } catch (const std::exception&) { rejected = true; }
        check(rejected, "malformed cube passed registration");
    };
    reject([](Cube& c) { c.block = 0; });
    reject([](Cube& c) { c.faces[0].geometry.mode = 2; });
    reject([](Cube& c) { c.faces[0].geometry.face = 1; });
    reject([](Cube& c) { c.faces[0].command.size = 2; });
    reject([](Cube& c) { c.faces[0].command.source[0] = 1; });
    reject([](Cube& c) { c.faces[0].command.translation[0] = 1; });
    reject([](Cube& c) { c.faces[0].geometry.positions[0][0] = 1.1; });
    reject([](Cube& c) { c.faces[0].geometry.positions[0][0] = std::numeric_limits<double>::quiet_NaN(); });
    // The frozen path must implement the Lua opaque-cube visibility relation.
    for (const uint32_t neighbour : {0u, 9u, 17u, 19u, 11u, 21u, 16u}) {
        VoxelFixture fixture;
        const bool shown = neighbour == 0 || neighbour == 19 || neighbour == 21 || neighbour == 16;
        for (const auto& d : offsets) fixture.classes[{d[0],d[1],d[2]}] = neighbour;
        auto in = fixture.make();
        prefetchVoxels(*in);
        check(fixture.reads < 125, "sparse capture read the full halo");
        in->snapshot.freeze();
        std::vector<unsigned> groups;
        expandVoxels(*in, groups, cancel);
        check(in->parts.size() == (shown ? 1 : 0), "voxel visibility group count");
        if (shown) check(in->parts[0].size() == 6 && groups[0] == 1, "voxel visibility differs from Lua");
    }
    VoxelFixture fixture;
    fixture.classes[{0,0,0}] = fixture.classes[{1,0,0}] = 9;
    auto in = fixture.make(true);
    Voxel second;
    second.source[0] = 1;
    second.translation[0] = 47.25;
    in->voxels.push_back(second);
    in->blockSize = 47.25;
    in->maxQuads = 1;
    // Legacy parts must keep their original upload indices when groups append.
    auto legacy = in->cubes[0].faces[0];
    in->parts.push_back({legacy});
    prefetch(legacy.geometry, legacy.command, in->snapshot);
    prefetchVoxels(*in);
    auto reference = fixture.make(true);
    WorkerPool pool;
    pool.start(2);
    const auto id = pool.submit(std::move(in));
    wait(pool, id);
    const auto result = pool.ready(id);
    check(result->error.empty(), result->error.c_str());
    check(result->sectionVoxels == 2 && result->sectionQuads == 10, "adjacent cubes kept internal faces");
    check(result->parts.size() == 11 && result->parts[0].group == 0, "mixed parts lost ordering/splitting");
    unsigned directions[6]{};
    for (size_t i = 1; i < result->parts.size(); ++i) {
        const auto& part = result->parts[i];
        check(part.quads.size() == 1 && part.group >= 1 && part.group <= 6, "directional group");
        ++directions[part.group - 1];
        auto work = reference->cubes[0].faces[part.group - 1];
        const bool moved = part.bounds[0] > 1;
        work.command.source[0] = moved ? 1 : 0;
        work.command.translation[0] = moved ? 47.25 : 0;
        work.command.size = 47.25;
        auto expected = evaluate(work.geometry, work.command, reference->snapshot, 0);
        check(std::memcmp(&expected, &part.quads[0], sizeof(Quad)) == 0, "voxel transform/light differs from legacy");
    }
    check(directions[2] == 1 && directions[3] == 1 && directions[0] == 2, "wrong neighbour face order");
    pool.stop();
    fixture.defaultClass = 9;
    auto hidden = fixture.make();
    prefetchVoxels(*hidden);
    pool.start(1);
    const auto emptyId = pool.submit(std::move(hidden));
    wait(pool, emptyId);
    check(pool.ready(emptyId)->error.empty() && pool.ready(emptyId)->parts.empty(), "fully hidden section did not finish empty");
    pool.stop();
    auto cancelled = fixture.make();
    cancel = true;
    std::vector<unsigned> groups;
    expandVoxels(*cancelled, groups, cancel);
    check(cancelled->parts.empty(), "cancelled voxel expansion touched snapshot");
    std::cout << "L2 voxels: visibility, sparse freeze, adjacent cubes, mixed groups, splitting, transforms and empty results passed\n";
}
void relighting() {
    WorkerPool pool;
    pool.start(2);
    auto in = input(5);
    auto second = in->parts[0][0];
    second.geometry.face = 2;
    second.command.tint = 3;
    in->parts.emplace_back(3, second);
    prefetch(second.geometry, second.command, in->snapshot);
    in->retainLighting = true;
    const auto id = pool.submit(std::move(in));
    wait(pool, id);
    auto result = pool.ready(id);
    check(result->error.empty() && !result->relight, "retained geometry failed");
    int origin[3]{}, dims[3] = {5,5,5};
    const auto changed = [](void*, int, int, int) -> Cell {
        check(std::this_thread::get_id() == mainThread, "relight called live reader");
        return {1048576u + 0xb7u, 0.6f};
    };
    auto light = std::make_unique<Input>(Snapshot(origin, dims, changed, nullptr));
    std::vector<LightQuad> expected;
    for (const auto& part : result->parts) {
        check(part.lighting && part.lighting->size() == part.quads.size(), "lost lighting recipe");
        light->relight.push_back(part.lighting);
        for (const auto& work : *part.lighting) {
            Template geometry;
            Command command;
            static_cast<LightTemplate&>(geometry) = work.geometry;
            static_cast<LightCommand&>(command) = work.command;
            prefetch(geometry, command, light->snapshot);
            const auto full = evaluate(geometry, command, light->snapshot, 0);
            expected.push_back({{full.pixels[0], full.pixels[1], full.pixels[2], full.pixels[3]}, full.occlusion});
        }
    }
    // Retained recipes must outlive the source job and its geometry buffers.
    pool.cancel(id);
    result.reset();
    pool.stop();
    pool.start(2);
    const auto lightId = pool.submit(std::move(light));
    wait(pool, lightId);
    result = pool.ready(lightId);
    check(result->error.empty() && result->relight && result->parts.size() == 2, "relight failed");
    size_t q = 0;
    for (const auto& part : result->parts) {
        check(part.quads.empty() && !part.lighting, "relight regenerated/retained geometry");
        for (size_t i = 0; i < part.pixels->occlusion.size(); ++i, ++q) {
            check(part.pixels->occlusion[i] == expected[q].occlusion, "relight AO mismatch");
            for (unsigned c = 0; c < 4; ++c)
                check(part.pixels->corners[i * 4 + c] == expected[q].pixels[c], "relight pixel mismatch");
        }
    }
    check(q == 8 && result->sectionVoxels == 0 && result->sectionQuads == 0, "relight expanded instances");
    check(pool.stats().relightJobs == 1 && pool.stats().relightQuads == 8, "relight statistics");
    pool.cancel(lightId);
    result.reset();
    pool.stop();
    check(pool.stats().bytes == 0, "completed relight disposal leaked");
    auto bad = input(1);
    bad->relight.push_back(nullptr);
    bool rejected = false;
    try { bad->reservation(); } catch (const std::exception&) { rejected = true; }
    check(rejected, "mixed relight input accepted");
    bad->parts.clear();
    rejected = false;
    try { bad->reservation(); } catch (const std::exception&) { rejected = true; }
    check(rejected, "null relight part accepted");
    std::cout << "L2 relight: exact pixels/AO, unchanged geometry, split parts, lifetime and cancellation passed\n";
}
struct SizedSource : CellSource {
    size_t footprint = 68u * 1024u * 1024u;
    Cell read(int, int, int) const override { return {1048576u + 255, 1}; }
    size_t bytes() const override { return footprint; }
};
void deferredWorkerCache() {
    struct Source : SizedSource {
        mutable unsigned calls = 0;
        Cell read(int, int, int) const override {
            check(std::this_thread::get_id() != mainThread, "owned source sampled during submission");
            ++calls;
            return {1048576u + 255, 1};
        }
    };
    auto source = std::make_shared<Source>();
    auto in = input(1);
    int origin[3]{}, dims[3] = {5,5,5};
    in->snapshot = Snapshot(origin, dims, source);
    auto* queued = in.get();
    WorkerPool pool;
    const auto id = pool.submit(std::move(in));
    check(id && !queued->snapshot.prepared() && source->calls == 0, "submission allocated owned scratch");
    pool.start(1);
    wait(pool, id);
    check(pool.ready(id)->error.empty() && source->calls > 0, "worker did not prepare/sample owned scratch");
    pool.stop();
    check(pool.stats().bytes == 0, "deferred scratch retained on shutdown");
}
void memoryAccounting() {
    WorkerPool pool;
    auto source = std::make_shared<SizedSource>();
    const auto make = [&](std::shared_ptr<const CellSource> value) {
        auto in = input(1);
        int origin[3]{}, dims[3] = {5,5,5};
        in->snapshot = Snapshot(origin, dims, std::move(value));
        return in;
    };
    auto first = make(source);
    auto reservation = first->memoryUsage();
    const auto sharedBytes = reservation.total() - reservation.owned;
    check(sharedBytes > 64 * 1024 * 1024 && reservation.shared.size() == 1, "source not recorded as shared");
    // Submit before starting workers to make admission and byte checks deterministic.
    for (unsigned i = 0; i < 4; ++i) {
        check(pool.submit(make(source)) != 0, "shared source charged again for each job");
        check(pool.stats().bytes == sharedBytes + (i + 1) * reservation.owned, "shared ledger total");
    }
    const auto before = pool.stats().bytes;
    check(pool.canSubmit(), "capacity hint unexpectedly full");
    check(pool.submit(make(std::make_shared<SizedSource>())) == 0, "new source revision bypassed memory limit");
    check(pool.stats().bytes == before, "rejected submission changed accounting");
    pool.start(2);
    pool.stop();
    check(pool.stats().bytes == 0, "shared cancellation leaked references");
    reservation.shared.clear();

    // Ready results relinquish worst-case private workspace, but retain shared tickets.
    auto in = make(source);
    in->parts[0].reserve(20000);
    in->retainLighting = true;
    const auto large = in->reservation();
    const auto id = pool.submit(std::move(in));
    std::weak_ptr<const CellSource> alive = source;
    source.reset();
    first.reset();
    pool.start(1);
    wait(pool, id);
    auto result = pool.ready(id);
    check(result->error.empty(), result->error.c_str());
    check(result->parts[0].lighting && result->parts[0].lighting->size() == 1, "result footprint lost retained light");
    check(pool.stats().bytes == sharedBytes + result->resultBytes(), "ready result still holds workspace reservation");
    check(pool.stats().bytes + 1000000 < large, "completion did not reclaim workspace");
    check(!alive.expired(), "shared source died before result release");
    // The external result reference is intentionally scoped through stop, as in uploads.
    pool.stop();
    check(pool.stats().bytes == 0, "ready shared result leaked accounting");
    result.reset();
    check(alive.expired(), "released result retained shared source");
    std::cout << "L2 memory: shared identity, exact admission, completion shrink and cancellation passed\n";
}
void contentSize() {
    WorkerPool pool;
    auto many = input(1);
    const auto work = many->parts[0][0];
    many->parts.resize(300, std::vector<Work>{work});
    many->retainLighting = true;
    const auto id = pool.submit(std::move(many));
    pool.start(1);
    wait(pool, id);
    auto result = pool.ready(id);
    check(result->error.empty() && result->parts.size() == 300, "300-part section was truncated or rejected");
    auto relight = input(1);
    relight->parts.clear();
    for (const auto& part : result->parts) relight->relight.push_back(part.lighting);
    pool.stop();
    const auto relightId = pool.submit(std::move(relight));
    pool.start(1);
    wait(pool, relightId);
    check(pool.ready(relightId)->error.empty() && pool.ready(relightId)->parts.size() == 300,
        "300-part relight was truncated or rejected");
    result.reset();
    pool.stop();

    auto dense = input(8192);
    dense->parts.resize(17, dense->parts[0]); // 139264 quads, each mesh remains legal.
    const auto denseId = pool.submit(std::move(dense));
    check(denseId != 0, "dense section was rejected by a content ceiling");
    pool.start(1);
    wait(pool, denseId);
    result = pool.ready(denseId);
    check(result->error.empty() && result->parts.size() == 17, "dense section failed or lost parts");
    size_t quads = 0;
    for (const auto& part : result->parts) quads += part.quads.size();
    check(quads == 139264, "dense section lost geometry");
    pool.stop();
    check(pool.stats().bytes == 0, "large content leaked accounting");
    bool overflow = false;
    try { checkedMultiply(std::numeric_limits<size_t>::max(), 2); }
    catch (const std::exception&) { overflow = true; }
    check(overflow, "allocation arithmetic overflow was accepted");
    std::cout << "L2 content: 300-part geometry/relight and 139264-quad section without content ceilings passed\n";
}
void run() {
    WorkerPool pool;
    pool.start(4);
    std::vector<uint64_t> ids;
    for (unsigned i = 0; i < WorkerPool::MaxJobs; ++i) {
        const auto id = pool.submit(input());
        check(id != 0, "bounded submissions rejected too early");
        ids.push_back(id);
    }
    check(pool.submit(input(1)) == 0 && !pool.canSubmit(), "ready jobs bypassed queue bound");
    for (const auto id : ids) {
        wait(pool, id);
        const auto result = pool.ready(id);
        check(result->error.empty(), "worker failed");
        auto reference = input(1);
        const auto& w = reference->parts[0][0];
        const auto expected = evaluate(w.geometry, w.command, reference->snapshot, 123);
        check(std::memcmp(&result->parts[0].quads[123], &expected, sizeof(Quad)) == 0, "worker differs from core");
        check(result->parts[0].pixels->occlusion[123] == expected.occlusion, "worker AO packing");
        check(result->parts[0].pixels->corners[123 * 4] == expected.pixels[0], "worker corner packing");
        check(!result->input, "worker retained input after computing");
    }
    const auto stats = pool.stats();
    check(stats.workers == 4 && stats.peakRunning >= 2 && stats.completed == ids.size(), "no real parallel execution");
    pool.cancel(0);
    pool.stop();
    check(pool.stats().bytes == 0 && pool.stats().running == 0 && pool.stats().ready == 0, "shutdown leaked jobs");
    check(pool.canSubmit(), "stopped pool cannot admit work after Lua reconnect");
    pool.start(2);
    auto bad = pool.submit(input(1, false));
    wait(pool, bad);
    check(pool.state(bad) == JobState::Failed &&
        pool.ready(bad)->error.find("unfrozen") != std::string::npos, "worker reached live reader or swallowed failure");
    pool.cancel(bad);
    auto running = pool.submit(input());
    pool.cancel(running);
    pool.stop();
    check(pool.stats().bytes == 0, "running cancellation leaked");
    auto large = input(1);
    auto largeSource = std::make_shared<SizedSource>();
    largeSource->footprint = WorkerPool::TargetBytes * 2;
    const int origin[3] = {0,0,0}, dimensions[3] = {5,5,5};
    large->snapshot = Snapshot(origin, dimensions, largeSource);
    const auto largeJob = pool.submit(std::move(large));
    check(largeJob != 0 && pool.stats().bytes > WorkerPool::TargetBytes,
        "a single large section was rejected by a scheduling target");
    check(!pool.canSubmit() && pool.submit(input(1)) == 0,
        "large section did not apply temporary backpressure");
    pool.start(1);
    wait(pool, largeJob);
    check(pool.ready(largeJob)->error.empty(), "large section did not complete");
    pool.stop();
    check(pool.stats().bytes == 0 && pool.canSubmit(), "large section did not release admission");
    // Rapid start/stop exercises queued, executing and completed disposal.
    for (unsigned i = 0; i < 12; ++i) {
        pool.start(2);
        for (unsigned j = 0; j < 4; ++j) pool.submit(input(1000));
        pool.stop();
        check(pool.stats().bytes == 0, "restart leaked");
    }
    std::cout << "L2 workers: parity, parallelism, bounded queue, frozen reader, errors, cancellation and restart passed\n";
}
}
int main() {
    try { run(); voxels(); relighting(); deferredWorkerCache(); memoryAccounting(); contentSize(); return 0; }
    catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
