# File-based localization

English | [简体中文](zh/localization.md)

MineMod UI text, messages, and names come from JSON catalogs shipped by each addon. This document defines resource formats, loading, language selection, and `MC.API.I18n`.

## 1. Resource files

### 1.1 Location

Each addon stores translations under a shared virtual root:

```text
addons/<addon>/data_static/mc/i18n/<namespace-directories...>/<fragment-name>.json
```

Installed addons merge their `data_static/` directories into the `GAME` search path. The loader recursively discovers `GAME:data_static/mc/i18n/`. `DATA` paths do not include `data_static/`. `data_static/*.json` is allowed in Workshop GMAs.

`addons/<addon>/` is not a namespace and confers no priority. The loader treats official, built-in, and third-party addons equally.

Personal overrides belong in writable `garrysmod/data/mc/i18n/overrides/` (`DATA:mc/i18n/overrides/`), using the same format and namespace rules. Clients and servers read their own directories; overrides are neither uploaded nor distributed.

### 1.2 Format

```json
{
  "locale": "zh_cn",
  "nativeName": "简体中文",
  "aliases": ["zh", "schinese"],
  "entries": {
    "title": "设置",
    "render.distance.label": "绘制距离"
  }
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `locale` | Yes | Language of these entries. Lowercased with `-` replaced by `_`; nonempty `[a-z0-9]` segments joined by single underscores; at most 32 bytes. No fixed language allowlist. |
| `nativeName` | No | Language self-name, such as `简体中文` or `English (United States)`. Nonblank, at most 128 UTF-8 bytes, with no control characters. Displayed literally; not used for key or locale matching. |
| `aliases` | No | Up to 16 normalized strings used only for `auto` game-language matching, not translation entries. |
| `entries` | Yes | Flat object mapping local keys to translation strings. No object, array, or numeric values. |

No other top-level fields are allowed. Files are UTF-8 with an optional BOM. Filenames locate fragments; use `<addon>.<locale>.json` to avoid addons masking one another.

Declare a locale's `nativeName` once and omit it in other fragments. It may share the alias fragment or come from a third-party language pack; no separate language-name table is needed. A metadata-only file with empty `entries` does not make an otherwise empty locale selectable.

### 1.3 Final keys

```text
final key = parent directories below the root ("/" replaced by ".") + "." + local key
```

At the root, the final key is the local key. Filename and locale do not participate. These all produce `space1.space2.xxx`:

| Parent directory | Local key |
| --- | --- |
| Root | `space1.space2.xxx` |
| `space1/` | `space2.xxx` |
| `space1/space2/` | `xxx` |

Keys consist of `[A-Za-z0-9_-]` segments joined by dots, without empty segments or leading/trailing dots. Final keys are at most 200 bytes. Directory names use `[a-z0-9_-]`; filenames use lowercase `[a-z0-9_.-]` and end in `.json`.

### 1.4 Resource limits

Exceeding any limit rejects and reports the entire file without truncation:

| Resource | Limit |
| --- | --- |
| Fragments per root | 4096 |
| Namespace directory depth | 8 |
| Virtual path | 240 bytes |
| File size | 1 MiB |
| Entries per file | 10000; GMod's `util.JSONToTable` limits each document to 15000 keys |
| Total entries | 524288 |
| Translation string | 8192 bytes |
| Language self-name | 128 bytes |

### 1.5 Installation and updates

A complete gameplay installation needs `mc_engine`, `mc_game`, and `mc_item`. The engine supplies loading and messaging; `mc_game` supplies vanilla item, container, and creative-tab catalogs; `mc_item` supplies effects, enchantments, weapon descriptions, and spawn-menu catalogs. Full MCITEM menus therefore also require `mc_game` item names. Resource and shader packs ship their own catalogs.

Install required content on the server and every client. `AddCSLuaFile` does not distribute JSON catalogs, and the server does not send them. Server-only installation can leave clients displaying English fallbacks or keys. Install the relevant client content and run `mc_i18n_reload`; server personal overrides do not replace client installation.

When upgrading the message protocol, update all three core addons on both sides and reconnect. Do not mount an older GMA and newer loose files for the same addon together; overlapping paths mask resources, and catalog reload cannot resolve mixed file versions.

Each core addon has `addon.json`. Package them separately with the game's `gmad`:

```text
gmad create -folder addons/mc_engine -out <output-directory>/mc_engine.gma
gmad create -folder addons/mc_game -out <output-directory>/mc_game.gma
gmad create -folder addons/mc_item -out <output-directory>/mc_item.gma
```

Include `data_static/mc/i18n/` and the engine font license `data_static/mc/licenses/unifont.txt`. Packaging ignore rules exclude documentation, development scripts, vanilla texture `.mcmeta` files, and unused platform model copies, not game-used models, textures, or catalogs.

## 2. Discovery and merging

1. Enumerate all `GAME` fragments and load them in bytewise full-virtual-path order. Then load `DATA` overrides the same way. Enumeration, `pairs`, and autorun order do not affect the result.
2. For duplicate final keys in one locale, the later file wins. A load-time warning includes locale, key, previous source, and new source, even when values match. Duplicates do not reject files.
3. Aliases follow load order. An alias reassigned to another locale uses the later value and warns.
4. Unreadable files, invalid JSON/fields/keys, and limit violations reject the entire file, add an `errors` record, and report `i18n_resource_invalid` through `mc_faults`. Other files still load.
5. Atomically replace catalogs, source records, and locale lists after loading, then notify language changes with reason `reload`. Queries keep reading the old catalog until replacement.

`nativeName` follows the same order. Omission preserves the previous name; identical names do not warn. Different names use the later value and record `nativeNameConflicts` with both names and sources. `nativeNames` reports the final `{ nativeName, source }` for each locale. Removing an override and reloading restores the shipped name.

When two addons provide exactly the same virtual path, `GAME` exposes only the first-mounted copy. Use unique fragment filenames. Sources are written as `GAME:data_static/mc/i18n/...` or `DATA:mc/i18n/overrides/...`.

## 3. Language selection

### 3.1 Available languages

A locale with at least one loaded entry is available. Locales are sorted lexicographically. Adding and reloading a locale file makes it selectable without code changes.

Selectors show `nativeName`, falling back to the locale ID, and always save the locale ID. Switching UI language does not translate language self-names. `auto` is a selection mode, not a catalog; its labels use `config.language.auto` (automatic/follow game) on clients and `config.language.auto_server` (automatic/English) on servers.

### 3.2 Client: mc_language

Client ConVar `mc_language` is archived/userinfo and defaults to `auto`:

- `auto` normalizes `gmod_language`, matches loaded locales, then aliases pointing to loaded locales, then falls back to `en_us`.
- An explicit locale is retained even without its resource files. Queries temporarily fall back to `en_us` and recover after resources are installed and reloaded.
- Writes normalize values (`ZH-CN` becomes `zh_cn`). Unrecognized values act as `auto` and print a console notice.

ConVar callbacks detect `gmod_language` changes. A lightweight once-per-second check covers changes the engine does not notify to Lua.

### 3.3 Server: mc_console_language

Archived server ConVar `mc_console_language` defaults to `en_us` and selects server-console and administrator-facing text. Servers have no game language, so `auto` means `en_us`. This does not change any player's language, and players do not change it.

### 3.4 Language-change notifications

Explicit setting changes (`setting`), game-language changes in auto mode (`game_language`), and reloads (`reload`):

1. Refresh GMod phrases registered with `BindPhrase`.
2. Invoke `RegisterLanguageChanged` callbacks in name order as `callback( locale, reason )`. A failing callback reports `i18n_language_callback` without stopping others.
3. Run `MC.LanguageChanged( locale, reason )`.

Refresh open interfaces and language-dependent caches in these callbacks.

## 4. Queries

### 4.1 Fallback order

```text
final key in specified/current locale -> same key in en_us -> key itself
```

Callers do not supply inline Chinese or English fallbacks. Missing keys are recorded once per locale/key, up to 4096 records: `base` means `en_us` was used; `key` means the key was displayed. `mc_i18n_debug 1` prints each missing key once; otherwise inspect `mc_i18n_missing` and reports.

Queries read in-memory catalogs without file enumeration, JSON parsing, or temporary catalog construction.

### 4.2 Parameters and message specifications

Translations use named `{name}` parameters. String and numeric values substitute literally; absent parameters remain unchanged. Use full sentence templates rather than concatenating language-specific fragments. Positional `{1}`, `{2}`, etc. read the array portion of vars for converted Minecraft templates (section 9).

A parameter can itself be `{ key = "...", vars = { ... } }`, translated in the same locale before substitution. Nesting is limited to four levels; deeper content becomes `?` and reports `i18n_spec_too_deep`. String parameters are always literal, so player-entered names are safe to pass directly.

### 4.3 Count variants

`TranslateCount( key, count )` uses `<key>.one` when `count == 1`, otherwise `<key>.other`, and supplies `{count}`. A locale providing either variant controls resolution; languages without singular forms need only `.other`. No ICU or scripting expressions are used.

## 5. MC.API.I18n

Defined in `addons/mc_engine/lua/mc/api/sh_api.lua`. Invalid inputs return `nil, err` (`false, err` for boolean operations). Internal tables are not exposed.

| Function | Realm | Description |
| --- | --- | --- |
| `Translate( key, vars, locale )` | Shared | Query using section 4; vars may nest message specifications. Errors: `invalid_key`, `invalid_vars`, `invalid_locale`. |
| `TranslateCount( key, count, vars, locale )` | Shared | Count variants; also returns `invalid_count`. |
| `TranslateForPlayer( ply, key, vars )` | Shared | Translate in the player's locale using server-local catalogs, excluding client personal overrides; sends no message. |
| `TranslateConsole( key, vars )` | Shared | Translate for this realm's console: server mc_console_language, or client UI language. |
| `Notify( ply, key, vars, channel )` | Server | Send keys/parameters for client translation. Return `true` or `false, err`. Channel: `chat` (default), `console`, `both`. Client calls return `false, "server_only"`. |
| `Has( key, locale )` | Shared | Whether the specified/current locale directly contains a key, excluding fallback. |
| `Language()` | Shared | Current effective locale in this realm. |
| `LanguageSetting()` | Shared | Normalized mc_language or mc_console_language setting, possibly `auto`. |
| `LanguageForPlayer( ply )` | Shared | Server: locale resolved from player userinfo. Client: local language. |
| `ConsoleLanguage()` | Shared | This realm's console language. |
| `Locales()` | Shared | Copy of loaded locale list. |
| `LanguageOptions()` | Shared | `{ { value = "auto", label = <localized-auto-label> }, { value = locale, label = <nativeName-or-locale> }, ... }`. |
| `SetLanguage( setting )` | Client | Set mc_language and return the normalized value; server returns `nil, "client_only"`. |
| `RegisterLanguageChanged( name, callback )` | Shared | Register `callback( locale, reason )`, replacing the same name. |
| `UnregisterLanguageChanged( name )` | Shared | Unregister the callback. |
| `Reload()` | Shared | Rescan files visible to this realm and return a report. |
| `Report()` | Shared | Copy of the latest report: `files`, `errors`, `conflicts`, `aliasConflicts`, `nativeNames`, `nativeNameConflicts`, `locales`, `entries`, `generation`, `realm`, `language`, `missing`. |
| `MissingKeys( locale )` | Shared | Missing keys since reload: `{ [locale] = { [key] = "base" \| "key" } }`; specifying a locale restricts the result. |
| `BindPhrase( phrase, key, vars )` | Client | Bind GMod `#phrase` (such as weapon PrintName) to MC language changes and reloads. |

