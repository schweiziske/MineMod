# 开发者 API（v2）

[English](../api.md) | 简体中文

第三方 addon 通过 `MC.API` 使用 MineMod。`MC.API.VERSION == 2`，内容注册契约
`ModRegistryVersion == "1.0"`，manifest 契约 `ManifestVersion == "1"`；这三个版本独立。
内部 `MC.World`、`MC.SV`、注册表、`mcmesh` 和 `_` 开头字段不属于公开扩展接口。

本文按当前门面实现组织：[共享](../../addons/mc_engine/lua/mc/api/sh_api.lua)、
[服务端](../../addons/mc_engine/lua/mc/api/sv_api.lua)、
[客户端](../../addons/mc_engine/lua/mc/api/cl_api.lua)、
[manifest](../../addons/mc_engine/lua/mc/api/sh_manifest.lua)。下文省略 `MC.API.` 前缀。
表中 SH 表示两端都有，SV 表示服务端，CL 表示客户端；SH 不表示调用会自动跨网络同步。

## 开始接入

完整的独立 addon 示例是 [mod_api_example.lua](../../examples/mod_api_example.lua)。把它改名后
放进自己 addon 的 `lua/autorun/`，同时复制 [examples/data_static](../../examples/data_static)
中的本地化词典。共享文件需通过 GMod 的 `AddCSLuaFile()` 发给客户端。

加载分两个阶段：

1. **register**：`MC.APIAvailable(version)`，注册表仍开放。在此注册 manifest、方块、物品与分类。
2. **ready**：`MC.APIReady(version)`，注册表已冻结，开始运行时逻辑、网络、UI 和 timer。

引擎在 autorun 加载后的 bootstrap 中调度 manifest，再冻结注册表。不要用 timer 延迟内容注册，
也不要把注册放进 `OnReady`。两端必须安装相同内容；运行时数字 ID 不应写进持久存档。

```lua
if SERVER then AddCSLuaFile() end

local function registerContent()
	local api = MC.API
	local ok, result = api.Blocks.RegisterNamespaced( {
		id = "example:stone",
		textures = { top = "stone", side = "stone", bottom = "stone" },
		boxes = { { 0, 0, 0, 1, 1, 1 } },
		hardness = 1.5,
		explosionResistance = 6,
	} )
	if not ok then ErrorNoHalt( "[example] " .. tostring( result ) .. "\n" ) end
end

if MC and MC.API and MC.API.OnRegister then
	MC.API.OnRegister( registerContent )
else
	hook.Add( "MC.APIAvailable", "example.register", registerContent )
end
```

该示例只注册引擎方块；物品、掉落与创造分类的完整组合见链接中的示例。
显示名称来自 `block.example.stone`，在 addon 的 `data_static/mc/i18n/` 内声明。
词典格式与完整 `I18n` 接口见 [本地化契约](localization.md)。

### 生命周期、manifest 与可选能力（SH）

| 调用 | 结果/用途 |
| --- | --- |
| `IsAvailable()`、`IsReady()` | 对应阶段是否已到达。 |
| `OnRegister(callback)`、`OnReady(callback)` | 阶段已发生则立即调用，否则排队；无效回调返回 `false`。晚注册订阅不会重新开放已冻结的表。 |
| `Require(2, addonName)` | 检查门面最低版本，返回 `ok, err`。 |
| `Require("mcswep", ">=1.0 <2.0", addonName)` | 检查 manifest 依赖版本，返回 `ok, err`。引擎的兼容依赖 ID 仍为 `mcswep`。 |
| `RegisterManifest(definition)` | 返回 `ok, manifestOrErr`；只能在注册阶段提交。 |
| `GetManifest(id)`、`ListManifests()` | 单份公开记录或错误、按 ID 排序的记录数组。 |
| `GetCapability(name, minimumVersion)` | 成功：`surface, nil, version, owner`；失败：`nil, err, actualVersionOrNil`。 |
| `HasCapability(name, minimumVersion)` | 是否存在满足版本的能力。 |
| `RequireCapability(name, minimumVersion, addonName)` | 成功返回 `surface, version`；失败打印原因并返回 `nil, err`。 |
| `OnCapability(name, minimumVersion, callback)` | `callback(surface, version, owner)`，满足时立即调用，否则等待。 |
| `RegisterCapability(name, version, surface, owner)` | 发布能力，返回 `ok, surfaceOrErr`；同 owner 可替换，其他 owner 不能覆盖。 |
| `UnregisterCapability(name, owner)` | 仅 owner 可移除，返回 `ok, err`。 |
| `RegisterEvents(owner, definitions)` | 登记事件描述，返回 `ok, err`；不自动触发事件。 |
| `DeepCopy(value)` | 深拷贝表；非表直接返回。 |
| `ResolveStateInput(block)` | 与 `Blocks.ParseState` 相同的状态输入解析。 |

manifest 是 Lua 表，不是自动扫描的 JSON，也不会替 addon 加载文件：

```lua
local manifest = {
	id = "example", version = "1.0.0", environment = "*",
	depends = { mcswep = ">=1.0 <2.0" },
	entrypoints = { main = function( context )
		-- context.api、context.manifest、context.realm
		return true
	end },
}
```

`environment` 为 `*`、`client` 或 `server`。entrypoint 名称为 `main`、`shared`、`client`、`server`，
值为函数或函数数组；按依赖顺序运行，当前端依次运行 main/shared/对应 realm。
回调抛错或显式返回 `false, reason` 会使 manifest bootstrap 失败；不要在失败时只 `return nil`。

## 单位、身份与返回值

- `bx/by/bz` 是整数格子坐标；连续 MC 世界坐标仍以 Source units 表示。
  一个方块的尺寸从 `Coords.BlockSize()` 读取。模型盒坐标是方块比例，转连续坐标只乘一次。
