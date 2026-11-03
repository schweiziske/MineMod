float4 MCWaterFog : register(c2); // RGB and inverse (end - start), zero in air
float4 MCWaterEye : register(c3); // render-space camera and fog start

float mcWaterFogAmount(float3 position)
{
    return saturate((length(position - MCWaterEye.xyz) - MCWaterEye.w) * MCWaterFog.w);
}
