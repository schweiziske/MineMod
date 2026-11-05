"""Offline tests of the file-based localization loader (mc/sh_i18n.lua).

    python tools/localization/tests/test_i18n_loader.py --deps <dir with lupa>

Every scenario builds its own addons/ and data/ trees in a temporary
directory and runs the real loader under LuaJIT with a stub GMod API.
"""
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lua_runtime  # noqa: E402
from lua_runtime import Runtime, VirtualFS  # noqa: E402

ROOT = "data_static/mc/i18n/"


def eq(actual, expected, what=""):
    if actual != expected:
        raise AssertionError("%s: expected %r, got %r" % (what or "value", expected, actual))


def check(condition, what):
    if not condition:
        raise AssertionError(what)


class Scenario:
    """Temporary addons/<name>/data_static/mc/i18n trees plus a data/ root."""

    def __enter__(self):
        self.base = Path(tempfile.mkdtemp(prefix="mc_i18n_test_"))
        (self.base / "addons").mkdir()
        (self.base / "data").mkdir()
        return self

    def __exit__(self, *_):
        shutil.rmtree(self.base, ignore_errors=True)

    def game_roots(self):
        return sorted(path for path in (self.base / "addons").iterdir() if path.is_dir())

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, (dict, list)):
            content = json.dumps(content, ensure_ascii=False, indent=2)
        path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return path

    def fragment(self, addon, relative, locale, entries, aliases=None, native_name=None):
        document = {"locale": locale, "entries": entries}
        if aliases is not None:
            document["aliases"] = aliases
        if native_name is not None:
            document["nativeName"] = native_name
        return self.write(self.base / "addons" / addon / ROOT / relative, document)

    def raw(self, addon, relative, content):
        return self.write(self.base / "addons" / addon / ROOT / relative, content)

    def override(self, relative, locale, entries):
        document = {"locale": locale, "entries": entries}
        return self.write(self.base / "data" / "mc" / "i18n" / "overrides" / relative, document)

    def runtime(self, realm="client", game_language="en", shuffle_seed=None, language=None):
        fs = VirtualFS(self.game_roots, self.base / "data", shuffle_seed)
        rt = Runtime(fs, realm, game_language)
        if language is not None:
            rt.run('TEST.SetConVarSilently( "mc_language", %s )' % json.dumps(language))
        return rt.load_i18n()


def T(rt, key, vars=None, locale=None):
    return rt.call("MC.T", key, vars, locale)


def conflicts_for(report, key):
    return [conflict for conflict in report["conflicts"] if conflict["key"] == key]


# ---------------------------------------------------------------- namespaces

def test_three_namespace_forms_give_one_key():
    forms = [("", "space1.space2.xxx"), ("space1/", "space2.xxx"), ("space1/space2/", "xxx")]
    for directory, key in forms:
        with Scenario() as s:
            s.fragment("addon_a", directory + "strings.json", "en_us", {key: "value"})
            rt = s.runtime()
            eq(T(rt, "space1.space2.xxx"), "value", "form %r" % directory)
            eq(rt.report()["errors"], [], "errors for form %r" % directory)
    # All three at once define the same final key three times.
    with Scenario() as s:
        for index, (directory, key) in enumerate(forms):
            s.fragment("addon_a", directory + "part%d.json" % index, "en_us", {key: "v%d" % index})
        rt = s.runtime()
        eq(len(conflicts_for(rt.report(), "space1.space2.xxx")), 2, "duplicates")
        eq(T(rt, "space1.space2.xxx"), "v2", "deepest path sorts last")


def test_file_name_never_changes_keys():
    with Scenario() as s:
        path = s.fragment("addon_a", "ui/settings/part_a.json", "en_us", {"render.distance.label": "Draw distance"})
        rt = s.runtime()
        eq(T(rt, "ui.settings.render.distance.label"), "Draw distance")
        path.rename(path.with_name("something.else.entirely.json"))
        rt.call("MC.I18n.Reload")
        eq(T(rt, "ui.settings.render.distance.label"), "Draw distance", "after rename")


def test_locale_comes_from_the_document_not_the_path():
    with Scenario() as s:
        # A directory called zh_cn is just a namespace; the file name suffix
        # means nothing either.
        s.fragment("addon_a", "zh_cn/strings.zh_cn.json", "en_us", {"title": "Title"})
        rt = s.runtime()
        eq(rt.to_python(rt.call("MC.I18n.Locales")), ["en_us"], "locales")
        eq(T(rt, "zh_cn.title"), "Title")
        eq(T(rt, "title"), "title", "the directory is part of the key")


