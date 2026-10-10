#include "Module/Pch.h"
#include "Bindings/PixelTextureBindings.h"
#include "Resources/Source/PixelTextureStore.h"
#include "Render/Source/EngineContext.h"
#include <cmath>
#include <stdexcept>
#include <vector>

namespace mcmesh::pixelbindings
{
using namespace GarrysMod::Lua;
namespace
{
int Fail(ILuaBase *inLua, const char *inReason)
{
	inLua->PushNil();
	inLua->PushString(inReason);
	return 2;
}

double ReadNumber(ILuaBase *inLua, int inIndex, double inMinimum, double inMaximum, bool inIntegral = true)
{
	if (!inLua->IsType(inIndex, Type::Number))
		throw std::runtime_error("l2_texture_number");
	const double value = inLua->GetNumber(inIndex);
	if (!std::isfinite(value) || value < inMinimum || value > inMaximum || (inIntegral && value != std::floor(value)))
		throw std::runtime_error("l2_texture_range");
	return value;
}

pixelupload::PixelTextureId ReadHandle(ILuaBase *inLua)
{
	return pixelupload::PixelTextureId(ReadNumber(inLua, 1, 1, double(pixelupload::cMaxPixelTextureId)));
}

void SetNumber(ILuaBase *inLua, const char *inKey, double inValue)
{
	inLua->PushNumber(inValue);
	inLua->SetField(-2, inKey);
}

void PushTextureStats(ILuaBase *inLua, const pixelupload::PixelTextureStats &inStats)
{
	inLua->CreateTable();
	SetNumber(inLua, "id", double(inStats.mId));
	SetNumber(inLua, "width", inStats.mWidth);
	SetNumber(inLua, "height", inStats.mHeight);
	SetNumber(inLua, "backingBytes", double(inStats.mBackingBytes));
	SetNumber(inLua, "pendingBytes", double(inStats.mPendingBytes));
	SetNumber(inLua, "callbacks", double(inStats.mCallbacks));
	SetNumber(inLua, "downloads", double(inStats.mDownloads));
	SetNumber(inLua, "uploadedBytes", double(inStats.mUploadedBytes));
	SetNumber(inLua, "writes", double(inStats.mWrites));
	SetNumber(inLua, "engineBytes", inStats.mEngineBytes);
	SetNumber(inLua, "flags", inStats.mFlags);
	inLua->PushString(inStats.mName.c_str());
	inLua->SetField(-2, "name");
}

/// Owns Lua-converted pixels until the store has staged their borrowed spans.
struct PixelInput
{
	uint32_t			  mFirst;
	double				  mScale, mOffset;
	std::vector<uint32_t> mPixels;
	pixelupload::Span	  GetSpan() const { return {mFirst, mPixels.data(), mPixels.size(), mScale, mOffset}; }
};

PixelInput ReadPixels(ILuaBase *inLua, const pixelupload::PixelTextureDimensions &inDimensions, int inFirstIndex, int inPixelsIndex, double inScale, double inOffset)
{
	PixelInput input{uint32_t(ReadNumber(inLua, inFirstIndex, 0, 268435455)), inScale, inOffset, {}};
	if (!inLua->IsType(inPixelsIndex, Type::Table))
		throw std::runtime_error("l2_texture_pixels");
	const int count = inLua->ObjLen(inPixelsIndex);
	if (count < 1)
		throw std::runtime_error("l2_texture_pixel_count");
	if (std::floor(((uint64_t(input.mFirst) + uint64_t(count) - 1) / inDimensions.mWidth) * inScale + inOffset) >= inDimensions.mHeight)
		throw std::runtime_error("l2_texture_target_bounds");
	input.mPixels.reserve(count);
	for (int i = 1; i <= count; ++i)
	{
		inLua->PushNumber(i);
		inLua->RawGet(inPixelsIndex);
		input.mPixels.push_back(uint32_t(ReadNumber(inLua, -1, 0, 4294967295.0)));
		inLua->Pop();
	}
	return input;
}

/// Restores the Lua stack only after C++ locals and resource scopes unwind.
using LuaOperation = int (*)(ILuaBase *);
int Guard(ILuaBase *inLua, LuaOperation inFunction)
{
	const int top = inLua->Top();
	try
	{
		return inFunction(inLua);
	}
	catch (const std::exception &error)
	{
		if (inLua->Top() > top)
			inLua->Pop(inLua->Top() - top);
		return Fail(inLua, error.what());
	}
}
int CreateTexture(ILuaBase *inLua)
{
	const int width = int(ReadNumber(inLua, 1, 1, 16384));
	const int height = int(ReadNumber(inLua, 2, 1, 16384));
	if (!inLua->IsType(3, Type::Bool))
		return Fail(inLua, "l2_texture_create_arguments");
	const auto stats = pixelupload::GetPixelTextureStore().Create(width, height, inLua->GetBool(3));
	PushTextureStats(inLua, stats);
	return 1;
}

int StagePixels(ILuaBase *inLua)
{
	auto				   &store = pixelupload::GetPixelTextureStore();
	const auto				id = ReadHandle(inLua);
	const auto				dimensions = store.GetDimensions(id);
	std::vector<PixelInput> inputs;
	inputs.push_back(ReadPixels(inLua, dimensions, 2, 3, ReadNumber(inLua, 4, 1, 5, false), ReadNumber(inLua, 5, 0, 4, false)));
	if (inLua->Top() >= 7 && !inLua->IsType(7, Type::Nil))
		inputs.push_back(ReadPixels(inLua, dimensions, 6, 7, 5, 2));
	std::vector<pixelupload::Span> spans;
	for (const auto &input : inputs)
		spans.push_back(input.GetSpan());
	store.Stage(id, spans);
	inLua->PushBool(true);
	return 1;
}

int FlushTextures(ILuaBase *inLua)
{
	pixelupload::GetPixelTextureStore().Flush();
	inLua->PushBool(true);
	return 1;
}

int BindTexture(ILuaBase *inLua)
{
	auto	  &store = pixelupload::GetPixelTextureStore();
	const auto id = ReadHandle(inLua);
	store.GetDimensions(id); // Preserve stale-handle validation before argument parsing.
	if (!inLua->IsType(2, Type::String) || !inLua->IsType(3, Type::String))
		return Fail(inLua, "l2_texture_binding_arguments");
	store.Bind(id, inLua->GetString(2), inLua->GetString(3));
	inLua->PushBool(true);
	return 1;
}

int ReleaseTexture(ILuaBase *inLua)
{
	pixelupload::GetPixelTextureStore().Release(ReadHandle(inLua));
	inLua->PushBool(true);
	return 1;
}

int PushStats(ILuaBase *inLua)
{
	auto &store = pixelupload::GetPixelTextureStore();
	if (inLua->IsType(1, Type::Number))
	{
		PushTextureStats(inLua, store.GetTextureStats(ReadHandle(inLua)));
		return 1;
	}
	const auto stats = store.GetStats();
	inLua->CreateTable();
	SetNumber(inLua, "version", pixelupload::cPixelTextureVersion);
	SetNumber(inLua, "barriers", double(stats.mBarriers));
	SetNumber(inLua, "queueDrainMS", stats.mQueueDrainMS);
	SetNumber(inLua, "materialLockMS", stats.mMaterialLockMS);
	SetNumber(inLua, "pixelVertices", 0);
	SetNumber(inLua, "residentBytes", double(stats.mResidentBytes));
	SetNumber(inLua, "pendingBytes", double(stats.mPendingBytes));
	SetNumber(inLua, "textures", double(stats.mTextures));
	return 1;
}
} // namespace

int Create(ILuaBase *inLua)
{
	return Guard(inLua, CreateTexture);
}

int Upload(ILuaBase *inLua)
{
	return Guard(inLua, StagePixels);
}

int Flush(ILuaBase *inLua)
{
	return Guard(inLua, FlushTextures);
}

int Version(ILuaBase *inLua)
{
	inLua->PushNumber(pixelupload::cPixelTextureVersion);
	return 1;
}

int DeviceRevision(ILuaBase *inLua)
{
	inLua->PushNumber(source::GetRenderDeviceRevision());
	return 1;
}

int Bind(ILuaBase *inLua)
{
	return Guard(inLua, BindTexture);
}

int Release(ILuaBase *inLua)
{
	return Guard(inLua, ReleaseTexture);
}

int Stats(ILuaBase *inLua)
{
	return Guard(inLua, PushStats);
}

int Draw(ILuaBase *inLua)
{
	return Fail(inLua, "l2_pixel_rectangles_removed_restart_with_current_lua");
}
} // namespace mcmesh::pixelbindings
