#ifndef MC_PBR_DYNAMIC_INCLUDED
#define MC_PBR_DYNAMIC_INCLUDED
#include "../../vanilla/lighting/dynamic_lights.fxh"
#include "ibl.fxh"
// c0 is private to the additive-light materials. Base PBR still uses its
// original shadow/corner contract and its original 16x16 lightmap.
float3 mcDynamicBRDF(float3 position, float3 base, float metallic, float roughness,
    float3 f0, float f90, float3 n, float3 v, float subsurface)
{
    float2 dfg = mcEnvironmentBRDF(roughness, saturate(dot(n, v)));
    float3 compensation = mcEnergyCompensation(f0, dfg);
    float3 result = 0;
    [loop] for (int i = 0; i < (int)MCQuadParams.w; ++i)
    {
        float3 direction;
        float3 radiance = mcReadDynamicLight(MCGlobalLightmap, i, position, direction);
        result += mcDirectBRDF(base, metallic, roughness, f0, f90, n, v, direction, compensation, subsurface) * radiance;
    }
    return result;
}
#endif
