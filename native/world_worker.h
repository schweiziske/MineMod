#pragma once
#include "world_core.h"
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>

namespace mcmesh::world {
struct LightCompletion {
    uint64_t id = 0;
    std::unique_ptr<LightResult> result;
    std::string error;
    bool cancelled = false;
    double queueMS = 0;
};
struct LightWorkerStats {
    uint64_t submitted = 0, completed = 0, failed = 0, cancelled = 0;
    bool busy = false, running = false, ready = false;
    double computeMS = 0, diffMS = 0;
};
// One bounded light job per world. Edits are coalesced by the owning session;
// workers never inspect live Store state or schedule Lua/engine work.
class LightWorker {
public:
    ~LightWorker();
    uint64_t submit(std::shared_ptr<const Snapshot> source);
    std::unique_ptr<LightCompletion> take();
    void cancel();
    void stop();
    LightWorkerStats stats() const;
private:
    void run();
    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::thread thread_;
    std::shared_ptr<const Snapshot> pending_;
    std::unique_ptr<LightCompletion> pendingCompletion_;
    std::unique_ptr<LightCompletion> ready_;
    std::atomic<bool> cancelled_{false};
    LightWorkerStats stats_;
    uint64_t next_ = 1, id_ = 0;
    double submittedAt_ = 0;
    bool stopping_ = false;
};
}
