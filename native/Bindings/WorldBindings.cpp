#include "Module/Pch.h"
#include "Bindings/WorldBindings.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace mcmesh::worldbridge
{
using namespace GarrysMod::Lua;
namespace
{
int worldType = -1;
struct Handle
{
	world::Session *value = nullptr;
	Handle		   *previous = nullptr;
	Handle		   *next = nullptr;
	// Lua-thread counter; publish only after a batch/decoded commit succeeds.
	uint64_t		mContextShapeReferences = 0;
};
Handle *first = nullptr;
void	require(bool ok, const char *message)
{
	if (!ok)
		throw std::runtime_error(message);
}
void field(ILuaBase *lua, const char *name, double value)
{
	lua->PushNumber(value);
	lua->SetField(-2, name);
}
void boolean(ILuaBase *lua, const char *name, bool value)
{
	lua->PushBool(value);
	lua->SetField(-2, name);
}
void text(ILuaBase *lua, const char *name, const char *value)
{
	lua->PushString(value);
	lua->SetField(-2, name);
}
double number(ILuaBase *lua, int at, double low, double high)
{
	require(lua->IsType(at, Type::Number), "native world expected an integer");
	const auto value = lua->GetNumber(at);
	require(std::isfinite(value) && value == std::floor(value) && value >= low && value <= high,
			"native world integer is out of range");
	return value;
}
double scalar(ILuaBase *lua, int table, const char *name, double fallback)
{
	lua->GetField(table, name);
	double value = fallback;
	if (!lua->IsType(-1, Type::Nil))
	{
		require(lua->IsType(-1, Type::Number), "native world field must be numeric");
		value = lua->GetNumber(-1);
		require(std::isfinite(value), "native world field must be finite");
	}
	lua->Pop();
	return value;
}
double integer(ILuaBase *lua, int table, const char *name, double fallback, double low, double high)
{
	const auto value = scalar(lua, table, name, fallback);
	require(value >= low && value <= high && value == std::floor(value), "native world field is out of range");
	return value;
}
bool flag(ILuaBase *lua, int table, const char *name, bool fallback)
{
	lua->GetField(table, name);
	bool value = fallback;
	if (!lua->IsType(-1, Type::Nil))
	{
		require(lua->IsType(-1, Type::Bool), "native world field must be boolean");
		value = lua->GetBool(-1);
	}
	lua->Pop();
	return value;
}
std::string string(ILuaBase *lua, int table, const char *name)
{
	lua->GetField(table, name);
	require(lua->IsType(-1, Type::String), "native world string field is missing");
	unsigned	length = 0;
	const char *bytes = lua->GetString(-1, &length);
	std::string value(bytes, length);
	lua->Pop();
	return value;
}
void hex(ILuaBase *lua, const char *name, uint64_t value)
{
	char buffer[17];
	std::snprintf(buffer, sizeof(buffer), "%016llx", static_cast<unsigned long long>(value));
	text(lua, name, buffer);
}
void pushToken(ILuaBase *lua, uint64_t value)
{
	char buffer[17];
	std::snprintf(buffer, sizeof(buffer), "%016llx", static_cast<unsigned long long>(value));
	lua->PushString(buffer);
}
uint64_t token(ILuaBase *lua, int at)
{
	require(lua->IsType(at, Type::String), "native job id must use hexadecimal encoding");
	unsigned	size = 0;
	const char *value = lua->GetString(at, &size);
	require(size == 16, "native job id must have sixteen digits");
	uint64_t id = 0;
	for (unsigned i = 0; i < size; ++i)
	{
		const char c = value[i];
		const int  digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10
																				 : -1;
		require(digit >= 0, "invalid native job id");
		id = (id << 4) | unsigned(digit);
	}
	return id;
}
uint64_t versionField(ILuaBase *lua, int table, const char *name)
{
	const auto value = string(lua, table, name);
	require(value.size() == 16, "native version must use sixteen hexadecimal digits");
	uint64_t result = 0;
	for (char c : value)
	{
		const int digit = c >= '0' && c <= '9'	 ? c - '0'
						  : c >= 'a' && c <= 'f' ? c - 'a' + 10
												 : -1;
		require(digit >= 0, "invalid native hexadecimal version");
		result = (result << 4) | unsigned(digit);
	}
	return result;
}
void version(ILuaBase *lua, const world::Store &store)
{
	lua->CreateTable();
	hex(lua, "epoch", store.epoch());
	hex(lua, "revision", store.revision());
	hex(lua, "catalog", store.catalogRevision());
}
uint64_t checkVersion(ILuaBase *lua, int at, const world::Store &store)
{
	require(lua->IsType(at, Type::Table), "native mutation requires version tuple");
	require(versionField(lua, at, "epoch") == store.epoch() && versionField(lua, at, "catalog") == store.catalogRevision(),
			"native mutation belongs to another world or catalog");
	const auto revision = versionField(lua, at, "revision");
	require(revision == store.revision(), "stale native mutation revision");
	return revision;
}
int fail(ILuaBase *lua, int top, const char *error)
{
	if (lua->Top() > top)
		lua->Pop(lua->Top() - top);
	lua->PushNil();
	lua->PushString(error);
	return 2;
}
template <class F>
int boundary(ILuaBase *lua, F call)
{
	const int top = lua->Top();
	try
	{
		return call();
	}
	catch (const std::exception &e)
	{
		return fail(lua, top, e.what());
	}
}
void close(Handle *handle)
{
	if (!handle || !handle->value)
		return;
	if (handle->previous)
		handle->previous->next = handle->next;
	else
		first = handle->next;
	if (handle->next)
		handle->next->previous = handle->previous;
	delete handle->value;
	handle->value = nullptr;
	handle->previous = handle->next = nullptr;
}
world::Coord coord(ILuaBase *lua, int table)
{
	constexpr double Missing = double(INT32_MAX) + 1;
	return {int(integer(lua, table, "cx", Missing, INT32_MIN, INT32_MAX)),
			int(integer(lua, table, "cy", Missing, INT32_MIN, INT32_MAX)),
			int(integer(lua, table, "cz", Missing, INT32_MIN, INT32_MAX))};
}
world::Coord cellCoord(ILuaBase *lua, int at)
{
	return {int(number(lua, at, INT32_MIN, INT32_MAX)), int(number(lua, at + 1, INT32_MIN, INT32_MAX)),
			int(number(lua, at + 2, INT32_MIN, INT32_MAX))};
}
world::Config config(ILuaBase *lua, int table)
{
	require(lua->IsType(table, Type::Table), "native world requires configuration");
	require(integer(lua, table, "protocol", 0, 2, 2) == 2, "native world requires protocol 2");
	require(string(lua, table, "coordinateSpace") == "mc:block", "native world coordinates must be MC block coordinates");
	world::Config cfg;
	cfg.chunkSize = int(integer(lua, table, "chunkSize", 0, 1, 64));
	cfg.chunkHeight = int(integer(lua, table, "chunkHeight", 0, 1, 64));
	cfg.sectionSize = int(integer(lua, table, "sectionSize", 0, 1, 64));
	cfg.blockSize = scalar(lua, table, "blockSize", 0);
	cfg.streaming = flag(lua, table, "streaming", false);
	cfg.skyEnabled = flag(lua, table, "skyEnabled", true);
	cfg.minChunkZ = int(integer(lua, table, "minChunkZ", INT32_MIN, INT32_MIN, INT32_MAX));
	cfg.maxChunkZ = int(integer(lua, table, "maxChunkZ", INT32_MAX, INT32_MIN, INT32_MAX));
	// Largest exactly represented Lua integer that also fits size_t.
	constexpr double maxSize = sizeof(size_t) == 8 ? 9007199254740991.0 : double(SIZE_MAX);
	cfg.maxChunks = size_t(integer(lua, table, "maxChunks", double(cfg.maxChunks), 0, maxSize));
	cfg.maxLightChunks = size_t(integer(lua, table, "maxLightChunks", double(cfg.maxLightChunks), 0, maxSize));
	cfg.maxLightBytes = size_t(integer(lua, table, "maxLightBytes", double(cfg.maxLightBytes), 0, maxSize));
	cfg.validate();
	return cfg;
}
std::shared_ptr<const l2::Shape> renderShape(ILuaBase *lua, int table)
{
	require(lua->IsType(table, Type::Table), "native profile requires render shape");
	auto result = std::make_shared<l2::Shape>();
	result->selector = unsigned(integer(lua, table, "selector", -1, 0, 3));
	result->stair = int(integer(lua, table, "stair", -2, -1, 7));
	result->connections = unsigned(integer(lua, table, "connections", -1, 0, 7));
	result->pane = flag(lua, table, "pane", false);
	lua->GetField(table, "variants");
	const int variants = lua->Top();
	require(lua->IsType(variants, Type::Table) && lua->ObjLen(variants) <= 64, "invalid render shape variants");
	result->variants.clear();
	for (int i = 1; i <= lua->ObjLen(variants); ++i)
	{
		lua->PushNumber(i);
		lua->RawGet(variants);
		const int boxes = lua->Top();
		require(lua->IsType(boxes, Type::Table) && lua->ObjLen(boxes) <= 4096, "invalid render shape boxes");
		std::vector<l2::ShapeBox> values;
		for (int j = 1; j <= lua->ObjLen(boxes); ++j)
		{
			lua->PushNumber(j);
			lua->RawGet(boxes);
			const int box = lua->Top();
			require(lua->IsType(box, Type::Table) && lua->ObjLen(box) == 6, "invalid render shape box");
			l2::ShapeBox value;
			for (unsigned a = 0; a < 6; ++a)
			{
				lua->PushNumber(a + 1);
				lua->RawGet(box);
				require(lua->IsType(-1, Type::Number), "invalid render shape coordinate");
				value[a] = lua->GetNumber(-1);
				lua->Pop();
			}
			values.push_back(value);
			lua->Pop();
		}
		result->variants.push_back(std::move(values));
		lua->Pop();
	}
	lua->Pop();
	result->validate();
	return result;
}
world::Profile ParseProfile(ILuaBase *inLua, int inTable, const world::Catalog *inCatalog = nullptr,
						   uint64_t *outShapeReferences = nullptr)
{
	require(inLua->IsType(inTable, Type::Table), "native state profile must be a table");
	world::Profile result;
	result.emission = uint8_t(integer(inLua, inTable, "propagationEmission", -1, 0, 15));
	result.opacity = uint8_t(integer(inLua, inTable, "propagationOpacity", -1, 0, 15));
	result.skyCost = uint8_t(integer(inLua, inTable, "skyCost", -1, 1, 16));
	result.l2Word = uint32_t(integer(inLua, inTable, "l2Word", -1, 0, 1048575));
	result.renderClass = uint32_t(integer(inLua, inTable, "renderClass", -1, 0, UINT32_MAX));
	result.shade = float(scalar(inLua, inTable, "shade", -1));
	inLua->GetField(inTable, "shapeState");
	if (inLua->IsType(-1, Type::Nil))
	{
		inLua->Pop();
		inLua->GetField(inTable, "shape");
		result.shape = renderShape(inLua, inLua->Top());
		inLua->Pop();
	}
	else
	{
		// The session owns an immutable, validated catalog for this version.
		// Catalog construction itself cannot reference a not-yet-built state.
		require(inCatalog != nullptr, "native catalog profiles cannot reference catalog shapes");
		const auto state = size_t(number(inLua, -1, 0, double(inCatalog->states.size() - 1)));
		result.shape = inCatalog->states[state].shape;
		inLua->Pop();
		if (outShapeReferences)
			++*outShapeReferences;
	}
	inLua->GetField(inTable, "fluid");
	const int fluid = inLua->Top();
	require(inLua->IsType(fluid, Type::Table), "native profile requires fluid properties");
	auto &f = result.fluid;
	f.kind = uint8_t(integer(inLua, fluid, "kind", -1, 0, 2));
	f.height = scalar(inLua, fluid, "height", -1);
	require(f.height >= 0 && f.height <= 1, "invalid fluid height");
	const auto boolean = [&](const char *inName)
	{
		inLua->GetField(fluid, inName);
		require(inLua->IsType(-1, Type::Bool), "missing fluid boolean property");
		const bool value = inLua->GetBool(-1);
		inLua->Pop();
		return value;
	};
	f.solid = boolean("solid");
	f.blocksMotion = boolean("blocksMotion");
	f.falling = boolean("falling");
	f.ice = boolean("ice");
	result.fluidSolid = boolean("lightSolid");
	const bool full = boolean("full"), empty = boolean("empty");
	inLua->GetField(fluid, "boxes");
	const int boxes = inLua->Top();
	require(inLua->IsType(boxes, Type::Table), "missing fluid collision boxes");
	const int count = inLua->ObjLen(boxes);
	require(count >= 0 && count <= 4096, "fluid collision box limit");
	std::vector<l2::FluidBox> values;
	values.reserve(count);
	for (int i = 1; i <= count; ++i)
	{
		inLua->PushNumber(i);
		inLua->RawGet(boxes);
		const int box = inLua->Top();
		require(inLua->IsType(box, Type::Table) && inLua->ObjLen(box) == 6, "invalid fluid collision box");
		l2::FluidBox value;
		for (unsigned a = 0; a < 6; ++a)
		{
			inLua->PushNumber(a + 1);
			inLua->RawGet(box);
			require(inLua->IsType(-1, Type::Number), "invalid fluid collision coordinate");
			value[a] = inLua->GetNumber(-1);
			inLua->Pop();
		}
		values.push_back(value);
		inLua->Pop();
	}
	l2::compileFluidCoverage(f, full, empty, values);
	inLua->Pop(2);
	result.validate();
	return result;
}
std::shared_ptr<const world::Catalog> catalog(ILuaBase *lua, int table)
{
	require(lua->IsType(table, Type::Table), "native world requires a state catalog");
	integer(lua, table, "formatVersion", 0, 2, 2);
	auto value = std::make_shared<world::Catalog>();
	value->revision = uint64_t(integer(lua, table, "revision", 0, 1, 9007199254740991.0));
	const auto count = unsigned(integer(lua, table, "stateCount", 0, 1, 1048576));
	const auto map = string(lua, table, "stateProfiles");
	require(map.size() == size_t(count) * 4, "native state profile map has wrong size");
	lua->GetField(table, "profiles");
	const int profilesTable = lua->Top();
	require(lua->IsType(profilesTable, Type::Table), "native profiles must be an array");
	const int size = lua->ObjLen(profilesTable);
	require(size > 0 && size <= 1048576, "native profile count exceeds budget");
	std::vector<world::Profile> profiles;
	profiles.reserve(size);
	for (int i = 1; i <= size; ++i)
	{
		lua->PushNumber(i);
		lua->RawGet(profilesTable);
		profiles.push_back(ParseProfile(lua, lua->Top()));
		value->shapeBytes += profiles.back().shape->bytes();
		lua->Pop();
	}
	lua->Pop();
	value->states.reserve(count);
	for (unsigned i = 0; i < count; ++i)
	{
		const auto	  *b = reinterpret_cast<const unsigned char *>(map.data() + i * 4);
		const uint32_t index = b[0] | (uint32_t(b[1]) << 8) | (uint32_t(b[2]) << 16) | (uint32_t(b[3]) << 24);
		require(index < profiles.size(), "native state profile index is outside catalog");
		value->states.push_back(profiles[index]);
	}
	lua->GetField(table, "contextual");
	if (!lua->IsType(-1, Type::Nil))
	{
		require(lua->IsType(-1, Type::String), "native context flags must be a binary string");
		unsigned	length = 0;
		const auto *data = reinterpret_cast<const uint8_t *>(lua->GetString(-1, &length));
		require(length == count, "native context flags have wrong length");
		value->contextual.assign(data, data + length);
	}
	lua->Pop();
	lua->GetField(table, "blockEntityStates");
	if (!lua->IsType(-1, Type::Nil))
	{
		require(lua->IsType(-1, Type::String), "native block entity flags must be a binary string");
		unsigned length = 0;
		const auto *data = reinterpret_cast<const uint8_t *>(lua->GetString(-1, &length));
		require(length == count, "native block entity flags have wrong length");
		value->mBlockEntityStates.assign(data, data + length);
	}
	lua->Pop();
	value->validate();
	return value;
}
std::vector<world::Mutation> ParseBatch(ILuaBase *inLua, int inTable, const world::Store &inStore,
								 uint64_t &outShapeReferences)
{
	const auto state_catalog = inStore.catalog();
	require(inLua->IsType(inTable, Type::Table), "native world batch must be an array");
	const int size = inLua->ObjLen(inTable);
	require(size >= 0 && size <= 64, "native world batch exceeds 64 chunks");
	std::vector<world::Mutation> result;
	result.reserve(size);
	for (int i = 1; i <= size; ++i)
	{
		inLua->PushNumber(i);
		inLua->RawGet(inTable);
		const int row = inLua->Top();
		require(inLua->IsType(row, Type::Table), "native mutation must be a table");
		world::Mutation mutation;
		mutation.chunk = coord(inLua, row);
		const auto op = string(inLua, row, "op");
		if (op == "replace")
			mutation.kind = world::Mutation::Kind::Replace;
		else if (op == "patch")
			mutation.kind = world::Mutation::Kind::Patch;
		else if (op == "unload")
			mutation.kind = world::Mutation::Kind::Unload;
		else
			throw std::runtime_error("unknown native world mutation");
		mutation.terrainPresent = flag(inLua, row, "terrainPresent", true);
		inLua->GetField(row, "cells");
		if (!inLua->IsType(-1, Type::Nil))
		{
			const int cells = inLua->Top();
			require(inLua->IsType(cells, Type::Table), "native cells must be a flat index/state array");
			const int count = inLua->ObjLen(cells);
			require(count >= 0 && count % 2 == 0 && unsigned(count / 2) <= inStore.config().cellCount(),
					"native mutation cell count is invalid");
			mutation.cells.reserve(count / 2);
			for (int c = 1; c <= count; c += 2)
			{
				inLua->PushNumber(c);
				inLua->RawGet(cells);
				const auto li = unsigned(number(inLua, -1, 0, inStore.config().cellCount() - 1));
				inLua->Pop();
				inLua->PushNumber(c + 1);
				inLua->RawGet(cells);
				const auto state = uint32_t(number(inLua, -1, 0, 1048575));
				inLua->Pop();
				mutation.cells.push_back({li, state});
			}
		}
		inLua->Pop();
		inLua->GetField(row, "contexts");
		if (!inLua->IsType(-1, Type::Nil))
		{
			const int contexts = inLua->Top();
			require(inLua->IsType(contexts, Type::Table), "native contexts must be an array");
			const int count = inLua->ObjLen(contexts);
			require(count >= 0 && unsigned(count) <= inStore.config().cellCount(), "native context count is invalid");
			mutation.contexts.reserve(count);
			for (int c = 1; c <= count; ++c)
			{
				inLua->PushNumber(c);
				inLua->RawGet(contexts);
				const int entry = inLua->Top();
				require(inLua->IsType(entry, Type::Table), "native context must be a typed profile");
				world::ContextEdit context;
				context.index = unsigned(integer(inLua, entry, "index", -1, 0, inStore.config().cellCount() - 1));
				context.clear = flag(inLua, entry, "clear", false);
				if (!context.clear)
					context.value = ParseProfile(inLua, entry, state_catalog.get(), &outShapeReferences);
				mutation.contexts.push_back(context);
				inLua->Pop();
			}
		}
		inLua->Pop();
		result.push_back(std::move(mutation));
		inLua->Pop();
	}
	return result;
}
LUA_FUNCTION(getVersion)
{
	return boundary(LUA, [&]
					{ version(LUA, session(LUA, 1).store()); return 1; });
}
LUA_FUNCTION(applyBatch)
{
	return boundary(LUA, [&]
	{
		auto &value = session(LUA, 1);
		const auto revision = checkVersion(LUA, 2, value.store());
		uint64_t shape_references = 0;
		auto mutations = ParseBatch(LUA, 3, value.store(), shape_references);
		require(value.apply(revision, mutations), "native mutation version changed");
		LUA->GetUserType<Handle>(1, worldType)->mContextShapeReferences += shape_references;
		version(LUA, value.store());
		return 1;
	});
}
void PushDecodedChunks(ILuaBase *inLua, const world::DecodedResult &inResult, const std::vector<unsigned> &inIndices,
					   bool inIncludeContexts, bool inIncludeBlockEntityCells)
{
	inLua->CreateTable();
	unsigned output_index = 1, blocks = 0;
	for (auto index : inIndices)
	{
		const auto &chunk = inResult.chunks.at(index);
		blocks += chunk.count;
		inLua->PushNumber(output_index++);
		inLua->CreateTable();
		field(inLua, "cx", chunk.coord.x);
		field(inLua, "cy", chunk.coord.y);
		field(inLua, "cz", chunk.coord.z);
		field(inLua, "count", chunk.count);
		inLua->PushString(chunk.blockEntitiesJSON.data(), unsigned(chunk.blockEntitiesJSON.size()));
		inLua->SetField(-2, "blockEntitiesJSON");
		inLua->CreateTable();
		if (inIncludeContexts)
		{
			unsigned cell_index = 1;
			for (const auto &entry : chunk.contextCells)
			{
				inLua->PushNumber(cell_index++);
				inLua->PushNumber(entry.index);
				inLua->RawSet(-3);
				inLua->PushNumber(cell_index++);
				inLua->PushNumber(entry.state);
				inLua->RawSet(-3);
			}
		}
		inLua->SetField(-2, "contextCells");
		if (inIncludeBlockEntityCells && inResult.mBlockEntityCellsComplete)
		{
			inLua->CreateTable();
			unsigned cell_index = 1;
			for (const auto &entry : chunk.mBlockEntityCells)
			{
				inLua->PushNumber(cell_index++);
				inLua->PushNumber(entry.index);
				inLua->RawSet(-3);
				inLua->PushNumber(cell_index++);
				inLua->PushNumber(entry.state);
				inLua->RawSet(-3);
			}
			inLua->SetField(-2, "blockEntityCells");
		}
		inLua->RawSet(-3);
	}
	inLua->SetField(-2, "chunks");
	field(inLua, "blocks", blocks);
}
LUA_FUNCTION(startDecode)
{
	return boundary(LUA, [&]
					{
        auto& value = session(LUA, 1);
        checkVersion(LUA, 2, value.store());
        require(LUA->IsType(3, Type::String) && LUA->IsType(4, Type::Table),
            "native binary decode requires payload and metadata");
        world::DecodeMetadata meta;
        meta.compression = uint8_t(integer(LUA, 4, "compression", -1, 0, 1));
        meta.rawBytes = uint32_t(integer(LUA, 4, "rawBytes", -1, 14, 64 * 1024 * 1024));
        meta.generation = uint32_t(integer(LUA, 4, "generation", -1, 0, UINT32_MAX));
        meta.revision = uint32_t(integer(LUA, 4, "revision", -1, 0, UINT32_MAX));
        meta.chunks = uint32_t(integer(LUA, 4, "chunks", -1, 1, 64));
        meta.cells = uint32_t(integer(LUA, 4, "cells", -1, 0, 131072));
        unsigned size = 0;
        const auto* data = reinterpret_cast<const uint8_t*>(LUA->GetString(3, &size));
        require(size > 0 && size <= 16 * 1024 * 1024, "native binary payload exceeds budget");
        pushToken(LUA, value.startDecode(meta, std::vector<uint8_t>(data, data + size)));
        return 1; });
}
void PushTransportStatus(ILuaBase *inLua, const world::TransportStatus &inStatus)
{
	const char *names[] = {"receiving", "queued", "running", "ready", "failed"};
	inLua->CreateTable();
	text(inLua, "status", names[unsigned(inStatus.mState)]);
	if (!inStatus.mError.empty())
		text(inLua, "error", inStatus.mError.c_str());
	field(inLua, "receivedParts", inStatus.mReceivedParts);
	field(inLua, "receivedBytes", double(inStatus.mReceivedBytes));
	if (inStatus.mState != world::ETransportState::Ready)
		return;
	boolean(inLua, "binary", inStatus.mBinary);
	field(inLua, "chunkCount", inStatus.mChunks);
	field(inLua, "cellCount", inStatus.mCells);
	field(inLua, "validateMS", inStatus.mValidateMS);
	inLua->CreateTable();
	unsigned index = 0;
	for (const auto &batch : inStatus.mBatches)
	{
		inLua->PushNumber(++index);
		inLua->CreateTable();
		field(inLua, "compression", batch.compression);
		field(inLua, "rawBytes", batch.rawBytes);
		field(inLua, "chunkCount", batch.chunks);
		field(inLua, "cellCount", batch.cells);
		inLua->RawSet(-3);
	}
	inLua->SetField(-2, "batches");
}

LUA_FUNCTION(BeginTransport)
{
	return boundary(LUA, [&]
	{
		auto &value = session(LUA, 1);
		checkVersion(LUA, 2, value.store());
		require(LUA->IsType(3, Type::Table), "native transport requires metadata");
		world::TransportInput input;
		input.mSnapshot = flag(LUA, 3, "snapshot", false);
		input.mGeneration = uint32_t(integer(LUA, 3, "generation", -1, 0, UINT32_MAX));
		input.mRevision = uint32_t(integer(LUA, 3, "revision", -1, 0, UINT32_MAX));
		input.mPartCount = unsigned(integer(LUA, 3, "partCount", -1, 1, 65535));
		input.mPartBytes = unsigned(integer(LUA, 3, "partBytes", -1, 1, 65535));
		input.mTotalBytes = size_t(integer(LUA, 3, "totalBytes", -1, 4, 64 * 1024 * 1024));
		input.mChunkSize = value.store().config().chunkSize;
		input.mChunkHeight = value.store().config().chunkHeight;
		input.mSectionCount = value.store().config().sectionCount();
		if (!input.mSnapshot)
		{
			input.mPatch.generation = input.mGeneration;
			input.mPatch.revision = input.mRevision;
			input.mPatch.compression = uint8_t(integer(LUA, 3, "compression", -1, 0, 1));
			input.mPatch.rawBytes = uint32_t(integer(LUA, 3, "rawBytes", -1, 14, 16 * 1024 * 1024));
			input.mPatch.chunks = uint32_t(integer(LUA, 3, "chunkCount", -1, 1, 64));
			input.mPatch.cells = uint32_t(integer(LUA, 3, "cellCount", -1, 0, 131072));
		}
		pushToken(LUA, value.GetTransport().Begin(input));
		return 1;
	});
}

LUA_FUNCTION(ReadTransportPart)
{
	return boundary(LUA, [&]
	{
		// GMod exposes net.ReadData, not its active bf_read. Use a protected call
		// and immediately copy into the Native owner; never return the string to
		// the Lua receive callback or retain a registry reference to it.
		const auto id = token(LUA, 2);
		const auto part = unsigned(number(LUA, 3, 0, 65534));
		const auto length = unsigned(number(LUA, 4, 1, 65535));
		LUA->GetField(INDEX_GLOBAL, "net");
		require(LUA->IsType(-1, Type::Table), "native transport requires net library");
		LUA->GetField(-1, "ReadData");
		require(LUA->IsType(-1, Type::Function), "native transport requires net.ReadData");
		LUA->Remove(-2);
		LUA->PushNumber(length);
		if (LUA->PCall(1, 1, 0) != 0)
		{
			const auto *error = LUA->IsType(-1, Type::String) ? LUA->GetString(-1) : nullptr;
			throw std::runtime_error(error ? error : "native transport net.ReadData failed");
		}
		require(LUA->IsType(-1, Type::String), "native transport net.ReadData returned no bytes");
		unsigned size = 0;
		const auto *bytes = reinterpret_cast<const uint8_t *>(LUA->GetString(-1, &size));
		require(size == length, "native transport net.ReadData length mismatch");
		const auto status = session(LUA, 1).GetTransport().Accept(id, part, bytes, size);
		LUA->Pop();
		PushTransportStatus(LUA, status);
		return 1;
	});
}

LUA_FUNCTION(AcceptTransportPart)
{
	return boundary(LUA, [&]
	{
		require(LUA->IsType(4, Type::String), "native transport part requires bytes");
		unsigned size = 0;
		const auto *bytes = reinterpret_cast<const uint8_t *>(LUA->GetString(4, &size));
		const auto status = session(LUA, 1).GetTransport().Accept(token(LUA, 2),
			unsigned(number(LUA, 3, 0, 65534)), bytes, size);
		PushTransportStatus(LUA, status);
		return 1;
	});
}

LUA_FUNCTION(SealTransport)
{
	return boundary(LUA, [&]
	{
		require(LUA->IsType(3, Type::String), "native transport requires CRC string");
		unsigned size = 0;
		const auto *crc = LUA->GetString(3, &size);
		session(LUA, 1).GetTransport().Seal(token(LUA, 2), std::string(crc, size));
		LUA->PushBool(true);
		return 1;
	});
}

LUA_FUNCTION(PollTransport)
{
	return boundary(LUA, [&]
	{
		PushTransportStatus(LUA, session(LUA, 1).GetTransport().Poll(token(LUA, 2)));
		return 1;
	});
}

LUA_FUNCTION(StartTransportDecode)
{
	return boundary(LUA, [&]
	{
		auto &value = session(LUA, 1);
		checkVersion(LUA, 2, value.store());
		pushToken(LUA, value.StartTransportDecode(token(LUA, 3), unsigned(number(LUA, 4, 1, 65535)) - 1));
		return 1;
	});
}

LUA_FUNCTION(TakeLegacyTransport)
{
	return boundary(LUA, [&]
	{
		const auto bytes = session(LUA, 1).GetTransport().TakeLegacy(token(LUA, 2));
		LUA->PushString(reinterpret_cast<const char *>(bytes.data()), unsigned(bytes.size()));
		return 1;
	});
}

LUA_FUNCTION(CancelTransport)
{
	return boundary(LUA, [&]
	{
		session(LUA, 1).GetTransport().Release(token(LUA, 2));
		LUA->PushBool(true);
		return 1;
	});
}

LUA_FUNCTION(GetTransportStats)
{
	return boundary(LUA, [&]
	{
		const auto stats = session(LUA, 1).GetTransport().GetStats();
		LUA->CreateTable();
		field(LUA, "jobs", double(stats.mJobs));
		field(LUA, "running", double(stats.mRunning));
		field(LUA, "retainedBytes", double(stats.mRetainedBytes));
		field(LUA, "reservedBytes", double(stats.mReservedBytes));
		return 1;
	});
}

LUA_FUNCTION(pollDecode)
{
	return boundary(LUA, [&]
					{
        const auto status = session(LUA, 1).pollDecode(token(LUA, 2));
        const char* names[] = {"queued", "running", "ready", "failed", "cancelled"};
        LUA->CreateTable();
        text(LUA, "status", names[unsigned(status.state)]);
        if (!status.error.empty()) text(LUA, "error", status.error.c_str());
        if (status.result) {
            const auto& result = *status.result;
            field(LUA, "generation", result.metadata.generation); field(LUA, "revision", result.metadata.revision);
            hex(LUA, "backendEpoch", result.prepared.epoch);
            field(LUA, "decompressMS", result.decompressMS); field(LUA, "parseMS", result.parseMS);
            std::vector<unsigned> indices;
            for (unsigned i = 0; i < result.chunks.size(); ++i) indices.push_back(i);
            PushDecodedChunks(LUA, result, indices, true, false);
        }
        return 1; });
}
LUA_FUNCTION(commitDecode)
{
	return boundary(LUA, [&]
	{
		auto &value = session(LUA, 1);
		const auto revision = checkVersion(LUA, 2, value.store());
		const auto id = token(LUA, 3);
		const auto decoded = value.pollDecode(id).result;
		require(decoded != nullptr, "native binary decode is not ready");
		require(LUA->IsType(4, Type::Table), "native binary include must be an array");
		const auto count = LUA->ObjLen(4);
		require(count >= 0 && size_t(count) <= decoded->chunks.size(), "invalid native binary include length");
		std::vector<unsigned> include;
		for (int i = 1; i <= count; ++i)
		{
			LUA->PushNumber(i);
			LUA->RawGet(4);
			include.push_back(unsigned(number(LUA, -1, 1, double(decoded->chunks.size()))) - 1);
			LUA->Pop();
		}
		std::vector<world::Mutation> contexts;
		uint64_t shape_references = 0;
		if (!LUA->IsType(5, Type::Nil))
			contexts = ParseBatch(LUA, 5, value.store(), shape_references);
		require(LUA->IsType(6, Type::Nil) || LUA->IsType(6, Type::Bool), "invalid native binary context result flag");
		const bool include_contexts = LUA->IsType(6, Type::Nil) || LUA->GetBool(6);
		// Prepare all Lua result allocations before changing native world ownership.
		LUA->CreateTable();
		PushDecodedChunks(LUA, *decoded, include, include_contexts, true);
		require(value.commitDecode(revision, id, include, contexts), "stale native binary decode");
		LUA->GetUserType<Handle>(1, worldType)->mContextShapeReferences += shape_references;
		return 1;
	});
}
LUA_FUNCTION(cancelDecode)
{
	return boundary(LUA, [&]
					{ session(LUA, 1).cancelDecode(token(LUA, 2)); LUA->PushBool(true); return 1; });
}
LUA_FUNCTION(cancelAllDecodes)
{
	return boundary(LUA, [&]
					{ session(LUA, 1).cancelAllDecodes(); LUA->PushBool(true); return 1; });
}
LUA_FUNCTION(getCell)
{
	return boundary(LUA, [&]
					{ LUA->PushNumber(session(LUA, 1).store().state(cellCoord(LUA, 2))); return 1; });
}
LUA_FUNCTION(isKnown)
{
	return boundary(LUA, [&]
					{ LUA->PushBool(session(LUA, 1).store().known(cellCoord(LUA, 2))); return 1; });
}
LUA_FUNCTION(getChunkInfo)
{
	return boundary(LUA, [&]
					{
        const auto& store = session(LUA, 1).store();
        const auto coord = cellCoord(LUA, 2);
        store.config().validateChunk(coord);
        const auto chunk = store.chunk(coord);
        LUA->CreateTable();
        boolean(LUA, "present", chunk != nullptr);
        field(LUA, "count", chunk ? chunk->count : 0);
        boolean(LUA, "terrainPresent", chunk && chunk->terrainPresent);
        return 1; });
}
LUA_FUNCTION(getLight)
{
	return boundary(LUA, [&]
					{
        const auto& store = session(LUA, 1).store();
        const auto cell = cellCoord(LUA, 2);
        LUA->PushNumber(store.light(cell, false)); LUA->PushNumber(store.light(cell, true));
        return 2; });
}
LUA_FUNCTION(lightReady)
{
	return boundary(LUA, [&]
					{ LUA->PushBool(session(LUA, 1).store().lightReady(cellCoord(LUA, 2))); return 1; });
}
LUA_FUNCTION(meshReady)
{
	return boundary(LUA, [&]
					{
        const auto& store = session(LUA, 1).store();
        const auto section = unsigned(number(LUA, 5, 1, store.config().sectionCount())) - 1;
        LUA->PushBool(store.meshReady(cellCoord(LUA, 2), section));
        return 1; });
}
LUA_FUNCTION(getCells)
{
	return boundary(LUA, [&]
					{
        const auto& store = session(LUA, 1).store();
        const auto chunk = cellCoord(LUA, 2);
        const auto& cfg = store.config();
        cfg.validateChunk(chunk);
        LUA->CreateTable();
        unsigned at = 1;
        for (unsigned li = 0; li < cfg.cellCount(); ++li) {
            const auto state = store.state(cfg.cellAt(chunk, li));
            if (!state) continue;
            LUA->PushNumber(at++); LUA->PushNumber(li); LUA->RawSet(-3);
            LUA->PushNumber(at++); LUA->PushNumber(state); LUA->RawSet(-3);
        }
        return 1; });
}
LUA_FUNCTION(getSectionCells)
{
	return boundary(LUA, [&]
	{
		const auto &store = session(LUA, 1).store();
		const auto chunk_coord = cellCoord(LUA, 2);
		const auto section_index = unsigned(number(LUA, 5, 1, store.config().sectionCount())) - 1;
		const auto cells = store.ReadSectionCells(chunk_coord, section_index);
		LUA->CreateTable();
		unsigned at = 1;
		for (const auto &cell : cells)
		{
			LUA->PushNumber(at++);
			LUA->PushNumber(cell.index);
			LUA->RawSet(-3);
			LUA->PushNumber(at++);
			LUA->PushNumber(cell.state);
			LUA->RawSet(-3);
		}
		return 1;
	});
}
LUA_FUNCTION(GetSectionCellsFiltered)
{
	return boundary(LUA, [&]
	{
		const auto &store = session(LUA, 1).store();
		const auto chunk_coord = cellCoord(LUA, 2);
		const auto section_index = unsigned(number(LUA, 5, 1, store.config().sectionCount())) - 1;
		require(LUA->IsType(6, Type::Table), "native section state filter must be an array");
		const int count = LUA->ObjLen(6);
		const int size = store.config().sectionSize;
		require(count >= 0 && count <= size * size * size, "native section state filter is too large");
		std::unordered_set<uint32_t> states;
		states.reserve(size_t(count));
		for (int i = 1; i <= count; ++i)
		{
			LUA->PushNumber(i);
			LUA->RawGet(6);
			const auto state = uint32_t(number(LUA, -1, 1, double(store.catalog()->states.size()) - 1));
			LUA->Pop();
			require(states.emplace(state).second, "duplicate native section filter state");
		}
		const auto cells = store.ReadSectionCells(chunk_coord, section_index, &states);
		LUA->CreateTable();
		unsigned at = 1;
		for (const auto &cell : cells)
		{
			LUA->PushNumber(at++);
			LUA->PushNumber(cell.index);
			LUA->RawSet(-3);
			LUA->PushNumber(at++);
			LUA->PushNumber(cell.state);
			LUA->RawSet(-3);
		}
		return 1;
	});
}
LUA_FUNCTION(getSectionInfo)
{
	return boundary(LUA, [&]
					{
        const auto& store = session(LUA, 1).store();
        const auto coord = cellCoord(LUA, 2);
        store.config().validateChunk(coord);
        const auto index = unsigned(number(LUA, 5, 1, store.config().sectionCount())) - 1;
        const auto chunk = store.chunk(coord);
        require(chunk != nullptr, "native section source is absent");
        const auto& section = chunk->sections[index];
        LUA->CreateTable();
        field(LUA, "count", section ? section->count : 0);
        LUA->CreateTable();
        if (section) for (const auto& entry : section->counts) {
            LUA->PushNumber(entry.first); LUA->PushNumber(entry.second); LUA->RawSet(-3);
        }
        LUA->SetField(-2, "counts");
        return 1; });
}
LUA_FUNCTION(pump)
{
	return boundary(LUA, [&]
					{
        const bool specified = LUA->Top() >= 2 && !LUA->IsType(2, Type::Nil);
        require(!specified || LUA->IsType(2, Type::Bool), "invalid light change export option");
        const bool includeChanged = !specified || LUA->GetBool(2);
        const auto result = session(LUA, 1).pump();
        if (!result.error.empty()) throw std::runtime_error(result.error);
        LUA->CreateTable();
        boolean(LUA, "completed", result.completed); boolean(LUA, "submitted", result.submitted);
        boolean(LUA, "pending", result.pending); boolean(LUA, "stale", result.commit.stale);
        field(LUA, "committed", result.commit.committed); field(LUA, "deferred", result.commit.deferred);
        field(LUA, "computeMS", result.computeMS); field(LUA, "diffMS", result.diffMS);
        field(LUA, "commitMS", result.commitMS); field(LUA, "snapshotMS", result.snapshotMS);
        field(LUA, "scannedCells", double(result.scannedCells));
        unsigned index = 1;
        // The renderer consumes worker-computed dirtySections. Detailed cell
        // deltas remain available to diagnostic/legacy callers on request.
        if (includeChanged) {
            LUA->CreateTable();
            for (const auto& pointer : result.commit.changed) {
                const auto& delta = *pointer;
                LUA->PushNumber(index++); LUA->CreateTable();
                field(LUA, "cx", delta.chunk.x); field(LUA, "cy", delta.chunk.y); field(LUA, "cz", delta.chunk.z);
                LUA->PushString(reinterpret_cast<const char*>(delta.changedBits.data()), unsigned(delta.changedBits.size()));
                LUA->SetField(-2, "changedBits");
                LUA->RawSet(-3);
            }
            LUA->SetField(-2, "changed");
        }
        const auto& owners = result.commit.dirtySections;
        LUA->CreateTable();
        index = 1;
        for (const auto& entry : owners) {
            LUA->PushNumber(index++); LUA->CreateTable();
            field(LUA, "cx", entry.first.x); field(LUA, "cy", entry.first.y); field(LUA, "cz", entry.first.z);
            LUA->CreateTable();
            unsigned at = 1;
            for (auto section : entry.second) {
                LUA->PushNumber(at++); LUA->PushNumber(section + 1); LUA->RawSet(-3);
            }
            LUA->SetField(-2, "sections");
            LUA->RawSet(-3);
        }
        LUA->SetField(-2, "dirtySections");
        return 1; });
}
LUA_FUNCTION(requestLight)
{
	return boundary(LUA, [&]
					{ session(LUA, 1).requestLight(); LUA->PushBool(true); return 1; });
}
LUA_FUNCTION(reset)
{
	return boundary(LUA, [&]
	{
		auto &value = session(LUA, 1);
		value.reset(config(LUA, 2), catalog(LUA, 3));
		LUA->GetUserType<Handle>(1, worldType)->mContextShapeReferences = 0;
		version(LUA, value.store());
		return 1;
	});
}
LUA_FUNCTION(reconfigure)
{
	return boundary(LUA, [&]
					{
        session(LUA, 1).reconfigure(config(LUA, 2));
        version(LUA, session(LUA, 1).store());
        return 1; });
}
LUA_FUNCTION(stats)
{
	return boundary(LUA, [&]
	{
		const auto &value = session(LUA, 1);
		const auto worker = value.workerStats();
		version(LUA, value.store());
		field(LUA, "chunks", double(value.store().chunkCount()));
		field(LUA, "lightChunks", double(value.store().lightChunkCount()));
		field(LUA, "submitted", double(worker.submitted));
		field(LUA, "completed", double(worker.completed));
		field(LUA, "failed", double(worker.failed));
		field(LUA, "cancelled", double(worker.cancelled));
		field(LUA, "computeMS", worker.computeMS);
		field(LUA, "diffMS", worker.diffMS);
		field(LUA, "commitMS", value.commitMS());
		field(LUA, "snapshotMS", value.snapshotMS());
		field(LUA, "contextShapeReferences", double(LUA->GetUserType<Handle>(1, worldType)->mContextShapeReferences));
		boolean(LUA, "busy", worker.busy);
		boolean(LUA, "running", worker.running);
		boolean(LUA, "pending", value.pending());
		return 1;
	});
}
LUA_FUNCTION(closeWorld)
{
	close(LUA->GetUserType<Handle>(1, worldType));
	LUA->PushBool(true);
	return 1;
}
void function(ILuaBase *lua, const char *name, CFunc fn)
{
	lua->PushCFunction(fn);
	lua->SetField(-2, name);
}
} // namespace
world::Session &session(ILuaBase *lua, int at)
{
	auto *handle = lua->GetUserType<Handle>(at, worldType);
	require(handle && handle->value, "native world session is closed or invalid");
	return *handle->value;
}
void initialize(ILuaBase *lua)
{
	worldType = lua->CreateMetaTable("MCNativeWorldV2");
	function(lua, "__gc", closeWorld);
	lua->Push(-1);
	lua->SetField(-2, "__index");
	function(lua, "Version", getVersion);
	function(lua, "ApplyBatch", applyBatch);
	function(lua, "StartBinaryDecode", startDecode);
	function(lua, "BeginTransport", BeginTransport);
	function(lua, "ReadTransportPart", ReadTransportPart);
	function(lua, "AcceptTransportPart", AcceptTransportPart);
	function(lua, "SealTransport", SealTransport);
	function(lua, "PollTransport", PollTransport);
	function(lua, "StartTransportDecode", StartTransportDecode);
	function(lua, "TakeLegacyTransport", TakeLegacyTransport);
	function(lua, "CancelTransport", CancelTransport);
	function(lua, "GetTransportStats", GetTransportStats);
	function(lua, "PollBinaryDecode", pollDecode);
	function(lua, "CommitBinaryDecode", commitDecode);
	function(lua, "CancelBinaryDecode", cancelDecode);
	function(lua, "CancelAllBinaryDecodes", cancelAllDecodes);
	function(lua, "GetCell", getCell);
	function(lua, "IsKnown", isKnown);
	function(lua, "GetChunkCells", getCells);
	function(lua, "GetSectionCells", getSectionCells);
	function(lua, "GetSectionCellsFiltered", GetSectionCellsFiltered);
	function(lua, "GetSectionInfo", getSectionInfo);
	function(lua, "GetChunkInfo", getChunkInfo);
	function(lua, "GetLight", getLight);
	function(lua, "LightReady", lightReady);
	function(lua, "IsMeshReady", meshReady);
	function(lua, "Pump", pump);
	function(lua, "RequestLighting", requestLight);
	function(lua, "GetStats", stats);
	function(lua, "Reset", reset);
	function(lua, "Close", closeWorld);
	function(lua, "Reconfigure", reconfigure);
	lua->Pop();
}
void shutdown()
{
	while (first)
		close(first);
}
int capabilities(ILuaBase *lua)
{
	lua->CreateTable();
	field(lua, "protocol", 2);
	text(lua, "versionEncoding", "hex64");
	field(lua, "worldSession", 1);
	field(lua, "stateCatalog", 1);
	field(lua, "worldLighting", 1);
	field(lua, "l2Snapshot", 1);
	field(lua, "binarySection", 1);
	field(lua, "nativeTransport", 1);
	field(lua, "terrainWorker", 1);
	field(lua, "fluidWorker", 1);
	field(lua, "shapeWorker", 1);
	field(lua, "sectionCellFilter", 1);
	field(lua, "mixedWorldTopology", 1);
	field(lua, "catalogShapeReferences", 1);
	field(lua, "generalModelWorker", 1);
	field(lua, "sectionLightReadiness", 1);
	field(lua, "worldAdapter", 1);
	return 1;
}
int create(ILuaBase *lua)
{
	return boundary(lua, [&]
					{
        const auto cfg = config(lua, 1);
        auto profiles = catalog(lua, 2);
        // Lua owns a trivial handle before the CPU session acquires resources.
        lua->PushUserType_Value(Handle{}, worldType);
        auto* handle = lua->GetUserType<Handle>(-1, worldType);
        handle->value = new world::Session(cfg, std::move(profiles));
        handle->next = first;
        if (first) first->previous = handle;
        first = handle;
        version(lua, handle->value->store());
        return 2; });
}
} // namespace mcmesh::worldbridge
