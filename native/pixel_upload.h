#pragma once
#include "include/GarrysMod/Lua/LuaBase.h"
#include "l2_pixels.h"
namespace mcmesh::pixelupload {
int Version(GarrysMod::Lua::ILuaBase* lua);
int Draw(GarrysMod::Lua::ILuaBase* lua);
int Create(GarrysMod::Lua::ILuaBase* lua);
int Upload(GarrysMod::Lua::ILuaBase* lua);
int Flush(GarrysMod::Lua::ILuaBase* lua);
int Bind(GarrysMod::Lua::ILuaBase* lua);
int Release(GarrysMod::Lua::ILuaBase* lua);
int Stats(GarrysMod::Lua::ILuaBase* lua);
void Flush();
void Shutdown();
void UploadNative(const l2::LightPixels& pixels, double texture, unsigned first);
void UploadNative(l2::PixelTransaction& transaction, double texture, bool restore);
}
