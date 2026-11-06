# 文件本地化

MineMod 的界面文字、提示和名称来自各 addon 随包发布的 JSON 词典。本文是资源格式、加载规则、语言选择和 `MC.API.I18n` 的契约。

## 1. 资源文件

### 1.1 位置

每个 addon 把自己的译文放在统一虚拟根目录下：

```text
addons/<addon>/data_static/mc/i18n/<命名空间目录...>/<片段文件名>.json
```

安装后所有 addon 的 `data_static/` 合并进 `GAME` 搜索路径，加载器从 `GAME` 的 `data_static/mc/i18n/` 递归发现片段。`DATA` 路径不包含 `data_static/`。`data_static/*.json` 在创意工坊 GMA 白名单内。

`addons/<addon>/` 不属于命名空间，也不带来任何优先级；加载器不区分官方、内置或第三方 addon。

个人覆盖放在可写目录 `garrysmod/data/mc/i18n/overrides/`（`DATA` 路径 `mc/i18n/overrides/`），格式和命名空间规则相同。客户端与服务端各读自己的数据目录，覆盖文件不上传、不分发。

### 1.2 格式

```json
{
  "locale": "zh_cn",
  "nativeName": "简体中文",
  "aliases": ["zh", "schinese"],
  "entries": {
    "title": "设置",
    "render.distance.label": "绘制距离"
  }
}
```

| 字段 | 必填 | 含义 |
| --- | --- | --- |
| `locale` | 是 | 本文件词条所属语言。读取时转小写、`-` 换成 `_`，形状为若干 `[a-z0-9]` 段以单个 `_` 连接，最长 32 字节。不对照任何语言名单。 |
| `nativeName` | 否 | 该语言的自称，如 `简体中文` 或 `English (United States)`。非空白字符串，最多 128 个 UTF-8 字节，不含控制字符；显示时不再翻译，不参与 key 或 locale 匹配。 |
| `aliases` | 否 | 字符串数组，最多 16 个，同样规范化。只供 `auto` 匹配游戏语言，不成为词条。 |
| `entries` | 是 | 扁平对象：局部 key → 字符串译文。值不能是对象、数组或数字。 |

不允许其他顶层字段。文件为 UTF-8，可带 BOM。文件名只用于定位片段，建议写成 `<addon>.<locale>.json`，让多个 addon 在同一目录下各自命名而不遮蔽。

同一 locale 的 `nativeName` 声明一次即可，其余片段省略；可以放在原有 aliases 所在的片段，也可以由第三方语言包提供。无需额外的语言名称表。只提供元数据且 `entries` 为空的文件不会让一个没有任何译文的 locale 出现在选项中。

### 1.3 最终 key

```text
最终 key = 根目录之后的父目录（"/" 换成 "."） + "." + 局部 key
```

父目录为空时最终 key 就是局部 key。文件名和 `locale` 都不参与 key。下面三种写法得到同一个 `space1.space2.xxx`：

| 父目录 | 局部 key |
| --- | --- |
| （根） | `space1.space2.xxx` |
| `space1/` | `space2.xxx` |
| `space1/space2/` | `xxx` |

key 由 `[A-Za-z0-9_-]` 段以 `.` 连接，不能有空段、首尾点号；最终 key 不超过 200 字节。目录名只能是 `[a-z0-9_-]`，文件名只能是小写 `[a-z0-9_.-]` 并以 `.json` 结尾。

### 1.4 资源边界

超出任何一项时整个文件被拒绝并报告，不截断：

| 项目 | 上限 |
| --- | --- |
| 单个根目录下的片段数 | 4096 |
| 命名空间目录深度 | 8 |
| 虚拟路径长度 | 240 字节 |
| 文件大小 | 1 MiB |
| 单文件词条数 | 10000（GMod 的 `util.JSONToTable` 对单个文档限制 15000 个 key） |
| 全部词条数 | 524288 |
| 译文长度 | 8192 字节 |
| 语言自称长度 | 128 字节 |

### 1.5 安装与更新