Translations require no registration call or manifest; add JSON files. Callers cannot write into loader catalogs. Internal engine code uses `MC.T( key, vars, locale )` and `MC.I18n.Resolve( keyOrSpec, vars, locale )` with the same fallback rules.

### 5.1 Player messages

Use `Notify` rather than translating with `TranslateForPlayer` and sending a string:

```lua
MC.API.I18n.Notify( ply, "server.gamemode.changed", {
	name = target:Nick(),
	mode = { key = "server.gamemode.creative" },
}, "both" )
```

`name` remains literal. The recipient resolves both the nested `mode` and outer message with their own locale and overrides. A player's `console` channel means their client console, not the server console.

Internal shared module `mc/sh_messages.lua` provides:

| Function | Purpose |
| --- | --- |
| `MC.Messages.Spec( key, vars )` | Construct an untranslated specification without sending it. |
| `MC.Messages.Encode( spec )`, `Decode( payload )` | Validate/copy specifications at transport boundaries; return a result or `nil, err`. A nil specification encodes as an empty string, and an empty string decodes to nil: no message. |
| `MC.Messages.Read()` | Read/decode one network string. Report failure through MC.Fault and return `nil, err`. |
| `MC.Messages.Notify( ply, keyOrSpec, vars, channel )` | Internal sender accepting a key or complete specification. |
| `MC.Messages.Console( keyOrSpec, vars )` | Print in this realm's console language without a network message. |
| `MC.Messages.Reply( ply, keyOrSpec, vars, channel )` | Server-command reply: valid players use Notify; server-console callers use Console. |

