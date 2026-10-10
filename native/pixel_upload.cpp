#include "pch.h"
#include "pixel_upload.h"
#include "global.h"
#include "pixel_texture_data.h"
#include "l2_pixels.h"
#include "public/materialsystem/itexture.h"
#include "public/materialsystem/imaterialvar.h"
#include "public/materialsystem/imaterialsystemhardwareconfig.h"
#include "public/vtf/vtf.h"
#include <chrono>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace mcmesh::pixelupload {
namespace {
using namespace GarrysMod::Lua;
struct Binding { IMaterial* material; IMaterialVar* variable; ITexture* previous; };
struct Texture final : ITextureRegenerator {
    uint64_t id = 0, callbacks = 0, downloads = 0, uploadedBytes = 0, writes = 0;
    int width = 0, height = 0;
    ITexture* texture = nullptr;
    Image image;
    Texture(int w, int h) : width(w), height(h), image(w, h) {}
    std::vector<Binding> bindings;
    std::mutex mutex;
    const char* error = nullptr;
    void RegenerateTextureBits(ITexture*, IVTFTexture* vtf, Rect_t* requested) override {
        std::lock_guard<std::mutex> lock(mutex);
        ++callbacks;
        if (!vtf || vtf->Width() != width || vtf->Height() != height || vtf->MipCount() != 1) {
            error = "l2_texture_vtf_layout"; return;
        }
        const auto format = vtf->Format();
        if (format != IMAGE_FORMAT_RGBA8888 && format != IMAGE_FORMAT_BGRA8888) {
            error = "l2_texture_vtf_format"; return;
        }
        Rect_t rect{0, 0, width, height};
        if (requested) rect = *requested;
        if (rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0
            || rect.x > width - rect.width || rect.y > height - rect.height) {
            error = "l2_texture_vtf_rect"; return;
        }
        auto* data = vtf->ImageData(0, 0, 0);
        const int pitch = vtf->RowSizeInBytes(0);
        if (!data || pitch < width * 4) { error = "l2_texture_vtf_data"; return; }
        for (int y = rect.y; y < rect.y + rect.height; ++y) {
            const auto& row = image.row(y);
            auto* dest = data + size_t(y) * pitch + rect.x * 4;
            if (row.empty()) { std::memset(dest, 0, size_t(rect.width) * 4); continue; }
            const auto* source = reinterpret_cast<const uint8_t*>(row.data() + rect.x);
            if (format == IMAGE_FORMAT_RGBA8888) std::memcpy(dest, source, size_t(rect.width) * 4);
            else for (int x = 0; x < rect.width; ++x, source += 4, dest += 4) {
                dest[0] = source[2]; dest[1] = source[1]; dest[2] = source[0]; dest[3] = source[3];
            }
        }
        uploadedBytes += size_t(rect.width) * rect.height * 4;
    }
    void Release() override {} // Slot owns the attached callback.
    void RestoreBindings() {
        // Material mutations must use the normal queued context. Restoring
        // under IMaterialSystem::Lock leaves its queued material copy bound.
        // The caller drains these mutations before destroying the texture.
        for (auto& binding : bindings) {
            if (binding.variable->GetTextureValue() == texture) binding.variable->SetTextureValue(binding.previous);
        }
    }
    ~Texture() {
        for (auto& binding : bindings) {
            if (binding.previous) binding.previous->Release();
            binding.material->DecrementReferenceCount();
        }
        if (texture) {
            texture->SetTextureRegenerator(nullptr);
            texture->Release();
            texture->DeleteIfUnreferenced();
        }
    }
};
std::map<uint64_t, std::unique_ptr<Texture>> textures;
uint64_t sequence = 0, barriers = 0;
int Fail(ILuaBase* lua, const char* reason) { lua->PushNil(); lua->PushString(reason); return 2; }
double Number(ILuaBase* lua, int at, double lo, double hi, bool integral = true) {
    if (!lua->IsType(at, Type::Number)) throw std::runtime_error("l2_texture_number");
    const double n = lua->GetNumber(at);
    if (!std::isfinite(n) || n < lo || n > hi || (integral && n != std::floor(n)))
        throw std::runtime_error("l2_texture_range");
    return n;
}
Texture& Find(double id) {
    if (!std::isfinite(id) || id < 1 || id > 9007199254740991.0 || id != std::floor(id))
        throw std::runtime_error("l2_texture_stale_handle");
    const auto found = textures.find(uint64_t(id));
    if (found == textures.end()) throw std::runtime_error("l2_texture_stale_handle");
    return *found->second;
}
Texture& Find(ILuaBase* lua) { return Find(Number(lua, 1, 1, 9007199254740991.0)); }
// GMod's barrier differs from Source's empty ExecuteQueued and from Lock,
// which only waits for the active async job. Drain queued consumers FIRST.
struct Barrier {
    MaterialLock_t lock;
    Barrier() {
        CMatRenderContextPtr context(g_matsys);
        context->GMOD_FlushQueue();
        lock = g_matsys->Lock(); ++barriers;
    }
    ~Barrier() { g_matsys->Unlock(lock); }
};
void Field(ILuaBase* lua, const char* key, double n) { lua->PushNumber(n); lua->SetField(-2, key); }
void Describe(ILuaBase* lua, Texture& item) {
    std::lock_guard<std::mutex> lock(item.mutex);
    lua->CreateTable();
    Field(lua, "id", double(item.id)); Field(lua, "width", item.width); Field(lua, "height", item.height);
    Field(lua, "backingBytes", double(item.image.backingBytes()));
    Field(lua, "pendingBytes", double(item.image.pendingBytes()));
    Field(lua, "callbacks", double(item.callbacks)); Field(lua, "downloads", double(item.downloads));
    Field(lua, "uploadedBytes", double(item.uploadedBytes)); Field(lua, "writes", double(item.writes));
    Field(lua, "engineBytes", item.texture->GetApproximateVidMemBytes()); Field(lua, "flags", item.texture->GetFlags());
    lua->PushString(item.texture->GetName()); lua->SetField(-2, "name");
}
struct Input { int first; double scale, offset; std::vector<uint32_t> pixels; };
Input Read(ILuaBase* lua, Texture& item, int firstAt, int pixelsAt, double scale, double offset) {
    Input input{int(Number(lua, firstAt, 0, 268435455)), scale, offset, {}};
    if (!lua->IsType(pixelsAt, Type::Table)) throw std::runtime_error("l2_texture_pixels");
    const int count = lua->ObjLen(pixelsAt);
    if (count < 1) throw std::runtime_error("l2_texture_pixel_count");
    if (std::floor(((uint64_t(input.first) + uint64_t(count) - 1) / item.width) * scale + offset) >= item.height)
        throw std::runtime_error("l2_texture_target_bounds");
    input.pixels.reserve(count);
    for (int i = 1; i <= count; ++i) {
        lua->PushNumber(i); lua->RawGet(pixelsAt);
        input.pixels.push_back(uint32_t(Number(lua, -1, 0, 4294967295.0))); lua->Pop();
    }
    return input;
}
template<class Fn> int Guard(ILuaBase* lua, Fn fn) {
    const int top = lua->Top();
    try { return fn(); }
    catch (const std::exception& e) {
        if (lua->Top() > top) lua->Pop(lua->Top() - top);
        return Fail(lua, e.what());
    }
}
}