完整游戏安装需要 `mc_engine`、`mc_game` 和 `mc_item`。`mc_engine` 提供加载器与消息协议；`mc_game` 提供原版物品、容器与创造分类词典；`mc_item` 提供效果、附魔、武器说明和生成菜单词典，因此 MCITEM 的完整菜单也依赖 `mc_game` 的物品名称。材质包、光影包的词典随各自内容包安装。

服务器和每个客户端都必须安装所需内容包。`AddCSLuaFile` 不分发 JSON 词典，服务器也不会把词典发送给客户端。只有服务器安装了资源时，客户端仍可能显示英文回退或 key；此时应安装对应内容包，再执行 `mc_i18n_reload`，不要把词典复制到服务器的个人覆盖目录来代替客户端安装。

升级消息协议时，服务器与客户端的三个核心包一起更新，然后重新连接。不要同时挂载同一 addon 的旧版 GMA 和新版散文件；重叠路径会遮蔽资源，重载词典无法解决文件版本混用。

三个核心 addon 均提供 `addon.json`。使用游戏附带的 `gmad` 分别打包，例如：

```text
gmad create -folder addons/mc_engine -out <输出目录>/mc_engine.gma
gmad create -folder addons/mc_game -out <输出目录>/mc_game.gma
gmad create -folder addons/mc_item -out <输出目录>/mc_item.gma
```

不要排除 `data_static/mc/i18n/`。引擎字体许可证位于 `data_static/mc/licenses/unifont.txt`，随包保留；打包忽略项仅排除文档、开发脚本、原版贴图的 `.mcmeta` 和不使用的模型平台副本，不排除游戏使用的模型、贴图或词典。

## 2. 发现与合并

1. 先列出 `GAME` 下全部片段，按完整虚拟路径的字节序排序后逐个加载；再按同样规则加载 `DATA` 覆盖目录。文件枚举顺序、`pairs` 顺序和 autorun 顺序都不影响结果。
2. 同一 `locale` 下最终 key 重复时，后加载的文件生效，加载阶段打印一次警告，包含 locale、key、先前来源和新来源。两个值相同也算重复。重复不是错误，不拒绝任何文件。
3. 别名同样按加载顺序登记；同一别名指向不同 locale 时后加载者生效并警告。
4. 无法读取、JSON 无效、字段或 key 不合法、超出边界的文件整个不加载，记入报告的 `errors`，并上报故障 `i18n_resource_invalid`（见 `mc_faults`）。其余文件照常加载。
5. 一轮加载完成后整体替换词典、来源记录和 locale 列表，然后通知语言变化（原因 `reload`）。查询在替换前一直读旧词典。

`nativeName` 同样按上述加载顺序合并：省略字段不清空已有名称；相同名称不警告，不同名称后加载者生效，记录 `nativeNameConflicts`，包含前后名称及双方来源。`nativeNames` 报告保存各 locale 最终的 `{ nativeName, source }`。删除覆盖后重载会恢复发布资源中的名称。

两个 addon 提供完全相同的虚拟路径时，`GAME` 只能读到挂载在前的那一份，被遮蔽的副本对加载器不可见。用唯一的片段文件名避免这种情况。

来源写作 `GAME:data_static/mc/i18n/...` 或 `DATA:mc/i18n/overrides/...`。

## 3. 语言选择

### 3.1 可用语言

至少有一个词条成功加载的 locale 就是可用语言，按 locale 字典序排列。新增一个从未在代码中出现过的 locale 文件并重新加载后，它就出现在选项中。语言选择界面显示该语言的 `nativeName`，缺少名称时显示 locale 标识；保存值始终是 locale。切换界面语言不翻译其他语言的自称，便于玩家找回自己的语言。`auto` 是选择模式而不是词典，其显示名走普通翻译 key：客户端为 `config.language.auto`（自动／跟随游戏），服务端为 `config.language.auto_server`（自动／英语）。

### 3.2 客户端：`mc_language`

客户端 convar `mc_language`（存档、userinfo），默认 `auto`：

