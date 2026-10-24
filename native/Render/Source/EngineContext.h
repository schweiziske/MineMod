#pragma once
#include "Render/Source/MaterialSystem.h"
#include <cstdint>

class IMaterial;

namespace mcmesh::source
{
enum class EEngineBranch
{
	Public,
	X86_64,
};

/// Resolve a supported game BRANCH before making any engine-interface calls.
bool SelectEngineBranch(const char *inName, EEngineBranch &outBranch);
/// Acquire the selected ABI and register its restore callback on the Lua/render thread.
bool AcquireMaterialSystem(EEngineBranch inBranch);
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
