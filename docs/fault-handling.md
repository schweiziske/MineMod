# Fault-handling contract

English | [简体中文](zh/fault-handling.md)

Applies to internal cross-module calls, resource loading, and world-data boundaries in MineMod. Implemented in [sh_fault.lua](../addons/mc_engine/lua/mc/sh_fault.lua). Third-party addons use [`MC.API`](api.md); these `MC.*` helpers are not part of the public extension API.

## Reporting and strict mode

`mc_strict` defaults to `0` and is saved in configuration. Faults are deduplicated by a stable `code`: the first occurrence is printed, and every occurrence increments the count and updates details. With `mc_strict 1`, reporting also raises a Lua error. Strict mode and fault tables belong to the current Lua realm; inspect client and server separately.

| Command | Purpose |
| --- | --- |
| `mc_faults` | List fault codes, counts, latest details, and first-report locations in this realm. |
| `mc_faults_clear` | Clear this realm's fault records. |

Reporting a fault does not mean recovery succeeded. The caller must still stop the operation, keep old resources, or roll back the transaction. Do not replace unknown data with air, empty tables, or a successful result and continue publishing it.

## Helpers

| Call | Returns and semantics |
| --- | --- |
| `MC.StrictFaults()` | Whether strict mode is enabled. |
| `MC.Fault(code, message, ...)` | Report a fault; accepts `string.format` arguments. Returns `false` outside strict mode. |
| `MC.Check(ok, code, message, ...)` | Return `true` when `ok` is truthy; otherwise call `Fault`. |
| `MC.Need(value, code, message, ...)` | Return non-`nil` values unchanged, including `false`; report and return `nil` for `nil`. |
| `MC.Try(code, fn, ...)` | Return `ok, result`; report failures. Preserves only the called function's first result, so it cannot preserve multiple-return APIs. |
| `MC.FaultReport()` | Return the internal live record array; do not modify it. |
| `MC.ClearFaults()` | Clear records. |

`MC.Try` does not forward all `pcall` results. Explicitly receive multiple success values, then report and handle failure:

```lua
local ok, minimum, maximum = pcall( queryBounds )
if not ok then
	MC.Fault( "bounds_query_failed", "%s", tostring( minimum ) )
	return false
end
-- Validate minimum / maximum at the boundary before passing them downstream.
```

## Validation boundaries

Validate inputs, dependencies, and model metadata at load, registration, and build boundaries; revalidate when revisions change. Validated block, quad, and vertex loops consume data directly, without repeated per-element dependency checks, `pcall`, or default substitution. Deduplicating the first log message does not remove the cost of repeated faults in a hot loop; fix the cause.

Fault codes describe stable conditions such as `atlas_source_missing`. Put dynamic paths, coordinates, and revisions in details, rather than creating a new code for each occurrence. Expected branches such as an absent optional capability, user cancellation, or no hit follow the interface's return contract and need not become internal faults.
