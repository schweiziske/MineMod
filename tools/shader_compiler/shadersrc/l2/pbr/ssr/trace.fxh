#ifndef MC_SSR_TRACE_INCLUDED
#define MC_SSR_TRACE_INCLUDED
// Perspective-correct screen-space traversal, informed by three.js SSRShader
// (MIT). Depth is GMod's linear clip-W / 4000 rather than a WebGL Z buffer.
// Fixed traversal, binary refinement, finite thickness and visibility fades
// avoid a temporal history or stochastic jitter that could trail camera motion.
float4 MCSSREye : register(c0);       // render-space eye, unused
float4 MCSSRLimits : register(c1);    // ray length, steps (8..48), base thickness, normal bias
float4 MCSSRDepthSize : register(c2); // width, height, reciprocal width/height
float4 MCSSRFootprint : register(c3); // trace/colour derivative scale XY, strength, precise MC depth
float4 MCSSRRight : register(c11);   // right XYZ, horizontal projection scale
float4 MCSSRUp : register(c12);      // up XYZ, vertical projection scale
float4 MCSSRForward : register(c13); // forward XYZ, near plane
float4 MCSSRViewport : register(c14);// normalized viewport origin XY, extent ZW
sampler2D MCSceneDepth : register(s1);

float4 mcSSRDepthSample(float2 uv)
{
    // The engine owns the sampler flags. Texel-centre LOD0 reads prevent
    // bilinear filtering from inventing geometry across foreground edges.
    float2 center = (floor(uv * MCSSRDepthSize.xy) + 0.5f) * MCSSRDepthSize.zw;
    return tex2Dlod(MCSceneDepth, float4(center, 0, 0));
}
float mcSSRDepth(float2 uv)
{
    return mcSSRDepthSample(uv).r * 4000.0f;
}
float mcSSRDepthError(float4 sample)
{
    // G identifies a winning MC surface in the shared RGBA16F depth. Native
    // geometry and legacy depth retain the larger eight-bit error allowance.
    return MCSSRFootprint.w > 0.5f && sample.g <= sample.r + 0.000001f
        ? max(0.0625f, sample.r * 3.90625f) : 2000.0f / 255.0f;
}
float3 mcSSRViewVector(float3 world)
{
    return float3(dot(world, MCSSRRight.xyz), dot(world, MCSSRUp.xyz), dot(world, MCSSRForward.xyz));
}
float2 mcSSRProject(float3 p)
{
    float2 uv = float2(p.x * MCSSRRight.w, -p.y * MCSSRUp.w) / p.z + 0.5f;
    return MCSSRViewport.xy + uv * MCSSRViewport.zw + MCSSRDepthSize.zw * 0.5f;
}

// Returns hit UV, receiver view depth, and confidence. A miss retains receiver
// depth with zero confidence, so the nearest water still owns the trace pixel.
float4 mcSSRTrace(float3 world, float3 normal, float3 incident)
{
    float3 receiver = mcSSRViewVector(world - MCSSREye.xyz);
    float4 miss = float4(0, 0, receiver.z, 0);
    float2 receiverUV = mcSSRProject(receiver);
    float4 receiverSample = mcSSRDepthSample(receiverUV);
    float sceneAtReceiver = receiverSample.r * 4000.0f;
    if (receiver.z < MCSSRForward.w || receiver.z > 3980.0f
        || sceneAtReceiver + MCSSRLimits.w + mcSSRDepthError(receiverSample) < receiver.z) return miss;

    float3 start = receiver + mcSSRViewVector(normal) * MCSSRLimits.w;
    float3 direction = mcSSRViewVector(reflect(incident, normal));
    float length = MCSSRLimits.x;
    if (direction.z < -0.0001f) length = min(length, (MCSSRForward.w - start.z) / direction.z);
    if (direction.z > 0.0001f) length = min(length, (3980.0f - start.z) / direction.z);
    if (length <= MCSSRLimits.w) return miss;
    float3 end = start + direction * length;
    float2 a = mcSSRProject(start), b = mcSSRProject(end);
    float2 delta = b - a;
    float2 low = MCSSRViewport.xy + MCSSRDepthSize.zw;
    float2 high = MCSSRViewport.xy + MCSSRViewport.zw - MCSSRDepthSize.zw;
    if (any(a < low) || any(a > high)) return miss;
    float2 safeDelta = float2(delta.x < 0 ? -1 : 1, delta.y < 0 ? -1 : 1) * max(abs(delta), 0.000001f);
    float2 exit = (float2(delta.x < 0 ? low.x : high.x, delta.y < 0 ? low.y : high.y) - a) / safeDelta;
    float fraction = saturate(min(exit.x, exit.y));
    delta *= fraction;
    float inverseStart = 1.0f / start.z;
    float inverseEnd = lerp(inverseStart, 1.0f / end.z, fraction);
    float2 pixels = abs(delta * MCSSRDepthSize.xy);
    float steps = min(MCSSRLimits.y, max(1.0f, ceil(max(pixels.x, pixels.y) * 0.5f)));
    float previous = 0;
    [loop] for (int index = 1; index <= 48; ++index)
    {
        if (index > steps) break;
        float along = index / steps;
        float2 uv = a + delta * along;
        float scene = mcSSRDepth(uv);
        float ray = 1.0f / lerp(inverseStart, inverseEnd, along);
        if (scene > 0.0f && scene < 3980.0f && ray >= scene)
        {
            float lo = previous, hi = along;
            [unroll] for (int refine = 0; refine < 5; ++refine)
            {
                float middle = (lo + hi) * 0.5f;
                float depth = mcSSRDepth(a + delta * middle);
                float z = 1.0f / lerp(inverseStart, inverseEnd, middle);
                if (depth > 0.0f && depth < 3980.0f && z >= depth) hi = middle;
                else lo = middle;
            }
            uv = a + delta * hi;
            float4 hitSample = mcSSRDepthSample(uv);
            scene = hitSample.r * 4000.0f;
            ray = 1.0f / lerp(inverseStart, inverseEnd, hi);
            float difference = ray - scene;
            // Stop at an occlusion discontinuity; searching past it would
            // reflect hidden objects through the front face of a wall.
            float thickness = MCSSRLimits.z + 2.0f * mcSSRDepthError(hitSample);
            if (difference < 0 || difference > thickness) return miss;
            float2 localUV = (uv - MCSSRViewport.xy - MCSSRDepthSize.zw * 0.5f) / MCSSRViewport.zw;
            float edge = saturate(min(min(localUV.x, localUV.y), min(1 - localUV.x, 1 - localUV.y)) / 0.06f);
            float3 hit = float3((localUV.x - 0.5f) * ray / MCSSRRight.w,
                               (0.5f - localUV.y) * ray / MCSSRUp.w, ray);
            float fade = saturate(1.0f - distance(hit, start) / MCSSRLimits.x);
            float confidence = edge * fade * saturate(1.0f - difference / thickness) * MCSSRFootprint.z;
            return float4(uv, receiver.z, confidence);
        }
        previous = along;
    }
    return miss;
}
#endif
