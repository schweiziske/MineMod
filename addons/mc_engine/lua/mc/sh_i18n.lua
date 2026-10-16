--[[----------------------------------------------------------------------------
	MC : shared localization helpers.
------------------------------------------------------------------------------]]

MC = MC or {}

local DEFAULT_LANGUAGE = "zh_cn"
local DEFAULT_LANGUAGE_SETTING = "auto"
local SUPPORTED_LANGUAGES = { zh_cn = true, en_us = true }
local LANGUAGE_OPTION_ORDER = { "auto", "zh_cn", "en_us" }
local LANGUAGE_OPTION_LABELS = {
	auto = "auto (game language)",
	zh_cn = "zh_cn (Chinese)",
	en_us = "en_us (English)",
}
local LANGUAGE_ALIASES = {
	zh = "zh_cn",
	cn = "zh_cn",
	zh_cn = "zh_cn",
	["zh-cn"] = "zh_cn",
	["zh_hans"] = "zh_cn",
	["zh-hans"] = "zh_cn",
	en = "en_us",
	us = "en_us",
	en_us = "en_us",
	["en-us"] = "en_us",
	english = "en_us",
	chinese = "zh_cn",
	schinese = "zh_cn",
	["simplified_chinese"] = "zh_cn",
}

local function trim( value )
	value = tostring( value or "" )
	if string.Trim then return string.Trim( value ) end
	return string.match( value, "^%s*(.-)%s*$" )
end

local function canonicalLanguageValue( value )
	value = string.lower( trim( value ) )
	return string.gsub( value, "-", "_" )
end

local function normalizeLanguage( value )
	value = canonicalLanguageValue( value )
	return LANGUAGE_ALIASES[value] or ( SUPPORTED_LANGUAGES[value] and value ) or DEFAULT_LANGUAGE
end

local function parseLanguageSetting( value )
	value = canonicalLanguageValue( value )
	if value == "" or value == "auto" or value == "default" or value == "game" or value == "gmod_language" then
		return DEFAULT_LANGUAGE_SETTING, true
	end
	local lang = LANGUAGE_ALIASES[value] or ( SUPPORTED_LANGUAGES[value] and value )
	if lang then return lang, true end
	return DEFAULT_LANGUAGE_SETTING, false
end

local function normalizeLanguageSetting( value )
	local setting = parseLanguageSetting( value )
	return setting
end

local function clientGameLanguage()
	if CLIENT and GetConVar then
		local cvar = GetConVar( "gmod_language" )
		if cvar and cvar.GetString then
			return cvar:GetString()
		end
	end
	return DEFAULT_LANGUAGE
end

local function resolveLanguage( setting, gameLanguage )
	setting = normalizeLanguageSetting( setting )
	if setting == DEFAULT_LANGUAGE_SETTING then
		return normalizeLanguage( gameLanguage or clientGameLanguage() )
	end
	return setting
end

MC.NormalizeLanguage = normalizeLanguage
function MC.ResolveLanguage( setting, gameLanguage )
	return resolveLanguage( setting, gameLanguage )
end
MC.LanguageCallbacks = MC.LanguageCallbacks or {}

