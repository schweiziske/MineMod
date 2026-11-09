#ifndef MC_VANILLA_QUAD_LIGHT_INCLUDED
#define MC_VANILLA_QUAD_LIGHT_INCLUDED
#include "tint.fxh"
#include "lightmap.fxh"
#include "corner_atlas.fxh"

float3 mcLitVertex(float2 uv)
{
    float4 bytes = floor(tex2Dlod(MCQuadVertices, float4(uv, 0, 0)) * 255.0f + 0.5f);
    float3 light = mcVanillaLightmap(bytes.rg);
    // Quantize tint*shade at EACH vertex, before interpolating the lit color.
    float3 color = floor(mcVanillaTintBytes(bytes.a) * (bytes.b / 255.0f) + 0.0001f) / 255.0f;
    return color * light;
}

float3 mcQuadLighting(MCQuadFragment input)
{
    float4 pixel = mcCornerAtlasPixel(input.quadAddressOpacity.xy, MCQuadParams.z);
    float2 uv = mcCornerAtlasUV(pixel);
    float2 stepX = float2(pixel.z, 0.0f);
    // Nonlinear lightmap lookup precedes interpolation; black is valid data.
    return mcLitVertex(uv) * input.weights.x
         + mcLitVertex(uv + stepX) * input.weights.y
         + mcLitVertex(uv + stepX * 2.0f) * input.weights.z
         + mcLitVertex(uv + stepX * 3.0f) * input.weights.w;
}
#endif
