#include "l2_core.h"
#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <stdexcept>

namespace mcmesh::l2 {
DirectionOrder directionOrder(const std::vector<Quad>& quads) {
    DirectionOrder out;
    std::vector<uint8_t> groups(quads.size(), 6);
    for (size_t i = 0; i < quads.size(); ++i) {
        const auto& v = quads[i].vertices;
        // Only exact axis-planar, consistently wound triangles are assigned.
        // Smooth normals, slopes and degenerate geometry stay unconditional.
        for (unsigned a = 0; a < 3; ++a) {
            if (v[0].position[a] != v[1].position[a] || v[0].position[a] != v[2].position[a] ||
                v[0].position[a] != v[3].position[a]) continue;
            const unsigned b = (a+1)%3, c = (a+2)%3;
            auto cross = [&](unsigned j, unsigned k) {
                return double(v[j].position[b]-v[0].position[b]) * (v[k].position[c]-v[0].position[c]) -
                    double(v[j].position[c]-v[0].position[c]) * (v[k].position[b]-v[0].position[b]);
            };
            const double one = cross(1,2), two = cross(2,3);
            if (one * two <= 0) continue;
            const float normal = one > 0 ? 1.0f : -1.0f;
            bool agrees = true;
            for (const auto& vertex : v)
                agrees = agrees && vertex.normal[a] == normal && vertex.normal[b] == 0 && vertex.normal[c] == 0;
            if (agrees) groups[i] = uint8_t((a == 2 ? 0 : a == 0 ? 2 : 4) + (one < 0 ? 1 : 0));
            break;
        }
        ++out.ranges[groups[i]].count;
    }
    unsigned first = 0;
    std::array<unsigned, 7> next{};
    for (unsigned g = 0; g < 7; ++g) {
        auto& range = out.ranges[g];
        next[g] = first; range.first = first * 6;
        first += range.count; range.count *= 6;
    }
    out.quads.resize(quads.size());
    for (unsigned i = 0; i < quads.size(); ++i) out.quads[next[groups[i]]++] = i;
    return out;
}
namespace {
constexpr int Normals[6][3] = {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0},{0,1,0},{0,-1,0}};
constexpr int Adjacent[6][4][3] = {
    {{1,0,0},{-1,0,0},{0,-1,0},{0,1,0}},
    {{-1,0,0},{1,0,0},{0,-1,0},{0,1,0}},
    {{0,0,-1},{0,0,1},{0,-1,0},{0,1,0}},
    {{0,0,1},{0,0,-1},{0,-1,0},{0,1,0}},
    {{-1,0,0},{1,0,0},{0,0,-1},{0,0,1}},
    {{0,0,1},{0,0,-1},{1,0,0},{-1,0,0}}
};
constexpr unsigned PairA[4] = {3,2,2,3}, PairB[4] = {0,0,1,1};

// Build with strict floating-point semantics. Java rounds each intermediate.
float sum4(float a, float b, float c, float d) { return ((a + b) + c) + d; }
float weighted(const float* values, const float* weights) {
    return sum4(values[0] * weights[0], values[1] * weights[1],
        values[2] * weights[2], values[3] * weights[3]);
}
int javaInt(float value) {
    if (value >= 2147483647.0) return INT32_MAX;
    if (value <= -2147483648.0) return INT32_MIN;
    return static_cast<int>(value);
}
uint32_t pack(unsigned block, unsigned sky) { return (block << 4) | (sky << 20); }
uint32_t light(const Cell& cell, const Cell& state) {
    return state.emissive() ? 0xf000f0 : pack(std::max(cell.block(), state.emission()), cell.sky());
}
uint32_t light(const Cell& cell) { return light(cell, cell); }
uint32_t emit(uint32_t value, unsigned emission) {
    return emission ? pack(std::max((value >> 4) & 15, emission),
        std::max((value >> 20) & 15, emission)) : value;
}
uint32_t blend(uint32_t a, uint32_t b, uint32_t c, uint32_t center) {
    if (((center >> 20) & 15) > 2 || ((center >> 4) & 15) > 2) {
        const auto fix = [center](uint32_t v) {
            if (!v) return center;
            return ((v >> 20) & 15) == 0 ? v | (center & 0xff0000) : v;
        };
        a = fix(a); b = fix(b); c = fix(c);
    }
    return ((a + b + c + center) >> 2) & 0xff00ff;
}
uint32_t pixel(uint32_t coords, unsigned shade, unsigned tint) {
    return (coords & 255) | (((coords >> 16) & 255) << 8) | (shade << 16) | (tint << 24);
}
}

