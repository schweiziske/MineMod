# Shader packs

English | [简体中文](../docs/zh/user/06-shader-packs.md)

Shader packs control shadows, reflections, exposure, and other effects. [Resource packs](05-resource-packs.md) control textures. Select them independently.

## Selection and settings

Open `mc_config → Client settings → Interface → Shaders` and select an installed pack:

| Pack | Purpose |
| --- | --- |
| Vanilla (`mc:vanilla`) | Default rendering |
| PBR (`mc:pbr`) | PBR materials, sunlight shadows, reflections, and screen effects; requires its addon |

The active pack supplies the parameters and presets below. Different packs may expose different options.

Enable the main switch and relevant entity types under **Lighting → Entity and vehicle lighting** to light players, NPCs, and props. If your saved player-lighting setting is disabled, enable it manually. PBR model shadows are separately controlled by `mc_pbr_shadow_entities`; Vanilla currently has no real-time model shadows.

PBR includes **Minimum, Low, Medium, High, Full** presets, with **High** as default. For better frame rates, try Low or Medium, or reduce reflections, volumetric lighting, shadow resolution, and shadow range.

Manual changes display **Custom**. **Save as** stores a user preset; built-in presets are read-only. The eye button in the title bar temporarily hides the window for inspecting the scene.

## Console commands

Run these in your client console:

| Command | Purpose |
| --- | --- |
| `mc_render_pack select mc:pbr` | Select PBR |
| `mc_render_pack select mc:vanilla` | Select Vanilla |
| `mc_render_pack off` | Return to default Vanilla; does not disable all rendering |
| `mc_render_pack_settings` | List the current pack's parameters, defaults, and ranges |
| `mc_render_pack_set <key> <value>` | Change a parameter |
| `mc_render_pack_reset` | Restore the pack's default preset |
| `mc_render_pack_preset list` | List presets |
| `mc_render_pack_preset apply builtin:low` | Apply PBR's built-in Low preset |

Shader settings and user presets reside on the client under `garrysmod/data/mc/shaderpacks/config/`. They are not part of world saves or ordinary ConVars.

## Rendering problems

Run `mc_render_pack_reset` for the affected pack. If the problem remains, return to Vanilla and check the shader addon, resource pack, and client console errors. Change PBR shadow parameters on the shader page; legacy `mc_shadow_*` variables do not replace the active pack's settings.
