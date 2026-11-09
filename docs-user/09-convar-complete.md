# Complete ConVar reference

English | [简体中文](../docs/zh/user/09-convar-complete.md)

For common settings, see the [ConVar quick reference](08-convar-reference.md). This page lists variables registered by the current source, including generated pose parameters, internal migration markers, and options retained in the legacy entry point.

## Reading this reference

- Defaults are source registration values; saved configuration, server synchronization, and version migrations may change the effective values.
- Change client variables in your own console and server variables in the server console. Single-player also distinguishes these realms.
- Enter the full variable name in the console to read its value; append a value to change it. Quote values containing spaces; use `""` for an empty string.
- Variables belonging to `mc_item` require that addon to be installed and loaded. Variables created on demand may appear only after a related entity is first rendered.
- Shader-pack parameters such as `shadow_resolution` are not ConVars; see [Shader packs](06-shader-packs.md).

The current entry point and built-in on-demand registrations define **963 unique names**, plus **6 variables exclusive to the legacy entry point**. Every full name is listed below, including generated suffixes.

Units are specified in the description column. One block currently defaults to 36.5 Source units; source defaults that depend on block size are expanded numerically here, which does not mean runtime code should hard-code that size.

Use `find mc_`, `find mcitem_`, or `find bmb_item_test_fp_` to inspect variables registered in the current process. Console commands and variables from other addons or the engine are excluded.

## Contents