Only the server sends `mc_message`, containing a two-bit channel ID and one JSON network string. No catalogs are transmitted, and there is no client-to-server message receiver. Existing save/preset responses use the same specification format without a second notification. Update response protocols on both sides together; old pretranslated-string fields are incompatible.

Message JSON is limited to 8192 bytes, 32 parameters per specification, 128 in the complete tree, and four nesting levels. Parameters accept strings, finite numbers, or nested specifications; individual strings are at most 2048 bytes. Parameter names are alphanumeric/underscore strings of at most 64 bytes. Integer indices 1–128 become strings for transmission to preserve placeholders such as `{1}`. Keys use catalog validation. Invalid fields/types or oversized messages are rejected, never truncated or sent.

Save/preset windows retain message specifications. Language changes and reloads rebuild from cached lists while preserving filters, searches, selection, entered names, and messages, without requesting lists again. Failed preset loads appear in chat and the open window's status bar; hover for full text. Technical error codes remain literal parameters.

## 6. Content key templates

Content definitions retain stable IDs. Display keys derive from IDs below; specify an explicit key only when reusing text elsewhere. The defining addon supplies translations under its own `data_static/mc/i18n/`.

| Content | Derived key | Explicit field |
| --- | --- | --- |
| Creative tab | `itemGroup.<namespace>.<path>`, replacing `/` with `.`; the 14 vanilla tabs retain Minecraft `itemGroup.*` keys | `titleKey` |
| Block | `block.<namespace>.<path>` | `translationKey`, `translationVars` |
| Item | `item.<namespace>.<path>`; BlockItems inherit their block's key/parameters when omitted | `translationKey`, `translationVars` |
| Effect, enchantment | `effect.<namespace>.<path>`, `enchantment.<namespace>.<path>`; levels use `enchantment.level.<n>` (1–10) | None |
| Potion | Minecraft `item.minecraft.<potion\|splash_potion\|lingering_potion>.effect.<name>` | None |
| Config group | `config.group.<id>` | `labelKey` |
| Config category | `config.category.<id>.label`, `config.category.<id>.description` | `labelKey`, `descriptionKey` |
| Config setting | `config.setting.<ConVar-name>.label`, `config.setting.<ConVar-name>.help` | `labelKey`, `helpKey` |
| Config choice | `config.setting.<ConVar-name>.choice.<value>` | `labelKey` |
| Config unit | `config.unit.<unit>` | None |
| Shader pack or standalone shader | `shaderpack.<id-with-colons-replaced-by-underscores>.` plus `name`, `description`, `groups.<id>.label`, `settings.<key>.label`, `settings.<key>.help`, or `presets.<id>.label` | Full keys only in descriptors; section 8 |

