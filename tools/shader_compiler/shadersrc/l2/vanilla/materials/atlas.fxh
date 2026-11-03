#ifndef MC_RESOURCE_ATLAS_INCLUDED
#define MC_RESOURCE_ATLAS_INCLUDED
// Last row of $invviewprojmat. Classic atlases bind maxMip=0; only validated
// sprite mips enable minification. Unused Source tail levels are never sampled.
float4 MCResourceAtlas : register(c18); // width, height, maximum mip, inverse area
// CPU calibration folds the measured sampler LOD offset into these dimensions
// and the lower/upper LOD bounds; no additional per-pixel arithmetic is needed.
float4 MCResourceFootprint : register(c17); // biased width/height, minimum squared footprint, PBR LOD delta
float mcResourceAtlasGrad(float2 uvx, float2 uvy)
{
    float2 dx = uvx * MCResourceFootprint.xy;
    float2 dy = uvy * MCResourceFootprint.xy;
    // The logarithm's argument is at least one, so its result is nonnegative.
    return min(0.5f * log2(max(max(dot(dx,dx),dot(dy,dy)),MCResourceFootprint.z)),MCResourceAtlas.z);
}
float mcResourceAtlasLod(float2 uv) { return mcResourceAtlasGrad(ddx(uv),ddy(uv)); }
float2 mcResourceAtlasUV(float2 uv, float lod)
{
    // Source POINTSAMPLE disables the mip sampler. Snap to base texel centres
    // for exact magnified pixels, then use the independently calculated LOD
    // for minification. The lower mips retain their normal within-level filter.
    float2 inverseSize = MCResourceAtlas.yx * MCResourceAtlas.w;
    return uv + (0.5f - frac(uv * MCResourceAtlas.xy)) * inverseSize;
}
#include "animation.fxh"
#endif