- `auto`：把 `gmod_language` 规范化后匹配已加载的 locale；不匹配时查文件声明的 `aliases`（只认指向已加载 locale 的别名）；都不匹配时用 `en_us`。
- 显式 locale：按原样保存，即使当前没有该语言的文件也不改写设置；查询暂时回退到 `en_us`，安装资源并重新加载后恢复。
- 写入时规范化（`ZH-CN` 存为 `zh_cn`）；无法识别的值按 `auto` 处理并在控制台提示。

`gmod_language` 的变化通过 convar 回调感知，另有每秒一次的轻量检查，覆盖引擎不通知 Lua 的情况。

### 3.3 服务端：`mc_console_language`

服务端 convar `mc_console_language`（存档），默认 `en_us`，决定服务端控制台和管理员可见文字使用的语言。服务端没有自己的游戏语言，`auto` 等同 `en_us`。它不影响任何玩家，玩家的选择也不影响它。

### 3.4 语言变化通知

显式设置变化（`setting`）、`auto` 下游戏语言变化（`game_language`）和词典重新加载（`reload`）都会：

1. 刷新 `BindPhrase` 绑定的 GMod 短语；
2. 按名称排序调用 `RegisterLanguageChanged` 登记的回调 `callback( locale, reason )`，单个回调出错上报 `i18n_language_callback`，不影响其他回调；
3. 运行钩子 `MC.LanguageChanged( locale, reason )`。

已打开的界面和语言相关缓存应在回调里刷新。

## 4. 查询

### 4.1 回退顺序

```text
指定或当前 locale 的最终 key -> en_us 的同一 key -> key 本身
```

调用方不提供内联中文或英文 fallback 文案。缺词按 locale 和 key 记录一次（最多 4096 条）：`base` 表示用了 `en_us`，`key` 表示显示了 key。`mc_i18n_debug 1` 时每个缺词只打印一次；平时只在 `mc_i18n_missing` 和报告中查看，不会每帧刷屏。

查询只读内存词典，不枚举文件、不解析 JSON、不构造临时词典。

### 4.2 参数与消息描述

译文用 `{name}` 形式的命名参数，参数值是字符串或数字，按原样替换；没有提供的参数保留原样。使用完整句子模板，不拼接语言专属的词片段。`{1}`、`{2}` 等位置参数取 vars 的数组部分，供转换后的 Minecraft 模板使用（第 9 节）。

参数值也可以是消息描述 `{ key = "...", vars = { ... } }`，它先在同一 locale 中翻译再代入，最多嵌套 4 层，超出部分显示 `?` 并上报 `i18n_spec_too_deep`。字符串参数永远是字面文本，不会被当作 key 翻译，因此玩家输入的名称可以直接作为参数。

### 4.3 计数变体

`TranslateCount( key, count )` 在 `count == 1` 时取 `<key>.one`，否则取 `<key>.other`，并自动提供 `{count}`。哪个 locale 有任一变体就由它决定，所以没有单数形式的语言只需提供 `.other`。不引入 ICU 或脚本表达式。

## 5. `MC.API.I18n`

位于 `addons/mc_engine/lua/mc/api/sh_api.lua`。输入不合法时返回 `nil, err`（布尔类返回 `false, err`），不返回内部表。

