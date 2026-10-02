#include "l2_worker.h"
#include <algorithm>
#include <chrono>
#include <limits>
#include <cmath>
#include <cstring>

namespace mcmesh::l2 {
namespace {
double milliseconds() {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
constexpr int Offsets[6][3] = {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}};
bool visible(Input& input, const Voxel& voxel, unsigned face, uint32_t block, bool keepInternal = false) {
    const auto& off = Offsets[face];
    const auto packed = input.snapshot.read(voxel.source[0] + off[0],
        voxel.source[1] + off[1], voxel.source[2] + off[2]).renderClass;
    const auto id = packed >> 3, flags = packed & 7;
    return !id || (flags & 4) || ((flags & 2) ? id != block || keepInternal : !(flags & 1));
}
template<class Emit>
void visitVoxel(Input& input, const Voxel& voxel, Emit emit) {
    if (!voxel.model) {
        const auto& cube = input.cubes[voxel.cube];
        for (unsigned face = 0; face < 6; ++face)
            if (visible(input, voxel, face, cube.block)) emit(cube.faces[face], cube.groups[face]);
        return;
    }
    const auto& binding = input.models[voxel.cube];
    const auto& model = *binding.model;
    bool ao = true;
    for (size_t i = 0; i < model.groups.size(); ++i) {
        const auto& group = model.groups[i];
        const auto& selected = group.alternatives[modelChoice(group, voxel.source)];
        if (i == 0) ao = selected.modelAO;
        for (const auto& quad : selected.quads) {
            if (quad.cullFace && !visible(input, voxel, quad.cullFace - 1, model.block, model.keepInternalFaces)) continue;
            Work work = quad.work;
            if (!ao) work.geometry = quad.withoutAO;
            emit(work, binding.group);
        }
    }
}
}
unsigned modelChoice(const ModelGroup& group, const int source[3]) {
    if (group.alternatives.size() == 1) return 0;
    // Match LuaJIT's bias-add bit conversion, not integer modulo. Far-coordinate
    // products can exceed the exact-integer range of an IEEE double.
    const auto bits = [](double value) {
        const double biased = value + 6755399441055744.0;
        uint64_t raw;
        std::memcpy(&raw, &biased, sizeof(raw));
        return uint32_t(raw);
    };
    uint32_t hash = bits(double(source[0]) * 73428767.0) ^ bits(double(source[1]) * 912931.0)
        ^ bits(double(source[2]) * 19349663.0) ^ bits(double(group.salt) * 83492791.0);
    unsigned choice = (hash & 0x7fffffffu) % group.totalWeight;
    for (unsigned i = 0; i < group.alternatives.size(); ++i) {
        if (choice < group.alternatives[i].weight) return i;
        choice -= group.alternatives[i].weight;
    }
    return 0;
}
void validateModel(Model& model) {
    require(model.block > 0 && model.block <= (UINT32_MAX >> 3), "invalid model block ID");
    require(!model.groups.empty() && model.groups.size() <= 255, "invalid model group count");
    model.maxQuads = 0;
    model.bytes = sizeof(Model) + model.groups.capacity() * sizeof(ModelGroup);
    size_t totalQuads = 0;
    for (auto& group : model.groups) {
        require(!group.alternatives.empty() && group.alternatives.size() <= 255, "invalid model alternatives");
        require(group.salt <= 65535u * 132u, "invalid model choice salt");
        group.totalWeight = 0;
        size_t maximum = 0;
        model.bytes += group.alternatives.capacity() * sizeof(ModelAlternative);
        for (const auto& alternative : group.alternatives) {
            require(alternative.weight > 0 && alternative.weight <= 255, "invalid model weight");
            group.totalWeight += alternative.weight;
            maximum = std::max(maximum, alternative.quads.size());
            totalQuads += alternative.quads.size();
            require(totalQuads <= WorkerPool::MaxSectionQuads, "model recipe exceeds quad budget");
            model.bytes += alternative.quads.capacity() * sizeof(ModelQuad);
            for (const auto& quad : alternative.quads) {
                require(quad.cullFace <= 6, "invalid model cull face");
                require(quad.work.geometry.mode == 0 && quad.withoutAO.mode == 0, "model requires standard L2 lighting");
                require(quad.work.command.size == 1, "model recipe requires unit scale");
                for (unsigned axis = 0; axis < 3; ++axis)
                    require(quad.work.command.source[axis] == 0 && quad.work.command.translation[axis] == 0,
                        "model recipe requires zero source and translation");
            }
        }
        model.maxQuads += maximum;
    }
}
void validateCube(const Cube& cube) {
    require(cube.block > 0 && cube.block <= (UINT32_MAX >> 3), "invalid cube block ID");
    for (unsigned face = 0; face < 6; ++face) {
        const auto& work = cube.faces[face];
        require(work.geometry.mode == 0 && work.geometry.face == static_cast<int>(face),
            "cube recipe requires standard lit faces");
        require(work.command.size == 1, "cube recipe requires unit scale");
        for (unsigned axis = 0; axis < 3; ++axis) {
            require(work.command.source[axis] == 0 && work.command.translation[axis] == 0,
                "cube recipe requires zero source and translation");
            for (const auto& p : work.geometry.positions)
                require(p[axis] >= 0 && p[axis] <= 1, "cube recipe position outside unit bounds");
        }
    }
}
size_t Input::reservation() const {
    size_t bytes = snapshot.bytes() + sizeof(Input) + parts.capacity() * sizeof(std::vector<Work>);
    for (const auto& part : parts)
        bytes += part.capacity() * sizeof(Work) + sizeof(Part) + part.size() * (sizeof(Quad) + 5 * sizeof(uint32_t));
    size_t expanded = instances ? instances->maxQuads() : 0;
    if (instances) bytes += instances->bytes();
    for (const auto& voxel : voxels) expanded += voxel.model ? models[voxel.cube].model->maxQuads : 6;
    require(expanded <= WorkerPool::MaxSectionQuads, "L2 instances exceed quad reservation");
    for (const auto& model : models) bytes += model.model->bytes;
    return bytes + cubes.capacity() * sizeof(Cube) + voxels.capacity() * sizeof(Voxel)
        + models.capacity() * sizeof(ModelBinding)
        // Growing work vectors can reserve up to twice their live element count.
        + expanded * (2 * sizeof(Work) + sizeof(Quad) + 5 * sizeof(uint32_t))
        + WorkerPool::MaxParts * (sizeof(Part) + 2 * sizeof(std::vector<Work>) + 64);
}
void prefetchVoxels(Input& input) {
    // Freeze only reachable samples, including visibility neighbours. No Lua
    // command arrays or vertex records are allocated for the supported cells.
    for (const auto& voxel : input.voxels) {
        visitVoxel(input, voxel, [&](const Work& work, unsigned) {
            Command command = work.command;
            std::copy(std::begin(voxel.source), std::end(voxel.source), command.source);
            prefetch(work.geometry, command, input.snapshot);
        });
    }
}
void expandVoxels(Input& input, std::vector<unsigned>& groups, const std::atomic<bool>& cancelled) {
    std::unordered_map<unsigned, size_t> buckets;
    groups.resize(input.parts.size(), 0);
    size_t count = 0;
    for (const auto& part : input.parts) count += part.size();
    for (const auto& voxel : input.voxels) {
        if (cancelled) return;
        visitVoxel(input, voxel, [&](const Work& source, unsigned group) {
            require(++count <= WorkerPool::MaxSectionQuads, "L2 voxel section exceeds quad budget");
            auto found = buckets.find(group);
            if (found == buckets.end() || input.parts[found->second].size() == input.maxQuads) {
                require(input.parts.size() < WorkerPool::MaxParts, "L2 voxel section exceeds part budget");
                const auto slot = input.parts.size();
                buckets[group] = slot;
                input.parts.emplace_back();
                groups.push_back(group);
                found = buckets.find(group);
            }
            Work work = source;
            std::copy(std::begin(voxel.source), std::end(voxel.source), work.command.source);
            std::copy(std::begin(voxel.translation), std::end(voxel.translation), work.command.translation);
            work.command.size = input.blockSize;
            input.parts[found->second].push_back(std::move(work));
        });
    }
}
WorkerPool::~WorkerPool() { stop(); }
void WorkerPool::start(unsigned count) {
    if (!threads_.empty()) return;
    if (!count) {
        const auto hardware = std::thread::hardware_concurrency();
        count = std::clamp(hardware > 2 ? hardware - 2 : 1u, 1u, 8u);
    }
    stopping_ = false;
    try {
        for (unsigned i = 0; i < count; ++i) threads_.emplace_back([this] { run(); });
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.workers = count;
    } catch (...) { stop(); throw; }
}
void WorkerPool::stop() {
    cancel(0);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    wake_.notify_all();
    for (auto& thread : threads_) thread.join();
    threads_.clear();
    std::lock_guard<std::mutex> lock(mutex_);
    stats_.workers = 0;
    // A reopened Lua state must pass admission before submit lazily starts workers.
    stopping_ = false;
}
bool WorkerPool::canSubmit() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return !stopping_ && jobs_.size() < MaxJobs && stats_.bytes < MaxBytes;
}
uint64_t WorkerPool::submit(std::unique_ptr<Input> input) {
    const size_t bytes = input->reservation();
    require(bytes <= MaxBytes, "L2 section exceeds worker memory budget");
    input->snapshot.freeze();
    auto job = std::make_shared<Job>();
    job->bytes = bytes;
    job->input = std::move(input);
    job->submittedAt = milliseconds();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_ || jobs_.size() >= MaxJobs || bytes > MaxBytes - stats_.bytes) return 0;
        job->id = next_++;
        jobs_.emplace(job->id, job);
        try { queue_.push_back(job); }
        catch (...) { jobs_.erase(job->id); throw; }
        stats_.bytes += bytes;
        ++stats_.submitted;
    }
    wake_.notify_one();
    return job->id;
}
JobState WorkerPool::state(uint64_t id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = jobs_.find(id);
    require(it != jobs_.end() && !it->second->cancelled, "unknown or cancelled L2 job");
    return it->second->state;
}
std::shared_ptr<const Job> WorkerPool::ready(uint64_t id) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = jobs_.find(id);
    require(it != jobs_.end() && !it->second->cancelled, "unknown or cancelled L2 job");
    const auto& job = it->second;
    require(job->state == JobState::Ready || job->state == JobState::Failed, "L2 result is not ready");
    return job;
}
void WorkerPool::cancel(uint64_t id) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& entry : jobs_) {
            auto& job = entry.second;
            if ((!id || id == job->id) && !job->cancelled) {
                if (job->state == JobState::Ready || job->state == JobState::Failed)
                    queue_.push_back(job);
                job->cancelled = true;
                ++stats_.cancelled;
            }
        }
    }
    wake_.notify_all();
}
WorkerStats WorkerPool::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    auto result = stats_;
    for (const auto& entry : jobs_) {
        switch (entry.second->state) {
        case JobState::Queued: ++result.queued; break;
        case JobState::Ready: case JobState::Failed: ++result.ready; break;
        default: break;
        }
    }
    return result;
}
void WorkerPool::run() {
    for (;;) {
        std::shared_ptr<Job> job;
        bool wasRunning = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
            if (queue_.empty()) return;
            job = std::move(queue_.front());
            queue_.pop_front();
            if (!job->cancelled) {
                job->state = JobState::Running;
                wasRunning = true;
                ++stats_.running;
                stats_.peakRunning = std::max(stats_.peakRunning, stats_.running);
            }
        }
        const double started = milliseconds();
        const bool compute = !job->cancelled;
        if (compute) {
            try {
                job->queueMS = started - job->submittedAt;
                auto& input = *job->input;
                std::vector<unsigned> groups;
                if (input.instances) input.instances->populate(input, job->cancelled);
                job->sectionVoxels = input.voxels.size();
                job->topology = std::move(input.topology);
                const size_t legacyParts = input.parts.size();
                expandVoxels(input, groups, job->cancelled);
                for (size_t p = legacyParts; p < input.parts.size(); ++p) job->sectionQuads += input.parts[p].size();
                job->parts.resize(input.parts.size());
                for (size_t p = 0; p < input.parts.size() && !job->cancelled; ++p) {
                    auto& output = job->parts[p];
                    output.group = groups[p];
                    const auto& work = input.parts[p];
                    output.quads.resize(work.size());
                    output.pixels.resize(work.size() * 4);
                    output.occlusion.resize(work.size());
                    std::fill(output.bounds, output.bounds + 3, std::numeric_limits<float>::max());
                    std::fill(output.bounds + 3, output.bounds + 6, -std::numeric_limits<float>::max());
                    for (unsigned i = 0; i < work.size(); ++i) {
                        if ((i & 63) == 0 && job->cancelled) break;
                        auto& q = output.quads[i];
                        q = evaluate(work[i].geometry, work[i].command, input.snapshot, i);
                        std::copy(std::begin(q.pixels), std::end(q.pixels), output.pixels.begin() + i * 4);
                        output.occlusion[i] = q.occlusion;
                        for (const auto& v : q.vertices) for (unsigned a = 0; a < 3; ++a) {
                            output.bounds[a] = std::min(output.bounds[a], v.position[a]);
                            output.bounds[a + 3] = std::max(output.bounds[a + 3], v.position[a]);
                        }
                    }
                }
                job->reads = input.snapshot.reads;
                job->hits = input.snapshot.hits;
            } catch (const std::exception& e) { job->error = e.what(); }
            catch (...) { job->error = "unknown L2 worker failure"; }
        }
        job->input.reset();
        job->computeMS = milliseconds() - started;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (wasRunning) --stats_.running;
            if (job->cancelled) {
                stats_.bytes -= job->bytes;
                jobs_.erase(job->id);
            } else {
                job->state = job->error.empty() ? JobState::Ready : JobState::Failed;
                ++stats_.completed;
                stats_.computeMS += job->computeMS;
                stats_.queueMS += job->queueMS;
                stats_.sectionVoxels += job->sectionVoxels;
                stats_.sectionQuads += job->sectionQuads;
            }
        }
        // Cancelled input/results are destroyed here, never in a render callback.
    }
}
}
