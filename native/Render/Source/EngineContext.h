#pragma once
#include <cstdint>

class IMaterial;
class IMaterialSystem;

namespace mcmesh::source
{
/// Borrowed engine interface, acquired at module open. All access is on the
/// Lua/render thread; the engine owns it for the loaded module's lifetime.
bool			 AcquireMaterialSystem();
IMaterialSystem *GetMaterialSystem();
/// Detach module callbacks after retiring engine resources, before DLL unload.
void ReleaseMaterialSystem();
/// Changes after device restoration. Safe from any thread; does not wait.
uint32_t GetRenderDeviceRevision();
/// Legacy material compatibility: position and UV0 are required, other inputs optional.
bool SupportsNativeMeshVertexFormat(IMaterial *inMaterial);
} // namespace mcmesh::source
