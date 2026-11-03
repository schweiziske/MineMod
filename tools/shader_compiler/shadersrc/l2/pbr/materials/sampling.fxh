#ifndef MC_PBR_SAMPLING_INCLUDED
#define MC_PBR_SAMPLING_INCLUDED
#include "../../vanilla/materials/atlas.fxh"

// c17.xy magnitudes remain calibrated atlas dimensions. Negative X enables
// color interpolation; negative Y enables material interpolation. LOD uses
// squared derivatives, so flags do not change it or the legacy sampler ABI.
float3 mcSpatialNormal(float4 value)
{
    float2 xy = value.xy * 2.0f - 1.0f;
    return float3(xy, sqrt(saturate(1.0f - dot(xy, xy))));
}

float4 mcSpatialMaterial(float4 a, float4 b, float4 c, float4 d, float4 w, bool normal)
{
    if (normal)
    {
        float3 n = mcSpatialNormal(a)*w.x + mcSpatialNormal(b)*w.y
            + mcSpatialNormal(c)*w.z + mcSpatialNormal(d)*w.w;
        float lengthSquared = dot(n,n);
        float2 xy = lengthSquared > 1e-12f ? n.xy*rsqrt(max(lengthSquared,1e-12f)) : 0.0f;
        return mcAnimationBytes(float4(xy*0.5f+0.5f, a.zw*w.x+b.zw*w.y+c.zw*w.z+d.zw*w.w));
    }
    float4 r = 255.0f-floor(float4(a.r,b.r,c.r,d.r)*255.0f+0.5f);
    float4 g = floor(float4(a.g,b.g,c.g,d.g)*255.0f+0.5f);
    float4 blue = floor(float4(a.b,b.b,c.b,d.b)*255.0f+0.5f);
    float4 alpha = floor(float4(a.a,b.a,c.a,d.a)*255.0f+0.5f);
    float4 dielectric = 1.0f-step(230.0f,g);
    // Select the largest total category weight, not the largest single tap.
    // All dielectric F0s form one category; each encoded metal is separate.
    float selected = g.x, best = -1;
    [unroll] for (int i=0; i<4; ++i)
    {
        float4 group = max(dielectric*dielectric[i],1.0f-step(0.5f,abs(g-g[i])));
        float weight = dot(w,group);
        if (weight>best) { best=weight; selected=g[i]; }
    }
    float f0 = selected<230.0f ? dot(g*w,dielectric)/max(dot(w,dielectric),1e-8f) : selected;
    float4 pores = 1.0f-step(65.0f,blue);
    float poreWeight = dot(w,pores), sssWeight = dot(w,1.0f-pores);
    bool usePores = poreWeight>sssWeight || (poreWeight==sssWeight && blue.x<65.0f);
    float poreSSS = usePores ? dot(blue*w,pores)/max(poreWeight,1e-8f)
        : dot(blue*w,1.0f-pores)/max(sssWeight,1e-8f);
    float emission = dot(alpha*(1.0f-step(254.5f,alpha)),w);
    return mcAnimationBytes(float4(255.0f-sqrt(dot(r*r,w)),f0,poreSSS,
        emission>0.0f ? emission : 255.0f)/255.0f);
}

// kind: 0 linear color/alpha, 1 sRGB color, 2 Lab normal, 3 Lab specular.
float4 mcSpatialTexel(sampler2D source, float2 uv, float lod, int kind)
{
    float4 value = tex2Dlod(source,float4(uv,0,lod));
    if (kind==1 && MCResourceAnimation.z>0)
        value.rgb=lerp(value.rgb/12.92f,pow((value.rgb+0.055f)/1.055f,2.4f),step(0.04045f,value.rgb));
    return value;
}

float4 mcSpatialLevel(sampler2D source, float2 uv, float level, float offset, int kind)
{
    float2 size = MCResourceAtlas.xy*exp2(-level);
    float2 position = uv*size-0.5f, f = frac(position);
    float2 first = (floor(position)+0.5f)/size, pixel = 1.0f/size;
    float4 a = mcSpatialTexel(source,first,level+offset,kind);
    float4 b = mcSpatialTexel(source,first+float2(pixel.x,0),level+offset,kind);
    float4 c = mcSpatialTexel(source,first+float2(0,pixel.y),level+offset,kind);
    float4 d = mcSpatialTexel(source,first+pixel,level+offset,kind);
    float4 weights = float4((1-f.x)*(1-f.y),f.x*(1-f.y),(1-f.x)*f.y,f.x*f.y);
    if (kind>=2) return mcSpatialMaterial(a,b,c,d,weights,kind==2);
    return a*weights.x+b*weights.y+c*weights.z+d*weights.w;
}

float4 mcSpatialMix(float4 a, float4 b, float weight, int kind)
{
    if (kind==2) return mcAnimationNormal(a,b,weight);
    if (kind==3) return mcAnimationSpecular(a,b,weight);
    return lerp(a,b,weight);
}

float4 mcSpatialFrameLevel(sampler2D source, MCAnimationAddress frames, float level, float offset, int kind)
{
    float4 first = mcSpatialLevel(source,frames.first,level,offset,kind);
    [branch] if (frames.weight>0)
        return mcSpatialMix(first,mcSpatialLevel(source,frames.second,level,offset,kind),frames.weight,kind);
    return first;
}

float4 mcSpatialSample(sampler2D source, float2 uv, float lod, int kind)
{
    MCAnimationAddress frames = mcResourceFrames(source,uv,kind==1);
    float colorOffset = 0.5f*log2(MCResourceFootprint.z);
    float offset = colorOffset + (kind>=2 ? MCResourceFootprint.w : 0.0f);
    float physical = clamp(lod-offset,0.0f,MCResourceAtlas.z-colorOffset);
    float level = floor(physical), weight = physical-level;
    float4 first = mcSpatialFrameLevel(source,frames,level,offset,kind);
    [branch] if (weight>0)
        return mcSpatialMix(first,mcSpatialFrameLevel(source,frames,level+1.0f,offset,kind),weight,kind);
    return first;
}

float4 mcPBRColor(sampler2D source, float2 uv, float lod, bool srgb)
{
    [branch] if (MCResourceFootprint.x<0)
        return mcSpatialSample(source,uv,lod,srgb ? 1 : 0);
    return mcResourceColor(source,mcResourceAtlasUV(uv,lod),lod,srgb);
}

float4 mcPBRMaterial(sampler2D source, float2 uv, float lod, bool normal)
{
    [branch] if (MCResourceFootprint.y<0 && MCResourceFootprint.w>=-50)
        return mcSpatialSample(source,uv,lod,normal ? 2 : 3);
    return mcResourceMaterial(source,mcResourceAtlasUV(uv,lod),lod,normal);
}
#endif
