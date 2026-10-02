#pragma once
#include "world_core.h"
#include <string>

namespace mcmesh::world {
struct DecodeMetadata {
    uint8_t compression = 0;
    uint32_t rawBytes = 0, generation = 0, revision = 0, chunks = 0, cells = 0;
};
struct DecodeInput {
    Config config;
    std::shared_ptr<const Catalog> catalog;
    uint64_t epoch = 0;
    DecodeMetadata metadata;
    std::vector<uint8_t> payload;
    void validate() const;
};
struct DecodedChunk {
    Coord coord;
    unsigned count = 0;
    std::string blockEntitiesJSON;
    std::vector<CellEdit> contextCells;
};
struct DecodedResult {
    DecodeMetadata metadata;
    PreparedBatch prepared;
    std::vector<DecodedChunk> chunks;
    double decompressMS = 0, parseMS = 0;
};
// MCB9 transport parsing, decompression and section construction are CPU-only.
std::shared_ptr<const DecodedResult> decodeBinary(const DecodeInput& input, const std::atomic<bool>& cancelled);

enum class DecodeState { Queued, Running, Ready, Failed, Cancelled };
struct DecodeStatus {
    DecodeState state = DecodeState::Queued;
    std::string error;
    std::shared_ptr<const DecodedResult> result;
};
class DecodeWorker {
public:
    DecodeWorker();
    ~DecodeWorker();
    DecodeWorker(const DecodeWorker&) = delete;
    DecodeWorker& operator=(const DecodeWorker&) = delete;
    uint64_t submit(DecodeInput input);
    DecodeStatus poll(uint64_t id) const;
    void release(uint64_t id);
    void cancelAll();
    void stop();
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
}
