#pragma once
#include "Render/Visibility/VisibilityTypes.h"

namespace mcmesh::l2draw
{
/// Pure CPU queries; inputs must be validated before entering geometry loops.
ERejectReason	TestBounds(const VisibilityBounds &inBounds, const Vec &inOrigin, const VisibilityView &inView, bool inTestDistance);
VisibilityFrame Compute(std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView, std::shared_ptr<const PortalMask> inPortals = nullptr);
/// True only when the original conservative envelope covers this view and revision.
bool Covers(const VisibilityFrame &inFrame, const VisibilityScene *inScene, const VisibilityGraph *inGraph, const VisibilityView &inView);
bool IsDirectionVisible(unsigned inGroup, const float inBounds[6], const Vec &inEye, double inMargin);
} // namespace mcmesh::l2draw
