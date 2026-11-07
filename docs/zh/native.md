# Native 模块

[English](../native.md) | 简体中文

Native 模块是可选的 Windows 客户端二进制模块 `minemod_native`，加载后在 Lua 中注册全局表 `mcmesh`。基础世界与玩法可使用 Lua 后端；装上它，客户端可把世界存储、光照传播、区段建面和部分资源处理交给 C++。资源包 ZIP 读取等能力另有 Native 要求，见下文。服务器不使用这个模块。

本文前半部分面向玩家和服务器管理员，后半部分面向从源码构建模块的开发者。修改 C++ 代码前另须阅读 [native-cpp-standard.md](native-cpp-standard.md)。

## 使用

### 加速范围

模块分两层生效。

只要 DLL 成功加载，以下功能就会使用 Native 实现，与 `mc_native_mesh` 无关：

- 资源包：读取 `garrysmod/data/mc/resourcepacks/inbox/` 中的 ZIP 包，计算资源 SHA-256，解码 PNG、生成 mip 并合成图集精灵，上传图集纹理。没有模块时只能使用目录形式的资源包，PNG 解码和图集生成走 Lua。
- L2 角点光照/AO 图集：使用 Native 创建的 procedural 纹理，只上传变化的行。没有模块时改用 Lua 渲染目标绘制。

`mc_native_mesh 1` 启用 Native 后端后，另外接管：

- 客户端已同步世界的方块状态存储，二进制区块包（MCB9）在工作线程解码；
- 方块光、天空光在工作线程增量传播；
- 整方块、受支持的模型、楼梯/半砖/栅栏/墙/玻璃板等基础形状、水和岩浆的建面，以及四角光照与 AO 计算；光照变化而几何不变时只重算光照；
- 地形绘制循环、后台可见性计算和背向面索引范围剔除（见下文三个 `mc_native_draw*` 开关）。

仍由 Lua 负责的部分：服务端逻辑与网络协议、特殊方块的 emitter、section 调度、材质与光影包，以及 Source 网格创建、上传和发布（这些在主线程执行）。资源包图集超过一页时，地形改走 Lua 准备、Native 计算的通用路径。

后台 CPU 任务（解码、光照、可见性、建面）共用一个并发上限：硬件线程数减 2，限制在 1～8 之间。

### 选择 DLL 文件

文件名由游戏进程的位数决定，与 Steam 分支名无关：

| 客户端 | 文件名 | 可用的构建 |
| --- | --- | --- |
| 64 位，public 引擎 | `gmcl_minemod_native_win64.dll` | `auto` |
| 64 位，x86-64 beta 引擎 | `gmcl_minemod_native_win64.dll` | `auto`（推荐） |
| 32 位，public 分支 | `gmcl_minemod_native_win32.dll` | `public` x86 |
| 32 位，x86-64 beta 分支 | 不支持 | — |

- 三种 x64 构建的文件名相同。`auto` 构建同时包含 public 与 beta 两套材质系统接口，加载时检查已载入的 `materialsystem.dll` 选择其一，不读取 `BRANCH`。固定分支的 x64 构建只接受对应的引擎，否则拒绝加载。
- 32 位构建只支持 public，加载时要求 `BRANCH` 为 `unknown`，x86-64 分支的 32 位客户端会被拒绝。
- 不确定位数时，可执行 `mc_native_status`：模块缺失时，它显示加载器期望的路径（含 `win32` 或 `win64`）。

### 安装

1. 完整退出游戏。
2. 把 DLL 复制到客户端的 `garrysmod/lua/bin/`（目录不存在时新建），即 `<GarrysMod>/garrysmod/lua/bin/gmcl_minemod_native_win64.dll`。
3. 启动游戏并进入装有 MineMod 的服务器或单人游戏。
4. 需要 Native 后端时，在设置的“画面与网格 → 原生网格后端”中打开“使用原生网格后端”，或在控制台执行 `mc_native_mesh 1`。该值会存档，默认为 `0`。

加载器每次进入游戏只探测一次模块。替换、删除 DLL 都要先完整退出游戏。DLL 动态链接 MSVC 运行库；如果提示找不到依赖模块，请安装与游戏位数相同的 Microsoft Visual C++ 2015–2022 可再发行组件。

服务器管理员：

