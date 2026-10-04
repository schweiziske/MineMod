#include "atlas_sprite_bridge.h"
#include "atlas_sprite.h"
#include "atlas_texture.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <unordered_map>

namespace mcmesh::atlassprite {
namespace {
using namespace GarrysMod::Lua;
constexpr size_t kBudget = size_t(512) * 1024 * 1024;
std::unordered_map<uint64_t, atlas::Sprite> sprites;
uint64_t sequence = 0;
size_t resident = 0, peak = 0;
int Fail(ILuaBase* lua, const char* reason) { lua->PushNil(); lua->PushString(reason); return 2; }
int Integer(ILuaBase* lua, int index, int minimum, int maximum) {
    if (!lua->IsType(index, Type::Number)) throw std::runtime_error("atlas_sprite_expected_integer");
    double n = lua->GetNumber(index);
    if (!std::isfinite(n) || n != std::floor(n) || n < minimum || n > maximum)
        throw std::runtime_error("atlas_sprite_integer_range");
    return int(n);
}
int Field(ILuaBase* lua, const char* name, int minimum, int maximum) {
    lua->GetField(2, name);
    int n = Integer(lua, -1, minimum, maximum); lua->Pop(); return n;
}
auto Find(ILuaBase* lua) {
    if (!lua->IsType(1, Type::Number)) return sprites.end();
    double n = lua->GetNumber(1);
    if (!std::isfinite(n) || n < 1 || n > 9007199254740991.0 || n != std::floor(n)) return sprites.end();
    return sprites.find(uint64_t(n));
}
void Number(ILuaBase* lua, const char* key, double n) { lua->PushNumber(n); lua->SetField(-2, key); }
}
int Create(ILuaBase* lua) {
    const int stack = lua->Top();
    try {
        if (!lua->IsType(1, Type::String) || !lua->IsType(2, Type::Table)) return Fail(lua, "atlas_sprite_arguments");
        if (sprites.size() >= 65536) return Fail(lua, "atlas_sprite_handle_budget");
        unsigned length = 0; const char* png = lua->GetString(1, &length);
        const int w = Field(lua, "width", 1, 16384), h = Field(lua, "height", 1, 16384);
        const int mip = Field(lua, "mip", 0, 14), pad = Field(lua, "padding", 0, 16384);
        const int strategy = Field(lua, "strategy", 0, 6);
        lua->GetField(2, "alphaBias");
        if (!lua->IsType(-1, Type::Number)) throw std::runtime_error("atlas_sprite_alpha_bias");
        const float bias = float(lua->GetNumber(-1)); lua->Pop();
        lua->GetField(2, "item");
        if (!lua->IsType(-1, Type::Bool)) throw std::runtime_error("atlas_sprite_item");
        const bool item = lua->GetBool(-1); lua->Pop();
        lua->GetField(2, "frames");
        if (!lua->IsType(-1, Type::Table)) throw std::runtime_error("atlas_sprite_frames");
        const int count = lua->ObjLen(-1), table = lua->Top();
        if (count < 1 || count > 65536) throw std::runtime_error("atlas_sprite_frame_budget");
        std::vector<int> frames; frames.reserve(count);
        for (int i = 1; i <= count; ++i) {
            lua->PushNumber(i); lua->GetTable(table);
            frames.push_back(Integer(lua, -1, 0, 65535)); lua->Pop();
        }
        lua->Pop();
        atlas::Image image; atlas::Sprite sprite; std::string error;
        if (!atlas::DecodePNG(std::string_view(png, length), image, error)) return Fail(lua, error.c_str());
        const int imageWidth=image.width, imageHeight=image.height;
        auto optionalImage=[&](const char* key, atlas::Image& decoded) {
            lua->GetField(2,key);
            if (lua->IsType(-1,Type::Nil)) { lua->Pop(); return false; }
            if (!lua->IsType(-1,Type::String)) throw std::runtime_error("atlas_material_png_argument");
            unsigned size=0; const char* bytes=lua->GetString(-1,&size);
            const bool ok=atlas::DecodePNG(std::string_view(bytes,size),decoded,error); lua->Pop();
            if (!ok) throw std::runtime_error(error);
            return true;
        };
        if (strategy>=5) {
            atlas::Image data,overlay,overlayData,result;
            const bool hasData=optionalImage("dataPNG",data), hasOverlay=optionalImage("overlayPNG",overlay);
            const bool hasOverlayData=optionalImage("overlayDataPNG",overlayData);
            const int bw=hasOverlay?Field(lua,"baseWidth",1,16384):w, bh=hasOverlay?Field(lua,"baseHeight",1,16384):h;
            const int ow=hasOverlay?Field(lua,"overlayWidth",1,16384):0, oh=hasOverlay?Field(lua,"overlayHeight",1,16384):0;
            if (hasOverlay && (w!=std::max(bw,ow) || h!=std::max(bh,oh))) return Fail(lua,"atlas_material_compose_size");
            if (!atlas::MaterialSheet(image,hasData?&data:nullptr,bw,bh,hasOverlay?&overlay:nullptr,
                hasOverlayData?&overlayData:nullptr,ow,oh,atlas::MipStrategy(strategy),result,error)) return Fail(lua,error.c_str());
            image=std::move(result);
        } else {
        atlas::Pixel tint{255,255,255,255};
        lua->GetField(2,"tint");
        if (!lua->IsType(-1,Type::Nil)) {
            if (!lua->IsType(-1,Type::Table)) throw std::runtime_error("atlas_sprite_tint");
            uint8_t* channels[]={&tint.r,&tint.g,&tint.b};
            const int table=lua->Top();
            for(int i=0;i<3;++i) { lua->PushNumber(i+1);lua->GetTable(table);*channels[i]=uint8_t(Integer(lua,-1,0,255));lua->Pop(); }
        }
        lua->Pop();
        lua->GetField(2,"overlayPNG");
        if (!lua->IsType(-1,Type::Nil)) {
            if (!lua->IsType(-1,Type::String)) throw std::runtime_error("atlas_sprite_overlay_png");
            unsigned bytes=0; const char* data=lua->GetString(-1,&bytes);
            atlas::Image overlay;
            if (!atlas::DecodePNG(std::string_view(data,bytes),overlay,error)) { lua->Pop(); return Fail(lua,error.c_str()); }
            lua->Pop();
            const int bw=Field(lua,"baseWidth",1,16384), bh=Field(lua,"baseHeight",1,16384);
            const int ow=Field(lua,"overlayWidth",1,16384), oh=Field(lua,"overlayHeight",1,16384);
            if (w!=std::max(bw,ow) || h!=std::max(bh,oh)) return Fail(lua,"atlas_sprite_compose_size");
            if (!atlas::ComposeSheets(image,bw,bh,&overlay,ow,oh,tint,error)) return Fail(lua,error.c_str());
        } else {
            lua->Pop();
            if (!atlas::ComposeSheets(image,w,h,nullptr,0,0,tint,error)) return Fail(lua,error.c_str());
        }
        }
        if (!atlas::CompileSprite(image, w, h, frames, mip, pad, atlas::MipStrategy(strategy), bias, item,
                kBudget - resident, sprite, error)) return Fail(lua, error.c_str());
        const uint64_t id = ++sequence; const size_t bytes = sprite.bytes;const bool constant=sprite.constant;
        sprites.emplace(id, std::move(sprite)); resident += bytes; peak = std::max(peak, resident);
        lua->CreateTable(); Number(lua, "id", double(id)); Number(lua, "bytes", double(bytes));
        lua->PushBool(constant);lua->SetField(-2,"constant");
        Number(lua, "imageWidth", imageWidth); Number(lua, "imageHeight", imageHeight);
        Number(lua, "width", w); Number(lua, "height", h); return 1;
    } catch (const std::exception& e) {
        if (lua->Top() > stack) lua->Pop(lua->Top() - stack);
        return Fail(lua, e.what());
    }
}
int Sample(ILuaBase* lua) {
    try {
        auto found = Find(lua);
        if (found == sprites.end()) return Fail(lua, "atlas_sprite_stale_handle");
        int a = Integer(lua, 2, 0, 65535), b = Integer(lua, 3, 0, 65535);
        if (!lua->IsType(4, Type::Number)) return Fail(lua, "atlas_sprite_fraction");
        const float fraction = float(lua->GetNumber(4));
        std::vector<atlas::Image> levels; std::string error;
        if (!atlas::SampleSprite(found->second, a, b, fraction, levels, error)) return Fail(lua, error.c_str());
        lua->CreateTable();
        for (size_t level = 0; level < levels.size(); ++level) {
            lua->PushNumber(double(level + 1));
            lua->PushString(reinterpret_cast<const char*>(levels[level].pixels.data()), unsigned(levels[level].pixels.size() * 4));
            lua->SetTable(-3);
        }
        return 1;
    } catch (const std::exception& e) { return Fail(lua, e.what()); }
}
int Release(ILuaBase* lua) {
    auto found = Find(lua);
    if (found == sprites.end()) return Fail(lua, "atlas_sprite_stale_handle");
    resident -= found->second.bytes; sprites.erase(found); lua->PushBool(true); return 1;
}
int UpdateTexture(ILuaBase* lua) {
    try {
        auto found=Find(lua);
        if(found==sprites.end()) return Fail(lua,"atlas_sprite_stale_handle");
        if(!lua->IsType(2,Type::Number)) return Fail(lua,"atlas_texture_stale_handle");
        const double texture=lua->GetNumber(2);
        if(!std::isfinite(texture) || texture<1 || texture>9007199254740991.0 || texture!=std::floor(texture))
            return Fail(lua,"atlas_texture_stale_handle");
        const int x=Integer(lua,3,0,16383),y=Integer(lua,4,0,16383);
        const int a=Integer(lua,5,0,65535),b=Integer(lua,6,0,65535);
        if(!lua->IsType(7,Type::Number)) return Fail(lua,"atlas_sprite_fraction");
        std::vector<atlas::Image> levels;std::string error;
        if(!atlas::SampleSprite(found->second,a,b,float(lua->GetNumber(7)),levels,error)
            || !atlastexture::QueueImages(uint64_t(texture),x,y,levels,error)) return Fail(lua,error.c_str());
        lua->PushBool(true);return 1;
    } catch(const std::exception& e) {return Fail(lua,e.what());}
}
int Stats(ILuaBase* lua) {
    lua->CreateTable(); Number(lua, "residentBytes", double(resident)); Number(lua, "peakBytes", double(peak));
    Number(lua, "count", double(sprites.size())); Number(lua, "budgetBytes", double(kBudget)); return 1;
}
void Shutdown() { sprites.clear(); resident = 0; }
}
