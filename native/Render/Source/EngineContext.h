#pragma once
#include "Render/Source/MaterialSystem.h"
#include "Render/Source/MaterialSystemAbi.h"
#include <cstdint>

class IMaterial;

namespace mcmesh::source
{
/// Inspect the loaded engine ABI before calling it, then register its restore
/// callback on the Lua/render thread. A failed detection returns a Lua-safe error.
bool AcquireMaterialSystem(const char *inReportedBranch, EEngineBranch &outBranch, const char *&outError);
/// Borrowed module-owned adapter, usable until ReleaseMaterialSystem. The Source
/// engine owns the underlying interface; all calls run on the Lua/render thread.
MaterialSystem *GetMaterialSystem();
/// Detach module callbacks after retiring engine resources, before DLL unload.
void ReleaseMaterialSystem();
/// Changes after device restoration. Safe from any thread; does not wait.
uint32_t GetRenderDeviceRevision();
/// Legacy material compatibility: position and UV0 are required, other inputs optional.
bool SupportsNativeMeshVertexFormat(IMaterial *inMaterial);
} // namespace mcmesh::source
