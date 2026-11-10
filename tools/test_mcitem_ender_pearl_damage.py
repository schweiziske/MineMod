"""Focused LuaJIT regression: python tools/test_mcitem_ender_pearl_damage.py.

Runs the production pearl, MineMod combat, protection and potion adapters.
Java 26.2 references: ThrownEnderpearl.onHit/onHitEntity, Player.hurtServer,
LivingEntity.hurtServer/getDamageAfterMagicAbsorb, CombatRules, damage_type
tags is_fall/bypasses_armor/no_knockback, and protection/feather_falling JSON.
Source engine physics, networking and inventory storage are test doubles.
"""

from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
ITEM = "addons/mc_item/lua/mcitem/"
BOOT = r'''
SERVER, CLIENT = true, false
bit = require("bit")
DMG_GENERIC, DMG_FALL, DMG_DROWN, DMG_POISON = 0, 32, 16384, 131072
DMG_BURN, DMG_SLOWBURN, DMG_CLUB, DMG_SLASH = 8, 2097152, 128, 4
DMG_BULLET, DMG_BUCKSHOT, DMG_BLAST, DMG_RADIATION = 2, 536870912, 64, 262144
OBS_MODE_NONE = 0
FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED = 1, 2, 4
now, scale, contacts, fx, sounds, armorWear, armorCalls = 100, 5, 0, 0, 0, 0, 0
function CurTime() return now end
function isfunction(v) return type(v) == "function" end
function istable(v) return type(v) == "table" end
function isstring(v) return type(v) == "string" end
function isnumber(v) return type(v) == "number" end
function string.StartWith(value,prefix) return value:sub(1,#prefix)==prefix end
function IsValid(v) return type(v) == "table" and v.valid == true end
function math.Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
function math.Rand() return 0.9 end
function CreateConVar() return { GetFloat = function() return scale end } end
hook = { events = {}, reverse = false }
function hook.Add(event, id, fn)
    hook.events[event] = hook.events[event] or {}
    hook.events[event][id] = fn
end
function hook.Remove(event, id)
    if hook.events[event] then hook.events[event][id] = nil end
end
function hook.Run(event, ...)
    local ids = {}
    for id in pairs(hook.events[event] or {}) do ids[#ids+1] = id end
    table.sort(ids, function(a,b) if hook.reverse then return a > b end return a < b end)
    for _, id in ipairs(ids) do
        local result = hook.events[event][id](...)
        if result ~= nil then return result end
    end
end
timer = { Simple = function() end, Create = function() end, Remove = function() end }
util = { AddNetworkString = function() end }
net = { Receive = function() end }
local V = {}; V.__index = V
function Vector(x,y,z) return setmetatable({x=x or 0,y=y or 0,z=z or 0},V) end
function isvector(v) return getmetatable(v) == V end
function V.__add(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
function V.__sub(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
function V.__mul(a,b) return Vector(a.x*b,a.y*b,a.z*b) end
function V:LengthSqr() return self.x*self.x+self.y*self.y+self.z*self.z end
function V:Normalize() local l=math.sqrt(self:LengthSqr()); self.x,self.y,self.z=self.x/l,self.y/l,self.z/l end
function V:GetNormalized() local v=Vector(self.x,self.y,self.z); v:Normalize(); return v end
function V:Dot(v) return self.x*v.x+self.y*v.y+self.z*v.z end
vector_origin, angle_zero, NULL = Vector(), {}, {}
local D = {}; D.__index = D
function DamageInfo() return setmetatable({amount=0,kind=0,force=vector_origin}, D) end
function D:SetDamage(v) self.amount=v end
function D:GetDamage() return self.amount end
function D:ScaleDamage(v) self.amount=self.amount*v end
function D:SetDamageType(v) self.kind=v end
function D:GetDamageType() return self.kind end
function D:IsDamageType(v) return bit.band(self.kind,v) ~= 0 end
function D:SetAttacker(v) self.attacker=v end
function D:GetAttacker() return self.attacker end
function D:SetInflictor(v) self.inflictor=v end
function D:GetInflictor() return self.inflictor end
function D:SetDamagePosition(v) self.pos=v end
function D:SetDamageForce(v) self.force=v end
function D:GetDamageForce() return self.force end
local E = {}; E.__index = E
function entity(kind)
    return setmetatable({valid=true,kind=kind or "player",health=100,mode="survival",
        position=Vector(),velocity=Vector(2,3,-10),angles={},enchantments={},effects={},
        record={equipment={}},armor=0,absorption=0,suit=100,fall=900,takes=0},E)
end
function E:IsPlayer() return self.kind=="player" end
function E:IsNPC() return self.kind=="npc" end
function E:IsNextBot() return false end
function E:IsWeapon() return false end
function E:IsWorld() return self.kind=="world" end
function E:Alive() return self.health>0 end
function E:Health() return self.health end
function E:HasGodMode() return self.god==true end
function E:GetObserverMode() return self.observer or 0 end
function E:GetNWString(_, default) return self.mode or default end
function E:GetNWFloat(_, default) return default end
function E:SetNWFloat() end
function E:GetActiveWeapon() return NULL end
function E:GetPos() return self.position end
function E:WorldSpaceCenter() return self.position end
function E:SetPos(v) self.position=v end
function E:GetAngles() return self.angles end
function E:EyeAngles() return {Forward=function() return Vector(1,0,0) end} end
function E:InVehicle() return self.vehicle==true end
function E:ExitVehicle() self.vehicle=false end
function E:SetSaveValue(name,value) assert(name=="m_flFallVelocity"); self.fall=value end
function E:GetVelocity() return self.velocity end
function E:SetVelocity(v) self.velocity=v end
function E:IsOnGround() return false end
function E:GetOwner() return self.owner end
function E:GetClass() return self.kind end
function E:TakeDamageInfo(damage)
    self.takes=self.takes+1
    if self.raiseDamage then error("engine failure") end
    -- A different engine userdata wrapper can reach the callbacks. Production
    -- context push/pop must still identify this as pearl damage.
    local info = damage
    if self.rewrap then
        info=DamageInfo()
        for k,v in pairs(damage) do info[k]=v end
    end
    self.lastInfo=info
    local blocked=hook.Run("EntityTakeDamage", self, info)==true
    local taken=not blocked and not self.god and info:GetDamage()>0
    if taken then
        self.health=self.health-info:GetDamage()
        -- Source suit armor must be bypassed by DMG_FALL.
        if not info:IsDamageType(DMG_FALL) then self.suit=self.suit-1 end
    end
    hook.Run("PostEntityTakeDamage",self,info,taken)
end
world=entity("world"); game={GetWorld=function() return world end}
MC={ SV={}, BlockPhysics={PlayerState={}} }
MC.SV.PlayerIsCreative=function(p) return p.mode=="creative" end
MC.SV.GetPlayerInventoryRecord=function(p) return p.record end
MC.SV.PlayerEquipmentTotals=function(record) return record.armor or 0, 0, 0 end
MC.SV.DamagePlayerArmor=function() armorWear=armorWear+1 end
MC.ArmorDamageAfterAbsorb=function(amount) armorCalls=armorCalls+1; return amount*0.2 end
MCITEM={EnchantmentRuntime={WindBurstImpulseStates={}},Potions={}}
MCITEM.BlockSize=function() return 36.5 end
MCITEM.EnchantmentRuntime.GetArmorEnchantmentTotal=function(p,id) return p.enchantments[id] or 0 end
MCITEM.EnchantmentRuntime.GetEquipmentLevel=function() return 0 end
MCITEM.Potions.GetEffect=function(p,id) return p.effects[id] end
MCITEM.Potions.HasEffect=function(p,id) return p.effects[id]~=nil end
MCITEM.Potions.GetAbsorptionAmount=function(p) return p.absorption end
MCITEM.Potions.SetAbsorptionAmount=function(p,value) p.absorption=value end
hook.Add("MCITEM.ProjectileHitEntity","test.contacts",function() contacts=contacts+1 end)
function pearl(p, target)
    local shot=entity("pearl"); shot.owner=p
    shot.MCTickStartPosition=Vector(40,50,60)
    shot.MCProjectileVelocity=Vector(1,0,0)
    MCITEM.Throwables.Behavior("ender_pearl").OnHit(shot,{Entity=target or world,HitPos=Vector(41,51,61)})
    return shot
end
function ordinary(p, amount)
    local info=DamageInfo(); info:SetDamage(amount); info:SetAttacker(world); info:SetInflictor(world)
    p:TakeDamageInfo(info)
end
'''


