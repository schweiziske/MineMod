# MC ConVar reference

English | [简体中文](docs/zh/convar.md)

This file summarizes the addon’s registered `mc_*` ConVars. Defaults come from source `CreateConVar` / `CreateClientConVar` calls; defaults marked `approx.` are evaluated Lua constants.

## Start here

| Goal | Main ConVars | Explanation |
| --- | --- | --- |
| Enable GPU lighting | `mc_light_shader 1`, `mc_light_texture 1`, `mc_lightmap 1` | Use the custom chunk shader, GPU chunk light textures, and global 16x16 lightmap. |
| Change GPU lighting style | `mc_light_style fancy/plain/fast/vanilla` | fancy is the default with shadows and warm/cool grading; plain is smooth without grading; fast is the legacy low-sample appearance; vanilla uses original Minecraft lightmap composition. |
| Make nights darker and bluer | `mc_daycycle 1`, `mc_daycycle_moon_light`, `mc_daycycle_night_tint`, `mc_lightmap_ambient` | moon_light controls night skylight level, night_tint controls the blue tint, and ambient controls the GPU lightmap brightness floor. |
| Darken shadows | `mc_shadow 1`, `mc_shadow_strength`, `mc_shadow_face_shade`, `mc_lightmap_ambient` | Shadow darkness uses the shadow map and fancy shader. |
| Darken enclosed spaces | `mc_light_sky_flood 1`, `mc_lightmap_ambient`, `mc_lightmap_sky_min` | Voxel skylight flood fill: 15 outdoors, -1 per horizontal block, 0 fully enclosed. The shader gates direct sunlight by voxel skylight, so enclosed cells receive no direct sunlight without maximizing mc_shadow_strength. ambient sets the absolute light floor; sky_min sets the ambient-skylight floor fraction. |
| Distinguish the brightness floors | `mc_light_ambient_min`, `mc_lightmap_ambient` | The former controls the CPU/vertex-color path; the latter controls the GPU global lightmap. |

## Server: permissions, world, and bulk operations

Most of these settings are server-side, archived, notified, and replicated to clients.

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_admin_only` | `0` | Restrict block placement/breaking to administrators; also affects some preset permissions. |
| `mc_world_limit` | `1024` | Maximum absolute distance from the origin on each block-coordinate axis. |
| `mc_max_blocks` | `0` | Global block count limit; 0 unlimited. |
| `mc_reach` | approx. `182.5` | Maximum player distance for placing/breaking MC blocks; 0 disables the distance limit. |
| `mc_fill_max` | `100000` | Maximum cells modified by one /fill; 0 unlimited. |
| `mc_fill_batch_cells` | `4096` | Maximum cells applied per server /fill batch. |
| `mc_fill_batch_chunks` | `16` | Maximum chunks touched per server /fill batch. |
| `mc_fill_batch_interval` | `0.05` | Seconds between /fill batches to spread out hitches. |
| `mc_import_max` | `0` | Maximum blocks imported by one mc_import; 0 unlimited. |
| `mc_autosave` | `0` | Autosave interval in seconds; 0 disables it. |
| `mc_save_public` | `0` | Allow non-admins to list, load, and save MC worlds; deletion remains administrator-only. |
| `mc_preset_public` | `0` | Allow non-admins to list, load, save, and place building presets. |
| `mc_preset_max_blocks` | `100000` | Maximum non-air blocks saved/placed in one building preset; 0 unlimited. |

## Server: synchronization, storage, and large worlds

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_binary_chunk_patch` | `0` | Experimental chunk transport. Sends Binary Sections as palettes and packed 32-bit words instead of generating JSON or "localIndex:paletteId" terrain text; clients without support use the old protocol. |
| `mc_binary_net_profile` | `0` | Collect Binary Section server encoding, LZMA, CRC, packet splitting/queueing, net.Send CPU time, and send-queue wall time. Read with mc_binary_net_report. |
| `mc_sync_messages_per_tick` | `4` | Maximum queued state messages sent per player every 0.05 seconds. |
| `mc_sync_reliable_budget` | `3400` | Hard queued-state byte limit per player per 0.05 seconds; about 68 KB/s, or about 3 seconds for 204 KB without congestion. |
| `mc_sync_frame_ms` | `4` | Approximate server CPU milliseconds spent on full synchronization per tick. |
| `mc_sync_inflight_limit` | `32768` | Maximum queued state bytes awaiting processing acknowledgement from one client. |
| `mc_chunk_http_enabled` | `0` | Allow clients to fetch lazy-save base chunks over HTTP instead of GMod net. |
| `mc_chunk_http_base_url` | empty | HTTP root pointing to the lazy-save manifest/parts under the server's garrysmod/data. |
| `mc_stream_chunk_span_xy` | `0` | Legacy horizontal client chunk synchronization radius; ignored by direct full synchronization. |
| `mc_stream_chunk_span_z` | `0` | Legacy vertical client chunk synchronization radius; ignored by direct full synchronization. |
| `mc_large_world_lazy_load` | `0` | Legacy v8 lazy chunk loading switch; direct server loading is the default. |
| `mc_large_world_chunk_threshold` | `2048` | Imported-save chunk threshold for large-world/lazy-streaming handling. |
| `mc_chunk_store_part_cache` | `8` | Maximum v8 lazy-save part files cached in memory. |
| `mc_chunk_store_loads_per_tick` | `8` | Maximum lazy chunks hydrated per store tick. |
| `mc_chunk_store_frame_ms` | `3` | Approximate lazy-chunk hydration budget in milliseconds per tick. |

