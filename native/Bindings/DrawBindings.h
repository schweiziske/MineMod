#pragma once
#include "include/GarrysMod/Lua/Interface.h"
namespace mcmesh::l2drawbridge
{
void initialize(GarrysMod::Lua::ILuaBase *lua);
void shutdown();
int	 version(GarrysMod::Lua::ILuaBase *lua);
int	 create(GarrysMod::Lua::ILuaBase *lua);
int	 patch(GarrysMod::Lua::ILuaBase *lua);
int	 graph(GarrysMod::Lua::ILuaBase *lua);
int	 spatialGraph(GarrysMod::Lua::ILuaBase *lua);
int	 draw(GarrysMod::Lua::ILuaBase *lua);
/// Main-thread draw with one status byte per scene chunk and a source-to-selected material table.
/// Lua retains all materials for the call; no worker accesses these arguments or Source resources.
int DrawBatched(GarrysMod::Lua::ILuaBase *inLua);
int	 stats(GarrysMod::Lua::ILuaBase *lua);
} // namespace mcmesh::l2drawbridge