def runtime(integrated=True, reverse=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(BOOT)
    modules = [ITEM + "sh_tuning.lua", ITEM + "enchantments/sv_gameplay.lua",
               ITEM + "potions/sh_attributes.lua", ITEM + "potions/status/sv_attributes.lua"]
    if integrated:
        modules.append("addons/mc_game/lua/mcgame/inventory/sv_combat.lua")
    modules += [ITEM + "throwables/sh_contract.lua", ITEM + "throwables/sv_damage.lua",
                ITEM + "throwables/behaviors/sv_ender_pearl.lua"]
    for name in modules:
        lua.execute((ROOT / name).read_text(encoding="utf-8"), name=name)
    lua.execute('''
        MCITEM.Throwables.BroadcastFX=function() fx=fx+1 end
        MCITEM.Throwables.PlayPearlTeleport=function() sounds=sounds+1 end
        MCITEM.Throwables.SpawnMCEndermite=function() error("unexpected spawn") end
    ''')
    lua.globals().hook.reverse = reverse
    return lua


class PearlDamageTests(unittest.TestCase):
    def test_mitigation_matrix_both_hook_orders(self):
        profiles = [
            ("bare", "", 25),
            ("armor only", "p.record.armor=20", 25),
            ("protection IV", "p.enchantments.protection=4", 21),
            ("feather IV", "p.enchantments.feather_falling=4", 13),
            ("four protection IV", "p.enchantments.protection=16", 9),
            ("protection cap", "p.enchantments.protection=16; p.enchantments.feather_falling=4", 5),
            ("projectile protection", "p.enchantments.projectile_protection=16", 25),
            ("resistance I", "p.effects.resistance={amplifier=0}", 20),
            ("resistance II", "p.effects.resistance={amplifier=1}", 15),
            ("resistance V", "p.effects.resistance={amplifier=4}", 0),
            ("combined", "p.record.armor=20; p.enchantments.feather_falling=4; p.effects.resistance={amplifier=0}", 10.4),
            ("absorption last", "p.enchantments.feather_falling=4; p.effects.resistance={amplifier=0}; p.absorption=2", 0.4),
            ("slow falling", "p.effects.slow_falling={amplifier=0}", 25),
        ]
        for integrated in (True, False):
            for reverse in (False, True):
                for label, setup, expected in profiles:
                    with self.subTest(label=label, integrated=integrated, reverse=reverse):
                        lua = runtime(integrated, reverse)
                        lua.execute("p=entity()\n" + setup + "\npearl(p)")
                        self.assertAlmostEqual(lua.eval("100-p.health"), expected)
                        self.assertEqual(lua.eval("armorWear+armorCalls"), 0)
                        self.assertEqual(lua.eval("p.suit"), 100)
                        self.assertEqual(lua.eval("contacts"), 0)
                        self.assertTrue(lua.eval("p.lastInfo:GetAttacker()==world and p.lastInfo:GetInflictor()==world"))

    def test_scale_and_fractional_damage(self):
        lua = runtime()
        lua.execute("scale=1; p=entity(); pearl(p)")
        self.assertEqual(lua.eval("p.health"), 95)
        lua.execute("now=101; scale=2.5; pearl(p)")
        self.assertEqual(lua.eval("p.health"), 82.5)

    def test_creative_spectator_god_dead(self):
        for setup in ("p.mode='creative'", "p.mode='spectator'", "p.observer=4", "p.god=true", "p.health=0"):
            lua = runtime()
            lua.execute("p=entity(); " + setup + "; before=p.health; pearl(p)")
            self.assertEqual(lua.eval("p.health"), lua.eval("before"))
            self.assertEqual(lua.eval("p.takes"), 0)

    def test_cooldown_boundaries_and_nonextending_rejects(self):
        lua = runtime()
        lua.execute("p=entity(); pearl(p); now=100.2; pearl(p); now=100.499; pearl(p)")
        self.assertEqual(lua.eval("p.health"), 75)
        self.assertEqual(lua.eval("p.position.z"), 60)
        lua.execute("now=100.5; pearl(p)")
        self.assertEqual(lua.eval("p.health"), 50)

    def test_previous_damage_compares_before_mitigation(self):
        for reverse in (False, True):
            for previous, expected in ((10, 15), (25, 0), (40, 0)):
                lua = runtime(reverse=reverse)
                lua.execute(f"p=entity(); p.record.armor=20; p.enchantments.protection=4; ordinary(p,{previous}); before=p.health; now=100.2; pearl(p)")
                self.assertAlmostEqual(lua.eval("before-p.health"), expected * 0.84)

    def test_absorbed_and_resisted_hits_still_start_window(self):
        for setup in ("p.absorption=20", "p.effects.resistance={amplifier=4}"):
            lua = runtime()
            lua.execute("p=entity(); " + setup + "; pearl(p); p.absorption=0; p.effects={}; now=100.2; pearl(p)")
            self.assertEqual(lua.eval("p.health"), 100)

    def test_absorbed_ordinary_damage_starts_window(self):
        for reverse in (False, True):
            lua = runtime(reverse=reverse)
            lua.execute("p=entity(); p.absorption=20; ordinary(p,25); p.absorption=0; now=100.2; pearl(p)")
            self.assertEqual(lua.eval("p.health"), 100)

    def test_cancelled_source_damage_does_not_suppress_pearl(self):
        for reverse in (False, True):
            lua = runtime(reverse=reverse)
            lua.execute('''p=entity()
                hook.Add('EntityTakeDamage','zz.test.cancel',function(_,d)
                    if not d:IsDamageType(DMG_FALL) then return true end
                end)
                ordinary(p,40); now=100.1; pearl(p)''')
            self.assertEqual(lua.eval("p.health"), 75)

    def test_before_equipment_immunity_does_not_suppress_pearl(self):
        for reverse in (False, True):
            lua = runtime(reverse=reverse)
            lua.execute('''p=entity()
                hook.Add('MCITEM.DamageBeforeEquipmentMitigation','test.immunity',function(_,d)
                    if not d:IsDamageType(DMG_FALL) then d:SetDamage(0); return true end
                end)
                ordinary(p,40); now=100.1; pearl(p)''')
            self.assertEqual(lua.eval("p.health"), 75)

    def test_other_source_damage_is_unchanged(self):
        lua = runtime()
        lua.execute("p=entity(); ordinary(p,40); now=100.1; ordinary(p,40)")
        self.assertEqual(lua.eval("p.health"), 20)

    def test_fire_resistance_immunity_does_not_start_window(self):
        for reverse in (False, True):
            lua = runtime(reverse=reverse)
            lua.execute('''p=entity(); p.effects.fire_resistance={amplifier=0}
                d=DamageInfo(); d:SetDamage(25); d:SetDamageType(DMG_BURN)
                d:SetAttacker(world); d:SetInflictor(world); p:TakeDamageInfo(d)
                p.effects={}; now=100.1; pearl(p)''')
            self.assertEqual(lua.eval("p.health"), 75)

    def test_source_strength_history_uses_post_modifier_boundary(self):
        # mc_game supplies damageBeforeArmor after all before hooks and shield
        # handling. The unordered history/potion listeners must consume that
        # authoritative value instead of emulating/inverting either formula.
        for reverse in (False, True):
            lua = runtime(reverse=reverse)
            lua.execute('''p=entity(); p.record.armor=20
                attacker=entity(); attacker.effects.strength={amplifier=0}
                weapon=entity('source_weapon'); weapon.IsWeapon=function() return true end
                d=DamageInfo(); d:SetDamage(10); d:SetDamageType(DMG_CLUB)
                d:SetAttacker(attacker); d:SetInflictor(weapon); p:TakeDamageInfo(d)
                before=p.health; now=100.1; pearl(p)''')
            # Actual damage is (10 + 3 Java HP * 5) * armor's 0.2 = 5 HP.
            self.assertEqual(lua.eval("before"), 95)
            self.assertEqual(lua.eval("before-p.health"), 0, f"reverse={reverse}")

    def test_shield_block_does_not_cancel_pearl_or_wear_equipment(self):
        for reverse in (False, True):
            lua = runtime(reverse=reverse)
            lua.execute('''p=entity()
                p.record.equipment.offhand={item='minecraft:shield',count=1}
                p.record.itemUse={kind='shield',hand='offhand',startedAt=0}
                MC.ItemShieldSpec=function() return {horizontalAngle=90,blockDelay=0} end
                shot=entity('source_projectile'); shot.MCProjectile=true; shot:SetPos(Vector(20,0,0))
                d=DamageInfo(); d:SetDamage(40); d:SetAttacker(world); d:SetInflictor(shot)
                p:TakeDamageInfo(d); before=p.health
                MC.ItemShieldDurabilityDamage=function() error('pearl wore shield') end
                now=100.1; pearl(p)''')
            self.assertEqual(lua.eval("before"), 100)
            self.assertEqual(lua.eval("p.health"), 75)
            lua.execute("now=100.5; pearl(p)")
            self.assertEqual(lua.eval("p.health"), 50)

    def test_zero_damage_contact_does_not_block_teleport_cost(self):
        lua = runtime()
        lua.execute("p=entity(); MCITEM.Throwables.MarkThrowableInvulnerability(p,{}); now=100.1; pearl(p); now=100.2; pearl(p)")
        self.assertEqual(lua.eval("p.health"), 75)
        lua.execute("now=100.5; pearl(p)")
        self.assertEqual(lua.eval("p.health"), 50)

    def test_failed_sleeping_and_nonplayer_teleports(self):
        for setup in ("p.TeleportFromMCEnderPearl=function() return false end", "p.IsMCSleeping=function() return true end"):
            lua = runtime()
            lua.execute("p=entity(); " + setup + "; pearl(p)")
            self.assertEqual(lua.eval("p.health"), 100)
            self.assertEqual(lua.eval("p.position.z"), 0)
            self.assertEqual(lua.eval("p.fall"), 900)
        lua = runtime()
        lua.execute("p=entity('npc'); pearl(p)")
        self.assertEqual(lua.eval("p.health"), 100)
        self.assertEqual(lua.eval("p.position.z"), 60)

    def test_success_resets_fall_and_impulse_preserves_velocity(self):
        lua = runtime()
        lua.execute('''p=entity(); p.vehicle=true
            MCITEM.EnchantmentRuntime.WindBurstImpulseStates[p]={}
            MC.BlockPhysics.PlayerState[p]={fallApexZ=999,lastFallDistance=100,lastLandingAt=now}
            pearl(p)''')
        self.assertEqual(lua.eval("p.fall"), 0)
        self.assertFalse(lua.eval("p.vehicle"))
        self.assertEqual(lua.eval("p.velocity.z"), -10)
        self.assertTrue(lua.eval("MCITEM.EnchantmentRuntime.WindBurstImpulseStates[p]==nil"))
        self.assertTrue(lua.eval("MC.BlockPhysics.PlayerState[p].fallApexZ==nil"))

    def test_metadata_handles_new_wrappers_and_errors(self):
        lua = runtime()
        lua.execute("p=entity(); p.rewrap=true; pearl(p); now=100.1; pearl(p)")
        self.assertEqual(lua.eval("p.health"), 75)
        self.assertTrue(lua.eval("MC.SV.GetCombatDamageContext(p,p.lastInfo)==nil"))
        lua.execute("now=101; p.raiseDamage=true; ok,err=pcall(pearl,p)")
        self.assertFalse(lua.eval("ok"))
        self.assertIn("engine failure", lua.eval("err"))
        self.assertTrue(lua.eval("MC.SV.GetCombatDamageContext(p,p.lastInfo)==nil"))

    def test_entity_contact_source_and_feedback(self):
        lua = runtime()
        lua.execute('''p=entity(); target=entity('npc')
            target.ApplyMCThrowableImpact=function(_,shot,ctx) contactSource=ctx.damageSource; return true end
            pearl(p,target)''')
        self.assertEqual(lua.eval("contactSource"), "minecraft:thrown")
        self.assertEqual(lua.eval("target.health"), 100)
        self.assertEqual(lua.eval("contacts"), 1)
        self.assertEqual(lua.eval("p.health"), 75)


if __name__ == "__main__":
    unittest.main(verbosity=2)
