# Native C++ standard

English | [简体中文](zh/native-cpp-standard.md)

Applies to project-owned code in `native/`. Formatting, checks, and indentation are configured in [native/.clang-format](../native/.clang-format), [.clang-tidy](../native/.clang-tidy), and [.editorconfig](../native/.editorconfig). Leave third-party libraries and generated output unchanged. `native/sdk/` preserves upstream naming, formatting, inheritance, and virtual layouts, with separate ABI review.

## Responsibilities and dependencies

| Directory | Responsibility |
| --- | --- |
| `Core/` | Shared infrastructure and CPU concurrency gates. |
| `World/` | World storage, revisions, snapshots, transport decoding, and light propagation. |
| `Mesh/` | Recipes, section geometry, fluid and model shapes, lighting, and face-building tasks. |
| `Render/Visibility/` | CPU-only visibility data, graph construction, queries, and background workers. |
| `Render/Source/` | Material-system ABI, engine meshes, drawing, and resource publication. |
| `Resources/`, `Resources/Atlas/` | Resource sources, atlases, PNGs, and pixel operations. |
| `Resources/Source/` | Engine textures, publication barriers, and relighting transactions. |
| `Bindings/` | Lua argument conversion, userdata, and return values. |
| `Module/` | DLL entry, initialization, export registration, and shutdown. |
| `Legacy/` | Required legacy implementations and compatibility entry points. |
| `tests/`, `cmake/` | Tests, probes, benchmarks, and shared build lists. |
| `include/`, `sdk/`, `build/` | Third-party dependencies, maintained Source interfaces, and build output. |

CPU-only code does not include Lua or Source SDK headers. Business modules do not depend on Bindings. Algorithms compute data; task objects manage queues, revisions, cancellation, and threading; resource objects manage uploads, publication, and destruction; bindings convert at boundaries. Do not implement a second resource transaction system in bindings.

Name files after their principal type, with declarations and implementations together, such as `SectionGeometry.h/.cpp`. Split by named responsibility, not line count, and avoid layers that only forward arguments. When moving files, update includes, CMake, test builds, and documentation. The name `Legacy` does not authorize deleting compatibility code.

## Naming and formatting

| Element | Rule | Example |
| --- | --- | --- |
| Classes, structs, type aliases | PascalCase | `VisibilityGraph` |
| Ordinary functions and methods | PascalCase, concrete verbs | `BuildGraph` |
| Members | `m` + PascalCase | `mChunks` |
| Static member methods and mutable static state | `s` + PascalCase | `sCreate` |
| Class, global, and static constants | `c` + PascalCase | `cMaxGridCells` |
| Input, output, and read/write parameters | `in` / `out` / `io` + PascalCase | `inSnapshot`, `outError` |
| Local variables and constants | snake_case | `visible_chunks` |
| Enum types and values | `E` + PascalCase, PascalCase | `ERejectReason::Frustum` |

SDK overrides, Lua exports, and C ABI symbols retain their contracts. Loop indices may use `i`, `x`, `y`, or `z`.

- Tabs of width 4; Allman braces; remove trailing whitespace and end files with a newline.
- Single-statement branches may omit braces, with the statement on a separate line. Keep validation, locks, Lua-stack handling, publication, rollback, and release readable step by step.
- Write pointers and references as `Texture *texture` and `const Snapshot &inSnapshot`. Do not compress multiple side effects into one line.
- Use `#pragma once` and direct dependency includes. No `using namespace` in public headers.
- A `.cpp` using a PCH includes it first, then its own header. CPU-only modules do not include an engine PCH.
- Include paths state the responsibility directory. Use `///` to document public inputs, failures, threads, and lifetimes; implementation comments explain necessary constraints.

## Ownership and threads

Give each resource one explicit owner; prefer value members or unique ownership. Document borrowed-pointer lifetimes and nullability. Use generation handles for long-lived references that may become invalid. Manage Lua registry references, engine references, locks, and transactions through RAII. Release acquired resources on initialization failure and explicitly declare copy and move semantics.

Workers receive immutable snapshots or exclusive data. They do not access the Lua stack, materials, textures, IMesh objects, or mutable live-world objects. Check world generation, revision, and cancellation before publication. Document mutex-protected members and lock order; do not call unknown callbacks or Lua while holding locks.

Stop accepting tasks, wake and join workers, then retire results and release resources. Detached threads must not bypass shutdown order.

Resource publication modules centrally own draining, material-system locks, Download, and transaction recovery. Drawing interfaces that can block or publish must document preconditions and cost. Cache keys cover all inputs, and owners handle invalidation.

## Validation, errors, and performance

Follow the [engineering rules](../AGENTS.md) and [fault-handling contract](fault-handling.md):

- Validate at load, registration, parsing, build, or revision changes; hot loops consume validated data.
- Return explicit failures for invalid external inputs and assert internal invariants. Assertions do not replace required Release boundary checks.
- Bindings convert errors consistently and restore the stack. C++ exceptions must not cross the C ABI; Lua long jumps must not skip required destructors.
- Pass runtime dimensions from the Lua coordinate API into C++. Do not hard-code block size or mix world, engine, and render spaces.
- Performance changes reduce total CPU, allocations, draws, or uploads for the same result. Frame spreading and tighter budgets are not optimizations.
- Timing identifies thread, scope, and waits. Wall time is not GPU time; nested stages cannot simply be added. Keep probes out of per-element loops.

## Tools

Use LLVM 22 or newer with support for the current configuration. Run the following only as arranged by the user:

```powershell
clang-format --style=file:native/.clang-format --dump-config
clang-tidy --config-file=native/.clang-tidy --verify-config
clang-format --style=file --dry-run --Werror native/Render/Visibility/VisibilityQuery.cpp
clang-tidy -p native/build/x64/auto-release-final native/Render/Visibility/VisibilityQuery.cpp
```

`--verify-config` only checks that the configuration parses. Use a compilation database matching the target architecture, branch, and configuration. A CPU-test-only database does not establish that DLL checks pass. `.clang-format-ignore` and the tidy header filter exclude `include/`, `sdk/`, and `build/`; do not pass third-party sources as primary translation units.

Do not mix repository-wide formatting with functional changes, run tidy `--fix` by default, or hide issues with global `NOLINT`. Scope necessary suppressions to specific locations and checks, and explain them. Source checks, tests, client launch, and sampling run only as arranged by the user. See the [Native module guide](native.md) for build parameters, SDK details, and output paths.
