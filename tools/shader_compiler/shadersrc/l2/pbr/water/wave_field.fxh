#ifndef MC_WATER_WAVE_FIELD_INCLUDED
#define MC_WATER_WAVE_FIELD_INCLUDED

static const float2x2 MCWaveLayerA = float2x2(262, 244, -244, 262) / 4096.0f;
static const float2x2 MCWaveLayerB = float2x2(392, 121, -121, 392) / 4096.0f;

float2 mcWaveUV(float2 surface, float time, uniform bool second)
{
    return second ? mul(MCWaveLayerB, surface) - float2(0, time * (202.0f / 4096.0f))
                  : mul(MCWaveLayerA, surface) - float2(0, time * (173.0f / 4096.0f));
}

float2 mcWaveSlope(float3 n0, float3 n1, float strength)
{
    float4 slopes = float4(n0.xy,n1.xy);
    float2 tilt = float2(
        dot(slopes,float4(262,-244,392,-121) * float4(0.67f/358.0f,0.67f/358.0f,0.33f/410.0f,0.33f/410.0f)),
        dot(slopes,float4(244,262,121,392) * float4(0.67f/358.0f,0.67f/358.0f,0.33f/410.0f,0.33f/410.0f)));
    return tilt / max(n0.z * 0.67f + n1.z * 0.33f, 0.35f) * (strength * 1.953125f);
}
#endif
