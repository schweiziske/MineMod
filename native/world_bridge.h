#pragma once
#include "GarrysMod/Lua/Interface.h"
#include "world_session.h"

namespace mcmesh::worldbridge {
void initialize(GarrysMod::Lua::ILuaBase* lua);
void shutdown();
int capabilities(GarrysMod::Lua::ILuaBase* lua);
int create(GarrysMod::Lua::ILuaBase* lua);
world::Session& session(GarrysMod::Lua::ILuaBase* lua, int at);
}
