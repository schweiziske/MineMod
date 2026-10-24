#include "Module/Pch.h"
#include "Bindings/DrawBindings.h"
#include "Render/Visibility/VisibilityGraph.h"
#include "Render/Visibility/VisibilityWorker.h"
#include "Bindings/MeshBindings.h"
#include "Render/Source/MeshResource.h"
#include "Render/Source/EngineContext.h"
#include "Render/Source/DrawProfile.h"
#include "Resources/Source/PixelTextureStore.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <unordered_set>

namespace mcmesh::l2drawbridge
{
using namespace GarrysMod::Lua;
namespace
{
int											   sceneType = -1;
uint64_t									   nextLane = 0;
l2draw::VisibilityWorker					   worker;
std::shared_ptr<const l2draw::VisibilityGraph> currentGraph;
struct Ref
{
	ILuaBase *lua;
	int		  id;
	explicit Ref(ILuaBase *l, int index) : lua(l)
	{
		lua->Push(index);
		id = lua->ReferenceCreate();
	}
	~Ref() { lua->ReferenceFree(id); }
};
struct Mesh
{
	source::DrawResource *resource = nullptr;
	std::shared_ptr<Ref>  material;
	IMaterial			 *identity = nullptr;
	bool				  cullable = false;
};
struct Section
{
	unsigned first = 0, end = 0;
	uint64_t vertices = 0;
};
struct Chunk
{
	std::shared_ptr<Ref>						   list;
	std::shared_ptr<const l2draw::VisibilityChunk> cpu;
	std::vector<Mesh>							   meshes;
	std::vector<Section>						   sections;
	uint64_t									   vertices = 0;
};
struct Scene
{
	bool										   drawing = false;
	std::vector<std::unique_ptr<Chunk>>			   chunks;
	std::shared_ptr<const l2draw::VisibilityScene> cpu;
	uint64_t									   lanes[3] = {++nextLane, ++nextLane, ++nextLane};
	void										   clear()
	{
		for (auto lane : lanes)
			worker.Forget(lane);
		chunks.clear();
		cpu.reset();
	}
	~Scene() { clear(); }
};
std::unordered_set<Scene *> scenes;
int							absolute(ILuaBase *lua, int at)
{
	return at > 0 ? at : lua->Top() + at + 1;
}
double numeric(ILuaBase *lua, int at)
{
	l2::require(lua->IsType(at, Type::Number), "Native draw requires a numeric field");
	const double v = lua->GetNumber(at);
	l2::require(std::isfinite(v), "Native draw received a non-finite field");
	return v;
}
double field(ILuaBase *lua, int at, const char *name)
{
	lua->GetField(at, name);
	const double v = numeric(lua, -1);
	lua->Pop();
	return v;
}
double item(ILuaBase *lua, int at, size_t index)
{
	lua->PushNumber(static_cast<double>(index));
	lua->RawGet(at);
	const double v = numeric(lua, -1);
	lua->Pop();
	return v;
}
bool boolean(ILuaBase *lua, int at, const char *name)
{
	lua->GetField(at, name);
	const bool v = lua->GetBool(-1);
	lua->Pop();
	return v;
}
template <class T>
void number(ILuaBase *lua, const char *name, T v)
{
	lua->PushNumber(static_cast<double>(v));
	lua->SetField(-2, name);
}
int failure(ILuaBase *lua, int top, const char *error)
{
	lua->Pop(lua->Top() - top);
	lua->PushNil();
	lua->PushString(error);
	return 2;
}
void call(ILuaBase *lua, int args, int results)
{
	if (lua->PCall(args, results, 0) != 0)
	{
		const char *message = lua->GetString(-1);
		throw std::runtime_error(message ? message : "Native draw callback failed");
	}
}
Scene &scene(ILuaBase *lua)
{
	auto *value = lua->GetUserType<Scene>(1, sceneType);
	l2::require(value && scenes.count(value), "invalid Native draw scene");
	return *value;
}
l2draw::VisibilityBounds bounds(ILuaBase *lua, int at)
{
	l2draw::VisibilityBounds out;
	out.mCenter = {field(lua, at, "x"), field(lua, at, "y"), field(lua, at, "z")};
	out.mHalf = {field(lua, at, "hx"), field(lua, at, "hy"), field(lua, at, "hz")};
	out.mRadius = field(lua, at, "radius");
	l2::require(out.mHalf[0] >= 0 && out.mHalf[1] >= 0 && out.mHalf[2] >= 0 &&
					out.mRadius >= std::sqrt(out.mHalf[0] * out.mHalf[0] + out.mHalf[1] * out.mHalf[1] + out.mHalf[2] * out.mHalf[2]) - 0.001,
				"invalid Native draw bounds");
	return out;
}
std::unique_ptr<Chunk> readChunk(ILuaBase *lua, int at)
{
	at = absolute(lua, at);
	auto out = std::make_unique<Chunk>();
	auto cpu = std::make_shared<l2draw::VisibilityChunk>();
	cpu->mKey = field(lua, at, "key");
	lua->GetField(at, "frame");
	const int frame = lua->Top();
	cpu->mOrigin = {field(lua, frame, "originX"), field(lua, frame, "originY"), field(lua, frame, "originZ")};
	const double width = field(lua, frame, "chunkW"), height = field(lua, frame, "chunkH");
	lua->Pop();
	lua->GetField(at, "list");
	const int list = lua->Top();
	l2::require(lua->IsType(list, Type::Table), "missing Native draw mesh list");
	out->list = std::make_shared<Ref>(lua, list);
	lua->GetField(list, "bounds");
	if (lua->IsType(-1, Type::Table))
		cpu->mBounds = bounds(lua, lua->Top());
	else
	{
		cpu->mBounds.mCenter = cpu->mBounds.mHalf = {width / 2, width / 2, height / 2};
		cpu->mBounds.mRadius = std::sqrt(width * width / 2 + height * height / 4);
	}
	lua->Pop();
	const unsigned count = lua->ObjLen(list);
	l2::require(count < INT32_MAX, "Native draw list exceeds index representation");
	out->meshes.reserve(count);
	// Adjacent material references share an identity for bind caching.
	std::unordered_map<IMaterial *, std::shared_ptr<Ref>> materials;
	for (unsigned i = 1; i <= count; ++i)
	{
		lua->PushNumber(i);
		lua->RawGet(list);
		const int entry = lua->Top();
		lua->GetField(entry, "mesh");
		Mesh mesh;
		mesh.resource = l2bridge::GetDrawResource(lua, -1);
		lua->Pop();
		lua->GetField(entry, "material");
		l2::require(lua->IsType(-1, Type::Material), "Native draw entry has no material");
		// A registry reference retains the Lua material and its GPU ownership.
		auto *identity = lua->GetUserType<IMaterial>(-1, Type::Material);
		l2::require(identity != nullptr, "invalid Native draw material identity");
		mesh.identity = identity;
		mesh.cullable = !identity->GetMaterialVarFlag(MATERIAL_VAR_NOCULL);
		auto &material = materials[identity];
		if (!material)
			material = std::make_shared<Ref>(lua, -1);
		mesh.material = material;
		lua->Pop();
		out->vertices += mesh.resource->mIndices / 6 * 4;
		out->meshes.push_back(std::move(mesh));
		lua->Pop();
	}
	lua->GetField(list, "sections");
	const int	   sections = lua->Top();
	const bool	   hasSections = lua->IsType(sections, Type::Table);
	const unsigned sectionCount = hasSections ? lua->ObjLen(sections) : 1;
	for (unsigned s = 1; s <= sectionCount; ++s)
	{
		l2draw::VisibilitySection metadata;
		Section					  range;
		range.end = count;
		if (hasSections)
		{
			lua->PushNumber(s);
			lua->RawGet(sections);
			const int sec = lua->Top();
			range.first = l2::integer(field(lua, sec, "first"), 1, count + 1, "invalid Native draw section start") - 1;
			range.end = l2::integer(field(lua, sec, "last"), range.first, count, "invalid Native draw section end");
			metadata.mIndex = l2::integer(field(lua, sec, "index"), 1, INT32_MAX, "invalid Native draw section index");
			lua->GetField(sec, "bounds");
			metadata.mBounded = lua->IsType(-1, Type::Table);
			if (metadata.mBounded)
			{
				metadata.mBounds = bounds(lua, lua->Top());
				metadata.mProtrudes = boolean(lua, lua->Top(), "protrudes");
			}
			lua->Pop(2);
		}
		for (unsigned i = range.first; i < range.end; ++i)
			range.vertices += out->meshes[i].resource->mIndices / 6 * 4;
		out->sections.push_back(range);
		cpu->mSections.push_back(metadata);
	}
	lua->Pop(2);
	out->cpu = std::move(cpu);
	return out;
}
LUA_FUNCTION(collect)
{
	auto *value = LUA->GetUserType<Scene>(1, sceneType);
	if (value)
	{
		scenes.erase(value);
		delete value;
		LUA->SetUserType(1, nullptr);
	}
	return 0;
}
} // namespace
void initialize(ILuaBase *lua)
{
	sceneType = lua->CreateMetaTable("MCSWEP_L2DrawScene_v1");
	lua->PushCFunction(collect);
	lua->SetField(-2, "__gc");
	lua->PushString("Native L2 draw scene");
	lua->SetField(-2, "__metatable");
	lua->Pop();
}
void shutdown()
{
	worker.Stop();
	for (auto *value : scenes)
		value->clear();
	currentGraph.reset();
}
int version(ILuaBase *lua)
{
	lua->PushNumber(1);
	return 1;
}
int create(ILuaBase *lua)
{
	const int top = lua->Top();
	try
	{
		auto value = std::make_unique<Scene>();
		lua->PushUserType(value.get(), sceneType);
		scenes.insert(value.get());
		value.release();
		return 1;
	}
	catch (const std::exception &e)
	{
		return failure(lua, top, e.what());
	}
}
int patch(ILuaBase *lua)
{
	const int top = lua->Top();
	try
	{
		auto &value = scene(lua);
		l2::require(!value.drawing, "cannot patch a Native scene during its draw");
		l2::require(lua->IsType(2, Type::Table), "missing Native draw scene updates");
		const unsigned										 count = l2::integer(numeric(lua, 3), 0, INT32_MAX, "Native draw chunk count out of range");
		std::unordered_map<unsigned, std::unique_ptr<Chunk>> updates;
		lua->PushNil();
		while (lua->Next(2) != 0)
		{
			const unsigned index = l2::integer(numeric(lua, -2), 1, count, "invalid Native scene update index") - 1;
			updates[index] = readChunk(lua, -1);
			lua->Pop();
		}
		auto cpu = std::make_shared<l2draw::VisibilityScene>();
		cpu->mChunks.reserve(count);
		for (unsigned i = 0; i < count; ++i)
		{
			auto		update = updates.find(i);
			const auto *chunk = update != updates.end() ? update->second.get() : i < value.chunks.size() ? value.chunks[i].get()
																										 : nullptr;
			l2::require(chunk != nullptr, "incomplete Native scene update");
			cpu->mChunks.push_back(chunk->cpu);
		}
		value.chunks.resize(count);
		for (auto &update : updates)
			value.chunks[update.first] = std::move(update.second);
		value.cpu = std::move(cpu);
		lua->PushBool(true);
		return 1;
	}
	catch (const std::exception &e)
	{
		return failure(lua, top, e.what());
	}
}
static int readGraph(ILuaBase *lua, bool spatial)
{
	const int top = lua->Top();
	try
	{
		numeric(lua, 1); // Lua owns revision caching; module reloads may restart its counter.
		const unsigned count = l2::integer(numeric(lua, 2), 0, INT32_MAX, "Native graph exceeds index representation");
		l2::require(lua->IsType(3, Type::Table) && lua->IsType(4, Type::Table) && lua->IsType(5, Type::Table),
					"invalid Native graph tables");
		auto		   result = std::make_shared<l2draw::VisibilityGraph>();
		const unsigned side = spatial ? l2::integer(numeric(lua, 9), 1, 64, "invalid Native graph section size") : 0;
		result->mNodes.resize(count + 1);
		for (unsigned id = 1; id <= count; ++id)
		{
			lua->PushNumber(id);
			lua->RawGet(3);
			const int source = lua->Top();
			auto	 &node = result->mNodes[id];
			node.mLive = lua->IsType(source, Type::Table);
			if (node.mLive)
				for (unsigned f = 0; f < 6; ++f)
				{
					node.mExits[f] = uint8_t(l2::integer(item(lua, source, f + 1), 0, 63, "invalid Native portal mask"));
					node.mNeighbors[f] = l2::integer(item(lua, 4, size_t(id - 1) * 6 + f + 1), 0, count, "invalid Native portal neighbor");
				}
			if (node.mLive && spatial)
			{
				lua->GetField(source, "uniform");
				if (lua->IsType(-1, Type::Number))
				{
					const auto uniform = l2::integer(numeric(lua, -1), 0, 64, "invalid Native uniform topology");
					l2::require(uniform == 63 || uniform == 64, "Native uniform topology must be air or solid");
					for (auto &face : node.mBoundary)
						face.assign(side * side, uint8_t(uniform));
					lua->Pop();
				}
				else
				{
					lua->Pop();
					lua->GetField(source, "cells");
					l2::require(lua->IsType(-1, Type::String), "missing Native topology cells");
					unsigned	length = 0;
					const auto *cells = reinterpret_cast<const uint8_t *>(lua->GetString(-1, &length));
					l2::require(length == side * side * side, "Native topology cell count disagrees with section size");
					for (unsigned i = 0; i < length; ++i)
						l2::require(cells[i] <= 64, "invalid Native topology component");
					for (unsigned face = 0; face < 6; ++face)
					{
						auto &boundary = node.mBoundary[face];
						boundary.resize(side * side);
						const unsigned edge = face & 1 ? 0 : side - 1;
						for (unsigned b = 0; b < side; ++b)
							for (unsigned a = 0; a < side; ++a)
							{
								const unsigned x = face < 2 || face >= 4 ? a : edge;
								const unsigned y = face < 2 ? b : face < 4 ? a
																		   : edge;
								const unsigned z = face < 2 ? edge : b;
								boundary[a + side * b] = cells[x + side * (y + side * z)];
							}
					}
					lua->Pop();
				}
			}
			lua->Pop();
		}
		for (unsigned id = 1; id <= count; ++id)
			if (result->mNodes[id].mLive)
				for (auto neighbor : result->mNodes[id].mNeighbors)
					l2::require(!neighbor || result->mNodes[neighbor].mLive, "Native graph edge points to a retired node");
		const unsigned perChunk = l2::integer(numeric(lua, 6), 1, INT32_MAX, "invalid Native graph section count");
		unsigned	   xy = 1, z = 1;
		if (spatial)
		{
			xy = l2::integer(numeric(lua, 7), 1, INT32_MAX, "invalid Native graph horizontal dimensions");
			z = l2::integer(numeric(lua, 8), 1, INT32_MAX, "invalid Native graph vertical dimensions");
			l2::require(double(xy) * xy * z == perChunk, "Native graph dimensions disagree with section count");
		}
		std::vector<uint8_t> assigned(spatial ? count + 1 : 0);
		lua->PushNil();
		while (lua->Next(5) != 0)
		{
			const double   key = numeric(lua, -2);
			const unsigned base = l2::integer(field(lua, lua->Top(), "base"), 0, count, "invalid Native graph base");
			l2::require(perChunk <= count - base, "Native graph chunk exceeds node storage");
			for (unsigned i = 1; i <= perChunk; ++i)
				l2::require(result->mNodes[base + i].mLive, "Native graph chunk contains retired node");
			if (spatial)
			{
				lua->GetField(lua->Top(), "chunk");
				const int chunk = lua->Top();
				l2::require(lua->IsType(chunk, Type::Table), "missing Native graph chunk coordinates");
				const double cx = field(lua, chunk, "cx"), cy = field(lua, chunk, "cy"), cz = field(lua, chunk, "cz");
				l2::require(std::floor(cx) == cx && std::floor(cy) == cy && std::floor(cz) == cz,
							"fractional Native graph chunk coordinates");
				for (unsigned i = 0; i < perChunk; ++i)
				{
					const unsigned id = base + i + 1;
					l2::require(!assigned[id], "Native spatial node has multiple owners");
					assigned[id] = 1;
					result->mNodes[id].mPosition = {
						l2::integer(cx * xy + i % xy, INT32_MIN, INT32_MAX, "Native graph X out of range"),
						l2::integer(cy * xy + i / xy % xy, INT32_MIN, INT32_MAX, "Native graph Y out of range"),
						l2::integer(cz * z + i / (xy * xy), INT32_MIN, INT32_MAX, "Native graph Z out of range")};
				}
				lua->Pop();
			}
			result->mBases.emplace(key, base);
			lua->Pop();
		}
		if (spatial)
		{
			for (unsigned id = 1; id <= count; ++id)
				l2::require(!result->mNodes[id].mLive || assigned[id], "unpositioned Native spatial node");
			l2draw::BuildSpatialGraph(*result);
			for (auto &node : result->mNodes)
				for (auto &face : node.mBoundary)
					std::vector<uint8_t>().swap(face);
		}
		currentGraph = std::move(result);
		lua->PushBool(true);
		return 1;
	}
	catch (const std::exception &e)
	{
		return failure(lua, top, e.what());
	}
}
int graph(ILuaBase *lua)
{
	return readGraph(lua, false);
}
int spatialGraph(ILuaBase *lua)
{
	return readGraph(lua, true);
}
static int DrawScene(ILuaBase *lua, bool inBatched)
{
	const int top = lua->Top();
	try
	{
		source::DrawProfile profile(lua->IsType(2, Type::Table) && boolean(lua, 2, "profile"));
		using source::EDrawPhase;
		const auto flush_started = profile.Start();
		pixelupload::GetPixelTextureStore().Flush();
		profile.Add(EDrawPhase::PixelFlush, flush_started);
		auto &value = scene(lua);
		l2::require(!value.drawing, "recursive Native scene draw");
		struct DrawScope
		{
			bool &flag;
			explicit DrawScope(bool &f) : flag(f) { flag = true; }
			~DrawScope() { flag = false; }
		} drawing(value.drawing);
		l2::require(value.cpu && lua->IsType(2, Type::Table) && lua->IsType(3, inBatched ? Type::String : Type::Function) &&
						lua->IsType(4, inBatched ? Type::Table : Type::Function) && lua->IsType(5, Type::Function),
					"invalid Native draw arguments");
		const unsigned char *chunk_states = nullptr;
		if (inBatched)
		{
			unsigned length = 0;
			chunk_states = reinterpret_cast<const unsigned char *>(lua->GetString(3, &length));
			l2::require(length == value.chunks.size(), "Native draw status count disagrees with scene");
			for (unsigned i = 0; i < length; ++i)
				l2::require(chunk_states[i] <= 3 || chunk_states[i] == 7, "invalid Native draw chunk status");
		}
		// The table at argument 4 retains the selected Lua materials throughout this draw.
		// Resolve each distinct source once; binding below stays on the Source main thread.
		std::unordered_map<IMaterial *, IMaterial *> selected_materials;
		l2draw::VisibilityView view;
		view.mEye = {field(lua, 2, "eyeX"), field(lua, 2, "eyeY"), field(lua, 2, "eyeZ")};
		view.mDistance = field(lua, 2, "distance");
		view.mMoveBudget = field(lua, 2, "moveBudget");
		l2::require(view.mDistance >= 0 && view.mMoveBudget >= 0, "invalid Native draw distance");
		view.mPortals = boolean(lua, 2, "portals");
		view.mRoot = l2::integer(field(lua, 2, "root"), 0, INT32_MAX, "invalid Native draw root");
		view.mSeed = uint8_t(l2::integer(field(lua, 2, "seed"), 0, 63, "invalid Native draw seed"));
		if (view.mPortals && currentGraph && currentGraph->mSpatial)
		{
			view.mPortalCell = {
				l2::integer(field(lua, 2, "portalX"), INT32_MIN, INT32_MAX, "invalid Native camera section X"),
				l2::integer(field(lua, 2, "portalY"), INT32_MIN, INT32_MAX, "invalid Native camera section Y"),
				l2::integer(field(lua, 2, "portalZ"), INT32_MIN, INT32_MAX, "invalid Native camera section Z")};
		}
		lua->GetField(2, "planes");
		const int planes = lua->Top();
		l2::require(lua->IsType(planes, Type::Table) && lua->ObjLen(planes) % 3 == 0,
					"invalid Native draw plane array");
		view.mPlaneCount = l2::integer(lua->ObjLen(planes) / 3, 0, 5, "invalid Native draw frustum");
		for (unsigned p = 0; p < view.mPlaneCount; ++p)
		{
			auto &n = view.mPlanes[p];
			for (unsigned a = 0; a < 3; ++a)
				n[a] = item(lua, planes, p * 3 + a + 1);
			const double length = std::sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
			l2::require(length > 0, "degenerate Native draw frustum");
			for (auto &axis : n)
				axis /= length;
		}
		lua->Pop();
		const l2draw::Vec offset = {field(lua, 2, "offsetX"), field(lua, 2, "offsetY"), field(lua, 2, "offsetZ")};
		const bool		  directional = boolean(lua, 2, "directional");
		const double	  margin = field(lua, 2, "directionMargin");
		l2::require(margin >= 0, "invalid Native direction margin");
		const unsigned								   lane = l2::integer(field(lua, 2, "lane"), 1, 3, "invalid Native draw lane") - 1;
		const auto									   graph = view.mPortals ? currentGraph : nullptr;
		std::shared_ptr<const l2draw::VisibilityFrame> frame;
		const bool									   background = boolean(lua, 2, "background");
		bool										   asyncHit = false;
		const auto visibility_started = profile.Start();
		if (background)
			frame = worker.Resolve(value.lanes[lane], value.cpu, graph, view, asyncHit);
		if (!frame)
		{
			auto exact = view;
			exact.mMoveBudget = exact.mNormalBudget = 0;
			frame = std::make_shared<l2draw::VisibilityFrame>(l2draw::Compute(value.cpu, graph, exact));
		}
		l2::require(frame->mError.empty(), frame->mError.c_str());
		profile.Add(EDrawPhase::Visibility, visibility_started);
		uint64_t			 drawn = 0, distance = 0, frustum = 0, stale = 0, meshes = 0, testedSections = 0,
							 drawnSections = 0, sectionFrustum = 0, sectionPortal = 0, rejectedDirections = 0,
							 vertices = 0, rejectedVertices = 0, binds = 0, rangesDrawn = 0, mergedRanges = 0,
							 chunk_callbacks = 0;
		CMatRenderContextPtr context(source::GetMaterialSystem()->GetRenderContext());
		l2::require(!!context, "Native draw render context unavailable");
		context->MatrixMode(MATERIAL_MODEL);
		struct MatrixScope
		{
			IMatRenderContext *context;
			bool			   pushed = false;
			~MatrixScope()
			{
				if (pushed)
				{
					context->MatrixMode(MATERIAL_MODEL);
					context->PopMatrix();
				}
			}
		};
		IMaterial *bound = nullptr;
		for (size_t i = 0; i < value.chunks.size(); ++i)
		{
			const auto &chunk = *value.chunks[i];
			const auto &cpu = *chunk.cpu;
			const auto &visible = frame->mChunks[i];
			if (visible.mReject != l2draw::ERejectReason::None)
			{
				rejectedVertices += chunk.vertices;
				if (visible.mReject == l2draw::ERejectReason::Distance)
					++distance;
				else
					++frustum;
				continue;
			}
			int status;
			bool dynamic;
			if (inBatched)
			{
				status = chunk_states[i] & 3;
				dynamic = (chunk_states[i] & 4) != 0;
			}
			else
			{
				const auto callback_started = profile.Start();
				lua->Push(3);
				lua->PushNumber(cpu.mKey);
				lua->ReferencePush(chunk.list->id);
				for (unsigned a = 0; a < 3; ++a)
					lua->PushNumber(cpu.mOrigin[a] - view.mEye[a]);
				call(lua, 5, 2);
				++chunk_callbacks;
				status = l2::integer(numeric(lua, -2), 0, 3, "invalid Native chunk callback result");
				dynamic = lua->GetBool(-1);
				lua->Pop(2);
				profile.Add(EDrawPhase::ChunkCallback, callback_started);
			}
			if (status != 3)
			{
				if (status == 0)
					++stale;
				if (status == 2)
				{
					++distance;
					rejectedVertices += chunk.vertices;
				}
				continue;
			}
			MatrixScope		  matrix{context};
			bool			  chunkDrawn = false;
			const l2draw::Vec localEye = {view.mEye[0] - cpu.mOrigin[0], view.mEye[1] - cpu.mOrigin[1], view.mEye[2] - cpu.mOrigin[2]};
			for (size_t s = 0; s < chunk.sections.size(); ++s)
			{
				const auto &section = chunk.sections[s];
				++testedSections;
				if (visible.mSections[s] != l2draw::ERejectReason::None)
				{
					rejectedVertices += section.vertices;
					if (visible.mSections[s] == l2draw::ERejectReason::Portal)
						++sectionPortal;
					else
						++sectionFrustum;
					continue;
				}
				bool sectionDrawn = false;
				for (unsigned j = section.first; j < section.end; ++j)
				{
					const auto &mesh = chunk.meshes[j];
					const auto &resource = *mesh.resource;
					l2::require(resource.mMesh != nullptr, "Native draw encountered a destroyed L2 mesh");
					CPrimList  ranges[7];
					unsigned   rangeCount = 0, selected = resource.mIndices;
					const bool useRanges = directional && mesh.cullable;
					if (useRanges)
					{
						const auto selection = l2draw::SelectDirectionRanges(resource.mDirections, resource.mBounds, localEye, margin);
						selected = selection.mIndices;
						rangeCount = selection.mRangeCount;
						rejectedDirections += selection.mRejectedDirections;
						mergedRanges += selection.mMergedRanges;
						for (unsigned range_index = 0; range_index < rangeCount; ++range_index)
						{
							const auto &range = selection.mRanges[range_index];
							ranges[range_index] = CPrimList(range.first, range.count);
						}
						rejectedVertices += (resource.mIndices - selected) / 6 * 4;
						if (!selected)
							continue;
					}
					if (!matrix.pushed)
					{
						VMatrix model;
						model.Init(1, 0, 0, float(cpu.mOrigin[0] + offset[0]),
								   0, 1, 0, float(cpu.mOrigin[1] + offset[1]), 0, 0, 1, float(cpu.mOrigin[2] + offset[2]), 0, 0, 0, 1);
						context->MatrixMode(MATERIAL_MODEL);
						context->PushMatrix();
						matrix.pushed = true;
						context->LoadMatrix(model);
					}
					auto *source = mesh.identity;
					if (source != bound)
					{
						const auto bind_started = profile.Start();
						if (inBatched)
						{
							auto found = selected_materials.find(source);
							if (found == selected_materials.end())
							{
								lua->ReferencePush(mesh.material->id);
								lua->RawGet(4);
								auto *selected_material = lua->GetUserType<IMaterial>(-1, Type::Material);
								l2::require(selected_material != nullptr, "missing Native prepared material");
								found = selected_materials.emplace(source, selected_material).first;
								lua->Pop();
							}
							context->Bind(found->second);
						}
						else
						{
							lua->Push(4);
							lua->ReferencePush(mesh.material->id);
							call(lua, 1, 0);
						}
						bound = source;
						++binds;
						profile.Add(EDrawPhase::MaterialBind, bind_started);
					}
					auto drawMesh = [&]
					{
						const auto draw_started = profile.Start();
						if (useRanges)
							resource.mMesh->Draw(ranges, rangeCount);
						else
							resource.mMesh->Draw(0, resource.mIndices);
						profile.Add(EDrawPhase::MeshDraw, draw_started);
					};
					drawMesh();
					if (dynamic)
					{
						const auto overlay_started = profile.Start();
						lua->Push(5);
						lua->PushBool(true);
						lua->ReferencePush(mesh.material->id);
						call(lua, 2, 1);
						const bool overlay = lua->GetBool(-1);
						lua->Pop();
						profile.Add(EDrawPhase::Overlay, overlay_started);
						if (overlay)
						{
							drawMesh();
							const auto restore_started = profile.Start();
							lua->Push(5);
							lua->PushBool(false);
							lua->ReferencePush(mesh.material->id);
							call(lua, 2, 0);
							profile.Add(EDrawPhase::Overlay, restore_started);
						}
					}
					++meshes;
					vertices += selected / 6 * 4;
					rangesDrawn += useRanges ? rangeCount : 1;
					chunkDrawn = sectionDrawn = true;
				}
				if (sectionDrawn)
					++drawnSections;
			}
			if (chunkDrawn)
				++drawn;
		}
		lua->CreateTable();
		if (profile.IsEnabled())
		{
			number(lua, "profileTotalMS", profile.GetTotalMS());
			number(lua, "profilePixelFlushMS", profile.Get(EDrawPhase::PixelFlush));
			number(lua, "profileVisibilityMS", profile.Get(EDrawPhase::Visibility));
			number(lua, "profileChunkCallbackMS", profile.Get(EDrawPhase::ChunkCallback));
			number(lua, "profileMaterialBindMS", profile.Get(EDrawPhase::MaterialBind));
			number(lua, "profileMeshDrawMS", profile.Get(EDrawPhase::MeshDraw));
			number(lua, "profileOverlayMS", profile.Get(EDrawPhase::Overlay));
		}
		number(lua, "drawn", drawn);
		number(lua, "distanceCulled", distance);
		number(lua, "frustumCulled", frustum);
		number(lua, "stale", stale);
		number(lua, "meshes", meshes);
		number(lua, "sectionsTested", testedSections);
		number(lua, "sectionsDrawn", drawnSections);
		number(lua, "sectionFrustumCulled", sectionFrustum);
		number(lua, "sectionOcclusionCulled", sectionPortal);
		number(lua, "directionCulled", rejectedDirections);
		number(lua, "vertices", vertices);
		number(lua, "verticesCulled", rejectedVertices);
		number(lua, "nativeBinds", binds);
		number(lua, "nativeChunkCallbacks", chunk_callbacks);
		number(lua, "nativeMaterialCallbacks", inBatched ? 0 : binds);
		number(lua, "nativePreparedMaterials", selected_materials.size());
		number(lua, "nativeRanges", rangesDrawn);
		number(lua, "nativeRangeMerges", mergedRanges);
		number(lua, "nativeAsyncHits", asyncHit ? 1 : 0);
		number(lua, "nativeSyncCulls", asyncHit ? 0 : 1);
		number(lua, "nativeCullMS", frame->mMilliseconds);
		lua->PushString(!view.mPortals ? "disabled" : !graph->mSpatial	 ? "connectivity_legacy"
												  : graph->mGrid.empty() ? "connectivity_extent"
																		 : "spatial_outward");
		lua->SetField(-2, "portalMode");
		number(lua, "portalGridCells", graph ? graph->mGrid.size() : 0);
		number(lua, "portalVisited", frame->mPortals ? frame->mPortals->mVisited : 0);
		return 1;
	}
	catch (const std::exception &e)
	{
		return failure(lua, top, e.what());
	}
}
int draw(ILuaBase *lua)
{
	return DrawScene(lua, false);
}
int DrawBatched(ILuaBase *inLua)
{
	return DrawScene(inLua, true);
}
int stats(ILuaBase *lua)
{
	const auto value = worker.GetStats();
	lua->CreateTable();
	number(lua, "requests", value.mRequests);
	number(lua, "cacheHits", value.mCacheHits);
	number(lua, "coalesced", value.mCoalesced);
	number(lua, "scheduled", value.mScheduled);
	number(lua, "completed", value.mCompleted);
	number(lua, "running", value.mRunning);
	number(lua, "synchronous", value.mSynchronous);
	number(lua, "computeMS", value.mComputeMS);
	number(lua, "portalTraversals", value.mPortalTraversals);
	number(lua, "portalCacheHits", value.mPortalCacheHits);
	return 1;
}
} // namespace mcmesh::l2drawbridge
