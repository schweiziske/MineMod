# Native module

English | [简体中文](zh/native.md)

The optional Windows client module `minemod_native` registers the global Lua table `mcmesh`. The base world and gameplay work with Lua. Installing the module lets the client move world storage, light propagation, section meshing, and some resource processing into C++. Features such as resource-pack ZIP reading have additional Native requirements described below. Servers do not use this module.

The first half of this guide is for players and server administrators; the second half covers source builds. Read [native-cpp-standard.md](native-cpp-standard.md) before editing C++.

## Usage

### Acceleration scope

The module operates at two levels. Once the DLL loads successfully, these features use Native code regardless of `mc_native_mesh`:

- Resource packs: ZIP sources under `garrysmod/data/mc/resourcepacks/inbox/`, resource SHA-256, PNG decoding, mip generation, atlas-sprite composition, and atlas uploads. Without the module, packs must be directories; Lua handles PNG decoding and atlas generation.
- L2 corner-lighting/AO atlases: Native procedural textures upload only changed rows. Without the module, Lua draws render targets.

Enabling `mc_native_mesh 1` additionally handles:

- Client storage for synchronized block states, with MCB9 binary chunk decoding on workers.
- Incremental block-light and skylight propagation on workers.
- Meshing for full blocks, supported models, basic shapes such as stairs/slabs/fences/walls/panes, water, and lava, including corner lighting and AO. Lighting-only changes reuse geometry.
- Terrain draw loops, background visibility, and back-facing index-range culling, controlled by the three `mc_native_draw*` switches below.

Lua retains server logic and network protocols, special-block emitters, section scheduling, materials and shader packs, and Source mesh creation/upload/publication on the main thread. Multi-page resource-pack atlases use the general path prepared by Lua and computed by Native.

Decoding, lighting, visibility, and meshing share a CPU concurrency limit of hardware threads minus two, clamped to 1–8.

### Choosing a DLL

The game process architecture determines the filename, independently of the Steam branch name:

| Client | Filename | Build |
| --- | --- | --- |
| 64-bit, public engine | `gmcl_minemod_native_win64.dll` | `auto` |
| 64-bit, x86-64 beta engine | `gmcl_minemod_native_win64.dll` | `auto` (recommended) |
| 32-bit, public branch | `gmcl_minemod_native_win32.dll` | `public` x86 |
| 32-bit, x86-64 beta branch | Unsupported | — |

- All three x64 builds have the same filename. `auto` includes both public and beta material-system interfaces and selects one by inspecting the loaded `materialsystem.dll`, without reading `BRANCH`. Fixed-branch x64 builds reject other engines.
- The 32-bit build supports public only and requires `BRANCH` to be `unknown`; the x86-64 branch's 32-bit client is rejected.
- If unsure of architecture, run `mc_native_status`. When the module is missing, it prints the expected path, including `win32` or `win64`.

### Installation

1. Fully exit the game.
2. Copy the DLL to the client's `garrysmod/lua/bin/`, creating the directory if needed: `<GarrysMod>/garrysmod/lua/bin/gmcl_minemod_native_win64.dll`.
3. Launch the game and join a MineMod server or single-player session.
4. To use the Native backend, enable it under **Graphics and meshes → Native mesh backend**, or run `mc_native_mesh 1`. This setting is archived and defaults to `0`.

The loader probes once per game session. Fully exit before replacing or deleting a DLL. The DLL dynamically links the MSVC runtime. If a dependency is missing, install the Microsoft Visual C++ 2015–2022 Redistributable matching the game architecture.

For server administrators:

- The server does not load this module; `gmcl_` modules run on clients.
- Servers do not send DLLs to players, and DLLs cannot be packaged in addons or Workshop GMAs. Players install them themselves.
- Servers do not require clients to have the module. Both client configurations can play together and see the same world.

### Checking the module

Run:

```text
mc_native_status
```

The first line has this format:

```text
[MC Native L2] requested=<mc_native_mesh> active=<enabled> available=<available> layout=mc:quad_corners_v1 scheduler=Lua-sections execution=worker-pool
```

