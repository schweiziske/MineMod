# MC — Minecraft 方块插件 (Garry's Mod)

用 **IMesh** 渲染我的世界方块，**不为每个方块创建实体**，所以放再多方块也不卡。

- 方块数据存在一个分区块 (16×16×16) 的体素表里，按区块用 IMesh 网格渲染 —— **每个区块只有 1 次 draw call**。
- 碰撞用 **每个区块 1 个物理实体** (`mc_chunk`，贪心合并成大盒子的 multiconvex)。约 **4096 个方块共用 1 个实体**。
- 服务器权威：客户端从不直接改方块，所有放置/破坏都由服务器校验后广播。
- 建筑**自动按地图保存**到 `data/mc/<地图名>.dat`，地图重启后自动恢复。

---

## 安装

把整个 `mc` 文件夹放到 `garrysmod/addons/` 下（你现在就在这）。重启服务器或地图即可。

材质图集已经生成好了：`materials/mc/atlas_365.png`。当前第一阶段会从本地 `26.2-pre-4/out` 生成完整方块注册表和贴图图集。

---

## 使用

两种工具都有：

### 1. SWEP（武器，任何 gamemode 都能用）
- 生成菜单武器栏里找 **MC 方块放置器**，或控制台 `give mc_placer`。
- **左键**：破坏方块
- **右键**：放置当前方块
- **R**：打开方块选择面板

### 2. 工具枪（仅 Sandbox 等带工具枪的 gamemode）
- 工具枪菜单 → Construction → **MC 方块**
- **左键**破坏 / **右键**放置 / **Reload** 复制准星处的方块
- 左侧面板选择方块

> 放置是“贴着表面放”的（像 MC 一样）：对着地面、墙或已有方块的某个面放，新方块就贴在那个面外侧。
> 会卡住玩家的位置放不了方块（防止把人埋住）。

### 调试 (F3)

按 **F3** 开/关调试信息（仿 MC F3）：显示你的世界坐标、所在方块格 (cell)、所在区块 (chunk)、朝向，以及准星看向的方块/区块和已加载的区块/方块数。也可在控制台 `mc_debug` 切换，或 `bind <键> mc_debug` 绑到别的键。

---

## 服务器 ConVars

| ConVar | 默认 | 说明 |
|---|---|---|
| `mc_admin_only` | `0` | 设 1 则只有管理员能建造 |
| `mc_world_limit` | `1024` | 每个轴方向离原点最多多少个方块 |
| `mc_max_blocks` | `300000` | 全图方块总数上限 |
| `mc_reach` | `182.5` | 放置/破坏的最大距离（单位），默认约 5 个方块，0 = 不限制 |
| `mc_fill_max` | `32768` | 单次 `/fill` 最多修改多少个格子，0 = 不限制 |
| `mc_autosave` | `120` | 自动保存间隔（秒），0 = 关闭 |

控制台命令：
- `mc_save` —— 立即保存（管理员）
- `mc_clear` —— 清空整个世界（管理员）
- `mc_block_sel <id>` —— SWEP 选择方块（一般由面板自动调用）
- `mc_fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]>` —— 填充/清除一块方块区域（不受 `mc_reach` 限制）

聊天命令：
- `/fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]>` 或 `!fill ...` —— 填充/清除一块方块区域，坐标是方块格坐标。例如 `/fill 0 0 0 9 0 9 stone`、`/fill 0 0 0 3 3 3 minecraft:oak_log[axis=x]`。

**客户端 ConVar**：
- `mc_client_collision`（默认 `1`）—— 是否在客户端也建一份碰撞，让本地玩家走在方块上时移动预测更顺、不抖。万一某些环境下表现异常，设 `0` 退回「只用服务器碰撞」。

---

## 重新生成 / 更换贴图

图集由 `_build/build_atlas.ps1` 生成。脚本读取本地 `E:\mc\.minecraft\versions\26.2-pre-4\out`，扫描 `blockstates`、`models/block`、`textures/block`，只把完整 cube 方块加入第一阶段注册表。

```powershell
# 在 addons/mc 目录下
powershell -ExecutionPolicy Bypass -File _build\build_atlas.ps1
```

脚本会同步生成：
- `materials/mc/atlas_365.png` —— 方块贴图图集
- `lua/mc/sh_generated_tiles.lua` —— 机器生成的 tile 索引
- `lua/mc/sh_generated_blocks.lua` —— 机器生成的完整方块注册表

想加自定义方块：走 `MC.RegisterBlock(def)` 注册，字段包括 `id`、`name`、`mcid`、`disp`、`solid`、`transparent`、`textures`、`stateRule`、`placeRule`、`handlers`。内部数字 ID 由本插件稳定维护，外部命令和后续地图导入优先使用 `minecraft:name`。

> 贴图版权归 Mojang。仅供你自己的服务器使用，请勿公开再分发。

---

## 工作原理（为什么不卡）

```
放置方块  ──► 服务器写入体素表 ──► 广播 mc_set
                     │                    │
                     ▼                    ▼
        标记该区块碰撞需重建      客户端更新本地体素表 + 标记网格脏
                     │                    │
                     ▼                    ▼
   mc_chunk:RebuildPhysics()    cl_render 在 Think 里重建该区块 IMesh
   (贪心盒子 → multiconvex)      mc_chunk:Draw() → MC.DrawChunk (1 draw call)
```

- 隐藏面剔除：相邻两个实心方块之间的面不生成。
- 玻璃/树叶：用 alpha cutout（材质 `alphatest`），且相邻同种透明方块之间不画面。
- 方向光照：顶面最亮、底面最暗，靠顶点颜色实现，像素风一致。
- 网格顶点超过 65535 会自动拆成多个 IMesh。

## 文件结构
```
lua/autorun/mc_load.lua          加载器
lua/mc/sh_config.lua             常量 / ConVar / net 协议
lua/mc/sh_blocks.lua             方块注册表 + 图集 tile 映射
lua/mc/sh_generated_tiles.lua    自动生成的 tile 索引
lua/mc/sh_generated_blocks.lua   自动生成的完整方块表
lua/mc/sh_voxel.lua              体素存储 + 坐标换算
lua/mc/sv_world.lua             服务器权威 / 同步 / 存档
lua/mc/cl_render.lua             IMesh 网格构建 + 绘制
lua/mc/cl_net.lua                客户端接收
lua/mc/cl_ui.lua                 方块图标 / 选择面板
lua/entities/mc_chunk/           区块实体（碰撞 + 渲染）
lua/weapons/mc_placer/           SWEP
lua/weapons/gmod_tool/stools/mc_block.lua   工具枪
materials/mc/atlas_365.png       贴图图集
_build/build_atlas.ps1           图集生成脚本
```
