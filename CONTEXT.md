# MC Voxel World

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
