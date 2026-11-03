// GGX/Smith/Schlick adapted from Google Filament surface_brdf.fs (Apache-2.0).
// Pinned source, modifications and license: third_party/filament/NOTICE.md.
#ifndef MC_PBR_BRDF_INCLUDED
#define MC_PBR_BRDF_INCLUDED
static const float MC_PI = 3.14159265359f;

float mcPow5(float value)
{
    float squared = value * value;
    return squared * squared * value;
}

float3 mcFresnel(float3 f0, float f90, float cosine)
{
    return f0 + (f90 - f0) * mcPow5(1.0f - saturate(cosine));
}

float3 mcDirectBRDF(float3 albedo, float metallic, float roughness, float3 f0, float f90, float3 n, float3 v, float3 l, float3 energyCompensation, float subsurface)
{
    float3 h = mcSafeNormalize(v + l);
    float nv = max(saturate(dot(n, v)), 0.0001f);
    float signedNL = dot(n, l);
    float nl = saturate(signedNL);
    float nh = saturate(dot(n, h));
    float vh = saturate(dot(v, h));
    float a = roughness * roughness;
    float a2 = a * a;
    // Divide before squaring, as in Filament. Clamping the squared denominator
    // to 1e-7 flattened narrow low-roughness highlights by orders of magnitude.
    float nhSquared = nh * nh;
    float k = a / max((1.0f - nhSquared) + a2 * nhSquared, 1.0e-12f);
    float distribution = k * k / MC_PI;
    // Height-correlated Smith visibility, already includes 1/(4*NdotV*NdotL).
    float lambdaV = nl * sqrt(nv * nv * (1.0f - a2) + a2);
    float lambdaL = nv * sqrt(nl * nl * (1.0f - a2) + a2);
    float visibility = 0.5f / max(lambdaV + lambdaL, 0.00001f);
    float3 f = mcFresnel(f0, f90, vh);
    float3 diffuse = (1.0f - f) * (1.0f - metallic) * albedo / MC_PI;
    // Thin leaves transmit tinted diffuse light from their back side. The
    // specular lobe remains on the lit side, and opaque materials decode zero.
    return diffuse * (nl + subsurface * saturate(-signedNL))
        + distribution * visibility * nl * f * energyCompensation;
}

float3 mcToneMap(float3 color)
{
    // All radiance terms and the validated exposure are nonnegative.
    float3 x = color * MCEyeExposure.w;
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}
#endif
