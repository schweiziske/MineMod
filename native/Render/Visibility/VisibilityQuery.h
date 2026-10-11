#pragma once
#include "Render/Visibility/VisibilityTypes.h"
#include "Mesh/SectionGeometry.h"
#include <array>

namespace mcmesh::l2draw
{
/// Pure CPU queries; inputs must be validated before entering geometry loops.
ERejectReason	TestBounds(const VisibilityBounds &inBounds, const Vec &inOrigin, const VisibilityView &inView, bool inTestDistance);
VisibilityFrame Compute(std::shared_ptr<const VisibilityScene> inScene, std::shared_ptr<const VisibilityGraph> inGraph, const VisibilityView &inView, std::shared_ptr<const PortalMask> inPortals = nullptr);
/// True only when the original conservative envelope covers this view and revision.
bool Covers(const VisibilityFrame &inFrame, const VisibilityScene *inScene, const VisibilityGraph *inGraph, const VisibilityView &inView);
bool IsDirectionVisible(unsigned inGroup, const float inBounds[6], const Vec &inEye, double inMargin);

struct DirectionDrawRanges
{
	std::array<l2::DirectionRange, 7> mRanges{};
	unsigned						 mRangeCount = 0, mIndices = 0, mRejectedDirections = 0, mMergedRanges = 0;
};
/// Select from the validated directional index stream. Merge only consecutive
/// intervals; retain exactly the same indices and order, including group 6.
DirectionDrawRanges SelectDirectionRanges(const std::array<l2::DirectionRange, 7> &inRanges,
										 const float inBounds[6], const Vec &inEye, double inMargin);
} // namespace mcmesh::l2draw
