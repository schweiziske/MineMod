"""LuaJIT harness for the MineMod localization tests.

The Lua runtime comes from lupa built for this Python (LuaJIT 2.1). Pass the
directory that contains the lupa package with --deps or the environment
variable MINEMOD_TEST_DEPS.
"""
import json
import os
import random
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TESTS = Path(__file__).resolve().parent
ENGINE_LUA = REPO / "addons" / "mc_engine" / "lua"

_luajit = None


def configure(argv):
    """Read --deps from argv and import lupa; returns the remaining args."""
    global _luajit
    rest = []
    deps = os.environ.get("MINEMOD_TEST_DEPS")
    index = 0
    while index < len(argv):
        if argv[index] == "--deps" and index + 1 < len(argv):
            deps = argv[index + 1]
            index += 2
            continue
        rest.append(argv[index])
        index += 1
    if deps:
        sys.path.insert(0, deps)
    try:
        from lupa import luajit21
    except ImportError as error:
        raise SystemExit("lupa with LuaJIT 2.1 is required; pass --deps <directory containing lupa> (%s)" % error)
    _luajit = luajit21
    return rest


class VirtualFS:
    """GAME merges every root directory in order, like mounted addons; the
    first root that has a path provides it. DATA is one directory.

    game_roots may be a list or a function returning the list, so a test can
    "install" an addon after the runtime started. find() returns names in
    reverse or shuffled order to prove that the loader sorts by itself."""

    def __init__(self, game_roots, data_root=None, shuffle_seed=None):
        self.game_roots = game_roots
        self.data_root = Path(data_root) if data_root else None
        self.random = random.Random(shuffle_seed) if shuffle_seed is not None else None
        self.reads = 0
        self.finds = 0

    def _roots(self, path_id):
        if path_id == "GAME":
            roots = self.game_roots() if callable(self.game_roots) else self.game_roots
            return [Path(root) for root in roots]
        if path_id == "DATA":
            return [self.data_root] if self.data_root else []
        raise ValueError("unsupported path id " + str(path_id))

    def resolve(self, path, path_id):
        for root in self._roots(path_id):
            target = root / path
            if target.is_file():
                return target
        return None

    def find(self, pattern, path_id):
        if not pattern.endswith("*"):
            raise ValueError("test file.Find only supports '<dir>/*' patterns: " + pattern)
        self.finds += 1
        directory = pattern[:-1]
        files, dirs = set(), set()
        for root in self._roots(path_id):
            base = root / directory
            if not base.is_dir():
                continue
            for child in base.iterdir():
                (dirs if child.is_dir() else files).add(child.name)
        files, dirs = sorted(files), sorted(dirs)
        if self.random:
            self.random.shuffle(files)
            self.random.shuffle(dirs)
        else:
            files.reverse()
            dirs.reverse()
        return files, dirs

    def read(self, path, path_id):
        target = self.resolve(path, path_id)
        if target is None:
            return None
        self.reads += 1
        return target.read_bytes().decode("utf-8")

    def size(self, path, path_id):
        target = self.resolve(path, path_id)
        return None if target is None else target.stat().st_size


