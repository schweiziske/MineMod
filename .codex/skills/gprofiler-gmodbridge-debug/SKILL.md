---
name: gprofiler-gmodbridge-debug
description: Use when debugging Garry's Mod plugins with GProfiler, gmodbridge, or gmodctl; when you need to inspect LuaJIT hot paths, hook/network/timer/file/command profiles, client console logs, or reproducible Lua traces.
---

# GProfiler + gmodbridge 调试

## 概要
!!!!只有用户要求使用的时候 你才能使用！！！！

先判断问题类型，再选工具：

- 交互式看图和分类分析，用 GProfiler
- 复现、拉日志、跑 Lua、导出 JSON，用 `gmodctl` + `gmodbridge`
- LuaJIT 热点采样，用 `gmodctl profiler-*`

## 使用顺序

1. 先确认 `gmodctl serve` 正在运行。
2. 如果要看控制台、Lua 报错、网络消息或命令输出，优先用 `gmodctl`。
3. 如果要看 hook、timer、file I/O、function、database、net 或 entity var 这种分栏结果，优先用 GProfiler UI。
4. 如果要做 LuaJIT 热点采样，使用 `gmodctl profiler-start` / `profiler-stop` / `profiler-query`。

## 工具选择

### 用 GProfiler 的场景

- 想看 Hooks、Networking、Functions、Commands、Timers、File I/O、Database
- 想看某个插件在 Client / Server / Both 哪一侧耗时
- 想看 call graph、bottleneck、源文件和行号
- 想在 UI 里交互式切 tab、筛选、对比

### 用 gmodbridge / gmodctl 的场景

- 想复现某个命令、Lua 片段或插件行为
- 想抓 `print`、`ErrorNoHalt`、`OnLuaError`、console scrollback
- 想把结果变成 JSON，继续自动分析
- 想在无 UI 方式下收集证据

## gmodctl 常用流程

```powershell
$exe = "E:\server\gmodds\garrysmod\addons\mc\_tools\gmodbridge\bin\gmodctl.exe"

& $exe serve
& $exe status
& $exe logs 50
& $exe console 100 "E:\SteamLibrary\steamapps\common\GarrysMod"
```

抓可复现记录时，先放 marker，再跑动作，再读日志：

```powershell
$marker = & $exe marker
& $exe cmd "your_repro_command_here"
Start-Sleep -Milliseconds 500
& $exe logs all --after $marker
```

如果要执行 Lua：

```powershell
& $exe lua "print(jit.status())"
& $exe eval-json "return { ok = true }"
```

## LuaJIT 采样

`gmodctl profiler-start` 用来启用 bridge 内置的 LuaJIT profiler。

默认值：

- `mode = li1`
- `dumpfmt = l;`
- `depth = 60`

示例：

```powershell
& $exe profiler-start
Start-Sleep -Seconds 3
& $exe profiler-stop
& $exe profiler-query 20
```

自定义模式：

```powershell
& $exe profiler-start "li10" "l;" 80
```

## 关键禁忌

- 不要同时运行 GProfiler 的 JIT profiler 和 `gmodctl profiler-start`
- 不要把 GProfiler UI 当成 bridge 替代品；它们是互补的
- 不要在没有 `gmodctl serve` 的情况下指望 `gmodctl` 直接连上客户端

## 常见判断

- 帧卡顿像 hook 或渲染问题：先 GProfiler Hooks / Functions
- 同步慢或消息大：先 GProfiler Networking
- 命令慢：先 GProfiler Commands
- 文件读写卡顿：先 GProfiler File I/O
- 想要 LuaJIT 热点：用 `gmodctl profiler-*`
- 想抓控制台错误或输出：用 `gmodctl logs` / `console`

## 结果汇报

当 AI 要把结果告诉用户时，优先交代：

- 用了哪个工具
- 在 Client / Server / Both 哪一侧采样
- 采样时间或复现命令
- top rows / 最热路径
- 是否看到 `gmodbridge`、`gprofiler` 或 `lua_shared.dll` 相关限制
