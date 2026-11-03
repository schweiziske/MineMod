#include "../adapter/bindings.fxh"
#include "../geometry/quad_interface.fxh"
#include "../lighting/quad.fxh"
#include "../materials/atlas.fxh"
#include "../lighting/water_fog.fxh"

float4 main(MCQuadFragment input, float faceSign : VFACE) : COLOR0
{
    float lod = mcResourceAtlasLod(input.uv);
    float4 albedo = mcResourceColor(MCAlbedo, mcResourceAtlasUV(input.uv,lod), lod, false);
#if !MC_ALPHA_TRANSLUCENT
    clip(faceSign);
#endif
#if MC_ALPHA_CUTOUT
    clip(albedo.a - MCQuadParams.w);
#endif
    float3 color = mcQuadLighting(input);
    float3 shaded = lerp(saturate(albedo.rgb * color), MCWaterFog.rgb, mcWaterFogAmount(input.worldPosition));
#if MC_ALPHA_TRANSLUCENT
    return float4(shaded, saturate(albedo.a * input.quadAddressOpacity.z));
#else
    return float4(shaded, 1.0f);
#endif
}
