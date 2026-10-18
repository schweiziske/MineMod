-- Optional mob-facing Shulker Bullet registration.  This definition reuses
-- MCITEM.Throwables.SpawnConfigured but intentionally does not expose a player
-- weapon or spawn-menu item.

if SERVER then AddCSLuaFile() end

MCITEM = MCITEM or {}
MCITEM.Throwables = MCITEM.Throwables or {}

include("mcitem/throwables/sh_data.lua")

MCITEM.Throwables.RegisterDefinition({
    id = "shulker_bullet",
    name = "Shulker Bullet",
    modelId = "shulker_bullet",
    entityClass = "mcitem_shulker_bullet",
    behavior = "shulker_bullet",
    power = 0,
    uncertainty = 0,
    gravity = 0,
    inertia = 1,
    collisionRadius = 0.15625,
}, {
    registerWeapon = false,
})
