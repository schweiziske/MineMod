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
using Cell = std::array<int, 3>;
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
struct PortalComponent { uint8_t mask = 0; std::array<uint64_t, 6> targets{}; };
struct Node {
    Cell position{};
    std::array<unsigned, 6> neighbors{};
    std::array<uint8_t, 6> exits{};
    // Build-boundary inputs; the bridge releases these after linking components.
    std::array<std::vector<uint8_t>, 6> boundary;
    std::array<uint64_t, 6> entries{};
    std::vector<PortalComponent> components;
    bool live = false;
};
struct Graph {
    std::vector<Node> nodes; // zero is the virtual exterior
    std::unordered_map<double, unsigned> bases;
    bool spatial = false;
    Cell lower{}, size{};
    std::vector<unsigned> grid; // zero is an open, unregistered section at this position
};
struct View {
    Vec eye{};
    Cell portalCell{};
    std::array<Vec, 5> planes{};
    unsigned planeCount = 0, root = 0;
    uint8_t seed = 63;
    bool portals = false;
    double distance = 0, moveBudget = 0, normalBudget = 0.12;
};
enum class Reject : uint8_t { None, Distance, Frustum, Portal };
struct VisibleChunk { Reject reject = Reject::None; std::vector<Reject> sections; };
struct PortalMask {
    std::shared_ptr<const Graph> graph;
    unsigned root = 0;
    uint8_t seed = 63;
    Cell cell{};
    unsigned visited = 0;
    std::vector<uint8_t> seen;
    bool matches(const Graph* value, const View& view) const {
        return graph.get() == value && root == view.root && seed == view.seed &&
            (!value->spatial || cell == view.portalCell);
    }
};
struct Frame {
    std::shared_ptr<const Scene> scene;
    std::shared_ptr<const Graph> graph;
    View view;
    std::shared_ptr<const PortalMask> portals;
    std::vector<VisibleChunk> chunks;
    std::string error;
    double milliseconds = 0;
};
std::vector<uint8_t> reachable(const Graph& graph, unsigned root, uint8_t seed);
void buildSpatialGraph(Graph& graph);
std::vector<uint8_t> reachable(const Graph& graph, const View& view, unsigned& visited);
Reject testBounds(const Bounds& bounds, const Vec& origin, const View& view, bool distance);
Frame compute(std::shared_ptr<const Scene> scene, std::shared_ptr<const Graph> graph, const View& view,
    std::shared_ptr<const PortalMask> portals = nullptr);
bool covers(const Frame& frame, const Scene* scene, const Graph* graph, const View& view);
bool directionVisible(unsigned group, const float bounds[6], const Vec& eye, double margin);
struct WorkerStats {
    uint64_t requests = 0, cacheHits = 0, coalesced = 0, scheduled = 0, completed = 0;
    uint64_t synchronous = 0, portalTraversals = 0, portalCacheHits = 0;
    double computeMS = 0;
    unsigned running = 0;
};

class Worker {
public:
    using Evaluator = Frame (*)(std::shared_ptr<const Scene>, std::shared_ptr<const Graph>, const View&,
        std::shared_ptr<const PortalMask>);
    explicit Worker(Evaluator evaluator = compute) : evaluator_(evaluator) {}
    ~Worker() { stop(); }
    std::shared_ptr<const Frame> request(uint64_t lane, std::shared_ptr<const Scene> scene,
        std::shared_ptr<const Graph> graph, const View& view);
    // Render-thread selection: fill a cold cache once, then refresh in the
    // background before the current conservative envelope stops covering it.
    std::shared_ptr<const Frame> resolve(uint64_t lane, std::shared_ptr<const Scene> scene,
        std::shared_ptr<const Graph> graph, const View& view, bool& cached);
    void forget(uint64_t lane);
    void stop();
    WorkerStats stats() const;
private:
    struct Slot {
        std::shared_ptr<const Frame> pending, running, ready, latest;
        bool queued = false;
    };
    void run();
    std::shared_ptr<Slot> slot(uint64_t lane);
    std::shared_ptr<const Frame> makeRequest(std::shared_ptr<const Scene> scene,
        std::shared_ptr<const Graph> graph, const View& view);
    void schedule(const std::shared_ptr<Slot>& slot, std::shared_ptr<const Scene> scene,
        std::shared_ptr<const Graph> graph, const View& view);
    void publish(Slot& slot, const std::shared_ptr<const Frame>& request, std::shared_ptr<const Frame> result);
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::unordered_map<uint64_t, std::shared_ptr<Slot>> slots_;
    std::deque<std::shared_ptr<Slot>> queue_;
    std::thread thread_;
    bool stopping_ = false;
    Evaluator evaluator_;
    WorkerStats stats_;
    std::shared_ptr<const PortalMask> portals_;
};
}
