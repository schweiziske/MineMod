# Water rendering from three.js

The MCSWEP water shader contains HLSL adaptations of the official three.js
Water / Water2 shaders, distributed under the MIT license in LICENSE.
Copyright (c) 2010-2026 three.js authors.

Pinned upstream commit: `7300402f96c23bfa2174ffc0da01fb4e277d33da`.

- Water.js: https://github.com/mrdoob/three.js/blob/7300402f96c23bfa2174ffc0da01fb4e277d33da/examples/jsm/objects/Water.js
- Water2.js: https://github.com/mrdoob/three.js/blob/7300402f96c23bfa2174ffc0da01fb4e277d33da/examples/jsm/objects/Water2.js
- Normal image: https://github.com/mrdoob/three.js/blob/7300402f96c23bfa2174ffc0da01fb4e277d33da/examples/textures/waternormals.jpg
- Image SHA256: `add9912b158a4fe9c12421745babe68c44c8af75631ac4837236cb2a03bc373f`.

Adapted parts:

- Water.js `getNoise`: four normal samples at different spatial scales and
  velocities, their layered sum, and the 1.5 lateral normal scale.
- Water2: two half-cycle flow phases, their triangular crossfade, and Schlick
  Fresnel mixing of reflected and refracted colour.
- The normal image is reduced from 1024 square to 256 square and normalized
  by `_tools/build_pbr_water.py`; an independently generated alpha channel
  provides shoreline foam. The generated normal PNG is a derived asset.

Local adaptations:

- Source SM3 HLSL, centroid/derivative inputs, current-view scene-copy sampling,
  block-space coordinates and raw block/sky light. A common phase/crossfade
  spans still and flowing surfaces; sprite UV rotations no longer split the
  wave field at their shared edges.
- Top-surface shading uses a common vertical normal, while the true geometry
  still supplies shadow bias. Screen refraction projects surface derivatives
  off the viewing ray to avoid changes of basis at sloped/flat water joins.
- Spatial scales use 32 upstream units per block. Scales and velocities are
  rounded to integer cycles per 4096 blocks/seconds to keep coordinate and
  clock wraps continuous. At the existing wave setting 0.32, lateral normal
  scaling of the texture ripples equals upstream's 1.5; zero disables normal
  distortion. Two locally added analytic swells provide visible longer waves,
  with derivative filtering when they become subpixel.
- PNG normals explicitly use repeating, mipmapped, smooth sampling. Their
  import filename differs from the earlier clamped resource so cached imports
  cannot preserve CLAMPS/CLAMPT across the update.
- Mip variance controls GGX specular filtering. The existing Filament direct
  sun BRDF, shadow atlas and prefiltered sky environment remain in use.
- Transmission uses per-channel water extinction and the current framebuffer.
  This port does not include the upstream Reflector/Refractor scene rerenders;
  reflected buildings and entities are not supplied by the static sky atlas.

The original JavaScript sources are research references, not runtime or build
dependencies. The vendored JPEG is a build input; the addon includes the
generated PNG, this notice, and LICENSE.
