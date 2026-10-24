#!/usr/bin/env python3
"""Simple localized Tkinter desktop UI for the standalone world importer."""

from __future__ import annotations

import json
import locale
import os
import pathlib
import queue
import re
import subprocess
import sys
import threading
import time
import tkinter as tk
import tkinter.font as tkfont
from tkinter import filedialog, messagebox, ttk
from typing import Any

from i18n import Localization
from ui_model import (
    DEFAULT_DATA_DIR,
    FORM_DEFAULTS,
    FormError,
    FormState,
    ImportPlan,
    TOOL_ROOT,
    build_plan,
    inspect_world,
    supported_data_version_ranges,
)


SETTINGS_PATH = TOOL_ROOT / "settings.json"
LOCALE_DIR = TOOL_ROOT / "locales"
SAVE_FORMAT_KEYS = {
    "auto": "save_format.auto",
    "classic": "save_format.classic",
    "chunked": "save_format.chunked",
    "streaming": "save_format.streaming",
}
SETTINGS_VERSION = 2


def detect_language() -> str:
    if os.name == "nt":
        try:
            import ctypes

            language_id = ctypes.windll.kernel32.GetUserDefaultUILanguage()
            if language_id & 0x3FF == 0x04:
                return "zh_CN"
        except (AttributeError, OSError):
            pass
    try:
        language = locale.getlocale()[0] or ""
    except ValueError:
        language = ""
    return "zh_CN" if language.lower().startswith("zh") else "en_US"


def load_settings() -> dict[str, Any]:
    try:
        value = json.loads(SETTINGS_PATH.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def save_settings(value: dict[str, Any]) -> None:
    try:
        temporary = SETTINGS_PATH.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        temporary.replace(SETTINGS_PATH)
    except OSError:
        pass


def set_windows_dpi_awareness() -> None:
    if os.name != "nt":
        return
    try:
        import ctypes

        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        pass


class ImportRunner:
    def __init__(self, command: list[str]) -> None:
        self.command = command
        self.events: queue.Queue[dict[str, Any]] = queue.Queue()
        self.process: subprocess.Popen[str] | None = None
        self.cancel_requested = False
        self.lock = threading.Lock()

    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True).start()

    def cancel(self) -> None:
        with self.lock:
            self.cancel_requested = True
            process = self.process
        if process is not None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass

    def _run(self) -> None:
        creation_flags = (
            subprocess.CREATE_NO_WINDOW
            if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW")
            else 0
        )
        environment = dict(os.environ)
        environment["PYTHONUTF8"] = "1"
        try:
            process = subprocess.Popen(
                self.command,
                cwd=TOOL_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                bufsize=1,
                env=environment,
                creationflags=creation_flags,
            )
        except OSError as exc:
            self.events.put({"type": "start_error", "message": str(exc)})
            return
        with self.lock:
            self.process = process
            cancel_requested = self.cancel_requested
        if cancel_requested:
            process.terminate()
        self.events.put({"type": "started"})
        assert process.stdout is not None
        try:
            for line in process.stdout:
                self.events.put({"type": "log", "text": line.rstrip("\r\n")})
            return_code = process.wait()
            self.events.put(
                {
                    "type": "finished",
                    "code": return_code,
                    "cancelled": self.cancel_requested,
                }
            )
        finally:
            with self.lock:
                self.process = None