MC.LanguageData = MC.LanguageData or {
	zh_cn = {
		["language.zh_cn"] = "中文",
		["language.en_us"] = "English",
		["native.dll_missing"] = "未检测到优化DLL，当前使用 Lua 后端。 下载地址：",
		["native.dll_outdated"] = "Native DLL 版本过期（当前 ABI {actual}，需要 ABI {required}），当前使用 Lua 后端。下载地址：",
		["native.dll_open_hint"] = "(推荐下载)",
		["native.dll_console"] = "Native DLL 下载地址: {url}",
		["native.dll_outdated_console"] = "Native DLL 版本过期（当前 ABI {actual}，需要 ABI {required}）。下载地址: {url}",
		["native.dll_command_help"] = "打开 MCSWEP Native DLL 的 GitHub 页面",
		["join.config_hint"] = "控制台输入 mc_config 打开配置界面，输入 mc_save_manager 打开存档管理器。",
		["join.config_hide_hint"] = "输入 mc_join_notice 0 关闭进服提示。",

		["tool.name"] = "MC 方块",
		["tool.desc"] = "放置 / 破坏 Minecraft 方块（IMesh 渲染，不生成实体）",
		["tool.usage"] = "左键破坏   右键放置   Reload 复制方块",
		["tool.help"] = "左键破坏 / 右键放置 / Reload 复制方块。/fill 支持 blockstate，例如 minecraft:furnace[facing=north]。",

		["weapon.mc_placer.name"] = "MC 方块放置器",
		["weapon.mc_placer.purpose"] = "放置 / 破坏 Minecraft 方块（IMesh 渲染，不生成实体）",
		["weapon.mc_placer.instructions"] = "左键破坏  右键放置  Reload 选择方块",
		["weapon.mc_placer.hud"] = "左键破坏   右键放置   Reload 选择方块",

		["weapon.mc_creative_placer.name"] = "MC DEBUG TOOL",
		["weapon.mc_creative_placer.purpose"] = "放置 / 破坏 Minecraft 方块，并从创造物品栏选择方块",
		["weapon.mc_creative_placer.instructions"] = "左键破坏  右键放置  Reload 创造物品栏",
		["weapon.mc_creative_placer.hud"] = "左键破坏    右键放置    中键取块(自动)    Shift+中键取数据    Reload 创造栏    Tab 切出",

		["weapon.mc_preset_placer.name"] = "MC 预设放置器",
		["weapon.mc_preset_placer.purpose"] = "保存和放置 Minecraft 方块建筑预设",
		["weapon.mc_preset_placer.instructions"] = "R 打开预设界面  左键选择/放置  右键撤销  G 旋转",
		["weapon.mc_preset_placer.help"] = "预设放置器：按 R 打开界面。新建预设用左键选四步；读取预设后左键放置。",
		["weapon.mc_preset_placer.title"] = "MC 预设放置器",
		["weapon.mc_preset_placer.overwrite_on"] = "覆盖: 开",
		["weapon.mc_preset_placer.overwrite_off"] = "覆盖: 关",
		["weapon.mc_preset_placer.rotation"] = "旋转: {degrees} deg",
		["weapon.mc_preset_placer.place_hint"] = "左键放置投影   右键取消   E 覆盖   G 旋转   R 预设",
		["weapon.mc_preset_placer.step0"] = "左键选择第一个方块   右键取消",
		["weapon.mc_preset_placer.step1"] = "左键选择第二个方块完成范围   右键撤销",
		["weapon.mc_preset_placer.step2"] = "左键选择基准面   右键撤销",
		["weapon.mc_preset_placer.step3"] = "左键截图并保存   右键撤销",
		["weapon.mc_preset_placer.saving"] = "正在保存预设...",
		["weapon.mc_preset_placer.open"] = "R 打开预设界面",

		["weapon.mc_cluster_tool.name"] = "MC 结构搬运器",
		["weapon.mc_cluster_tool.purpose"] = "把选中的 Minecraft 方块变成可搬运的物理实体",
		["weapon.mc_cluster_tool.instructions"] = "左键 选择  右键 取消  R 切换模式  E 连通选择  G 转换/放回  X 清空",
		["weapon.mc_cluster_tool.help"] = "结构搬运器：左键选方块 (R 切换框选)，E 连通选择，G 把选区变成实体；对准实体按 G 放回网格。",
		["weapon.mc_cluster_tool.aim_paste_hint"] = "对准结构时按 G 放回网格",
		["weapon.mc_cluster_tool.aim_block"] = "请准星对准一个 MC 方块",
		["weapon.mc_cluster_tool.corner_cancel"] = "已取消角点",
		["weapon.mc_cluster_tool.mode_box"] = "已切换到框选模式",
		["weapon.mc_cluster_tool.mode_fine"] = "已切换到细选模式",
		["weapon.mc_cluster_tool.mode_crate"] = "已切换到箱体模式 (碰撞为整箱, 适合大结构)",
		["weapon.mc_cluster_tool.mode_box_label"] = "模式: 框选",
		["weapon.mc_cluster_tool.mode_fine_label"] = "模式: 细选",
		["weapon.mc_cluster_tool.mode_crate_label"] = "模式: 箱体 (整箱碰撞)",
		["weapon.mc_cluster_tool.hint_crate_a"] = "左键 选择第一个角点   G 转换(整箱碰撞)   R 细选   X 清空",
		["weapon.mc_cluster_tool.hint_crate_b"] = "左键 选择对角完成框选   右键 取消角点   G 转换(整箱碰撞)   X 清空",
		["weapon.mc_cluster_tool.crate_no_flood"] = "箱体模式只支持框选",
		["weapon.mc_cluster_tool.ui_tab_fine"] = "细选",
		["weapon.mc_cluster_tool.ui_tab_box"] = "框选",
		["weapon.mc_cluster_tool.ui_tab_crate"] = "箱体",
		["weapon.mc_cluster_tool.ui_cycle"] = "切换模式",
		["weapon.mc_cluster_tool.ui_structure"] = "方块结构",
		["weapon.mc_cluster_tool.ui_blocks"] = "{n} 方块",
		["weapon.mc_cluster_tool.ui_durability"] = "耐久",
		["weapon.mc_cluster_tool.ui_paste"] = "放回网格",
		["weapon.mc_cluster_tool.ui_paste_ok"] = "可放回",
		["weapon.mc_cluster_tool.ui_paste_blocked"] = "有 {n} 格被占用",
		["weapon.mc_cluster_tool.ui_paste_tilted"] = "先用物理枪放平",
		["weapon.mc_cluster_tool.ui_add"] = "加选",
		["weapon.mc_cluster_tool.ui_remove"] = "减选",
		["weapon.mc_cluster_tool.ui_flood"] = "连通选择",
		["weapon.mc_cluster_tool.ui_convert"] = "转换",
		["weapon.mc_cluster_tool.ui_convert_crate"] = "转换(整箱)",
		["weapon.mc_cluster_tool.ui_clear"] = "清空",
		["weapon.mc_cluster_tool.ui_corner_a"] = "选第一角点",
		["weapon.mc_cluster_tool.ui_corner_b"] = "选对角",
		["weapon.mc_cluster_tool.ui_corner_cancel"] = "取消角点",
		["weapon.mc_cluster_tool.ui_key_lmb"] = "左键",
		["weapon.mc_cluster_tool.ui_key_rmb"] = "右键",
		["weapon.mc_cluster_tool.count"] = "已选 {n}/{max}",
		["weapon.mc_cluster_tool.hint_tilted"] = "结构 ({n} 方块) 倾斜太大, 用物理枪放平后才能放回",
		["weapon.mc_cluster_tool.hint_blocked"] = "结构 ({n} 方块): 目标位置有 {b} 格被占用",
		["weapon.mc_cluster_tool.hint_paste"] = "结构 ({n} 方块): 按 G 放回网格",
		["weapon.mc_cluster_tool.durability"] = "耐久 {hp}/{max}",
		["weapon.mc_cluster_tool.durability_inf"] = "耐久 无敌",
		["weapon.mc_cluster_tool.owner"] = "主人 {name}",
		["weapon.mc_cluster_tool.hint_corner_b"] = "左键 选择对角完成框选   右键 取消角点   G 转换   X 清空",
		["weapon.mc_cluster_tool.hint_corner_a"] = "左键 选择第一个角点   E 连通选择   G 转换   R 细选   X 清空",
		["weapon.mc_cluster_tool.hint_fine"] = "左键 加选   右键 减选   E 连通选择   G 转换   R 框选   X 清空",

		["cluster.cleared"] = "已清空选区",
		["cluster.add_failed"] = "无法加选",
		["cluster.add_failed_count"] = "选区已达方块数上限",
		["cluster.add_failed_extent"] = "选区尺寸超过上限",
		["cluster.add_failed_air"] = "那里没有方块",
		["cluster.flood_air"] = "请准星对准一个方块再连通选择",
		["cluster.flood_limited"] = "连通选择到达上限, 已选 {n} 个方块",
		["cluster.flood_done"] = "连通选择 +{n} (共 {total})",
		["cluster.corner_a"] = "已选第一个角点, 再选对角完成框选",
		["cluster.box_extent"] = "框选尺寸超过上限 ({max} 格)",
		["cluster.box_volume"] = "框选体积太大",
		["cluster.box_limited"] = "框选到达上限, 已选 {n} 个方块",
		["cluster.box_done"] = "框选 +{n} (共 {total})",
		["cluster.nothing_selected"] = "先选择一些方块 (左键加选 / E 连通选择 / 框选)",
		["cluster.admin_only"] = "只有管理员可以使用结构搬运器 (mc_cluster_public 0)",
		["cluster.too_many"] = "选区超过上限 ({max} 方块, mc_cluster_max_blocks)",
		["cluster.per_player_limit"] = "你的结构实体已达上限 ({max} 个, mc_cluster_max_per_player)",
		["cluster.too_large"] = "选区尺寸超过上限 ({max} 格, mc_cluster_max_extent)",
		["cluster.too_far"] = "选区离你太远",
		["cluster.not_loaded"] = "选区内有区块未能加载，请稍后重试",
		["cluster.empty"] = "选区里没有方块",
		["cluster.too_complex"] = "结构太复杂: {n}/{max} 个碰撞凸包",
		["cluster.no_collision"] = "选区里没有可碰撞的方块",
		["cluster.phys_failed"] = "碰撞构建失败: {err}",
		["cluster.spawn_failed"] = "生成结构实体失败: {err}",
		["cluster.remove_failed"] = "移除方块失败，转换已取消",
		["cluster.converted"] = "已转换 {n} 个方块为结构实体 (初始为冻结状态, 物理枪解冻后可搬运, 对准后按 G 放回网格)",
		["cluster.converted_crate"] = "已转换 {n} 个方块为箱体结构 (整箱碰撞, 物理枪解冻可搬运, 对准按 G 放回网格)",
		["cluster.paste_occupied_n"] = "目标位置有 {n} 格被方块占用",
		["cluster.paste_err_occupied"] = "目标位置被方块占用",
		["cluster.paste_err_bounds"] = "超出建造范围",
		["cluster.paste_err_limit"] = "会超过全局方块上限 (mc_max_blocks)",
		["cluster.paste_err_record"] = "结构数据缺失",
		["cluster.undo_text"] = "撤销 MC 方块结构 (放回原位)",
		["cluster.undo_restored"] = "已把结构放回原位",
		["cluster.undo_failed"] = "撤销失败: {err}",
		["cluster.pasted"] = "已把 {n} 个方块放回网格",
		["cluster.paste_failed"] = "放回失败: {err}",
		["cluster.tilted"] = "结构倾斜太大, 先用物理枪放平再放回",
		["cluster.ghosted"] = "结构嵌在方块里: 已暂时不与方块碰撞, 拖出来后自动恢复",
		["cluster.use_info"] = "方块结构: {n} 方块  耐久 {hp}",
		["cluster.use_invincible"] = "无敌",
		["cluster.use_owner"] = "  主人 {name}",
		["cluster.use_frozen"] = "  [已冻结]",

		["creative.category.all"] = "全部",
		["creative.category.color_blocks"] = "色块",
		["creative.category.slopes"] = "斜坡",
		["creative.category.custom"] = "自定义",
		["creative.category.building"] = "建筑方块",
		["creative.category.natural"] = "自然方块",
		["creative.category.functional"] = "功能方块",
		["creative.category.redstone"] = "红石",
		["creative.category.decoration"] = "装饰",
		["creative.category.transparent"] = "透明/玻璃",
		["creative.category.plants"] = "植物",
		["creative.title"] = "创造物品栏",
		["creative.search"] = "搜索中文名 / 英文名 / minecraft:id",
		["creative.page"] = "{page} / {pages}    {count} 个方块",
		["creative.state.title"] = "方块状态",
		["creative.state.auto"] = "自动放置",
		["creative.state.selected"] = "已选中",
		["creative.state.explicit_default"] = "显式默认状态",
		["creative.state.approx_preview"] = "预览使用兼容模型，状态数据仍完整",
		["palette.title"] = "选择方块",
		["sync.progress"] = "MC 同步 {received}/{expected} 方块  {done}/{chunks} 区块",
		["sync.progress_bytes"] = "MC 同步 {received}/{expected} KB  {done}/{chunks} 分片",
		["sync.complete"] = "MC 同步完成  {label}",
		["sync.workshop_progress"] = "本地读取创意工坊世界 {received}/{expected} 方块  {done}/{chunks} 区块",
		["sync.workshop_complete"] = "创意工坊基础世界已从本地读取完成",

		["save.no_cover"] = "暂无截图",
		["save.auto_cover"] = "保存一次会自动截图",
		["save.enter_name"] = "请输入存档名",
		["save.uploading"] = "正在上传截图和保存存档...",
		["save.upload_busy"] = "截图正在上传，请稍候",
		["save.upload_failed"] = "截图上传失败，未执行保存: {err}",
		["save.admin_only"] = "默认只有管理员可以保存和读取存档",
		["save.map_prefix"] = "地图: {map}",
		["save.title"] = "MC 存档管理",
		["save.current_map"] = "当前地图: {map}",
		["save.new_name"] = "新存档名",
		["save.save_current"] = "保存当前",
		["save.refresh"] = "刷新",
		["save.loading"] = "读取中...",
		["save.list_title"] = "选择地图 / 存档",
		["save.info_title"] = "地图信息",
		["save.select_hint"] = "左侧选择一个存档。",
		["save.field_save"] = "存档",
		["save.field_map"] = "地图",
		["save.field_saved"] = "保存",
		["save.field_size"] = "规模",
		["save.field_cover"] = "截图",
		["save.none"] = "无",
		["save.load"] = "读取",
		["save.select_first"] = "先选择一个存档",
		["save.load_confirm_body"] = "读取存档会替换当前 MC 方块世界，并重新同步所有客户端。",
		["save.load_confirm_title"] = "读取存档: {name}",
		["save.cancel"] = "取消",
		["save.overwrite"] = "覆盖并截图",
		["save.overwrite_confirm_body"] = "用当前世界覆盖这个命名存档，并刷新截图？",
		["save.overwrite_confirm_title"] = "覆盖存档: {name}",
		["save.delete"] = "删除",
		["save.delete_confirm_body"] = "删除后不会自动恢复。",
		["save.delete_confirm_title"] = "删除存档: {name}",
		["save.mounted_read_only"] = "挂载的创意工坊存档只能读取",
		["save.empty"] = "还没有命名存档。输入名字后点“保存当前”。",
		["save.count"] = "{count} 个存档",
		["workshop.import"] = "读取创意工坊",
		["workshop.import_hint"] = "输入 Workshop ID 或 Steam 创意工坊链接；服务端批准后才会接收并读取世界包。",
		["workshop.permission_hint"] = "当前 mc_workshop_manage 不允许你管理创意工坊世界。",
		["workshop.publish"] = "发布到创意工坊",
		["workshop.publish_hint"] = "服务端导出存档后，客户端截图并打开 GMod 发布窗口。",
		["workshop.publish_confirm_body"] = "客户端将向服务端请求这个存档，隐藏界面拍摄封面，然后打开 Garry's Mod 创意工坊发布窗口。是否继续？",
		["workshop.publish_confirm_title"] = "发布到创意工坊: {name}",
		["workshop.view"] = "查看创意工坊",
		["workshop.field_source"] = "来源",
		["workshop.field_id"] = "Workshop ID",
		["workshop.source_local"] = "本地存档",
		["workshop.source_published"] = "本地存档（已发布）",
		["workshop.source_imported"] = "创意工坊导入",
		["workshop.source_mounted"] = "创意工坊挂载（只读）",
		["workshop.source_mounted_badge"] = "已挂载",
		["workshop.filter_source"] = "来源",
		["workshop.filter_local"] = "本地存档",
		["workshop.filter_workshop"] = "创意工坊",
		["workshop.exporting"] = "服务端正在导出存档...",
		["workshop.capturing"] = "正在隐藏界面并拍摄创意工坊封面...",
		["workshop.publisher_open"] = "正在打开 Garry's Mod 创意工坊发布窗口...",
		["workshop.binding"] = "正在把创意工坊 ID 写回服务端存档...",
		["workshop.publish_done"] = "已发布并关联 Workshop ID {id}",
		["workshop.publish_bound"] = "已关联创意工坊 ID: {id}",
		["workshop.bind_title"] = "关联创意工坊 ID",
		["workshop.bind_prompt"] = "发布窗口没有把 ID 直接返回游戏。请输入刚发布或更新的 Workshop ID，或粘贴其 Steam 创意工坊链接。",
		["workshop.bind_cancelled"] = "发布文件已交给 Steam，但没有关联 Workshop ID",
		["workshop.bind"] = "关联",
		["workshop.import_title"] = "读取创意工坊世界",
		["workshop.import_prompt"] = "输入 Workshop ID 或 Steam 创意工坊链接。支持完整 filedetails 链接、末尾带 / 的链接和纯数字 ID。客户端会先下载并校验，服务端批准后才接收和读取。",
		["workshop.import_dedicated_title"] = "专用服务器传输: {id}",
		["workshop.import_dedicated_body"] = "当前连接的是专用服务器。完整 GMA 将由你的客户端从 Steam 下载并校验，再通过游戏网络上传给服务器。大世界可能消耗较多上行流量，并需要数分钟。是否继续？",
		["workshop.import_dedicated_continue"] = "继续传输",
		["workshop.downloading"] = "正在从创意工坊下载 {id}...",
		["workshop.awaiting_approval"] = "世界包已校验，正在等待服务端批准读取...",
		["workshop.uploading"] = "服务端已批准，正在上传并再次校验世界包...",
		["workshop.reading_shared"] = "服务端已批准，正在通过 Listen Server 共享目录读取并再次校验世界包...",
		["workshop.import_done"] = "已从创意工坊读取: {name}",
		["workshop.error_permission"] = "服务端未批准该创意工坊操作",
		["workshop.error_rate"] = "请求太快，请稍后再试",
		["workshop.error_busy"] = "已有创意工坊传输正在进行",
		["workshop.error_slot"] = "存档名称无效",
		["workshop.error_legacy"] = "旧版存档暂不能发布，请先重新覆盖保存一次",
		["workshop.error_id"] = "创意工坊 ID 或链接无效",
		["workshop.error_request"] = "创意工坊读取请求无效",
		["workshop.error_not_world"] = "该物品不是 MC 世界存档",
		["workshop.error_version"] = "该 MC 世界存档版本不受支持",
		["workshop.error_corrupt"] = "创意工坊世界包校验失败",
		["workshop.error_capture_empty"] = "无法从当前游戏画面拍摄创意工坊封面，请返回游戏画面后重试",
		["workshop.error_capture_too_large"] = "拍摄到的创意工坊封面超过大小限制",
		["workshop.error_capture_write"] = "无法把创意工坊封面写入客户端数据目录",
		["workshop.error_capture_timeout"] = "等待游戏画面截图超时",
		["workshop.error_capture_size"] = "当前游戏画面尺寸太小，无法生成创意工坊封面",
		["workshop.error_file_unreadable"] = "无法读取 Steam 下载的创意工坊世界文件",
		["workshop.error_file_too_large"] = "创意工坊世界文件超过服务器允许的大小",
		["workshop.error_shared_write"] = "无法写入 Listen Server 共享世界文件",
		["workshop.error_shared_read"] = "Listen Server 无法读取共享世界文件",
		["workshop.error_shared_unavailable"] = "当前客户端不能使用 Listen Server 共享读取",
		["workshop.error_cache_write"] = "无法缓存创意工坊基础世界",
		["workshop.error_timeout"] = "创意工坊操作超时",
		["workshop.error_load"] = "服务端无法读取该世界",
		["workshop.error_generic"] = "创意工坊操作失败: {err}",
		["library.save_subtitle"] = "整理、筛选并回到你的方块世界",
		["library.preset_subtitle"] = "收藏并整理可以再次搭建的作品",
		["library.filter"] = "筛选",
		["library.maps"] = "保存地图",
		["library.all"] = "全部",
		["library.current_map"] = "当前地图",
		["library.groups"] = "自定义分组",
		["library.all_groups"] = "全部分组",
		["library.group_none"] = "未分组",
		["library.group"] = "分组",
		["library.new"] = "+ 新建",
		["library.new_group"] = "新建分组",
		["library.rename_group"] = "重命名分组",
		["library.delete_group"] = "删除分组",
		["library.delete_group_hint"] = "分组会被删除，里面的条目会变成未分组。",
		["library.group_name"] = "输入分组名称",
		["library.group_exists"] = "分组名称不能为空或已存在",
		["library.group_manage_hint"] = "右键可重命名或删除分组",
		["library.move_to_group"] = "整理到",
		["library.search"] = "搜索名称或地图",
		["library.no_results"] = "没有符合当前筛选的内容。",
		["library.showing"] = "显示 {visible} / {total}",

		["preset.no_cover"] = "暂无截图",
		["preset.auto_cover"] = "保存预设时自动截图",
		["preset.overwrite_on"] = "预设覆盖模式: 开。放置时会覆盖目标体积里的已有方块。",
		["preset.overwrite_off"] = "预设覆盖模式: 关。目标位置有方块时不会放置。",
		["preset.rotation_chat"] = "Preset rotation: {degrees} deg",
		["preset.loaded_chat"] = "已读取预设: {name}。移动准星看投影，G 旋转，左键放置，右键取消。",
		["preset.start_chat"] = "开始新建预设 {name}：左键选择第一个方块。",
		["preset.selection_incomplete"] = "预设选择还没完成。",
		["preset.saving_chat"] = "正在截图并保存预设: {name}",
		["preset.upload_failed_saved"] = "截图上传失败，预设仍已保存（无封面）: {err}",
		["preset.admin_only"] = "默认只有管理员可以保存和读取预设",
		["preset.aim_block"] = "请准星对准一个 MC 方块。",
		["preset.step1_chat"] = "已选择第一个方块。左键选择第二个方块完成范围，右键撤销。",
		["preset.step2_chat"] = "范围已完成。左键选择一个基准面，之后预设会用它对齐准星。",
		["preset.anchor_outside"] = "基准面必须在刚才选择的范围里。",
		["preset.step3_chat"] = "基准面已选择。再按一次左键截图并保存。",
		["preset.projection_cancelled"] = "已取消预设投影。",
		["preset.selection_cancelled"] = "已取消预设选择。",
		["preset.undo"] = "已撤销一步。",
		["preset.load_first"] = "先按 R 读取一个预设。",
		["preset.aim_place"] = "请准星对准可以放置预设的位置。",
		["preset.manager_title"] = "MC 预设放置器",
		["preset.header"] = "新建或读取建筑预设",
		["preset.new_name"] = "新预设名",
		["preset.create"] = "新建预设",
		["preset.refresh"] = "刷新",
		["preset.loading"] = "读取中...",
		["preset.list_title"] = "预设列表",
		["preset.info_title"] = "预设信息",
		["preset.select_hint"] = "左侧选择一个预设，或输入名字新建。",
		["preset.field_preset"] = "预设",
		["preset.field_map"] = "地图",
		["preset.field_size"] = "规模",
		["preset.field_created"] = "创建",
		["preset.load_projection"] = "读取投影",
		["preset.select_first"] = "先选择一个预设",
		["preset.loading_projection"] = "正在读取预设...",
		["preset.empty"] = "还没有预设。输入名字后点“新建预设”。",
		["preset.count"] = "{count} 个预设",
		["preset.load_failed"] = "预设读取失败: {message}",
		["preset.load_damaged"] = "预设读取失败: 数据损坏",

		["server.admin_build"] = "只有管理员可以建造 (mc_admin_only)",
		["server.world_limit"] = "超出建造范围 (mc_world_limit)",
		["server.max_blocks"] = "已达到方块上限 (mc_max_blocks)",
		["server.fill_usage"] = "用法: /fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]> [state]",
		["server.invalid_state"] = "方块状态不合法: {block}",
		["server.fill_too_large"] = "填充范围太大 ({volume} > mc_fill_max {max})",
		["server.fill_max_blocks"] = "会超过方块上限 (mc_max_blocks)",
		["server.filled"] = "已填充 {count} 个方块",
		["server.import_usage"] = "用法: mc_import <mc_import/文件.json> [replace|append]",
		["server.invalid_file"] = "文件格式不对",
		["server.import_missing"] = "找不到导入文件: garrysmod/data/{path}",
		["server.import_bad_json"] = "导入文件不是有效 JSON: {path}",
		["server.import_failed"] = "导入失败: {err}",
		["server.import_done"] = "导入完成: {blocks} 个方块，当前总数 {total}，跳过未知 {unknown}，越界 {bounds}，超上限 {max}",
		["server.import_count_mismatch"] = "导入文件写着 {expected} 个方块，实际进服 {imported} 个；少的都在上面跳过统计里。",
		["server.import_truncated"] = "导入被 mc_import_max={max} 截断了；完整区块请先执行 mc_import_max 0。",
		["server.rebuilt"] = "重建了 {count} 个区块的碰撞",
		["server.save_admin_list"] = "只有管理员可以读取/保存存档 (mc_save_public 0)",
		["server.save_admin_save"] = "只有管理员可以保存存档 (mc_save_public 0)",
		["server.save_admin_load"] = "只有管理员可以读取存档 (mc_save_public 0)",
		["server.save_admin_delete"] = "只有管理员可以删除存档",
		["server.action_done"] = "操作完成: {action}",
		["server.action_failed"] = "操作失败: {err}",
		["server.preset_admin"] = "只有管理员可以读取/保存/放置预设 (mc_preset_public 0)",
		["server.preset_edit_admin"] = "只有管理员可以保存/放置预设 (mc_admin_only)",
		["server.preset_admin_list"] = "只有管理员可以读取/保存预设 (mc_preset_public 0)",
		["server.preset_admin_load"] = "只有管理员可以读取预设 (mc_preset_public 0)",
		["server.preset_admin_save"] = "只有管理员可以保存预设 (mc_preset_public 0)",
		["server.preset_placed"] = "已放置预设: {name} ({changes} changes)",
		["server.preset_overwritten"] = "已覆盖预设: {name} ({changes} changes)",
		["server.preset_saved"] = "预设已保存: {name}",
		["server.preset_save_failed"] = "预设保存失败: {err}",
		["server.preset_place_failed"] = "预设放置失败: {err}",
	},

	en_us = {
		["language.zh_cn"] = "Chinese",
		["language.en_us"] = "English",
		["native.dll_missing"] = "Optional Native DLL was not detected; using the Lua backend. ",
		["native.dll_outdated"] = "Native DLL is outdated (installed ABI {actual}, required ABI {required}); using the Lua backend. Download: ",
		["native.dll_open_hint"] = " (recommended download)",
		["native.dll_console"] = "Native DLL download: {url}",
		["native.dll_outdated_console"] = "Native DLL is outdated (installed ABI {actual}, required ABI {required}). Download: {url}",
		["native.dll_command_help"] = "Open the MCSWEP Native DLL GitHub page",
		["join.config_hint"] = "Enter mc_config in the console to open settings, or mc_save_manager to open the save manager.",
		["join.config_hide_hint"] = "Enter mc_join_notice 0 to disable this join notice.",

		["tool.name"] = "MC Block",
		["tool.desc"] = "Place and break Minecraft blocks using IMesh chunks instead of entities",
		["tool.usage"] = "Left click breaks   Right click places   Reload copies a block",
		["tool.help"] = "Left click breaks, right click places, Reload copies a block. /fill supports blockstates, for example minecraft:furnace[facing=north].",

		["weapon.mc_placer.name"] = "MC Block Placer",
		["weapon.mc_placer.purpose"] = "Place and break Minecraft blocks using IMesh chunks instead of entities",
		["weapon.mc_placer.instructions"] = "Left click breaks  Right click places  Reload selects a block",
		["weapon.mc_placer.hud"] = "Left click breaks   Right click places   Reload selects a block",

		["weapon.mc_creative_placer.name"] = "MC DEBUG TOOL",
		["weapon.mc_creative_placer.purpose"] = "Place and break Minecraft blocks, with a creative inventory picker",
		["weapon.mc_creative_placer.instructions"] = "Left click breaks  Right click places  Reload opens creative inventory",
		["weapon.mc_creative_placer.hud"] = "Left breaks    Right places    Middle picks (auto)    Shift+Middle copies state    Reload opens inventory    Tab switches weapon",

		["weapon.mc_preset_placer.name"] = "MC Preset Placer",
		["weapon.mc_preset_placer.purpose"] = "Save and place Minecraft block build presets",
		["weapon.mc_preset_placer.instructions"] = "R opens presets  Left click selects/places  Right click undoes  G rotates",
		["weapon.mc_preset_placer.help"] = "Preset placer: press R to open the manager. Create presets with four left-click steps; after loading one, left click places it.",
		["weapon.mc_preset_placer.title"] = "MC Preset Placer",
		["weapon.mc_preset_placer.overwrite_on"] = "Overwrite: On",
		["weapon.mc_preset_placer.overwrite_off"] = "Overwrite: Off",
		["weapon.mc_preset_placer.rotation"] = "Rotation: {degrees} deg",
		["weapon.mc_preset_placer.place_hint"] = "Left click places projection   Right click cancels   E overwrite   G rotate   R presets",
		["weapon.mc_preset_placer.step0"] = "Left click selects first block   Right click cancels",
		["weapon.mc_preset_placer.step1"] = "Left click selects second block to finish range   Right click undoes",
		["weapon.mc_preset_placer.step2"] = "Left click selects anchor face   Right click undoes",
		["weapon.mc_preset_placer.step3"] = "Left click captures and saves   Right click undoes",
		["weapon.mc_preset_placer.saving"] = "Saving preset...",
		["weapon.mc_preset_placer.open"] = "R opens preset manager",

		["weapon.mc_cluster_tool.name"] = "MC Structure Grabber",
		["weapon.mc_cluster_tool.purpose"] = "Turn selected Minecraft blocks into a movable physics entity",
		["weapon.mc_cluster_tool.instructions"] = "Left selects  Right deselects  R toggles mode  E flood select  G convert/place back  X clear",
		["weapon.mc_cluster_tool.help"] = "Structure grabber: left click selects blocks (R toggles box select), E flood selects, G converts the selection into an entity; aim at an entity and press G to place it back onto the grid.",
		["weapon.mc_cluster_tool.aim_paste_hint"] = "Aim at a structure and press G to place it back onto the grid",
		["weapon.mc_cluster_tool.aim_block"] = "Aim at an MC block",
		["weapon.mc_cluster_tool.corner_cancel"] = "Corner cancelled",
		["weapon.mc_cluster_tool.mode_box"] = "Switched to box select mode",
		["weapon.mc_cluster_tool.mode_fine"] = "Switched to fine select mode",
		["weapon.mc_cluster_tool.mode_crate"] = "Switched to crate mode (single-box collision, for large structures)",
		["weapon.mc_cluster_tool.mode_box_label"] = "Mode: Box",
		["weapon.mc_cluster_tool.mode_fine_label"] = "Mode: Fine",
		["weapon.mc_cluster_tool.mode_crate_label"] = "Mode: Crate (box collision)",
		["weapon.mc_cluster_tool.hint_crate_a"] = "Left picks the first corner   G converts (box collision)   R fine mode   X clear",
		["weapon.mc_cluster_tool.hint_crate_b"] = "Left picks the opposite corner   Right cancels corner   G converts (box collision)   X clears",
		["weapon.mc_cluster_tool.crate_no_flood"] = "Crate mode only supports box selection",
		["weapon.mc_cluster_tool.ui_tab_fine"] = "Fine",
		["weapon.mc_cluster_tool.ui_tab_box"] = "Box",
		["weapon.mc_cluster_tool.ui_tab_crate"] = "Crate",
		["weapon.mc_cluster_tool.ui_cycle"] = "Switch mode",
		["weapon.mc_cluster_tool.ui_structure"] = "Block structure",
		["weapon.mc_cluster_tool.ui_blocks"] = "{n} blocks",
		["weapon.mc_cluster_tool.ui_durability"] = "Durability",
		["weapon.mc_cluster_tool.ui_paste"] = "Place back",
		["weapon.mc_cluster_tool.ui_paste_ok"] = "Ready to place",
		["weapon.mc_cluster_tool.ui_paste_blocked"] = "{n} cells occupied",
		["weapon.mc_cluster_tool.ui_paste_tilted"] = "Level it with the physgun first",
		["weapon.mc_cluster_tool.ui_add"] = "Add",
		["weapon.mc_cluster_tool.ui_remove"] = "Remove",
		["weapon.mc_cluster_tool.ui_flood"] = "Flood select",
		["weapon.mc_cluster_tool.ui_convert"] = "Convert",
		["weapon.mc_cluster_tool.ui_convert_crate"] = "Convert (crate)",
		["weapon.mc_cluster_tool.ui_clear"] = "Clear",
		["weapon.mc_cluster_tool.ui_corner_a"] = "Pick first corner",
		["weapon.mc_cluster_tool.ui_corner_b"] = "Pick opposite corner",
		["weapon.mc_cluster_tool.ui_corner_cancel"] = "Cancel corner",
		["weapon.mc_cluster_tool.ui_key_lmb"] = "LMB",
		["weapon.mc_cluster_tool.ui_key_rmb"] = "RMB",
		["weapon.mc_cluster_tool.count"] = "Selected {n}/{max}",
		["weapon.mc_cluster_tool.hint_tilted"] = "Structure ({n} blocks) is tilted too far; level it with the physgun before placing back",
		["weapon.mc_cluster_tool.hint_blocked"] = "Structure ({n} blocks): {b} target cells are occupied",
		["weapon.mc_cluster_tool.hint_paste"] = "Structure ({n} blocks): press G to place it back onto the grid",
		["weapon.mc_cluster_tool.durability"] = "Durability {hp}/{max}",
		["weapon.mc_cluster_tool.durability_inf"] = "Durability: invulnerable",
		["weapon.mc_cluster_tool.owner"] = "Owner {name}",
		["weapon.mc_cluster_tool.hint_corner_b"] = "Left picks the opposite corner   Right cancels corner   G converts   X clears",
		["weapon.mc_cluster_tool.hint_corner_a"] = "Left picks the first corner   E flood select   G convert   R fine mode   X clear",
		["weapon.mc_cluster_tool.hint_fine"] = "Left adds   Right removes   E flood select   G convert   R box mode   X clear",

		["cluster.cleared"] = "Selection cleared",
		["cluster.add_failed"] = "Cannot add that",
		["cluster.add_failed_count"] = "Selection reached the block limit",
		["cluster.add_failed_extent"] = "Selection exceeds the size limit",
		["cluster.add_failed_air"] = "There is no block there",
		["cluster.flood_air"] = "Aim at a block before flood selecting",
		["cluster.flood_limited"] = "Flood select hit the limit; {n} blocks selected",
		["cluster.flood_done"] = "Flood select +{n} ({total} total)",
		["cluster.corner_a"] = "First corner set; pick the opposite corner to finish the box",
		["cluster.box_extent"] = "Box selection exceeds the size limit ({max} blocks)",
		["cluster.box_volume"] = "Box selection volume is too large",
		["cluster.box_limited"] = "Box select hit the limit; {n} blocks selected",
		["cluster.box_done"] = "Box select +{n} ({total} total)",
		["cluster.nothing_selected"] = "Select some blocks first (left click adds / E flood selects / box select)",
		["cluster.admin_only"] = "Only administrators may use the structure grabber (mc_cluster_public 0)",
		["cluster.too_many"] = "Selection exceeds the limit ({max} blocks, mc_cluster_max_blocks)",
		["cluster.per_player_limit"] = "You reached your structure entity limit ({max}, mc_cluster_max_per_player)",
		["cluster.too_large"] = "Selection exceeds the size limit ({max} blocks, mc_cluster_max_extent)",
		["cluster.too_far"] = "The selection is too far away",
		["cluster.not_loaded"] = "Some chunks in the selection could not be loaded, try again",
		["cluster.empty"] = "The selection contains no blocks",
		["cluster.too_complex"] = "Structure too complex: {n}/{max} collision convexes",
		["cluster.no_collision"] = "The selection has no collidable blocks",
		["cluster.phys_failed"] = "Collision build failed: {err}",
		["cluster.spawn_failed"] = "Failed to spawn the structure entity: {err}",
		["cluster.remove_failed"] = "Block removal failed; conversion cancelled",
		["cluster.converted"] = "Converted {n} blocks into a structure entity (spawns frozen; unfreeze with the physgun to move it, aim and press G to place it back)",
		["cluster.converted_crate"] = "Converted {n} blocks into a crate structure (single-box collision; unfreeze with the physgun to move it, aim and press G to place it back)",
		["cluster.paste_occupied_n"] = "{n} target cells are occupied by blocks",
		["cluster.paste_err_occupied"] = "The target cells are occupied",
		["cluster.paste_err_bounds"] = "Outside build bounds",
		["cluster.paste_err_limit"] = "Would exceed the global block limit (mc_max_blocks)",
		["cluster.paste_err_record"] = "Structure data is missing",
		["cluster.undo_text"] = "Undo MC block structure (restore in place)",
		["cluster.undo_restored"] = "Structure restored to its original spot",
		["cluster.undo_failed"] = "Undo failed: {err}",
		["cluster.pasted"] = "Placed {n} blocks back onto the grid",
		["cluster.paste_failed"] = "Place back failed: {err}",
		["cluster.tilted"] = "The structure is tilted too far; level it with the physgun first",
		["cluster.ghosted"] = "The structure is embedded in blocks: block collision is off until you pull it clear",
		["cluster.use_info"] = "Block structure: {n} blocks  durability {hp}",
		["cluster.use_invincible"] = "invulnerable",
		["cluster.use_owner"] = "  owner {name}",
		["cluster.use_frozen"] = "  [frozen]",

		["creative.category.all"] = "All",
		["creative.category.color_blocks"] = "Color Blocks",
		["creative.category.slopes"] = "Slopes",
		["creative.category.custom"] = "Custom",
		["creative.category.building"] = "Building Blocks",
		["creative.category.natural"] = "Natural Blocks",
		["creative.category.functional"] = "Functional Blocks",
		["creative.category.redstone"] = "Redstone",
		["creative.category.decoration"] = "Decoration",
		["creative.category.transparent"] = "Transparent/Glass",
		["creative.category.plants"] = "Plants",
		["creative.title"] = "Creative Inventory",
		["creative.search"] = "Search Chinese / English / minecraft:id",
		["creative.page"] = "{page} / {pages}    {count} blocks",
		["creative.state.title"] = "Block State",
		["creative.state.auto"] = "Automatic Placement",
		["creative.state.selected"] = "Selected",
		["creative.state.explicit_default"] = "Explicit Default State",
		["creative.state.approx_preview"] = "Preview uses a compatibility model; state data remains complete",
		["palette.title"] = "Select Block",
		["sync.progress"] = "MC sync {received}/{expected} blocks  {done}/{chunks} chunks",
		["sync.progress_bytes"] = "MC sync {received}/{expected} KB  {done}/{chunks} parts",
		["sync.complete"] = "MC sync complete  {label}",
		["sync.workshop_progress"] = "Loading Workshop world locally {received}/{expected} blocks  {done}/{chunks} chunks",
		["sync.workshop_complete"] = "Workshop base world loaded locally",

		["save.no_cover"] = "No screenshot",
		["save.auto_cover"] = "Saving once will capture one automatically",
		["save.enter_name"] = "Enter a save name",
		["save.uploading"] = "Uploading screenshot and saving...",
		["save.upload_busy"] = "A screenshot is already uploading",
		["save.upload_failed"] = "Screenshot upload failed; save was not created: {err}",
		["save.admin_only"] = "Only admins can save and load by default",
		["save.map_prefix"] = "Map: {map}",
		["save.title"] = "MC Save Manager",
		["save.current_map"] = "Current map: {map}",
		["save.new_name"] = "New save name",
		["save.save_current"] = "Save Current",
		["save.refresh"] = "Refresh",
		["save.loading"] = "Loading...",
		["save.list_title"] = "Maps / Saves",
		["save.info_title"] = "Map Info",
		["save.select_hint"] = "Select a save on the left.",
		["save.field_save"] = "Save",
		["save.field_map"] = "Map",
		["save.field_saved"] = "Saved",
		["save.field_size"] = "Size",
		["save.field_cover"] = "Screenshot",
		["save.none"] = "None",
		["save.load"] = "Load",
		["save.select_first"] = "Select a save first",
		["save.load_confirm_body"] = "Loading this save will replace the current MC block world and resync all clients.",
		["save.load_confirm_title"] = "Load save: {name}",
		["save.cancel"] = "Cancel",
		["save.overwrite"] = "Overwrite and Capture",
		["save.overwrite_confirm_body"] = "Overwrite this named save with the current world and refresh the screenshot?",
		["save.overwrite_confirm_title"] = "Overwrite save: {name}",
		["save.delete"] = "Delete",
		["save.delete_confirm_body"] = "Deletion cannot be automatically undone.",
		["save.delete_confirm_title"] = "Delete save: {name}",
		["save.mounted_read_only"] = "Mounted Workshop saves are read-only",
		["save.empty"] = "No named saves yet. Enter a name, then click Save Current.",
		["save.count"] = "{count} saves",
		["workshop.import"] = "Load from Workshop",
		["workshop.import_hint"] = "Enter a Workshop ID or Steam Workshop link; the server must approve before receiving and loading the world bundle.",
		["workshop.permission_hint"] = "mc_workshop_manage does not allow you to manage Workshop worlds.",
		["workshop.publish"] = "Publish to Workshop",
		["workshop.publish_hint"] = "The server exports the save, then this client captures a preview and opens GMod's publisher.",
		["workshop.publish_confirm_body"] = "The client will request this save from the server, hide the menu to capture a preview, then open Garry's Mod's Workshop publisher. Continue?",
		["workshop.publish_confirm_title"] = "Publish to Workshop: {name}",
		["workshop.view"] = "View Workshop",
		["workshop.field_source"] = "Source",
		["workshop.field_id"] = "Workshop ID",
		["workshop.source_local"] = "Local save",
		["workshop.source_published"] = "Local save (published)",
		["workshop.source_imported"] = "Workshop import",
		["workshop.source_mounted"] = "Mounted Workshop save (read-only)",
		["workshop.source_mounted_badge"] = "Mounted",
		["workshop.filter_source"] = "Source",
		["workshop.filter_local"] = "Local saves",
		["workshop.filter_workshop"] = "Workshop",
		["workshop.exporting"] = "The server is exporting the save...",
		["workshop.capturing"] = "Hiding the menu and capturing the Workshop preview...",
		["workshop.publisher_open"] = "Opening Garry's Mod's Workshop publisher...",
		["workshop.binding"] = "Writing the Workshop ID back to the server save...",
		["workshop.publish_done"] = "Published and linked Workshop ID {id}",
		["workshop.publish_bound"] = "Linked Workshop ID: {id}",
		["workshop.bind_title"] = "Link Workshop ID",
		["workshop.bind_prompt"] = "The publisher did not return its ID directly to the game. Enter the Workshop ID you just published or updated, or paste its Steam Workshop link.",
		["workshop.bind_cancelled"] = "The file was handed to Steam, but no Workshop ID was linked",
		["workshop.bind"] = "Link",
		["workshop.import_title"] = "Load Workshop world",
		["workshop.import_prompt"] = "Enter a Workshop ID or Steam Workshop link. Full filedetails links, links ending in /, and plain numeric IDs are supported. The client validates it first; the server receives and loads it only after approval.",
		["workshop.import_dedicated_title"] = "Dedicated server transfer: {id}",
		["workshop.import_dedicated_body"] = "You are connected to a dedicated server. Your client will download and validate the complete GMA from Steam, then upload it to the server through the game network. Large worlds may use significant upstream bandwidth and take several minutes. Continue?",
		["workshop.import_dedicated_continue"] = "Continue transfer",
		["workshop.downloading"] = "Downloading Workshop item {id}...",
		["workshop.awaiting_approval"] = "World bundle validated; waiting for server approval...",
		["workshop.uploading"] = "Server approved; uploading for a second validation...",
		["workshop.reading_shared"] = "Server approved; reading and validating the world bundle through the Listen Server shared data directory...",
		["workshop.import_done"] = "Loaded from Workshop: {name}",
		["workshop.error_permission"] = "The server did not approve this Workshop operation",
		["workshop.error_rate"] = "Too many requests; try again shortly",
		["workshop.error_busy"] = "Another Workshop transfer is already active",
		["workshop.error_slot"] = "The save name is invalid",
		["workshop.error_legacy"] = "Legacy saves cannot be published yet; overwrite-save it once first",
		["workshop.error_id"] = "The Workshop ID or link is invalid",
		["workshop.error_request"] = "The Workshop load request is invalid",
		["workshop.error_not_world"] = "This item is not an MC world save",
		["workshop.error_version"] = "This MC world save version is not supported",
		["workshop.error_corrupt"] = "The Workshop world bundle failed validation",
		["workshop.error_capture_empty"] = "Could not capture the current game view for the Workshop preview; return to the game view and try again",
		["workshop.error_capture_too_large"] = "The captured Workshop preview exceeds the size limit",
		["workshop.error_capture_write"] = "Could not write the Workshop preview to the client data directory",
		["workshop.error_capture_timeout"] = "Timed out waiting to capture the game view",
		["workshop.error_capture_size"] = "The current game view is too small to create a Workshop preview",
		["workshop.error_file_unreadable"] = "Could not read the Workshop world file downloaded by Steam",
		["workshop.error_file_too_large"] = "The Workshop world file exceeds the server size limit",
		["workshop.error_shared_write"] = "Could not write the Listen Server shared world file",
		["workshop.error_shared_read"] = "The Listen Server could not read the shared world file",
		["workshop.error_shared_unavailable"] = "This client cannot use Listen Server shared loading",
		["workshop.error_cache_write"] = "Could not cache the Workshop base world",
		["workshop.error_timeout"] = "The Workshop operation timed out",
		["workshop.error_load"] = "The server could not load this world",
		["workshop.error_generic"] = "Workshop operation failed: {err}",
		["library.save_subtitle"] = "Organize, filter, and return to your block worlds",
		["library.preset_subtitle"] = "Keep build ideas ready to place again",
		["library.filter"] = "Filters",
		["library.maps"] = "Saved map",
		["library.all"] = "All",
		["library.current_map"] = "Current map",
		["library.groups"] = "Custom groups",
		["library.all_groups"] = "All groups",
		["library.group_none"] = "Ungrouped",
		["library.group"] = "Group",
		["library.new"] = "+ New",
		["library.new_group"] = "New group",
		["library.rename_group"] = "Rename group",
		["library.delete_group"] = "Delete group",
		["library.delete_group_hint"] = "The group will be removed and its items will become ungrouped.",
		["library.group_name"] = "Enter a group name",
		["library.group_exists"] = "The group name is empty or already exists",
		["library.group_manage_hint"] = "Right-click to rename or delete this group",
		["library.move_to_group"] = "Move to",
		["library.search"] = "Search name or map",
		["library.no_results"] = "Nothing matches the current filters.",
		["library.showing"] = "Showing {visible} / {total}",

		["preset.no_cover"] = "No screenshot",
		["preset.auto_cover"] = "Saving a preset will capture one automatically",
		["preset.overwrite_on"] = "Preset overwrite mode: on. Existing blocks in the target volume will be replaced.",
		["preset.overwrite_off"] = "Preset overwrite mode: off. Placement will skip occupied target cells.",
		["preset.rotation_chat"] = "Preset rotation: {degrees} deg",
		["preset.loaded_chat"] = "Loaded preset: {name}. Aim to preview it, G rotates, left click places, right click cancels.",
		["preset.start_chat"] = "Started new preset {name}: left click the first block.",
		["preset.selection_incomplete"] = "Preset selection is not complete yet.",
		["preset.saving_chat"] = "Capturing screenshot and saving preset: {name}",
		["preset.upload_failed_saved"] = "Screenshot upload failed; preset saved without a cover: {err}",
		["preset.admin_only"] = "Only admins can save and load presets by default",
		["preset.aim_block"] = "Aim at an MC block.",
		["preset.step1_chat"] = "Selected first block. Left click the second block to finish the range, right click undoes.",
		["preset.step2_chat"] = "Range complete. Left click an anchor face; the preset will align it to your aim point.",
		["preset.anchor_outside"] = "The anchor face must be inside the selected range.",
		["preset.step3_chat"] = "Anchor selected. Left click once more to capture and save.",
		["preset.projection_cancelled"] = "Cancelled preset projection.",
		["preset.selection_cancelled"] = "Cancelled preset selection.",
		["preset.undo"] = "Undid one step.",
		["preset.load_first"] = "Press R and load a preset first.",
		["preset.aim_place"] = "Aim at a valid preset placement position.",
		["preset.manager_title"] = "MC Preset Placer",
		["preset.header"] = "Create or load build presets",
		["preset.new_name"] = "New preset name",
		["preset.create"] = "Create Preset",
		["preset.refresh"] = "Refresh",
		["preset.loading"] = "Loading...",
		["preset.list_title"] = "Presets",
		["preset.info_title"] = "Preset Info",
		["preset.select_hint"] = "Select a preset on the left, or enter a name to create one.",
		["preset.field_preset"] = "Preset",
		["preset.field_map"] = "Map",
		["preset.field_size"] = "Size",
		["preset.field_created"] = "Created",
		["preset.load_projection"] = "Load Projection",
		["preset.select_first"] = "Select a preset first",
		["preset.loading_projection"] = "Loading preset...",
		["preset.empty"] = "No presets yet. Enter a name, then click Create Preset.",
		["preset.count"] = "{count} presets",
		["preset.load_failed"] = "Preset load failed: {message}",
		["preset.load_damaged"] = "Preset load failed: data is damaged",

		["server.admin_build"] = "Only admins can build (mc_admin_only)",
		["server.world_limit"] = "Outside build bounds (mc_world_limit)",
		["server.max_blocks"] = "Block limit reached (mc_max_blocks)",
		["server.fill_usage"] = "Usage: /fill x1 y1 z1 x2 y2 z2 <id|name|air|minecraft:name[state]> [state]",
		["server.invalid_state"] = "Invalid block state: {block}",
		["server.fill_too_large"] = "Fill range is too large ({volume} > mc_fill_max {max})",
		["server.fill_max_blocks"] = "This would exceed the block limit (mc_max_blocks)",
		["server.filled"] = "Filled {count} blocks",
		["server.import_usage"] = "Usage: mc_import <mc_import/file.json> [replace|append]",
		["server.invalid_file"] = "Invalid file format",
		["server.import_missing"] = "Import file not found: garrysmod/data/{path}",
		["server.import_bad_json"] = "Import file is not valid JSON: {path}",
		["server.import_failed"] = "Import failed: {err}",
		["server.import_done"] = "Import complete: {blocks} blocks, current total {total}, skipped unknown {unknown}, out of bounds {bounds}, over limit {max}",
		["server.import_count_mismatch"] = "Import file lists {expected} blocks, but {imported} entered the server; skipped blocks are counted above.",
		["server.import_truncated"] = "Import was truncated by mc_import_max={max}; run mc_import_max 0 before importing the full chunks.",
		["server.rebuilt"] = "Rebuilt collision for {count} chunks",
		["server.save_admin_list"] = "Only admins can load/save saves (mc_save_public 0)",
		["server.save_admin_save"] = "Only admins can save saves (mc_save_public 0)",
		["server.save_admin_load"] = "Only admins can load saves (mc_save_public 0)",
		["server.save_admin_delete"] = "Only admins can delete saves",
		["server.action_done"] = "Action complete: {action}",
		["server.action_failed"] = "Action failed: {err}",
		["server.preset_admin"] = "Only admins can list/load/save/place presets (mc_preset_public 0)",
		["server.preset_edit_admin"] = "Only admins can save/place presets (mc_admin_only)",
		["server.preset_admin_list"] = "Only admins can load/save presets (mc_preset_public 0)",
		["server.preset_admin_load"] = "Only admins can load presets (mc_preset_public 0)",
		["server.preset_admin_save"] = "Only admins can save presets (mc_preset_public 0)",
		["server.preset_placed"] = "Placed preset: {name} ({changes} changes)",
		["server.preset_overwritten"] = "Overwrote preset: {name} ({changes} changes)",
		["server.preset_saved"] = "Preset saved: {name}",
		["server.preset_save_failed"] = "Preset save failed: {err}",
		["server.preset_place_failed"] = "Preset placement failed: {err}",
	},
}

