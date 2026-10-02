#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

// No GLua or Source dependencies: the probe and game module use this same core.
namespace mcmesh::l2 {
constexpr unsigned TemplateSize = 46;
constexpr unsigned MaxQuads = 10833;
constexpr unsigned AtlasQuads = 1048576;
constexpr unsigned Triangle[6] = {0, 2, 1, 0, 3, 2};

struct Template {
    int mode = 0, face = 0, flags = 0, flatShade = 255, emission = 0, lightFace = -1;
    float directionShade = 1;
    double positions[4][3]{}, extent[3]{};
    float uv[4][2]{}, normal[3]{}, weights[4][4]{};
    unsigned indices[4]{};
};

struct Cell {
    uint32_t word = 0;
    float shade = 0;
    uint32_t renderClass = 0;
    unsigned block() const { return word & 15; }
    unsigned sky() const { return (word >> 4) & 15; }
    unsigned emission() const { return (word >> 8) & 15; }
    unsigned dampening() const { return (word >> 12) & 15; }
    bool emissive() const { return (word & 65536) != 0; }
    bool viewBlocking() const { return (word & 131072) != 0; }
    bool solidRender() const { return (word & 262144) != 0; }
    bool fullCollision() const { return (word & 524288) != 0; }
    bool loaded() const { return (word & 1048576) != 0; }
};

using ReadCell = Cell (*)(void*, int, int, int);
// Only immutable CPU data may implement this interface. Live Lua readers use
// the callback constructor and are always detached before worker submission.
struct CellSource {
    virtual ~CellSource() = default;
    virtual Cell read(int x, int y, int z) const = 0;
    virtual size_t bytes() const = 0;
};
class Snapshot {
public:
    Snapshot(const int origin[3], const int dimensions[3], ReadCell reader, void* context);
    Snapshot(const int origin[3], const int dimensions[3], std::shared_ptr<const CellSource> source);
    const Cell& read(int x, int y, int z);
    void validateSource(const int source[3]) const;
    void freeze() { reader_ = nullptr; context_ = nullptr; }
    size_t bytes() const { return cells_.capacity() * sizeof(Cell) + ready_.capacity() + (source_ ? source_->bytes() : 0); }
    uint64_t reads = 0, hits = 0;
private:
    int origin_[3], dimensions_[3];
    ReadCell reader_;
    void* context_;
    std::shared_ptr<const CellSource> source_;
    std::vector<Cell> cells_;
    std::vector<uint8_t> ready_;
};

struct Command {
    int source[3]{};
    double translation[3]{}, size = 1;
    unsigned tint = 0, opacity = 255;
    uint32_t prepared[4]{};
};
struct Vertex {
    float position[3], normal[3], uv[2];
    uint8_t color[4];
};
struct Quad {
    Vertex vertices[4]{};
    uint32_t pixels[4]{}, occlusion = 0xffffffff;
};

void require(bool valid, const char* message);
int integer(double value, int minimum, int maximum, const char* message);
Template compile(const double* packet);
void validateCommand(const Template& geometry, const Command& command, const Snapshot& snapshot, unsigned firstQuad);
void prefetch(const Template& geometry, const Command& command, Snapshot& snapshot);
Quad evaluate(const Template& geometry, const Command& command, Snapshot& snapshot, unsigned globalQuad);
}
