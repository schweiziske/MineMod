#ifndef MC_WATER_WAVES_INCLUDED
#define MC_WATER_WAVES_INCLUDED
#include "wave_field.fxh"

// Directional ripples after chun v2's default waves (getwaves1). The baked
// field (build_pbr_water.py) runs long along U; two layers rotated -0.75 and
// -0.3 rad, as in chun, each travel across their crests. Integer matrices
// over 4096 keep whole periods per 4096 blocks/seconds for re-origin/wrap.
float4 mcWaterWaves(float2 surface, float2 dx, float2 dy,
                    float time, float strength, out float variance)
{
    float2x2 layerA = MCWaveLayerA;
    float2x2 layerB = MCWaveLayerB;
    // Crest speeds are half of chun's (403/2 rounded to 202).
    // One world-space wave field spans BOTH still and flowing sprites. Choosing
    // weights from a sprite's UV rotation makes adjoining faces crack.
    float2 uvA = mcWaveUV(surface, time, false);
    float2 uvB = mcWaveUV(surface, time, true);
    float4 a = tex2Dgrad(MCNormal, uvA, mul(layerA, dx), mul(layerA, dy));
    float4 b = tex2Dgrad(MCNormal, uvB, mul(layerB, dx), mul(layerB, dy));
    float3 n0 = a.xyz * 2.0f - 1.0f, n1 = b.xyz * 2.0f - 1.0f;
    // Measure mip variance before mixing independent waves. Treating their
    // intentional cancellation as variance would turn water rough and milky.
    variance = (saturate(1.0f - dot(n0, n0) - 0.014f) + saturate(1.0f - dot(n1, n1) - 0.014f)) * 0.5f;
    // Shared with light-space refraction; strength changes the normal, not light gain.
    float2 slope = mcWaveSlope(n0, n1, strength);
    return float4(slope, a.a * 0.67f + b.a * 0.33f, 0);
}

#endif
