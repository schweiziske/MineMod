#include "../l2_worker.h"
#include <algorithm>
#include <exception>
#include <string>

#ifdef _WIN32
#define L2_EXPORT extern "C" __declspec(dllexport)
#else
#define L2_EXPORT extern "C"
#endif

namespace {
thread_local std::string lastError;
struct ProbeCells {
    const uint32_t* words;
    const float* shades;
    const int* dimensions;
    const uint32_t* classes = nullptr;
    const int* origin = nullptr;
};
mcmesh::l2::Cell read(void* context, int x, int y, int z) {
    const auto& in = *static_cast<ProbeCells*>(context);
    if (in.origin) { x -= in.origin[0]; y -= in.origin[1]; z -= in.origin[2]; }
    const auto index = x + in.dimensions[0] * (y + in.dimensions[1] * z);
    return {in.words[index], in.shades[index], in.classes ? in.classes[index] : 0};
}
}

L2_EXPORT const char* L2LastError() { return lastError.c_str(); }
L2_EXPORT unsigned L2ModelChoice(int x, int y, int z, unsigned salt) {
    mcmesh::l2::ModelGroup group;
    group.salt = salt;
    group.totalWeight = 11;
    group.alternatives.resize(3);
    group.alternatives[0].weight = 2;
    group.alternatives[1].weight = 5;
    group.alternatives[2].weight = 4;
    const int source[3] = {x,y,z};
    return mcmesh::l2::modelChoice(group, source);
}
L2_EXPORT unsigned L2TriangleIndex(unsigned index) {
    return index < 6 ? mcmesh::l2::Triangle[index] : UINT32_MAX;
}
L2_EXPORT int L2Evaluate(const double* packet, const uint32_t* words, const float* shades,
    const int* dimensions, const int* source, const double* transform,
    unsigned tint, unsigned opacity, unsigned firstQuad, const uint32_t* prepared,
    uint32_t* pixels, float* vertices, uint64_t* statistics, unsigned repeat) {
    using namespace mcmesh::l2;
    try {
        require(packet && words && shades && dimensions && source && transform && prepared &&
            pixels && vertices && statistics && repeat > 0, "invalid probe arguments");
        const Template geometry = compile(packet);
        Command command;
        std::copy(source, source + 3, command.source);
        std::copy(transform, transform + 3, command.translation);
        std::copy(prepared, prepared + 4, command.prepared);
        command.size = transform[3]; command.tint = tint; command.opacity = opacity;
        const int origin[3]{};
        ProbeCells input{words, shades, dimensions};
        Snapshot snapshot(origin, dimensions, read, &input);
        validateCommand(geometry, command, snapshot, firstQuad);
        prefetch(geometry, command, snapshot);
        snapshot.freeze();
        Quad quad;
        for (unsigned i = 0; i < repeat; ++i) quad = evaluate(geometry, command, snapshot, firstQuad);
        std::copy(std::begin(quad.pixels), std::end(quad.pixels), pixels);
        pixels[4] = quad.occlusion;
        for (unsigned i = 0; i < 4; ++i) {
            const auto& v = quad.vertices[i];
            std::copy(std::begin(v.position), std::end(v.position), vertices + i * 12);
            std::copy(std::begin(v.normal), std::end(v.normal), vertices + i * 12 + 3);
            std::copy(std::begin(v.uv), std::end(v.uv), vertices + i * 12 + 6);
            std::copy(std::begin(v.color), std::end(v.color), vertices + i * 12 + 8);
        }
        statistics[0] = snapshot.reads; statistics[1] = snapshot.hits;
        statistics[2] = repeat * 4ull; statistics[3] = repeat * 6ull;
        lastError.clear();
        return 1;
    } catch (const std::exception& e) {
        lastError = e.what();
        return 0;
    }
}

// Exercises the production voxel expansion and frozen sampling without Source.
L2_EXPORT int L2EvaluateVoxels(const double* packets, const uint32_t* metadata, unsigned cubeCount,
    const int* voxels, const double* translations, unsigned voxelCount, double blockSize, unsigned maxQuads,
    const uint32_t* words, const float* shades, const uint32_t* classes, const int* origin, const int* dimensions,
    uint32_t* layout, uint32_t* pixels, float* vertices, uint64_t* statistics) {
    using namespace mcmesh::l2;
    try {
        require(cubeCount > 0 && cubeCount <= 512 && voxelCount <= 512, "invalid voxel probe counts");
        require(maxQuads > 0 && maxQuads <= MaxQuads, "invalid voxel probe part limit");
        ProbeCells cells{words, shades, dimensions, classes, origin};
        Input input(Snapshot(origin, dimensions, read, &cells));
        input.blockSize = blockSize;
        input.maxQuads = maxQuads;
        for (unsigned c = 0; c < cubeCount; ++c) {
            Cube cube;
            cube.block = metadata[c * 19];
            for (unsigned f = 0; f < 6; ++f) {
                auto& w = cube.faces[f];
                w.geometry = compile(packets + (c * 6 + f) * TemplateSize);
                cube.groups[f] = metadata[c * 19 + 1 + f * 3];
                w.command.tint = metadata[c * 19 + 2 + f * 3];
                w.command.opacity = metadata[c * 19 + 3 + f * 3];
            }
            validateCube(cube);
            input.cubes.push_back(cube);
        }
        for (unsigned i = 0; i < voxelCount; ++i) {
            Voxel voxel;
            std::copy(voxels + i * 4, voxels + i * 4 + 3, voxel.source);
            std::copy(translations + i * 3, translations + i * 3 + 3, voxel.translation);
            voxel.cube = voxels[i * 4 + 3];
            require(voxel.cube < cubeCount, "invalid voxel probe recipe");
            input.snapshot.validateSource(voxel.source);
            input.voxels.push_back(voxel);
        }
        prefetchVoxels(input);
        input.snapshot.freeze();
        std::atomic<bool> cancelled{false};
        std::vector<unsigned> groups;
        expandVoxels(input, groups, cancelled);
        unsigned count = 0;
        for (unsigned p = 0; p < input.parts.size(); ++p) {
            for (unsigned q = 0; q < input.parts[p].size(); ++q, ++count) {
                const auto& work = input.parts[p][q];
                const auto quad = evaluate(work.geometry, work.command, input.snapshot, q);
                layout[count * 2] = p;
                layout[count * 2 + 1] = groups[p];
                std::copy(std::begin(quad.pixels), std::end(quad.pixels), pixels + count * 5);
                pixels[count * 5 + 4] = quad.occlusion;
                for (unsigned c = 0; c < 4; ++c) {
                    const auto& v = quad.vertices[c];
                    auto* out = vertices + count * 48 + c * 12;
                    std::copy(std::begin(v.position), std::end(v.position), out);
                    std::copy(std::begin(v.normal), std::end(v.normal), out + 3);
                    std::copy(std::begin(v.uv), std::end(v.uv), out + 6);
                    std::copy(std::begin(v.color), std::end(v.color), out + 8);
                }
            }
        }
        statistics[0] = input.snapshot.reads;
        statistics[1] = input.snapshot.hits;
        lastError.clear();
        return static_cast<int>(count);
    } catch (const std::exception& e) { lastError = e.what(); return -1; }
}