- 服务器上无需也不会加载此模块，`gmcl_` 前缀的模块只在客户端加载。
- 服务器不会把 DLL 发送给客户端，DLL 也不能打进 addon 或创意工坊 GMA。需要的玩家自行安装。
- 服务器不检查客户端是否装有模块。装与不装的玩家可以在同一服务器上游戏，看到同一个世界。

### 确认加载

进入游戏后在控制台执行：

```text
mc_native_status
```

第一行格式为：

```text
[MC Native L2] requested=<mc_native_mesh> active=<是否启用> available=<是否可用> layout=mc:quad_corners_v1 scheduler=Lua-sections execution=worker-pool
```

- `available=false` 时，下一行给出原因，例如 `module not installed: lua/bin/gmcl_minemod_native_win64.dll`。
- `available=true active=false`：模块可用，但 `mc_native_mesh` 为 0；此时资源包和光照图集加速已经生效。
- 后端启用后，状态表中应有 `mode=native_world_l2`、`worldBackend=native`、`worldLightBackend=native_worker`、`meshExecution=native_world_workers_lua_sections`、`terrainBackend=native_models_shapes_fluids_lua_specials`。`fullTakeover=false` 是正常值，表示特殊方块、调度和 GPU 发布仍在 Lua。

之后依次打印模块统计（`GetL2Stats`）以及 Lua 侧计数，如 `committedSections`、`relightSections`、`fluidWorkerAvailable`。

切换 `mc_native_mesh` 时控制台输出：

```text
[MC Native L2] Enabled (Native workers, Lua section scheduler); previous meshes cleared; section rebuilds queued.
[MC Native L2] Disabled (Lua L2); previous meshes cleared; section rebuilds queued.
```

这只表示重建已经排队，不表示新网格已全部完成。值未改变时不会输出。

允许运行客户端 Lua 时（单人游戏，或服务器开启 `sv_allowcslua`），还可以检查进程位数和模块选中的引擎接口：

```text
lua_run_cl print(BRANCH, jit.arch, mcmesh and mcmesh.EngineBranch, mcmesh and mcmesh.AbiVersion())
```

`mcmesh.EngineBranch` 为 `public` 或 `x86-64`，`AbiVersion()` 当前为 `8`。

### 没有模块或加载失败时

加载器（`addons/mc_engine/lua/autorun/mc_load.lua`）在客户端启动时按 `jit.arch` 查找 `lua/bin/` 下对应的文件，找到后 `require( "minemod_native" )`，检查 `AbiVersion()` 是否等于 `8`，以及必需的导出是否齐全。约 1 秒后在聊天栏提示：

| 情况 | 提示 | 结果 |
| --- | --- | --- |
| 没有找到文件 | 黄色“未检测到优化 DLL”，附下载地址 | 使用 Lua 后端，Native 设置分类隐藏 |
| ABI 低于 8 | “Native DLL 版本过期（当前 ABI x，需要 ABI 8）” | 使用 Lua 后端 |
| 模块初始化报错、ABI 高于 8、缺少导出 | 红色“Native DLL 初始化失败”及原因，并记录故障 `native_module_init_failed` | 使用 Lua 后端 |
| 非 Windows 或未知架构 | 无提示 | 使用 Lua 后端 |

这三种提示出现时同时注册 `mc_native_download` 命令，在浏览器中打开 `mc_load.lua` 中的下载地址。

无模块时渲染 section 同样为 16³；这不同于 `16×16×32` 的存储 chunk。世界、建造和光影仍可用 Lua 路径运行，加载和重建通常较慢；ZIP 资源源等专属能力仍需模块。

运行期间：

- 模块可用但缺少当前 Lua 需要的 L2 接口时，设置 `mc_native_mesh 1` 会记录一次故障 `native_mesh_l2_unavailable`，世界保持 Lua 所有，设置值保留。启用过程中世界移交失败记录 `native_mesh_switch_failed`，同样保留原状态。
- 启用成功后，单个 section 的构建、上传或发布失败只记录故障并保留旧的 section，不会自动切回 Lua，也不会清空世界。
- 切换后端时先清空已加载 chunk 的旧网格，再逐个 section 重建，重建期间部分地形暂时不可见。方块数据、碰撞和光影包设置不受影响。启用时先把 Lua 世界导入 Native 并校验，关闭时先恢复 Lua 存储再关闭 Native 会话。
- 资源包和图集加速只检查自己需要的函数是否存在，不参考加载器的 ABI 判定。遇到 ABI 提示时应更换 DLL，而不是依赖这些功能继续工作。