local EN_BLOCK_OVERRIDES = {
	["minecraft:tnt"] = "TNT",
	["minecraft:redstone_wire"] = "Redstone Dust",
	["minecraft:grass_block"] = "Grass Block",
	["mcswep:oak_slope"] = "Custom Oak Slope",
	["mcswep:red_color_block"] = "Custom Red Block",
	["mcswep:green_color_block"] = "Custom Green Block",
	["mcswep:blue_color_block"] = "Custom Blue Block",
	["mcswep:white_color_block"] = "Custom White Block",
	["mcswep:black_color_block"] = "Custom Black Block",
}
MC.EnglishBlockNameOverrides = EN_BLOCK_OVERRIDES

local TITLE_ACRONYMS = {
	tnt = "TNT",
	tv = "TV",
}

local function titleWord( word )
	word = tostring( word or "" )
	local lower = string.lower( word )
	if TITLE_ACRONYMS[lower] then return TITLE_ACRONYMS[lower] end
	return string.upper( string.sub( lower, 1, 1 ) ) .. string.sub( lower, 2 )
end

local function englishNameFromID( mcid )
	local key = string.match( tostring( mcid or "" ), "^[^:]+:(.+)$" ) or tostring( mcid or "" )
	key = string.gsub( key, "_", " " )
	return string.gsub( key, "%S+", titleWord )
