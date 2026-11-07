# Getting started

English | [简体中文](../docs/zh/user/02-basic-gameplay.md)

## Inventory and building

With `mc_game` installed, select **MC** (class `mc_item_hand`) in the Sandbox Q menu under **Weapons → Minecraft**.

## Creative and survival modes

**Creative mode** is the default. The server can change the default; returning players keep their saved mode.

Switch through `mc_config → Client settings → Interface → Home → Minecraft game mode`, or enter in your console:

```text
mc_gamemode creative
mc_gamemode survival
```

By default, players may switch their own mode. `mc_allow_gamemode_switch 0` prevents ordinary players from switching. Administrators can change another player's mode with `mc_set_gamemode <creative|survival> <player-name-or-SteamID>`. The server console must specify a player.

Survival deaths drop inventory and equipment by default; `mc_keep_inventory 1` retains them. Inventories persist across reconnects by default, controlled by `mc_inventory_persist`.

## Airboats on water

Spawn **Half-Life 2 → Airboat** from the Sandbox Vehicles menu. The normal Source airboat floats and drives on Minecraft water with its usual enter/exit, throttle, reverse and steering controls. Deep water lets the hull float freely; shallow water can ground it on the lake bed. See [airboat water support](../docs/airboat-water.md) for scope and integration details.

## When building or mining fails

Check server editing permissions, reach, and world bounds. `mc_admin_only 1` restricts editing to administrators; `mc_world_limit` limits coordinates; `mc_max_blocks` limits the world's total block count.
