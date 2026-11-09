#pragma once

#include "include/GarrysMod/Lua/LuaBase.h"

namespace mcmesh::pixelbindings
{
int Version(GarrysMod::Lua::ILuaBase *inLua);
int DeviceRevision(GarrysMod::Lua::ILuaBase *inLua);
int DeviceLimits(GarrysMod::Lua::ILuaBase *inLua);
int Draw(GarrysMod::Lua::ILuaBase *inLua);
int Create(GarrysMod::Lua::ILuaBase *inLua);
int Upload(GarrysMod::Lua::ILuaBase *inLua);
int Flush(GarrysMod::Lua::ILuaBase *inLua);
int Bind(GarrysMod::Lua::ILuaBase *inLua);
int Release(GarrysMod::Lua::ILuaBase *inLua);
int Stats(GarrysMod::Lua::ILuaBase *inLua);
} // namespace mcmesh::pixelbindings
