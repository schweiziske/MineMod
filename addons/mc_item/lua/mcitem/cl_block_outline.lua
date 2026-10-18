-- 手持 MCITEM 武器 / 物品时，瞄准的 MCSWEP 方块画描边。
--
-- MCSWEP 自己的 `mc_item_hand_block_outline` 钩子只在"当前武器是 MC Hands、背包，
-- 或者当前选中栈解析得到的那把 SWEP"时才画；从生成菜单直接拿一把 MCITEM 武器
-- （没有 MCSWEP 背包栈）就落在条件外面，所以这里补一份。判据互斥：MCSWEP 已经
-- 认领这一帧时本文件直接让路，不会画两遍。
--
-- 描边本身用 MCSWEP 的 `MC.API.UI.DrawBlockOutline`（v1 公开入口），形状、颜色和
-- 原版方块一致，我们不自己画线框。

if not CLIENT then return end

MCITEM = MCITEM or {}

if MCITEM.BlockOutlineInstalled then return end
MCITEM.BlockOutlineInstalled = true

local cvOutline = CreateClientConVar("mcitem_block_outline", "1", true, false,
    "Draw the MCSWEP block outline while a Minecraft weapon or item is aimed at a block.")

local OUTLINE_COLOR = Color(0, 0, 0, 235)

-- MCITEM 的每一件 SWEP 都继承 weapon_bmb_item_model_test，所以基类方法就是判据；
-- 不按类名前缀匹配（食物 / 药水 / 投掷物的类名规则各不相同）。
local function isMCItemWeapon(weapon)
    return IsValid(weapon) and isfunction(weapon.GetMCItemState)
end

hook.Add("PostDrawTranslucentRenderables", "MCITEM.BlockOutline", function(_, _, sky3d)
    if sky3d or not cvOutline:GetBool() then return end

    local ply = LocalPlayer()
    if not IsValid(ply) or not ply:Alive() then return end
    if not isMCItemWeapon(ply:GetActiveWeapon()) then return end

    local api = MC and MC.API
    if not istable(api) or not istable(api.UI) or not isfunction(api.UI.DrawBlockOutline) then return end
    if isfunction(api.IsReady) and not api.IsReady() then return end

    -- MCSWEP 已经为这把武器画了描边就让路（受管 SWEP / 选中栈解析得到的那把）。
    if isfunction(MC.IsInventoryHeldItemWeaponActive) and MC.IsInventoryHeldItemWeaponActive(ply) then
        return
    end

    if not istable(api.World) or not isfunction(api.World.PlayerAim) then return end
    local hit = api.World.PlayerAim(ply)
    if not istable(hit) or hit.bx == nil then return end

    api.UI.DrawBlockOutline(hit.StateId or hit.Block, hit.bx, hit.by, hit.bz, OUTLINE_COLOR)
end)
