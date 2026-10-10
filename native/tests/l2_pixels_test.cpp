#include "Mesh/LightPixels.h"
#include <iostream>
#include <map>

using namespace mcmesh::l2;
void check(bool value, const char *message)
{
	if (!value)
		throw std::runtime_error(message);
}
template <class F>
void fails(F &&fn)
{
	bool failed = false;
	try
	{
		fn();
	}
	catch (const std::exception &)
	{
		failed = true;
	}
	check(failed, "expected pixel boundary failure");
}
std::shared_ptr<const LightPixels> pixels(unsigned count, uint32_t color)
{
	auto result = std::make_shared<LightPixels>(count);
	std::fill(result->corners.begin(), result->corners.end(), color);
	std::fill(result->occlusion.begin(), result->occlusion.end(), color ^ 0xff123456);
	return result;
}
void runs()
{
	const int	   width = 16384, height = 16384;
	const unsigned capacity = width * (height / 5);
	for (unsigned first : {0u, 4095u, 16383u, AtlasQuads - 8, AtlasQuads, capacity - 8})
	{
		LightPixels	   values(8);
		const uint32_t colors[] = {0, 0xffffffff, 0x12345678, 0x00abcdef};
		for (size_t i = 0; i < values.corners.size(); ++i)
			values.corners[i] = colors[i / 3 % 4];
		for (size_t i = 0; i < values.occlusion.size(); ++i)
			values.occlusion[i] = colors[i % 4];
		validatePixelRange(values, width, height, first);
		std::vector<PixelRun> output;
		appendPixelRuns(output, width, first * 4, values.corners, 1.25, 0.625);
		appendPixelRuns(output, width, first, values.occlusion, 5, 2);
		std::map<std::pair<int, int>, uint32_t> actual, expected;
		for (const auto &run : output)
		{
			check(run.x >= 0 && run.x + run.length <= width && run.y < height, "run escaped target");
			for (int x = run.x; x < run.x + run.length; ++x)
				check(actual.emplace(std::make_pair(x, run.y), run.color).second, "overlapping pixel runs");
		}
		for (unsigned i = 0; i < 32; ++i)
		{
			const unsigned address = first * 4 + i, row = address / width;
			expected[{int(address % width), int(row / 4 * 5 + row % 4 + (row % 4 >= 2))}] = values.corners[i];
		}
		for (unsigned i = 0; i < 8; ++i)
			expected[{int((first + i) % width), int((first + i) / width * 5 + 2)}] = values.occlusion[i];
		check(actual == expected, "Native corner/AO bytes changed");
	}
	auto value = pixels(8, 0);
	fails([&]
		  { validatePixelRange(*value, width, height, capacity - 7); });
	fails([&]
		  { validatePixelRange(*value, width, height, AtlasQuads - 7); });
}
void transactions()
{
	std::vector<PixelUpdate>						updates;
	std::vector<std::shared_ptr<const LightPixels>> atlas;
	for (unsigned i = 0; i < 3; ++i)
	{
		auto old = pixels(2, i), next = pixels(2, i + 10);
		auto slot = std::make_shared<PixelSlot>();
		slot->pixels = old;
		updates.push_back({slot, old, next, i * 2});
		atlas.push_back(old);
	}
	unsigned draws = 0;
	auto	 draw = [&](std::shared_ptr<const LightPixels> value, unsigned first)
	{
		++draws;
		// Simulate a GPU write before an error, including the failing part.
		atlas[first / 2] = value;
		if (draws == 2)
			throw std::runtime_error("injected partial upload");
	};
	PixelTransaction failed(updates);
	fails([&]
		  { failed.draw(draw); });
	check(draws == 4, "did not restore both attempted parts");
	for (size_t i = 0; i < 3; ++i)
	{
		check(atlas[i]->corners == updates[i].previous->corners, "atlas rollback failed");
		check(updates[i].target->pixels == updates[i].previous, "failed upload published CPU pixels");
	}
	failed.discard();
	PixelTransaction cleanup(updates);
	cleanup.draw(draw);
	cleanup.restore(draw); // A Lua render-state cleanup failure after all draws.
	cleanup.discard();
	for (size_t i = 0; i < 3; ++i)
		check(atlas[i]->corners == updates[i].previous->corners, "late rollback failed");
	PixelTransaction committed(updates);
	committed.draw(draw);
	check(committed.commit() == 0, "same-size replacement changed mesh byte accounting");
	for (const auto &update : updates)
		check(update.target->pixels == update.next, "commit copied or lost pixels");
	fails([&]
		  { PixelTransaction stale(updates); });
	auto dead = updates;
	for (auto &update : dead)
		update.previous = update.target->pixels;
	PixelTransaction destroyed(dead);
	dead[1].target->live = false;
	const auto previousDraws = draws;
	fails([&]
		  { destroyed.draw(draw); });
	check(draws == previousDraws, "destroyed mesh was not rejected before first draw");
	dead[1].target->live = true;
	dead[1].first = dead[0].first;
	fails([&]
		  { PixelTransaction overlap(dead); });
	dead[1] = dead[0];
	fails([&]
		  { PixelTransaction duplicate(dead); });
	// A world can have many parts; only each individual engine mesh is bounded.
	std::vector<PixelUpdate> many;
	for (unsigned i = 0; i < 300; ++i)
	{
		auto slot = std::make_shared<PixelSlot>();
		slot->pixels = pixels(1, i);
		many.push_back({slot, slot->pixels, pixels(1, i + 1), i});
	}
	PixelTransaction large(std::move(many));
	large.draw([](std::shared_ptr<const LightPixels>, unsigned) {});
	large.commit();
}
void queuedTransactions()
{
	auto previous = pixels(1, 7), next = pixels(1, 9);
	auto slot = std::make_shared<PixelSlot>();
	slot->pixels = previous;
	PixelTransaction								transaction({{slot, previous, next, 0}});
	std::vector<std::shared_ptr<const LightPixels>> queue;
	auto											atlas = previous;
	unsigned										flushes = 0;
	auto											enqueue = [&](std::shared_ptr<const LightPixels> value, unsigned)
	{
		queue.push_back(value);
	};
	auto flush = [&]
	{
		for (const auto &value : queue)
			atlas = value;
		queue.clear();
		if (++flushes == 1)
			throw std::runtime_error("failure after queued partial write");
	};
	fails([&]
		  { transaction.draw(enqueue, flush); });
	check(flushes == 2 && atlas == previous && slot->pixels == previous,
		  "deferred upload failure was not rolled back before returning");
	transaction.discard();
	PixelTransaction cleanup({{slot, previous, next, 0}});
	cleanup.draw(enqueue, flush);
	check(queue.empty() && atlas == next && slot->pixels == previous,
		  "lighting publication raced the pending upload");
	cleanup.restore(enqueue, flush);
	check(queue.empty() && atlas == previous, "late restore returned before its queue executed");
	cleanup.discard();
}
int main()
{
	try
	{
		runs();
		transactions();
		queuedTransactions();
		std::cout << "PASS: retained pixel ownership, exact RGBA/AO runs, banks, batch commit, partial/late rollback and lifetime\n";
		return 0;
	}
	catch (const std::exception &e)
	{
		std::cerr << e.what() << '\n';
		return 1;
	}
}
