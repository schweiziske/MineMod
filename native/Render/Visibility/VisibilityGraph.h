#pragma once

#include "Render/Visibility/VisibilityTypes.h"

namespace mcmesh::l2draw
{
/// Link spatial components before publishing the graph; mutates only ioGraph.
void BuildSpatialGraph(VisibilityGraph &ioGraph);
/// Traverse a validated immutable graph. Blocking walls remain visible.
std::vector<uint8_t> FindReachable(const VisibilityGraph &inGraph, unsigned inRoot, uint8_t inSeed);
std::vector<uint8_t> FindReachable(const VisibilityGraph &inGraph, const VisibilityView &inView, unsigned &outVisited);
} // namespace mcmesh::l2draw