int Create(ILuaBase* lua) { return Guard(lua, [&] {
    const int width = int(Number(lua, 1, 1, 16384)), height = int(Number(lua, 2, 1, 16384));
    if (!g_matsys || !lua->IsType(3, Type::Bool)) return Fail(lua, "l2_texture_create_arguments");
    int code = 0;
    auto* hardware = g_matsys->GetHardwareConfig(MATERIALSYSTEM_HARDWARECONFIG_INTERFACE_VERSION, &code);
    if (!hardware || width > hardware->MaxTextureWidth() || height > hardware->MaxTextureHeight())
        return Fail(lua, "l2_texture_device_limit");
    if (sequence == 9007199254740991ULL) return Fail(lua, "l2_texture_handle_exhausted");
    Barrier barrier;
    auto item = std::make_unique<Texture>(width, height);
    item->id = ++sequence;
    const std::string name = "mc_l2_pixels_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count())
        + "_" + std::to_string(item->id);
    int flags = TEXTUREFLAGS_CLAMPS | TEXTUREFLAGS_CLAMPT | TEXTUREFLAGS_NOLOD | TEXTUREFLAGS_NOMIP
        | TEXTUREFLAGS_PROCEDURAL | TEXTUREFLAGS_EIGHTBITALPHA | TEXTUREFLAGS_SINGLECOPY;
    if (lua->GetBool(3)) flags |= TEXTUREFLAGS_POINTSAMPLE;
    item->texture = g_matsys->CreateProceduralTexture(name.c_str(), TEXTURE_GROUP_OTHER,
        width, height, IMAGE_FORMAT_RGBA8888, flags);
    if (!item->texture || item->texture->IsError()) return Fail(lua, "l2_texture_creation_failed");
    if (item->texture->GetActualWidth() != width || item->texture->GetActualHeight() != height)
        return Fail(lua, "l2_texture_engine_resized");
    item->texture->SetTextureRegenerator(item.get()); item->texture->Download();
    if (item->error) return Fail(lua, item->error);
    if (!item->callbacks) return Fail(lua, "l2_texture_regenerator_not_called");
    const auto id = item->id;
    auto inserted = textures.emplace(id, std::move(item));
    Describe(lua, *inserted.first->second); return 1;
}); }