### ConVar 与命令

| ConVar | 默认 | 作用 |
| --- | --- | --- |
| `mc_native_mesh` | `0` | `1` 启用 Native 后端（世界存储、光照、建面、绘制）；`0` 使用 Lua。存档。 |
| `mc_native_draw` | `1` | Native 后端启用时使用 C++ 绘制循环；`0` 改用 Lua 绘制循环作对照，不切换世界或建面后端。 |
| `mc_native_draw_worker` | `1` | 在后台线程计算保守可见性并复用结果；`0` 每帧在 C++ 中同步计算。 |
| `mc_native_draw_directions` | `1` | 跳过背向相机的索引范围；`0` 提交完整索引。 |

后三个开关只在 Native 后端启用时生效，修改后无需重建网格。`mc_mesh_frustum_cull`、`mc_mesh_occlusion_cull`、绘制距离等通用渲染设置继续生效。

设置界面的“原生网格后端”分类中还列有 `mc_native_think_ms`。它属于已停用的旧 L1 后端，当前加载的代码没有注册这个 ConVar，修改它没有效果。

| 命令 | 作用 |
| --- | --- |
| `mc_native_status` | 打印可用性、启用状态、世界会话状态和模块统计。 |
| `mc_native_toggle` | 在 `mc_native_mesh 0` 与 `1` 之间切换。 |
| `mc_native_fallbacks` | 列出处理次数最多的 32 个仍走 Lua emitter 的方块状态，计数包含重复重建。 |
| `mc_native_download` | 打开下载页面；只在出现缺失、过期或失败提示时注册。 |
| `mc_native_load_profile` | 打印最近一次存档或快照载入的 hydrate 耗时与 chunk、格数。 |
| `mc_mesh_cull_stats` | 剔除统计；Native 绘制启用时另有 `[MC native cull work]` 一行。 |
| `mc_faults` | 列出已记录的故障及次数。 |

### 故障排除

| 现象 | 处理 |
| --- | --- |
| `mc_native_status` 显示 `module not installed: ...` | 文件名、位数或目录不对。按提示中的路径放置文件，注意 `win32`/`win64`。 |
| `ABI mismatch` 或版本过期提示 | DLL 与当前 MineMod 版本不配套，换用同一版本构建的 DLL。 |
| `mcmesh: this x86 DLL requires public GMod` | 在 x86-64 分支运行了 32 位客户端。改用 64 位客户端和 win64 DLL，或切回 public 分支。 |
| `mcmesh: this DLL does not contain the detected materialsystem ABI; install the auto build` | 固定分支的 x64 构建装到了另一种引擎上，换用 `auto` 构建。 |
| `mcmesh: unsupported or ambiguous materialsystem ABI; ...` | 游戏更新改变了材质系统，模块无法识别，在发出引擎调用前停止。需要更新模块。 |
| `mcmesh: materialsystem acquire failed` | 未能取得引擎材质系统接口。确认游戏文件完整后重启。 |
| 原因中有 `update the DLL`、`installed DLL has no L2 interface` | DLL 过旧，缺少当前 Lua 需要的接口或版本，换用当前构建。 |
| 替换 DLL 后没有变化 | 加载器每次进入游戏只探测一次，已加载的 DLL 也不会被替换。完整退出游戏后再替换。 |
| 启用后画面异常或地形缺块 | 先执行 `mc_faults` 查看故障；`mc_native_draw 0` 可区分绘制与建面问题，`mc_native_mesh 0` 可与 Lua 后端对照。报告问题时附上 `mc_native_status`、`mc_faults` 的输出和复现步骤。 |

## 从源码构建

### 前置条件

- Windows 和 Visual Studio（脚本通过 `vswhere` 选用最新安装的一份），需安装：
  - MSVC x64/x86 生成工具（组件 `Microsoft.VisualStudio.Component.VC.Tools.x86.x64`）；
  - Windows SDK；
  - “适用于 Windows 的 C++ CMake 工具”，提供 VS 自带的 CMake（不低于 3.24）和 Ninja。
