#include "Resources/Atlas/AtlasRegions.h"
#include <iostream>
#include <random>
#include <stdexcept>

int main()
{
	using namespace mcmesh::atlas;
	std::mt19937 random(42017);
	for (int trial = 0; trial < 200; ++trial)
	{
		std::vector<UploadRegion> input;
		for (int i = 0; i < 1 + trial % 100; ++i)
		{
			const int x = int(random() % 125) * 16, y = int(random() % 125) * 16;
			input.push_back({x, y, 16 * int(1 + random() % 3), 16 * int(1 + random() % 3)});
		}
		auto merged = input;
		MergeUploadRegions(merged);
		if (merged.size() > input.size())
			throw std::runtime_error("grew upload count");
		for (const auto &region : merged)
			if (region.x % 16 || region.y % 16 || region.width % 16 || region.height % 16 || region.x + region.width > 2048 || region.y + region.height > 2048)
				throw std::runtime_error("alignment or bounds");
		for (const auto &region : input)
		{
			bool covered = false;
			for (const auto &output : merged)
				if (output.x <= region.x && output.y <= region.y && output.x + output.width >= region.x + region.width && output.y + output.height >= region.y + region.height)
					covered = true;
			if (!covered)
				throw std::runtime_error("lost update");
		}
	}
	std::vector<UploadRegion> nearby{{0, 0, 48, 48}, {48, 0, 48, 48}, {96, 0, 48, 48}, {1904, 1904, 48, 48}};
	MergeUploadRegions(nearby);
	if (nearby.size() != 2)
		throw std::runtime_error("merge separated or adjacent regions incorrectly");
	std::vector<UploadRegion> island;
	for (int y = 0; y < 1024; y += 256)
		for (int x = 0; x < 2048; x += 256)
			island.push_back({x, y, 48, 48});
	MergeUploadRegions(island, int64_t(8192) * 4096 / 8);
	if (island.size() != 1 || island[0].x != 0 || island[0].y != 0 || island[0].width != 1840 || island[0].height != 816)
		throw std::runtime_error("large atlas animation island did not coalesce");
	std::cout << "atlas upload regions: 200 coverage/alignment cases passed\n";
}