int Upload(ILuaBase* lua) { return Guard(lua, [&] {
    Texture& item = Find(lua);
    std::vector<Input> inputs;
    inputs.push_back(Read(lua, item, 2, 3, Number(lua, 4, 1, 5, false), Number(lua, 5, 0, 4, false)));
    if (lua->Top() >= 7 && !lua->IsType(7, Type::Nil)) inputs.push_back(Read(lua, item, 6, 7, 5, 2));
    std::vector<Span> spans;
    for (const auto& input : inputs)
        spans.push_back({uint32_t(input.first), input.pixels.data(), input.pixels.size(), input.scale, input.offset});
    std::lock_guard<std::mutex> lock(item.mutex);
    item.image.stage(spans);
    ++item.writes; lua->PushBool(true); return 1;
}); }

void Flush() {
    bool dirty = false;
    for (const auto& [id, item] : textures) if (!item->image.pending.empty()) dirty = true;
    if (!dirty) return;
    Barrier barrier;
    for (auto& [id, item] : textures) if (!item->image.pending.empty()) {
        // Allocate the rectangle plan before changing the published image.
        const auto rects = item->image.rectangles();
        {
            std::lock_guard<std::mutex> lock(item->mutex);
            item->image.publish();
        }
        for (const auto& area : rects) {
            Rect_t rect{area.x, area.y, area.width, area.height};
            item->error = nullptr;
            const auto before = item->callbacks;
            item->texture->Download(&rect); ++item->downloads;
            if (item->error) throw std::runtime_error(item->error);
            if (item->callbacks == before) throw std::runtime_error("l2_texture_regenerator_not_called");
        }
        item->image.pending.clear();
    }
}
int Flush(ILuaBase* lua) { return Guard(lua, [&] { Flush(); lua->PushBool(true); return 1; }); }
int Version(ILuaBase* lua) { lua->PushNumber(2); return 1; }