## Server and client collision

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_server_collision` | `0` | Build server-authoritative MC collision. Disabling immediately clears existing mc_chunk/mc_chunk_phys collision entities and pending rebuilds; client prediction collision is unaffected. Currently disabled by default to diagnose hitches. |
| `mc_server_collision_chunk_span` | `0` | Extra chunk radius kept active around the server collision AABB. |
| `mc_server_collision_aabb_padding` | approx. `36.5` | Player/entity AABB padding in Source units used to keep MC chunk collision active. |
| `mc_collision_aim_distance` | approx. `18688` | Trace distance for maintaining collision interest around the crosshair block; independent of building reach. |
| `mc_server_collision_aim_radius` | `1` | Block radius around each player's crosshair hit kept active for server collision. |
| `mc_client_collision_aim_radius` | `1` | Crosshair-block radius used by client prediction collision. |
| `mc_server_collision_hot_span` | `2` | Extra server collision chunk radius kept active by entity-velocity prediction. |
| `mc_server_collision_lookahead_time` | `0.5` | Seconds of entity-velocity lookahead for server collision interest. |
| `mc_server_collision_lookahead_max` | `4` | Maximum chunk radius added by velocity prediction. |
| `mc_client_collision` | `1` | Build block collision for client prediction; 0 uses server collision only. |
| `mc_client_collision_chunk_span` | `1` | Client prediction collision AABB chunk radius around the local player; 0 disables it. |
| `mc_client_collision_debug` | `0` | Print client prediction collision rebuild diagnostics. |
| `mc_client_collision_cross_chunk` | `0` | Allow client prediction collision interest to extend into adjacent chunks. |
| `mc_client_collision_default_version` | `0` | Internal marker for migration of client collision defaults. |

## Explosions, damage, and bulk rebuilds

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_explosion_mesh_sections_per_frame` | `4` | Client render sections rebuilt per interval after explosion block edits. |
| `mc_explosion_mesh_interval` | `0.12` | Seconds between client mesh rebuild batches after explosions. |
| `mc_bulk_collision_chunks_per_interval` | `1` | Server collision chunks rebuilt per interval after explosion/preset edits. |
| `mc_bulk_collision_interval` | `0.12` | Server bulk collision rebuild interval in seconds. |
| `mc_block_damage` | `1` | Allow GMod damage to break MC blocks. |
| `mc_block_health_scale` | `20` | Multiplier converting Minecraft hardness to block health. |
| `mc_block_damage_decay` | `5` | Seconds until partial block damage is forgotten. |
| `mc_block_explosion_scale` | `0.04` | Multiplier converting GMod explosion damage to a Minecraft-style explosion radius. |
| `mc_block_explosion_max_radius` | `8` | Maximum Minecraft-style block explosion radius. |
| `mc_block_explosion_max_blocks` | `4096` | Maximum MC blocks broken by one GMod explosion; 0 unlimited. |
| `mc_block_explosion_fx_limit` | `16` | Maximum block-break particle/sound events broadcast per explosion; 0 disables broadcasting. |

