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
        check(result->parts[0].occlusion[123] == expected.occlusion, "worker AO packing");
        check(result->parts[0].pixels[123 * 4] == expected.pixels[0], "worker corner packing");
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
    pool.start(1);
    auto large = input(1);
    large->parts[0].reserve(WorkerPool::MaxBytes / sizeof(Work) + 1);
    bool rejected = false;
    try { pool.submit(std::move(large)); }
    catch (const std::exception&) { rejected = true; }
    check(rejected && pool.stats().bytes == 0, "oversized section bypassed memory budget");
    pool.stop();
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
    try { run(); voxels(); return 0; }
    catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
