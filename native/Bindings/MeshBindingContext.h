#pragma once
#include "include/GarrysMod/Lua/Interface.h"
#include "Mesh/SectionWorker.h"

namespace mcmesh::l2bridge
{
using ModelHandle = std::shared_ptr<const l2::Model>;

/// Lua-only metatable IDs and boundary diagnostics. Main thread only; no
/// engine resources, tickets, worker state or publication ownership live here.
struct MeshBindingState
{
	int		 mTemplateType = -1, mMeshType = -1, mCubeType = -1, mModelType = -1, mFluidType = -1, mPixelTransactionType = -1;
	uint64_t mTemplates = 0, mLiveTemplates = 0, mBatches = 0;
	uint64_t mVertices = 0, mIndices = 0, mReads = 0, mHits = 0, mFailures = 0;
	double	 mSnapshotMS = 0, mCommandMS = 0, mUploadMS = 0;
	uint64_t mNativePixelTexels = 0, mLuaPixelValues = 0, mRelightBatches = 0;
	bool	 mBuilding = false;
};
MeshBindingState &GetBindingState();
double			  ClockMS();
void			  SetFunction(GarrysMod::Lua::ILuaBase *inLua, const char *inName, GarrysMod::Lua::CFunc inFunction);
void			  SetNumber(GarrysMod::Lua::ILuaBase *inLua, const char *inName, double inValue);
double			  ReadNumber(GarrysMod::Lua::ILuaBase *inLua, int inIndex);
double			  ReadItem(GarrysMod::Lua::ILuaBase *inLua, int inTable, int inIndex);
void			  ResetStack(GarrysMod::Lua::ILuaBase *inLua, int inTop);
int				  Fail(GarrysMod::Lua::ILuaBase *inLua, int inTop, const char *inReason);
void			  PushPixels(GarrysMod::Lua::ILuaBase *inLua, const uint32_t *inValues, size_t inCount);

class BuildScope
{
public:
	BuildScope();
	~BuildScope();
	BuildScope(const BuildScope &) = delete;
	BuildScope &operator=(const BuildScope &) = delete;
};
} // namespace mcmesh::l2bridge
