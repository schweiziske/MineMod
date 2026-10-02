#pragma once
#include "include/GarrysMod/Lua/Interface.h"

namespace mcmesh::l2bridge {
void initialize(GarrysMod::Lua::ILuaBase* lua);
void shutdown();
int version(GarrysMod::Lua::ILuaBase* lua);
int compileTemplate(GarrysMod::Lua::ILuaBase* lua);
int compileCube(GarrysMod::Lua::ILuaBase* lua);
int compileModel(GarrysMod::Lua::ILuaBase* lua);
int sectionParts(GarrysMod::Lua::ILuaBase* lua);
int buildMesh(GarrysMod::Lua::ILuaBase* lua);
int submitSection(GarrysMod::Lua::ILuaBase* lua);
int submitWorldSection(GarrysMod::Lua::ILuaBase* lua);
int worldSectionCurrent(GarrysMod::Lua::ILuaBase* lua);
int sectionTopology(GarrysMod::Lua::ILuaBase* lua);
int pollSection(GarrysMod::Lua::ILuaBase* lua);
int uploadPart(GarrysMod::Lua::ILuaBase* lua);
int cancelSection(GarrysMod::Lua::ILuaBase* lua);
int canSubmit(GarrysMod::Lua::ILuaBase* lua);
int statistics(GarrysMod::Lua::ILuaBase* lua);
}
