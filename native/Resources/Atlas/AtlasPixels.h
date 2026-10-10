#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace mcmesh::atlas
{
struct Pixel
{
	uint8_t r = 0, g = 0, b = 0, a = 0;
};
struct Image
{
	int				   width = 0, height = 0;
	std::vector<Pixel> pixels;
};
enum class MipStrategy
{
	Auto,
	Mean,
	Cutout,
	StrictCutout,
	DarkCutout,
	LabNormal,
	LabSpecular
};
// Weights are nonnegative and normalized by the caller. Ties choose the first
// sample. Encoded material categories must never become an invented metal ID.
Pixel FilterMaterial(const Pixel *pixels, const float *weights, int count, MipStrategy strategy);
// Boundary validation is performed once. Image/texel loops then use validated data.
bool GenerateMips(Image image, int mip, MipStrategy strategy, float alphaBias,
				  bool item, std::vector<Image> &result, std::string &error);
} // namespace mcmesh::atlas