- 实体 `GetPos()` / `EyePos()` 属于引擎空间；重定位世界中必须带实体 context 换算。
  绘制位置另用当前帧渲染空间，不把世界位置直接交给引擎 trace 或 `SetPos`。
- `block` 参数一般接受 **stateId**、`"minecraft:stone"`、带属性的 spec，或 `0/nil/"air"`。
  blockId、runtimeId、stateId 不是同一身份。`Blocks.Resolve` 查询方块类型，`ParseState` 查询状态。
- 持久化使用命名空间名称或 `FormatState` 的 spec；运行时数字仅对当前进程有效。
- 不假定所有函数都是 `ok, err`。数量函数可能返回 `0`，查询可能返回 `nil`，多返回值见各表。
  不用 `and`、`or`、括号包裹多返回值调用。

```lua
local x, y, z = MC.API.Coords.EntityCell( ply )
if x == nil then return end
local ok, err = MC.API.Player.Place( ply, x, y, z + 1, "minecraft:stone" )
if not ok then print( err ) end
```

## Coords（SH，注明者为 CL）

| 调用 | 返回 |
| --- | --- |
| `BlockSize()` | 当前方块边长。 |
| `WorldToCell(pos)`、`EngineToCell(pos, context)` | `bx, by, bz`；无效输入为三个 `nil`。 |
| `EngineToWorld(pos, context)`、`WorldToEngine(pos, context)` | 换算后的 Vector，失败 `nil, err`。 |
| `EntityCell(ent)`、`EntityEyeCell(ent)` | 脚部/眼睛的 `bx, by, bz`。 |
| `EntityWorldPos(ent)`、`EntityEyeWorldPos(ent)` | 世界空间 Vector 副本或 `nil, err`。 |
| `MoveOriginWorldPos(ply, pos)` | 按预测移动 origin 换算的世界 Vector 或 `nil, err`。 |
| `EntityWorldAABB(ent)` | `minimum, maximum` 两份世界 Vector；失败 `nil, nil, err`。 |
| `EntityCellBounds(ent, inset)` | `minX, minY, minZ, maxX, maxY, maxZ`；inset 为 Source units。 |
| `CellMin(bx, by, bz)`、`CellCenter(bx, by, bz)` | 世界空间格子角点/中心 Vector，无效格子返回 `nil`。 |
| `CellToChunk(bx, by, bz)` | `cx, cy, cz, localIndex`。 |
| `RenderToWorld(pos)`、`WorldToRender(pos)` | CL；换算 Vector 或 `nil, err`，服务端返回 `client_only`。 |
| `CellRenderMin(bx, by, bz)`、`CellRenderCenter(bx, by, bz)` | 当前帧绘制坐标，供客户端 render hook 使用。 |

## Blocks（SH）

| 调用 | 返回/用途 |
| --- | --- |
| `Resolve(input)` | 方块类型记录 `{id, blockId, runtimeId, name, mcid, defaultStateId}` 或 `nil, err`。 |
| `ParseState(spec)`、`FormatState(stateId)` | `stateId, err` / `spec, err`。 |
| `Name(stateId)`、`StateName(stateId)` | 状态所属规范方块名 / 完整 spec。 |
| `IsValidState(stateId)`、`StateBlockId(stateId)` | 有效性 / 兼容 blockId。 |
| `StateFromLegacy(blockId, orient)`、`DefaultState(input)` | `stateId, err`。 |
| `GetProperty(stateId, propertyName)`、`WithProperty(stateId, propertyName, value)` | 读取属性 / 返回另一合法状态，不修改原状态。 |
| `DisplayName(idOrStateId, locale)`、`DisplayNameForState(stateId, locale)` | 本地化名称；数字同时命中时前者优先视为 blockId，状态请用后者。 |
| `TranslationKey(idOrStateId)` | `key, varsCopy` 或 `nil, err`。 |
| `Hardness(id)`、`ExplosionResistance(id)`、`LightEmission(id)`、`RequiresCorrectTool(id)` | 方块类型属性；这里的 id 是 blockId。 |
| `LightOpacity(stateId, bx, by, bz)` | 状态不透明度 `0..15`，位置用于连接形状。 |
| `StateShapeAt(stateId, bx, by, bz)` | 精确状态形状副本：boxes、collisionBoxes、collisionConvexes、extentLo/Hi、hasCollision、fullCube 等。 |
| `Kind(stateId)` | `air/liquid/narrow/door/trapdoor/bed/stairs/slab/slope/none/full/partial` 或 `nil, err`；粗分类不能代替精确碰撞。 |
| `IsFlammable(block)` | 可燃性，解析失败另带 err。 |
| `List()`、`ListNames()` | blockId 数组 / 排序的规范名称数组。 |
| `RuntimeId(input)`、`NameForRuntimeId(runtimeId)` | 当前进程映射。 |
| `RegistrySnapshot()`、`ResolveRegistrySnapshot(snapshot)` | 注册映射快照 / 解析后的副本，或 `nil, err`。 |
| `RegistryHash()`、`NetworkHash()` | 持久 schema hash / 网络运行时映射 hash，不能互换。 |
| `RegisterNamespaced(definition)` | `true, result` 或 `nil, err`；推荐的新内容注册入口。 |
| `Register(definition)` | 旧兼容入口；旧定义成功返回 `true, blockId`；纯字符串 id 的新定义转发到 RegisterNamespaced。 |

### 注册定义与行为

新定义使用自己的 `namespace:path`，不预选数字 ID。可用字段包括：

