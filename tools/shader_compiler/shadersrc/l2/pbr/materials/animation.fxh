#ifndef MC_LAB_ANIMATION_INCLUDED
#define MC_LAB_ANIMATION_INCLUDED

float4 mcAnimationBytes(float4 value)
{
    return floor(saturate(value) * 255.0f + 0.5f) / 255.0f;
}

// Semantic interpolation of texel-centre samples, in time or between mips.
// Nonlinear filtering order matters: mip each frame, mix time, then mix LOD.
// Match atlas::FilterMaterial except undefined near-antipodal normal averages.
// Endpoints are copied; a vector shorter than 1e-6 has no stable direction.
float4 mcAnimationNormal(float4 first, float4 second, float weight)
{
    if (weight <= 0.0f) return first;
    if (weight >= 1.0f) return second;
    float2 a = first.xy * 2.0f - 1.0f;
    float2 b = second.xy * 2.0f - 1.0f;
    float3 n = lerp(float3(a, sqrt(saturate(1.0f - dot(a, a)))),
                    float3(b, sqrt(saturate(1.0f - dot(b, b)))), weight);
    float lengthSquared = dot(n, n);
    float2 xy = lengthSquared > 1e-12f ? n.xy * rsqrt(max(lengthSquared, 1e-12f)) : 0.0f;
    return mcAnimationBytes(float4(xy * 0.5f + 0.5f, lerp(first.zw, second.zw, weight)));
}

float4 mcAnimationSpecular(float4 first, float4 second, float weight)
{
    if (weight <= 0.0f) return first;
    if (weight >= 1.0f) return second;
    float4 a = floor(first * 255.0f + 0.5f);
    float4 b = floor(second * 255.0f + 0.5f);
    float roughness = sqrt(lerp((255.0f - a.r) * (255.0f - a.r),
                               (255.0f - b.r) * (255.0f - b.r), weight));
    float selectedF0 = weight > 0.5f ? b.g : a.g;
    float f0 = a.g < 230.0f && b.g < 230.0f ? lerp(a.g, b.g, weight) : selectedF0;
    bool sameCategory = (a.b < 65.0f) == (b.b < 65.0f);
    float poreSSS = sameCategory ? lerp(a.b, b.b, weight) : (weight > 0.5f ? b.b : a.b);
    float emission = lerp(a.a == 255.0f ? 0.0f : a.a, b.a == 255.0f ? 0.0f : b.a, weight);
    return mcAnimationBytes(float4(255.0f - roughness, f0, poreSSS, emission > 0.0f ? emission : 255.0f) / 255.0f);
}
#endif
