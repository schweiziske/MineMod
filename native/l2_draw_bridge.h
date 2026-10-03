#pragma once
#include "include/GarrysMod/Lua/Interface.h"
namespace mcmesh::l2drawbridge {
void initialize(GarrysMod::Lua::ILuaBase* lua);
void shutdown();
int version(GarrysMod::Lua::ILuaBase* lua);
int create(GarrysMod::Lua::ILuaBase* lua);
int patch(GarrysMod::Lua::ILuaBase* lua);
int graph(GarrysMod::Lua::ILuaBase* lua);
int draw(GarrysMod::Lua::ILuaBase* lua);
}
