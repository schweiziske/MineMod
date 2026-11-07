# MineMod Source SDK headers

English | [简体中文](../../docs/zh/native/sdk/README.md)

This directory maintains the Windows Source interfaces used by MineMod. Directory names, class names, inheritance, virtual methods, and structs follow the Source SDK. Verified shared interfaces such as `IMesh` and `ITexture` use ordinary calls. The `Render/Source/MaterialSystem` boundary selects the appropriate strongly typed material-system ABI.

## Usage

The `source_sdk` target in `native/CMakeLists.txt` searches only this directory's `sdk/`, `sdk/public/`, and `sdk/public/tier0/`. Engine interfaces and their mathlib, tier0/tier1, enum, and utility dependencies are maintained as ordinary repository files.

`sdk/lib/public/tier0.lib` and `sdk/lib/public/x64/tier0.lib` are the x86 and x64 import libraries, with their `.def` files retained. The LZMA decoder in `native/include/lzma/` is independent of the engine SDK.

| CMake `GMOD_BRANCH` | Header macros | `IAppSystem` base virtual methods | Accepted runtime ABI |
| --- | --- | ---: | --- |
| `auto` (default, x64 only) | `GMOD_SDK_PUBLIC` + module `MCSWEP_AUTO_BRANCH` | Both 5 and 9 | public / beta |
| `public` | `GMOD_SDK_PUBLIC` | 5 | public |
| `x86-64` | `GMOD_SDK_X86_64` | 9 | beta |

Public supports Windows x86 and x64; beta builds only a Windows x64 module. The `x86` in the beta branch name does not mean a 32-bit module.

`IAppSystemPublic` declares the original five methods. `IAppSystemX86_64` adds beta's `GetDependencies`, `GetTier`, `Reconnect`, and `IsSingleton`. `IAppSystem` retains the Source name for the compile-time default branch. `IMaterialSystemBase<TAppSystem>` shares method declarations, while `IMaterialSystemPublic` and `IMaterialSystemX86_64` use distinct base layouts to avoid conflicting definitions of one type. `IMaterialSystem` remains the compile-time default. Calls use normal C++ virtual dispatch.

On x64, the DLL entry point first inspects the factory object's material-system ABI without modifying it, selects an implementation, and registers the restore callback. Shared algorithms and Lua exports do not branch. `auto` is the universal x64 build; fixed-branch builds reject the other ABI.

`BRANCH` identifies the Steam beta selection, not a standalone installation's binary ABI: the local public 2026.09.17 client also returns `x86-64` when that Steam branch is selected. Fixed-public x86 builds retain the `BRANCH=unknown` check.

`Render/Source/MaterialSystemAbi.h` checks verified x64 instruction shapes for `GetHardwareConfig` (slots 14/18) and `GetCurrentConfigForVideoCard` (17/21), ignoring only addresses and member offsets. Reads are restricted to readable/executable PE sections of the loaded materialsystem module. Slots are used only for detection; subsequent calls use the strongly typed SDK. If both candidates match, neither matches, or a memory range is invalid, initialization fails with a Lua error before any engine virtual call. Compiler changes to these instruction shapes require another audit.

After loading, `mcmesh.EngineBranch` is `public` or `x86-64`.

## Upstream sources

Repository: `https://github.com/danielga/sourcesdk-minimal`.

- Copy baseline: `x86-64-branch`, commit `99cafecf352ef5e6af6b1dade2566a8680039152`.
- Public comparison: `master`, commit `ab7be3ebe52c608bbf7b846f757fe18886b9f305`.
- Preserve Valve copyright headers, this directory's `LICENSE`, and `thirdpartylegalnotices.txt` when distributing. Vendored dependencies retain their own licenses.

Core engine interfaces:

```text
public/appframework/IAppSystem.h
public/materialsystem/imaterialsystem.h
public/materialsystem/MaterialSystem_Config.h
public/materialsystem/imaterial.h
public/materialsystem/imaterialvar.h
public/materialsystem/imesh.h
public/materialsystem/meshreader.h
public/materialsystem/itexture.h
public/materialsystem/imaterialsystemhardwareconfig.h
public/vtf/vtf.h
```

Local adaptations comprise explicit branch types and shared declarations for `IAppSystem` / `IMaterialSystem`, platform/default-branch constraints in `gmod/branch.h`, and x86/x64 size assertions for `IMaterialVar` and mesh descriptors. These assertions constrain compiled layouts; they do not establish runtime engine correctness. Other declarations retain upstream shapes, without padding functions for unknown slots.

## Verified scope

Maintenance covers the material, mesh, texture, and VTF prefixes used by this project, rather than a complete Garry's Mod SDK. VTF tails differ between branches. Unaudited upstream tail declarations are not callable contracts; a header's presence does not authorize new calls. Entity and player interfaces in `server.dll` / `client.dll` are outside this scope. Garry's Mod Lua headers live in `native/include/GarrysMod/`.

## Updating

1. Record the new DLL's SHA-256, branch, PE timestamp, and available depot manifest before analyzing addresses. Do not reuse old RVAs after automatic updates.
2. Find the actual factory object's primary and secondary vtables; verify signatures, inheritance, and member offsets. Identical interface-version strings do not imply identical ABIs, and MSVC overload slots cannot be inferred by counting header lines.
3. Update declarations in the relevant Source headers, retaining names and directories. Business code must not maintain another numeric-slot table. Do not guess unverified signatures or compensate with automatic offsets.
4. Update build/SDK documentation. Revise verification conclusions only after user-arranged builds for both branches, CPU regressions, and in-engine Source-resource checks. Formatting and tidy exclude this directory.