| 函数 | 领域 | 说明 |
| --- | --- | --- |
| `Translate( key, vars, locale )` | 共享 | 按第 4 节查询；`vars` 可含嵌套消息描述。错误：`invalid_key`、`invalid_vars`、`invalid_locale`。 |
| `TranslateCount( key, count, vars, locale )` | 共享 | 计数变体。错误另有 `invalid_count`。 |
| `TranslateForPlayer( ply, key, vars )` | 共享 | 服务端本机词典中该玩家语言的译文，不含玩家机器上的个人覆盖，也不发送任何消息。 |
| `TranslateConsole( key, vars )` | 共享 | 本领域控制台语言的译文：服务端为 `mc_console_language`，客户端为界面语言。 |
| `Notify( ply, key, vars, channel )` | 服务端 | 向一个玩家发送 key 与参数，由其客户端翻译；返回 `true` 或 `false, err`。`channel` 为 `chat`（默认）、`console` 或 `both`。客户端调用返回 `false, "server_only"`。 |
| `Has( key, locale )` | 共享 | 指定或当前 locale 是否直接含有该 key（不计回退）。 |
| `Language()` | 共享 | 本领域当前有效 locale。 |
| `LanguageSetting()` | 共享 | 客户端 `mc_language` 或服务端 `mc_console_language` 的规范化设置值，可能是 `auto`。 |
| `LanguageForPlayer( ply )` | 共享 | 服务端按玩家 userinfo 解析出的 locale；客户端返回本机语言。 |
| `ConsoleLanguage()` | 共享 | 本领域控制台语言。 |
| `Locales()` | 共享 | 已加载 locale 列表（副本）。 |
| `LanguageOptions()` | 共享 | `{ { value = "auto", label = <本领域的自动选项译文> }, { value = locale, label = <nativeName 或 locale> }, ... }`。 |
| `SetLanguage( setting )` | 客户端 | 设置 `mc_language`，返回规范化后的值；服务端返回 `nil, "client_only"`。 |
| `RegisterLanguageChanged( name, callback )` | 共享 | 登记 `callback( locale, reason )`，同名替换。 |
| `UnregisterLanguageChanged( name )` | 共享 | 取消登记。 |
| `Reload()` | 共享 | 重新扫描本领域可见的文件，返回报告。 |
| `Report()` | 共享 | 上次加载的报告副本：`files`、`errors`、`conflicts`、`aliasConflicts`、`nativeNames`、`nativeNameConflicts`、`locales`、`entries`、`generation`，以及 `realm`、`language`、`missing`。 |
| `MissingKeys( locale )` | 共享 | 自上次加载以来的缺词：`{ [locale] = { [key] = "base" \| "key" } }`，给出 locale 时只返回该语言。 |
| `BindPhrase( phrase, key, vars )` | 客户端 | 让 GMod 短语 `#phrase`（如武器 `PrintName`）跟随 MC 语言和重新加载。 |

提供译文不需要调用任何注册函数，也没有 manifest；增加 JSON 文件即可。调用方不能写入加载器的词典。

引擎内部代码直接使用 `MC.T( key, vars, locale )` 和 `MC.I18n.Resolve( keyOrSpec, vars, locale )`，回退规则相同。

### 5.1 玩家消息

面向玩家的提示使用 `Notify`，不要先调用 `TranslateForPlayer` 再发送字符串：

```lua
MC.API.I18n.Notify( ply, "server.gamemode.changed", {
	name = target:Nick(),
	mode = { key = "server.gamemode.creative" },
}, "both" )
```

`name` 原样保留；嵌套的 `mode` 与外层消息都由接收方使用自己的 locale 和个人覆盖解析。玩家的 `console` 通道指该玩家的客户端控制台，不是服务端控制台。

内部共享模块 `mc/sh_messages.lua` 提供：

| 函数 | 作用 |
| --- | --- |
| `MC.Messages.Spec( key, vars )` | 构造尚未翻译的消息描述；不发送消息。 |
| `MC.Messages.Encode( spec )`、`Decode( payload )` | 在传输边界校验并复制消息描述；返回结果或 `nil, err`。`nil` 描述编码为空字符串，空字符串解码为 `nil`，表示无提示。 |
| `MC.Messages.Read()` | 读取一个网络字符串并解码；失败通过 `MC.Fault` 上报，同时返回 `nil, err`。 |
| `MC.Messages.Notify( ply, keyOrSpec, vars, channel )` | 内部发送入口，接受 key 或完整描述。 |
| `MC.Messages.Console( keyOrSpec, vars )` | 使用本领域控制台语言输出，不发送网络消息。 |
| `MC.Messages.Reply( ply, keyOrSpec, vars, channel )` | 服务端命令回调使用；有效玩家走 `Notify`，服务器控制台调用走 `Console`。 |