- [Interface and pack selection](#convars-1)
- [Server permissions, building, and saves](#convars-2)
- [Day/night, block updates, and survival](#convars-3)
- [Block damage and explosions](#convars-4)
- [Structure entities](#convars-5)
- [Networking and chunk streaming](#convars-6)
- [Collision and prediction](#convars-7)
- [Mesh building and drawing](#convars-8)
- [Lighting and compatibility rendering parameters](#convars-9)
- [Creative-mode held blocks](#convars-10)
- [MC Item: gameplay and presentation](#convars-11)
- [MC Item: shared first-person anchors](#convars-12)
- [MC Item: per-item first-person anchors](#convars-13)
- [MC Item: use-pose offsets and stretching](#convars-14)
- [MC Item: cocked-pose offsets](#convars-15)
- [MC Item: swing component multipliers](#convars-16)
- [MC Item: third-person animation types](#convars-17)
- [MC Item: third-person state models](#convars-18)
- [MC Item: third-person poses](#convars-19)
- [MC Item: projectile model orientation](#convars-20)
- [Debugging and performance diagnostics](#convars-21)
- [Internal migration markers](#convars-22)
- [Options retained in the legacy Native entry point](#convars-23)

<a id="convars-1"></a>

## Interface and pack selection

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_gamemode` | `creative` | Client | Request your game mode: creative / 1 or survival / 0; confirmed by the server |
| `mc_inventory_hud_offset_x` | `0` | Client | Survival HUD horizontal offset, pixels |
| `mc_inventory_hud_offset_y` | `0` | Client | Survival HUD vertical offset, pixels |
| `mc_inventory_hud_scale` | `0` | Client | Survival HUD scale cap; 0 automatic, positive values still limited by resolution |
| `mc_inventory_return_button` | `1` | Client | Show a Return to GMod button below the inventory |
| `mc_inventory_ui_offset_x` | `0` | Client | Inventory horizontal offset, pixels |
| `mc_inventory_ui_offset_y` | `0` | Client | Inventory vertical offset, pixels |
| `mc_inventory_ui_scale` | `0` | Client | Inventory/container scale cap; 0 automatic, positive values still limited by resolution |
| `mc_item_drop_draw_distance` | `96` | Client | Drop draw distance, blocks; 0 disables distance culling |
| `mc_join_notice` | `1` | Client | Show the settings-entry notice on joining |
| `mc_language` | `auto` | Client | Follow GMod by default; unsupported/unrecognized languages fall back to English; zh_cn Chinese, en_us English |
| `mc_render_pack_saved` | `mc:vanilla` | Client | Shader pack ID selected on joining; saved by mc_render_pack select / off |
| `mc_texture_pack` | `mc_default_raw` | Client | Current resource-pack ID |

Source: [mc_load.lua](../addons/mc_engine/lua/autorun/mc_load.lua), [cl_mesh_config.lua](../addons/mc_engine/lua/mc/render/cl_mesh_config.lua), [cl_render_pack_runtime.lua](../addons/mc_engine/lua/mc/render/cl_render_pack_runtime.lua), [sh_game_mode.lua](../addons/mc_engine/lua/mc/sh_game_mode.lua), [sh_i18n.lua](../addons/mc_engine/lua/mc/sh_i18n.lua), [cl_init.lua](../addons/mc_game/lua/entities/mc_item_drop/cl_init.lua), [cl_theme.lua](../addons/mc_game/lua/mcgame/inventory/ui/cl_theme.lua).

<a id="convars-2"></a>

## Server permissions, building, and saves

The server controls permissions and effective game rules. A name containing client does not imply that clients can change it.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_admin_only` | `0` | Server | Restrict block placement and breaking to administrators |
| `mc_allow_gamemode_switch` | `1` | Server | Allow players to switch their own creative/survival mode |
| `mc_autosave` | `0` | Server | Autosave interval, seconds; 0 off; writes the current map's default slot |
| `mc_cluster_public` | `0` | Server | Allow ordinary players to use the structure mover |
| `mc_default_gamemode` | `creative` | Server | New-player default: creative or survival; preserves saved player modes |
| `mc_fill_batch_cells` | `4096` | Server | Maximum cells processed per server /fill batch |
| `mc_fill_batch_chunks` | `16` | Server | Maximum chunks touched per server /fill batch |
| `mc_fill_batch_interval` | `0.05` | Server | Interval between server /fill batches, seconds |
| `mc_fill_max` | `100000` | Server | Maximum volume per /fill; 0 unlimited |
| `mc_import_max` | `0` | Server | Maximum blocks per world import; 0 unlimited |
| `mc_inventory_action_rate` | `80` | Server | Allowed server inventory actions per player per second |
| `mc_inventory_persist` | `1` | Server | Persist player MC inventory by SteamID64 |
| `mc_keep_inventory` | `0` | Server | Keep MC inventory and equipment on death |
| `mc_max_blocks` | `0` | Server | World block-count limit; 0 unlimited |
| `mc_preset_max_blocks` | `100000` | Server | Maximum non-air blocks saved/placed per preset; 0 unlimited |
| `mc_preset_public` | `0` | Server | Allow ordinary players to list, save, load, and place presets |
| `mc_reach` | `182.5` | Server | Placement/breaking reach, Source units; default five block sizes; 0 disables checks |
| `mc_save_public` | `0` | Server | Allow ordinary players to list/save/load saves; deletion remains administrator-only |
| `mc_use_interact` | `1` | Server | Right-click interacts with usable aimed MC blocks; E is not block interaction |
| `mc_workshop_manage` | `0` | Server | Workshop publishing/import permissions: 0 superadmin, 1 admin, 2 everyone |
| `mc_world_limit` | `1024` | Server | Maximum absolute block coordinate on each axis |

Source: [sh_config.lua](../addons/mc_engine/lua/mc/sh_config.lua), [sh_game_mode.lua](../addons/mc_engine/lua/mc/sh_game_mode.lua), [sv_presets.lua](../addons/mc_engine/lua/mc/sv_presets.lua), [sv_saves.lua](../addons/mc_engine/lua/mc/sv_saves.lua), [sv_workshop.lua](../addons/mc_engine/lua/mc/workshop/sv_workshop.lua).

<a id="convars-3"></a>

## Day/night, block updates, and survival

This section is server-controlled. mc_gameplay_parity_* is also registered in the shared realm; server registrations are replicated. The server executes the actual physics and interactions.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_atmos_fixed_time` | `7` | Server | Locked Atmos time, decimal hours, 0–24 |
| `mc_atmos_time_locked` | `0` | Server | When Atmos is installed, lock its time to mc_atmos_fixed_time |
| `mc_block_update_max_cells_per_tick` | `16384` | Server | Soft limit on transaction cells produced by block updates per logical tick |
| `mc_block_update_max_depth` | `64` | Server | Maximum asynchronous neighbor-update chain depth |
| `mc_block_update_max_per_tick` | `4096` | Server | Maximum block-update callbacks per 20 TPS logical tick |
| `mc_block_update_max_queue` | `262144` | Server | Combined queue limit for ready and scheduled block updates |
| `mc_block_updates_enabled` | `1` | Server | Enable neighbor-update queues and scheduled block ticks |
| `mc_daycycle` | `0` | Server | MC day/night cycle; when off, use the map's sun direction |
| `mc_daycycle_follow_atmos` | `0` | Server | Follow the Atmos clock when installed |
| `mc_daycycle_length` | `1200` | Server | Real seconds per complete MC day |
| `mc_daycycle_paused` | `0` | Server | Pause the MC day/night clock |
| `mc_farming_mob_griefing` | `1` | Server | Allow non-player living entities to trample farmland |
| `mc_fire_tick` | `1` | Server | Let fire age and extinguish; unsupported fire is still removed |
| `mc_gameplay_parity_block_physics` | `0` | Server | MC physics for ice, honey, cobwebs, soul-related blocks, and slime |
| `mc_gameplay_parity_decorations` | `0` | Server | MC rules for paintings, armor stands, and item frames |
| `mc_gameplay_parity_item_entity` | `0` | Server | MC physics and lifetime rules for dropped-item entities |
| `mc_gameplay_parity_logistics` | `0` | Server | MC logistics for hoppers, dispensers, and droppers |
| `mc_random_tick_max_callbacks_per_tick` | `1024` | Server | Maximum random-tick callbacks per logical tick; also counts toward the total update budget |
| `mc_random_tick_max_samples_per_tick` | `4096` | Server | Maximum sampled block positions per logical random-tick production pass |
| `mc_random_tick_max_sections_per_tick` | `1024` | Server | Maximum loaded 16³ sections checked per logical random-tick production pass |
| `mc_random_tick_speed` | `3` | Server | Random samples per eligible 16³ section per logical tick |
| `mc_redstone_input_scan_budget` | `256` | Server | Maximum active pressure-plate/daylight inputs checked every 0.1 seconds |
| `mc_water_clear_flowing` | `0` | Server | Remove standalone flowing water, preserving sources and waterlogged blocks |
| `mc_water_source_conversion` | `1` | Server | Allow adjacent supported water sources to create new sources |

Source: [sv_scheduler.lua](../addons/mc_engine/lua/mc/block_update/sv_scheduler.lua), [sh_core.lua](../addons/mc_engine/lua/mc/daycycle/sh_core.lua), [sv_atmos.lua](../addons/mc_engine/lua/mc/daycycle/sv_atmos.lua), [sv_trampling.lua](../addons/mc_engine/lua/mc/farming/sv_trampling.lua), [sv_water_cleanup.lua](../addons/mc_engine/lua/mc/liquid/sv_water_cleanup.lua), [sv_water_state.lua](../addons/mc_engine/lua/mc/liquid/sv_water_state.lua), [sv_inputs.lua](../addons/mc_engine/lua/mc/redstone/sv_inputs.lua), [sh_config.lua](../addons/mc_engine/lua/mc/sh_config.lua), [sh_rules.lua](../addons/mc_game/lua/mcgame/block_physics/sh_rules.lua), [sh_rules.lua](../addons/mc_game/lua/mcgame/decoration/sh_rules.lua), [sh_rules.lua](../addons/mc_game/lua/mcgame/item_entity/sh_rules.lua), [sh_rules.lua](../addons/mc_game/lua/mcgame/logistics/sh_rules.lua).

<a id="convars-4"></a>

## Block damage and explosions

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_block_damage` | `1` | Server | Allow GMod damage to break MC blocks |
| `mc_block_damage_decay` | `5` | Server | Retention time for partial block damage, seconds |
| `mc_block_explosion_fx_limit` | `16` | Server | Maximum break particle/sound groups broadcast per explosion; 0 disables broadcasts |
| `mc_block_explosion_max_blocks` | `4096` | Server | Maximum MC blocks broken per GMod explosion; 0 unlimited |
| `mc_block_explosion_max_radius` | `8` | Server | Maximum MC explosion radius, blocks |
| `mc_block_explosion_scale` | `0.04` | Server | GMod explosion damage to MC explosion-radius multiplier |
| `mc_block_health_scale` | `20` | Server | Block hardness to health multiplier |

Source: [sh_config.lua](../addons/mc_engine/lua/mc/sh_config.lua).

<a id="convars-5"></a>

## Structure entities

The server controls these limits. Avoid arbitrarily increasing exact-collision parameters: the source identifies a risk of crashing Source physics.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_cluster_collision_inset` | `0.5` | Server | Inset per cluster collision face, Source units; 0 no inset |
| `mc_cluster_health_per_block` | `4` | Server | Cluster health per block; 0 indestructible |
| `mc_cluster_mass_per_block` | `10` | Server | Cluster mass per block, kg |
| `mc_cluster_max_blocks` | `8191` | Server | Maximum blocks per cluster; protocol hard limit 8191 |
| `mc_cluster_max_convexes` | `64` | Server | Convex count cap in exact-collision mode; box mode is exempt; increasing risks server crashes |
| `mc_cluster_max_extent` | `96` | Server | Maximum cluster-selection edge length, blocks |
| `mc_cluster_max_per_player` | `8` | Server | Maximum clusters per player; 0 unlimited |
| `mc_cluster_merge_cells` | `8` | Server | Maximum merged collision-box edge, cells; values above 8 risk physics-engine crashes |

Source: [sh_block_cluster.lua](../addons/mc_engine/lua/mc/sh_block_cluster.lua).

<a id="convars-6"></a>

## Networking and chunk streaming

The server controls data streaming; the two client unload options control only local cleanup budgets.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_binary_chunk_patch` | `1` | Server | Use palette/packed-word binary section patches instead of terrain JSON |
| `mc_chunk_http_base_url` | `""` | Server | HTTP root serving lazy-save manifests/parts under garrysmod/data |
| `mc_chunk_http_enabled` | `0` | Server | Fetch lazy-save base chunks over HTTP instead of GMod net |
| `mc_chunk_store_frame_ms` | `3` | Server | Approximate hydration budget per storage tick, milliseconds |
| `mc_chunk_store_loads_per_tick` | `8` | Server | Maximum lazy chunks hydrated per storage tick |
| `mc_chunk_store_part_cache` | `8` | Server | Maximum cached v8 lazy-save part files in memory |
| `mc_chunk_streaming` | `0` | Server | Enable server-controlled horizontal chunk-column streaming |
| `mc_large_world_chunk_threshold` | `2048` | Server | Imported-save chunk threshold for recommending lazy streaming |
| `mc_large_world_lazy_load` | `0` | Server | Legacy v8 lazy-loading switch; default is direct server loading |
| `mc_stream_chunk_span_xy` | `8` | Server | Horizontal subscription-column radius; sends complete vertical columns |
| `mc_stream_chunk_span_z` | `0` | Server | Reserved; current streaming sends full columns without a separate Z radius |
| `mc_stream_columns_per_batch` | `1` | Server | Maximum new subscribed columns per streaming interval |
| `mc_stream_interval` | `0.3` | Server | Server chunk-column interest update interval, seconds |
| `mc_stream_max_patch_cells` | `32768` | Server | Maximum non-air cells per streaming patch |
| `mc_stream_max_patch_chunks` | `16` | Server | Maximum nonempty chunks per streaming patch |
| `mc_stream_unload_chunks_per_frame` | `1` | Client | Detached streamed chunks cleaned per client frame |
| `mc_stream_unload_frame_ms` | `3` | Client | Detached streamed-chunk cleanup budget per client frame, milliseconds |
| `mc_stream_unload_margin` | `2` | Server | Additional retained column radius before unloading |
| `mc_sync_frame_ms` | `4` | Server | Approximate full-sync CPU budget per server tick, milliseconds |
| `mc_sync_inflight_limit` | `32768` | Server | Maximum unacknowledged reliable state bytes per player |
| `mc_sync_messages_per_tick` | `4` | Server | Maximum queued reliable state messages per player per 0.05 seconds |
| `mc_sync_reliable_budget` | `3400` | Server | Hard queued reliable state byte budget per player per 0.05 seconds |

Source: [cl_net.lua](../addons/mc_engine/lua/mc/cl_net.lua), [sh_config.lua](../addons/mc_engine/lua/mc/sh_config.lua).

<a id="convars-7"></a>

## Collision and prediction

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_bulk_collision_chunks_per_interval` | `1` | Server | Server collision chunks rebuilt per interval after explosion/preset bulk edits |
| `mc_bulk_collision_interval` | `0.12` | Server | Server bulk-edit collision rebuild interval, seconds |
| `mc_client_collision` | `1` | Client | Build local movement-prediction collision; 0 uses only server collision |
| `mc_client_collision_aim_radius` | `1` | Server | Server-defined client aim-prediction collision radius, blocks |
| `mc_client_collision_chunk_span` | `1` | Client | Enable a small prediction AABB near the player; 0 off; not a general chunk radius |
| `mc_client_collision_cross_chunk` | `0` | Client | Allow client prediction collision interest to extend into adjacent chunks |
| `mc_collision_aim_distance` | `18688` | Server | Aim-collision interest trace distance, Source units; separate from building reach |
| `mc_server_collision` | `1` | Server | Build server-authoritative block collision |
| `mc_server_collision_aabb_padding` | `36.5` | Server | Player/entity collision-interest AABB padding, Source units; default one block size |
| `mc_server_collision_aim_radius` | `1` | Server | Server collision radius around the player's aimed block, blocks |
| `mc_server_collision_chunk_span` | `0` | Server | Extra chunk radius beyond server collision AABBs |
| `mc_server_collision_hot_span` | `2` | Server | Chunk span for velocity-lookahead collision interest |
| `mc_server_collision_lookahead_max` | `4` | Server | Maximum chunk radius of velocity-lookahead expansion |
| `mc_server_collision_lookahead_time` | `0.5` | Server | Entity velocity lookahead time, seconds |

Source: [cl_collision.lua](../addons/mc_engine/lua/mc/render/cl_collision.lua), [sh_config.lua](../addons/mc_engine/lua/mc/sh_config.lua).

<a id="convars-8"></a>

## Mesh building and drawing

All options are client-side. Native drawing requires an active L2 backend; setting the switch to 1 does not mean the module loaded.

Scheduling presets specify build milliseconds / bulk-geometry milliseconds / sections per frame: smooth = 3 / 3 / 16, fast = 8 / 8 / 64, loading = 20 / 20 / 128. A single section upload cannot be split and can still exceed the frame budget.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_build_unlimited` | `0` | Client | Remove client build/cleanup budgets and lazy-mesh deferral; process incoming jobs continuously |
| `mc_explosion_mesh_frame_ms` | `8` | Client | Per-frame Lua budget for paced geometry tasks such as explosions/pack changes, milliseconds |
| `mc_explosion_mesh_sections_per_frame` | `64` | Client | Render sections processed per frame by paced geometry tasks |
| `mc_gc_smoothing` | `0` | Client | Global client Lua GC smoothing: 0 restore previous settings; larger values 1–16 request smaller steps; atomic pauses remain possible |
| `mc_mesh_begin_upload` | `1` | Client | Upload IMesh vertices with mesh.Begin instead of BuildFromTriangles |
| `mc_mesh_block_emit_cache_sections` | `1536` | Client | Section cap for per-block vertex/light caches; lowering increases full rebuild work |
| `mc_mesh_build_frame_ms` | `8` | Client | Approximate Lua geometry/light rebuild budget per frame, milliseconds; Native path controls only deferred builds; 0 unlimited |
| `mc_mesh_build_preset` | `fast` | Client | Scheduling preset: smooth, fast, loading, custom; manual budget changes select custom |
| `mc_mesh_connection_visible_template` | `1` | Client | Experimental visible-geometry template cache for connected fences, panes, walls, and pipes |
| `mc_mesh_cull_mode` | `ccw` | Client | Mesh face culling direction: cw or ccw |
| `mc_mesh_directional_cull` | `0` | Client | Experimental six-direction opaque meshes; may increase DX9 draws; switching rebuilds meshes |
| `mc_mesh_directional_min_blocks` | `64` | Client | Split face directions only for render sections with at least this many blocks |
| `mc_mesh_draw_distance` | `0` | Client | Draw distance, Source units; 0 uses lazy-build distance when enabled, otherwise unlimited |
| `mc_mesh_frustum_cull` | `1` | Client | Cull 8³ render sections outside the frustum |
| `mc_mesh_geometry_cache_sections` | `384` | Client | Section cap retaining Lua vertex/light data for recoloring; lower values save memory |
| `mc_mesh_lazy_build` | `0` | Client | Retain full client world data but build meshes only within view distance |
| `mc_mesh_lazy_distance` | `10000` | Client | Lazy-build distance, Source units; also draw distance when the explicit value is 0 |
| `mc_mesh_occlusion_cull` | `1` | Client | Conservative section-connectivity occlusion culling; unknown/transparent space stays open |
| `mc_mesh_render` | `1` | Client | Draw world meshes; disabling does not affect collision |
| `mc_native_draw` | `1` | Client | Native L2 batched drawing; 0 uses Lua drawing for comparison |
| `mc_native_draw_directions` | `1` | Client | Skip back-facing L2 index ranges without splitting meshes |
| `mc_native_draw_worker` | `1` | Client | Compute conservative L2 visibility on a background thread |
| `mc_native_mesh` | `0` | Client | L2 mesh backend: 0 Lua, 1 Native corner lighting and indexed-mesh uploads; requires the module |

Source: [cl_gc.lua](../addons/mc_engine/lua/mc/cl_gc.lua), [cl_collision.lua](../addons/mc_engine/lua/mc/render/cl_collision.lua), [cl_dirty.lua](../addons/mc_engine/lua/mc/render/cl_dirty.lua), [cl_draw.lua](../addons/mc_engine/lua/mc/render/cl_draw.lua), [cl_mesh_cache.lua](../addons/mc_engine/lua/mc/render/cl_mesh_cache.lua), [cl_mesh_config.lua](../addons/mc_engine/lua/mc/render/cl_mesh_config.lua), [cl_mesh_presets.lua](../addons/mc_engine/lua/mc/render/cl_mesh_presets.lua), [cl_native_mesh_config.lua](../addons/mc_engine/lua/mc/render/cl_native_mesh_config.lua), [cl_render_section_cull.lua](../addons/mc_engine/lua/mc/render/cl_render_section_cull.lua).

<a id="convars-9"></a>

## Lighting and compatibility rendering parameters

All entries are registered on the client. Legacy chunk-shader, Fancy, and custom shadow-map/heightfield options remain registered; the current shader pack may not use them. Query PBR pack parameters such as shadows and bloom with mc_render_pack_settings. The legacy mc_shadow_size is separate from PBR shadow_resolution.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_daycycle_moon_light` | `3` | Client | Deep-night skylight level, 0–15 |
| `mc_daycycle_moon_shadow` | `0.3` | Client | Legacy moon-shadow strength relative to sun shadows; 0 no moon shadow |
| `mc_daycycle_night_tint` | `0.35` | Client | Night-sky blue surface tint strength; 0 neutral |
| `mc_daycycle_sun_tilt` | `0.2` | Client | Lateral sun-path tilt to avoid axis-aligned shadows |
| `mc_dynamic_flashlight` | `1` | Client | MC surfaces receive MC and Source flashlight beams |
| `mc_dynamic_lights` | `1` | Client | Moving lights for Vanilla and shader packs |
| `mc_dynamic_lights_max` | `8` | Client | Maximum visible moving lights |
| `mc_light_ambient_min` | `0` | Client | Minimum vertex-light brightness multiplier |
| `mc_light_bloom` | `1` | Client | Legacy Fancy GPU screen bloom switch |
| `mc_light_bloom_radius` | `6` | Client | Legacy Fancy bloom blur radius, screen pixels |
| `mc_light_bloom_strength` | `0.3` | Client | Legacy Fancy bloom strength |
| `mc_light_bloom_threshold` | `0.7` | Client | Legacy Fancy bloom brightness threshold |
| `mc_light_brightness` | `1.5` | Client | Block/skylight brightness multiplier; 1 unchanged |
| `mc_light_enabled` | `1` | Client | Apply MC vertex lighting to block meshes |
| `mc_light_entity` | `0` | Client | Main switch for interpolated MC lighting on players and common model entities |
| `mc_light_entity_cluster` | `1` | Client | Apply MC entity lighting to mc_block_cluster structures |
| `mc_light_entity_cluster_gain` | `1` | Client | MC-lit cluster exposure multiplier; 1 matches chunk vertex lighting |
| `mc_light_entity_gain` | `0.48` | Client | Exposure multiplier for MC-lit Source entities |
| `mc_light_entity_interval` | `0.10` | Client | Minimum voxel-light sample interval per entity, seconds, including movement; at most 4 entity updates per frame; 0 requests each frame, excess queues |
| `mc_light_entity_npcs` | `1` | Client | Apply MC lighting to NPC and NextBot models |
| `mc_light_entity_player_gamma` | `2.2` | Client | Exponent converting player ambient-cube lighting from display to linear space |
| `mc_light_entity_players` | `1` | Client | Apply MC lighting to player models; saved settings retain their values |
| `mc_light_entity_props` | `1` | Client | Apply MC lighting to common prop models |
| `mc_light_entity_reflections` | `0.35` | Client | Entity reflection strength, also affected by sampled brightness |
| `mc_light_entity_vehicles` | `1` | Client | Apply MC lighting to standard Source vehicles |
| `mc_light_gamma` | `1` | Client | Light falloff curve; above 1 brightens midtones, below 1 darkens them |
| `mc_light_shader` | `1` | Client | Legacy chunk GPU shader switch; requires compiled VCS |
| `mc_light_sky_flood` | `1` | Client | MC skylight propagation: 15 outdoors, decaying per cell indoors; 0 uniform bright sky |
| `mc_light_sky_flood_frame_ms` | `2` | Client | Soft skylight recomputation budget per frame, milliseconds; 0 unlimited |
| `mc_light_sky_flood_per_frame` | `4` | Client | Maximum chunk-skylight recalculations per frame |
| `mc_light_style` | `vanilla` | Client | Deprecated appearance selector; does not select the current shader pack |
| `mc_light_sun_brightness` | `1` | Client | Sun/skylight brightness multiplier |
| `mc_light_texture` | `1` | Client | Legacy GPU path samples chunk-light textures instead of baked vertex colors |
| `mc_light_atlas_size` | `auto` | Client | L2 corner/AO atlas: `auto` selects the largest supported tier; `16384`, `8192`, `4096` select exact supported sizes; reconnect to apply |
| `mc_lightmap` | `1` | Client | 16×16 global lightmap: warm block light and day/night sky colors; 0 grayscale fallback |
| `mc_lightmap_ambient` | `0.18` | Client | Minimum visible brightness in fully dark global-lightmap regions |
| `mc_lightmap_eye_dark` | `1` | Client | Ambient multiplier when the camera cell has no skylight; 1 no darkening |
| `mc_lightmap_night_gamma` | `0.6` | Client | Day/night sky brightness curve; 1 linear, lower values brighten/blue the night |
| `mc_lightmap_sky_curve` | `3` | Client | Sky ambient falloff exponent; higher values brighten sheltered but open areas |
| `mc_lightmap_sky_min` | `0.18` | Client | Minimum sky ambient fraction at skylight 0; independent of direct sun |
| `mc_lightmap_sunset` | `0.5` | Client | Global-lightmap sunrise/sunset orange intensity; 0 off |
| `mc_lightmap_torch_warmth` | `0.7` | Client | Global-lightmap block-light warmth; 0 white |
| `mc_lightmap_vanilla_flicker` | `1` | Client | Vanilla per-tick torch flicker; 0 stable block light |
| `mc_lightmap_vanilla_gamma` | `0.5` | Client | Vanilla brightness slider: 0 Moody, 0.5 default, 1 Bright |
| `mc_pbr_shadow_entities` | `1` | Client | Source props, players, NPCs, and vehicles cast shadows onto MC surfaces |
| `mc_shadow` | `1` | Client | Legacy chunk shader receives MC-owned sun shadows |
| `mc_shadow_bias` | `0` | Client | Legacy shadow-map depth/edge sampling bias |
| `mc_shadow_cascade_ratio` | `3` | Client | Legacy cascade radius ratio; near distance / ratio², middle distance / ratio |
| `mc_shadow_caster_distance` | `10000` | Client | Legacy shadow-map caster distance from camera, Source units |
| `mc_shadow_distance` | `10000` | Client | Legacy MC-owned shadow coverage radius, Source units |
| `mc_shadow_edge_fade` | `0.1` | Client | Legacy Fancy shadow-coverage edge fade width, UV units; 0 hard cut |
| `mc_shadow_face_shade` | `0.65` | Client | Legacy Fancy back-facing surface shadow strength |
| `mc_shadow_facefix` | `0` | Client | Legacy shadow A/B: 0 old composition, 1 separate cast shadow and back-face correction |
| `mc_shadow_hf_max_dist` | `2400` | Client | Legacy heightfield maximum ray-march distance, Source units |
| `mc_shadow_hf_range` | `4096` | Client | Legacy player-centered heightfield radius, Source units |
| `mc_shadow_hf_size` | `1024` | Client | Legacy heightfield shadow resolution |
| `mc_shadow_hf_softness` | `0.05` | Client | Legacy heightfield penumbra slope with occluder distance |
| `mc_shadow_hf_update_interval` | `0` | Client | Legacy heightfield minimum redraw interval after geometry/window changes, seconds |
| `mc_shadow_mode` | `map` | Client | Legacy shadow mode: linear, map, csm, height |
| `mc_shadow_size` | `4096` | Client | Legacy MC-owned shadow-map layer resolution, 512–4096; not PBR shadow resolution |
| `mc_shadow_softness` | `0.5` | Client | Legacy PCF radius, shadow texels; normal bias remains one texel |
| `mc_shadow_strength` | `0.75` | Client | Legacy chunk-shader shadow strength multiplier |
| `mc_shadow_sun_step` | `0` | Client | Legacy sun-angle quantization step, degrees; 0 continuous |
| `mc_shadow_tint` | `0.6` | Client | Legacy Fancy cool-sky shadow tint; 0 darkening only |
| `mc_shadow_update_interval` | `0` | Client | Legacy MC-owned shadow minimum redraw interval, seconds; 0 every frame |
| `mc_shadow_warmth` | `0.35` | Client | Legacy Fancy sunlit/torch warmth; 0 neutral |

Source: [cl_lighting.lua](../addons/mc_engine/lua/mc/cl_lighting.lua), [cl_entity_lighting.lua](../addons/mc_engine/lua/mc/render/cl_entity_lighting.lua), [cl_mesh_config.lua](../addons/mc_engine/lua/mc/render/cl_mesh_config.lua), [cl_render_dynamic_lights.lua](../addons/mc_engine/lua/mc/render/cl_render_dynamic_lights.lua), [cl_render_pbr_shadows.lua](../addons/mc_engine/lua/mc/render/cl_render_pbr_shadows.lua), [cl_sky_flood.lua](../addons/mc_engine/lua/mc/render/cl_sky_flood.lua).

<a id="convars-10"></a>

## Creative-mode held blocks

All options are client-side and adjust the creative placer's held block, separately from the MC Item anchors below.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_creative_held_anim` | `1` | Client | Play the creative-mode held-block swing animation |
| `mc_creative_held_fp_forward` | `11.5` | Client | Creative-mode held-block first-person forward/back offset, Source units |
| `mc_creative_held_fp_pitch` | `0` | Client | Creative-mode held-block first-person pitch, degrees |
| `mc_creative_held_fp_right` | `12` | Client | Creative-mode held-block first-person lateral offset, Source units |
| `mc_creative_held_fp_roll` | `0` | Client | Creative-mode held-block first-person roll, degrees |
| `mc_creative_held_fp_scale` | `6.4` | Client | Creative-mode held-block first-person scale multiplier |
| `mc_creative_held_fp_up` | `-8.3` | Client | Creative-mode held-block first-person vertical offset, Source units |
| `mc_creative_held_fp_yaw` | `45` | Client | Creative-mode held-block first-person yaw, degrees |
| `mc_creative_held_model` | `1` | Client | Show the creative-mode held-block model |
| `mc_creative_held_tp_forward` | `2.5` | Client | Creative-mode held-block third-person forward/back offset, Source units |
| `mc_creative_held_tp_pitch` | `75` | Client | Creative-mode held-block third-person pitch, degrees |
| `mc_creative_held_tp_right` | `2.2` | Client | Creative-mode held-block third-person lateral offset, Source units |
| `mc_creative_held_tp_roll` | `0` | Client | Creative-mode held-block third-person roll, degrees |
| `mc_creative_held_tp_scale` | `6` | Client | Creative-mode held-block third-person scale multiplier |
| `mc_creative_held_tp_up` | `-1.8` | Client | Creative-mode held-block third-person vertical offset, Source units |
| `mc_creative_held_tp_yaw` | `45` | Client | Creative-mode held-block third-person yaw, degrees |

Source: [shared.lua](../addons/mc_engine/lua/weapons/mc_creative_placer/shared.lua).

<a id="convars-11"></a>

## MC Item: gameplay and presentation

Requires mc_item. Server parameters control gameplay; client parameters control local presentation.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_attack_indicator` | `1` | Client | Attack progress indicator: 0 off, 1 at the crosshair |
| `mcitem_attack_range` | `4.5` | Server | Normal melee attack range, blocks; spears use their own range |
| `mcitem_block_outline` | `1` | Client | Draw the selected-block outline while holding an MC Item weapon/item and aiming at a block |
| `mcitem_channeling_thunderstorm` | `0` | Server | Treat the current GMod world as a thunderstorm for Channeling tridents |
| `mcitem_crosshair` | `1` | Client | Show the MC crosshair while holding an MC Item weapon |
| `mcitem_crosshair_invert` | `1` | Client | Use inverted-color blending for the MC crosshair; does not invert attack progress |
| `mcitem_damage_scale` | `5` | Server | Direct weapon damage multiplier, including melee, sweeping attacks, spears, maces, arrows, and projectiles; excludes potion effect damage |
| `mcitem_draw_shake` | `1` | Client | Amplitude multiplier for subtle bow, crossbow, and trident charge shake; 0 disables it |
| `mcitem_draw_stretch` | `1` | Client | Enable depth stretching while charging bows, crossbows, and tridents |
| `mcitem_fov_effect_scale` | `1` | Server | MC FOV effect strength; 0 disables bow zoom, 1 uses vanilla strength |
| `mcitem_hand_aspect_lock` | `1` | Client | Compensate held-item horizontal position for aspect ratio to preserve the 4:3 calibration |
| `mcitem_hand_fov_lock` | `1` | Client | Preserve held-item screen size when drawing a bow reduces world FOV |
| `mcitem_hand_lower` | `1` | Client | Raise/lower the hand with attack cooldown; 0 keeps it raised |
| `mcitem_hud_scale` | `2` | Client | Screen pixels per MC GUI pixel; 0 automatic |
| `mcitem_knockback_scale` | `0.3` | Server | Multiplier mapping MC knockback velocity to Source |
| `mcitem_mcswep_lighting` | `1` | Client | Use MineMod voxel lighting for held items, drops, and projectile models |
| `mcitem_name_tag_scale` | `2.5` | Client | World-space name-tag text scale, range 0.5–3 |
| `mcitem_particle_limit` | `1200` | Client | Maximum simultaneous MC Item particles; 0 unlimited |
| `mcitem_potion_max_entity_cramming` | `24` | Server | maxEntityCramming limit for the Oozing effect; 0 disables this limit |
| `mcitem_projectile_billboard` | `1` | Client | Use camera-facing sprites for snowballs, eggs, pearls, potions, Eyes of Ender, and similar projectiles; 0 uses original models |
| `mcitem_projectile_light_offset` | `0.5` | Client | Lighting sample offset along the hit-surface normal for embedded arrows/tridents, blocks; 0 uses the geometry center |
| `mcitem_projectile_stick_depth` | `0.05` | Server | Arrow/trident tip penetration beyond the hit surface, blocks |
| `mcitem_use_preview` | `-1` | Client | Freeze the use/charge animation at the specified MC tick; -1 plays normally |
| `mcitem_view_bob` | `1` | Client | Held-item walking bob multiplier; 0 disables it |
| `mcitem_view_sway` | `1` | Client | Held-item lag when turning the view; 0 disables it |

Source: [cl_init.lua](../addons/mc_item/lua/entities/mcitem_arrow/cl_init.lua), [shared.lua](../addons/mc_item/lua/entities/mcitem_arrow/shared.lua), [cl_billboard.lua](../addons/mc_item/lua/mcitem/cl_billboard.lua), [cl_block_outline.lua](../addons/mc_item/lua/mcitem/cl_block_outline.lua), [cl_crosshair.lua](../addons/mc_item/lua/mcitem/cl_crosshair.lua), [cl_model_lighting.lua](../addons/mc_item/lua/mcitem/cl_model_lighting.lua), [sh_runtime.lua](../addons/mc_item/lua/mcitem/enchantments/sh_runtime.lua), [cl_render.lua](../addons/mc_item/lua/mcitem/name_tags/cl_render.lua), [sv_special.lua](../addons/mc_item/lua/mcitem/potions/status/sv_special.lua), [sh_tuning.lua](../addons/mc_item/lua/mcitem/sh_tuning.lua), [sh_use_effects.lua](../addons/mc_item/lua/mcitem/sh_use_effects.lua), [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-12"></a>

## MC Item: shared first-person anchors

The names retain bmb_item_test_fp_*, but general MC Item weapons inherit this rendering base; these are not limited to the test weapon. All variables are client-side.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `bmb_item_test_fp_fov` | `80` | Client | Held-item FOV outside MC animation mode, degrees |
| `bmb_item_test_fp_mc_fov` | `70` | Client | Held-item FOV in MC animation mode, degrees |
| `bmb_item_test_fp_mc_pivot` | `1` | Client | MC hand rotation pivot offset multiplier |
| `bmb_item_test_fp_mc_pos_x` | `1` | Client | X component multiplier for the MC swing position transform |
| `bmb_item_test_fp_mc_pos_y` | `1` | Client | Y component multiplier for the MC swing position transform |
| `bmb_item_test_fp_mc_pos_z` | `1` | Client | Z component multiplier for the MC swing position transform |
| `bmb_item_test_fp_mc_preview` | `-1` | Client | Freeze the swing animation phase; -1 plays normally |
| `bmb_item_test_fp_mc_rot_pitch` | `1` | Client | MC swing pitch transform multiplier |
| `bmb_item_test_fp_mc_rot_roll` | `1` | Client | MC swing roll transform multiplier |
| `bmb_item_test_fp_mc_rot_yaw` | `1` | Client | MC swing yaw transform multiplier |
| `bmb_item_test_fp_mc_scale` | `0.68` | Client | Additional multiplier on the base scale in MC animation mode |
| `bmb_item_test_fp_minecraft` | `1` | Client | Enable MC first-person motion transforms |
| `bmb_item_test_fp_pitch` | `-3` | Client | Shared first-person pitch, degrees |
| `bmb_item_test_fp_roll` | `20` | Client | Shared first-person roll, degrees |
| `bmb_item_test_fp_scale` | `0.5` | Client | Shared first-person base model scale |
| `bmb_item_test_fp_x` | `19.5` | Client | Shared first-person forward/back offset, Source units |
| `bmb_item_test_fp_y` | `10.3` | Client | Shared first-person lateral offset, Source units |
| `bmb_item_test_fp_yaw` | `110` | Client | Shared first-person yaw, degrees |
| `bmb_item_test_fp_z` | `-7` | Client | Shared first-person vertical offset, Source units |

Source: [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-13"></a>

## MC Item: per-item first-person anchors

All variables are client-side. Position/rotation offsets are added to the shared anchor; scale is a multiplier. bow, crossbow, trident, spear, shield, fishing_rod, food, and potion are registered at load time; item and bucket are created on demand when a related item is first rendered. The shield's exact MC transform path bypasses the generic anchor, so registration does not imply every rendering path reads it.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_fp_bow_pitch` | `5` | Client | Bow first-person held offset: pitch, degrees |
| `mcitem_fp_bow_roll` | `0` | Client | Bow first-person held offset: roll, degrees |
| `mcitem_fp_bow_scale` | `1` | Client | Bow first-person held offset: scale multiplier |
| `mcitem_fp_bow_x` | `-1` | Client | Bow first-person held offset: forward/back translation, Source units |
| `mcitem_fp_bow_y` | `0` | Client | Bow first-person held offset: lateral translation, Source units |
| `mcitem_fp_bow_yaw` | `-5` | Client | Bow first-person held offset: yaw, degrees |
| `mcitem_fp_bow_z` | `0` | Client | Bow first-person held offset: vertical translation, Source units |
| `mcitem_fp_bucket_pitch` | `0` | Client | Bucket first-person held offset: pitch, degrees |
| `mcitem_fp_bucket_roll` | `0` | Client | Bucket first-person held offset: roll, degrees |
| `mcitem_fp_bucket_scale` | `1` | Client | Bucket first-person held offset: scale multiplier |
| `mcitem_fp_bucket_x` | `0` | Client | Bucket first-person held offset: forward/back translation, Source units |
| `mcitem_fp_bucket_y` | `0` | Client | Bucket first-person held offset: lateral translation, Source units |
| `mcitem_fp_bucket_yaw` | `0` | Client | Bucket first-person held offset: yaw, degrees |
| `mcitem_fp_bucket_z` | `0` | Client | Bucket first-person held offset: vertical translation, Source units |
| `mcitem_fp_crossbow_pitch` | `5` | Client | Crossbow first-person held offset: pitch, degrees |
| `mcitem_fp_crossbow_roll` | `-244` | Client | Crossbow first-person held offset: roll, degrees |
| `mcitem_fp_crossbow_scale` | `1` | Client | Crossbow first-person held offset: scale multiplier |
| `mcitem_fp_crossbow_x` | `-1` | Client | Crossbow first-person held offset: forward/back translation, Source units |
| `mcitem_fp_crossbow_y` | `0.6` | Client | Crossbow first-person held offset: lateral translation, Source units |
| `mcitem_fp_crossbow_yaw` | `-100` | Client | Crossbow first-person held offset: yaw, degrees |
| `mcitem_fp_crossbow_z` | `0` | Client | Crossbow first-person held offset: vertical translation, Source units |
| `mcitem_fp_fishing_rod_pitch` | `0` | Client | Fishing rod first-person held offset: pitch, degrees |
| `mcitem_fp_fishing_rod_roll` | `5` | Client | Fishing rod first-person held offset: roll, degrees |
| `mcitem_fp_fishing_rod_scale` | `1` | Client | Fishing rod first-person held offset: scale multiplier |
| `mcitem_fp_fishing_rod_x` | `0` | Client | Fishing rod first-person held offset: forward/back translation, Source units |
| `mcitem_fp_fishing_rod_y` | `1` | Client | Fishing rod first-person held offset: lateral translation, Source units |
| `mcitem_fp_fishing_rod_yaw` | `-10` | Client | Fishing rod first-person held offset: yaw, degrees |
| `mcitem_fp_fishing_rod_z` | `1` | Client | Fishing rod first-person held offset: vertical translation, Source units |
| `mcitem_fp_food_pitch` | `0` | Client | Food first-person held offset: pitch, degrees |
| `mcitem_fp_food_roll` | `0` | Client | Food first-person held offset: roll, degrees |
| `mcitem_fp_food_scale` | `1` | Client | Food first-person held offset: scale multiplier |
| `mcitem_fp_food_x` | `0` | Client | Food first-person held offset: forward/back translation, Source units |
| `mcitem_fp_food_y` | `0` | Client | Food first-person held offset: lateral translation, Source units |
| `mcitem_fp_food_yaw` | `0` | Client | Food first-person held offset: yaw, degrees |
| `mcitem_fp_food_z` | `0` | Client | Food first-person held offset: vertical translation, Source units |
| `mcitem_fp_item_pitch` | `0` | Client | Item first-person held offset: pitch, degrees |
| `mcitem_fp_item_roll` | `0` | Client | Item first-person held offset: roll, degrees |
| `mcitem_fp_item_scale` | `1` | Client | Item first-person held offset: scale multiplier |
| `mcitem_fp_item_x` | `0` | Client | Item first-person held offset: forward/back translation, Source units |
| `mcitem_fp_item_y` | `0` | Client | Item first-person held offset: lateral translation, Source units |
| `mcitem_fp_item_yaw` | `0` | Client | Item first-person held offset: yaw, degrees |
| `mcitem_fp_item_z` | `0` | Client | Item first-person held offset: vertical translation, Source units |
| `mcitem_fp_potion_pitch` | `0` | Client | Potion first-person held offset: pitch, degrees |
| `mcitem_fp_potion_roll` | `0` | Client | Potion first-person held offset: roll, degrees |
| `mcitem_fp_potion_scale` | `1` | Client | Potion first-person held offset: scale multiplier |
| `mcitem_fp_potion_x` | `0` | Client | Potion first-person held offset: forward/back translation, Source units |
| `mcitem_fp_potion_y` | `0` | Client | Potion first-person held offset: lateral translation, Source units |
| `mcitem_fp_potion_yaw` | `0` | Client | Potion first-person held offset: yaw, degrees |
| `mcitem_fp_potion_z` | `0` | Client | Potion first-person held offset: vertical translation, Source units |
| `mcitem_fp_shield_pitch` | `190` | Client | Shield first-person held offset: pitch, degrees |
| `mcitem_fp_shield_roll` | `-185` | Client | Shield first-person held offset: roll, degrees |
| `mcitem_fp_shield_scale` | `1.5` | Client | Shield first-person held offset: scale multiplier |
| `mcitem_fp_shield_x` | `-10` | Client | Shield first-person held offset: forward/back translation, Source units |
| `mcitem_fp_shield_y` | `16` | Client | Shield first-person held offset: lateral translation, Source units |
| `mcitem_fp_shield_yaw` | `-15` | Client | Shield first-person held offset: yaw, degrees |
| `mcitem_fp_shield_z` | `-20` | Client | Shield first-person held offset: vertical translation, Source units |
| `mcitem_fp_spear_pitch` | `17` | Client | Spear first-person held offset: pitch, degrees |
| `mcitem_fp_spear_roll` | `-20` | Client | Spear first-person held offset: roll, degrees |
| `mcitem_fp_spear_scale` | `1.3` | Client | Spear first-person held offset: scale multiplier |
| `mcitem_fp_spear_x` | `2` | Client | Spear first-person held offset: forward/back translation, Source units |
| `mcitem_fp_spear_y` | `0` | Client | Spear first-person held offset: lateral translation, Source units |
| `mcitem_fp_spear_yaw` | `-4` | Client | Spear first-person held offset: yaw, degrees |
| `mcitem_fp_spear_z` | `-0.7` | Client | Spear first-person held offset: vertical translation, Source units |
| `mcitem_fp_trident_pitch` | `0` | Client | Trident first-person held offset: pitch, degrees |
| `mcitem_fp_trident_roll` | `0` | Client | Trident first-person held offset: roll, degrees |
| `mcitem_fp_trident_scale` | `1.5` | Client | Trident first-person held offset: scale multiplier |
| `mcitem_fp_trident_x` | `-2` | Client | Trident first-person held offset: forward/back translation, Source units |
| `mcitem_fp_trident_y` | `19.3` | Client | Trident first-person held offset: lateral translation, Source units |
| `mcitem_fp_trident_yaw` | `0` | Client | Trident first-person held offset: yaw, degrees |
| `mcitem_fp_trident_z` | `-57` | Client | Trident first-person held offset: vertical translation, Source units |

Source: [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-14"></a>

## MC Item: use-pose offsets and stretching

All variables are client-side and registered by item name at load time. x/y/z and angles are added only in the use state. draw controls pullback amplitude; stretch controls depth deformation. Some item/use states do not enter the relevant branch, so a variable's existence does not imply the current action reads it.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_use_bow_draw` | `1` | Client | Bow use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_bow_pitch` | `-5` | Client | Bow first-person use offset: pitch, degrees |
| `mcitem_use_bow_roll` | `0` | Client | Bow first-person use offset: roll, degrees |
| `mcitem_use_bow_stretch` | `1` | Client | Bow charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_bow_x` | `-3` | Client | Bow first-person use offset: forward/back translation, Source units |
| `mcitem_use_bow_y` | `1` | Client | Bow first-person use offset: lateral translation, Source units |
| `mcitem_use_bow_yaw` | `0` | Client | Bow first-person use offset: yaw, degrees |
| `mcitem_use_bow_z` | `0` | Client | Bow first-person use offset: vertical translation, Source units |
| `mcitem_use_crossbow_draw` | `1` | Client | Crossbow use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_crossbow_pitch` | `-5` | Client | Crossbow first-person use offset: pitch, degrees |
| `mcitem_use_crossbow_roll` | `0` | Client | Crossbow first-person use offset: roll, degrees |
| `mcitem_use_crossbow_stretch` | `1` | Client | Crossbow charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_crossbow_x` | `-2` | Client | Crossbow first-person use offset: forward/back translation, Source units |
| `mcitem_use_crossbow_y` | `-2` | Client | Crossbow first-person use offset: lateral translation, Source units |
| `mcitem_use_crossbow_yaw` | `0` | Client | Crossbow first-person use offset: yaw, degrees |
| `mcitem_use_crossbow_z` | `0` | Client | Crossbow first-person use offset: vertical translation, Source units |
| `mcitem_use_fishing_rod_draw` | `1` | Client | Fishing rod use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_fishing_rod_pitch` | `0` | Client | Fishing rod first-person use offset: pitch, degrees |
| `mcitem_use_fishing_rod_roll` | `5` | Client | Fishing rod first-person use offset: roll, degrees |
| `mcitem_use_fishing_rod_stretch` | `1` | Client | Fishing rod charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_fishing_rod_x` | `0` | Client | Fishing rod first-person use offset: forward/back translation, Source units |
| `mcitem_use_fishing_rod_y` | `1` | Client | Fishing rod first-person use offset: lateral translation, Source units |
| `mcitem_use_fishing_rod_yaw` | `-10` | Client | Fishing rod first-person use offset: yaw, degrees |
| `mcitem_use_fishing_rod_z` | `1` | Client | Fishing rod first-person use offset: vertical translation, Source units |
| `mcitem_use_food_draw` | `1` | Client | Food use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_food_pitch` | `10` | Client | Food first-person use offset: pitch, degrees |
| `mcitem_use_food_roll` | `3` | Client | Food first-person use offset: roll, degrees |
| `mcitem_use_food_stretch` | `1` | Client | Food charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_food_x` | `-9` | Client | Food first-person use offset: forward/back translation, Source units |
| `mcitem_use_food_y` | `3` | Client | Food first-person use offset: lateral translation, Source units |
| `mcitem_use_food_yaw` | `-5` | Client | Food first-person use offset: yaw, degrees |
| `mcitem_use_food_z` | `0` | Client | Food first-person use offset: vertical translation, Source units |
| `mcitem_use_potion_draw` | `1` | Client | Potion use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_potion_pitch` | `10` | Client | Potion first-person use offset: pitch, degrees |
| `mcitem_use_potion_roll` | `3` | Client | Potion first-person use offset: roll, degrees |
| `mcitem_use_potion_stretch` | `1` | Client | Potion charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_potion_x` | `-9` | Client | Potion first-person use offset: forward/back translation, Source units |
| `mcitem_use_potion_y` | `3` | Client | Potion first-person use offset: lateral translation, Source units |
| `mcitem_use_potion_yaw` | `-10` | Client | Potion first-person use offset: yaw, degrees |
| `mcitem_use_potion_z` | `0` | Client | Potion first-person use offset: vertical translation, Source units |
| `mcitem_use_shield_draw` | `1` | Client | Shield use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_shield_pitch` | `-8` | Client | Shield first-person use offset: pitch, degrees |
| `mcitem_use_shield_roll` | `20` | Client | Shield first-person use offset: roll, degrees |
| `mcitem_use_shield_stretch` | `1` | Client | Shield charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_shield_x` | `-2` | Client | Shield first-person use offset: forward/back translation, Source units |
| `mcitem_use_shield_y` | `7` | Client | Shield first-person use offset: lateral translation, Source units |
| `mcitem_use_shield_yaw` | `0` | Client | Shield first-person use offset: yaw, degrees |
| `mcitem_use_shield_z` | `2` | Client | Shield first-person use offset: vertical translation, Source units |
| `mcitem_use_spear_draw` | `1` | Client | Spear use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_spear_pitch` | `0` | Client | Spear first-person use offset: pitch, degrees |
| `mcitem_use_spear_roll` | `0` | Client | Spear first-person use offset: roll, degrees |
| `mcitem_use_spear_stretch` | `1` | Client | Spear charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_spear_x` | `0` | Client | Spear first-person use offset: forward/back translation, Source units |
| `mcitem_use_spear_y` | `0` | Client | Spear first-person use offset: lateral translation, Source units |
| `mcitem_use_spear_yaw` | `0` | Client | Spear first-person use offset: yaw, degrees |
| `mcitem_use_spear_z` | `0` | Client | Spear first-person use offset: vertical translation, Source units |
| `mcitem_use_trident_draw` | `3` | Client | Trident use-pose charge pullback amplitude multiplier; does not stretch the model |
| `mcitem_use_trident_pitch` | `-12` | Client | Trident first-person use offset: pitch, degrees |
| `mcitem_use_trident_roll` | `1` | Client | Trident first-person use offset: roll, degrees |
| `mcitem_use_trident_stretch` | `1` | Client | Trident charge depth stretch multiplier; 0 leaves the model undeformed |
| `mcitem_use_trident_x` | `-15` | Client | Trident first-person use offset: forward/back translation, Source units |
| `mcitem_use_trident_y` | `3` | Client | Trident first-person use offset: lateral translation, Source units |
| `mcitem_use_trident_yaw` | `-12` | Client | Trident first-person use offset: yaw, degrees |
| `mcitem_use_trident_z` | `58` | Client | Trident first-person use offset: vertical translation, Source units |

Source: [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-15"></a>

## MC Item: cocked-pose offsets

All variables are client-side and registered at load time. They are currently read mainly by the crossbow charged state; other item names are preregistered but have no effect without the corresponding state.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_charged_bow_pitch` | `0` | Client | Bow first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_bow_roll` | `0` | Client | Bow first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_bow_x` | `0` | Client | Bow first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_bow_y` | `0` | Client | Bow first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_bow_yaw` | `0` | Client | Bow first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_bow_z` | `0` | Client | Bow first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_crossbow_pitch` | `-2` | Client | Crossbow first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_crossbow_roll` | `9` | Client | Crossbow first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_crossbow_x` | `-2` | Client | Crossbow first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_crossbow_y` | `1` | Client | Crossbow first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_crossbow_yaw` | `0` | Client | Crossbow first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_crossbow_z` | `0` | Client | Crossbow first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_fishing_rod_pitch` | `0` | Client | Fishing rod first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_fishing_rod_roll` | `0` | Client | Fishing rod first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_fishing_rod_x` | `0` | Client | Fishing rod first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_fishing_rod_y` | `0` | Client | Fishing rod first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_fishing_rod_yaw` | `0` | Client | Fishing rod first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_fishing_rod_z` | `0` | Client | Fishing rod first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_food_pitch` | `0` | Client | Food first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_food_roll` | `0` | Client | Food first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_food_x` | `0` | Client | Food first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_food_y` | `0` | Client | Food first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_food_yaw` | `0` | Client | Food first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_food_z` | `0` | Client | Food first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_potion_pitch` | `0` | Client | Potion first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_potion_roll` | `0` | Client | Potion first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_potion_x` | `0` | Client | Potion first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_potion_y` | `0` | Client | Potion first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_potion_yaw` | `0` | Client | Potion first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_potion_z` | `0` | Client | Potion first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_shield_pitch` | `0` | Client | Shield first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_shield_roll` | `0` | Client | Shield first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_shield_x` | `0` | Client | Shield first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_shield_y` | `0` | Client | Shield first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_shield_yaw` | `0` | Client | Shield first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_shield_z` | `0` | Client | Shield first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_spear_pitch` | `0` | Client | Spear first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_spear_roll` | `0` | Client | Spear first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_spear_x` | `0` | Client | Spear first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_spear_y` | `0` | Client | Spear first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_spear_yaw` | `0` | Client | Spear first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_spear_z` | `0` | Client | Spear first-person loaded/cocked idle offset: vertical translation, Source units |
| `mcitem_charged_trident_pitch` | `0` | Client | Trident first-person loaded/cocked idle offset: pitch, degrees |
| `mcitem_charged_trident_roll` | `0` | Client | Trident first-person loaded/cocked idle offset: roll, degrees |
| `mcitem_charged_trident_x` | `0` | Client | Trident first-person loaded/cocked idle offset: forward/back translation, Source units |
| `mcitem_charged_trident_y` | `0` | Client | Trident first-person loaded/cocked idle offset: lateral translation, Source units |
| `mcitem_charged_trident_yaw` | `0` | Client | Trident first-person loaded/cocked idle offset: yaw, degrees |
| `mcitem_charged_trident_z` | `0` | Client | Trident first-person loaded/cocked idle offset: vertical translation, Source units |

Source: [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-16"></a>

## MC Item: swing component multipliers

All variables are client-side. Position and rotation components are multiplied independently; 1 preserves amplitude and 0 disables that component. item and bucket are created on demand; the other items below are registered at load time.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_swing_bow_pos_x` | `1` | Client | Bow first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_bow_pos_y` | `1` | Client | Bow first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_bow_pos_z` | `1` | Client | Bow first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_bow_rot_pitch` | `1` | Client | Bow first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_bow_rot_roll` | `1` | Client | Bow first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_bow_rot_yaw` | `1` | Client | Bow first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_bucket_pos_x` | `1` | Client | Bucket first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_bucket_pos_y` | `1` | Client | Bucket first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_bucket_pos_z` | `1` | Client | Bucket first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_bucket_rot_pitch` | `1` | Client | Bucket first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_bucket_rot_roll` | `1` | Client | Bucket first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_bucket_rot_yaw` | `1` | Client | Bucket first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_crossbow_pos_x` | `1` | Client | Crossbow first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_crossbow_pos_y` | `1` | Client | Crossbow first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_crossbow_pos_z` | `1` | Client | Crossbow first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_crossbow_rot_pitch` | `1` | Client | Crossbow first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_crossbow_rot_roll` | `1` | Client | Crossbow first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_crossbow_rot_yaw` | `1` | Client | Crossbow first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_fishing_rod_pos_x` | `1` | Client | Fishing rod first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_fishing_rod_pos_y` | `1` | Client | Fishing rod first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_fishing_rod_pos_z` | `1` | Client | Fishing rod first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_fishing_rod_rot_pitch` | `1` | Client | Fishing rod first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_fishing_rod_rot_roll` | `1` | Client | Fishing rod first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_fishing_rod_rot_yaw` | `1` | Client | Fishing rod first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_food_pos_x` | `1` | Client | Food first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_food_pos_y` | `1` | Client | Food first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_food_pos_z` | `1` | Client | Food first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_food_rot_pitch` | `1` | Client | Food first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_food_rot_roll` | `1` | Client | Food first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_food_rot_yaw` | `1` | Client | Food first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_item_pos_x` | `1` | Client | Item first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_item_pos_y` | `1` | Client | Item first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_item_pos_z` | `1` | Client | Item first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_item_rot_pitch` | `1` | Client | Item first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_item_rot_roll` | `1` | Client | Item first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_item_rot_yaw` | `1` | Client | Item first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_potion_pos_x` | `1` | Client | Potion first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_potion_pos_y` | `1` | Client | Potion first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_potion_pos_z` | `1` | Client | Potion first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_potion_rot_pitch` | `1` | Client | Potion first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_potion_rot_roll` | `1` | Client | Potion first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_potion_rot_yaw` | `1` | Client | Potion first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_shield_pos_x` | `1` | Client | Shield first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_shield_pos_y` | `1` | Client | Shield first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_shield_pos_z` | `1` | Client | Shield first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_shield_rot_pitch` | `1` | Client | Shield first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_shield_rot_roll` | `1` | Client | Shield first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_shield_rot_yaw` | `1` | Client | Shield first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_spear_pos_x` | `1` | Client | Spear first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_spear_pos_y` | `1` | Client | Spear first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_spear_pos_z` | `1` | Client | Spear first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_spear_rot_pitch` | `1` | Client | Spear first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_spear_rot_roll` | `1` | Client | Spear first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_spear_rot_yaw` | `1` | Client | Spear first-person left-click swing yaw rotation amplitude multiplier |
| `mcitem_swing_trident_pos_x` | `1` | Client | Trident first-person left-click swing X translation amplitude multiplier |
| `mcitem_swing_trident_pos_y` | `1` | Client | Trident first-person left-click swing Y translation amplitude multiplier |
| `mcitem_swing_trident_pos_z` | `1` | Client | Trident first-person left-click swing Z translation amplitude multiplier |
| `mcitem_swing_trident_rot_pitch` | `1` | Client | Trident first-person left-click swing pitch rotation amplitude multiplier |
| `mcitem_swing_trident_rot_roll` | `1` | Client | Trident first-person left-click swing roll rotation amplitude multiplier |
| `mcitem_swing_trident_rot_yaw` | `1` | Client | Trident first-person left-click swing yaw rotation amplitude multiplier |

Source: [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-17"></a>

## MC Item: third-person animation types

The server selects the GMod HoldType. Values: normal, fist, melee, melee2, knife, smg, ar2, pistol, revolver, shotgun, rpg, physgun, grenade, slam, passive, magic, crossbow, camera, duel. Invalid names fall back to the state's default.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_holdtype_bow` | `normal` | Server | Bow idle GMod HoldType |
| `mcitem_holdtype_bow_attack` | `melee` | Server | Bow left-click attack GMod HoldType |
| `mcitem_holdtype_bow_draw` | `revolver` | Server | Drawing a bow GMod HoldType |
| `mcitem_holdtype_bucket_use` | `melee` | Server | Bucket fluid pickup/placement GMod HoldType |
| `mcitem_holdtype_crossbow` | `normal` | Server | Crossbow idle GMod HoldType |
| `mcitem_holdtype_crossbow_attack` | `melee` | Server | Crossbow left-click attack GMod HoldType |
| `mcitem_holdtype_crossbow_charged` | `revolver` | Server | Crossbow cocked GMod HoldType |
| `mcitem_holdtype_crossbow_load` | `shotgun` | Server | Crossbow loading GMod HoldType |
| `mcitem_holdtype_eat` | `camera` | Server | Eating/drinking GMod HoldType |
| `mcitem_holdtype_fishing_rod_use` | `melee` | Server | Fishing rod use GMod HoldType |
| `mcitem_holdtype_flint_and_steel_use` | `melee` | Server | Flint and steel use GMod HoldType |
| `mcitem_holdtype_item` | `normal` | Server | Normal-item idle GMod HoldType |
| `mcitem_holdtype_item_attack` | `melee` | Server | Normal-item left-click attack/mining GMod HoldType |
| `mcitem_holdtype_mace` | `melee` | Server | Mace GMod HoldType |
| `mcitem_holdtype_shears_use` | `melee` | Server | Shears use GMod HoldType |
| `mcitem_holdtype_shield` | `normal` | Server | Shield idle GMod HoldType |
| `mcitem_holdtype_shield_block` | `slam` | Server | Shield blocking GMod HoldType |
| `mcitem_holdtype_spear` | `normal` | Server | Spear idle GMod HoldType |
| `mcitem_holdtype_spear_attack` | `crossbow` | Server | Spear left-click thrust GMod HoldType |
| `mcitem_holdtype_spear_use` | `crossbow` | Server | Spear right-click charge GMod HoldType |
| `mcitem_holdtype_throw` | `grenade` | Server | Throwing GMod HoldType |
| `mcitem_holdtype_trident` | `melee` | Server | Trident idle GMod HoldType |
| `mcitem_holdtype_trident_charge` | `melee` | Server | Trident charging GMod HoldType |
| `mcitem_holdtype_trident_melee` | `melee` | Server | Trident melee GMod HoldType |

Source: [sh_holdtypes.lua](../addons/mc_item/lua/mcitem/sh_holdtypes.lua).

<a id="convars-18"></a>

## MC Item: third-person state models

The server controls stage switches and thresholds; the client creates same-name mirrors for rendering.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_tp_bow_pull_1_threshold` | `0.65` | Server | Bow draw progress threshold for stage 1 |
| `mcitem_tp_bow_pull_2_threshold` | `0.9` | Server | Bow draw progress threshold for stage 2 |
| `mcitem_tp_bow_state_models` | `1` | Server | Enable staged third-person bow models |
| `mcitem_tp_crossbow_pull_1_threshold` | `0.58` | Server | Crossbow draw progress threshold for stage 1 |
| `mcitem_tp_crossbow_pull_2_threshold` | `1` | Server | Crossbow draw progress threshold for stage 2 |
| `mcitem_tp_crossbow_state_models` | `1` | Server | Enable staged third-person crossbow models |

Source: [sh_holdtypes.lua](../addons/mc_item/lua/mcitem/sh_holdtypes.lua).

<a id="convars-19"></a>

## MC Item: third-person poses

All variables are client-side and registered independently per item/state. x/y/z offset along the player's right-hand bone Forward/Right/Up; pitch/yaw/roll rotate about Right/Up/Forward in degrees; scale multiplies the world model. Registered states without a dedicated default pose use position/angles 0 and scale 1; unregistered states fall back to idle.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_tp_axe_attack_pitch` | `-10` | Client | Axe / left-click attack/mining: pitch, degrees |
| `mcitem_tp_axe_attack_roll` | `50` | Client | Axe / left-click attack/mining: roll, degrees |
| `mcitem_tp_axe_attack_scale` | `1.3` | Client | Axe / left-click attack/mining: scale multiplier |
| `mcitem_tp_axe_attack_x` | `1.5` | Client | Axe / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_axe_attack_y` | `5` | Client | Axe / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_axe_attack_yaw` | `-200` | Client | Axe / left-click attack/mining: yaw, degrees |
| `mcitem_tp_axe_attack_z` | `-1` | Client | Axe / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_axe_idle_pitch` | `-10` | Client | Axe / idle: pitch, degrees |
| `mcitem_tp_axe_idle_roll` | `50` | Client | Axe / idle: roll, degrees |
| `mcitem_tp_axe_idle_scale` | `1.3` | Client | Axe / idle: scale multiplier |
| `mcitem_tp_axe_idle_x` | `1.5` | Client | Axe / idle: forward/back translation, Source units |
| `mcitem_tp_axe_idle_y` | `5` | Client | Axe / idle: lateral translation, Source units |
| `mcitem_tp_axe_idle_yaw` | `-200` | Client | Axe / idle: yaw, degrees |
| `mcitem_tp_axe_idle_z` | `-1` | Client | Axe / idle: vertical translation, Source units |
| `mcitem_tp_bow_attack_pitch` | `0` | Client | Bow / left-click attack/mining: pitch, degrees |
| `mcitem_tp_bow_attack_roll` | `0` | Client | Bow / left-click attack/mining: roll, degrees |
| `mcitem_tp_bow_attack_scale` | `1` | Client | Bow / left-click attack/mining: scale multiplier |
| `mcitem_tp_bow_attack_x` | `0` | Client | Bow / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_bow_attack_y` | `0` | Client | Bow / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_bow_attack_yaw` | `0` | Client | Bow / left-click attack/mining: yaw, degrees |
| `mcitem_tp_bow_attack_z` | `0` | Client | Bow / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_bow_draw_0_pitch` | `6` | Client | Bow / draw stage 0: pitch, degrees |
| `mcitem_tp_bow_draw_0_roll` | `220` | Client | Bow / draw stage 0: roll, degrees |
| `mcitem_tp_bow_draw_0_scale` | `1.3` | Client | Bow / draw stage 0: scale multiplier |
| `mcitem_tp_bow_draw_0_x` | `0` | Client | Bow / draw stage 0: forward/back translation, Source units |
| `mcitem_tp_bow_draw_0_y` | `8` | Client | Bow / draw stage 0: lateral translation, Source units |
| `mcitem_tp_bow_draw_0_yaw` | `-25` | Client | Bow / draw stage 0: yaw, degrees |
| `mcitem_tp_bow_draw_0_z` | `-5` | Client | Bow / draw stage 0: vertical translation, Source units |
| `mcitem_tp_bow_draw_1_pitch` | `6` | Client | Bow / draw stage 1: pitch, degrees |
| `mcitem_tp_bow_draw_1_roll` | `220` | Client | Bow / draw stage 1: roll, degrees |
| `mcitem_tp_bow_draw_1_scale` | `1.3` | Client | Bow / draw stage 1: scale multiplier |
| `mcitem_tp_bow_draw_1_x` | `0` | Client | Bow / draw stage 1: forward/back translation, Source units |
| `mcitem_tp_bow_draw_1_y` | `8` | Client | Bow / draw stage 1: lateral translation, Source units |
| `mcitem_tp_bow_draw_1_yaw` | `-25` | Client | Bow / draw stage 1: yaw, degrees |
| `mcitem_tp_bow_draw_1_z` | `-5` | Client | Bow / draw stage 1: vertical translation, Source units |
| `mcitem_tp_bow_draw_2_pitch` | `6` | Client | Bow / draw stage 2: pitch, degrees |
| `mcitem_tp_bow_draw_2_roll` | `220` | Client | Bow / draw stage 2: roll, degrees |
| `mcitem_tp_bow_draw_2_scale` | `1.3` | Client | Bow / draw stage 2: scale multiplier |
| `mcitem_tp_bow_draw_2_x` | `0` | Client | Bow / draw stage 2: forward/back translation, Source units |
| `mcitem_tp_bow_draw_2_y` | `8` | Client | Bow / draw stage 2: lateral translation, Source units |
| `mcitem_tp_bow_draw_2_yaw` | `-25` | Client | Bow / draw stage 2: yaw, degrees |
| `mcitem_tp_bow_draw_2_z` | `-5` | Client | Bow / draw stage 2: vertical translation, Source units |
| `mcitem_tp_bow_idle_pitch` | `0` | Client | Bow / idle: pitch, degrees |
| `mcitem_tp_bow_idle_roll` | `180` | Client | Bow / idle: roll, degrees |
| `mcitem_tp_bow_idle_scale` | `1.3` | Client | Bow / idle: scale multiplier |
| `mcitem_tp_bow_idle_x` | `0` | Client | Bow / idle: forward/back translation, Source units |
| `mcitem_tp_bow_idle_y` | `6` | Client | Bow / idle: lateral translation, Source units |
| `mcitem_tp_bow_idle_yaw` | `0` | Client | Bow / idle: yaw, degrees |
| `mcitem_tp_bow_idle_z` | `-9` | Client | Bow / idle: vertical translation, Source units |
| `mcitem_tp_crossbow_attack_pitch` | `0` | Client | Crossbow / left-click attack/mining: pitch, degrees |
| `mcitem_tp_crossbow_attack_roll` | `0` | Client | Crossbow / left-click attack/mining: roll, degrees |
| `mcitem_tp_crossbow_attack_scale` | `1` | Client | Crossbow / left-click attack/mining: scale multiplier |
| `mcitem_tp_crossbow_attack_x` | `0` | Client | Crossbow / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_crossbow_attack_y` | `0` | Client | Crossbow / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_crossbow_attack_yaw` | `0` | Client | Crossbow / left-click attack/mining: yaw, degrees |
| `mcitem_tp_crossbow_attack_z` | `0` | Client | Crossbow / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_crossbow_charged_arrow_pitch` | `90` | Client | Crossbow / loaded with an arrow: pitch, degrees |
| `mcitem_tp_crossbow_charged_arrow_roll` | `195` | Client | Crossbow / loaded with an arrow: roll, degrees |
| `mcitem_tp_crossbow_charged_arrow_scale` | `1.3` | Client | Crossbow / loaded with an arrow: scale multiplier |
| `mcitem_tp_crossbow_charged_arrow_x` | `0` | Client | Crossbow / loaded with an arrow: forward/back translation, Source units |
| `mcitem_tp_crossbow_charged_arrow_y` | `9` | Client | Crossbow / loaded with an arrow: lateral translation, Source units |
| `mcitem_tp_crossbow_charged_arrow_yaw` | `10` | Client | Crossbow / loaded with an arrow: yaw, degrees |
| `mcitem_tp_crossbow_charged_arrow_z` | `-6.5` | Client | Crossbow / loaded with an arrow: vertical translation, Source units |
| `mcitem_tp_crossbow_charged_firework_pitch` | `90` | Client | Crossbow / loaded with a firework: pitch, degrees |
| `mcitem_tp_crossbow_charged_firework_roll` | `195` | Client | Crossbow / loaded with a firework: roll, degrees |
| `mcitem_tp_crossbow_charged_firework_scale` | `1.3` | Client | Crossbow / loaded with a firework: scale multiplier |
| `mcitem_tp_crossbow_charged_firework_x` | `0` | Client | Crossbow / loaded with a firework: forward/back translation, Source units |
| `mcitem_tp_crossbow_charged_firework_y` | `9` | Client | Crossbow / loaded with a firework: lateral translation, Source units |
| `mcitem_tp_crossbow_charged_firework_yaw` | `10` | Client | Crossbow / loaded with a firework: yaw, degrees |
| `mcitem_tp_crossbow_charged_firework_z` | `-6.5` | Client | Crossbow / loaded with a firework: vertical translation, Source units |
| `mcitem_tp_crossbow_idle_pitch` | `10` | Client | Crossbow / idle: pitch, degrees |
| `mcitem_tp_crossbow_idle_roll` | `190` | Client | Crossbow / idle: roll, degrees |
| `mcitem_tp_crossbow_idle_scale` | `1.3` | Client | Crossbow / idle: scale multiplier |
| `mcitem_tp_crossbow_idle_x` | `0` | Client | Crossbow / idle: forward/back translation, Source units |
| `mcitem_tp_crossbow_idle_y` | `5` | Client | Crossbow / idle: lateral translation, Source units |
| `mcitem_tp_crossbow_idle_yaw` | `-25` | Client | Crossbow / idle: yaw, degrees |
| `mcitem_tp_crossbow_idle_z` | `-9` | Client | Crossbow / idle: vertical translation, Source units |
| `mcitem_tp_crossbow_load_0_pitch` | `-270` | Client | Crossbow / loading stage 0: pitch, degrees |
| `mcitem_tp_crossbow_load_0_roll` | `200` | Client | Crossbow / loading stage 0: roll, degrees |
| `mcitem_tp_crossbow_load_0_scale` | `1.3` | Client | Crossbow / loading stage 0: scale multiplier |
| `mcitem_tp_crossbow_load_0_x` | `0` | Client | Crossbow / loading stage 0: forward/back translation, Source units |
| `mcitem_tp_crossbow_load_0_y` | `0` | Client | Crossbow / loading stage 0: lateral translation, Source units |
| `mcitem_tp_crossbow_load_0_yaw` | `0` | Client | Crossbow / loading stage 0: yaw, degrees |
| `mcitem_tp_crossbow_load_0_z` | `-5` | Client | Crossbow / loading stage 0: vertical translation, Source units |
| `mcitem_tp_crossbow_load_1_pitch` | `-270` | Client | Crossbow / loading stage 1: pitch, degrees |
| `mcitem_tp_crossbow_load_1_roll` | `200` | Client | Crossbow / loading stage 1: roll, degrees |
| `mcitem_tp_crossbow_load_1_scale` | `1.3` | Client | Crossbow / loading stage 1: scale multiplier |
| `mcitem_tp_crossbow_load_1_x` | `0` | Client | Crossbow / loading stage 1: forward/back translation, Source units |
| `mcitem_tp_crossbow_load_1_y` | `0` | Client | Crossbow / loading stage 1: lateral translation, Source units |
| `mcitem_tp_crossbow_load_1_yaw` | `0` | Client | Crossbow / loading stage 1: yaw, degrees |
| `mcitem_tp_crossbow_load_1_z` | `-5` | Client | Crossbow / loading stage 1: vertical translation, Source units |
| `mcitem_tp_crossbow_load_2_pitch` | `-270` | Client | Crossbow / loading stage 2: pitch, degrees |
| `mcitem_tp_crossbow_load_2_roll` | `200` | Client | Crossbow / loading stage 2: roll, degrees |
| `mcitem_tp_crossbow_load_2_scale` | `1.3` | Client | Crossbow / loading stage 2: scale multiplier |
| `mcitem_tp_crossbow_load_2_x` | `0` | Client | Crossbow / loading stage 2: forward/back translation, Source units |
| `mcitem_tp_crossbow_load_2_y` | `0` | Client | Crossbow / loading stage 2: lateral translation, Source units |
| `mcitem_tp_crossbow_load_2_yaw` | `0` | Client | Crossbow / loading stage 2: yaw, degrees |
| `mcitem_tp_crossbow_load_2_z` | `-5` | Client | Crossbow / loading stage 2: vertical translation, Source units |
| `mcitem_tp_fishing_rod_attack_pitch` | `0` | Client | Fishing rod / left-click attack/mining: pitch, degrees |
| `mcitem_tp_fishing_rod_attack_roll` | `0` | Client | Fishing rod / left-click attack/mining: roll, degrees |
| `mcitem_tp_fishing_rod_attack_scale` | `0.6` | Client | Fishing rod / left-click attack/mining: scale multiplier |
| `mcitem_tp_fishing_rod_attack_x` | `1` | Client | Fishing rod / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_fishing_rod_attack_y` | `5` | Client | Fishing rod / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_fishing_rod_attack_yaw` | `-20` | Client | Fishing rod / left-click attack/mining: yaw, degrees |
| `mcitem_tp_fishing_rod_attack_z` | `-5` | Client | Fishing rod / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_fishing_rod_idle_pitch` | `0` | Client | Fishing rod / idle: pitch, degrees |
| `mcitem_tp_fishing_rod_idle_roll` | `0` | Client | Fishing rod / idle: roll, degrees |
| `mcitem_tp_fishing_rod_idle_scale` | `0.6` | Client | Fishing rod / idle: scale multiplier |
| `mcitem_tp_fishing_rod_idle_x` | `1` | Client | Fishing rod / idle: forward/back translation, Source units |
| `mcitem_tp_fishing_rod_idle_y` | `5` | Client | Fishing rod / idle: lateral translation, Source units |
| `mcitem_tp_fishing_rod_idle_yaw` | `-20` | Client | Fishing rod / idle: yaw, degrees |
| `mcitem_tp_fishing_rod_idle_z` | `-5` | Client | Fishing rod / idle: vertical translation, Source units |
| `mcitem_tp_fishing_rod_use_pitch` | `0` | Client | Fishing rod / use: pitch, degrees |
| `mcitem_tp_fishing_rod_use_roll` | `0` | Client | Fishing rod / use: roll, degrees |
| `mcitem_tp_fishing_rod_use_scale` | `0.6` | Client | Fishing rod / use: scale multiplier |
| `mcitem_tp_fishing_rod_use_x` | `1` | Client | Fishing rod / use: forward/back translation, Source units |
| `mcitem_tp_fishing_rod_use_y` | `5` | Client | Fishing rod / use: lateral translation, Source units |
| `mcitem_tp_fishing_rod_use_yaw` | `-20` | Client | Fishing rod / use: yaw, degrees |
| `mcitem_tp_fishing_rod_use_z` | `-5` | Client | Fishing rod / use: vertical translation, Source units |
| `mcitem_tp_flint_and_steel_attack_pitch` | `0` | Client | Flint and steel / left-click attack/mining: pitch, degrees |
| `mcitem_tp_flint_and_steel_attack_roll` | `-45` | Client | Flint and steel / left-click attack/mining: roll, degrees |
| `mcitem_tp_flint_and_steel_attack_scale` | `0.6` | Client | Flint and steel / left-click attack/mining: scale multiplier |
| `mcitem_tp_flint_and_steel_attack_x` | `1` | Client | Flint and steel / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_flint_and_steel_attack_y` | `5` | Client | Flint and steel / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_flint_and_steel_attack_yaw` | `-20` | Client | Flint and steel / left-click attack/mining: yaw, degrees |
| `mcitem_tp_flint_and_steel_attack_z` | `-4` | Client | Flint and steel / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_flint_and_steel_idle_pitch` | `0` | Client | Flint and steel / idle: pitch, degrees |
| `mcitem_tp_flint_and_steel_idle_roll` | `-45` | Client | Flint and steel / idle: roll, degrees |
| `mcitem_tp_flint_and_steel_idle_scale` | `0.6` | Client | Flint and steel / idle: scale multiplier |
| `mcitem_tp_flint_and_steel_idle_x` | `1` | Client | Flint and steel / idle: forward/back translation, Source units |
| `mcitem_tp_flint_and_steel_idle_y` | `5` | Client | Flint and steel / idle: lateral translation, Source units |
| `mcitem_tp_flint_and_steel_idle_yaw` | `-20` | Client | Flint and steel / idle: yaw, degrees |
| `mcitem_tp_flint_and_steel_idle_z` | `-4` | Client | Flint and steel / idle: vertical translation, Source units |
| `mcitem_tp_flint_and_steel_use_pitch` | `0` | Client | Flint and steel / use: pitch, degrees |
| `mcitem_tp_flint_and_steel_use_roll` | `-45` | Client | Flint and steel / use: roll, degrees |
| `mcitem_tp_flint_and_steel_use_scale` | `0.6` | Client | Flint and steel / use: scale multiplier |
| `mcitem_tp_flint_and_steel_use_x` | `1` | Client | Flint and steel / use: forward/back translation, Source units |
| `mcitem_tp_flint_and_steel_use_y` | `5` | Client | Flint and steel / use: lateral translation, Source units |
| `mcitem_tp_flint_and_steel_use_yaw` | `-20` | Client | Flint and steel / use: yaw, degrees |
| `mcitem_tp_flint_and_steel_use_z` | `-4` | Client | Flint and steel / use: vertical translation, Source units |
| `mcitem_tp_food_attack_pitch` | `0` | Client | Food / left-click attack/mining: pitch, degrees |
| `mcitem_tp_food_attack_roll` | `0` | Client | Food / left-click attack/mining: roll, degrees |
| `mcitem_tp_food_attack_scale` | `0.6` | Client | Food / left-click attack/mining: scale multiplier |
| `mcitem_tp_food_attack_x` | `1` | Client | Food / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_food_attack_y` | `5` | Client | Food / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_food_attack_yaw` | `-20` | Client | Food / left-click attack/mining: yaw, degrees |
| `mcitem_tp_food_attack_z` | `-5` | Client | Food / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_food_idle_pitch` | `0` | Client | Food / idle: pitch, degrees |
| `mcitem_tp_food_idle_roll` | `0` | Client | Food / idle: roll, degrees |
| `mcitem_tp_food_idle_scale` | `0.6` | Client | Food / idle: scale multiplier |
| `mcitem_tp_food_idle_x` | `1` | Client | Food / idle: forward/back translation, Source units |
| `mcitem_tp_food_idle_y` | `5` | Client | Food / idle: lateral translation, Source units |
| `mcitem_tp_food_idle_yaw` | `-20` | Client | Food / idle: yaw, degrees |
| `mcitem_tp_food_idle_z` | `-5` | Client | Food / idle: vertical translation, Source units |
| `mcitem_tp_food_use_pitch` | `30` | Client | Food / use: pitch, degrees |
| `mcitem_tp_food_use_roll` | `20` | Client | Food / use: roll, degrees |
| `mcitem_tp_food_use_scale` | `0.6` | Client | Food / use: scale multiplier |
| `mcitem_tp_food_use_x` | `-3` | Client | Food / use: forward/back translation, Source units |
| `mcitem_tp_food_use_y` | `5` | Client | Food / use: lateral translation, Source units |
| `mcitem_tp_food_use_yaw` | `60` | Client | Food / use: yaw, degrees |
| `mcitem_tp_food_use_z` | `-9` | Client | Food / use: vertical translation, Source units |
| `mcitem_tp_hoe_attack_pitch` | `-10` | Client | Hoe / left-click attack/mining: pitch, degrees |
| `mcitem_tp_hoe_attack_roll` | `50` | Client | Hoe / left-click attack/mining: roll, degrees |
| `mcitem_tp_hoe_attack_scale` | `1.3` | Client | Hoe / left-click attack/mining: scale multiplier |
| `mcitem_tp_hoe_attack_x` | `1.5` | Client | Hoe / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_hoe_attack_y` | `5` | Client | Hoe / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_hoe_attack_yaw` | `-200` | Client | Hoe / left-click attack/mining: yaw, degrees |
| `mcitem_tp_hoe_attack_z` | `-1` | Client | Hoe / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_hoe_idle_pitch` | `-10` | Client | Hoe / idle: pitch, degrees |
| `mcitem_tp_hoe_idle_roll` | `50` | Client | Hoe / idle: roll, degrees |
| `mcitem_tp_hoe_idle_scale` | `1.3` | Client | Hoe / idle: scale multiplier |
| `mcitem_tp_hoe_idle_x` | `1.5` | Client | Hoe / idle: forward/back translation, Source units |
| `mcitem_tp_hoe_idle_y` | `5` | Client | Hoe / idle: lateral translation, Source units |
| `mcitem_tp_hoe_idle_yaw` | `-200` | Client | Hoe / idle: yaw, degrees |
| `mcitem_tp_hoe_idle_z` | `-1` | Client | Hoe / idle: vertical translation, Source units |
| `mcitem_tp_mace_attack_pitch` | `5` | Client | Mace / left-click attack/mining: pitch, degrees |
| `mcitem_tp_mace_attack_roll` | `0` | Client | Mace / left-click attack/mining: roll, degrees |
| `mcitem_tp_mace_attack_scale` | `1.4` | Client | Mace / left-click attack/mining: scale multiplier |
| `mcitem_tp_mace_attack_x` | `-0.8` | Client | Mace / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_mace_attack_y` | `2` | Client | Mace / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_mace_attack_yaw` | `2` | Client | Mace / left-click attack/mining: yaw, degrees |
| `mcitem_tp_mace_attack_z` | `-2` | Client | Mace / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_mace_idle_pitch` | `5` | Client | Mace / idle: pitch, degrees |
| `mcitem_tp_mace_idle_roll` | `0` | Client | Mace / idle: roll, degrees |
| `mcitem_tp_mace_idle_scale` | `1.4` | Client | Mace / idle: scale multiplier |
| `mcitem_tp_mace_idle_x` | `-0.8` | Client | Mace / idle: forward/back translation, Source units |
| `mcitem_tp_mace_idle_y` | `2` | Client | Mace / idle: lateral translation, Source units |
| `mcitem_tp_mace_idle_yaw` | `2` | Client | Mace / idle: yaw, degrees |
| `mcitem_tp_mace_idle_z` | `-2` | Client | Mace / idle: vertical translation, Source units |
| `mcitem_tp_name_tag_attack_pitch` | `0` | Client | Name tag / left-click attack/mining: pitch, degrees |
| `mcitem_tp_name_tag_attack_roll` | `0` | Client | Name tag / left-click attack/mining: roll, degrees |
| `mcitem_tp_name_tag_attack_scale` | `0.6` | Client | Name tag / left-click attack/mining: scale multiplier |
| `mcitem_tp_name_tag_attack_x` | `1` | Client | Name tag / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_name_tag_attack_y` | `5` | Client | Name tag / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_name_tag_attack_yaw` | `-20` | Client | Name tag / left-click attack/mining: yaw, degrees |
| `mcitem_tp_name_tag_attack_z` | `-5` | Client | Name tag / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_name_tag_idle_pitch` | `0` | Client | Name tag / idle: pitch, degrees |
| `mcitem_tp_name_tag_idle_roll` | `0` | Client | Name tag / idle: roll, degrees |
| `mcitem_tp_name_tag_idle_scale` | `0.6` | Client | Name tag / idle: scale multiplier |
| `mcitem_tp_name_tag_idle_x` | `1` | Client | Name tag / idle: forward/back translation, Source units |
| `mcitem_tp_name_tag_idle_y` | `5` | Client | Name tag / idle: lateral translation, Source units |
| `mcitem_tp_name_tag_idle_yaw` | `-20` | Client | Name tag / idle: yaw, degrees |
| `mcitem_tp_name_tag_idle_z` | `-5` | Client | Name tag / idle: vertical translation, Source units |
| `mcitem_tp_pickaxe_attack_pitch` | `-10` | Client | Pickaxe / left-click attack/mining: pitch, degrees |
| `mcitem_tp_pickaxe_attack_roll` | `50` | Client | Pickaxe / left-click attack/mining: roll, degrees |
| `mcitem_tp_pickaxe_attack_scale` | `1.3` | Client | Pickaxe / left-click attack/mining: scale multiplier |
| `mcitem_tp_pickaxe_attack_x` | `1.5` | Client | Pickaxe / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_pickaxe_attack_y` | `5` | Client | Pickaxe / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_pickaxe_attack_yaw` | `-200` | Client | Pickaxe / left-click attack/mining: yaw, degrees |
| `mcitem_tp_pickaxe_attack_z` | `-1` | Client | Pickaxe / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_pickaxe_idle_pitch` | `-10` | Client | Pickaxe / idle: pitch, degrees |
| `mcitem_tp_pickaxe_idle_roll` | `50` | Client | Pickaxe / idle: roll, degrees |
| `mcitem_tp_pickaxe_idle_scale` | `1.3` | Client | Pickaxe / idle: scale multiplier |
| `mcitem_tp_pickaxe_idle_x` | `1.5` | Client | Pickaxe / idle: forward/back translation, Source units |
| `mcitem_tp_pickaxe_idle_y` | `5` | Client | Pickaxe / idle: lateral translation, Source units |
| `mcitem_tp_pickaxe_idle_yaw` | `-200` | Client | Pickaxe / idle: yaw, degrees |
| `mcitem_tp_pickaxe_idle_z` | `-1` | Client | Pickaxe / idle: vertical translation, Source units |
| `mcitem_tp_potion_attack_pitch` | `0` | Client | Potion / left-click attack/mining: pitch, degrees |
| `mcitem_tp_potion_attack_roll` | `0` | Client | Potion / left-click attack/mining: roll, degrees |
| `mcitem_tp_potion_attack_scale` | `0.6` | Client | Potion / left-click attack/mining: scale multiplier |
| `mcitem_tp_potion_attack_x` | `1` | Client | Potion / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_potion_attack_y` | `5` | Client | Potion / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_potion_attack_yaw` | `-20` | Client | Potion / left-click attack/mining: yaw, degrees |
| `mcitem_tp_potion_attack_z` | `-5` | Client | Potion / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_potion_idle_pitch` | `0` | Client | Potion / idle: pitch, degrees |
| `mcitem_tp_potion_idle_roll` | `0` | Client | Potion / idle: roll, degrees |
| `mcitem_tp_potion_idle_scale` | `0.6` | Client | Potion / idle: scale multiplier |
| `mcitem_tp_potion_idle_x` | `1` | Client | Potion / idle: forward/back translation, Source units |
| `mcitem_tp_potion_idle_y` | `5` | Client | Potion / idle: lateral translation, Source units |
| `mcitem_tp_potion_idle_yaw` | `-20` | Client | Potion / idle: yaw, degrees |
| `mcitem_tp_potion_idle_z` | `-5` | Client | Potion / idle: vertical translation, Source units |
| `mcitem_tp_potion_throw_pitch` | `0` | Client | Potion / throwing: pitch, degrees |
| `mcitem_tp_potion_throw_roll` | `0` | Client | Potion / throwing: roll, degrees |
| `mcitem_tp_potion_throw_scale` | `1` | Client | Potion / throwing: scale multiplier |
| `mcitem_tp_potion_throw_x` | `0` | Client | Potion / throwing: forward/back translation, Source units |
| `mcitem_tp_potion_throw_y` | `0` | Client | Potion / throwing: lateral translation, Source units |
| `mcitem_tp_potion_throw_yaw` | `0` | Client | Potion / throwing: yaw, degrees |
| `mcitem_tp_potion_throw_z` | `0` | Client | Potion / throwing: vertical translation, Source units |
| `mcitem_tp_potion_use_pitch` | `30` | Client | Potion / use: pitch, degrees |
| `mcitem_tp_potion_use_roll` | `20` | Client | Potion / use: roll, degrees |
| `mcitem_tp_potion_use_scale` | `0.6` | Client | Potion / use: scale multiplier |
| `mcitem_tp_potion_use_x` | `-3` | Client | Potion / use: forward/back translation, Source units |
| `mcitem_tp_potion_use_y` | `5` | Client | Potion / use: lateral translation, Source units |
| `mcitem_tp_potion_use_yaw` | `60` | Client | Potion / use: yaw, degrees |
| `mcitem_tp_potion_use_z` | `-9` | Client | Potion / use: vertical translation, Source units |
| `mcitem_tp_shears_attack_pitch` | `0` | Client | Shears / left-click attack/mining: pitch, degrees |
| `mcitem_tp_shears_attack_roll` | `0` | Client | Shears / left-click attack/mining: roll, degrees |
| `mcitem_tp_shears_attack_scale` | `0.6` | Client | Shears / left-click attack/mining: scale multiplier |
| `mcitem_tp_shears_attack_x` | `1` | Client | Shears / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_shears_attack_y` | `5` | Client | Shears / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_shears_attack_yaw` | `-20` | Client | Shears / left-click attack/mining: yaw, degrees |
| `mcitem_tp_shears_attack_z` | `-5` | Client | Shears / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_shears_idle_pitch` | `0` | Client | Shears / idle: pitch, degrees |
| `mcitem_tp_shears_idle_roll` | `0` | Client | Shears / idle: roll, degrees |
| `mcitem_tp_shears_idle_scale` | `0.6` | Client | Shears / idle: scale multiplier |
| `mcitem_tp_shears_idle_x` | `1` | Client | Shears / idle: forward/back translation, Source units |
| `mcitem_tp_shears_idle_y` | `5` | Client | Shears / idle: lateral translation, Source units |
| `mcitem_tp_shears_idle_yaw` | `-20` | Client | Shears / idle: yaw, degrees |
| `mcitem_tp_shears_idle_z` | `-5` | Client | Shears / idle: vertical translation, Source units |
| `mcitem_tp_shears_use_pitch` | `0` | Client | Shears / use: pitch, degrees |
| `mcitem_tp_shears_use_roll` | `0` | Client | Shears / use: roll, degrees |
| `mcitem_tp_shears_use_scale` | `0.6` | Client | Shears / use: scale multiplier |
| `mcitem_tp_shears_use_x` | `1` | Client | Shears / use: forward/back translation, Source units |
| `mcitem_tp_shears_use_y` | `5` | Client | Shears / use: lateral translation, Source units |
| `mcitem_tp_shears_use_yaw` | `-20` | Client | Shears / use: yaw, degrees |
| `mcitem_tp_shears_use_z` | `-5` | Client | Shears / use: vertical translation, Source units |
| `mcitem_tp_shield_attack_pitch` | `180` | Client | Shield / left-click attack/mining: pitch, degrees |
| `mcitem_tp_shield_attack_roll` | `5` | Client | Shield / left-click attack/mining: roll, degrees |
| `mcitem_tp_shield_attack_scale` | `1.3` | Client | Shield / left-click attack/mining: scale multiplier |
| `mcitem_tp_shield_attack_x` | `2` | Client | Shield / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_shield_attack_y` | `12` | Client | Shield / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_shield_attack_yaw` | `30` | Client | Shield / left-click attack/mining: yaw, degrees |
| `mcitem_tp_shield_attack_z` | `-4` | Client | Shield / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_shield_block_pitch` | `165` | Client | Shield / blocking: pitch, degrees |
| `mcitem_tp_shield_block_roll` | `170` | Client | Shield / blocking: roll, degrees |
| `mcitem_tp_shield_block_scale` | `1.3` | Client | Shield / blocking: scale multiplier |
| `mcitem_tp_shield_block_x` | `0` | Client | Shield / blocking: forward/back translation, Source units |
| `mcitem_tp_shield_block_y` | `0` | Client | Shield / blocking: lateral translation, Source units |
| `mcitem_tp_shield_block_yaw` | `-90` | Client | Shield / blocking: yaw, degrees |
| `mcitem_tp_shield_block_z` | `-6` | Client | Shield / blocking: vertical translation, Source units |
| `mcitem_tp_shield_idle_pitch` | `180` | Client | Shield / idle: pitch, degrees |
| `mcitem_tp_shield_idle_roll` | `5` | Client | Shield / idle: roll, degrees |
| `mcitem_tp_shield_idle_scale` | `1.3` | Client | Shield / idle: scale multiplier |
| `mcitem_tp_shield_idle_x` | `2` | Client | Shield / idle: forward/back translation, Source units |
| `mcitem_tp_shield_idle_y` | `12` | Client | Shield / idle: lateral translation, Source units |
| `mcitem_tp_shield_idle_yaw` | `30` | Client | Shield / idle: yaw, degrees |
| `mcitem_tp_shield_idle_z` | `-4` | Client | Shield / idle: vertical translation, Source units |
| `mcitem_tp_shovel_attack_pitch` | `-10` | Client | Shovel / left-click attack/mining: pitch, degrees |
| `mcitem_tp_shovel_attack_roll` | `50` | Client | Shovel / left-click attack/mining: roll, degrees |
| `mcitem_tp_shovel_attack_scale` | `1.3` | Client | Shovel / left-click attack/mining: scale multiplier |
| `mcitem_tp_shovel_attack_x` | `1.5` | Client | Shovel / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_shovel_attack_y` | `5` | Client | Shovel / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_shovel_attack_yaw` | `-200` | Client | Shovel / left-click attack/mining: yaw, degrees |
| `mcitem_tp_shovel_attack_z` | `-1` | Client | Shovel / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_shovel_idle_pitch` | `-10` | Client | Shovel / idle: pitch, degrees |
| `mcitem_tp_shovel_idle_roll` | `50` | Client | Shovel / idle: roll, degrees |
| `mcitem_tp_shovel_idle_scale` | `1.3` | Client | Shovel / idle: scale multiplier |
| `mcitem_tp_shovel_idle_x` | `1.5` | Client | Shovel / idle: forward/back translation, Source units |
| `mcitem_tp_shovel_idle_y` | `5` | Client | Shovel / idle: lateral translation, Source units |
| `mcitem_tp_shovel_idle_yaw` | `-200` | Client | Shovel / idle: yaw, degrees |
| `mcitem_tp_shovel_idle_z` | `-1` | Client | Shovel / idle: vertical translation, Source units |
| `mcitem_tp_spear_attack_pitch` | `15` | Client | Spear / left-click attack/mining: pitch, degrees |
| `mcitem_tp_spear_attack_roll` | `205` | Client | Spear / left-click attack/mining: roll, degrees |
| `mcitem_tp_spear_attack_scale` | `2` | Client | Spear / left-click attack/mining: scale multiplier |
| `mcitem_tp_spear_attack_x` | `7` | Client | Spear / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_spear_attack_y` | `-3` | Client | Spear / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_spear_attack_yaw` | `-35` | Client | Spear / left-click attack/mining: yaw, degrees |
| `mcitem_tp_spear_attack_z` | `-10` | Client | Spear / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_spear_idle_pitch` | `-5` | Client | Spear / idle: pitch, degrees |
| `mcitem_tp_spear_idle_roll` | `50` | Client | Spear / idle: roll, degrees |
| `mcitem_tp_spear_idle_scale` | `2` | Client | Spear / idle: scale multiplier |
| `mcitem_tp_spear_idle_x` | `0` | Client | Spear / idle: forward/back translation, Source units |
| `mcitem_tp_spear_idle_y` | `7` | Client | Spear / idle: lateral translation, Source units |
| `mcitem_tp_spear_idle_yaw` | `150` | Client | Spear / idle: yaw, degrees |
| `mcitem_tp_spear_idle_z` | `-1` | Client | Spear / idle: vertical translation, Source units |
| `mcitem_tp_spear_use_pitch` | `15` | Client | Spear / use: pitch, degrees |
| `mcitem_tp_spear_use_roll` | `205` | Client | Spear / use: roll, degrees |
| `mcitem_tp_spear_use_scale` | `2` | Client | Spear / use: scale multiplier |
| `mcitem_tp_spear_use_x` | `7` | Client | Spear / use: forward/back translation, Source units |
| `mcitem_tp_spear_use_y` | `-3` | Client | Spear / use: lateral translation, Source units |
| `mcitem_tp_spear_use_yaw` | `-35` | Client | Spear / use: yaw, degrees |
| `mcitem_tp_spear_use_z` | `-10` | Client | Spear / use: vertical translation, Source units |
| `mcitem_tp_sword_attack_pitch` | `-15` | Client | Sword / left-click attack/mining: pitch, degrees |
| `mcitem_tp_sword_attack_roll` | `48` | Client | Sword / left-click attack/mining: roll, degrees |
| `mcitem_tp_sword_attack_scale` | `1.3` | Client | Sword / left-click attack/mining: scale multiplier |
| `mcitem_tp_sword_attack_x` | `2` | Client | Sword / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_sword_attack_y` | `7` | Client | Sword / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_sword_attack_yaw` | `-35` | Client | Sword / left-click attack/mining: yaw, degrees |
| `mcitem_tp_sword_attack_z` | `3` | Client | Sword / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_sword_idle_pitch` | `-15` | Client | Sword / idle: pitch, degrees |
| `mcitem_tp_sword_idle_roll` | `48` | Client | Sword / idle: roll, degrees |
| `mcitem_tp_sword_idle_scale` | `1.3` | Client | Sword / idle: scale multiplier |
| `mcitem_tp_sword_idle_x` | `2` | Client | Sword / idle: forward/back translation, Source units |
| `mcitem_tp_sword_idle_y` | `7` | Client | Sword / idle: lateral translation, Source units |
| `mcitem_tp_sword_idle_yaw` | `-35` | Client | Sword / idle: yaw, degrees |
| `mcitem_tp_sword_idle_z` | `3` | Client | Sword / idle: vertical translation, Source units |
| `mcitem_tp_throwable_attack_pitch` | `0` | Client | Projectile / left-click attack/mining: pitch, degrees |
| `mcitem_tp_throwable_attack_roll` | `0` | Client | Projectile / left-click attack/mining: roll, degrees |
| `mcitem_tp_throwable_attack_scale` | `0.6` | Client | Projectile / left-click attack/mining: scale multiplier |
| `mcitem_tp_throwable_attack_x` | `1` | Client | Projectile / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_throwable_attack_y` | `5` | Client | Projectile / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_throwable_attack_yaw` | `-20` | Client | Projectile / left-click attack/mining: yaw, degrees |
| `mcitem_tp_throwable_attack_z` | `-5` | Client | Projectile / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_throwable_idle_pitch` | `0` | Client | Projectile / idle: pitch, degrees |
| `mcitem_tp_throwable_idle_roll` | `0` | Client | Projectile / idle: roll, degrees |
| `mcitem_tp_throwable_idle_scale` | `0.6` | Client | Projectile / idle: scale multiplier |
| `mcitem_tp_throwable_idle_x` | `1` | Client | Projectile / idle: forward/back translation, Source units |
| `mcitem_tp_throwable_idle_y` | `5` | Client | Projectile / idle: lateral translation, Source units |
| `mcitem_tp_throwable_idle_yaw` | `-20` | Client | Projectile / idle: yaw, degrees |
| `mcitem_tp_throwable_idle_z` | `-5` | Client | Projectile / idle: vertical translation, Source units |
| `mcitem_tp_throwable_throw_pitch` | `0` | Client | Projectile / throwing: pitch, degrees |
| `mcitem_tp_throwable_throw_roll` | `0` | Client | Projectile / throwing: roll, degrees |
| `mcitem_tp_throwable_throw_scale` | `0.6` | Client | Projectile / throwing: scale multiplier |
| `mcitem_tp_throwable_throw_x` | `1` | Client | Projectile / throwing: forward/back translation, Source units |
| `mcitem_tp_throwable_throw_y` | `5` | Client | Projectile / throwing: lateral translation, Source units |
| `mcitem_tp_throwable_throw_yaw` | `-20` | Client | Projectile / throwing: yaw, degrees |
| `mcitem_tp_throwable_throw_z` | `-5` | Client | Projectile / throwing: vertical translation, Source units |
| `mcitem_tp_totem_of_undying_attack_pitch` | `0` | Client | Totem of Undying / left-click attack/mining: pitch, degrees |
| `mcitem_tp_totem_of_undying_attack_roll` | `0` | Client | Totem of Undying / left-click attack/mining: roll, degrees |
| `mcitem_tp_totem_of_undying_attack_scale` | `0.6` | Client | Totem of Undying / left-click attack/mining: scale multiplier |
| `mcitem_tp_totem_of_undying_attack_x` | `1` | Client | Totem of Undying / left-click attack/mining: forward/back translation, Source units |
| `mcitem_tp_totem_of_undying_attack_y` | `5` | Client | Totem of Undying / left-click attack/mining: lateral translation, Source units |
| `mcitem_tp_totem_of_undying_attack_yaw` | `-20` | Client | Totem of Undying / left-click attack/mining: yaw, degrees |
| `mcitem_tp_totem_of_undying_attack_z` | `-5` | Client | Totem of Undying / left-click attack/mining: vertical translation, Source units |
| `mcitem_tp_totem_of_undying_idle_pitch` | `0` | Client | Totem of Undying / idle: pitch, degrees |
| `mcitem_tp_totem_of_undying_idle_roll` | `0` | Client | Totem of Undying / idle: roll, degrees |
| `mcitem_tp_totem_of_undying_idle_scale` | `0.6` | Client | Totem of Undying / idle: scale multiplier |
| `mcitem_tp_totem_of_undying_idle_x` | `1` | Client | Totem of Undying / idle: forward/back translation, Source units |
| `mcitem_tp_totem_of_undying_idle_y` | `5` | Client | Totem of Undying / idle: lateral translation, Source units |
| `mcitem_tp_totem_of_undying_idle_yaw` | `-20` | Client | Totem of Undying / idle: yaw, degrees |
| `mcitem_tp_totem_of_undying_idle_z` | `-5` | Client | Totem of Undying / idle: vertical translation, Source units |
| `mcitem_tp_trident_charge_pitch` | `90` | Client | Trident / charging: pitch, degrees |
| `mcitem_tp_trident_charge_roll` | `0` | Client | Trident / charging: roll, degrees |
| `mcitem_tp_trident_charge_scale` | `1.3` | Client | Trident / charging: scale multiplier |
| `mcitem_tp_trident_charge_x` | `20` | Client | Trident / charging: forward/back translation, Source units |
| `mcitem_tp_trident_charge_y` | `7` | Client | Trident / charging: lateral translation, Source units |
| `mcitem_tp_trident_charge_yaw` | `-15` | Client | Trident / charging: yaw, degrees |
| `mcitem_tp_trident_charge_z` | `-7` | Client | Trident / charging: vertical translation, Source units |
| `mcitem_tp_trident_idle_pitch` | `0` | Client | Trident / idle: pitch, degrees |
| `mcitem_tp_trident_idle_roll` | `-30` | Client | Trident / idle: roll, degrees |
| `mcitem_tp_trident_idle_scale` | `1.3` | Client | Trident / idle: scale multiplier |
| `mcitem_tp_trident_idle_x` | `0` | Client | Trident / idle: forward/back translation, Source units |
| `mcitem_tp_trident_idle_y` | `15` | Client | Trident / idle: lateral translation, Source units |
| `mcitem_tp_trident_idle_yaw` | `0` | Client | Trident / idle: yaw, degrees |
| `mcitem_tp_trident_idle_z` | `-20` | Client | Trident / idle: vertical translation, Source units |
| `mcitem_tp_trident_melee_pitch` | `0` | Client | Trident / melee: pitch, degrees |
| `mcitem_tp_trident_melee_roll` | `-30` | Client | Trident / melee: roll, degrees |
| `mcitem_tp_trident_melee_scale` | `1.3` | Client | Trident / melee: scale multiplier |
| `mcitem_tp_trident_melee_x` | `0` | Client | Trident / melee: forward/back translation, Source units |
| `mcitem_tp_trident_melee_y` | `15` | Client | Trident / melee: lateral translation, Source units |
| `mcitem_tp_trident_melee_yaw` | `0` | Client | Trident / melee: yaw, degrees |
| `mcitem_tp_trident_melee_z` | `-20` | Client | Trident / melee: vertical translation, Source units |
| `mcitem_tp_trident_throw_pitch` | `0` | Client | Trident / throwing: pitch, degrees |
| `mcitem_tp_trident_throw_roll` | `0` | Client | Trident / throwing: roll, degrees |
| `mcitem_tp_trident_throw_scale` | `1` | Client | Trident / throwing: scale multiplier |
| `mcitem_tp_trident_throw_x` | `0` | Client | Trident / throwing: forward/back translation, Source units |
| `mcitem_tp_trident_throw_y` | `0` | Client | Trident / throwing: lateral translation, Source units |
| `mcitem_tp_trident_throw_yaw` | `0` | Client | Trident / throwing: yaw, degrees |
| `mcitem_tp_trident_throw_z` | `0` | Client | Trident / throwing: vertical translation, Source units |

Source: [sh_holdtypes.lua](../addons/mc_item/lua/mcitem/sh_holdtypes.lua).

<a id="convars-20"></a>

## MC Item: projectile model orientation

Created when arrow/trident model orientation is first calculated; server registrations are replicated. Rotations are added to the flight direction, rather than to a first-person held pose.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mcitem_arrow_model_pitch` | `0` | Server | Arrow projectile model offset relative to the flight direction: pitch, degrees; created on demand |
| `mcitem_arrow_model_roll` | `0` | Server | Arrow projectile model offset relative to the flight direction: roll, degrees; created on demand |
| `mcitem_arrow_model_yaw` | `0` | Server | Arrow projectile model offset relative to the flight direction: yaw, degrees; created on demand |
| `mcitem_trident_model_pitch` | `0` | Server | Trident projectile model offset relative to the flight direction: pitch, degrees; created on demand |
| `mcitem_trident_model_roll` | `90` | Server | Trident projectile model offset relative to the flight direction: roll, degrees; created on demand |
| `mcitem_trident_model_yaw` | `90` | Server | Trident projectile model offset relative to the flight direction: yaw, degrees; created on demand |

Source: [shared.lua](../addons/mc_item/lua/entities/mcitem_arrow/shared.lua).

<a id="convars-21"></a>

## Debugging and performance diagnostics

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_binary_net_profile` | `0` | Server | Collect server timings for binary encoding, compression, queueing, and net.Send |
| `mc_client_collision_aabb_debug` | `0` | Client | Draw predicted collision AABBs on the client |
| `mc_client_collision_aabb_debug_limit` | `2048` | Client | Maximum predicted collision AABBs drawn on the client |
| `mc_client_collision_area_debug` | `0` | Client | Draw the client prediction collision area of interest |
| `mc_client_collision_debug` | `0` | Client | Print client prediction collision rebuild information |
| `mc_debug_block_interact` | `0` | Server | Print server-console reasons why right-click block interaction did or did not trigger |
| `mc_debug_gallery_aim_distance` | `4096` | Client | Maximum debug-gallery inspector trace distance, Source units |
| `mc_debug_gallery_hud` | `1` | Client | Show block/state identity when aiming at a debug-gallery entry |
| `mc_light_perf_debug` | `0` | Client | Display and collect detailed lighting performance information |
| `mc_light_perf_print_break` | `0` | Client | Print lighting performance information after breaking a block |
| `mc_light_perf_print_each` | `0` | Client | Print one timing line for each lighting calculation |
| `mc_mesh_debug_full_cube_only` | `0` | Client | Debug: emit meshes only for full-cube blocks |
| `mc_mesh_emit_probe` | `0` | Client | Print detailed timings for complete mesh geometry rebuilds |
| `mc_pbr_bloom_debug` | `0` | Client | Debug: display extracted and blurred highlights |
| `mc_pbr_ssao_debug` | `0` | Client | Debug: display the SSAO visibility buffer |
| `mc_pbr_volumetric_debug` | `0` | Client | Debug: display only sun scattering |
| `mc_pbr_water_ssr_debug` | `0` | Client | Debug: display intermediate water SSR render targets |
| `mc_server_collision_debug` | `0` | Client | Draw server-authoritative collision interest boundaries on the client |
| `mc_stream_profile_debug` | `0` | Client | Print frame timings for streaming patches and unloads |
| `mc_strict` | `0` | Independent per realm | Error handling in this realm: 0 log and continue, 1 raise a Lua error at the failure |
| `mcitem_debug` | `0` | Client | Show actual MC tick/swing timing and reference values; not archived |
| `mcitem_entity_interact_debug` | `0` | Server | Print server dispatch results for MC Item right-click entity interactions |

Source: [cl_debug.lua](../addons/mc_engine/lua/mc/cl_debug.lua), [cl_lighting.lua](../addons/mc_engine/lua/mc/cl_lighting.lua), [cl_net.lua](../addons/mc_engine/lua/mc/cl_net.lua), [cl_collision.lua](../addons/mc_engine/lua/mc/render/cl_collision.lua), [cl_mesh_config.lua](../addons/mc_engine/lua/mc/render/cl_mesh_config.lua), [cl_render_pbr_post.lua](../addons/mc_engine/lua/mc/render/cl_render_pbr_post.lua), [cl_render_pbr_ssr.lua](../addons/mc_engine/lua/mc/render/cl_render_pbr_ssr.lua), [sh_config.lua](../addons/mc_engine/lua/mc/sh_config.lua), [sh_fault.lua](../addons/mc_engine/lua/mc/sh_fault.lua), [sv_world.lua](../addons/mc_engine/lua/mc/sv_world.lua), [sh_block_interact.lua](../addons/mc_item/lua/mcitem/sh_block_interact.lua), [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-22"></a>

## Internal migration markers

Used for version migration, not user tuning. The table still lists registration defaults; post-migration values appear in the description column.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_client_collision_default_version` | `0` | Client | Internal collision-default migration marker; registered as 0, becomes 2 after migration |
| `mcitem_holdtype_item_idle_migration` | `0` | Server | Internal normal-item idle HoldType migration marker; registered as 0, becomes 1 after migration |
| `mcitem_holdtype_ranged_attack_migration` | `0` | Server | Internal bow/crossbow left-click attack HoldType migration marker; registered as 0, becomes 1 after migration |
| `mcitem_name_tag_scale_revision` | `0` | Client | Internal name-tag scale migration marker; registered as 0, becomes 1 after migration |
| `mcitem_tp_tuned_defaults_migration` | `0` | Client | Internal third-person pose-default migration marker; registered as 0, becomes 2 after migration |
| `mcitem_trident_pose_revision` | `0` | Client | Internal trident use-pose migration marker; registered as 0, becomes 2 after migration |

Source: [cl_collision.lua](../addons/mc_engine/lua/mc/render/cl_collision.lua), [cl_render.lua](../addons/mc_item/lua/mcitem/name_tags/cl_render.lua), [sh_holdtypes.lua](../addons/mc_item/lua/mcitem/sh_holdtypes.lua), [cl_view.lua](../addons/mc_item/lua/weapons/weapon_bmb_item_model_test/cl_view.lua).

<a id="convars-23"></a>

## Options retained in the legacy Native entry point

Registered only in the retained cl_native_mesh_backend.lua; the current main loader does not load this legacy L1 backend. These names may therefore be absent from a default installation's console. The current L2 mc_native_mesh defaults to 0, as listed under Mesh building and drawing; the legacy file's same-name default of 1 is not the current default.

| Variable | Default | Where to change | Description |
|---|---|---|---|
| `mc_native_directional_draw` | `1` | Client | Draw opaque face-direction ranges according to the camera direction in the legacy L1 backend |
| `mc_native_greedy` | `0` | Client | Use simple greedy merging for opaque full blocks in the legacy L1 backend |
| `mc_native_lod` | `0` | Client | Use distant 2×2×2 opaque-block LOD in the legacy L1 backend |
| `mc_native_lod_start` | `24` | Client | LOD start distance in the legacy L1 backend, chunks |
| `mc_native_occlusion_cull` | `1` | Client | Conservative section-portal occlusion culling in the legacy L1 backend |
| `mc_native_think_ms` | `3` | Client | Per-frame finalization budget in the legacy L1 backend, milliseconds |

Source: [cl_native_mesh_backend.lua](../addons/mc_engine/lua/mc/render/cl_native_mesh_backend.lua).

## Dynamic name extension boundaries

The dynamic tables above expand the repository's built-in items, states, and projectile types. Third-party additions to MCAnchorName, ThirdPerson.Profiles, or MCAngleConVarName can register further variables by the same rules. Names requiring third-party code are outside this version's built-in list.

First-person variables expand `<item>` into `mcitem_fp_*`, `mcitem_use_*`, `mcitem_charged_*`, and `mcitem_swing_*`; third-person variables use `mcitem_tp_<item>_<state>_<field>`; projectiles use `mcitem_<type>_model_<angle-axis>`. Each field, built-in name, and default is listed individually in its table.
