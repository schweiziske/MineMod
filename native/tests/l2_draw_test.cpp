#include "../l2_draw.h"
#include "../l2_core.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <random>
#include <stdexcept>
#include <thread>
using namespace mcmesh;
using namespace l2draw;
static void check(bool v, const char* message) { if (!v) throw std::runtime_error(message); }
static void portalTests() {
    Graph graph;
    graph.nodes.resize(5);
    for (unsigned i = 1; i < 5; ++i) {
        graph.nodes[i].live = true;
        // Closed other faces: no exterior access from the inside.
        graph.nodes[i].exits.fill(0);
    }
    graph.nodes[1].neighbors[2] = 2; graph.nodes[2].neighbors[3] = 1;
    graph.nodes[2].neighbors[2] = 3; graph.nodes[3].neighbors[3] = 2;
    graph.nodes[3].neighbors[2] = 4; graph.nodes[4].neighbors[3] = 3;
    graph.nodes[2].exits[3] = 4;
    auto seen = reachable(graph, 1, 4);
    check(seen[1] && seen[2] && seen[3] && !seen[4], "portal wall must draw without propagating");
    seen = reachable(graph, 1, 0);
    check(seen[1] && !seen[2], "sealed camera pocket must not become exterior");
    graph.nodes[3].exits[3] = 4;
    seen = reachable(graph, 1, 4);
    check(seen[4], "opened portal did not propagate");
    seen = reachable(graph, 0, 63);
    check(seen[1] && seen[4], "virtual exterior omitted boundary walls");
    graph.nodes[1].live = false;
    bool threw = false;
    try { reachable(graph, 1, 63); } catch (const std::exception&) { threw = true; }
    check(threw, "retired root silently accepted");
}
static void spatialPortalTests() {
    Graph graph;
    graph.nodes.resize(4);
    // A solid section at x=0 blocks a target at x=1. An unrelated high
    // section expands the air grid so a flood can go over then behind it.
    for (unsigned id = 1; id <= 3; ++id) graph.nodes[id].live = true;
    graph.nodes[1].position = {0, 0, 0};
    graph.nodes[2].position = {1, 0, 0};
    graph.nodes[3].position = {0, 0, 2};
    buildSpatialGraph(graph);
    View view; view.portals = true; view.portalCell = {-1, 0, 0};
    unsigned visited = 0;
    auto seen = reachable(graph, view, visited);
    check(seen[1] && !seen[2], "outside camera leaked through/around a section wall");
    // A thin wall inside the root leaves its camera-side five faces open.
    graph.nodes[1].exits.fill(63);
    graph.nodes[1].exits[3] = 59;
    graph.nodes[1].exits[2] = 55;
    buildSpatialGraph(graph);
    view.root = 1; view.portalCell = {0, 0, 0}; view.seed = 59;
    seen = reachable(graph, view, visited);
    check(seen[1] && !seen[2], "registered camera escaped its wall through exterior air");
    view.root = 0; view.seed = 63;
    view.portalCell = {0, 0, 1}; // Missing air section inside the grid.
    seen = reachable(graph, view, visited);
    check(seen[2], "air above wall did not see the target");
    view.portalCell = {-1, 0, 0};
    graph.nodes[1].exits.fill(63); // Door opens; next immutable graph sees it.
    buildSpatialGraph(graph);
    seen = reachable(graph, view, visited);
    check(seen[2], "opened wall did not reveal target");

    // A negative-coordinate wall blocks the same line; translation does not
    // change the topology, and retired slots must not define spatial bounds.
    graph.nodes[1].exits.fill(0);
    graph.nodes.push_back(Node{}); graph.nodes.back().position = {INT32_MAX,0,0};
    for (auto& node : graph.nodes) if (node.live)
        for (auto& coordinate : node.position) coordinate -= 100;
    buildSpatialGraph(graph);
    view.portalCell = {-101,-100,-100};
    seen = reachable(graph, view, visited);
    check(graph.grid.size() == 6 && seen[1] && !seen[2], "negative/retired spatial coordinates changed visibility");

    auto shared = std::make_shared<Graph>(graph);
    auto scene = std::make_shared<Scene>();
    auto chunk = std::make_shared<Chunk>(); chunk->key = 7;
    chunk->sections = {{{},1,true,false}, {{},1,true,true}};
    scene->chunks.push_back(chunk); shared->bases[7] = 1; // Both sections refer to target id 2.
    view.moveBudget = 100;
    Worker worker; bool cached = false;
    auto first = worker.resolve(1, scene, shared, view, cached);
    check(first->chunks[0].sections[0] == Reject::Portal && first->chunks[0].sections[1] == Reject::None,
        "spatial culling ignored bounds/protrusion contract");
    check(worker.resolve(2, scene, shared, view, cached)->portals == first->portals,
        "spatial portal mask was not shared between passes");
    auto moved = view; moved.portalCell = {-100,-100,-99};
    check(!covers(*first, scene.get(), shared.get(), moved), "root=0 camera section change reused frame envelope");
    auto second = worker.resolve(1, scene, shared, moved, cached);
    check(!cached && second->portals != first->portals && second->chunks[0].sections[0] == Reject::None,
        "moving above wall retained root=0 occlusion cache");
    auto opened = std::make_shared<Graph>(*shared); opened->nodes[1].exits.fill(63);
    buildSpatialGraph(*opened);
    auto third = worker.resolve(1, scene, opened, view, cached);
    check(!cached && third->chunks[0].sections[0] == Reject::None, "door edit reused old spatial graph");
    worker.stop();

    Graph huge; huge.nodes.resize(3);
    huge.nodes[1].live = huge.nodes[2].live = true;
    huge.nodes[1].position = {INT32_MIN,0,0}; huge.nodes[2].position = {INT32_MAX,0,0};
    buildSpatialGraph(huge);
    check(huge.spatial && huge.grid.empty(), "sparse world exceeded dense spatial allocation limit");
    seen = reachable(huge, view, visited);
    check(seen[1] && seen[2], "extent fallback hid disconnected boundary sections");
    huge.nodes[2].position = huge.nodes[1].position;
    bool threw = false;
    try { buildSpatialGraph(huge); } catch (const std::exception&) { threw = true; }
    check(threw, "duplicate spatial coordinates were accepted");
    std::cout << "Spatial walls: outside/registered/air cameras, opened door, negative coordinates, protrusions and cache invalidation passed\n";
}
static void spatialRayTests() {
    // Independent segment/box oracle: every section hit by an unobstructed
    // straight ray must survive the directional portal traversal.
    std::mt19937 rng(77339);
    std::uniform_real_distribution<double> camera(-3.9,7.9), point(0.01,0.99);
    unsigned verified = 0;
    for (unsigned world = 0; world < 30; ++world) {
        Graph graph; graph.nodes.resize(1);
        for (int z = 0; z < 4; ++z) for (int y = 0; y < 4; ++y) for (int x = 0; x < 4; ++x) {
            if (rng()%3 == 0 && x+y+z != 0 && x+y+z != 9) continue; // unregistered air
            Node node; node.live = true; node.position = {x,y,z};
            node.exits.fill(rng()%3 == 0 ? 0 : 63);
            graph.nodes.push_back(node);
        }
        buildSpatialGraph(graph);
        for (unsigned trial = 0; trial < 80; ++trial) {
            Vec eye = {camera(rng),camera(rng),camera(rng)};
            View view; view.portals = true;
            for (unsigned a = 0; a < 3; ++a) view.portalCell[a] = int(std::floor(eye[a]));
            for (unsigned id = 1; id < graph.nodes.size(); ++id)
                if (graph.nodes[id].position == view.portalCell) view.root = id;
            if (view.root && !graph.nodes[view.root].exits[0]) continue; // solid-camera bypass belongs to Lua
            unsigned visited;
            auto seen = reachable(graph, view, visited);
            for (unsigned target = 1; target < graph.nodes.size(); ++target) {
                Vec end;
                for (unsigned a = 0; a < 3; ++a) end[a] = graph.nodes[target].position[a] + point(rng);
                bool blocked = false;
                for (unsigned id = 1; id < graph.nodes.size() && !blocked; ++id) {
                    if (id == target || graph.nodes[id].exits[0]) continue;
                    double near = 0, far = 1;
                    for (unsigned a = 0; a < 3; ++a) {
                        const double d = end[a]-eye[a], low = graph.nodes[id].position[a]-eye[a];
                        double t0 = low/d, t1 = (low+1)/d;
                        if (t0 > t1) std::swap(t0,t1);
                        near = std::max(near,t0); far = std::min(far,t1);
                    }
                    blocked = near < far;
                }
                if (!blocked) { ++verified; check(seen[target], "directional flood hid a directly visible ray target"); }
            }
        }
    }
    std::cout << "Spatial ray oracle: " << verified << " directly visible targets preserved in 30 sparse worlds\n";
}
static void spatialBoundaryTests() {
    Graph graph; graph.nodes.resize(1);
    for (int z = 0; z < 3; ++z) for (int y = 0; y < 3; ++y) for (int x : {0,2}) {
        Node node; node.live = true; node.position = {x,y,z};
        node.exits.fill(x == 0 ? 63 : 0);
        if (x == 0) { node.exits[2] = 55; node.exits[3] = 59; }
        for (unsigned face = 0; face < 6; ++face) for (unsigned b = 0; b < 4; ++b) for (unsigned a = 0; a < 4; ++a) {
            const unsigned px = face < 2 || face >= 4 ? a : face & 1 ? 0 : 3;
            node.boundary[face].push_back(x == 2 || px == 2 ? 64 : px < 2 ? 59 : 55);
        }
        graph.nodes.push_back(std::move(node));
    }
    buildSpatialGraph(graph);
    View view; view.portals = true; view.portalCell = {-1,1,1};
    unsigned visited;
    auto seen = reachable(graph, view, visited);
    for (unsigned id = 1; id < graph.nodes.size(); ++id)
        check(bool(seen[id]) == (graph.nodes[id].position[0] == 0), "shared boundary mixed the two sides of a thin wall");
    // A doorway in the center section reconnects both sides. Its first
    // target must become visible, without inventing a new exterior node.
    for (auto& node : graph.nodes) if (node.position == Cell{0,1,1}) {
        node.exits.fill(63);
        for (auto& face : node.boundary) std::fill(face.begin(),face.end(),uint8_t(63));
    }
    buildSpatialGraph(graph);
    seen = reachable(graph, view, visited);
    for (unsigned id = 1; id < graph.nodes.size(); ++id) if (graph.nodes[id].position == Cell{2,1,1})
        check(seen[id], "opened component boundary failed to reveal target");
    std::cout << "Spatial boundaries: nine thin-wall target sections hidden, disconnected face regions preserved, doorway restored\n";
}
static void coverageTests() {
    auto scene = std::make_shared<Scene>();
    auto chunk = std::make_shared<Chunk>();
    chunk->bounds = {{0,0,0}, {1,1,1}, std::sqrt(3.0)};
    scene->chunks.push_back(chunk);
    View expanded;
    expanded.planeCount = 1; expanded.planes[0] = {1,0,0};
    expanded.moveBudget = 4; expanded.normalBudget = 0.12; expanded.distance = 100;
    std::mt19937 random(9343);
    std::uniform_real_distribution<double> position(-200,200), eye(-2,2), angle(-0.11,0.11);
    for (unsigned trial = 0; trial < 20000; ++trial) {
        chunk->origin = {position(random), position(random), position(random)};
        auto frame = compute(scene, nullptr, expanded);
        View actual = expanded;
        actual.eye = {eye(random), eye(random), eye(random)};
        double a = angle(random);
        actual.planes[0] = {std::cos(a), std::sin(a), 0};
        actual.moveBudget = actual.normalBudget = 0;
        check(covers(frame, scene.get(), nullptr, actual), "valid conservative coverage rejected");
        if (testBounds(chunk->bounds, chunk->origin, actual, true) == Reject::None)
            check(frame.chunks[0].reject == Reject::None, "cached candidate omitted a currently visible box");
    }
    auto frame = compute(scene, nullptr, expanded);
    View moved = expanded; moved.eye[0] = 4.01;
    check(!covers(frame, scene.get(), nullptr, moved), "teleport reused old culling");
    moved = expanded; moved.planes[0] = {-1,0,0};
    check(!covers(frame, scene.get(), nullptr, moved), "turnaround reused old culling");
    moved = expanded; moved.root = 1;
    check(!covers(frame, scene.get(), nullptr, moved), "portal component change reused culling");
    auto other = std::make_shared<Scene>(*scene);
    check(!covers(frame, other.get(), nullptr, expanded), "scene revision reused culling");
    Graph graph;
    check(!covers(frame, scene.get(), &graph, expanded), "graph revision reused culling");
    moved = expanded; moved.planeCount = 0;
    check(!covers(frame, scene.get(), nullptr, moved), "orthographic view reused perspective culling");

    auto topology = std::make_shared<Graph>();
    topology->nodes.resize(3);
    topology->nodes[1].live = topology->nodes[2].live = true;
    topology->bases[chunk->key] = 0;
    chunk->origin = {0,0,0};
    chunk->sections = {{chunk->bounds, 2, true, false}, {chunk->bounds, 2, true, true}};
    View portal; portal.portals = true; portal.root = 1; portal.seed = 0;
    frame = compute(scene, topology, portal);
    check(frame.chunks[0].sections[0] == Reject::Portal &&
        frame.chunks[0].sections[1] == Reject::None, "protruding section must bypass owner portal");
}
static void directionTests() {
    std::vector<l2::Quad> quads;
    for (unsigned g = 0; g < 6; ++g) {
        l2::Quad quad;
        const unsigned a = g < 2 ? 2 : g < 4 ? 0 : 1, b = (a+1)%3, c = (a+2)%3;
        const float x[4] = {0,1,1,0}, y[4] = {0,0,1,1};
        for (unsigned i = 0; i < 4; ++i) {
            auto& v = quad.vertices[i];
            v.position[a] = 2;
            v.position[b] = x[i]; v.position[c] = (g & 1) ? -y[i] : y[i];
            v.normal[a] = (g & 1) ? -1.0f : 1.0f;
            v.color[0] = uint8_t(g * 4 + i);
        }
        quads.push_back(quad);
    }
    auto slope = quads[0]; slope.vertices[0].position[2] = 1;
    quads.push_back(slope);
    auto mismatch = quads[0]; mismatch.vertices[0].normal[2] = -1;
    quads.push_back(mismatch);
    quads.push_back(l2::Quad{});
    const auto original = quads;
    auto order = l2::directionOrder(quads);
    check(std::memcmp(quads.data(), original.data(), quads.size()*sizeof(l2::Quad)) == 0,
        "direction grouping mutated atlas/vertex data");
    for (unsigned g = 0; g < 6; ++g)
        check(order.ranges[g].count == 6 && order.quads[order.ranges[g].first/6] == g, "axis grouping failed");
    check(order.ranges[6].count == 18, "unsafe quad classified directional");
    auto sorted = order.quads; std::sort(sorted.begin(), sorted.end());
    for (unsigned i = 0; i < sorted.size(); ++i) check(sorted[i] == i, "index ordering lost/duplicated quads");
    float box[6] = {0,0,0,1,1,1};
    check(directionVisible(0, box, {0,0,0}, 0), "coplanar face vanished");
    check(!directionVisible(0, box, {0,0,-1}, 0), "back face was retained");
    check(directionVisible(1, box, {0,0,-1}, 0), "front face was discarded");
    check(directionVisible(6, box, {0,0,-100}, 0), "unassigned geometry was discarded");
}
static void workerTests() {
    Worker worker;
    auto scene = std::make_shared<Scene>();
    auto chunk = std::make_shared<Chunk>();
    scene->chunks.push_back(chunk);
    View view; view.moveBudget = 4;
    auto frame = worker.request(1, scene, nullptr, view);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!frame && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
        frame = worker.request(1, scene, nullptr, view);
    }
    check(frame && frame->error.empty() && frame->chunks.size() == 1, "visibility worker produced no usable frame");
    auto other = std::make_shared<Scene>(*scene);
    check(!worker.request(1, other, nullptr, view), "worker accepted retired scene");
    for (uint64_t lane = 2; lane < 100; ++lane) {
        worker.request(lane, scene, nullptr, view);
        worker.forget(lane);
    }
    worker.stop();
    check(!worker.request(1, scene, nullptr, view), "worker restart reused retired result");
    worker.stop();
}
static std::mutex gateMutex;
static std::condition_variable gateWake;
static bool gateEntered = false, gateReleased = false;
static Frame gatedCompute(std::shared_ptr<const Scene> scene, std::shared_ptr<const Graph> graph, const View& view,
    std::shared_ptr<const PortalMask> portals) {
    {
        std::unique_lock<std::mutex> lock(gateMutex);
        gateEntered = true;
        gateWake.notify_all();
        gateWake.wait(lock, [] { return gateReleased; });
    }
    return compute(std::move(scene), std::move(graph), view, std::move(portals));
}
static void coalescingTests() {
    Worker worker(gatedCompute);
    auto scene = std::make_shared<Scene>();
    scene->chunks.push_back(std::make_shared<Chunk>());
    View view; view.moveBudget = 4;
    worker.request(1, scene, nullptr, view);
    bool started;
    {
        std::unique_lock<std::mutex> lock(gateMutex);
        started = gateWake.wait_for(lock, std::chrono::seconds(5), [] { return gateEntered; });
    }
    for (unsigned i = 0; i < 100; ++i) worker.request(1, scene, nullptr, view);
    const auto during = worker.stats();
    {
        std::lock_guard<std::mutex> lock(gateMutex);
        gateReleased = true;
    }
    gateWake.notify_all();
    worker.stop();
    std::cout << "Same-view requests=101, scheduled=" << during.scheduled << ", coalesced=" << during.coalesced << '\n';
    check(started, "visibility worker did not start");
    check(during.scheduled == 1 && during.coalesced == 100,
        "identical in-flight visibility requests scheduled duplicate computation");
}
static void resolveTests() {
    Worker worker;
    auto scene = std::make_shared<Scene>();
    auto chunk = std::make_shared<Chunk>();
    chunk->bounds = {{0,0,0}, {1,1,1}, std::sqrt(3.0)};
    chunk->sections = {{chunk->bounds, 2, true, false}};
    scene->chunks.push_back(chunk);
    auto graph = std::make_shared<Graph>();
    graph->nodes.resize(3);
    graph->nodes[1].live = graph->nodes[2].live = true;
    graph->bases[0] = 0;
    View view; view.portals = true; view.root = 1; view.seed = 0; view.moveBudget = 4;
    bool cached = true;
    const auto first = worker.resolve(1, scene, graph, view, cached);
    check(!cached && first->chunks[0].sections[0] == Reject::Portal, "cold render selection did not cull hidden section");
    for (unsigned i = 0; i < 100; ++i) {
        check(worker.resolve(1, scene, graph, view, cached) == first && cached,
            "stationary render selection recomputed culling");
    }
    auto stats = worker.stats();
    check(stats.synchronous == 1 && stats.scheduled == 0 && stats.portalTraversals == 1,
        "cold render selection computed the same view on main and worker threads");
    auto secondScene = std::make_shared<Scene>(*scene);
    const auto second = worker.resolve(2, secondScene, graph, view, cached);
    check(!cached && first->portals == second->portals, "opaque/depth scenes repeated the same portal flood");
    auto moved = view; moved.eye[0] = 3;
    worker.resolve(1, scene, graph, moved, cached);
    check(cached, "conservative coverage expired before background refresh");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (worker.stats().completed == 0 && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    const auto refreshed = worker.resolve(1, scene, graph, moved, cached);
    stats = worker.stats();
    check(cached && refreshed->view.eye == moved.eye && stats.scheduled == 1 && stats.completed == 1
        && stats.portalTraversals == 1 && stats.portalCacheHits == 2,
        "camera movement did not reuse portal connectivity during background refresh");
    auto revised = std::make_shared<Graph>(*graph);
    worker.resolve(1, scene, revised, moved, cached);
    check(!cached && worker.stats().portalTraversals == 2, "graph revision reused obsolete portal connectivity");
    moved.root = 2;
    const auto newRoot = worker.resolve(1, scene, revised, moved, cached);
    check(!cached && newRoot->chunks[0].sections[0] == Reject::None && worker.stats().portalTraversals == 3,
        "camera portal root change reused a sealed component");
    worker.stop();
    std::cout << "Render selection: 101 stationary draws = 1 cull, portal reuse across movement/passes, revision invalidation passed\n";
}
static Frame gatedRefresh(std::shared_ptr<const Scene> scene, std::shared_ptr<const Graph> graph, const View& view,
    std::shared_ptr<const PortalMask> portals) {
    if (view.eye[0] == 3) return gatedCompute(std::move(scene), std::move(graph), view, std::move(portals));
    return compute(std::move(scene), std::move(graph), view, std::move(portals));
}
static void lateRefreshTests() {
    { std::lock_guard<std::mutex> lock(gateMutex); gateEntered = gateReleased = false; }
    Worker worker(gatedRefresh);
    struct Release {
        ~Release() {
            { std::lock_guard<std::mutex> lock(gateMutex); gateReleased = true; }
            gateWake.notify_all();
        }
    } release;
    auto scene = std::make_shared<Scene>();
    scene->chunks.push_back(std::make_shared<Chunk>());
    View view; view.moveBudget = 4;
    bool cached;
    worker.resolve(1, scene, nullptr, view, cached);
    view.eye[0] = 3;
    worker.resolve(1, scene, nullptr, view, cached);
    {
        std::unique_lock<std::mutex> lock(gateMutex);
        check(gateWake.wait_for(lock, std::chrono::seconds(5), [] { return gateEntered; }), "refresh did not start");
    }
    view.eye[0] = 100;
    const auto teleported = worker.resolve(1, scene, nullptr, view, cached);
    check(!cached, "teleport used obsolete conservative coverage");
    { std::lock_guard<std::mutex> lock(gateMutex); gateReleased = true; }
    gateWake.notify_all();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (worker.stats().completed == 0 && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    check(worker.resolve(1, scene, nullptr, view, cached) == teleported && cached
        && worker.stats().synchronous == 2, "late background result overwrote current camera culling");
}
int main() {
    try {
        portalTests(); spatialPortalTests(); spatialBoundaryTests(); spatialRayTests(); coverageTests(); directionTests(); workerTests(); coalescingTests(); resolveTests(); lateRefreshTests();
        std::cout << "PASS: portals, 20000 conservative-coverage trials, directions, immutable atlas order, worker lifecycle\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