void require(bool valid, const char* message) {
    if (!valid) throw std::runtime_error(message);
}
int integer(double value, int minimum, int maximum, const char* message) {
    require(std::isfinite(value) && value >= minimum && value <= maximum && value == std::floor(value), message);
    return static_cast<int>(value);
}

Template compile(const double* p) {
    for (unsigned i = 0; i < TemplateSize; ++i)
        require(std::isfinite(p[i]) && std::abs(p[i]) <= std::numeric_limits<float>::max(),
            "L2 template contains non-finite or unrepresentable data");
    Template t;
    t.mode = integer(p[0], 0, 2, "invalid L2 template mode");
    t.face = integer(p[1], 1, 6, "invalid L2 face") - 1;
    t.flags = integer(p[2], 0, 15, "invalid L2 flags");
    require(p[3] >= 0 && p[3] <= 1, "invalid direction shade");
    t.directionShade = static_cast<float>(p[3]);
    t.flatShade = integer(p[4], 0, 255, "invalid flat shade");
    t.emission = integer(p[5], 0, 15, "invalid quad emission");
    t.lightFace = integer(p[6], 0, 6, "invalid light face") - 1;
    unsigned mask = 0;
    for (unsigned i = 0; i < 4; ++i) {
        for (unsigned a = 0; a < 3; ++a) {
            t.positions[i][a] = p[7 + i * 3 + a];
            t.extent[a] = std::max(t.extent[a], std::abs(t.positions[i][a]));
        }
        for (unsigned a = 0; a < 2; ++a) t.uv[i][a] = static_cast<float>(p[19 + i * 2 + a]);
        if (t.flags & 4) {
            for (unsigned j = 0; j < 4; ++j) {
                // BakeQuad accepts model coordinates up to 32768 in magnitude.
                require(std::abs(p[30 + i * 4 + j]) <= 1073807361.0, "invalid partial weight");
                t.weights[i][j] = static_cast<float>(p[30 + i * 4 + j]);
            }
        } else {
            const unsigned index = integer(p[30 + i * 4], 0, 3, "invalid corner index");
            require(!(mask & (1u << index)), "corner indices must be a permutation");
            mask |= 1u << index;
            t.indices[i] = index;
        }
    }
    for (unsigned a = 0; a < 3; ++a) t.normal[a] = static_cast<float>(p[27 + a]);
    return t;
}

