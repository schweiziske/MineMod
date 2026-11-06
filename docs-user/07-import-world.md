# 导入 Minecraft 世界

导入器将 Java 版世界的选区转换为 MineMod 方块。
支持方块、状态、朝向以及主世界、下界、末地；不迁移玩家、mob 和整套 Minecraft 游戏状态。

## 启动与转换

电脑需安装 Python 3.11 或更新版本及 Tcl/Tk，无需安装第三方库。

1. 在 `tools/world importer/` 双击 `start.cmd`。
2. 选择含 `level.dat` 的世界根目录，随后选择维度。
3. 按 Chunk 或方块坐标填写选区，两端均包含。输入使用 Minecraft 坐标，Y 为高度。
4. 将“GMod data 目录”设为目标**服务器**的 `garrysmod/data/`；
   单人游戏选择本机目录。
5. 选择输出方式，填写名称，点击“开始导入”。

默认输出位置是工具自己的 `output/`，**不会自动安装到 GMod**。
转换完成后，可在“任务与日志”查看结果并打开输出目录。

## 输出为 GMod 存档

普通读档使用此方式，格式保持 `auto`。

若输出到正确的服务器 DATA 目录，打开 `mc_save_manager` 刷新后读取；
也可在服务器控制台执行：

```text
mc_load_save 存档名
```

读取会替换当前 MC 世界。若转换在其他电脑完成，需复制完整输出，
包括存档文件或目录及其关联分片，不能只复制一个 manifest。

## 输出为 mc_import JSON

文件位于所选 DATA 目录的 `mc_import/`，分片也须一起保留。
由管理员或服务器控制台选择导入方式：

| 命令示例 | 作用 |
|---|---|
| `mc_import house replace` | 替换当前 MC 世界，默认方式 |
| `mc_import house append` | 保留现有世界并追加导入；重叠位置可能被改写 |

这里的 `house` 对应 `mc_import/house.json`。
要向现有世界添加建筑，应明确使用 `append`；`replace` 会清空原世界。

导入成功后用 `mc_save 新存档名` 保存结果。

## 原点与方块实体

默认选区移动到原点 `0, 0, 0`，输出使用 MineMod 坐标，Z 为高度。
需要放到其他位置时调整高级参数中的原点；首次先转换一个小区域确认位置。

默认勾选“跳过方块实体 NBT”：不迁移箱子库存、告示牌文字或熔炉进度，
方块及其朝向仍保留。取消勾选可能与 MineMod 的方块实体冲突，
报 `opaque_block_entity_conflicts_active` 时应重新勾选并导出。

## 转换失败时

| 提示或现象 | 检查 |
|---|---|
| 找不到 region | 世界目录和所选维度是否正确，该维度是否生成过区块 |
| DataVersion 不受支持或缺失 | 查看日志，确认世界版本与区块数据可被工具读取 |
| 找不到方块或状态不支持 | 查看转换日志中的具体 ID；不能把未知方块当成完整导入 |
| 工具无法启动 | 检查 Python、PATH 和 Tcl/Tk |
| 游戏中找不到结果 | 检查是否仍输出在工具的 `output/`，以及是否复制了所有分片 |

更多启动与错误说明见[导入器说明](../tools/world%20importer/README_CN.md)。
