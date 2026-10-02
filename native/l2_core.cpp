#include "l2_core.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace mcmesh::l2 {
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

Snapshot::Snapshot(const int origin[3], const int dimensions[3], ReadCell reader, void* context)
    : reader_(reader), context_(context) {
    require(reader != nullptr, "missing L2 snapshot reader");
    size_t count = 1;
    for (unsigned a = 0; a < 3; ++a) {
        require(dimensions[a] >= 5 && dimensions[a] <= 4096, "invalid L2 snapshot dimensions");
        require(int64_t(origin[a]) + dimensions[a] <= INT32_MAX, "L2 snapshot coordinate overflow");
        origin_[a] = origin[a]; dimensions_[a] = dimensions[a];
        require(count <= (4 * 1024 * 1024) / size_t(dimensions[a]), "L2 snapshot exceeds cell budget");
        count *= dimensions[a];
    }
    cells_.resize(count); ready_.resize(count);
}
Snapshot::Snapshot(const int origin[3], const int dimensions[3], std::shared_ptr<const CellSource> source)
    : Snapshot(origin, dimensions, [](void*, int, int, int) -> Cell {
        throw std::runtime_error("missing owned L2 cell source");
    }, nullptr) {
    require(source != nullptr, "missing owned L2 snapshot");
    source_ = std::move(source);
    freeze();
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

Quad evaluate(const Template& t, const Command& c, Snapshot& snapshot, unsigned globalQuad) {
    Quad out;
    if (t.mode == 2) {
        std::copy(std::begin(c.prepared), std::end(c.prepared), out.pixels);
    } else {
        const int x = c.source[0], y = c.source[1], z = c.source[2];
        const Cell& state = snapshot.read(x, y, z);
        if (t.mode == 1) {
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
                const auto& n = Normals[t.face];
                const auto& adjacent = Adjacent[t.face];
                const int bx = x + (cubic ? n[0] : 0), by = y + (cubic ? n[1] : 0), bz = z + (cubic ? n[2] : 0);
                const Cell* sides[4];
                bool open[4];
                for (unsigned i = 0; i < 4; ++i) {
                    const auto& a = adjacent[i];
                    sides[i] = &snapshot.read(bx + a[0], by + a[1], bz + a[2]);
                    const Cell& test = snapshot.read(bx + a[0] + n[0], by + a[1] + n[1], bz + a[2] + n[2]);
                    open[i] = !test.viewBlocking() || test.dampening() == 0;
                }
                const Cell& next = snapshot.read(x + n[0], y + n[1], z + n[2]);
                const auto center = light(cubic || !next.solidRender() ? next : state);
                const float centerShade = cubic ? next.shade : state.shade;
                uint32_t coords[4];
                float ao[4], blocks[4], skies[4];
                for (unsigned i = 0; i < 4; ++i) {
                    const unsigned a = PairA[i], b = PairB[i];
                    const Cell* diagonal = sides[0];
                    if (open[a] || open[b])
                        diagonal = &snapshot.read(bx + adjacent[a][0] + adjacent[b][0],
                            by + adjacent[a][1] + adjacent[b][1], bz + adjacent[a][2] + adjacent[b][2]);
                    coords[i] = blend(light(*sides[a]), light(*sides[b]), light(*diagonal), center);
                    blocks[i] = static_cast<float>(coords[i] & 255);
                    skies[i] = static_cast<float>((coords[i] >> 16) & 255);
                    ao[i] = sum4(sides[a]->shade, sides[b]->shade, diagonal->shade, centerShade) * 0.25f;
                }
                out.occlusion = 0;
                for (unsigned i = 0; i < 4; ++i) {
                    uint32_t value;
                    float ambient;
                    if (t.flags & 4) {
                        value = (javaInt(weighted(blocks, t.weights[i])) & 255) |
                            ((javaInt(weighted(skies, t.weights[i])) & 255) << 16);
                        ambient = std::clamp(weighted(ao, t.weights[i]), 0.0f, 1.0f);
                    } else {
                        value = coords[t.indices[i]]; ambient = ao[t.indices[i]];
                    }
                    const auto gray = static_cast<unsigned>(ambient * 255.0f);
                    out.occlusion |= gray << (i * 8);
                    out.pixels[i] = pixel(emit(value, t.emission),
                        static_cast<unsigned>(static_cast<float>(gray) * t.directionShade), c.tint);
                }
            }
        }
    }
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
