-- Minecraft-style custom-name labels plus the Dinnerbone / Grumm render-only
-- inversion. NameTagItem does not set customNameVisible, so ordinary mobs show
-- the label only while they are the crosshair-picked entity; the renderer still
-- enforces Java's 64-block name-tag distance ceiling.

if not CLIENT then return end

MCITEM = MCITEM or {}
MCITEM.NameTags = MCITEM.NameTags or {}

local NameTags = MCITEM.NameTags
local LABEL_BASE_SCALE = 0.055
local LABEL_FONT_SCALE = 6
local LABEL_TEXT_OFFSET_Y = LABEL_FONT_SCALE
local LABEL_LIGHT_INTERVAL = 0.1
local LABEL_SCALE_DEFAULT = 2.5
local LABEL_SCALE_REVISION = 1
local LABEL_SCALE_CVAR = CreateClientConVar(
    "mcitem_name_tag_scale", tostring(LABEL_SCALE_DEFAULT), true, false,
    "Minecraft name-tag world-size multiplier", 0.5, 3
)
local LABEL_SCALE_REVISION_CVAR = CreateClientConVar(
    "mcitem_name_tag_scale_revision", "0", true, false,
    "Internal migration revision for the Minecraft name-tag scale", 0, LABEL_SCALE_REVISION
)
local inverted = setmetatable({}, { __mode = "k" })
local lightingCache = setmetatable({}, { __mode = "k" })

surface.CreateFont("MCITEMNameTagFallback", {
    font = "Roboto",
    size = 56,
    weight = 500,
    antialias = false,
    extended = true,
})

local function labelScale()
    local multiplier = LABEL_SCALE_CVAR and LABEL_SCALE_CVAR.GetFloat
        and LABEL_SCALE_CVAR:GetFloat() or LABEL_SCALE_DEFAULT
    return LABEL_BASE_SCALE * math.Clamp(tonumber(multiplier) or LABEL_SCALE_DEFAULT, 0.5, 3)
end

local function migrateLabelScaleDefault()
    if not RunConsoleCommand or not LABEL_SCALE_REVISION_CVAR then return end
    local revision = LABEL_SCALE_REVISION_CVAR.GetInt and LABEL_SCALE_REVISION_CVAR:GetInt()
        or LABEL_SCALE_REVISION_CVAR.GetFloat and LABEL_SCALE_REVISION_CVAR:GetFloat() or 0
    if (tonumber(revision) or 0) >= LABEL_SCALE_REVISION then return end

    local current = LABEL_SCALE_CVAR and LABEL_SCALE_CVAR.GetFloat and LABEL_SCALE_CVAR:GetFloat()
    if math.abs((tonumber(current) or LABEL_SCALE_DEFAULT) - 1.2) < 0.0001 then
        RunConsoleCommand("mcitem_name_tag_scale", tostring(LABEL_SCALE_DEFAULT))
    end
    RunConsoleCommand("mcitem_name_tag_scale_revision", tostring(LABEL_SCALE_REVISION))
end

if timer and timer.Simple then timer.Simple(0, migrateLabelScaleDefault) else migrateLabelScaleDefault() end

local function minecraftFont()
    local font = MC and MC.API and MC.API.Font
    if not font or not isfunction(font.Measure) or not isfunction(font.Draw) then return nil end
    return font
end

local function sampleLabelColor(target, position)
    local now = RealTime()
    local cached = lightingCache[target]
    if cached and cached.nextSample > now then return cached.color end

    local r, g, b = 1, 1, 1
    local light = MC and MC.API and MC.API.Light
    if light and isfunction(light.SampleRGB) then
        -- EntityRenderer submits the visible name-tag pass with emission 2.
        -- Sample the same world-space attachment through MCSWEP's public API.
        r, g, b = light.SampleRGB(position, 2)
    end
    local color = Color(
        math.floor(math.Clamp(tonumber(r) or 1, 0, 1) * 255 + 0.5),
        math.floor(math.Clamp(tonumber(g) or 1, 0, 1) * 255 + 0.5),
        math.floor(math.Clamp(tonumber(b) or 1, 0, 1) * 255 + 0.5),
        255
    )
    lightingCache[target] = { nextSample = now + LABEL_LIGHT_INTERVAL, color = color }
    return color
