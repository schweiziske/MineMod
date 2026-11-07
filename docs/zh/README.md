# 工程文档索引

[English](../README.md) | 简体中文

本索引汇总中文文档。默认 Markdown 页面使用英文，中文版集中在 `docs/zh/`。新增 `docs/` 下的 Markdown 文档时，应在英文索引的对应阅读类别表格中登记，并同步维护中文版。

## 契约

| 文档 | 回答的问题 |
| --- | --- |
| [api.md](api.md) | 第三方 addon 如何加载、注册内容并通过 `MC.API` 查询和修改世界？ |
| [fault-handling.md](fault-handling.md) | 内部依赖或资源失败时如何记录、定位并处理故障？ |
| [native-cpp-standard.md](native-cpp-standard.md) | Native C++ 如何组织职责、命名、管理资源与线程并执行检查？ |
| [localization.md](localization.md) | 本地化 JSON 如何安装打包、维护检查、按目录加载及选择语言，`MC.API.I18n` 如何查询及发送由客户端翻译的玩家消息？ |
| [MC Item 转换约定](addons/mc_item/AGENTS.md) | Minecraft 物品的空间、单位、变换和投影如何转换到 Source？ |

## 参考

| 文档 | 回答的问题 |
| --- | --- |
| [README.md](README.md) | 当前检出中的工程文档从哪里开始查阅？ |
| [native.md](native.md) | 如何安装、排查和编译 MineMod Native 客户端模块？ |
| [airboat-water.md](airboat-water.md) | 原生 Source 气垫船如何在 Minecraft 水体中漂浮和驾驶？ |
| [project.md](project.md) | MineMod 有哪些功能，仓库如何组织，如何参与开发？ |
| [user/](user/README.md) | 如何安装和游玩，使用存档、预设、材质包、光影包与世界导入？ |
| [CONTEXT.md](CONTEXT.md) | 方块状态、section、世界包和覆盖层等术语是什么意思？ |
| [convar.md](convar.md) | `mc_*` 变量与详细光照参数如何使用？ |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | 第三方组件与移植算法有哪些来源和许可要求？ |
| [native/sdk/](native/sdk/README.md) | 编译 Native 模块需要准备哪些 SDK？ |
| [tools/shader_compiler/](tools/shader_compiler/README.md) | 如何准备编译器、构建 shader 并发布显示设置？ |
| [tools/world importer/](<tools/world importer/README.md>) | 如何使用 Java 版世界导入工具？ |

类别按阅读方式划分：**契约**规定必须遵守的行为；**参考**便于查阅；**踩坑**解释故障与陷阱；**设计**记录架构和取舍；**过程**说明工作流程；**外部技术调研**分析其他项目。子目录在索引中的条目覆盖其内容。