| 字段 | 含义 |
| --- | --- |
| `id` | 规范内容名称，如 `example:stone`。 |
| `textures` | `top/side/bottom/front/particle/icon`，引用已登记 atlas 纹理；最小示例复用 stone。 |
| `boxes` | 比例盒数组 `{minX,minY,minZ,maxX,maxY,maxZ}`。 |
| `collisionConvexes`（或 `convexes`） | 凸碰撞几何，不能同时提供两个别名。 |
| `hardness`、`explosionResistance`、`lightEmission` | 有限数值；发光为整数 `0..15`。 |
| `castsAmbientOcclusion`、`castsShadow` | 布尔值。 |
| `translationKey`、`translationVars` | 可选名称 key 与插值参数；不提供则按方块名生成 key。 |
| `handlers` | 下表中的生命周期回调。 |

复杂形状还有 `boxFaces/modelQuads/baked/modelVariants` 验证，具体格式见
[注册验证器](../../addons/mc_engine/lua/mc/registry/sh_mod_registry.lua)。
`collisionBoxes`、`drops/lootTable/loot_table`、内部 aliases/生成几何字段不被新注册接口接受。
`disp/dispZH` 内联名称也被拒绝；掉落通过 `BlockLoot` 单独登记。

| 调用 | 语义 |
| --- | --- |
| `SetHandlers(nameOrId, handlers)` | 替换指定回调，值为 `false` 时移除。允许 CanUse、OnUse、OnPlace、OnBreak、OnTick、OnPlaced、OnRemoved、OnReplaced、OnStateChanged、OnMoved。 |
| `RegisterUpdateHandler(blockName, definition)`、`UnregisterUpdateHandler(blockName)` | 功能方块更新回调。 |
| `RegisterStateUpdateHandler(key, matcher, definition)`、`UnregisterStateUpdateHandler(key)` | matcher(stateId, schema) 为纯函数，结果缓存；按登记顺序选首个匹配处理器。 |
| `RegisterBlockEntityType(definition)`、`IsBlockEntityTypeRegistered(typeName)` | 注册/探测方块实体数据类型。 |
| `BindBlockEntityType(blockNames, typeName)`、`CreateDefaultBlockEntity(stateId)` | 绑定类型 / 返回默认记录副本。方块实体不是 GMod Entity。 |
| `RegisterPlacementStateProvider(id, provider, priority)`、`UnregisterPlacementStateProvider(id)` | 放置状态扩展。 |

更新 definition 使用 `OnScheduledTick/OnNeighborUpdate/OnRandomTick/OnBlockEvent`；上下文和
`{cells, schedule, updates}` 结果契约以
[更新注册实现](../../addons/mc_engine/lua/mc/block_update/sh_registry.lua) 为准。
生命周期与更新回调不是同一套协议，不能混用其参数。

## World 查询（SH）

| 调用 | 返回/语义 |
| --- | --- |
| `GetBlockState(bx, by, bz)`、`IsAir(bx, by, bz)` | stateId（空气为 `0`）/ 布尔。无效或不可见数据也可能表现为空气。 |
| `IsCellLoaded(bx, by, bz)`、`IsChunkLoaded(cx, cy, cz)` | 已驻留或已知为空。判断世界事实前先检查。 |
| `GetBlockInfo(bx, by, bz)` | `{stateId,id,orient,name,mcid,spec}`，空气返回 `nil`。 |
| `ForEachBlock(x1,y1,z1,x2,y2,z2, callback)` | 包含端点的盒内非空气格；callback(bx,by,bz,stateId)，返回 false 提前结束。返回 `ok, skippedChunks`，失败第二项为 err。 |
| `ForEachLoadedBlock(callback, stateFilter)` | 当前已加载非空气格；filter(stateId) 按 section palette 过滤。成功 `true, visited`；回调失败 `false, "callback_failed", visited`。 |
| `GetCellShape(bx, by, bz)` | 当前格子的形状副本或 nil。 |
| `TraceRay(startPos, dir, maxDist)` | 世界空间体素射线，仅命中方块，不含地图/prop；结果含 bx/by/bz、StateId、HitPos、HitNormal。距离为 Source units。 |
| `PlayerAim(ply, reach)` | 玩家方块瞄准结果或 `nil, err`。 |
| `CanSeeSky(bx, by, bz)` | 高度列天空判断；SV 的正不透明度均遮挡，CL 仅完全不透明遮挡，不是侧向泛洪。 |
| `GetBlockEntity(bx, by, bz)` | 记录副本或 nil。 |
| `ListBlockEntities(typeName)` | 已加载记录数组 `{bx,by,bz,record}`，可按类型过滤。 |
| `ForEachBlockEntity(typeName, callback)` | callback(bx,by,bz,record)，false 停止；成功 `true, entriesCount`（快照总数）。 |

`skippedChunks > 0` 表示查询区域不完整，不能把空结果认定为“没有方块”。
客户端流式同步和服务端惰性加载都会影响驻留范围；不要逐帧全世界扫描。

## 权威修改（SV）

`World` 写入是可信服务端代码，跳过玩家距离、冷却和管理员验证。
由网络或玩家触发的编辑应调用 `Player`，不得把不可信请求直接送进 World。

