#pragma once
#include "include/GarrysMod/Lua/Interface.h"
namespace mcmesh::source
{
struct DrawResource;
}

namespace mcmesh::l2bridge
{
source::DrawResource *GetDrawResource(GarrysMod::Lua::ILuaBase *inLua, int inIndex);
void				  Initialize(GarrysMod::Lua::ILuaBase *inLua);
void				  Shutdown();
int					  Version(GarrysMod::Lua::ILuaBase *inLua);
int					  CompileTemplate(GarrysMod::Lua::ILuaBase *inLua);
int					  CompileCube(GarrysMod::Lua::ILuaBase *inLua);
int					  CompileModel(GarrysMod::Lua::ILuaBase *inLua);
int					  CompileFluid(GarrysMod::Lua::ILuaBase *inLua);
int					  SectionParts(GarrysMod::Lua::ILuaBase *inLua);
int					  BuildMesh(GarrysMod::Lua::ILuaBase *inLua);
int					  SubmitSection(GarrysMod::Lua::ILuaBase *inLua);
int					  SubmitWorldSection(GarrysMod::Lua::ILuaBase *inLua);
int					  SubmitWorldRelight(GarrysMod::Lua::ILuaBase *inLua);
int					  LightPart(GarrysMod::Lua::ILuaBase *inLua);
int					  WorldSectionCurrent(GarrysMod::Lua::ILuaBase *inLua);
int					  WorldSectionGeometryCurrent(GarrysMod::Lua::ILuaBase *inLua);
int					  SectionTopology(GarrysMod::Lua::ILuaBase *inLua);
int					  PollSection(GarrysMod::Lua::ILuaBase *inLua);
int					  UploadPart(GarrysMod::Lua::ILuaBase *inLua);
int					  UploadNativePart(GarrysMod::Lua::ILuaBase *inLua);
int					  LightingVersion(GarrysMod::Lua::ILuaBase *inLua);
int					  UploadMeshPixels(GarrysMod::Lua::ILuaBase *inLua);
int					  ReadMeshPixels(GarrysMod::Lua::ILuaBase *inLua);
int					  StageRelight(GarrysMod::Lua::ILuaBase *inLua);
int					  UploadRelight(GarrysMod::Lua::ILuaBase *inLua);
int					  FinishRelight(GarrysMod::Lua::ILuaBase *inLua);
int					  CancelSection(GarrysMod::Lua::ILuaBase *inLua);
int					  CanSubmit(GarrysMod::Lua::ILuaBase *inLua);
int					  Statistics(GarrysMod::Lua::ILuaBase *inLua);
} // namespace mcmesh::l2bridge
