#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <wincodec.h>
#include <wrl/client.h>
#include "atlas_sprite.h"
#include "include/miniz/miniz.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <set>
#pragma comment(lib, "windowscodecs.lib")
#pragma comment(lib, "ole32.lib")

namespace mcmesh::atlas {
namespace {
using Microsoft::WRL::ComPtr;
constexpr size_t kPixels = 67108864;
uint32_t BE(const char* p) {
    const auto* b = reinterpret_cast<const uint8_t*>(p);
    return (uint32_t(b[0]) << 24) | (uint32_t(b[1]) << 16) | (uint32_t(b[2]) << 8) | b[3];
}
bool Fail(std::string& error, const char* reason) { error = reason; return false; }
// WIC handles palette, transparency, 16-bit and Adam7 PNGs. Validate framing
// and CRC ourselves: a decoder may otherwise tolerate truncated/damaged data.
bool ValidatePNG(std::string_view data, int& width, int& height, std::string& error) {
    if (data.size() < 45 || data.size() > 128 * 1024 * 1024
        || std::memcmp(data.data(), "\211PNG\r\n\032\n", 8)) return Fail(error, "atlas_png_header");
    bool header = false, pixels = false, endedPixels = false;
    for (size_t pos = 8; pos < data.size();) {
        if (data.size() - pos < 12) return Fail(error, "atlas_png_truncated_chunk");
        const size_t length = BE(data.data() + pos);
        if (length > data.size() - pos - 12) return Fail(error, "atlas_png_truncated_chunk");
        const char* type = data.data() + pos + 4;
        const std::string_view name(type, 4);
        if (mz_crc32(0, reinterpret_cast<const unsigned char*>(type), length + 4) != BE(type + 4 + length))
            return Fail(error, "atlas_png_crc");
        if (!header && name != "IHDR") return Fail(error, "atlas_png_ihdr_missing");
        if (name == "IHDR") {
            if (header || length != 13) return Fail(error, "atlas_png_ihdr_invalid");
            uint32_t w = BE(type + 4), h = BE(type + 8);
            if (!w || !h || w > 16384 || h > 16384 || uint64_t(w) * h > kPixels)
                return Fail(error, "atlas_png_pixel_budget");
            width = int(w); height = int(h); header = true;
        } else if (name == "IDAT") {
            if (endedPixels) return Fail(error, "atlas_png_idat_order");
            pixels = true;
        } else if (name == "IEND") {
            if (!pixels || length || pos + 12 != data.size()) return Fail(error, "atlas_png_iend_invalid");
            return true;
        } else {
            if (pixels) endedPixels = true;
            if (!(type[0] & 32) && name != "PLTE") return Fail(error, "atlas_png_unknown_critical_chunk");
        }
        pos += length + 12;
    }
    return Fail(error, "atlas_png_iend_missing");
}
struct Apartment {
    HRESULT result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~Apartment() { if (SUCCEEDED(result)) CoUninitialize(); }
};
}
bool DecodePNG(std::string_view encoded, Image& result, std::string& error) {
    error.clear(); int width, height;
    if (!ValidatePNG(encoded, width, height, error)) return false;
    Apartment apartment;
    if (FAILED(apartment.result) && apartment.result != RPC_E_CHANGED_MODE) return Fail(error, "atlas_png_com");
    ComPtr<IWICImagingFactory> factory;
    ComPtr<IWICStream> stream;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICFormatConverter> converter;
    if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))
        || FAILED(factory->CreateStream(&stream))
        || FAILED(stream->InitializeFromMemory(reinterpret_cast<BYTE*>(const_cast<char*>(encoded.data())), DWORD(encoded.size())))
        || FAILED(factory->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder))
        || FAILED(decoder->GetFrame(0, &frame))) return Fail(error, "atlas_png_decode");
    UINT w = 0, h = 0;
    if (FAILED(frame->GetSize(&w, &h)) || w != UINT(width) || h != UINT(height)) return Fail(error, "atlas_png_decode_dimensions");
    if (FAILED(factory->CreateFormatConverter(&converter))
        || FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone,
            nullptr, 0, WICBitmapPaletteTypeCustom))) return Fail(error, "atlas_png_rgba");
    Image candidate{width, height, {}};
    candidate.pixels.resize(size_t(width) * height);
    static_assert(sizeof(Pixel) == 4);
    if (FAILED(converter->CopyPixels(nullptr, width * 4, UINT(candidate.pixels.size() * 4),
        reinterpret_cast<BYTE*>(candidate.pixels.data())))) return Fail(error, "atlas_png_pixels");
    result = std::move(candidate); return true;
}

