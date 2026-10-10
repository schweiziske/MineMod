#include "World/WorldSession.h"
#include <chrono>
#include <stdexcept>
#include <unordered_set>

namespace mcmesh::world
{
bool Session::apply(uint64_t revision, const std::vector<Mutation> &batch)
{
	const auto before = store_.revision();
	if (!store_.apply(revision, batch))
		return false;
	if (before != store_.revision())
		requestLight();
	return true;
}
uint64_t Session::startDecode(DecodeMetadata metadata, std::vector<uint8_t> payload)
{
	return decoder_.submit({store_.config(), store_.catalog(), store_.epoch(), metadata, std::move(payload)});
}
bool Session::commitDecode(uint64_t revision, uint64_t id, const std::vector<unsigned> &include,
						   const std::vector<Mutation> &contexts)
{
	const auto status = decoder_.poll(id);
	if (status.state != DecodeState::Ready || !status.result)
		throw std::runtime_error("native binary decode is not ready");
	const auto			  &decoded = *status.result;
	PreparedBatch		   selected{decoded.prepared.epoch, decoded.prepared.catalog, {}};
	Grid<const Mutation *> overlays;
	for (const auto &row : contexts)
	{
		if (!overlays.emplace(row.chunk, &row).second)
			throw std::runtime_error("duplicate binary context chunk");
	}
	for (const auto index : include)
	{
		if (index >= decoded.chunks.size())
			throw std::runtime_error("invalid binary include index");
		const auto &chunk = decoded.chunks[index];
		if (!selected.chunks.emplace(chunk.coord, decoded.prepared.chunks.at(chunk.coord)).second)
			throw std::runtime_error("duplicate binary include index");
		const auto	 overlay = overlays.find(chunk.coord);
		const size_t count = overlay == overlays.end() ? 0 : overlay->second->contexts.size();
		if (count != chunk.contextCells.size())
			throw std::runtime_error("missing typed binary lighting contexts");
		if (overlay != overlays.end())
		{
			std::unordered_set<unsigned> required;
			for (const auto &cell : chunk.contextCells)
				required.insert(cell.index);
			for (const auto &context : overlay->second->contexts)
			{
				if (context.clear || !required.erase(context.index))
					throw std::runtime_error("invalid typed binary lighting context");
			}
		}
	}
	for (const auto &entry : overlays)
	{
		if (selected.chunks.find(entry.first) == selected.chunks.end())
			throw std::runtime_error("binary context is outside include selection");
	}
	const auto before = store_.revision();
	if (!store_.applyPrepared(revision, selected, contexts))
		return false;
	decoder_.release(id);
	if (before != store_.revision())
		requestLight();
	return true;
}
void Session::requestLight()
{
	dirty_ = true;
	failed_ = false;
}
void Session::reset(Config config, std::shared_ptr<const Catalog> catalog)
{
	// Validation/sealing can fail. Do that before cancelling the old session.
	store_.reset(config, std::move(catalog));
	worker_.cancel();
	decoder_.cancelAll();
	dirty_ = failed_ = false;
}
void Session::reconfigure(Config config)
{
	store_.reconfigure(config);
	worker_.cancel();
	decoder_.cancelAll();
	requestLight();
}
PumpResult Session::pump()
{
	PumpResult result;
	if (auto completion = worker_.take())
	{
		result.completed = true;
		result.job = completion->id;
		if (!completion->cancelled)
		{
			if (!completion->error.empty())
			{
				result.error = std::move(completion->error);
				failed_ = true;
			}
			else if (completion->result)
			{
				const auto started = std::chrono::steady_clock::now();
				result.commit = store_.commit(*completion->result);
				result.commitMS = std::chrono::duration<double, std::milli>(
									  std::chrono::steady_clock::now() - started)
									  .count();
				commitMS_ += result.commitMS;
				result.computeMS = completion->result->computeMS;
				result.diffMS = completion->result->diffMS;
				result.scannedCells = completion->result->scannedCells;
				if (!result.commit.stale && result.commit.deferred > 0)
					dirty_ = true;
			}
		}
	}
	if (dirty_ && !failed_ && !worker_.stats().busy)
	{
		const auto started = std::chrono::steady_clock::now();
		auto	   snapshot = store_.snapshot();
		result.snapshotMS = std::chrono::duration<double, std::milli>(
								std::chrono::steady_clock::now() - started)
								.count();
		snapshotMS_ += result.snapshotMS;
		const auto id = worker_.submit(std::move(snapshot));
		if (id != 0)
		{
			dirty_ = false;
			result.submitted = true;
			result.job = id;
		}
	}
	result.pending = pending();
	return result;
}
} // namespace mcmesh::world
