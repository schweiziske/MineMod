# World saves

English | [简体中文](../docs/zh/user/03-saves.md)

A save contains the entire MC block world and its block data, plus supported mobs when **Save mobs** is selected. **Loading replaces the current MC world for all players.** It does not change the GMod map or save the entire GMod scene.

## Saving and loading

Enter `mc_save_manager`, or open it from **Interface → Home** in settings.

| Action | Steps |
| --- | --- |
| Create | Enter a new save name and click **Save current** |
| Load | Select a save, click **Load**, and confirm |
| Overwrite | Select a save and click **Overwrite and screenshot** |
| Delete | Select a save, click **Delete**, and confirm; administrators only |

The manager captures a cover image when saving. Saving under an existing name overwrites it. A red map name means the save was created on another GMod map; loading does not change maps for you.

**Save mobs**, beside **Delete**, is checked by default and applies to both creating and overwriting saves. With BlockMob Base installed, it records living BMB mobs, including position, health, age, breeding and pet data, weapons and handedness, and active effects. Villagers keep their profession, variant, level, exact trades and item components, trade usage, reputation and workstation. Effect durations and cooldowns resume from the saved remaining time; instant healing or damage is not repeated.

Loading a save with mob data replaces the current BMB mob population, including clearing it when the saved population is empty. Unchecking the option replaces any previously saved mob snapshot with a block-only save; loading that save, or an older save without mob data, leaves existing mobs in place. Other addons' mobs require their own save provider. Missing providers are reported and skipped, while invalid data for an installed provider stops the load before replacement. Behavior threads, paths, animations, open trading menus, loose item drops and experience orbs are not included.

Console and API saves include supported mobs by default. An API caller can pass `{ saveEntities = false }` to save blocks only. Autosave and shutdown saving retain their existing block-dirty trigger; mob movement alone does not trigger a save.

By default, only administrators may list, save, or load worlds. `mc_save_public 1` grants these actions to ordinary players; deletion remains restricted to administrators.

## Default and named saves

| Command | Purpose |
| --- | --- |
| `mc_save house` | Save as `house`, overwriting that name |
| `mc_save_list` | List named saves |
| `mc_load_save house` | Load the named save `house` |
| `mc_delete_save house` | Delete the named save `house` |
| `mc_save` | Save to the current GMod map's default slot |

The map's default save loads automatically on entry. Named saves load manually. Even after loading `house`, `mc_save` without a name still writes the default slot.

**Periodic autosaving is disabled by default.** Server setting `mc_autosave 300` writes a changed world to the default slot every 300 seconds; `mc_autosave 0` disables it. Autosaving does not overwrite the last named save you loaded.

## Workshop

- **Load Workshop** accepts a Workshop ID or Steam Workshop URL.
- **Publish to Workshop** obtains the selected save, captures a screenshot, and opens GMod's publishing window. Follow its prompts to associate a Workshop ID.
- **Workshop mount (read-only)** entries cannot be overwritten or deleted. To edit one, load it and save a local named copy.

Workshop importing and publishing also follow `mc_workshop_manage`: `0` superadmins, `1` admins, `2` everyone; default `0`.

## Files and backups

These paths are under the **server's** `garrysmod/data/`; in single-player, that is your computer:

| Path | Contents |
| --- | --- |
| `mc/saves/<name>/` | Current named-save format: manifest, metadata, and parts |
| `mc/saves/<name>.dat` | Compatible legacy format or importer output |
| `mc/<map-name>.dat` | Map default save |
| `mc/save_covers/` | Save covers |
| `mc/workshop_saves/` | Local copies of imported Workshop saves |

Back up the complete save directory and associated parts, metadata, and covers. Copying only the manifest is insufficient.