Published content retains these keys; changing one removes access to old translations. `MC.I18n.ContentKey( kind, id )` derives keys with `/` changed to `.`, returning `nil` for invalid IDs.

Block/item registration (`MC.API.Blocks.*`, `MC.API.Items.Register`, mod registry) rejects `disp`, `dispZH`, `displayName`, and `displayNameZH` with `inline_name_unsupported`. Invalid `translationKey`/`translationVars` also fail. Registries retain keys/parameters, resolving names at query time. Parameters can nest specifications; generated slopes use `{ block = { key = <original-block-key> } }`.

Name queries accept optional `locale`, defaulting to the current realm language and forwarding it downstream:

| Function | Description |
| --- | --- |
| `MC.API.Blocks.DisplayName( id, locale )`, `DisplayNameForState( stateId, locale )` | Block name. Non-string locale returns `nil, "invalid_locale"`. |
| `MC.API.Blocks.TranslationKey( id )` | Block-name key and copied parameters. |
| `MC.API.Items.DisplayName( id, locale )`, `TranslationKey( id )` | Item name and key, provided by mc_game. |
| `MC.BlockDisplayName`, `MC.ItemDisplayName`, `MC.PotionContents.DisplayName`, `MCITEM.EnchantmentLevelName`, `MCITEM.EnchantedBookDisplayName` | Internal engine/game helpers also accepting locale. |
| `MC.InventoryUI.ItemRenderer.DisplayName( stack, locale )` | Inventory name: player custom names and GMod weapon titles remain literal; others use locale. |

Inventory/creative searches match names in both the current locale and `en_us`, plus item IDs.

