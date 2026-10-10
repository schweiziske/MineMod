#include "Mesh/ModelShapes.h"
#include "Mesh/SectionGeometry.h"
#include <algorithm>
#include <cmath>

namespace mcmesh::l2
{
void Shape::validate() const
{
	require(selector <= 3 && connections <= 7 && stair >= -1 && stair < 8, "invalid render shape properties");
	const unsigned counts[] = {1, 5, 16, 64};
	require(variants.size() == counts[selector] && (selector != 1 || stair >= 0), "invalid render shape variants");
	for (const auto &boxes : variants)
	{
		require(boxes.size() <= 4096, "render shape box limit");
		for (const auto &box : boxes)
			for (unsigned a = 0; a < 3; ++a)
				require(std::isfinite(box[a]) && std::isfinite(box[a + 3]) && box[a] <= box[a + 3],
						"invalid render shape bounds");
	}
}
size_t Shape::bytes() const
{
	size_t n = sizeof(Shape) + variants.capacity() * sizeof(std::vector<ShapeBox>);
	for (const auto &boxes : variants)
		n += boxes.capacity() * sizeof(ShapeBox);
	return n;
}
unsigned shapeChoice(const ShapeSource &source, const int p[3], const Shape &shape)
{
	constexpr int offsets[6][3] = {{0, -1, 0}, {0, 1, 0}, {-1, 0, 0}, {1, 0, 0}, {0, 0, -1}, {0, 0, 1}};
	const auto	  neighbour = [&](unsigned direction) -> const Shape &
	{
		const auto &off = offsets[direction];
		return source.shape(p[0] + off[0], p[1] + off[1], p[2] + off[2]);
	};
	if (shape.selector == 0)
		return 0;
	if (shape.selector != 1)
	{
		unsigned	   mask = 0;
		const unsigned count = shape.selector == 3 ? 6 : 4;
		for (unsigned i = 0; i < count; ++i)
		{
			const auto flags = neighbour(i).connections;
			if (shape.selector == 2 ? (flags & 1) : (flags & 2) || (i == 4 && (flags & 4)))
				mask |= 1u << i;
		}
		return mask;
	}
	constexpr unsigned opposite[] = {1, 0, 3, 2}, ccw[] = {2, 3, 1, 0};
	const unsigned	   facing = unsigned(shape.stair) & 3;
	const int		   half = shape.stair & 4;
	const auto		   candidate = [&](int other)
	{
		return other >= 0 && (other & 4) == half && (unsigned(other & 3) / 2 != facing / 2);
	};
	const int ahead = neighbour(facing).stair;
	if (candidate(ahead) && neighbour(opposite[ahead & 3]).stair != shape.stair)
		return unsigned(ahead & 3) == ccw[facing] ? 3 : 4;
	const int behind = neighbour(opposite[facing]).stair;
	if (candidate(behind) && neighbour(behind & 3).stair != shape.stair)
		return unsigned(behind & 3) == ccw[facing] ? 1 : 2;
	return 0;
}
bool shapeCovered(const ShapeBox &box, unsigned face, const std::vector<ShapeBox> &boxes, const int off[3])
{
	constexpr double   eps = 0.0001;
	constexpr unsigned axes[] = {2, 2, 0, 0, 1, 1};
	const unsigned	   axis = axes[face], a = axis == 0 ? 1 : 0, b = axis == 2 ? 1 : 2;
	const bool		   positive = (face & 1) == 0;
	const double	   plane = box[axis + (positive ? 3 : 0)];
	if (std::abs(plane - (positive ? 1 : 0)) > eps)
		return false;
	std::vector<std::array<double, 4>> covers;
	std::vector<double>				   as{box[a], box[a + 3]}, bs{box[b], box[b + 3]};
	for (const auto &other : boxes)
	{
		if (std::abs(other[axis + (positive ? 0 : 3)] + off[axis] - plane) > eps)
			continue;
		const double a0 = std::max(box[a], other[a] + off[a]), a1 = std::min(box[a + 3], other[a + 3] + off[a]);
		const double b0 = std::max(box[b], other[b] + off[b]), b1 = std::min(box[b + 3], other[b + 3] + off[b]);
		if (a1 <= box[a] + eps || a0 >= box[a + 3] - eps || b1 <= box[b] + eps || b0 >= box[b + 3] - eps)
			continue;
		if (a0 <= box[a] + eps && a1 >= box[a + 3] - eps && b0 <= box[b] + eps && b1 >= box[b + 3] - eps)
			return true;
		covers.push_back({a0, a1, b0, b1});
		for (double edge : {a0, a1})
			if (edge > box[a] + eps && edge < box[a + 3] - eps)
				as.push_back(edge);
		for (double edge : {b0, b1})
			if (edge > box[b] + eps && edge < box[b + 3] - eps)
				bs.push_back(edge);
	}
	if (covers.empty())
		return false;
	std::sort(as.begin(), as.end());
	std::sort(bs.begin(), bs.end());
	for (size_t ai = 1; ai < as.size(); ++ai)
		for (size_t bi = 1; bi < bs.size(); ++bi)
		{
			const double ma = (as[ai - 1] + as[ai]) * 0.5, mb = (bs[bi - 1] + bs[bi]) * 0.5;
			bool		 covered = false;
			for (const auto &r : covers)
				if (ma >= r[0] - eps && ma <= r[1] + eps && mb >= r[2] - eps && mb <= r[3] + eps)
				{
					covered = true;
					break;
				}
			if (!covered)
				return false;
		}
	return true;
}
} // namespace mcmesh::l2
