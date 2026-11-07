# World Importer

English | [简体中文](../../docs/zh/tools/world%20importer/README.md)

Import Java Edition Minecraft worlds into Garry's Mod.

The importer supports blocks, block states, orientation, and height.
You do not need to convert coordinates or enter a DataVersion manually.

## Requirements

Python 3.11 or newer is required.

When installing Python on Windows, keep the **Tcl/Tk** option enabled.
No other libraries are required, and you do not need to run `pip install`.

## Launch

On Windows, double-click:

```text
start.cmd
```

You can also open PowerShell in this folder and run:

```powershell
.\start.ps1
```

The World Importer window will open. Use the control in the upper-right
corner to switch between Simplified Chinese and English.

## Import Steps

1. Click **Browse** and select the Minecraft world directory.

   Select the world root directory containing `level.dat`, not the
   `region` folder inside it.

2. Select a dimension: Overworld, Nether, or End.

3. Set the import range.

   - **Chunk** is suitable for selecting Minecraft chunks.
   - **Block coordinates** lets you enter an exact X/Y/Z range.
   - Both ends of the selected range are included.

4. Select the GMod `data` directory.

   On a Windows dedicated server, this is usually:

   ```text
   garrysmod/data
   ```

5. Select an output type.

   - **GMod save** creates a world that can be loaded from the save manager.
   - **mc_import JSON** creates an import file for the `mc_import` command.

6. Click **Start import**.

The UI automatically switches to the **Activity and log** tab while the
import is running. When it finishes, click **Open output directory** to
view the generated files.

## After Importing

For a GMod save, run this command in the server console:

```text
mc_load_save <save-name>
```

You can also open the in-game save manager:

```text
mc_save_manager
```

For an mc_import JSON file, run this command in the server console:

```text
mc_import <file-name>
```

## Default Behavior

### Automatic DataVersion Compatibility

The importer detects the Minecraft world's DataVersion and selects the
correct storage format automatically. Every block state is still validated,
so this does not skip version compatibility checks unconditionally.

### Skip Block Entity NBT

By default, block entity data such as chest inventories, sign text, and
furnace progress is not imported.

This allows GMod to create chests, signs, and other active block entities
normally and prevents this error when loading a save:

`opaque_block_entity_conflicts_active`

Blocks, orientation, and block states are still preserved.

If you need to preserve source block entity data, clear **Skip block entity
NBT** in Advanced settings. This may conflict with GMod's default block
entities.

## Troubleshooting

### The selected world is missing a region directory

Make sure you selected the world root containing `level.dat`, and that
chunks have been generated in the selected dimension.

Original console output (the directory varies by world):

```text
FileNotFoundError: could not find a region directory; tried: D:\Minecraft\saves\World\region
```

### The DataVersion is not supported

The tool cannot safely read worlds created by this Minecraft version.
Open and resave the world with a supported Minecraft version, then try again.

Original console output (coordinates and version numbers vary by world):

```text
[MC import] unsupported_chunk_storage_data_version: chunk 0,0 DataVersion 5000 has no audited chunk-storage adapter
```

If automatic version compatibility is disabled, you may also see:

```text
[MC import] data_version_mismatch: chunk 0,0 has DataVersion 3465, expected 4897; --auto-data-version accepts audited storage versions
```

### A chunk is missing DataVersion

This usually means the chunk data is incomplete or uses an unrecognized
storage format. Open and resave the world in Minecraft, then try again.

Original console output (coordinates vary by world):

```text
[MC import] missing_data_version: chunk 0,0 is missing DataVersion
```

### `opaque_block_entity_conflicts_active`

The world contains NBT that conflicts with GMod's default active block
entities. Keep **Skip block entity NBT** selected, export the save again,
and then load it.

Original console output:

```text
[MC] load save failed: opaque_block_entity_conflicts_active
```

### The window closes immediately after double-clicking `start.cmd`

This means the system could not find the `python` command. Install Python
3.11 or newer, enable **Add Python to PATH** and Tcl/Tk in the installer,
and then try again.

Original console output:

```text
Python 3 was not found. Install Python 3.11 or newer.
```

### Importing is slow

The importer must read and convert every chunk in the selected range.
Reduce the range or import the world in smaller Chunk-coordinate sections.