Inventory responses retain error keys/codes. Common errors have translations; unknown codes use `inventory.error.action_failed` with the literal code. Language changes refresh errors and recipe-book results without clearing searches. MCITEM weapons, entities, and spawn categories use GMod phrase bindings. Potion names/effect summaries are generated dynamically; language changes update weapon instructions and clear old `InfoMarkup`.

Spawn-menu refresh follows Sandbox rules: rebuild when closed and no unsaved spawn-list edits exist; otherwise defer refresh. Changing category text must not discard a player's edited spawn list.

## 7. Settings menu metadata

Groups, categories, and settings in `mc/sh_config_ui.lua`, including external `MC.API.Config.RegisterGroup`/`RegisterCategory` entries, contain IDs and functional fields. Text resolves using section 6. `MC.ConfigText` provides `GroupKey`, `CategoryKey`, `CategoryDescriptionKey`, `ItemKey`, `ItemHelpKey`, `ChoiceKey`, `UnitKey`, and `Keys( kind, entry )`.

- `helpKey = false` or `descriptionKey = false` means no description.
- `labelVars`, `helpVars`, and `descriptionVars` accept template parameters, including nested specifications.
- An option's `text` displays literally, for language self-names and player-named shader presets.
- `choices` may be a function evaluated when the menu opens. Server entries can supply `serverChoices`, sent with server settings through `mc_config_values`.
- Built-in units are `blocks`, `bytes`, `cells`, `chunks`, `chunks_per_frame`, `deg`, `kg`, `ms`, `px`, `s`, `scale`, `texels`, and `u`. Addons define other `config.unit.<unit>` keys.

`RegisterGroup`/`RegisterCategory` reject inline `label`, `zhLabel`, `labelZH`, `description`, `descriptionZH`, `help`, and `helpZH`, including option labels, with `inline_text_unsupported`. Invalid derived/explicit keys return `invalid_text_key`. Missing translations do not reject registration; section 4 fallback applies.

`mc_language` lists `auto` and client-loaded locales. Server `mc_console_language` lists `auto` and server-loaded locales, under administrator permissions. The server sends only locale IDs; clients use local self-name metadata or show the ID. No catalogs or name metadata are synchronized. Both automatic labels follow the client's UI language, with server auto explicitly labeled English.

Settings searches match current-locale text, `en_us` text, and ConVar names.

## 8. Shader descriptors

In `data_static/mc/shaderpacks/*.json`, `definition` uses keys for all visible text:

| Object | Fields |
| --- | --- |
| Pack or shader | Required `nameKey`, optional `descriptionKey` |
| Settings group | Required `labelKey`, optional `descriptionKey` |
| Setting | Required `labelKey`, optional `helpKey` |
| Enum option | Optional `labelKey`; otherwise display the value |
| Built-in preset | Required `labelKey`, optional `descriptionKey` |

Keys are complete final keys, independent of descriptor directories. `MC.RenderPackSchema` validates key shape and rejects old fields such as `name`, `label`, `labelZH`, `help`, and `helpZH`. Missing translations do not prevent a functionally valid shader from loading. Setting IDs, option values, preset IDs, program names, and hashes are functional data, not translated. Player preset names remain literal.

`MC.RenderPackRegistry.List` returns `nameKey`/`descriptionKey`. Language changes/reloads rebuild only settings text, without shader compilation, GPU rebuilds, or setting changes.

Build entry points under `tools/shader_compiler/` publish descriptors. Display keys live in `descriptor_display.json`; PBR settings/presets in `shadersrc/l2/pbr_assets/settings.json`. Translations are not build inputs; display/settings-only edits can be republished without compiling. See the [compiler README](../tools/shader_compiler/README.md).

## 9. Vanilla Minecraft translations

A generator copies Minecraft translations into the owning addon's catalog:

```text
python tools/localization/generate_minecraft_lang.py --lang-dir <assets/minecraft/lang-directory> [--check]
```

It reads every `<locale>.json` except `deprecated.json`, keeps keys also present in `en_us.json`, assigns prefixes according to `OWNERS`, and writes `addons/<addon>/data_static/mc/i18n/<addon>.minecraft.<locale>.json`. Minecraft keys remain unchanged, such as `itemGroup.buildingBlocks`. Java formats convert to parameters: successive `%s` become `{1}`, `{2}`, etc.; `%2$s` becomes `{2}`; `%%` becomes `%`. Other percent sequences fail. `--check` writes nothing and returns 1 for mismatches or obsolete generated files.