size_t checkedAdd(size_t a, size_t b) {
    require(b <= std::numeric_limits<size_t>::max() - a, "L2 allocation size overflow");
    return a + b;
}
size_t checkedMultiply(size_t a, size_t b) {
    require(!b || a <= std::numeric_limits<size_t>::max() / b, "L2 allocation size overflow");
    return a * b;
}
void MemoryUsage::share(std::shared_ptr<const void> owner, size_t bytes) {
    shared.push_back({std::move(owner), checkedAdd(bytes, 64)});
}
void MemoryUsage::normalize() {
    const std::less<const void*> less;
    std::sort(shared.begin(), shared.end(), [&](const auto& a, const auto& b) {
        return less(a.owner.get(), b.owner.get());
    });
    size_t count = 0;
    for (size_t i = 0; i < shared.size(); ++i) {
        if (count && shared[count - 1].owner.get() == shared[i].owner.get()) {
            require(shared[count - 1].bytes == shared[i].bytes, "inconsistent shared allocation size");
        } else {
            if (count != i) shared[count] = std::move(shared[i]);
            ++count;
        }
    }
    shared.resize(count);
}
size_t MemoryUsage::total() const {
    size_t result = owned;
    for (const auto& allocation : shared) result = checkedAdd(result, allocation.bytes);
    return result;
}
Snapshot::Snapshot(const int origin[3], const int dimensions[3]) {
    for (unsigned a = 0; a < 3; ++a) {
        require(dimensions[a] >= 5 && dimensions[a] <= 4096, "invalid L2 snapshot dimensions");
        require(int64_t(origin[a]) + dimensions[a] <= INT32_MAX, "L2 snapshot coordinate overflow");
        origin_[a] = origin[a]; dimensions_[a] = dimensions[a];
        require(cellCount_ <= (4 * 1024 * 1024) / size_t(dimensions[a]), "L2 snapshot exceeds cell budget");
        cellCount_ *= dimensions[a];
    }
}
Snapshot::Snapshot(const int origin[3], const int dimensions[3], ReadCell reader, void* context)
    : Snapshot(origin, dimensions) {
    require(reader != nullptr, "missing L2 snapshot reader");
    reader_ = reader; context_ = context;
    prepare(); // Lua callbacks still prefetch on their owning thread.
}
Snapshot::Snapshot(const int origin[3], const int dimensions[3], std::shared_ptr<const CellSource> source)
    : Snapshot(origin, dimensions) {
    require(source != nullptr, "missing owned L2 snapshot");
    source_ = std::move(source);
}
void Snapshot::prepare() {
    if (prepared()) return; // Preserve the callback path's prefetched cells.
    std::vector<Cell> cells(cellCount_);
    std::vector<uint8_t> ready(cellCount_);
    cells_.swap(cells); ready_.swap(ready);
}
size_t Snapshot::cacheBytes() const {
    return std::max(cellCount_, cells_.capacity()) * sizeof(Cell) + std::max(cellCount_, ready_.capacity());
}
void Snapshot::validateSource(const int source[3]) const {
    for (unsigned a = 0; a < 3; ++a) {
        const int64_t relative = int64_t(source[a]) - origin_[a];
        require(relative >= 2 && relative < dimensions_[a] - 2, "L2 source is outside snapshot interior");
    }
}
const Cell& Snapshot::read(int x, int y, int z) {
    const int64_t dx = int64_t(x) - origin_[0], dy = int64_t(y) - origin_[1], dz = int64_t(z) - origin_[2];
    require(dx >= 0 && dx < dimensions_[0] && dy >= 0 && dy < dimensions_[1] &&
        dz >= 0 && dz < dimensions_[2], "L2 sample is outside the two-cell halo");
    const size_t index = static_cast<size_t>(dx + dimensions_[0] * (dy + dimensions_[1] * dz));
    if (ready_[index]) { ++hits; return cells_[index]; }
    require(source_ || reader_, "L2 worker requested an unfrozen cell");
    const Cell value = source_ ? source_->read(x, y, z) : reader_(context_, x, y, z);
    if (!source_) require(value.word <= 2097151 && std::isfinite(value.shade) && value.shade >= 0 && value.shade <= 1,
        "invalid L2 snapshot cell");
    cells_[index] = value; ready_[index] = 1; ++reads;
    return cells_[index];
}
void validateCommand(const Template& t, const Command& c, const Snapshot& snapshot, unsigned firstQuad) {
    snapshot.validateSource(c.source);
    require(firstQuad < AtlasQuads, "L2 quad exceeds corner atlas");
    require(c.tint <= 31 && c.opacity <= 255, "invalid L2 tint or opacity");
    require(std::isfinite(c.size) && c.size > 0, "invalid L2 block size");
    for (unsigned a = 0; a < 3; ++a)
        require(std::isfinite(c.translation[a]) &&
            std::abs(c.translation[a]) + t.extent[a] * c.size <= std::numeric_limits<float>::max(),
            "L2 transformed position exceeds Source float range");
}

void prefetch(const Template& t, const Command& c, Snapshot& snapshot) {
    if (t.mode == 2) return;
    const int x = c.source[0], y = c.source[1], z = c.source[2];
    const Cell& state = snapshot.read(x, y, z);
    if (t.mode == 1) return;
    const bool cubic = (t.flags & 1) || ((t.flags & 2) && state.fullCollision());
    const bool smooth = (t.flags & 8) && state.emission() == 0;
    if (!smooth) {
        const int face = t.lightFace >= 0 ? t.lightFace : (cubic ? t.face : -1);
        if (face >= 0) {
            const auto& n = Normals[face];
            snapshot.read(x + n[0], y + n[1], z + n[2]);
        }
        return;
    }
    const auto& n = Normals[t.face];
    const auto& adjacent = Adjacent[t.face];
    const int bx = x + (cubic ? n[0] : 0), by = y + (cubic ? n[1] : 0), bz = z + (cubic ? n[2] : 0);
    bool open[4];
    for (unsigned i = 0; i < 4; ++i) {
        const auto& a = adjacent[i];
        snapshot.read(bx + a[0], by + a[1], bz + a[2]);
        const auto& test = snapshot.read(bx + a[0] + n[0], by + a[1] + n[1], bz + a[2] + n[2]);
        open[i] = !test.viewBlocking() || test.dampening() == 0;
    }
    snapshot.read(x + n[0], y + n[1], z + n[2]);
    for (unsigned i = 0; i < 4; ++i) if (open[PairA[i]] || open[PairB[i]]) {
        const auto& a = adjacent[PairA[i]];
        const auto& b = adjacent[PairB[i]];
        snapshot.read(bx + a[0] + b[0], by + a[1] + b[1], bz + a[2] + b[2]);
    }
}

