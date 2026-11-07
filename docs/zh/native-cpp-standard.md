# Native C++ 代码规范

[English](../native-cpp-standard.md) | 简体中文

用于 `native/` 中项目维护的代码。排版、检查与缩进配置分别为
[`native/.clang-format`](../../native/.clang-format)、[`.clang-tidy`](../../native/.clang-tidy)
及 [`.editorconfig`](../../native/.editorconfig)。第三方库和生成文件保持原样；
`native/sdk/` 保留上游命名、排版、继承与虚函数布局，按 ABI 单独审查。

## 职责与依赖

| 目录 | 职责 |
| --- | --- |
| `Core/` | 共用基础设施、CPU 并发闸门。 |
| `World/` | 世界存储、修订、快照、传输解码、光传播。 |
| `Mesh/` | 配方、区段几何、流体与模型形状、采光及建面任务。 |
| `Render/Visibility/` | 纯 CPU 可见性数据、图构建、查询及后台 worker。 |
| `Render/Source/` | 材质系统 ABI、引擎网格、绘制和发布资源。 |
| `Resources/`、`Resources/Atlas/` | 资源来源、图集、PNG 和像素运算。 |
| `Resources/Source/` | 引擎纹理、发布屏障与补光事务。 |
| `Bindings/` | Lua 参数转换、userdata、返回值。 |
| `Module/` | DLL 入口、初始化、导出注册和关闭。 |
| `Legacy/` | 仍需保留的旧实现及兼容入口。 |
| `tests/`、`cmake/` | 测试/探针/基准，以及共用构建列表。 |
| `include/`、`sdk/`、`build/` | 第三方依赖、维护的 Source 接口、构建产物。 |

纯 CPU 代码不包含 Lua 或 Source SDK；业务模块不反向依赖 Bindings。
算法计算数据，任务对象管理排队、修订、取消和线程，资源对象管理上传、发布和销毁，
绑定只转换边界。不要在绑定中另写一套资源事务。

文件与主要类型同名，声明和实现放同目录，如 `SectionGeometry.h/.cpp`。
按可命名的职责拆分，不按行数机械切文件，不建立只转发参数的多层包装。
移动文件时同步 include、CMake、测试构建和文档；不能凭 `Legacy` 名称删除兼容实现。

## 命名与排版

| 对象 | 规则 | 示例 |
| --- | --- | --- |
| 类、结构体、类型别名 | PascalCase | `VisibilityGraph` |
| 普通函数、方法 | PascalCase、具体动词 | `BuildGraph` |
| 成员 | `m` + PascalCase | `mChunks` |
| 静态成员方法、静态可变状态 | `s` + PascalCase | `sCreate` |
| 类/全局/静态常量 | `c` + PascalCase | `cMaxGridCells` |
| 输入、输出、读写参数 | `in` / `out` / `io` + PascalCase | `inSnapshot`、`outError` |
| 局部变量与局部常量 | snake_case | `visible_chunks` |
| 枚举类型、枚举值 | `E` + PascalCase、PascalCase | `ERejectReason::Frustum` |

SDK override、Lua 导出及 C ABI 符号保持原契约。循环索引可用 `i`、`x`、`y`、`z`。

- Tab 宽度 4；Allman 花括号；删除行尾空白，文件末尾换行。
- 单语句分支可省花括号，但语句另起一行；校验、锁、Lua 栈、发布、回滚和释放写成可逐步阅读的流程。
- 指针和引用使用 `Texture *texture`、`const Snapshot &inSnapshot`；不要压缩多个副作用到同一行。
- 头文件使用 `#pragma once`，直接包含依赖；公开头文件不使用 `using namespace`。
- 使用 PCH 的 `.cpp` 先包含 PCH，再包含自身头文件；纯 CPU 模块不引入引擎 PCH。
- include 写明职责路径；`///` 说明公开类型/接口的输入、失败、线程与寿命，实现注释解释必要约束。

## 所有权与线程

每种资源明确一个所有者，优先值成员或唯一所有权。借用指针注明有效期和可空性，
可失效的长期引用使用代际句柄。Lua registry reference、引擎引用、锁和事务由 RAII 管理；
初始化失败释放已取得资源，复制与移动语义明确声明。

worker 接收不可变快照或独占数据，不访问 Lua 栈、材质、纹理、IMesh 或活动世界可变对象。
发布前检查世界代际、修订和取消状态。mutex 注明保护成员与加锁顺序，持锁时不调用未知回调或 Lua。
停止接受任务后唤醒并 join worker，随后退役结果并释放资源；不使用 detached 线程绕过关闭顺序。

drain、材质系统锁、Download 和事务恢复由资源发布模块集中负责。
可能阻塞或发布的绘制接口必须说明前置条件与成本。缓存键覆盖全部输入，所有者负责失效。

## 校验、错误与性能

遵守 [工程规则](../../AGENTS.md) 和 [故障上报约定](fault-handling.md)：

- 在加载、注册、解析、构建或修订变化时验证输入，热循环直接消费验证后的数据。
- 外部输入错误返回明确失败，内部不变量使用断言；Release 必需的边界检查不能被断言替代。
- 绑定统一转换错误并恢复栈。C++ 异常不跨 C ABI，Lua 长跳转不能跳过必须执行的析构。
- 运行时尺寸通过 Lua 坐标 API 提供并传入 C++；不硬编码方块尺寸，不混用世界、引擎、渲染空间。
- 性能改动减少相同结果的总 CPU、分配、绘制或上传工作；不以分帧或预算收紧冒充优化。
- 计时写清线程、范围及等待；wall time 不称为 GPU 时间，嵌套阶段不直接相加，探针不放进逐元素循环。

## 工具

使用能识别当前配置的 LLVM 22 或更高版本。以下为按用户安排执行的命令示例：

```powershell
clang-format --style=file:native/.clang-format --dump-config
clang-tidy --config-file=native/.clang-tidy --verify-config
clang-format --style=file --dry-run --Werror native/Render/Visibility/VisibilityQuery.cpp
clang-tidy -p native/build/x64/auto-release-final native/Render/Visibility/VisibilityQuery.cpp
```

`--verify-config` 仅检查配置可解析。tidy 使用与目标架构、分支、配置匹配的编译数据库；
独立 CPU 测试数据库不能证明 DLL 检查通过。`.clang-format-ignore` 和 tidy header filter
排除 `include/`、`sdk/`、`build/`，仍不得把第三方源文件当作主翻译单元输入。

不混入整库格式化，不默认运行 tidy `--fix`，不以全库 `NOLINT` 掩盖问题。
必要抑制限定具体位置和检查项并解释原因。源码检查、测试、客户端启动及采样仅按用户安排执行。
构建参数、SDK 与产物位置见 [Native 模块指南](native.md)。
