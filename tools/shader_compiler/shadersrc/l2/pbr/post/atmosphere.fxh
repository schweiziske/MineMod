float4 MCAtmosphere : register(c0); // linear scatter RGB, distance extinction / block
float4 MCFogShape : register(c1);   // start, height extinction, base, inverse scale; negative scale = water
float4 MCFogCamera : register(c2);  // world eye height in blocks, inverse block size, projection scale XY
float4 MCFogViewport : register(c3);// depth texel XY, max distance in blocks, max opacity
float4 MCFogRight : register(c11);
float4 MCFogUp : register(c12);
float4 MCFogForward : register(c13);

float3 mcFogRay(float2 uv)
{
    uv -= float2(MCFogRight.w, MCFogUp.w);
    return float3((uv.x - 0.5f) / MCFogCamera.z, (0.5f - uv.y) / MCFogCamera.w, 1);
}
float3 mcFogWorld(float3 view)
{
    return view.x * MCFogRight.xyz + view.y * MCFogUp.xyz + view.z * MCFogForward.xyz;
}
float mcFogOpticalDepth(float length, float worldDirectionZ)
{
    float start = min(MCFogShape.x, length);
    float segment = max(0.0f, length - start);
    float h0 = (MCFogShape.z - MCFogCamera.x - worldDirectionZ * start) * MCFogShape.w;
    float h1 = (MCFogShape.z - MCFogCamera.x - worldDirectionZ * length) * MCFogShape.w;
    // Density is constant below the base and exponential above it. Split rays
    // crossing the base; clamping only their endpoints would integrate the wrong layer.
    float low = min(h0, h1);
    float high = max(h0, h1);
    float above = saturate(-low / max(high - low, 0.000001f));
    float x = (min(high, 0.0f) - min(low, 0.0f)) * 0.693147181f;
    // Non-positive exponents avoid overflow; the series keeps horizontal rays stable.
    float mean = x < 0.001f ? 1.0f - x * 0.5f + x * x / 6.0f : (1.0f - exp(-x)) / x;
    float heightIntegral = segment * lerp(1.0f, exp2(min(high, 0.0f)) * mean, above);
    return segment * MCAtmosphere.w + MCFogShape.y * heightIntegral;
}

float3 mcMediumExtinction()
{
    return MCAtmosphere.w * float3(0.18f, 0.075f, 0.045f);
}
float3 mcMediumOpticalDepth(float distance, float worldDirectionZ)
{
    if (MCFogShape.w < 0) return distance * mcMediumExtinction();
    return mcFogOpticalDepth(distance, worldDirectionZ);
}