const FaceLight& Snapshot::sampleFace(int x, int y, int z, unsigned face, bool cubic) {
    if (faceSource_[0] != x || faceSource_[1] != y || faceSource_[2] != z) {
        faceSource_[0] = x; faceSource_[1] = y; faceSource_[2] = z;
        faceMask_ = 0;
    }
    const unsigned slot = face + (cubic ? 6u : 0u);
    if (faceMask_ & (1u << slot)) { ++faceHits; return faces_[slot]; }
    const auto& n = Normals[face];
    const auto& adjacent = Adjacent[face];
    const int bx = x + (cubic ? n[0] : 0), by = y + (cubic ? n[1] : 0), bz = z + (cubic ? n[2] : 0);
    const Cell* sides[4];
    bool open[4];
    for (unsigned i = 0; i < 4; ++i) {
        const auto& a = adjacent[i];
        sides[i] = &read(bx + a[0], by + a[1], bz + a[2]);
        const Cell& test = read(bx + a[0] + n[0], by + a[1] + n[1], bz + a[2] + n[2]);
        open[i] = !test.viewBlocking() || test.dampening() == 0;
    }
    const Cell& state = read(x, y, z);
    const Cell& next = read(x + n[0], y + n[1], z + n[2]);
    const auto center = light(cubic || !next.solidRender() ? next : state);
    const float centerShade = cubic ? next.shade : state.shade;
    auto& sampled = faces_[slot];
    for (unsigned i = 0; i < 4; ++i) {
        const unsigned a = PairA[i], b = PairB[i];
        const Cell* diagonal = sides[0];
        if (open[a] || open[b])
            diagonal = &read(bx + adjacent[a][0] + adjacent[b][0],
                by + adjacent[a][1] + adjacent[b][1], bz + adjacent[a][2] + adjacent[b][2]);
        sampled.coords[i] = blend(light(*sides[a]), light(*sides[b]), light(*diagonal), center);
        sampled.blocks[i] = static_cast<float>(sampled.coords[i] & 255);
        sampled.skies[i] = static_cast<float>((sampled.coords[i] >> 16) & 255);
        sampled.ao[i] = sum4(sides[a]->shade, sides[b]->shade, diagonal->shade, centerShade) * 0.25f;
    }
    faceMask_ |= 1u << slot;
    ++faceSamples;
    return sampled;
}