## Client basic lighting

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_light_enabled` | `1` | Apply Minecraft-style vertex lighting to MC chunk meshes. |
| `mc_light_ambient_min` | `0` | Minimum brightness of the CPU/vertex-color path; does not control the GPU global lightmap. |
| `mc_light_profile` | `shader` | Mesh lighting profile: fast, vanilla, and best use CPU/vertex colors; shader uses the GPU chunk shader (default). |
| `mc_light_style` | `fancy` | GPU pixel-lighting style: fancy, plain, fast, vanilla. Old archived shader/best/numeric values normalize to fancy. |
| `mc_light_perf_debug` | `0` | Display and collect detailed lighting performance diagnostics. |
| `mc_light_perf_print_break` | `0` | Print lighting performance diagnostics after breaking a block. |
| `mc_light_perf_print_each` | `0` | Print one timing diagnostic line per lighting calculation. |
| `mc_light_sky_flood` | `1` | Voxel skylight flood fill: 15 outdoors, attenuating by 1 per horizontal block indoors, 0 fully enclosed; 0 makes skylight uniformly full. |
| `mc_light_sky_flood_per_frame` | `4` | Chunks whose skylight flood fill is recalculated from the amortized queue per frame. |

## Client rendering and meshes

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_mesh_render` | `1` | Draw MC chunk IMesh objects; disabling hides meshes without affecting collision. |
| `mc_mesh_cull_mode` | `ccw` | MC chunk mesh culling direction: ccw or cw. |
| `mc_mesh_frustum_cull` | `1` | Skip drawing MC chunk meshes outside the view frustum. |
| `mc_mesh_draw_distance` | `0` | Maximum MC chunk mesh draw distance in Source units; 0 unlimited. |
| `mc_item_drop_draw_distance` | `96` | Maximum drop draw distance in Minecraft blocks; 0 disables distance culling. At most 2 stack copies beyond 16 blocks and 1 beyond 32; item counts and pickup are unaffected. |
| `mc_mesh_depth_prepass` | `0` | Extra CPU-material depth-only prepass before GPU shading; doubles geometry cost and should usually remain off. |
| `mc_mesh_emit_probe` | `0` | Print detailed mesh emission timings to diagnose full geometry rebuilds. |
| `mc_mesh_begin_upload` | `1` | Upload IMesh vertices with mesh.Begin instead of IMesh:BuildFromTriangles. |
| `mc_mesh_debug_full_cube_only` | `0` | Render only full-cube blocks when debugging mesh emission. |
| `mc_mesh_geometry_cache_sections` | `384` | Render sections retaining Lua vertex/lighting data; reducing this saves memory. |
| `mc_mesh_block_emit_cache_sections` | `1536` | Sections retaining per-block emitted vertex/lighting caches; reducing this saves memory but increases rebuild work. |
| `mc_mesh_connection_visible_template` | `1` | Cache visible geometry templates for connected shapes such as fences, panes, walls, and pipes. |

