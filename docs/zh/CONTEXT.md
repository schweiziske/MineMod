# MC Voxel World

[English](../../CONTEXT.md) | 简体中文

该上下文描述 GMod MC 插件中方块、方块状态以及 Minecraft 世界导入的统一语言。

## Language

**方块类型（Block Type）**:
由 `minecraft:*` 名称标识的方块种类，不包含某个世界位置上的具体属性组合。
_Avoid_: 方块状态、方块 ID

**方块状态（Block State）**:
某个方块类型的一组完整、合法且不可变的属性组合，例如楼梯的朝向、上下半和形状。
_Avoid_: Orient、Metadata

**状态属性（State Property）**:
方块状态中的一个具名维度，其值域为布尔、整数范围或枚举。
_Avoid_: 字段、Metadata

**状态 Schema**:
一个方块类型允许的状态属性、值域和默认值的定义。
_Avoid_: 状态表、Orient Rule

**状态注册表（State Registry）**:
包含所有合法方块状态并为其分配运行时身份的不可变目录。
_Avoid_: Palette

**Section Palette**:
一个 `16×16×16` 存储 section 内实际出现的方块状态集合；格子只引用该集合中的局部下标。
_Avoid_: 全局状态注册表、方块列表

**状态行为（State Behaviour）**:
根据放置、邻居变化、随机刻或玩家交互，把一个方块状态转换为另一个方块状态的规则。
_Avoid_: 状态存储

**方块实体（Block Entity）**:
附着在某个方块位置、不能由有限状态属性表达的有类型数据，例如容器物品、告示牌文字或熔炉进度。它不是独立的 Garry's Mod Entity。
_Avoid_: 方块状态、每方块 GMod Entity、Tile Entity

**状态无损导入（State-Lossless Import）**:
Minecraft 存档中的方块名称和全部合法状态属性在导入后保持一致；该术语不承诺实体、行为或方块实体也已实现。
_Avoid_: 完美导入

## Workshop 世界同步

**世界包（World Package）**:
通过 Workshop 发布的只读世界数据集合，拥有稳定的内容身份并包含一个基线快照。
_Avoid_: 存档、运行时世界、Workshop ID

**基线快照（Base Snapshot）**:
世界包中不可变的体素世界状态，是判断运行时差异的唯一参照。
_Avoid_: 当前世界、备份

**运行时世界（Runtime World）**:
服务端当前权威世界，由一个基线快照和属于该基线的覆盖层共同定义。
_Avoid_: Workshop 地图、基线

**覆盖层（Overlay）**:
运行时世界相对某个确定基线快照的规范化差异集合。
_Avoid_: 完整存档、编辑历史、Dirty 列表

**差异格（Dirty Cell）**:
当前方块状态或方块实体确实不同于基线的格子；曾经被编辑但已经还原的格子不是差异格。
_Avoid_: 被编辑过的格子、脏历史

**基线 Hash（Base Hash）**:
标识一个基线快照完整内容的密码学指纹；Workshop item ID 不属于该身份。
_Avoid_: Workshop ID、文件名、版本备注

**世界世代（World Generation）**:
一次活动运行时世界会话的身份，用于把旧世界的网络数据与当前世界隔离。
_Avoid_: 地图版本、修订号

**修订屏障（Revision Barrier）**:
客户端加载基线时选定的权威修订点；客户端先得到该点的覆盖层，再连续接收之后的事务。
_Avoid_: 暂停世界、最终修订

## 玩家游戏模式与挖掘

**玩家游戏模式（Player Game Mode）**:
服务端为每名玩家维护的权威玩法状态；当前只包含 `survival` 与 `creative`，不等同于 Garry's Mod 的全局 Gamemode。
_Avoid_: 服务器模式、客户端 ConVar

**挖掘会话（Mining Session）**:
一名生存玩家持续破坏一个确定方块状态的临时过程，目标、进度和完成判定均归服务端所有。
_Avoid_: 方块伤害、客户端破坏预测

**有效工具（Effective Tool）**:
能提高当前方块挖掘速度的工具；它与工具是否满足掉落条件是两个独立判断。
_Avoid_: 正确掉落工具

**正确掉落工具（Correct Tool for Drops）**:
满足当前方块掉落要求的工具；正确掉落不必然意味着具有额外挖掘速度。
_Avoid_: 有效工具
