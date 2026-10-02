#pragma once
#include "l2_core.h"
#include <atomic>
#include <limits>
#include <memory>
#include <map>
#include <unordered_map>

// Persistent voxel ownership. Source resources and Lua values never enter this API.
namespace mcmesh::world {
struct Coord {
    int x = 0, y = 0, z = 0;
    bool operator==(const Coord& other) const {
        return x == other.x && y == other.y && z == other.z;
    }
};
struct CoordHash { size_t operator()(const Coord& value) const noexcept; };
template<class T> using Grid = std::unordered_map<Coord, T, CoordHash>;
int floorDiv(int value, int divisor);

struct Config {
    int chunkSize = 16, chunkHeight = 32, sectionSize = 8;
    double blockSize = 1;
    bool streaming = false, skyEnabled = true;
    int minChunkZ = (std::numeric_limits<int>::min)(), maxChunkZ = (std::numeric_limits<int>::max)();
    size_t maxChunks = 65536, maxLightChunks = 131072;
    size_t maxLightBytes = 256 * 1024 * 1024;
    void validate() const;
    void validateChunk(Coord chunk) const;
    unsigned cellCount() const { return unsigned(chunkSize * chunkSize * chunkHeight); }
    unsigned sectionCount() const {
        return unsigned((chunkSize / sectionSize) * (chunkSize / sectionSize) * (chunkHeight / sectionSize));
    }
    Coord chunkAt(Coord cell) const;
    unsigned localIndex(Coord cell) const;
    Coord cellAt(Coord chunk, unsigned index) const;
};

struct Profile {
    uint8_t emission = 0, opacity = 0, skyCost = 1;
    // L2 state-only bits: emission, dampening and the four boolean properties.
    // Raw light levels and loaded are supplied by the world, not the catalog.
    uint32_t l2Word = 0, renderClass = 0;
    float shade = 1;
    void validate() const;
};
struct Catalog {
    uint64_t revision = 1;
    std::vector<Profile> states;
    // Optional state-indexed flags for sparse Lua-resolved live contexts.
    std::vector<uint8_t> contextual;
    void validate() const;
};

struct Section {
    std::vector<uint32_t> states;
    std::unordered_map<uint32_t, unsigned> counts;
    std::unordered_map<unsigned, Profile> contexts;
    unsigned count = 0;
    explicit Section(unsigned cells) : states(cells) {}
};
struct Chunk {
    std::vector<std::shared_ptr<const Section>> sections;
    std::vector<int16_t> columnTops;
    unsigned count = 0;
    bool terrainPresent = false;
    uint64_t revision = 0;
    explicit Chunk(const Config& config);
};
struct LightChunk { std::vector<uint8_t> values; };
using Column = std::map<int, std::shared_ptr<const Chunk>>;
struct Snapshot {
    Config config;
    uint64_t epoch = 0, revision = 0;
    std::shared_ptr<const Catalog> catalog;
    Grid<std::shared_ptr<const Chunk>> chunks;
    Grid<std::shared_ptr<const LightChunk>> light;
    Grid<bool> invalidLight;
    bool known(Coord chunk) const;
    uint32_t state(Coord cell) const;
    const Profile& profile(Coord cell) const;
};

struct CellEdit { unsigned index = 0; uint32_t state = 0; };
struct ContextEdit { unsigned index = 0; bool clear = false; Profile value; };
struct Mutation {
    enum class Kind { Replace, Patch, Unload };
    Kind kind = Kind::Patch;
    Coord chunk;
    // A known-empty streaming record is not terrain and does not expand the light domain.
    bool terrainPresent = true;
    std::vector<CellEdit> cells;
    std::vector<ContextEdit> contexts;
};
// Worker-prepared replacements contain no mutable references into a live Store.
struct PreparedBatch {
    uint64_t epoch = 0;
    std::shared_ptr<const Catalog> catalog;
    Grid<std::shared_ptr<const Chunk>> chunks;
};
PreparedBatch prepareReplacements(const Config& config, std::shared_ptr<const Catalog> catalog,
    uint64_t epoch, const std::vector<Mutation>& batch);

struct LightResult {
    std::shared_ptr<const Snapshot> source;
    Grid<std::shared_ptr<const LightChunk>> chunks;
    Grid<bool> targets;
    uint64_t sources = 0, visits = 0;
    uint64_t scannedCells = 0;
    double computeMS = 0;
};
struct LightDelta {
    Coord chunk;
    std::vector<uint8_t> changedBits;
};
struct CommitResult {
    unsigned committed = 0, deferred = 0;
    bool stale = false;
    std::vector<LightDelta> changed;
};
// Owners whose two-cell L2 sampling halo contains a changed light cell.
Grid<std::vector<unsigned>> affectedLightSections(const Config& config, const std::vector<LightDelta>& changed);

// Called only by a CPU worker. Matches the current Lua sparse-air domain and
// opacity>0 column exposure, not the old L1 opacity>=15 sky approximation.
std::unique_ptr<LightResult> rebuildLight(std::shared_ptr<const Snapshot> source,
    const std::atomic<bool>& cancelled);

struct MeshSnapshot : l2::CellSource {
    std::shared_ptr<const Snapshot> world;
    Grid<std::shared_ptr<const LightChunk>> light;
    Grid<std::shared_ptr<const Column>> columns;
    Coord origin, dimensions;
    l2::Cell read(Coord cell) const;
    l2::Cell read(int x, int y, int z) const override { return read({x,y,z}); }
    size_t bytes() const override;
    static l2::Cell readCell(void* data, int x, int y, int z);
};

class Store {
public:
    Store(Config config, std::shared_ptr<const Catalog> catalog);
    // All Store operations run on the owning thread. Workers receive snapshots.
    uint64_t revision() const { return revision_; }
    uint64_t epoch() const { return epoch_; }
    uint64_t catalogRevision() const { return catalog_->revision; }
    size_t chunkCount() const { return chunks_.size(); }
    size_t lightChunkCount() const { return light_.size(); }
    const Config& config() const { return config_; }
    std::shared_ptr<const Catalog> catalog() const { return catalog_; }
    std::shared_ptr<const Snapshot> snapshot() const;
    uint32_t state(Coord cell) const;
    bool known(Coord chunk) const;
    std::shared_ptr<const Chunk> chunk(Coord coord) const;
    // Validate the complete batch before publishing any chunk.
    bool apply(uint64_t expectedRevision, const std::vector<Mutation>& batch);
    bool applyPrepared(uint64_t expectedRevision, const PreparedBatch& batch,
        const std::vector<Mutation>& contexts = {});
    void reset(Config config, std::shared_ptr<const Catalog> catalog);
    // Lighting/stream policy changes retain immutable terrain but invalidate jobs.
    void reconfigure(Config config);
    CommitResult commit(const LightResult& result);
    bool lightReady(Coord chunk) const;
    bool meshReady(Coord chunk, unsigned section) const;
    MeshSnapshot meshSnapshot(Coord chunk, unsigned section) const;
    bool current(const MeshSnapshot& snapshot) const;
    unsigned light(Coord cell, bool sky) const;
private:
    bool publish(Grid<std::shared_ptr<const Chunk>> pending);
    Config config_;
    std::shared_ptr<const Catalog> catalog_;
    Grid<std::shared_ptr<const Chunk>> chunks_;
    Grid<std::shared_ptr<const Column>> columns_;
    Grid<std::shared_ptr<const LightChunk>> light_;
    Grid<bool> invalidLight_;
    uint64_t epoch_ = 1, revision_ = 0;
};
}
