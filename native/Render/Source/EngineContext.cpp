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

bool AcquireMaterialSystem(const char *inReportedBranch, EEngineBranch &outBranch, const char *&outError)
{
	outError = "mcmesh: materialsystem acquire failed";
	if (sMaterialSystem)
	{
		outBranch = sEngineBranch;
		return true;
	}
	HMODULE library = GetModuleHandleA("materialsystem.dll");
	if (!library)
		return false;
	auto factory = reinterpret_cast<CreateInterfaceFn>(GetProcAddress(library, "CreateInterface"));
	if (!factory)
		return false;
	void *engine_interface = factory(MATERIAL_SYSTEM_INTERFACE_VERSION, nullptr);
	if (!engine_interface)
		return false;
	EEngineBranch engine_branch;
#if defined(_M_X64)
	// Steam's BRANCH can describe another installation of App 4000. In
	// particular, a separately installed public x64 client can report x86-64.
	// Inspect both layouts before making any material-system virtual call.
	const auto *image = reinterpret_cast<const uint8_t *>(library);
	const auto *dos = reinterpret_cast<const IMAGE_DOS_HEADER *>(image);
	const auto *nt = reinterpret_cast<const IMAGE_NT_HEADERS *>(image + dos->e_lfanew);
	const auto *sections = IMAGE_FIRST_SECTION(nt);
	auto read_image = [&](uintptr_t inAddress, void *outBytes, size_t inSize, DWORD inFlags)
	{
		const uintptr_t image_base = reinterpret_cast<uintptr_t>(image);
		if (inAddress < image_base)
			return false;
		const uintptr_t rva = inAddress - image_base;
		for (unsigned i = 0; i < nt->FileHeader.NumberOfSections; ++i)
		{
			const auto &section = sections[i];
			if ((section.Characteristics & inFlags) != inFlags || rva < section.VirtualAddress)
				continue;
			const uintptr_t offset = rva - section.VirtualAddress;
			if (offset > section.Misc.VirtualSize || inSize > section.Misc.VirtualSize - offset)
				continue;
			std::memcpy(outBytes, reinterpret_cast<const void *>(inAddress), inSize);
			return true;
		}
		return false;
	};
	uintptr_t methods[22]{};
	const auto table = *static_cast<const uintptr_t *const *>(engine_interface);
	outError = "mcmesh: unsupported or ambiguous materialsystem ABI; native initialization stopped before engine calls";
	if (!read_image(reinterpret_cast<uintptr_t>(table), methods, sizeof(methods), IMAGE_SCN_MEM_READ)
		|| !DetectMaterialSystemAbi(methods, [&](uintptr_t inAddress, void *outBytes, size_t inSize)
		{
			return read_image(inAddress, outBytes, inSize, IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE);
		}, engine_branch))
		return false;
#else
	// The x86 build has only the public SDK layout.
	outError = "mcmesh: this x86 DLL requires public GMod";
	if (!inReportedBranch || std::strcmp(inReportedBranch, "unknown") != 0)
		return false;
	engine_branch = EEngineBranch::Public;
#endif
	outError = "mcmesh: this DLL does not contain the detected materialsystem ABI; install the auto build";
	switch (engine_branch)
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
	sEngineBranch = engine_branch;
	outBranch = engine_branch;
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
