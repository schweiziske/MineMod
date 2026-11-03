// LabPBR 1.3 decode. _n: XY normal (+Y follows increasing V), B = AO,
// A = height. _s: R = perceptual smoothness, G = F0 (230+ metal),
// B = porosity (<65) / subsurface, A = emission (255 = none).
#ifndef MC_PBR_LABPBR_INCLUDED
#define MC_PBR_LABPBR_INCLUDED
float3 mcLabNormal(float4 normalSample)
{
    float2 xy = normalSample.xy * 2.0f - 1.0f;
    return float3(xy, sqrt(saturate(1.0f - dot(xy, xy))));
}

void mcLabSpecular(float4 specular, float3 base, out float roughness, out float metallic,
    out float3 f0, out float subsurface, out float emission)
{
    roughness = max(1.0f - specular.r, 0.045f); // UNORM input already bounds the upper end.
    // Hardcoded metals (230-254) use albedo as F0, like 255.
    metallic = specular.g > (229.5f / 255.0f) ? 1.0f : 0.0f;
    f0 = lerp(specular.ggg, base, metallic);
    subsurface = saturate((specular.b * 255.0f - 64.5f) / 190.5f);
    emission = specular.a < (254.5f / 255.0f) ? specular.a * (255.0f / 254.0f) : 0.0f;
}
#endif
