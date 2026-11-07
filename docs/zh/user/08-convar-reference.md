# ConVar 简洁版：常用设置

[English](../../../docs-user/08-convar-reference.md) | 简体中文

本页只列常用设置。全部变量、动态姿态参数与调试项见[ConVar 完整版](09-convar-complete.md)。

优先在 `mc_config` 搜索和修改。客户端设置影响自己；
服务器设置须在服务器控制台或管理员设置页修改。

在对应控制台直接输入变量名可查看当前值；名称后加值可修改，例如：

```text
mc_language zh_cn
```

下表为源码默认值，已有配置和服务器规则可能覆盖它们。
用 `find mc_` 或 `find mcitem_` 查当前进程实际注册的设置。

## 客户端

| 变量 | 默认 | 用途 |
|---|---|---|
| `mc_language` | `auto` | 跟随 GMod，失败时英文；也可选 `zh_cn`、`en_us` |
| `mc_join_notice` | `1` | 进服时显示操作提示 |
| `mc_gamemode` | `creative` | 请求切换自己的模式，由服务器确认 |
| `mc_inventory_hud_scale` | `0` | 生存 HUD 缩放，0 自动 |
| `mc_inventory_ui_scale` | `0` | 物品栏与容器界面缩放，0 自动 |
| `mc_inventory_hud_offset_x`、`mc_inventory_hud_offset_y` | `0` | HUD 像素偏移 |
| `mc_inventory_ui_offset_x`、`mc_inventory_ui_offset_y` | `0` | 物品栏界面偏移 |
| `mc_inventory_return_button` | `1` | 物品栏返回按钮 |
| `mc_item_drop_draw_distance` | `96` | 掉落物绘制距离，单位为方块 |
| `mc_mesh_render` | `1` | 显示世界网格，关闭仍保留碰撞 |
| `mc_mesh_draw_distance` | `0` | 绘制距离，Source 单位；0 在延迟构建开启时使用其距离，否则不限 |
| `mc_mesh_build_preset` | `fast` | 构建调度：smooth、fast、loading；手动改预算后为 custom |
| `mc_client_collision` | `1` | 本地预测碰撞 |
| `mc_dynamic_lights` | `1` | 动态光源 |
| `mc_dynamic_flashlight` | `1` | 方块接收手电光束 |
| `mc_light_entity` | `0` | 实体接收 MC 光照 |
| `mc_light_entity_players` | `1` | 玩家接收 MC 光照；旧配置若为 0，需在设置中开启 |
| `mc_light_entity_npcs` | `1` | NPC 和 NextBot 接收 MC 光照 |

### MC Item

需安装 `mc_item`；以下均在客户端修改。

| 变量 | 默认 | 用途 |
|---|---|---|
| `mcitem_crosshair` | `1` | MC 准星 |
| `mcitem_attack_indicator` | `1` | 攻击进度：0 关闭、1 准星处 |
| `mcitem_crosshair_invert` | `1` | 准星反色混合 |
| `mcitem_hud_scale` | `2` | 准星 / 攻击指示缩放；0 自动 |
| `mcitem_block_outline` | `1` | 持有 MC Item 时显示方块选中轮廓 |
| `mcitem_view_bob` | `1` | 手持物走路晃动倍率；0 关闭 |
| `mcitem_view_sway` | `1` | 手持物转头滞后倍率；0 关闭 |
| `mcitem_name_tag_scale` | `2.5` | 命名牌文字大小倍率 |

## 服务器权限与玩法

| 变量 | 默认 | 用途 |
|---|---|---|
| `mc_admin_only` | `0` | 1 限制管理员编辑方块 |
| `mc_default_gamemode` | `creative` | 新玩家模式，不覆盖玩家已保存的模式 |
| `mc_allow_gamemode_switch` | `1` | 允许普通玩家切换自己的模式 |
| `mc_inventory_creative` | `1` | 允许创造物品栏的目录和复制操作 |
| `mc_inventory_persist` | `1` | 保存玩家物品栏 |
| `mc_keep_inventory` | `0` | 1 死亡保留物品栏与装备 |
| `mc_use_interact` | `1` | 右键与可使用的 MC 方块交互 |
| `mc_save_public` | `0` | 1 开放列出、保存和读档；删除仍限管理员 |
| `mc_preset_public` | `0` | 1 开放列出、保存、读取和放置预设 |
| `mc_cluster_public` | `0` | 1 开放结构搬运器 |
| `mc_workshop_manage` | `0` | 工坊权限：0 超级管理员、1 管理员、2 所有人 |
| `mc_autosave` | `0` | 定时保存间隔秒数，0 关闭；写地图默认档 |

## 服务器建造限制

| 变量 | 默认 | 用途 |
|---|---|---|
| `mc_world_limit` | `1024` | 每个坐标轴的最大绝对方块坐标 |
| `mc_max_blocks` | `0` | 世界方块总数上限，0 不限 |
| `mc_fill_max` | `100000` | 单次填充体积上限，0 不限 |
| `mc_import_max` | `0` | 单次导入方块数上限，0 不限 |
| `mc_preset_max_blocks` | `100000` | 预设非空气方块数上限，0 不限 |
| `mc_block_damage` | `1` | 允许 GMod 伤害破坏方块 |

`mc_reach` 控制玩家编辑距离，使用 Source 单位；默认按方块尺寸计算，0 关闭距离检查。

## 光影参数与排障

当前光影包的参数请用[光影页](06-shader-packs.md)或 `mc_render_pack_settings` 查看，
例如 PBR 阴影分辨率使用包内的 `shadow_resolution`，
不能用旧 `mc_shadow_size` 代替。

| 命令 | 用途 |
|---|---|
| `mc_client_diag` | 客户端诊断 |
| `mc_native_status` | Native 后端状态 |
| `mc_save_diag` | 服务器存档诊断 |

排障时提供完整错误、复现步骤以及所选材质包和光影包。
