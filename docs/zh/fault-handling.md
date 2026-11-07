# 故障上报约定

[English](../fault-handling.md) | 简体中文

适用于 MineMod 内部跨模块调用、资源加载和世界数据边界。实现见
[`sh_fault.lua`](../../addons/mc_engine/lua/mc/sh_fault.lua)。第三方 addon 的受支持入口仍是
[`MC.API`](api.md)，这些 `MC.*` 辅助函数不属于公开扩展 API。

## 记录与严格模式

`mc_strict` 默认 `0`，保存到配置。发生故障时按稳定的 `code` 去重，首次打印，
每次累加计数并更新详情；`mc_strict 1` 则在记录后抛出 Lua 错误。
严格模式和故障表分别属于当前 Lua realm，客户端和服务端要分别查看。

| 命令 | 作用 |
| --- | --- |
| `mc_faults` | 列出当前 realm 的故障代码、次数、最近详情及首次记录的位置。 |
| `mc_faults_clear` | 清空当前 realm 的故障记录。 |

记录故障不等于恢复成功。调用者仍要中止当前操作、保留旧资源或回滚事务，
不能把未知数据改成空气、空表、成功结果后继续发布。

## 辅助函数

| 调用 | 返回与语义 |
| --- | --- |
| `MC.StrictFaults()` | 当前是否启用严格模式。 |
| `MC.Fault(code, message, ...)` | 上报；可用 `string.format` 参数；非严格模式返回 `false`。 |
| `MC.Check(ok, code, message, ...)` | `ok` 为真时返回 `true`，否则调用 `Fault`。 |
| `MC.Need(value, code, message, ...)` | 非 `nil` 值原样返回，包括 `false`；`nil` 时上报并返回 `nil`。 |
| `MC.Try(code, fn, ...)` | 返回 `ok, result`；失败时上报。当前实现只保留被调函数的第一个返回值，不能用于保留多返回值的 API。 |
| `MC.FaultReport()` | 返回当前记录数组；这是内部的活动记录，不应修改。 |
| `MC.ClearFaults()` | 清空记录。 |

`MC.Try` 并非完整的 `pcall` 返回值透传；需要多个成功返回值时显式接收，
失败后上报并处理：

```lua
local ok, minimum, maximum = pcall( queryBounds )
if not ok then
	MC.Fault( "bounds_query_failed", "%s", tostring( minimum ) )
	return false
end
-- 在边界验证 minimum / maximum 后再交给下游。
```

## 在什么位置验证

输入、依赖、模型元数据在加载、注册、构建边界检查；修订变化时重新验证。
已经验证的方块、quad、顶点循环直接消费数据，不逐元素重复依赖探测、`pcall`
或默认值替代。首次日志去重也不能消除热循环反复发生故障的成本，应修复根因。

故障代码描述稳定的失败条件，例如 `atlas_source_missing`；动态路径、坐标、
修订放进详情，不要拼进代码导致每次成为新故障。可选能力未安装、用户取消、
无命中等正常分支按接口返回处理，不必全部上升为内部故障。
