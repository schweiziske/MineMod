#pragma once
#include "Render/Visibility/VisibilityTypes.h"
#include <cmath>

namespace mcmesh::l2draw::detail
{
inline double Length(const Vec &inVector)
{
	return std::sqrt(inVector[0] * inVector[0] + inVector[1] * inVector[1] + inVector[2] * inVector[2]);
}
inline Vec Subtract(const Vec &inLeft, const Vec &inRight)
{
	return {inLeft[0] - inRight[0], inLeft[1] - inRight[1], inLeft[2] - inRight[2]};
}
} // namespace mcmesh::l2draw::detail
