-- Network bridge for server-authoritative FishingHook particles.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Fishing = MCITEM.Fishing or {}

local Fishing = MCITEM.Fishing
if (tonumber(Fishing.ServerEffectsVersion) or 0) >= 1 then return Fishing end
Fishing.ServerEffectsVersion = 1

local NET_EFFECT = "MCITEM_FishingFX"
util.AddNetworkString(NET_EFFECT)

function Fishing.SendEffect(kind, position, velocity, count, bubble)
    if not isvector(position) then return false end
    net.Start(NET_EFFECT)
        net.WriteUInt(math.Clamp(math.floor(tonumber(kind) or 0), 0, 3), 2)
        net.WriteVector(position)
        net.WriteVector(isvector(velocity) and velocity or vector_origin)
        net.WriteUInt(math.Clamp(math.floor(tonumber(count) or 0), 0, 31), 5)
        net.WriteBool(bubble == true)
    net.SendPVS(position)
    return true
end

return Fishing