def test_many_addons_share_one_namespace():
    with Scenario() as s:
        s.fragment("mc_engine", "ui/mc_engine.json", "en_us", {"engine": "Engine"})
        s.fragment("mc_game", "ui/mc_game.json", "en_us", {"game": "Game"})
        s.fragment("mc_game", "ui/more/mc_game.json", "en_us", {"deeper": "Deeper"})
        rt = s.runtime()
        eq(T(rt, "ui.engine"), "Engine")
        eq(T(rt, "ui.game"), "Game")
        eq(T(rt, "ui.more.deeper"), "Deeper")
        report = rt.report()
        eq(report["conflicts"], [], "conflicts")
        eq(len(report["files"]), 3, "files")


def test_same_virtual_path_is_shadowed_like_any_mounted_file():
    # The first mounted root provides a path that two addons both ship; the
    # loader cannot see the hidden copy (documented limitation).
    with Scenario() as s:
        s.fragment("addon_a", "ui/strings.json", "en_us", {"from_a": "A"})
        s.fragment("addon_b", "ui/strings.json", "en_us", {"from_b": "B"})
        rt = s.runtime()
        eq(T(rt, "ui.from_a"), "A")
        eq(T(rt, "ui.from_b"), "ui.from_b")


# ---------------------------------------------------------------- order and duplicates

def test_load_order_is_the_sorted_path_whatever_the_enumeration():
    outcomes = set()
    for seed in (None, 1, 2, 3, 4, 5, 6, 7):
        with Scenario() as s:
            s.fragment("addon_b", "ui/b_late.json", "en_us", {"title": "late"})
            s.fragment("addon_a", "ui/a_early.json", "en_us", {"title": "early"})
            s.fragment("addon_c", "ui/sub/z.json", "en_us", {"deep": "z"})
            s.fragment("addon_c", "ui/sub.json", "en_us", {"sub.deep": "flat"})
            rt = s.runtime(shuffle_seed=seed)
            report = rt.report()
            order = tuple(entry["source"] for entry in report["files"])
            outcomes.add((T(rt, "ui.title"), T(rt, "ui.sub.deep"), order))
    eq(len(outcomes), 1, "every enumeration order gives one result")
    title, deep, order = outcomes.pop()
    eq(title, "late", "b_late.json sorts after a_early.json")
    # "ui/sub.json" < "ui/sub/z.json" because "." sorts before "/".
    eq(deep, "z")
    eq(list(order), [
        "GAME:" + ROOT + "ui/a_early.json",
        "GAME:" + ROOT + "ui/b_late.json",
        "GAME:" + ROOT + "ui/sub.json",
        "GAME:" + ROOT + "ui/sub/z.json",
    ], "load order")


def test_duplicate_reports_both_sources_even_for_equal_text():
    with Scenario() as s:
        s.fragment("addon_a", "ui/a.json", "en_us", {"same": "Same", "other": "First"})
        s.fragment("addon_b", "ui/b.json", "en_us", {"same": "Same", "other": "Second"})
        rt = s.runtime()
        report = rt.report()
        same = conflicts_for(report, "ui.same")
        other = conflicts_for(report, "ui.other")
        eq(len(same), 1, "equal text is still a duplicate")
        eq(same[0]["sameText"], True)
        eq(other[0]["sameText"], False)
        eq(other[0]["previous"], "GAME:" + ROOT + "ui/a.json")
        eq(other[0]["current"], "GAME:" + ROOT + "ui/b.json")
        eq(other[0]["locale"], "en_us")
        eq(T(rt, "ui.other"), "Second", "the later file wins")
        printed = "\n".join(rt.output())
        check("duplicate en_us ui.same" in printed and "(same text)" in printed, "same-text warning printed")
        check(("GAME:" + ROOT + "ui/a.json, then GAME:" + ROOT + "ui/b.json wins") in printed, "both sources printed")
        eq(report["errors"], [], "a duplicate is not an error")


def test_duplicates_only_count_within_one_locale():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"title": "设置"})
        rt = s.runtime()
        eq(rt.report()["conflicts"], [])


# ---------------------------------------------------------------- broken resources