通道 `mc_message` 只由服务器发送，包含 2 位通道编号和一个 JSON 网络字符串；没有词典传输或客户端向服务端的消息接收器。存档、预设的既有响应复用相同描述格式，不另发第二条提示。服务端与客户端的这些响应协议必须一起更新，不兼容旧的已翻译字符串字段。

消息 JSON 最多 8192 字节；每个描述最多 32 个参数，整棵描述最多 128 个参数，嵌套最多 4 层。参数只接受字符串、有限数字或嵌套描述，单个字符串最多 2048 字节。参数名为最多 64 字节的字母、数字、下划线串；1–128 的整数索引在传输前转为字符串，以保留 `{1}` 等占位符。key 沿用词典 key 校验，非法字段、类型或超限消息被拒绝，不截断、不发送。

存档和预设窗口保留消息描述而非仅保留已翻译文字。语言变化或词典重载时从缓存列表重建界面，保留筛选、搜索、选中项、输入的名称和提示，不为语言刷新重新请求列表。预设读取失败同时显示在聊天和仍打开的窗口状态栏中，完整状态文字可通过悬停查看。底层技术错误代码仍作为字面参数保留。

## 6. 内容 key 模板

内容定义只保存稳定 id，显示文字的 key 由 id 按下表推导；需要复用别处文字时才显式给出 key。key 由定义内容的 addon 在自己的 `data_static/mc/i18n/` 中提供译文。

| 内容 | 推导出的 key | 显式指定 |
| --- | --- | --- |
| 创造分类 | `itemGroup.<命名空间>.<路径>`，路径中的 `/` 换成 `.`。原版 14 个标签沿用 Minecraft 自己的 `itemGroup.*`。 | `titleKey` |
| 方块 | `block.<命名空间>.<路径>` | `translationKey`、`translationVars` |
| 物品 | `item.<命名空间>.<路径>`；BlockItem 不写时继承所属方块的 key 和参数 | `translationKey`、`translationVars` |
| 效果、附魔 | `effect.<命名空间>.<路径>`、`enchantment.<命名空间>.<路径>`，等级数字为 `enchantment.level.<n>`（1–10） | 无 |
| 药水 | Minecraft 的 `item.minecraft.<potion\|splash_potion\|lingering_potion>.effect.<名称>` | 无 |
| 配置分组 | `config.group.<id>` | `labelKey` |
| 配置分类 | `config.category.<id>.label`、`config.category.<id>.description` | `labelKey`、`descriptionKey` |
| 配置项 | `config.setting.<ConVar 名>.label`、`config.setting.<ConVar 名>.help` | `labelKey`、`helpKey` |
| 配置选项 | `config.setting.<ConVar 名>.choice.<值>` | `labelKey` |
| 配置单位 | `config.unit.<单位>` | 无 |
| 光影包或独立 shader | `shaderpack.<id，":" 换成 "_">.` 加 `name`、`description`、`groups.<id>.label`、`settings.<key>.label`、`settings.<key>.help`、`presets.<id>.label` | 描述文件中只写完整 key，见第 8 节 |

已经发布的内容沿用上表的 key；改动 key 等同于删除旧译文。`MC.I18n.ContentKey( kind, id )` 按上表从内容 id 构造 key（`/` 换成 `.`，id 不合法时返回 `nil`）。

方块和物品注册（`MC.API.Blocks.*`、`MC.API.Items.Register`、mod 注册表）拒绝 `disp`、`dispZH`、`displayName`、`displayNameZH`，返回 `inline_name_unsupported`；`translationKey` 或 `translationVars` 不合法时注册同样失败。注册表只保存 key 和参数，名称在查询时按 locale 翻译，不因注册时的语言而固化。`translationVars` 可以包含嵌套消息描述，例如生成的斜坡方块用 `{ block = { key = <原方块 key> } }`。

名称查询都接受可选的 `locale`（默认本领域当前语言），并把它传给所有下层查询：

