include("shared.lua")
include("mcitem/fishing/cl_effects.lua")

local Fishing = MCITEM.Fishing
local hookMaterial = Material("mcitem/fishing/fishing_hook.png", "noclamp")

function ENT:Initialize()
    -- FishingHookRenderer disables normal entity culling because the sixteen
    -- segment line can remain visible while the bobber itself is off-screen.
    local extent = Fishing.MaxOwnerDistance * Fishing.BlockSize()
    self:SetRenderBounds(Vector(-extent, -extent, -extent), Vector(extent, extent, extent))
end

local function fallbackLineOrigin(owner)
    if not IsValid(owner) then return nil end
    local eye = owner:EyePos()
    local angles = owner:EyeAngles()
    return eye + angles:Forward() * (0.8 * Fishing.BlockSize())
        + angles:Right() * (0.35 * Fishing.BlockSize())
        - angles:Up() * (0.45 * Fishing.BlockSize())
end

function ENT:FishingLineOrigin()
    local owner = self:GetOwner()
    if not IsValid(owner) then return nil end
    local weapon = self:GetRodWeapon()
    if IsValid(weapon) and isfunction(weapon.GetMCFishingLineOrigin) then
        local position = weapon:GetMCFishingLineOrigin(owner)
        if isvector(position) then return position end
    end
    return fallbackLineOrigin(owner)
end

function ENT:DrawFishingLine(handPosition)
    if not isvector(handPosition) then return end
    local size = Fishing.BlockSize()
    local hookPosition = self:GetPos()
    local start = hookPosition + Vector(0, 0, 0.25 * size)
    local offset = handPosition - start
    local prior = start
    for index = 1, 16 do
        local amount = index / 16
        local point = Vector(
            hookPosition.x + offset.x * amount,
            hookPosition.y + offset.y * amount,
            hookPosition.z + (offset.z * (amount * amount + amount) * 0.5 + 0.25 * size)
        )
        render.DrawLine(prior, point, color_black, true)
        prior = point
    end
end

function ENT:Draw()
    local size = Fishing.BlockSize() * 0.5
    render.SetMaterial(hookMaterial)
    render.DrawSprite(self:GetPos(), size, size, color_white)
    self:DrawFishingLine(self:FishingLineOrigin())
end
