#include "Mesh/SectionWorker.h"
#include <algorithm>
#include <exception>
#include <string>

#ifdef _WIN32
#define L2_EXPORT extern "C" __declspec(dllexport)
#else
#define L2_EXPORT extern "C"
#endif

namespace
{
thread_local std::string lastError;
struct ProbeCells
{
	const uint32_t *words;
	const float	   *shades;
	const int	   *dimensions;
	const uint32_t *classes = nullptr;
	const int	   *origin = nullptr;
};
mcmesh::l2::Cell read(void *context, int x, int y, int z)
{
	const auto &in = *static_cast<ProbeCells *>(context);
	if (in.origin)
	{
		x -= in.origin[0];
		y -= in.origin[1];
		z -= in.origin[2];
	}
	const auto index = x + in.dimensions[0] * (y + in.dimensions[1] * z);
	return {in.words[index], in.shades[index], in.classes ? in.classes[index] : 0};
}
} // namespace

L2_EXPORT const char *L2LastError()
{
	return lastError.c_str();
}
namespace
{
struct ShapeGrid final : mcmesh::l2::ShapeSource, mcmesh::l2::CellSource
{
	std::vector<mcmesh::l2::Shape> profiles;
	std::vector<uint32_t>		   classes;
	const uint32_t				  *cells = nullptr;
	unsigned					   state(int x, int y, int z) const
	{
		mcmesh::l2::require(x >= -2 && x <= 2 && y >= -2 && y <= 2 && z >= -2 && z <= 2,
							"shape probe halo");
		return cells[x + 2 + 5 * (y + 2 + 5 * (z + 2))];
	}
	const mcmesh::l2::Shape &shape(int x, int y, int z) const override
	{
		return profiles.at(state(x, y, z));
	}
	mcmesh::l2::Cell read(int x, int y, int z) const override
	{
		return {0, 1, classes.at(state(x, y, z))};
	}
	size_t bytes() const override { return sizeof(*this); }
};
} // namespace
// Return original quad indices after production model expansion. Lua compares
// the selected commands with its ordinary emitter, independently of lighting.
L2_EXPORT int L2SelectShape(const double *profiles, unsigned count, const uint32_t *cells,
							const double *recipe, uint32_t *selected)
{
	using namespace mcmesh::l2;
	try
	{
		auto grid = std::make_shared<ShapeGrid>();
		grid->cells = cells;
		for (unsigned i = 0; i < count; ++i)
		{
			Shape shape;
			shape.selector = unsigned(*profiles++);
			shape.stair = int(*profiles++);
			shape.connections = unsigned(*profiles++);
			shape.pane = *profiles++ != 0;
			grid->classes.push_back(uint32_t(*profiles++));
			shape.variants.resize(unsigned(*profiles++));
			for (auto &boxes : shape.variants)
			{
				boxes.resize(unsigned(*profiles++));
				for (auto &box : boxes)
					for (auto &v : box)
						v = *profiles++;
			}
			shape.validate();
			grid->profiles.push_back(std::move(shape));
		}
		auto model = std::make_shared<Model>();
		model->shapeSelector = unsigned(*recipe++);
		model->block = unsigned(*recipe++);
		model->keepInternalFaces = *recipe++ != 0;
		model->groups.resize(1);
		model->groups[0].alternatives.resize(unsigned(*recipe++));
		unsigned index = 0;
		for (auto &alternative : model->groups[0].alternatives)
		{
			alternative.quads.resize(unsigned(*recipe++));
			for (auto &quad : alternative.quads)
			{
				quad.cullFace = unsigned(*recipe++);
				quad.shapeCull = *recipe++ != 0;
				for (auto &v : quad.box)
					v = *recipe++;
				quad.work.command.tint = ++index;
			}
		}
		validateModel(*model);
		const int origin[] = {-2, -2, -2}, dims[] = {5, 5, 5};
		Input	  input(Snapshot(origin, dims, grid));
		input.snapshot.prepare();
		input.shapeSource = grid;
		input.models.push_back({model, 1});
		Voxel voxel;
		voxel.model = true;
		input.voxels.push_back(voxel);
		input.snapshot.freeze();
		std::vector<unsigned> groups;
		std::atomic<bool>	  cancelled{false};
		expandVoxels(input, groups, cancelled);
		unsigned n = 0;
		for (const auto &part : input.parts)
			for (const auto &work : part)
				selected[n++] = work.command.tint;
		lastError.clear();
		return int(n);
	}
	catch (const std::exception &e)
	{
		lastError = e.what();
		return -1;
	}
}
L2_EXPORT unsigned L2ModelChoice(int x, int y, int z, unsigned salt)
{
	mcmesh::l2::ModelGroup group;
	group.salt = salt;
	group.totalWeight = 11;
	group.alternatives.resize(3);
	group.alternatives[0].weight = 2;
	group.alternatives[1].weight = 5;
	group.alternatives[2].weight = 4;
	const int source[3] = {x, y, z};
	return mcmesh::l2::modelChoice(group, source);
}
L2_EXPORT unsigned L2TriangleIndex(unsigned index)
{
	return index < 6 ? mcmesh::l2::Triangle[index] : UINT32_MAX;
}
L2_EXPORT int L2Evaluate(const double *packet, const uint32_t *words, const float *shades,
						 const int *dimensions, const int *source, const double *transform,
						 unsigned tint, unsigned opacity, unsigned firstQuad, const uint32_t *prepared,
						 uint32_t *pixels, float *vertices, uint64_t *statistics, unsigned repeat)
{
	using namespace mcmesh::l2;
	try
	{
		require(packet && words && shades && dimensions && source && transform && prepared &&
					pixels && vertices && statistics && repeat > 0,
				"invalid probe arguments");
		const Template geometry = compile(packet);
		Command		   command;
		std::copy(source, source + 3, command.source);
		std::copy(transform, transform + 3, command.translation);
		std::copy(prepared, prepared + 4, command.prepared);
		command.size = transform[3];
		command.tint = tint;
		command.opacity = opacity;
		const int  origin[3]{};
		ProbeCells input{words, shades, dimensions};
		Snapshot   snapshot(origin, dimensions, read, &input);
		validateCommand(geometry, command, snapshot, firstQuad);
		prefetch(geometry, command, snapshot);
		snapshot.freeze();
		Quad quad;
		for (unsigned i = 0; i < repeat; ++i)
			quad = evaluate(geometry, command, snapshot, firstQuad);
		std::copy(std::begin(quad.pixels), std::end(quad.pixels), pixels);
		pixels[4] = quad.occlusion;
		for (unsigned i = 0; i < 4; ++i)
		{
			const auto &v = quad.vertices[i];
			std::copy(std::begin(v.position), std::end(v.position), vertices + i * 12);
			std::copy(std::begin(v.normal), std::end(v.normal), vertices + i * 12 + 3);
			std::copy(std::begin(v.uv), std::end(v.uv), vertices + i * 12 + 6);
			std::copy(std::begin(v.color), std::end(v.color), vertices + i * 12 + 8);
		}
		statistics[0] = snapshot.reads;
		statistics[1] = snapshot.hits;
		statistics[2] = repeat * 4ull;
		statistics[3] = repeat * 6ull;
		lastError.clear();
		return 1;
	}
	catch (const std::exception &e)
	{
		lastError = e.what();
		return 0;
	}
}

