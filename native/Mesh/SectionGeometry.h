#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

// No GLua or Source dependencies: the probe and game module use this same core.
namespace mcmesh::l2
{
constexpr unsigned TemplateSize = 46;
constexpr unsigned MaxQuads = 10833;
constexpr unsigned AtlasQuads = 1048576;
constexpr unsigned Triangle[6] = {0, 2, 1, 0, 3, 2};

struct LightTemplate
{
	int		 mode = 0, face = 0, flags = 0, flatShade = 255, emission = 0, lightFace = -1;
	float	 directionShade = 1;
	float	 weights[4][4]{};
	unsigned indices[4]{};
};
struct Template : LightTemplate
{
	double positions[4][3]{}, extent[3]{};
	float  uv[4][2]{}, normal[3]{};
};

struct Cell
{
	uint32_t word = 0;
	float	 shade = 0;
	uint32_t renderClass = 0;
	uint8_t	 fluidEmission = 0;
	bool	 fluidSolid = false;
	unsigned block() const { return word & 15; }
	unsigned sky() const { return (word >> 4) & 15; }
	unsigned emission() const { return (word >> 8) & 15; }
	unsigned dampening() const { return (word >> 12) & 15; }
	bool	 emissive() const { return (word & 65536) != 0; }
	bool	 viewBlocking() const { return (word & 131072) != 0; }
	bool	 solidRender() const { return (word & 262144) != 0; }
	bool	 fullCollision() const { return (word & 524288) != 0; }
	bool	 loaded() const { return (word & 1048576) != 0; }
};

using ReadCell = Cell (*)(void *, int, int, int);
// Size arithmetic at registration/admission boundaries, before allocation.
size_t checkedAdd(size_t a, size_t b);
size_t checkedMultiply(size_t a, size_t b);
struct SharedAllocation
{
	std::shared_ptr<const void> owner;
	size_t						bytes;
};
struct MemoryUsage
{
	size_t						  owned = 0;
	std::vector<SharedAllocation> shared;
	void						  share(std::shared_ptr<const void> owner, size_t bytes);
	void						  normalize();
	size_t						  total() const;
};
// Only immutable CPU data may implement this interface. Live Lua readers use
// the callback constructor and are always detached before worker submission.
struct CellSource
{
	virtual ~CellSource() = default;
	virtual Cell read(int x, int y, int z) const = 0;
	/// Optional bulk read of a whole box, x fastest, with values identical to
	/// read(). Returns false when the source only supports per-cell reads.
	virtual bool   fill(const int[3], const int[3], Cell *) const { return false; }
	virtual size_t bytes() const = 0;
	virtual void   memoryUsage(MemoryUsage &usage) const { usage.owned += bytes(); }
};
struct FaceLight
{
	uint32_t coords[4]{};
	float	 ao[4]{}, blocks[4]{}, skies[4]{};
};
class Snapshot
{
public:
	Snapshot(const int origin[3], const int dimensions[3], ReadCell reader, void *context);
	// Owned sources reserve their scratch at admission, but allocate it on the
	// consuming worker. Direct CPU callers must prepare before sampling.
	Snapshot(const int origin[3], const int dimensions[3], std::shared_ptr<const CellSource> source);
	void			 prepare();
	bool			 prepared() const { return !ready_.empty(); }
	/// Worker-side: fill the whole cache from an owned source in one pass when
	/// the source supports bulk reads. Per-cell reads stay lazy otherwise.
	void			 preload();
	const Cell		&read(int x, int y, int z);
	const FaceLight &sampleFace(int x, int y, int z, unsigned face, bool cubic);
	void			 validateSource(const int source[3]) const;
	void			 freeze()
	{
		reader_ = nullptr;
		context_ = nullptr;
	}
	size_t bytes() const { return cacheBytes() + (source_ ? source_->bytes() : 0); }
	void   memoryUsage(MemoryUsage &usage) const
	{
		usage.owned += cacheBytes();
		if (source_)
		{
			MemoryUsage source;
			source_->memoryUsage(source);
			usage.share(source_, source.owned);
			for (auto &allocation : source.shared)
				usage.shared.push_back(std::move(allocation));
		}
	}
	uint64_t reads = 0, hits = 0;
	uint64_t faceSamples = 0, faceHits = 0;

private:
	Snapshot(const int origin[3], const int dimensions[3]);
	size_t							  cacheBytes() const;
	int								  origin_[3], dimensions_[3];
	size_t							  cellCount_ = 1;
	ReadCell						  reader_ = nullptr;
	void							 *context_ = nullptr;
	std::shared_ptr<const CellSource> source_;
	std::vector<Cell>				  cells_;
	std::vector<uint8_t>			  ready_;
	int								  faceSource_[3]{};
	unsigned						  faceMask_ = 0;
	std::array<FaceLight, 12>		  faces_{};
};

struct LightCommand
{
	int		 source[3]{};
	unsigned tint = 0, opacity = 255;
	uint32_t prepared[4]{};
};
struct Command : LightCommand
{
	double translation[3]{}, size = 1;
};
struct LightWork
{
	LightTemplate geometry;
	LightCommand  command;
};
struct LightQuad
{
	uint32_t pixels[4]{}, occlusion = 0xffffffff;
};
struct Vertex
{
	float	position[3], normal[3], uv[2];
	uint8_t color[4];
};
struct Quad
{
	Vertex	 vertices[4]{};
	uint32_t pixels[4]{}, occlusion = 0xffffffff;
};

struct DirectionRange
{
	unsigned first = 0, count = 0;
};
struct DirectionOrder
{
	std::array<DirectionRange, 7> ranges{};
	std::vector<unsigned>		  quads;
};
DirectionOrder directionOrder(const std::vector<Quad> &quads);

void	  require(bool valid, const char *message);
int		  integer(double value, int minimum, int maximum, const char *message);
Template  compile(const double *packet);
void	  validateCommand(const Template &geometry, const Command &command, const Snapshot &snapshot, unsigned firstQuad);
void	  prefetch(const Template &geometry, const Command &command, Snapshot &snapshot);
Quad	  evaluate(const Template &geometry, const Command &command, Snapshot &snapshot, unsigned globalQuad);
LightQuad evaluateLight(const LightTemplate &geometry, const LightCommand &command, Snapshot &snapshot);
} // namespace mcmesh::l2