def test_broken_files_are_reported_and_the_rest_loads():
    with Scenario() as s:
        s.fragment("addon_a", "ui/good.json", "en_us", {"title": "Good"})
        bad = {
            "ui/syntax.json": '{"locale": "en_us", "entries": {',
            "ui/array.json": '["not", "an", "object"]',
            "ui/unknown_field.json": {"locale": "en_us", "entries": {}, "name": "x"},
            "ui/not_string.json": {"locale": "en_us", "entries": {"n": 1}},
            "ui/nested.json": {"locale": "en_us", "entries": {"a": {"b": "x"}}},
            "ui/empty_segment.json": {"locale": "en_us", "entries": {"a..b": "x"}},
            "ui/leading_dot.json": {"locale": "en_us", "entries": {".a": "x"}},
            "ui/space_key.json": {"locale": "en_us", "entries": {"a b": "x"}},
            "ui/no_locale.json": {"entries": {"a": "x"}},
            "ui/bad_locale.json": {"locale": "en us", "entries": {"a": "x"}},
            "ui/bad_alias.json": {"locale": "en_us", "aliases": ["ok", "not ok"], "entries": {"a": "x"}},
            "ui/no_entries.json": {"locale": "en_us"},
            "ui/Upper.json": {"locale": "en_us", "entries": {"a": "x"}},
            "ui/notes.txt": "not a fragment",
            "Bad_Dir/strings.json": {"locale": "en_us", "entries": {"a": "x"}},
            "dotted.dir/strings.json": {"locale": "en_us", "entries": {"a": "x"}},
        }
        for relative, content in bad.items():
            s.raw("addon_a", relative, content)
        rt = s.runtime()
        eq(T(rt, "ui.title"), "Good", "good file still loads")
        report = rt.report()
        reported = {error["source"] for error in report["errors"]}
        for relative in bad:
            if relative.startswith("Bad_Dir/") or relative.startswith("dotted.dir/"):
                expected = "GAME:" + ROOT + relative.split("/")[0] + "/"
            else:
                expected = "GAME:" + ROOT + relative
            check(expected in reported, "error reported for %s (got %s)" % (relative, sorted(reported)))
        eq(len(report["errors"]), len(bad), "one error per bad resource")
        reasons = {error["source"].split(ROOT, 1)[1]: error["reason"] for error in report["errors"]}
        for relative, expected in {
            "ui/syntax.json": "not a valid JSON object",
            "ui/array.json": "must be a JSON object, not an array",
            "ui/unknown_field.json": "unknown top-level field 'name'",
            "ui/not_string.json": "entry 'n' is not a string",
            "ui/nested.json": "entry 'a' is not a string",
            "ui/empty_segment.json": "invalid entry key 'a..b'",
            "ui/no_locale.json": "'locale' is missing",
            "ui/bad_alias.json": "alias #2",
            "ui/no_entries.json": "'entries' must be an object",
            "ui/Upper.json": "file name must be lowercase",
            "Bad_Dir/": "directory name must be lowercase",
        }.items():
            check(expected in str(reasons.get(relative)), "%s: %r should mention %r" % (relative, reasons.get(relative), expected))
        eq(len(report["files"]), 1, "only the good file loaded")
        check("i18n_resource_invalid" in rt.faults(), "resource fault raised")
        eq(T(rt, "ui.a"), "ui.a", "nothing from a rejected file")


def test_utf8_bom_is_accepted():
    with Scenario() as s:
        content = json.dumps({"locale": "zh_cn", "entries": {"title": "设置"}}, ensure_ascii=False)
        s.raw("addon_a", "ui/bom.json", b"\xef\xbb\xbf" + content.encode("utf-8"))
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        rt = s.runtime(language="zh_cn")
        eq(rt.report()["errors"], [])
        eq(T(rt, "ui.title"), "设置")


