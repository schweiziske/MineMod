#ifndef MC_VANILLA_LIGHTMAP_INCLUDED
#define MC_VANILLA_LIGHTMAP_INCLUDED
float3 mcVanillaLightmap(float2 lightBytes)
{
    // 1/16-level precision; s2 MUST be linear filtered, unlike the L1 RT.
    float2 uv = (clamp(lightBytes, 0.0f, 240.0f) + 8.0f) / 256.0f;
    return tex2D(MCGlobalLightmap, uv).rgb;
}
#endif