end

local function interpolate( text, vars )
	if type( vars ) ~= "table" then return text end
	return ( string.gsub( text, "{([%w_]+)}", function( key )
		local value = vars[key]
		if value == nil then return "{" .. key .. "}" end
		return tostring( value )
	end ) )
end

function MC.LanguageOptions()
	local options = {}
	for _, value in ipairs( LANGUAGE_OPTION_ORDER ) do
		options[#options + 1] = {
			value = value,
			label = LANGUAGE_OPTION_LABELS[value] or value,
		}
	end
	return options
end

local function cvarLanguageSetting()
	if CLIENT then
		if not MC.LanguageConVar and CreateClientConVar then
			MC.LanguageConVar = CreateClientConVar( "mc_language", DEFAULT_LANGUAGE_SETTING, true, true, "MC UI language: auto, zh_cn, or en_us" )
		end
		if MC.LanguageConVar and MC.LanguageConVar.GetString then
			return normalizeLanguageSetting( MC.LanguageConVar:GetString() )
		end
	end
	return normalizeLanguageSetting( MC.CurrentLanguage or DEFAULT_LANGUAGE_SETTING )
end

function MC.LanguageSetting()
	return cvarLanguageSetting()
end

function MC.Language()
	return resolveLanguage( cvarLanguageSetting(), clientGameLanguage() )
