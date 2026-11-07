# Minecraft -> Garry's Mod 转换约定

[English](../../../../addons/mc_item/AGENTS.md) | 简体中文

本仓库把 Minecraft Java 的物品、动画和渲染行为移植到 Garry's Mod。凡是修改模型位置、角度、缩放、动画、第一人称投影或 `PoseStack` 的代码，必须先遵守本文件。

## 基本事实

- Minecraft Java 的客户端渲染数据来自 OpenGL/JOML/`PoseStack` 约定；Garry's Mod/Source 使用 DX9/Source 约定。两边的坐标系、手性、局部轴、矩阵乘法语义和投影参数不能直接照抄。
- “OpenGL -> DX9”不是一条可以套在所有数据上的固定 `x/y/z` 交换。必须先说明数据属于 Minecraft 世界空间、相机空间、`ModelPart` 局部空间、item display 空间，还是转换后 MDL 的局部空间。
- Minecraft 世界空间的竖直轴是 `+Y`；Source 世界空间的竖直轴是 `+Z`。Source 模型局部基是 `+X = Forward`、`+Y = Left`、`+Z = Up`，而 `Angle:Right()` 指向局部 `-Y`。
- Minecraft 相机空间按 `+X = 右`、`+Y = 上`、`+Z = 朝向观察者` 处理；换到 Source 相机基时使用 `Right / Up / -Forward`。现有唯一入口是 `MCITEM.Render.CameraOffset`。

## 单位与缩放

- Minecraft item display 的 translation 使用模型像素，必须先除以 `16` 才是方块单位；使用 `MCITEM.Render.DisplayOffset`。
- 当前 `mc2source` 物品模型的导出常量是 `$scale 36.5`，即一个模型方块单位对应 `36.5` Source units。它是模型导出比例，不是世界方块尺寸。
- Minecraft 世界中的一格必须从运行时方块尺寸 API/`MC.BS` 获取。禁止拿 `36.5` 代替世界方块尺寸，也禁止把可变的世界方块尺寸反过来改写模型导出比例。
- 模型实体又有自己的 render scale。位移与模型缩放必须处在同一套单位中，不能只缩模型而漏缩相机空间位移。

## 变换与投影

- 必须保留 Java `PoseStack` 的 translate/rotate/scale 调用顺序、右乘语义和 pivot。旋转不可交换；不要把每个 Java Euler 分量独立改符号后再用另一顺序组合。
- 优先在 Minecraft 空间重建完整矩阵或三个基向量，最后只做一次 Minecraft -> Source 换基。禁止用一串手调 Source Euler 角近似已经可以从源码还原的矩阵。
- 相机轴映射不能直接用于编译后的模型轴。当前盾牌几何的明确合同是 `ShieldModel (x,y,z) -> runtime MDL local (z,x,y)`，还包含 special renderer 的 `(1,-1,-1)` 和 idle sequence yaw；使用 `MCITEM.Render.ApplyExactShieldTransform`，不要另写一套。
- Minecraft 传给透视矩阵的 `70` 是垂直 FOV；Source viewmodel FOV 按参考 `4:3` 的水平 FOV 解释。换算公式是 `2*atan(tan(vertical/2)*(4/3))`，`70` 对应约 `86.067`，禁止直接把 `70` 填给 Source 后声称画面等价。

## 修改要求

- 每个新向量/角度/缩放值旁边必须能判断它的来源空间和单位；来源不清楚时先追 Minecraft 源码与转换器输出。
- 先复用或扩展 `lua/mcitem/cl_item_render.lua` 的公共转换函数。发现新的轴合同，应集中实现并加回归检查，禁止在某把武器里偷偷写 private 轴修正。
- 手调锚点只能补偿 Source viewmodel/模型资源本身的已知差异，不能用来掩盖符号、轴、FOV、`1/16` 或方块尺寸换算错误。
- 校验时至少分别检查静止位姿、发生旋转后的位姿和非零 pivot/translation；只看静止截图无法证明坐标转换正确。
