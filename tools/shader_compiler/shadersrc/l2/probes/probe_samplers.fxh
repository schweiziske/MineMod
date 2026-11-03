// Probe-only bindings, not the public material ABI.
sampler BaseSampler : register(s0);
sampler LightBytesSampler : register(s1);
sampler LightmapSampler : register(s2);
sampler NormalSampler : register(s3);
sampler ORMSampler : register(s4);
sampler EmissiveSampler : register(s5);
sampler Spare6Sampler : register(s6);
sampler Spare7Sampler : register(s7);

struct PS_INPUT
{
    float2 uv : TEXCOORD0;
    float4 clipPosition : TEXCOORD1;
};
