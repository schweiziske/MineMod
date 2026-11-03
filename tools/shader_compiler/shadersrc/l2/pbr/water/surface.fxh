#ifndef MC_WATER_SURFACE_INCLUDED
#define MC_WATER_SURFACE_INCLUDED
#include "interface.fxh"
#include "../geometry/normal.fxh"
#include "waves.fxh"

struct MCWaterSurface
{
    float3 px, py, view, geometric, base, normal;
    float4 waves;
    float top, roughness, fresnel, below;
};

// Colour, reflection tracing and reflection composition use the same wave
// clock and normal field. derivativeScale keeps half-resolution traces at
// the colour pass's normal-map footprint instead of changing the waves.
MCWaterSurface mcWaterSurface(MCWaterFragment input, float face, float4 origin, float4 motion,
                              float3 eye, float2 derivativeScale)
{
    MCWaterSurface s;
    // origin.w's sign carries the camera medium. From air, skip faces seen
    // from behind (the inside of a water volume); from water, skip faces seen
    // from the front (the outside of other water beyond the surface).
    clip(face * origin.w);
    float underwater = step(origin.w, 0.0f);
    origin.w = abs(origin.w);
    s.px = ddx(input.derivativeWorldPosition) * derivativeScale.x;
    s.py = ddy(input.derivativeWorldPosition) * derivativeScale.y;
    s.view = mcSafeNormalize(eye - input.worldPosition);
    s.geometric = mcSafeNormalize(cross(s.py, s.px));
    s.geometric *= dot(s.geometric, s.view) < 0.0f ? -1.0f : 1.0f;
    s.top = step(0.5f, abs(s.geometric.z));
    float sideX = step(abs(s.geometric.y), abs(s.geometric.x));
    float3 axisU = lerp(lerp(float3(1, 0, 0), float3(0, 1, 0), sideX), float3(1, 0, 0), s.top);
    float3 axisV = lerp(float3(0, 0, -1), float3(0, 1, 0), s.top);
    float3 p = input.worldPosition * origin.w + origin.xyz;
    float2 uv = float2(dot(p, axisU), dot(p, axisV));
    float2 dx = float2(dot(s.px, axisU), dot(s.px, axisV)) * origin.w;
    float2 dy = float2(dot(s.py, axisU), dot(s.py, axisV)) * origin.w;
    float variance;
    s.waves = mcWaterWaves(uv, dx, dy, motion.x, motion.y, variance);
    s.base = lerp(s.geometric, float3(0, 0, s.geometric.z < 0.0f ? -1.0f : 1.0f), s.top);
    s.normal = mcSafeNormalize(s.base + axisU * s.waves.x + axisV * s.waves.y);
    s.roughness = sqrt(0.0036f + variance * motion.y * motion.y * 2.3f);
    float nv = max(saturate(dot(s.normal, s.view)), 0.001f);
    float f = 1.0f - nv, f2 = f * f;
    s.fresnel = 0.02037f + 0.97963f * f2 * f2 * f;
    // Total internal reflection only exists looking up from inside the water;
    // from air, a downward face is the bottom of a hanging water body.
    s.below = step(0.5f, -s.geometric.z) * underwater;
    s.fresnel = max(s.fresnel, s.below * (1.0f - smoothstep(0.63f, 0.70f, nv)));
    return s;
}

// Seen from below, beyond the critical angle the surface reflects the water
// body, not the sky: a fixed lit water colour that SSR then replaces with
// the actual underwater scene where the trace hits.
float3 mcWaterUnderside(float3 scatter, float3 block, float3 sky)
{
    return scatter * (block + sky) * 3.0f;
}
#endif
