#include "interface.fxh"
#include "../lighting/tint.fxh"
#include "../lighting/corner_atlas.fxh"
#include "../lighting/dynamic_lights.fxh"
#include "../materials/atlas.fxh"
#ifndef MC_RESOURCE_PBR_SPRITE
#include "../lighting/water_fog.fxh"
#endif
float4 MCDynamicParams : register(c0); // inverse block size, corner layout/bank, opacity, count
float4 MCDynamicEye : register(c1); // render-space eye, unused
sampler2D MCAlbedo : register(s0);
sampler2D MCQuadVertices : register(s1);
sampler2D MCLightData : register(s2);

float3 mcDynamicTint(float2 uv)
{
    float code = floor(tex2Dlod(MCQuadVertices, float4(uv, 0, 0)).a * 255.0f + 0.5f);
    return mcVanillaTintBytes(code) / 255.0f;
}

float4 main(MCDynamicFragment input, float faceSign : VFACE) : COLOR0
{
    float3 normal = cross(ddy(input.derivativeWorldPosition), ddx(input.derivativeWorldPosition));
    normal *= rsqrt(max(dot(normal, normal), 1.0e-12f));
    normal *= dot(normal, MCDynamicEye.xyz - input.worldPosition) < 0 ? -1.0f : 1.0f;
    float lod = mcResourceAtlasLod(input.uv);
#ifdef MC_RESOURCE_PBR_SPRITE
    float4 albedo = mcResourceColor(MCAlbedo, mcResourceAtlasUV(input.uv,lod), lod, true);
#else
    float4 albedo = mcResourceColor(MCAlbedo, mcResourceAtlasUV(input.uv,lod), lod, false);
#endif
#if MC_ALPHA_CUTOUT
    clip(albedo.a - 0.5f);
#endif
#if MC_DYNAMIC_SPRITE
    // Sprite meshes retain their existing tint/shade in vertex colour. Bring
    // its hue into the local-light pass without multiplying by static darkness.
    float brightness = max(max(input.weights.r, input.weights.g), input.weights.b);
    // At zero ambient the baked RGB no longer contains a recoverable hue.
    // Keep the texture colour so a fully dark fluid can still receive light.
    float3 tint = brightness > 0.0f ? input.weights.rgb / max(brightness, 1.0e-6f) : 1.0f;
#else
#if !MC_ALPHA_TRANSLUCENT
    clip(faceSign);
#endif
    float4 pixel = mcCornerAtlasPixel(input.quadAddressOpacity.xy, MCDynamicParams.y);
    float2 uv = mcCornerAtlasUV(pixel);
    float3 tint = mcDynamicTint(uv) * input.weights.x
        + mcDynamicTint(uv + float2(pixel.z, 0)) * input.weights.y
        + mcDynamicTint(uv + float2(2.0f * pixel.z, 0)) * input.weights.z
        + mcDynamicTint(uv + float2(3.0f * pixel.z, 0)) * input.weights.w;
#endif
    float3 position = (input.worldPosition - MCDynamicEye.xyz) * MCDynamicParams.x;
    float3 light = 0;
    [loop] for (int i = 0; i < (int)MCDynamicParams.w; ++i)
    {
        float3 direction;
        float3 radiance = mcReadDynamicLight(MCLightData, i, position, direction);
        light += radiance * saturate(dot(normal, direction)) * 0.318309886f;
    }
    float opacity = MCDynamicParams.z;
#if MC_ALPHA_TRANSLUCENT || MC_DYNAMIC_SPRITE
    opacity *= albedo.a * input.quadAddressOpacity.z;
#endif
    float3 contribution = saturate(albedo.rgb * tint * light) * opacity;
#ifndef MC_RESOURCE_PBR_SPRITE
    contribution *= 1.0f - mcWaterFogAmount(input.worldPosition);
#endif
    return float4(contribution, 0);
}
