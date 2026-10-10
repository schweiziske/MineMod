#pragma once
#include "Mesh/SectionGeometry.h"
#include <algorithm>
#include <cmath>
#include <exception>
#include <stdexcept>
#include <string>
#include <unordered_set>

namespace mcmesh::l2
{
// Workers produce this allocation once. Meshes retain it without retaining the
// job, its geometry, or its world snapshot. Published pixels are immutable.
struct LightPixels
{
	std::vector<uint32_t> corners, occlusion;
	explicit LightPixels(size_t quads = 0) : corners(quads * 4), occlusion(quads) {}
	size_t bytes() const
	{
		return sizeof(*this) + (corners.capacity() + occlusion.capacity()) * sizeof(uint32_t);
	}
	void validate(size_t quads) const
	{
		require(quads > 0 && quads <= MaxQuads && corners.size() == quads * 4 && occlusion.size() == quads, "invalid Native L2 pixel layout");
	}
};

// Main-thread ownership. Transactions can outlive Destroy, but may never
// publish into a destroyed mesh or overwrite a newer lighting transaction.
struct PixelSlot
{
	std::shared_ptr<const LightPixels> pixels;
	bool							   live = true;
};
struct PixelUpdate
{
	std::shared_ptr<PixelSlot>		   target;
	std::shared_ptr<const LightPixels> previous, next;
	unsigned						   first = 0;
};

struct PixelRun
{
	int		 x, y, length;
	uint32_t color;
};
inline void appendPixelRun(std::vector<PixelRun> &runs, int x, int y, uint32_t color)
{
	if (!runs.empty() && runs.back().y == y && runs.back().x + runs.back().length == x && runs.back().color == color)
		++runs.back().length;
	else
		runs.push_back({x, y, 1, color});
}
inline void appendPixelRuns(std::vector<PixelRun> &runs, int width, unsigned first,
							const std::vector<uint32_t> &pixels, double scale, double offset)
{
	for (size_t i = 0; i < pixels.size(); ++i)
	{
		const auto pixel = first + unsigned(i);
		appendPixelRun(runs, int(pixel % width), int(std::floor((pixel / width) * scale + offset)), pixels[i]);
	}
}
inline void validatePixelRange(const LightPixels &pixels, int width, int height, unsigned first)
{
	pixels.validate(pixels.occlusion.size());
	require(width > 0 && height >= 5 && first <= uint64_t(width) * (height / 5) && pixels.occlusion.size() <= uint64_t(width) * (height / 5) - first,
			"Native L2 pixels exceed the corner atlas");
	require(first % AtlasQuads + pixels.occlusion.size() <= AtlasQuads,
			"Native L2 pixels cross an address bank");
}

// GPU drawing is injected so the production rollback/commit protocol is also
// exercised by CPU tests. No Lua values or Source resources enter this type.
class PixelTransaction
{
public:
	explicit PixelTransaction(std::vector<PixelUpdate> updates) : updates_(std::move(updates))
	{
		require(!updates_.empty(), "empty Native L2 lighting transaction");
		std::unordered_set<const PixelSlot *>	   targets;
		std::vector<std::pair<uint64_t, uint64_t>> ranges;
		for (const auto &update : updates_)
		{
			require(update.target && update.previous && update.next, "missing Native L2 lighting payload");
			update.previous->validate(update.next->occlusion.size());
			update.next->validate(update.previous->occlusion.size());
			require(targets.insert(update.target.get()).second, "duplicate Native L2 relight mesh");
			ranges.emplace_back(update.first, update.first + uint64_t(update.next->occlusion.size()));
		}
		std::sort(ranges.begin(), ranges.end());
		for (size_t i = 1; i < ranges.size(); ++i)
			require(ranges[i - 1].second <= ranges[i].first, "overlapping Native L2 relight ranges");
		validate();
	}
	const std::vector<PixelUpdate> &updates() const { return updates_; }
	void							validate() const
	{
		require(!finished_, "Native L2 lighting transaction was released");
		for (const auto &update : updates_)
			require(update.target->live && update.target->pixels == update.previous,
					"Native L2 relight mesh was destroyed or changed");
	}
	template <class Draw>
	void draw(Draw &&drawPixels)
	{
		draw(drawPixels, [] {});
	}
	template <class Draw, class Flush>
	void draw(Draw &&drawPixels, Flush &&flush)
	{
		validate();
		require(attempted_ == 0, "Native L2 lighting transaction already drawn");
		try
		{
			for (const auto &update : updates_)
			{
				++attempted_; // Include a part that fails after a partial GPU write.
				drawPixels(update.next, update.first);
			}
			flush();
		}
		catch (...)
		{
			const auto failure = std::current_exception();
			try
			{
				restore(drawPixels, flush);
			}
			catch (const std::exception &e)
			{
				throw std::runtime_error(std::string("Native L2 atlas rollback failed: ") + e.what());
			}
			std::rethrow_exception(failure);
		}
	}
	template <class Draw>
	void restore(Draw &&drawPixels)
	{
		restore(drawPixels, [] {});
	}
	template <class Draw, class Flush>
	void restore(Draw &&drawPixels, Flush &&flush)
	{
		validate();
		std::exception_ptr failure;
		for (size_t i = 0; i < attempted_; ++i)
		{
			try
			{
				drawPixels(updates_[i].previous, updates_[i].first);
			}
			catch (...)
			{
				if (!failure)
					failure = std::current_exception();
			}
		}
		try
		{
			flush();
		}
		catch (...)
		{
			if (!failure)
				failure = std::current_exception();
		}
		if (failure)
			std::rethrow_exception(failure);
		attempted_ = 0;
	}
	int64_t commit()
	{
		validate();
		require(attempted_ == updates_.size(), "Native L2 lighting has not been uploaded");
		int64_t bytes = 0;
		// Validation is complete; pointer publication cannot partially fail.
		for (auto &update : updates_)
		{
			bytes += int64_t(update.next->bytes()) - int64_t(update.previous->bytes());
			update.target->pixels = std::move(update.next);
		}
		attempted_ = 0;
		finished_ = true;
		updates_.clear();
		return bytes;
	}
	void discard()
	{
		require(attempted_ == 0, "restore Native L2 atlas pixels before discarding the transaction");
		finished_ = true;
		updates_.clear();
	}
	void shutdown() noexcept
	{
		// The owning meshes/atlas have already been retired by module shutdown.
		attempted_ = 0;
		finished_ = true;
		updates_.clear();
	}

private:
	std::vector<PixelUpdate> updates_;
	size_t					 attempted_ = 0;
	bool					 finished_ = false;
};
} // namespace mcmesh::l2
