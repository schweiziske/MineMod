-- 方块交互：左键的"挖掘 vs 攻击"分流，以及锄 / 铲 / 斧的右键 useOn（MC 26.2）。
--
-- 源码来源（解包在 D:\BMBTools\26.2\nnnewest）：
--   Minecraft.startAttack / continueAttack   左键三分支（ENTITY / BLOCK / MISS）
--   HoeItem.useOn + TILLABLES                锄：草/土/径/粗土/缠根泥土
--   ShovelItem.useOn + FLATTENABLES          铲：压成土径
--   AxeItem.useOn + STRIPPABLES / WeatheringCopper.getPrevious / HoneycombItem.WAX_OFF_BY_BLOCK
--
-- MCSWEP 是**软依赖**：没装（或版本没有 MC.API）时，右键 useOn 静默失效、左键退化成
-- "看到 Source 世界实体就当方块"。整个文件不许 include BMB 的任何东西。

MCITEM = MCITEM or {}

local Blocks = MCITEM.BlockInteract or {}
MCITEM.BlockInteract = Blocks

-- InteractionResult.Success 带一个 swingSource()：CLIENT 表示客户端自己挥
-- （HoeItem/ShovelItem/AxeItem 返回的 InteractionResult.SUCCESS 就是这一档），
-- SERVER 表示由服务端广播。我们两条都走：客户端按同一张表预判、服务端**再补发一次**
-- 确认。预判判据和服务端完全一致时这一条是幂等的；一旦哪端看到的方块不一样
-- （网络延迟、chunk 还没水合、MC.API 在某一端没就绪），动画也不会丢。
if SERVER then util.AddNetworkString("MCITEM_ToolUseSwing") end

--------------------------------------------------------------------------------
-- MCSWEP 探测（只走 MC.API v1；内部符号一个都不碰）
--------------------------------------------------------------------------------

local function mcApi()
    if not MC or not istable(MC.API) then return nil end
    if isfunction(MC.API.IsReady) and not MC.API.IsReady() then return nil end
    return MC.API
end

Blocks.Api = mcApi

-- MC 的方块交互距离是 Player.blockInteractionRange()；这里改用 MCSWEP 自己的 reach
-- （`mc_reach`，PlayerAim 传 nil 时的默认），这样工具能够到的格子和方块 addon 的
-- 放置/破坏完全一致，不会出现"能放不能锄"。
function Blocks.AimBlock(ply, reachUnits)
    local api = mcApi()
    if not api or not istable(api.World) or not isfunction(api.World.PlayerAim) then return nil end
    if not IsValid(ply) then return nil end

    local hit = api.World.PlayerAim(ply, reachUnits)
    if not istable(hit) or hit.bx == nil then return nil end
    return hit
end

-- getClickedFace()：命中法线朝下 = 点了方块底面（Direction.DOWN）。
local function clickedDownFace(hit)
    local normal = hit and hit.HitNormal
    return isvector(normal) and normal.z < -0.5
end

local function blockInfo(api, bx, by, bz)
    return api.World.GetBlockInfo(bx, by, bz)
end

-- ⚠ 查表一律用 **mcid**，不要用 `info.name`。MCSWEP 的 `name` 是它自己的内部短名，
-- 和 Minecraft 的 id 不是一回事：草方块注册成 `name = "grass"`、
-- `mcid = "minecraft:grass_block"`（sh_blocks.lua 的 RegisterBlock，aliases 里才有
-- "grass_block"）。按 name 查会让锄头/铲子对草方块完全无反应。
-- mcid 缺席时才退回 name（自定义方块可能没有 mcid）。
function Blocks.LookupKey(info)
    if not istable(info) then return nil end

    local mcid = info.mcid
    if isstring(mcid) and mcid ~= "" then
        return (string.gsub(mcid, "^minecraft:", ""))
    end
    return info.name
end

-- v1 的 GetBlockState 承诺 0 = 空气且绝不返回 nil。
local function isAirAbove(api, bx, by, bz)
    return api.World.GetBlockState(bx, by, bz + 1) == 0
