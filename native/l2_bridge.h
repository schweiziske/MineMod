#pragma once
#include "include/GarrysMod/Lua/Interface.h"
#include "l2_core.h"
class IMesh;

namespace mcmesh::l2bridge {
struct DrawResource {
    IMesh* mesh = nullptr;
    unsigned indices = 0;
    float bounds[6]{};
    std::array<l2::DirectionRange, 7> directions{};
};
DrawResource* drawResource(GarrysMod::Lua::ILuaBase* lua, int index);
void initialize(GarrysMod::Lua::ILuaBase* lua);
void shutdown();
int version(GarrysMod::Lua::ILuaBase* lua);
int compileTemplate(GarrysMod::Lua::ILuaBase* lua);
int compileCube(GarrysMod::Lua::ILuaBase* lua);
int compileModel(GarrysMod::Lua::ILuaBase* lua);
int compileFluid(GarrysMod::Lua::ILuaBase* lua);
int sectionParts(GarrysMod::Lua::ILuaBase* lua);
int buildMesh(GarrysMod::Lua::ILuaBase* lua);
int submitSection(GarrysMod::Lua::ILuaBase* lua);
int submitWorldSection(GarrysMod::Lua::ILuaBase* lua);
int submitWorldRelight(GarrysMod::Lua::ILuaBase* lua);
int lightPart(GarrysMod::Lua::ILuaBase* lua);
int worldSectionCurrent(GarrysMod::Lua::ILuaBase* lua);
int worldSectionGeometryCurrent(GarrysMod::Lua::ILuaBase* lua);
int sectionTopology(GarrysMod::Lua::ILuaBase* lua);
int pollSection(GarrysMod::Lua::ILuaBase* lua);
int uploadPart(GarrysMod::Lua::ILuaBase* lua);
int uploadNativePart(GarrysMod::Lua::ILuaBase* lua);
int lightingVersion(GarrysMod::Lua::ILuaBase* lua);
int uploadMeshPixels(GarrysMod::Lua::ILuaBase* lua);
int readMeshPixels(GarrysMod::Lua::ILuaBase* lua);
int stageRelight(GarrysMod::Lua::ILuaBase* lua);
int uploadRelight(GarrysMod::Lua::ILuaBase* lua);
int finishRelight(GarrysMod::Lua::ILuaBase* lua);
int cancelSection(GarrysMod::Lua::ILuaBase* lua);
int canSubmit(GarrysMod::Lua::ILuaBase* lua);
int statistics(GarrysMod::Lua::ILuaBase* lua);
}
