# Resource packs

English | [简体中文](../docs/zh/user/05-resource-packs.md)

Resource packs change block textures, texture animations, and LabPBR companion maps. Full replacement of models, block states, GUIs, sounds, languages, and OptiFine CTM is not supported.

## Selecting a pack

1. Enter `mc_texture_packs`, or open **Interface → Resource packs** in `mc_config`.
2. Select a pack and click **Apply**.
3. If a pack-version warning appears, decide whether to try applying it.
4. Wait for preparation and baking to finish.

One pack is active at a time. Selecting an entry does not apply it until you click **Apply**. Successful changes save your preference for the next session; failures retain the previous working resources.

**Revert changes** discards the draft. **Restore defaults** selects the default pack. Keep the default texture addon installed to fill textures missing from other packs.

## Included packs

| Pack | Installation |
| --- | --- |
| Default | `mc_texturepack_default`, required |
| Programmer Art | `mc_texturepack_programmer_art`; source assets included |
| AVPBR | `mc_texturepack_avpbr`; source assets included |

Programmer Art and AVPBR generate their atlases automatically when applied. No offline baking script is required. AVPBR normal and specular effects also require the `mc:pbr` [shader pack](06-shader-packs.md).

Fully restart after installing or removing addons. Refreshing the manager does not mount new addons.

## Importing a Java resource pack

Extract it on the **client** to:

```text
garrysmod/data/mc/resourcepacks/inbox/MyPack/
  pack.mcmeta
  assets/
  pack.png       (optional cover)
```

`pack.mcmeta` must be directly inside `MyPack/`. Refresh the manager and apply the pack. Reading ZIPs directly requires a Native module with resource-pack I/O support; otherwise use an extracted directory.

Pack selection is client-side. Placing a pack only in a dedicated server's DATA directory does not install or select it for players. Different players can use different packs.

## Troubleshooting

- **Pack is not listed:** check the client path, `pack.mcmeta` nesting, and addon mounts.
- **Version warning:** applying only attempts to read compatible resources; it does not enable unsupported features such as model replacement.
- **Textures work but PBR effects are missing:** check companion maps and select PBR on the shader page.
- **Application fails:** record the manager error and console output. Restore the default pack to check the base resources.