| 函数 | 说明 |
| --- | --- |
| `MC.API.Blocks.DisplayName( id, locale )`、`DisplayNameForState( stateId, locale )` | 方块名称；`locale` 不是字符串时返回 `nil, "invalid_locale"`。 |
| `MC.API.Blocks.TranslationKey( id )` | 方块名称的 key 和参数副本。 |
| `MC.API.Items.DisplayName( id, locale )`、`TranslationKey( id )` | 物品名称及其 key（由 `mc_game` 提供）。 |
| `MC.BlockDisplayName`、`MC.ItemDisplayName`、`MC.PotionContents.DisplayName`、`MCITEM.EnchantmentLevelName`、`MCITEM.EnchantedBookDisplayName` | 引擎和游戏层内部使用，同样接受 `locale`。 |
| `MC.InventoryUI.ItemRenderer.DisplayName( stack, locale )` | 物品栏显示名：玩家自定义名称和 GMod 武器标题原样显示，其余按 `locale` 翻译。 |

物品栏和创造模式搜索同时匹配当前语言、`en_us` 的名称以及物品 id。

物品栏错误在收到响应时保存 key 与错误代码；常见错误有独立译文，未知代码使用 `inventory.error.action_failed`，将代码作为原文参数保留。语言切换刷新已有错误和配方书搜索结果，不清空搜索输入。MCITEM 武器、实体及生成菜单分类通过 GMod 短语绑定显示；药水武器名称与效果摘要动态生成，武器说明在语言变化时更新并清除旧的 `InfoMarkup`。

GMod 生成菜单采用 Sandbox 自身的刷新约定：菜单关闭且没有未保存的生成列表修改时重建，否则标记为稍后刷新。不会为了立即替换分类名称丢弃玩家正在编辑的生成列表。

## 7. 配置菜单元数据

`mc/sh_config_ui.lua` 的分组、分类和配置项，以及外部 addon 通过 `MC.API.Config.RegisterGroup`、`RegisterCategory` 加入的条目，只包含 id 和功能字段，所有文字都按第 6 节的 key 查询。`MC.ConfigText` 给出推导规则：`GroupKey`、`CategoryKey`、`CategoryDescriptionKey`、`ItemKey`、`ItemHelpKey`、`ChoiceKey`、`UnitKey`，以及列出某个条目全部 key 的 `Keys( kind, entry )`。

- `helpKey = false` 或 `descriptionKey = false` 表示该条目没有说明。
- `labelVars`、`helpVars`、`descriptionVars` 为模板参数，可以包含嵌套消息描述。
- 选项带 `text` 时原样显示该文字，不查词典；用于语言自称和玩家自己命名的光影预设。
- `choices` 可以是函数，打开菜单时求值。服务端条目可提供 `serverChoices`，选项随服务端配置值一起发送给客户端（`mc_config_values`）。
- 引擎提供通用单位：`blocks`、`bytes`、`cells`、`chunks`、`chunks_per_frame`、`deg`、`kg`、`ms`、`px`、`s`、`scale`、`texels`、`u`。使用其他单位的 addon 自己提供 `config.unit.<单位>`。

`RegisterGroup`、`RegisterCategory` 拒绝内联文字字段（`label`、`zhLabel`、`labelZH`、`description`、`descriptionZH`、`help`、`helpZH`，包括选项中的 `label`），返回 `inline_text_unsupported`；推导或给出的 key 不合法时返回 `invalid_text_key`。缺少译文不会拒绝注册，显示时按第 4 节回退。

界面语言 `mc_language` 的选项是 `auto` 加客户端已加载的 locale；服务端设置中的 `mc_console_language` 的选项是 `auto` 加服务端已加载的 locale，修改沿用服务端配置的管理员权限。服务端仍只传语言标识，客户端用自己的元数据显示自称；客户端没有相应名称时显示标识，不同步词典或名称元数据。两种设置的自动选项都按客户端界面语言显示，但服务器的自动模式明确标注为英语。

设置搜索同时匹配当前语言和 `en_us` 的文字以及 ConVar 名。

## 8. 光影描述文件

