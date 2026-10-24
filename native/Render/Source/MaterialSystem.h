#pragma once

#include "public/materialsystem/imaterialsystem.h"

namespace mcmesh::source
{
/// Module-owned ABI boundary for borrowed engine interfaces. Calls run on the
/// Lua/render thread; returned resources remain owned by the Source engine.
/// Select the implementation once at module open, before registering callbacks.
class MaterialSystem
{
public:
	virtual ~MaterialSystem() = default;
	virtual IMaterialSystemHardwareConfig *GetHardwareConfig(const char *inVersion, int *outCode) = 0;
	virtual const MaterialSystem_Config_t &GetCurrentConfigForVideoCard() const = 0;
	virtual void AddRestoreFunc(MaterialBufferRestoreFunc_t inCallback) = 0;
	virtual void RemoveRestoreFunc(MaterialBufferRestoreFunc_t inCallback) = 0;
	virtual IMaterial *FindMaterial(const char *inName, const char *inGroup, bool inComplain = true,
		const char *inComplainPrefix = nullptr) = 0;
	virtual ITexture *CreateProceduralTexture(const char *inName, const char *inGroup,
		int inWidth, int inHeight, ImageFormat inFormat, int inFlags) = 0;
	virtual ITexture *CreateNamedRenderTargetTextureEx(const char *inName, int inWidth, int inHeight,
		RenderTargetSizeMode_t inSizeMode, ImageFormat inFormat,
		MaterialRenderTargetDepth_t inDepth = MATERIAL_RT_DEPTH_SHARED,
		unsigned inTextureFlags = TEXTUREFLAGS_CLAMPS | TEXTUREFLAGS_CLAMPT, unsigned inRenderTargetFlags = 0) = 0;
	virtual ITexture *CreateNamedRenderTargetTexture(const char *inName, int inWidth, int inHeight,
		RenderTargetSizeMode_t inSizeMode, ImageFormat inFormat,
		MaterialRenderTargetDepth_t inDepth = MATERIAL_RT_DEPTH_SHARED,
		bool inClampTexCoords = true, bool inAutoMipMap = false) = 0;
	virtual IMatRenderContext *GetRenderContext() = 0;
	virtual MaterialLock_t Lock() = 0;
	virtual void Unlock(MaterialLock_t inLock) = 0;
};
} // namespace mcmesh::source