| 调用 | 返回/用途 |
| --- | --- |
| `World.SetBlock(bx,by,bz,block,opts)`、`RemoveBlock(bx,by,bz,opts)` | `ok, err`；未变化为 `false, "unchanged"`。 |
| `World.SetBlocks(cells,opts)`、`RemoveBlocks(cells,opts)` | 改变数量及底层结果；验证失败为 `0, err`。cells 用具名 bx/by/bz，写入值用 block/stateId/spec。 |
| `World.Fill(x1,y1,z1,x2,y2,z2,block,opts)` | 体积填充结果 `{changed,chunks,added,removed,revision,...}` 或 `nil, err`；opts 为 actor、ignoreVolumeLimit、quiet。 |
| `World.Clear()` | 清空体素世界并重同步全部玩家。 |
| `World.SetBlockEntity(bx,by,bz,record,opts)` | 替换并校验记录；nil 清除记录，不更改状态。 |
| `World.UpdateBlockEntity(bx,by,bz,callback,opts)` | 回调修改私有副本、返回替代记录或 false 中止；成功 `true, recordCopy`。 |
| `World.Damage(bx,by,bz,amount,opts)` | `broken, status, damage, health`。 |
| `World.Explode(center,damage,opts)` | `ok, brokenCount, radiusOrStatus`。 |
| `World.TriggerExplosion(center,radius,opts)` | 非破坏 TRIGGER_BLOCK 交互；`ok, triggeredCount, selectedCountOrStatus`。 |
| `World.MinecraftExplosion(center,radius,opts)` | 完整 Minecraft 爆炸；成功 `true, summary`，失败 `false, err, summaryOrNil`；radius 为 Minecraft 方块尺度。 |
| `World.PlayFx(kind,bx,by,bz,block)` | 广播 place/break 效果，不改世界。 |
| `World.CountBlocks()`、`World.GetRevision()` | 当前方块计数 / 已提交事务修订。 |
| `World.RegisterBlockGuard(id,callback)`、`UnregisterBlockGuard(id)` | 保护非玩家 damage/explosion；callback(bx,by,bz,stateId,cause,context) 返回 false 拒绝，必须足够廉价。 |
| `Player.Place(ply,bx,by,bz,block)`、`Break(ply,bx,by,bz)`、`Use(ply,bx,by,bz)` | 完整玩家验证与否决 hook，返回底层操作结果。 |
| `Player.UseAimedBlock(ply)` | 是否成功使用瞄准方块。 |
| `Player.CanEdit(ply)`、`CanReachCell(ply,bx,by,bz)` | 编辑资格 / 仅距离校验；后者不执行编辑否决也不写世界。 |
| `Player.TransformBlock(ply,bx,by,bz,block,expectedState)` | 原位修改，校验权限/距离及可选旧 stateId，不产生挖掘掉落。 |
| `Player.Resync(ply)` | nil 表示全部玩家；重新开始世界同步。 |

一般写入 opts 只接收：actor、fx、fxIndex、fxLimit、handlers、blockUpdates、
preventPlayerOverlap、priorityPhys、deferPhys、netPaced、stateStream、cellsPerMessage、
compareCollision、blockEntity。未知选项会被丢弃。

MinecraftExplosion 的 opts 单独为 source、actor、interaction、dropDecay、dropResources、
interactsWithBlocks、createFire、affectsEntities、entityDamageScale。
entityDamageScale 可为非负倍率或 callback(entity, vanillaDamage, center, radius)。
摘要只含计数与结果信息，不泄漏内部事务。

`Explosion.RegisterBlockInteractionHandler(identifier,{Prepare,Commit})` 和对应的
`UnregisterBlockInteractionHandler(identifier)` 扩展爆炸方块交互；Prepare(snapshots,radius,options)，
Commit(plan,transaction,snapshots,radius,options)，输入为公开快照。
`RegisterKnockbackResistanceProvider(identifier,callback)` / `UnregisterKnockbackResistanceProvider(identifier)`
扩展击退抗性，callback(entity,center,radius,options)。

## Items、BlockLoot 与 Creative（SH）

引擎只保存中立物品/掉落注册队列。完整物品查询和 ItemStack 语义由 `mc_game` 提供；
只安装引擎时 Items 查询返回 `item_registry_unavailable`。

| 调用 | 返回/语义 |
| --- | --- |
| `Items.Register(definition)` | `true, {name,runtimeId?,pending}` 或 `nil, err`；注册阶段使用 id、block、maxStack、texture、kind 等字段。 |
| `Items.Resolve(value)` | mc_game：`{name,runtimeId,blockName,maxStack,maxDamage}` 或 `nil, err`。 |
| `Items.RuntimeId(value)`、`NameForRuntimeId(runtimeId)`、`ListNames()`、`RegistrySnapshot()` | mc_game 的当前映射/快照。 |
| `Items.FoodProperties(value)` | mc_game：物品名或 ItemStack 的 FOOD 组件（物品栈自带组件优先），返回副本 `{nutrition,saturation,alwaysEdible,consumable}`；不是食物返回 `nil, "not_food"`，未知物品返回 `nil, "unknown_item"`。 |
| `Items.TranslationKey(value)`、`DisplayName(value,locale)` | mc_game：`key,varsCopy` / 本地化名称。 |
| `BlockLoot.RegisterDefaultBlockItem(blockName,itemName)` | 注册普通 dropSelf，返回 `ok, recordOrErr`；省略 itemName 时冻结阶段解析绑定 BlockItem。 |
| `Creative.RegisterCategory(definition)` | `ok, categoryOrErr`；id、icon、showTitle、canScroll、可选 titleKey。槽位由注册表分配。 |
| `Creative.RegisterBlock(categoryId,blockName)`、`RegisterItem(categoryId,itemName)`、`RegisterStack(categoryId,stack)` | 注册类别条目，`ok, resultOrErr`。stack 条目 count 必须为 1。 |
| `Creative.ListCategories()`、`GetCategory(id)`、`IsFrozen()` | 分类副本 / 单分类 / 冻结状态。 |

名称来自 `item.<namespace>.<path>` 或 BlockItem 对应方块 key；拒绝 `displayName/displayNameZH`。
分类标题来自 `itemGroup.<namespace>.<path>`，拒绝内联 title/titleZH，忽略自选 row/column/page 并提示。
相同 ItemStack 不应同时通过 RegisterBlock 和 RegisterItem 重复加入同一类别。

`mc_game` 的 ItemStack 工具：`ItemStack.GetCustomName(stack)` 返回 `name,present,err`，
空字符串仍可 present；`Hash(stack)` 返回并发校验用 hash；
`GetEnchantmentLevel(stack,enchantment)` 返回非负等级及可选 err。
详见 [游戏物品门面](../../addons/mc_game/lua/mcgame/item/sh_public_api.lua)。