光影包和独立 shader 的描述文件（`data_static/mc/shaderpacks/*.json` 的 `definition`）只用 key 表示用户可见文字：

| 对象 | 字段 |
| --- | --- |
| 包或 shader | `nameKey`（必填）、`descriptionKey`（可选） |
| 设置分组 | `labelKey`（必填）、`descriptionKey`（可选） |
| 设置项 | `labelKey`（必填）、`helpKey`（可选） |
| 枚举选项 | `labelKey`（可选；省略时显示选项值） |
| 内置预设 | `labelKey`（必填）、`descriptionKey`（可选） |

key 是完整的最终 key，不继承描述文件所在目录。`MC.RenderPackSchema` 只校验 key 的形状，拒绝 `name`、`label`、`labelZH`、`help`、`helpZH` 等旧字段；缺少译文不影响加载一个功能有效的光影。设置 id、选项值、预设 id、程序名和 hash 是功能数据，不翻译。玩家保存的预设名称是玩家文本，原样显示。

`MC.RenderPackRegistry.List` 返回 `nameKey`、`descriptionKey`。语言切换和词典重新加载只重建设置界面的文字，不编译 shader、不重建 GPU 资源，也不改写设置值。

仓库内描述文件由 `tools/shader_compiler/` 的构建入口发布：显示 key 登记在 `descriptor_display.json`，PBR 的设置与预设在 `shadersrc/l2/pbr_assets/settings.json`。译文不是构建输入；只改显示 key 或设置时可以不编译直接重新发布，见该目录的 README。

## 9. Minecraft 原版译文

Minecraft 自带的译文由工具复制到内容所属 addon 的词典，不手工抄写：

```text
python tools/localization/generate_minecraft_lang.py --lang-dir <assets/minecraft/lang 目录> [--check]
```

工具读取目录中除 `deprecated.json` 以外的每个 `<locale>.json`，只保留 `en_us.json` 也有的 key，按 `OWNERS` 表的前缀把 key 分给所属 addon，写出 `addons/<addon>/data_static/mc/i18n/<addon>.minecraft.<locale>.json`。key 保持 Minecraft 原样（例如 `itemGroup.buildingBlocks`）。Java 格式符转换为本框架的参数：`%s` 依次变为 `{1}`、`{2}`…，`%2$s` 变为 `{2}`，`%%` 变为 `%`；其他 `%` 序列使工具报错退出。`--check` 不写文件，生成结果与仓库内容不一致、或有不再生成的旧文件时返回 1。

| addon | 拥有的 Minecraft key |
| --- | --- |
| `mc_engine` | `block.minecraft.*` |
| `mc_game` | `item.minecraft.*`、`itemGroup.*`、`container.*`、`merchant.*`、`entity.minecraft.villager*`、`entity.minecraft.wandering_trader`、`book.pageIndicator`、`item.durability`、`item.components` |
| `mc_item` | `effect.minecraft.*`、`effect.duration.infinite`、`effect.none`、`enchantment.minecraft.*`、`enchantment.level.*`、`potion.withAmplifier`、`potion.withDuration` |

当前来源为 Minecraft 26.2-pre-4 的语言文件。

原版物品注册表和创造分类由另一个工具从同一个解压后的 Minecraft 客户端生成，输出中每个物品只带翻译 key（先找 `item.minecraft.<id>`，再找 `block.minecraft.<id>`），不写入任何译文：

```text
powershell -File tools/content/generate_items.ps1 -MinecraftRoot <解压目录> [-SkipMaterials]
```

它写出 `addons/mc_game/lua/mcgame/generated/sh_generated_items.lua` 和 `sh_generated_creative_tabs.lua`；不带 `-SkipMaterials` 时还会把物品与容器贴图复制到 `addons/mc_game/materials/mc/`。

## 10. 控制台命令

