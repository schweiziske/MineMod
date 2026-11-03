#include "../adapter/bindings.fxh"
#include "quad_interface.fxh"
float4x3 MCModel : register(c58);

struct MCQuadVertex
{
    float4 position : POSITION0;
    float2 uv : TEXCOORD0;
    float4 color : COLOR0;
};

MCQuadFragment main(MCQuadVertex input)
{
    MCQuadFragment output;
    output.position = mul(input.position, MCModelViewProjection);
    output.uv = input.uv;
    output.worldPosition = mul(input.position, MCModel);
    float4 bytes = floor(input.color * 255.0f + 0.5f);
    float vertex = dot(bytes.rgb, float3(1.0f, 256.0f, 65536.0f));
    float quad = floor(vertex * 0.25f);
    float corner = vertex - quad * 4.0f;
    // Interpolate the actual triangles, including rotated/non-planar quads.
    output.weights = 1.0f - step(0.5f, abs(float4(0, 1, 2, 3) - corner));
    // Keep perspective interpolants small: 512 quad columns, 2048 rows.
    // A global quad ID can reach 1048575; it is not a texture coordinate.
    float row = floor(quad / 512.0f);
    output.quadAddressOpacity = float3(quad - row * 512.0f, row, bytes.a / 255.0f);
    return output;
}
