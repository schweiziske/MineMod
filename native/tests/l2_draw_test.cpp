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
int main() {
    try {
        portalTests(); coverageTests(); directionTests(); workerTests();
        std::cout << "PASS: portals, 20000 conservative-coverage trials, directions, immutable atlas order, worker lifecycle\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
