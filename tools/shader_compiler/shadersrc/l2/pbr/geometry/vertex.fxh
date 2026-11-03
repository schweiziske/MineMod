#include "../adapter/bindings.fxh"
#include "interface.fxh"

struct MCPBRVertex
{
    float4 position : POSITION0;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

MCPBRFragment main(MCPBRVertex input)
{
    MCPBRFragment output;
    output.position = mul(input.position, MCModelViewProjection);
    output.worldPosition = mul(input.position, MCModel);
    output.uv = input.uv;
    // Rotation only: chunk-local coordinates keep ddx/ddy precise up close,
    // where large world coordinates made the tangent frame jitter in streaks.
    output.derivativeWorldPosition = mul(input.position.xyz, (float3x3)MCModel);
    output.derivativeUV = input.uv;
#if MC_BLOCK_ENTITY
    // Immediate block-entity geometry carries raw block/sky light in RG.
    output.weights = input.color;
    output.quadAddressOpacity = float3(0, 0, input.color.a);
#else
    float4 bytes = floor(input.color * 255.0f + 0.5f);
    float vertex = dot(bytes.rgb, float3(1.0f, 256.0f, 65536.0f));
    float quad = floor(vertex * 0.25f);
    float corner = vertex - quad * 4.0f;
    output.weights = 1.0f - step(0.5f, abs(float4(0, 1, 2, 3) - corner));
    float row = floor(quad / 512.0f);
    output.quadAddressOpacity = float3(quad - row * 512.0f, row, bytes.a / 255.0f);
#endif
    return output;
}
