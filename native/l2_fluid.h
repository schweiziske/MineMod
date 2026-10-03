#pragma once
#include "l2_core.h"

namespace mcmesh::l2 {
struct FluidState {
    double height = 0;
    std::array<double, 6> cover{};
    uint8_t kind = 0, sturdy = 0;
    bool ready = false, solid = false, blocksMotion = false, falling = false, ice = false;
};
using FluidBox = std::array<double, 6>;
void compileFluidCoverage(FluidState& state, bool full, bool empty, const std::vector<FluidBox>& boxes);
struct FluidTile {
    // Uninset atlas origin, scale per raw UV unit, and endpoint inset.
    double origin[2]{}, scale[2]{}, inset[2]{};
};
struct FluidRecipe {
    std::array<FluidTile, 7> tiles; // Six faces, then flowing top.
    std::array<unsigned, 6> shade{};
    double offset = 0;
    unsigned emission = 0, opacity = 255, group = 0;
    uint8_t kind = 0;
    bool flow = false, full = false;
};
struct FluidSource {
    virtual ~FluidSource() = default;
    virtual const FluidState& fluid(int x, int y, int z) const = 0;
};
struct FluidGeometry {
    std::array<Template, 6> faces;
    unsigned mask = 0;
};
FluidGeometry fluidGeometry(const FluidRecipe& recipe, const FluidSource& source, const int cell[3]);
}