## 其他共享系统

| 命名空间 | 调用与语义 |
| --- | --- |
| `Identifiers` | `Normalize(value)` 返回规范标识符或 nil,err；`Parts(value)` 分解标识符。使用小写合法命名空间，不依赖运行时替你修正非法拼写。 |
| `Network` | `Register(owner,names)` 登记消息归属（SV 同时 AddNetworkString），返回 ok,namesCopyOrErr；`Owner(name)`；`CoordinateBits()` 为协议有符号坐标位宽。仍需自己编写 net.Send/Receive。 |
| `Sound` | `Candidates(eventName)` 返回候选副本；`Play(eventName,position,options)` 返回 ok,candidateCopy,err。options 为 volume/pitch 倍率及 soundLevel。 |
| `Banners` | `MaxStoredPatterns()`、`IsState(stateId)`、`IsWallState(stateId)`、`NormalizeData(data,maxLayers)`；最后一项返回规范记录副本及 err。 |
| `Redstone` | `GetPower(bx,by,bz)`、`GetPowerToward(bx,by,bz,dx,dy,dz)` 为 0..15；后者是指定邻居提供给目标格的信号。`RegisterEmitter(blockName,emitter)`、`RegisterDirectEmitter(blockName,emitter)`。 |
| `Liquid` | `GetAt(bx,by,bz)` 返回 kind,height,level,falling,waterlogged 描述；height 为 0..1。`GetBucketSource(bx,by,bz)` 另含 stateId/source。`AtPos(pos)`、`PlayerEye(ply)` 查询接触；`FlowAt(bx,by,bz,requiredKind)` 返回 x,y,z 三分量。 |
| `DayCycle` | `GetTicks()`、`IsEnabled()`、`IsPaused()`、`SkyLevel()`、`SunVector()`、`NightAmount()`、`NightBlend()`、`IsNight()`、`SkyBrightness()`、`CelestialAngle()`。SunVector 返回 Vector,elevation；SkyLevel 为 0..15，SkyBrightness 为 0..1。 |
| `GameMode` | `Get(ply)` 返回 creative/survival 及可选 err；`IsCreative(ply)` 返回 bool,err。 |
| `Config` | `HasGroup(scope,id)`、`HasCategory(scope,id)`、`RegisterGroup(scope,group)`、`RegisterCategory(scope,category)`；scope 为 client/server。注册项使用 labelKey 等词典 key，不接受内联双语文本。 |

`I18n` 完整说明见 [localization.md](localization.md)，包括查询、复数、玩家通知、语言变更和诊断。

### 其他服务端操作

| 命名空间 | 调用 |
| --- | --- |
| `Saves` | `Save(name)` 返回 ok,pathOrErr，nil 为当前地图默认存档；`Load(name,resync)`、`Delete(name)`、`Exists(name)`、`List()`。List 扫磁盘，不轮询。 |
| `Presets` | `List()`、`Get(name)`、`Place(ply,name,origin,opts)`、`SaveFromWorld(name,cornerA,cornerB,anchor,ply)`、`Delete(name)`；格子用 bx/by/bz 或三元素数组，rotation 为 0..3，opts.overwrite 布尔。nil ply 可绕过玩家门控，仅供可信代码。 |
| `Cluster` | `Capture(x1,y1,z1,x2,y2,z2)` 返回非空气记录；`Spawn(record,pos,opts)` 返回实体或 nil,err,convexCount，pos 为引擎位置，opts 为 angles/frozen/owner；`PlaceBack(ply,ent,targetMin,rotation)`、`Break(ent,attacker)`。 |
| `Schedule` | `BlockTick(bx,by,bz,delayTicks,expectedStateId,options)`（20 TPS）；`BlockUpdate(bx,by,bz)`；`CancelBlockTick(bx,by,bz)` 取消该格所有待执行类型，不按 owner 区分。 |
| `Schedule` | `Observe(key,match,definition)`、`Unobserve(key)` 追加过滤更新观察者；match 为方块名或纯 state matcher，原处理器先运行。CancelBlockTick 不会移除 observer。 |
| `Farming` | `CanSurvive(bx,by,bz,state)`；`Plant(ply,bx,by,bz,state,opts)`、`ApplyBonemeal(ply,bx,by,bz,opts)`、`TryTrample(entity,bx,by,bz,fallDistance,opts)`，写入成功返回 true,resultCopy。 |
| `Redstone` | `Pulse(bx,by,bz,power,durationTicks)`，作用于 target 或 lightning rod。 |
| `DayCycle`、`GameMode` | `SetTicks(ticks)`（取模 24000）；`Set(ply,mode,actor)`。 |
| `Liquid` | `PickupSource(ply)`、`PlaceSource(ply,kind)`（water/lava）；成功返回结果记录，库存事务失败后调用 RollbackPickup/Placement(ply,result)，完成后调用 CommitPickup/Placement(ply,result) 发出事件。 |

## 客户端显示与光照（CL）