- 初始化两个第三方子模块：

  ```powershell
  git submodule update --init native/include/miniz native/include/rapidjson-master
  ```

不需要单独下载 Source SDK。`native/sdk/` 已随仓库提交，包含本项目实际使用的 Windows Source 接口头文件，以及 x86（`sdk/lib/public/tier0.lib`）和 x64（`sdk/lib/public/x64/tier0.lib`）的 tier0 导入库。它源自 `danielga/sourcesdk-minimal`，加入了 public 与 x86-64 beta 两套材质系统基类布局。来源提交、本地改动和更新步骤见 [native/sdk/README.md](native/sdk/README.md)。

`native/include/` 中的其他依赖：`GarrysMod/Lua/` 模块头文件、`lzma/` 解码器（均已提交）、`miniz/` 和 `rapidjson-master/`（子模块）。

### `build.ps1`

在仓库根目录执行：

```powershell
.\native\build.ps1                                   # auto，x64，Release_Final
.\native\build.ps1 -Branch public                    # public x64
.\native\build.ps1 -Branch public -Architecture x86  # public x86
.\native\build.ps1 -Branch x86-64                    # x86-64 beta x64
.\native\build.ps1 -Tests                            # 同时构建测试并运行 CTest
```

| 参数 | 取值 | 默认 | 说明 |
| --- | --- | --- | --- |
| `-Configuration` | `Debug`、`Release`、`Release_Final` | `Release_Final` | 见下表。 |
| `-Branch` | `auto`、`public`、`x86-64` | `auto` | 写入 CMake 的 `GMOD_BRANCH`。 |
| `-Architecture` | `x64`、`x86` | `x64` | `x86` 只能配合 `-Branch public`，否则脚本报错。 |
| `-OutputDirectory` | 路径 | `build/<arch>/<preset>/bin` | 相对 `native/` 解析，必须仍在 `native/` 内。省略时会重置先前设置的输出目录。 |
| `-Tests` | 开关 | 关 | 以 `MCSWEP_BUILD_TESTS=ON` 配置，构建后执行 CTest。 |

脚本通过 `vswhere` 定位 Visual Studio，进入对应架构的 Developer PowerShell 环境，用 VS 自带的 CMake 和 Ninja 配置并构建 preset。它只负责构建，不部署 DLL，也不启动游戏。

preset 名为 `<分支>-<配置>`，分支为 `auto`、`public`、`beta`（对应 `-Branch x86-64`），配置为 `debug`、`release`、`release-final`；public x86 为 `public-x86-<配置>`，共 12 个，定义在 `native/CMakePresets.json`。

| 配置 | 编译选项 | CRT |
| --- | --- | --- |
| `Debug` | CMake 的 MSVC Debug 默认值 | `/MDd` |
| `Release` | `/Od /Ob0 /Zi`，保留旧工程关闭优化的行为，不用于发布 | `/MD` |
| `Release_Final` | `/O2 /Ob2 /Zi /GL`，链接 `/LTCG` | `/MD` |

所有配置都生成 PDB。项目代码统一使用 `/W3 /sdl /utf-8 /permissive-`；`cmake/NativeCore.cmake` 中列出的 CPU 源文件额外使用 `/fp:strict`，以保持与 Lua 结果一致的浮点语义。

### 输出

```text
native/build/x64/auto-release-final/bin/gmcl_minemod_native_win64.dll
native/build/x64/public-release-final/bin/gmcl_minemod_native_win64.dll
native/build/x64/beta-release-final/bin/gmcl_minemod_native_win64.dll
native/build/x86/public-x86-release-final/bin/gmcl_minemod_native_win32.dll
```

