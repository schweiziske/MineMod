#include "l2_draw.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <stdexcept>

namespace mcmesh::l2draw {
namespace {
double length(const Vec& v) { return std::sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]); }
Vec subtract(const Vec& a, const Vec& b) { return {a[0]-b[0], a[1]-b[1], a[2]-b[2]}; }
}
std::vector<uint8_t> reachable(const Graph& graph, unsigned root, uint8_t seed) {
    std::vector<uint8_t> seen(graph.nodes.size()), exits(graph.nodes.size()), sent(graph.nodes.size()),
        queued(graph.nodes.size());
    std::vector<unsigned> queue;
    auto visit = [&](unsigned id, uint8_t mask) {
        seen[id] = 1; // The wall that stops propagation is itself visible.
        const auto combined = uint8_t(exits[id] | mask);
        if (combined == exits[id]) return;
        exits[id] = combined;
        if (!queued[id]) { queued[id] = 1; queue.push_back(id); }
    };
    bool exteriorSeen = false;
    auto exterior = [&] {
        exteriorSeen = true;
        for (unsigned id = 1; id < graph.nodes.size(); ++id) {
            const auto& node = graph.nodes[id];
            if (node.live) for (unsigned face = 0; face < 6; ++face)
                if (!node.neighbors[face]) visit(id, node.exits[face]);
        }
    };
    if (root) {
        if (root >= graph.nodes.size() || !graph.nodes[root].live || seed > 63)
            throw std::runtime_error("invalid Native visibility root");
        visit(root, seed);
    } else exterior();
    for (size_t head = 0; head < queue.size(); ++head) {
        const unsigned id = queue[head];
        queued[id] = 0;
        const unsigned pending = exits[id] & ~sent[id];
        sent[id] = exits[id];
        for (unsigned face = 0; face < 6; ++face) if (pending & (1u << face)) {
            const auto neighbor = graph.nodes[id].neighbors[face];
            if (neighbor) visit(neighbor, graph.nodes[neighbor].exits[face ^ 1]);
            else if (!exteriorSeen) exterior();
        }
    }
    return seen;
}
void buildSpatialGraph(Graph& graph) {
    graph.spatial = true;
    graph.grid.clear(); graph.lower = {}; graph.size = {};
    std::vector<Cell> positions;
    for (const auto& node : graph.nodes) if (node.live) positions.push_back(node.position);
    if (positions.empty()) return;
    std::sort(positions.begin(), positions.end());
    if (std::adjacent_find(positions.begin(), positions.end()) != positions.end())
        throw std::runtime_error("duplicate Native spatial section");
    Cell upper = graph.lower = positions.front();
    for (const auto& p : positions) for (unsigned a = 0; a < 3; ++a) {
        graph.lower[a] = std::min(graph.lower[a], p[a]);
        upper[a] = std::max(upper[a], p[a]);
    }
    // Widely separated islands must not create an unbounded dense allocation.
    // Such graphs retain conservative connectivity and report that mode.
    constexpr uint64_t limit = 1u << 20;
    uint64_t volume = 1;
    Cell size;
    for (unsigned a = 0; a < 3; ++a) {
        const auto extent = uint64_t(int64_t(upper[a]) - graph.lower[a] + 1);
        if (extent > limit / volume) return;
        volume *= extent; size[a] = int(extent);
    }
    graph.size = size;
    graph.grid.resize(size_t(volume));
    for (unsigned id = 1; id < graph.nodes.size(); ++id) if (graph.nodes[id].live) {
        const auto& p = graph.nodes[id].position;
        const unsigned slot = unsigned(p[0]-graph.lower[0]) + unsigned(size[0]) *
            (unsigned(p[1]-graph.lower[1]) + unsigned(size[1])*unsigned(p[2]-graph.lower[2]));
        graph.grid[slot] = id;
    }
    const unsigned axes[6] = {2, 2, 0, 0, 1, 1};
    const unsigned stride[3] = {1, unsigned(size[0]), unsigned(size[0]*size[1])};
    for (unsigned slot = 0; slot < graph.grid.size(); ++slot) {
        const auto id = graph.grid[slot];
        if (!id) continue;
        auto& node = graph.nodes[id];
        node.entries = {}; node.components.clear();
        uint64_t masks = 0;
        for (unsigned face = 0; face < 6; ++face) {
            if (node.boundary[face].empty()) node.entries[face] = uint64_t(1) << node.exits[face];
            else for (const auto cell : node.boundary[face]) node.entries[face] |= uint64_t(1) << (cell == 64 ? 0 : cell);
            masks |= node.entries[face];
        }
        for (unsigned mask = 1; mask < 64; ++mask) if (masks & (uint64_t(1) << mask)) {
            PortalComponent component; component.mask = uint8_t(mask);
            for (unsigned face = 0; face < 6; ++face) if (mask & (1u << face)) {
                const unsigned a = axes[face];
                const int p = node.position[a]-graph.lower[a];
                const bool edge = face & 1 ? p == 0 : p == size[a]-1;
                const unsigned neighbor = edge ? 0 : graph.grid[face & 1 ? slot-stride[a] : slot+stride[a]];
                if (!neighbor) { component.targets[face] = uint64_t(1) << 63; continue; }
                const auto& from = node.boundary[face];
                const auto& other = graph.nodes[neighbor];
                const auto& to = other.boundary[face ^ 1];
                if (from.empty() || to.empty()) {
                    component.targets[face] = uint64_t(1) << other.exits[face ^ 1];
                    continue;
                }
                if (from.size() != to.size()) throw std::runtime_error("Native portal boundary sizes disagree");
                // Keep disconnected air regions separate across a shared face.
                // Equal six-bit component masks may merge, which only adds visibility.
                for (size_t cell = 0; cell < from.size(); ++cell) if (from[cell] == mask)
                    component.targets[face] |= uint64_t(1) << (to[cell] == 64 ? 0 : to[cell]);
            }
            node.components.push_back(component);
        }
    }
}
std::vector<uint8_t> reachable(const Graph& graph, const View& view, unsigned& visited) {
    if (!graph.spatial || graph.grid.empty()) {
        auto seen = reachable(graph, view.root, view.seed);
        visited = unsigned(std::count(seen.begin(), seen.end(), uint8_t(1)));
        return seen;
    }
    const auto& size = graph.size;
    const unsigned strides[3] = {1, unsigned(size[0]), unsigned(size[0]*size[1])};
    constexpr unsigned axes[6] = {2, 2, 0, 0, 1, 1};
    const auto local = [&](unsigned slot) {
        return Cell{int(slot % size[0]), int(slot / size[0] % size[1]), int(slot / strides[2])};
    };
    const auto index = [&](const Cell& p) {
        return unsigned(p[0]) + strides[1]*unsigned(p[1]) + strides[2]*unsigned(p[2]);
    };
    std::vector<uint8_t> seen(graph.nodes.size()), queued(graph.grid.size()), entered(graph.grid.size());
    std::vector<uint64_t> exits(graph.grid.size()), sent(graph.grid.size());
    std::vector<unsigned> queue;
    visited = 0;
    auto visit = [&](unsigned slot, uint64_t mask) {
        if (!entered[slot]) { entered[slot] = 1; ++visited; }
        const auto id = graph.grid[slot];
        if (id) seen[id] = 1; // A blocking wall is drawn even when it has no exits.
        const auto combined = exits[slot] | mask;
        if (combined == exits[slot]) return;
        exits[slot] = combined;
        if (!queued[slot]) { queued[slot] = 1; queue.push_back(slot); }
    };
    auto enter = [&](unsigned slot, unsigned face) {
        const auto id = graph.grid[slot];
        visit(slot, id ? graph.nodes[id].entries[face] : uint64_t(1) << 63);
    };
    bool inside = true;
    Cell camera{};
    for (unsigned a = 0; a < 3; ++a) {
        const int64_t p = int64_t(view.portalCell[a]) - graph.lower[a];
        if (p < 0 || p >= size[a]) inside = false;
        else camera[a] = int(p);
    }
    if (inside) {
        const auto slot = index(camera);
        if (graph.grid[slot] != view.root || view.seed > 63)
            throw std::runtime_error("Native camera section disagrees with spatial root");
        visit(slot, uint64_t(1) << view.seed);
    } else {
        if (view.root) throw std::runtime_error("Native spatial root outside graph bounds");
        // Every ray from outside a box enters a camera-facing boundary plane.
        // Seed whole planes, not a clamped point, to preserve oblique sightlines.
        for (unsigned face = 0; face < 6; ++face) {
            const unsigned a = axes[face], b = (a+1)%3, c = (a+2)%3;
            const bool positive = !(face & 1);
            if (positive ? int64_t(view.portalCell[a]) < int64_t(graph.lower[a])+size[a]
                         : view.portalCell[a] >= graph.lower[a]) continue;
            Cell p{}; p[a] = positive ? size[a]-1 : 0;
            for (p[b] = 0; p[b] < size[b]; ++p[b]) for (p[c] = 0; p[c] < size[c]; ++p[c])
                enter(index(p), face);
        }
    }
    for (size_t head = 0; head < queue.size(); ++head) {
        const unsigned slot = queue[head];
        queued[slot] = 0;
        const uint64_t pending = exits[slot] & ~sent[slot];
        sent[slot] = exits[slot];
        const auto p = local(slot);
        const auto id = graph.grid[slot];
        uint64_t targets[6] = {};
        if (id) {
            for (const auto& component : graph.nodes[id].components) if (pending & (uint64_t(1) << component.mask))
                for (unsigned face = 0; face < 6; ++face) targets[face] |= component.targets[face];
        } else if (pending & (uint64_t(1) << 63)) {
            for (auto& target : targets) target = uint64_t(1) << 63;
        }
        for (unsigned face = 0; face < 6; ++face) if (targets[face]) {
            const unsigned a = axes[face];
            const int absolute = p[a] + graph.lower[a];
            if (face & 1) {
                if (absolute > view.portalCell[a] || p[a] == 0) continue;
                if (id) visit(slot - strides[a], targets[face]);
                else enter(slot - strides[a], face ^ 1);
            } else {
                if (absolute < view.portalCell[a] || p[a] == size[a]-1) continue;
                if (id) visit(slot + strides[a], targets[face]);
                else enter(slot + strides[a], face ^ 1);
            }
        }
    }
    return seen;
}
Reject testBounds(const Bounds& bounds, const Vec& origin, const View& view, bool distance) {
    const Vec center = {origin[0]+bounds.center[0]-view.eye[0],
        origin[1]+bounds.center[1]-view.eye[1], origin[2]+bounds.center[2]-view.eye[2]};
    const double d = length(center);
    if (distance && view.distance > 0 && d > view.distance + bounds.radius + view.moveBudget)
        return Reject::Distance;
    // For every point p in the box: |(n'-n).p| <= |n'-n| * (|center|+radius).
    // This envelope safely covers both camera translation and rotation.
    const double slack = view.moveBudget + view.normalBudget * (d + bounds.radius);
    for (unsigned i = 0; i < view.planeCount; ++i) {
        const auto& n = view.planes[i];
        double value = slack;
        for (unsigned a = 0; a < 3; ++a)
            value += n[a]*center[a] + std::abs(n[a])*bounds.half[a];
        if (value < 0) return Reject::Frustum;
    }
    return Reject::None;
}
Frame compute(std::shared_ptr<const Scene> scene, std::shared_ptr<const Graph> graph, const View& view,
    std::shared_ptr<const PortalMask> portals) {
    const auto start = std::chrono::steady_clock::now();
    Frame frame;
    frame.scene = std::move(scene); frame.graph = std::move(graph); frame.view = view;
    if (view.portals) {
        if (!frame.graph) throw std::runtime_error("missing Native visibility graph");
        if (!portals || !portals->matches(frame.graph.get(), view)) {
            auto mask = std::make_shared<PortalMask>();
            mask->graph = frame.graph; mask->root = view.root; mask->seed = view.seed;
            mask->cell = view.portalCell;
            mask->seen = reachable(*frame.graph, view, mask->visited);
            portals = std::move(mask);
        }
        frame.portals = std::move(portals);
    }
    frame.chunks.resize(frame.scene->chunks.size());
    for (size_t i = 0; i < frame.chunks.size(); ++i) {
        const auto& chunk = *frame.scene->chunks[i];
        auto& result = frame.chunks[i];
        result.reject = testBounds(chunk.bounds, chunk.origin, view, true);
        if (result.reject != Reject::None) continue;
        unsigned base = 0;
        bool registered = false;
        if (view.portals) {
            const auto found = frame.graph->bases.find(chunk.key);
            if (found != frame.graph->bases.end()) { registered = true; base = found->second; }
        }
        result.sections.resize(chunk.sections.size());
        for (size_t s = 0; s < chunk.sections.size(); ++s) {
            const auto& section = chunk.sections[s];
            auto& reason = result.sections[s];
            if (section.bounded) reason = testBounds(section.bounds, chunk.origin, view, false);
            if (reason == Reject::None && registered && section.bounded && !section.protrudes) {
                const auto id = base + section.index;
                if (id >= frame.portals->seen.size() || !frame.graph->nodes[id].live)
                    throw std::runtime_error("Native visibility section is outside its graph");
                if (!frame.portals->seen[id]) reason = Reject::Portal;
            }
        }
    }
    frame.milliseconds = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - start).count();
    return frame;
}
bool covers(const Frame& frame, const Scene* scene, const Graph* graph, const View& view) {
    const auto& old = frame.view;
    if (frame.scene.get() != scene || frame.graph.get() != graph || old.portals != view.portals ||
        old.root != view.root || old.seed != view.seed || old.planeCount != view.planeCount ||
        old.distance != view.distance || length(subtract(old.eye, view.eye)) > old.moveBudget) return false;
    if (view.portals && graph && graph->spatial && old.portalCell != view.portalCell) return false;
    for (unsigned i = 0; i < view.planeCount; ++i)
        if (length(subtract(old.planes[i], view.planes[i])) > old.normalBudget) return false;
    return true;
}
bool directionVisible(unsigned group, const float bounds[6], const Vec& eye, double margin) {
    if (group == 6) return true;
    const unsigned axis = group < 2 ? 2 : group < 4 ? 0 : 1;
    return group & 1 ? eye[axis] <= bounds[axis+3] + margin : eye[axis] >= bounds[axis] - margin;
}
std::shared_ptr<const Frame> Worker::request(uint64_t lane, std::shared_ptr<const Scene> scene,
    std::shared_ptr<const Graph> graph, const View& view) {
    std::lock_guard<std::mutex> lock(mutex_);
    ++stats_.requests;
    auto entry = slot(lane);
    auto result = entry->ready;
    if (result && covers(*result, scene.get(), graph.get(), view)) { ++stats_.cacheHits; return result; }
    schedule(entry, std::move(scene), std::move(graph), view);
    return nullptr;
}
std::shared_ptr<Worker::Slot> Worker::slot(uint64_t lane) {
    auto& entry = slots_[lane];
    if (!entry) entry = std::make_shared<Slot>();
    return entry;
}
std::shared_ptr<const Frame> Worker::makeRequest(std::shared_ptr<const Scene> scene,
    std::shared_ptr<const Graph> graph, const View& view) {
    auto request = std::make_shared<Frame>();
    request->scene = std::move(scene); request->graph = std::move(graph); request->view = view;
    if (view.portals && portals_ && portals_->matches(request->graph.get(), view)) request->portals = portals_;
    return request;
}
void Worker::schedule(const std::shared_ptr<Slot>& entry, std::shared_ptr<const Scene> scene,
    std::shared_ptr<const Graph> graph, const View& view) {
    if (entry->pending && covers(*entry->pending, scene.get(), graph.get(), view)) {
        ++stats_.coalesced; return;
    }
    if (entry->running && covers(*entry->running, scene.get(), graph.get(), view)) {
        entry->pending.reset();
        entry->latest = entry->running;
        ++stats_.coalesced; return;
    }
    if (!thread_.joinable()) { stopping_ = false; thread_ = std::thread(&Worker::run, this); }
    auto request = makeRequest(std::move(scene), std::move(graph), view);
    if (!entry->queued) {
        queue_.push_back(entry); entry->queued = true;
        ++stats_.scheduled;
    }
    entry->latest = entry->pending = std::move(request);
    wake_.notify_one();
}
std::shared_ptr<const Frame> Worker::resolve(uint64_t lane, std::shared_ptr<const Scene> scene,
    std::shared_ptr<const Graph> graph, const View& view, bool& cached) {
    std::shared_ptr<Slot> entry;
    std::shared_ptr<const Frame> request;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ++stats_.requests;
        entry = slot(lane);
        const auto& ready = entry->ready;
        cached = ready && covers(*ready, scene.get(), graph.get(), view);
        if (cached) {
            ++stats_.cacheHits;
            const auto& old = ready->view;
            bool refresh = length(subtract(old.eye, view.eye)) > old.moveBudget * 0.5;
            for (unsigned i = 0; i < view.planeCount && !refresh; ++i)
                refresh = length(subtract(old.planes[i], view.planes[i])) > old.normalBudget * 0.5;
            if (refresh) schedule(entry, std::move(scene), std::move(graph), view);
            return ready;
        }
        // There is no usable frame after a scene/portal change or teleport.
        // Compute the required envelope once; don't also queue the same work.
        request = makeRequest(std::move(scene), std::move(graph), view);
        entry->pending.reset();
        entry->latest = request;
        ++stats_.synchronous;
    }
    auto result = std::make_shared<Frame>(evaluator_(request->scene, request->graph, request->view, request->portals));
    {
        std::lock_guard<std::mutex> lock(mutex_);
        publish(*entry, request, result);
    }
    return result;
}
void Worker::publish(Slot& slot, const std::shared_ptr<const Frame>& request, std::shared_ptr<const Frame> result) {
    stats_.computeMS += result->milliseconds;
    if (result->portals) {
        if (result->portals == request->portals) ++stats_.portalCacheHits;
        else ++stats_.portalTraversals;
    }
    // A late background result must not overwrite a newer synchronous frame.
    if (slot.latest != request) return;
    if (result->portals) portals_ = result->portals;
    slot.ready = std::move(result);
}
void Worker::forget(uint64_t lane) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = slots_.find(lane);
    if (found != slots_.end()) {
        found->second->pending.reset(); found->second->latest.reset(); slots_.erase(found);
    }
}
void Worker::stop() {
    { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; queue_.clear(); wake_.notify_all(); }
    if (thread_.joinable()) thread_.join();
    std::lock_guard<std::mutex> lock(mutex_);
    slots_.clear();
    portals_.reset();
}
WorkerStats Worker::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}
void Worker::run() {
    for (;;) {
        std::shared_ptr<Slot> slot;
        std::shared_ptr<const Frame> request;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
            if (stopping_) return;
            slot = queue_.front(); queue_.pop_front();
            slot->queued = false; request = std::move(slot->pending);
            slot->running = request;
            if (request) ++stats_.running;
        }
        if (!request) continue;
        auto result = std::make_shared<Frame>();
        try { *result = evaluator_(request->scene, request->graph, request->view, request->portals); }
        catch (const std::exception& e) { *result = *request; result->error = e.what(); }
        catch (...) { *result = *request; result->error = "unknown Native visibility worker failure"; }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            slot->running.reset();
            publish(*slot, request, std::move(result));
            --stats_.running;
            ++stats_.completed;
        }
    }
}
}
