#pragma once

#include "Module/Pch.h"
#include "Render/Source/EngineContext.h"
#include <vector>

namespace mcmesh
{
// 全局常量
constexpr int	 kCS = 16;
constexpr int	 kCH = 32;
constexpr double kBS = 36.5;
constexpr int	 kCellsPerChunk = kCS * kCS * kCH;
constexpr int	 kStateBlobBytes = kCellsPerChunk * 4;

// 约定信息结构体
struct AtlasPageMaterials
{
	IMaterial *MatOpaque = nullptr;
	IMaterial *MatTranslucent = nullptr;
};

struct Promise
{
	// chunk 水平尺寸 (x/y)
	int CS;
	// CH, chunk 垂直尺寸 (z)
	int CH;
	// Section size
	int SS;
	// Block size
	double BS;
	// CS / SS
	int NSX;
	// CH / SS
	int NSZ;
	// 每个Chunk的Cell数量
	int CPC;
	// 每个Chunk的Section数量
	int SPC;
	// 每个 atlas page 独立绑定不透明/半透明材质；IMesh 创建时固定材质。
	std::vector<AtlasPageMaterials> AtlasMaterials;
};

inline IMesh  *g_mesh = nullptr;
inline Promise g_promise;

} // namespace mcmesh
