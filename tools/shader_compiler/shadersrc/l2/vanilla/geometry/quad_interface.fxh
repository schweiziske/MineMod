#ifndef MC_QUAD_INTERFACE_INCLUDED
#define MC_QUAD_INTERFACE_INCLUDED
#if MC_VERTEX_STAGE
#define MC_CENTROID
#else
#define MC_CENTROID centroid
#endif
struct MCQuadFragment
{
#if MC_VERTEX_STAGE
    float4 position : POSITION0;
#endif
    MC_CENTROID float2 uv : TEXCOORD0;
    MC_CENTROID float4 weights : TEXCOORD1;
    float3 quadAddressOpacity : TEXCOORD2;
    float3 worldPosition : TEXCOORD3;
};
#undef MC_CENTROID
#endif