bool ComposeSheets(Image& base, int bw, int bh, const Image* overlay, int ow, int oh, Pixel tint, std::string& error) {
    auto valid = [](const Image& image, int w, int h) {
        return w > 0 && h > 0 && image.width >= w && image.height >= h && image.width % w == 0 && image.height % h == 0
            && image.pixels.size() == size_t(image.width) * image.height;
    };
    if (!valid(base,bw,bh) || (overlay && !valid(*overlay,ow,oh))) return Fail(error,"atlas_compose_dimensions");
    auto tinted = [tint](Pixel p) {
        p.r = uint8_t((int(p.r)*tint.r+127)/255); p.g = uint8_t((int(p.g)*tint.g+127)/255);
        p.b = uint8_t((int(p.b)*tint.b+127)/255); return p;
    };
    if (!overlay) {
        if (tint.r != 255 || tint.g != 255 || tint.b != 255) for (auto& p : base.pixels) p = tinted(p);
        return true;
    }
    const int bc=base.width/bw, oc=overlay->width/ow;
    const int bn=bc*(base.height/bh), on=oc*(overlay->height/oh);
    if (bn != on && bn != 1 && on != 1) return Fail(error,"atlas_compose_frame_count");
    const int w=std::max(bw,ow), h=std::max(bh,oh), n=std::max(bn,on);
    const int columns=std::min(n,16384/w), rows=(n+columns-1)/columns;
    if (h*rows>16384 || size_t(w)*columns*h*rows > kPixels) return Fail(error,"atlas_compose_pixel_budget");
    Image candidate{w*columns,h*rows,{}}; candidate.pixels.resize(size_t(candidate.width)*candidate.height);
    for (int frame=0;frame<n;++frame) {
        const int bf=bn==1?0:frame, of=on==1?0:frame;
        for (int y=0;y<h;++y) for (int x=0;x<w;++x) {
            const auto b=base.pixels[size_t((bf/bc)*bh+y*bh/h)*base.width+(bf%bc)*bw+x*bw/w];
            const auto a=tinted(overlay->pixels[size_t((of/oc)*oh+y*oh/h)*overlay->width+(of%oc)*ow+x*ow/w]);
            // Straight-alpha source-over; preserve hidden RGB for subsequent MC mip policy.
            const int alpha=int(a.a)*255+int(b.a)*(255-a.a);
            auto channel=[&](uint8_t av,uint8_t bv) {
                return alpha ? uint8_t((int(av)*a.a*255+int(bv)*b.a*(255-a.a)+alpha/2)/alpha) : bv;
            };
            candidate.pixels[size_t((frame/columns)*h+y)*candidate.width+(frame%columns)*w+x]=
                {channel(a.r,b.r),channel(a.g,b.g),channel(a.b,b.b),uint8_t((alpha+127)/255)};
        }
    }
    base=std::move(candidate); return true;
}

