#include "Resources/PixelImage.h"
#include <chrono>
#include <iomanip>
#include <iostream>
#include <string>

using namespace mcmesh::pixelupload;
namespace
{
constexpr unsigned Width = 16384;
struct Case
{
	std::string			  name;
	unsigned			  iterations;
	std::vector<uint32_t> colors;
	std::vector<Span>	  spans;
};
Case quads(const char *name, unsigned count, unsigned first, unsigned iterations)
{
	Case test{name, iterations, std::vector<uint32_t>(count * 5, 0x12345678u), {}};
	test.spans = {{first * 4, test.colors.data(), count * 4, 1.25, 0.625},
				  {first, test.colors.data() + count * 4, count, 5, 2}};
	return test;
}
Case scattered(const char *name, unsigned count, bool separateRows, unsigned iterations)
{
	Case test{name, iterations, std::vector<uint32_t>(count * 5, 0x87654321u), {}};
	for (unsigned i = 0; i < count; ++i)
	{
		const unsigned first = separateRows ? i * Width : i * 127;
		test.spans.push_back({first * 4, test.colors.data() + i * 5, 4, 1.25, 0.625});
		test.spans.push_back({first, test.colors.data() + i * 5 + 4, 1, 5, 2});
	}
	return test;
}
void run(Case test, bool comma)
{
	using Clock = std::chrono::steady_clock;
	Image image(Width, Width);
	image.stage(test.spans);
	const auto pendingBytes = image.pendingBytes();
	const auto rowCount = image.pending.size();
	const auto rectangles = image.rectangles();
	size_t	   rectangleTexels = 0, inputTexels = 0;
	for (const auto &rect : rectangles)
		rectangleTexels += size_t(rect.width) * rect.height;
	for (const auto &span : test.spans)
		inputTexels += span.count;
	const auto &firstSpan = test.spans.front();
	const auto	firstRow = int(std::floor((firstSpan.first / Width) * firstSpan.scale + firstSpan.offset));
	const auto	firstX = int(test.spans.front().first % Width);
	image.publish();
	image.pending.clear();
	std::vector<double> samples;
	uint64_t			checksum = 0;
	// Published backing is already resident. Time CPU staging, rectangle planning,
	// publication and pending cleanup; Source barriers/Download/GPU are excluded.
	for (unsigned repeat = 0; repeat < 7; ++repeat)
	{
		const auto begin = Clock::now();
		for (unsigned i = 0; i < test.iterations; ++i)
		{
			test.colors[0] = i + repeat;
			image.stage(test.spans);
			const auto plan = image.rectangles();
			image.publish();
			checksum += image.row(firstRow)[firstX] + plan.size();
			image.pending.clear();
		}
		samples.push_back(std::chrono::duration<double, std::nano>(Clock::now() - begin).count() / test.iterations);
	}
	std::sort(samples.begin(), samples.end());
	std::cout << (comma ? ",\n" : "\n") << "    {\"name\":\"" << test.name
			  << "\",\"iterations\":" << test.iterations
			  << ",\"repeats\":" << samples.size()
			  << ",\"inputTexels\":" << inputTexels
			  << ",\"touchedRows\":" << rowCount
			  << ",\"pendingBytes\":" << pendingBytes
			  << ",\"rectangleTexels\":" << rectangleTexels
			  << ",\"medianNS\":" << samples[samples.size() / 2]
			  << ",\"minNS\":" << samples.front()
			  << ",\"maxNS\":" << samples.back()
			  << ",\"checksum\":" << checksum << "}";
}
} // namespace
int main()
{
	try
	{
		std::cout << std::fixed << std::setprecision(3)
				  << "{\"scope\":\"warm CPU pixel stage/plan/publish/clear; no Source or GPU\",\"cases\":[";
		run(quads("single_quad", 1, 0, 8192), false);
		run(quads("section_512_quads", 512, 8192, 8192), true);
		run(quads("part_10833_quads", 10833, 0, 2048), true);
		Case rows{"eight_full_rows", 512, std::vector<uint32_t>(Width * 8, 0x31415926u), {}};
		rows.spans.push_back({0, rows.colors.data(), rows.colors.size()});
		run(std::move(rows), true);
		run(scattered("32_updates_same_rows", 32, false, 4096), true);
		run(scattered("64_updates_separate_rows", 64, true, 128), true);
		std::cout << "\n  ]}\n";
	}
	catch (const std::exception &e)
	{
		std::cerr << e.what() << '\n';
		return 1;
	}
}
