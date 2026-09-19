# Material classification reference

The offline MCSWEP material responses in `_tools/pbr_materials.py` were
researched against Complementary Reimagined r5.9.3, whose official release
includes Minecraft 26.2 support:

- Release: https://modrinth.com/shader/complementary-reimagined/version/Bqen1mJX
- Source: https://github.com/ComplementaryDevelopment/ComplementaryReimagined
- Reference commit: `c09950df0650b27dac260c1b0f69afc11387aa6f`
- Upstream license: **Complementary License Agreement 1.7** (`License.txt`
  in the official release).

MCSWEP implements the researched block families, numerical material responses
and texture-region masks in its own offline atlas generator. The generated
maps use MCSWEP's source textures and its existing Filament-based BRDF. No
upstream GLSL source files or upstream shader-pack assets are included in this
addon, and the upstream shader pack is not a build dependency.

The separate direct-highlight and reflection controls, colour corrections,
dynamic state effects, refraction and reflection passes of Complementary are
not reproduced by a single ORM map. See the repository's
`docs/minecraft-26.2-pbr-material-port-2026-09-19.md` for the adaptation and
its limits, and `docs/minecraft-26.2-pbr-material-reference-2026-09-19.md` for
source locations.

This notice does not relicense Complementary under MCSWEP's or Filament's
license. The Filament notice documents the BRDF implementation separately.
