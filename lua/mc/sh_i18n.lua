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
		["native.dll_open_hint"] = "(推荐下载)",
		["native.dll_console"] = "Native DLL 下载地址: {url}",
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

		["weapon.mc_creative_placer.name"] = "MC 创造方块放置器",
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
		["sync.complete"] = "MC 同步完成  {label}",

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
		["save.empty"] = "还没有命名存档。输入名字后点“保存当前”。",
		["save.count"] = "{count} 个存档",
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
		["preset.upload_failed"] = "截图上传失败，未保存预设: {err}",
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
		["native.dll_open_hint"] = " (recommended download)",
		["native.dll_console"] = "Native DLL download: {url}",
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

		["weapon.mc_creative_placer.name"] = "MC Creative Block Placer",
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
		["sync.complete"] = "MC sync complete  {label}",

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
		["save.empty"] = "No named saves yet. Enter a name, then click Save Current.",
		["save.count"] = "{count} saves",
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
		["preset.upload_failed"] = "Screenshot upload failed; preset was not saved: {err}",
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