| 命名空间 | 调用/语义 |
| --- | --- |
| `UI` | `DrawBlockIcon(block,x,y,w,h)` 在 2D Paint 中；`DrawBlockOutline(block,bx,by,bz,color)` 在 3D 上下文中。 |
| `UI` | `OpenCreativeInventory(onSelect,opts)` 回调 id,stateIdOrNil，opts.closeOnSelect；`OpenPalette(onSelect)` 必须有回调 id；`OpenSaveManager()`、`OpenPresetManager()`。 |
| `Font` | `Measure(text,fontName)`、`TrimToWidth(text,maxWidth,fontName)`、`Draw(text,x,y,options)`、`LineHeight()`；度量是逻辑 GUI 像素，Draw 支持 font/scale/color/align/verticalAlign/shadow/maxWidth。 |
| `Hotbar` | `GetSelection()` 返回 slot/id/stateId；`SetSlot(slot,block)` 同时选中并同步，`SelectSlot(slot)`；这里 slot 为 1..9。 |
| `Effects` | `PlayBlockEffect(kind,bx,by,bz,block,opts)` 只本地；`BlockParticleMaterial(block,col,row)` 返回共享缓存材质，不修改或释放；`PlayBlockHitSound(block,pos,options)` 支持 volume/pitch。 |
| `Light` | `SampleCell(bx,by,bz,selfEmission)` 两端都有，返回 brightness,level,blockLight,skyLight；天空值不含昼夜。SV 高度列模型与 CL 渲染采样不同。 |
| `Light` | `SampleRGB(pos,emission)`、`SamplePresentationRGB(pos,emission)` 返回 r,g,b。都使用持续 MC 世界位置；后者用于物品/粒子所在格 lightmap 加移动光源，不使用手部姿势或 render-relative 位置。 |
| `Light` | `SkyLightAt(bx,by,bz)`、`ScaleRGB(r,g,b,gain)`。 |
| `Render` | `MarkCellDirty(bx,by,bz)` 重建几何/采样，不重跑世界光传播；`MarkAllDirty()` 昂贵，仅全局注册变化时使用。 |
| `Render` | `ActivePack()`：当前已发布渲染包的快照副本 `{id,build,adapter,family}`（family 为 `pbr`/`vanilla`/`other`），没有时返回 nil,"no_active_pack"。请缓存结果并在 `MC.RenderPackChanged` 时刷新。 |
| `Render` | `RegisterDynamicLightProvider(id,definition)` / `UnregisterDynamicLightProvider(id)`；`RegisterSSRDepthRenderer(id,callback)` / `UnregisterSSRDepthRenderer(id)`；`RegisterSpecialBlockEmitter(blockName,emitter)`。这些是高级渲染扩展，definition/回调协议以门面链接的 provider 实现为准。 |

可选的 Minecraft 玩家光照（`mc_light_entity`）会让持有 ARC9 的玩家保留 Source 原生光照与绘制路径，避免第三人称动画求解器重复执行。

### 资源包与图集（CL）

`Resources.VERSION == "1.2"`。资源栈准备与已发布 atlas 切换是两个操作：
PrepareSelection 同步准备 CPU 数据，不表示已发布 GPU 图集。

| 调用 | 用途 |
| --- | --- |
| `Resources.GetCatalog()`、`Refresh()` | 资源目录快照/刷新。 |
| `Resources.RegisterResourcePack(id,definition,owner)`、`UnregisterResourcePack(id,owner)` | 带归属的源包登记。 |
| `Resources.ValidateSelection(ids,revision,confirmed)` | 校验目录版本及选择。 |
| `Resources.PrepareSelection(ids,revision,resources,options)` | 同步 CPU 资源栈准备。 |
| `Resources.GetResourceSource(ids,revision,resource,confirmed)` | 打开选择快照、解析来源后关闭；返回 result,err。 |
| `Resources.ResolveTexturePath(pack,resource)` | 解析纹理来源路径。 |
| `Resources.RegisterAtlasPack(name,definition,owner)`、`UnregisterAtlasPack(name,owner)` | 已烘焙 atlas；转发 Render 的纹理包注册。 |
| `Resources.RegisterSourcePack(name,definition,owner)`、`UnregisterSourcePack(name,owner)` | 运行时烘焙的源包。 |
| `Resources.ListPacks()`、`GetSelection()` | 当前可用包/选择。 |
| `Resources.ApplyPack(name,options)`、`ReloadPack(name,options)` | 选择一个 atlas 包 / 重新加载。 |
| `Resources.GetApplyStatus(id)`、`CancelApply(id)` | 查询/取消应用任务。 |
| `Render.RegisterTexturePack(name,definition,owner)`、`UnregisterTexturePack(name,owner)`、`UnregisterTexturePackOwner(owner)` | 客户端纹理包与 owner 清理。材质路径不带扩展名。 |
| `Render.AcquireTexturePack(owner,name,priority)`、`ReleaseTexturePack(owner)` | 模式临时接管；释放后恢复玩家偏好和其他租约。 |
| `Render.SetTexturePack(name)`、`SetTexturePackPreference(name)`、`GetTexturePack()` | 立即切换 / 保存玩家偏好 / 当前包名。模式应优先用租约。 |
| `Render.GetTexturePackLeaseOwner()`、`ListTexturePacks()`、`ListTexturePackLeases()` | 当前 owner/包/租约查询。 |
| `Render.RegisterAtlasProfile(name,definition,owner)`、`UnregisterAtlasProfile(name,owner)`、`UnregisterAtlasProfileOwner(owner)` | 注册不同物理布局及清理。 |
| `Render.SetAtlasProfile(name)`、`GetAtlasProfile()`、`ListAtlasProfiles()` | 当前图集布局。 |
| `Render.ResolveAtlasTile(tile)`、`ResolveAtlasSurface(tile)` | tile 映射 / page,tile,layout。 |
| `Render.GetAtlasPageCount()`、`GetAtlasPageLayout(page)` | 图集分页查询。 |

新包通常用 addon 的 `data_static/mc/resourcepacks/` manifest 发现，无需运行时 Lua 注册。
用户使用流程见 [材质包](user/05-resource-packs.md)，复杂定义格式以
[Resources 门面](../../addons/mc_engine/lua/mc/api/cl_api.lua) 转发的实现为准，不直接调用内部表。

`Render` 还提供独立的冷路径定义目录：`RegisterPack(id,definition)`、`RegisterShader(id,definition)`、
`UpdatePack(id,definition,expectedBuild)`、`UpdateShader(id,definition,expectedBuild)`、
`GetPack(id)`、`GetShader(id)`、`ListPacks()`、`ListShaders()`、`PlanPack(id,requests)`、`GetPackStatus()`。
更新要求 expectedBuild 字符串用于版本比较；此目录独立于生产 shader variant 注册，
PlanPack 不代表 GPU 资源已准备。schema 及返回结果见
[渲染包目录](../../addons/mc_engine/lua/mc/render/cl_render_pack_registry.lua)。

