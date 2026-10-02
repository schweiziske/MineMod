#include "../l2_core.h"
#include <algorithm>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

using namespace mcmesh::l2;
namespace {
unsigned checks = 0;
void check(bool value, const char* message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
template<class F> void rejects(F action, const char* text) {
    try { action(); }
    catch (const std::runtime_error& error) {
        check(std::string(error.what()).find(text) != std::string::npos, "wrong failure reason");
        return;
    }
    throw std::runtime_error("invalid input was accepted");
}
std::array<double, TemplateSize> packet() {
    std::array<double, TemplateSize> p{};
    p[1] = 1; p[2] = 11; p[3] = 1; p[4] = 255;
    p[7] = 1; p[29] = 1;
    for (unsigned i = 0; i < 4; ++i) p[30 + i * 4] = i;
    return p;
}
struct Reader {
    unsigned calls = 0;
    bool fail = false;
    Cell cell{1048576 + 240, 1.0f};
    static Cell read(void* context, int, int, int) {
        auto& self = *static_cast<Reader*>(context);
        ++self.calls;
        if (self.fail) throw std::runtime_error("injected reader failure");
        return self.cell;
    }
};
void run() {
    const int origin[3]{}, dims[3] = {5,5,5};
    Reader reader;
    Snapshot snapshot(origin, dims, Reader::read, &reader);
    Command c;
    std::fill(std::begin(c.source), std::end(c.source), 2);
    const auto p = packet();
    const Template t = compile(p.data());
    validateCommand(t, c, snapshot, AtlasQuads - 1);
    const Quad q = evaluate(t, c, snapshot, AtlasQuads - 1);
    check(q.pixels[0] == 0x00fff000, "full sky pixel");
    check(q.occlusion == 0xffffffff, "full AO pixel");
    check(q.vertices[3].color[0] == 255 && q.vertices[3].color[1] == 255 &&
        q.vertices[3].color[2] == 63, "last corner address");
    check(snapshot.reads == reader.calls && snapshot.reads <= 27, "cell cache read accounting");
    const unsigned calls = reader.calls;
    evaluate(t, c, snapshot, 0);
    check(reader.calls == calls && snapshot.hits > 0, "snapshot cache reuse");
    for (unsigned tint = 0; tint < 32; ++tint) {
        c.tint = tint;
        const auto tinted = evaluate(t, c, snapshot, 0);
        check(tinted.pixels[0] == (0x00fff000 | (tint << 24)), "tint transport byte");
    }
    c.tint = 0;
    for (unsigned field : {0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 19u, 27u, 30u}) {
        auto invalid = p;
        invalid[field] = std::numeric_limits<double>::quiet_NaN();
        rejects([&] { compile(invalid.data()); }, "non-finite");
    }
    for (auto entry : {std::pair<unsigned, double>{0,3}, {1,0}, {1,7}, {2,16},
            {3,1.1}, {4,256}, {5,16}, {6,7}, {30,4}, {30,0.5}}) {
        auto invalid = p;
        invalid[entry.first] = entry.second;
        rejects([&] { compile(invalid.data()); }, "invalid");
    }
    auto invalid = p;
    invalid[34] = 0;
    rejects([&] { compile(invalid.data()); }, "permutation");
    rejects([&] { validateCommand(t, c, snapshot, AtlasQuads); }, "atlas");
    auto bad = c; bad.source[0] = 1;
    rejects([&] { validateCommand(t, bad, snapshot, 0); }, "interior");
    bad = c; bad.opacity = 256;
    rejects([&] { validateCommand(t, bad, snapshot, 0); }, "opacity");
    bad = c; bad.tint = 32;
    rejects([&] { validateCommand(t, bad, snapshot, 0); }, "tint");
    bad = c; bad.size = -1;
    rejects([&] { validateCommand(t, bad, snapshot, 0); }, "size");
    bad = c; bad.size = 1e100;
    rejects([&] { validateCommand(t, bad, snapshot, 0); }, "float range");
    bad = c; bad.translation[0] = std::numeric_limits<double>::infinity();
    rejects([&] { validateCommand(t, bad, snapshot, 0); }, "float range");
    const int huge[3] = {4096,4096,4096}, small[3] = {4,5,5}, edge[3] = {INT32_MAX,0,0};
    rejects([&] { Snapshot s(origin, huge, Reader::read, &reader); }, "budget");
    rejects([&] { Snapshot s(origin, small, Reader::read, &reader); }, "dimensions");
    rejects([&] { Snapshot s(edge, dims, Reader::read, &reader); }, "overflow");
    rejects([&] { Snapshot s(origin, dims, nullptr, &reader); }, "reader");
    rejects([&] { snapshot.read(-1, 2, 2); }, "halo");
    rejects([&] { snapshot.read(5, 2, 2); }, "halo");
    Reader failed;
    Snapshot fresh(origin, dims, Reader::read, &failed);
    failed.fail = true;
    rejects([&] { fresh.read(2,2,2); }, "injected");
    failed.fail = false;
    check(fresh.read(2,2,2).loaded() && fresh.reads == 1 && failed.calls == 2, "failed sample was cached");
    Reader invalidCell;
    Snapshot invalidCells(origin, dims, Reader::read, &invalidCell);
    invalidCell.cell.word = 2097152;
    rejects([&] { invalidCells.read(2,2,2); }, "cell");
    invalidCell.cell = {1048576, std::numeric_limits<float>::quiet_NaN()};
    rejects([&] { invalidCells.read(2,2,2); }, "cell");
    invalidCell.cell = {0, 0.2f};
    auto cross = t; cross.mode = 1;
    rejects([&] { evaluate(cross, c, invalidCells, 0); }, "unavailable");
    auto prepared = t; prepared.mode = 2;
    failed.fail = true;
    c.prepared[0] = 0x12345678; c.prepared[3] = 0xffffffff;
    Snapshot unread(origin, dims, Reader::read, &failed);
    const auto fluid = evaluate(prepared, c, unread, 0);
    check(fluid.pixels[0] == c.prepared[0] && fluid.pixels[3] == c.prepared[3] &&
        fluid.occlusion == 0xffffffff && unread.reads == 0, "prepared fluid sampled world");
}
}
int main() {
    try { run(); std::cout << "L2 core: " << checks << " checks passed\n"; return 0; }
    catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
