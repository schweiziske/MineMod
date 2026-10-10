#pragma once
#include "include/GarrysMod/Lua/LuaBase.h"
namespace mcmesh::atlassprite
{
int	 Create(GarrysMod::Lua::ILuaBase *lua);
int	 Sample(GarrysMod::Lua::ILuaBase *lua);
int	 UpdateTexture(GarrysMod::Lua::ILuaBase *lua);
int	 Release(GarrysMod::Lua::ILuaBase *lua);
int	 Stats(GarrysMod::Lua::ILuaBase *lua);
void Shutdown();
} // namespace mcmesh::atlassprite
