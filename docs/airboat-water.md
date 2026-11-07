# Source airboats on Minecraft water

English | [简体中文](zh/airboat-water.md)

The engine addon automatically supports `prop_vehicle_airboat` on Minecraft water. Spawn the normal Half-Life 2 Airboat from the Vehicles menu and use its normal enter, exit, throttle, reverse and steering controls. No separate vehicle class, item or console command is required.

The server samples four support points derived from the physics hull. Water displacement and vertical damping supply buoyancy and pitch/roll support; the native Source vehicle retains propulsion, steering, seats and solid-world collisions. Sampling uses MC world coordinates converted from the entity's engine coordinate frame and the current block size. Full water columns give full displacement, so a submerged boat can rise through multiple cells instead of settling at an internal cell boundary. Water-containing plants and waterlogged states use the same fluid decoding as ordinary water.

Support is recomputed each server tick, including after water is placed or removed. Frozen physics objects receive no forces. Lava and dry air provide no support. When Source reports native BSP water contact, the adapter yields to the engine to avoid applying both buoyancy systems. The adapter does not change `Entity:WaterLevel()` or fabricate BSP contents; unrelated addons that inspect those values still see Source water only.

The implementation is [sv_airboat_water.lua](../addons/mc_engine/lua/mc/integration/sv_airboat_water.lua), loaded on the server by the engine addon. It tracks existing and newly spawned airboats and releases entries when entities are removed. This support applies to the native airboat class, not arbitrary prop boats, Jeeps or third-party vehicle frameworks. Decorative `prop_dynamic` airboat models are not drivable and do not receive this adapter.