- `available=false`: the next line explains why, for example `module not installed: lua/bin/gmcl_minemod_native_win64.dll`.
- `available=true active=false`: the module is available but `mc_native_mesh` is 0. Resource-pack and light-atlas acceleration is already active.
- With the backend enabled, expect `mode=native_world_l2`, `worldBackend=native`, `worldLightBackend=native_worker`, `meshExecution=native_world_workers_lua_sections`, and `terrainBackend=native_models_shapes_fluids_lua_specials`. `fullTakeover=false` is normal: Lua retains special blocks, scheduling, and GPU publication.

Module statistics (`GetL2Stats`) follow, then Lua counters such as `committedSections`, `relightSections`, and `fluidWorkerAvailable`.

Changing `mc_native_mesh` prints:

```text
[MC Native L2] Enabled (Native workers, Lua section scheduler); previous meshes cleared; section rebuilds queued.
[MC Native L2] Disabled (Lua L2); previous meshes cleared; section rebuilds queued.
```

This confirms that rebuilds were queued, not that all meshes are finished. Unchanged values produce no message.

Where client Lua is allowed (single-player, or `sv_allowcslua` on the server), inspect architecture and the selected engine ABI:

```text
lua_run_cl print(BRANCH, jit.arch, mcmesh and mcmesh.EngineBranch, mcmesh and mcmesh.AbiVersion())
```

`mcmesh.EngineBranch` is `public` or `x86-64`; the current `AbiVersion()` is `8`.

### Missing modules and load failures

At client startup, `addons/mc_engine/lua/autorun/mc_load.lua` uses `jit.arch` to find the DLL under `lua/bin/`, calls `require( "minemod_native" )`, requires `AbiVersion() == 8`, and checks required exports. After about one second, it reports:

| Condition | Message | Result |
| --- | --- | --- |
| File missing | Yellow missing-optimization-DLL notice with download URL | Lua backend; Native settings hidden |
| ABI below 8 | Outdated Native DLL notice, with actual and required ABI | Lua backend |
| Initialization error, ABI above 8, or missing exports | Red initialization-failed notice with reason; fault `native_module_init_failed` | Lua backend |
| Non-Windows or unknown architecture | No notice | Lua backend |

The first three notices also register `mc_native_download`, which opens the download URL configured in `mc_load.lua`.

Without the module, render sections are still 16³, distinct from `16×16×32` storage chunks. Worlds, building, and shader packs work through Lua, usually with slower loading and rebuilding. Exclusive capabilities such as ZIP sources still require the module.

At runtime:

- If required L2 interfaces are missing, `mc_native_mesh 1` records `native_mesh_l2_unavailable`, retains Lua world ownership, and preserves the setting. Failed ownership transfer records `native_mesh_switch_failed` and preserves the previous state.
- After successful activation, a section build/upload/publication failure records a fault and retains the old section. It does not automatically switch to Lua or clear the world.
- Switching backends clears old meshes for loaded chunks and rebuilds sections, temporarily hiding some terrain. Block data, collision, and shader-pack settings remain intact. Enabling first imports and validates the Lua world; disabling restores Lua storage before closing the Native session.
- Resource-pack and atlas acceleration check their required functions independently of the loader ABI check. Replace the DLL when an ABI notice appears.

### ConVars and commands

| ConVar | Default | Purpose |
| --- | --- | --- |
| `mc_native_mesh` | `0` | Archived backend selection: `1` Native storage, lighting, meshing, and drawing; `0` Lua. |
| `mc_native_draw` | `1` | C++ draw loop with the Native backend; `0` uses Lua drawing for comparison without changing world or meshing backends. |
| `mc_native_draw_worker` | `1` | Background conservative visibility with result reuse; `0` computes synchronously in C++ each frame. |
| `mc_native_draw_directions` | `1` | Skip back-facing index ranges; `0` submits all indices. |

The last three apply only while the Native backend is active and do not require mesh rebuilds. General settings such as `mc_mesh_frustum_cull`, `mc_mesh_occlusion_cull`, and draw distance still apply.

The settings UI also lists `mc_native_think_ms`. It belongs to the inactive legacy L1 backend and is not registered by the currently loaded code; changing it has no effect.

| Command | Purpose |
| --- | --- |
| `mc_native_status` | Availability, activation, world-session state, and module statistics. |
| `mc_native_toggle` | Toggle `mc_native_mesh` between 0 and 1. |
| `mc_native_fallbacks` | Top 32 block states still using Lua emitters, including repeated rebuilds in the counts. |
| `mc_native_download` | Open the download page; registered only for missing/outdated/failed notices. |
| `mc_native_load_profile` | Hydration time, chunk count, and cell count for the latest save or snapshot load. |
| `mc_mesh_cull_stats` | Culling statistics, with an extra `[MC native cull work]` line for Native drawing. |
| `mc_faults` | Recorded faults and counts. |

