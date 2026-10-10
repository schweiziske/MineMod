#pragma once
#include "Resources/Atlas/AtlasPixels.h"
#include <string_view>
#include <map>

namespace mcmesh::atlas
{
// Pixel operations only. Lua supplies the resolved frame set and all policy.
struct Sprite
{
	int								  width = 0, height = 0, mip = 0, padding = 0;
	size_t							  bytes = 0;
	std::map<int, std::vector<Image>> frames;
	MipStrategy						  strategy = MipStrategy::Mean;
	bool							  constant = true;
};
bool DecodePNG(std::string_view encoded, Image &result, std::string &error);
bool ComposeSheets(Image &base, int baseWidth, int baseHeight, const Image *overlay,
				   int overlayWidth, int overlayHeight, Pixel tint, std::string &error);
bool MaterialSheet(const Image &color, const Image *data, int bw, int bh,
				   const Image *overlayColor, const Image *overlayData, int ow, int oh,
				   MipStrategy strategy, Image &result, std::string &error);
bool CompileSprite(const Image &image, int width, int height, const std::vector<int> &frames,
				   int mip, int padding, MipStrategy strategy, float bias, bool item, size_t budget,
				   Sprite &result, std::string &error);
bool SampleSprite(const Sprite &sprite, int current, int next, float fraction,
				  std::vector<Image> &result, std::string &error);
} // namespace mcmesh::atlas
