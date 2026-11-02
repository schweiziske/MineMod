#pragma once

#include "Render/Visibility/VisibilityTypes.h"

namespace mcmesh::l2draw
{
/// Link spatial components before publishing the graph; mutates only ioGraph.
/// A node whose identity and six neighbour identities match the node at the
/// same position in inPrevious reuses its entries and components.
void BuildSpatialGraph(VisibilityGraph &ioGraph, const VisibilityGraph *inPrevious = nullptr);
/// Traverse a validated immutable graph. Blocking walls remain visible.
std::vector<uint8_t> FindReachable(const VisibilityGraph &inGraph, unsigned inRoot, uint8_t inSeed);
std::vector<uint8_t> FindReachable(const VisibilityGraph &inGraph, const VisibilityView &inView, unsigned &outVisited);
} // namespace mcmesh::l2draw
