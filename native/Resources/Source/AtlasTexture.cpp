#include "Module/Pch.h"
#include "Resources/Source/AtlasTexture.h"
#include "Resources/Atlas/AtlasRegions.h"
#include "Render/Source/EngineContext.h"
#include "public/materialsystem/imaterialvar.h"
#include "public/materialsystem/itexture.h"
#include "public/materialsystem/imaterialsystemhardwareconfig.h"
#include "public/materialsystem/materialsystem_config.h"
#include "public/vtf/vtf.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>

namespace mcmesh::atlastexture
{
namespace
{
using namespace GarrysMod::Lua;
constexpr size_t kBudget = size_t(1536) * 1024 * 1024;
// Active, pending and one retiring generation, each with up to three channels.
constexpr size_t kSlots = 9;
struct Level
{
	int					 width, height;
	std::vector<uint8_t> bytes;
};
struct Binding
{
	IMaterial	 *material;
	IMaterialVar *variable;
	ITexture	 *previous;
};

struct Texture final : ITextureRegenerator
{
	uint64_t						 id = 0, callbacks = 0, uploadedBytes = 0;
	int								 width = 0, height = 0, requestedMip = 0, actualMipCount = 0;
	size_t							 bytes = 0;
	ITexture						*texture = nullptr;
	std::vector<Level>				 levels;
	std::vector<Binding>			 bindings;
	std::vector<atlas::UploadRegion> dirty;
	const char						*error = nullptr;
	Rect_t							 lastRect{};

