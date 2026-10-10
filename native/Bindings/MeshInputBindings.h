#pragma once
#include "include/GarrysMod/Lua/Interface.h"
#include "Mesh/SectionWorker.h"

namespace mcmesh::l2bridge
{
/// Reads and validates Lua recipes/input on the main thread. The returned input
/// must be prefetched and detached from Lua before submitting it to workers.
std::vector<l2::Work> ReadWork(GarrysMod::Lua::ILuaBase *inLua, int inTable, l2::Snapshot &ioSnapshot, bool inRecipe = false);
l2::Snapshot		  ReadSnapshot(GarrysMod::Lua::ILuaBase *inLua);
void				  ReadVoxels(GarrysMod::Lua::ILuaBase *inLua, l2::Input &ioInput);
} // namespace mcmesh::l2bridge
