#pragma once

#include "Mesh/SectionWorker.h"
#include <memory>
#include <unordered_map>
#include <vector>

namespace mcmesh::world
{
struct MeshSnapshot;
}

namespace mcmesh::l2
{
struct RelightLayout
{
	std::shared_ptr<PixelSlot> mSlot;
	unsigned				   mFirst, mCount;
};

/// Owns section jobs and the immutable world tickets needed to publish them.
/// Public calls run on the main thread; WorkerPool owns all worker synchronization.
/// Relight targets are weak: queued work never extends a mesh resource's lifetime.
class SectionTasks
{
public:
	bool									   PrepareSubmission();
	bool									   CanSubmit() const;
	uint64_t								   Submit(std::unique_ptr<Input>					 inInput,
													  std::shared_ptr<const world::MeshSnapshot> inSource = {},
													  std::vector<std::weak_ptr<PixelSlot>>		 inTargets = {});
	std::shared_ptr<const Job>				   GetReady(uint64_t inId) const;
	JobState								   GetState(uint64_t inId) const;
	WorkerStats								   GetStats() const;
	std::shared_ptr<const world::MeshSnapshot> GetSource(uint64_t inId) const;
	std::unique_ptr<PixelTransaction>		   StageRelight(uint64_t inId, const std::vector<RelightLayout> &inLayout) const;
	void									   Cancel(uint64_t inId);
	void									   Shutdown();

private:
	struct Ticket
	{
		std::shared_ptr<const world::MeshSnapshot> mSource;
		std::vector<std::weak_ptr<PixelSlot>>	   mTargets;
	};
	WorkerPool							 mWorkers;
	std::unordered_map<uint64_t, Ticket> mTickets;
};

SectionTasks &GetSectionTasks();
} // namespace mcmesh::l2
