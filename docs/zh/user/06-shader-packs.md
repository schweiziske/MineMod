# 光影包

[English](../../../docs-user/06-shader-packs.md) | 简体中文

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

## 光照图集分辨率

打开 `mc_config`，选择“客户端设置 → 渲染 → 显示 → 光照图集分辨率”。
选项固定为“自动”（默认）、“16K”、“8K”、“4K”。只有“自动”会同时参考设备最大宽高，
选择支持的最大档位；保存的值和界面显示仍然是“自动”。
手动档位指定精确尺寸，不是上限；设置界面会拒绝设备不支持的选择。
修改后重新连接，已有网格在本次连接中继续使用原布局。

对应客户端配置项为 `mc_light_atlas_size auto|16384|8192|4096`，
由各光影包共用，不属于包的画质预设。缩小图集减少可用面数，不降低单个面的光照精度。
三档 RGBA8、无 mip 的单张纹理数据量分别为 1 GiB、256 MiB、64 MiB，
另有 CPU backing 和引擎临时内存。面数容量耗尽时报告 `render_pack_atlas_budget`，不会覆盖仍在使用的槽位。

8K/4K 需要匹配版本的光影包。`l2_texture_device_limit` 表示尺寸不受支持；
`l2_texture_hardware_config_unavailable` 是独立的 Native 硬件接口失败，缩小尺寸不能修复。
安装了 Native 的客户端还需使用包含 `GetL2PixelTextureLimits` 的 DLL。

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
