# World Importer

[English](../../../../tools/world%20importer/README.md) | 简体中文

把 Java 版 Minecraft 存档中的世界导入到 Garry's Mod。

可以导入方块、方块状态、朝向和高度，不需要手动转换坐标或填写
DataVersion。

## 使用前准备

电脑需要安装 Python 3.11 或更新版本。

Windows 用户安装 Python 时，请保留安装器中的 **Tcl/Tk** 选项。
不需要安装其他库，也不需要执行 `pip install`。

## 启动

Windows 用户双击：

```text
start.cmd
```

也可以在该文件夹打开 PowerShell，然后运行：

```powershell
.\start.ps1
```

启动后会出现 World Importer 窗口。右上角可以在简体中文和英文之间切换。

## 导入步骤

1. 点击“浏览”，选择 Minecraft 世界目录。

   应选择包含 `level.dat` 的世界根目录，而不是其中的 `region` 文件夹。

2. 选择维度：主世界、下界或末地。

3. 设置导入范围。

   - “Chunk”适合按 Minecraft 区块选择。
   - “方块坐标”适合填写精确的 X/Y/Z 范围。
   - 范围两端都包含在导入结果中。

4. 选择 GMod 的 `data` 目录。

   Windows 专用服务器通常位于：

   ```text
   garrysmod/data
   ```

5. 选择输出方式。

   - **GMod 存档**：生成可从存档管理器加载的世界。
   - **mc_import JSON**：生成供 `mc_import` 命令使用的导入文件。

6. 点击“开始导入”。

导入过程中会自动切换到“任务与日志”页。完成后可以点击
“打开输出目录”查看生成的文件。

## 导入完成后

选择“GMod 存档”时，进入服务器控制台执行：

```text
mc_load_save 存档名
```

也可以进入游戏后打开存档管理器：

```text
mc_save_manager
```

选择“mc_import JSON”时，进入服务器控制台执行：

```text
mc_import 文件名
```

## 默认行为

### 自动兼容 DataVersion

程序会自动识别 Minecraft 存档版本并选择正确的读取方式。
方块状态仍会逐项检查，因此不是无条件跳过版本校验。

### 跳过方块实体 NBT

默认不会导入箱子库存、告示牌文字、熔炉进度等方块实体数据。

这样可以让 GMod 正常创建箱子、告示牌等实体，并避免存档加载时出现
`opaque_block_entity_conflicts_active`。

方块本身、朝向和状态仍会保留。

如果确实需要保留原版方块实体数据，可以在“高级参数”中取消
“跳过方块实体 NBT”。这样做可能与 GMod 默认方块实体冲突。

## 常见问题

### 选择世界后提示找不到 region 文件

请确认选择的是包含 `level.dat` 的世界根目录，并且该维度确实生成过区块。

控制台原文（目录会随存档位置变化）：

```text
FileNotFoundError: could not find a region directory; tried: D:\Minecraft\saves\World\region
```

### 提示 DataVersion 不受支持

当前工具无法安全读取这个 Minecraft 版本生成的存档。请使用受支持的
Minecraft 版本打开世界并重新保存，然后再导入。

控制台原文（坐标和版本号会随存档变化）：

```text
[MC import] unsupported_chunk_storage_data_version: chunk 0,0 DataVersion 5000 has no audited chunk-storage adapter
```

如果关闭了自动版本兼容，也可能看到：

```text
[MC import] data_version_mismatch: chunk 0,0 has DataVersion 3465, expected 4897; --auto-data-version accepts audited storage versions
```

### 提示存档缺少 DataVersion

这通常表示区块数据不完整或来自无法识别的存档格式。请用 Minecraft
打开并重新保存世界后再试。

控制台原文（坐标会随存档变化）：

```text
[MC import] missing_data_version: chunk 0,0 is missing DataVersion
```

### 提示 `opaque_block_entity_conflicts_active`

存档中包含了与 GMod 默认方块实体冲突的 NBT。请保持“跳过方块实体 NBT”
为勾选状态，重新导出存档后再加载。

控制台原文：

```text
[MC] load save failed: opaque_block_entity_conflicts_active
```

### 双击 `start.cmd` 后窗口立即关闭

说明系统没有找到 `python` 命令。请重新安装 Python 3.11 或更新版本，
安装时勾选“Add Python to PATH”和 Tcl/Tk，然后重试。

控制台原文：

```text
Python 3 was not found. Install Python 3.11 or newer.
```

### 导入很慢

导入器需要读取并转换选区内所有区块。一次性选择过大的范围时，请适当减小
选区，或使用 Chunk 坐标分段导入。