end

function MC.LanguageForPlayer( ply )
	if SERVER and IsValid( ply ) and ply.GetInfo then
		local setting = normalizeLanguageSetting( ply:GetInfo( "mc_language" ) )
		return resolveLanguage( setting, ply:GetInfo( "gmod_language" ) )
	end
	return MC.Language()
end

function MC.T( key, fallback, vars, lang )
	if type( fallback ) == "table" then
		vars = fallback
		fallback = nil
	end
	lang = normalizeLanguage( lang or MC.Language() )
	local tableForLang = MC.LanguageData[lang] or MC.LanguageData[DEFAULT_LANGUAGE] or {}
	local text = tableForLang[key]
	if text == nil and lang ~= DEFAULT_LANGUAGE then
		text = ( MC.LanguageData[DEFAULT_LANGUAGE] or {} )[key]
	end
	if text == nil then text = fallback or key end
	return interpolate( tostring( text ), vars )
end

function MC.TFor( ply, key, fallback, vars )
	return MC.T( key, fallback, vars, MC.LanguageForPlayer( ply ) )
end

function MC.SetLanguage( lang )
	lang = normalizeLanguageSetting( lang )
	if CLIENT and RunConsoleCommand then
		RunConsoleCommand( "mc_language", lang )
	else
		MC.CurrentLanguage = lang
	end
	return lang