| addon | Owned Minecraft keys |
| --- | --- |
| `mc_engine` | `block.minecraft.*` |
| `mc_game` | `item.minecraft.*`, `itemGroup.*`, `container.*`, `merchant.*`, `entity.minecraft.villager*`, `entity.minecraft.wandering_trader`, `book.pageIndicator`, `item.durability`, `item.components` |
| `mc_item` | `effect.minecraft.*`, `effect.duration.infinite`, `effect.none`, `enchantment.minecraft.*`, `enchantment.level.*`, `potion.withAmplifier`, `potion.withDuration` |

The current source is Minecraft 26.2-pre-4.

A separate tool generates vanilla item and creative catalogs from the same extracted client, retaining translation keys only: first `item.minecraft.<id>`, then `block.minecraft.<id>`.

```text
powershell -File tools/content/generate_items.ps1 -MinecraftRoot <extracted-directory> [-SkipMaterials]
```

Outputs are `addons/mc_game/lua/mcgame/generated/sh_generated_items.lua` and `sh_generated_creative_tabs.lua`. Without `-SkipMaterials`, it also copies item/container textures to `addons/mc_game/materials/mc/`.

## 10. Console commands

| Command | Realm | Purpose |
| --- | --- | --- |
| `mc_lang [locale\|auto]` | Client | Without arguments, list settings/options; with an argument, set UI language. Supports completion. |
| `mc_i18n_reload` | Client | Reload locally visible catalogs. |
| `mc_i18n_report` | Client | List loaded fragments, resource errors, duplicate keys, and alias conflicts. |
| `mc_i18n_missing` | Client | List missing keys since the latest load. |
| `mc_i18n_reload_sv`, `mc_i18n_report_sv`, `mc_i18n_missing_sv` | Server | Server equivalents; server console or superadmins only. |
| `mc_i18n_debug 0\|1` | Client ConVar | Print each missing key once. |

## 11. Translation maintenance and checks

Catalog maintenance needs only Python's standard library:

```text
python tools/localization/check_catalogs.py --report <output-directory>/i18n-report.json
python tools/localization/check_catalogs.py --overrides <override-directory> --report <output-directory>/i18n-with-overrides.json
```

The checker reads addon fragments in virtual-path order, followed by optional overrides. It validates duplicate JSON members, directories/keys, self-names, resource limits, missing translations against `en_us`, `{name}` placeholder sets, and coverage. Reports retain file order, previous/final conflict sources, alias conflicts, `nativeNames`, and `nativeNameConflicts`. Duplicate addon virtual paths fail. Format errors, missing keys, or placeholder mismatches return nonzero; valid key/name overrides are reported without failure.

When adding or editing translations:

1. Maintain `en_us` and target locales in the owning addon. Prefix filenames with the addon name to avoid virtual-path masking.
2. Keep keys, placeholder names, and parameter meanings stable. Translate sentences, not IDs, error codes, or player names.
3. Run the resource checker, then `mc_i18n_reload` in game and inspect the changed interface/message. Check `mc_i18n_missing` for new gaps.
4. Ensure GMAs include new fragments. Reload server catalogs after editing server-console resources.

The checker does not execute Lua or replace full loader boundary validation. Section 9's generator owns vanilla catalogs; do not put hand-written translations into generated files. Missing-key export and automatic merge tools are not provided. Use JSON reports for manual merging while preserving existing human translations.

### 11.1 Runtime tests

Tests run real engine Lua in LuaJIT through lupa. Point `--deps` or `MINEMOD_TEST_DEPS` at a directory containing lupa:

```text
python tools/localization/tests/test_i18n_loader.py --deps <directory>
python tools/localization/tests/test_i18n_content.py --deps <directory>
```

- `test_i18n_loader.py` simulates multi-addon `GAME` mounts and `DATA` overrides in temporary directories, reversing/shuffling enumeration. It covers sections 1–4 and loads all shipped fragments, requiring no resource errors, duplicate keys, or alias conflicts and matching `en_us`/`zh_cn` key sets, except count variants with only `.other`.
- `test_i18n_content.py` loads `sh_config_ui.lua` and public APIs; checks rejection of inline text, translation coverage for configuration/creative/shader keys, and descriptor schema validity without old fields. It also checks `ContentKey` templates, key-only generated item catalogs, potion/effect/enchantment coverage, literal keys used by `MC.T`, `MC.I18n.Resolve`, container titles, resource packs, and F3, and propagation of explicit `locale` through potion-name queries independently of UI language.

Use `generate_minecraft_lang.py --check` to compare generated catalogs with the repository.
