#pragma once
#include <array>
#include <cstddef>
#include <memory>
#include <vector>

namespace mcmesh::l2
{
using ShapeBox = std::array<double, 6>;
struct Shape
{
	// 0 static, 1 stairs, 2 horizontal connections, 3 six-way connections.
	unsigned						   selector = 0, connections = 0;
	int								   stair = -1;
	bool							   pane = false;
	std::vector<std::vector<ShapeBox>> variants{{}};
	void							   validate() const;
	size_t							   bytes() const;
};
struct ShapeSource
{
	virtual ~ShapeSource() = default;
	virtual const Shape &shape(int x, int y, int z) const = 0;
};
inline std::shared_ptr<const Shape> emptyShape()
{
	static const auto value = std::make_shared<const Shape>();
	return value;
}
unsigned shapeChoice(const ShapeSource &source, const int position[3], const Shape &shape);
bool	 shapeCovered(const ShapeBox &box, unsigned face, const std::vector<ShapeBox> &boxes, const int offset[3]);
} // namespace mcmesh::l2
