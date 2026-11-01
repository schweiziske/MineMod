include("shared.lua")

local orbMaterial = Material("mcitem/particles/throwable_experience_orb")

function ENT:Initialize()
    local extent = MCITEM.BlockSize() * 0.5
    self:SetRenderBounds(
        Vector(-extent, -extent, -extent),
        Vector(extent, extent, extent)
    )
end

local function orbIcon(value)
    for index, threshold in ipairs(MCITEM.Throwables.ExperienceValues) do
        if value >= threshold then return 11 - index end
    end
    return 0
end

local function sampleLight(position)
    if isfunction(MCITEM.SampleParticleLightRGB) then
        return MCITEM.SampleParticleLightRGB(position, 7)
    end
    local light = MC and MC.API and MC.API.Light
    if light and isfunction(light.SampleRGB) then return light.SampleRGB(position, 7) end
    local source = render.GetLightColor(position)
    return source.x, source.y, source.z
end

local LIGHT_SAMPLE_SECONDS = 0.1
local vertexPosition = Vector(0, 0, 0)

local function vertex(x, y, z, u, v, r, g, b)
    vertexPosition.x, vertexPosition.y, vertexPosition.z = x, y, z
    mesh.Position(vertexPosition)
    mesh.TexCoord(0, u, v)
    mesh.Color(r, g, b, 128)
    mesh.AdvanceVertex()
end

-- Voxel light changes slowly relative to the orb; resample at most every
-- LIGHT_SAMPLE_SECONDS per orb.
local function cachedOrbLight(orb, center)
    local now = RealTime()
    if orb.MCLightSampleExpires and orb.MCLightSampleExpires > now then
        return orb.MCLightR, orb.MCLightG, orb.MCLightB
    end
    local r, g, b = sampleLight(center)
    orb.MCLightR, orb.MCLightG, orb.MCLightB = r, g, b
    orb.MCLightSampleExpires = now + LIGHT_SAMPLE_SECONDS
    return r, g, b
end

function ENT:DrawTranslucent()
    local blockSize = MCITEM.BlockSize()
    local center = self:GetPos()
    center.z = center.z + 0.175 * blockSize
    local eyeAngles = EyeAngles()
    local halfSize = 0.15 * blockSize
    local right = eyeAngles:Right()
    local up = eyeAngles:Up()
    local rx, ry, rz = right.x * halfSize, right.y * halfSize, right.z * halfSize
    local ux, uy, uz = up.x * halfSize, up.y * halfSize, up.z * halfSize
    local cx, cy, cz = center.x, center.y, center.z
    local icon = orbIcon(self:GetExperienceValue())
    local u0, u1 = (icon % 4) * 0.25, (icon % 4 + 1) * 0.25
    local v0, v1 = math.floor(icon / 4) * 0.25, (math.floor(icon / 4) + 1) * 0.25
    local age = self:GetOrbAge() / 2
    local red = math.floor(((math.sin(age) + 1) * 0.5) * 255)
    local green = 255
    local blue = math.floor(((math.sin(age + 4.1887903) + 1) * 0.1) * 255)
    local litR, litG, litB = cachedOrbLight(self, center)
    red = math.Clamp(math.floor(red * litR), 0, 255)
    green = math.Clamp(math.floor(green * litG), 0, 255)
    blue = math.Clamp(math.floor(blue * litB), 0, 255)

    render.SetMaterial(orbMaterial)
    mesh.Begin(MATERIAL_QUADS, 1)
    vertex(cx - rx - ux, cy - ry - uy, cz - rz - uz, u0, v1, red, green, blue)
    vertex(cx + rx - ux, cy + ry - uy, cz + rz - uz, u1, v1, red, green, blue)
    vertex(cx + rx + ux, cy + ry + uy, cz + rz + uz, u1, v0, red, green, blue)
    vertex(cx - rx + ux, cy - ry + uy, cz - rz + uz, u0, v0, red, green, blue)
    mesh.End()
end
