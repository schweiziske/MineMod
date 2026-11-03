#ifndef MC_RESOURCE_ANIMATION_INCLUDED
#define MC_RESOURCE_ANIMATION_INCLUDED
// Row two of invviewprojmat; row one remains available to block SSR.
float4 MCResourceAnimation : register(c16); // table origin XY, row width, elapsed ticks
#include "../../pbr/materials/animation.fxh"
float4 mcAnimationBytes(sampler2D source, float index, bool srgb)
{
    float row = floor(index/MCResourceAnimation.z);
    float2 p = float2(index-row*MCResourceAnimation.z,row);
    float2 uv = (MCResourceAnimation.xy+p+0.5f)/MCResourceAtlas.xy;
    float4 raw = tex2Dlod(source,float4(uv,0,0));
    return floor(saturate(raw)*255.0f+0.5f);
}
float mcAnimationInteger(float4 b) { return dot(b,float4(1,256,65536,16777216)); }
float2 mcAnimationPair(float4 b) { return b.xz+b.yw*256.0f; }
float mcAnimationFloat(float4 b)
{
    float sign = step(128.0f,b.w);
    float high = floor(b.z/128.0f);
    float exponent = (b.w-sign*128.0f)*2.0f+high;
    float mantissa = b.x+b.y*256.0f+(b.z-high*128.0f)*65536.0f;
    return (exponent>0.0f ? 1.0f+mantissa/8388608.0f : 0.0f)
        * exp2(exponent-127.0f) * (1.0f-sign*2.0f);
}
struct MCAnimationAddress { float2 first; float2 second; float weight; };
MCAnimationAddress mcResourceFrames(sampler2D source, float2 uv, bool srgb)
{
    MCAnimationAddress result;
    result.first=uv; result.second=uv; result.weight=0;
    [branch] if (MCResourceAnimation.z>0.0f)
    {
        float cell=exp2(MCResourceAtlas.z)*rsqrt(MCResourceFootprint.z);
        float2 grid=floor(uv*MCResourceAtlas.xy/cell);
        float pointer=mcAnimationInteger(mcAnimationBytes(source,grid.y*(MCResourceAtlas.x/cell)+grid.x,srgb));
        [branch] if (pointer>0.0f)
        {
            float2 origin=mcAnimationPair(mcAnimationBytes(source,pointer,srgb));
            float sequence=mcAnimationInteger(mcAnimationBytes(source,pointer+2,srgb));
            float count=mcAnimationInteger(mcAnimationBytes(source,pointer+3,srgb));
            float duration=mcAnimationFloat(mcAnimationBytes(source,pointer+4,srgb));
            float tick=frac(MCResourceAnimation.w/abs(duration))*abs(duration);
            float low=0, high=count-1;
            [loop] while (low<high)
            {
                float middle=floor((low+high+1)*0.5f);
                float start=mcAnimationFloat(mcAnimationBytes(source,sequence+middle*4,srgb));
                if (start<=tick) low=middle; else high=middle-1;
            }
            float at=sequence+low*4;
            float start=mcAnimationFloat(mcAnimationBytes(source,at,srgb));
            float time=mcAnimationFloat(mcAnimationBytes(source,at+1,srgb));
            result.first=uv+(mcAnimationPair(mcAnimationBytes(source,at+2,srgb))-origin)/MCResourceAtlas.xy;
            result.second=uv+(mcAnimationPair(mcAnimationBytes(source,at+3,srgb))-origin)/MCResourceAtlas.xy;
            result.weight=duration>0.0f ? floor(saturate((tick-start)/time)*1000.0f)/1000.0f : 0;
        }
    }
    return result;
}
float4 mcResourceColor(sampler2D source, float2 uv, float lod, bool srgb)
{
    MCAnimationAddress a=mcResourceFrames(source,uv,srgb);
    float4 first=tex2Dlod(source,float4(a.first,0,lod));
    // Runtime atlases contain raw metadata: disable hardware sRGB for the atlas,
    // and decode only actual color samples. Legacy atlases keep hardware sRGB.
    if (srgb && MCResourceAnimation.z>0)
        first.rgb=lerp(first.rgb/12.92f,pow((first.rgb+0.055f)/1.055f,2.4f),step(0.04045f,first.rgb));
    [branch] if (a.weight>0)
    {
        float4 second=tex2Dlod(source,float4(a.second,0,lod));
        if (srgb && MCResourceAnimation.z>0)
            second.rgb=lerp(second.rgb/12.92f,pow((second.rgb+0.055f)/1.055f,2.4f),step(0.04045f,second.rgb));
        return lerp(first,second,a.weight);
    }
    return first;
}
float4 mcResourceMaterialLevel(sampler2D source, MCAnimationAddress a, float level, float offset, bool normal)
{
    // Sample one physical mip at texel centres. Encoded material categories
    // must never pass through hardware bilinear or trilinear interpolation.
    float2 size=MCResourceAtlas.xy*exp2(-level);
    float2 firstUV=(floor(a.first*size)+0.5f)/size;
    float4 first=tex2Dlod(source,float4(firstUV,0,level+offset));
    [branch] if (a.weight>0)
    {
        float2 secondUV=(floor(a.second*size)+0.5f)/size;
        float4 second=tex2Dlod(source,float4(secondUV,0,level+offset));
        if (normal) return mcAnimationNormal(first,second,a.weight);
        return mcAnimationSpecular(first,second,a.weight);
    }
    return first;
}
float4 mcResourceMaterial(sampler2D source, float2 uv, float lod, bool normal)
{
    // Legacy atlases and color-only generations have no material frame table.
    [branch] if (MCResourceAnimation.z<=0)
        return tex2Dlod(source,float4(uv,0,lod));
    [branch] if (MCResourceFootprint.w < -50)
        return tex2Dlod(source,float4(uv,0,0));
    MCAnimationAddress a=mcResourceFrames(source,uv,false);
    float colorOffset=0.5f*log2(MCResourceFootprint.z);
    float offset=colorOffset+MCResourceFootprint.w;
    float physicalLod=clamp(lod-offset,0.0f,MCResourceAtlas.z-colorOffset);
    float level=floor(physicalLod);
    float weight=physicalLod-level;
    // Frame mips are generated independently: interpolate time within each
    // level first, then blend adjacent levels using the same channel semantics.
    float4 first=mcResourceMaterialLevel(source,a,level,offset,normal);
    [branch] if (weight>0)
    {
        float4 second=mcResourceMaterialLevel(source,a,level+1.0f,offset,normal);
        if (normal) return mcAnimationNormal(first,second,weight);
        return mcAnimationSpecular(first,second,weight);
    }
    return first;
}
#endif
