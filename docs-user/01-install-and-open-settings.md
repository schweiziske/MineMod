# Installation and settings

English | [简体中文](../docs/zh/user/01-install-and-open-settings.md)

## Installation

When subscribing through Workshop, also subscribe to the dependencies listed on the release page.

For manual installation, place each required addon in `garrysmod/addons/`. This repository's addons are under `addons/`; placing the entire repository in the game does not mount those nested directories.

| Addon | Purpose |
| --- | --- |
| `mc_engine` | Required: block world and building tools |
| `mc_texturepack_default` | Required: base textures and missing-texture fallback |
| `mc_shaderpack_vanilla` | Default Vanilla shader pack |
| `mc_game` | MC inventory, crafting, survival, and containers |
| `mc_item` | MC item weapons, models, materials, and sounds |
| `mc_shaderpack_pbr` | Optional PBR shader pack |
| `mc_texturepack_programmer_art` | Optional classic textures |
| `mc_texturepack_avpbr` | Optional AVPBR textures and PBR materials |

For your first session, install the first three addons plus `mc_game` and `mc_item`. Fully exit and restart the game after adding or replacing addons.

The Native module is an optional client acceleration component. Place the DLL matching your version and game architecture in the client's `garrysmod/lua/bin/`, then restart. Servers do not distribute DLLs automatically. See [Native installation](../docs/native.md#usage).

## Opening settings

Hold the default `C` key to open the context menu, then click **MC Config** at the top left.

Alternatively, enable the GMod developer console, open it with the default `~` key, and enter:

```text
mc_config
```

| Location | Purpose |
| --- | --- |
| Client settings → Interface → Home | Saves, resource pack manager, and game mode |
| Client settings → Interface → Resource packs | Change textures |
| Client settings → Interface → Shaders | Choose shader packs, presets, and parameters |
| Client settings → Interface → Language | Chinese, English, or follow GMod |
| Server settings | Administrator controls for permissions, saves, and world rules |

Use search to find settings. Click **Save** after entering a numeric value. Server settings take effect according to the server's response.

The default `mc_language auto` follows GMod's language, falling back to English for an unrecognized or unsupported language. You can select `zh_cn` or `en_us` manually. Existing language preferences are retained.

## Troubleshooting

- **Commands or MC weapons are missing:** check addon mounts, then fully restart.
- **Missing textures:** check that the client has `mc_texturepack_default`.
- **Server settings cannot be changed:** administrator permissions are required.
- **Rendering problems:** select Vanilla on the shader page. If the problem remains, run `mc_client_diag` and `mc_native_status`, and provide their output with reproduction steps.
