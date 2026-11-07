# Source 气垫船与 Minecraft 水体

[English](../airboat-water.md) | 简体中文

引擎 addon 自动为 `prop_vehicle_airboat` 提供 Minecraft 水体支持。在载具菜单中生成普通 Half-Life 2 气垫船，即可使用原有的上下车、油门、倒车和转向操作。不需要另一种载具类、物品或控制台命令。

服务端根据物理船体计算四个支撑点，以排水浮力和垂直阻尼提供浮力及俯仰、横滚支撑；推进、转向、座位和实体碰撞仍由原生 Source 载具负责。采样位置从实体的引擎坐标转换到 MC 世界坐标，并读取当前方块尺寸。连续水柱按完全浸没处理，因此沉入深水的船可以跨越多个水方块回浮，不会停在内部方块边界。海草等含水植物、含水方块与普通水使用同一套液体解码。

每个服务端 tick 都会重新计算支撑，因此放置和移除水后会立即响应。被冻结的物理对象不受额外力。岩浆和空气不提供浮力。当 Source 报告原生 BSP 水接触时，适配器交还给引擎，避免叠加两套浮力。适配器不会修改 `Entity:WaterLevel()` 或伪造 BSP contents；依赖这些值的其他 addon 仍然只能看到 Source 水。

实现位于 [sv_airboat_water.lua](../../addons/mc_engine/lua/mc/integration/sv_airboat_water.lua)，由引擎 addon 在服务端加载，跟踪已有及新生成的气垫船，并在实体移除后释放记录。支持范围是原生气垫船类，不包括任意道具船、吉普车或第三方载具框架。装饰用的 `prop_dynamic` 气垫船模型不可驾驶，也不会获得此适配。
