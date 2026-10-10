#pragma once
#include "include/GarrysMod/Lua/LuaBase.h"
namespace mcmesh::resourceio
{
int	 List(GarrysMod::Lua::ILuaBase *lua);
int	 Open(GarrysMod::Lua::ILuaBase *lua);
int	 Read(GarrysMod::Lua::ILuaBase *lua);
int	 Unchanged(GarrysMod::Lua::ILuaBase *lua);
int	 Close(GarrysMod::Lua::ILuaBase *lua);
int	 HashBytes(GarrysMod::Lua::ILuaBase *lua);
void Shutdown();
} // namespace mcmesh::resourceio
