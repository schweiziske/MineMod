#include "Mesh/SectionTasks.h"
#include "World/WorldStore.h"
#include <utility>

namespace mcmesh::l2
{
namespace
{
SectionTasks sSectionTasks;
}

SectionTasks &GetSectionTasks()
{
	return sSectionTasks;
}

bool SectionTasks::PrepareSubmission()
{
	mWorkers.start();
	return mWorkers.canSubmit();
}

bool SectionTasks::CanSubmit() const
{
	return mWorkers.canSubmit();
}
std::shared_ptr<const Job> SectionTasks::GetReady(uint64_t inId) const
{
	return mWorkers.ready(inId);
}
JobState SectionTasks::GetState(uint64_t inId) const
{
	return mWorkers.state(inId);
}
WorkerStats SectionTasks::GetStats() const
{
	return mWorkers.stats();
}

uint64_t SectionTasks::Submit(std::unique_ptr<Input>					 inInput,
							  std::shared_ptr<const world::MeshSnapshot> inSource, std::vector<std::weak_ptr<PixelSlot>> inTargets)
{
	const auto id = mWorkers.submit(std::move(inInput));
	if (!id)
		return 0;
	try
	{
		if (inSource || !inTargets.empty())
			mTickets.emplace(id, Ticket{std::move(inSource), std::move(inTargets)});
	}
	catch (...)
	{
		// Allocation failure after submission must not leave an untracked job.
		mWorkers.cancel(id);
		throw;
	}
	return id;
}

std::shared_ptr<const world::MeshSnapshot> SectionTasks::GetSource(uint64_t inId) const
{
	const auto found = mTickets.find(inId);
	return found == mTickets.end() ? nullptr : found->second.mSource;
}

std::unique_ptr<PixelTransaction> SectionTasks::StageRelight(uint64_t inId, const std::vector<RelightLayout> &inLayout) const
{
	const auto job = GetReady(inId);
	require(job->error.empty(), job->error.c_str());
	require(job->relight && inLayout.size() == job->parts.size(), "invalid Native L2 relight layout");
	const auto found = mTickets.find(inId);
	require(found != mTickets.end() && found->second.mTargets.size() == job->parts.size(),
			"Native L2 relight targets are unavailable");
	std::vector<PixelUpdate> updates;
	updates.reserve(inLayout.size());
	for (size_t i = 0; i < inLayout.size(); ++i)
	{
		const auto &layout = inLayout[i];
		require(layout.mSlot && layout.mSlot->live && layout.mSlot->pixels, "Native L2 relight mesh was destroyed or changed");
		require(layout.mSlot == found->second.mTargets[i].lock(), "Native L2 relight mesh order changed");
		job->parts[i].pixels->validate(layout.mCount);
		updates.push_back({layout.mSlot, layout.mSlot->pixels, job->parts[i].pixels, layout.mFirst});
	}
	return std::make_unique<PixelTransaction>(std::move(updates));
}

void SectionTasks::Cancel(uint64_t inId)
{
	mWorkers.cancel(inId);
	if (inId)
		mTickets.erase(inId);
	else
		mTickets.clear();
}

void SectionTasks::Shutdown()
{
	mWorkers.stop();
	mTickets.clear();
}
} // namespace mcmesh::l2