end

function MC.RegisterLanguageChanged( name, fn )
	if type( name ) == "function" then
		fn = name
		name = tostring( fn )
	end
	if type( fn ) ~= "function" then return end
	MC.LanguageCallbacks[tostring( name )] = fn
end

local function runLanguageChanged()
	if MC.RefreshBlockDisplayNames then MC.RefreshBlockDisplayNames() end
	if MC.LocalizeToolLanguage then MC.LocalizeToolLanguage() end
	for _, fn in pairs( MC.LanguageCallbacks or {} ) do
		fn( MC.Language() )
	end
end

function MC.BlockDisplayName( blockOrDef, fallback, lang )
	local def = type( blockOrDef ) == "table" and blockOrDef or nil
	local mcid = def and def.mcid or tostring( blockOrDef or "" )
	local name = def and def.name
	lang = normalizeLanguage( lang or MC.Language() )

	if lang == "en_us" then
		return EN_BLOCK_OVERRIDES[mcid] or EN_BLOCK_OVERRIDES[name] or englishNameFromID( mcid ~= "" and mcid or name )
	end

	if def then
		return def.dispZH or def.zhDisp or def.baseDisp or fallback or def.disp
			or ( MC.GeneratedBlockNames and ( MC.GeneratedBlockNames[mcid] or MC.GeneratedBlockNames[name] ) )
			or englishNameFromID( mcid ~= "" and mcid or name )
	end
	return fallback or englishNameFromID( mcid )
