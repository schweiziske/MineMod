#ifndef MC_VANILLA_TINT_INCLUDED
#define MC_VANILLA_TINT_INCLUDED
float3 mcVanillaTintBytes(float code)
{
    if (code < 0.5f) return 255.0f;
    if (code < 16.5f)
    {
        float power = code - 1.0f;
        float red = power < 0.5f ? 76.0f : floor(102.0f + power * 10.2f);
        float green = power < 12.5f ? 0.0f : (power < 13.5f ? 6.0f : (power < 14.5f ? 27.0f : 50.0f));
        return float3(red, green, 0.0f);
    }
    if (code < 24.5f)
    {
        float age = code - 17.0f;
        return float3(age * 32.0f, 255.0f - age * 8.0f, age * 4.0f);
    }
    if (code < 25.5f) return float3(224.0f, 199.0f, 28.0f);
    return 255.0f;
}
#endif
