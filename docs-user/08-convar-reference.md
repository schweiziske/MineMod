# ConVar quick reference: common settings

English | [简体中文](../docs/zh/user/08-convar-reference.md)

This page lists common settings. See the [complete ConVar reference](09-convar-complete.md) for all variables, generated pose parameters, and diagnostics.

Search and edit settings in `mc_config` first. Client settings affect your own client; change server settings in the server console or the administrator settings page.

Enter a variable name in the appropriate console to read its current value; append a value to change it, for example:

```text
mc_language en_us
```

The tables list source defaults; saved configuration and server rules may override them. Use `find mc_` or `find mcitem_` to inspect settings registered in the current process.

## Client

| Variable | Default | Description |
|---|---|---|
| `mc_language` | `auto` | Follow GMod, falling back to English; also accepts `zh_cn` and `en_us` |
| `mc_join_notice` | `1` | Show control hints on joining |
| `mc_gamemode` | `creative` | Request a personal mode change, confirmed by the server |
| `mc_inventory_hud_scale` | `0` | Survival HUD scale; 0 automatic |
| `mc_inventory_ui_scale` | `0` | Inventory/container UI scale; 0 automatic |
| `mc_inventory_hud_offset_x`, `mc_inventory_hud_offset_y` | `0` | HUD offset in pixels |
| `mc_inventory_ui_offset_x`, `mc_inventory_ui_offset_y` | `0` | Inventory UI offset |
| `mc_inventory_return_button` | `1` | Inventory return button |
| `mc_item_drop_draw_distance` | `96` | Item-drop draw distance, blocks |
| `mc_mesh_render` | `1` | Show world meshes; collision remains when disabled |
| `mc_light_atlas_size` | `auto` | Lighting atlas: Auto (largest supported), `16384`, `8192`, or `4096`; manual sizes must be supported; reconnect to apply |
| `mc_mesh_draw_distance` | `0` | Draw distance, Source units; 0 uses the deferred-build distance when enabled, otherwise unlimited |
| `mc_mesh_build_preset` | `fast` | Build scheduling: smooth, fast, loading; custom after manual budget changes |
| `mc_client_collision` | `1` | Local prediction collision |
| `mc_dynamic_lights` | `1` | Dynamic lights |
| `mc_dynamic_flashlight` | `1` | Blocks receive flashlight beams |
| `mc_light_entity` | `0` | Entities receive MC lighting |
| `mc_light_entity_players` | `1` | Players receive MC lighting; enable it in settings if an older configuration has 0 |
| `mc_light_entity_npcs` | `1` | NPCs and NextBots receive MC lighting |

### MC Item

Requires `mc_item`. Change all settings below on the client.

| Variable | Default | Description |
|---|---|---|
| `mcitem_crosshair` | `1` | MC crosshair |
| `mcitem_attack_indicator` | `1` | Attack progress: 0 off, 1 at the crosshair |
| `mcitem_crosshair_invert` | `1` | Inverted-color crosshair blending |
| `mcitem_hud_scale` | `2` | Crosshair/attack indicator scale; 0 automatic |
| `mcitem_block_outline` | `1` | Selected-block outline while holding MC Item |
| `mcitem_view_bob` | `1` | Held-item walking bob multiplier; 0 off |
| `mcitem_view_sway` | `1` | Held-item lag when turning; 0 off |
| `mcitem_name_tag_scale` | `2.5` | Name-tag text scale |

## Server permissions and gameplay

| Variable | Default | Description |
|---|---|---|
| `mc_admin_only` | `0` | 1 restricts block editing to administrators |
| `mc_default_gamemode` | `creative` | New-player mode; preserves a player's saved mode |
| `mc_allow_gamemode_switch` | `1` | Allow regular players to change their own mode |
| `mc_inventory_persist` | `1` | Save player inventories |
| `mc_keep_inventory` | `0` | 1 preserves inventory and equipment on death |
| `mc_use_interact` | `1` | Right-click usable MC blocks to interact |
| `mc_save_public` | `0` | 1 allows listing, saving, and loading; deletion remains administrator-only |
| `mc_preset_public` | `0` | 1 allows listing, saving, loading, and placing presets |
| `mc_cluster_public` | `0` | 1 allows the structure mover |
| `mc_workshop_manage` | `0` | Workshop permissions: 0 superadmins, 1 admins, 2 everyone |
| `mc_autosave` | `0` | Save interval in seconds; 0 off; writes the map's default save |

## Server building limits

| Variable | Default | Description |
|---|---|---|
| `mc_world_limit` | `1024` | Maximum absolute block coordinate on each axis |
| `mc_max_blocks` | `0` | World block limit; 0 unlimited |
| `mc_fill_max` | `100000` | Maximum volume per fill; 0 unlimited |
| `mc_import_max` | `0` | Maximum blocks per import; 0 unlimited |
| `mc_preset_max_blocks` | `100000` | Maximum non-air preset blocks; 0 unlimited |
| `mc_block_damage` | `1` | Allow GMod damage to break blocks |

`mc_reach` controls player editing distance in Source units. Its default is calculated from block size; 0 disables the distance check.

## Shader settings and troubleshooting

Use the [shader settings page](06-shader-packs.md) or `mc_render_pack_settings` to inspect the current shader pack's parameters. For example, PBR shadow resolution uses the pack's `shadow_resolution`, separately from the legacy `mc_shadow_size`.

| Command | Purpose |
|---|---|
| `mc_client_diag` | Client diagnostics |
| `mc_native_status` | Native backend status |
| `mc_save_diag` | Server save diagnostics |

When reporting an issue, include the complete error, reproduction steps, and selected resource and shader packs.
