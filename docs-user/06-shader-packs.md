# 光影包

光影包控制阴影、反射、曝光等画面效果；[材质包](05-resource-packs.md)控制贴图。
两者分别选择。

## 选择与调节

打开 `mc_config → 客户端设置 → 界面 → 光影`，先选择已安装的光影包：

| 包 | 用途 |
|---|---|
| Vanilla（`mc:vanilla`） | 默认画面 |
| PBR（`mc:pbr`） | PBR 材质、太阳阴影、反射及屏幕后效，需安装对应 addon |

下面的参数和预设由当前光影包提供，不是所有包都有相同选项。

玩家、NPC、道具的受光可在“光照 → 实体与载具光照”中开启总开关和对应类型。
已有配置里的玩家开关若为关闭，需要手动开启。PBR 的模型投影另由
`mc_pbr_shadow_entities` 控制；Vanilla 目前不提供模型实时投影阴影。

PBR 提供“最低、低、中、高、完全”五档，默认“高”。
帧率不足时先选“低”或“中”；还可减少反射、体积光、阴影分辨率及范围。

手动修改后显示“自定义”。“另存为”可保存用户预设；内置预设只读。
标题栏的眼睛按钮可临时隐藏窗口，便于观察画面。

## 控制台命令

在自己的客户端控制台执行：

| 命令 | 作用 |
|---|---|
| `mc_render_pack select mc:pbr` | 选择 PBR |
| `mc_render_pack select mc:vanilla` | 选择 Vanilla |
| `mc_render_pack off` | 同样切回默认 Vanilla，不是停用全部渲染 |
| `mc_render_pack_settings` | 列出当前包的参数、默认值和范围 |
| `mc_render_pack_set <键> <值>` | 修改当前包的参数 |
| `mc_render_pack_reset` | 恢复当前包的默认预设 |
| `mc_render_pack_preset list` | 列出当前包的预设 |
| `mc_render_pack_preset apply builtin:low` | 应用 PBR 内置低档 |

光影参数与用户预设保存在客户端 `garrysmod/data/mc/shaderpacks/config/`，
不随世界存档保存，也不是普通 ConVar。

## 画面异常

先对出问题的光影包执行 `mc_render_pack_reset`。
仍异常时切回 Vanilla，并检查光影 addon、材质包和客户端控制台错误。
PBR 的阴影等参数应在光影页修改，旧的 `mc_shadow_*` 变量不能代替当前包的参数。
