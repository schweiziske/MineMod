# Filament references and adaptations

This project's PBR implementation adapts algorithms and expressions from
[Google Filament](https://github.com/google/filament), distributed under the
[Apache License 2.0](LICENSE), at commit
`9eb21d78b68ed7b161d96a1aaadfac9b8bdca282`.

Referenced files:

- `shaders/src/surface_brdf.fs`: GGX distribution, height-correlated Smith
  visibility and Schlick Fresnel.
- `shaders/src/surface_light_indirect.fs`: GGX importance sampling,
  prefiltered split-sum IBL, dominant reflection direction and diffuse
  irradiance from the roughness-one level.
- `shaders/src/surface_shading_lit.fs`: multiple-scattering energy compensation.
- `shaders/src/surface_ambient_occlusion.fs`: Lagarde's view- and
  roughness-dependent specular occlusion.

Adaptations use HLSL Shader Model 3 and this project's existing vertex/lightmap
layout. The offline baker stores a two-dimensional octahedral roughness atlas
in RGBM64 instead of Filament's floating-point cubemap. Its DFG texture stores
16-bit A and B for `F0*A+B`; Filament stores B and A+B. The compensation term is
converted consistently. These are project-specific changes, not an integration
of the Filament renderer or its full feature set.
The shared Minecraft corner byte combines directional shading and occlusion.
This adapter uses its conservative lower range as an occlusion estimate; it
does not expose Filament's bent-normal or screen-space occlusion paths.

The environment is **Kloofendal 48d Partly Cloudy**, by **Greg Zaal / Poly Haven**,
under **CC0-1.0**: https://polyhaven.com/a/kloofendal_48d_partly_cloudy
and https://polyhaven.com/license.
Attribution and the pinned download fingerprint are stored in the repository's
`shadersrc/l2/pbr_assets/environment.json` and bundled in the shader addon's
`third_party/polyhaven/environment.json`.
It is a static captured environment, not a reflection capture of the GMod world.