// Exercises the production voxel expansion and frozen sampling without Source.
L2_EXPORT int L2EvaluateVoxels(const double *packets, const uint32_t *metadata, unsigned cubeCount,
							   const int *voxels, const double *translations, unsigned voxelCount, double blockSize, unsigned maxQuads,
							   const uint32_t *words, const float *shades, const uint32_t *classes, const int *origin, const int *dimensions,
							   uint32_t *layout, uint32_t *pixels, float *vertices, uint64_t *statistics)
{
	using namespace mcmesh::l2;
	try
	{
		require(cubeCount > 0 && cubeCount <= 512 && voxelCount <= 512, "invalid voxel probe counts");
		require(maxQuads > 0 && maxQuads <= MaxQuads, "invalid voxel probe part limit");
		ProbeCells cells{words, shades, dimensions, classes, origin};
		Input	   input(Snapshot(origin, dimensions, read, &cells));
		input.blockSize = blockSize;
		input.maxQuads = maxQuads;
		for (unsigned c = 0; c < cubeCount; ++c)
		{
			Cube cube;
			cube.block = metadata[c * 19];
			for (unsigned f = 0; f < 6; ++f)
			{
				auto &w = cube.faces[f];
				w.geometry = compile(packets + (c * 6 + f) * TemplateSize);
				cube.groups[f] = metadata[c * 19 + 1 + f * 3];
				w.command.tint = metadata[c * 19 + 2 + f * 3];
				w.command.opacity = metadata[c * 19 + 3 + f * 3];
			}
			validateCube(cube);
			input.cubes.push_back(cube);
		}
		for (unsigned i = 0; i < voxelCount; ++i)
		{
			Voxel voxel;
			std::copy(voxels + i * 4, voxels + i * 4 + 3, voxel.source);
			std::copy(translations + i * 3, translations + i * 3 + 3, voxel.translation);
			voxel.cube = voxels[i * 4 + 3];
			require(voxel.cube < cubeCount, "invalid voxel probe recipe");
			input.snapshot.validateSource(voxel.source);
			input.voxels.push_back(voxel);
		}
		prefetchVoxels(input);
		input.snapshot.freeze();
		std::atomic<bool>	  cancelled{false};
		std::vector<unsigned> groups;
		expandVoxels(input, groups, cancelled);
		unsigned count = 0;
		for (unsigned p = 0; p < input.parts.size(); ++p)
		{
			for (unsigned q = 0; q < input.parts[p].size(); ++q, ++count)
			{
				const auto &work = input.parts[p][q];
				const auto	quad = evaluate(work.geometry, work.command, input.snapshot, q);
				layout[count * 2] = p;
				layout[count * 2 + 1] = groups[p];
				std::copy(std::begin(quad.pixels), std::end(quad.pixels), pixels + count * 5);
				pixels[count * 5 + 4] = quad.occlusion;
				for (unsigned c = 0; c < 4; ++c)
				{
					const auto &v = quad.vertices[c];
					auto	   *out = vertices + count * 48 + c * 12;
					std::copy(std::begin(v.position), std::end(v.position), out);
					std::copy(std::begin(v.normal), std::end(v.normal), out + 3);
					std::copy(std::begin(v.uv), std::end(v.uv), out + 6);
					std::copy(std::begin(v.color), std::end(v.color), out + 8);
				}
			}
		}
		statistics[0] = input.snapshot.reads;
		statistics[1] = input.snapshot.hits;
		lastError.clear();
		return static_cast<int>(count);
	}
	catch (const std::exception &e)
	{
		lastError = e.what();
		return -1;
	}
}

