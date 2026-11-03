#ifndef MC_PBR_NORMAL_INCLUDED
#define MC_PBR_NORMAL_INCLUDED
float3 mcSafeNormalize(float3 value)
{
    // Adding the floor is one slot cheaper than max() in fxc output and
    // leaves every non-degenerate vector unchanged at float precision.
    return value * rsqrt(dot(value, value) + 1.0e-20f);
}

// Derivative frames jitter per pixel quad up close; block faces are
// axis-aligned, so near-axis normals snap exactly (diagonal plants keep theirs).
float3 mcSnapAxis(float3 value)
{
    // Half-integer components cannot pass the near-axis test below. Avoid
    // round()'s signed tie handling, which costs several SM3 instructions.
    float3 axis = floor(value + 0.5f);
    return abs(dot(axis, value) - 1.0f) < 0.02f ? axis : value;
}

float3 mcMappedNormal(float3 px, float3 py, float2 ux, float2 uy, float3 n, float3 map)
{
    float determinant = ux.x * uy.y - ux.y * uy.x;
    float handedness = determinant < 0.0f ? -1.0f : 1.0f;
    float3 t = px * uy.y - py * ux.y;
    float3 b = py * ux.x - px * uy.x;
    // t and b already lie in the face plane; skipping re-orthogonalisation
    // pays for the snap within the SM3 budget.
    n = mcSnapAxis(n);
    t = mcSafeNormalize(t);
    b = mcSafeNormalize(b);
    map.xy *= handedness;
    return mcSafeNormalize(t * map.x + b * map.y + n * map.z);
}
#endif