## HandWeapon：选中物品与 SWEP 桥接

这一层属于引擎，通过 provider 获取上层选中物品，不要求引擎依赖 `mc_game`。
实现见 [共享桥接](../../addons/mc_engine/lua/mc/integration/sh_hand_weapon_bridge.lua)。

| 调用 | realm / 语义 |
| --- | --- |
| `RegisterResolver(id,resolver,priority)`、`UnregisterResolver(id)` | SH；resolver(stackCopy,ply) 返回 SWEP class 或 nil，由桥接选择。 |
| `RegisterSelectionProvider(id,provider,priority)`、`UnregisterSelectionProvider(id)` | SH；provider.GetSelected(ply)，可选 IsSessionOpen(ply)。 |
| `RegisterPresentationProvider(id,provider,priority)`、`UnregisterPresentationProvider(id)` | SH；provider(weapon,stackCopy,ply)，负责表现同步。 |
| `RegisterWeaponAdapter(className,adapter)` | SH；adapter 必需 acquire/matches，另可设置 retain/ownsFirstPerson。 |
| `ConfigureBaseClasses(owner,handClass,inventoryClass)` | SH；配置默认类，同一 owner 管理。 |
| `RegisterManagedClass(className)`、`UnregisterManagedClass(className)` | SH；纳入/移除受管类。 |
| `IsManagedClass(value)`、`IsInventoryControlledClass(value)`、`OwnsFirstPersonPresentation(value)` | SH；类/实体的归属与第一人称表现能力判断。 |
| `Resolve(stack,ply)` | SH；className,resolverId，失败 nil,err。 |
| `Refresh(ply)`、`Reconcile(ply,stack,context)`、`QueueRefresh(ply,stack,context)` | SV；请求重新对齐选中物品和活动武器；CL 调用返回 server_only。 |
| `SelectOwnedWeapon(ply,weapon)` | SV；请求通过预测命令切换到玩家已有的武器，并取消排队中的物品栏协调；返回 true,className 或 false,err，切换异步完成。 |
| `IsManagedActive(ply)` | 两端各自的活动武器判断；兼容名 IsInventoryActive。 |
| `IsSelectedActive(ply)`、`IsManagedSwitchPending(ply)` | CL；是否为选中物品武器 / 正在切换到物品栏接管的武器，不包括返回普通武器；IsHeldItemActive 是前者的兼容名。 |
| `GetBlockFirstPersonPose(weapon,leftHand)`、`GetBlockThirdPersonPose(ply,leftHand)`、`GetItemThirdPersonAnchor(ply,leftHand)` | CL；姿势/锚点可能返回多个值，必须直接接收，协议见客户端桥接。 |
| `SamplePresentationLighting(pos,state)`、`DrawBlockState(stateId,pos,ang,scale,lighting)` | CL；采样位置为 MC 世界坐标，绘制位置由当前渲染上下文决定。 |

客户端具体返回与绘制参数见 [客户端桥接](../../addons/mc_engine/lua/mc/integration/cl_hand_weapon_bridge.lua)。
这些 API 保留公开 Lua 名称，不要通过读取内部网络字段来猜测切换状态。

换枪通过持有者客户端的 usercmd 发起，使 SWEP 的 Deploy/Holster 保持正常预测；机器人通过服务端 StartCommand 选择。暂时被拒绝的选择会重试。延迟 Holster 期间，新请求只替换排队目标，当前阶段完成后再选择最新目标。桥接在确认最终武器激活后才清理代理，玩家选择不同武器会取消整条切换链。单个阶段十秒内未完成时报告 `hand_weapon_switch_timeout`。集成层不得手动调用 Deploy/Holster 来补偿服务端强制换枪。

## 可选 mc_game 运行时接口

这些接口不是只安装 mc_engine 就有的。共享能力有 `mc.game.items/creative/block_loot/config`（v1），
服务端有 `mc.game.fire/shears/mining/item_drops`（v1）、`mc.game.inventory`（v2），客户端有
`mc.game.item_renderer/inventory_ui`（v1）。用 GetCapability/OnCapability 协商后调用。

```lua
local inventory, err = MC.API.GetCapability( "mc.game.inventory", 2 )
if not inventory then return false, err end
local stack, slot, selectedError = inventory.GetSelected( ply )
```

库存格为 **0..35**，与客户端创造 Hotbar 的 **1..9** 不同。

| 常用 SV 调用 | 返回/用途 |
| --- | --- |
| `Inventory.Get(ply)` | selected、revision、slots[0..35] 快照。 |
| `GetSlot(ply,slot)`、`GetEquipmentSlot(ply,slot)` | ItemStack 副本；装备可用 head/chest/legs/feet/offhand 等别名。 |
| `GetSelected(ply)` | stackCopy,slot；错误为 nil,nil,err。 |
| `Give(ply,item,count,components,damage)` | inserted,remainderCopy,err；必须处理未能放入的余量。 |
| `Remove(ply,item,count)`、`Select(ply,slot)` | 扣除物品 / 选中格子。 |
| `DamageSelected(ply,amount,context)`、`DamageEquipment(ply,slot,amount,context)` | resultCopy,broken,err。 |
| `ConsumeSelected(ply,amount,replacement,context)` | result,consumed,overflow,infinite,err。 |
| `ConsumeHeld(ply,hand,amount,context)` | result,consumed,oldStack,err；手为 mainhand/offhand。 |
| `ReplaceSelected(ply,replacement,context)` | result,stack,err。 |
| `TakeSelectedWithDurability(ply,amount,context)` | stack,infinite,mutationResult,err，原子取出用于投射物。 |
| `CanTakeSelectedWithDurability(ply,amount,context)` | allowed,infinite,stack,err。 |
| `HasInfiniteMaterials(ply)`、`Open(ply)` | 无限材料判定 / 打开库存。 |

