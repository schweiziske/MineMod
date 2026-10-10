#pragma once

#include "include/GarrysMod/Lua/Interface.h"

namespace mcmesh::handshake
{
inline constexpr int ABI_VERSION = 8;

// 返回版本信息
inline int AbiVersion(GarrysMod::Lua::ILuaBase *LUA)
{
	LUA->PushNumber(ABI_VERSION);
	return 1;
}

int Handshake(GarrysMod::Lua::ILuaBase *LUA);
int SetAtlasPageMaterial(GarrysMod::Lua::ILuaBase *LUA);

int SetBlockDefs(GarrysMod::Lua::ILuaBase *LUA);
int Think(GarrysMod::Lua::ILuaBase *LUA);
int DrawChunk(GarrysMod::Lua::ILuaBase *LUA);
int UnloadChunk(GarrysMod::Lua::ILuaBase *LUA);
int ClearWorld(GarrysMod::Lua::ILuaBase *LUA);
int Shutdown(GarrysMod::Lua::ILuaBase *LUA);
} // namespace mcmesh::handshake
