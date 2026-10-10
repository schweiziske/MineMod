#include "Mesh/WorldMeshInput.h"
#include <algorithm>

namespace mcmesh::world
{
MeshInstances::MeshInstances(std::shared_ptr<const MeshSnapshot> snapshot, Coord chunk, unsigned section,
							 std::unordered_map<uint32_t, MeshRecipe> recipes, bool topology)
	: snapshot_(std::move(snapshot)), recipes_(std::move(recipes)), chunk_(chunk), topology_(topology)
{
	const auto &cfg = snapshot_->world->config;
	section_ = snapshot_->world->chunks.at(chunk)->sections.at(section);
	const int ss = cfg.sectionSize, xy = cfg.chunkSize / ss;
	base_ = {int(section % xy) * ss, int(section / xy % xy) * ss, int(section / (xy * xy)) * ss};
	if (section_)
		for (const auto &state : section_->counts)
		{
			const auto found = recipes_.find(state.first);
			l2::require(found != recipes_.end() || !topology_, "native-only section has an unsupported state");
			if (found != recipes_.end())
			{
				const auto &recipe = found->second;
				l2::require(!recipe.shapeSelector || recipe.shapeSelector == snapshot_->world->catalog->states[state.first].shape->selector,
							"model/world shape selector mismatch");
				quads_ = l2::checkedAdd(quads_, l2::checkedMultiply(recipe.maxQuads, state.second));
			}
		}
	if (section_)
		for (const auto &context : section_->contexts)
		{
			const auto found = recipes_.find(section_->states[context.first]);
			if (found == recipes_.end())
				continue;
			l2::require(!found->second.shapeSelector || found->second.shapeSelector == context.second.shape->selector,
						"model/context shape selector mismatch");
		}
}
size_t MeshInstances::bytes() const
{
	const auto size = snapshot_->world->config.sectionSize;
	return sizeof(*this) + recipes_.size() * (sizeof(MeshRecipe) + 64) + size_t(size * size * size) * (2 * sizeof(l2::Voxel) + 8);
}
void MeshInstances::populate(l2::Input &input, const std::atomic<bool> &cancelled) const
{
	const auto			&cfg = snapshot_->world->config;
	const unsigned		 ss = cfg.sectionSize;
	std::vector<uint8_t> cells;
	if (topology_)
		cells.resize(ss * ss * ss);
	if (section_)
	{
		input.voxels.reserve(section_->count * 2);
		for (unsigned i = 0; i < section_->states.size(); ++i)
		{
			if ((i & 63) == 0 && cancelled)
				return;
			const auto state = section_->states[i];
			if (!state)
				continue;
			const auto found = recipes_.find(state);
			if (found == recipes_.end())
				continue;
			const auto &recipe = found->second;
			if (topology_)
				cells[i] = recipe.blocking ? 64 : 0;
			const int local[3] = {base_.x + int(i % ss), base_.y + int(i / ss % ss),
								  base_.z + int(i / (ss * ss))};
			l2::Voxel voxel;
			voxel.cube = recipe.index;
			voxel.model = recipe.model;
			const int origin[3] = {chunk_.x * cfg.chunkSize, chunk_.y * cfg.chunkSize, chunk_.z * cfg.chunkHeight};
			for (unsigned a = 0; a < 3; ++a)
			{
				voxel.source[a] = origin[a] + local[a];
				voxel.translation[a] = local[a] * cfg.blockSize;
			}
			if (!recipe.fluidOnly)
				input.voxels.push_back(voxel);
			if (recipe.fluidIndex >= 0)
			{
				voxel.cube = unsigned(recipe.fluidIndex);
				voxel.model = false;
				voxel.fluid = true;
				input.voxels.push_back(voxel);
			}
		}
	}
	if (topology_ && !cancelled)
		input.topology = meshTopology(std::move(cells), ss);
}
l2::Topology meshTopology(std::vector<uint8_t> cells, unsigned size)
{
	l2::require(size > 0 && size <= 64 && cells.size() == size_t(size) * size * size, "invalid topology size");
	l2::Topology result;
	const auto	 blocked = std::count(cells.begin(), cells.end(), uint8_t(64));
	if (!blocked)
	{
		result.faces.fill(63);
		result.uniform = 63;
		result.graphOpen = true;
		return result;
	}
	if (size_t(blocked) == cells.size())
	{
		result.uniform = 64;
		return result;
	}
	constexpr int		  off[6][3] = {{0, 0, 1}, {0, 0, -1}, {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}};
	std::vector<unsigned> queue;
	queue.reserve(cells.size());
	for (unsigned start = 0; start < cells.size(); ++start)
	{
		if (cells[start])
			continue;
		queue.clear();
		queue.push_back(start);
		cells[start] = 255;
		uint8_t mask = 0;
		for (size_t head = 0; head < queue.size(); ++head)
		{
			const auto cell = queue[head];
			const int  p[3] = {int(cell % size), int(cell / size % size), int(cell / (size * size))};
			for (unsigned face = 0; face < 6; ++face)
			{
				const int x = p[0] + off[face][0], y = p[1] + off[face][1], z = p[2] + off[face][2];
				if (x < 0 || y < 0 || z < 0 || x >= int(size) || y >= int(size) || z >= int(size))
				{
					mask |= uint8_t(1u << face);
					continue;
				}
				const auto next = unsigned(x) + size * (unsigned(y) + size * unsigned(z));
				if (!cells[next])
				{
					cells[next] = 255;
					queue.push_back(next);
				}
			}
		}
		for (unsigned cell : queue)
			cells[cell] = uint8_t(mask + 128);
		for (unsigned face = 0; face < 6; ++face)
			if (mask & (1u << face))
				result.faces[face] |= mask;
	}
	for (auto &cell : cells)
		if (cell >= 128)
			cell -= 128;
	result.cells = std::move(cells);
	result.graphOpen = std::all_of(result.faces.begin(), result.faces.end(), [](uint8_t v)
								   { return v == 63; });
	return result;
}
} // namespace mcmesh::world
