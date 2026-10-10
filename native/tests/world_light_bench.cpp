#include "World/WorldStore.h"
#include <chrono>
#include <iostream>
#include <stdexcept>

using namespace mcmesh::world;
namespace
{
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point start)
{
	return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
void measure(Store &store, const char *scene, const char *operation)
{
	std::atomic<bool> cancelled{false};
	auto			  start = Clock::now();
	auto			  snapshot = store.snapshot();
	const double	  snapshotMS = elapsed(start);
	auto			  result = rebuildLight(std::move(snapshot), cancelled);
	start = Clock::now();
	const auto	 committed = store.commit(*result);
	const double commitMS = elapsed(start);
	if (committed.stale || committed.deferred)
		throw std::runtime_error("benchmark commit rejected");
	std::cout << scene << ',' << operation << ',' << result->scannedCells << ','
			  << result->targets.size() << ',' << result->computeMS << ',' << result->diffMS << ','
			  << snapshotMS << ',' << commitMS << '\n';
}
void run(const char *scene, int levels)
{
	Config cfg;
	cfg.streaming = true;
	cfg.minChunkZ = -16;
	cfg.maxChunkZ = 16;
	auto catalog = std::make_shared<Catalog>();
	catalog->states.resize(4);
	catalog->states[1] = {0, 15, 16, 0xef000, 9, 0.2f};
	catalog->states[2] = {15, 0, 1, 0x10f00, 16, 1.0f};
	catalog->states[3] = {15, 15, 16, 0xeff00, 9, 0.2f};
	Store				  store(cfg, catalog);
	std::vector<Mutation> batch;
	for (int z = -levels / 2; z < levels - levels / 2; ++z)
		for (int y = -2; y <= 2; ++y)
			for (int x = -2; x <= 2; ++x)
			{
				Mutation row;
				row.chunk = {x, y, z};
				for (int h : {0, cfg.chunkHeight - 1})
					for (int b = 0; b < cfg.chunkSize; ++b)
						for (int a = 0; a < cfg.chunkSize; ++a)
							row.cells.push_back({unsigned(a + cfg.chunkSize * (b + cfg.chunkSize * h)), 1});
				batch.push_back(std::move(row));
			}
	store.apply(0, batch);
	measure(store, scene, "initial");
	Mutation edit;
	edit.cells = {{cfg.localIndex({8, 8, 8}), 0}};
	for (int repeat = 0; repeat < 3; ++repeat)
	{
		for (uint32_t state : {2u, 0u, 3u, 0u})
		{
			edit.cells[0].state = state;
			store.apply(store.revision(), {edit});
			measure(store, scene, state == 2 ? "torch_place" : state == 3 ? "solid_light_place"
																		  : "remove");
		}
	}
}
} // namespace
int main()
{
	try
	{
		std::cout << "scene,operation,scannedCells,targets,computeMS,diffMS,snapshotMS,commitMS\n";
		run("flat", 1);
		run("tall", 8);
		return 0;
	}
	catch (const std::exception &error)
	{
		std::cerr << error.what() << '\n';
		return 1;
	}
}
