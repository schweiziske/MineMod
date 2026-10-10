#pragma once
#include "l2_core.h"
#include "l2_fluid.h"
#include "l2_shapes.h"
#include "l2_pixels.h"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

// This pool owns CPU-only values. Neither jobs nor results may own engine/Lua objects.
namespace mcmesh::l2 {
struct Work { Template geometry; Command command; };
// A compiled, state-only cube recipe. No engine objects cross the worker boundary.
struct Cube {
    std::array<Work, 6> faces;
    std::array<unsigned, 6> groups{};
    uint32_t block = 0;
};
void validateCube(const Cube& cube);
struct ModelQuad {
    Work work;
    Template withoutAO;
    // Zero is unconditional; otherwise the Lua model emitter's one-based face.
    unsigned cullFace = 0;
    bool shapeCull = false;
    ShapeBox box{};
};
struct ModelAlternative {
    std::vector<ModelQuad> quads;
    unsigned weight = 1;
    bool modelAO = true;
};
struct ModelGroup {
    std::vector<ModelAlternative> alternatives;
    uint32_t salt = 0;
    unsigned totalWeight = 0;
};
struct Model {
    std::vector<ModelGroup> groups;
    uint32_t block = 0;
    size_t maxQuads = 0, bytes = 0;
    bool keepInternalFaces = false;
    unsigned shapeSelector = 0;
    bool needsShapes = false;
};
// Registration computes validated budgets once, outside instance/quad loops.
void validateModel(Model& model);
unsigned modelChoice(const ModelGroup& group, const int source[3]);
struct ModelBinding { std::shared_ptr<const Model> model; unsigned group = 0; };
struct Voxel {
    int source[3]{};
    double translation[3]{};
    unsigned cube = 0;
    bool model = false;
    bool fluid = false;
};
struct Part {
    std::vector<Quad> quads;
    DirectionOrder directions;
    std::shared_ptr<const LightPixels> pixels;
    float bounds[6]{};
    unsigned group = 0;
    std::shared_ptr<const std::vector<LightWork>> lighting;
};
struct Topology {
    std::array<uint8_t, 6> faces{};
    std::vector<uint8_t> cells;
    uint8_t uniform = 0;
    bool graphOpen = false;
};
struct Input;
struct InstanceSource {
    virtual ~InstanceSource() = default;
    virtual void populate(Input& input, const std::atomic<bool>& cancelled) const = 0;
    virtual size_t maxQuads() const = 0;
    virtual size_t bytes() const = 0;
};
struct Input {
    Snapshot snapshot;
    std::vector<std::vector<Work>> parts;
    std::vector<Cube> cubes;
    std::vector<ModelBinding> models;
    std::vector<FluidRecipe> fluids;
    std::shared_ptr<const FluidSource> fluidSource;
    std::shared_ptr<const ShapeSource> shapeSource;
    std::vector<Voxel> voxels;
    double blockSize = 1;
    unsigned maxQuads = MaxQuads;
    std::shared_ptr<const InstanceSource> instances;
    Topology topology;
    bool retainLighting = false;
    std::vector<std::shared_ptr<const std::vector<LightWork>>> relight;
    explicit Input(Snapshot&& value) : snapshot(std::move(value)) {}
    size_t reservation() const;
    MemoryUsage memoryUsage() const;
};
enum class JobState { Queued, Running, Ready, Failed };
struct Job {
    uint64_t id = 0;
    size_t bytes = 0;
    std::vector<SharedAllocation> shared;
    std::atomic<bool> cancelled{false};
    JobState state = JobState::Queued; // Protected by the pool mutex.
    std::unique_ptr<Input> input;
    std::vector<Part> parts;
    std::string error;
    double queueMS = 0, computeMS = 0, submittedAt = 0;
    uint64_t reads = 0, hits = 0;
    uint64_t faceSamples = 0, faceHits = 0;
    uint64_t sectionVoxels = 0, sectionQuads = 0;
    Topology topology;
    bool relight = false;
    size_t resultBytes() const;
};
struct WorkerStats {
    unsigned workers = 0, queued = 0, running = 0, ready = 0, peakRunning = 0;
    size_t bytes = 0;
    uint64_t submitted = 0, completed = 0, cancelled = 0;
    double computeMS = 0, queueMS = 0;
    uint64_t sectionVoxels = 0, sectionQuads = 0;
    uint64_t reads = 0, hits = 0, faceSamples = 0, faceHits = 0;
    uint64_t relightJobs = 0, relightQuads = 0;
};
void expandVoxels(Input& input, std::vector<unsigned>& groups, const std::atomic<bool>& cancelled);
void prefetchVoxels(Input& input);
class WorkerPool {
public:
    // Scheduling targets, not content limits. One larger task runs exclusively.
    static constexpr size_t TargetBytes = 128 * 1024 * 1024;
    static constexpr unsigned MaxJobs = 16;
    ~WorkerPool();
    void start(unsigned count = 0);
    void stop();
    bool canSubmit() const; // Capacity hint; submit checks the actual task footprint.
    uint64_t submit(std::unique_ptr<Input> input); // Zero means backpressure.
    std::shared_ptr<const Job> ready(uint64_t id) const;
    JobState state(uint64_t id) const;
    void cancel(uint64_t id); // Zero cancels all; disposal runs on workers.
    WorkerStats stats() const;
private:
    void run();
    void releaseShared(const Job& job, size_t count);
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::vector<std::thread> threads_;
    std::deque<std::shared_ptr<Job>> queue_;
    std::unordered_map<uint64_t, std::shared_ptr<Job>> jobs_;
    struct SharedUsage { size_t bytes = 0, references = 0; };
    std::unordered_map<const void*, SharedUsage> shared_;
    WorkerStats stats_;
    uint64_t next_ = 1;
    bool stopping_ = false;
};
}
