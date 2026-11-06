# 安装与设置

## 安装

订阅创意工坊版本时，同时订阅发布页列出的依赖。

手动安装时，将所需 addon 分别放进 `garrysmod/addons/`。
本仓库的 addon 位于 `addons/` 下；只把整个仓库放进游戏不会自动挂载嵌套目录。

| addon | 用途 |
|---|---|
| `mc_engine` | 必需，方块世界与建造工具 |
| `mc_texturepack_default` | 必需，基础材质与缺失贴图回退 |
| `mc_shaderpack_vanilla` | 默认 Vanilla 光影包 |
| `mc_game` | MC 物品栏、合成、生存与容器玩法 |
| `mc_item` | MC 物品武器、模型、材质和声音 |
| `mc_shaderpack_pbr` | 可选，PBR 光影包 |
| `mc_texturepack_programmer_art` | 可选，经典贴图 |
| `mc_texturepack_avpbr` | 可选，AVPBR 贴图与 PBR 材质 |

第一次游玩建议安装前三项以及 `mc_game`、`mc_item`。
新增或替换 addon 后，完整退出并重启游戏。

Native 模块是可选客户端加速组件。使用时将匹配当前版本和游戏架构的 DLL
放到客户端 `garrysmod/lua/bin/`，然后重启；服务器不会自动下发 DLL。
详见[Native 安装说明](../docs/native.md#使用)。

## 打开设置

按住默认的 `C` 键打开上下文菜单，点击左上角的 **MC Config** 即可打开设置。

也可以启用 GMod 开发者控制台，按默认的 `~` 键打开，输入：

```text
mc_config
```

| 入口 | 用途 |
|---|---|
| 客户端设置 → 界面 → 首页 | 存档、材质包管理器和游戏模式 |
| 客户端设置 → 界面 → 材质包 | 更换贴图 |
| 客户端设置 → 界面 → 光影 | 选择光影包、预设和参数 |
| 客户端设置 → 界面 → 语言 | 中文、英文或跟随 GMod |
| 服务器设置 | 管理员修改权限、存档和世界规则 |

可用搜索框查找设置。数字项目输入后点击“保存”；服务器项目以服务器返回的结果为准。
界面默认 `mc_language auto`，跟随 GMod 语言；无法识别或不支持时使用英文。也可手动选择 `zh_cn` 中文或 `en_us` 英文，已有的语言设置会保留。

## 无法使用时

- **命令不存在或找不到 MC 武器**：检查 addon 是否挂载，随后完整重启。
- **贴图缺失**：先检查客户端是否安装 `mc_texturepack_default`。
- **服务器设置不可修改**：需要管理员权限。
- **画面异常**：先在光影页切回 Vanilla；仍有问题时运行
  `mc_client_diag` 和 `mc_native_status`，提供输出及复现步骤。
