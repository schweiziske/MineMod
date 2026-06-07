# MC 方块插件交接说明

这个插件是在 Garry's Mod 里用 IMesh 渲染类似 Minecraft 的方块世界。目标不是每个方块一个实体，而是把方块按区块合成网格渲染，再用 `mc_chunk` 实体提供碰撞。

这份 README 主要给下一个接手的 AI/开发者看。当前工程不是稳定完成态，尤其是“区块拼接”和“大地图同步”还有明显问题，不要默认当前实现是对的。

## 当前目标

- 支持 36.5 units 的方块尺寸。
- 支持放置、破坏、`/fill`、基础方块注册和材质 atlas。
- 支持从 Java Minecraft 存档导出 JSON，再在 GMod 里导入。
- 最终目标是把 Minecraft 地图读到 GMod，并保留方块 ID、方块状态、朝向和后续自定义交互接口。

## 当前重要问题

### 1. 区块拼接目前是错的

现有代码里曾经尝试把区块改成 `16x16x384`，并用 `cz` 上下拼接。但是这个方案目前没有验证通过，表现包括：

- 上下 section 之间可能空一大块。
- 靠近 chunk 时可能消失。
- 客户端 mesh 坐标、实体坐标、render bounds、碰撞坐标之间容易出现重复偏移或少偏移。
- 当前实现不要当成正确答案继续硬补。

下一步应该先重新设计区块坐标，不要在旧补丁上继续猜。

建议重新明确三套坐标：

- MC 源数据坐标：Java 存档里的 `x, y, z`，高度通常是 `-64..319`。
- GMod 方块格坐标：插件内部的 `bx, by, bz`。
- 渲染实体本地坐标：`mc_chunk` 实体位置加本地 mesh 顶点。

如果继续用 `16x16x384`：

- `ChunkKey` 至少要包含 `cx, cy, czBand`。
- `czBand` 只能表示一个 384 高的带，不应该再有固定 `ChunkMinZ`。
- mesh 顶点必须只用实体本地坐标，实体位置负责世界偏移。
- 碰撞和渲染必须用同一套 local index 解码。
- 旧存档/旧导入格式必须明确迁移，不能混着猜。

也可以考虑更接近 Minecraft 的内部结构：

- 水平 chunk 是 `16x16`。
- 垂直按 section 切成 `16` 高。
- 导入时按 column 管理，但网络同步和 mesh 可以按 section 或更小批次发。

注意：用户之前明确提过“我的世界正确的区块拼接，但是 GMod 可以上下拼接”。不要把“一个固定最低 z 的大柱子”当成最终方案。

### 2. GMod 不能一次发送大包

GMod 的 net reliable buffer 很容易溢出。已经出现过类似错误：

```text
Disconnect: ... overflowed reliable buffer
```

原因是一次把大量方块或者一个巨大 chunk 通过 `mc_full` 发给客户端。不要再做这种一次性同步。

后续同步必须分片：

- 一个 chunk/section 生成完后可以发，但也要按小包切。
- 每个 net message 要控制大小，宁可多 tick 发送。
- 不要把几十万方块塞进一个 reliable message。
- 客户端应该边收到边建立 mesh/碰撞，而不是等全量一次性完成。
- 服务器也不能在同一帧给所有客户端塞满同步队列。

建议做一个同步队列：

- `mc_full_begin(key, totalParts)`
- `mc_full_part(key, partIndex, cells...)`
- `mc_full_end(key)`

或者更简单：每次只发固定数量 cell，例如 512 或 1024 个，客户端累积到 section 后标 dirty。

### 3. 当前导入 JSON 要保持简单

用户明确不想要特别啰嗦的 JSON。导入文件应该尽量简单：

```json
{
  "v": 5,
  "h": 384,
  "p": ["minecraft:stone", "minecraft:dirt"],
  "chunks": [
    [0, 0, 0, [0, 0, 1, 0, 2, 1]]
  ]
}
```

含义：

- `p` 是全局 palette。
- `chunks` 里每项是 `[cx, cy, cz, cells]`。
- `cells` 是 `[localIndex, paletteIndex, localIndex, paletteIndex, ...]`。

不要在每个方块里重复写 `"minecraft:stone"`。

### 4. 服务器碰撞和客户端预测都要保留

用户要求必须有客户端预测，但服务器碰撞也要有。

注意：

- 客户端预测不能一次性为大地图全量建碰撞，否则会崩或卡死。
- 服务器碰撞也不能一次性为超多 chunk 同帧构建。
- 应该按 chunk/section 分批 dirty rebuild。
- 如果导入大地图，先默认只发渲染数据，再按玩家附近逐步建立碰撞会更稳。

## 当前主要文件

```text
lua/mc/sh_config.lua             方块尺寸、chunk 尺寸、net bit 配置、ConVar
lua/mc/sh_voxel.lua              方块存储和坐标换算
lua/mc/sv_world.lua              服务端放置/破坏/fill/import/save/sync
lua/mc/cl_net.lua                客户端接收 mc_full/mc_set
lua/mc/cl_render.lua             客户端 IMesh 生成和绘制
lua/entities/mc_chunk/           chunk 实体，负责绘制入口和碰撞
_tools/mc_import_world.py        Java .mca 导出为 GMod 导入 JSON
_build/build_atlas.ps1           从 Minecraft out 目录生成 atlas 和注册表
out                              我的世界26.2-pre-4源代码
```

## 接手时先做什么

1. 先看当前 git 状态：

```powershell
git status --short
git diff -- lua/mc/sh_voxel.lua lua/mc/sv_world.lua lua/mc/cl_net.lua lua/mc/cl_render.lua lua/entities/mc_chunk _tools/mc_import_world.py
```

2. 不要直接相信当前 chunk 拼接实现。先写一个最小测试：

- 只放两个方块：`bz=-1` 和 `bz=0`。
- 确认它们在渲染和碰撞里是相邻的。
- 再测试 `bz=383` 和 `bz=384`。
- 再测试 `bz=-384` 和 `bz=-385`。

3. 确认 mesh 和实体坐标规则：

- 如果 mesh 顶点是本地坐标，实体位置必须是 chunk 世界原点。
- 如果 mesh 顶点是世界坐标，实体位置必须是零或 Draw 时要处理矩阵。
- 两种方式不能混用。

4. 同步先做小包。

不要先导入 16x16 chunks 或 300000 方块。先导入一个很小的 1 chunk，再确认客户端不卡、不丢、不消失。

## 常用命令

生成 1 个 MC chunk：

```powershell
xxx
```

服务器导入：

```text
mc_import 123_1chunk_16x16x384
```

清空：

```text
mc_clear
```

重建碰撞：

```text
mc_rebuild
```

如果同步卡死或 reliable buffer 溢出，先不要继续扩大地图，先修分片同步。

## 用户偏好

- README 和玩家能看到的文本尽量中文。
- 不要擅自把 README 改英文。
- 不要把导入 JSON 写得很复杂。
- 不要一次性发送大包。
- 不要把“看起来能跑一次”的 chunk 拼接当成正确实现。
- 修改前先判断是不是用户刚回滚过的代码，不要把回滚内容又写回来。


