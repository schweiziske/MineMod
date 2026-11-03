#ifndef MC_PBR_SHADOW_INCLUDED
#define MC_PBR_SHADOW_INCLUDED
#include "shadow_layout.fxh"
// 2x4 atlas: ordinary opaque, water, sky entrance, interior opaque.
// RG = little-endian 16-bit depth; water BA = red/blue sunlight / 4.
// Clear depth 65535 means no interface. Offset includes the half texel.
float4 mcShadowTexel(float2 uv, float2 offset)
{
    float2 address = uv * 0.5f + offset;
    address.y *= 2.0f * MC_SHADOW_ROW_SCALE;
    return tex2Dlod(MCShadowDepth, float4(address, 0, 0));
}

// Choose per PCF tap, before filtering, so sky edges cannot erase local shadows.
float mcShadowReceiverDepth(float2 uv, float2 offset, float reference)
{
    const float2 bytes = float2(255.0f, 65280.0f);
#if MC_SKY_BOUNDARY
    float entrance = dot(mcShadowTexel(uv, offset + float2(0, 1)).rg, bytes);
    float interior = step(entrance + 0.5f, reference) * (1.0f - step(65535.0f, entrance));
    float ordinaryDepth = dot(mcShadowTexel(uv, offset).rg, bytes);
    [branch] if (interior > 0.5f)
        return dot(mcShadowTexel(uv, offset + float2(0, 1.5f)).rg, bytes);
    return ordinaryDepth;
#else
    return dot(mcShadowTexel(uv, offset).rg, bytes);
#endif
}

// Empty water texels contain clear BA, not neutral light.
float2 mcWaterLightTexel(float2 uv, float2 offset)
{
    float4 wet = mcShadowTexel(uv, offset);
    return min(wet.r, wet.g) == 1.0f ? 0.25f : wet.ba;
}

// reference and depthGradient are in 16-bit depth steps.
float mcShadowPCF(float2 uv, float2 offset, float reference, float2 depthGradient)
{
    float texel = MCShadowRemap.w;
    // POINTSAMPLE is mandatory: interpolate comparison results, not RG depth.
    // Source's DX9 ortho raster samples integer pixel positions; offset adds
    // the half texel only to texture addresses, keeping the receiver plane in
    // raster UV. Receivers stay inside [0, 1]: the near cascade fades out at
    // 0.94 and the far border fade hides the clamped outermost texel.
    float2 weight = frac(uv / texel);
    float2 low = uv - weight * texel;
    float reference00 = reference - dot(depthGradient, weight) * texel;
    float2 delta = depthGradient * texel;
    float4 references = reference00 + float4(0, delta.x, delta.y, delta.x + delta.y);
    float4 stored = float4(mcShadowReceiverDepth(low, offset, references.x),
        mcShadowReceiverDepth(low + float2(texel, 0), offset, references.y),
        mcShadowReceiverDepth(low + float2(0, texel), offset, references.z),
        mcShadowReceiverDepth(low + texel, offset, references.w));
    float4 visible = step(references, stored);
    float top = lerp(visible.x, visible.y, weight.x);
    float bottom = lerp(visible.z, visible.w, weight.x);
    return lerp(top, bottom, weight.y);
}

// Center plus eight equally spaced points on a one-texel circle, each bilinear PCF.
// Merge their overlapping comparisons: 16 unique grid taps instead of 9 * 4.
float mcShadowRadialPCF(float2 uv, float2 offset, float reference, float2 depthGradient)
{
    float texel = MCShadowRemap.w;
    float2 grid = uv / texel;
    float2 phase = frac(grid);
    float2 base = floor(grid) - 1.0f;
    const float diagonal = 0.7071067812f;
    float visibility = 0;
    [loop] for (int tap = 0; tap < 16; ++tap)
    {
        float row = floor(float(tap) * 0.25f);
        float2 corner = float2(float(tap) - row * 4.0f, row);
        float2 distance = corner - 1.0f - phase;
        float2 center = saturate(1.0f - abs(distance));
        float2 axial = saturate(1.0f - abs(distance - 1.0f)) + saturate(1.0f - abs(distance + 1.0f));
        float2 diagonalPair = saturate(1.0f - abs(distance - diagonal)) + saturate(1.0f - abs(distance + diagonal));
        // Center weight 1/4; each of the eight ring points has weight 3/32.
        float weight = 0.25f * center.x * center.y
            + (3.0f / 32.0f) * (dot(axial, center.yx) + diagonalPair.x * diagonalPair.y);
        float2 address = clamp((base + corner) * texel, 0.0f, 1.0f - texel);
        // The same texel must use the same plane depth in every logical disk sample.
        float tapReference = reference + dot(depthGradient, address - uv);
        float stored = mcShadowReceiverDepth(address, offset, tapReference);
        visibility += weight * step(tapReference, stored);
    }
    return saturate(visibility);
}

