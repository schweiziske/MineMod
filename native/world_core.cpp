#include "world_core.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <deque>
#include <stdexcept>
#include <unordered_set>

namespace mcmesh::world {
namespace {
constexpr int Offsets[6][3] = {{1,0,0},{-1,0,0},{0,1,0},{0,-1,0},{0,0,1},{0,0,-1}};
using Clock = std::chrono::steady_clock;
void require(bool ok, const char* message) { if (!ok) throw std::runtime_error(message); }
void checkCoord(Coord c, const Config& config) {
    // Leave room for the light domain and mesh halo without signed overflow.
    constexpr int margin = 256;
    for (const auto value : {std::pair<int,int>{c.x, config.chunkSize},
             {c.y, config.chunkSize}, {c.z, config.chunkHeight}}) {
        const int64_t base = int64_t(value.first) * value.second;
        require(base >= int64_t(std::numeric_limits<int>::min()) + margin
            && base <= int64_t(std::numeric_limits<int>::max()) - margin,
            "world chunk coordinate exceeds the block-coordinate range");
    }
}
struct Address { unsigned section, cell; };
Address address(const Config& cfg, unsigned li) {
    const unsigned cs = cfg.chunkSize, ss = cfg.sectionSize, xy = cs / ss;
    const unsigned x = li % cs, y = li / cs % cs, z = li / (cs * cs);
    return {x / ss + xy * (y / ss + xy * (z / ss)),
        x % ss + ss * (y % ss + ss * (z % ss))};
}
uint32_t stateIn(const Config& cfg, const Chunk& chunk, unsigned li) {
    const auto a = address(cfg, li);
    const auto& section = chunk.sections[a.section];
    return section ? section->states[a.cell] : 0;
}
const Profile& profileIn(const Config& cfg, const Catalog& catalog, const Chunk& chunk, unsigned li) {
    const auto a = address(cfg, li);
    const auto& section = chunk.sections[a.section];
    if (!section) return catalog.states[0];
    const auto context = section->contexts.find(a.cell);
    return context != section->contexts.end() ? context->second : catalog.states[section->states[a.cell]];
}
template<class T>
const T* find(const Grid<std::shared_ptr<const T>>& map, Coord coord) {
    const auto found = map.find(coord);
    return found == map.end() ? nullptr : found->second.get();
}
bool lightDepends(Coord target, Coord changed, const Config& config) {
    // Sky column changes affect arbitrary Z, but can only spread 14 cells sideways.
    const int radius = (16 + config.chunkSize - 1) / config.chunkSize;
    return std::abs(int64_t(target.x) - changed.x) <= radius
        && std::abs(int64_t(target.y) - changed.y) <= radius;
}
std::shared_ptr<const Chunk> editChunk(const Config& cfg, const Catalog& catalog,
    const Chunk* previous, const Mutation& mutation, uint64_t revision) {
    auto chunk = previous && mutation.kind == Mutation::Kind::Patch
        ? std::make_shared<Chunk>(*previous) : std::make_shared<Chunk>(cfg);
    chunk->terrainPresent = mutation.terrainPresent;
    chunk->revision = revision;
    std::unordered_map<unsigned, std::shared_ptr<Section>> dirty;
    std::unordered_set<unsigned> columns;
    auto writable = [&](Address a) -> Section& {
        auto found = dirty.find(a.section);
        if (found == dirty.end()) {
            const auto& old = chunk->sections[a.section];
            auto section = old ? std::make_shared<Section>(*old)
                : std::make_shared<Section>(cfg.sectionSize * cfg.sectionSize * cfg.sectionSize);
            found = dirty.emplace(a.section, std::move(section)).first;
            chunk->sections[a.section] = found->second;
        }
        return *found->second;
    };
    for (const auto& cell : mutation.cells) {
        const auto a = address(cfg, cell.index);
        auto& section = writable(a);
        const auto old = section.states[a.cell];
        if (old != cell.state) {
            const int delta = int(cell.state != 0) - int(old != 0);
            chunk->count = unsigned(int(chunk->count) + delta);
            section.count = unsigned(int(section.count) + delta);
            section.states[a.cell] = cell.state;
            if (old && --section.counts.at(old) == 0) section.counts.erase(old);
            if (cell.state) ++section.counts[cell.state];
            section.contexts.erase(a.cell);
            columns.insert(cell.index % unsigned(cfg.chunkSize * cfg.chunkSize));
        }
    }
    for (const auto& context : mutation.contexts) {
        auto& section = writable(address(cfg, context.index));
        const auto a = address(cfg, context.index);
        if (context.clear) section.contexts.erase(a.cell);
        else {
            require(section.states[a.cell] != 0, "lighting context cannot belong to air");
            section.contexts[a.cell] = context.value;
        }
        columns.insert(context.index % unsigned(cfg.chunkSize * cfg.chunkSize));
    }
    for (const auto& entry : dirty) {
        if (!entry.second->count && entry.second->contexts.empty()) chunk->sections[entry.first].reset();
    }
    const unsigned cs2 = cfg.chunkSize * cfg.chunkSize;
    for (unsigned column : columns) {
        chunk->columnTops[column] = -1;
        for (int z = cfg.chunkHeight - 1; z >= 0; --z) {
            if (profileIn(cfg, catalog, *chunk, column + unsigned(z) * cs2).opacity > 0) {
                chunk->columnTops[column] = int16_t(z);
                break;
            }
        }
    }
    require(chunk->terrainPresent || chunk->count == 0, "known-empty record contains terrain");
    return chunk;
}
void validateMutation(const Config& cfg, const Catalog& catalog, const Mutation& mutation) {
    checkCoord(mutation.chunk, cfg);
    require(mutation.cells.size() <= cfg.cellCount() && mutation.contexts.size() <= cfg.cellCount(),
        "world mutation exceeds its cell limit");
    std::unordered_set<unsigned> indices;
    for (const auto& cell : mutation.cells) {
        require(cell.index < cfg.cellCount() && cell.state < catalog.states.size(), "invalid world state edit");
        require(indices.insert(cell.index).second, "world mutation contains duplicate cells");
    }
    indices.clear();
    for (const auto& context : mutation.contexts) {
        require(context.index < cfg.cellCount(), "invalid world context index");
        require(indices.insert(context.index).second, "world mutation contains duplicate contexts");
        if (!context.clear) context.value.validate();
    }
}
}

PreparedBatch prepareReplacements(const Config& config, std::shared_ptr<const Catalog> catalog,
    uint64_t epoch, const std::vector<Mutation>& batch) {
    require(catalog != nullptr, "replacement batch requires a catalog");
    require(batch.size() <= config.maxChunks, "replacement batch exceeds its chunk limit");
    PreparedBatch result{epoch, std::move(catalog), {}};
    for (const auto& mutation : batch) {
        require(mutation.kind == Mutation::Kind::Replace, "prepared batch must contain replacements");
        require(result.chunks.find(mutation.chunk) == result.chunks.end(), "duplicate prepared chunk");
        validateMutation(config, *result.catalog, mutation);
        result.chunks.emplace(mutation.chunk, editChunk(config, *result.catalog, nullptr, mutation, 0));
    }
    return result;
}
size_t CoordHash::operator()(const Coord& c) const noexcept {
    uint64_t hash = uint64_t(uint32_t(c.x)) * 0x9e3779b185ebca87ull;
    hash ^= uint64_t(uint32_t(c.y)) * 0xc2b2ae3d27d4eb4full;
    hash ^= uint64_t(uint32_t(c.z)) * 0x165667b19e3779f9ull;
    return size_t(hash ^ (hash >> 32));
}
int floorDiv(int value, int divisor) {
    const int q = value / divisor, r = value % divisor;
    return q - int(r < 0);
}
void Config::validate() const {
    require(chunkSize >= 1 && chunkSize <= 64 && chunkHeight >= 1 && chunkHeight <= 64
        && sectionSize >= 1 && sectionSize <= 64
        && chunkSize % sectionSize == 0 && chunkHeight % sectionSize == 0,
        "invalid world grid dimensions");
    require(std::isfinite(blockSize) && blockSize > 0 && minChunkZ <= maxChunkZ,
        "invalid world scale or vertical bounds");
    require(maxChunks > 0 && maxChunks <= 1048576 && maxLightChunks > 0 && maxLightChunks <= 1048576,
        "invalid world resource limits");
    require(maxLightBytes >= 1024 && maxLightBytes <= size_t(4) * 1024 * 1024 * 1024,
        "invalid native lighting memory budget");
}
Coord Config::chunkAt(Coord cell) const {
    return {floorDiv(cell.x, chunkSize), floorDiv(cell.y, chunkSize), floorDiv(cell.z, chunkHeight)};
}
void Config::validateChunk(Coord chunk) const { checkCoord(chunk, *this); }
unsigned Config::localIndex(Coord cell) const {
    const auto chunk = chunkAt(cell);
    return unsigned((int64_t(cell.x) - int64_t(chunk.x) * chunkSize)
        + chunkSize * ((int64_t(cell.y) - int64_t(chunk.y) * chunkSize)
            + chunkSize * (int64_t(cell.z) - int64_t(chunk.z) * chunkHeight)));
}
Coord Config::cellAt(Coord chunk, unsigned li) const {
    return {chunk.x * chunkSize + int(li % chunkSize),
        chunk.y * chunkSize + int(li / chunkSize % chunkSize),
        chunk.z * chunkHeight + int(li / (chunkSize * chunkSize))};
}
void Profile::validate() const {
    require(emission <= 15 && opacity <= 15 && skyCost >= 1 && skyCost <= 16,
        "invalid propagation profile");
    require(skyCost == (opacity >= 15 ? 16 : std::max(1, int(opacity)))
        || (opacity > 2 && opacity < 15 && skyCost == 2), "invalid sky propagation cost");
    require((l2Word & ~uint32_t(0xfff00)) == 0 && std::isfinite(shade) && shade >= 0 && shade <= 1,
        "invalid L2 state properties");
}
void Catalog::validate() const {
    require(revision != 0 && !states.empty() && states.size() <= 1048576, "invalid world state catalog");
    require(contextual.empty() || contextual.size() == states.size(), "invalid context state map");
    for (auto flag : contextual) require(flag <= 1, "invalid context state flag");
    require(contextual.empty() || contextual[0] == 0, "air cannot require a lighting context");
    for (const auto& profile : states) profile.validate();
    const auto& air = states[0];
    require(air.emission == 0 && air.opacity == 0 && air.skyCost == 1, "state zero must be non-emitting air");
}
Chunk::Chunk(const Config& config)
    : sections(config.sectionCount()), columnTops(config.chunkSize * config.chunkSize, -1) {}
bool Snapshot::known(Coord chunk) const {
    return chunks.find(chunk) != chunks.end() || !config.streaming
        || chunk.z < config.minChunkZ || chunk.z > config.maxChunkZ;
}
uint32_t Snapshot::state(Coord cell) const {
    const auto* chunk = find(chunks, config.chunkAt(cell));
    return chunk ? stateIn(config, *chunk, config.localIndex(cell)) : 0;
}
const Profile& Snapshot::profile(Coord cell) const {
    const auto* chunk = find(chunks, config.chunkAt(cell));
    return chunk ? profileIn(config, *catalog, *chunk, config.localIndex(cell)) : catalog->states[0];
}

std::unique_ptr<LightResult> rebuildLight(std::shared_ptr<const Snapshot> source,
    const std::atomic<bool>& cancelled) {
    require(source && source->catalog, "light build needs a world snapshot");
    const auto started = Clock::now();
    const auto& cfg = source->config;
    auto result = std::make_unique<LightResult>();
    result->source = source;
    // Summaries are maintained during mutation. The worker scans columns, not all
    // states a second time, and never reads a mutable Store.
    Grid<int> tops;
    std::unordered_set<Coord, CoordHash> domain;
    const int xyHalo = (16 + cfg.chunkSize - 1) / cfg.chunkSize;
    const int zHalo = (16 + cfg.chunkHeight - 1) / cfg.chunkHeight;
    for (const auto& entry : source->chunks) {
        if (cancelled.load(std::memory_order_relaxed)) return nullptr;
        const auto cc = entry.first;
        const auto& chunk = *entry.second;
        for (unsigned column = 0; column < chunk.columnTops.size(); ++column) {
            const int top = chunk.columnTops[column];
            if (top < 0) continue;
            const Coord key{cc.x * cfg.chunkSize + int(column % cfg.chunkSize),
                cc.y * cfg.chunkSize + int(column / cfg.chunkSize), 0};
            const int z = cc.z * cfg.chunkHeight + top;
            const auto found = tops.find(key);
            if (found == tops.end()) tops.emplace(key, z);
            else found->second = std::max(found->second, z);
        }
        if (!chunk.terrainPresent) continue;
        for (int dz = -zHalo; dz <= zHalo; ++dz)
        for (int dy = -xyHalo; dy <= xyHalo; ++dy)
        for (int dx = -xyHalo; dx <= xyHalo; ++dx) {
            Coord key{cc.x + dx, cc.y + dy, cc.z + dz};
            if (source->known(key)) domain.insert(key);
            require(domain.size() <= cfg.maxLightChunks, "native light domain exceeds its chunk limit");
        }
    }
    auto exposed = [&](Coord cell) {
        if (!source->known(cfg.chunkAt(cell))) return false;
        const auto found = tops.find({cell.x, cell.y, 0});
        return found == tops.end() || cell.z > found->second;
    };
    struct WorkChunk {
        Coord coord;
        std::vector<uint8_t> values, blockCost, skyCost;
        std::array<size_t, 6> neighbors;
    };
    std::vector<WorkChunk> chunks;
    require(domain.size() <= cfg.maxLightBytes / cfg.cellCount(),
        "native persistent lighting exceeds its memory budget");
    Grid<size_t> byKey;
    for (const auto& coord : domain) {
        if (source->light.find(coord) != source->light.end()
            && source->invalidLight.find(coord) == source->invalidLight.end()) continue;
        require((source->light.size() + (chunks.size() + 1) * 3) <= cfg.maxLightBytes / cfg.cellCount(),
            "native lighting work exceeds its memory budget");
        result->targets.emplace(coord, true);
        byKey.emplace(coord, chunks.size());
        WorkChunk chunk;
        chunk.coord = coord;
        chunk.values.resize(cfg.cellCount());
        chunk.blockCost.resize(cfg.cellCount());
        chunk.skyCost.resize(cfg.cellCount());
        chunks.push_back(std::move(chunk));
    }
    for (const auto& entry : source->light) {
        if (domain.find(entry.first) == domain.end()) result->targets.emplace(entry.first, true);
    }
    // Includes existing immutable values and worker arrays. Queue capacity is
    // checked separately as propagation discovers work.
    const size_t fixedBytes = (source->light.size() + chunks.size() * 3) * cfg.cellCount();
    require(fixedBytes <= cfg.maxLightBytes, "native lighting work exceeds its memory budget");
    constexpr size_t Missing = std::numeric_limits<size_t>::max();
    struct Node { size_t chunk; unsigned cell; uint8_t level; };
    std::deque<Node> blockQueue, skyQueue;
    auto enqueue = [&](std::deque<Node>& queue, Node node) {
        require((blockQueue.size() + skyQueue.size() + 1) <= (cfg.maxLightBytes - fixedBytes) / sizeof(Node),
            "native lighting queue exceeds its memory budget");
        queue.push_back(node);
    };
    auto previous = [&](Coord pos, bool sky) -> unsigned {
        const auto key = cfg.chunkAt(pos);
        if (!source->known(key)) return 0;
        const auto* old = source->invalidLight.find(key) == source->invalidLight.end()
            && domain.find(key) != domain.end() ? find(source->light, key) : nullptr;
        if (old) {
            const auto value = old->values[cfg.localIndex(pos)];
            return sky ? value >> 4 : value & 15;
        }
        return sky && (!cfg.skyEnabled || exposed(pos)) ? 15 : 0;
    };
    for (size_t ci = 0; ci < chunks.size(); ++ci) {
        if (cancelled.load(std::memory_order_relaxed)) return nullptr;
        auto& chunk = chunks[ci];
        const auto cc = chunk.coord;
        for (int f = 0; f < 6; ++f) {
            const auto found = byKey.find({cc.x + Offsets[f][0], cc.y + Offsets[f][1], cc.z + Offsets[f][2]});
            chunk.neighbors[f] = found == byKey.end() ? Missing : found->second;
        }
        const Chunk* states = find(source->chunks, cc);
        for (unsigned li = 0; li < cfg.cellCount(); ++li) {
            ++result->scannedCells;
            const auto& p = states ? profileIn(cfg, *source->catalog, *states, li) : source->catalog->states[0];
            chunk.values[li] = p.emission;
            chunk.blockCost[li] = uint8_t(p.opacity >= 15 ? 16 : std::max(1, int(p.opacity)));
            chunk.skyCost[li] = p.skyCost;
            if (p.emission) { enqueue(blockQueue, {ci, li, p.emission}); ++result->sources; }
            const auto pos = cfg.cellAt(cc, li);
            if (!cfg.skyEnabled || exposed(pos)) {
                chunk.values[li] |= 0xf0;
            } else {
                // Seed from all exposed neighbors, including the cell just above a
                // water/leaf column top and known sparse air outside this domain.
                for (const auto& offset : Offsets) {
                    if (exposed({pos.x + offset[0], pos.y + offset[1], pos.z + offset[2]}) && p.skyCost < 15) {
                        const auto level = uint8_t(15 - p.skyCost);
                        chunk.values[li] |= uint8_t(level << 4);
                        enqueue(skyQueue, {ci, li, level});
                        ++result->sources;
                        break;
                    }
                }
            }
            // Unchanged chunks supply boundary light for incremental reflood.
            // Invalid chunks always belong to this build, so their old light
            // cannot seed a removed emitter or an opened/closed sky column.
            const unsigned x = li % cfg.chunkSize, y = li / cfg.chunkSize % cfg.chunkSize;
            const unsigned z = li / (cfg.chunkSize * cfg.chunkSize);
            if (x == 0 || y == 0 || z == 0 || x + 1 == unsigned(cfg.chunkSize)
                || y + 1 == unsigned(cfg.chunkSize) || z + 1 == unsigned(cfg.chunkHeight)) {
                unsigned block = chunk.values[li] & 15, sky = chunk.values[li] >> 4;
                for (const auto& offset : Offsets) {
                    const Coord neighbor{pos.x + offset[0], pos.y + offset[1], pos.z + offset[2]};
                    const auto key = cfg.chunkAt(neighbor);
                    if (key == cc || byKey.find(key) != byKey.end()) continue;
                    const int b = int(previous(neighbor, false)) - chunk.blockCost[li];
                    const int s = int(previous(neighbor, true)) - chunk.skyCost[li];
                    if (b > int(block)) block = unsigned(b);
                    if (s > int(sky)) sky = unsigned(s);
                }
                if (block > unsigned(chunk.values[li] & 15)) enqueue(blockQueue, {ci, li, uint8_t(block)});
                if (sky > unsigned(chunk.values[li] >> 4)) enqueue(skyQueue, {ci, li, uint8_t(sky)});
                chunk.values[li] = uint8_t(block | (sky << 4));
            }
        }
    }
    const unsigned cs = cfg.chunkSize, cs2 = cs * cs;
    auto flood = [&](std::deque<Node>& queue, bool sky) {
        while (!queue.empty()) {
            if ((result->visits & 1023) == 0 && cancelled.load(std::memory_order_relaxed)) return false;
            const Node node = queue.front();
            queue.pop_front();
            ++result->visits;
            const auto& chunk = chunks[node.chunk];
            const unsigned current = sky ? chunk.values[node.cell] >> 4 : chunk.values[node.cell] & 15;
            if (current != node.level || current <= 1) continue;
            const int x = node.cell % cs, y = node.cell / cs % cs, z = node.cell / cs2;
            for (int f = 0; f < 6; ++f) {
                int nx = x + Offsets[f][0], ny = y + Offsets[f][1], nz = z + Offsets[f][2];
                size_t target = node.chunk;
                if (nx < 0 || nx >= cfg.chunkSize || ny < 0 || ny >= cfg.chunkSize || nz < 0 || nz >= cfg.chunkHeight) {
                    target = chunk.neighbors[f];
                    if (target == Missing) continue;
                    if (nx < 0) nx += cfg.chunkSize;
                    else if (nx >= cfg.chunkSize) nx -= cfg.chunkSize;
                    if (ny < 0) ny += cfg.chunkSize;
                    else if (ny >= cfg.chunkSize) ny -= cfg.chunkSize;
                    if (nz < 0) nz += cfg.chunkHeight;
                    else if (nz >= cfg.chunkHeight) nz -= cfg.chunkHeight;
                }
                auto& destination = chunks[target];
                const unsigned li = unsigned(nx) + cs * (unsigned(ny) + cs * unsigned(nz));
                const int next = int(current) - (sky ? destination.skyCost[li] : destination.blockCost[li]);
                const unsigned old = sky ? destination.values[li] >> 4 : destination.values[li] & 15;
                if (next <= 0 || int(old) >= next) continue;
                auto& value = destination.values[li];
                value = sky ? uint8_t((value & 15) | (next << 4)) : uint8_t((value & 0xf0) | next);
                enqueue(queue, {target, li, uint8_t(next)});
            }
        }
        return true;
    };
    if (!flood(blockQueue, false) || !flood(skyQueue, true)) return nullptr;
    for (auto& chunk : chunks) {
        auto value = std::make_shared<LightChunk>();
        value->values = std::move(chunk.values);
        result->chunks.emplace(chunk.coord, std::move(value));
    }
    result->computeMS = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
    return result;
}

Store::Store(Config config, std::shared_ptr<const Catalog> catalog) : config_(config), catalog_(std::move(catalog)) {
    config_.validate();
    require(catalog_ != nullptr, "world requires a catalog");
    catalog_->validate();
    // The caller cannot mutate the sealed catalog through its original pointer.
    catalog_ = std::make_shared<const Catalog>(*catalog_);
}
void Store::reset(Config config, std::shared_ptr<const Catalog> catalog) {
    config.validate();
    require(catalog != nullptr, "world reset requires a catalog");
    catalog->validate();
    auto sealed = std::make_shared<const Catalog>(*catalog);
    config_ = config;
    catalog_ = std::move(sealed);
    chunks_.clear();
    columns_.clear();
    light_.clear();
    invalidLight_.clear();
    ++epoch_;
    revision_ = 0;
}
void Store::reconfigure(Config config) {
    config.validate();
    require(config.chunkSize == config_.chunkSize && config.chunkHeight == config_.chunkHeight
        && config.sectionSize == config_.sectionSize && config.blockSize == config_.blockSize,
        "world geometry configuration requires an ownership transfer");
    require(chunks_.size() <= config.maxChunks, "new world chunk limit is too small");
    config_ = config;
    light_.clear();
    invalidLight_.clear();
    ++epoch_;
}
std::shared_ptr<const Snapshot> Store::snapshot() const {
    auto result = std::make_shared<Snapshot>();
    result->config = config_;
    result->epoch = epoch_;
    result->revision = revision_;
    result->catalog = catalog_;
    result->chunks = chunks_;
    result->light = light_;
    result->invalidLight = invalidLight_;
    return result;
}
uint32_t Store::state(Coord cell) const {
    const auto* chunk = find(chunks_, config_.chunkAt(cell));
    return chunk ? stateIn(config_, *chunk, config_.localIndex(cell)) : 0;
}
bool Store::known(Coord chunk) const {
    return chunks_.find(chunk) != chunks_.end() || !config_.streaming
        || chunk.z < config_.minChunkZ || chunk.z > config_.maxChunkZ;
}
bool Store::apply(uint64_t expectedRevision, const std::vector<Mutation>& batch) {
    if (expectedRevision != revision_) return false;
    // A replacement transaction can unload a full world and insert another one.
    // publish() checks the final population; this bounds the staging work only.
    require(batch.size() <= config_.maxChunks * 2, "world batch exceeds its chunk limit");
    Grid<std::shared_ptr<const Chunk>> pending;
    for (const auto& mutation : batch) {
        validateMutation(config_, *catalog_, mutation);
        require(pending.find(mutation.chunk) == pending.end(), "world batch contains duplicate chunks");
        const auto* previous = find(chunks_, mutation.chunk);
        if (mutation.kind == Mutation::Kind::Unload) {
            require(mutation.cells.empty() && mutation.contexts.empty(), "unload mutation contains cells");
            pending.emplace(mutation.chunk, nullptr);
        } else {
            require(mutation.kind == Mutation::Kind::Replace || mutation.kind == Mutation::Kind::Patch,
                "unknown world mutation kind");
            pending.emplace(mutation.chunk, editChunk(config_, *catalog_, previous, mutation, revision_ + 1));
        }
    }
    return publish(std::move(pending));
}
bool Store::applyPrepared(uint64_t expectedRevision, const PreparedBatch& batch, const std::vector<Mutation>& contexts) {
    if (expectedRevision != revision_ || batch.epoch != epoch_ || batch.catalog != catalog_) return false;
    auto pending = batch.chunks;
    Grid<bool> seen;
    for (const auto& mutation : contexts) {
        require(mutation.kind == Mutation::Kind::Patch && mutation.cells.empty(), "invalid prepared context overlay");
        require(seen.emplace(mutation.chunk, true).second, "duplicate prepared context chunk");
        const auto found = pending.find(mutation.chunk);
        require(found != pending.end() && found->second, "context overlay has no prepared chunk");
        validateMutation(config_, *catalog_, mutation);
        found->second = editChunk(config_, *catalog_, found->second.get(), mutation, revision_ + 1);
    }
    return publish(std::move(pending));
}
bool Store::publish(Grid<std::shared_ptr<const Chunk>> pending) {
    auto finalSize = chunks_.size(), additions = size_t(0);
    for (const auto& entry : pending) {
        const bool exists = chunks_.find(entry.first) != chunks_.end();
        if (entry.second && !exists) { ++finalSize; ++additions; }
        else if (!entry.second && exists) --finalSize;
    }
    require(finalSize <= config_.maxChunks, "native world exceeds its chunk limit");
    if (pending.empty()) return true;
    Grid<std::shared_ptr<Column>> columns;
    for (const auto& entry : pending) {
        const Coord key{entry.first.x, entry.first.y, 0};
        auto found = columns.find(key);
        if (found == columns.end()) {
            const auto previous = columns_.find(key);
            auto column = previous == columns_.end() ? std::make_shared<Column>()
                : std::make_shared<Column>(*previous->second);
            found = columns.emplace(key, std::move(column)).first;
        }
        if (entry.second) (*found->second)[entry.first.z] = entry.second;
        else found->second->erase(entry.first.z);
    }
    Grid<std::shared_ptr<const Column>> sealedColumns;
    for (auto& entry : columns) sealedColumns.emplace(entry.first, std::move(entry.second));
    // Prepare invalidation too, so allocation failure cannot publish half a batch.
    auto invalid = invalidLight_;
    for (const auto& entry : pending) {
        invalid[entry.first] = true;
        for (const auto& light : light_) {
            if (lightDepends(light.first, entry.first, config_)) invalid[light.first] = true;
        }
    }
    // All allocations precede publication. Transfer preallocated nodes instead
    // of copying the entire world root on every single-cell edit.
    // Pending iteration can insert before erasing; reserve the transient peak.
    chunks_.reserve(chunks_.size() + additions);
    columns_.reserve(columns_.size() + sealedColumns.size());
    while (!sealedColumns.empty()) {
        auto node = sealedColumns.extract(sealedColumns.begin());
        const auto old = columns_.find(node.key());
        if (node.mapped()->empty()) {
            if (old != columns_.end()) columns_.erase(old);
        } else if (old != columns_.end()) old->second = std::move(node.mapped());
        else columns_.insert(std::move(node));
    }
    while (!pending.empty()) {
        auto node = pending.extract(pending.begin());
        const auto old = chunks_.find(node.key());
        if (!node.mapped()) {
            if (old != chunks_.end()) chunks_.erase(old);
        } else if (old != chunks_.end()) {
            old->second = std::move(node.mapped());
        } else chunks_.insert(std::move(node));
    }
    invalidLight_.swap(invalid);
    ++revision_;
    return true;
}
CommitResult Store::commit(const LightResult& result) {
    CommitResult out;
    require(result.source != nullptr, "light result has no source");
    if (result.source->epoch != epoch_ || result.source->catalog != catalog_) { out.stale = true; return out; }
    std::vector<Coord> conflicts;
    for (const auto& entry : result.source->chunks) {
        if (find(chunks_, entry.first) != entry.second.get()) conflicts.push_back(entry.first);
    }
    for (const auto& entry : chunks_) {
        if (result.source->chunks.find(entry.first) == result.source->chunks.end()) conflicts.push_back(entry.first);
    }
    auto conflict = [&](Coord coord) {
        for (Coord changed : conflicts) if (lightDepends(coord, changed, config_)) return true;
        return false;
    };
    auto next = light_;
    auto invalid = invalidLight_;
    for (const auto& target : result.targets) {
        const auto coord = target.first;
        if (conflict(coord)) { ++out.deferred; continue; }
        const auto found = result.chunks.find(coord);
        const auto* old = find(light_, coord);
        const auto* value = found == result.chunks.end() ? nullptr : found->second.get();
        LightDelta delta;
        delta.chunk = coord;
        delta.changedBits.resize((config_.cellCount() + 7) / 8);
        bool changed = false;
        for (unsigned li = 0; li < config_.cellCount(); ++li) {
            if (!old || !value || old->values[li] != value->values[li]) {
                delta.changedBits[li / 8] |= uint8_t(1u << (li % 8));
                changed = true;
            }
        }
        if (changed) {
            out.changed.push_back(std::move(delta));
            if (value) next[coord] = found->second;
            else next.erase(coord);
        }
        invalid.erase(coord);
        ++out.committed;
    }
    // Unloaded/known-empty records can sit outside both light domains. Their
    // invalidation is consumed too, unless this result predates a conflicting edit.
    for (const auto& entry : result.source->invalidLight) {
        if (!conflict(entry.first)) invalid.erase(entry.first);
    }
    light_.swap(next);
    invalidLight_.swap(invalid);
    return out;
}
bool Store::lightReady(Coord coord) const {
    if (invalidLight_.find(coord) != invalidLight_.end()) return false;
    const auto chunk = chunks_.find(coord);
    return light_.find(coord) != light_.end() || chunk == chunks_.end() || !chunk->second->terrainPresent;
}
std::shared_ptr<const Chunk> Store::chunk(Coord coord) const {
    const auto found = chunks_.find(coord);
    return found == chunks_.end() ? nullptr : found->second;
}
Grid<std::vector<unsigned>> affectedLightSections(const Config& cfg, const std::vector<LightDelta>& changed) {
    Grid<std::vector<uint8_t>> owners;
    const int ss = cfg.sectionSize, xy = cfg.chunkSize / ss, height = cfg.chunkHeight / ss;
    for (const auto& delta : changed) {
        require(delta.changedBits.size() == (cfg.cellCount() + 7) / 8, "invalid light delta");
        for (unsigned li = 0; li < cfg.cellCount(); ++li) {
            if (!(delta.changedBits[li / 8] & (1u << (li % 8)))) continue;
            const auto cell = cfg.cellAt(delta.chunk, li);
            for (int z = floorDiv(cell.z - 2, ss); z <= floorDiv(cell.z + 2, ss); ++z)
                for (int y = floorDiv(cell.y - 2, ss); y <= floorDiv(cell.y + 2, ss); ++y)
                    for (int x = floorDiv(cell.x - 2, ss); x <= floorDiv(cell.x + 2, ss); ++x) {
                        const Coord chunk{floorDiv(x, xy), floorDiv(y, xy), floorDiv(z, height)};
                        auto& bits = owners[chunk];
                        if (bits.empty()) bits.resize(cfg.sectionCount());
                        const unsigned section = unsigned(x - chunk.x * xy)
                            + unsigned(xy * (y - chunk.y * xy + xy * (z - chunk.z * height)));
                        bits[section] = 1;
                    }
        }
    }
    Grid<std::vector<unsigned>> result;
    for (const auto& entry : owners) {
        auto& indices = result[entry.first];
        for (unsigned i = 0; i < entry.second.size(); ++i) if (entry.second[i]) indices.push_back(i);
    }
    return result;
}
bool Store::meshReady(Coord chunk, unsigned section) const {
    config_.validateChunk(chunk);
    require(section < config_.sectionCount(), "invalid native render section");
    if (chunks_.find(chunk) == chunks_.end() || !lightReady(chunk)) return false;
    const int ss = config_.sectionSize, xy = config_.chunkSize / ss;
    const Coord origin{chunk.x * config_.chunkSize + int(section % xy) * ss - 2,
        chunk.y * config_.chunkSize + int(section / xy % xy) * ss - 2,
        chunk.z * config_.chunkHeight + int(section / (xy * xy)) * ss - 2};
    const auto lo = config_.chunkAt(origin);
    const auto hi = config_.chunkAt({origin.x + ss + 3, origin.y + ss + 3, origin.z + ss + 3});
    for (int z = lo.z; z <= hi.z; ++z)
    for (int y = lo.y; y <= hi.y; ++y)
    for (int x = lo.x; x <= hi.x; ++x)
        if (known({x,y,z}) && !lightReady({x,y,z})) return false;
    return true;
}
MeshSnapshot Store::meshSnapshot(Coord chunk, unsigned section) const {
    require(section < config_.sectionCount(), "invalid native render section");
    require(chunks_.find(chunk) != chunks_.end(), "native mesh source chunk is absent");
    require(meshReady(chunk, section), "native mesh light halo is pending");
    const int ss = config_.sectionSize, xy = config_.chunkSize / ss;
    MeshSnapshot result;
    result.origin = {chunk.x * config_.chunkSize + int(section % xy) * ss - 2,
        chunk.y * config_.chunkSize + int(section / xy % xy) * ss - 2,
        chunk.z * config_.chunkHeight + int(section / (xy * xy)) * ss - 2};
    result.dimensions = {ss + 4, ss + 4, ss + 4};
    auto source = std::make_shared<Snapshot>();
    source->config = config_;
    source->catalog = catalog_;
    source->epoch = epoch_;
    source->revision = revision_;
    const auto lo = config_.chunkAt(result.origin);
    const auto hi = config_.chunkAt({result.origin.x + ss + 3, result.origin.y + ss + 3, result.origin.z + ss + 3});
    for (int z = lo.z; z <= hi.z; ++z)
    for (int y = lo.y; y <= hi.y; ++y)
    for (int x = lo.x; x <= hi.x; ++x) {
        Coord key{x,y,z};
        const auto state = chunks_.find(key);
        if (state != chunks_.end()) source->chunks.emplace(key, state->second);
        if (!known(key)) continue;
        const auto light = light_.find(key);
        if (light != light_.end()) result.light.emplace(key, light->second);
        else {
            const Coord columnKey{x,y,0};
            const auto column = columns_.find(columnKey);
            if (column != columns_.end()) result.columns.emplace(columnKey, column->second);
        }
    }
    result.world = std::move(source);
    return result;
}
bool Store::current(const MeshSnapshot& candidate) const {
    if (!candidate.world || candidate.world->epoch != epoch_ || candidate.world->catalog != catalog_) return false;
    const auto lo = config_.chunkAt(candidate.origin);
    const auto hi = config_.chunkAt({candidate.origin.x + candidate.dimensions.x - 1,
        candidate.origin.y + candidate.dimensions.y - 1, candidate.origin.z + candidate.dimensions.z - 1});
    for (int z = lo.z; z <= hi.z; ++z)
    for (int y = lo.y; y <= hi.y; ++y)
    for (int x = lo.x; x <= hi.x; ++x) {
        Coord key{x,y,z};
        if (find(candidate.world->chunks, key) != find(chunks_, key)
            || (known(key) && (find(candidate.light, key) != find(light_, key)
                || invalidLight_.find(key) != invalidLight_.end()))) return false;
        if (known(key) && candidate.light.find(key) == candidate.light.end()) {
            const Coord column{x,y,0};
            if (find(candidate.columns, column) != find(columns_, column)) return false;
        }
    }
    return true;
}
unsigned Store::light(Coord cell, bool sky) const {
    const auto coord = config_.chunkAt(cell);
    if (!known(coord)) return 0;
    if (sky && !config_.skyEnabled) return 15;
    const auto* chunk = find(light_, coord);
    if (chunk) {
        const unsigned value = chunk->values[config_.localIndex(cell)];
        return sky ? value >> 4 : value & 15;
    }
    // Outside the finite flood domain only implicit exposed sky can exist.
    if (!sky) return 0;
    const unsigned column = config_.localIndex(cell) % unsigned(config_.chunkSize * config_.chunkSize);
    const auto found = columns_.find({coord.x, coord.y, 0});
    if (found == columns_.end()) return 15;
    for (const auto& entry : *found->second) {
        const auto top = entry.second->columnTops[column];
        if (top >= 0 && cell.z <= entry.first * config_.chunkHeight + top) return 0;
    }
    return 15;
}
l2::Cell MeshSnapshot::read(Coord cell) const {
    require(world && cell.x >= origin.x && cell.y >= origin.y && cell.z >= origin.z
        && int64_t(cell.x) < int64_t(origin.x) + dimensions.x
        && int64_t(cell.y) < int64_t(origin.y) + dimensions.y
        && int64_t(cell.z) < int64_t(origin.z) + dimensions.z, "native sample is outside its mesh halo");
    const auto& cfg = world->config;
    const Coord key = cfg.chunkAt(cell);
    if (!world->known(key)) return {0xef000, 0.2f, 1};
    const auto found = light.find(key);
    unsigned value = 0xf0;
    if (found != light.end()) value = found->second->values[cfg.localIndex(cell)];
    else if (cfg.skyEnabled) {
        const auto column = columns.find({key.x,key.y,0});
        const auto li = cfg.localIndex(cell) % unsigned(cfg.chunkSize * cfg.chunkSize);
        if (column != columns.end()) for (const auto& entry : *column->second) {
            const auto top = entry.second->columnTops[li];
            if (top >= 0 && cell.z <= entry.first * cfg.chunkHeight + top) { value = 0; break; }
        }
    }
    const auto& p = world->profile(cell);
    return {p.l2Word | 1048576u | value, p.shade, p.renderClass};
}
size_t MeshSnapshot::bytes() const {
    size_t total = sizeof(*this) + sizeof(Snapshot);
    total += world->catalog->states.capacity() * sizeof(Profile) + world->catalog->contextual.capacity();
    const auto chunkBytes = [](const Chunk& chunk) {
        size_t bytes = sizeof(Chunk) + chunk.sections.capacity() * sizeof(std::shared_ptr<const Section>)
            + chunk.columnTops.capacity() * sizeof(int16_t);
        for (const auto& section : chunk.sections) if (section)
            bytes += sizeof(Section) + section->states.capacity() * sizeof(uint32_t) + section->counts.size() * 64
                + section->contexts.size() * (sizeof(Profile) + 64);
        return bytes;
    };
    for (const auto& entry : world->chunks) total += chunkBytes(*entry.second) + 64;
    for (const auto& entry : light) total += sizeof(LightChunk) + entry.second->values.capacity() + 64;
    for (const auto& column : columns) for (const auto& entry : *column.second)
        total += chunkBytes(*entry.second) + 64;
    return total;
}
l2::Cell MeshSnapshot::readCell(void* data, int x, int y, int z) {
    return static_cast<MeshSnapshot*>(data)->read({x,y,z});
}
}
