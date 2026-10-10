#pragma once
#include "World/LightWorker.h"
#include "World/WorldDecoder.h"

namespace mcmesh::world
{
struct PumpResult
{
	bool		 completed = false, submitted = false, pending = false;
	uint64_t	 job = 0;
	CommitResult commit;
	std::string	 error;
	double		 computeMS = 0, diffMS = 0, commitMS = 0, snapshotMS = 0;
	uint64_t	 scannedCells = 0;
};
// Owned and pumped on the Lua thread, with no Lua/Source dependencies. Multiple
// edits between pumps become one snapshot; an in-flight job is never restarted
// merely because more terrain arrived.
class Session
{
public:
	Session(Config config, std::shared_ptr<const Catalog> catalog) : store_(config, std::move(catalog)) {}
	const Store		&store() const { return store_; }
	bool			 apply(uint64_t revision, const std::vector<Mutation> &batch);
	uint64_t		 startDecode(DecodeMetadata metadata, std::vector<uint8_t> payload);
	DecodeStatus	 pollDecode(uint64_t id) const { return decoder_.poll(id); }
	void			 cancelDecode(uint64_t id) { decoder_.release(id); }
	void			 cancelAllDecodes() { decoder_.cancelAll(); }
	bool			 commitDecode(uint64_t revision, uint64_t id, const std::vector<unsigned> &include,
								  const std::vector<Mutation> &contexts);
	void			 reset(Config config, std::shared_ptr<const Catalog> catalog);
	void			 reconfigure(Config config);
	void			 requestLight();
	PumpResult		 pump();
	LightWorkerStats workerStats() const { return worker_.stats(); }
	double			 commitMS() const { return commitMS_; }
	double			 snapshotMS() const { return snapshotMS_; }
	bool			 pending() const { return dirty_ || worker_.stats().busy; }

private:
	Store		 store_;
	LightWorker	 worker_;
	DecodeWorker decoder_;
	bool		 dirty_ = false, failed_ = false;
	double		 commitMS_ = 0, snapshotMS_ = 0;
};
} // namespace mcmesh::world
