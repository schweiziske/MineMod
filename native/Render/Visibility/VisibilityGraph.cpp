#include "Render/Visibility/VisibilityGraph.h"
#include <algorithm>
#include <stdexcept>
namespace mcmesh::l2draw
{
std::vector<uint8_t> FindReachable(const VisibilityGraph &inGraph, unsigned inRoot, uint8_t inSeed)
{
	std::vector<uint8_t> seen(inGraph.mNodes.size()), exits(inGraph.mNodes.size()), sent(inGraph.mNodes.size()),
		queued(inGraph.mNodes.size());
	std::vector<unsigned> queue;
	auto				  visit = [&](unsigned id, uint8_t mask)
	{
		seen[id] = 1; // The wall that stops propagation is itself visible.
		const auto combined = uint8_t(exits[id] | mask);
		if (combined == exits[id])
			return;
		exits[id] = combined;
		if (!queued[id])
		{
			queued[id] = 1;
			queue.push_back(id);
		}
	};
	bool exterior_seen = false;
	auto exterior = [&]
	{
		exterior_seen = true;
		for (unsigned id = 1; id < inGraph.mNodes.size(); ++id)
		{
			const auto &node = inGraph.mNodes[id];
			if (node.mLive)
				for (unsigned face = 0; face < 6; ++face)
					if (!node.mNeighbors[face])
						visit(id, node.mExits[face]);
		}
	};
	if (inRoot)
	{
		if (inRoot >= inGraph.mNodes.size() || !inGraph.mNodes[inRoot].mLive || inSeed > 63)
			throw std::runtime_error("invalid Native visibility root");
		visit(inRoot, inSeed);
	}
	else
		exterior();
	for (size_t head = 0; head < queue.size(); ++head)
	{
		const unsigned id = queue[head];
		queued[id] = 0;
		const unsigned pending = exits[id] & ~sent[id];
		sent[id] = exits[id];
		for (unsigned face = 0; face < 6; ++face)
			if (pending & (1u << face))
			{
				const auto neighbor = inGraph.mNodes[id].mNeighbors[face];
				if (neighbor)
					visit(neighbor, inGraph.mNodes[neighbor].mExits[face ^ 1]);
				else if (!exterior_seen)
					exterior();
			}
	}
	return seen;
}
void BuildSpatialGraph(VisibilityGraph &ioGraph)
{
	ioGraph.mSpatial = true;
	ioGraph.mGrid.clear();
	ioGraph.mLower = {};
	ioGraph.mSize = {};
	std::vector<Cell> positions;
	for (const auto &node : ioGraph.mNodes)
		if (node.mLive)
			positions.push_back(node.mPosition);
	if (positions.empty())
		return;
	std::sort(positions.begin(), positions.end());
	if (std::adjacent_find(positions.begin(), positions.end()) != positions.end())
		throw std::runtime_error("duplicate Native spatial section");
	Cell upper = ioGraph.mLower = positions.front();
	for (const auto &p : positions)
		for (unsigned a = 0; a < 3; ++a)
		{
			ioGraph.mLower[a] = std::min(ioGraph.mLower[a], p[a]);
			upper[a] = std::max(upper[a], p[a]);
		}
	// Widely separated islands must not create an unbounded dense allocation.
	// Such graphs retain conservative connectivity and report that mode.
	constexpr uint64_t limit = 1u << 20;
	uint64_t		   volume = 1;
	Cell			   size;
	for (unsigned a = 0; a < 3; ++a)
	{
		const auto extent = uint64_t(int64_t(upper[a]) - ioGraph.mLower[a] + 1);
		if (extent > limit / volume)
			return;
		volume *= extent;
		size[a] = int(extent);
	}
	ioGraph.mSize = size;
	ioGraph.mGrid.resize(size_t(volume));
	for (unsigned id = 1; id < ioGraph.mNodes.size(); ++id)
		if (ioGraph.mNodes[id].mLive)
		{
			const auto	  &p = ioGraph.mNodes[id].mPosition;
			const unsigned slot = unsigned(p[0] - ioGraph.mLower[0]) + unsigned(size[0]) *
																		   (unsigned(p[1] - ioGraph.mLower[1]) + unsigned(size[1]) * unsigned(p[2] - ioGraph.mLower[2]));
			ioGraph.mGrid[slot] = id;
		}
	const unsigned axes[6] = {2, 2, 0, 0, 1, 1};
	const unsigned stride[3] = {1, unsigned(size[0]), unsigned(size[0] * size[1])};
	for (unsigned slot = 0; slot < ioGraph.mGrid.size(); ++slot)
	{
		const auto id = ioGraph.mGrid[slot];
		if (!id)
			continue;
		auto &node = ioGraph.mNodes[id];
		node.mEntries = {};
		node.mComponents.clear();
		uint64_t masks = 0;
		for (unsigned face = 0; face < 6; ++face)
		{
			if (node.mBoundary[face].empty())
				node.mEntries[face] = uint64_t(1) << node.mExits[face];
			else
				for (const auto cell : node.mBoundary[face])
					node.mEntries[face] |= uint64_t(1) << (cell == 64 ? 0 : cell);
			masks |= node.mEntries[face];
		}
		for (unsigned mask = 1; mask < 64; ++mask)
			if (masks & (uint64_t(1) << mask))
			{
				PortalComponent component;
				component.mMask = uint8_t(mask);
				for (unsigned face = 0; face < 6; ++face)
					if (mask & (1u << face))
					{
						const unsigned a = axes[face];
						const int	   p = node.mPosition[a] - ioGraph.mLower[a];
						const bool	   edge = face & 1 ? p == 0 : p == size[a] - 1;
						const unsigned neighbor = edge ? 0 : ioGraph.mGrid[face & 1 ? slot - stride[a] : slot + stride[a]];
						if (!neighbor)
						{
							component.mTargets[face] = uint64_t(1) << 63;
							continue;
						}
						const auto &from = node.mBoundary[face];
						const auto &other = ioGraph.mNodes[neighbor];
						const auto &to = other.mBoundary[face ^ 1];
						if (from.empty() || to.empty())
						{
							component.mTargets[face] = uint64_t(1) << other.mExits[face ^ 1];
							continue;
						}
						if (from.size() != to.size())
							throw std::runtime_error("Native portal boundary sizes disagree");
						// Keep disconnected air regions separate across a shared face.
						// Equal six-bit component masks may merge, which only adds visibility.
						for (size_t cell = 0; cell < from.size(); ++cell)
							if (from[cell] == mask)
								component.mTargets[face] |= uint64_t(1) << (to[cell] == 64 ? 0 : to[cell]);
					}
				node.mComponents.push_back(component);
			}
	}
}
std::vector<uint8_t> FindReachable(const VisibilityGraph &inGraph, const VisibilityView &inView, unsigned &outVisited)
{
	if (!inGraph.mSpatial || inGraph.mGrid.empty())
	{
		auto seen = FindReachable(inGraph, inView.mRoot, inView.mSeed);
		outVisited = unsigned(std::count(seen.begin(), seen.end(), uint8_t(1)));
		return seen;
	}
	const auto		  &size = inGraph.mSize;
	const unsigned	   strides[3] = {1, unsigned(size[0]), unsigned(size[0] * size[1])};
	constexpr unsigned axes[6] = {2, 2, 0, 0, 1, 1};
	const auto		   local = [&](unsigned slot)
	{
		return Cell{int(slot % size[0]), int(slot / size[0] % size[1]), int(slot / strides[2])};
	};
	const auto index = [&](const Cell &p)
	{
		return unsigned(p[0]) + strides[1] * unsigned(p[1]) + strides[2] * unsigned(p[2]);
	};
	std::vector<uint8_t>  seen(inGraph.mNodes.size()), queued(inGraph.mGrid.size()), entered(inGraph.mGrid.size());
	std::vector<uint64_t> exits(inGraph.mGrid.size()), sent(inGraph.mGrid.size());
	std::vector<unsigned> queue;
	outVisited = 0;
	auto visit = [&](unsigned slot, uint64_t mask)
	{
		if (!entered[slot])
		{
			entered[slot] = 1;
			++outVisited;
		}
		const auto id = inGraph.mGrid[slot];
		if (id)
			seen[id] = 1; // A blocking wall is drawn even when it has no exits.
		const auto combined = exits[slot] | mask;
		if (combined == exits[slot])
			return;
		exits[slot] = combined;
		if (!queued[slot])
		{
			queued[slot] = 1;
			queue.push_back(slot);
		}
	};
	auto enter = [&](unsigned slot, unsigned face)
	{
		const auto id = inGraph.mGrid[slot];
		visit(slot, id ? inGraph.mNodes[id].mEntries[face] : uint64_t(1) << 63);
	};
	bool inside = true;
	Cell camera{};
	for (unsigned a = 0; a < 3; ++a)
	{
		const int64_t p = int64_t(inView.mPortalCell[a]) - inGraph.mLower[a];
		if (p < 0 || p >= size[a])
			inside = false;
		else
			camera[a] = int(p);
	}
	if (inside)
	{
		const auto slot = index(camera);
		if (inGraph.mGrid[slot] != inView.mRoot || inView.mSeed > 63)
			throw std::runtime_error("Native camera section disagrees with spatial root");
		visit(slot, uint64_t(1) << inView.mSeed);
	}
	else
	{
		if (inView.mRoot)
			throw std::runtime_error("Native spatial root outside graph bounds");
		// Every ray from outside a box enters a camera-facing boundary plane.
		// Seed whole planes, not a clamped point, to preserve oblique sightlines.
		for (unsigned face = 0; face < 6; ++face)
		{
			const unsigned a = axes[face], b = (a + 1) % 3, c = (a + 2) % 3;
			const bool	   positive = !(face & 1);
			if (positive ? int64_t(inView.mPortalCell[a]) < int64_t(inGraph.mLower[a]) + size[a]
						 : inView.mPortalCell[a] >= inGraph.mLower[a])
				continue;
			Cell p{};
			p[a] = positive ? size[a] - 1 : 0;
			for (p[b] = 0; p[b] < size[b]; ++p[b])
				for (p[c] = 0; p[c] < size[c]; ++p[c])
					enter(index(p), face);
		}
	}
	for (size_t head = 0; head < queue.size(); ++head)
	{
		const unsigned slot = queue[head];
		queued[slot] = 0;
		const uint64_t pending = exits[slot] & ~sent[slot];
		sent[slot] = exits[slot];
		const auto p = local(slot);
		const auto id = inGraph.mGrid[slot];
		uint64_t   targets[6] = {};
		if (id)
		{
			for (const auto &component : inGraph.mNodes[id].mComponents)
				if (pending & (uint64_t(1) << component.mMask))
					for (unsigned face = 0; face < 6; ++face)
						targets[face] |= component.mTargets[face];
		}
		else if (pending & (uint64_t(1) << 63))
		{
			for (auto &target : targets)
				target = uint64_t(1) << 63;
		}
		for (unsigned face = 0; face < 6; ++face)
			if (targets[face])
			{
				const unsigned a = axes[face];
				const int	   absolute = p[a] + inGraph.mLower[a];
				if (face & 1)
				{
					if (absolute > inView.mPortalCell[a] || p[a] == 0)
						continue;
					if (id)
						visit(slot - strides[a], targets[face]);
					else
						enter(slot - strides[a], face ^ 1);
				}
				else
				{
					if (absolute < inView.mPortalCell[a] || p[a] == size[a] - 1)
						continue;
					if (id)
						visit(slot + strides[a], targets[face]);
					else
						enter(slot + strides[a], face ^ 1);
				}
			}
	}
	return seen;
}

} // namespace mcmesh::l2draw
