#include "pch.h"
#include "test.h"
#include "handshake.h"
#include "worldstate.h"
#include "blockdefs.h"
#include "meshbuild.h"
#include "patchdecode.h"
#include "lightatlas.h"
#include "atlas_texture.h"
#include "pixel_upload.h"
#include "atlas_sprite_bridge.h"
#include "resource_io.h"
#include "l2_bridge.h"
#include "l2_draw_bridge.h"
#include "world_bridge.h"

using namespace GarrysMod::Lua;
using namespace std;

// 简化匿名函数
#define GTLUAF(func) \
    [](lua_State* L) -> int { \
        ILuaBase* LUA = L->luabase; \
        return func(LUA); \
    }

// 用于辅助添加函数。只能在初始化时使用。
// 注：该类必须先手动push全局表，最后手动弹出全局表。
class FunctionAdder {
	ILuaBase* L;
	const char* name;
public:
	FunctionAdder(ILuaBase* LUA) {
		L = LUA;
	}

	// 从某个表开始
	void Start(const char* table) {
		name = table;
		L->CreateTable();
		// 此时栈顶为特定名称的表
	}

	// 添加函数
	void AddFunction(const char* name, CFunc f) {
		L->PushString(name);
		L->PushCFunction(f);
		L->SetTable(-3);
		// 这里会弹出键和值
	}

	// 添加常量（或枚举）
	void AddConstant(const char* name, double number) {
		L->PushNumber(number);
		L->SetField(-2, name);
	}

	void End() {
		// 弹出这个表
		L->SetField(-2, name);
	}
};