class AdvancedDialog(tk.Toplevel):
    FIELDS = (
        "origin_x",
        "origin_y",
        "origin_z",
        "max_blocks",
        "data_versions",
        "save_map",
        "block_size",
        "part_size",
    )
    CHECKS = (
        "auto_data_version",
        "keep_coords",
        "allow_mixed",
        "skip_nbt",
        "replace_invalid_nbt",
    )

    def __init__(
        self, parent: "ImporterApp", state: FormState, i18n: Localization
    ) -> None:
        super().__init__(parent)
        self.parent = parent
        self.i18n = i18n
        self.result: dict[str, Any] | None = None
        self.text_vars: dict[str, tk.StringVar] = {}
        self.vars = {
            key: tk.StringVar(value=str(state.get(key))) for key in self.FIELDS
        }
        self.vars.update(
            {
                key: tk.BooleanVar(value=bool(state.get(key)))
                for key in self.CHECKS
            }
        )
        self.title(self.t("advanced.title"))
        self.transient(parent)
        self.resizable(False, False)
        self.protocol("WM_DELETE_WINDOW", self.destroy)
        self.bind("<Escape>", lambda _event: self.destroy())
        self._build()
        self.update_idletasks()
        self._center_on_parent()
        self.grab_set()
        self.focus_set()

    def t(self, key: str, **values: Any) -> str:
        return self.i18n.text(key, **values)

    def text_var(self, key: str) -> tk.StringVar:
        if key not in self.text_vars:
            self.text_vars[key] = tk.StringVar(value=self.t(key))
        return self.text_vars[key]

    def _center_on_parent(self) -> None:
        width = max(620, self.winfo_reqwidth())
        height = max(520, self.winfo_reqheight())
        x = self.parent.winfo_rootx() + (self.parent.winfo_width() - width) // 2
        y = self.parent.winfo_rooty() + (self.parent.winfo_height() - height) // 2
        self.geometry(f"{width}x{height}+{max(0, x)}+{max(0, y)}")

    def _build(self) -> None:
        outer = ttk.Frame(self, padding=(22, 18))
        outer.pack(fill="both", expand=True)
        ttk.Label(
            outer, textvariable=self.text_var("advanced.title"), style="SectionTitle.TLabel"
        ).pack(anchor="w")
        ttk.Label(
            outer,
            textvariable=self.text_var("advanced.description"),
            style="Muted.TLabel",
            wraplength=560,
        ).pack(anchor="w", pady=(3, 15))

        form = ttk.Frame(outer)
        form.pack(fill="both", expand=True)
        form.columnconfigure(1, weight=1)

        row = 0
        ttk.Label(
            form, textvariable=self.text_var("field.origin")
        ).grid(row=row, column=0, sticky="w", padx=(0, 14), pady=5)
        origin_box = ttk.Frame(form)
        origin_box.grid(row=row, column=1, sticky="w", pady=5)
        for index, (key, unit) in enumerate(
            (
                ("origin_x", "unit.x"),
                ("origin_y", "unit.y"),
                ("origin_z", "unit.z"),
            )
        ):
            ttk.Label(origin_box, textvariable=self.text_var(unit)).grid(
                row=0, column=index * 2, padx=(0 if index == 0 else 12, 4)
            )
            ttk.Entry(origin_box, textvariable=self.vars[key], width=10).grid(
                row=0, column=index * 2 + 1
            )

        entries = (
            ("field.max_blocks", "max_blocks"),
            ("field.data_versions", "data_versions"),
            ("field.save_map", "save_map"),
            ("field.block_size", "block_size"),
            ("field.part_size", "part_size"),
        )
        for label_key, key in entries:
            row += 1
            ttk.Label(form, textvariable=self.text_var(label_key)).grid(
                row=row, column=0, sticky="w", padx=(0, 14), pady=5
            )
            ttk.Entry(form, textvariable=self.vars[key]).grid(
                row=row, column=1, sticky="ew", pady=5
            )

        checks = ttk.Frame(outer)
        checks.pack(fill="x", pady=(12, 0))
        for key in self.CHECKS:
            ttk.Checkbutton(
                checks,
                textvariable=self.text_var(f"field.{key}"),
                variable=self.vars[key],
            ).pack(anchor="w", pady=2)

        actions = ttk.Frame(outer)
        actions.pack(fill="x", side="bottom", pady=(18, 0))
        ttk.Button(
            actions,
            textvariable=self.text_var("buttons.reset"),
            command=self._reset,
        ).pack(side="left")
        ttk.Button(
            actions,
            textvariable=self.text_var("buttons.close"),
            command=self.destroy,
        ).pack(side="right")
        ttk.Button(
            actions,
            textvariable=self.text_var("buttons.apply"),
            style="Accent.TButton",
            command=self._apply,
        ).pack(side="right", padx=(0, 8))

    def _reset(self) -> None:
        for key in self.FIELDS:
            self.vars[key].set(str(FORM_DEFAULTS[key]))
        for key in self.CHECKS:
            self.vars[key].set(bool(FORM_DEFAULTS[key]))

    def _apply(self) -> None:
        self.result = {
            **{key: self.vars[key].get() for key in self.FIELDS},
            **{key: bool(self.vars[key].get()) for key in self.CHECKS},
        }
        self.destroy()


