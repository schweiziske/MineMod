#include "Module/Pch.h"
#include "Legacy/ChunkMeshBuilder.h"
#include "Legacy/ChunkMeshDraw.h"
#include "Legacy/WorldMirror.h"
#include <cmath>

using namespace GarrysMod::Lua;
using namespace mcmesh;
namespace ws = mcmesh::worldstate;
namespace
{
bool ReadFiniteNumber(ILuaBase *inLua, int inIndex, double &outValue)
{
	if (!inLua->IsType(inIndex, Type::Number))
		return false;
	outValue = inLua->GetNumber(inIndex);
	return std::isfinite(outValue);
}
} // namespace
namespace mcmesh::meshbuild
{
int DrawChunk(ILuaBase *inLua)
{
	int cx, cy, cz;
	if (!ws::ReadChunkCoords(inLua, cx, cy, cz) || g_faulted)
	{
		inLua->PushBool(false);
		return 1;
	}
	if (!inLua->IsType(4, Type::Number))
	{
		inLua->PushBool(false);
		return 1;
	}
	const double pass_d = inLua->GetNumber(4);
	if (!std::isfinite(pass_d) || pass_d != std::floor(pass_d) || (pass_d != 0 && pass_d != 1))
	{
		inLua->PushBool(false);
		return 1;
	}
	const int pass = (int)pass_d;

	inLua->PushBool(GetChunkMeshDraw().DrawChunk(cx, cy, cz, pass));
	return 1;
}

int DrawVisible(ILuaBase *inLua)
{
	double		   pass_value = 0;
	NativeDrawView view;
	double		  *numbers[] = {
		&pass_value,
		&view.mEye[0],
		&view.mEye[1],
		&view.mEye[2],
		&view.mForward[0],
		&view.mForward[1],
		&view.mForward[2],
		&view.mRight[0],
		&view.mRight[1],
		&view.mRight[2],
		&view.mUp[0],
		&view.mUp[1],
		&view.mUp[2],
		&view.mTanX,
		&view.mTanY,
		&view.mOffset[0],
		&view.mOffset[1],
		&view.mOffset[2],
		&view.mDistance,
	};
	for (int i = 0; i < int(sizeof(numbers) / sizeof(numbers[0])); ++i)
		if (!ReadFiniteNumber(inLua, i + 1, *numbers[i]))
		{
			inLua->PushBool(false);
			return 1;
		}
	if ((pass_value != 0 && pass_value != 1) || view.mTanX <= 0 || view.mTanY <= 0 || view.mDistance < 0 || !inLua->IsType(20, Type::Bool) || !inLua->IsType(21, Type::Bool) || !inLua->IsType(22, Type::Bool) || g_faulted || !source::GetMaterialSystem())
	{
		inLua->PushBool(false);
		return 1;
	}
	const int pass = int(pass_value);
	view.mFrustum = inLua->GetBool(20);
	view.mHorizontalDistance = inLua->GetBool(21);
	view.mCollectKeys = inLua->GetBool(22);
	view.mOcclusionCull = g_occlusionCullEnabled.load(std::memory_order_relaxed);
	view.mOcclusionEpoch = GetChunkMeshDraw().GetMetadataEpoch();
	view.mLod = g_lodDrawEnabled.load(std::memory_order_relaxed);
	view.mLodStartChunks = g_lodStartChunks.load(std::memory_order_relaxed);
	view.mLodStartDistance = view.mLodStartChunks * g_promise.CS * g_promise.BS;

	view.mChunkSize = g_promise.CS;
	view.mChunkHeight = g_promise.CH;
	view.mSectionSize = g_promise.SS;
	view.mSectionsX = g_promise.NSX;
	view.mSectionsZ = g_promise.NSZ;
	view.mSectionCount = g_promise.SPC;
	view.mBlockSize = g_promise.BS;
	if (view.mChunkSize <= 0 || view.mChunkHeight <= 0 || view.mSectionSize <= 0 || view.mSectionsX <= 0 || view.mSectionsZ <= 0 || view.mSectionCount <= 0 || view.mSectionCount > 64 || !std::isfinite(view.mBlockSize) || view.mBlockSize <= 0)
	{
		inLua->PushBool(false);
		return 1;
	}
	NativeDrawResult result;
	if (!GetChunkMeshDraw().Draw(view, pass, result))
	{
		inLua->PushBool(false);
		return 1;
	}

	inLua->CreateTable();
#define MC_DRAW_RESULT(name, value)   \
	inLua->PushNumber(double(value)); \
	inLua->SetField(-2, name)
	MC_DRAW_RESULT("tested", result.mTestedChunks);
	MC_DRAW_RESULT("drawn", result.mDrawnChunks);
	MC_DRAW_RESULT("distanceCulled", result.mDistanceCulled);
	MC_DRAW_RESULT("frustumCulled", result.mFrustumCulled);
	MC_DRAW_RESULT("visible", result.mVisibleChunks);
	MC_DRAW_RESULT("sectionsTested", result.mTestedSections);
	MC_DRAW_RESULT("sectionsVisible", result.mVisibleSections);
	MC_DRAW_RESULT("sectionsDrawn", result.mDrawnSections);
	MC_DRAW_RESULT("meshesDrawn", result.mMeshesDrawn);
	MC_DRAW_RESULT("nativeUs", result.mElapsedUs);
	result.mTrianglesDrawn = result.mVerticesDrawn / 3;
	MC_DRAW_RESULT("verticesFullDetail", result.mVerticesFullDetail);
	MC_DRAW_RESULT("verticesCandidate", result.mVerticesCandidate);
	MC_DRAW_RESULT("verticesDrawn", result.mVerticesDrawn);
	MC_DRAW_RESULT("verticesLodCulled", result.mVerticesLodCulled);
	MC_DRAW_RESULT("verticesDirectionCulled", result.mVerticesDirectionCulled);
	MC_DRAW_RESULT("trianglesDrawn", result.mTrianglesDrawn);
	MC_DRAW_RESULT("lodSectionsDrawn", result.mLodSectionsDrawn);
	MC_DRAW_RESULT("lodMeshesDrawn", result.mLodMeshesDrawn);
	MC_DRAW_RESULT("lodStartChunks", result.mLodStartChunks);
	MC_DRAW_RESULT("sectionsOcclusionTested", result.mOcclusionTestedSections);
	MC_DRAW_RESULT("sectionsOcclusionCulled", result.mOcclusionCulledSections);
	MC_DRAW_RESULT("chunksOcclusionCulled", result.mOcclusionCulledChunks);
	MC_DRAW_RESULT("occlusionComponentSections", result.mOcclusionComponentSections);
	MC_DRAW_RESULT("occlusionReachableSections", result.mOcclusionReachableSections);
	MC_DRAW_RESULT("cullUs", result.mCullUs);
#undef MC_DRAW_RESULT
	inLua->PushBool(result.mDirectionalDraw);
	inLua->SetField(-2, "directionalDraw");
	inLua->PushBool(result.mLod);
	inLua->SetField(-2, "lod");
	inLua->PushBool(result.mLodApplied);
	inLua->SetField(-2, "lodApplied");
	inLua->PushBool(result.mOcclusionCull);
	inLua->SetField(-2, "occlusionCull");
	inLua->PushBool(result.mOcclusionApplied);
	inLua->SetField(-2, "occlusionApplied");
	if (!result.mVisibleKeys.empty())
	{
		inLua->PushString(result.mVisibleKeys.data(), (unsigned int)result.mVisibleKeys.size());
		inLua->SetField(-2, "visibleKeys");
	}
	return 1;
}

int SetChunkVisible(ILuaBase *inLua)
{
	int cx, cy, cz;
	if (!ws::ReadChunkCoords(inLua, cx, cy, cz) || !inLua->IsType(4, Type::Bool))
	{
		inLua->PushBool(false);
		return 1;
	}
	const uint64_t key = ws::PackChunkKey(cx, cy, cz);
	GetChunkMeshDraw().SetHidden(key, !inLua->GetBool(4));
	inLua->PushBool(true);
	return 1;
}

} // namespace mcmesh::meshbuild