int Bind(ILuaBase* lua) { return Guard(lua, [&] {
    Texture& item = Find(lua);
    if (!lua->IsType(2, Type::String) || !lua->IsType(3, Type::String)) return Fail(lua, "l2_texture_binding_arguments");
    auto* material = g_matsys->FindMaterial(lua->GetString(2), TEXTURE_GROUP_OTHER, false);
    if (!material || material->IsErrorMaterial()) return Fail(lua, "l2_texture_binding_material");
    bool found = false;
    auto* variable = material->FindVar(lua->GetString(3), &found, false);
    if (!found || !variable || !variable->IsTexture()) return Fail(lua, "l2_texture_binding_parameter");
    for (const auto& [id, slot] : textures) for (const auto& binding : slot->bindings)
        if (binding.variable == variable) {
            if (slot.get() != &item) return Fail(lua, "l2_texture_binding_owned");
            variable->SetTextureValue(item.texture); lua->PushBool(true); return 1;
        }
    item.bindings.push_back({material, variable, variable->GetTextureValue()});
    material->IncrementReferenceCount();
    if (item.bindings.back().previous) item.bindings.back().previous->AddRef();
    variable->SetTextureValue(item.texture); lua->PushBool(true); return 1;
}); }
int Release(ILuaBase* lua) { return Guard(lua, [&] {
    Texture& item = Find(lua);
    item.RestoreBindings();
    Barrier barrier;
    textures.erase(item.id);
    lua->PushBool(true); return 1;
}); }
int Stats(ILuaBase* lua) { return Guard(lua, [&] {
    if (lua->IsType(1, Type::Number)) { Describe(lua, Find(lua)); return 1; }
    lua->CreateTable(); Field(lua, "version", 2); Field(lua, "barriers", double(barriers));
    Field(lua, "pixelVertices", 0);
    size_t backing = 0, pending = 0;
    for (const auto& [id, item] : textures) {
        std::lock_guard<std::mutex> lock(item->mutex);
        backing += item->image.backingBytes(); pending += item->image.pendingBytes();
    }
    Field(lua, "residentBytes", double(backing)); Field(lua, "pendingBytes", double(pending));
    Field(lua, "textures", double(textures.size())); return 1;
}); }
int Draw(ILuaBase* lua) { return Fail(lua, "l2_pixel_rectangles_removed_restart_with_current_lua"); }
void Shutdown() {
    if (textures.empty()) return;
    for (auto& [id, item] : textures) item->RestoreBindings();
    Barrier barrier;
    textures.clear();
}
namespace {
std::array<Span, 2> NativeSpans(const l2::LightPixels& pixels, unsigned first) {
    return {{{first * 4, pixels.corners.data(), pixels.corners.size(), 1.25, 0.625},
        {first, pixels.occlusion.data(), pixels.occlusion.size(), 5, 2}}};
}
void PrepareNative(Texture& item, const l2::LightPixels& pixels, unsigned first) {
    l2::validatePixelRange(pixels, item.width, item.height, first);
    for (const auto& span : NativeSpans(pixels, first)) item.image.prepare(span);
}
void StageNative(Texture& item, const l2::LightPixels& pixels, unsigned first) {
    for (const auto& span : NativeSpans(pixels, first)) item.image.stagePrepared(span);
    ++item.writes;
}
}
void UploadNative(const l2::LightPixels& pixels, double texture, unsigned first) {
    auto& item = Find(texture);
    std::lock_guard<std::mutex> lock(item.mutex);
    PrepareNative(item, pixels, first);
    StageNative(item, pixels, first);
}
void UploadNative(l2::PixelTransaction& transaction, double texture, bool restore) {
    auto& item = Find(texture);
    transaction.validate();
    {
        std::lock_guard<std::mutex> lock(item.mutex);
        for (const auto& update : transaction.updates()) PrepareNative(item, *update.next, update.first);
    }
    auto stage = [&](const std::shared_ptr<const l2::LightPixels>& pixels, unsigned first) {
        std::lock_guard<std::mutex> lock(item.mutex);
        // A rollback after Flush also needs fresh pending rows.
        for (const auto& span : NativeSpans(*pixels, first)) item.image.prepare(span);
        StageNative(item, *pixels, first);
    };
    if (restore) transaction.restore(stage, [] { Flush(); });
    else transaction.draw(stage, [] { Flush(); });
}
}
