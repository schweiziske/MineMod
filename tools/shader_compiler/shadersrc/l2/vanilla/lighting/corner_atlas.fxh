#ifndef MC_CORNER_ATLAS_INCLUDED
#define MC_CORNER_ATLAS_INCLUDED
// Keep bank-local RGB addresses. layout = bank + 64 * (16384 / size - 1).
// Return corner coordinates, inverse physical size, and one-quarter row width.
float4 mcCornerAtlasPixel(float2 address, float layout)
{
    float scaleCode = floor(layout / 64.0f);
    float scale = scaleCode + 1.0f;
    float bank = layout - scaleCode * 64.0f;
    float columns = 8.0f / scale;
    address = floor(address + 0.5f);
    float row = floor(address.y * (scale * 0.125f));
    return float4((address.x + (address.y - row * columns) * 512.0f) * 4.0f,
                  row + bank * (256.0f * scale), scale / 16384.0f, columns * 512.0f);
}
float2 mcCornerAtlasUV(float4 pixel)
{
    return float2(pixel.x + 0.5f, floor((pixel.y + 0.5f) * 1.25f) + 0.5f) * pixel.z;
}
float2 mcCornerAtlasAO(float4 pixel)
{
    float group = floor(pixel.y * 0.25f);
    return float2(pixel.x * 0.25f + (pixel.y - group * 4.0f) * pixel.w + 0.5f,
                  group * 5.0f + 2.5f) * pixel.z;
}
#endif