class Runtime:
    def __init__(self, fs, realm="client", game_language="en", extra=None):
        if _luajit is None:
            raise RuntimeError("call configure(sys.argv[1:]) first")
        self.fs = fs
        self.lua = _luajit.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        test = self.lua.table()
        test.realm = realm
        test.gameLanguage = game_language
        test.Find = self._find
        test.Read = fs.read
        test.Size = fs.size
        test.DecodeJSON = self._decode
        test.EncodeJSON = lambda value: json.dumps(self.to_python(value))
        for key, value in (extra or {}).items():
            test[key] = value
        g.TEST = test
        self.test = test
        self.run_file(TESTS / "gmod_env.lua")

    def _find(self, pattern, path_id):
        files, dirs = self.fs.find(pattern, path_id)
        return self.lua.table_from(files), self.lua.table_from(dirs)

    def to_lua(self, value):
        if isinstance(value, dict):
            table = self.lua.table()
            for key, child in value.items():
                if child is not None:
                    table[key] = self.to_lua(child)
            return table
        if isinstance(value, list):
            table = self.lua.table()
            for index, child in enumerate(value, 1):
                table[index] = self.to_lua(child)
            return table
        return value

    def to_python(self, value):
        if _luajit.lua_type(value) == "table":
            keys = list(value.keys())
            if not keys:
                return []
            if all(isinstance(key, int) for key in keys):
                return [self.to_python(value[index]) for index in range(1, len(keys) + 1)]
            return {key: self.to_python(value[key]) for key in keys}
        return value

    def _decode(self, text):
        try:
            return self.to_lua(json.loads(text))
        except (ValueError, TypeError):
            return None

    def run_file(self, path, chunkname=None):
        source = Path(path).read_text(encoding="utf-8")
        loader = self.lua.eval("load")
        # load() returns the chunk alone, or nil plus the message.
        result = loader(source, "@" + (chunkname or Path(path).name))
        if isinstance(result, tuple):
            raise RuntimeError("Lua syntax error: %s" % (result[1],))
        if result is None:
            raise RuntimeError("Lua syntax error in %s" % path)
        return result()

    def run(self, source):
        return self.lua.execute(source)

    def eval(self, expression):
        return self.lua.eval(expression)

    def call(self, function_expression, *args):
        """Calls the Lua function an expression names; Python dicts and
        lists become Lua tables, None becomes nil."""
        function = self.lua.eval(function_expression)
        return function(*[self.to_lua(arg) for arg in args])

    def report(self):
        return self.to_python(self.lua.eval("MC.I18n.Report()"))

    def faults(self):
        """Fault codes recorded by MC.Fault, in first-seen order."""
        records = self.lua.eval("MC.FaultReport()")
        return [records[index].code for index in range(1, len(records) + 1)]

    def output(self):
        out = self.test.output
        return [out[index] for index in range(1, len(out) + 1)]

    def clear_output(self):
        self.test.output = self.lua.table()

    def load_i18n(self):
        """Loads the fault reporter and the real localization runtime."""
        self.run_file(ENGINE_LUA / "mc" / "sh_fault.lua")
        self.run_file(ENGINE_LUA / "mc" / "sh_i18n.lua")
        return self

    def load_api(self):
        """Adds the config metadata and the public API facade on top of
        load_i18n(), with just enough registry stubs for them to load."""
        self.run_file(ENGINE_LUA / "mc" / "sh_config_ui.lua")
        self.run("""
            MC.ModRegistry = { creativeCategories = {}, creativeEntries = {}, creativeOrder = {},
                creativeBlockCategories = {}, creativeSlotCursor = 0 }
            function MC.NormalizeResourceLocation( value )
                if type( value ) ~= "string" then return nil end
                if not string.find( value, ":", 1, true ) then value = "minecraft:" .. value end
                if not string.find( value, "^[a-z0-9_.%-]+:[a-z0-9_./%-]+$" ) then return nil end
                return value
            end
            function Vector( x, y, z ) return { x = x or 0, y = y or 0, z = z or 0 } end
            function Angle( p, y, r ) return { p = p or 0, y = y or 0, r = r or 0 } end
            function Color( r, g, b, a ) return { r = r, g = g, b = b, a = a or 255 } end
        """)
        self.run_file(ENGINE_LUA / "mc" / "api" / "sh_api.lua")
        return self


def repo_game_roots():
    return sorted(path for path in (REPO / "addons").iterdir() if path.is_dir())


def run_tests(module_globals, argv):
    """Runs every test_* function in module order; returns an exit code."""
    configure(argv)
    tests = [(name, fn) for name, fn in module_globals.items() if name.startswith("test_") and callable(fn)]
    failures = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception as error:  # report every failure, then fail the run
            failures += 1
            print("FAIL", name, "-", type(error).__name__, error)
    print("%d passed, %d failed" % (len(tests) - failures, failures))
    return 1 if failures else 0
