#include "Module/Pch.h"
#include "Bindings/MeshBindings.h"
#include "Bindings/MeshBindingContext.h"
#include "Bindings/MeshInputBindings.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace mcmesh::l2bridge
{
using namespace GarrysMod::Lua;
namespace
{
l2::Cell ReadCell(void *inData, int inX, int inY, int inZ)
{
	auto *lua = static_cast<ILuaBase *>(inData);
	lua->Push(2);
	lua->PushNumber(inX);
	lua->PushNumber(inY);
	lua->PushNumber(inZ);
	// A Lua error must not longjmp across C++ snapshot/vector destructors.
	if (lua->PCall(3, 3, 0) != 0)
	{
		const char *message = lua->IsType(-1, Type::String) ? lua->GetString(-1) : "non-string Lua reader error";
		throw std::runtime_error(std::string("L2 snapshot reader: ") + message);
	}
	const auto	 word = l2::integer(ReadNumber(lua, -3), 0, 2097151, "invalid packed L2 cell");
	const double shade = ReadNumber(lua, -2);
	l2::require(shade >= 0 && shade <= 1, "invalid L2 cell shade");
	uint32_t render_class = 0;
	if (!lua->IsType(-1, Type::Nil))
	{
		const double packed = ReadNumber(lua, -1);
		l2::require(packed >= 0 && packed <= UINT32_MAX && packed == std::floor(packed), "invalid L2 render class");
		render_class = static_cast<uint32_t>(packed);
	}
	else
		l2::require(!lua->IsType(4, Type::Table), "voxel input requires neighbour render classes");
	lua->Pop(3);
	return {static_cast<uint32_t>(word), static_cast<float>(shade), render_class};
}

int ReadField(ILuaBase *inLua, const char *inName, int inLow, int inHigh)
{
	inLua->PushString(inName);
	inLua->RawGet(3);
	const int value = l2::integer(ReadNumber(inLua, -1), inLow, inHigh, "invalid L2 snapshot field");
	inLua->Pop();
	return value;
}
} // namespace
std::vector<l2::Work> ReadWork(ILuaBase *inLua, int inTable, l2::Snapshot &ioSnapshot, bool inRecipe)
{
	l2::require(inLua->IsType(inTable, Type::Table), "invalid L2 commands table");
	const int length = inLua->ObjLen(inTable);
	l2::require(length >= 0 && (length > 0 || inRecipe) && length % 11 == 0 && (inRecipe || length / 11 <= l2::MaxQuads), "invalid L2 command count");
	std::vector<l2::Work> work(length / 11);
	for (unsigned i = 0; i < work.size(); ++i)
	{
		const unsigned offset = i * 11;
		inLua->PushNumber(offset + 1);
		inLua->RawGet(inTable);
		const auto *geometry = inLua->GetUserType<l2::Template>(-1, GetBindingState().mTemplateType);
		l2::require(geometry != nullptr, "invalid or destroyed L2 template");
		auto &w = work[i];
		w.geometry = *geometry;
		inLua->Pop();
		auto &c = w.command;
		for (unsigned a = 0; a < 3; ++a)
		{
			c.source[a] = l2::integer(ReadItem(inLua, inTable, offset + 2 + a), INT32_MIN, INT32_MAX, "invalid L2 source coordinate");
			c.translation[a] = ReadItem(inLua, inTable, offset + 5 + a);
		}
		c.size = ReadItem(inLua, inTable, offset + 8);
		c.tint = l2::integer(ReadItem(inLua, inTable, offset + 9), 0, 31, "invalid L2 tint");
		c.opacity = l2::integer(ReadItem(inLua, inTable, offset + 10), 0, 255, "invalid L2 opacity");
		l2::validateCommand(w.geometry, c, ioSnapshot, inRecipe ? 0 : i);
		inLua->PushNumber(offset + 11);
		inLua->RawGet(inTable);
		if (w.geometry.mode == 2)
		{
			l2::require(inLua->IsType(-1, Type::Table) && inLua->ObjLen(-1) == 4, "prepared L2 quad requires four pixels");
			const int prepared = inLua->Top();
			for (unsigned corner = 0; corner < 4; ++corner)
			{
				const double pixel = ReadItem(inLua, prepared, corner + 1);
				l2::require(pixel >= 0 && pixel <= UINT32_MAX && pixel == std::floor(pixel), "invalid prepared pixel");
				c.prepared[corner] = static_cast<uint32_t>(pixel);
			}
		}
		else
		{
			l2::require(inLua->IsType(-1, Type::Bool) && !inLua->GetBool(-1), "unexpected prepared L2 pixels");
		}
		inLua->Pop();
	}
	return work;
}
l2::Snapshot ReadSnapshot(ILuaBase *inLua)
{
	int origin[3] = {ReadField(inLua, "x", INT32_MIN, INT32_MAX), ReadField(inLua, "y", INT32_MIN, INT32_MAX),
					 ReadField(inLua, "z", INT32_MIN, INT32_MAX)};
	int dimensions[3] = {ReadField(inLua, "sx", 5, 4096), ReadField(inLua, "sy", 5, 4096), ReadField(inLua, "sz", 5, 4096)};
	return l2::Snapshot(origin, dimensions, ReadCell, inLua);
}
void ReadVoxels(ILuaBase *inLua, l2::Input &ioInput)
{
	if (!inLua->IsType(4, Type::Table))
		return;
	const int cs = l2::integer(ReadItem(inLua, 4, 2), 1, 64, "invalid voxel chunk width");
	const int ch = l2::integer(ReadItem(inLua, 4, 3), 1, 64, "invalid voxel chunk height");
	ioInput.blockSize = ReadItem(inLua, 4, 1);
	ioInput.maxQuads = l2::integer(ReadItem(inLua, 4, 8), 1, l2::MaxQuads, "invalid voxel part limit");
	l2::require(ioInput.blockSize > 0 && ioInput.blockSize * std::max(cs, ch) <= FLT_MAX,
				"invalid voxel block size");
	int origin[3];
	for (int a = 0; a < 3; ++a)
		origin[a] = l2::integer(ReadItem(inLua, 4, a + 4), INT32_MIN + 64, INT32_MAX - 128, "invalid voxel origin");
	inLua->PushNumber(7);
	inLua->RawGet(4);
	const int sections = inLua->Top();
	const int chunk_cells = cs * cs * ch;
	l2::require(inLua->IsType(sections, Type::Table) && inLua->ObjLen(sections) <= chunk_cells, "invalid voxel sections");
	std::vector<uint8_t> seen(chunk_cells);
	for (int s = 1; s <= inLua->ObjLen(sections); ++s)
	{
		inLua->PushNumber(s);
		inLua->RawGet(sections);
		const int section = inLua->Top();
		l2::require(inLua->IsType(section, Type::Table), "invalid voxel section");
		inLua->PushNumber(1);
		inLua->RawGet(section);
		const int indices_table = inLua->Top();
		inLua->PushNumber(2);
		inLua->RawGet(section);
		const int states_table = inLua->Top();
		inLua->PushNumber(3);
		inLua->RawGet(section);
		const int recipes = inLua->Top();
		l2::require(inLua->IsType(indices_table, Type::Table) && inLua->IsType(states_table, Type::Table) && inLua->IsType(recipes, Type::Table), "invalid voxel index/recipe arrays");
		const int count = inLua->ObjLen(indices_table);
		int		  low[3], high[3];
		int		  volume = 1;
		for (int a = 0; a < 3; ++a)
		{
			low[a] = l2::integer(ReadItem(inLua, section, a + 4), 0, (a == 2 ? ch : cs) - 1, "invalid voxel minimum");
			high[a] = l2::integer(ReadItem(inLua, section, a + 7), low[a], (a == 2 ? ch : cs) - 1,
								  "invalid voxel maximum");
			volume *= high[a] - low[a] + 1;
		}
		l2::require(count >= 0 && count <= volume && inLua->ObjLen(states_table) == count, "invalid voxel section length");
		std::unordered_map<uint32_t, std::pair<unsigned, bool>> mapped;
		inLua->PushNil();
		while (inLua->Next(recipes))
		{
			const double state = ReadNumber(inLua, -2);
			l2::require(state > 0 && state <= UINT32_MAX && state == std::floor(state), "invalid voxel recipe state");
			const int recipe = inLua->Top();
			l2::require(inLua->IsType(recipe, Type::Table), "invalid voxel recipe");
			inLua->PushNumber(1);
			inLua->RawGet(recipe);
			const auto *cube = inLua->GetUserType<l2::Cube>(-1, GetBindingState().mCubeType);
			const auto *model = inLua->GetUserType<ModelHandle>(-1, GetBindingState().mModelType);
			l2::require(cube != nullptr || (model && *model), "invalid compiled voxel recipe");
			l2::require(mapped.size() < size_t(volume), "more voxel recipes than section cells");
			if (cube)
			{
				auto value = *cube;
				inLua->Pop();
				for (unsigned f = 0; f < 6; ++f)
					value.groups[f] = l2::integer(ReadItem(inLua, recipe, f + 2), 1, INT32_MAX, "invalid voxel group");
				mapped.emplace(static_cast<uint32_t>(state), std::make_pair(static_cast<unsigned>(ioInput.cubes.size()), false));
				ioInput.cubes.push_back(value);
			}
			else
			{
				l2::ModelBinding value{*model, 0};
				inLua->Pop();
				value.group = l2::integer(ReadItem(inLua, recipe, 2), 1, INT32_MAX, "invalid model group");
				mapped.emplace(static_cast<uint32_t>(state), std::make_pair(static_cast<unsigned>(ioInput.models.size()), true));
				ioInput.models.push_back(std::move(value));
			}
			inLua->Pop();
		}
		for (int i = 1; i <= count; ++i)
		{
			const double state = ReadItem(inLua, states_table, i);
			l2::require(state > 0 && state <= UINT32_MAX && state == std::floor(state), "invalid voxel state");
			const auto found = mapped.find(static_cast<uint32_t>(state));
			const int  li = l2::integer(ReadItem(inLua, indices_table, i), 0, cs * cs * ch - 1, "invalid voxel local index");
			const int  local[3] = {li % cs, li / cs % cs, li / (cs * cs)};
			for (int a = 0; a < 3; ++a)
				l2::require(local[a] >= low[a] && local[a] <= high[a], "voxel index outside its section");
			l2::require(!seen[li], "duplicate voxel index");
			seen[li] = 1;
			if (found == mapped.end())
				continue;
			l2::Voxel voxel;
			voxel.cube = found->second.first;
			voxel.model = found->second.second;
			for (int a = 0; a < 3; ++a)
			{
				voxel.source[a] = origin[a] + local[a];
				voxel.translation[a] = local[a] * ioInput.blockSize;
			}
			ioInput.snapshot.validateSource(voxel.source);
			ioInput.voxels.push_back(voxel);
		}
		inLua->Pop(4);
	}
	inLua->Pop();
}
int CompileCube(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		const int	 origin[3] = {-2, -2, -2}, dims[3] = {5, 5, 5};
		l2::Snapshot snapshot(origin, dims, ReadCell, inLua);
		const auto	 work = ReadWork(inLua, 1, snapshot);
		l2::require(work.size() == 6, "cube recipe requires six ordered faces");
		l2::Cube cube;
		cube.block = l2::integer(ReadNumber(inLua, 2), 1, 536870911, "invalid cube block ID");
		std::copy(work.begin(), work.end(), cube.faces.begin());
		l2::validateCube(cube);
		inLua->PushUserType_Value(cube, GetBindingState().mCubeType);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int CompileFluid(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		l2::require(inLua->IsType(1, Type::Table), "fluid recipe must be a table");
		const auto read_field = [&](const char *name)
		{
			inLua->GetField(1, name);
			const double v = ReadNumber(inLua, -1);
			inLua->Pop();
			return v;
		};
		l2::FluidRecipe recipe;
		recipe.kind = uint8_t(l2::integer(read_field("kind"), 1, 2, "invalid fluid kind"));
		recipe.emission = l2::integer(read_field("emission"), 0, 15, "invalid fluid emission");
		recipe.opacity = l2::integer(read_field("opacity"), 0, 255, "invalid fluid opacity");
		recipe.full = l2::integer(read_field("full"), 0, 1, "invalid fluid full flag") != 0;
		recipe.flow = l2::integer(read_field("flow"), 0, 1, "invalid fluid flow flag") != 0;
		recipe.offset = read_field("offset");
		l2::require(std::isfinite(recipe.offset) && recipe.offset >= 0 && recipe.offset < .5, "invalid fluid offset");
		inLua->GetField(1, "shade");
		const int shades = inLua->Top();
		l2::require(inLua->IsType(shades, Type::Table) && inLua->ObjLen(shades) == 6, "invalid fluid shades");
		for (unsigned f = 0; f < 6; ++f)
			recipe.shade[f] = l2::integer(ReadItem(inLua, shades, f + 1), 0, 255, "invalid fluid shade");
		inLua->Pop();
		inLua->GetField(1, "tiles");
		const int tiles = inLua->Top();
		l2::require(inLua->IsType(tiles, Type::Table) && inLua->ObjLen(tiles) == 7, "invalid fluid tiles");
		for (unsigned f = 0; f < 7; ++f)
		{
			inLua->PushNumber(f + 1);
			inLua->RawGet(tiles);
			const int tile = inLua->Top();
			l2::require(inLua->IsType(tile, Type::Table) && inLua->ObjLen(tile) == 6, "invalid fluid UV transform");
			auto &out = recipe.tiles[f];
			for (unsigned a = 0; a < 2; ++a)
			{
				out.origin[a] = ReadItem(inLua, tile, a + 1);
				out.scale[a] = ReadItem(inLua, tile, a + 3);
				out.inset[a] = ReadItem(inLua, tile, a + 5);
				l2::require(std::isfinite(out.origin[a]) && std::abs(out.origin[a]) <= 32768 && std::isfinite(out.scale[a]) && out.scale[a] > 0 && out.scale[a] <= 1 && std::isfinite(out.inset[a]) && out.inset[a] >= 0 && out.inset[a] <= out.scale[a],
							"invalid fluid atlas transform");
			}
			inLua->Pop();
		}
		inLua->Pop();
		inLua->PushUserType_Value(recipe, GetBindingState().mFluidType);
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int CompileModel(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		l2::require(inLua->IsType(1, Type::Table), "invalid model plan");
		const int count = inLua->ObjLen(1);
		l2::require(count > 0 && count <= 255, "invalid model plan group count");
		auto model = std::make_shared<l2::Model>();
		model->block = l2::integer(ReadNumber(inLua, 2), 1, 536870911, "invalid model block ID");
		l2::require(inLua->IsType(3, Type::Bool), "model requires internal-face policy");
		model->keepInternalFaces = inLua->GetBool(3);
		// An omitted argument is outside the Lua stack, not a nil stack value.
		if (top >= 4 && !inLua->IsType(4, Type::Nil))
			model->shapeSelector = l2::integer(ReadNumber(inLua, 4), 0, 3, "invalid shape selector");
		const int	 origin[3] = {-2, -2, -2}, dims[3] = {5, 5, 5};
		l2::Snapshot snapshot(origin, dims, ReadCell, inLua);
		for (int i = 1; i <= count; ++i)
		{
			inLua->PushNumber(i);
			inLua->RawGet(1);
			const int group_table = inLua->Top();
			l2::require(inLua->IsType(group_table, Type::Table), "invalid model group");
			l2::ModelGroup group;
			group.salt = l2::integer(ReadItem(inLua, group_table, 1), 0, 65535 * 132, "invalid model salt");
			inLua->PushNumber(2);
			inLua->RawGet(group_table);
			const int alternatives = inLua->Top();
			l2::require(inLua->IsType(alternatives, Type::Table) && inLua->ObjLen(alternatives) > 0 && inLua->ObjLen(alternatives) <= 255, "invalid model alternatives");
			for (int a = 1; a <= inLua->ObjLen(alternatives); ++a)
			{
				inLua->PushNumber(a);
				inLua->RawGet(alternatives);
				const int alternative = inLua->Top();
				l2::require(inLua->IsType(alternative, Type::Table), "invalid model alternative");
				l2::ModelAlternative value;
				value.weight = l2::integer(ReadItem(inLua, alternative, 1), 1, 255, "invalid model weight");
				inLua->PushNumber(2);
				inLua->RawGet(alternative);
				l2::require(inLua->IsType(-1, Type::Bool), "invalid model AO");
				value.modelAO = inLua->GetBool(-1);
				inLua->Pop();
				inLua->PushNumber(3);
				inLua->RawGet(alternative);
				auto shaded = ReadWork(inLua, inLua->Top(), snapshot, true);
				inLua->Pop();
				inLua->PushNumber(4);
				inLua->RawGet(alternative);
				auto flat = ReadWork(inLua, inLua->Top(), snapshot, true);
				inLua->Pop();
				inLua->PushNumber(5);
				inLua->RawGet(alternative);
				const int culls = inLua->Top();
				l2::require(shaded.size() == flat.size() && inLua->IsType(culls, Type::Table) && inLua->ObjLen(culls) == shaded.size(), "model AO/cull array count mismatch");
				for (size_t q = 0; q < shaded.size(); ++q)
				{
					const auto &first = shaded[q];
					const auto &second = flat[q];
					l2::require(first.command.tint == second.command.tint && first.command.opacity == second.command.opacity && second.command.size == 1, "model AO variants changed command");
					for (unsigned axis = 0; axis < 3; ++axis)
						l2::require(second.command.source[axis] == 0 && second.command.translation[axis] == 0,
									"model AO variant changed origin");
					l2::ModelQuad quad;
					quad.work = first;
					quad.withoutAO = second.geometry;
					inLua->PushNumber(static_cast<double>(q + 1));
					inLua->RawGet(culls);
					if (inLua->IsType(-1, Type::Table))
					{
						const int cull = inLua->Top();
						l2::require(inLua->ObjLen(cull) == 7, "invalid shape cull record");
						quad.shapeCull = true;
						quad.cullFace = l2::integer(ReadItem(inLua, cull, 1), 1, 6, "invalid shape cull face");
						for (unsigned a = 0; a < 6; ++a)
							quad.box[a] = ReadItem(inLua, cull, a + 2);
					}
					else
						quad.cullFace = l2::integer(ReadNumber(inLua, -1), 0, 6, "invalid model cull");
					inLua->Pop();
					value.quads.push_back(std::move(quad));
				}
				inLua->Pop();
				group.alternatives.push_back(std::move(value));
				inLua->Pop();
			}
			model->groups.push_back(std::move(group));
			inLua->Pop(2);
		}
		l2::validateModel(*model);
		auto handle = std::make_unique<ModelHandle>(std::move(model));
		inLua->PushUserType(handle.get(), GetBindingState().mModelType);
		handle.release();
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}
int CompileTemplate(ILuaBase *inLua)
{
	const int top = inLua->Top();
	try
	{
		l2::require(inLua->IsType(1, Type::Table) && inLua->ObjLen(1) == l2::TemplateSize,
					"L2 template must contain exactly 46 numbers");
		double packet[l2::TemplateSize];
		for (unsigned i = 0; i < l2::TemplateSize; ++i)
			packet[i] = ReadItem(inLua, 1, i + 1);
		const auto value = l2::compile(packet);
		inLua->PushUserType_Value(value, GetBindingState().mTemplateType);
		++GetBindingState().mTemplates;
		++GetBindingState().mLiveTemplates;
		return 1;
	}
	catch (const std::exception &e)
	{
		return Fail(inLua, top, e.what());
	}
}

} // namespace mcmesh::l2bridge