def test_resource_limits_reject_whole_files():
    with Scenario() as s:
        s.fragment("addon_a", "ui/small.json", "en_us", {"a": "x"})
        s.fragment("addon_a", "ui/two.json", "en_us", {"b": "x", "c": "y"})
        s.fragment("addon_a", "ui/long_value.json", "en_us", {"d": "x" * 40})
        rt = s.runtime()
        rt.run("MC.I18n.LIMITS.entriesPerFile = 1; MC.I18n.LIMITS.valueBytes = 16")
        rt.call("MC.I18n.Reload")
        reasons = {error["source"].rsplit("/", 1)[1]: error["reason"] for error in rt.report()["errors"]}
        check("more than 1 entries" in reasons.get("two.json", ""), "entry limit: %r" % reasons)
        check("longer than 16 bytes" in reasons.get("long_value.json", ""), "value limit: %r" % reasons)
        eq(T(rt, "ui.a"), "x")
        eq(T(rt, "ui.b"), "ui.b", "nothing from a file over the limit")
        rt.run("MC.I18n.LIMITS.fileBytes = 8")
        rt.call("MC.I18n.Reload")
        check(all("larger than 8 bytes" in error["reason"] for error in rt.report()["errors"]), "file size limit")


# ---------------------------------------------------------------- locales

def test_new_locale_becomes_selectable_after_reload():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        s.fragment("addon_a", "config/labels.json", "en_us", {"language.auto": "Automatic (game language)"})
        rt = s.runtime()
        eq(rt.to_python(rt.call("MC.I18n.Locales")), ["en_us"])
        # A new addon with a locale no Lua code names.
        s.fragment("addon_fr", "ui/fr_strings.json", "fr-FR", {"title": "Paramètres"})
        rt.call("MC.I18n.Reload")
        eq(rt.to_python(rt.call("MC.I18n.Locales")), ["en_us", "fr_fr"])
        options = rt.to_python(rt.call("MC.I18n.LanguageOptions"))
        eq(options, [{"value": "auto", "label": "Automatic (game language)"}, {"value": "en_us", "label": "en_us"},
                     {"value": "fr_fr", "label": "fr_fr"}], "unnamed locales keep their ids")
        eq(rt.call("MC.I18n.SetLanguage", "FR-fr"), "fr_fr")
        eq(rt.eval('GetConVar( "mc_language" ):GetString()'), "fr_fr")
        eq(rt.call("MC.I18n.Language"), "fr_fr")
        eq(T(rt, "ui.title"), "Paramètres")


def test_native_names_merge_without_changing_language_values():
    with Scenario() as s:
        s.fragment("addon_a", "a.json", "en_us", {"config.language.auto": "Automatic"}, native_name="English")
        s.fragment("addon_a", "b.json", "fr_fr", {"title": "Paramètres"}, native_name="Français")
        s.fragment("addon_b", "c.json", "fr_fr", {}, native_name="Français")
        s.fragment("addon_b", "d.json", "fr_fr", {"other": "Autre"})
        rt = s.runtime()
        eq(rt.report()["nativeNameConflicts"], [], "same name and omitted field are not conflicts")
        eq(rt.to_python(rt.call("MC.I18n.LanguageOptions"))[-1], {"value": "fr_fr", "label": "Français"})
        path = s.base / "data" / "mc" / "i18n" / "overrides" / "name.json"
        s.write(path, {"locale": "fr_fr", "nativeName": "Français (France)", "entries": {}})
        rt.call("MC.I18n.Reload")
        report = rt.report()
        eq(len(report["nativeNameConflicts"]), 1)
        eq(report["nativeNameConflicts"][0]["previousSource"], "GAME:" + ROOT + "c.json")
        eq(report["nativeNames"]["fr_fr"]["source"], "DATA:mc/i18n/overrides/name.json")
        eq(rt.to_python(rt.call("MC.I18n.LanguageOptions"))[-1], {"value": "fr_fr", "label": "Français (France)"})
        eq(rt.call("MC.I18n.Has", "nativeName", "fr_fr"), False, "metadata is not a translation key")
        path.unlink()
        rt.call("MC.I18n.Reload")
        eq(rt.to_python(rt.call("MC.I18n.LanguageOptions"))[-1], {"value": "fr_fr", "label": "Français"})


def test_locale_without_entries_is_not_listed():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        s.fragment("addon_a", "ui/de.json", "de_de", {}, aliases=["de"])
        rt = s.runtime(game_language="de")
        eq(rt.to_python(rt.call("MC.I18n.Locales")), ["en_us"])
        eq(rt.call("MC.I18n.Language"), "en_us", "an alias of an empty locale does not apply")


