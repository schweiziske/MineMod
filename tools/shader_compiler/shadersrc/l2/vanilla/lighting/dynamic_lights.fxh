#ifndef MC_DYNAMIC_LIGHTS_INCLUDED
#define MC_DYNAMIC_LIGHTS_INCLUDED
// One 64x1 POINT RGBA8 texture; five texels per light, at most eight lights.
// Positions and radii are in blocks (1/64 precision), relative to this view's
// eye. Data reads MUST remain linear. See docs/render-dynamic-lights.md.
float mcLightWord(float2 bytes)
{
    return dot(bytes, float2(255.0f, 65280.0f));
}

float3 mcLightDirection(float2 oct)
{
    float2 p = oct * 2.0f - 1.0f;
    float3 n = float3(p, 1.0f - abs(p.x) - abs(p.y));
    float t = saturate(-n.z);
    n.xy += float2(n.x >= 0 ? -t : t, n.y >= 0 ? -t : t);
    return normalize(n);
}

// Both vanilla and PBR use exactly the same bounded falloff and soft cone.
// No derivative/implicit-LOD texture operations occur inside the light loop.
float3 mcReadDynamicLight(sampler2D data, int index, float3 position, out float3 direction)
{
    float u = (index * 5.0f + 0.5f) / 64.0f;
    float4 xy = tex2Dlod(data, float4(u, 0.5f, 0, 0));
    float4 zr = tex2Dlod(data, float4(u + 1.0f / 64.0f, 0.5f, 0, 0));
    float4 color = tex2Dlod(data, float4(u + 2.0f / 64.0f, 0.5f, 0, 0));
    float3 origin = (float3(mcLightWord(xy.rg), mcLightWord(xy.ba), mcLightWord(zr.rg)) - 32768.0f) / 64.0f;
    float radius = mcLightWord(zr.ba) / 64.0f;
    float3 delta = origin - position;
    float distance2 = dot(delta, delta);
    float inverseDistance = rsqrt(max(distance2, 0.000001f));
    direction = delta * inverseDistance;
    float falloff = saturate(1.0f - distance2 * inverseDistance / max(radius, 0.015625f));
    falloff *= falloff;
    [branch] if (color.a > 0.5f && falloff > 0.0f)
    {
        float4 axis = tex2Dlod(data, float4(u + 3.0f / 64.0f, 0.5f, 0, 0));
        float4 cone = tex2Dlod(data, float4(u + 4.0f / 64.0f, 0.5f, 0, 0));
        float3 forward = mcLightDirection(float2(mcLightWord(axis.rg), mcLightWord(axis.ba)) / 65535.0f);
        float inner = mcLightWord(cone.rg) / 65535.0f;
        float outer = mcLightWord(cone.ba) / 65535.0f;
        float spot = saturate((dot(-direction, forward) - outer) / max(inner - outer, 0.00001526f));
        falloff *= spot * spot * (3.0f - 2.0f * spot);
    }
    return color.rgb * (16.0f * falloff);
}
#endif
