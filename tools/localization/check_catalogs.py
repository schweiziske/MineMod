"""Check packaged localization files without loading Lua or installing dependencies."""

import argparse
import json
import re
from pathlib import Path

KEY = re.compile(r"[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\Z")
LOCALE = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)*\Z")
PARAMETER = re.compile(r"\{([A-Za-z0-9_]+)\}")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def inspect(roots):
    catalogs, sources, aliases = {}, {}, {}
    report = {"files": [], "errors": [], "conflicts": [], "aliasConflicts": [],
              "nativeNameConflicts": [], "nativeNames": {},
              "missing": {}, "placeholders": [], "coverage": {}}
    # A root represents a mounted virtual tree. Preserve root order for overrides.
    for roots_in_layer in roots:
        files = sorted((p.relative_to(root).as_posix(), p, root)
                       for root in roots_in_layer for p in root.rglob("*.json"))
        if len(files) > 4096:
            report["errors"].append("catalog layer exceeds 4096 files")
        seen = set()
        for relative, path, root in files:
            source = str(path)
            if relative in seen:
                report["errors"].append(f"virtual path collision: {relative}")
            seen.add(relative)
            try:
                parts = Path(relative).parts
                if (len(parts) > 9 or len(relative.encode()) > 240
                        or not re.fullmatch(r"[a-z0-9_.-]+\.json", parts[-1])
                        or any(not re.fullmatch(r"[a-z0-9_-]+", part) for part in parts[:-1])):
                    raise ValueError("invalid catalog path")
                raw = path.read_bytes()
                if len(raw) > 1048576:
                    raise ValueError("file exceeds 1 MiB")
                data = json.loads(raw.decode("utf-8-sig"), object_pairs_hook=unique_object)
                if not isinstance(data, dict) or set(data) - {"locale", "nativeName", "aliases", "entries"}:
                    raise ValueError("invalid catalog fields")
                locale = data.get("locale")
                if not isinstance(locale, str):
                    raise ValueError("locale must be a string")
                locale = locale.lower().replace("-", "_")
                if len(locale) > 32 or not LOCALE.fullmatch(locale):
                    raise ValueError("invalid locale")
                native_name = data.get("nativeName")
                if "nativeName" in data:
                    if (not isinstance(native_name, str) or not native_name.strip(" \t\r\n\v\f")
                            or len(native_name.encode()) > 128 or re.search(r"[\x00-\x1f\x7f]", native_name)):
                        raise ValueError("nativeName must be nonblank text without control characters, at most 128 bytes")
                entries = data.get("entries")
                if not isinstance(entries, dict) or len(entries) > 10000:
                    raise ValueError("entries must be an object with at most 10000 members")
                prefix = ".".join(Path(relative).parts[:-1])
                checked = {}
                for local_key, text in entries.items():
                    key = f"{prefix}.{local_key}" if prefix else local_key
                    if len(key.encode()) > 200 or not KEY.fullmatch(key):
                        raise ValueError(f"invalid key: {key}")
                    if not isinstance(text, str) or len(text.encode()) > 8192:
                        raise ValueError(f"invalid translation: {key}")
                    checked[key] = text
                declared = data.get("aliases", [])
                if not isinstance(declared, list) or len(declared) > 16:
                    raise ValueError("invalid aliases")
                for alias in declared:
                    if (not isinstance(alias, str) or len(alias) > 32
                            or not LOCALE.fullmatch(alias.lower().replace("-", "_"))):
                        raise ValueError("invalid alias")
            except (ValueError, OSError, UnicodeError) as error:
                report["errors"].append(f"{source}: {error}")
                continue
            dictionary = catalogs.setdefault(locale, {})
            origins = sources.setdefault(locale, {})
            for key, text in checked.items():
                if key in dictionary:
                    report["conflicts"].append({"locale": locale, "key": key,
                                                "previous": origins[key], "winner": source})
                dictionary[key], origins[key] = text, source
            for alias in declared:
                alias = alias.lower().replace("-", "_")
                if alias in aliases and aliases[alias] != locale:
                    report["aliasConflicts"].append({"alias": alias, "previous": aliases[alias], "winner": locale})
                aliases[alias] = locale
            if native_name is not None:
                previous = report["nativeNames"].get(locale)
                if previous and previous["nativeName"] != native_name:
                    report["nativeNameConflicts"].append({
                        "locale": locale, "previous": previous["nativeName"], "previousSource": previous["source"],
                        "current": native_name, "source": source})
                report["nativeNames"][locale] = {"nativeName": native_name, "source": source}
            report["files"].append({"source": source, "locale": locale, "entries": len(checked)})
    base = catalogs.get("en_us", {})
    if not base:
        report["errors"].append("No en_us catalog was loaded")
    for locale, dictionary in sorted(catalogs.items()):
        missing = [key for key in base if key not in dictionary
                   and not (key.endswith(".one") and key[:-4] + ".other" in dictionary)]
        report["missing"][locale] = sorted(missing)
        report["coverage"][locale] = {"base": len(base), "translated": len(base) - len(missing)}
        for key in sorted(dictionary.keys() & base.keys()):
            expected, actual = set(PARAMETER.findall(base[key])), set(PARAMETER.findall(dictionary[key]))
            if expected != actual:
                report["placeholders"].append({"locale": locale, "key": key, "source": sources[locale][key],
                                               "expected": sorted(expected), "actual": sorted(actual)})
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--addons", type=Path, default=Path(__file__).resolve().parents[2] / "addons")
    parser.add_argument("--overrides", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    roots = [sorted(args.addons.glob("*/data_static/mc/i18n"))]
    if args.overrides:
        roots.append([args.overrides])
    report = inspect(roots)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(report['files'])} files; {len(report['errors'])} errors; "
          f"{len(report['conflicts'])} key conflicts; {len(report['nativeNameConflicts'])} language name conflicts; "
          f"{len(report['placeholders'])} placeholder mismatches")
    for locale, coverage in report["coverage"].items():
        print(f"{locale}: {coverage['translated']}/{coverage['base']} base entries")
        for key in report["missing"][locale][:10]:
            print(f"  missing: {key}")
    for error in report["errors"][:10]:
        print(error)
    for mismatch in report["placeholders"][:10]:
        print(f"{mismatch['locale']} {mismatch['key']}: {mismatch['expected']} != {mismatch['actual']}")
    for conflict in report["nativeNameConflicts"][:10]:
        print(f"{conflict['locale']} nativeName: {conflict['previous']} ({conflict['previousSource']})"
              f" -> {conflict['current']} ({conflict['source']})")
    # Conflicting catalogs are legal; their winning sources stay visible in the report.
    return int(bool(report["errors"] or report["placeholders"] or any(report["missing"].values())))


if __name__ == "__main__":
    raise SystemExit(main())