GMOD_MODULE_OPEN()
{
	if (!mcmesh::handshake::AcquireMaterialSystem()) {
		LUA->ThrowError("mcmesh: materialsystem acquire failed");
		return 0;
	}
	
	mcmesh::l2bridge::initialize(LUA);
	mcmesh::worldbridge::initialize(LUA);
	LUA->PushSpecial(GarrysMod::Lua::SPECIAL_GLOB);

	FunctionAdder fa(LUA);
	fa.Start("mcmesh");

	// ---- 握手 / 生命周期 ----
	fa.AddFunction("AbiVersion", GTLUAF(mcmesh::handshake::AbiVersion));
	fa.AddConstant("AtlasRegionVersion", 1);
	fa.AddFunction("Handshake", GTLUAF(mcmesh::handshake::Handshake));
	fa.AddFunction("SetAtlasPageMaterial", GTLUAF(mcmesh::handshake::SetAtlasPageMaterial));
	fa.AddFunction("L2Version", GTLUAF(mcmesh::l2bridge::version));
		fa.AddFunction("L2DrawVersion", GTLUAF(mcmesh::l2drawbridge::version));
		fa.AddFunction("L2DrawStats", GTLUAF(mcmesh::l2drawbridge::stats));
		fa.AddFunction("CreateL2DrawScene", GTLUAF(mcmesh::l2drawbridge::create));
		fa.AddFunction("PatchL2DrawScene", GTLUAF(mcmesh::l2drawbridge::patch));
		fa.AddFunction("SetL2DrawGraph", GTLUAF(mcmesh::l2drawbridge::graph));
		fa.AddFunction("SetL2DrawSpatialGraph", GTLUAF(mcmesh::l2drawbridge::spatialGraph));
		fa.AddFunction("DrawL2Scene", GTLUAF(mcmesh::l2drawbridge::draw));
	fa.AddFunction("CompileL2Template", GTLUAF(mcmesh::l2bridge::compileTemplate));
	fa.AddFunction("CompileL2Cube", GTLUAF(mcmesh::l2bridge::compileCube));
	fa.AddFunction("CompileL2Model", GTLUAF(mcmesh::l2bridge::compileModel));
	fa.AddFunction("CompileL2Fluid", GTLUAF(mcmesh::l2bridge::compileFluid));
	fa.AddFunction("GetL2SectionParts", GTLUAF(mcmesh::l2bridge::sectionParts));
	fa.AddFunction("BuildL2Mesh", GTLUAF(mcmesh::l2bridge::buildMesh));
	fa.AddFunction("SubmitL2Section", GTLUAF(mcmesh::l2bridge::submitSection));
	fa.AddFunction("SubmitWorldL2Section", GTLUAF(mcmesh::l2bridge::submitWorldSection));
	fa.AddFunction("SubmitWorldL2Relight", GTLUAF(mcmesh::l2bridge::submitWorldRelight));
	fa.AddFunction("GetL2LightPart", GTLUAF(mcmesh::l2bridge::lightPart));
	fa.AddFunction("IsWorldL2Current", GTLUAF(mcmesh::l2bridge::worldSectionCurrent));
	fa.AddFunction("IsWorldL2GeometryCurrent", GTLUAF(mcmesh::l2bridge::worldSectionGeometryCurrent));
	fa.AddFunction("GetWorldL2Topology", GTLUAF(mcmesh::l2bridge::sectionTopology));
	fa.AddFunction("PollL2Section", GTLUAF(mcmesh::l2bridge::pollSection));
	fa.AddFunction("UploadL2Part", GTLUAF(mcmesh::l2bridge::uploadPart));
	fa.AddFunction("L2LightingVersion", GTLUAF(mcmesh::l2bridge::lightingVersion));
	fa.AddFunction("UploadL2PartNative", GTLUAF(mcmesh::l2bridge::uploadNativePart));
	fa.AddFunction("UploadL2MeshPixels", GTLUAF(mcmesh::l2bridge::uploadMeshPixels));
	fa.AddFunction("DrawL2MeshPixels", GTLUAF(mcmesh::pixelupload::Draw));
	fa.AddFunction("ReadL2MeshPixels", GTLUAF(mcmesh::l2bridge::readMeshPixels));
	fa.AddFunction("StageL2Relight", GTLUAF(mcmesh::l2bridge::stageRelight));
	fa.AddFunction("UploadL2Relight", GTLUAF(mcmesh::l2bridge::uploadRelight));
	fa.AddFunction("DrawL2Relight", GTLUAF(mcmesh::pixelupload::Draw));
	fa.AddFunction("FinishL2Relight", GTLUAF(mcmesh::l2bridge::finishRelight));
	fa.AddFunction("CancelL2Section", GTLUAF(mcmesh::l2bridge::cancelSection));
	fa.AddFunction("CanSubmitL2", GTLUAF(mcmesh::l2bridge::canSubmit));
	fa.AddFunction("GetL2Stats", GTLUAF(mcmesh::l2bridge::statistics));
	fa.AddFunction("GetTakeoverCapabilities", GTLUAF(mcmesh::worldbridge::capabilities));
	fa.AddFunction("CreateWorldSession", GTLUAF(mcmesh::worldbridge::create));

	// ---- 世界数据流入(worldstate 持有镜像 + diff; meshbuild 加握手守卫)----
	fa.AddFunction("CreateChunk", GTLUAF(mcmesh::meshbuild::CreateChunk));
	fa.AddFunction("ApplyChunk", GTLUAF(mcmesh::meshbuild::ApplyChunk));
	fa.AddFunction("ApplyChunkCells", GTLUAF(mcmesh::meshbuild::ApplyChunkCells));
	fa.AddFunction("SetCellsBatch", GTLUAF(mcmesh::meshbuild::ApplyChunkCells));
	fa.AddFunction("SetCell", GTLUAF(mcmesh::meshbuild::SetCell));
	fa.AddFunction("GetCell", GTLUAF(mcmesh::meshbuild::GetCell));
	fa.AddFunction("GetChunkCells", GTLUAF(mcmesh::meshbuild::GetChunkCells));
	fa.AddFunction("RebuildBlockLight", GTLUAF(mcmesh::meshbuild::RebuildBlockLight));
	fa.AddFunction("StartBlockLightRebuild", GTLUAF(mcmesh::meshbuild::StartBlockLightRebuild));
	fa.AddFunction("PollBlockLightRebuild", GTLUAF(mcmesh::meshbuild::PollBlockLightRebuild));
	fa.AddFunction("CancelBlockLightRebuild", GTLUAF(mcmesh::meshbuild::CancelBlockLightRebuild));
	fa.AddFunction("GetBlockLightChunk", GTLUAF(mcmesh::meshbuild::GetBlockLightChunk));
	fa.AddFunction("GetSkyLightChunk", GTLUAF(mcmesh::meshbuild::GetSkyLightChunk));
	fa.AddFunction("GetLightingHalo", GTLUAF(mcmesh::meshbuild::GetLightingHalo));
	fa.AddFunction("GetChunkLightTile", GTLUAF(mcmesh::meshbuild::GetChunkLightTile));
	fa.AddFunction("BindLightAtlasMaterial", GTLUAF(mcmesh::lightatlas::BindLightAtlasMaterial));
	fa.AddFunction("GetLightAtlasStats", GTLUAF(mcmesh::lightatlas::GetLightAtlasStats));
	fa.AddFunction("GetLightAtlasSlot", GTLUAF(mcmesh::lightatlas::GetLightAtlasSlot));
	fa.AddFunction("CreateAtlasTexture", GTLUAF(mcmesh::atlastexture::Create));
	fa.AddFunction("DebugAtlasRenderTarget", GTLUAF(mcmesh::atlastexture::DebugRenderTarget));
	fa.AddFunction("DrawL2AtlasPixels", GTLUAF(mcmesh::pixelupload::Draw));
	fa.AddFunction("L2PixelTextureVersion", GTLUAF(mcmesh::pixelupload::Version));
	fa.AddFunction("CreateL2PixelTexture", GTLUAF(mcmesh::pixelupload::Create));
	fa.AddFunction("UploadL2PixelTexture", GTLUAF(mcmesh::pixelupload::Upload));
	fa.AddFunction("FlushL2PixelTextures", GTLUAF(mcmesh::pixelupload::Flush));
	fa.AddFunction("BindL2PixelTexture", GTLUAF(mcmesh::pixelupload::Bind));
	fa.AddFunction("ReleaseL2PixelTexture", GTLUAF(mcmesh::pixelupload::Release));
	fa.AddFunction("GetL2PixelTextureStats", GTLUAF(mcmesh::pixelupload::Stats));
	fa.AddFunction("CreateAtlasSprite", GTLUAF(mcmesh::atlassprite::Create));
	fa.AddFunction("SampleAtlasSprite", GTLUAF(mcmesh::atlassprite::Sample));
	fa.AddFunction("UpdateAtlasSpriteTexture", GTLUAF(mcmesh::atlassprite::UpdateTexture));
	fa.AddFunction("ReleaseAtlasSprite", GTLUAF(mcmesh::atlassprite::Release));
	fa.AddFunction("GetAtlasSpriteStats", GTLUAF(mcmesh::atlassprite::Stats));
	fa.AddFunction("UploadAtlasTextureRect", GTLUAF(mcmesh::atlastexture::Upload));
	fa.AddFunction("FlushAtlasTexture", GTLUAF(mcmesh::atlastexture::Flush));
	fa.AddFunction("FlushAtlasTextureUpdates", GTLUAF(mcmesh::atlastexture::FlushUpdates));
	fa.AddFunction("BindAtlasTexture", GTLUAF(mcmesh::atlastexture::Bind));
	fa.AddFunction("ReleaseAtlasTexture", GTLUAF(mcmesh::atlastexture::Release));
	fa.AddFunction("GetAtlasTextureStats", GTLUAF(mcmesh::atlastexture::Stats));
	fa.AddFunction("DebugFillAtlasTextureMips", GTLUAF(mcmesh::atlastexture::DebugFill));
	fa.AddFunction("ListResourcePackSources", GTLUAF(mcmesh::resourceio::List));
	fa.AddFunction("HashResourceBytes", GTLUAF(mcmesh::resourceio::HashBytes));
	fa.AddFunction("OpenResourcePackSource", GTLUAF(mcmesh::resourceio::Open));
	fa.AddFunction("ReadResourcePackSource", GTLUAF(mcmesh::resourceio::Read));
	fa.AddFunction("ResourcePackSourceUnchanged", GTLUAF(mcmesh::resourceio::Unchanged));
	fa.AddFunction("CloseResourcePackSource", GTLUAF(mcmesh::resourceio::Close));
	fa.AddFunction("StartCompressedPatchDecode", GTLUAF(mcmesh::patchdecode::StartCompressedPatchDecode));
	fa.AddFunction("PollCompressedPatchDecode", GTLUAF(mcmesh::patchdecode::PollCompressedPatchDecode));
	fa.AddFunction("CommitCompressedPatch", GTLUAF(mcmesh::patchdecode::CommitCompressedPatch));
	fa.AddFunction("StartBinarySectionPatchDecode", GTLUAF(mcmesh::patchdecode::StartBinarySectionPatchDecode));
	fa.AddFunction("PollBinarySectionPatchDecode", GTLUAF(mcmesh::patchdecode::PollBinarySectionPatchDecode));
	fa.AddFunction("CommitBinarySectionPatch", GTLUAF(mcmesh::patchdecode::CommitBinarySectionPatch));
	fa.AddFunction("CancelCompressedPatchDecode", GTLUAF(mcmesh::patchdecode::CancelCompressedPatchDecode));
	fa.AddFunction("CancelAllCompressedPatchDecodes", GTLUAF(mcmesh::patchdecode::CancelAllCompressedPatchDecodes));

	// ---- 方块静态数据 ----
	fa.AddFunction("SetBlockDefs", GTLUAF(mcmesh::blockdefs::SetBlockDefs));
	fa.AddFunction("SetLightDefs", GTLUAF(mcmesh::blockdefs::SetLightDefs));

	// ---- 建面 / 帧循环 / 绘制(meshbuild; Unload/Clear 先毁 mesh 再转调 worldstate)----
	fa.AddFunction("Think", GTLUAF(mcmesh::meshbuild::Think));
	fa.AddFunction("DrawChunk", GTLUAF(mcmesh::meshbuild::DrawChunk));
	fa.AddFunction("DrawVisible", GTLUAF(mcmesh::meshbuild::DrawVisible));
	fa.AddFunction("SetChunkVisible", GTLUAF(mcmesh::meshbuild::SetChunkVisible));
	fa.AddFunction("UnloadChunk", GTLUAF(mcmesh::meshbuild::UnloadChunk));
	fa.AddFunction("ClearWorld", GTLUAF(mcmesh::meshbuild::ClearWorld));
	fa.AddFunction("Shutdown", GTLUAF(mcmesh::meshbuild::Shutdown));
	fa.AddFunction("GetStats", GTLUAF(mcmesh::meshbuild::GetStats));
	fa.AddFunction("SetProfiling", GTLUAF(mcmesh::meshbuild::SetProfiling));
	fa.AddFunction("SetSimpleGreedy", GTLUAF(mcmesh::meshbuild::SetSimpleGreedy));
	fa.AddFunction("SetDirectionalDraw", GTLUAF(mcmesh::meshbuild::SetDirectionalDraw));
	fa.AddFunction("SetOcclusionCull", GTLUAF(mcmesh::meshbuild::SetOcclusionCull));
	fa.AddFunction("SetLod", GTLUAF(mcmesh::meshbuild::SetLod));

	// ---- 调试口(正式功能, 不删)----
	fa.AddFunction("DebugGetCell", GTLUAF(mcmesh::Test::DebugGetCell));
	fa.AddFunction("DebugClearDirty", GTLUAF(mcmesh::Test::mcmesh_DebugClearDirty));
	fa.AddFunction("DebugBlockDef", GTLUAF(mcmesh::blockdefs::DebugBlockDef));
	fa.AddFunction("DebugStateDef", GTLUAF(mcmesh::blockdefs::DebugStateDef));
	fa.AddFunction("DebugBuildSection", GTLUAF(mcmesh::meshbuild::DebugBuildSection));
	fa.AddFunction("mcmesh_SpikeQuad", GTLUAF(mcmesh::Test::mcmesh_SpikeQuad));

	fa.End();

	// 弹出全局表
	LUA->Pop(1);

	return 0;
}

GMOD_MODULE_CLOSE()
{
	mcmesh::worldbridge::shutdown();
	// Lua Shutdown hook 不保证在模块卸载前必达；DLL close 是最终线程回收屏障。
	// 引擎资源必须在线程完全停止后释放，避免 worker 仍持有建面数据。
	mcmesh::patchdecode::Shutdown();
	mcmesh::meshbuild::StopWorkers();
	mcmesh::worldstate::StopBlockLightWorker();
	mcmesh::Test::DestroyDebugMesh();
	mcmesh::l2bridge::shutdown();
	mcmesh::meshbuild::DestroyAllMeshes();
	mcmesh::lightatlas::Shutdown();
	mcmesh::atlastexture::Shutdown();
	mcmesh::atlassprite::Shutdown();
	mcmesh::resourceio::Shutdown();
	return 0;
}