end

local function blockSize()
    local coords = MC and MC.API and MC.API.Coords
    return coords and isfunction(coords.BlockSize) and tonumber(coords.BlockSize()) or 36.5
end

local function setUpsideDown(target, enabled)
    if enabled then
        local mins, maxs = target:OBBMins(), target:OBBMaxs()
        local matrix = Matrix()
        -- Minecraft translates by entity height and then rotates 180 degrees
        -- around its forward axis. Source's equivalent local axis is roll.
        matrix:SetAngles(Angle(0, 0, 180))
        matrix:SetTranslation(Vector(0, 0, mins.z + maxs.z))
        target:EnableMatrix("RenderMultiply", matrix)
        inverted[target] = true
    elseif inverted[target] then
        target:DisableMatrix("RenderMultiply")
        inverted[target] = nil
    end
end

timer.Create("MCITEM.NameTags.UpdateMagicNames", 0.2, 0, function()
    for _, target in ipairs(ents.GetAll()) do
        if NameTags.IsSupportedTarget(target) then
            local name, present = NameTags.GetEntityCustomName(target)
            setUpsideDown(target, present and NameTags.IsUpsideDownName(name) or false)
        elseif inverted[target] then
            setUpsideDown(target, false)
        end
    end
end)

hook.Add("PostDrawTranslucentRenderables", "MCITEM.NameTags.DrawCrosshairLabel", function(depth, skybox)
    if skybox then return end
    local player = LocalPlayer()
    if not IsValid(player) then return end
    local maximum = blockSize() * 64
    -- Use the same ray-versus-collision-box fallback as the authoritative
    -- interaction path.  BMB SOLID_BBOX entities are not always returned by a
    -- plain MASK_SHOT trace, but the label must still appear only after the
    -- crosshair actually enters their collision box.
    local target = NameTags.FindAimTarget(player, nil, maximum, true)
    if not IsValid(target) then return end
    local name, present = NameTags.GetEntityCustomName(target)
    if not present then return end

    if player:EyePos():DistToSqr(target:WorldSpaceCenter()) >= maximum * maximum then return end

    local _, maxs = target:OBBMins(), target:OBBMaxs()
    local position = target:LocalToWorld(Vector(0, 0, maxs.z + blockSize() * 0.28))
    local textColor = sampleLabelColor(target, position)
    local angle = EyeAngles()
    angle:RotateAroundAxis(angle:Right(), 90)
    angle:RotateAroundAxis(angle:Up(), -90)

    cam.Start3D2D(position, angle, labelScale())
        local font = minecraftFont()
        if font then
            local width = font.Measure(name, "default") * LABEL_FONT_SCALE
            local height = (isfunction(font.LineHeight) and font.LineHeight() or 9) * LABEL_FONT_SCALE
            local padding = LABEL_FONT_SCALE
            surface.SetDrawColor(0, 0, 0, 64)
            surface.DrawRect(-width * 0.5 - padding, -height * 0.5 - padding,
                width + padding * 2, height + padding * 2)
            font.Draw(name, 0, LABEL_TEXT_OFFSET_Y, {
                font = "default",
                scale = LABEL_FONT_SCALE,
                color = textColor,
                align = TEXT_ALIGN_CENTER,
                verticalAlign = TEXT_ALIGN_CENTER,
                shadow = false,
            })
        else
            surface.SetFont("MCITEMNameTagFallback")
            local width, height = surface.GetTextSize(name)
            surface.SetDrawColor(0, 0, 0, 64)
            surface.DrawRect(-width * 0.5 - 5, -height * 0.5 - 2, width + 10, height + 4)
            draw.SimpleText(name, "MCITEMNameTagFallback", 0, LABEL_TEXT_OFFSET_Y, textColor,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    cam.End3D2D()
end)

hook.Add("ShutDown", "MCITEM.NameTags.ClearMagicNames", function()
    lightingCache = setmetatable({}, { __mode = "k" })
    for target in pairs(inverted) do
        if IsValid(target) then target:DisableMatrix("RenderMultiply") end
    end
end)
