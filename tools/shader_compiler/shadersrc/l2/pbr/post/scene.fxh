// Positive view-space Z; GMod colour depth stores perspective clip W / 4000.
float4 MCPostTexel : register(c0); // depth inverse XY, effect inverse XY
float4 MCPostAO : register(c1);    // radius, bias, distance fade, strength
float4 MCPostView : register(c2);  // debug, horizontal/vertical projection scale
float4 MCPostJitter : register(c3);

float3 mcPostPosition(float2 uv, float depth)
{
    uv = (floor(uv / MCPostTexel.xy) + 0.5f) * MCPostTexel.xy;
    uv -= MCPostJitter.xy;
    return float3((uv.x - 0.5f) * depth / MCPostView.y,
                  (0.5f - uv.y) * depth / MCPostView.z, depth);
}
float mcPostDepth(sampler2D source, float2 uv)
{
    float2 center = (floor(uv / MCPostTexel.xy) + 0.5f) * MCPostTexel.xy;
    float3 depth = tex2Dlod(source, float4(center, 0, 0)).rgb;
    // Only SSAO uses this helper. A visible sky block is neither a receiver
    // nor an occluder; other scene effects still consume the original R depth.
    return depth.b <= depth.r ? 4000.0f : depth.r * 4000.0f;
}
bool mcPostInside(float2 uv)
{
    return all(uv >= MCPostTexel.xy * 0.5f) && all(uv <= 1.0f - MCPostTexel.xy * 0.5f);
}
