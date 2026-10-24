#include "Module/Pch.h"
#include "Render/Source/EngineContext.h"
#include <windows.h>
#include <atomic>
#include <cstring>

namespace mcmesh::source
{
namespace
{
template<class TInterface>
class MaterialSystemAdapter final : public MaterialSystem
{
public:
	void Bind(void *inInterface)
	{
		mInterface = static_cast<TInterface *>(inInterface);
	}

	IMaterialSystemHardwareConfig *GetHardwareConfig(const char *inVersion, int *outCode) override
	{
		return mInterface->GetHardwareConfig(inVersion, outCode);
	}

	const MaterialSystem_Config_t &GetCurrentConfigForVideoCard() const override
	{
		return mInterface->GetCurrentConfigForVideoCard();
	}

	void AddRestoreFunc(MaterialBufferRestoreFunc_t inCallback) override
	{
		mInterface->AddRestoreFunc(inCallback);
	}

	void RemoveRestoreFunc(MaterialBufferRestoreFunc_t inCallback) override
	{
		mInterface->RemoveRestoreFunc(inCallback);
	}

	IMaterial *FindMaterial(const char *inName, const char *inGroup, bool inComplain,
		const char *inComplainPrefix) override
	{
		return mInterface->FindMaterial(inName, inGroup, inComplain, inComplainPrefix);
	}

	ITexture *CreateProceduralTexture(const char *inName, const char *inGroup,
		int inWidth, int inHeight, ImageFormat inFormat, int inFlags) override
	{
		return mInterface->CreateProceduralTexture(inName, inGroup, inWidth, inHeight, inFormat, inFlags);
	}

	ITexture *CreateNamedRenderTargetTextureEx(const char *inName, int inWidth, int inHeight,
		RenderTargetSizeMode_t inSizeMode, ImageFormat inFormat, MaterialRenderTargetDepth_t inDepth,
		unsigned inTextureFlags, unsigned inRenderTargetFlags) override
	{
		return mInterface->CreateNamedRenderTargetTextureEx(inName, inWidth, inHeight,
			inSizeMode, inFormat, inDepth, inTextureFlags, inRenderTargetFlags);
	}

	ITexture *CreateNamedRenderTargetTexture(const char *inName, int inWidth, int inHeight,
		RenderTargetSizeMode_t inSizeMode, ImageFormat inFormat, MaterialRenderTargetDepth_t inDepth,
		bool inClampTexCoords, bool inAutoMipMap) override
	{
		return mInterface->CreateNamedRenderTargetTexture(inName, inWidth, inHeight,
			inSizeMode, inFormat, inDepth, inClampTexCoords, inAutoMipMap);
	}

	IMatRenderContext *GetRenderContext() override
	{
		return mInterface->GetRenderContext();
	}

	MaterialLock_t Lock() override
	{
		return mInterface->Lock();
	}

	void Unlock(MaterialLock_t inLock) override
	{
		mInterface->Unlock(inLock);
	}

private:
	TInterface *mInterface = nullptr;
};

#if defined(MCSWEP_AUTO_BRANCH) || defined(GMOD_SDK_PUBLIC)
MaterialSystemAdapter<IMaterialSystemPublic> sPublicMaterialSystem;
#endif
#if defined(_M_X64) && (defined(MCSWEP_AUTO_BRANCH) || defined(GMOD_SDK_X86_64))
MaterialSystemAdapter<IMaterialSystemX86_64> sBetaMaterialSystem;
#endif
MaterialSystem *sMaterialSystem = nullptr;
EEngineBranch sEngineBranch = EEngineBranch::Public;
std::atomic<uint32_t> sRenderDeviceRevision{1};

void OnRestoreBuffers(int /*inChangeFlags*/)
{
	// Engine callbacks may run on the render worker. Do not touch Lua, resource
	// registries or render state here; owners repair RT contents before sampling.
	sRenderDeviceRevision.fetch_add(1, std::memory_order_relaxed);
}
} // namespace

bool SelectEngineBranch(const char *inName, EEngineBranch &outBranch)
{
	if (!inName)
		return false;
#if defined(MCSWEP_AUTO_BRANCH) || defined(GMOD_SDK_PUBLIC)
	if (std::strcmp(inName, "unknown") == 0)
	{
		outBranch = EEngineBranch::Public;
		return true;
	}
#endif
#if defined(_M_X64) && (defined(MCSWEP_AUTO_BRANCH) || defined(GMOD_SDK_X86_64))
	if (std::strcmp(inName, "x86-64") == 0)
	{
		outBranch = EEngineBranch::X86_64;
		return true;
	}
#endif
	return false;
}

bool AcquireMaterialSystem(EEngineBranch inBranch)
{
	if (sMaterialSystem)
		return inBranch == sEngineBranch;
	HMODULE library = GetModuleHandleA("materialsystem.dll");
	if (!library)
		return false;
	auto factory = reinterpret_cast<CreateInterfaceFn>(GetProcAddress(library, "CreateInterface"));
	if (!factory)
		return false;
	void *engine_interface = factory(MATERIAL_SYSTEM_INTERFACE_VERSION, nullptr);
	if (!engine_interface)
		return false;
	switch (inBranch)
	{
#if defined(MCSWEP_AUTO_BRANCH) || defined(GMOD_SDK_PUBLIC)
	case EEngineBranch::Public:
		sPublicMaterialSystem.Bind(engine_interface);
		sMaterialSystem = &sPublicMaterialSystem;
		break;
#endif
#if defined(_M_X64) && (defined(MCSWEP_AUTO_BRANCH) || defined(GMOD_SDK_X86_64))
	case EEngineBranch::X86_64:
		sBetaMaterialSystem.Bind(engine_interface);
		sMaterialSystem = &sBetaMaterialSystem;
		break;
#endif
	default:
		return false;
	}
	sEngineBranch = inBranch;
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

MaterialSystem *GetMaterialSystem()
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