def test_metadata_never_becomes_an_entry():
    with Scenario() as s:
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"title": "设置"}, aliases=["zh", "schinese"])
        s.fragment("addon_a", "en.json", "en_us", {"title": "Settings"}, aliases=["en"])
        rt = s.runtime()
        for key in ("locale", "aliases", "entries", "ui.locale", "ui.aliases", "ui.entries", "zh", "ui.zh"):
            for locale in ("zh_cn", "en_us"):
                eq(rt.call("MC.I18n.Has", key, locale), False, "%s in %s" % (key, locale))
        eq(rt.report()["entries"], 2, "only the two entries count")


def test_auto_follows_the_game_language_through_canonical_ids_and_aliases():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"}, aliases=["en", "english"])
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"title": "设置"}, aliases=["zh", "schinese"])
        cases = [("zh-CN", "zh_cn"), ("ZH_cn", "zh_cn"), ("zh", "zh_cn"), ("schinese", "zh_cn"),
                 ("en", "en_us"), ("english", "en_us"), ("fr", "en_us"), ("", "en_us"), ("$$$", "en_us")]
        for game_language, expected in cases:
            rt = s.runtime(game_language=game_language)
            eq(rt.call("MC.I18n.LanguageSetting"), "auto")
            eq(rt.call("MC.I18n.Language"), expected, "auto with gmod_language %r" % game_language)


def test_alias_conflicts_are_reported_and_the_later_file_wins():
    with Scenario() as s:
        s.fragment("addon_a", "a/pt_br.json", "pt_br", {"title": "Configurações"}, aliases=["pt"])
        s.fragment("addon_a", "b/pt_pt.json", "pt_pt", {"title": "Definições"}, aliases=["pt"])
        s.fragment("addon_a", "c/en.json", "en_us", {"title": "Settings"})
        rt = s.runtime(game_language="pt")
        conflicts = rt.report()["aliasConflicts"]
        eq(len(conflicts), 1)
        eq((conflicts[0]["alias"], conflicts[0]["previous"], conflicts[0]["current"]), ("pt", "pt_br", "pt_pt"))
        eq(conflicts[0]["previousSource"], "GAME:" + ROOT + "a/pt_br.json")
        eq(conflicts[0]["source"], "GAME:" + ROOT + "b/pt_pt.json")
        eq(rt.call("MC.I18n.Language"), "pt_pt")


def test_explicit_setting_survives_missing_resources():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        rt = s.runtime(language="fr_fr")
        eq(rt.eval('GetConVar( "mc_language" ):GetString()'), "fr_fr", "the setting is not rewritten")
        eq(rt.call("MC.I18n.Language"), "fr_fr")
        eq(T(rt, "ui.title"), "Settings", "lookups use en_us meanwhile")
        s.fragment("addon_fr", "ui/fr.json", "fr_fr", {"title": "Paramètres"})
        rt.call("MC.I18n.Reload")
        eq(T(rt, "ui.title"), "Paramètres", "installing the resources restores the choice")


def test_settings_are_canonicalised():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"title": "设置"})
        rt = s.runtime()
        rt.run('TEST.SetConVar( "mc_language", "ZH-CN" )')
        eq(rt.eval('GetConVar( "mc_language" ):GetString()'), "zh_cn")
        eq(rt.call("MC.I18n.Language"), "zh_cn")
        result = rt.call("MC.I18n.SetLanguage", "not a locale!")
        eq(result, (None, "invalid_locale"))
        eq(rt.eval('GetConVar( "mc_language" ):GetString()'), "zh_cn", "an invalid request changes nothing")
        rt.run('TEST.SetConVar( "mc_language", "???" )')
        eq(rt.call("MC.I18n.LanguageSetting"), "auto", "an invalid stored value acts as auto")
        eq(rt.call("MC.I18n.Language"), "en_us")


# ---------------------------------------------------------------- overrides

def test_personal_override_wins_and_removal_restores():
    with Scenario() as s:
        s.fragment("addon_a", "ui/strings.json", "en_us", {"title": "Settings", "other": "Other"})
        # "a.json" sorts before "strings.json"; overrides still load last.
        override = s.override("ui/a.json", "en_us", {"title": "My settings"})
        rt = s.runtime()
        eq(T(rt, "ui.title"), "My settings")
        eq(T(rt, "ui.other"), "Other", "an override only needs the keys it changes")
        conflict = conflicts_for(rt.report(), "ui.title")[0]
        eq(conflict["previous"], "GAME:" + ROOT + "ui/strings.json")
        eq(conflict["current"], "DATA:mc/i18n/overrides/ui/a.json")
        kinds = {entry["source"]: entry["kind"] for entry in rt.report()["files"]}
        eq(kinds["DATA:mc/i18n/overrides/ui/a.json"], "override")
        eq(rt.call("MC.I18n.Source", "ui.title"), "DATA:mc/i18n/overrides/ui/a.json")
        override.unlink()
        rt.call("MC.I18n.Reload")
        eq(T(rt, "ui.title"), "Settings", "deleting the override restores the published text")
        eq(rt.report()["conflicts"], [])