bool MaterialSheet(const Image& color, const Image* data, int bw, int bh,
    const Image* overlayColor, const Image* overlayData, int ow, int oh,
    MipStrategy strategy, Image& result, std::string& error) {
    auto valid=[](const Image& c,const Image* d,int w,int h) {
        return w>0 && h>0 && c.width%w==0 && c.height%h==0 && c.width>=w && c.height>=h
            && (!d || (d->width==c.width && d->height==c.height));
    };
    if (!valid(color,data,bw,bh) || (overlayColor && !valid(*overlayColor,overlayData,ow,oh)))
        return Fail(error,"atlas_material_dimensions");
    const Pixel neutral=strategy==MipStrategy::LabNormal?Pixel{128,128,255,255}:Pixel{0,10,0,255};
    if (!overlayColor) {
        result={color.width,color.height,{}};
        if (data) result.pixels=data->pixels; else result.pixels.assign(color.pixels.size(),neutral);
        return true;
    }
    const int bc=color.width/bw, oc=overlayColor->width/ow;
    const int bn=bc*(color.height/bh), on=oc*(overlayColor->height/oh);
    if (bn!=on && bn!=1 && on!=1) return Fail(error,"atlas_material_frame_count");
    const int w=std::max(bw,ow), h=std::max(bh,oh), n=std::max(bn,on);
    const int columns=std::min(n,16384/w), rows=(n+columns-1)/columns;
    if (h*rows>16384 || size_t(w)*columns*h*rows>kPixels) return Fail(error,"atlas_material_pixel_budget");
    Image candidate{w*columns,h*rows,{}}; candidate.pixels.resize(size_t(candidate.width)*candidate.height);
    for(int frame=0;frame<n;++frame) for(int y=0;y<h;++y) for(int x=0;x<w;++x) {
        const int bf=bn==1?0:frame, of=on==1?0:frame;
        const size_t bi=size_t((bf/bc)*bh+y*bh/h)*color.width+(bf%bc)*bw+x*bw/w;
        const size_t oi=size_t((of/oc)*oh+y*oh/h)*overlayColor->width+(of%oc)*ow+x*ow/w;
        const float a=overlayColor->pixels[oi].a/255.0f, b=color.pixels[bi].a/255.0f*(1-a), sum=a+b;
        const Pixel p[]={data?data->pixels[bi]:neutral,overlayData?overlayData->pixels[oi]:neutral};
        const float weights[]={sum>0?b/sum:1,sum>0?a/sum:0};
        candidate.pixels[size_t((frame/columns)*h+y)*candidate.width+(frame%columns)*w+x]=FilterMaterial(p,weights,2,strategy);
    }
    result=std::move(candidate); return true;
}

bool CompileSprite(const Image& image, int width, int height, const std::vector<int>& frames,
    int mip, int padding, MipStrategy strategy, float bias, bool item, size_t budget,
    Sprite& result, std::string& error) {
    error.clear();
    if (image.width < 1 || image.height < 1 || image.width > 16384 || image.height > 16384
        || image.pixels.size() != size_t(image.width) * image.height || width < 1 || height < 1
        || width > image.width || height > image.height || image.width % width || image.height % height
        || mip < 0 || mip > 14 || width % (1 << mip) || height % (1 << mip)
        || padding < 0 || padding > 16384 || padding % (1 << mip)
        || width + padding * 2 > 16384 || height + padding * 2 > 16384
        || frames.empty() || frames.size() > 65536 || !std::isfinite(bias)
        || strategy < MipStrategy::Auto || strategy > MipStrategy::LabSpecular)
        return Fail(error, "atlas_sprite_arguments");
    const int columns = image.width / width, count = columns * (image.height / height);
    const std::set<int> unique(frames.begin(), frames.end());
    if (*unique.begin() < 0 || *unique.rbegin() >= count) return Fail(error, "atlas_sprite_frame_index");
    size_t bytes = 0;
    for (int level = 0; level <= mip; ++level) bytes += size_t(width >> level) * (height >> level) * 4;
    if (bytes > budget / unique.size()) return Fail(error, "atlas_sprite_memory_budget");
    Sprite candidate{width, height, mip, padding, bytes * unique.size(), {}};
    candidate.strategy = strategy;
    for (int index : unique) {
        Image cropped{width, height, {}}; cropped.pixels.resize(size_t(width) * height);
        const int x = (index % columns) * width, y = (index / columns) * height;
        for (int row = 0; row < height; ++row)
            std::memcpy(cropped.pixels.data() + size_t(row) * width,
                image.pixels.data() + size_t(y + row) * image.width + x, size_t(width) * 4);
        if (!GenerateMips(std::move(cropped), mip, strategy, bias, item, candidate.frames[index], error)) return false;
    }
    const auto& first=candidate.frames.begin()->second[0].pixels;
    for(const auto& frame:candidate.frames) {
        const auto& pixels=frame.second[0].pixels;
        if(std::memcmp(first.data(),pixels.data(),first.size()*sizeof(Pixel))!=0) {candidate.constant=false;break;}
    }
    // A malformed/non-unit encoded normal can change when interpolated even
    // between identical frames. Keep that original behavior for such content.
    if(candidate.constant && candidate.frames.size()>1 && strategy==MipStrategy::LabNormal) {
        for(const auto& level:candidate.frames.begin()->second) for(const auto& pixel:level.pixels) {
            const Pixel inputs[]={pixel,pixel};const float weights[]={0.5f,0.5f};
            const Pixel filtered=FilterMaterial(inputs,weights,2,strategy);
            if(std::memcmp(&pixel,&filtered,sizeof(Pixel))!=0) {candidate.constant=false;break;}
        }
    }
    result = std::move(candidate); return true;
}

