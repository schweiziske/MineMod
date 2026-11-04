"""Offline tests of the content that uses the localization runtime: creative
tab titles, config metadata and shader descriptors carry keys only, and every
key they reference is translated by the files of the addon that owns it.

    python tools/localization/tests/test_i18n_content.py --deps <dir with lupa>
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lua_runtime  # noqa: E402
from lua_runtime import REPO, Runtime, VirtualFS  # noqa: E402

LOCALES = ("en_us", "zh_cn")
ADDONS = REPO / "addons"


def eq(actual, expected, what=""):
    if actual != expected:
        raise AssertionError("%s: expected %r, got %r" % (what or "value", expected, actual))


def check(condition, what):
    if not condition:
        raise AssertionError(what)


def runtime(realm="client", extra_roots=()):
    roots = lua_runtime.repo_game_roots() + [Path(root) for root in extra_roots]
    rt = Runtime(VirtualFS(roots), realm, "en").load_i18n()
    eq(rt.report()["errors"], [], "resource errors")
    return rt


def untranslated(rt, keys):
    """Keys that some locale lacks, as 'locale key'."""
    missing = []
    for key in sorted(set(keys)):
        for locale in LOCALES:
            if not rt.call("MC.I18n.Has", key, locale):
                # A locale without a singular form only provides <key>.other.
                if key.endswith(".one") and rt.call("MC.I18n.Has", key[:-4] + ".other", locale):
                    continue
                missing.append("%s %s" % (locale, key))
    return missing


def spec_keys(value, out):
    """Keys of nested { key = ..., vars = ... } specs inside a vars table."""
    if isinstance(value, dict):
        if isinstance(value.get("key"), str):
            out.append(value["key"])
        for child in value.values():
            spec_keys(child, out)
    elif isinstance(value, list):
        for child in value:
            spec_keys(child, out)


def config_keys(rt, scopes=("client", "server")):
    """Every key the registered config metadata looks up."""
    rt.run("""
        TEST.configKeys = {}
        local function add( list )
            for _, key in ipairs( list ) do TEST.configKeys[#TEST.configKeys + 1] = key end
        end
        for _, scope in ipairs( { "client", "server" } ) do
            for _, group in ipairs( MC.ConfigGroups[scope] or {} ) do add( MC.ConfigText.Keys( "group", group ) ) end
            for _, category in ipairs( MC.ConfigConVars[scope] or {} ) do
                add( MC.ConfigText.Keys( "category", category ) )
                for _, item in ipairs( category.items or {} ) do add( MC.ConfigText.Keys( "item", item ) ) end
            end
        end
    """)
    keys = rt.to_python(rt.eval("TEST.configKeys"))
    vars_tables = rt.to_python(rt.eval("""(function()
        local all = {}
        for _, scope in ipairs( { "client", "server" } ) do
            for _, category in ipairs( MC.ConfigConVars[scope] or {} ) do
                all[#all + 1] = { category.labelVars, category.descriptionVars }
                for _, item in ipairs( category.items or {} ) do all[#all + 1] = { item.labelVars, item.helpVars } end
            end
        end
        return all
    end)()"""))
    spec_keys(vars_tables, keys)
    return keys


# ---------------------------------------------------------------- creative tabs

def test_creative_titles_are_keys():
    rt = runtime().load_api()
    register = "MC.API.Creative.RegisterCategory"
    ok, record = rt.call(register, {"id": "example:building"})
    eq(ok, True)
    eq(rt.to_python(record)["titleKey"], "itemGroup.example.building", "derived key")
    for field in ("title", "titleZH"):
        eq(rt.call(register, {"id": "example:other", field: "Other"}), (False, "inline_title_unsupported"), field)
    ok, record = rt.call(register, {"id": "example:nested/tab"})
    eq(rt.to_python(record)["titleKey"], "itemGroup.example.nested.tab", "'/' becomes '.'")
    ok, record = rt.call(register, {"id": "example:third", "titleKey": "itemGroup.shared"})
    eq(rt.to_python(record)["titleKey"], "itemGroup.shared", "explicit key")
    eq(rt.call(register, {"id": "example:bad", "titleKey": "not a key"}), (False, "invalid_title_key"))
    listed = rt.to_python(rt.call("MC.API.Creative.ListCategories"))
    check(all("title" not in category and "titleZH" not in category for category in listed), "no inline titles listed")


def creative_registrations():
    """(file, id, explicit titleKey) of every RegisterCategory call in the repo."""
    found = []
    for path in sorted(list(ADDONS.rglob("*.lua")) + list((REPO / "examples").rglob("*.lua"))):
        # Generated tables register no categories; the vanilla tabs are checked separately.
        if "mc_bedwars" in path.parts or "generated" in path.parts:
            continue
        text = path.read_text(encoding="utf-8")
        constants = dict(re.findall(r'local\s+(\w+)\s*=\s*"([^"]+)"', text))
        for match in re.finditer(r"RegisterCategory\(\s*\{(.*?)\}\s*\)", text, re.S):
            body = match.group(1)
            ident = re.search(r'\bid\s*=\s*(?:"([^"]+)"|(\w+))', body)
            if not ident:
                continue
            value = ident.group(1) or constants.get(ident.group(2))
            check(value is not None, "%s: unresolved category id %s" % (path, ident.group(2)))
            explicit = re.search(r'titleKey\s*=\s*"([^"]+)"', body)
            found.append((path, value, explicit and explicit.group(1)))
    return found


def test_repository_creative_titles_are_translated():
    rt = runtime(extra_roots=[REPO / "examples"])
    keys = []
    registrations = creative_registrations()
    check(len(registrations) >= 5, "found the category registrations: %r" % registrations)
    for path, ident, explicit in registrations:
        namespace, rest = ident.split(":", 1)
        keys.append(explicit or "itemGroup.%s.%s" % (namespace, rest.replace("/", ".")))
    generated = (ADDONS / "mc_game/lua/mcgame/generated/sh_generated_creative_tabs.lua").read_text(encoding="utf-8")
    vanilla = re.findall(r'titleKey="([^"]+)"', generated)
    eq(len(vanilla), 14, "vanilla tabs")
    keys += vanilla
    engine_ui = (ADDONS / "mc_engine/lua/mc/cl_ui.lua").read_text(encoding="utf-8")
    keys += re.findall(r'labelKey = "(creative\.category\.[a-z_]+)"', engine_ui)
    eq(untranslated(rt, keys), [], "creative titles")


# ---------------------------------------------------------------- config metadata

def test_config_api_rejects_inline_text():
    rt = runtime().load_api()
    group, category = "MC.API.Config.RegisterGroup", "MC.API.Config.RegisterCategory"
    eq(rt.call(group, "client", {"id": "g1", "label": "G"}), (False, "inline_text_unsupported"))
    eq(rt.call(group, "client", {"id": "g1", "zhLabel": "G"}), (False, "inline_text_unsupported"))
    eq(rt.call(group, "client", {"id": "g1", "labelKey": "bad key"}), (False, "invalid_text_key"))
    eq(rt.call(group, "client", {"id": "g1"}), True)
    item = {"name": "test_cvar", "kind": "bool"}
    eq(rt.call(category, "client", {"id": "c1", "group": "g1", "items": [dict(item, labelZH="x")]}),
       (False, "inline_text_unsupported"), "item text")
    eq(rt.call(category, "client", {"id": "c1", "group": "g1", "descriptionZH": "x", "items": [item]}),
       (False, "inline_text_unsupported"), "category text")
    choice_item = {"name": "test_choice", "kind": "choice", "choices": [{"value": "a", "label": "A"}]}
    eq(rt.call(category, "client", {"id": "c1", "group": "g1", "items": [choice_item]}),
       (False, "inline_text_unsupported"), "choice text")
    eq(rt.call(category, "client", {"id": "c1", "group": "g1", "items": [dict(item, unit="bad unit")]}),
       (False, "invalid_text_key"), "unit key")
    eq(rt.call(category, "client", {"id": "c1", "group": "g1", "items": [item]}), True)
    keys = rt.to_python(rt.eval("""MC.ConfigText.Keys( "item", MC.ConfigConVars.client[#MC.ConfigConVars.client].items[1] )"""))
    eq(keys, ["config.setting.test_cvar.label", "config.setting.test_cvar.help"], "derived item keys")


def test_engine_config_keys_are_translated():
    for realm in ("client", "server"):
        rt = runtime(realm).load_api()
        eq(untranslated(rt, config_keys(rt)), [], "%s config" % realm)


def test_language_choices_are_the_loaded_locales():
    rt = runtime().load_api()
    choices = rt.to_python(rt.eval("""(function()
        local item = MC.FindConfigConVar( "client", "mc_language" )
        return item.choices()
    end)()"""))
    eq(choices, [{"value": "auto", "text": "auto"}, {"value": "en_us", "text": "en_us"},
                 {"value": "zh_cn", "text": "zh_cn"}])
    server = runtime("server").load_api()
    choices = server.to_python(server.eval("""(function()
        local item = MC.FindConfigConVar( "server", "mc_console_language" )
        return item.serverChoices()
    end)()"""))
    eq([choice["value"] for choice in choices], ["auto", "en_us", "zh_cn"], "server console choices")


def load_mcitem_config(rt):
    rt.run("MCITEM = nil")
    for name in ("sh_holdtypes.lua", "sh_config_menu.lua"):
        rt.run_file(ADDONS / "mc_item/lua/mcitem" / name)
    eq(rt.eval("MCITEM.RegisterConfigMenu()"), True, "MCITEM registration")


def test_mcitem_config_keys_are_translated():
    rt = runtime().load_api()
    load_mcitem_config(rt)
    keys = config_keys(rt)
    check(any(key.startswith("mcitem.thirdperson.") for key in keys), "third-person templates are referenced")
    eq(untranslated(rt, keys), [], "MCITEM config")
    label = rt.eval("""(function()
        for _, category in ipairs( MC.ConfigConVars.client ) do
            if category.id == "mcitem_thirdperson_food" then
                for _, item in ipairs( category.items ) do
                    if item.name == "mcitem_tp_food_use_yaw" then
                        return MC.I18n.Resolve( MC.ConfigText.ItemKey( item ), item.labelVars, "zh_cn" )
                    end
                end
            end
        end
    end)()""")
    eq(label, "食用 - 偏航", "state override and field fill the template")


def test_inventory_ui_config_keys_are_translated():
    rt = runtime().load_api()
    source = (ADDONS / "mc_game/lua/mcgame/inventory/ui/cl_theme.lua").read_text(encoding="utf-8")
    match = re.search(r'configAPI\.RegisterCategory\( "client", (\{.*?\n\t\} )\)', source, re.S)
    check(match, "found the inventory UI registration")
    rt.run("TEST.inventoryCategory = " + match.group(1))
    eq(rt.eval('MC.API.Config.RegisterCategory( "client", TEST.inventoryCategory )'), True)
    eq(untranslated(rt, config_keys(rt)), [], "inventory UI config")


# ---------------------------------------------------------------- shader descriptors

DISPLAY_TEXT = re.compile(r'"(name|label|labelZH|help|helpZH|description|descriptionZH)"\s*:')


def descriptor_files():
    return sorted(ADDONS.glob("*/data_static/mc/shaderpacks/*.json"))


def descriptor_keys(definition):
    keys = [definition["nameKey"]]
    if definition.get("descriptionKey"):
        keys.append(definition["descriptionKey"])
    for group in definition.get("settingGroups", []):
        keys += [group["labelKey"]] + ([group["descriptionKey"]] if group.get("descriptionKey") else [])
    for spec in definition.get("settings", []):
        keys += [spec["labelKey"]] + ([spec["helpKey"]] if spec.get("helpKey") else [])
        keys += [choice["labelKey"] for choice in spec.get("choices", []) if choice.get("labelKey")]
    for preset in definition.get("presets", []):
        keys += [preset["labelKey"]] + ([preset["descriptionKey"]] if preset.get("descriptionKey") else [])
    return keys


def load_schema(rt):
    rt.run_file(lua_runtime.ENGINE_LUA / "mc/render/cl_render_pack_schema.lua")


def test_shader_descriptors_are_key_only_and_translated():
    rt = runtime()
    load_schema(rt)
    files = descriptor_files()
    eq(len(files), 3, "published descriptors")
    sources = [Path("tools/shader_compiler/shadersrc/l2/pbr_assets/settings.json")]
    for path in files + [REPO / source for source in sources]:
        check(not DISPLAY_TEXT.search(path.read_text(encoding="utf-8")), "%s has inline display text" % path)
    keys = []
    for path in files:
        document = json.loads(path.read_text(encoding="utf-8"))
        definition, err = rt.call("MC.RenderPackSchema.Normalize", document["definition"])
        check(definition is not None, "%s rejected: %s" % (path, err))
        keys += descriptor_keys(document["definition"])
        prefix = "shaderpack.%s." % document["id"].replace(":", "_")
        check(all(key.startswith(prefix) for key in descriptor_keys(document["definition"])),
              "%s keys use %s" % (path, prefix))
    eq(untranslated(rt, keys), [], "shader texts")
    legacy = rt.run_file(lua_runtime.ENGINE_LUA / "mc/render/generated/cl_render_pack_vanilla.lua")
    definition, err = rt.call("MC.RenderPackSchema.Normalize", legacy)
    check(definition is not None, "legacy built-in vanilla definition rejected: %s" % err)


def test_shader_schema_rejects_inline_display_text():
    rt = runtime()
    load_schema(rt)
    base = json.loads((ADDONS / "mc_shaderpack_pbr/data_static/mc/shaderpacks/mc_pbr.json").read_text(encoding="utf-8"))
    cases = {
        "definition name": lambda d: d.update(name="PBR"),
        "missing nameKey": lambda d: d.pop("nameKey"),
        "group label": lambda d: d["settingGroups"][0].update(label="Textures"),
        "setting labelZH": lambda d: d["settings"][0].update(labelZH="x"),
        "setting help": lambda d: d["settings"][0].update(help="x"),
        "choice label": lambda d: next(s for s in d["settings"] if s.get("choices"))["choices"][0].update(label="x"),
        "preset label": lambda d: d["presets"][0].update(label="Low"),
        "invalid key": lambda d: d["settings"][0].update(labelKey="not a key"),
    }
    for what, mutate in cases.items():
        definition = json.loads(json.dumps(base["definition"]))
        mutate(definition)
        result, err = rt.call("MC.RenderPackSchema.Normalize", definition)
        check(result is None, "%s accepted" % what)
    definition, err = rt.call("MC.RenderPackSchema.Normalize", base["definition"])
    check(definition is not None, "published PBR descriptor: %s" % err)


def test_shader_builders_publish_display_keys():
    display = json.loads((REPO / "tools/shader_compiler/descriptor_display.json").read_text(encoding="utf-8"))
    for path in descriptor_files():
        document = json.loads(path.read_text(encoding="utf-8"))
        eq(document["definition"]["nameKey"], display[document["id"]]["nameKey"], "%s nameKey" % path.name)
    for name in ("build_l2_pbr.cjs", "build_l2_vanilla.cjs", "build_skybox_block.cjs"):
        text = (REPO / "tools/shader_compiler" / name).read_text(encoding="utf-8")
        check("withDisplay(" in text and not re.search(r'\bname: "', text), "%s writes display keys only" % name)


if __name__ == "__main__":
    sys.exit(lua_runtime.run_tests(dict(globals()), sys.argv[1:]))