LightQuad evaluateLight(const LightTemplate& t, const LightCommand& c, Snapshot& snapshot) {
    LightQuad out;
    if (t.mode == 2) {
        std::copy(std::begin(c.prepared), std::end(c.prepared), out.pixels);
    } else {
        const int x = c.source[0], y = c.source[1], z = c.source[2];
        const Cell& state = snapshot.read(x, y, z);
        if (t.mode == 3) {
            // FluidRenderer uses legacy smooth block/sky light, not model AO or
            // pinned L2 emissive sky. Preserve this descriptor for relighting.
            constexpr int corners[6][4][3] = {
                {{0,0,1},{1,0,1},{1,1,1},{0,1,1}}, {{0,1,0},{1,1,0},{1,0,0},{0,0,0}},
                {{1,0,0},{1,1,0},{1,1,1},{1,0,1}}, {{0,1,0},{0,0,0},{0,0,1},{0,1,1}},
                {{1,1,0},{0,1,0},{0,1,1},{1,1,1}}, {{0,0,0},{1,0,0},{1,0,1},{0,0,1}}
            };
            const auto sample = [&](const Cell& cell) {
                return pack(std::max({cell.block(), unsigned(cell.fluidEmission), unsigned(t.emission)}), cell.sky());
            };
            const auto& n = Normals[t.face];
            const bool cubic = (t.flags & 1) != 0;
            const int base[3] = {x + (cubic ? n[0] : 0), y + (cubic ? n[1] : 0), z + (cubic ? n[2] : 0)};
            const auto& next = snapshot.read(x+n[0], y+n[1], z+n[2]);
            const auto center = sample(cubic || !next.fluidSolid ? next : state);
            uint32_t values[4];
            for (unsigned i = 0; i < 4; ++i) {
                const auto& corner = corners[t.face][i];
                const unsigned a = t.face < 2 || t.face >= 4 ? 0 : 1, b = t.face < 2 ? 1 : 2;
                int pa[3] = {base[0],base[1],base[2]}, pb[3] = {base[0],base[1],base[2]}, pd[3] = {base[0],base[1],base[2]};
                pa[a] += corner[a] <= 0 ? -1 : 1;
                pb[b] += corner[b] <= 0 ? -1 : 1;
                pd[a] = pa[a]; pd[b] = pb[b];
                const auto la = sample(snapshot.read(pa[0],pa[1],pa[2]));
                const auto lb = sample(snapshot.read(pb[0],pb[1],pb[2]));
                const bool blocked = snapshot.read(pa[0]+n[0],pa[1]+n[1],pa[2]+n[2]).fluidSolid
                    && snapshot.read(pb[0]+n[0],pb[1]+n[1],pb[2]+n[2]).fluidSolid;
                const auto ld = blocked ? la : sample(snapshot.read(pd[0],pd[1],pd[2]));
                values[i] = pixel(blend(la,lb,ld,center), t.flatShade, c.tint);
            }
            for (unsigned i = 0; i < 4; ++i) out.pixels[i] = values[t.indices[i]];
        } else if (t.mode == 1) {
            require(state.loaded(), "cross source cell is unavailable");
            const unsigned block = state.emissive() ? 15 : std::max({state.block(), state.emission(), unsigned(t.emission)});
            const unsigned sky = state.emissive() ? 15 : std::max(state.sky(), unsigned(t.emission));
            std::fill(std::begin(out.pixels), std::end(out.pixels), pixel(pack(block, sky), 255, c.tint));
        } else {
            const bool cubic = (t.flags & 1) || ((t.flags & 2) && state.fullCollision());
            const bool smooth = (t.flags & 8) && state.emission() == 0;
            if (!smooth) {
                const int face = t.lightFace >= 0 ? t.lightFace : (cubic ? t.face : -1);
                const Cell* cell = &state;
                if (face >= 0) {
                    const auto& n = Normals[face];
                    cell = &snapshot.read(x + n[0], y + n[1], z + n[2]);
                }
                const auto value = pixel(emit(light(*cell, state), t.emission), t.flatShade, c.tint);
                std::fill(std::begin(out.pixels), std::end(out.pixels), value);
            } else {
                const auto& sampled = snapshot.sampleFace(x, y, z, t.face, cubic);
                out.occlusion = 0;
                for (unsigned i = 0; i < 4; ++i) {
                    uint32_t value;
                    float ambient;
                    if (t.flags & 4) {
                        value = (javaInt(weighted(sampled.blocks, t.weights[i])) & 255) |
                            ((javaInt(weighted(sampled.skies, t.weights[i])) & 255) << 16);
                        ambient = std::clamp(weighted(sampled.ao, t.weights[i]), 0.0f, 1.0f);
                    } else {
                        value = sampled.coords[t.indices[i]]; ambient = sampled.ao[t.indices[i]];
                    }
                    const auto gray = static_cast<unsigned>(ambient * 255.0f);
                    out.occlusion |= gray << (i * 8);
                    out.pixels[i] = pixel(emit(value, t.emission),
                        static_cast<unsigned>(static_cast<float>(gray) * t.directionShade), c.tint);
                }
            }
        }
    }
    return out;
}

Quad evaluate(const Template& t, const Command& c, Snapshot& snapshot, unsigned globalQuad) {
    Quad out;
    const auto light = evaluateLight(t, c, snapshot);
    std::copy(std::begin(light.pixels), std::end(light.pixels), out.pixels);
    out.occlusion = light.occlusion;
    for (unsigned i = 0; i < 4; ++i) {
        Vertex& v = out.vertices[i];
        for (unsigned a = 0; a < 3; ++a) {
            // Lua does the transform in double before the Source float upload.
            v.position[a] = static_cast<float>(c.translation[a] + t.positions[i][a] * c.size);
            v.normal[a] = t.normal[a];
        }
        std::copy(std::begin(t.uv[i]), std::end(t.uv[i]), v.uv);
        const unsigned address = globalQuad * 4 + i;
        v.color[0] = static_cast<uint8_t>(address);
        v.color[1] = static_cast<uint8_t>(address >> 8);
        v.color[2] = static_cast<uint8_t>(address >> 16);
        v.color[3] = static_cast<uint8_t>(c.opacity);
    }
    return out;
}
}
