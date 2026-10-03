#include "../world_session.h"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

using namespace mcmesh::world;
namespace {
void check(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
std::shared_ptr<Catalog> catalog() {
    auto value = std::make_shared<Catalog>();
    value->states.resize(2);
    value->states[1].emission = 15;
    value->states[1].l2Word = 15 << 8;
    return value;
}
Config config() {
    Config cfg;
    cfg.chunkSize = cfg.chunkHeight = cfg.sectionSize = 4;
    return cfg;
}
void wait(Session& session, bool expectError = false) {
    const auto limit = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (session.pending()) {
        const auto result = session.pump();
        if (expectError && !result.error.empty()) return;
        check(result.error.empty(), result.error.c_str());
        check(std::chrono::steady_clock::now() < limit, "native world worker timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    check(!expectError, "worker did not report expected fault");
}
void run() {
    Session session(config(), catalog());
    Mutation change;
    change.cells = {{0,1}};
    for (int i = 0; i < 12; ++i) {
        change.chunk = {i,0,0};
        session.apply(session.store().revision(), {change});
    }
    check(session.workerStats().submitted == 0, "mutation copied snapshots or launched work before pump");
    check(session.pump().submitted, "session did not submit coalesced light");
    check(session.workerStats().submitted == 1, "batch burst was not coalesced");
    for (int i = 0; i < 12; ++i) {
        change.chunk = {i,0,0};
        change.cells[0].state = 0;
        session.apply(session.store().revision(), {change});
    }
    wait(session);
    check(session.workerStats().submitted == 2, "in-flight mutations were not coalesced");
    check(session.store().light({1,0,0}, false) == 0, "stale emitter result survived latest edit");
    const auto source = session.store().snapshot();
    LightWorker worker;
    check(worker.submit(source) != 0 && worker.submit(source) == 0, "light worker ignored single-job backpressure");
    worker.cancel();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    for (;;) {
        auto done = worker.take();
        if (done) {
            check(done->cancelled && !done->result, "cancelled worker published data");
            break;
        }
        check(std::chrono::steady_clock::now() < deadline, "cancel timeout");
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    worker.stop();
    check(worker.submit(source) != 0, "stopped worker could not restart");
    worker.stop();
    check(!worker.stats().busy, "shutdown left live worker job");
    change.cells[0].state = 1;
    session.apply(session.store().revision(), {change});
    session.pump();
    session.reset(config(), catalog());
    change.chunk = {-2,0,0};
    session.apply(0, {change});
    wait(session);
    check(session.store().state({-8,0,0}) == 1 && session.store().state({44,0,0}) == 0, "reset retained old world");
    check(session.store().light({-7,0,0}, false) == 14, "post-reset light missing");
    auto limited = config();
    limited.maxLightBytes = 1024;
    session.reset(limited, catalog());
    session.apply(0, {change});
    wait(session, true);
    const auto failed = session.workerStats().submitted;
    for (int i = 0; i < 100; ++i) session.pump();
    check(session.workerStats().submitted == failed, "failed light job retried every frame");
}
}
int main() {
    try {
        run();
        std::cout << "World workers: coalescing, snapshots, backpressure, cancellation, reset and fault latch passed\n";
        return 0;
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
