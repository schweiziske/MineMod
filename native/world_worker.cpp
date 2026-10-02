#include "world_worker.h"
#include <chrono>
#include <stdexcept>
#include <utility>

namespace mcmesh::world {
namespace {
double now() {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
}
LightWorker::~LightWorker() { stop(); }
uint64_t LightWorker::submit(std::shared_ptr<const Snapshot> source) {
    if (!source || !source->catalog) throw std::runtime_error("native light worker requires a sealed world snapshot");
    std::lock_guard<std::mutex> lock(mutex_);
    if (stats_.busy || stopping_) return 0;
    auto completion = std::make_unique<LightCompletion>();
    if (!thread_.joinable()) thread_ = std::thread(&LightWorker::run, this);
    pending_ = std::move(source);
    pendingCompletion_ = std::move(completion);
    cancelled_.store(false, std::memory_order_relaxed);
    id_ = next_++;
    submittedAt_ = now();
    stats_.busy = true;
    ++stats_.submitted;
    wake_.notify_one();
    return id_;
}
std::unique_ptr<LightCompletion> LightWorker::take() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ready_) return nullptr;
    stats_.busy = stats_.ready = false;
    return std::move(ready_);
}
void LightWorker::cancel() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!stats_.busy) return;
    cancelled_.store(true, std::memory_order_relaxed);
    if (ready_ && !ready_->cancelled) {
        ready_->cancelled = true;
        ready_->result.reset();
        ++stats_.cancelled;
    }
}
void LightWorker::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        cancelled_.store(true, std::memory_order_relaxed);
        wake_.notify_one();
    }
    if (thread_.joinable()) thread_.join();
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.reset();
    pendingCompletion_.reset();
    ready_.reset();
    stats_.busy = stats_.ready = stats_.running = false;
    stopping_ = false;
}
LightWorkerStats LightWorker::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}
void LightWorker::run() {
    for (;;) {
        std::shared_ptr<const Snapshot> source;
        std::unique_ptr<LightCompletion> completion;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [&] { return stopping_ || pending_ != nullptr; });
            if (stopping_) return;
            source = std::move(pending_);
            completion = std::move(pendingCompletion_);
            completion->id = id_;
            completion->queueMS = now() - submittedAt_;
            stats_.running = true;
        }
        try { completion->result = rebuildLight(std::move(source), cancelled_); }
        catch (const std::exception& e) { completion->error = e.what(); }
        catch (...) { completion->error = "unknown native lighting worker exception"; }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            completion->cancelled = cancelled_.load(std::memory_order_relaxed);
            if (completion->cancelled) {
                completion->result.reset();
                ++stats_.cancelled;
            } else if (!completion->error.empty()) ++stats_.failed;
            else if (completion->result) {
                ++stats_.completed;
                stats_.computeMS += completion->result->computeMS;
            }
            ready_ = std::move(completion);
            stats_.running = false;
            stats_.ready = true;
        }
    }
}
}
