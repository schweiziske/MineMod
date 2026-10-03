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
Frame compute(std::shared_ptr<const Scene> scene, std::shared_ptr<const Graph> graph, const View& view) {
    const auto start = std::chrono::steady_clock::now();
    Frame frame;
    frame.scene = std::move(scene); frame.graph = std::move(graph); frame.view = view;
    std::vector<uint8_t> seen;
    if (view.portals) {
        if (!frame.graph) throw std::runtime_error("missing Native visibility graph");
        seen = reachable(*frame.graph, view.root, view.seed);
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
                if (id >= seen.size() || !frame.graph->nodes[id].live)
                    throw std::runtime_error("Native visibility section is outside its graph");
                if (!seen[id]) reason = Reject::Portal;
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
    if (!thread_.joinable()) { stopping_ = false; thread_ = std::thread(&Worker::run, this); }
    auto& entry = slots_[lane];
    if (!entry) entry = std::make_shared<Slot>();
    auto result = entry->ready;
    if (result && covers(*result, scene.get(), graph.get(), view)) return result;
    auto request = std::make_shared<Frame>();
    request->scene = std::move(scene); request->graph = std::move(graph); request->view = view;
    entry->pending = std::move(request);
    if (!entry->queued) { entry->queued = true; queue_.push_back(entry); wake_.notify_one(); }
    return nullptr;
}
void Worker::forget(uint64_t lane) {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = slots_.find(lane);
    if (found != slots_.end()) { found->second->pending.reset(); slots_.erase(found); }
}
void Worker::stop() {
    { std::lock_guard<std::mutex> lock(mutex_); stopping_ = true; queue_.clear(); wake_.notify_all(); }
    if (thread_.joinable()) thread_.join();
    std::lock_guard<std::mutex> lock(mutex_);
    slots_.clear();
}
void Worker::run() {
    for (;;) {
        std::shared_ptr<Slot> slot;
        std::shared_ptr<Frame> request;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [&] { return stopping_ || !queue_.empty(); });
            if (stopping_) return;
            slot = queue_.front(); queue_.pop_front();
            slot->queued = false; request = std::move(slot->pending);
        }
        if (!request) continue;
        try { *request = compute(request->scene, request->graph, request->view); }
        catch (const std::exception& e) { request->error = e.what(); }
        catch (...) { request->error = "unknown Native visibility worker failure"; }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            slot->ready = std::move(request);
        }
    }
}
}
