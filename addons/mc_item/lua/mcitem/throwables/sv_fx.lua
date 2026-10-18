-- Compact server-to-client particle event transport. Per-tick trails stay on
-- their entities; only one-shot impacts use this message.

if not SERVER then return end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

local Throwables = MCITEM.Throwables
local NET_FX = "MCITEM_ThrowableFX"

util.AddNetworkString(NET_FX)

function Throwables.BroadcastFX(kind, position, velocity)
    if not isnumber(kind) or not isvector(position) then return false end
    net.Start(NET_FX)
    net.WriteUInt(math.Clamp(math.floor(kind), 0, 15), 4)
    net.WriteVector(position)
    net.WriteVector(isvector(velocity) and velocity or vector_origin)
    if isfunction(net.SendPVS) then
        net.SendPVS(position)
    else
        net.Broadcast()
    end
    return true
end
