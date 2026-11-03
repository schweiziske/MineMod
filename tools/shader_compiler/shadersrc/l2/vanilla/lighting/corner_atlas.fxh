#ifndef MC_CORNER_ATLAS_INCLUDED
#define MC_CORNER_ATLAS_INCLUDED
// RGB addresses stay local to a 1,048,576-quad bank. Repack the old 512
// quad columns into a 16K-wide atlas; each bank occupies 256 corner rows.
float2 mcCornerAtlasPixel(float2 address, float bank)
{
    address = floor(address + 0.5f);
    float row = floor(address.y * 0.125f);
    return float2((address.x + (address.y - row * 8.0f) * 512.0f) * 4.0f,
                  row + bank * 256.0f);
}
float2 mcCornerAtlasUV(float2 pixel)
{
    return float2(pixel.x + 0.5f, floor((pixel.y + 0.5f) * 1.25f) + 0.5f) / 16384.0f;
}
float2 mcCornerAtlasAO(float2 pixel)
{
    float group = floor(pixel.y * 0.25f);
    return float2(pixel.x * 0.25f + (pixel.y - group * 4.0f) * 4096.0f + 0.5f,
                  group * 5.0f + 2.5f) / 16384.0f;
}
#endif