def test_override_can_add_a_locale():
    with Scenario() as s:
        s.fragment("addon_a", "ui/strings.json", "en_us", {"title": "Settings"})
        s.override("ui/mine.json", "eo", {"title": "Agordoj"})
        rt = s.runtime(language="eo")
        eq(rt.to_python(rt.call("MC.I18n.Locales")), ["en_us", "eo"])
        eq(T(rt, "ui.title"), "Agordoj")


# ---------------------------------------------------------------- lookup

def test_fallback_is_locale_then_en_us_then_key():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"a": "A", "b": "B"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"a": "甲"})
        rt = s.runtime(language="zh_cn")
        eq(T(rt, "ui.a"), "甲")
        eq(T(rt, "ui.b"), "B")
        eq(T(rt, "ui.c"), "ui.c")
        eq(T(rt, "ui.a", None, "en_us"), "A", "explicit locale")
        eq(T(rt, "ui.a", None, "ZH-CN"), "甲", "explicit locale is canonicalised")
        eq(T(rt, "ui.a", None, "fr_fr"), "A", "explicit missing locale falls back")
        missing = rt.to_python(rt.call("MC.I18n.MissingKeys"))
        eq(missing["zh_cn"], {"ui.b": "base", "ui.c": "key"})
        eq(missing["fr_fr"], {"ui.a": "base"})
        check("en_us" not in missing, "en_us hits record nothing")


def test_missing_keys_are_printed_only_in_debug_mode_and_once():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"a": "A"})
        rt = s.runtime()
        rt.clear_output()
        T(rt, "ui.nope")
        eq([line for line in rt.output() if "missing" in line], [], "quiet by default")
        rt.run('TEST.SetConVar( "mc_i18n_debug", "1" )')
        for _ in range(5):
            T(rt, "ui.nope2")
        eq(len([line for line in rt.output() if "ui.nope2" in line]), 1, "once per key")


def test_named_parameters():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {
            "greet": "Hello {name}, {count} items {unknown}",
            "plain": "No placeholders",
            "percent": "{value} done",
        })
        rt = s.runtime()
        eq(T(rt, "ui.greet", {"name": "Alex", "count": 3}), "Hello Alex, 3 items {unknown}")
        eq(T(rt, "ui.percent", {"value": "100%"}), "100% done", "replacement text is literal")
        eq(T(rt, "ui.plain", {"name": "x"}), "No placeholders")
        eq(T(rt, "ui.greet"), "Hello {name}, {count} items {unknown}", "no vars, no change")
        eq(T(rt, "ui.greet", "oops"), "Hello {name}, {count} items {unknown}")
        check("i18n_vars_not_table" in rt.faults(), "non-table vars are a fault")
        eq(rt.call("MC.T", None), "nil")
        check("i18n_invalid_key" in rt.faults(), "a non-string key is a fault")


def test_positional_parameters():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"durability": "Durability: {1} / {2}", "mixed": "{1} of {name}"})
        rt = s.runtime()
        eq(T(rt, "ui.durability", [12, 250]), "Durability: 12 / 250")
        eq(T(rt, "ui.mixed", {1: "one", "name": "all"}), "one of all")
        eq(T(rt, "ui.durability", {"1": "string key"}), "Durability: string key / {2}")