### Troubleshooting

| Symptom | Action |
| --- | --- |
| `module not installed: ...` | Check filename, architecture, and directory against the reported `win32`/`win64` path. |
| `ABI mismatch` or outdated notice | Use a DLL built for the same MineMod version. |
| `mcmesh: this x86 DLL requires public GMod` | Use the 64-bit client and win64 DLL, or switch to public. |
| `mcmesh: this DLL does not contain the detected materialsystem ABI; install the auto build` | Replace the fixed-branch x64 build with `auto`. |
| `mcmesh: unsupported or ambiguous materialsystem ABI; ...` | An engine update changed the material system. Initialization stopped before engine calls; update the module. |
| `mcmesh: materialsystem acquire failed` | Verify game files and restart. |
| `update the DLL` or `installed DLL has no L2 interface` | Install the current build with the required interface/version. |
| Replacing the DLL has no effect | Fully exit first; the loader probes only once, and loaded DLLs cannot be replaced. |
| Broken rendering or missing terrain after enabling | Inspect `mc_faults`. Compare `mc_native_draw 0` for drawing issues and `mc_native_mesh 0` for Lua behavior. Include status, faults, and reproduction steps in reports. |

## Building from source

### Prerequisites

- Windows and Visual Studio, selected through `vswhere` using the newest installation, with MSVC x64/x86 build tools (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`), Windows SDK, and **C++ CMake tools for Windows** supplying CMake 3.24+ and Ninja.
- Initialize the two third-party submodules:

```powershell
git submodule update --init native/include/miniz native/include/rapidjson-master
```

No separate Source SDK download is required. `native/sdk/` contains the Windows Source headers used here and x86 (`sdk/lib/public/tier0.lib`) and x64 (`sdk/lib/public/x64/tier0.lib`) tier0 import libraries. It derives from `danielga/sourcesdk-minimal` with separate public and x86-64 beta material-system base layouts. See [SDK sources and maintenance](../native/sdk/README.md).

Other `native/include/` dependencies are committed `GarrysMod/Lua/` headers and the `lzma/` decoder, plus the `miniz/` and `rapidjson-master/` submodules.

### build.ps1

Run at the repository root:

```powershell
.\native\build.ps1                                   # auto, x64, Release_Final
.\native\build.ps1 -Branch public                    # public x64
.\native\build.ps1 -Branch public -Architecture x86  # public x86
.\native\build.ps1 -Branch x86-64                    # x86-64 beta x64
.\native\build.ps1 -Tests                            # Build tests and run CTest
```

| Parameter | Values | Default | Meaning |
| --- | --- | --- | --- |
| `-Configuration` | `Debug`, `Release`, `Release_Final` | `Release_Final` | See below. |
| `-Branch` | `auto`, `public`, `x86-64` | `auto` | CMake `GMOD_BRANCH`. |
| `-Architecture` | `x64`, `x86` | `x64` | `x86` requires `-Branch public`. |
| `-OutputDirectory` | Path | `build/<arch>/<preset>/bin` | Relative to `native/` and must remain inside it. Omitting resets a previously configured output path. |
| `-Tests` | Switch | Off | Configure `MCSWEP_BUILD_TESTS=ON`, then run CTest after building. |

The script locates Visual Studio, enters the target architecture's Developer PowerShell environment, and configures/builds with VS's CMake and Ninja. It does not deploy DLLs or launch the game.

Preset names are `<branch>-<configuration>`: branches `auto`, `public`, and `beta` (`-Branch x86-64`); configurations `debug`, `release`, and `release-final`. Public x86 uses `public-x86-<configuration>`. The 12 presets are in `native/CMakePresets.json`.

| Configuration | Compiler options | CRT |
| --- | --- | --- |
| `Debug` | CMake's MSVC Debug defaults | `/MDd` |
| `Release` | `/Od /Ob0 /Zi`; unoptimized compatibility configuration, not for releases | `/MD` |
| `Release_Final` | `/O2 /Ob2 /Zi /GL`, link `/LTCG` | `/MD` |

All configurations generate PDBs. Project code uses `/W3 /sdl /utf-8 /permissive-`. CPU sources listed in `cmake/NativeCore.cmake` also use `/fp:strict` for floating-point semantics matching Lua.

### Output

```text
native/build/x64/auto-release-final/bin/gmcl_minemod_native_win64.dll
native/build/x64/public-release-final/bin/gmcl_minemod_native_win64.dll
native/build/x64/beta-release-final/bin/gmcl_minemod_native_win64.dll
native/build/x86/public-x86-release-final/bin/gmcl_minemod_native_win32.dll
```

Build directories are `native/build/<arch>/<preset>/` and contain `compile_commands.json` for clang-tidy. `native/.gitignore` excludes `native/build/` and `*.dll`. Publish `Release_Final`. For local testing, close the game, copy the DLL into `garrysmod/lua/bin/`, and follow [installation](#installation).

In a configured Developer PowerShell environment:

```powershell
Set-Location native
cmake --preset auto-release-final
cmake --build --preset auto-release-final --parallel
```

### Tests

`-Tests` builds tests, benchmarks, and probes in `native/tests/`, writes them to `native/build/<arch>/<preset>/tests/`, then executes:

```text
ctest --test-dir native/build/<arch>/<preset> --output-on-failure
```

CTest registers 12 tests: `material_system_abi`, `cpu_work`, `atlas_regions`, `l2_core`, `l2_pixels`, `pixel_texture_data`, `l2_draw`, `l2_workers`, `world_core`, `world_workers`, `world_decode`, and `world_mesh`. All except `material_system_abi` link `mc_native_core`; that test checks public/beta detection against recorded machine code. These tests do not launch GMod or call Source/GPU resources, so they do not establish correct in-game loading, drawing, or device recovery.

Also built, but not run by CTest: benchmarks `mc_pixel_texture_data_bench`, `mc_l2_snapshot_bench`, `mc_native_world_light_bench`; probes `mc_resource_source_probe`, `mc_native_atlas_pixels_probe`, `mc_native_atlas_sprite_probe`, `mc_native_l2_probe` (DLL); and D3D9 programs `mc_atlas_sampler_dx9`, `mc_material_mips_dx9`. The manual client diagnostic `native/tests/l2_source_lifecycle.lua` stores results in global `MCNativeL2Lifecycle` and is not a CTest test.

For CPU tests without a module build, use the independent project:

```powershell
cmake -S native/tests -B <build-directory>
cmake --build <build-directory> --parallel
ctest --test-dir <build-directory> --output-on-failure
```

This bypasses SDK/module compiler settings and does not establish module compatibility. Run formatting, static checks, and tests as arranged by the user under [AGENTS.md](../AGENTS.md).

## Source organization

CMake defines a strict CPU/engine boundary:

- `mc_native_core` (static library, `cmake/NativeCore.cmake`): `Core/`, `World/`, `Mesh/`, `Render/Visibility/`, the `Resources/` root, and `Resources/Atlas/`. No Lua/Source SDK includes; tests link directly.
- `mcswep_native_mesh` (module, `CMakeLists.txt`): `Module/`, `Bindings/`, `Render/Source/`, `Resources/Source/`, and `Legacy/`. Links `mc_native_core` and `source_sdk`, using `Module/Pch.h`.

| Directory | Responsibility | Main files |
| --- | --- | --- |
| `Core/` | Shared concurrency gate for all background CPU tasks | `CpuWorkGate` |
| `World/` | Persistent storage, revisions, snapshots, MCB9/MCSB transport/decoding, and light propagation | `WorldStore`, `WorldSession`, `WorldTransport`, `WorldDecoder`, `LightWorker`, `ChunkKey.h` |
| `Mesh/` | Recipes, section meshing, corner lighting, fluid/shape geometry, and mesh tasks | `SectionGeometry`, `SectionWorker`, `SectionTasks`, `FluidGeometry`, `ModelShapes`, `WorldMeshInput`, `LightPixels.h` |
| `Render/Visibility/` | Frustum/directional/portal culling graphs and background visibility | `VisibilityGraph`, `VisibilityQuery`, `VisibilityWorker`, `ChunkVisibilityQuery` |
| `Render/Source/` | Material-system acquisition and ABI detection, Source meshes, published meshes, and draw timing | `EngineContext`, `MaterialSystem.h`, `MaterialSystemAbi.h`, `MeshResource`, `PublishedMesh`, `MeshIndex.cpp`, `DrawProfile.h` |
| `Resources/` | Directory/ZIP resource sources, PNG/atlas pixel operations, and pixel data | `ResourceSource`, `Atlas/AtlasPixels`, `Atlas/AtlasSprite`, `Atlas/AtlasRegions.h`, `PixelImage.h` |
| `Resources/Source/` | Light-pixel textures, publication barriers, relighting transactions, and resource atlas textures | `PixelTexture`, `PixelTextureStore`, `AtlasTexture` |
| `Bindings/` | Lua argument conversion, userdata, and returns | `WorldBindings`, `MeshBindings`, `MeshInputBindings`, `DrawBindings`, `PixelTextureBindings`, `ResourceBindings`, `AtlasSpriteBindings` |
| `Module/` | DLL entry, engine selection, export registration, and shutdown | `Module.cpp`, `Handshake`, `Pch.h` |
| `Legacy/` | Legacy L1 backend, compiled/exported but unused by the current Lua main path | `ChunkMeshBuilder`, `ChunkMeshDraw`, `WorldMirror`, `BlockDefinitions` and others |
| `tests/` | CTest tests, benchmarks, and probes | See above |
| `cmake/` | Shared source lists and third-party static libraries for the module and independent tests | `NativeCore.cmake` |
| `sdk/` | Maintained Source headers and tier0 libraries | `README.md` |
| `include/` | Third-party headers and libraries | Preserve upstream layout |

`GMOD_MODULE_OPEN` acquires the material system (x64 detects public/beta from loaded machine code; x86 requires public via `BRANCH`). Failures raise a Lua error before material-system virtual calls. It then initializes L2/world bindings and registers `mcmesh`. `GMOD_MODULE_CLOSE` stops and joins all workers, releases meshes, textures, and resource handles, then unregisters the material-system restore callback.

Lua counterparts:

| File | Purpose |
| --- | --- |
| `addons/mc_engine/lua/autorun/mc_load.lua` | Probe/load the module, validate ABI/exports, and display notices |
| `addons/mc_engine/lua/mc/render/cl_native_mesh_config.lua` | mc_native_mesh and activation requests |
| `addons/mc_engine/lua/mc/render/cl_native_l2_backend.lua` | L2 probing, mesh submission, upload/publication, and mc_native_status |
| `addons/mc_engine/lua/mc/render/cl_native_world_session.lua` | World-session protocol, state catalog, and capability checks |
| `addons/mc_engine/lua/mc/render/cl_native_world_backend.lua` | Lua/Native world ownership transfer and lighting pump |
| `addons/mc_engine/lua/mc/render/cl_draw.lua` | Native draw scenes and mc_native_draw* switches |
| `addons/mc_engine/lua/mc/render/cl_render_l2_resources.lua` | Light-pixel textures |
| `addons/mc_engine/lua/mc/resources/` | Resource-pack ZIP reading, hashing, and atlas generation |

`addons/mc_engine/lua/mc/render/cl_native_mesh_backend.lua` is the legacy L1 backend and is not loaded by the current loader.

## Lua interface

All exports are registered in `native/Module/Module.cpp` under global `mcmesh`. This is an internal MineMod interface, not a public addon API. Calling Lua files define argument formats.

| Group | Exports |
| --- | --- |
| Identity and versions | `AbiVersion()` (8), `EngineBranch`, `AtlasRegionVersion` (1), `L2Version()` (2), `L2DrawVersion()` (1), `L2LightingVersion()` (2), `L2PixelTextureVersion()` (2), `L2LightTextureRevision()`, `GetTakeoverCapabilities()` |
| World sessions | `CreateWorldSession(config, catalog)` returns userdata with methods `ApplyBatch`, `StartBinaryDecode`/`PollBinaryDecode`/`CommitBinaryDecode`, transport (`BeginTransport` and others), `GetCell`, `GetSectionInfo`, `IsMeshReady`, `GetLight`, `Pump`, `RequestLighting`, `Reconfigure`, `Reset`, `Close`, `GetStats` |
| L2 meshing | `CompileL2Template`/`Cube`/`Model`/`Fluid`, `SubmitL2Section`, `SubmitWorldL2Section`, `SubmitWorldL2Relight`, `PollL2Section`, `CanSubmitL2`, `CancelL2Section`, `GetL2SectionParts`, `GetWorldL2Topology`, `IsWorldL2Current`, `IsWorldL2GeometryCurrent`, `UploadL2PartNative`, `UploadL2MeshPixels`, `StageL2Relight`, `UploadL2Relight`, `UploadL2RelightBatch`, `FinishL2Relight`, `GetL2Stats` |
| L2 diagnostics | `BuildL2Mesh`, `UploadL2Part`, `GetL2LightPart`, `ReadL2MeshPixels` |
| L2 drawing | `CreateL2DrawScene`, `PatchL2DrawScene`, `SetL2DrawGraph`, `SetL2DrawSpatialGraph`, `DrawL2Scene`, `DrawL2SceneBatched`, `L2DrawStats` |
| Pixel textures | `CreateL2PixelTexture`, `UploadL2PixelTexture`, `FlushL2PixelTextures`, `BindL2PixelTexture`, `ReleaseL2PixelTexture`, `GetL2PixelTextureStats` |
| Resource packs and atlases | `ListResourcePackSources`, `OpenResourcePackSource`, `ReadResourcePackSource`, `ResourcePackSourceUnchanged`, `CloseResourcePackSource`, `HashResourceBytes`, `CreateAtlasSprite`, `SampleAtlasSprite`, `UpdateAtlasSpriteTexture`, `ReleaseAtlasSprite`, `GetAtlasSpriteStats`, `CreateAtlasTexture`, `UploadAtlasTextureRect`, `FlushAtlasTexture`, `FlushAtlasTextureUpdates`, `BindAtlasTexture`, `ReleaseAtlasTexture`, `GetAtlasTextureStats` |
| Legacy L1 | `Handshake`, `SetAtlasPageMaterial`, `SetBlockDefs`, `SetLightDefs`, `CreateChunk`, `ApplyChunk`, `SetCellsBatch`, `SetCell`, `Think`, `DrawChunk`, `DrawVisible`, lighting rebuilds, light atlases, compressed-patch decoding, and `Debug*` and others |
| Removed | `DrawL2MeshPixels`, `DrawL2Relight`, `DrawL2AtlasPixels` retain their names but always return error `l2_pixel_rectangles_removed_restart_with_current_lua` |

Lua checks compatibility at three levels:

1. `mc_load.lua` requires `AbiVersion() == 8` and all 31 legacy L1 exports listed in `NATIVE_MODULE_EXPORTS`. Removing an unused legacy export still causes rejection.
2. `MC.NativeL2.Probe` requires L2 mesh, pixel, and draw functions; `L2Version`, `L2LightingVersion`, and `L2PixelTextureVersion` equal to 2; `L2DrawVersion` equal to 1; `CompileL2Fluid`; and `GetTakeoverCapabilities().shapeWorker == 1`.
3. World sessions require `protocol=2`, `versionEncoding=hex64`, and `worldSession`, `stateCatalog`, `binarySection`, `worldLighting`, `l2Snapshot`, `worldAdapter`, and `fluidWorker` all equal to 1.

`UploadL2RelightBatch`, `IsWorldL2GeometryCurrent`, `SubmitWorldL2Relight`, and capabilities `mixedWorldTopology`, `sectionCellFilter`, `nativeTransport`, and `catalogShapeReferences` are optional. Lua uses the slower complete path when they are missing.

When changing interfaces:

- Preserve published export names, arguments, and return formats. Bump the relevant version and Lua checks for incompatible changes, such as `ABI_VERSION` in `Module/Handshake.h` and `MC.NativeMeshABI` in `mc_load.lua`.
- Prefer optional functions or `GetTakeoverCapabilities()` fields that Lua probes.
- Update registration in `Module.cpp`, Lua probes, and this guide for new exports.

`mc_native_session_begin`, `mc_native_session_light`, and `mc_native_session_close` import the current world and trigger lighting in an independent development session without changing active-world ownership.

## Code standard

See [native-cpp-standard.md](native-cpp-standard.md) for responsibilities, naming, formatting, ownership, threading, validation, and tools. General coordinate, unit, multiple-return, and hot-path rules are in [AGENTS.md](../AGENTS.md).