// Only opaque visibility uses the radial kernel. Caustic BA retains its original
// four-tap interpolation and nearest-depth wet/dry gate; RG always stays POINT.
float2 mcShadowWaterPCF(float2 uv, float2 offset, float reference, float2 depthGradient)
{
    float texel = MCShadowRemap.w;
    float2 weight = frac(uv / texel);
    float2 low = uv - weight * texel;
    float2 waterOffset = offset + float2(0, 0.5f);
    float2 filtered = 0;
    float2 corner = 0;
    [loop] for (int tap = 0; tap < 4; ++tap)
    {
        float2 address = low + corner * texel;
        float2 weights = lerp(1.0f - weight, weight, corner);
        float2 light = mcWaterLightTexel(address, waterOffset);
        filtered += light * (weights.x * weights.y);
        corner = float2(1.0f - corner.y, corner.x); // 00, 10, 11, 01.
    }
    float waterDepth = dot(mcShadowTexel(uv, waterOffset).rg, float2(255.0f, 65280.0f));
#if MC_SKY_BOUNDARY
    float skyDepth = dot(mcShadowTexel(uv, offset + float2(0, 1)).rg, float2(255.0f, 65280.0f));
    // Keep the original nearest-depth wet/dry gate, including empty depth 65535.
    // An exterior water interface must not tint sunlight entering through sky.
    float exteriorWater = step(skyDepth + 0.5f, reference) * step(waterDepth, skyDepth)
        * (1.0f - step(65535.0f, skyDepth));
#else
    const float exteriorWater = 0;
#endif
    float2 transmission = reference >= waterDepth + 2.0f && exteriorWater < 0.5f ? filtered * 4.0f : 1.0f;
    return transmission * mcShadowRadialPCF(uv, offset, reference, depthGradient);
}

// Direct sunlight reaching a receiver: shadow visibility, times the light
// pattern of the water surfaces in front of it when caustics is set. Water
// itself must not take the pattern of its own surface.
float3 mcSunLight(float3 position, float3 geometricNormal, uniform bool caustics)
{
    // Strength zero is handled by the final lerp, avoiding an SM3 return branch.
    float4 world = float4(position, 1);
    float2 nearUV = float2(dot(MCShadowU, world), dot(MCShadowV, world));
    float2 farUV = nearUV * MCShadowRemap.x + MCShadowRemap.yz;
    float depth = dot(MCShadowZ, world);
    float farEdge = max(abs(farUV.x * 2 - 1), abs(farUV.y * 2 - 1));
    // Positive only inside every boundary. A minimum avoids SM3's expensive
    // boolean-OR expansion without changing the inclusive outside test.
    [branch] if (min(1.0f - farEdge, min(depth, 1.0f - depth)) <= 0.0f) return 1.0f;
    float bias = MCQuadParams.x * (1.0f + 2.0f * (1.0f - saturate(dot(geometricNormal, MCSunDirection.xyz))));
    float nearEdge = max(abs(nearUV.x * 2 - 1), abs(nearUV.y * 2 - 1));
    float nearWeight = saturate((0.94f - nearEdge) * 12.5f);
    float texel = MCShadowRemap.w;
    // Start in the near cascade, or the far cascade when blending is needed.
    float2 nearOffset = texel * 0.25f;
    float2 offset = nearWeight >= 1.0f ? nearOffset : nearOffset + float2(0.5f, 0);
    float2 uv = nearWeight >= 1.0f ? nearUV : farUV;
    // dz/du,dz/dv on the geometric receiver plane, in 16-bit depth steps. The
    // shared projection has near diameter / depth range = 1/8; squared
    // row-length ratio = 1/64. The bounded reciprocal remains finite for a
    // plane parallel to the light. The far cascade is four times as wide
    // (MCShadowRemap.x = 1/4).
    float facing = dot(geometricNormal, MCShadowZ.xyz);
    float2 gradient = float2(dot(geometricNormal, MCShadowU.xyz), dot(geometricNormal, MCShadowV.xyz))
        * (-facing / max(facing * facing, 1.0e-20f) * (65535.0f / 64.0f));
    float2 mainGradient = gradient * (nearWeight >= 1.0f ? 1.0f : 4.0f);
    float reference = (depth - bias) * 65535.0f;
    float blend = 1.0f;
    float2 sunlight = 1.0f;
    // Share one cascade body to stay within ps_3_0's 512-slot minimum. The second
    // iteration executes only in the cascade transition.
    [loop] for (int cascade = 0; cascade < 2; ++cascade)
    {
        float2 light;
        if (caustics) light = mcShadowWaterPCF(uv, offset, reference, mainGradient);
        else light = mcShadowPCF(uv, offset, reference, mainGradient);
        sunlight = lerp(sunlight, light, blend);
        // offset.x is the half-texel address inside the near tile.
        [branch] if (blend == nearWeight) break;
        offset = nearOffset;
        uv = nearUV;
        mainGradient = gradient;
        blend = nearWeight;
    }
    float border = saturate((1.0f - farEdge) * 16.666667f);
    float2 light = lerp(1.0f, sunlight, MCQuadParams.y * border);
    return float3(light.x, dot(light, 0.5f), light.y);
}

float mcSunVisibility(float3 position, float3 geometricNormal)
{
    return mcSunLight(position, geometricNormal, false).x;
}
#endif