def test_nested_specs_translate_in_the_same_locale_and_strings_stay_literal():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"item": "{count} x {name}", "stone": "Stone", "wrap": "[{inner}]"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"stone": "石头"})
        rt = s.runtime()
        resolve = "MC.I18n.Resolve"
        eq(rt.call(resolve, "ui.item", {"count": 2, "name": {"key": "ui.stone"}}), "2 x Stone")
        eq(rt.call(resolve, "ui.item", {"count": 2, "name": {"key": "ui.stone"}}, "zh_cn"), "2 x 石头")
        eq(rt.call(resolve, {"key": "ui.item", "vars": {"count": 1, "name": "ui.stone"}}), "1 x ui.stone",
           "a string parameter is literal text, never a key")
        eq(rt.call(resolve, "ui.stone", None, "zh_cn"), "石头")
        spec = {"key": "ui.stone"}
        for _ in range(8):
            spec = {"key": "ui.wrap", "vars": {"inner": spec}}
        eq(rt.call(resolve, spec), "[[[[[?]]]]]", "nesting stops after the depth limit")
        check("i18n_spec_too_deep" in rt.faults(), "deep nesting is reported")
        eq(rt.call(resolve, 42), "?")
        check("i18n_invalid_spec" in rt.faults(), "a bad spec is reported")


def test_translate_count_picks_explicit_variants():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"items.one": "{count} item", "items.other": "{count} items"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"items.other": "{count} 个物品"})
        rt = s.runtime()
        count = "MC.I18n.TranslateCount"
        eq(rt.call(count, "ui.items", 1), "1 item")
        eq(rt.call(count, "ui.items", 0), "0 items")
        eq(rt.call(count, "ui.items", 5), "5 items")
        eq(rt.call(count, "ui.items", 1, None, "zh_cn"), "1 个物品", "a locale with only .other uses it for 1")
        eq(rt.call(count, "ui.items", 3, {"extra": "x"}, "zh_cn"), "3 个物品")
        eq(rt.call(count, "ui.none", 1), "ui.none.one")


# ---------------------------------------------------------------- change notifications

def test_language_changes_notify_callbacks_hooks_and_phrases():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"title": "设置"}, aliases=["zh"])
        rt = s.runtime()
        rt.run("""
            TEST.calls = {}
            MC.I18n.RegisterLanguageChanged( "b_test", function( locale, reason )
                TEST.calls[#TEST.calls + 1] = locale .. ":" .. reason
            end )
            MC.I18n.RegisterLanguageChanged( "a_broken", function() error( "boom" ) end )
            MC.I18n.BindPhrase( "mc.test.title", "ui.title" )
            MC.I18n.BindPhraseProducer( "mc.test.locale", function( locale ) return "L:" .. locale end )
            TEST.events = {}
        """)

        def calls():
            return rt.to_python(rt.eval("TEST.calls"))

        eq(rt.eval('TEST.phrases["mc.test.title"]'), "Settings")
        rt.call("MC.I18n.SetLanguage", "zh_cn")
        eq(calls(), ["zh_cn:setting"])
        eq(rt.eval('TEST.phrases["mc.test.title"]'), "设置", "bound phrase follows the language")
        eq(rt.eval('TEST.phrases["mc.test.locale"]'), "L:zh_cn")
        eq(rt.eval("TEST.events[1][1]"), "MC.LanguageChanged")
        eq(rt.eval("TEST.events[1][2]"), "zh_cn")
        check("i18n_language_callback" in rt.faults(), "a failing callback is reported")
        rt.call("MC.I18n.SetLanguage", "zh_cn")
        eq(len(calls()), 1, "no change, no notification")

        rt.call("MC.I18n.SetLanguage", "auto")
        eq(calls()[-1], "en_us:setting")
        rt.run('TEST.SetConVar( "gmod_language", "zh-CN" )')
        eq(calls()[-1], "zh_cn:game_language", "auto follows a game language change")
        rt.run('TEST.SetConVarSilently( "gmod_language", "en" )')
        rt.run('TEST.timers["mc_i18n_game_language"]()')
        eq(calls()[-1], "en_us:game_language", "the poll catches an unannounced change")
        before = len(calls())
        rt.run('TEST.timers["mc_i18n_game_language"]()')
        eq(len(calls()), before, "the poll is quiet without a change")

        rt.call("MC.I18n.Reload")
        eq(calls()[-1], "en_us:reload", "a reload always notifies")
        rt.call("MC.I18n.UnregisterLanguageChanged", "b_test")
        rt.call("MC.I18n.SetLanguage", "zh_cn")
        eq(calls()[-1], "en_us:reload", "unregistered callbacks stay quiet")


