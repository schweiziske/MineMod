"""Copy Minecraft's own translations into the dictionaries of the addons that
own the content.

    python tools/localization/generate_minecraft_lang.py --lang-dir <dir> [--check]

<dir> is assets/minecraft/lang of an extracted Minecraft client: every
<locale>.json in it (deprecated.json excepted) becomes one fragment per owner,

    addons/<addon>/data_static/mc/i18n/<addon>.minecraft.<locale>.json

holding the full Minecraft keys that the OWNERS table assigns to that addon.
Java format specifiers become MineMod placeholders: %s and %n$s turn into {n}
(the n-th positional parameter), %% into %. Any other % sequence stops the run.

--check writes nothing and exits 1 when a fragment is missing, stale or left
over from a locale that is no longer in <dir>.
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SUFFIX = ".minecraft."

# addon -> predicate over Minecraft keys. Ownership follows the content
# definition: the game layer owns the vanilla creative tabs.
OWNERS = {
    "mc_game": lambda key: key.startswith("itemGroup."),
}

SPECIFIER = re.compile(r"%(?:(\d+)\$)?([sd])|%%|%")


def convert(key, text):
    """Java format string -> MineMod template; raises on unknown specifiers."""
    counter = 0

    def replace(match):
        nonlocal counter
        whole = match.group(0)
        if whole == "%%":
            return "%"
        if match.group(2) is None:
            raise ValueError("unsupported format specifier in %s: %r" % (key, text))
        if match.group(1):
            return "{%d}" % int(match.group(1))
        counter += 1
        return "{%d}" % counter

    return SPECIFIER.sub(replace, text)


def load_locales(lang_dir):
    locales = {}
    for path in sorted(lang_dir.glob("*.json")):
        if path.name == "deprecated.json":
            continue
        locale = path.stem.lower().replace("-", "_")
        if not re.fullmatch(r"[a-z0-9]+(?:_[a-z0-9]+)*", locale):
            raise SystemExit("not a locale file name: %s" % path)
        document = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(document, dict) or not all(isinstance(v, str) for v in document.values()):
            raise SystemExit("not a flat string map: %s" % path)
        locales[locale] = document
    if "en_us" not in locales:
        raise SystemExit("en_us.json is required in %s" % lang_dir)
    return locales


def render(locale, entries):
    document = {"locale": locale, "entries": dict(sorted(entries.items()))}
    return json.dumps(document, ensure_ascii=False, indent=2) + "\n"


def i18n_root(addon):
    return REPO / "addons" / addon / "data_static" / "mc" / "i18n"


def build(locales):
    """{ path: text } for every fragment the current lang files produce."""
    outputs = {}
    for addon, owns in OWNERS.items():
        for locale, document in locales.items():
            entries = {key: convert(key, text) for key, text in document.items() if owns(key)}
            if entries:
                path = i18n_root(addon) / ("%s%s%s.json" % (addon, SUFFIX, locale))
                outputs[path] = render(locale, entries)
    return outputs


def existing_fragments():
    found = set()
    for addon in OWNERS:
        root = i18n_root(addon)
        if root.is_dir():
            found.update(root.glob("%s%s*.json" % (addon, SUFFIX)))
    return found


def normalized(path):
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--lang-dir", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    outputs = build(load_locales(args.lang_dir))
    stale = sorted(existing_fragments() - set(outputs))
    differing = sorted(path for path, text in outputs.items()
                       if not path.is_file() or normalized(path) != text)
    if args.check:
        for path in differing:
            print("out of date:", path.relative_to(REPO))
        for path in stale:
            print("no longer generated:", path.relative_to(REPO))
        print("%d fragment(s) checked, %d out of date, %d stale" % (len(outputs), len(differing), len(stale)))
        return 1 if differing or stale else 0
    for path in differing:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(outputs[path])
        print("wrote", path.relative_to(REPO))
    for path in stale:
        path.unlink()
        print("removed", path.relative_to(REPO))
    print("%d fragment(s), %d written, %d removed" % (len(outputs), len(differing), len(stale)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
