#ifndef MC_PBR_BINDINGS_INCLUDED
#define MC_PBR_BINDINGS_INCLUDED
#if MC_VERTEX_STAGE
// Source SM3 matrices: common_vs_fxc.h, c4 and c58. IMesh positions are local.
float4x4 MCModelViewProjection : register(c4);
float4x3 MCModel : register(c58);
#else
float4 MCQuadParams : register(c0); // normalized shadow bias, shadow strength, corner layout/bank, alpha cutoff
float4 MCEyeExposure : register(c1); // current engine-space camera, exposure
float4 MCSunDirection : register(c2); // direction toward the sun, direct radiance
float4 MCSunColor : register(c3); // linear sun RGB, environment intensity
sampler2D MCAlbedo : register(s0);
sampler2D MCQuadVertices : register(s1);
sampler2D MCGlobalLightmap : register(s2);
sampler2D MCNormal : register(s3); // LabPBR _n: XY normal (+Y follows increasing V), B = AO, A = height
sampler2D MCORM : register(s4); // LabPBR _s: smoothness, F0 (230+ metal), porosity/subsurface, emission (255 = none)
sampler2D MCShadowDepth : register(s5); // POINT RGBA8, 2x2 atlas: opaque above, water below; RG depth, BA water light
sampler2D MCEnvironment : register(s6); // linear RGBM64, 8 prefiltered octahedral levels
sampler2D MCDFG : register(s7); // linear RG/BA: two big-endian UNORM16 A/B coefficients
// $viewprojmat transports four independent rows, with no Lua transpose.
float4 MCShadowU : register(c11);
float4 MCShadowV : register(c12);
float4 MCShadowZ : register(c13);
float4 MCShadowRemap : register(c14); // near/far scale, offsets U/V, inverse tile size
#endif
#endif