def test_queries_never_touch_files():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"a": "A {x}", "n.one": "{count}", "n.other": "{count}s"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"a": "甲 {x}"})
        rt = s.runtime(language="zh_cn")
        reads, finds = rt.fs.reads, rt.fs.finds
        rt.run("""
            for i = 1, 2000 do
                MC.T( "ui.a", { x = i } )
                MC.T( "ui.missing" )
                MC.T( "ui.a", nil, "en_us" )
                MC.I18n.Resolve( "ui.a", { x = { key = "ui.a" } } )
                MC.I18n.TranslateCount( "ui.n", i )
                MC.I18n.Has( "ui.a" )
                MC.I18n.Language()
                MC.I18n.Locales()
                MC.I18n.LanguageOptions()
            end
        """)
        eq((rt.fs.reads, rt.fs.finds), (reads, finds), "file reads and listings during queries")


# ---------------------------------------------------------------- server realm

def test_server_console_language_is_independent():
    with Scenario() as s:
        s.fragment("addon_a", "ui/en.json", "en_us", {"title": "Settings"})
        s.fragment("addon_a", "ui/zh.json", "zh_cn", {"title": "设置"}, aliases=["zh"])
        rt = s.runtime(realm="server")
        eq(rt.eval('GetConVar( "mc_console_language" ):GetString()'), "en_us", "default")
        eq(rt.call("MC.I18n.ConsoleLanguage"), "en_us")
        rt.run('TEST.SetConVar( "mc_console_language", "zh_cn" )')
        eq(rt.call("MC.I18n.ConsoleLanguage"), "zh_cn")
        eq(rt.call("MC.I18n.TranslateConsole", "ui.title"), "设置")
        eq(rt.call("MC.I18n.SetLanguage", "en_us"), (None, "client_only"))
        rt.run("""
            local function player( info )
                local ply = { valid = true, info = info }
                function ply:GetInfo( name ) return self.info[name] or "" end
                return ply
            end
            TEST.zhPlayer = player( { mc_language = "auto", gmod_language = "zh-CN" } )
            TEST.enPlayer = player( { mc_language = "en_us", gmod_language = "zh-CN" } )
            TEST.oddPlayer = player( { mc_language = "x y", gmod_language = "fr" } )
        """)
        eq(rt.eval("MC.I18n.LanguageForPlayer( TEST.zhPlayer )"), "zh_cn")
        eq(rt.eval("MC.I18n.LanguageForPlayer( TEST.enPlayer )"), "en_us")
        eq(rt.eval("MC.I18n.LanguageForPlayer( TEST.oddPlayer )"), "en_us")
        eq(rt.call("MC.I18n.ConsoleLanguage"), "zh_cn", "players do not change the console language")
        rt.run('TEST.SetConVar( "mc_console_language", "auto" )')
        eq(rt.call("MC.I18n.ConsoleLanguage"), "en_us", "auto on the server means en_us")


# ---------------------------------------------------------------- repository resources

def repo_entries():
    """{ locale: { final key: source } } read straight from the repository files."""
    result = {}
    for addon in lua_runtime.repo_game_roots():
        root = addon / "data_static" / "mc" / "i18n"
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*.json")):
            document = json.loads(path.read_text(encoding="utf-8-sig"))
            namespace = ".".join(path.relative_to(root).parent.parts)
            bucket = result.setdefault(document["locale"], {})
            for key in document["entries"]:
                bucket[namespace + "." + key if namespace else key] = str(path)
    return result


def test_repository_fragments_load_cleanly():
    for realm in ("client", "server"):
        rt = Runtime(VirtualFS(lua_runtime.repo_game_roots()), realm, "en").load_i18n()
        report = rt.report()
        eq(report["errors"], [], "%s errors" % realm)
        eq(report["conflicts"], [], "%s duplicates" % realm)
        eq(report["aliasConflicts"], [], "%s alias conflicts" % realm)
        check({"en_us", "zh_cn"} <= set(report["locales"]), "%s locales %r" % (realm, report["locales"]))
    entries = repo_entries()
    en, zh = set(entries["en_us"]), set(entries["zh_cn"])
    eq(sorted(zh - en), [], "zh_cn keys without an en_us original")
    # A language without a singular form only provides <key>.other.
    untranslated = sorted(key for key in en - zh
                          if not (key.endswith(".one") and key[:-4] + ".other" in zh))
    eq(untranslated, [], "en_us keys without a zh_cn translation")


if __name__ == "__main__":
    sys.exit(lua_runtime.run_tests(dict(globals()), sys.argv[1:]))