## GPU shaders, GPU light textures, and the global lightmap

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_light_shader` | `1` | Use the custom GPU chunk shader; requires compiled VCS files. |
| `mc_light_texture` | `1` | Sample lighting from chunk light textures in the GPU shader instead of baking it into vertex colors. |
| `mc_light_style` | `fancy` | GPU lighting style: fancy = PCF shadows and warm/cool grading; plain = smooth lighting without grading; fast = legacy low-sample appearance; vanilla = original Minecraft lightmap composition. |
| `mc_light_bloom` | `1` | Screen bloom for fancy GPU lighting; the shader creates torch/sun highlight seeds and this option performs their blur/spread. |
| `mc_light_bloom_strength` | `0.8` | Bloom strength; automatically increases slightly at night. |
| `mc_light_bloom_threshold` | `0.7` | Bloom luminance threshold; higher values retain only the brightest torch cores and sunlight highlights. |
| `mc_light_bloom_radius` | `6` | Screen-space bloom blur radius, clamped at runtime to 1..16. |
| `mc_light_brightness` | `1.5` | Block/sky brightness multiplier for GPU light textures; values above 1 clip high torch levels. Use gamma to brighten torches without clipping. |
| `mc_light_gamma` | `1` | GPU light texture attenuation curve; values above 1 brighten midtones, below 1 darken them. |
| `mc_light_sun_brightness` | `1` | Sun/sky brightness multiplier for the GPU path. |
| `mc_light_refresh_per_frame` | `2` | Chunk light textures refreshed per frame when the day/night sky level changes. |
| `mc_lightmap` | `1` | Enable the procedural 16x16 global lightmap for warm torchlight and colored day/night skylight. |
| `mc_lightmap_torch_warmth` | `0.7` | Warmth of block/torch light in the global lightmap. |
| `mc_lightmap_ambient` | `0.04` | Minimum visible brightness of the GPU global lightmap; 0 approaches complete darkness. |
| `mc_lightmap_sunset` | `0.5` | Orange gradient strength along the sunrise/sunset skylight axis; 0 disables it. |
| `mc_lightmap_night_gamma` | `0.6` | Perceptual curve for day/night skylight brightness; 1 linear, lower values make nights brighter/bluer and dusk transitions gentler. |
| `mc_lightmap_sky_curve` | `3` | Skylight ambient attenuation shape, 1-(1-level)^curve. Higher values brighten open but shaded areas under eaves/canopies, leaving only truly enclosed spaces at the ambient floor; 1 linear. |
| `mc_lightmap_sky_min` | `0.1` | Fraction of ambient skylight retained at sky level 0 (ambient floor indoors/under large buildings); direct sunlight is controlled separately by the shadow map. |
| `mc_lightmap_eye_dark` | `1` | Ambient multiplier when the camera cell has no skylight (eyeBrightness cave darkening); 1 disables it. Disabled by default because standing under large buildings also triggers it. |
| `mc_lightmap_vanilla_gamma` | `0.5` | Vanilla options.gamma brightness used by mc_light_style vanilla: 0 Moody, 0.5 vanilla default, 1 Bright. |
| `mc_lightmap_vanilla_flicker` | `1` | Vanilla per-tick torch flicker for mc_light_style vanilla; 0 gives stable block light. |

## Day/night cycle

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_daycycle` | `0` | Server MC day/night cycle; disabled by default, so lighting follows the map sun. |
| `mc_daycycle_paused` | `0` | Pause world time; unpausing resumes from the frozen time. |
| `mc_daycycle_length` | `1200` | Real seconds per full MC day; 1200 equals vanilla's 20 minutes. |
| `mc_daycycle_sun_tilt` | `0.2` | Lateral sun-path tilt used by the shadow map to avoid purely axial shadows. |
| `mc_daycycle_moon_shadow` | `0.3` | Night moon-shadow strength relative to sun shadows. |
| `mc_daycycle_moon_light` | `2` | Deep-night moonlight sky level, 0..15; lower values darken the night. |
| `mc_daycycle_night_tint` | `0.85` | Strength of the blue moonlight tint in night skylight; 0 neutral. |

## GPU shadow map

