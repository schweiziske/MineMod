#include "interface.fxh"
float4x4 MCModelViewProjection : register(c4);
float4x3 MCModel : register(c58);
struct MCDynamicVertex
{
    float4 position : POSITION0;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};
MCDynamicFragment main(MCDynamicVertex input)
{
    MCDynamicFragment output;
    output.position = mul(input.position, MCModelViewProjection);
    output.uv = input.uv;
    output.worldPosition = mul(input.position, MCModel);
    output.derivativeWorldPosition = output.worldPosition;
#if MC_DYNAMIC_SPRITE
    output.weights = input.color;
    output.quadAddressOpacity = float3(0, 0, input.color.a);
#else
    float4 bytes = floor(input.color * 255.0f + 0.5f);
    float vertex = dot(bytes.rgb, float3(1, 256, 65536));
    float quad = floor(vertex * 0.25f), corner = vertex - quad * 4.0f;
    output.weights = 1.0f - step(0.5f, abs(float4(0, 1, 2, 3) - corner));
    float row = floor(quad / 512.0f);
    output.quadAddressOpacity = float3(quad - row * 512.0f, row, bytes.a / 255.0f);
#endif
    return output;
}
