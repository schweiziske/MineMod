#include "../adapter/bindings.fxh"
#include "../geometry/interface.fxh"
#include "../geometry/normal.fxh"
#include "../lighting/corners.fxh"
#include "../lighting/brdf.fxh"
#include "../lighting/ibl.fxh"
#include "../lighting/shadow.fxh"
#include "../materials/labpbr.fxh"
#include "../materials/sampling.fxh"

float4 main(MCPBRFragment input, float faceSign : VFACE) : COLOR0
{
    // Derivatives are evaluated before alpha clipping. No NORMAL vertex stream
    // is assumed by the screenspace_general_8tex declaration.
    float3 px = ddx(input.derivativeWorldPosition), py = ddy(input.derivativeWorldPosition);
    float2 ux = ddx(input.derivativeUV), uy = ddy(input.derivativeUV);
    // Clipped fragments are strictly beyond the camera's near plane.
    float3 v = normalize(MCEyeExposure.xyz - input.worldPosition);
    // A rasterized nondegenerate triangle has a nonzero derivative cross.
    float3 geometric = normalize(cross(py, px));
    geometric *= dot(geometric, v) < 0.0f ? -1.0f : 1.0f;
    float lod = mcResourceAtlasGrad(ux,uy);
    float4 albedo = mcPBRColor(MCAlbedo, input.uv, lod, true);
    lod += MCResourceFootprint.w;
    float4 specularSample = mcPBRMaterial(MCORM, input.uv, lod, false);
    float4 normalSample = mcPBRMaterial(MCNormal, input.uv, lod, true);
    float3 n = mcMappedNormal(px, py, ux, uy, geometric, mcLabNormal(normalSample));
#if MC_ALPHA_CUTOUT
    clip(float2(faceSign, albedo.a - MCQuadParams.w));
#else
    clip(faceSign);
#endif
    float2 lightBytes;
    float3 tint, block, sky;
    float shade, occlusion;
    mcPBRCorners(input, lightBytes, tint, shade, occlusion);
    mcPBRIrradiance(lightBytes, block, sky);
    float3 base = albedo.rgb * tint;
    float roughness, metallic, subsurface, emission;
    float3 f0;
    mcLabSpecular(specularSample, base, roughness, metallic, f0, subsurface, emission);
    float materialAO = normalSample.b;
    // Filament's low-reflectance f90 heuristic prevents porous materials from
    // regaining a fully white grazing lobe. Apply it to both direct and IBL.
    float f90 = saturate(dot(f0, 16.5f));
    float nv = saturate(dot(n, v));
    float3 reflected = reflect(-v, n);
    // Retain the Minecraft lightmap's indirect-light scale while using the
    // same captured environment for directional diffuse and specular light.
    float3 ambient = block + sky * mcDiffuseIrradiance(n) * 0.4f;
    float2 dfg = mcEnvironmentBRDF(roughness, nv);
    float3 reflectance = saturate(f0 * dfg.x + f90 * dfg.y);
    float3 compensation = mcEnergyCompensation(f0, dfg);
    float3 diffuse = base * (1.0f - reflectance) * (1.0f - metallic) * ambient * shade;
    float3 environment = mcPrefilteredRadiance(n, reflected, roughness) * sky + block * 0.15f;
    float3 specular = environment * reflectance * compensation * MCSunColor.w;
    // Directional face shading and contact AO are independent. Occlusion only
    // attenuates indirect reflection; the shadow map controls direct sunlight.
    float ambientVisibility = materialAO * occlusion;
    specular *= mcSpecularOcclusion(nv, ambientVisibility, roughness);
    float skyAccess = lightBytes.y / 240.0f;
    skyAccess *= skyAccess;
    float sunPower = skyAccess * MCSunDirection.w;
    float3 direct = mcDirectBRDF(base, metallic, roughness, f0, f90, n, v, MCSunDirection.xyz, compensation, subsurface)
        * MCSunColor.rgb * sunPower;
    direct *= mcSunLight(input.worldPosition, geometric, true);
    float3 color = diffuse * materialAO + specular + direct + base * emission * 4.0f;
    color = mcToneMap(color);
#if MC_ALPHA_TRANSLUCENT
    return float4(color, saturate(albedo.a * input.quadAddressOpacity.z));
#else
    return float4(color, 1.0f);
#endif
}
