#include "Core/CpuWorkGate.h"
#include <chrono>
#include <exception>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

using namespace mcmesh::core;
namespace
{
void Check(bool inValue, const char *inMessage)
{
	if (!inValue)
		throw std::runtime_error(inMessage);
}
template <class Predicate>
void WaitUntil(Predicate inPredicate)
{
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (!inPredicate())
	{
		Check(std::chrono::steady_clock::now() < deadline, "CPU gate test timed out");
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}
// Cancellation/join also runs when a test assertion throws while a slot is held.
class TestWorkers
{
public:
	explicit TestWorkers(CpuWorkGate &inGate) : mGate(inGate) {}
	~TestWorkers()
	{
		mCancelled.store(true);
		mGate.NotifyCancellation();
		Join();
	}
	template <class Work>
	void Start(Work inWork)
	{
		mThreads.emplace_back([this, work = std::move(inWork)]
		{
			try
			{
				work();
			}
			catch (...)
			{
				std::lock_guard<std::mutex> lock(mMutex);
				mError = std::current_exception();
			}
		});
	}
	void Join()
	{
		for (auto &thread : mThreads)
			if (thread.joinable())
				thread.join();
	}
	void Rethrow()
	{
		std::lock_guard<std::mutex> lock(mMutex);
		if (mError)
			std::rethrow_exception(mError);
	}
	std::atomic<bool> mCancelled{false};

private:
	CpuWorkGate &mGate;
	std::vector<std::thread> mThreads;
	std::mutex mMutex;
	std::exception_ptr mError;
};
void GlobalConcurrency()
{
	CpuWorkGate gate(3);
	std::atomic<bool> release{false};
	std::atomic<unsigned> completed{0};
	TestWorkers workers(gate);
	for (unsigned i = 0; i < 24; ++i)
		workers.Start([&, work_class = ECpuWorkClass(i % cCpuWorkClassCount)]
		{
			auto permit = gate.Acquire(work_class, workers.mCancelled);
			if (!permit)
				return;
			while (!release.load() && !workers.mCancelled.load())
				std::this_thread::yield();
			const auto stats = gate.GetStats();
			Check(stats.mActive <= 3 && stats.mPeakActive <= 3, "work classes exceeded their shared CPU limit");
			++completed;
		});
	WaitUntil([&] { return gate.GetStats().mActive == 3 && gate.GetStats().mQueued == 21; });
	release.store(true);
	WaitUntil([&] { return completed.load() == 24; });
	workers.Join();
	workers.Rethrow();
	const auto stats = gate.GetStats();
	Check(stats.mActive == 0 && stats.mQueued == 0 && stats.mAdmitted == 24 && stats.mPeakActive == 3,
		"shared concurrency accounting did not return to idle");
	for (size_t i = 0; i < cCpuWorkClassCount; ++i)
		Check(stats.mActiveByClass[i] == 0 && stats.mQueuedByClass[i] == 0, "per-class accounting leaked");
}
void FairDispatchAndFIFO()
{
	CpuWorkGate gate(1);
	std::atomic<bool> cancelled{false};
	auto blocker = gate.Acquire(ECpuWorkClass::Mesh, cancelled);
	std::mutex order_mutex;
	std::vector<unsigned> order;
	TestWorkers workers(gate);
	const ECpuWorkClass classes[] = {ECpuWorkClass::Visibility, ECpuWorkClass::Visibility,
		ECpuWorkClass::Visibility, ECpuWorkClass::Decode, ECpuWorkClass::Lighting, ECpuWorkClass::Mesh};
	for (unsigned i = 0; i < 6; ++i)
	{
		workers.Start([&, i]
		{
			auto permit = gate.Acquire(classes[i], workers.mCancelled);
			if (permit)
			{
				std::lock_guard<std::mutex> lock(order_mutex);
				order.push_back(i);
			}
		});
		WaitUntil([&] { return gate.GetStats().mQueued == i + 1; });
	}
	blocker.Reset();
	WaitUntil([&] { return gate.GetStats().mAdmitted == 7 && gate.GetStats().mActive == 0; });
	workers.Join();
	workers.Rethrow();
	Check(order == std::vector<unsigned>({0, 3, 1, 4, 2, 5}), "weighted dispatch starved a work class or broke FIFO");
}
void CancelledWaitCanJoin()
{
	CpuWorkGate gate(1);
	std::atomic<bool> cancelled{false};
	auto blocker = gate.Acquire(ECpuWorkClass::Mesh, cancelled);
	std::atomic<unsigned> returned{0};
	TestWorkers workers(gate);
	for (size_t i = 0; i < cCpuWorkClassCount; ++i)
		workers.Start([&, work_class = ECpuWorkClass(i)]
		{
			Check(!gate.Acquire(work_class, workers.mCancelled), "cancelled waiter obtained a CPU slot");
			++returned;
		});
	WaitUntil([&] { return gate.GetStats().mQueued == cCpuWorkClassCount; });
	workers.mCancelled.store(true);
	gate.NotifyCancellation();
	// The occupied slot remains held: shutdown must not depend on its release.
	WaitUntil([&] { return returned.load() == cCpuWorkClassCount; });
	workers.Join();
	workers.Rethrow();
	const auto stats = gate.GetStats();
	Check(stats.mQueued == 0 && stats.mActive == 1 && stats.mCancelled == cCpuWorkClassCount,
		"cancelled admission changed active-slot accounting");
	Check(!gate.Acquire(ECpuWorkClass::Decode, workers.mCancelled), "pre-cancelled admission waited");
}
void PermitLifetime()
{
	struct ComputeFailure {};
	CpuWorkGate gate(1);
	std::atomic<bool> cancelled{false};
	try
	{
		auto first = gate.Acquire(ECpuWorkClass::Lighting, cancelled);
		auto second = std::move(first);
		Check(!first && second && gate.GetStats().mActive == 1, "permit move changed the execution count");
		CpuWorkPermit third;
		third = std::move(second);
		Check(!second && third, "permit move assignment lost ownership");
		throw ComputeFailure{};
	}
	catch (const ComputeFailure &)
	{
	}
	Check(gate.GetStats().mActive == 0, "exception leaked a CPU slot");
	auto next = gate.Acquire(ECpuWorkClass::Decode, cancelled);
	next.Reset();
	next.Reset();
	Check(gate.GetStats().mActive == 0 && gate.GetStats().mAdmitted == 2, "permit reset released twice");
}
} // namespace
int main()
{
	try
	{
		GlobalConcurrency();
		FairDispatchAndFIFO();
		CancelledWaitCanJoin();
		PermitLifetime();
		std::cout << "CPU gate: shared limit, weighted FIFO, cancellation/join and permit lifetime passed\n";
		return 0;
	}
	catch (const std::exception &error)
	{
		std::cerr << error.what() << '\n';
		return 1;
	}
}
