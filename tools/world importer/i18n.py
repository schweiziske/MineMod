"""Small JSON-backed localization helper with no third-party dependencies."""

from __future__ import annotations

import json
import pathlib
from typing import Any


class Localization:
    def __init__(self, locale_dir: pathlib.Path, preferred: str = "") -> None:
        self.locale_dir = locale_dir
        self.languages: dict[str, str] = {}
        self.catalog: dict[str, str] = {}
        self.language = ""
        self._discover()
        fallback = "zh_CN" if preferred.lower().startswith("zh") else "en_US"
        self.set_language(preferred if preferred in self.languages else fallback)

    def _discover(self) -> None:
        for path in sorted(self.locale_dir.glob("*.json")):
            try:
                data = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                continue
            code = str(data.get("_code") or path.stem)
            name = str(data.get("_name") or code)
            self.languages[code] = name
        if "en_US" not in self.languages:
            self.languages["en_US"] = "English"
        if "zh_CN" not in self.languages:
            self.languages["zh_CN"] = "简体中文"

    def set_language(self, code: str) -> None:
        if code not in self.languages:
            code = "zh_CN" if "zh_CN" in self.languages else "en_US"
        data = json.loads(
            (self.locale_dir / f"{code}.json").read_text(encoding="utf-8")
        )
        self.catalog = {
            key: str(value)
            for key, value in data.items()
            if not key.startswith("_") and isinstance(value, str)
        }
        self.language = code

    def text(self, key: str, **values: Any) -> str:
        template = self.catalog.get(key, key)
        try:
            return template.format(**values)
        except (KeyError, ValueError):
            return template

    def error_text(self, error: Exception) -> str:
        code = getattr(error, "code", "unexpected")
        values = dict(getattr(error, "values", {}) or {})
        for key, value in tuple(values.items()):
            if isinstance(value, str) and value.startswith(("field.", "unit.")):
                values[key] = self.text(value)
        return self.text(f"error.{code}", **values)
