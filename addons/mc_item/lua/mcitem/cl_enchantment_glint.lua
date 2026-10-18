-- Source render pass matching Java 26.2's single enchanted-item glint layer.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.Glint = MCITEM.Glint or {}

local Glint = MCITEM.Glint
local STRENGTH = 0.75
local SPEED = 0.5
-- Java 26.2 applies scale 8 to baked-quad atlas UVs. A normal 16px item occupies
-- 16/512 of the separate item atlas, so the equivalent scale for our standalone
-- 0..1 item texture is 8 * 16 / 512 = 0.25. Special entity models (trident,
-- shield, and similar renderers) use entityGlint's direct 0.5 transform.
local ITEM_TEXTURE_SCALE = 8 * 16 / 512
local ITEM_32_TEXTURE_SCALE = 8 * 32 / 512
local ENTITY_TEXTURE_SCALE = 0.5
local PROFILE_SCALES = {
    item = { ITEM_TEXTURE_SCALE, ITEM_TEXTURE_SCALE },
    item_32 = { ITEM_32_TEXTURE_SCALE, ITEM_32_TEXTURE_SCALE },
    entity = { ENTITY_TEXTURE_SCALE, ENTITY_TEXTURE_SCALE },
}
local ROTATION = math.rad(10)
-- Model materials need their shader flags compiled before StudioRender sees
-- them. A shipped VMT is reliable here; a Lua-created material could report a
-- valid IMaterial while the baked weapon mesh still rendered no override.
local MATERIAL = Material("mcitem/misc/enchanted_glint_model")
local BLEND_AVAILABLE = render.OverrideBlend and BLEND_SRC_COLOR ~= nil
    and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil
local STENCIL_AVAILABLE = render.SetStencilEnable and render.OverrideColorWriteEnable
    and STENCIL_ALWAYS ~= nil and STENCIL_EQUAL ~= nil and STENCIL_REPLACE ~= nil and STENCIL_KEEP ~= nil
local nextMaterialWarning = 0

local function usableMaterial()
    if not MATERIAL or MATERIAL:IsError() then return false end
    if not MATERIAL.GetTexture then return true end
    local texture = MATERIAL:GetTexture("$basetexture")
    if not texture or texture.IsError and texture:IsError() then return false end
    local width = texture.Width and texture:Width() or nil
    local height = texture.Height and texture:Height() or nil
    return not width or not height or width == 128 and height == 128
end

local function warnMaterial()
    local now = RealTime and RealTime() or 0
    if now < nextMaterialWarning then return end
    nextMaterialWarning = now + 10
    if ErrorNoHalt then
        ErrorNoHalt("[MCITEM] model enchantment glint material/texture is unavailable; expected 128x128 VTF\n")
    end
end

local function profileScales(profile)
    local scales = PROFILE_SCALES[profile] or PROFILE_SCALES.item
    return scales[1], scales[2]
end

local function updateTextureTransform(material, profile)
    if not material or material:IsError() or not material.SetMatrix then return end
    local now = RealTime and RealTime() or (CurTime and CurTime() or 0)
    local elapsed = now * 1000 * SPEED * 8
    local offsetU = -(elapsed % 110000) / 110000
    local offsetV = (elapsed % 30000) / 30000
    local cosine, sine = math.cos(ROTATION), math.sin(ROTATION)
    local scaleU, scaleV = profileScales(profile)
    local transform = Matrix()
    transform:SetField(1, 1, cosine * scaleU)
    transform:SetField(1, 2, -sine * scaleV)
    transform:SetField(1, 4, offsetU)
    transform:SetField(2, 1, sine * scaleU)
    transform:SetField(2, 2, cosine * scaleV)
    transform:SetField(2, 4, offsetV)
    material:SetMatrix("$basetexturetransform", transform)
end

local function lightChannel(value)
    return math.Clamp(tonumber(value) or 1, 0, 1)
end

local function restore(lightR, lightG, lightB)
    if BLEND_AVAILABLE then render.OverrideBlend(false) end
    if render.OverrideAlphaWriteEnable then render.OverrideAlphaWriteEnable(false, false) end
    if render.OverrideColorWriteEnable then render.OverrideColorWriteEnable(false, false) end
    if render.SetStencilEnable then render.SetStencilEnable(false) end
    render.MaterialOverride()
    render.SetColorModulation(lightR, lightG, lightB)
    render.SetBlend(1)
end

function Glint.DrawModel(entity, profile, lightR, lightG, lightB, restoreR, restoreG, restoreB)
    if not IsValid(entity) then return false end
    if not usableMaterial() then
        warnMaterial()
        return false
    end
    lightR, lightG, lightB = lightChannel(lightR), lightChannel(lightG), lightChannel(lightB)
    restoreR = lightChannel(restoreR ~= nil and restoreR or lightR)
    restoreG = lightChannel(restoreG ~= nil and restoreG or lightG)
    restoreB = lightChannel(restoreB ~= nil and restoreB or lightB)
    updateTextureTransform(MATERIAL, profile)

    -- The baked item models use alpha-tested cutout quads. Overriding them with
    -- the glint texture removes the base alpha mask, so first mark the visible
    -- pixels with the model's normal material, then restrict the glint redraw to
    -- that stencil. This is the model equivalent of the inventory sprite mask.
    if STENCIL_AVAILABLE then
        render.ClearStencil()
        render.SetStencilEnable(true)
        render.SetStencilWriteMask(255)
        render.SetStencilTestMask(255)
        render.SetStencilReferenceValue(1)
        render.SetStencilCompareFunction(STENCIL_ALWAYS)
        render.SetStencilPassOperation(STENCIL_REPLACE)
        render.SetStencilFailOperation(STENCIL_KEEP)
        render.SetStencilZFailOperation(STENCIL_KEEP)
        render.OverrideColorWriteEnable(true, false)
        if render.OverrideAlphaWriteEnable then render.OverrideAlphaWriteEnable(true, false) end
        entity:DrawModel()
        if render.OverrideAlphaWriteEnable then render.OverrideAlphaWriteEnable(false, false) end
        render.OverrideColorWriteEnable(false, false)
        render.SetStencilCompareFunction(STENCIL_EQUAL)
        render.SetStencilPassOperation(STENCIL_KEEP)
    end

    if BLEND_AVAILABLE then
        render.OverrideBlend(true,
            BLEND_SRC_COLOR, BLEND_ONE, BLENDFUNC_ADD,
            BLEND_ZERO, BLEND_ONE, BLENDFUNC_ADD)
    end
    render.SetColorModulation(STRENGTH * lightR, STRENGTH * lightG, STRENGTH * lightB)
    render.SetBlend(1)
    render.MaterialOverride(MATERIAL)
    entity:DrawModel()
    restore(restoreR, restoreG, restoreB)
    if STENCIL_AVAILABLE then render.ClearStencil() end
    return true
end