These settings primarily control darkness in shadows. Start with `mc_light_shader 1`, `mc_light_texture 1`, `mc_light_style fancy`, and `mc_shadow 1`, then adjust `mc_shadow_strength` and `mc_lightmap_ambient`.

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_shadow` | `1` | Make the GPU light-texture chunk shader receive the MC shadow map. |
| `mc_shadow_strength` | `0.75` | Shadow-map darkening strength on final brightness. |
| `mc_shadow_bias` | `0.0005` | Shadow-map depth/edge sampling bias to reduce acne and light leaks. |
| `mc_shadow_softness` | `0.5` | 16-tap Vogel PCF radius in shadow-map texels; no longer coupled to normal bias. |
| `mc_shadow_size` | `2048` | MC-owned shadow-map resolution, 512–4096. map mode uses a size × size RT; csm uses a vertical size × 3·size cascade atlas. At 4096 it uses about 240 MB VRAM; older GPUs may fail RT creation and disable shadows. |
| `mc_shadow_distance` | `4096` | Total shadow coverage radius. In distorted map mode, texel density decreases continuously from about 6.7× at the camera, keeping nearby shadows sharp. In csm mode, near/middle cascade radii are distance/ratio² and distance/ratio. |
| `mc_shadow_cascade_ratio` | `3` | csm only: cascade radius ratio, 1.5–8. |
| `mc_shadow_caster_distance` | `4608` | Maximum camera distance of MC chunks drawn into the shadow map. |
| `mc_shadow_update_interval` | `0` | Minimum shadow-map redraw interval in seconds. 0 imposes no rate limit, but the depth pass redraws only when sun direction, texel-aligned window, chunk geometry, or coverage radius changes; static scenes incur no redraw cost. |
| `mc_shadow_sun_step` | `1` | Day/night shadow-map sun-angle quantization step, degrees. Continuous sun motion rotates the light-space texel grid each frame, causing more edge crawling/jitter at larger mc_shadow_distance. Quantization keeps the grid stationary between steps and skips matching depth-pass signatures. 0 continuous; shadow-strength transitions remain continuous. |
| `mc_shadow_tint` | `0.6` | Cool skylight tint strength in fancy shader shadows. |
| `mc_shadow_edge_fade` | `0.1` | Fade width at the edge of fancy shader shadow coverage. |
| `mc_shadow_face_shade` | `0.65` | Shadow darkening strength on faces pointing away from the sun in the fancy shader. |
| `mc_shadow_warmth` | `0.35` | Warmth of sunlit faces and torch-lit areas in the fancy shader. |

## Heightfield shadow mode

An alternative sun-shadow technique: select `mc_shadow_mode height`, or switch back with `map`; requires `mc_shadow 1`.
It maintains a top-down heightmap, redrawing only when blocks change or the player moves far enough. The chunk shader raymarches it along the sun direction,
producing distance-dependent soft shadows that are sharp nearby and soft farther away. Sun/camera motion adds no redraw cost, making this much cheaper than map mode during the day/night cycle.
Strength and grading reuse `mc_shadow_strength` and fancy tint/face_shade/warmth/edge_fade.
Shadow-map-only settings such as `bias/softness/size/distance/caster_distance/update_interval` have no effect in this mode.

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_shadow_mode` | `map` | Sun shadow technique: map = Photon-style distorted single shadow map with radial clip-space stretching, about 6.7× nearby texel density decreasing continuously with distance, and no cascade seams; csm = 3-cascade vertical atlas with texel snapping, stationary between sun steps but quality transitions at cascade boundaries as the camera moves; height = cached top-down heightfield raymarching. |
| `mc_shadow_hf_size` | `1024` | Heightmap resolution. |
| `mc_shadow_hf_range` | `4096` | Heightmap world coverage radius, centered on the player. |
| `mc_shadow_hf_max_dist` | `2400` | Maximum world-space shadow casting distance (raymarch range). |
| `mc_shadow_hf_softness` | `0.05` | Penumbra tangent: rate at which shadows soften with occluder distance; 0.02 sharp, 0.12 very soft. |
| `mc_shadow_hf_update_interval` | `0.1` | Minimum heightmap redraw interval in seconds after geometry changes/window relocation. |

## Source engine lighting bridge

This optional bridge mixes Source static lighting into MC mesh vertex colors; it is separate from the GPU global lightmap.

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_mesh_source_lighting` | `0` | Mix Source static lighting into MC mesh vertex colors: 0 off, 1 ambient, 2 normal, 3 max. |
| `mc_mesh_source_lighting_strength` | `0.55` | Strength of Source lighting modulation on MC vertex colors. |
| `mc_mesh_source_lighting_min` | `0.35` | Minimum multiplier during Source lighting modulation. |
| `mc_mesh_source_lighting_scale` | `1.0` | Multiplier on Source lighting samples before mixing. |

## Debugging

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_server_collision_debug` | `0` | Draw server-authoritative MC collision interest bounds. |
| `mc_client_collision_area_debug` | `0` | Draw the client prediction collision interest area. |
| `mc_client_collision_aabb_debug` | `0` | Draw client prediction collision AABB boxes. |
| `mc_client_collision_aabb_debug_limit` | `2048` | Maximum client prediction collision AABB boxes drawn. |

