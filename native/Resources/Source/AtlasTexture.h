#pragma once
#include "include/GarrysMod/Lua/LuaBase.h"
#include "Resources/Atlas/AtlasPixels.h"

// Experimental Source backend. Main/render thread only; CPU workers never enter here.
namespace mcmesh::atlastexture
{
int	 Create(GarrysMod::Lua::ILuaBase *lua);
int	 Upload(GarrysMod::Lua::ILuaBase *lua);
int	 Flush(GarrysMod::Lua::ILuaBase *lua);
int	 FlushUpdates(GarrysMod::Lua::ILuaBase *lua);
bool QueueImages(uint64_t id, int x, int y, const std::vector<atlas::Image> &levels, std::string &error);
int	 Bind(GarrysMod::Lua::ILuaBase *lua);
int	 Release(GarrysMod::Lua::ILuaBase *lua);
int	 Stats(GarrysMod::Lua::ILuaBase *lua);
int	 DebugFill(GarrysMod::Lua::ILuaBase *lua);
int	 DebugRenderTarget(GarrysMod::Lua::ILuaBase *lua);
void Shutdown();
} // namespace mcmesh::atlastexture
