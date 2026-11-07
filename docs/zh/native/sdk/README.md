# MineMod Source SDK 头文件

[English](../../../../native/sdk/README.md) | 简体中文

这里维护 MineMod 实际使用的 Windows Source 引擎接口。目录、类名、继承、
虚函数和结构体沿用 Source SDK。`IMesh`、`ITexture` 等已核对的共用接口正常调用；
材质系统在 `Render/Source/MaterialSystem` 边界选择对应的强类型 ABI。

## 使用

通过 `native/CMakeLists.txt` 的 `source_sdk` target 使用，只搜索本目录的 `sdk/`、
`sdk/public/` 和 `sdk/public/tier0/`。引擎接口及其依赖的 mathlib、tier0/tier1、
枚举和工具头文件全部作为普通文件由本仓库维护。
`sdk/lib/public/tier0.lib` 与 `sdk/lib/public/x64/tier0.lib` 分别是 x86/x64 导入库，
相应 `.def` 一并保留。LZMA 解码器独立位于 `native/include/lzma/`，不依赖引擎 SDK。

| CMake `GMOD_BRANCH` | 头文件宏 | `IAppSystem` 基类虚函数数 | 接受的实际 ABI |
|---|---|---:|---|
| `auto`（默认，仅 x64） | `GMOD_SDK_PUBLIC` + 模块 `MCSWEP_AUTO_BRANCH` | 同时支持 5/9 | public / beta |
| `public` | `GMOD_SDK_PUBLIC` | 5 | public |
| `x86-64` | `GMOD_SDK_X86_64` | 9 | beta |

public 支持 Windows x86 和 x64；beta 只生成 Windows x64 模块。
beta 分支名称中的 `x86` 不表示生成 32 位模块。
`IAppSystemPublic` 声明原版的 5 个方法，`IAppSystemX86_64` 追加 beta 的
`GetDependencies`、`GetTier`、`Reconnect`、`IsSingleton`。`IAppSystem` 保留编译时
默认分支的 Source 名称；`IMaterialSystemBase<TAppSystem>` 共享原有方法声明，
`IMaterialSystemPublic` / `IMaterialSystemX86_64` 使用不同的基类布局，避免同名类型异定义。
`IMaterialSystem` 仍对应编译时默认分支；所有这些接口仍使用正常 C++ 虚调用。
DLL 入口在 x64 上先只读检查工厂返回对象的材质系统 ABI，再选择对应实现并注册 restore 回调；
共用算法和 Lua 导出不分支。`auto` 用于通用 x64 DLL；固定分支产物仍拒绝另一分支。
`BRANCH` 表示 Steam Beta 分支，不能作为独立安装目录的二进制 ABI 证明：本地 public
2026.09.17 客户端在 Steam 选择 x86-64 时实测也返回 `x86-64`。x86 固定 public 构建
仍保留 `BRANCH=unknown` 检查。
`Render/Source/MaterialSystemAbi.h` 检查已核对的 `GetHardwareConfig`（14/18）和
`GetCurrentConfigForVideoCard`（17/21）两个槽位的 x64 指令形状；只忽略地址/成员位移，
读取范围限定于实际加载的 materialsystem PE 可读/可执行节。槽位只用于检测，后续调用
仍通过强类型 SDK。两个候选都匹配、都不匹配或内存范围无效时，在首次引擎虚调用前
拒绝初始化并给出 Lua 错误，不猜测布局。未来编译器改变这些指令形状时需重新核对。
成功加载后，`mcmesh.EngineBranch` 为 `public` 或 `x86-64`，供控制台确认所选 ABI。

## 上游来源

来源仓库：`https://github.com/danielga/sourcesdk-minimal`。

- 复制基线：`x86-64-branch`，提交 `99cafecf352ef5e6af6b1dade2566a8680039152`。
- public 对照：`master`，提交 `ab7be3ebe52c608bbf7b846f757fe18886b9f305`。
- Valve 版权声明保留在各文件顶部；分发时同时保留本目录的 `LICENSE` 和
  `thirdpartylegalnotices.txt`。vendor 中的第三方依赖仍遵守各自许可。

核心引擎接口：

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

本地改动是 `IAppSystem` / `IMaterialSystem` 的显式分支类型和共用声明、
`gmod/branch.h` 的平台/默认分支约束，以及
`IMaterialVar`、mesh descriptor 的 x86/x64 大小断言。断言用于约束编译布局，
不等于已经完成引擎运行时验证。其余声明保留上游形状，不加入未知槽位填充函数。

## 已核对的边界

当前以本项目调用的材质、网格、纹理和 VTF 前缀为维护范围，不是完整 Garry's Mod SDK。
特别是 VTF 尾部在两个分支间存在差异；尚未核对的上游尾部声明不能作为可调用契约，
不得仅凭头文件存在就新增调用。`server.dll`/`client.dll` 的实体、玩家等接口没有接管。
GarrysMod Lua 头文件位于 `native/include/GarrysMod/`。

## 更新方式

1. 记录新 DLL 的 SHA-256、分支、PE 时间戳及可用的 depot manifest，再使用其地址做分析；
   不把旧 RVA 套到自动更新后的 DLL。
2. 找到工厂实际返回对象及其主/次虚表，核对本项目使用的方法签名、继承和成员偏移。
   接口版本字符串相同不代表 ABI 相同；同名重载也不能按头文件逐行编号推断 MSVC 槽位。
3. 在对应 Source 头文件中修改声明，保持类型名和目录；业务代码不维护另一份数字槽位表。
   未确认的方法不猜签名，不用自动偏移补偿。
4. 同步构建/SDK 文档。由用户安排两个分支的编译、CPU 回归和 Source 资源实机验收后，
   才更新验收结论。格式化和 tidy 不扫描本目录。
