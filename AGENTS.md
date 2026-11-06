# MineMod Engineering Rules

## Native C++ code organization and style

- Before adding or reorganizing project-owned Native C++ code, read and follow
  [docs/native-cpp-standard.md](docs/native-cpp-standard.md).
- Use `native/.clang-format`, `native/.clang-tidy`, and `native/.editorconfig`.
  Exclude vendored dependencies and generated output from formatting and checks.
- Assign new code to its responsibility directory. Keep CPU algorithms, task
  scheduling, Source resources, and Lua bindings distinct, with explicit
  ownership and thread contracts. Preserve published Lua names and ABI.
- Follow naming and formatting rules when writing new code or restructuring a
  function. Do not mix repository-wide formatting or automatic tidy fixes with
  functional changes. Run source checks and tests only as arranged by the user.

## Units, coordinate spaces, and Lua return values

- One Minecraft block is `MC.API.Coords.BlockSize()` Source units. Its current
  default is `36.5`, but runtime code must read the API instead of hard-coding
  `36.5`. Minecraft model/display values are dimensionless block ratios and
  must be multiplied by the current block size exactly once.
- Keep MC world space, Source engine space, and client render space distinct.
  Use `MC.API.Coords` conversion/query functions. Do not pass an MC-world
  vector directly to an engine trace or `Entity:SetPos` on a re-origining
  world.
- Treat every GLua function documented to return multiple values as unsafe
  behind `and`, `or`, parentheses, or another function argument. Lua preserves
  all results only when the call is the final expression in an assignment,
  return statement, or list-style table constructor. An `and`/`or` expression
  always collapses the nested call to one value.

Forbidden:

```lua
local minimum, maximum = Coords and Coords.EntityWorldAABB
	and Coords.EntityWorldAABB( entity )
local value, err = available and query() or nil
local first, second = ( query() )
```

Required:

```lua
local minimum, maximum
if Coords and Coords.EntityWorldAABB then
	minimum, maximum = Coords.EntityWorldAABB( entity )
end
if not isvector( minimum ) or not isvector( maximum ) then
	minimum, maximum = entity:WorldSpaceAABB()
end
```

Single-result capability checks may still use `and`/`or`. If the number of
returns is unknown, use the explicit branch form. Pay particular attention to
coordinate APIs because bounds, cell coordinates, and mutation APIs commonly
return two or more values.

## LuaJIT and garbage collection

- Treat Garry's Mod Lua as LuaJIT with Lua 5.1 semantics and GMod-specific
  extensions. Do not assume behavior or libraries from newer PUC Lua versions.
- Keep per-frame hooks and large traversal loops allocation-light. Avoid
  short-lived tables, closures, strings, and Vector/Angle objects in hot paths;
  reuse storage only when ownership and mutation cannot leak across callers.
- Do not force full collections or change global GC pause/step settings as a
  local performance fix. Use the existing opt-in GC controls where relevant,
  and measure heap growth and frame impact in the actual client workload.
- LuaJIT performance depends on stable, traceable hot paths. Benchmark changes
  in GMod and compare total work and allocation pressure; do not infer gains
  from desktop Lua timing or isolated microbenchmarks alone.

## Hot-path validation

- Validate inputs, model metadata, and required dependencies at load,
  registration, or build boundaries; revalidate when their revision changes.
- Block, quad, and vertex loops consume validated data directly. Do not repeat
  type/range/dependency checks, protected calls, or fallback defaults for
  invariants already established by the caller.
- Put exhaustive checks in tests or explicit debug validation passes. Genuine
  boundary and resource failures still follow `docs/fault-handling.md`; do not
  swallow errors or silently substitute defaults.

## Performance work

- Spreading work across frames is not an optimization. Do not resolve a hitch
  or slow path by adding or tightening per-frame budgets, time slicing,
  deferral queues, or staggering. A performance change must reduce the total
  work for the same result: CPU time, allocations, draw calls, or uploads.
  Report that total, not only the per-frame peak.

## Source rendering and DX9

- Design rendering for Garry's Mod's Source MaterialSystem and Direct3D 9
  capabilities. Do not assume modern APIs or features such as compute shaders,
  UAVs, bindless resources, or a modern deferred pipeline.
- Check the actual shader target, material-system interfaces, mesh limits,
  render-target formats, and resource lifetime before relying on them. Use
  Source-compatible materials and compiled shader resources; account for
  device reset and resource release/restore behavior.
- GMod texture atlases may be up to `16384x16384`. Do not assume a shader
  instruction limit of `512`; check the actual target/compiler constraints.
- Keep engine/GPU resource operations on the supported render path. Worker
  threads may process CPU-owned snapshots, but must not touch Lua state,
  materials, textures, IMesh objects, or mutable engine state.

## Addon merge tool

- `tools/merge_addons.ps1` only merges addon files into the generated root
  directory `minemod/`, which is ignored by Git. Keep conflict detection based
  on duplicate destination paths; do not add hashing or unrelated build,
  migration, or resource-generation behavior.
- Keep change summaries focused on the requested result. Mention omitted work,
  historical state, or unrun validation only when it affects the result or the
  user needs it to make a decision.

## Documentation

- Keep documentation focused on current behavior, contracts, and usage. Do not
  append editing history, migration progress, or dated validation logs; use Git
  history for change records. Preserve dependency provenance and license notices.
- Every new Markdown document in `docs/` must be registered in
  `docs/README.md` in the same commit that adds it: add one row to the table
  of its category, in the form
  `| [name.md](name.md) | one sentence on the question it answers |`.
  The table decides the category; do not add a category column. Files in a
  subdirectory such as `docs/adr/` are covered by that subdirectory's entry;
  keep its description current.
- Choose the category by how the document should be read: `契约`, `参考`,
  `踩坑`, `设计` or `过程`. Research into other projects' code goes under
  `外部技术调研`. Definitions and the remaining writing rules are in
  `docs/README.md`.
- A missing entry is fixed by adding the entry, never by deleting the
  document. Cleanup is manual.
