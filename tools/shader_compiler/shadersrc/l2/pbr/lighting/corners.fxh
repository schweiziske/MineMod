#ifndef MC_PBR_CORNERS_INCLUDED
#define MC_PBR_CORNERS_INCLUDED
#include "../../vanilla/lighting/corner_atlas.fxh"

float3 mcPBRTintBytes(float4 codes, float4 weights)
{
    // Evaluate the same vanilla palette for all four corners in vector lanes.
    // Scalar branching repeated per corner consumes much of the SM3 budget.
    // Centroid barycentric weights sum to one; an untinted quad is white.
    [branch] if (dot(codes, 1.0f) < 0.5f) return 255.0f;
    float4 colored = step(0.5f, codes);
    float4 afterWire = step(16.5f, codes);
    float4 afterStem = step(24.5f, codes);
    float4 afterLily = step(25.5f, codes);
    float4 wireWeights = weights * (colored - afterWire);
    float4 power = codes - 1.0f;
    float4 red = lerp(76.0f, floor(102.0f + power * 10.2f), step(0.5f, power));
    float4 green = step(12.5f, power) * 6.0f + step(13.5f, power) * 21.0f + step(14.5f, power) * 23.0f;
    float3 result = float3(dot(wireWeights, red), dot(wireWeights, green), 0);
    float4 stemWeights = weights * (afterWire - afterStem);
    float age = dot(stemWeights, codes - 17.0f);
    result += float3(age * 32.0f, dot(stemWeights, 255.0f) - age * 8.0f, age * 4.0f);
    result += dot(weights, afterStem - afterLily) * float3(224.0f, 199.0f, 28.0f);
    return result + dot(weights, 1.0f - colored + afterLily) * 255.0f;
}

// Accurate enough for integer tint multipliers; textures use hardware sRGB.
float3 mcTintLinear(float3 color)
{
    return color * (color * (color * 0.305306011f + 0.682171111f) + 0.012522878f);
}

void mcPBRCorners(MCPBRFragment input, out float2 lightBytes, out float3 tint, out float shade, out float occlusion)
{
#if MC_BLOCK_ENTITY
    lightBytes = min(input.weights.rg * 255.0f, 240.0f);
    tint = 1.0f;
    shade = input.weights.b;
    occlusion = 1.0f;
#else
    float2 pixel = mcCornerAtlasPixel(input.quadAddressOpacity.xy, MCQuadParams.z);
    float2 uv = mcCornerAtlasUV(pixel);
    float2 stepX = float2(1.0f / 16384.0f, 0.0f);
    float4 b0 = floor(tex2Dlod(MCQuadVertices, float4(uv, 0, 0)) * 255.0f + 0.5f);
    float4 b1 = floor(tex2Dlod(MCQuadVertices, float4(uv + stepX, 0, 0)) * 255.0f + 0.5f);
    float4 b2 = floor(tex2Dlod(MCQuadVertices, float4(uv + stepX * 2, 0, 0)) * 255.0f + 0.5f);
    float4 b3 = floor(tex2Dlod(MCQuadVertices, float4(uv + stepX * 3, 0, 0)) * 255.0f + 0.5f);
    float4 w = input.weights;
    float2 aoUV = mcCornerAtlasAO(pixel);
    occlusion = dot(tex2Dlod(MCQuadVertices, float4(aoUV, 0, 0)), w);
    float3 raw = b0.rgb * w.x + b1.rgb * w.y + b2.rgb * w.z + b3.rgb * w.w;
    // Decoded bytes and centroid weights are nonnegative. Only the lightmap's
    // upper limit needs clamping (emission transport can contain 248).
    lightBytes = min(raw.rg, 240.0f);
    shade = saturate(raw.b / 255.0f);
    // The legacy byte already contains directionalShade * AO. Give contact AO
    // a quadratic response in linear HDR light without squaring face shading.
    // Open surfaces (AO=1) are unchanged; no additional screen-space pass.
    shade *= occlusion;
    occlusion *= occlusion;
    tint = mcTintLinear(mcPBRTintBytes(float4(b0.a, b1.a, b2.a, b3.a), w) / 255.0f);
#endif
}

void mcPBRIrradiance(float2 lightBytes, out float3 block, out float3 sky)
{
    // Only two lightmap reads. PBR interpolates raw light before lookup; vanilla
    // continues its original nonlinear per-corner lookups in its own shader.
    float2 uv = (lightBytes + 8.0f) / 256.0f;
    block = tex2D(MCGlobalLightmap, float2(uv.x, 0.03125f)).rgb;
    sky = max(tex2D(MCGlobalLightmap, uv).rgb - block, 0.0f);
}
#endif
