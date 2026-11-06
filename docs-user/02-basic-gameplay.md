# 开始游玩

## 物品栏与建造

安装 `mc_game` 后，在 Sandbox 的 Q 菜单“武器 → Minecraft”中选择
**MC**（类名 `mc_item_hand`）。

## 切换创造与生存

默认是**创造模式**；服务器可修改默认值，已有玩家沿用已保存的模式。

在 `mc_config → 客户端设置 → 界面 → 首页 → Minecraft 游戏模式` 切换，
或在自己的控制台输入：

```text
mc_gamemode creative
mc_gamemode survival
```

服务器默认允许玩家切换自己；`mc_allow_gamemode_switch 0` 可禁止普通玩家切换。
管理员修改其他玩家时使用 `mc_set_gamemode <creative|survival> <玩家名或 SteamID>`。
服务器控制台执行此命令必须指定玩家。

生存默认死亡掉落物品栏与装备；`mc_keep_inventory 1` 可保留。
物品栏默认会跨重连保存，由 `mc_inventory_persist` 控制。

## 无法放置或破坏

检查服务器编辑权限、建造距离和世界边界。
`mc_admin_only 1` 限制管理员编辑；`mc_world_limit` 限制坐标范围，
`mc_max_blocks` 限制世界方块总数。
