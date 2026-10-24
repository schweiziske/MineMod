#!/usr/bin/env sh
set -eu

TOOL_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if ! command -v python3 >/dev/null 2>&1; then
	echo "Python 3 was not found. Install Python 3.11 or newer." >&2
	exit 1
fi

PYTHONUTF8=1 exec python3 "$TOOL_ROOT/world_importer_ui.py" "$@"
