#include "Module/Pch.h"
#include "Bindings/MeshBindings.h"
#include "Core/CpuWorkGate.h"
#include "Mesh/SectionGeometry.h"
#include "Mesh/SectionWorker.h"
#include "Bindings/DrawBindings.h"
#include "Bindings/WorldBindings.h"
#include "Mesh/WorldMeshInput.h"
#include "Resources/Source/PixelTextureStore.h"
#include "Render/Source/PublishedMesh.h"
#include "Mesh/SectionTasks.h"
#include "Bindings/MeshBindingContext.h"
#include "Bindings/MeshInputBindings.h"
#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <stdexcept>
#include <string>

namespace mcmesh::l2bridge
{
using namespace GarrysMod::Lua;
namespace
{
using MeshHandle = source::PublishedMesh;
LUA_FUNCTION(MeshDestroy)
{
	auto *handle = LUA->GetUserType<MeshHandle>(1, GetBindingState().mMeshType);
	if (handle)
		handle->Destroy();
	return 0;
}
LUA_FUNCTION(MeshGC)
{
	auto *handle = LUA->GetUserType<MeshHandle>(1, GetBindingState().mMeshType);
	delete handle;
	LUA->SetUserType(1, nullptr);
	return 0;
}
LUA_FUNCTION(PixelTransactionGC)
{
	auto *transaction = LUA->GetUserType<l2::PixelTransaction>(1, GetBindingState().mPixelTransactionType);
	source::GetMeshPublication().ReleaseTransaction(transaction);
	LUA->SetUserType(1, nullptr);
	return 0;
}
LUA_FUNCTION(MeshValid)
{
	auto *handle = LUA->GetUserType<MeshHandle>(1, GetBindingState().mMeshType);
	LUA->PushBool(handle && handle->IsValid());
	return 1;
}
LUA_FUNCTION(MeshDraw)
{
	auto *handle = LUA->GetUserType<MeshHandle>(1, GetBindingState().mMeshType);
	if (!handle || !handle->IsValid())
	{
		LUA->ThrowError("Native L2: drawing a destroyed mesh");
		return 0;
	}
	char error[512]{};
	try
	{
		pixelupload::GetPixelTextureStore().Flush();
	}
	catch (const std::exception &e)
	{
		snprintf(error, sizeof(error), "%s", e.what());
	}
	if (*error)
	{
		LUA->ThrowError(error);
		return 0;
	}
	// The Lua render stage has already bound its material and view transform.
	auto &resource = handle->GetDrawResource();
	resource.mMesh->Draw(0, resource.mIndices);
	return 0;
}
LUA_FUNCTION(TemplateGC)
{
	if (LUA->GetUserType<l2::Template>(1, GetBindingState().mTemplateType))
	{
		LUA->SetUserType(1, nullptr);
		--GetBindingState().mLiveTemplates;
	}
	return 0;
}
LUA_FUNCTION(ModelGC)
{
	delete LUA->GetUserType<ModelHandle>(1, GetBindingState().mModelType);
	LUA->SetUserType(1, nullptr);
	return 0;
}
} // namespace

source::DrawResource *GetDrawResource(ILuaBase *inLua, int inIndex)
{
	auto *handle = inLua->GetUserType<MeshHandle>(inIndex, GetBindingState().mMeshType);
	l2::require(handle && handle->IsValid(), "Native draw scene requires a live L2 mesh");
	return &handle->GetDrawResource();
}

void Initialize(ILuaBase *inLua)
{
	l2drawbridge::initialize(inLua);
	GetBindingState().mFluidType = inLua->CreateMetaTable("MCSWEP_L2Fluid_v1");
	inLua->PushString("immutable Native L2 fluid");
	inLua->SetField(-2, "__metatable");
	inLua->Pop();
	GetBindingState().mModelType = inLua->CreateMetaTable("MCSWEP_L2Model_v1");
	SetFunction(inLua, "__gc", ModelGC);
	inLua->PushString("immutable Native L2 model");
	inLua->SetField(-2, "__metatable");
	inLua->Pop();
	GetBindingState().mCubeType = inLua->CreateMetaTable("MCSWEP_L2Cube_v1");
	inLua->PushString("immutable Native L2 cube");
	inLua->SetField(-2, "__metatable");
	inLua->Pop();
	GetBindingState().mTemplateType = inLua->CreateMetaTable("MCSWEP_L2Template_v1");
	SetFunction(inLua, "__gc", TemplateGC);
	inLua->PushString("immutable Native L2 template");
	inLua->SetField(-2, "__metatable");
	inLua->Pop();
	GetBindingState().mMeshType = inLua->CreateMetaTable("MCSWEP_L2Mesh_v1");
	SetFunction(inLua, "Draw", MeshDraw);
	SetFunction(inLua, "Destroy", MeshDestroy);
	SetFunction(inLua, "IsValid", MeshValid);
	SetFunction(inLua, "__gc", MeshGC);
	inLua->Push(-1);
	inLua->SetField(-2, "__index");
	inLua->PushString("Native L2 mesh");
	inLua->SetField(-2, "__metatable");
	inLua->Pop();
	GetBindingState().mPixelTransactionType = inLua->CreateMetaTable("MCSWEP_L2LightingTransaction_v1");
	SetFunction(inLua, "__gc", PixelTransactionGC);
	inLua->PushString("Native L2 lighting transaction");
	inLua->SetField(-2, "__metatable");
	inLua->Pop();
}
void Shutdown()
{
	l2::GetSectionTasks().Shutdown();
	l2drawbridge::shutdown();
	source::GetMeshPublication().Shutdown();
	pixelupload::GetPixelTextureStore().Shutdown();
}
int Version(ILuaBase *inLua)
{
	inLua->PushNumber(2);
	return 1;
}
int LightingVersion(ILuaBase *inLua)
{
	inLua->PushNumber(2);
	return 1;
}
static int UploadPartToLua(ILuaBase *inLua, const l2::Part &inPart, unsigned inFirst, const std::string &inMaterialName,
						   const world::MeshSnapshot *inSource = nullptr, bool inNativePixels = false)
{
	const int	top = inLua->Top();
	MeshHandle *handle = nullptr;
	try
	{
		const double   started = ClockMS();
		const unsigned count = static_cast<unsigned>(inPart.quads.size());
		auto		   owned = std::make_unique<MeshHandle>(source::GetMeshPublication());
		inLua->PushUserType(owned.get(), GetBindingState().mMeshType);
		handle = owned.release();
		handle->Upload(inPart, inFirst, inMaterialName, inSource, inNativePixels);
		const int mesh_index = inLua->Top();
		inLua->CreateTable();
		inLua->Push(mesh_index);
		inLua->SetField(-2, "mesh");
		inLua->PushBool(handle->GetLighting() != nullptr);
		inLua->SetField(-2, "relight");
		SetNumber(inLua, "vertices", count * 4);
		SetNumber(inLua, "indices", count * 6);
		if (!inNativePixels)
		{
			PushPixels(inLua, inPart.pixels->corners.data(), inPart.pixels->corners.size());
			inLua->SetField(-2, "pixels");
			PushPixels(inLua, inPart.pixels->occlusion.data(), inPart.pixels->occlusion.size());
			inLua->SetField(-2, "occlusion");
			GetBindingState().mLuaPixelValues += inPart.pixels->corners.size() + inPart.pixels->occlusion.size();
		}
		inLua->CreateTable();
		for (unsigned i = 0; i < 6; ++i)
		{
			inLua->PushNumber(i + 1);
			inLua->PushNumber(inPart.bounds[i]);
			inLua->RawSet(-3);
		}
		inLua->SetField(-2, "bounds");
		++GetBindingState().mBatches;
		GetBindingState().mVertices += count * 4;
		GetBindingState().mIndices += count * 6;
		GetBindingState().mUploadMS += ClockMS() - started;
		return 1;
	}
	catch (const std::exception &e)
	{
		if (handle)
			handle->Destroy();
		return Fail(inLua, top, e.what());
	}
}
// Retained only for explicit synchronous diagnostics/compatibility, not terrain.
int BuildMesh(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		BuildScope guard;
		l2::require(inLua->IsType(2, Type::Function) && inLua->IsType(3, Type::Table) &&
						inLua->IsType(5, Type::String),
					"invalid L2 build arguments");
		auto			  snapshot = ReadSnapshot(inLua);
		const auto		  work = ReadWork(inLua, 1, snapshot);
		const unsigned	  first = l2::integer(ReadNumber(inLua, 4), 0, l2::AtlasQuads - static_cast<int>(work.size()),
											  "L2 batch exceeds corner atlas");
		const std::string material = inLua->GetString(5);
		l2::Part		  part;
		part.quads.resize(work.size());
		auto pixels = std::make_shared<l2::LightPixels>(work.size());
		part.pixels = pixels;
		std::fill(part.bounds, part.bounds + 3, FLT_MAX);
		std::fill(part.bounds + 3, part.bounds + 6, -FLT_MAX);
		for (unsigned i = 0; i < work.size(); ++i)
		{
			auto &q = part.quads[i];
			q = l2::evaluate(work[i].geometry, work[i].command, snapshot, i);
			std::copy(std::begin(q.pixels), std::end(q.pixels), pixels->corners.begin() + i * 4);
			pixels->occlusion[i] = q.occlusion;
			for (const auto &v : q.vertices)
				for (unsigned a = 0; a < 3; ++a)
				{
					part.bounds[a] = std::min(part.bounds[a], v.position[a]);
					part.bounds[a + 3] = std::max(part.bounds[a + 3], v.position[a]);
				}
		}
		GetBindingState().mReads += snapshot.reads;
		GetBindingState().mHits += snapshot.hits;
		return UploadPartToLua(inLua, part, first, material);
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int SubmitSection(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		BuildScope guard;
		l2::require(inLua->IsType(1, Type::Table) && inLua->IsType(2, Type::Function) &&
						inLua->IsType(3, Type::Table),
					"invalid L2 submission arguments");
		if (!l2::GetSectionTasks().PrepareSubmission())
		{
			inLua->PushBool(false);
			return 1;
		}
		const double started = ClockMS();
		const int	 count = inLua->ObjLen(1);
		l2::require(count >= 0 && (count > 0 || inLua->IsType(4, Type::Table)), "missing L2 section input");
		auto input = std::make_unique<l2::Input>(ReadSnapshot(inLua));
		input->parts.reserve(count);
		for (int i = 1; i <= count; ++i)
		{
			inLua->PushNumber(i);
			inLua->RawGet(1);
			input->parts.push_back(ReadWork(inLua, inLua->Top(), input->snapshot));
			inLua->Pop();
		}
		ReadVoxels(inLua, *input);
		for (const auto &model : input->models)
			l2::require(!model.model->needsShapes, "shape recipe requires Native world snapshot");
		GetBindingState().mCommandMS += ClockMS() - started;
		const double frozen_at = ClockMS();
		l2::prefetchVoxels(*input);
		// Capture only cells reachable by these commands, once per section.
		// Detach the reader before the immutable snapshot crosses threads.
		for (const auto &part : input->parts)
			for (const auto &w : part)
				l2::prefetch(w.geometry, w.command, input->snapshot);
		GetBindingState().mSnapshotMS += ClockMS() - frozen_at;
		GetBindingState().mReads += input->snapshot.reads;
		GetBindingState().mHits += input->snapshot.hits;
		const auto id = l2::GetSectionTasks().Submit(std::move(input));
		if (id)
			inLua->PushNumber(static_cast<double>(id));
		else
			inLua->PushBool(false);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int SubmitWorldSection(ILuaBase *inLua)
{
	const int top = inLua->Top();
	uint64_t  submitted = 0;
	try
	{
		BuildScope		   guard;
		auto			  &store = worldbridge::session(inLua, 2).store();
		const world::Coord chunk{
			l2::integer(ReadNumber(inLua, 3), INT32_MIN, INT32_MAX, "invalid world chunk x"),
			l2::integer(ReadNumber(inLua, 4), INT32_MIN, INT32_MAX, "invalid world chunk y"),
			l2::integer(ReadNumber(inLua, 5), INT32_MIN, INT32_MAX, "invalid world chunk z")};
		store.config().validateChunk(chunk);
		const unsigned section = l2::integer(ReadNumber(inLua, 6), 1, store.config().sectionCount(), "invalid world section") - 1;
		l2::require(inLua->IsType(1, Type::Table) && inLua->IsType(7, Type::Table) && inLua->IsType(9, Type::Bool),
					"invalid world L2 submission");
		if (!l2::GetSectionTasks().PrepareSubmission())
		{
			inLua->PushBool(false);
			return 1;
		}
		const auto started = ClockMS();
		// Only geometry submissions opt in. Relights still require settled light.
		const bool deferred_light = inLua->IsType(10, Type::Bool) && inLua->GetBool(10);
		auto	   source = std::make_shared<const world::MeshSnapshot>(store.meshSnapshot(chunk, section, deferred_light));
		const int  origin[3] = {source->origin.x, source->origin.y, source->origin.z};
		const int  dims[3] = {source->dimensions.x, source->dimensions.y, source->dimensions.z};
		auto	   input = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, source));
		input->fluidSource = source;
		input->shapeSource = source;
		input->blockSize = store.config().blockSize;
		input->maxQuads = l2::integer(ReadNumber(inLua, 8), 1, l2::MaxQuads, "invalid world part limit");
		std::unordered_map<uint32_t, world::MeshRecipe> recipes;
		inLua->PushNil();
		while (inLua->Next(7))
		{
			const auto state = l2::integer(ReadNumber(inLua, -2), 1, int(store.catalog()->states.size()) - 1, "invalid recipe state");
			const int  table = inLua->Top();
			l2::require(inLua->IsType(table, Type::Table), "invalid world recipe");
			inLua->PushNumber(1);
			inLua->RawGet(table);
			const auto		 *cube = inLua->GetUserType<l2::Cube>(-1, GetBindingState().mCubeType);
			const auto		 *model = inLua->GetUserType<ModelHandle>(-1, GetBindingState().mModelType);
			world::MeshRecipe recipe;
			if (cube)
			{
				auto value = *cube;
				inLua->Pop();
				for (unsigned f = 0; f < 6; ++f)
					value.groups[f] = l2::integer(ReadItem(inLua, table, f + 2), 1, INT32_MAX, "invalid cube group");
				recipe.index = unsigned(input->cubes.size());
				recipe.maxQuads = 6;
				input->cubes.push_back(std::move(value));
			}
			else if (model && *model)
			{
				l2::ModelBinding value{*model, 0};
				inLua->Pop();
				value.group = l2::integer(ReadItem(inLua, table, 2), 1, INT32_MAX, "invalid model group");
				recipe.index = unsigned(input->models.size());
				recipe.model = true;
				recipe.maxQuads = value.model->maxQuads;
				recipe.shapeSelector = value.model->shapeSelector;
				input->models.push_back(std::move(value));
			}
			else
			{
				l2::require(inLua->IsType(-1, Type::Bool) && !inLua->GetBool(-1), "invalid world compiled recipe");
				recipe.fluidOnly = true;
				inLua->Pop();
			}
			inLua->GetField(table, "fluid");
			if (!inLua->IsType(-1, Type::Nil))
			{
				const auto *fluid = inLua->GetUserType<l2::FluidRecipe>(-1, GetBindingState().mFluidType);
				l2::require(fluid != nullptr && source->world->catalog->states[state].fluid.ready && source->world->catalog->states[state].fluid.kind == fluid->kind,
							"missing compiled fluid recipe/profile");
				auto value = *fluid;
				inLua->Pop();
				inLua->GetField(table, "fluidGroup");
				value.group = l2::integer(ReadNumber(inLua, -1), 1, INT32_MAX, "invalid fluid group");
				recipe.fluidIndex = int(input->fluids.size());
				recipe.maxQuads += 6;
				input->fluids.push_back(value);
			}
			inLua->Pop();
			l2::require(!recipe.fluidOnly || recipe.fluidIndex >= 0, "missing fluid-only recipe");
			inLua->GetField(table, "blocking");
			l2::require(inLua->IsType(-1, Type::Bool), "missing topology classification");
			recipe.blocking = inLua->GetBool(-1);
			inLua->Pop();
			recipes.emplace(uint32_t(state), recipe);
			inLua->Pop();
		}
		// Optional complete visual classification for mixed Native/Lua sections.
		// Copy booleans at submission; no worker invokes the Lua classifier.
		std::unordered_map<uint32_t, bool> blocking_states;
		if (inLua->Top() >= 11 && !inLua->IsType(11, Type::Nil))
		{
			l2::require(inLua->IsType(11, Type::Table) && inLua->GetBool(9), "invalid mixed topology classification");
			const auto size = store.config().sectionSize;
			const size_t classification_limit = size_t(size) * size * size;
			inLua->PushNil();
			while (inLua->Next(11))
			{
				const auto state = l2::integer(ReadNumber(inLua, -2), 1, int(store.catalog()->states.size()) - 1, "invalid topology state");
				l2::require(inLua->IsType(-1, Type::Bool), "invalid topology blocking flag");
				blocking_states.emplace(uint32_t(state), inLua->GetBool(-1));
				l2::require(blocking_states.size() <= classification_limit, "mixed topology classification is too large");
				inLua->Pop();
			}
		}
		input->instances = std::make_shared<world::MeshInstances>(source, chunk, section, std::move(recipes),
			inLua->GetBool(9), std::move(blocking_states));
		const int count = inLua->ObjLen(1);
		l2::require(count >= 0, "invalid world section part count");
		input->retainLighting = inLua->GetBool(9) && count == 0;
		for (int i = 1; i <= count; ++i)
		{
			inLua->PushNumber(i);
			inLua->RawGet(1);
			input->parts.push_back(ReadWork(inLua, inLua->Top(), input->snapshot));
			inLua->Pop();
		}
		GetBindingState().mCommandMS += ClockMS() - started;
		// The owned CPU reader is sampled only by the worker. No Lua prefetch.
		submitted = l2::GetSectionTasks().Submit(std::move(input), std::move(source));
		if (submitted)
		{
			inLua->PushNumber(double(submitted));
		}
		else
			inLua->PushBool(false);
		return 1;
	}
	catch (const std::exception &e)
	{
		if (submitted)
		{
			l2::GetSectionTasks().Cancel(submitted);
		}
		return Fail(inLua, top, e.what());
	}
}
int WorldSectionCurrent(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = uint64_t(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid world L2 job"));
		const auto snapshot = l2::GetSectionTasks().GetSource(id);
		inLua->PushBool(snapshot && worldbridge::session(inLua, 2).store().current(*snapshot));
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int WorldSectionGeometryCurrent(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = uint64_t(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid world L2 job"));
		const auto snapshot = l2::GetSectionTasks().GetSource(id);
		inLua->PushBool(snapshot && worldbridge::session(inLua, 2).store().geometryCurrent(*snapshot));
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int SubmitWorldRelight(ILuaBase *inLua)
{
	const int top = inLua->Top();
	uint64_t  submitted = 0;
	try
	{
		BuildScope		   guard;
		auto			  &store = worldbridge::session(inLua, 2).store();
		const world::Coord chunk{
			l2::integer(ReadNumber(inLua, 3), INT32_MIN, INT32_MAX, "invalid relight chunk x"),
			l2::integer(ReadNumber(inLua, 4), INT32_MIN, INT32_MAX, "invalid relight chunk y"),
			l2::integer(ReadNumber(inLua, 5), INT32_MIN, INT32_MAX, "invalid relight chunk z")};
		store.config().validateChunk(chunk);
		const unsigned section = l2::integer(ReadNumber(inLua, 6), 1, store.config().sectionCount(),
											 "invalid relight section") -
								 1;
		l2::require(inLua->IsType(1, Type::Table), "invalid relight meshes");
		const int count = inLua->ObjLen(1);
		l2::require(count > 0, "invalid relight part count");
		if (!l2::GetSectionTasks().PrepareSubmission())
		{
			inLua->PushBool(false);
			return 1;
		}
		const auto								  started = ClockMS();
		auto									  source = std::make_shared<const world::MeshSnapshot>(store.meshSnapshot(chunk, section));
		const int								  origin[3] = {source->origin.x, source->origin.y, source->origin.z};
		const int								  dims[3] = {source->dimensions.x, source->dimensions.y, source->dimensions.z};
		auto									  input = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, source));
		std::vector<std::weak_ptr<l2::PixelSlot>> targets;
		for (int i = 1; i <= count; ++i)
		{
			inLua->PushNumber(i);
			inLua->RawGet(1);
			const auto *mesh = inLua->GetUserType<MeshHandle>(-1, GetBindingState().mMeshType);
			l2::require(mesh && mesh->IsValid(), "relight mesh was destroyed");
			const auto *retained = mesh->GetLighting();
			inLua->Pop();
			if (!retained || !(retained->mGeometry.origin == source->origin) || !(retained->mGeometry.dimensions == source->dimensions) || !store.current(retained->mGeometry))
			{
				inLua->PushBool(false);
				inLua->PushString("geometry_changed_or_not_retained");
				return 2;
			}
			input->relight.push_back(retained->mWork);
			targets.push_back(mesh->GetPixels());
		}
		GetBindingState().mCommandMS += ClockMS() - started;
		submitted = l2::GetSectionTasks().Submit(std::move(input), std::move(source), std::move(targets));
		if (submitted)
		{
			inLua->PushNumber(double(submitted));
		}
		else
			inLua->PushBool(false);
		return 1;
	}
	catch (const std::exception &e)
	{
		if (submitted)
		{
			l2::GetSectionTasks().Cancel(submitted);
		}
		return Fail(inLua, top, e.what());
	}
}
int LightPart(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = uint64_t(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid relight job"));
		const auto job = l2::GetSectionTasks().GetReady(id);
		l2::require(job->error.empty(), job->error.c_str());
		l2::require(job->relight, "L2 job is not light-only");
		const auto	index = l2::integer(ReadNumber(inLua, 2), 1, int(job->parts.size()), "invalid relight part") - 1;
		const auto &part = job->parts[index];
		inLua->CreateTable();
		PushPixels(inLua, part.pixels->corners.data(), part.pixels->corners.size());
		inLua->SetField(-2, "pixels");
		PushPixels(inLua, part.pixels->occlusion.data(), part.pixels->occlusion.size());
		inLua->SetField(-2, "occlusion");
		GetBindingState().mLuaPixelValues += part.pixels->corners.size() + part.pixels->occlusion.size();
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int SectionTopology(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = uint64_t(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid topology job"));
		const auto job = l2::GetSectionTasks().GetReady(id);
		l2::require(job->error.empty(), job->error.c_str());
		const auto &value = job->topology;
		l2::require(value.uniform != 0 || !value.cells.empty(), "world topology was not requested");
		inLua->CreateTable();
		for (unsigned face = 0; face < 6; ++face)
		{
			inLua->PushNumber(face + 1);
			inLua->PushNumber(value.faces[face]);
			inLua->RawSet(-3);
		}
		inLua->PushBool(value.graphOpen);
		inLua->SetField(-2, "graphOpen");
		if (value.uniform)
			SetNumber(inLua, "uniform", value.uniform);
		else
		{
			inLua->PushString(reinterpret_cast<const char *>(value.cells.data()), unsigned(value.cells.size()));
			inLua->SetField(-2, "cells");
		}
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int PollSection(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = static_cast<uint64_t>(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid L2 job"));
		const auto state = l2::GetSectionTasks().GetState(id);
		if (state == l2::JobState::Failed)
		{
			const auto job = l2::GetSectionTasks().GetReady(id);
			return Fail(inLua, top, job->error.c_str());
		}
		inLua->PushBool(state == l2::JobState::Ready);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int SectionParts(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = static_cast<uint64_t>(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid L2 job"));
		const auto job = l2::GetSectionTasks().GetReady(id);
		l2::require(job->error.empty(), job->error.c_str());
		inLua->CreateTable();
		for (size_t i = 0; i < job->parts.size(); ++i)
		{
			inLua->PushNumber(static_cast<double>(i + 1));
			inLua->CreateTable();
			SetNumber(inLua, "group", job->parts[i].group);
			SetNumber(inLua, "quads", static_cast<double>(job->parts[i].quads.size()));
			inLua->RawSet(-3);
		}
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
static int UploadJobPart(ILuaBase *inLua, bool inNativePixels)
{
	const int top = inLua->Top();
	try
	{
		BuildScope guard;
		const auto id = static_cast<uint64_t>(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid L2 job"));
		const auto job = l2::GetSectionTasks().GetReady(id);
		l2::require(job->error.empty(), job->error.c_str());
		const auto	   index = l2::integer(ReadNumber(inLua, 2), 1, static_cast<int>(job->parts.size()), "invalid L2 part") - 1;
		const auto	  &part = job->parts[index];
		const unsigned first = l2::integer(ReadNumber(inLua, 3), 0, l2::AtlasQuads - static_cast<int>(part.quads.size()),
										   "L2 batch exceeds corner atlas");
		l2::require(inLua->IsType(4, Type::String), "invalid L2 material");
		const auto source = l2::GetSectionTasks().GetSource(id);
		return UploadPartToLua(inLua, part, first, inLua->GetString(4),
							   source.get(), inNativePixels);
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int UploadPart(ILuaBase *inLua)
{
	return UploadJobPart(inLua, false);
}
int UploadNativePart(ILuaBase *inLua)
{
	return UploadJobPart(inLua, true);
}
namespace
{
MeshHandle &ReadPixelMesh(ILuaBase *inLua, int inAt)
{
	auto *mesh = inLua->GetUserType<MeshHandle>(inAt, GetBindingState().mMeshType);
	l2::require(mesh && mesh->IsValid() && mesh->GetPixels() && mesh->GetPixels()->pixels,
				"Native L2 mesh has no retained pixels");
	return *mesh;
}
l2::PixelTransaction &ReadPixelTransaction(ILuaBase *inLua)
{
	auto *transaction = inLua->GetUserType<l2::PixelTransaction>(1, GetBindingState().mPixelTransactionType);
	l2::require(transaction != nullptr, "Native L2 lighting transaction was released");
	return *transaction;
}
} // namespace
int UploadMeshPixels(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto	  &mesh = ReadPixelMesh(inLua, 1);
		const double   texture = ReadNumber(inLua, 2);
		const unsigned first = l2::integer(ReadNumber(inLua, 3), 0, INT32_MAX, "invalid Native L2 atlas address");
		pixelupload::GetPixelTextureStore().UploadNative(*mesh.GetPixels()->pixels, pixelupload::ParsePixelTextureId(texture), first);
		GetBindingState().mNativePixelTexels += mesh.GetPixels()->pixels->occlusion.size() * 5;
		inLua->PushBool(true);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int ReadMeshPixels(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto &pixels = *ReadPixelMesh(inLua, 1).GetPixels()->pixels;
		inLua->CreateTable();
		PushPixels(inLua, pixels.corners.data(), pixels.corners.size());
		inLua->SetField(-2, "pixels");
		PushPixels(inLua, pixels.occlusion.data(), pixels.occlusion.size());
		inLua->SetField(-2, "occlusion");
		GetBindingState().mLuaPixelValues += pixels.corners.size() + pixels.occlusion.size();
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int StageRelight(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = uint64_t(l2::integer(ReadNumber(inLua, 1), 1, INT32_MAX, "invalid relight job"));
		const auto job = l2::GetSectionTasks().GetReady(id);
		l2::require(job->error.empty(), job->error.c_str());
		l2::require(job->relight && inLua->IsType(2, Type::Table) && size_t(inLua->ObjLen(2)) == job->parts.size(), "invalid Native L2 relight layout");
		std::vector<l2::RelightLayout> layout;
		layout.reserve(job->parts.size());
		for (size_t i = 0; i < job->parts.size(); ++i)
		{
			inLua->PushNumber(double(i + 1));
			inLua->RawGet(2);
			l2::require(inLua->IsType(-1, Type::Table), "invalid Native L2 relight part");
			const int row = inLua->Top();
			inLua->GetField(row, "mesh");
			auto slot = ReadPixelMesh(inLua, -1).GetPixels();
			inLua->Pop();
			inLua->GetField(row, "firstQuad");
			const unsigned first = l2::integer(ReadNumber(inLua, -1), 0, INT32_MAX, "invalid relight atlas address");
			inLua->Pop();
			inLua->GetField(row, "quadCount");
			const unsigned count = l2::integer(ReadNumber(inLua, -1), 1, l2::MaxQuads, "invalid relight quad count");
			inLua->Pop();
			layout.push_back({std::move(slot), first, count});
			inLua->Pop();
		}
		auto transaction = l2::GetSectionTasks().StageRelight(id, layout);
		inLua->PushUserType(transaction.get(), GetBindingState().mPixelTransactionType);
		try
		{
			source::GetMeshPublication().AdoptTransaction(std::move(transaction));
		}
		catch (...)
		{
			// Adoption may allocate. Never leave userdata pointing at its failed
			// unique_ptr after unwinding, even while the userdata awaits GC.
			inLua->SetUserType(-1, nullptr);
			throw;
		}
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int UploadRelight(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		auto		&transaction = ReadPixelTransaction(inLua);
		const double texture = ReadNumber(inLua, 2);
		l2::require(inLua->IsType(3, Type::Bool), "invalid Native L2 relight upload");
		const bool restore = inLua->GetBool(3);
		pixelupload::GetPixelTextureStore().UploadNative(transaction, pixelupload::ParsePixelTextureId(texture), restore);
		if (!restore)
		{
			++GetBindingState().mRelightBatches;
			for (const auto &update : transaction.updates())
				GetBindingState().mNativePixelTexels += update.next->occlusion.size() * 5;
		}
		inLua->PushBool(true);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int FinishRelight(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		auto &transaction = ReadPixelTransaction(inLua);
		l2::require(inLua->IsType(2, Type::Bool), "invalid Native L2 lighting publication");
		source::GetMeshPublication().FinishTransaction(transaction, inLua->GetBool(2));
		inLua->SetUserType(1, nullptr);
		inLua->PushBool(true);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int CancelSection(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const auto id = static_cast<uint64_t>(l2::integer(ReadNumber(inLua, 1), 0, INT32_MAX, "invalid L2 job"));
		l2::GetSectionTasks().Cancel(id);
		inLua->PushBool(true);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int CanSubmit(ILuaBase *inLua)
{
	inLua->PushBool(l2::GetSectionTasks().CanSubmit());
	return 1;
}
int Statistics(ILuaBase *inLua)
{
	const auto publication = source::GetMeshPublication().GetStats();
	inLua->CreateTable();
	SetNumber(inLua, "templates", static_cast<double>(GetBindingState().mTemplates));
	SetNumber(inLua, "liveTemplates", static_cast<double>(GetBindingState().mLiveTemplates));
	SetNumber(inLua, "batches", static_cast<double>(GetBindingState().mBatches));
	SetNumber(inLua, "liveMeshes", static_cast<double>(publication.mLiveMeshes));
	SetNumber(inLua, "vertices", static_cast<double>(GetBindingState().mVertices));
	SetNumber(inLua, "indices", static_cast<double>(GetBindingState().mIndices));
	SetNumber(inLua, "sampleReads", static_cast<double>(GetBindingState().mReads));
	SetNumber(inLua, "sampleCacheHits", static_cast<double>(GetBindingState().mHits));
	SetNumber(inLua, "failures", static_cast<double>(GetBindingState().mFailures));
	const auto s = l2::GetSectionTasks().GetStats();
	SetNumber(inLua, "workers", s.workers);
	SetNumber(inLua, "queued", s.queued);
	SetNumber(inLua, "running", s.running);
	SetNumber(inLua, "ready", s.ready);
	SetNumber(inLua, "peakRunning", s.peakRunning);
	SetNumber(inLua, "workerBytes", static_cast<double>(s.bytes));
	SetNumber(inLua, "submitted", static_cast<double>(s.submitted));
	SetNumber(inLua, "completed", static_cast<double>(s.completed));
	SetNumber(inLua, "releasedOrCancelled", static_cast<double>(s.cancelled));
	SetNumber(inLua, "commandMS", GetBindingState().mCommandMS);
	SetNumber(inLua, "snapshotMS", GetBindingState().mSnapshotMS);
	SetNumber(inLua, "computeMS", s.computeMS);
	SetNumber(inLua, "queueMS", s.queueMS);
	const auto cpu = core::GetCpuWorkGate()->GetStats();
	SetNumber(inLua, "cpuLimit", cpu.mLimit);
	SetNumber(inLua, "cpuActive", cpu.mActive);
	SetNumber(inLua, "cpuPeakActive", cpu.mPeakActive);
	SetNumber(inLua, "cpuQueued", cpu.mQueued);
	SetNumber(inLua, "cpuAdmitted", static_cast<double>(cpu.mAdmitted));
	SetNumber(inLua, "cpuCancelled", static_cast<double>(cpu.mCancelled));
	SetNumber(inLua, "cpuWaitMS", cpu.mWaitMS);
	constexpr const char *active_names[] = {"cpuVisibilityActive", "cpuDecodeActive", "cpuLightingActive", "cpuMeshActive"};
	constexpr const char *queued_names[] = {"cpuVisibilityQueued", "cpuDecodeQueued", "cpuLightingQueued", "cpuMeshQueued"};
	for (size_t i = 0; i < core::cCpuWorkClassCount; ++i)
	{
		SetNumber(inLua, active_names[i], cpu.mActiveByClass[i]);
		SetNumber(inLua, queued_names[i], cpu.mQueuedByClass[i]);
	}
	SetNumber(inLua, "uploadMS", GetBindingState().mUploadMS);
	SetNumber(inLua, "sectionVoxels", static_cast<double>(s.sectionVoxels));
	SetNumber(inLua, "sectionQuads", static_cast<double>(s.sectionQuads));
	SetNumber(inLua, "workerSampleReads", static_cast<double>(s.reads));
	SetNumber(inLua, "workerSampleCacheHits", static_cast<double>(s.hits));
	SetNumber(inLua, "faceSamples", static_cast<double>(s.faceSamples));
	SetNumber(inLua, "faceCacheHits", static_cast<double>(s.faceHits));
	SetNumber(inLua, "relightJobs", static_cast<double>(s.relightJobs));
	SetNumber(inLua, "relightQuads", static_cast<double>(s.relightQuads));
	SetNumber(inLua, "retainedLightBytes", static_cast<double>(publication.mRetainedLightBytes));
	SetNumber(inLua, "retainedLightMisses", 0);
	SetNumber(inLua, "meshPixelBytes", static_cast<double>(publication.mMeshPixelBytes));
	SetNumber(inLua, "nativePixelTexels", static_cast<double>(GetBindingState().mNativePixelTexels));
	SetNumber(inLua, "luaPixelValues", static_cast<double>(GetBindingState().mLuaPixelValues));
	SetNumber(inLua, "relightBatches", static_cast<double>(GetBindingState().mRelightBatches));
	SetNumber(inLua, "livePixelTransactions", static_cast<double>(publication.mLiveTransactions));
	return 1;
}
} // namespace mcmesh::l2bridge