| 命令 | 领域 | 作用 |
| --- | --- | --- |
| `mc_lang [locale\|auto]` | 客户端 | 不带参数时列出当前设置和可选值；带参数时设置界面语言，支持补全。 |
| `mc_i18n_reload` | 客户端 | 重新加载本机可见的词典。 |
| `mc_i18n_report` | 客户端 | 列出已加载片段、资源错误、重复 key 和别名冲突。 |
| `mc_i18n_missing` | 客户端 | 列出自上次加载以来的缺词。 |
| `mc_i18n_reload_sv`、`mc_i18n_report_sv`、`mc_i18n_missing_sv` | 服务端 | 同上，作用于服务端词典；仅服务器控制台或超级管理员。 |
| `mc_i18n_debug 0\|1` | 客户端 convar | 每个缺词首次出现时打印一行。 |

## 11. 翻译维护与检查

翻译维护只需 Python 标准库，不需要 LuaJIT：

```text
python tools/localization/check_catalogs.py --report <输出目录>/i18n-report.json
python tools/localization/check_catalogs.py --overrides <个人覆盖目录> --report <输出目录>/i18n-with-overrides.json
```

工具按虚拟路径排序读取全部 addon 片段，再读取可选的个人覆盖目录。检查 JSON 重复成员、目录及 key 格式、语言自称、常用资源上限、中英文等各语言相对 `en_us` 的缺词、`{name}` 占位符集合和覆盖率；报告保留文件顺序、每个冲突的先前来源与最终来源，以及别名冲突、`nativeNames` 和 `nativeNameConflicts`。相同虚拟路径被多个 addon 使用时直接报错。格式错误、缺词或占位符不一致返回非零退出码；合法的 key 或语言名称覆盖仅报告，不作为失败。

添加或修改译文时：

1. 在内容所属 addon 中维护 `en_us` 基准及相应 locale，文件名使用 addon 前缀以避免虚拟路径遮蔽。
2. 保持 key、占位符名称和参数含义稳定。只翻译句子，不翻译内容 id、错误代码或玩家命名。
3. 执行上述资源检查，再在游戏中执行 `mc_i18n_reload`，检查实际修改的一个界面或消息；查看 `mc_i18n_missing`，确认没有新缺词。
4. 发布时确认 GMA 包含新增片段。修改服务端控制台资源后还需重载服务端词典。

该工具是资源检查，不执行 Lua，也不代替游戏加载器完整的边界校验。原版词典由第 9 节的生成器维护；新增人工译文不要写进会被生成器覆盖的文件。缺词导出和自动合并工具尚未提供，人工合并时依据 JSON 报告定位缺词，保留已有人工译文。

### 11.1 运行时测试

测试在 LuaJIT（lupa）中运行真实的引擎 Lua，用 `--deps` 或环境变量 `MINEMOD_TEST_DEPS` 指定包含 lupa 的目录：

```text
python tools/localization/tests/test_i18n_loader.py --deps <目录>
python tools/localization/tests/test_i18n_content.py --deps <目录>
```

- `test_i18n_loader.py`：用临时目录模拟多个 addon 的 `GAME` 挂载和 `DATA` 覆盖目录，文件枚举顺序被反转或打乱，覆盖第 1 至 4 节的加载、合并、语言选择和查询规则；并加载仓库内全部 addon 的真实片段，要求没有资源错误、重复 key 和别名冲突，且 `en_us` 与 `zh_cn` 的 key 集合一致（只有 `.other` 的计数变体除外）。
- `test_i18n_content.py`：加载 `sh_config_ui.lua` 与公开 API，检查创造分类和配置注册拒绝内联文字；引擎、MCITEM 和物品栏界面的全部配置 key、全部创造分类标题和光影描述文件的显示 key 在两种语言中都有译文；描述文件通过真实 schema 校验且不含旧显示字段。名称部分检查 `ContentKey` 的模板、生成的物品表不含名称且每个物品 key 都有译文、药水/效果/附魔名称的覆盖、代码中以字面量写出的 key（`MC.T`、`MC.I18n.Resolve`、容器标题和材质包、F3 面板）都有译文，以及显式 `locale` 能穿过药水名称查询而不受界面语言影响。

生成结果可用 `generate_minecraft_lang.py --check` 检查是否与仓库一致。
