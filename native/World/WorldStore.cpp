#include "World/WorldStore.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <stdexcept>
#include <unordered_set>

namespace mcmesh::world
{
namespace
{
constexpr int Offsets[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
using Clock = std::chrono::steady_clock;
void require(bool ok, const char *message)
{
	if (!ok)
		throw std::runtime_error(message);
}
void checkCoord(Coord c, const Config &config)
{
	// Leave room for the light domain and mesh halo without signed overflow.
	constexpr int margin = 256;
	for (const auto value : {std::pair<int, int>{c.x, config.chunkSize},
							 {c.y, config.chunkSize},
							 {c.z, config.chunkHeight}})
	{
		const int64_t base = int64_t(value.first) * value.second;
		require(base >= int64_t(std::numeric_limits<int>::min()) + margin && base <= int64_t(std::numeric_limits<int>::max()) - margin,
				"world chunk coordinate exceeds the block-coordinate range");
	}
}
struct Address
{
	unsigned section, cell;
};
Address address(const Config &cfg, unsigned li)
{
	const unsigned cs = cfg.chunkSize, ss = cfg.sectionSize, xy = cs / ss;
	const unsigned x = li % cs, y = li / cs % cs, z = li / (cs * cs);
	return {x / ss + xy * (y / ss + xy * (z / ss)),
			x % ss + ss * (y % ss + ss * (z % ss))};
}
uint32_t stateIn(const Config &cfg, const Chunk &chunk, unsigned li)
{
	const auto	a = address(cfg, li);
	const auto &section = chunk.sections[a.section];
	return section ? section->states[a.cell] : 0;
}
const Profile &profileIn(const Config &cfg, const Catalog &catalog, const Chunk &chunk, unsigned li)
{
	const auto	a = address(cfg, li);
	const auto &section = chunk.sections[a.section];
	if (!section)
		return catalog.states[0];
	const auto context = section->contexts.find(a.cell);
	return context != section->contexts.end() ? context->second : catalog.states[section->states[a.cell]];
}
template <class T>
const T *find(const Grid<std::shared_ptr<const T>> &map, Coord coord)
{
	const auto found = map.find(coord);
	return found == map.end() ? nullptr : found->second.get();
}
std::shared_ptr<const Chunk> editChunk(const Config &cfg, const Catalog &catalog,
									   const Chunk *previous, const Mutation &mutation, uint64_t revision)
{
	auto chunk = previous && mutation.kind == Mutation::Kind::Patch
					 ? std::make_shared<Chunk>(*previous)
					 : std::make_shared<Chunk>(cfg);
	chunk->terrainPresent = mutation.terrainPresent;
	chunk->revision = revision;
	std::unordered_map<unsigned, std::shared_ptr<Section>> dirty;
	std::unordered_set<unsigned>						   columns;
	auto												   writable = [&](Address a) -> Section &
	{
		auto found = dirty.find(a.section);
		if (found == dirty.end())
		{
			const auto &old = chunk->sections[a.section];
			auto		section = old ? std::make_shared<Section>(*old)
									  : std::make_shared<Section>(cfg.sectionSize * cfg.sectionSize * cfg.sectionSize);
			found = dirty.emplace(a.section, std::move(section)).first;
			chunk->sections[a.section] = found->second;
		}
		return *found->second;
	};
	for (const auto &cell : mutation.cells)
	{
		const auto a = address(cfg, cell.index);
		auto	  &section = writable(a);
		const auto old = section.states[a.cell];
		if (old != cell.state)
		{
			const int delta = int(cell.state != 0) - int(old != 0);
			chunk->count = unsigned(int(chunk->count) + delta);
			section.count = unsigned(int(section.count) + delta);
			section.states[a.cell] = cell.state;
			if (old && --section.counts.at(old) == 0)
				section.counts.erase(old);
			if (cell.state)
				++section.counts[cell.state];
			section.contexts.erase(a.cell);
			columns.insert(cell.index % unsigned(cfg.chunkSize * cfg.chunkSize));
		}
	}
	for (const auto &context : mutation.contexts)
	{
		auto	  &section = writable(address(cfg, context.index));
		const auto a = address(cfg, context.index);
		if (context.clear)
			section.contexts.erase(a.cell);
		else
		{
			require(section.states[a.cell] != 0, "lighting context cannot belong to air");
			section.contexts[a.cell] = context.value;
		}
		columns.insert(context.index % unsigned(cfg.chunkSize * cfg.chunkSize));
	}
	for (const auto &entry : dirty)
	{
		if (!entry.second->count && entry.second->contexts.empty())
			chunk->sections[entry.first].reset();
	}
	const unsigned cs2 = cfg.chunkSize * cfg.chunkSize;
	for (unsigned column : columns)
	{
		chunk->columnTops[column] = -1;
		for (int z = cfg.chunkHeight - 1; z >= 0; --z)
		{
			if (profileIn(cfg, catalog, *chunk, column + unsigned(z) * cs2).opacity > 0)
			{
				chunk->columnTops[column] = int16_t(z);
				break;
			}
		}
	}
	require(chunk->terrainPresent || chunk->count == 0, "known-empty record contains terrain");
	chunk->SealMemoryUsage();
	return chunk;
}
void validateMutation(const Config &cfg, const Catalog &catalog, const Mutation &mutation)
{
	checkCoord(mutation.chunk, cfg);
	require(mutation.cells.size() <= cfg.cellCount() && mutation.contexts.size() <= cfg.cellCount(),
			"world mutation exceeds its cell limit");
	std::unordered_set<unsigned> indices;
	for (const auto &cell : mutation.cells)
	{
		require(cell.index < cfg.cellCount() && cell.state < catalog.states.size(), "invalid world state edit");
		require(indices.insert(cell.index).second, "world mutation contains duplicate cells");
	}
	indices.clear();
	for (const auto &context : mutation.contexts)
	{
		require(context.index < cfg.cellCount(), "invalid world context index");
		require(indices.insert(context.index).second, "world mutation contains duplicate contexts");
		if (!context.clear)
			context.value.validate();
	}
}
} // namespace

PreparedBatch prepareReplacements(const Config &config, std::shared_ptr<const Catalog> catalog,
								  uint64_t epoch, const std::vector<Mutation> &batch)
{
	require(catalog != nullptr, "replacement batch requires a catalog");
	require(!config.maxChunks || batch.size() <= config.maxChunks, "replacement batch exceeds its chunk limit");
	PreparedBatch result{epoch, std::move(catalog), {}};
	for (const auto &mutation : batch)
	{
		require(mutation.kind == Mutation::Kind::Replace, "prepared batch must contain replacements");
		require(result.chunks.find(mutation.chunk) == result.chunks.end(), "duplicate prepared chunk");
		validateMutation(config, *result.catalog, mutation);
		result.chunks.emplace(mutation.chunk, editChunk(config, *result.catalog, nullptr, mutation, 0));
	}
	return result;
}
size_t CoordHash::operator()(const Coord &c) const noexcept
{
	uint64_t hash = uint64_t(uint32_t(c.x)) * 0x9e3779b185ebca87ull;
	hash ^= uint64_t(uint32_t(c.y)) * 0xc2b2ae3d27d4eb4full;
	hash ^= uint64_t(uint32_t(c.z)) * 0x165667b19e3779f9ull;
	return size_t(hash ^ (hash >> 32));
}
int floorDiv(int value, int divisor)
{
	const int q = value / divisor, r = value % divisor;
	return q - int(r < 0);
}
void Config::validate() const
{
	require(chunkSize >= 1 && chunkSize <= 64 && chunkHeight >= 1 && chunkHeight <= 64 && sectionSize >= 1 && sectionSize <= 64 && chunkSize % sectionSize == 0 && chunkHeight % sectionSize == 0,
			"invalid world grid dimensions");
	require(std::isfinite(blockSize) && blockSize > 0 && minChunkZ <= maxChunkZ,
			"invalid world scale or vertical bounds");
}
Coord Config::chunkAt(Coord cell) const
{
	return {floorDiv(cell.x, chunkSize), floorDiv(cell.y, chunkSize), floorDiv(cell.z, chunkHeight)};
}
void Config::validateChunk(Coord chunk) const
{
	checkCoord(chunk, *this);
}
unsigned Config::localIndex(Coord cell) const
{
	const auto chunk = chunkAt(cell);
	return unsigned((int64_t(cell.x) - int64_t(chunk.x) * chunkSize) + chunkSize * ((int64_t(cell.y) - int64_t(chunk.y) * chunkSize) + chunkSize * (int64_t(cell.z) - int64_t(chunk.z) * chunkHeight)));
}
Coord Config::cellAt(Coord chunk, unsigned li) const
{
	return {chunk.x * chunkSize + int(li % chunkSize),
			chunk.y * chunkSize + int(li / chunkSize % chunkSize),
			chunk.z * chunkHeight + int(li / (chunkSize * chunkSize))};
}
void Profile::validate() const
{
	require(shape != nullptr, "missing render shape");
	require(shape != nullptr, "missing render shape");
	require(emission <= 15 && opacity <= 15 && skyCost >= 1 && skyCost <= 16,
			"invalid propagation profile");
	require(skyCost == (opacity >= 15 ? 16 : std::max(1, int(opacity))) || (opacity > 2 && opacity < 15 && skyCost == 2), "invalid sky propagation cost");
	require((l2Word & ~uint32_t(0xfff00)) == 0 && std::isfinite(shade) && shade >= 0 && shade <= 1,
			"invalid L2 state properties");
}
void Catalog::validate() const
{
	require(revision != 0 && !states.empty() && states.size() <= 1048576, "invalid world state catalog");
	require(contextual.empty() || contextual.size() == states.size(), "invalid context state map");
	for (auto flag : contextual)
		require(flag <= 1, "invalid context state flag");
	require(contextual.empty() || contextual[0] == 0, "air cannot require a lighting context");
	require(mBlockEntityStates.empty() || mBlockEntityStates.size() == states.size(), "invalid block entity state map");
	for (auto flag : mBlockEntityStates)
		require(flag <= 1, "invalid block entity state flag");
	require(mBlockEntityStates.empty() || mBlockEntityStates[0] == 0, "air cannot own a block entity");
	for (const auto &profile : states)
		profile.validate();
	const auto &air = states[0];
	require(air.emission == 0 && air.opacity == 0 && air.skyCost == 1, "state zero must be non-emitting air");
}
Chunk::Chunk(const Config &config)
	: sections(config.sectionCount()), columnTops(config.chunkSize * config.chunkSize, -1)
{
	SealMemoryUsage();
}
void Chunk::SealMemoryUsage()
{
	l2::MemoryUsage usage;
	std::unordered_set<const l2::Shape *> shapes;
	for (const auto &section : sections)
	{
		if (!section)
			continue;
		usage.share(section, sizeof(Section) + section->states.capacity() * sizeof(uint32_t) +
			section->counts.size() * 64 + section->counts.bucket_count() * sizeof(void *) +
			section->contexts.size() * (sizeof(Profile) + 64) + section->contexts.bucket_count() * sizeof(void *));
		for (const auto &context : section->contexts)
		{
			const auto &shape = context.second.shape;
			if (shapes.insert(shape.get()).second)
				usage.share(shape, shape->bytes());
		}
	}
	usage.normalize();
	usage.owned = sizeof(Chunk) + sections.capacity() * sizeof(std::shared_ptr<const Section>) +
		columnTops.capacity() * sizeof(int16_t) + usage.shared.capacity() * sizeof(l2::SharedAllocation);
	usage.total(); // Keep admission arithmetic checked at the sealing boundary.
	mMemoryUsage = std::move(usage);
}
bool Snapshot::known(Coord chunk) const
{
	return chunks.find(chunk) != chunks.end() || !config.streaming || chunk.z < config.minChunkZ || chunk.z > config.maxChunkZ;
}
uint32_t Snapshot::state(Coord cell) const
{
	const auto *chunk = find(chunks, config.chunkAt(cell));
	return chunk ? stateIn(config, *chunk, config.localIndex(cell)) : 0;
}
const Profile &Snapshot::profile(Coord cell) const
{
	const auto *chunk = find(chunks, config.chunkAt(cell));
	return chunk ? profileIn(config, *catalog, *chunk, config.localIndex(cell)) : catalog->states[0];
}

std::unique_ptr<LightResult> rebuildLight(std::shared_ptr<const Snapshot> source,
										  const std::atomic<bool>		 &cancelled)
{
	require(source && source->catalog, "light build needs a world snapshot");
	const auto	started = Clock::now();
	const auto &cfg = source->config;
	auto		result = std::make_unique<LightResult>();
	result->source = source;
	// Summaries are maintained during mutation. The worker groups chunk roots by
	// XY column and resolves exposure thresholds only for the columns a target or
	// boundary sample reads, never hashing every block column of the world.
	const int							 cs = cfg.chunkSize;
	const unsigned						 cs2 = unsigned(cs * cs);
	Grid<std::vector<std::pair<int, const Chunk *>>> xyChunks;
	std::unordered_set<Coord, CoordHash> domain;
	const int							 xyHalo = (16 + cfg.chunkSize - 1) / cfg.chunkSize;
	const int							 zHalo = (16 + cfg.chunkHeight - 1) / cfg.chunkHeight;
	for (const auto &entry : source->chunks)
	{
		if (cancelled.load(std::memory_order_relaxed))
			return nullptr;
		const auto	cc = entry.first;
		const auto &chunk = *entry.second;
		xyChunks[{cc.x, cc.y, 0}].emplace_back(cc.z, &chunk);
		if (!chunk.terrainPresent)
			continue;
		for (int dz = -zHalo; dz <= zHalo; ++dz)
			for (int dy = -xyHalo; dy <= xyHalo; ++dy)
				for (int dx = -xyHalo; dx <= xyHalo; ++dx)
				{
					Coord key{cc.x + dx, cc.y + dy, cc.z + dz};
					if (source->known(key))
						domain.insert(key);
					require(!cfg.maxLightChunks || domain.size() <= cfg.maxLightChunks, "native light domain exceeds its chunk limit");
				}
	}
	// Absolute exposure threshold of every block column in one XY chunk column;
	// INT_MIN marks a column without any opacity>0 cell (fully exposed).
	Grid<std::vector<int>> topCache;
	auto				   chunkColumnTops = [&](int cx, int cy) -> const std::vector<int> &
	{
		const Coord key{cx, cy, 0};
		const auto	found = topCache.find(key);
		if (found != topCache.end())
			return found->second;
		std::vector<int> tops(cs2, std::numeric_limits<int>::min());
		const auto		 members = xyChunks.find(key);
		if (members != xyChunks.end())
			for (const auto &member : members->second)
				for (unsigned column = 0; column < cs2; ++column)
				{
					const int top = member.second->columnTops[column];
					if (top >= 0)
						tops[column] = std::max(tops[column], member.first * cfg.chunkHeight + top);
				}
		return topCache.emplace(key, std::move(tops)).first->second;
	};
	struct WorkChunk
	{
		Coord				  coord;
		std::vector<uint8_t>  values, blockCost, skyCost;
		std::array<size_t, 6> neighbors;
	};
	std::vector<WorkChunk> chunks;
	require(!cfg.maxLightBytes || domain.size() <= cfg.maxLightBytes / cfg.cellCount(),
			"native persistent lighting exceeds its memory budget");
	Grid<size_t> byKey;
	for (const auto &coord : domain)
	{
		if (source->light.find(coord) != source->light.end() && source->invalidLight.find(coord) == source->invalidLight.end())
			continue;
		require(!cfg.maxLightBytes || (source->light.size() + (chunks.size() + 1) * 3) <= cfg.maxLightBytes / cfg.cellCount(),
				"native lighting work exceeds its memory budget");
		result->targets.emplace(coord, true);
		byKey.emplace(coord, chunks.size());
		WorkChunk chunk;
		chunk.coord = coord;
		chunk.values.resize(cfg.cellCount());
		chunk.blockCost.resize(cfg.cellCount());
		chunk.skyCost.resize(cfg.cellCount());
		chunks.push_back(std::move(chunk));
	}
	for (const auto &entry : source->light)
	{
		if (domain.find(entry.first) == domain.end())
			result->targets.emplace(entry.first, true);
	}
	// Includes existing immutable values and worker arrays. Queue capacity is
	// checked separately as propagation discovers work.
	const size_t fixedBytes = l2::checkedMultiply(l2::checkedAdd(source->light.size(),
																 l2::checkedMultiply(chunks.size(), 3)),
												  cfg.cellCount());
	require(!cfg.maxLightBytes || fixedBytes <= cfg.maxLightBytes, "native lighting work exceeds its memory budget");
	constexpr size_t Missing = std::numeric_limits<size_t>::max();
	// Eight-byte nodes in a compacting vector FIFO. MSVC's std::deque keeps one
	// element of the former 16-byte node per block, an allocation per enqueue.
	struct Node
	{
		uint32_t chunk;
		uint32_t cellLevel; // cell << 4 | level
	};
	struct Queue
	{
		std::vector<Node> nodes;
		size_t			  head = 0;
		bool			  empty() const { return head == nodes.size(); }
		Node			  pop()
		{
			const Node node = nodes[head++];
			if (head == nodes.size())
				nodes.clear(), head = 0;
			else if (head >= 4096 && head * 2 >= nodes.size())
			{
				nodes.erase(nodes.begin(), nodes.begin() + std::ptrdiff_t(head));
				head = 0;
			}
			return node;
		}
	};
	Queue blockQueue, skyQueue;
	auto  enqueue = [&](Queue &queue, size_t chunk, unsigned cell, unsigned level)
	{
		// Vector slack can double the live footprint; budget for it.
		require(!cfg.maxLightBytes || (blockQueue.nodes.size() + skyQueue.nodes.size() + 1) * 2 * sizeof(Node) <= cfg.maxLightBytes - fixedBytes,
				"native lighting queue exceeds its memory budget");
		queue.nodes.push_back({uint32_t(chunk), (cell << 4) | level});
	};
	// Chunk-local address tables replace per-cell runtime-divisor arithmetic.
	const int			  ss = cfg.sectionSize, sectionsXY = cfg.chunkSize / ss, ch = cfg.chunkHeight;
	std::vector<unsigned> sectionX(cs), cellX(cs), sectionZ(ch), cellZ(ch);
	for (int i = 0; i < cs; ++i)
	{
		sectionX[i] = unsigned(i / ss);
		cellX[i] = unsigned(i % ss);
	}
	for (int i = 0; i < ch; ++i)
	{
		sectionZ[i] = unsigned(i / ss);
		cellZ[i] = unsigned(i % ss);
	}
	const auto &air = source->catalog->states[0];
	// Boundary seeding reads only the six face neighbours of a target. Resolve
	// their roots once instead of hashing every boundary cell and face.
	struct FaceNeighbour
	{
		const LightChunk *old = nullptr;
		bool			  target = false, known = false;
	};
	for (size_t ci = 0; ci < chunks.size(); ++ci)
	{
		if (cancelled.load(std::memory_order_relaxed))
			return nullptr;
		auto					   &chunk = chunks[ci];
		const auto					cc = chunk.coord;
		std::array<bool, 6>			knownNeighbors;
		std::array<FaceNeighbour, 6> faces;
		for (int f = 0; f < 6; ++f)
		{
			const Coord key{cc.x + Offsets[f][0], cc.y + Offsets[f][1], cc.z + Offsets[f][2]};
			const auto	found = byKey.find(key);
			chunk.neighbors[f] = found == byKey.end() ? Missing : found->second;
			knownNeighbors[f] = source->known(key);
			auto &face = faces[f];
			face.target = chunk.neighbors[f] != Missing;
			face.known = knownNeighbors[f];
			// Same rule as an old-light read: only a valid in-domain light root
			// supplies boundary values; otherwise implicit exposure applies.
			if (face.known && !face.target && source->invalidLight.find(key) == source->invalidLight.end() &&
				domain.find(key) != domain.end())
				face.old = find(source->light, key);
		}
		// Exposure is a column threshold. Resolve the horizontal halo once, not
		// through world/hash lookups for every cell and each of its six faces.
		const unsigned			 stride = unsigned(cfg.chunkSize + 2);
		std::array<int, 66 * 66> columnTops;
		const std::vector<int>	*ring[3][3];
		for (int dy = -1; dy <= 1; ++dy)
			for (int dx = -1; dx <= 1; ++dx)
				ring[dy + 1][dx + 1] = &chunkColumnTops(cc.x + dx, cc.y + dy);
		for (int y = -1; y <= cfg.chunkSize; ++y)
			for (int x = -1; x <= cfg.chunkSize; ++x)
			{
				const int ix = x < 0 ? 0 : x >= cs ? 2 : 1, iy = y < 0 ? 0 : y >= cs ? 2 : 1;
				const int lx = x < 0 ? cs - 1 : x >= cs ? 0 : x, ly = y < 0 ? cs - 1 : y >= cs ? 0 : y;
				columnTops[unsigned(x + 1) + stride * unsigned(y + 1)] = (*ring[iy][ix])[unsigned(lx) + unsigned(cs) * unsigned(ly)];
			}
		const Chunk *states = find(source->chunks, cc);
		unsigned	 li = 0;
		for (unsigned z = 0; z < unsigned(ch); ++z)
			for (unsigned y = 0; y < unsigned(cs); ++y)
				for (unsigned x = 0; x < unsigned(cs); ++x, ++li)
				{
					++result->scannedCells;
					const Profile *profile = &air;
					if (states)
					{
						const auto &section = states->sections[sectionX[x] + sectionsXY * (sectionX[y] + sectionsXY * sectionZ[z])];
						if (section)
						{
							const unsigned cell = cellX[x] + unsigned(ss) * (cellX[y] + unsigned(ss) * cellZ[z]);
							profile = &source->catalog->states[section->states[cell]];
							if (!section->contexts.empty())
							{
								const auto context = section->contexts.find(cell);
								if (context != section->contexts.end())
									profile = &context->second;
							}
						}
					}
					const auto &p = *profile;
					chunk.values[li] = p.emission;
					chunk.blockCost[li] = uint8_t(p.opacity >= 15 ? 16 : std::max(1, int(p.opacity)));
					chunk.skyCost[li] = p.skyCost;
					if (p.emission)
					{
						enqueue(blockQueue, ci, li, p.emission);
						++result->sources;
					}
					const int	   pz = cc.z * cfg.chunkHeight + int(z);
					const unsigned column = x + 1 + stride * (y + 1);
					const int	   top = columnTops[column];
					if (!cfg.skyEnabled || pz > top)
					{
						chunk.values[li] |= 0xf0;
					}
					else if (p.skyCost < 15)
					{
						// Seed from all exposed neighbors, including the cell just above a
						// water/leaf column top and known sparse air outside this domain.
						if (((x + 1 < unsigned(cfg.chunkSize) || knownNeighbors[0]) && pz > columnTops[column + 1]) || ((x > 0 || knownNeighbors[1]) && pz > columnTops[column - 1]) || ((y + 1 < unsigned(cfg.chunkSize) || knownNeighbors[2]) && pz > columnTops[column + stride]) || ((y > 0 || knownNeighbors[3]) && pz > columnTops[column - stride]) || ((z + 1 < unsigned(cfg.chunkHeight) || knownNeighbors[4]) && pz + 1 > top) || ((z > 0 || knownNeighbors[5]) && pz - 1 > top))
						{
							const auto level = uint8_t(15 - p.skyCost);
							chunk.values[li] |= uint8_t(level << 4);
							enqueue(skyQueue, ci, li, level);
							++result->sources;
						}
					}
					// Unchanged chunks supply boundary light for incremental reflood.
					// Invalid chunks always belong to this build, so their old light
					// cannot seed a removed emitter or an opened/closed sky column.
					if (x == 0 || y == 0 || z == 0 || x + 1 == unsigned(cfg.chunkSize) || y + 1 == unsigned(cfg.chunkSize) || z + 1 == unsigned(cfg.chunkHeight))
					{
						unsigned block = chunk.values[li] & 15, sky = chunk.values[li] >> 4;
						for (unsigned f = 0; f < 6; ++f)
						{
							// A face offset leaves this chunk only on the matching boundary.
							unsigned nx = x, ny = y, nz = z, neighbourColumn = column;
							bool	 leaves = false;
							switch (f)
							{
							case 0:
								leaves = x + 1 == unsigned(cs), nx = 0, neighbourColumn = column + 1;
								break;
							case 1:
								leaves = x == 0, nx = unsigned(cs - 1), neighbourColumn = column - 1;
								break;
							case 2:
								leaves = y + 1 == unsigned(cs), ny = 0, neighbourColumn = column + stride;
								break;
							case 3:
								leaves = y == 0, ny = unsigned(cs - 1), neighbourColumn = column - stride;
								break;
							case 4:
								leaves = z + 1 == unsigned(ch), nz = 0;
								break;
							default:
								leaves = z == 0, nz = unsigned(ch - 1);
								break;
							}
							const auto &face = faces[f];
							if (!leaves || face.target)
								continue;
							unsigned previousBlock = 0, previousSky = 0;
							if (face.known)
							{
								if (face.old)
								{
									const auto value = face.old->values[nx + unsigned(cs) * (ny + unsigned(cs) * nz)];
									previousBlock = value & 15;
									previousSky = value >> 4;
								}
								else if (!cfg.skyEnabled || pz + Offsets[f][2] > columnTops[neighbourColumn])
									previousSky = 15;
							}
							const int b = int(previousBlock) - chunk.blockCost[li];
							const int s = int(previousSky) - chunk.skyCost[li];
							if (b > int(block))
								block = unsigned(b);
							if (s > int(sky))
								sky = unsigned(s);
						}
						if (block > unsigned(chunk.values[li] & 15))
							enqueue(blockQueue, ci, li, block);
						if (sky > unsigned(chunk.values[li] >> 4))
							enqueue(skyQueue, ci, li, sky);
						chunk.values[li] = uint8_t(block | (sky << 4));
					}
				}
	}
	const unsigned fcs = unsigned(cfg.chunkSize), fcs2 = fcs * fcs;
	auto		   flood = [&](Queue &queue, bool sky)
	{
		while (!queue.empty())
		{
			if ((result->visits & 1023) == 0 && cancelled.load(std::memory_order_relaxed))
				return false;
			const Node node = queue.pop();
			++result->visits;
			const unsigned cell = node.cellLevel >> 4, level = node.cellLevel & 15;
			const auto	  &chunk = chunks[node.chunk];
			const unsigned current = sky ? chunk.values[cell] >> 4 : chunk.values[cell] & 15;
			if (current != level || current <= 1)
				continue;
			const int x = cell % fcs, y = cell / fcs % fcs, z = cell / fcs2;
			for (int f = 0; f < 6; ++f)
			{
				int	   nx = x + Offsets[f][0], ny = y + Offsets[f][1], nz = z + Offsets[f][2];
				size_t target = node.chunk;
				if (nx < 0 || nx >= cfg.chunkSize || ny < 0 || ny >= cfg.chunkSize || nz < 0 || nz >= cfg.chunkHeight)
				{
					target = chunk.neighbors[f];
					if (target == Missing)
						continue;
					if (nx < 0)
						nx += cfg.chunkSize;
					else if (nx >= cfg.chunkSize)
						nx -= cfg.chunkSize;
					if (ny < 0)
						ny += cfg.chunkSize;
					else if (ny >= cfg.chunkSize)
						ny -= cfg.chunkSize;
					if (nz < 0)
						nz += cfg.chunkHeight;
					else if (nz >= cfg.chunkHeight)
						nz -= cfg.chunkHeight;
				}
				auto		  &destination = chunks[target];
				const unsigned li = unsigned(nx) + fcs * (unsigned(ny) + fcs * unsigned(nz));
				const int	   next = int(current) - (sky ? destination.skyCost[li] : destination.blockCost[li]);
				const unsigned old = sky ? destination.values[li] >> 4 : destination.values[li] & 15;
				if (next <= 0 || int(old) >= next)
					continue;
				auto &value = destination.values[li];
				value = sky ? uint8_t((value & 15) | (next << 4)) : uint8_t((value & 0xf0) | next);
				enqueue(queue, target, li, unsigned(next));
			}
		}
		return true;
	};
	if (!flood(blockQueue, false) || !flood(skyQueue, true))
		return nullptr;
	for (auto &chunk : chunks)
	{
		auto value = std::make_shared<LightChunk>();
		value->values = std::move(chunk.values);
		result->chunks.emplace(chunk.coord, std::move(value));
	}
	const auto	 diffStarted = Clock::now();
	const size_t deltaBytes = sizeof(LightDelta) + (cfg.cellCount() + 7) / 8;
	// Reserve a conservative bound for halo masks, hash nodes and vector growth
	// before allocating them. Worker result metadata shares the lighting budget.
	const size_t xyOwners = 1 + 2 * ((2 + cfg.chunkSize - 1) / cfg.chunkSize);
	const size_t zOwners = 1 + 2 * ((2 + cfg.chunkHeight - 1) / cfg.chunkHeight);
	const size_t ownerBytes = xyOwners * xyOwners * zOwners * (160 + size_t(cfg.sectionCount()) * (1 + 2 * sizeof(unsigned)));
	size_t		 diffBytes = fixedBytes;
	for (const auto &target : result->targets)
	{
		if (cancelled.load(std::memory_order_relaxed))
			return nullptr;
		require(!cfg.maxLightBytes || deltaBytes <= cfg.maxLightBytes - diffBytes,
				"native lighting delta exceeds its memory budget");
		const auto *old = find(source->light, target.first);
		const auto *value = find(result->chunks, target.first);
		auto		delta = std::make_shared<LightDelta>();
		delta->chunk = target.first;
		const unsigned cells = cfg.cellCount();
		delta->changedBits.resize((cells + 7) / 8);
		bool changed = false;
		if (!old || !value)
		{
			// A created or removed root changes every cell.
			std::fill(delta->changedBits.begin(), delta->changedBits.end(), uint8_t(0xff));
			if (cells % 8)
				delta->changedBits.back() = uint8_t((1u << (cells % 8)) - 1);
			changed = true;
		}
		else
		{
			// Compare eight cells per step; only differing blocks are expanded.
			const uint8_t *before = old->values.data(), *after = value->values.data();
			unsigned	   li = 0;
			for (; li + 8 <= cells; li += 8)
			{
				uint64_t a, b;
				std::memcpy(&a, before + li, sizeof(a));
				std::memcpy(&b, after + li, sizeof(b));
				if (a == b)
					continue;
				for (unsigned k = li; k < li + 8; ++k)
					if (before[k] != after[k])
						delta->changedBits[k / 8] |= uint8_t(1u << (k % 8));
				changed = true;
			}
			for (; li < cells; ++li)
				if (before[li] != after[li])
				{
					delta->changedBits[li / 8] |= uint8_t(1u << (li % 8));
					changed = true;
				}
		}
		if (changed)
		{
			require(!cfg.maxLightBytes || ownerBytes <= cfg.maxLightBytes - diffBytes - deltaBytes,
					"native lighting section masks exceed their memory budget");
			diffBytes = l2::checkedAdd(diffBytes, deltaBytes + ownerBytes);
			delta->sections = affectedLightSections(cfg, {delta});
			result->deltas.emplace(target.first, std::move(delta));
		}
	}
	result->diffMS = std::chrono::duration<double, std::milli>(Clock::now() - diffStarted).count();
	result->computeMS = std::chrono::duration<double, std::milli>(Clock::now() - started).count();
	return result;
}

Store::Store(Config config, std::shared_ptr<const Catalog> catalog) : config_(config), catalog_(std::move(catalog))
{
	config_.validate();
	require(catalog_ != nullptr, "world requires a catalog");
	catalog_->validate();
	// The caller cannot mutate the sealed catalog through its original pointer.
	catalog_ = std::make_shared<const Catalog>(*catalog_);
}
void Store::reset(Config config, std::shared_ptr<const Catalog> catalog)
{
	config.validate();
	require(catalog != nullptr, "world reset requires a catalog");
	// Reusing this Store's own sealed catalog needs neither validation nor a copy.
	std::shared_ptr<const Catalog> sealed = catalog == catalog_ ? std::move(catalog) : nullptr;
	if (!sealed)
	{
		catalog->validate();
		sealed = std::make_shared<const Catalog>(*catalog);
	}
	config_ = config;
	catalog_ = std::move(sealed);
	chunks_.clear();
	columns_.clear();
	light_.clear();
	lightColumns_.clear();
	invalidLight_.clear();
	mLightChanges.clear();
	mLightChangeBase = 0;
	++epoch_;
	revision_ = 0;
}
void Store::reconfigure(Config config)
{
	config.validate();
	require(config.chunkSize == config_.chunkSize && config.chunkHeight == config_.chunkHeight && config.sectionSize == config_.sectionSize && config.blockSize == config_.blockSize,
			"world geometry configuration requires an ownership transfer");
	require(!config.maxChunks || chunks_.size() <= config.maxChunks, "new world chunk limit is too small");
	config_ = config;
	light_.clear();
	lightColumns_.clear();
	invalidLight_.clear();
	mLightChanges.clear();
	mLightChangeBase = revision_;
	++epoch_;
}
std::shared_ptr<const Snapshot> Store::snapshot() const
{
	auto result = std::make_shared<Snapshot>();
	result->config = config_;
	result->epoch = epoch_;
	result->revision = revision_;
	result->catalog = catalog_;
	result->chunks = chunks_;
	result->light = light_;
	result->invalidLight = invalidLight_;
	return result;
}
uint32_t Store::state(Coord cell) const
{
	const auto *chunk = find(chunks_, config_.chunkAt(cell));
	return chunk ? stateIn(config_, *chunk, config_.localIndex(cell)) : 0;
}
bool Store::known(Coord chunk) const
{
	return chunks_.find(chunk) != chunks_.end() || !config_.streaming || chunk.z < config_.minChunkZ || chunk.z > config_.maxChunkZ;
}
bool Store::apply(uint64_t expectedRevision, const std::vector<Mutation> &batch)
{
	if (expectedRevision != revision_)
		return false;
	// A replacement transaction can unload a full world and insert another one.
	// publish() checks the final population; this bounds the staging work only.
	require(!config_.maxChunks || batch.size() / 2 + batch.size() % 2 <= config_.maxChunks,
			"world batch exceeds its chunk limit");
	Grid<std::shared_ptr<const Chunk>> pending;
	for (const auto &mutation : batch)
	{
		validateMutation(config_, *catalog_, mutation);
		require(pending.find(mutation.chunk) == pending.end(), "world batch contains duplicate chunks");
		const auto *previous = find(chunks_, mutation.chunk);
		if (mutation.kind == Mutation::Kind::Unload)
		{
			require(mutation.cells.empty() && mutation.contexts.empty(), "unload mutation contains cells");
			pending.emplace(mutation.chunk, nullptr);
		}
		else
		{
			require(mutation.kind == Mutation::Kind::Replace || mutation.kind == Mutation::Kind::Patch,
					"unknown world mutation kind");
			pending.emplace(mutation.chunk, editChunk(config_, *catalog_, previous, mutation, revision_ + 1));
		}
	}
	return publish(std::move(pending));
}
bool Store::applyPrepared(uint64_t expectedRevision, const PreparedBatch &batch, const std::vector<Mutation> &contexts)
{
	if (expectedRevision != revision_ || batch.epoch != epoch_ || batch.catalog != catalog_)
		return false;
	auto	   pending = batch.chunks;
	Grid<bool> seen;
	for (const auto &mutation : contexts)
	{
		require(mutation.kind == Mutation::Kind::Patch && mutation.cells.empty(), "invalid prepared context overlay");
		require(seen.emplace(mutation.chunk, true).second, "duplicate prepared context chunk");
		const auto found = pending.find(mutation.chunk);
		require(found != pending.end() && found->second, "context overlay has no prepared chunk");
		validateMutation(config_, *catalog_, mutation);
		found->second = editChunk(config_, *catalog_, found->second.get(), mutation, revision_ + 1);
	}
	return publish(std::move(pending));
}
bool Store::publish(Grid<std::shared_ptr<const Chunk>> pending)
{
	auto finalSize = chunks_.size(), additions = size_t(0);
	for (const auto &entry : pending)
	{
		const bool exists = chunks_.find(entry.first) != chunks_.end();
		if (entry.second && !exists)
		{
			++finalSize;
			++additions;
		}
		else if (!entry.second && exists)
			--finalSize;
	}
	require(!config_.maxChunks || finalSize <= config_.maxChunks, "native world exceeds its chunk limit");
	if (pending.empty())
		return true;
	Grid<std::shared_ptr<Column>> columns;
	for (const auto &entry : pending)
	{
		const Coord key{entry.first.x, entry.first.y, 0};
		auto		found = columns.find(key);
		if (found == columns.end())
		{
			const auto previous = columns_.find(key);
			auto	   column = previous == columns_.end() ? std::make_shared<Column>()
														   : std::make_shared<Column>(*previous->second);
			found = columns.emplace(key, std::move(column)).first;
		}
		if (entry.second)
			(*found->second)[entry.first.z] = entry.second;
		else
			found->second->erase(entry.first.z);
	}
	Grid<std::shared_ptr<const Column>> sealedColumns;
	for (auto &entry : columns)
		sealedColumns.emplace(entry.first, std::move(entry.second));
	// Sky exposure is the highest opacity>0 cell of each block column across the
	// whole XY chunk column. Only a change of that merged threshold can alter
	// light down an entire column; everything else is a bounded 15-level flood.
	const unsigned cs2 = unsigned(config_.chunkSize * config_.chunkSize);
	auto		   mergedTops = [&](const Column *inColumn, std::vector<int> &outTops)
	{
		outTops.assign(cs2, std::numeric_limits<int>::min());
		if (!inColumn)
			return;
		for (const auto &entry : *inColumn)
			for (unsigned c = 0; c < cs2; ++c)
			{
				const int top = entry.second->columnTops[c];
				if (top >= 0)
					outTops[c] = std::max(outTops[c], entry.first * config_.chunkHeight + top);
			}
	};
	Grid<bool>		 exposureChanged;
	std::vector<int> topsBefore, topsAfter;
	for (const auto &entry : sealedColumns)
	{
		const auto previous = columns_.find(entry.first);
		mergedTops(previous == columns_.end() ? nullptr : previous->second.get(), topsBefore);
		mergedTops(entry.second.get(), topsAfter);
		exposureChanged.emplace(entry.first, topsBefore != topsAfter);
	}
	// Prepare invalidation too, so allocation failure cannot publish half a batch.
	auto	  invalid = invalidLight_;
	const int radius = (16 + config_.chunkSize - 1) / config_.chunkSize;
	const int zRadius = (16 + config_.chunkHeight - 1) / config_.chunkHeight;
	mLightChanges.reserve(mLightChanges.size() + pending.size());
	std::vector<LightChange> changes;
	changes.reserve(pending.size());
	for (const auto &entry : pending)
	{
		const auto *after = entry.second.get();
		// Removal can lower the exposure threshold and also changes the known
		// domain, so it stays whole-column. Arrival and edits flood a bounded
		// halo unless they move the merged exposure threshold.
		const bool wholeColumn = !after || exposureChanged.at({entry.first.x, entry.first.y, 0});
		changes.push_back({revision_ + 1, entry.first, wholeColumn});
		invalid[entry.first] = true;
		for (int y = -radius; y <= radius; ++y)
			for (int x = -radius; x <= radius; ++x)
			{
				const Coord key{entry.first.x + x, entry.first.y + y, 0};
				const auto	column = lightColumns_.find(key);
				if (column == lightColumns_.end())
					continue;
				const auto &levels = *column->second;
				auto		begin = wholeColumn ? levels.begin() : levels.lower_bound(entry.first.z - zRadius);
				const auto	end = wholeColumn ? levels.end() : levels.upper_bound(entry.first.z + zRadius);
				for (; begin != end; ++begin)
					invalid[{key.x, key.y, *begin}] = true;
			}
	}
	// All allocations precede publication. Transfer preallocated nodes instead
	// of copying the entire world root on every single-cell edit.
	// Pending iteration can insert before erasing; reserve the transient peak.
	chunks_.reserve(chunks_.size() + additions);
	columns_.reserve(columns_.size() + sealedColumns.size());
	while (!sealedColumns.empty())
	{
		auto	   node = sealedColumns.extract(sealedColumns.begin());
		const auto old = columns_.find(node.key());
		if (node.mapped()->empty())
		{
			if (old != columns_.end())
				columns_.erase(old);
		}
		else if (old != columns_.end())
			old->second = std::move(node.mapped());
		else
			columns_.insert(std::move(node));
	}
	while (!pending.empty())
	{
		auto	   node = pending.extract(pending.begin());
		const auto old = chunks_.find(node.key());
		if (!node.mapped())
		{
			if (old != chunks_.end())
				chunks_.erase(old);
		}
		else if (old != chunks_.end())
		{
			old->second = std::move(node.mapped());
		}
		else
			chunks_.insert(std::move(node));
	}
	invalidLight_.swap(invalid);
	// Capacity was reserved above; appending cannot fail after publication.
	mLightChanges.insert(mLightChanges.end(), changes.begin(), changes.end());
	// Without light commits the log would grow with every edit. Commits whose
	// snapshot predates the retained log fall back to root comparison.
	constexpr size_t cMaxLightChanges = size_t(1) << 16;
	if (mLightChanges.size() > cMaxLightChanges)
	{
		const size_t dropped = mLightChanges.size() / 2;
		mLightChangeBase = std::max(mLightChangeBase, mLightChanges[dropped - 1].mRevision);
		mLightChanges.erase(mLightChanges.begin(), mLightChanges.begin() + std::ptrdiff_t(dropped));
	}
	++revision_;
	return true;
}
CommitResult Store::commit(const LightResult &result)
{
	CommitResult out;
	require(result.source != nullptr, "light result has no source");
	if (result.source->epoch != epoch_ || result.source->catalog != catalog_)
	{
		out.stale = true;
		return out;
	}
	Grid<bool> conflicts, conflictCells;
	const int  radius = (16 + config_.chunkSize - 1) / config_.chunkSize;
	const int  zRadius = (16 + config_.chunkHeight - 1) / config_.chunkHeight;
	auto	   changed = [&](Coord coord)
	{
		for (int y = -radius; y <= radius; ++y)
			for (int x = -radius; x <= radius; ++x)
				conflicts[{coord.x + x, coord.y + y, 0}] = true;
	};
	const uint64_t since = result.source->revision;
	if (since != revision_)
	{
		if (since >= mLightChangeBase)
		{
			// A later change conflicts exactly with the light roots its own
			// invalidation covers, including targets that had no root yet.
			for (const auto &change : mLightChanges)
			{
				if (change.mRevision <= since)
					continue;
				if (change.mWholeColumn)
				{
					changed(change.mChunk);
					continue;
				}
				for (int z = -zRadius; z <= zRadius; ++z)
					for (int y = -radius; y <= radius; ++y)
						for (int x = -radius; x <= radius; ++x)
							conflictCells[{change.mChunk.x + x, change.mChunk.y + y, change.mChunk.z + z}] = true;
			}
		}
		else
		{
			// The change log no longer covers this snapshot: compare chunk roots.
			for (const auto &entry : result.source->chunks)
				if (find(chunks_, entry.first) != entry.second.get())
					changed(entry.first);
			for (const auto &entry : chunks_)
				if (result.source->chunks.find(entry.first) == result.source->chunks.end())
					changed(entry.first);
		}
	}
	auto conflict = [&](Coord coord)
	{
		return conflicts.find({coord.x, coord.y, 0}) != conflicts.end() || conflictCells.find(coord) != conflictCells.end();
	};
	Grid<std::shared_ptr<const LightChunk>> pending;
	Grid<std::set<int>>						columns;
	Grid<std::vector<uint8_t>>				owners;
	std::vector<Coord>						accepted;
	Grid<bool>								deferred;
	size_t									additions = 0;
	for (const auto &target : result.targets)
	{
		const auto coord = target.first;
		// Worker deltas are relative to their exact light baseline, not merely
		// terrain revisions. Reject a late result after another light commit.
		if (conflict(coord) || find(light_, coord) != find(result.source->light, coord))
		{
			deferred[coord] = true;
			++out.deferred;
			continue;
		}
		const auto delta = result.deltas.find(coord);
		if (delta != result.deltas.end())
		{
			out.changed.push_back(delta->second);
			for (const auto &owner : delta->second->sections)
			{
				auto &bits = owners[owner.first];
				if (bits.empty())
					bits.resize(config_.sectionCount());
				for (unsigned section : owner.second)
					bits[section] = 1;
			}
			const auto found = result.chunks.find(coord);
			const bool exists = light_.find(coord) != light_.end(), present = found != result.chunks.end();
			pending.emplace(coord, present ? found->second : nullptr);
			if (exists != present)
			{
				const Coord key{coord.x, coord.y, 0};
				auto		inserted = columns.try_emplace(key);
				if (inserted.second)
				{
					const auto old = lightColumns_.find(key);
					if (old != lightColumns_.end())
						inserted.first->second = *old->second;
				}
				if (present)
				{
					inserted.first->second.insert(coord.z);
					++additions;
				}
				else
					inserted.first->second.erase(coord.z);
			}
		}
		accepted.push_back(coord);
		++out.committed;
	}
	for (const auto &owner : owners)
	{
		auto &sections = out.dirtySections[owner.first];
		for (unsigned i = 0; i < owner.second.size(); ++i)
			if (owner.second[i])
				sections.push_back(i);
	}
	Grid<std::shared_ptr<const std::set<int>>> sealed;
	for (auto &column : columns)
		sealed.emplace(column.first, std::make_shared<const std::set<int>>(std::move(column.second)));
	// Preallocate every insertion before publishing; unchanged light roots and
	// delta byte buffers are no longer copied on the owning thread.
	light_.reserve(light_.size() + additions);
	lightColumns_.reserve(lightColumns_.size() + sealed.size());
	while (!pending.empty())
	{
		auto	   node = pending.extract(pending.begin());
		const auto old = light_.find(node.key());
		if (!node.mapped())
		{
			if (old != light_.end())
				light_.erase(old);
		}
		else if (old != light_.end())
			old->second = std::move(node.mapped());
		else
			light_.insert(std::move(node));
	}
	while (!sealed.empty())
	{
		auto	   node = sealed.extract(sealed.begin());
		const auto old = lightColumns_.find(node.key());
		if (node.mapped()->empty())
		{
			if (old != lightColumns_.end())
				lightColumns_.erase(old);
		}
		else if (old != lightColumns_.end())
			old->second = std::move(node.mapped());
		else
			lightColumns_.insert(std::move(node));
	}
	for (Coord coord : accepted)
		invalidLight_.erase(coord);
	// Unloaded/known-empty records can sit outside both light domains. Their
	// invalidation is consumed too, unless this result predates a conflicting edit.
	for (const auto &entry : result.source->invalidLight)
	{
		if (!conflict(entry.first) && deferred.find(entry.first) == deferred.end())
			invalidLight_.erase(entry.first);
	}
	// Later commits use newer snapshots; older ones take the conservative path.
	if (since > mLightChangeBase)
	{
		mLightChanges.erase(std::remove_if(mLightChanges.begin(), mLightChanges.end(),
										   [since](const LightChange &inChange) { return inChange.mRevision <= since; }),
							mLightChanges.end());
		mLightChangeBase = since;
	}
	return out;
}
bool Store::lightReady(Coord coord) const
{
	if (invalidLight_.find(coord) != invalidLight_.end())
		return false;
	const auto chunk = chunks_.find(coord);
	return light_.find(coord) != light_.end() || chunk == chunks_.end() || !chunk->second->terrainPresent;
}
std::shared_ptr<const Chunk> Store::chunk(Coord coord) const
{
	const auto found = chunks_.find(coord);
	return found == chunks_.end() ? nullptr : found->second;
}
std::vector<CellEdit> Store::ReadSectionCells(Coord inChunk, unsigned inSection,
	const std::unordered_set<uint32_t> *inStates) const
{
	config_.validateChunk(inChunk);
	require(inSection < config_.sectionCount(), "invalid native section index");
	const auto source = chunk(inChunk);
	require(source != nullptr, "native section source is absent");
	const auto &section = source->sections[inSection];
	std::vector<CellEdit> cells;
	if (!section || (inStates && inStates->empty()))
		return cells;
	size_t count = section->count;
	if (inStates)
	{
		count = 0;
		for (uint32_t state : *inStates)
		{
			const auto found = section->counts.find(state);
			if (found != section->counts.end())
				count += found->second;
		}
	}
	cells.reserve(count);
	const unsigned size = unsigned(config_.sectionSize);
	const unsigned width = unsigned(config_.chunkSize), xy = width / size;
	const unsigned base_x = inSection % xy * size;
	const unsigned base_y = inSection / xy % xy * size;
	const unsigned base_z = inSection / (xy * xy) * size;
	for (unsigned i = 0; i < section->states.size(); ++i)
	{
		const uint32_t state = section->states[i];
		if (!state || (inStates && inStates->find(state) == inStates->end()))
			continue;
		const unsigned x = base_x + i % size;
		const unsigned y = base_y + i / size % size;
		const unsigned z = base_z + i / (size * size);
		cells.push_back({x + width * (y + width * z), state});
	}
	return cells;
}
Grid<std::vector<unsigned>> affectedLightSections(const Config &cfg, const LightChanges &changed)
{
	Grid<std::vector<uint8_t>> owners;
	const int				   ss = cfg.sectionSize, xy = cfg.chunkSize / ss, height = cfg.chunkHeight / ss;
	const int				   cs = cfg.chunkSize, ch = cfg.chunkHeight;
	for (const auto &pointer : changed)
	{
		const auto &delta = *pointer;
		require(delta.changedBits.size() == (cfg.cellCount() + 7) / 8, "invalid light delta");
		// Every changed cell marks the absolute sections its two-cell sampling
		// halo overlaps. Mark a dense local window first; hash owners only once
		// per marked section instead of once per cell and section.
		const int bx = delta.chunk.x * cs, by = delta.chunk.y * cs, bz = delta.chunk.z * ch;
		const int sx0 = floorDiv(bx - 2, ss), sy0 = floorDiv(by - 2, ss), sz0 = floorDiv(bz - 2, ss);
		const int nx = floorDiv(bx + cs + 1, ss) - sx0 + 1, ny = floorDiv(by + cs + 1, ss) - sy0 + 1;
		const int nz = floorDiv(bz + ch + 1, ss) - sz0 + 1;
		std::vector<std::pair<int, int>> rangeX(cs), rangeY(cs), rangeZ(ch);
		for (int i = 0; i < cs; ++i)
		{
			rangeX[i] = {floorDiv(bx + i - 2, ss) - sx0, floorDiv(bx + i + 2, ss) - sx0};
			rangeY[i] = {floorDiv(by + i - 2, ss) - sy0, floorDiv(by + i + 2, ss) - sy0};
		}
		for (int i = 0; i < ch; ++i)
			rangeZ[i] = {floorDiv(bz + i - 2, ss) - sz0, floorDiv(bz + i + 2, ss) - sz0};
		std::vector<uint8_t> marks(size_t(nx) * ny * nz);
		// A created or removed root changes every cell, whose halos together
		// cover the whole window.
		const unsigned cells = cfg.cellCount(), fullBytes = cells / 8;
		bool		   full = std::all_of(delta.changedBits.begin(), delta.changedBits.begin() + fullBytes,
										  [](uint8_t inBits) { return inBits == 0xff; });
		if (full && cells % 8)
			full = delta.changedBits.back() == uint8_t((1u << (cells % 8)) - 1);
		if (full)
			std::fill(marks.begin(), marks.end(), uint8_t(1));
		for (unsigned word = 0; !full && word < delta.changedBits.size(); ++word)
		{
			const unsigned bits = delta.changedBits[word];
			if (!bits)
				continue;
			for (unsigned bit = 0; bit < 8; ++bit)
			{
				if (!(bits & (1u << bit)))
					continue;
				const unsigned li = word * 8 + bit;
				if (li >= cfg.cellCount())
					break;
				const auto &rx = rangeX[li % unsigned(cs)];
				const auto &ry = rangeY[li / unsigned(cs) % unsigned(cs)];
				const auto &rz = rangeZ[li / unsigned(cs * cs)];
				for (int z = rz.first; z <= rz.second; ++z)
					for (int y = ry.first; y <= ry.second; ++y)
						for (int x = rx.first; x <= rx.second; ++x)
							marks[size_t(x) + size_t(nx) * (size_t(y) + size_t(ny) * size_t(z))] = 1;
			}
		}
		for (int z = 0; z < nz; ++z)
			for (int y = 0; y < ny; ++y)
				for (int x = 0; x < nx; ++x)
				{
					if (!marks[size_t(x) + size_t(nx) * (size_t(y) + size_t(ny) * size_t(z))])
						continue;
					const int	ax = sx0 + x, ay = sy0 + y, az = sz0 + z;
					const Coord chunk{floorDiv(ax, xy), floorDiv(ay, xy), floorDiv(az, height)};
					auto	   &bits = owners[chunk];
					if (bits.empty())
						bits.resize(cfg.sectionCount());
					const unsigned section = unsigned(ax - chunk.x * xy) + unsigned(xy * (ay - chunk.y * xy + xy * (az - chunk.z * height)));
					bits[section] = 1;
				}
	}
	Grid<std::vector<unsigned>> result;
	for (const auto &entry : owners)
	{
		auto &indices = result[entry.first];
		for (unsigned i = 0; i < entry.second.size(); ++i)
			if (entry.second[i])
				indices.push_back(i);
	}
	return result;
}
bool Store::meshReady(Coord chunk, unsigned section) const
{
	config_.validateChunk(chunk);
	require(section < config_.sectionCount(), "invalid native render section");
	if (chunks_.find(chunk) == chunks_.end() || !lightReady(chunk))
		return false;
	const int	ss = config_.sectionSize, xy = config_.chunkSize / ss;
	const Coord origin{chunk.x * config_.chunkSize + int(section % xy) * ss - 2,
					   chunk.y * config_.chunkSize + int(section / xy % xy) * ss - 2,
					   chunk.z * config_.chunkHeight + int(section / (xy * xy)) * ss - 2};
	const auto	lo = config_.chunkAt(origin);
	const auto	hi = config_.chunkAt({origin.x + ss + 3, origin.y + ss + 3, origin.z + ss + 3});
	for (int z = lo.z; z <= hi.z; ++z)
		for (int y = lo.y; y <= hi.y; ++y)
			for (int x = lo.x; x <= hi.x; ++x)
				if (known({x, y, z}) && !lightReady({x, y, z}))
					return false;
	return true;
}
MeshSnapshot Store::meshSnapshot(Coord chunk, unsigned section, bool allowPendingLight) const
{
	config_.validateChunk(chunk);
	require(section < config_.sectionCount(), "invalid native render section");
	require(chunks_.find(chunk) != chunks_.end(), "native mesh source chunk is absent");
	require(allowPendingLight || meshReady(chunk, section), "native mesh light halo is pending");
	const int	 ss = config_.sectionSize, xy = config_.chunkSize / ss;
	MeshSnapshot result;
	result.origin = {chunk.x * config_.chunkSize + int(section % xy) * ss - 2,
					 chunk.y * config_.chunkSize + int(section / xy % xy) * ss - 2,
					 chunk.z * config_.chunkHeight + int(section / (xy * xy)) * ss - 2};
	result.dimensions = {ss + 4, ss + 4, ss + 4};
	auto source = std::make_shared<Snapshot>();
	source->config = config_;
	source->catalog = catalog_;
	source->epoch = epoch_;
	source->revision = revision_;
	const auto lo = config_.chunkAt(result.origin);
	const auto hi = config_.chunkAt({result.origin.x + ss + 3, result.origin.y + ss + 3, result.origin.z + ss + 3});
	for (int z = lo.z; z <= hi.z; ++z)
		for (int y = lo.y; y <= hi.y; ++y)
			for (int x = lo.x; x <= hi.x; ++x)
			{
				Coord	   key{x, y, z};
				const auto state = chunks_.find(key);
				if (state != chunks_.end())
					source->chunks.emplace(key, state->second);
				if (!known(key))
					continue;
				const auto light = light_.find(key);
				if (light != light_.end())
					result.light.emplace(key, light->second);
				else
				{
					const Coord columnKey{x, y, 0};
					const auto	column = columns_.find(columnKey);
					if (column != columns_.end())
						result.columns.emplace(columnKey, column->second);
				}
			}
	result.world = std::move(source);
	return result;
}
GeometryStamp::GeometryStamp(const MeshSnapshot &source)
	: epoch(source.world->epoch), catalog(source.world->catalog),
	  origin(source.origin), dimensions(source.dimensions)
{
	for (const auto &entry : source.world->chunks)
		chunks.emplace(entry.first, entry.second);
}
bool Store::current(const GeometryStamp &candidate) const
{
	if (candidate.epoch != epoch_ || candidate.catalog.lock() != catalog_)
		return false;
	const auto lo = config_.chunkAt(candidate.origin);
	const auto hi = config_.chunkAt({candidate.origin.x + candidate.dimensions.x - 1,
									 candidate.origin.y + candidate.dimensions.y - 1, candidate.origin.z + candidate.dimensions.z - 1});
	for (int z = lo.z; z <= hi.z; ++z)
		for (int y = lo.y; y <= hi.y; ++y)
			for (int x = lo.x; x <= hi.x; ++x)
			{
				const Coord key{x, y, z};
				const auto	before = candidate.chunks.find(key);
				const auto	now = chunks_.find(key);
				if (before == candidate.chunks.end())
				{
					if (now != chunks_.end())
						return false;
				}
				else if (now == chunks_.end() || before->second.lock() != now->second)
					return false;
			}
	return true;
}
bool Store::geometryCurrent(const MeshSnapshot &candidate) const
{
	if (!candidate.world || candidate.world->epoch != epoch_ || candidate.world->catalog != catalog_)
		return false;
	const auto lo = config_.chunkAt(candidate.origin);
	const auto hi = config_.chunkAt({candidate.origin.x + candidate.dimensions.x - 1,
									 candidate.origin.y + candidate.dimensions.y - 1, candidate.origin.z + candidate.dimensions.z - 1});
	for (int z = lo.z; z <= hi.z; ++z)
		for (int y = lo.y; y <= hi.y; ++y)
			for (int x = lo.x; x <= hi.x; ++x)
				if (find(candidate.world->chunks, {x, y, z}) != find(chunks_, {x, y, z}))
					return false;
	return true;
}
bool Store::current(const MeshSnapshot &candidate) const
{
	if (!candidate.world || candidate.world->epoch != epoch_ || candidate.world->catalog != catalog_)
		return false;
	const auto lo = config_.chunkAt(candidate.origin);
	const auto hi = config_.chunkAt({candidate.origin.x + candidate.dimensions.x - 1,
									 candidate.origin.y + candidate.dimensions.y - 1, candidate.origin.z + candidate.dimensions.z - 1});
	for (int z = lo.z; z <= hi.z; ++z)
		for (int y = lo.y; y <= hi.y; ++y)
			for (int x = lo.x; x <= hi.x; ++x)
			{
				Coord key{x, y, z};
				if (find(candidate.world->chunks, key) != find(chunks_, key) || (known(key) && (find(candidate.light, key) != find(light_, key) || invalidLight_.find(key) != invalidLight_.end())))
					return false;
				if (known(key) && candidate.light.find(key) == candidate.light.end())
				{
					const Coord column{x, y, 0};
					if (find(candidate.columns, column) != find(columns_, column))
						return false;
				}
			}
	return true;
}
unsigned Store::light(Coord cell, bool sky) const
{
	const auto coord = config_.chunkAt(cell);
	if (!known(coord))
		return 0;
	if (sky && !config_.skyEnabled)
		return 15;
	const auto *chunk = find(light_, coord);
	if (chunk)
	{
		const unsigned value = chunk->values[config_.localIndex(cell)];
		return sky ? value >> 4 : value & 15;
	}
	// Outside the finite flood domain only implicit exposed sky can exist.
	if (!sky)
		return 0;
	const unsigned column = config_.localIndex(cell) % unsigned(config_.chunkSize * config_.chunkSize);
	const auto	   found = columns_.find({coord.x, coord.y, 0});
	if (found == columns_.end())
		return 15;
	for (const auto &entry : *found->second)
	{
		const auto top = entry.second->columnTops[column];
		if (top >= 0 && cell.z <= entry.first * config_.chunkHeight + top)
			return 0;
	}
	return 15;
}
l2::Cell MeshSnapshot::read(Coord cell) const
{
	require(world && cell.x >= origin.x && cell.y >= origin.y && cell.z >= origin.z && int64_t(cell.x) < int64_t(origin.x) + dimensions.x && int64_t(cell.y) < int64_t(origin.y) + dimensions.y && int64_t(cell.z) < int64_t(origin.z) + dimensions.z, "native sample is outside its mesh halo");
	const auto &cfg = world->config;
	const Coord key = cfg.chunkAt(cell);
	if (!world->known(key))
		return {0xef000, 0.2f, 1};
	const auto found = light.find(key);
	unsigned   value = 0xf0;
	if (found != light.end())
		value = found->second->values[cfg.localIndex(cell)];
	else if (cfg.skyEnabled)
	{
		const auto column = columns.find({key.x, key.y, 0});
		const auto li = cfg.localIndex(cell) % unsigned(cfg.chunkSize * cfg.chunkSize);
		if (column != columns.end())
			for (const auto &entry : *column->second)
			{
				const auto top = entry.second->columnTops[li];
				if (top >= 0 && cell.z <= entry.first * cfg.chunkHeight + top)
				{
					value = 0;
					break;
				}
			}
	}
	const auto &p = world->profile(cell);
	return {p.l2Word | 1048576u | value, p.shade, p.renderClass, p.emission, p.fluidSolid};
}
namespace
{
/// Visit a box inside the mesh halo chunk by chunk, x fastest. The visitor gets
/// the box index, whether the chunk is known, the stored light byte exactly as
/// MeshSnapshot::read derives it, and the profile MeshSnapshot::profile returns.
template <class Visit>
void VisitMeshBox(const MeshSnapshot &inSnapshot, const int inOrigin[3], const int inDimensions[3], Visit &&inVisit)
{
	require(inSnapshot.world != nullptr, "native mesh snapshot has no world");
	const int lower[3] = {inSnapshot.origin.x, inSnapshot.origin.y, inSnapshot.origin.z};
	const int extent[3] = {inSnapshot.dimensions.x, inSnapshot.dimensions.y, inSnapshot.dimensions.z};
	for (unsigned a = 0; a < 3; ++a)
		require(inDimensions[a] > 0 && inOrigin[a] >= lower[a] &&
					int64_t(inOrigin[a]) + inDimensions[a] <= int64_t(lower[a]) + extent[a],
				"native sample is outside its mesh halo");
	const auto &world = *inSnapshot.world;
	const auto &cfg = world.config;
	const auto &catalog = *world.catalog;
	const int	cs = cfg.chunkSize, ch = cfg.chunkHeight, ss = cfg.sectionSize, xy = cs / ss;
	// Chunk-local address tables; chunks are at most 64 cells on each axis.
	unsigned sectionXY[64], cellXY[64], sectionZ[64], cellZ[64];
	for (int i = 0; i < cs; ++i)
	{
		sectionXY[i] = unsigned(i / ss);
		cellXY[i] = unsigned(i % ss);
	}
	for (int i = 0; i < ch; ++i)
	{
		sectionZ[i] = unsigned(i / ss);
		cellZ[i] = unsigned(i % ss);
	}
	const int		 x0 = inOrigin[0], y0 = inOrigin[1], z0 = inOrigin[2];
	const int		 x1 = x0 + inDimensions[0], y1 = y0 + inDimensions[1], z1 = z0 + inDimensions[2];
	const Coord		 lo = cfg.chunkAt({x0, y0, z0}), hi = cfg.chunkAt({x1 - 1, y1 - 1, z1 - 1});
	std::vector<int> tops;
	for (int cz = lo.z; cz <= hi.z; ++cz)
		for (int cy = lo.y; cy <= hi.y; ++cy)
			for (int cx = lo.x; cx <= hi.x; ++cx)
			{
				const Coord		  key{cx, cy, cz};
				const int		  bx = cx * cs, by = cy * cs, bz = cz * ch;
				const bool		  known = world.known(key);
				const Chunk		 *chunk = find(world.chunks, key);
				const LightChunk *light = known ? find(inSnapshot.light, key) : nullptr;
				// Without a light root, sky exposure is the highest opacity>0 cell of
				// the whole block column, as read() scans the column's chunk roots.
				tops.clear();
				if (known && !light && cfg.skyEnabled)
				{
					tops.assign(size_t(cs) * cs, std::numeric_limits<int>::min());
					const auto column = inSnapshot.columns.find({cx, cy, 0});
					if (column != inSnapshot.columns.end())
						for (const auto &entry : *column->second)
							for (size_t c = 0; c < tops.size(); ++c)
							{
								const int top = entry.second->columnTops[c];
								if (top >= 0)
									tops[c] = std::max(tops[c], entry.first * ch + top);
							}
				}
				const int ax0 = std::max(x0, bx), ax1 = std::min(x1, bx + cs);
				const int ay0 = std::max(y0, by), ay1 = std::min(y1, by + cs);
				const int az0 = std::max(z0, bz), az1 = std::min(z1, bz + ch);
				for (int z = az0; z < az1; ++z)
					for (int y = ay0; y < ay1; ++y)
					{
						const unsigned lz = unsigned(z - bz), ly = unsigned(y - by);
						size_t		   index = size_t(ax0 - x0) + size_t(inDimensions[0]) * (size_t(y - y0) + size_t(inDimensions[1]) * size_t(z - z0));
						for (int x = ax0; x < ax1; ++x, ++index)
						{
							const unsigned lx = unsigned(x - bx);
							const unsigned li = lx + unsigned(cs) * (ly + unsigned(cs) * lz);
							unsigned	   value = 0xf0;
							if (light)
								value = light->values[li];
							else if (!tops.empty() && z <= tops[lx + unsigned(cs) * ly])
								value = 0;
							const Profile *profile = &catalog.states[0];
							if (chunk)
							{
								const auto &section = chunk->sections[sectionXY[lx] + unsigned(xy) * (sectionXY[ly] + unsigned(xy) * sectionZ[lz])];
								if (section)
								{
									const unsigned cell = cellXY[lx] + unsigned(ss) * (cellXY[ly] + unsigned(ss) * cellZ[lz]);
									profile = &catalog.states[section->states[cell]];
									if (!section->contexts.empty())
									{
										const auto context = section->contexts.find(cell);
										if (context != section->contexts.end())
											profile = &context->second;
									}
								}
							}
							inVisit(index, known, value, *profile);
						}
					}
			}
}
} // namespace
bool MeshSnapshot::fill(const int inOrigin[3], const int inDimensions[3], l2::Cell *outCells) const
{
	VisitMeshBox(*this, inOrigin, inDimensions, [&](size_t inIndex, bool inKnown, unsigned inValue, const Profile &inProfile)
	{
		outCells[inIndex] = inKnown ? l2::Cell{inProfile.l2Word | 1048576u | inValue, inProfile.shade, inProfile.renderClass, inProfile.emission, inProfile.fluidSolid}
									: l2::Cell{0xef000, 0.2f, 1};
	});
	return true;
}
void MeshSnapshot::FillProfiles(const int inOrigin[3], const int inDimensions[3], const Profile **outProfiles) const
{
	VisitMeshBox(*this, inOrigin, inDimensions, [&](size_t inIndex, bool, unsigned, const Profile &inProfile)
	{ outProfiles[inIndex] = &inProfile; });
}
size_t MeshSnapshot::bytes() const
{
	l2::MemoryUsage usage;
	memoryUsage(usage);
	usage.normalize();
	return usage.total();
}
void MeshSnapshot::memoryUsage(l2::MemoryUsage &usage) const
{
	usage.owned += sizeof(*this) + sizeof(Snapshot) + (world->chunks.size() + light.size() + columns.size()) * 64;
	const auto &catalog = world->catalog;
	usage.share(catalog, sizeof(Catalog) + catalog->states.capacity() * sizeof(Profile) + catalog->contextual.capacity() + catalog->mBlockEntityStates.capacity() + catalog->shapeBytes);
	const auto addChunk = [&](const std::shared_ptr<const Chunk> &chunk)
	{
		usage.share(chunk, chunk->mMemoryUsage.owned);
		const auto &shared = chunk->mMemoryUsage.shared;
		// Entries already include MemoryUsage's ownership overhead.
		usage.shared.insert(usage.shared.end(), shared.begin(), shared.end());
	};
	for (const auto &entry : world->chunks)
		addChunk(entry.second);
	for (const auto &entry : light)
		usage.share(entry.second, sizeof(LightChunk) + entry.second->values.capacity());
	for (const auto &column : columns)
	{
		usage.share(column.second, sizeof(Column) + column.second->size() * 64);
		for (const auto &entry : *column.second)
			addChunk(entry.second);
	}
}
l2::Cell MeshSnapshot::readCell(void *data, int x, int y, int z)
{
	return static_cast<MeshSnapshot *>(data)->read({x, y, z});
}
} // namespace mcmesh::world
