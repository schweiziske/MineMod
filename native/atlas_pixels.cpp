#include "atlas_pixels.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>

namespace mcmesh::atlas {
namespace {
struct ColorTables {
    std::array<int, 256> linear{};
    std::array<uint8_t, 1024> srgb{};
    ColorTables() {
        for (int i = 0; i < 256; ++i) {
            const float x = i / 255.0f;
            const float value = x >= 0.04045f ? float(std::pow((x + 0.055) / 1.055, 2.4)) : x / 12.92f;
            linear[i] = int(std::floor(value * 1023.0f + 0.5f));
        }
        for (int i = 0; i < 1024; ++i) {
            const float x = i / 1023.0f;
            const float value = x >= 0.0031308f ? float(1.055 * std::pow(x, 0.4166666666666667) - 0.055) : 12.92f * x;
            srgb[i] = uint8_t(std::floor(value * 255.0f + 0.5f));
        }
    }
};
const ColorTables tables;
uint8_t Mean(uint8_t a, uint8_t b, uint8_t c, uint8_t d) {
    return tables.srgb[(tables.linear[a] + tables.linear[b] + tables.linear[c] + tables.linear[d]) / 4];
}
Pixel Blend(const Pixel& a, const Pixel& b, const Pixel& c, const Pixel& d, bool dark) {
    if (!dark) return {Mean(a.r,b.r,c.r,d.r),Mean(a.g,b.g,c.g,d.g),Mean(a.b,b.b,c.b,d.b),uint8_t((int(a.a)+b.a+c.a+d.a)/4)};
    float r=0,g=0,blue=0,alpha=0;
    for (const Pixel* p : {&a,&b,&c,&d}) if (p->a) {
        r += tables.linear[p->r] / 1023.0f; g += tables.linear[p->g] / 1023.0f;
        blue += tables.linear[p->b] / 1023.0f; alpha += tables.linear[p->a] / 1023.0f;
    }
    return {tables.srgb[int((r/4)*1023.0f)],tables.srgb[int((g/4)*1023.0f)],
        tables.srgb[int((blue/4)*1023.0f)],tables.srgb[int((alpha/4)*1023.0f)]};
}
void Solidify(Image& image, bool dark) {
    if (dark) {
        Pixel darkest{255,255,255,255}; int minimum=std::numeric_limits<int>::max();
        for (int x=0;x<image.width;++x) for (int y=0;y<image.height;++y) {
            const auto p=image.pixels[size_t(y)*image.width+x];
            const int brightness=int(p.r)+p.g+p.b;
            if (p.a && brightness<minimum) { minimum=brightness; darkest=p; }
        }
        Pixel fill{uint8_t(3*int(darkest.r)/4),uint8_t(3*int(darkest.g)/4),uint8_t(3*int(darkest.b)/4),0};
        for (auto& p:image.pixels) if (!p.a) p=fill;
        return;
    }
    std::vector<int> distance(image.pixels.size(),std::numeric_limits<int>::max());
    std::vector<Pixel> nearest(image.pixels.size());
    std::vector<int> queue; queue.reserve(image.pixels.size());
    // Java's x-outer scan and direction order decide equal-distance ties.
    for (int x=0;x<image.width;++x) for (int y=0;y<image.height;++y) {
        const int index=y*image.width+x;
        if (image.pixels[index].a) { distance[index]=0; nearest[index]=image.pixels[index]; queue.push_back(index); }
    }
    constexpr int directions[4][2]={{1,0},{-1,0},{0,1},{0,-1}};
    for (size_t head=0;head<queue.size();++head) {
        const int current=queue[head], x=current%image.width, y=current/image.width;
        for (const auto& direction:directions) {
            const int nx=x+direction[0],ny=y+direction[1], index=ny*image.width+nx;
            if (nx>=0 && ny>=0 && nx<image.width && ny<image.height && distance[index]>distance[current]+1) {
                distance[index]=distance[current]+1; nearest[index]=nearest[current]; queue.push_back(index);
            }
        }
    }
    for (size_t i=0;i<image.pixels.size();++i) if (!image.pixels[i].a) {
        image.pixels[i]=nearest[i]; image.pixels[i].a=0;
    }
}
float Coverage(const Image& image,float reference,float scale) {
    float coverage=0;
    for(int y=0;y<image.height-1;++y) for(int x=0;x<image.width-1;++x) {
        const size_t index=size_t(y)*image.width+x;
        const float a=std::clamp((image.pixels[index].a/255.0f)*scale,0.0f,1.0f);
        const float b=std::clamp((image.pixels[index+1].a/255.0f)*scale,0.0f,1.0f);
        const float c=std::clamp((image.pixels[index+image.width].a/255.0f)*scale,0.0f,1.0f);
        const float d=std::clamp((image.pixels[index+image.width+1].a/255.0f)*scale,0.0f,1.0f);
        float count=0;
        for(int sy=0;sy<4;++sy) {
            const float fy=(sy+0.5f)/4;
            for(int sx=0;sx<4;++sx) {
                const float fx=(sx+0.5f)/4;
                const float alpha=a*(1-fx)*(1-fy)+b*fx*(1-fy)+c*(1-fx)*fy+d*fx*fy;
                if(alpha>reference) ++count;
            }
        }
        coverage+=count/16;
    }
    return coverage/float((image.width-1)*(image.height-1));
}
void ScaleAlpha(Image& image,float desired,float reference,float bias) {
    float minimum=0,maximum=4,scale=1,bestScale=1,bestError=std::numeric_limits<float>::max();
    for(int i=0;i<5;++i) {
        const float current=Coverage(image,reference,scale), error=std::abs(current-desired);
        if(error<bestError) { bestError=error; bestScale=scale; }
        if(current<desired) minimum=scale;
        else { if(!(current>desired)) break; maximum=scale; }
        scale=(minimum+maximum)*0.5f;
    }
    for(auto& p:image.pixels) p.a=uint8_t(std::floor(std::clamp((p.a/255.0f)*bestScale+bias+0.025f,0.0f,1.0f)*255));
}
}
Pixel FilterMaterial(const Pixel* pixels, const float* weights, int count, MipStrategy strategy) {
    auto byte = [](float x) { return uint8_t(std::clamp(std::floor(x + 0.5f), 0.0f, 255.0f)); };
    if (strategy == MipStrategy::LabNormal) {
        float x=0, y=0, z=0, ao=0, height=0;
        for (int i=0;i<count;++i) {
            const auto p=pixels[i]; const float w=weights[i];
            const float nx=p.r*(2.0f/255)-1, ny=p.g*(2.0f/255)-1;
            x+=w*nx; y+=w*ny; z+=w*std::sqrt(std::max(0.0f,1-nx*nx-ny*ny));
            ao+=w*p.b; height+=w*p.a;
        }
        const float length=std::sqrt(x*x+y*y+z*z);
        if (length>1e-8f) { x/=length; y/=length; } else { x=0; y=0; }
        return {byte((x+1)*127.5f),byte((y+1)*127.5f),byte(ao),byte(height)};
    }
    float rough=0, emission=0;
    // Dielectrics form one continuous group; each encoded metal is its own.
    int selected=0; float best=-1;
    for (int i=0;i<count;++i) {
        float weight=0;
        for (int j=0;j<count;++j)
            if ((pixels[i].g<230 && pixels[j].g<230) || pixels[i].g==pixels[j].g) weight+=weights[j];
        if (weight>best) { selected=i; best=weight; }
    }
    float f0=0, f0Weight=0, poreWeight=0, sssWeight=0, pore=0, sss=0;
    for (int i=0;i<count;++i) {
        const auto p=pixels[i]; const float w=weights[i], r=255.0f-p.r;
        rough+=w*r*r; emission+=w*(p.a==255?0:p.a);
        if (p.g<230) { f0+=w*p.g; f0Weight+=w; }
        if (p.b<65) { pore+=w*p.b; poreWeight+=w; } else { sss+=w*p.b; sssWeight+=w; }
    }
    const uint8_t green=pixels[selected].g<230 ? byte(f0/std::max(f0Weight,1e-8f)) : pixels[selected].g;
    const bool usePores=poreWeight>sssWeight || (poreWeight==sssWeight && pixels[0].b<65);
    return {byte(255-std::sqrt(rough)),green,
        usePores?byte(pore/std::max(poreWeight,1e-8f)):byte(sss/std::max(sssWeight,1e-8f)),
        emission>0?byte(emission):uint8_t(255)};
}
bool GenerateMips(Image image,int mip,MipStrategy strategy,float alphaBias,bool item,
    std::vector<Image>& result,std::string& error) {
    error.clear();
    if(image.width<1 || image.height<1 || image.width>16384 || image.height>16384
        || image.pixels.size()!=size_t(image.width)*image.height || mip<0 || mip>14
        || image.width%(1<<mip) || image.height%(1<<mip) || !std::isfinite(alphaBias)
        || strategy<MipStrategy::Auto || strategy>MipStrategy::LabSpecular) {
        error="invalid_atlas_mip_input"; return false;
    }
    if(strategy==MipStrategy::Auto) {
        // Transparency.hasTransparent refers to fully transparent pixels.
        const bool transparent=std::any_of(image.pixels.begin(),image.pixels.end(),[](const Pixel& p){return p.a==0;});
        strategy=transparent ? MipStrategy::Cutout : MipStrategy::Mean;
    }
    const bool cutout=strategy==MipStrategy::Cutout || strategy==MipStrategy::StrictCutout || strategy==MipStrategy::DarkCutout;
    if(!item && cutout) Solidify(image,strategy==MipStrategy::DarkCutout);
    const float reference=strategy==MipStrategy::StrictCutout ? 0.3f : 0.5f;
    const float original=cutout ? Coverage(image,reference,1) : 0;
    std::vector<Image> candidate;
    candidate.reserve(size_t(mip)+1); candidate.push_back(std::move(image));
    for(int level=1;level<=mip;++level) {
        const Image& previous=candidate.back();
        Image next{previous.width/2,previous.height/2,{}};
        next.pixels.resize(size_t(next.width)*next.height);
        for(int y=0;y<next.height;++y) for(int x=0;x<next.width;++x) {
            const size_t i=size_t(y*2)*previous.width+x*2;
            if (strategy>=MipStrategy::LabNormal) {
                const Pixel p[]={previous.pixels[i],previous.pixels[i+1],previous.pixels[i+previous.width],previous.pixels[i+previous.width+1]};
                const float weights[]={0.25f,0.25f,0.25f,0.25f};
                next.pixels[size_t(y)*next.width+x]=FilterMaterial(p,weights,4,strategy);
            } else next.pixels[size_t(y)*next.width+x]=Blend(previous.pixels[i],previous.pixels[i+1],
                previous.pixels[i+previous.width],previous.pixels[i+previous.width+1],strategy==MipStrategy::DarkCutout);
        }
        if(cutout) ScaleAlpha(next,original,reference,alphaBias);
        candidate.push_back(std::move(next));
    }
    result=std::move(candidate); return true;
}
}
