#pragma once
#include <array>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

// Immutable CPU snapshots only. No Lua references or Source resources on workers.
namespace mcmesh::l2draw {
using Vec = std::array<double, 3>;
struct Bounds { Vec center{}, half{}; double radius = 0; };
struct Section {
    Bounds bounds;
    unsigned index = 0;
    bool bounded = false, protrudes = false;
};
struct Chunk {
    double key = 0;
    Vec origin{};
    Bounds bounds;
    std::vector<Section> sections;
};
struct Scene { std::vector<std::shared_ptr<const Chunk>> chunks; };
struct Node {
    std::array<unsigned, 6> neighbors{};
    std::array<uint8_t, 6> exits{};
    bool live = false;
};
struct Graph {
    std::vector<Node> nodes; // zero is the virtual exterior
    std::unordered_map<double, unsigned> bases;
};
struct View {
    Vec eye{};
    std::array<Vec, 5> planes{};
    unsigned planeCount = 0, root = 0;
    uint8_t seed = 63;
    bool portals = false;
    double distance = 0, moveBudget = 0, normalBudget = 0.12;
};
enum class Reject : uint8_t { None, Distance, Frustum, Portal };
struct VisibleChunk { Reject reject = Reject::None; std::vector<Reject> sections; };
struct Frame {
    std::shared_ptr<const Scene> scene;
    std::shared_ptr<const Graph> graph;
    View view;
    std::vector<VisibleChunk> chunks;
    std::string error;
    double milliseconds = 0;
};
std::vector<uint8_t> reachable(const Graph& graph, unsigned root, uint8_t seed);
Reject testBounds(const Bounds& bounds, const Vec& origin, const View& view, bool distance);
Frame compute(std::shared_ptr<const Scene> scene, std::shared_ptr<const Graph> graph, const View& view);
bool covers(const Frame& frame, const Scene* scene, const Graph* graph, const View& view);
bool directionVisible(unsigned group, const float bounds[6], const Vec& eye, double margin);

class Worker {
public:
    ~Worker() { stop(); }
    std::shared_ptr<const Frame> request(uint64_t lane, std::shared_ptr<const Scene> scene,
        std::shared_ptr<const Graph> graph, const View& view);
    void forget(uint64_t lane);
    void stop();
private:
    struct Slot {
        std::shared_ptr<Frame> pending;
        std::shared_ptr<const Frame> ready;
        bool queued = false;
    };
    void run();
    std::mutex mutex_;
    std::condition_variable wake_;
    std::unordered_map<uint64_t, std::shared_ptr<Slot>> slots_;
    std::deque<std::shared_ptr<Slot>> queue_;
    std::thread thread_;
    bool stopping_ = false;
};
}