end

function MC.RefreshBlockDisplayNames( lang )
	lang = normalizeLanguage( lang or MC.Language() )
	for _, b in pairs( MC.Blocks or {} ) do
		b.disp = MC.BlockDisplayName( b, b.dispZH or b.disp, lang )
	end
end

function MC.LocalizeToolLanguage()
	if not CLIENT or not language or not language.Add then return end
	language.Add( "tool.mc_block.name", MC.T( "tool.name", "MC 方块" ) )
	language.Add( "tool.mc_block.desc", MC.T( "tool.desc", "放置 / 破坏 Minecraft 方块（IMesh 渲染，不生成实体）" ) )
	language.Add( "tool.mc_block.0", MC.T( "tool.usage", "左键破坏   右键放置   Reload 复制方块" ) )
end

if CLIENT then
	cvarLanguageSetting()

	local function printLanguageOptions()
		local lines = {
			string.format( "[MC] mc_language = %s (current %s)", MC.LanguageSetting(), MC.Language() ),
			"[MC] Available languages:",
		}
		for _, option in ipairs( MC.LanguageOptions() ) do
			lines[#lines + 1] = string.format( "[MC]   %s - %s", option.value, option.label )
		end
		for _, line in ipairs( lines ) do
			if MsgN then MsgN( line ) else print( line ) end
		end
	end

	local function autocompleteLanguageCommand( commandName, stringArgs )
		local needle = string.lower( trim( stringArgs or "" ) )
		local suggestions = {}
		for _, option in ipairs( MC.LanguageOptions() ) do
			local haystack = string.lower( option.value .. " " .. option.label )
			if needle == "" or string.find( haystack, needle, 1, true ) then
				suggestions[#suggestions + 1] = commandName .. " " .. option.value
			end
		end
		return suggestions
	end

	if cvars and cvars.AddChangeCallback then
		cvars.RemoveChangeCallback( "mc_language", "mc_i18n_refresh" )
		cvars.AddChangeCallback( "mc_language", function( _, _, newValue )
			local normalized = normalizeLanguageSetting( newValue )
			if normalized ~= trim( newValue ) and RunConsoleCommand then
				RunConsoleCommand( "mc_language", normalized )
				return
			end
			runLanguageChanged()
		end, "mc_i18n_refresh" )
	end

	if concommand and concommand.Add then
		concommand.Add( "mc_language_toggle", function()
			MC.SetLanguage( MC.Language() == "en_us" and "zh_cn" or "en_us" )
		end )
		concommand.Add( "mc_lang", function( _, _, args )
			local requested = args and args[1] or ""
			local parsed, ok = parseLanguageSetting( requested )
			if trim( requested ) == "" or requested == "?" or requested == "help" then
				printLanguageOptions()
				return
			end
			if not ok then
				MC.SetLanguage( parsed )
				printLanguageOptions()
				return
			end
			MC.SetLanguage( parsed )
		end, autocompleteLanguageCommand, "Set MC UI language: auto, zh_cn, or en_us" )
	end

	if timer and timer.Simple then
		timer.Simple( 0, runLanguageChanged )
	end
end
