-- Client-only visibility adapter.  Potion particles remain visible while the
-- affected entity model is hidden, matching LivingEntity invisibility.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Potions = MCITEM.Potions or {}

local hidden = setmetatable({}, { __mode = "k" })

-- 只有带效果的实体才可能发光或隐身，所以这两个 hook 读状态 tick 每 20Hz 产出的
-- 那份列表就够了。它们以前各自**每帧**遍历 ents.GetAll()，并且发光那条还会对每个
-- 实体解一次效果快照（NW2 字符串读 + JSON 解码）——世界里实体越多越贵，而其中
-- 带药水效果的通常是个位数。
local function affectedEntities()
    return MCITEM.Potions.AffectedEntities or {}
end

local function hasGlowing(entity)
    local effects = MCITEM.Potions.ClientEffects and MCITEM.Potions.ClientEffects(entity) or {}
    for _, effect in ipairs(effects) do
        if effect.id == "glowing" then return true end
    end
    return false
end

hook.Remove("PreDrawHalos", "MCITEM.Potions.GlowingOutline")
hook.Add("PreDrawHalos", "MCITEM.Potions.GlowingOutline", function()
    if not halo or not halo.Add then return end
    local glowing = {}
    for _, entity in ipairs(affectedEntities()) do
        if IsValid(entity) and hasGlowing(entity) then
            glowing[#glowing + 1] = entity
        end
    end
    if #glowing > 0 then
        -- Java renders glowing entities through the entity-outline pass. GMod's
        -- halo pass is the closest depth-aware equivalent and remains visible
        -- through geometry, which is the gameplay-significant behavior.
        halo.Add(glowing, Color(255, 255, 255), 2, 2, 1, true, true)
    end
end)

hook.Remove("Think", "MCITEM.Potions.Invisibility")
hook.Add("Think", "MCITEM.Potions.Invisibility", function()
    for _, entity in ipairs(affectedEntities()) do
        if IsValid(entity) and hidden[entity] == nil
            and entity:GetNW2Bool("MCITEMPotionInvisible", false)
        then
            hidden[entity] = entity:GetNoDraw()
            entity:SetNoDraw(true)
        end
    end
    -- 恢复必须走我们自己隐藏过的那张表，不能只扫 affected：效果结束后实体就从
    -- 列表里消失了，只扫 affected 会让它永远隐身。
    for entity, previous in pairs(hidden) do
        if not IsValid(entity) then
            hidden[entity] = nil
        elseif not entity:GetNW2Bool("MCITEMPotionInvisible", false) then
            entity:SetNoDraw(previous)
            hidden[entity] = nil
        end
    end
end)

hook.Remove("EntityRemoved", "MCITEM.Potions.InvisibilityCleanup")
hook.Add("EntityRemoved", "MCITEM.Potions.InvisibilityCleanup", function(entity)
    hidden[entity] = nil
end)
