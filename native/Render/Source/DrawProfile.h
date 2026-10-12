#pragma once
#include <array>
#include <chrono>
#include <cstddef>

namespace mcmesh::source
{
enum class EDrawPhase
{
	PixelFlush,
	Visibility,
	ChunkCallback,
	MaterialBind,
	MeshDraw,
	Overlay,
	Count
};

/// Opt-in main-thread wall-time probe. Source calls can enqueue work or wait;
/// these durations are not GPU timestamps. Disabled probes never read a clock.
class DrawProfile
{
public:
	using Clock = std::chrono::steady_clock;
	using TimePoint = Clock::time_point;

	explicit DrawProfile(bool inEnabled) : mEnabled(inEnabled), mStarted(Start())
	{
	}

	TimePoint Start() const { return mEnabled ? Clock::now() : TimePoint{}; }

	void Add(EDrawPhase inPhase, TimePoint inStarted)
	{
		if (mEnabled)
			mMilliseconds[static_cast<size_t>(inPhase)] += std::chrono::duration<double, std::milli>(Clock::now() - inStarted).count();
	}

	double Get(EDrawPhase inPhase) const { return mMilliseconds[static_cast<size_t>(inPhase)]; }
	double GetTotalMS() const { return mEnabled ? std::chrono::duration<double, std::milli>(Clock::now() - mStarted).count() : 0; }
	bool IsEnabled() const { return mEnabled; }

private:
	bool	  mEnabled;
	TimePoint mStarted;
	std::array<double, static_cast<size_t>(EDrawPhase::Count)> mMilliseconds{};
};
} // namespace mcmesh::source