	void RegenerateTextureBits(ITexture *, IVTFTexture *vtf, Rect_t *requested) override
	{
		++callbacks;
		if (!vtf || vtf->Width() != width || vtf->Height() != height || vtf->MipCount() != int(levels.size()))
		{
			error = "atlas_texture_vtf_layout_mismatch";
			return;
		}
		actualMipCount = vtf->MipCount();
		const ImageFormat format = vtf->Format();
		if (format != IMAGE_FORMAT_RGBA8888 && format != IMAGE_FORMAT_BGRA8888)
		{
			error = "atlas_texture_vtf_format_unsupported";
			return;
		}
		Rect_t rect{0, 0, width, height};
		if (requested)
			rect = *requested;
		if (rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0 || rect.x > width - rect.width || rect.y > height - rect.height)
		{
			error = "atlas_texture_vtf_rect_invalid";
			return;
		}
		lastRect = rect;
		// Download accepts a level-zero rectangle. Each lower level covers the
		// corresponding rounded-out rectangle; never regenerate adjacent sprites.
		for (int mip = 0; mip < int(levels.size()); ++mip)
		{
			const Level &level = levels[mip];
			const int	 unit = 1 << mip;
			const int	 x = rect.x / unit, y = rect.y / unit;
			const int	 right = std::min(level.width, (rect.x + rect.width + unit - 1) / unit);
			const int	 bottom = std::min(level.height, (rect.y + rect.height + unit - 1) / unit);
			uint8_t		*target = vtf->ImageData(0, 0, mip);
			if (!target)
			{
				error = "atlas_texture_vtf_data_missing";
				return;
			}
			const int stride = vtf->RowSizeInBytes(mip);
			for (int row = y; row < bottom; ++row)
			{
				const uint8_t *source = level.bytes.data() + (size_t(row) * level.width + x) * 4;
				uint8_t		  *dest = target + size_t(row) * stride + x * 4;
				if (format == IMAGE_FORMAT_RGBA8888)
					std::memcpy(dest, source, size_t(right - x) * 4);
				else
					for (int col = x; col < right; ++col, source += 4, dest += 4)
					{
						dest[0] = source[2];
						dest[1] = source[1];
						dest[2] = source[0];
						dest[3] = source[3];
					}
			}
			uploadedBytes += size_t(right - x) * (bottom - y) * 4;
		}
	}
	void Release() override {} // The owning slot outlives the regenerator attachment.
	~Texture()
	{
		for (auto &binding : bindings)
		{
			if (binding.variable->GetTextureValue() == texture)
				binding.variable->SetTextureValue(binding.previous);
			if (binding.previous)
				binding.previous->Release();
			binding.material->DecrementReferenceCount();
		}
		if (texture)
		{
			texture->SetTextureRegenerator(nullptr);
			texture->Release();
			texture->DeleteIfUnreferenced();
		}
	}
};
std::array<std::unique_ptr<Texture>, kSlots> textures;
// Fixed-size opt-in probes, separate from production atlas ownership.
std::array<ITexture *, 2> renderTargetProbes{};
uint64_t				  sequence = 0, creations = 0, releases = 0;
size_t					  resident = 0, peak = 0;
int						  Fail(ILuaBase *lua, const char *reason)
{
	lua->PushNil();
	lua->PushString(reason);
	return 2;
}
bool Integer(ILuaBase *lua, int index, int lo, int hi, int &out)
{
	if (!lua->IsType(index, Type::Number))
		return false;
	double value = lua->GetNumber(index);
	if (!std::isfinite(value) || value != std::floor(value) || value < lo || value > hi)
		return false;
	out = int(value);
	return true;
}
Texture *Find(ILuaBase *lua)
{
	if (!lua->IsType(1, Type::Number))
		return nullptr;
	const double id = lua->GetNumber(1);
	for (auto &texture : textures)
		if (texture && double(texture->id) == id)
			return texture.get();
	return nullptr;
}
void Number(ILuaBase *lua, const char *key, double value)
{
	lua->PushNumber(value);
	lua->SetField(-2, key);
}
void Describe(ILuaBase *lua, const Texture &item)
{
	lua->CreateTable();
	Number(lua, "id", double(item.id));
	Number(lua, "width", item.width);
	Number(lua, "height", item.height);
	Number(lua, "requestedMip", item.requestedMip);
	Number(lua, "actualMipCount", item.actualMipCount);
	Number(lua, "backingBytes", double(item.bytes));
	Number(lua, "callbacks", double(item.callbacks));
	Number(lua, "uploadedBytes", double(item.uploadedBytes));
	Number(lua, "engineBytes", item.texture->GetApproximateVidMemBytes());
	Number(lua, "flags", item.texture->GetFlags());
	lua->PushBool(item.texture->IsMipmapped());
	lua->SetField(-2, "mipmapped");
	Number(lua, "rectX", item.lastRect.x);
	Number(lua, "rectY", item.lastRect.y);
	Number(lua, "rectWidth", item.lastRect.width);
	Number(lua, "rectHeight", item.lastRect.height);
	lua->PushString(item.texture->GetName());
	lua->SetField(-2, "name");
}
} // namespace

int Create(ILuaBase *lua)
{
	int width, height, mip;
	if (!Integer(lua, 1, 1, 16384, width) || !Integer(lua, 2, 1, 16384, height) || !Integer(lua, 3, 0, 14, mip) || (width & (width - 1)) || (height & (height - 1)) || (1 << mip) > std::min(width, height))
		return Fail(lua, "invalid_atlas_texture_dimensions");
	if (!source::GetMaterialSystem())
		return Fail(lua, "atlas_texture_materialsystem_unavailable");
	int	  code = 0;
	auto *hardware = source::GetMaterialSystem()->GetHardwareConfig(MATERIALSYSTEM_HARDWARECONFIG_INTERFACE_VERSION, &code);
	if (!hardware || width > hardware->MaxTextureWidth() || height > hardware->MaxTextureHeight())
		return Fail(lua, "atlas_texture_device_limit");
	size_t slot = 0;
	while (slot < kSlots && textures[slot])
		++slot;
	if (slot == kSlots)
		return Fail(lua, "atlas_texture_slots_exhausted");
	// Source's public procedural API allocates a complete chain or NOMIP.
	// Report the actual allocation; requestedMip is a sampling limit, not a claim
	// that unused tail levels were omitted by the driver.
	size_t bytes = 0;
	int	   w = width, h = height;
	do
	{
		bytes += size_t(w) * h * 4;
		if (mip == 0 || (w == 1 && h == 1))
			break;
		w = std::max(1, w / 2);
		h = std::max(1, h / 2);
	} while (true);
	if (bytes > kBudget - resident)
		return Fail(lua, "atlas_texture_memory_budget");
	try
	{
		auto item = std::make_unique<Texture>();
		item->id = ++sequence;
		item->width = width;
		item->height = height;
		item->requestedMip = mip;
		item->bytes = bytes;
		w = width;
		h = height;
		do
		{
			item->levels.push_back({w, h, std::vector<uint8_t>(size_t(w) * h * 4, 0)});
			if (mip == 0 || (w == 1 && h == 1))
				break;
			w = std::max(1, w / 2);
			h = std::max(1, h / 2);
		} while (true);
		const std::string name = "mc_resource_atlas_native_" + std::to_string(item->id);
		// Without ALL_MIPS Source stops uploading at 32x32 even though the
		// scratch VTF and approximate byte count describe the complete chain.
		int flags = TEXTUREFLAGS_CLAMPS | TEXTUREFLAGS_CLAMPT | TEXTUREFLAGS_NOLOD | TEXTUREFLAGS_ALL_MIPS | TEXTUREFLAGS_PROCEDURAL | TEXTUREFLAGS_EIGHTBITALPHA | TEXTUREFLAGS_SINGLECOPY;
		// Source's POINTSAMPLE sampler disables mip selection even for
		// tex2Dlod. Mipped atlas shaders snap UVs to the selected texel centre.
		if (!mip)
			flags |= TEXTUREFLAGS_NOMIP | TEXTUREFLAGS_POINTSAMPLE;
		ITexture *created = source::GetMaterialSystem()->CreateProceduralTexture(name.c_str(), TEXTURE_GROUP_OTHER,
																				 width, height, IMAGE_FORMAT_RGBA8888, flags);
		if (!created || created->IsError())
			return Fail(lua, "atlas_texture_creation_failed");
		item->texture = created;
		if (created->GetActualWidth() != width || created->GetActualHeight() != height)
			return Fail(lua, "atlas_texture_engine_resized");
		created->SetTextureRegenerator(item.get());
		created->Download();
		if (item->error)
			return Fail(lua, item->error);
		if (!item->callbacks)
			return Fail(lua, "atlas_texture_regenerator_not_called");
		resident += bytes;
		peak = std::max(peak, resident);
		++creations;
		textures[slot] = std::move(item);
		Describe(lua, *textures[slot]);
		return 1;
	}
	catch (const std::exception &)
	{
		return Fail(lua, "atlas_texture_allocation_failed");
	}
}

int Upload(ILuaBase *lua)
{
	Texture *item = Find(lua);
	if (!item)
		return Fail(lua, "atlas_texture_stale_handle");
	int x, y, width, height;
	if (!Integer(lua, 2, 0, item->width - 1, x) || !Integer(lua, 3, 0, item->height - 1, y) || !Integer(lua, 4, 1, item->width, width) || !Integer(lua, 5, 1, item->height, height) || x > item->width - width || y > item->height - height || !lua->IsType(6, Type::Table))
		return Fail(lua, "invalid_atlas_texture_rect");
	const int alignment = 1 << item->requestedMip;
	if ((x % alignment) || (y % alignment) || (width % alignment) || (height % alignment))
		return Fail(lua, "atlas_texture_rect_mip_alignment");
	if (lua->Top() >= 7 && !lua->IsType(7, Type::Bool))
		return Fail(lua, "atlas_texture_upload_defer_boolean");
	const bool defer = lua->Top() >= 7 && lua->GetBool(7);
	struct Input
	{
		const char *data;
		int			x, y, width, height;
	};
	std::array<Input, 15> inputs{};
	// Validate the complete update before touching any backing pixels.
	for (int mip = 0; mip <= item->requestedMip; ++mip)
	{
		lua->PushNumber(mip + 1);
		lua->GetTable(6);
		unsigned	length = 0;
		const bool	string = lua->IsType(-1, Type::String);
		const char *data = string ? lua->GetString(-1, &length) : nullptr;
		const int	mw = width >> mip, mh = height >> mip;
		lua->Pop();
		if (!data || size_t(length) != size_t(mw) * mh * 4)
			return Fail(lua, "atlas_texture_mip_bytes_invalid");
		inputs[mip] = {data, x >> mip, y >> mip, mw, mh};
	}
	for (int mip = 0; mip <= item->requestedMip; ++mip)
	{
		const Input &input = inputs[mip];
		Level		&level = item->levels[mip];
		for (int row = 0; row < input.height; ++row)
			std::memcpy(level.bytes.data() + (size_t(input.y + row) * level.width + input.x) * 4,
						input.data + size_t(row) * input.width * 4, size_t(input.width) * 4);
	}
	if (defer)
	{
		lua->PushBool(true);
		return 1;
	}
	Rect_t rect{x, y, width, height};
	item->error = nullptr;
	item->texture->Download(&rect);
	if (item->error)
		return Fail(lua, item->error);
	lua->PushBool(true);
	return 1;
}

int Flush(ILuaBase *lua)
{
	Texture *item = Find(lua);
	if (!item)
		return Fail(lua, "atlas_texture_stale_handle");
	item->error = nullptr;
	item->texture->Download();
	if (item->error)
		return Fail(lua, item->error);
	item->dirty.clear();
	lua->PushBool(true);
	return 1;
}

bool QueueImages(uint64_t id, int x, int y, const std::vector<atlas::Image> &levels, std::string &error)
{
	Texture *item = nullptr;
	for (const auto &slot : textures)
		if (slot && slot->id == id)
		{
			item = slot.get();
			break;
		}
	auto fail = [&](const char *reason)
	{
		error = reason;
		return false;
	};
	if (!item)
		return fail("atlas_texture_stale_handle");
	if (levels.size() != size_t(item->requestedMip + 1))
		return fail("atlas_texture_mip_count");
	const int width = levels[0].width, height = levels[0].height, alignment = 1 << item->requestedMip;
	if (x < 0 || y < 0 || width <= 0 || height <= 0 || x > item->width - width || y > item->height - height)
		return fail("invalid_atlas_texture_rect");
	if (x % alignment || y % alignment || width % alignment || height % alignment)
		return fail("atlas_texture_rect_mip_alignment");
	for (int mip = 0; mip <= item->requestedMip; ++mip)
	{
		const auto &image = levels[mip];
		if (image.width != (width >> mip) || image.height != (height >> mip) || image.pixels.size() != size_t(image.width) * image.height)
			return fail("atlas_texture_mip_bytes_invalid");
	}
	// Reserve before modifying pixels. Repeated callers cannot grow this queue
	// indefinitely; coalescing all regions still preserves their backing pixels.
	const atlas::UploadRegion region{x, y, width, height};
	if (item->dirty.size() < 256)
		item->dirty.push_back(region);
	else
	{
		auto combined = region;
		for (const auto &pending : item->dirty)
			combined = atlas::Union(combined, pending);
		item->dirty.resize(1);
		item->dirty[0] = combined;
	}
	for (int mip = 0; mip <= item->requestedMip; ++mip)
	{
		const auto &image = levels[mip];
		auto	   &target = item->levels[mip];
		for (int row = 0; row < image.height; ++row)
			std::memcpy(target.bytes.data() + (size_t((y >> mip) + row) * target.width + (x >> mip)) * 4,
						image.pixels.data() + size_t(row) * image.width, size_t(image.width) * 4);
	}
	return true;
}

int FlushUpdates(ILuaBase *lua)
{
	Texture *item = Find(lua);
	if (!item)
		return Fail(lua, "atlas_texture_stale_handle");
	// Source Download has texture-sized staging costs even for small rectangles.
	// Large atlases must trade more backing copies for fewer driver callbacks.
	// The compiler packs animated sprites together, keeping those unions small.
	const int64_t overheadPixels = std::max<int64_t>(65536, int64_t(item->width) * item->height / 8);
	atlas::MergeUploadRegions(item->dirty, overheadPixels);
	for (const auto &region : item->dirty)
	{
		Rect_t rect{region.x, region.y, region.width, region.height};
		item->error = nullptr;
		item->texture->Download(&rect);
		if (item->error)
			return Fail(lua, item->error);
	}
	item->dirty.clear();
	lua->PushBool(true);
	return 1;
}

int Bind(ILuaBase *lua)
{
	Texture *item = Find(lua);
	if (!item)
		return Fail(lua, "atlas_texture_stale_handle");
	if (!lua->IsType(2, Type::String) || !lua->IsType(3, Type::String))
		return Fail(lua, "invalid_atlas_texture_binding");
	IMaterial *material = source::GetMaterialSystem()->FindMaterial(lua->GetString(2), TEXTURE_GROUP_OTHER, false);
	if (!material || material->IsErrorMaterial())
		return Fail(lua, "atlas_texture_material_missing");
	bool		  found = false;
	IMaterialVar *variable = material->FindVar(lua->GetString(3), &found, false);
	if (!found || !variable || !variable->IsTexture())
		return Fail(lua, "atlas_texture_material_var_missing");
	for (const auto &other : textures)
		if (other)
			for (const auto &bound : other->bindings)
				if (bound.variable == variable)
				{
					if (other.get() != item)
						return Fail(lua, "atlas_texture_binding_owned");
					variable->SetTextureValue(item->texture);
					lua->PushBool(true);
					return 1;
				}
	try
	{
		item->bindings.push_back({material, variable, variable->GetTextureValue()});
	}
	catch (const std::exception &)
	{
		return Fail(lua, "atlas_texture_binding_allocation_failed");
	}
	material->IncrementReferenceCount();
	if (item->bindings.back().previous)
		item->bindings.back().previous->AddRef();
	variable->SetTextureValue(item->texture);
	lua->PushBool(true);
	return 1;
}

int Release(ILuaBase *lua)
{
	Texture *item = Find(lua);
	if (!item)
		return Fail(lua, "atlas_texture_stale_handle");
	resident -= item->bytes;
	for (auto &slot : textures)
		if (slot.get() == item)
		{
			slot.reset();
			++releases;
			break;
		}
	lua->PushBool(true);
	return 1;
}

int DebugFill(ILuaBase *lua)
{
	Texture *item = Find(lua);
	if (!item)
		return Fail(lua, "atlas_texture_stale_handle");
	constexpr uint8_t colors[][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}, {255, 0, 255, 255}, {0, 255, 255, 255}};
	for (size_t mip = 0; mip < item->levels.size(); ++mip)
	{
		auto &bytes = item->levels[mip].bytes;
		for (size_t pixel = 0; pixel < bytes.size(); pixel += 4)
			std::memcpy(bytes.data() + pixel, colors[mip % 6], 4);
	}
	item->error = nullptr;
	item->texture->Download();
	if (item->error)
		return Fail(lua, item->error);
	Describe(lua, *item);
	return 1;
}
int Stats(ILuaBase *lua)
{
	if (lua->IsType(1, Type::Number))
	{
		Texture *item = Find(lua);
		if (!item)
			return Fail(lua, "atlas_texture_stale_handle");
		Describe(lua, *item);
		return 1;
	}
	lua->CreateTable();
	Number(lua, "residentBytes", double(resident));
	Number(lua, "peakBytes", double(peak));
	Number(lua, "creations", double(creations));
	Number(lua, "releases", double(releases));
	Number(lua, "budgetBytes", double(kBudget));
	Number(lua, "maxLive", kSlots);
	if (source::GetMaterialSystem())
		Number(lua, "engineSkipMipLevels", source::GetMaterialSystem()->GetCurrentConfigForVideoCard().skipMipLevels);
	return 1;
}
int DebugRenderTarget(ILuaBase *lua)
{
	int mode;
	if (!Integer(lua, 1, 0, 1, mode))
		return Fail(lua, "atlas_gpu_probe_mode");
	if (!source::GetMaterialSystem())
		return Fail(lua, "atlas_texture_materialsystem_unavailable");
	ITexture *&texture = renderTargetProbes[mode];
	if (!texture)
	{
		const char *name = mode ? "mc_native_gpu_probe_bool_v1" : "mc_native_gpu_probe_flags_v1";
		if (mode)
		{
			texture = source::GetMaterialSystem()->CreateNamedRenderTargetTexture(name, 256, 256,
																				  RT_SIZE_LITERAL, IMAGE_FORMAT_RGBA8888, MATERIAL_RT_DEPTH_NONE, true, true);
		}
		else
		{
			texture = source::GetMaterialSystem()->CreateNamedRenderTargetTextureEx(name, 256, 256,
																					RT_SIZE_LITERAL, IMAGE_FORMAT_RGBA8888, MATERIAL_RT_DEPTH_NONE,
																					TEXTUREFLAGS_CLAMPS | TEXTUREFLAGS_CLAMPT | TEXTUREFLAGS_NOLOD | TEXTUREFLAGS_ALL_MIPS | TEXTUREFLAGS_EIGHTBITALPHA,
																					CREATERENDERTARGETFLAGS_AUTOMIPMAP);
		}
	}
	if (!texture || texture->IsError())
		return Fail(lua, "atlas_gpu_probe_creation_failed");
	lua->CreateTable();
	lua->PushString(texture->GetName());
	lua->SetField(-2, "name");
	Number(lua, "width", texture->GetActualWidth());
	Number(lua, "height", texture->GetActualHeight());
	Number(lua, "flags", texture->GetFlags());
	Number(lua, "engineBytes", texture->GetApproximateVidMemBytes());
	lua->PushBool(texture->IsMipmapped());
	lua->SetField(-2, "mipmapped");
	lua->PushBool(texture->IsRenderTarget());
	lua->SetField(-2, "renderTarget");
	return 1;
}
void Shutdown()
{
	for (auto &texture : textures)
		texture.reset();
	for (auto *&texture : renderTargetProbes)
	{
		if (texture)
		{
			texture->Release();
			texture->DeleteIfUnreferenced();
			texture = nullptr;
		}
	}
	resident = 0;
}
} // namespace mcmesh::atlastexture