namespace
{
struct FluidGrid final : mcmesh::l2::FluidSource, mcmesh::l2::CellSource
{
	std::vector<mcmesh::l2::FluidState> profiles;
	std::vector<unsigned>				emission;
	std::vector<bool>					solid;
	const uint32_t					   *states;
	const uint32_t					   *words;
	int									origin[3];
	size_t								index(int x, int y, int z) const
	{
		x -= origin[0];
		y -= origin[1];
		z -= origin[2];
		mcmesh::l2::require(x >= 0 && x < 5 && y >= 0 && y < 5 && z >= 0 && z < 5, "fluid probe halo");
		return x + 5 * (y + 5 * z);
	}
	const mcmesh::l2::FluidState &fluid(int x, int y, int z) const override
	{
		return profiles.at(states[index(x, y, z)]);
	}
	mcmesh::l2::Cell read(int x, int y, int z) const override
	{
		const auto i = index(x, y, z), state = size_t(states[i]);
		return {words[i], 1, 0, uint8_t(emission.at(state)), solid.at(state)};
	}
	size_t bytes() const override { return sizeof(*this); }
};
} // namespace

// Inputs are production Lua profile/recipe values; both geometry and lighting
// execute the same implementations linked into the game DLL.
L2_EXPORT int L2EvaluateFluid(const double *profiles, unsigned count, const double *boxes,
							  const uint32_t *states, const uint32_t *words, const double *recipe, const int *source,
							  const double *transform, uint32_t *pixels, float *vertices)
{
	using namespace mcmesh::l2;
	try
	{
		auto grid = std::make_shared<FluidGrid>();
		grid->states = states;
		grid->words = words;
		for (unsigned a = 0; a < 3; ++a)
			grid->origin[a] = source[a] - 2;
		for (unsigned i = 0; i < count; ++i)
		{
			const auto *p = profiles + i * 12;
			FluidState	s;
			s.kind = uint8_t(p[0]);
			s.height = p[1];
			s.falling = p[2] != 0;
			s.solid = p[3] != 0;
			s.blocksMotion = p[4] != 0;
			s.ice = p[5] != 0;
			std::vector<FluidBox> collision;
			for (unsigned b = unsigned(p[10]); b < unsigned(p[10] + p[11]); ++b)
			{
				FluidBox box;
				std::copy(boxes + b * 6, boxes + b * 6 + 6, box.begin());
				collision.push_back(box);
			}
			compileFluidCoverage(s, p[6] != 0, p[7] != 0, collision);
			grid->profiles.push_back(s);
			grid->solid.push_back(p[8] != 0);
			grid->emission.push_back(unsigned(p[9]));
		}
		FluidRecipe r;
		r.kind = uint8_t(recipe[0]);
		r.emission = unsigned(recipe[1]);
		r.opacity = unsigned(recipe[2]);
		r.offset = recipe[3];
		r.flow = recipe[4] != 0;
		r.full = recipe[5] != 0;
		for (unsigned f = 0; f < 6; ++f)
			r.shade[f] = unsigned(recipe[6 + f]);
		for (unsigned t = 0; t < 7; ++t)
			for (unsigned a = 0; a < 2; ++a)
			{
				r.tiles[t].origin[a] = recipe[12 + t * 6 + a];
				r.tiles[t].scale[a] = recipe[14 + t * 6 + a];
				r.tiles[t].inset[a] = recipe[16 + t * 6 + a];
			}
		const auto geometry = fluidGeometry(r, *grid, source);
		const int  dims[3] = {5, 5, 5};
		Snapshot   snapshot(grid->origin, dims, grid);
		snapshot.prepare();
		snapshot.freeze();
		Command command;
		std::copy(source, source + 3, command.source);
		std::copy(transform, transform + 3, command.translation);
		command.size = transform[3];
		command.opacity = r.opacity;
		unsigned first = 0;
		for (unsigned f = 0; f < 6; ++f)
			if (geometry.mask & (1u << f))
			{
				const auto q = evaluate(geometry.faces[f], command, snapshot, first++);
				std::copy(std::begin(q.pixels), std::end(q.pixels), pixels + f * 5);
				pixels[f * 5 + 4] = q.occlusion;
				for (unsigned c = 0; c < 4; ++c)
				{
					const auto &v = q.vertices[c];
					auto	   *out = vertices + f * 48 + c * 12;
					std::copy(std::begin(v.position), std::end(v.position), out);
					std::copy(std::begin(v.normal), std::end(v.normal), out + 3);
					std::copy(std::begin(v.uv), std::end(v.uv), out + 6);
					std::copy(std::begin(v.color), std::end(v.color), out + 8);
				}
			}
		lastError.clear();
		return int(geometry.mask);
	}
	catch (const std::exception &e)
	{
		lastError = e.what();
		return -1;
	}
}
