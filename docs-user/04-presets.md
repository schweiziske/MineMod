# Building presets

English | [简体中文](../docs/zh/user/04-presets.md)

Presets save a selection as a reusable building. Loading displays a projection; the world changes only when you place it with the left mouse button. Use [world saves](03-saves.md) for complete world backups.

Equip the **MC Preset Placer** (`mc_preset_placer`) and press R to open the manager, or enter `mc_preset_manager`.

## Saving a building

1. Enter a name in the manager and click **New preset**.
2. With the preset placer, left-click two opposite corner blocks.
3. Left-click a reference face inside the selection to align later placement.
4. Left-click once more to take a screenshot and save.

Right-click during selection to go back one step. The default limit is 100000 non-air blocks, controlled by server setting `mc_preset_max_blocks`.

## Placing a building

Select a preset, click **Load projection**, and return to the world to adjust its position:

| Key | Action |
| --- | --- |
| G | Rotate by 90° |
| E | Toggle overwrite mode |
| Left mouse | Place |
| Right mouse | Cancel the projection |
| R | Open the manager |

With overwrite disabled, destination cells for preset blocks must be empty; air in the preset does not remove existing buildings. With overwrite enabled, the entire target volume is replaced, including clearing cells where the preset contains air.

**Right-click does not undo a building already placed.**

## Permissions

By default, only administrators may list, save, load, and place presets. `mc_preset_public 1` grants these actions to ordinary players. Placement still follows server editing permissions, world bounds, and block limits.

The reference face and rotation determine projection alignment. Adjust your aim or press G to reposition it. To change the reference face, create the preset again.
