// Adapted from Google Filament, Apache-2.0, commit 9eb21d78b68ed7b161d96a1aaadfac9b8bdca282.
// See third_party/filament/NOTICE.md. DX9 atlas storage and A/B packing are local changes.
#ifndef MC_PBR_IBL_INCLUDED
#define MC_PBR_IBL_INCLUDED

float2 mcEnvironmentBRDF(float roughness, float nv)
{
    float4 packed = tex2Dlod(MCDFG, float4(saturate(nv), roughness, 0, 0));
    return float2(dot(packed.rg, float2(256, 1)), dot(packed.ba, float2(256, 1))) * (255.0f / 65535.0f);
}

float2 mcEnvironmentLocalUV(float3 direction)
{
    float2 oct = direction.xy / max(dot(abs(direction), 1.0f), 1.0e-8f);
    if (direction.z < 0.0f)
        oct = (1.0f - abs(oct.yx)) * (step(0.0f, oct) * 2.0f - 1.0f);
    return (oct * 0.5f + 0.5f) * float2(124.0f / 512.0f, 124.0f / 256.0f)
        + float2(2.0f / 512.0f, 2.0f / 256.0f);
}

float3 mcDiffuseIrradiance(float3 n)
{
    // Filament's Irradiance_RoughnessOne path. At alpha=1 and V=N, the
    // normalized GGX prefilter is cosine-weighted irradiance divided by PI.
    float2 uv = mcEnvironmentLocalUV(n) + float2(0.75f, 0.5f);
    float4 radiance = tex2Dlod(MCEnvironment, float4(uv, 0, 0));
    return radiance.rgb * radiance.a * 64.0f;
}

float3 mcPrefilteredRadiance(float3 n, float3 reflected, float roughness)
{
    // Filament's dominant-direction shift uses linear roughness squared.
    float alpha = roughness * roughness;
    float2 localUV = mcEnvironmentLocalUV(lerp(reflected, n, alpha * alpha));
    // The offline levels are uniformly spaced in perceptual roughness. They
    // are independently convolved with GGX, not ordinary box-filtered mips.
    float level = roughness * 7.0f;
    float low = floor(level), high = min(low + 1.0f, 7.0f);
    float2 lowUV = localUV + float2(frac(low * 0.25f), floor(low * 0.25f) * 0.5f);
    float2 highUV = localUV + float2(frac(high * 0.25f), floor(high * 0.25f) * 0.5f);
    float4 a = tex2Dlod(MCEnvironment, float4(lowUV, 0, 0));
    float4 b = tex2Dlod(MCEnvironment, float4(highUV, 0, 0));
    return lerp(a.rgb * a.a, b.rgb * b.a, frac(level)) * 64.0f;
}

float3 mcEnergyCompensation(float3 f0, float2 dfg)
{
    // Filament dfg.y is A+B. Its compensation restores energy lost by the
    // single-scattering GGX lobe, especially on rough metallic surfaces.
    return 1.0f + f0 * (1.0f / max(dfg.x + dfg.y, 0.0001f) - 1.0f);
}

float mcSpecularOcclusion(float nv, float visibility, float roughness)
{
    // Filament SpecularAO_Lagarde, from Moving Frostbite to PBR (2014).
    // Filament uses linear roughness here, not perceptual roughness.
    return saturate(pow(max(nv + visibility, 1.0e-6f), exp2(-16.0f * roughness * roughness - 1.0f))
        - 1.0f + visibility);
}
#endif
