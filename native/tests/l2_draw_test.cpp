#include "Render/Visibility/VisibilityGraph.h"
#include "Render/Visibility/VisibilityWorker.h"
#include "Mesh/SectionGeometry.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <random>
#include <stdexcept>
#include <thread>
using namespace mcmesh;
using namespace l2draw;
static void check(bool v, const char *message)
{
	if (!v)
		throw std::runtime_error(message);
}
static void portalTests()
{
	VisibilityGraph graph;
	graph.mNodes.resize(5);
	for (unsigned i = 1; i < 5; ++i)
	{
		graph.mNodes[i].mLive = true;
		// Closed other faces: no exterior access from the inside.
		graph.mNodes[i].mExits.fill(0);
	}
	graph.mNodes[1].mNeighbors[2] = 2;
	graph.mNodes[2].mNeighbors[3] = 1;
	graph.mNodes[2].mNeighbors[2] = 3;
	graph.mNodes[3].mNeighbors[3] = 2;
	graph.mNodes[3].mNeighbors[2] = 4;
	graph.mNodes[4].mNeighbors[3] = 3;
	graph.mNodes[2].mExits[3] = 4;
	auto seen = FindReachable(graph, 1, 4);
	check(seen[1] && seen[2] && seen[3] && !seen[4], "portal wall must draw without propagating");
	seen = FindReachable(graph, 1, 0);
	check(seen[1] && !seen[2], "sealed camera pocket must not become exterior");
	graph.mNodes[3].mExits[3] = 4;
	seen = FindReachable(graph, 1, 4);
	check(seen[4], "opened portal did not propagate");
	seen = FindReachable(graph, 0, 63);
	check(seen[1] && seen[4], "virtual exterior omitted boundary walls");
	graph.mNodes[1].mLive = false;
	bool threw = false;
	try
	{
		FindReachable(graph, 1, 63);
	}
	catch (const std::exception &)
	{
		threw = true;
	}
	check(threw, "retired root silently accepted");
}
static void spatialPortalTests()
{
	VisibilityGraph graph;
	graph.mNodes.resize(4);
	// A solid section at x=0 blocks a target at x=1. An unrelated high
	// section expands the air grid so a flood can go over then behind it.
	for (unsigned id = 1; id <= 3; ++id)
		graph.mNodes[id].mLive = true;
	graph.mNodes[1].mPosition = {0, 0, 0};
	graph.mNodes[2].mPosition = {1, 0, 0};
	graph.mNodes[3].mPosition = {0, 0, 2};
	BuildSpatialGraph(graph);
	VisibilityView view;
	view.mPortals = true;
	view.mPortalCell = {-1, 0, 0};
	unsigned visited = 0;
	auto	 seen = FindReachable(graph, view, visited);
	check(seen[1] && !seen[2], "outside camera leaked through/around a section wall");
	// A thin wall inside the root leaves its camera-side five faces open.
	graph.mNodes[1].mExits.fill(63);
	graph.mNodes[1].mExits[3] = 59;
	graph.mNodes[1].mExits[2] = 55;
	BuildSpatialGraph(graph);
	view.mRoot = 1;
	view.mPortalCell = {0, 0, 0};
	view.mSeed = 59;
	seen = FindReachable(graph, view, visited);
	check(seen[1] && !seen[2], "registered camera escaped its wall through exterior air");
	view.mRoot = 0;
	view.mSeed = 63;
	view.mPortalCell = {0, 0, 1}; // Missing air section inside the grid.
	seen = FindReachable(graph, view, visited);
	check(seen[2], "air above wall did not see the target");
	view.mPortalCell = {-1, 0, 0};
	graph.mNodes[1].mExits.fill(63); // Door opens; next immutable graph sees it.
	BuildSpatialGraph(graph);
	seen = FindReachable(graph, view, visited);
	check(seen[2], "opened wall did not reveal target");

	// A negative-coordinate wall blocks the same line; translation does not
	// change the topology, and retired slots must not define spatial bounds.
	graph.mNodes[1].mExits.fill(0);
	graph.mNodes.push_back(PortalNode{});
	graph.mNodes.back().mPosition = {INT32_MAX, 0, 0};
	for (auto &node : graph.mNodes)
		if (node.mLive)
			for (auto &coordinate : node.mPosition)
				coordinate -= 100;
	BuildSpatialGraph(graph);
	view.mPortalCell = {-101, -100, -100};
	seen = FindReachable(graph, view, visited);
	check(graph.mGrid.size() == 6 && seen[1] && !seen[2], "negative/retired spatial coordinates changed visibility");

	auto shared = std::make_shared<VisibilityGraph>(graph);
	auto scene = std::make_shared<VisibilityScene>();
	auto chunk = std::make_shared<VisibilityChunk>();
	chunk->mKey = 7;
	chunk->mSections = {{{}, 1, true, false}, {{}, 1, true, true}};
	scene->mChunks.push_back(chunk);
	shared->mBases[7] = 1; // Both sections refer to target id 2.
	view.mMoveBudget = 100;
	VisibilityWorker worker;
	bool			 cached = false;
	auto			 first = worker.Resolve(1, scene, shared, view, cached);
	check(first->mChunks[0].mSections[0] == ERejectReason::Portal && first->mChunks[0].mSections[1] == ERejectReason::None,
		  "spatial culling ignored bounds/protrusion contract");
	check(worker.Resolve(2, scene, shared, view, cached)->mPortals == first->mPortals,
		  "spatial portal mask was not shared between passes");
	auto moved = view;
	moved.mPortalCell = {-100, -100, -99};
	check(!Covers(*first, scene.get(), shared.get(), moved), "root=0 camera section change reused frame envelope");
	auto second = worker.Resolve(1, scene, shared, moved, cached);
	check(!cached && second->mPortals != first->mPortals && second->mChunks[0].mSections[0] == ERejectReason::None,
		  "moving above wall retained root=0 occlusion cache");
	auto opened = std::make_shared<VisibilityGraph>(*shared);
	opened->mNodes[1].mExits.fill(63);
	BuildSpatialGraph(*opened);
	auto third = worker.Resolve(1, scene, opened, view, cached);
	check(!cached && third->mChunks[0].mSections[0] == ERejectReason::None, "door edit reused old spatial graph");
	worker.Stop();

	VisibilityGraph huge;
	huge.mNodes.resize(3);
	huge.mNodes[1].mLive = huge.mNodes[2].mLive = true;
	huge.mNodes[1].mPosition = {INT32_MIN, 0, 0};
	huge.mNodes[2].mPosition = {INT32_MAX, 0, 0};
	BuildSpatialGraph(huge);
	check(huge.mSpatial && huge.mGrid.empty(), "sparse world exceeded dense spatial allocation limit");
	seen = FindReachable(huge, view, visited);
	check(seen[1] && seen[2], "extent fallback hid disconnected boundary sections");
	huge.mNodes[2].mPosition = huge.mNodes[1].mPosition;
	bool threw = false;
	try
	{
		BuildSpatialGraph(huge);
	}
	catch (const std::exception &)
	{
		threw = true;
	}
	check(threw, "duplicate spatial coordinates were accepted");
	std::cout << "Spatial walls: outside/registered/air cameras, opened door, negative coordinates, protrusions and cache invalidation passed\n";
}
static void spatialRayTests()
{
	// Independent segment/box oracle: every section hit by an unobstructed
	// straight ray must survive the directional portal traversal.
	std::mt19937						   rng(77339);
	std::uniform_real_distribution<double> camera(-3.9, 7.9), point(0.01, 0.99);
	unsigned							   verified = 0;
	for (unsigned world = 0; world < 30; ++world)
	{
		VisibilityGraph graph;
		graph.mNodes.resize(1);
		for (int z = 0; z < 4; ++z)
			for (int y = 0; y < 4; ++y)
				for (int x = 0; x < 4; ++x)
				{
					if (rng() % 3 == 0 && x + y + z != 0 && x + y + z != 9)
						continue; // unregistered air
					PortalNode node;
					node.mLive = true;
					node.mPosition = {x, y, z};
					node.mExits.fill(rng() % 3 == 0 ? 0 : 63);
					graph.mNodes.push_back(node);
				}
		BuildSpatialGraph(graph);
		for (unsigned trial = 0; trial < 80; ++trial)
		{
			Vec			   eye = {camera(rng), camera(rng), camera(rng)};
			VisibilityView view;
			view.mPortals = true;
			for (unsigned a = 0; a < 3; ++a)
				view.mPortalCell[a] = int(std::floor(eye[a]));
			for (unsigned id = 1; id < graph.mNodes.size(); ++id)
				if (graph.mNodes[id].mPosition == view.mPortalCell)
					view.mRoot = id;
			if (view.mRoot && !graph.mNodes[view.mRoot].mExits[0])
				continue; // solid-camera bypass belongs to Lua
			unsigned visited;
			auto	 seen = FindReachable(graph, view, visited);
			for (unsigned target = 1; target < graph.mNodes.size(); ++target)
			{
				Vec end;
				for (unsigned a = 0; a < 3; ++a)
					end[a] = graph.mNodes[target].mPosition[a] + point(rng);
				bool blocked = false;
				for (unsigned id = 1; id < graph.mNodes.size() && !blocked; ++id)
				{
					if (id == target || graph.mNodes[id].mExits[0])
						continue;
					double near = 0, far = 1;
					for (unsigned a = 0; a < 3; ++a)
					{
						const double d = end[a] - eye[a], low = graph.mNodes[id].mPosition[a] - eye[a];
						double		 t0 = low / d, t1 = (low + 1) / d;
						if (t0 > t1)
							std::swap(t0, t1);
						near = std::max(near, t0);
						far = std::min(far, t1);
					}
					blocked = near < far;
				}
				if (!blocked)
				{
					++verified;
					check(seen[target], "directional flood hid a directly visible ray target");
				}
			}
		}
	}
	std::cout << "Spatial ray oracle: " << verified << " directly visible targets preserved in 30 sparse worlds\n";
}
static void spatialBoundaryTests()
{
	VisibilityGraph graph;
	graph.mNodes.resize(1);
	for (int z = 0; z < 3; ++z)
		for (int y = 0; y < 3; ++y)
			for (int x : {0, 2})
			{
				PortalNode node;
				node.mLive = true;
				node.mPosition = {x, y, z};
				node.mExits.fill(x == 0 ? 63 : 0);
				if (x == 0)
				{
					node.mExits[2] = 55;
					node.mExits[3] = 59;
				}
				for (unsigned face = 0; face < 6; ++face)
					for (unsigned b = 0; b < 4; ++b)
						for (unsigned a = 0; a < 4; ++a)
						{
							const unsigned px = face < 2 || face >= 4 ? a : face & 1 ? 0
																					 : 3;
							node.mBoundary[face].push_back(x == 2 || px == 2 ? 64 : px < 2 ? 59
																						   : 55);
						}
				graph.mNodes.push_back(std::move(node));
			}
	BuildSpatialGraph(graph);
	VisibilityView view;
	view.mPortals = true;
	view.mPortalCell = {-1, 1, 1};
	unsigned visited;
	auto	 seen = FindReachable(graph, view, visited);
	for (unsigned id = 1; id < graph.mNodes.size(); ++id)
		check(bool(seen[id]) == (graph.mNodes[id].mPosition[0] == 0), "shared boundary mixed the two sides of a thin wall");
	// A doorway in the center section reconnects both sides. Its first
	// target must become visible, without inventing a new exterior node.
	for (auto &node : graph.mNodes)
		if (node.mPosition == Cell{0, 1, 1})
		{
			node.mExits.fill(63);
			for (auto &face : node.mBoundary)
				std::fill(face.begin(), face.end(), uint8_t(63));
		}
	BuildSpatialGraph(graph);
	seen = FindReachable(graph, view, visited);
	for (unsigned id = 1; id < graph.mNodes.size(); ++id)
		if (graph.mNodes[id].mPosition == Cell{2, 1, 1})
			check(seen[id], "opened component boundary failed to reveal target");
	std::cout << "Spatial boundaries: nine thin-wall target sections hidden, disconnected face regions preserved, doorway restored\n";
}
static void coverageTests()
{
	auto scene = std::make_shared<VisibilityScene>();
	auto chunk = std::make_shared<VisibilityChunk>();
	chunk->mBounds = {{0, 0, 0}, {1, 1, 1}, std::sqrt(3.0)};
	scene->mChunks.push_back(chunk);
	VisibilityView expanded;
	expanded.mPlaneCount = 1;
	expanded.mPlanes[0] = {1, 0, 0};
	expanded.mMoveBudget = 4;
	expanded.mNormalBudget = 0.12;
	expanded.mDistance = 100;
	std::mt19937						   random(9343);
	std::uniform_real_distribution<double> position(-200, 200), eye(-2, 2), angle(-0.11, 0.11);
	for (unsigned trial = 0; trial < 20000; ++trial)
	{
		chunk->mOrigin = {position(random), position(random), position(random)};
		auto		   frame = Compute(scene, nullptr, expanded);
		VisibilityView actual = expanded;
		actual.mEye = {eye(random), eye(random), eye(random)};
		double a = angle(random);
		actual.mPlanes[0] = {std::cos(a), std::sin(a), 0};
		actual.mMoveBudget = actual.mNormalBudget = 0;
		check(Covers(frame, scene.get(), nullptr, actual), "valid conservative coverage rejected");
		if (TestBounds(chunk->mBounds, chunk->mOrigin, actual, true) == ERejectReason::None)
			check(frame.mChunks[0].mReject == ERejectReason::None, "cached candidate omitted a currently visible box");
	}
	auto		   frame = Compute(scene, nullptr, expanded);
	VisibilityView moved = expanded;
	moved.mEye[0] = 4.01;
	check(!Covers(frame, scene.get(), nullptr, moved), "teleport reused old culling");
	moved = expanded;
	moved.mPlanes[0] = {-1, 0, 0};
	check(!Covers(frame, scene.get(), nullptr, moved), "turnaround reused old culling");
	moved = expanded;
	moved.mRoot = 1;
	check(!Covers(frame, scene.get(), nullptr, moved), "portal component change reused culling");
	auto other = std::make_shared<VisibilityScene>(*scene);
	check(!Covers(frame, other.get(), nullptr, expanded), "scene revision reused culling");
	VisibilityGraph graph;
	check(!Covers(frame, scene.get(), &graph, expanded), "graph revision reused culling");
	moved = expanded;
	moved.mPlaneCount = 0;
	check(!Covers(frame, scene.get(), nullptr, moved), "orthographic view reused perspective culling");

	auto topology = std::make_shared<VisibilityGraph>();
	topology->mNodes.resize(3);
	topology->mNodes[1].mLive = topology->mNodes[2].mLive = true;
	topology->mBases[chunk->mKey] = 0;
	chunk->mOrigin = {0, 0, 0};
	chunk->mSections = {{chunk->mBounds, 2, true, false}, {chunk->mBounds, 2, true, true}};
	VisibilityView portal;
	portal.mPortals = true;
	portal.mRoot = 1;
	portal.mSeed = 0;
	frame = Compute(scene, topology, portal);
	check(frame.mChunks[0].mSections[0] == ERejectReason::Portal &&
			  frame.mChunks[0].mSections[1] == ERejectReason::None,
		  "protruding section must bypass owner portal");
}
static void directionTests()
{
	std::vector<l2::Quad> quads;
	for (unsigned g = 0; g < 6; ++g)
	{
		l2::Quad	   quad;
		const unsigned a = g < 2 ? 2 : g < 4 ? 0
											 : 1,
					   b = (a + 1) % 3, c = (a + 2) % 3;
		const float	   x[4] = {0, 1, 1, 0}, y[4] = {0, 0, 1, 1};
		for (unsigned i = 0; i < 4; ++i)
		{
			auto &v = quad.vertices[i];
			v.position[a] = 2;
			v.position[b] = x[i];
			v.position[c] = (g & 1) ? -y[i] : y[i];
			v.normal[a] = (g & 1) ? -1.0f : 1.0f;
			v.color[0] = uint8_t(g * 4 + i);
		}
		quads.push_back(quad);
	}
	auto slope = quads[0];
	slope.vertices[0].position[2] = 1;
	quads.push_back(slope);
	auto mismatch = quads[0];
	mismatch.vertices[0].normal[2] = -1;
	quads.push_back(mismatch);
	quads.push_back(l2::Quad{});
	const auto original = quads;
	auto	   order = l2::directionOrder(quads);
	check(std::memcmp(quads.data(), original.data(), quads.size() * sizeof(l2::Quad)) == 0,
		  "direction grouping mutated atlas/vertex data");
	for (unsigned g = 0; g < 6; ++g)
		check(order.ranges[g].count == 6 && order.quads[order.ranges[g].first / 6] == g, "axis grouping failed");
	check(order.ranges[6].count == 18, "unsafe quad classified directional");
	auto sorted = order.quads;
	std::sort(sorted.begin(), sorted.end());
	for (unsigned i = 0; i < sorted.size(); ++i)
		check(sorted[i] == i, "index ordering lost/duplicated quads");
	float box[6] = {0, 0, 0, 1, 1, 1};
	check(IsDirectionVisible(0, box, {0, 0, 0}, 0), "coplanar face vanished");
	check(!IsDirectionVisible(0, box, {0, 0, -1}, 0), "back face was retained");
	check(IsDirectionVisible(1, box, {0, 0, -1}, 0), "front face was discarded");
	check(IsDirectionVisible(6, box, {0, 0, -100}, 0), "unassigned geometry was discarded");
}
static void workerTests()
{
	VisibilityWorker worker;
	auto			 scene = std::make_shared<VisibilityScene>();
	auto			 chunk = std::make_shared<VisibilityChunk>();
	scene->mChunks.push_back(chunk);
	VisibilityView view;
	view.mMoveBudget = 4;
	auto	   frame = worker.Request(1, scene, nullptr, view);
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (!frame && std::chrono::steady_clock::now() < deadline)
	{
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
		frame = worker.Request(1, scene, nullptr, view);
	}
	check(frame && frame->mError.empty() && frame->mChunks.size() == 1, "visibility worker produced no usable frame");
	auto other = std::make_shared<VisibilityScene>(*scene);
	check(!worker.Request(1, other, nullptr, view), "worker accepted retired scene");
	for (uint64_t lane = 2; lane < 100; ++lane)
	{
		worker.Request(lane, scene, nullptr, view);
		worker.Forget(lane);
	}
	worker.Stop();
	check(!worker.Request(1, scene, nullptr, view), "worker restart reused retired result");
	worker.Stop();
}
static std::mutex			   gateMutex;
static std::condition_variable gateWake;
static bool					   gateEntered = false, gateReleased = false;
static VisibilityFrame		   gatedCompute(std::shared_ptr<const VisibilityScene> scene, std::shared_ptr<const VisibilityGraph> graph, const VisibilityView &view,
											std::shared_ptr<const PortalMask> portals)
{
	{
		std::unique_lock<std::mutex> lock(gateMutex);
		gateEntered = true;
		gateWake.notify_all();
		gateWake.wait(lock, []
					  { return gateReleased; });
	}
	return Compute(std::move(scene), std::move(graph), view, std::move(portals));
}
static void coalescingTests()
{
	VisibilityWorker worker(gatedCompute);
	auto			 scene = std::make_shared<VisibilityScene>();
	scene->mChunks.push_back(std::make_shared<VisibilityChunk>());
	VisibilityView view;
	view.mMoveBudget = 4;
	worker.Request(1, scene, nullptr, view);
	bool started;
	{
		std::unique_lock<std::mutex> lock(gateMutex);
		started = gateWake.wait_for(lock, std::chrono::seconds(5), []
									{ return gateEntered; });
	}
	for (unsigned i = 0; i < 100; ++i)
		worker.Request(1, scene, nullptr, view);
	const auto during = worker.GetStats();
	{
		std::lock_guard<std::mutex> lock(gateMutex);
		gateReleased = true;
	}
	gateWake.notify_all();
	worker.Stop();
	std::cout << "Same-view requests=101, scheduled=" << during.mScheduled << ", coalesced=" << during.mCoalesced << '\n';
	check(started, "visibility worker did not start");
	check(during.mScheduled == 1 && during.mCoalesced == 100,
		  "identical in-flight visibility requests scheduled duplicate computation");
}
static void resolveTests()
{
	VisibilityWorker worker;
	auto			 scene = std::make_shared<VisibilityScene>();
	auto			 chunk = std::make_shared<VisibilityChunk>();
	chunk->mBounds = {{0, 0, 0}, {1, 1, 1}, std::sqrt(3.0)};
	chunk->mSections = {{chunk->mBounds, 2, true, false}};
	scene->mChunks.push_back(chunk);
	auto graph = std::make_shared<VisibilityGraph>();
	graph->mNodes.resize(3);
	graph->mNodes[1].mLive = graph->mNodes[2].mLive = true;
	graph->mBases[0] = 0;
	VisibilityView view;
	view.mPortals = true;
	view.mRoot = 1;
	view.mSeed = 0;
	view.mMoveBudget = 4;
	bool	   cached = true;
	const auto first = worker.Resolve(1, scene, graph, view, cached);
	check(!cached && first->mChunks[0].mSections[0] == ERejectReason::Portal, "cold render selection did not cull hidden section");
	for (unsigned i = 0; i < 100; ++i)
	{
		check(worker.Resolve(1, scene, graph, view, cached) == first && cached,
			  "stationary render selection recomputed culling");
	}
	auto stats = worker.GetStats();
	check(stats.mSynchronous == 1 && stats.mScheduled == 0 && stats.mPortalTraversals == 1,
		  "cold render selection computed the same view on main and worker threads");
	auto	   secondScene = std::make_shared<VisibilityScene>(*scene);
	const auto second = worker.Resolve(2, secondScene, graph, view, cached);
	check(!cached && first->mPortals == second->mPortals, "opaque/depth scenes repeated the same portal flood");
	auto moved = view;
	moved.mEye[0] = 3;
	worker.Resolve(1, scene, graph, moved, cached);
	check(cached, "conservative coverage expired before background refresh");
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (worker.GetStats().mCompleted == 0 && std::chrono::steady_clock::now() < deadline)
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	const auto refreshed = worker.Resolve(1, scene, graph, moved, cached);
	stats = worker.GetStats();
	check(cached && refreshed->mView.mEye == moved.mEye && stats.mScheduled == 1 && stats.mCompleted == 1 && stats.mPortalTraversals == 1 && stats.mPortalCacheHits == 2,
		  "camera movement did not reuse portal connectivity during background refresh");
	auto revised = std::make_shared<VisibilityGraph>(*graph);
	worker.Resolve(1, scene, revised, moved, cached);
	check(!cached && worker.GetStats().mPortalTraversals == 2, "graph revision reused obsolete portal connectivity");
	moved.mRoot = 2;
	const auto newRoot = worker.Resolve(1, scene, revised, moved, cached);
	check(!cached && newRoot->mChunks[0].mSections[0] == ERejectReason::None && worker.GetStats().mPortalTraversals == 3,
		  "camera portal root change reused a sealed component");
	worker.Stop();
	std::cout << "Render selection: 101 stationary draws = 1 cull, portal reuse across movement/passes, revision invalidation passed\n";
}
static VisibilityFrame gatedRefresh(std::shared_ptr<const VisibilityScene> scene, std::shared_ptr<const VisibilityGraph> graph, const VisibilityView &view,
									std::shared_ptr<const PortalMask> portals)
{
	if (view.mEye[0] == 3)
		return gatedCompute(std::move(scene), std::move(graph), view, std::move(portals));
	return Compute(std::move(scene), std::move(graph), view, std::move(portals));
}
static void lateRefreshTests()
{
	{
		std::lock_guard<std::mutex> lock(gateMutex);
		gateEntered = gateReleased = false;
	}
	VisibilityWorker worker(gatedRefresh);
	struct Release
	{
		~Release()
		{
			{
				std::lock_guard<std::mutex> lock(gateMutex);
				gateReleased = true;
			}
			gateWake.notify_all();
		}
	} release;
	auto scene = std::make_shared<VisibilityScene>();
	scene->mChunks.push_back(std::make_shared<VisibilityChunk>());
	VisibilityView view;
	view.mMoveBudget = 4;
	bool cached;
	worker.Resolve(1, scene, nullptr, view, cached);
	view.mEye[0] = 3;
	worker.Resolve(1, scene, nullptr, view, cached);
	{
		std::unique_lock<std::mutex> lock(gateMutex);
		check(gateWake.wait_for(lock, std::chrono::seconds(5), []
								{ return gateEntered; }),
			  "refresh did not start");
	}
	view.mEye[0] = 100;
	const auto teleported = worker.Resolve(1, scene, nullptr, view, cached);
	check(!cached, "teleport used obsolete conservative coverage");
	{
		std::lock_guard<std::mutex> lock(gateMutex);
		gateReleased = true;
	}
	gateWake.notify_all();
	const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
	while (worker.GetStats().mCompleted == 0 && std::chrono::steady_clock::now() < deadline)
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	check(worker.Resolve(1, scene, nullptr, view, cached) == teleported && cached && worker.GetStats().mSynchronous == 2, "late background result overwrote current camera culling");
}
int main()
{
	try
	{
		portalTests();
		spatialPortalTests();
		spatialBoundaryTests();
		spatialRayTests();
		coverageTests();
		directionTests();
		workerTests();
		coalescingTests();
		resolveTests();
		lateRefreshTests();
		std::cout << "PASS: portals, 20000 conservative-coverage trials, directions, immutable atlas order, worker lifecycle\n";
		return 0;
	}
	catch (const std::exception &e)
	{
		std::cerr << e.what() << '\n';
		return 1;
	}
}