`mc.game.item_drops`（v1）供非玩家实体读取和拾取地上的掉落物（`mc_item_drop`）。位置用 MC 世界坐标；返回的列表归调用方所有。

| SV 调用 | 返回/用途 |
| --- | --- |
| `ItemDrops.FindInBox(minimum,maximum,options)`、`FindInSphere(center,radius,options)` | 掉落物列表；参数无效时 nil,err。 |
| `ItemDrops.FindNearEntity(entity,inflateX,inflateY,inflateZ,options)` | 对应 Java `getBoundingBox().inflate(x,y,z)`：实体自身世界 AABB 每侧外扩若干 Source 单位。 |
| options | `item`（物品名或列表）、`pickupReady=true`（跳过仍在拾取冷却的）、`filter(drop,stackCopy)`（返回 false 跳过）、`sortFrom`（由近到远）、`limit`。 |
| `ItemDrops.IsDrop(entity)`、`GetStack(drop)`、`IsPickupReady(drop)` | 是否有效掉落物 / stackCopy 或 nil,err / 拾取冷却是否结束。指定拾取者只限制玩家拾取，与 Java 一致。 |
| `ItemDrops.Take(drop,count,actor,options)` | takenStackCopy 或 nil,err。取走至多 count 个（默认整堆），取空时移除掉落物。默认播放拾取音效，`options.sound=false` 关闭；另有 `ignorePickupDelay`、`reason`。否决事件 `MC.CanEntityTakeItemDrop`，观察事件 `MC.EntityTookItemDrop`。 |

弓弩弹药、使用状态、掉落实体、装备写入和菜单入口的精确签名与返回值见
[游戏服务端公开门面](../../addons/mc_game/lua/mcgame/api/sv_public_api.lua)。同文件还公开
`Farming.UseHeld(ply,bx,by,bz,context)`、`Tools.UseHeld(ply,action,context)`、Fire、Shears、Mining。
这些带库存事务的调用不能用 World.SetBlock 加手动扣物品替代。
客户端能力字段见 [客户端桥接](../../addons/mc_game/lua/mcgame/api/cl_engine_bridge.lua)。

mc_game 另有共享 `CreativeStacks` 接口，用于给已有分类追加条目，而不是在冻结后新建分类：
`RegisterEntries(tab,id,operations,priority)`、`UnregisterEntries(id)`，operations 的 action 为
append/prepend/before/after，visibility 为 both/tab/search，items 为 count=1 的物品栈，
before/after 还需 anchor。高级 `RegisterProvider(id,provider,priority)` / `UnregisterProvider(id)`
及 `Invalidate()`、`Contains(stack)` 见 [创造条目实现](../../addons/mc_game/lua/mcgame/inventory/sh_creative_stacks.lua)。
外部状态变化后显式 Invalidate；依赖此模块时等待 `MC.CreativeStacksAPIReady`，不能只等引擎 APIReady。

## 事件与权限

`MC.API.Events` 是事件描述目录，每条含 realm、args、desc，监听使用 GMod
`hook.Add(name, uniqueId, callback)`。观察事件不返回值；否决事件仅在拒绝时返回 `false`，
允许时不返回，避免提前终止其他监听器。

| 事件 | 何时使用 |
| --- | --- |
| `MC.APIAvailable`、`MC.APIReady` | 注册和运行两个阶段；参数 version。 |
| `MC.APICapabilityAvailable`、`MC.APICapabilityRemoved` | 可选公开能力出现/移除；参数见上面的 capability API。 |
| `MC.CanPlayerEdit(ply)`、`MC.CanPlayerEditCell(ply,bx,by,bz,placing,context)` | SV 否决玩家操作；context.action 为 place/break/use/modify。不能阻挡所有可信 World 写入。 |
| `MC.BlocksChanged(changes,revision,actor)` | SV 一次常规事务；changes 含新旧状态和 kind。**不包含** Fill/import 原始写入。 |
| `MC.WorldFilled(fill,actor)`、`MC.WorldCleared()`、`MC.PreWorldLoad(path,name)`、`MC.WorldLoaded(path,name,blockCount)` | SV 批量世界变化/切换。 |
| `MC.ChunkHydrated(key,cx,cy,cz)` | SV 惰性数据驻留，不产生逐格事件。 |
| `MC.ClientBlockStateChanged(bx,by,bz,oldStateId,newStateId,reason)` | CL 单格投影改变。 |
| `MC.ClientWorldProjectionChanged(reason,context)` | CL 批量快照/加载/卸载/重置；可重建派生索引。 |
| `MC.RenderPackChanged(info,previousInfo)` | CL 一个准备好的渲染包运行时已发布（同一个包重新准备也会触发）；info 与 `Render.ActivePack()` 相同。 |
| `MC.StateRevisionApplied(generation,revision)` | CL 完成一次权威修订。 |
| `MC.PlayerPlacedBlock`、`MC.PlayerBrokeBlock`、`MC.PlayerUsedBlock` | SV 玩家操作已提交。 |
| `MC.PlayerPickedUpFluid`、`MC.PlayerPlacedFluid` | SV 桶的库存事务确认后提交。 |

存档、预设、cluster、爆炸、车辆、Workshop 和游戏模式的完整事件参数直接列于
[共享 API 末尾的事件表](../../addons/mc_engine/lua/mc/api/sh_api.lua)。mc_game 自己登记的事件由其桥接文件补充。
不要把 `BlocksChanged` 当成全部世界变化的唯一通知，也不要直接修改 chunk 来逃过事务和同步。
