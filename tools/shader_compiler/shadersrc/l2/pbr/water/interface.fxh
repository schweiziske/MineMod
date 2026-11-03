#ifndef MC_WATER_INTERFACE_INCLUDED
#define MC_WATER_INTERFACE_INCLUDED
#if MC_VERTEX_STAGE
#define MC_CENTROID
#else
#define MC_CENTROID centroid
#endif
struct MCWaterFragment
{
#if MC_VERTEX_STAGE
    float4 position : POSITION0;
#endif
    MC_CENTROID float2 uv : TEXCOORD0;
    MC_CENTROID float4 lightDepthShore : TEXCOORD1;
    MC_CENTROID float3 worldPosition : TEXCOORD2;
    // Only derivative inputs stay at pixel centres under MSAA.
    float3 derivativeWorldPosition : TEXCOORD3;
    float2 derivativeUV : TEXCOORD4;
    // Clip W, for the distance to the opaque surface behind.
    float clipW : TEXCOORD5;
};
#undef MC_CENTROID
#endif