构建目录为 `native/build/<arch>/<preset>/`，其中有 `compile_commands.json`，供 clang-tidy 使用。`native/build/` 和 `*.dll` 已被 `native/.gitignore` 忽略。发布时使用 `Release_Final`。本地测试时关闭游戏，把产物复制到 `garrysmod/lua/bin/`，再按[安装](#安装)步骤启动。

已配置好的 Developer PowerShell 中也可以直接调用 CMake：

```powershell
Set-Location native
cmake --preset auto-release-final
cmake --build --preset auto-release-final --parallel
```

### 测试

`-Tests` 构建 `native/tests/` 中的测试、基准和探针程序，产物位于 `native/build/<arch>/<preset>/tests/`，随后执行：

```text
ctest --test-dir native/build/<arch>/<preset> --output-on-failure
```

CTest 注册了 12 项：`material_system_abi`、`cpu_work`、`atlas_regions`、`l2_core`、`l2_pixels`、`pixel_texture_data`、`l2_draw`、`l2_workers`、`world_core`、`world_workers`、`world_decode`、`world_mesh`。除 `material_system_abi` 外都链接 CPU 库 `mc_native_core`；`material_system_abi` 用记录下的机器码检查 public/beta 材质系统识别逻辑。这些测试不启动 GMod，不调用 Source 或 GPU，不能证明模块在游戏中加载、绘制或设备恢复正确。

同时构建但不由 CTest 运行的程序：基准 `mc_pixel_texture_data_bench`、`mc_l2_snapshot_bench`、`mc_native_world_light_bench`，探针 `mc_resource_source_probe`、`mc_native_atlas_pixels_probe`、`mc_native_atlas_sprite_probe`、`mc_native_l2_probe`（DLL），以及使用 D3D9 的 `mc_atlas_sampler_dx9`、`mc_material_mips_dx9`。`native/tests/l2_source_lifecycle.lua` 是手动执行的客户端 Source 资源诊断脚本，结果保存在全局变量 `MCNativeL2Lifecycle`，不属于 CTest。

不构建模块、只跑 CPU 测试时，可以把 `native/tests/` 作为独立 CMake 工程：

```powershell
cmake -S native/tests -B <构建目录>
cmake --build <构建目录> --parallel
ctest --test-dir <构建目录> --output-on-failure
```

它不经过 SDK 和模块编译参数，不能作为模块兼容性的结论。按 [AGENTS.md](../../AGENTS.md)，格式检查、静态检查和测试在用户安排时运行。

## 源码结构

CMake 把代码分为两个目标，这是 CPU 代码与引擎代码的硬边界：

- `mc_native_core`（静态库，`cmake/NativeCore.cmake`）：`Core/`、`World/`、`Mesh/`、`Render/Visibility/`、`Resources/` 根目录与 `Resources/Atlas/`。不包含 Lua 或 Source SDK 头文件，测试直接链接它。
- `mcswep_native_mesh`（模块，`CMakeLists.txt`）：`Module/`、`Bindings/`、`Render/Source/`、`Resources/Source/`、`Legacy/`。链接 `mc_native_core` 与 `source_sdk`，使用预编译头 `Module/Pch.h`。

| 目录 | 职责 | 主要文件 |
| --- | --- | --- |
| `Core/` | 所有后台 CPU 任务共用的并发闸门 | `CpuWorkGate` |
| `World/` | 持久世界存储与修订、快照、MCB9/MCSB 传输与解码、光传播 | `WorldStore`、`WorldSession`、`WorldTransport`、`WorldDecoder`、`LightWorker`、`ChunkKey.h` |
| `Mesh/` | 配方、区段建面、四角光照、流体与形状几何、建面任务 | `SectionGeometry`、`SectionWorker`、`SectionTasks`、`FluidGeometry`、`ModelShapes`、`WorldMeshInput`、`LightPixels.h` |
| `Render/Visibility/` | 视锥、方向、portal 遮挡图与后台可见性线程 | `VisibilityGraph`、`VisibilityQuery`、`VisibilityWorker`、`ChunkVisibilityQuery` |
| `Render/Source/` | 材质系统获取与 ABI 识别、Source 网格、已发布网格、绘制计时 | `EngineContext`、`MaterialSystem.h`、`MaterialSystemAbi.h`、`MeshResource`、`PublishedMesh`、`MeshIndex.cpp`、`DrawProfile.h` |
| `Resources/` | 资源包来源（目录/ZIP）、PNG 与图集像素运算、像素数据 | `ResourceSource`、`Atlas/AtlasPixels`、`Atlas/AtlasSprite`、`Atlas/AtlasRegions.h`、`PixelImage.h` |
| `Resources/Source/` | 光照像素纹理、发布屏障与补光事务、资源图集纹理 | `PixelTexture`、`PixelTextureStore`、`AtlasTexture` |
| `Bindings/` | Lua 参数转换、userdata、返回值 | `WorldBindings`、`MeshBindings`、`MeshInputBindings`、`DrawBindings`、`PixelTextureBindings`、`ResourceBindings`、`AtlasSpriteBindings` |
| `Module/` | DLL 入口、引擎分支选择、导出注册、关闭顺序 | `Module.cpp`、`Handshake`、`Pch.h` |
| `Legacy/` | 旧 L1 后端，仍编译并导出，当前 Lua 主路径不调用 | `ChunkMeshBuilder`、`ChunkMeshDraw`、`WorldMirror`、`BlockDefinitions` 等 |
| `tests/` | CTest 测试、基准、探针 | 见上节 |
| `cmake/` | 模块和独立测试工程共用的源文件列表与第三方静态库 | `NativeCore.cmake` |
| `sdk/` | 本项目维护的 Source 接口头文件和 tier0 导入库 | `README.md` |
| `include/` | 第三方头文件与库 | 保持上游布局 |

`GMOD_MODULE_OPEN` 取得材质系统（x64 检查已加载模块的机器码识别 public/beta，x86 检查 `BRANCH` 要求 public），失败时在任何材质系统虚调用之前抛出 Lua 错误；然后初始化 L2 与世界绑定，注册 `mcmesh` 表。`GMOD_MODULE_CLOSE` 先停止并 join 所有工作线程，再释放网格、纹理和资源句柄，最后注销材质系统恢复回调。

Lua 侧的对应文件：

| 文件 | 作用 |
| --- | --- |
| `addons/mc_engine/lua/autorun/mc_load.lua` | 探测、加载模块，检查 ABI 与必需导出，显示提示 |
| `addons/mc_engine/lua/mc/render/cl_native_mesh_config.lua` | `mc_native_mesh` 及启用请求 |
| `addons/mc_engine/lua/mc/render/cl_native_l2_backend.lua` | L2 接口探测、建面提交、结果上传与发布、`mc_native_status` |
| `addons/mc_engine/lua/mc/render/cl_native_world_session.lua` | 世界会话协议、状态目录构建、能力检查 |
| `addons/mc_engine/lua/mc/render/cl_native_world_backend.lua` | 世界所有权在 Lua 与 Native 之间的移交、光照泵 |
| `addons/mc_engine/lua/mc/render/cl_draw.lua` | Native 绘制场景与三个 `mc_native_draw*` 开关 |
| `addons/mc_engine/lua/mc/render/cl_render_l2_resources.lua` | 光照像素纹理 |
| `addons/mc_engine/lua/mc/resources/` | 资源包 ZIP、哈希与图集生成 |

`addons/mc_engine/lua/mc/render/cl_native_mesh_backend.lua` 是旧 L1 后端，当前加载器不加载它。

## Lua 接口

所有导出注册在 `native/Module/Module.cpp`，位于全局表 `mcmesh` 中。这是 MineMod 内部接口，不是给其他 addon 使用的公开 API；参数格式以调用它的 Lua 文件为准。

| 分组 | 导出 |
| --- | --- |
| 身份与版本 | `AbiVersion()`（8）、`EngineBranch`、`AtlasRegionVersion`（1）、`L2Version()`（2）、`L2DrawVersion()`（1）、`L2LightingVersion()`（2）、`L2PixelTextureVersion()`（2）、`L2LightTextureRevision()`、`GetTakeoverCapabilities()` |
| 世界会话 | `CreateWorldSession(config, catalog)` 返回 userdata，方法包括 `ApplyBatch`、`StartBinaryDecode`/`PollBinaryDecode`/`CommitBinaryDecode`、传输（`BeginTransport` 等）、`GetCell`、`GetSectionInfo`、`IsMeshReady`、`GetLight`、`Pump`、`RequestLighting`、`Reconfigure`、`Reset`、`Close`、`GetStats` |
| L2 建面 | `CompileL2Template`/`Cube`/`Model`/`Fluid`、`SubmitL2Section`、`SubmitWorldL2Section`、`SubmitWorldL2Relight`、`PollL2Section`、`CanSubmitL2`、`CancelL2Section`、`GetL2SectionParts`、`GetWorldL2Topology`、`IsWorldL2Current`、`IsWorldL2GeometryCurrent`、`UploadL2PartNative`、`UploadL2MeshPixels`、`StageL2Relight`、`UploadL2Relight`、`UploadL2RelightBatch`、`FinishL2Relight`、`GetL2Stats` |
| L2 诊断 | `BuildL2Mesh`、`UploadL2Part`、`GetL2LightPart`、`ReadL2MeshPixels` |
| L2 绘制 | `CreateL2DrawScene`、`PatchL2DrawScene`、`SetL2DrawGraph`、`SetL2DrawSpatialGraph`、`DrawL2Scene`、`DrawL2SceneBatched`、`L2DrawStats` |
| 像素纹理 | `CreateL2PixelTexture`、`UploadL2PixelTexture`、`FlushL2PixelTextures`、`BindL2PixelTexture`、`ReleaseL2PixelTexture`、`GetL2PixelTextureStats` |
| 资源包与图集 | `ListResourcePackSources`、`OpenResourcePackSource`、`ReadResourcePackSource`、`ResourcePackSourceUnchanged`、`CloseResourcePackSource`、`HashResourceBytes`、`CreateAtlasSprite`、`SampleAtlasSprite`、`UpdateAtlasSpriteTexture`、`ReleaseAtlasSprite`、`GetAtlasSpriteStats`、`CreateAtlasTexture`、`UploadAtlasTextureRect`、`FlushAtlasTexture`、`FlushAtlasTextureUpdates`、`BindAtlasTexture`、`ReleaseAtlasTexture`、`GetAtlasTextureStats` |
| 旧 L1 | `Handshake`、`SetAtlasPageMaterial`、`SetBlockDefs`、`SetLightDefs`、`CreateChunk`、`ApplyChunk`、`SetCellsBatch`、`SetCell`、`Think`、`DrawChunk`、`DrawVisible`、光照重建、光照图集、压缩补丁解码及 `Debug*` 等 |
| 已移除 | `DrawL2MeshPixels`、`DrawL2Relight`、`DrawL2AtlasPixels` 仍保留名称，调用即返回错误 `l2_pixel_rectangles_removed_restart_with_current_lua` |

Lua 分三层检查兼容性：

1. `mc_load.lua` 要求 `AbiVersion() == 8`，并要求 31 个旧 L1 导出存在（列表为 `NATIVE_MODULE_EXPORTS`）。因此删除旧导出会让加载器拒绝模块，即使主路径已不调用它们。
2. `MC.NativeL2.Probe` 要求 L2 建面、像素、绘制函数齐全，`L2Version`、`L2LightingVersion`、`L2PixelTextureVersion` 为 2，`L2DrawVersion` 为 1，`CompileL2Fluid` 存在，并且 `GetTakeoverCapabilities().shapeWorker == 1`。
3. 启用世界会话时要求 `GetTakeoverCapabilities()` 返回 `protocol=2`、`versionEncoding=hex64`，`worldSession`、`stateCatalog`、`binarySection`、`worldLighting`、`l2Snapshot`、`worldAdapter`、`fluidWorker` 均为 1。

`UploadL2RelightBatch`、`IsWorldL2GeometryCurrent`、`SubmitWorldL2Relight` 及能力 `mixedWorldTopology`、`sectionCellFilter`、`nativeTransport`、`catalogShapeReferences` 是可选的，缺少时 Lua 改走较慢的完整路径。

修改接口时：

- 保持已发布的导出名、参数和返回格式。不兼容的改动要同时提升对应版本号并更新 Lua 检查，例如 `ABI_VERSION`（`Module/Handshake.h`）与 `MC.NativeMeshABI`（`mc_load.lua`）。
- 新增能力优先作为可选函数或 `GetTakeoverCapabilities()` 字段，由 Lua 探测。
- 新增导出后同步注册（`Module.cpp`）、Lua 探测和本文。

调试世界会话可用 `mc_native_session_begin`、`mc_native_session_light`、`mc_native_session_close`。它们在独立的开发会话中导入当前世界、触发光照，不改变当前世界的所有权。

## 代码规范

目录职责、命名、排版、所有权与线程、校验和工具用法见 [native-cpp-standard.md](native-cpp-standard.md)。坐标、单位、多返回值和热路径校验的通用规则见 [AGENTS.md](../../AGENTS.md)。
