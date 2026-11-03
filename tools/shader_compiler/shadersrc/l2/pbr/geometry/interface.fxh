#ifndef MC_PBR_INTERFACE_INCLUDED
#define MC_PBR_INTERFACE_INCLUDED
#if MC_VERTEX_STAGE
#define MC_CENTROID
#else
#define MC_CENTROID centroid
#endif
struct MCPBRFragment
{
#if MC_VERTEX_STAGE
    float4 position : POSITION0;
#endif
    MC_CENTROID float2 uv : TEXCOORD0;
    MC_CENTROID float4 weights : TEXCOORD1;
    float3 quadAddressOpacity : TEXCOORD2;
    MC_CENTROID float3 worldPosition : TEXCOORD3;
    // Centroid positions can move within a 2x2 pixel quad at silhouettes.
    // Keep derivatives at pixel centers; only the actual lookups use centroid.
    float3 derivativeWorldPosition : TEXCOORD4;
    float2 derivativeUV : TEXCOORD5;
};
#undef MC_CENTROID
#endif
