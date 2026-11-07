# 材质包

[English](../../../docs-user/05-resource-packs.md) | 简体中文

材质包改变方块贴图、贴图动画和 LabPBR 伴图。
包内的模型、方块状态、GUI、声音、语言和 OptiFine CTM 尚不支持完整替换。

## 选择材质包

1. 输入 `mc_texture_packs`，或从 `mc_config` 的“界面 → 材质包”打开管理器。
2. 选择一个包，点击“应用”。
3. 若提示资源包版本不匹配，决定是否继续尝试。
4. 等待准备与烘焙完成。

当前一次启用一个包。单击列表只改选择，点击“应用”才生效。
成功后保存偏好，下次进入地图恢复；失败时保留上一套可用资源。

“撤销更改”放弃草稿，“恢复默认”切回默认包。
默认材质 addon 必须保留，用来补齐其他包缺少的贴图。

## 随附材质包

| 包 | 安装要求 |
|---|---|
| 默认 | 安装 `mc_texturepack_default`，必需 |
| Programmer Art | 安装 `mc_texturepack_programmer_art`，已含原始资源 |
| AVPBR | 安装 `mc_texturepack_avpbr`，已含原始资源 |

Programmer Art 与 AVPBR 应用时自动生成图集，无需用户运行离线烘焙脚本。
AVPBR 的法线、高光等效果还需选择 `mc:pbr` [光影包](06-shader-packs.md)。

安装或移除 addon 后须完整重启游戏；管理器刷新不会挂载新 addon。

## 导入自己的 Java 资源包

在**客户端**解压到：

```text
garrysmod/data/mc/resourcepacks/inbox/MyPack/
  pack.mcmeta
  assets/
  pack.png       （可选封面）
```

`pack.mcmeta` 应直接位于 `MyPack/`，然后在管理器刷新并应用。
ZIP 直读需要具备资源包 I/O 功能的 Native 模块；不安装模块时使用解压目录。

材质选择属于客户端。把资源包只放进专用服务器的 DATA 目录，
不会自动给玩家安装或切换材质。不同玩家可以选择不同的包。

## 常见问题

- **列表没有包**：检查客户端路径、`pack.mcmeta` 所在层级和 addon 挂载状态。
- **版本警告**：继续应用只会尝试读取兼容资源，不会让模型等未支持功能生效。
- **贴图正确但没有 PBR 效果**：检查伴图是否齐全，并在光影页选择 PBR。
- **应用失败**：记录管理器错误和控制台输出；先恢复默认包确认基础资源可用。