end

-- BlockState.withPropertiesOf(old)：把旧状态的属性带到新方块上。v1 没有"列出全部属性"
-- 的接口，但 GetBlockInfo().spec 就是 `minecraft:name[a=b,c=d]` 的完整状态串，直接把
-- 方括号那一段接到新名字后面即可；解析失败就退回默认状态（= 不带属性）。
local function stateWithProperties(api, targetName, spec, onlyKeys)
    if not spec then return targetName end

    local properties = string.match(spec, "%[(.*)%]")
    if not properties or properties == "" then return targetName end

    if onlyKeys then
        local kept = {}
        for pair in string.gmatch(properties, "[^,]+") do
            local key = string.match(pair, "^%s*([%w_]+)%s*=")
            if key and onlyKeys[key] then kept[#kept + 1] = pair end
        end
        if #kept == 0 then return targetName end
        properties = table.concat(kept, ",")
    end

    local candidate = targetName .. "[" .. properties .. "]"
    local blocksApi = api.Blocks
    if istable(blocksApi) and isfunction(blocksApi.ParseState) and not blocksApi.ParseState(candidate) then
        return targetName
    end
    return candidate
end

--------------------------------------------------------------------------------
-- MC 的三张替换表（逐条抄自 26.2 的 class）
--------------------------------------------------------------------------------

-- 属性继承方式（见 ResolveToolUse 的注释）。
local AXIS_ONLY = { axis = true }
local ALL_PROPERTIES = true

-- HoeItem.TILLABLES。value = 变成什么；airAbove=false 的那条是 ROOTED_DIRT
-- （原版谓词是 `context -> true`，不要求上方是空气）。
Blocks.Tillables = {
    grass_block = { to = "minecraft:farmland", airAbove = true },
    dirt_path = { to = "minecraft:farmland", airAbove = true },
    dirt = { to = "minecraft:farmland", airAbove = true },
    coarse_dirt = { to = "minecraft:dirt", airAbove = true },
    -- changeIntoStateAndDropItem(DIRT, HANGING_ROOTS)：GMod 侧没有掉落物系统，
    -- 方块变化照做，垂根的掉落先不发。
    rooted_dirt = { to = "minecraft:dirt", airAbove = false },
}

-- ShovelItem.FLATTENABLES。原版额外要求 `level.getBlockState(pos.above()).isAir()`。
Blocks.Flattenables = {
    grass_block = "minecraft:dirt_path",
    dirt = "minecraft:dirt_path",
    podzol = "minecraft:dirt_path",
    coarse_dirt = "minecraft:dirt_path",
    mycelium = "minecraft:dirt_path",
    rooted_dirt = "minecraft:dirt_path",
}

-- AxeItem.STRIPPABLES。
Blocks.Strippables = {}
for _, wood in ipairs({
    "oak", "dark_oak", "pale_oak", "acacia", "cherry", "birch", "jungle", "spruce", "mangrove",
}) do
    Blocks.Strippables[wood .. "_wood"] = "minecraft:stripped_" .. wood .. "_wood"
    Blocks.Strippables[wood .. "_log"] = "minecraft:stripped_" .. wood .. "_log"
end
Blocks.Strippables["warped_stem"] = "minecraft:stripped_warped_stem"
Blocks.Strippables["warped_hyphae"] = "minecraft:stripped_warped_hyphae"
Blocks.Strippables["crimson_stem"] = "minecraft:stripped_crimson_stem"
Blocks.Strippables["crimson_hyphae"] = "minecraft:stripped_crimson_hyphae"
Blocks.Strippables["bamboo_block"] = "minecraft:stripped_bamboo_block"

-- WeatheringCopper.getPrevious：氧化度往回退一级（OXIDIZED → WEATHERED → EXPOSED → 未氧化）。
-- 每个形状（整块 / 切制 / 台阶 / 楼梯 / 錾制 / 格栅 / 门 / 活板门 / 灯 / 链 / 栏杆 / 箱子 /
-- 铜灯笼 / 铜傀儡雕像）各一条链，命名规则是 `<氧化前缀>_<形状>`，未氧化那一级没有前缀。
Blocks.Scrapables = {}
do
    -- 未氧化级的实际方块名（不是简单去前缀：整块叫 copper_block，切制叫 cut_copper）。
    local SHAPES = {
        { oxidized = "copper", base = "copper_block" },
        { oxidized = "cut_copper", base = "cut_copper" },
        { oxidized = "cut_copper_slab", base = "cut_copper_slab" },
        { oxidized = "cut_copper_stairs", base = "cut_copper_stairs" },
        { oxidized = "chiseled_copper", base = "chiseled_copper" },
        { oxidized = "copper_grate", base = "copper_grate" },
        { oxidized = "copper_bulb", base = "copper_bulb" },
        { oxidized = "copper_door", base = "copper_door" },
        { oxidized = "copper_trapdoor", base = "copper_trapdoor" },
        { oxidized = "copper_chain", base = "copper_chain" },
        { oxidized = "copper_bars", base = "copper_bars" },
        { oxidized = "copper_chest", base = "copper_chest" },
        { oxidized = "copper_lantern", base = "copper_lantern" },
        { oxidized = "copper_golem_statue", base = "copper_golem_statue" },
    }
    local LEVELS = { "oxidized", "weathered", "exposed" }

    for _, shape in ipairs(SHAPES) do
        for index, level in ipairs(LEVELS) do
            local previousLevel = LEVELS[index + 1]
            local from = level .. "_" .. shape.oxidized
            local to = previousLevel and (previousLevel .. "_" .. shape.oxidized) or shape.base
            Blocks.Scrapables[from] = "minecraft:" .. to
        end
    end
end

-- HoneycombItem.WAX_OFF_BY_BLOCK：打蜡方块去蜡 = 去掉 `waxed_` 前缀。
-- 表由 Scrapables 的全部键 + 四级未氧化基名推出来，避免手抄两遍。
Blocks.WaxOff = {}
do
    local waxable = {}
    for from in pairs(Blocks.Scrapables) do waxable[from] = from end
    for _, shape in ipairs({
        "copper_block", "cut_copper", "cut_copper_slab", "cut_copper_stairs", "chiseled_copper",
        "copper_grate", "copper_bulb", "copper_door", "copper_trapdoor", "copper_chain",
        "copper_bars", "copper_chest", "copper_lantern", "copper_golem_statue",
    }) do
        waxable[shape] = shape
    end
    for name in pairs(waxable) do
        Blocks.WaxOff["waxed_" .. name] = "minecraft:" .. name
    end
end

--------------------------------------------------------------------------------
-- 音效（原版 wave，44.1kHz mono 转码；调用点 level.playSound(..., 1.0f, 1.0f)）
--------------------------------------------------------------------------------

MCITEM.ToolSoundEvents = {
    hoe_till = { "till1.ogg", "till2.ogg", "till3.ogg", "till4.ogg" },
    shovel_flatten = { "flatten1.ogg", "flatten2.ogg", "flatten3.ogg", "flatten4.ogg" },
    axe_strip = { "strip1.ogg", "strip2.ogg", "strip3.ogg", "strip4.ogg" },
    axe_scrape = { "scrape1.ogg", "scrape2.ogg", "scrape3.ogg" },
    axe_wax_off = { "wax_off1.ogg", "wax_off2.ogg", "wax_off3.ogg" },
}

if SERVER then
    for _, files in pairs(MCITEM.ToolSoundEvents) do
        for _, filename in ipairs(files) do
            resource.AddFile("sound/mcitem/tool/" .. filename)
        end
    end
end

-- MC 是 level.playSound(player, pos, event, SoundSource.BLOCKS, 1.0f, 1.0f) —— 声音在
-- **方块那一格**响，不是从玩家身上。position 省略时才退回实体发声。
function MCITEM.PlayToolSound(entity, key, position)
    local files = MCITEM.ToolSoundEvents[key]
    if not files or #files == 0 then return end

    local path = "mcitem/tool/" .. files[math.random(1, #files)]
    if isvector(position) then
        sound.Play(path, position, 75, 100, 1)
    elseif IsValid(entity) then
        entity:EmitSound(path, 75, 100, 1, CHAN_AUTO)
    end
end

--------------------------------------------------------------------------------
-- useOn 求解（纯函数，两端都能跑；服务端才真正写方块）
--------------------------------------------------------------------------------

-- 返回 目标方块名, 音效 key, 属性继承方式；不适用时返回 nil（= InteractionResult.PASS）。
--
-- 属性继承逐条对齐原版，不要统一成一种：
--   锄 changeIntoState(FARMLAND.defaultBlockState())        → 默认状态
--   铲 DIRT_PATH.defaultBlockState()                        → 默认状态
--   斧去皮 defaultBlockState().setValue(AXIS, old.axis)     → 只带 axis
--   斧刮氧化 / 去蜡 withPropertiesOf(oldState)               → 全部属性
function Blocks.ResolveToolUse(action, name, downFace, airAbove)
    if not name then return nil end

    if action == "hoe" then
        local entry = Blocks.Tillables[name]
        if not entry then return nil end
        -- HoeItem.onlyIfAirAbove
        if entry.airAbove and (downFace or not airAbove) then return nil end
        return entry.to, "hoe_till", nil
    end

    if action == "shovel" then
        if downFace then return nil end
        local to = Blocks.Flattenables[name]
        if not to or not airAbove then return nil end
        return to, "shovel_flatten", nil
    end

    if action == "axe" then
        -- AxeItem.evaluateNewBlockState 的顺序：去皮 → 刮氧化 → 去蜡。
        local stripped = Blocks.Strippables[name]
        if stripped then return stripped, "axe_strip", AXIS_ONLY end
        local scraped = Blocks.Scrapables[name]
        if scraped then return scraped, "axe_scrape", ALL_PROPERTIES end
        local waxOff = Blocks.WaxOff[name]
        if waxOff then return waxOff, "axe_wax_off", ALL_PROPERTIES end
        return nil
    end

    return nil
end

if SERVER then
    -- 返回 true = InteractionResult.SUCCESS（吃掉这次右键）。
    function Blocks.UseToolOnBlock(ply, weapon, action)
        if not action or not IsValid(ply) then return false end

        local api = mcApi()
        if not api then return false end

        local hit = Blocks.AimBlock(ply)
        if not hit then return false end

        local bx, by, bz = hit.bx, hit.by, hit.bz
        local info = blockInfo(api, bx, by, bz)
        local target, soundKey, carry = Blocks.ResolveToolUse(
            action, Blocks.LookupKey(info), clickedDownFace(hit), isAirAbove(api, bx, by, bz)
        )
        if not target then return false end

        if carry == ALL_PROPERTIES then
            target = stateWithProperties(api, target, info and info.spec or nil, nil)
        elseif carry then
            target = stateWithProperties(api, target, info and info.spec or nil, carry)
        end

        -- 写入走 v1 的 World.SetBlock（受信服务端路径：跳过玩家 reach/冷却校验，但仍走
        -- 完整副作用管线）。`unchanged` 是正常竞态，按成功处理、不重试。
        local ok, err = api.World.SetBlock(bx, by, bz, target, { actor = ply })
        if not ok and err ~= "unchanged" then return false end

        -- HoeItem/ShovelItem/AxeItem each call hurtAndBreak(1) after a
        -- successful useOn transaction. Route it through the existing selected
        -- stack durability bridge instead of mutating a second local counter.
        if IsValid(weapon) and isfunction(weapon.ApplyMCDurabilityDamage) then
            weapon:ApplyMCDurabilityDamage(1, {
                reason = "tool_use",
                action = action,
                bx = bx, by = by, bz = bz,
            })
        end

        local center = istable(api.Coords) and isfunction(api.Coords.CellCenter)
            and api.Coords.CellCenter(bx, by, bz) or nil
        MCITEM.PlayToolSound(ply, soundKey, center)

        -- AxeItem.spawnSoundAndParticle 的 levelEvent(3005/3004) 是刮痕 / 去蜡的方块碎屑
        -- （去皮那一支没有粒子）。MCSWEP 的等价物是 PlayFx("break")，用新状态发，
        -- 才不会掉出旧贴图的碎屑。
        if soundKey == "axe_scrape" or soundKey == "axe_wax_off" then
            api.World.PlayFx("break", bx, by, bz, target)
        end

        -- InteractionResult.SUCCESS → player.swing(hand)。服务端确认这一刀真的落地了，
        -- 补发给挥手的那个玩家（客户端预判命中时会被 duration/2 门吃掉，不会挥两次）。
        if ply:IsPlayer() then
            net.Start("MCITEM_ToolUseSwing")
            net.Send(ply)
        end

        return true
    end
end

-- MCITEM 的 SWEP 接管时，右键实体压根没有走到 MC.UseItemOnEntity —— MCSWEP 那条
-- 分发在 mc_item_hand 的 SecondaryAttack 里，而选中的物品一旦由 MCITEM 自己的 SWEP
-- 接管，那个 SWEP 就不是 mc_item_hand 了。表现就是"在 mcinventory 里拿着 mcitem 的
-- 物品时没法和生物交互"。
--
-- 补在这里而不是逐个改十九个武器：这是一条与具体物品无关的分发，各武器自己的
-- SecondaryAttack 不受影响。只在当前武器确实是 MCITEM SWEP 时才跑，所以和
-- mc_item_hand 那条天然互斥，不会重复触发。
local MCITEM_ENTITY_INTERACT_COOLDOWN = 0.25
MCITEM.EntityInteractDebug = MCITEM.EntityInteractDebug
    or (SERVER and CreateConVar and CreateConVar("mcitem_entity_interact_debug", "0",
        FCVAR_ARCHIVE, "打印 MCITEM 右键实体的分发结果")) or nil
local nextEntityInteract = setmetatable({}, { __mode = "k" })

local function javaEntityReach(ply)
    -- Player.DEFAULT_ENTITY_INTERACTION_RANGE = 3，创造 +2；和 mc_item_hand 一致。
    local blockSize = tonumber(MC and MC.BS) or 36.5
    local blocks = 3
    local creative = MC and MC.SV and MC.SV.PlayerIsCreative
    if isfunction(creative) and creative(ply) == true then blocks = blocks + 2 end
    return blockSize * blocks
end

local function traceEntityTarget(ply)
    local trace = ply.GetEyeTrace and ply:GetEyeTrace()
    local target = trace and trace.Entity or nil
    if not IsValid(target) or target == ply then return nil, trace end
    if target.IsWorld and target:IsWorld() then return nil, trace end

    local start = ply.GetShootPos and ply:GetShootPos() or ply:EyePos()
    local hit = trace.HitPos
        or (target.WorldSpaceCenter and target:WorldSpaceCenter())
        or target:GetPos()
    local reach = javaEntityReach(ply)
    if hit and (hit - start):LengthSqr() > reach * reach + 1 then return nil, trace end
    return target, trace
end

local function selectedStack(ply)
    local inventory = MC and MC.API and MC.API.Inventory
    if not inventory or not isfunction(inventory.GetSelected) then return nil end
    local ok, stack = pcall(inventory.GetSelected, ply)
    return ok and istable(stack) and stack or nil
end

if SERVER then
    -- Debug prints sit before every bail: "no output at all" has to be
    -- distinguishable from "fired and bailed", and the first version of this
    -- only printed after the trace succeeded, which could not tell them apart.
    local function debugOn()
        return MCITEM.EntityInteractDebug and MCITEM.EntityInteractDebug:GetBool()
    end

    hook.Remove("KeyPress", "MCITEM_EntityInteract")
    hook.Add("KeyPress", "MCITEM_EntityInteract", function(ply, key)
        if key ~= IN_ATTACK2 or not IsValid(ply) or not ply:IsPlayer() then return end

        local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon()
        if debugOn() then
            print(string.format("[MCITEM interact] KeyPress ATTACK2 weapon=%s MCSwing=%s",
                IsValid(weapon) and weapon:GetClass() or "nil",
                IsValid(weapon) and tostring(weapon.MCSwing ~= nil) or "nil"))
        end

        -- MCSwing is the marker every MCITEM SWEP carries; mc_item_hand does not,
        -- and it owns this dispatch itself.
        if not IsValid(weapon) or not weapon.MCSwing then return end

        local now = CurTime()
        if now < (nextEntityInteract[ply] or 0) then
            if debugOn() then print("[MCITEM interact] bail: 冷却中") end
            return
        end

        if MCITEM.TryEntityInteract(ply) then return end
    end)

    -- Right click on an entity, dispatched exactly where mc_item_hand does it:
    -- entity interaction first, item/block use afterwards. Returns true when a
    -- listener claimed the click.
    function MCITEM.TryEntityInteract(ply)
        if not SERVER or not IsValid(ply) or not ply:IsPlayer() then return false end
        local weapon = ply.GetActiveWeapon and ply:GetActiveWeapon()
        if not IsValid(weapon) or not weapon.MCSwing then return false end
        if MC and MC.InventoryOffhandUseActive and MC.InventoryOffhandUseActive(weapon) then return false end

        local now = CurTime()
        if now < (nextEntityInteract[ply] or 0) then return false end

        local target, trace = traceEntityTarget(ply)
        if not IsValid(target) then
            if debugOn() then
                local raw = ply.GetEyeTrace and ply:GetEyeTrace()
                local rawEntity = raw and raw.Entity
                print(string.format("[MCITEM interact] bail: 射线没打到可交互实体（原始命中=%s，超距或没瞄到）",
                    IsValid(rawEntity) and rawEntity:GetClass() or "nil"))
            end
            return false
        end

        nextEntityInteract[ply] = now + MCITEM_ENTITY_INTERACT_COOLDOWN
        local context = {
            preview = false,
            hand = "mainhand",
            source = "mcitem_secondary",
            hitPos = trace and trace.HitPos and Vector(trace.HitPos) or nil,
            hitNormal = trace and trace.HitNormal and Vector(trace.HitNormal) or nil,
        }
        local stack = selectedStack(ply)
        local result = hook.Run("MC.UseItemOnEntity", ply, target, stack, context)
        if MCITEM.EntityInteractDebug and MCITEM.EntityInteractDebug:GetBool() then
            -- A non-nil result means some listener claimed the click and every
            -- later listener (the swing among them) was skipped.
            print(string.format("[MCITEM interact] %s(%d) stack=%s -> %s",
                target:GetClass(), target:EntIndex(),
                istable(stack) and tostring(stack.item) or tostring(stack),
                tostring(result)))
        end
        local consumed = result ~= nil
        -- Send the swing here rather than from a MC.UseItemOnEntity listener.
        -- hook.Run stops at the first non-nil return, and the listener that
        -- opens the trade returns true, so a listener-based swing is only ever
        -- reached for interactions nobody claimed -- exactly backwards. Doing it
        -- at the dispatch site also matches Java, where the swing follows
        -- InteractionResult.SUCCESS instead of every attempted right click.
        if consumed and ply:IsPlayer() then
            net.Start("MCITEM_ToolUseSwing")
            net.Send(ply)
        end
        return consumed
    end
end

if CLIENT then
    -- 服务端确认 useOn 成功（InteractionResult.SUCCESS → player.swing）。
    -- 已经被客户端预判挥过的话，MCITEM.Swing 的 duration/2 门会把这次请求吃掉，
    -- 不会变成两次挥动。
    net.Receive("MCITEM_ToolUseSwing", function()
        local ply = LocalPlayer()
        if not IsValid(ply) then return end

        local weapon = ply:GetActiveWeapon()
        if not IsValid(weapon) or not weapon.MCSwing then return end
        weapon:MCSwing(CurTime())
    end)
end

return Blocks
