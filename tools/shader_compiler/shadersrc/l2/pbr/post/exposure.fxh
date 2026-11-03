// Independently implemented metering/adaptation math; see render-post-effects.md.
float mcExposureWeight(float luminance, float2 uv)
{
    float radius = sqrt(dot(uv - 0.5f, uv - 0.5f));
    float centre = 1.0f - smoothstep(0.4f, 0.6f, radius);
    return centre * pow(max(luminance, 0.01f), -0.7f);
}
float mcExposureAdapt(float luminance, float previous, float dt, float time)
{
    float encoded = pow(max(luminance, 0.0001f), 0.25f);
    float rate = encoded < previous ? 3.0f : 1.0f;
    return lerp(previous, encoded, 1.0f - exp(-rate * dt / time));
}
float mcExposureGain(float encoded, float key, float strength, float range)
{
    float luminance = encoded * encoded;
    luminance *= luminance;
    return clamp(pow(key / max(luminance, 0.0001f), strength), exp2(-range), exp2(range));
}
float mcExposureChannel(float colour, float gain)
{
    // Invert the fitted ACES curve, apply relative exposure, then re-map.
    // This cannot recover clipped HDR radiance from the existing LDR scene.
    float y = saturate(colour);
    float a = 2.51f - 2.43f * y;
    float b = 0.03f - 0.59f * y;
    float x = max(0.0f, (sqrt(b * b + 0.56f * a * y) - b) / (2.0f * a)) * gain;
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}