## Creative-mode held-block display

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_creative_held_model` | `1` | Draw the creative-mode held-block model. |
| `mc_creative_held_anim` | `1` | Play the creative-mode held-block swing animation. |
| `mc_creative_held_fp_forward` | `11.5` | First-person held-block forward/back offset. |
| `mc_creative_held_fp_right` | `12` | First-person held-block lateral offset. |
| `mc_creative_held_fp_up` | `-8.3` | First-person held-block vertical offset. |
| `mc_creative_held_fp_scale` | `6.4` | First-person held-block scale. |
| `mc_creative_held_fp_yaw` | `45` | First-person held-block yaw. |
| `mc_creative_held_fp_pitch` | `0` | First-person held-block pitch. |
| `mc_creative_held_fp_roll` | `0` | First-person held-block roll. |
| `mc_creative_held_tp_forward` | `2.5` | Third-person held-block forward/back offset. |
| `mc_creative_held_tp_right` | `2.2` | Third-person held-block lateral offset. |
| `mc_creative_held_tp_up` | `-1.8` | Third-person held-block vertical offset. |
| `mc_creative_held_tp_scale` | `6` | Third-person held-block scale. |
| `mc_creative_held_tp_yaw` | `45` | Third-person held-block yaw. |
| `mc_creative_held_tp_pitch` | `75` | Third-person held-block pitch. |
| `mc_creative_held_tp_roll` | `0` | Third-person held-block roll. |

## UI

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_language` | `auto` | Follow gmod_language by default, falling back to English if unrecognized/unsupported; manually select zh_cn Chinese or en_us English. |
| `mc_inventory_hud_scale` | `0` | Integer scale for hotbar, health, hunger, experience, and status-effect HUD. 0 selects automatically using vanilla's 320×240 minimum logical size; manual range 1..32. |
| `mc_inventory_hud_offset_x` | `0` | Horizontal offset of the entire survival HUD in physical screen pixels; positive moves right. |
| `mc_inventory_hud_offset_y` | `0` | Vertical offset of the entire survival HUD in physical screen pixels; positive moves down. |
| `mc_inventory_ui_scale` | `0` | Integer scale for inventory, containers, recipe book, anvil, and enchanting table. 0 selects automatically using vanilla's 320×240 minimum logical size; manual range 1..32. |
| `mc_inventory_ui_offset_x` | `0` | Horizontal inventory/container UI offset in physical screen pixels; positive moves right. |
| `mc_inventory_ui_offset_y` | `0` | Vertical inventory/container UI offset in physical screen pixels; positive moves down. |

At 1920×1080, for example, try `mc_inventory_hud_scale 3` if the HUD is too large, then adjust the two offsets if needed. Enter 0 to restore automatic scaling or the default position.

## Fast low-sample GPU lighting (legacy appearance)

`mc_light_style fast` restores the original low-sample GPU lighting shader: 4 lighting samples plus 1 atlas sample per pixel,
analytical warm/cool grading and face shading, with **no shadow samples or lightmap lookup**. It takes priority over fancy/height material selection.
Day/night brightness, night tint, and warmth are passed through once-per-frame constants, reusing daycycle/lightmap ConVars with no per-chunk cost.

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_light_style` | `fancy` | Set to fast for the legacy low-sample GPU lighting shader, skipping shadow-map/heightfield consumption. |
| `mc_light_flush_per_frame` | `8` | Maximum chunk light textures rebaked per frame in PreRender; the draw path no longer rebakes them. 0 unlimited. |

## Original Minecraft lighting (vanilla appearance)

`mc_light_style vanilla` reproduces Minecraft 26.2 lighting, with formulas ported line by line from
`lightmap.fsh`, `LightmapRenderStateExtractor`, and `Timelines` in the decompiled `out/` sources:
final color = atlas color × lightmap(block light, skylight) × face shading (top 1.0 / bottom 0.5 / X faces 0.6 / Y faces 0.8) × AO.
**No shadow maps or warm/cool grading.** Day/night brightness, warm torchlight (0xFFD88C), and blue night skylight (0.48, 0.48, 1 × 0.24)
are baked into a 16x16 lightmap using the vanilla day/night timeline, redrawn each MC tick with a torch-flicker random walk.
Enabling it automatically skips per-frame shadow-map/heightfield rendering. Restore the default style with `mc_light_style fancy`.
Requires `mc_lightmap 1`, enabled by default.

| ConVar | Default | Description |
| --- | --- | --- |
| `mc_light_style` | `fancy` | Set to vanilla for original Minecraft lighting composition: one lightmap lookup, no shadows. |
| `mc_lightmap_vanilla_gamma` | `0.5` | Vanilla options.gamma brightness: 0 Moody, 0.5 vanilla default, 1 Bright. |
| `mc_lightmap_vanilla_flicker` | `1` | Vanilla per-tick torch flicker with a random walk and ×0.9 decay; 0 gives stable block light. |
