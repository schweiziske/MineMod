# Importing Minecraft worlds

English | [简体中文](../docs/zh/user/07-import-world.md)

The importer converts a selected area of a Java Edition world into MineMod blocks. It supports blocks, states, orientation, and the Overworld, Nether, and End. Players, mobs, and the full Minecraft game state are not transferred.

## Launching and converting

Install Python 3.11 or newer with Tcl/Tk. No third-party libraries are needed.

1. Double-click `start.cmd` in `tools/world importer/`.
2. Select the world root containing `level.dat`, then a dimension.
3. Enter an inclusive Chunk or block-coordinate selection. Inputs use Minecraft coordinates, with Y as height.
4. Set **GMod data directory** to the target **server's** `garrysmod/data/`; use your local directory for single-player.
5. Select an output type, enter a name, and click **Start import**.

The default output is the tool's own `output/` directory. **It does not install results into GMod automatically.** After conversion, inspect the **Activity and log** tab and open the output directory.

## GMod save output

Use this for ordinary world loading, with format left at `auto`. When output points to the correct server DATA directory, refresh `mc_save_manager` and load the result, or enter in the server console:

```text
mc_load_save <save-name>
```

Loading replaces the current MC world. When converting on another computer, copy the entire output, including the save file or directory and all associated parts. Do not copy only the manifest.

## mc_import JSON output

Files reside in `mc_import/` under the selected DATA directory. Keep all parts together. An administrator or the server console selects the import mode:

| Example | Purpose |
| --- | --- |
| `mc_import house replace` | Replace the current MC world; default mode |
| `mc_import house append` | Keep the existing world and add imported blocks; overlapping positions may change |

Here, `house` refers to `mc_import/house.json`. Explicitly use `append` to add buildings to an existing world. `replace` clears the old world.

After importing, save the result with `mc_save <new-save-name>`.

## Origin and block entities

By default, the selection moves to origin `0, 0, 0`. Output uses MineMod coordinates, with Z as height. Set a different origin in Advanced settings if needed. Convert a small area first to check placement.

**Skip block entity NBT** is enabled by default: chest inventories, sign text, and furnace progress are not imported, while blocks and orientation remain. Disabling it can conflict with MineMod's block entities. If `opaque_block_entity_conflicts_active` occurs, enable the option and export again.

## Conversion problems

| Message or symptom | Check |
| --- | --- |
| Missing region directory | Correct world and dimension, with generated chunks |
| Unsupported or missing DataVersion | Logs, world version, and readable chunk data |
| Unknown block or unsupported state | Exact IDs in conversion logs; unknown blocks are not a complete import |
| Tool will not start | Python, PATH, and Tcl/Tk |
| Result missing in game | Whether output is still in the tool's `output/`, and whether all parts were copied |

See the [importer instructions](../tools/world%20importer/README.md) for more launch and error details.