class ImporterApp(tk.Tk):
    def __init__(self) -> None:
        set_windows_dpi_awareness()
        self.settings = load_settings()
        preferred = str(
            self.settings.get("language") or detect_language()
        )
        self.i18n = Localization(LOCALE_DIR, preferred)
        saved_form = self.settings.get("form")
        self.state = FormState(saved_form if isinstance(saved_form, dict) else None)
        try:
            saved_settings_version = int(self.settings.get("version") or 1)
        except (TypeError, ValueError):
            saved_settings_version = 1
        if saved_settings_version < SETTINGS_VERSION:
            self.state.set("skip_nbt", True)
        super().__init__()

        self.title(self.t("app.title"))
        self.configure(background="#edf1f2")
        self.minsize(760, 700)
        self.geometry("840x780")
        self._center_window()
        self.protocol("WM_DELETE_WINDOW", self._on_close)

        self.text_vars: dict[str, tk.StringVar] = {}
        self.field_vars: dict[str, tk.Variable] = {}
        self.input_widgets: list[tk.Widget] = []
        self.plan: ImportPlan | None = None
        self.runner: ImportRunner | None = None
        self.job_state = "idle"
        self.log_has_content = False
        self._save_after_id: str | None = None
        self._refresh_after_id: str | None = None
        self._poll_after_id: str | None = None
        self._elapsed_after_id: str | None = None
        self._run_started: float | None = None
        self.last_run_log = ""
        self.diagnostic_key: str | None = None
        self.diagnostic_values: dict[str, Any] = {}
        self._save_format_display_to_code: dict[str, str] = {}
        self._language_name_to_code: dict[str, str] = {}
        self._close_after_cancel = False

        self._build_style()
        self._build_ui()
        self._initialize_variables()
        self._apply_language()
        self._sync_mode_frames()
        self._set_job_state("idle")
        self.after(180, self._refresh_plan)

    def t(self, key: str, **values: Any) -> str:
        return self.i18n.text(key, **values)

    def text_var(self, key: str) -> tk.StringVar:
        if key not in self.text_vars:
            self.text_vars[key] = tk.StringVar(value=self.t(key))
        return self.text_vars[key]

    def _center_window(self) -> None:
        self.update_idletasks()
        width = min(840, self.winfo_screenwidth() - 60)
        height = min(780, self.winfo_screenheight() - 80)
        x = max(0, (self.winfo_screenwidth() - width) // 2)
        y = max(0, (self.winfo_screenheight() - height) // 2)
        self.geometry(f"{width}x{height}+{x}+{y}")

    def _font_family(self) -> str:
        available = set(tkfont.families(self))
        for name in (
            "Microsoft YaHei UI",
            "Segoe UI Variable",
            "Segoe UI",
            "Noto Sans CJK SC",
            "DejaVu Sans",
        ):
            if name in available:
                return name
        return "TkDefaultFont"

    def _build_style(self) -> None:
        family = self._font_family()
        for name in ("TkDefaultFont", "TkTextFont", "TkMenuFont", "TkHeadingFont"):
            tkfont.nametofont(name).configure(family=family, size=10)
        tkfont.nametofont("TkFixedFont").configure(
            family="Cascadia Mono" if "Cascadia Mono" in set(tkfont.families(self)) else "Consolas",
            size=9,
        )
        style = ttk.Style(self)
        style.theme_use("clam")
        style.configure(".", font=(family, 10), background="#edf1f2", foreground="#1d2d35")
        style.configure("TFrame", background="#edf1f2")
        style.configure("Surface.TFrame", background="#ffffff")
        style.configure("TLabel", background="#ffffff", foreground="#24353d")
        style.configure("Muted.TLabel", background="#ffffff", foreground="#687980")
        style.configure(
            "Title.TLabel", background="#ffffff", foreground="#17262e", font=(family, 16, "bold")
        )
        style.configure(
            "Subtitle.TLabel", background="#ffffff", foreground="#687980", font=(family, 9)
        )
        style.configure(
            "SectionTitle.TLabel",
            background="#ffffff",
            foreground="#263941",
            font=(family, 10, "bold"),
        )
        style.configure(
            "Success.TLabel", background="#ffffff", foreground="#27784b"
        )
        style.configure(
            "Error.TLabel", background="#ffffff", foreground="#ae3c3c"
        )
        style.configure(
            "Job.TLabel", background="#ffffff", foreground="#42555d", font=(family, 10, "bold")
        )
        style.configure(
            "Path.TLabel", background="#ffffff", foreground="#5f7178", font=(family, 9)
        )
        style.configure("TEntry", fieldbackground="#fbfcfc", padding=5)
        style.configure("TCombobox", fieldbackground="#fbfcfc", padding=4)
        style.configure("TButton", padding=(11, 6))
        style.configure(
            "Accent.TButton",
            background="#087b74",
            foreground="#ffffff",
            padding=(16, 7),
            font=(family, 10, "bold"),
        )
        style.map(
            "Accent.TButton",
            background=[("active", "#06645f"), ("disabled", "#9bbdb9")],
            foreground=[("disabled", "#edf3f2")],
        )
        style.configure("Stop.TButton", foreground="#8f3434", padding=(12, 7))
        style.configure("TRadiobutton", background="#ffffff", padding=(3, 3))
        style.configure("TSeparator", background="#dce4e6")
        style.configure("TProgressbar", background="#087b74", troughcolor="#dde5e7")

    def _build_ui(self) -> None:
        outer = ttk.Frame(self, style="Surface.TFrame", padding=(20, 15))
        outer.pack(fill="both", expand=True)

        header = ttk.Frame(outer, style="Surface.TFrame")
        header.pack(fill="x", pady=(0, 11))
        title_box = ttk.Frame(header, style="Surface.TFrame")
        title_box.pack(side="left", fill="x", expand=True)
        ttk.Label(
            title_box, textvariable=self.text_var("app.title"), style="Title.TLabel"
        ).pack(anchor="w")
        self.subtitle_label = ttk.Label(
            title_box, textvariable=self.text_var("app.subtitle"), style="Subtitle.TLabel"
        )
        self.subtitle_label.pack(anchor="w", pady=(1, 0))

        language_box = ttk.Frame(header, style="Surface.TFrame")
        language_box.pack(side="right", padx=(18, 0))
        ttk.Label(
            language_box,
            textvariable=self.text_var("app.language"),
            style="Muted.TLabel",
        ).pack(side="left", padx=(0, 7))
        self.language_combo = ttk.Combobox(
            language_box, state="readonly", width=12
        )
        self.language_combo.pack(side="left")
        self.language_combo.bind("<<ComboboxSelected>>", self._on_language_selected)

        ttk.Separator(outer).pack(fill="x")
        self.notebook = ttk.Notebook(outer)
        self.notebook.pack(fill="both", expand=True, pady=(9, 0))
        self.setup_tab = ttk.Frame(
            self.notebook, style="Surface.TFrame", padding=(6, 4, 6, 8)
        )
        self.activity_tab = ttk.Frame(
            self.notebook, style="Surface.TFrame", padding=(6, 8, 6, 8)
        )
        self.notebook.add(self.setup_tab)
        self.notebook.add(self.activity_tab)
        self.setup_tab.columnconfigure(0, weight=1)
        self.setup_tab.rowconfigure(0, weight=1)

        scroll_host = ttk.Frame(self.setup_tab, style="Surface.TFrame")
        scroll_host.grid(row=0, column=0, sticky="nsew")
        scroll_host.columnconfigure(0, weight=1)
        scroll_host.rowconfigure(0, weight=1)
        self.setup_canvas = tk.Canvas(
            scroll_host,
            background="#ffffff",
            borderwidth=0,
            highlightthickness=0,
        )
        setup_scrollbar = ttk.Scrollbar(
            scroll_host, orient="vertical", command=self.setup_canvas.yview
        )
        self.setup_canvas.configure(yscrollcommand=setup_scrollbar.set)
        self.setup_canvas.grid(row=0, column=0, sticky="nsew")
        setup_scrollbar.grid(row=0, column=1, sticky="ns", padx=(5, 0))
        self.setup_form = ttk.Frame(
            self.setup_canvas, style="Surface.TFrame", padding=(0, 0, 4, 4)
        )
        self.setup_window = self.setup_canvas.create_window(
            (0, 0), window=self.setup_form, anchor="nw"
        )
        self.setup_form.bind("<Configure>", self._update_setup_scroll_region)
        self.setup_canvas.bind("<Configure>", self._resize_setup_form)
        self.bind_all("<MouseWheel>", self._on_setup_mousewheel, add="+")

        self._build_source_section(self.setup_form)
        self._build_range_section(self.setup_form)
        self._build_output_section(self.setup_form)
        action_host = ttk.Frame(self.setup_tab, style="Surface.TFrame")
        action_host.grid(row=1, column=0, sticky="ew", pady=(7, 0))
        self._build_actions(action_host)
        self._build_activity_section(self.activity_tab)

    def _update_setup_scroll_region(self, _event: tk.Event[Any] | None = None) -> None:
        self.setup_canvas.configure(scrollregion=self.setup_canvas.bbox("all"))

    def _resize_setup_form(self, event: tk.Event[Any]) -> None:
        self.setup_canvas.itemconfigure(self.setup_window, width=event.width)

    def _on_setup_mousewheel(self, event: tk.Event[Any]) -> str | None:
        if self.notebook.select() != str(self.setup_tab):
            return None
        widget = self.winfo_containing(self.winfo_pointerx(), self.winfo_pointery())
        current = widget
        while current is not None:
            if current == self.setup_canvas:
                delta = -1 if event.delta > 0 else 1
                self.setup_canvas.yview_scroll(delta * 3, "units")
                return "break"
            current = current.master if hasattr(current, "master") else None
        return None

    def _section(self, parent: ttk.Frame, key: str) -> ttk.Frame:
        frame = ttk.Frame(parent, style="Surface.TFrame")
        frame.pack(fill="x", pady=(10, 0))
        ttk.Label(
            frame, textvariable=self.text_var(key), style="SectionTitle.TLabel"
        ).pack(anchor="w", pady=(0, 7))
        body = ttk.Frame(frame, style="Surface.TFrame")
        body.pack(fill="x")
        return body

    def _build_source_section(self, parent: ttk.Frame) -> None:
        body = self._section(parent, "section.source")
        body.columnconfigure(1, weight=1)
        ttk.Label(
            body,
            textvariable=self.text_var("field.world"),
            width=18,
        ).grid(row=0, column=0, sticky="w", padx=(0, 10))
        self.world_entry = ttk.Entry(body, textvariable=self._make_var("world"))
        self.world_entry.grid(row=0, column=1, sticky="ew")
        self.world_browse = ttk.Button(
            body,
            textvariable=self.text_var("buttons.browse"),
            command=self._browse_world,
        )
        self.world_browse.grid(row=0, column=2, padx=(7, 0))
        self.input_widgets.extend((self.world_entry, self.world_browse))

        self.world_status = ttk.Label(
            body,
            textvariable=self.text_var("status.world_empty"),
            style="Muted.TLabel",
            wraplength=540,
            justify="left",
        )
        self.world_status.grid(
            row=1, column=1, columnspan=2, sticky="w", pady=(3, 5)
        )

        ttk.Label(
            body, textvariable=self.text_var("field.dimension"), width=18
        ).grid(row=2, column=0, sticky="w", padx=(0, 10))
        dimension_box = ttk.Frame(body, style="Surface.TFrame")
        dimension_box.grid(row=2, column=1, columnspan=2, sticky="w")
        for value in ("overworld", "the_nether", "the_end"):
            radio = ttk.Radiobutton(
                dimension_box,
                textvariable=self.text_var(f"dimension.{value}"),
                value=value,
                variable=self._make_var("dimension"),
            )
            radio.pack(side="left", padx=(0, 16))
            self.input_widgets.append(radio)

    def _build_range_section(self, parent: ttk.Frame) -> None:
        body = self._section(parent, "section.range")
        mode_box = ttk.Frame(body, style="Surface.TFrame")
        mode_box.grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Label(
            mode_box, textvariable=self.text_var("field.range_mode"), width=18
        ).pack(side="left", padx=(0, 10))
        for value in ("chunk", "block"):
            radio = ttk.Radiobutton(
                mode_box,
                textvariable=self.text_var(f"mode.{value}"),
                value=value,
                variable=self._make_var("range_mode"),
            )
            radio.pack(side="left", padx=(0, 16))
            self.input_widgets.append(radio)

        self.chunk_frame = ttk.Frame(body, style="Surface.TFrame")
        self.chunk_frame.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(8, 0))
        self.chunk_frame.columnconfigure(2, weight=1)
        self._coordinate_row(
            self.chunk_frame,
            0,
            "field.from_chunk",
            (("from_chunk_x", "unit.cx"), ("from_chunk_z", "unit.cz")),
        )
        self._coordinate_row(
            self.chunk_frame,
            1,
            "field.to_chunk",
            (("to_chunk_x", "unit.cx"), ("to_chunk_z", "unit.cz")),
        )
        self._coordinate_row(
            self.chunk_frame,
            2,
            "field.y_range",
            (("y_min", "unit.min_y"), ("y_max", "unit.max_y")),
        )

        self.block_frame = ttk.Frame(body, style="Surface.TFrame")
        self.block_frame.grid(row=1, column=0, columnspan=3, sticky="ew", pady=(8, 0))
        self.block_frame.columnconfigure(4, weight=1)
        self._coordinate_row(
            self.block_frame,
            0,
            "field.from_block",
            (("from_x", "unit.x"), ("from_y", "unit.y"), ("from_z", "unit.z")),
        )
        self._coordinate_row(
            self.block_frame,
            1,
            "field.to_block",
            (("to_x", "unit.x"), ("to_y", "unit.y"), ("to_z", "unit.z")),
        )

    def _coordinate_row(
        self,
        parent: ttk.Frame,
        row: int,
        label_key: str,
        fields: tuple[tuple[str, str], ...],
    ) -> None:
        ttk.Label(
            parent, textvariable=self.text_var(label_key), width=18
        ).grid(row=row, column=0, sticky="w", padx=(0, 10), pady=2)
        column = 1
        for key, unit_key in fields:
            ttk.Label(
                parent, textvariable=self.text_var(unit_key), style="Muted.TLabel"
            ).grid(row=row, column=column, sticky="e", padx=(0, 3), pady=2)
            entry = ttk.Entry(parent, textvariable=self._make_var(key), width=9)
            entry.grid(row=row, column=column + 1, sticky="ew", padx=(0, 10), pady=2)
            self.input_widgets.append(entry)
            column += 2

    def _build_output_section(self, parent: ttk.Frame) -> None:
        body = self._section(parent, "section.output")
        body.columnconfigure(1, weight=1)
        mode_box = ttk.Frame(body, style="Surface.TFrame")
        mode_box.grid(row=0, column=0, columnspan=3, sticky="w")
        ttk.Label(
            mode_box, textvariable=self.text_var("field.output_mode"), width=18
        ).pack(side="left", padx=(0, 10))
        for value in ("save", "json"):
            radio = ttk.Radiobutton(
                mode_box,
                textvariable=self.text_var(f"output.{value}"),
                value=value,
                variable=self._make_var("output_mode"),
            )
            radio.pack(side="left", padx=(0, 16))
            self.input_widgets.append(radio)

        ttk.Label(
            body, textvariable=self.text_var("field.data_dir"), width=18
        ).grid(row=1, column=0, sticky="w", padx=(0, 10), pady=(7, 0))
        self.data_entry = ttk.Entry(body, textvariable=self._make_var("data_dir"))
        self.data_entry.grid(row=1, column=1, sticky="ew", pady=(7, 0))
        self.data_browse = ttk.Button(
            body,
            textvariable=self.text_var("buttons.browse"),
            command=self._browse_data_dir,
        )
        self.data_browse.grid(row=1, column=2, padx=(7, 0), pady=(7, 0))
        self.input_widgets.extend((self.data_entry, self.data_browse))

        self.save_frame = ttk.Frame(body, style="Surface.TFrame")
        self.save_frame.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(7, 0))
        self.save_frame.columnconfigure(1, weight=1)
        ttk.Label(
            self.save_frame, textvariable=self.text_var("field.save_name"), width=18
        ).grid(row=0, column=0, sticky="w", padx=(0, 10))
        self.save_name_entry = ttk.Entry(
            self.save_frame, textvariable=self._make_var("save_name")
        )
        self.save_name_entry.grid(row=0, column=1, columnspan=2, sticky="ew")
        ttk.Label(
            self.save_frame, textvariable=self.text_var("field.save_format"), width=18
        ).grid(row=1, column=0, sticky="w", padx=(0, 10), pady=(6, 0))
        self.save_format_combo = ttk.Combobox(
            self.save_frame, state="readonly", width=24
        )
        self.save_format_combo.grid(row=1, column=1, sticky="w", pady=(6, 0))
        self.save_format_combo.bind(
            "<<ComboboxSelected>>", lambda _event: self._schedule_refresh()
        )
        self.input_widgets.extend((self.save_name_entry, self.save_format_combo))

        self.json_frame = ttk.Frame(body, style="Surface.TFrame")
        self.json_frame.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(7, 0))
        self.json_frame.columnconfigure(1, weight=1)
        ttk.Label(
            self.json_frame, textvariable=self.text_var("field.output_name"), width=18
        ).grid(row=0, column=0, sticky="w", padx=(0, 10))
        self.output_name_entry = ttk.Entry(
            self.json_frame, textvariable=self._make_var("output_name")
        )
        self.output_name_entry.grid(row=0, column=1, columnspan=2, sticky="ew")
        self.split_check = ttk.Checkbutton(
            self.json_frame,
            textvariable=self.text_var("field.split_chunks"),
            variable=self._make_var("split_chunks"),
        )
        self.split_check.grid(
            row=1, column=1, columnspan=2, sticky="w", pady=(6, 0)
        )
        self.input_widgets.extend((self.output_name_entry, self.split_check))

    def _build_actions(self, parent: ttk.Frame) -> None:
        action_box = ttk.Frame(parent, style="Surface.TFrame")
        action_box.pack(fill="x", pady=(12, 0))
        self.advanced_button = ttk.Button(
            action_box,
            textvariable=self.text_var("buttons.advanced"),
            command=self._open_advanced,
        )
        self.advanced_button.pack(side="left")
        self.validation_label = ttk.Label(
            action_box, text="", style="Error.TLabel"
        )
        self.validation_label.pack(side="left", padx=(12, 8))
        self.start_button = ttk.Button(
            action_box,
            textvariable=self.text_var("buttons.import"),
            style="Accent.TButton",
            command=self._start_import,
            state="disabled",
        )
        self.start_button.pack(side="right", padx=(0, 8))

    def _build_activity_section(self, parent: ttk.Frame) -> None:
        activity = ttk.Frame(parent, style="Surface.TFrame")
        activity.pack(fill="both", expand=True)
        heading = ttk.Frame(activity, style="Surface.TFrame")
        heading.pack(fill="x")
        ttk.Label(
            heading,
            textvariable=self.text_var("section.activity"),
            style="SectionTitle.TLabel",
        ).pack(side="left")
        self.job_status_label = ttk.Label(
            heading, textvariable=self.text_var("status.ready"), style="Job.TLabel"
        )
        self.job_status_label.pack(side="left", padx=(10, 0))
        self.clear_log_button = ttk.Button(
            heading,
            textvariable=self.text_var("buttons.clear_log"),
            command=self._clear_log,
            padding=(7, 3),
        )
        self.clear_log_button.pack(side="right")
        self.copy_button = ttk.Button(
            heading,
            textvariable=self.text_var("buttons.copy_command"),
            command=self._copy_command,
            padding=(7, 3),
            state="disabled",
        )
        self.copy_button.pack(side="right", padx=(0, 6))
        self.open_button = ttk.Button(
            heading,
            textvariable=self.text_var("buttons.open_output"),
            command=self._open_output,
            padding=(7, 3),
            state="disabled",
        )
        self.open_button.pack(side="right", padx=(0, 6))
        self.stop_button = ttk.Button(
            heading,
            textvariable=self.text_var("buttons.stop"),
            style="Stop.TButton",
            command=self._stop_import,
            padding=(7, 3),
            state="disabled",
        )
        self.stop_button.pack(side="right", padx=(0, 6))

        progress_row = ttk.Frame(activity, style="Surface.TFrame")
        progress_row.pack(fill="x", pady=(7, 5))
        self.progress = ttk.Progressbar(
            progress_row, mode="determinate", maximum=100
        )
        self.progress.pack(side="left", fill="x", expand=True)
        self.elapsed_label = ttk.Label(
            progress_row, text="", style="Muted.TLabel", width=7
        )
        self.elapsed_label.pack(side="right", padx=(8, 0))

        self.output_label = ttk.Label(
            activity,
            textvariable=self.text_var("status.output_unknown"),
            style="Path.TLabel",
            wraplength=760,
        )
        self.output_label.pack(fill="x", pady=(0, 7))
        self.diagnostic_label = ttk.Label(
            activity, text="", style="Error.TLabel", wraplength=760
        )
        self.diagnostic_label.pack(fill="x", pady=(0, 7))

        log_box = ttk.Frame(activity)
        log_box.pack(fill="both", expand=True)
        self.log_text = tk.Text(
            log_box,
            height=9,
            wrap="word",
            background="#132128",
            foreground="#cbdadd",
            insertbackground="#cbdadd",
            relief="flat",
            borderwidth=0,
            padx=10,
            pady=8,
            font=tkfont.nametofont("TkFixedFont"),
            state="disabled",
        )
        scrollbar = ttk.Scrollbar(log_box, orient="vertical", command=self.log_text.yview)
        self.log_text.configure(yscrollcommand=scrollbar.set)
        self.log_text.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")

    def _make_var(self, key: str) -> tk.Variable:
        if key in self.field_vars:
            return self.field_vars[key]
        default = self.state.get(key)
        variable: tk.Variable
        if isinstance(default, bool):
            variable = tk.BooleanVar(value=default)
        else:
            variable = tk.StringVar(value=str(default))
        self.field_vars[key] = variable
        variable.trace_add("write", lambda *_args: self._on_form_changed())
        return variable

    def _initialize_variables(self) -> None:
        for key in self.state.values:
            self._make_var(key)
        self._fill_languages()
        self._fill_save_formats()
        self._clear_log()
        self._update_version_label()

    def _fill_languages(self) -> None:
        names = list(self.i18n.languages.values())
        self._language_name_to_code = {
            name: code for code, name in self.i18n.languages.items()
        }
        self.language_combo.configure(values=names)
        self.language_combo.set(self.i18n.languages[self.i18n.language])

    def _fill_save_formats(self) -> None:
        current = str(self.state.get("save_format") or "auto")
        display_values = [self.t(key) for key in SAVE_FORMAT_KEYS.values()]
        self._save_format_display_to_code = {
            self.t(key): code for code, key in SAVE_FORMAT_KEYS.items()
        }
        self.save_format_combo.configure(values=display_values)
        self.save_format_combo.set(
            self.t(SAVE_FORMAT_KEYS.get(current, "save_format.auto"))
        )

    def _update_version_label(self) -> None:
        text = (TOOL_ROOT / "data" / "sh_generated_block_state_schemas.lua").read_text(
            encoding="utf-8"
        )
        import re

        version = re.search(r'minecraftId="([^"]+)"', text)
        data_version = re.search(r"worldVersion=(\d+)", text)
        if version and data_version:
            self.text_vars["app.subtitle"].set(
                f"{self.t('app.subtitle')} · "
                + self.t(
                    "app.version",
                    version=version.group(1),
                    data_version=data_version.group(1),
                )
            )

    def _collect_state(self) -> FormState:
        values = self.state.to_dict()
        for key, variable in self.field_vars.items():
            values[key] = bool(variable.get()) if isinstance(variable, tk.BooleanVar) else str(variable.get())
        selected_format = self.save_format_combo.get()
        values["save_format"] = self._save_format_display_to_code.get(
            selected_format, str(self.state.get("save_format") or "auto")
        )
        return FormState(values)

    def _on_form_changed(self) -> None:
        if not hasattr(self, "start_button"):
            return
        self._schedule_save()
        self._sync_mode_frames()
        self._schedule_refresh()

    def _sync_mode_frames(self) -> None:
        if not hasattr(self, "chunk_frame"):
            return
        range_mode = str(self.field_vars["range_mode"].get())
        if range_mode == "chunk":
            self.block_frame.grid_remove()
            self.chunk_frame.grid()
        else:
            self.chunk_frame.grid_remove()
            self.block_frame.grid()

        output_mode = str(self.field_vars["output_mode"].get())
        if output_mode == "save":
            self.json_frame.grid_remove()
            self.save_frame.grid()
        else:
            self.save_frame.grid_remove()
            self.json_frame.grid()

    def _schedule_refresh(self) -> None:
        if self._refresh_after_id is not None:
            self.after_cancel(self._refresh_after_id)
        self._refresh_after_id = self.after(320, self._refresh_plan)

    def _schedule_save(self) -> None:
        if self._save_after_id is not None:
            self.after_cancel(self._save_after_id)
        self._save_after_id = self.after(450, self._persist_settings)

    def _persist_settings(self) -> None:
        self._save_after_id = None
        state = self._collect_state()
        self.state = state
        save_settings(
            {
                "version": SETTINGS_VERSION,
                "language": self.i18n.language,
                "form": state.to_dict(),
            }
        )

    def _refresh_plan(self) -> None:
        self._refresh_after_id = None
        current = self._collect_state()
        self.state = current
        world_text = str(current.get("world")).strip()
        dimension = str(current.get("dimension"))
        if not world_text:
            self._set_world_status(
                self.t("status.world_empty"), style="Muted.TLabel"
            )
        else:
            try:
                world, count, data_version = inspect_world(world_text, dimension)
                version_text = (
                    str(data_version)
                    if data_version is not None
                    else self.t("status.data_version_unknown")
                )
                status_text = self.t(
                    "status.world_valid",
                    name=world.name,
                    count=count,
                    data_version=version_text,
                )
                if bool(current.get("auto_data_version")) and data_version is not None:
                    status_text += " · " + self.t("status.auto_compatible")
                self._set_world_status(
                    status_text,
                    style="Success.TLabel",
                )
                if not str(current.get("save_name")).strip():
                    self.field_vars["save_name"].set(world.name)
                if not str(current.get("output_name")).strip():
                    self.field_vars["output_name"].set(world.name)
            except FormError as error:
                self._set_world_status(self.i18n.error_text(error), style="Error.TLabel")

        try:
            self.plan = build_plan(current)
        except FormError as error:
            self.plan = None
            self.start_button.configure(state="disabled")
            self.copy_button.configure(state="disabled")
            self.validation_label.configure(
                text=self.i18n.error_text(error), style="Error.TLabel"
            )
            self.output_label.configure(text=self.t("status.output_unknown"))
            return
        self.validation_label.configure(text="", style="Error.TLabel")
        if self.job_state not in ("running", "cancelling"):
            self.start_button.configure(state="normal")
        self.copy_button.configure(state="normal")
        self.output_label.configure(text=str(self.plan.output_path))

    def _set_world_status(self, text: str, style: str) -> None:
        self.world_status.configure(style=style)
        self.text_vars["status.world_empty"].set(text)

    def _browse_world(self) -> None:
        initial = str(self.field_vars["world"].get()).strip()
        options: dict[str, Any] = {
            "parent": self,
            "title": self.t("field.world"),
            "mustexist": True,
        }
        if initial and pathlib.Path(initial).is_dir():
            options["initialdir"] = initial
        selected = filedialog.askdirectory(**options)
        if selected:
            self.field_vars["world"].set(selected)

    def _browse_data_dir(self) -> None:
        initial = str(self.field_vars["data_dir"].get()).strip()
        options: dict[str, Any] = {
            "parent": self,
            "title": self.t("field.data_dir"),
            "mustexist": False,
        }
        if initial and pathlib.Path(initial).is_dir():
            options["initialdir"] = initial
        selected = filedialog.askdirectory(**options)
        if selected:
            self.field_vars["data_dir"].set(selected)

    def _open_advanced(self) -> None:
        dialog = AdvancedDialog(self, self._collect_state(), self.i18n)
        self.wait_window(dialog)
        if dialog.result:
            for key, value in dialog.result.items():
                self.field_vars[key].set(value)
            self._schedule_refresh()

    def _start_import(self) -> None:
        self._refresh_plan()
        if self.plan is None:
            return
        self.notebook.select(self.activity_tab)
        self.last_run_log = ""
        self._clear_diagnostic()
        self._clear_log()
        self._append_log("$ " + self.plan.display_command)
        self._set_job_state("running")
        self.open_button.configure(state="disabled")
        self._run_started = time.monotonic()
        self._tick_elapsed()
        self.progress.configure(mode="indeterminate", value=0)
        self.progress.start(12)
        self._set_busy(True)
        self.runner = ImportRunner(self.plan.command)
        self.runner.start()
        self._poll_runner()

    def _set_busy(self, busy: bool) -> None:
        for widget in self.input_widgets:
            try:
                if isinstance(widget, ttk.Combobox):
                    widget.configure(state="disabled" if busy else "readonly")
                else:
                    widget.configure(state="disabled" if busy else "normal")
            except tk.TclError:
                pass
        self.advanced_button.configure(state="disabled" if busy else "normal")
        self.stop_button.configure(state="normal" if busy else "disabled")
        self.start_button.configure(
            state="disabled" if busy or self.plan is None else "normal"
        )

    def _stop_import(self) -> None:
        if self.runner is not None:
            self.runner.cancel()
            self._set_job_state("cancelling")

    def _poll_runner(self) -> None:
        if self.runner is None:
            return
        while True:
            try:
                event = self.runner.events.get_nowait()
            except queue.Empty:
                break
            event_type = event["type"]
            if event_type == "log":
                text = str(event["text"])
                self.last_run_log += text + "\n"
                self._append_log(text)
            elif event_type == "start_error":
                self._finish_import(
                    success=False,
                    cancelled=False,
                    message=self.t("error.process_start", message=event["message"]),
                )
                return
            elif event_type == "finished":
                code = int(event["code"])
                cancelled = bool(event["cancelled"])
                diagnostic = (
                    self._diagnose_data_version_failure()
                    if code != 0 and not cancelled
                    else None
                )
                message = ""
                if code != 0 and not cancelled:
                    if diagnostic:
                        key, values = diagnostic
                        message = self.t(key, **values)
                    else:
                        message = self.t("error.process_exit", code=code)
                self._finish_import(
                    success=code == 0 and not cancelled,
                    cancelled=cancelled,
                    message=message,
                    diagnostic=diagnostic,
                )
                return
        self._poll_after_id = self.after(100, self._poll_runner)

    def _finish_import(
        self,
        success: bool,
        cancelled: bool,
        message: str,
        diagnostic: tuple[str, dict[str, Any]] | None = None,
    ) -> None:
        if self._elapsed_after_id is not None:
            self.after_cancel(self._elapsed_after_id)
            self._elapsed_after_id = None
        self._tick_elapsed(final=True)
        self.progress.stop()
        self.progress.configure(
            mode="determinate", value=100 if success else 0
        )
        if success:
            self._clear_diagnostic()
            self._set_job_state("success")
        elif cancelled:
            self._clear_diagnostic()
            self._set_job_state("cancelled")
        else:
            self._set_job_state("failed")
            if diagnostic:
                self._set_diagnostic(*diagnostic)
            else:
                self._clear_diagnostic()
            if message:
                self._append_log(message)
        self.runner = None
        self._set_busy(False)
        self.open_button.configure(
            state="normal" if self.plan and self.plan.output_path.parent.exists() else "disabled"
        )
        if self._close_after_cancel:
            self.destroy()

    def _set_job_state(self, state: str) -> None:
        self.job_state = state
        key = {
            "idle": "status.ready",
            "running": "status.running",
            "cancelling": "status.cancelling",
            "success": "status.success",
            "failed": "status.failed",
            "cancelled": "status.cancelled",
        }.get(state, "status.ready")
        self.job_status_label.configure(text=self.t(key))
        self.stop_button.configure(
            state="normal" if state in ("running", "cancelling") else "disabled"
        )
        if state in ("running", "cancelling"):
            self.start_button.configure(state="disabled")

    def _diagnose_data_version_failure(
        self,
    ) -> tuple[str, dict[str, Any]] | None:
        if "unsupported_chunk_storage_data_version" in self.last_run_log:
            match = re.search(r"DataVersion\s+(\d+)\s+has no audited", self.last_run_log)
            return (
                "error.unsupported_data_version",
                {
                    "version": match.group(1) if match else "?",
                    "ranges": supported_data_version_ranges(),
                },
            )
        if "missing_data_version" in self.last_run_log:
            return ("error.missing_data_version", {})
        if "data_version_mismatch" in self.last_run_log:
            return ("error.data_version_mismatch", {})
        if "mixed_data_versions" in self.last_run_log:
            return ("error.mixed_data_versions", {})
        return None

    def _set_diagnostic(self, key: str, values: dict[str, Any]) -> None:
        self.diagnostic_key = key
        self.diagnostic_values = dict(values)
        self.diagnostic_label.configure(text=self.t(key, **values))

    def _clear_diagnostic(self) -> None:
        self.diagnostic_key = None
        self.diagnostic_values = {}
        self.diagnostic_label.configure(text="")

    def _append_log(self, text: str) -> None:
        if not text:
            return
        if not self.log_has_content:
            self.log_text.configure(state="normal")
            self.log_text.delete("1.0", "end")
        self.log_has_content = True
        self.log_text.configure(state="normal")
        if self.log_text.get("1.0", "end-1c").strip():
            self.log_text.insert("end", "\n")
        self.log_text.insert("end", text)
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _tick_elapsed(self, final: bool = False) -> None:
        if self._run_started is None:
            self.elapsed_label.configure(text="")
            return
        seconds = max(0, int(time.monotonic() - self._run_started))
        hours, remainder = divmod(seconds, 3600)
        minutes, seconds = divmod(remainder, 60)
        text = (
            f"{hours:02d}:{minutes:02d}:{seconds:02d}"
            if hours
            else f"{minutes:02d}:{seconds:02d}"
        )
        self.elapsed_label.configure(text=text)
        if not final and self.job_state in ("running", "cancelling"):
            self._elapsed_after_id = self.after(500, self._tick_elapsed)

    def _clear_log(self) -> None:
        self.log_has_content = False
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.insert("1.0", self.t("status.log_empty"))
        self.log_text.configure(state="disabled")

    def _copy_command(self) -> None:
        if self.plan is None:
            return
        self.clipboard_clear()
        self.clipboard_append(self.plan.display_command)
        self._set_job_state(self.job_state)
        self.validation_label.configure(
            text=self.t("status.command_copied"), style="Success.TLabel"
        )
        self.after(2200, self._refresh_plan)

    def _open_output(self) -> None:
        if self.plan is None:
            return
        target = self.plan.output_path.parent
        if not target.exists():
            target = self.plan.data_dir
        if not target.exists():
            messagebox.showwarning(
                self.t("app.title"),
                self.t("dialog.output_missing"),
                parent=self,
            )
            return
        try:
            if os.name == "nt":
                os.startfile(str(target))  # type: ignore[attr-defined]
            elif sys.platform == "darwin":
                subprocess.Popen(["open", str(target)])
            else:
                subprocess.Popen(["xdg-open", str(target)])
        except OSError as exc:
            messagebox.showerror(
                self.t("app.title"),
                self.t("error.open_path", message=str(exc)),
                parent=self,
            )

    def _on_language_selected(self, _event: tk.Event[Any]) -> None:
        code = self._language_name_to_code.get(self.language_combo.get())
        if not code or code == self.i18n.language:
            return
        selected_save_format = self._save_format_display_to_code.get(
            self.save_format_combo.get(), str(self.state.get("save_format"))
        )
        self.state.set("save_format", selected_save_format)
        self.i18n.set_language(code)
        self._apply_language()
        self._persist_settings()
        self._refresh_plan()

    def _apply_language(self) -> None:
        self.title(self.t("app.title"))
        for key, variable in self.text_vars.items():
            variable.set(self.t(key))
        self.notebook.tab(self.setup_tab, text=self.t("tab.setup"))
        self.notebook.tab(self.activity_tab, text=self.t("tab.activity"))
        self._fill_languages()
        self._fill_save_formats()
        self._update_version_label()
        self._set_job_state(self.job_state)
        if self.diagnostic_key:
            self.diagnostic_label.configure(
                text=self.t(self.diagnostic_key, **self.diagnostic_values)
            )
        if not self.log_has_content:
            self._clear_log()
        if not self.plan:
            self.output_label.configure(text=self.t("status.output_unknown"))
        self._refresh_plan()

    def _on_close(self) -> None:
        if self.runner is not None:
            should_close = messagebox.askyesno(
                self.t("dialog.running_title"),
                self.t("dialog.running_message"),
                parent=self,
            )
            if not should_close:
                return
            self._close_after_cancel = True
            self._stop_import()
            self.after(500, self._force_close_after_cancel)
            return
        self._persist_settings()
        self.destroy()

    def _force_close_after_cancel(self) -> None:
        if self.runner is not None:
            self.runner.cancel()
        self._persist_settings()
        self.destroy()


def main() -> int:
    app = ImporterApp()
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
