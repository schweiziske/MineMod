#include "Module/Pch.h"
#include "Render/Source/EngineContext.h"
#include <windows.h>
#include <atomic>

namespace mcmesh::source
{
namespace
{
IMaterialSystem		 *sMaterialSystem = nullptr;
std::atomic<uint32_t> sRenderDeviceRevision{1};

void OnRestoreBuffers(int /*inChangeFlags*/)
{
	// Engine callbacks may run on the render worker. Do not touch Lua, resource
	// registries or render state here; owners repair RT contents before sampling.
	sRenderDeviceRevision.fetch_add(1, std::memory_order_relaxed);
}
} // namespace

bool AcquireMaterialSystem()
{
	if (sMaterialSystem)
		return true;
	HMODULE library = GetModuleHandleA("materialsystem.dll");
	if (!library)
		return false;
	auto factory = reinterpret_cast<CreateInterfaceFn>(GetProcAddress(library, "CreateInterface"));
	if (!factory)
		return false;
	sMaterialSystem = static_cast<IMaterialSystem *>(factory(MATERIAL_SYSTEM_INTERFACE_VERSION, nullptr));
	if (!sMaterialSystem)
		return false;
	sMaterialSystem->AddRestoreFunc(OnRestoreBuffers);
	return true;
}

void ReleaseMaterialSystem()
{
	if (!sMaterialSystem)
		return;
	sMaterialSystem->RemoveRestoreFunc(OnRestoreBuffers);
	sMaterialSystem = nullptr;
}

uint32_t GetRenderDeviceRevision()
{
	return sRenderDeviceRevision.load(std::memory_order_relaxed);
}

IMaterialSystem *GetMaterialSystem()
{
	return sMaterialSystem;
}

bool SupportsNativeMeshVertexFormat(IMaterial *inMaterial)
{
	if (!inMaterial || inMaterial->IsErrorMaterial())
		return false;
	const VertexFormat_t format = inMaterial->GetVertexFormat() & ~VERTEX_FORMAT_COMPRESSED;
	return (VertexFlags(format) & VERTEX_POSITION) != 0 && TexCoordSize(0, format) >= 2;
}
} // namespace mcmesh::source