bool SampleSprite(const Sprite& sprite, int current, int next, float fraction,
    std::vector<Image>& result, std::string& error) {
    error.clear();
    const auto a = sprite.frames.find(current), b = sprite.frames.find(next);
    if (a == sprite.frames.end() || b == sprite.frames.end() || !std::isfinite(fraction) || fraction < 0 || fraction > 1)
        return Fail(error, "atlas_sprite_sample_arguments");
    std::vector<Image> candidate; candidate.reserve(sprite.mip + 1);
    for (int level = 0; level <= sprite.mip; ++level) {
        const auto& first = a->second[level]; const auto& second = b->second[level];
        const int pad = sprite.padding >> level;
        Image image{first.width + pad * 2, first.height + pad * 2, {}};
        image.pixels.resize(size_t(image.width) * image.height);
        for (int y = 0; y < first.height; ++y) for (int x = 0; x < first.width; ++x) {
            const auto p = first.pixels[size_t(y) * first.width + x], q = second.pixels[size_t(y) * first.width + x];
            auto blend = [fraction](uint8_t v, uint8_t w) { return uint8_t(std::floor(v + (int(w) - v) * fraction + 0.5f)); };
            Pixel value=p;
            if (current!=next && fraction>0) {
                if (sprite.strategy>=MipStrategy::LabNormal) {
                    const Pixel samples[]={p,q}; const float weights[]={1-fraction,fraction};
                    value=FilterMaterial(samples,weights,2,sprite.strategy);
                } else value={blend(p.r,q.r),blend(p.g,q.g),blend(p.b,q.b),blend(p.a,q.a)};
            }
            image.pixels[size_t(y + pad) * image.width + x + pad] = value;
        }
        // Extend the already interpolated edge without mixing adjacent sprites.
        for (int y = pad; y < image.height - pad; ++y) {
            auto* row = image.pixels.data() + size_t(y) * image.width;
            std::fill(row, row + pad, row[pad]);
            std::fill(row + image.width - pad, row + image.width, row[image.width - pad - 1]);
        }
        for (int y = 0; y < pad; ++y) {
            std::memcpy(image.pixels.data() + size_t(y) * image.width,
                image.pixels.data() + size_t(pad) * image.width, size_t(image.width) * 4);
            std::memcpy(image.pixels.data() + size_t(image.height - y - 1) * image.width,
                image.pixels.data() + size_t(image.height - pad - 1) * image.width, size_t(image.width) * 4);
        }
        candidate.push_back(std::move(image));
    }
    result = std::move(candidate); return true;
}
}
