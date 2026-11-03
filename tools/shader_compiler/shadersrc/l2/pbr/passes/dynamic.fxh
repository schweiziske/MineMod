#include "../adapter/bindings.fxh"
#include "../geometry/interface.fxh"
#include "../geometry/normal.fxh"
#include "../lighting/corners.fxh"
#include "../lighting/brdf.fxh"
#include "../lighting/dynamic.fxh"
#include "../materials/labpbr.fxh"
#include "../materials/sampling.fxh"

float4 main(MCPBRFragment input, float faceSign : VFACE) : COLOR0
{
    float3 px = ddx(input.derivativeWorldPosition), py = ddy(input.derivativeWorldPosition);
    float2 ux = ddx(input.derivativeUV), uy = ddy(input.derivativeUV);
    float3 v = normalize(MCEyeExposure.xyz - input.worldPosition);
    float3 geometric = normalize(cross(py, px));
    geometric *= dot(geometric, v) < 0 ? -1.0f : 1.0f;
    float lod = mcResourceAtlasGrad(ux,uy);
    float4 albedo = mcPBRColor(MCAlbedo, input.uv, lod, true);
    lod += MCResourceFootprint.w;
    float4 specularSample = mcPBRMaterial(MCORM, input.uv, lod, false);
    float4 normalSample = mcPBRMaterial(MCNormal, input.uv, lod, true);
    float3 n = mcMappedNormal(px, py, ux, uy, geometric, mcLabNormal(normalSample));
#if MC_ALPHA_CUTOUT
    clip(float2(faceSign, albedo.a - 0.5f));
#else
    clip(faceSign);
#endif
    float2 lightBytes;
    float3 tint;
    float shade, occlusion;
    // Only the tint survives compilation; no static-light lookup or AO is
    // applied a second time. Dynamic direct light respects the same dry-wood
    // F0, roughness, metal and thin-leaf parameters as the base BRDF.
    mcPBRCorners(input, lightBytes, tint, shade, occlusion);
    float3 base = albedo.rgb * tint;
    float roughness, metallic, subsurface, emission;
    float3 f0;
    mcLabSpecular(specularSample, base, roughness, metallic, f0, subsurface, emission);
    float3 localLight = mcDynamicBRDF((input.worldPosition - MCEyeExposure.xyz) * MCQuadParams.x,
        base, metallic, roughness, f0, saturate(dot(f0, 16.5f)), n, v, subsurface);
    float opacity = 1;
#if MC_ALPHA_TRANSLUCENT
    opacity = albedo.a * input.quadAddressOpacity.z;
#endif
    return float4(mcToneMap(localLight) * opacity, 0);
}
