"""Run production survival HUD rendering against a LuaJIT drawing recorder.

python tools/test_survival_hud.py
Game rendering/network delivery are mocked; sprite pixels are read from disk.
"""
from pathlib import Path
import hashlib
import unittest

from lupa import luajit21
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LUA = ROOT / 'addons/mc_game/lua'
MATERIALS = ROOT / 'addons/mc_game/materials/mc/gui'

BOOT = r'''
SERVER, CLIENT = false, true
now, realNow = 10, 10
function CurTime() return now end
function RealTime() return realNow end
function IsValid(v) return type(v)=='table' and v.valid==true end
function istable(v) return type(v)=='table' end
function isfunction(v) return type(v)=='function' end
function isstring(v) return type(v)=='string' end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a or 255} end
function math.Clamp(v,a,b) return math.max(a,math.min(b,v)) end
function ScrW() return 960 end
function ScrH() return 540 end
hooks={}
hook={Add=function(event,id,fn) hooks[event]=hooks[event] or {}; hooks[event][id]=fn end}
function hook.Run(event,...)
    for _,fn in pairs(hooks[event] or {}) do local result=fn(...); if result~=nil then return result end end
end
local hand={valid=true,GetClass=function() return 'mc_item_hand' end}
p={valid=true,health=100,maxHealth=100,absorption=0,food=20,saturation=5,effects={},alive=true,hurtUntil=0}
function p:Alive() return self.alive end
function p:IsPlayer() return true end
function p:GetActiveWeapon() return hand end
function p:Health() return self.health end
function p:GetMaxHealth() return self.maxHealth end
function p:GetNW2Float(key,default)
    if key=='MCITEMAbsorptionAmount' then return self.absorption end
    if key=='mc_hud_hurt_until' then return self.hurtUntil end
    return default
end
function p:SetNW2Float(key,value) if key=='mc_hud_hurt_until' then self.hurtUntil=value end end
function p:GetNWInt(key,default) if key=='mc_food_level' then return self.food end return default end
function p:GetNWFloat(key,default) if key=='mc_food_saturation' then return self.saturation end return default end
function p:GetNW2String() return tostring(self.statusRevision or 0) end
function LocalPlayer() return p end
util={JSONToTable=function() return p.effects end}
MCITEM={Potions={ClientEffects=function(entity) return entity.effects end}}
MC={API={GameMode={Get=function() return 'survival' end}},InventoryUI={}}
function MC.NewLegacyRandom() return {NextInt=function(_,n) return n-1 end} end
local UI=MC.InventoryUI
function UI.HUDScale() return 2 end
function UI.GetGuiMaterial(name)
    assert(MC.GeneratedGuiSpriteData.sprites[name], 'unregistered GUI sprite: '..name)
    return name
end
function UI.WithPointFiltering(fn) fn() end
draws={}
function UI.DrawTexture(name,x,y,w,h) draws[#draws+1]={name=name,x=x,y=y,w=w,h=h} end
function UI.DrawText() end
function frame(t)
    now=t or now; realNow=now; draws={}
    hooks.HUDPaint.mc_inventory_survival_status()
    return draws
end
function setEffects(...)
    p.effects={}
    p.statusRevision=(p.statusRevision or 0)+1
    for _,id in ipairs({...}) do p.effects[#p.effects+1]={id=id,infinite=true,showIcon=false,visible=false} end
end
'''


def runtime():
    lua = luajit21.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(BOOT)
    for path in ['mcgame/generated/cl_generated_gui_sprites.lua',
                 'mcgame/generated/cl_generated_survival_hud_sprites.lua',
                 'mcgame/inventory/sh_survival_hud.lua',
                 'mcgame/inventory/ui/cl_effects.lua',
                 'mcgame/inventory/ui/cl_survival_hud.lua']:
        lua.execute((LUA / path).read_text(encoding='utf-8'))
    return lua


class HUDTests(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()

    def run_lua(self, code):
        self.lua.execute(code)

    def names(self, t=10):
        return [entry['name'] for entry in self.lua.globals().frame(t).values()]

    def test_status_priority_and_hidden_effect_icons(self):
        self.run_lua("p.absorption=4; setEffects('poison','wither','hunger')")
        names = self.names()
        self.assertIn('sprites/hud/heart/poisoned_full', names)
        self.assertIn('sprites/hud/heart/absorbing_full', names)
        self.assertNotIn('sprites/hud/heart/withered_full', names)
        self.assertIn('sprites/hud/food_empty_hunger', names)
        self.assertIn('sprites/hud/food_full_hunger', names)

    def test_wither_also_changes_absorption_and_half_hearts(self):
        self.run_lua("p.health=95; p.absorption=3; setEffects('wither')")
        names = self.names()
        self.assertEqual(names.count('sprites/hud/heart/withered_full'), 10)
        self.assertEqual(names.count('sprites/hud/heart/withered_half'), 2)
        self.assertFalse(any('/absorbing_' in name for name in names))

    def test_hunger_half_and_empty_icons_then_expiry(self):
        self.run_lua("p.food=3; p.effects={{id='hunger',expiresAt=11,showIcon=false}}")
        names = self.names(10)
        self.assertEqual(names.count('sprites/hud/food_empty_hunger'), 10)
        self.assertEqual(names.count('sprites/hud/food_full_hunger'), 1)
        self.assertEqual(names.count('sprites/hud/food_half_hunger'), 1)
        expired = self.names(11)
        self.assertFalse(any('_hunger' in name for name in expired))
        self.assertEqual(expired.count('sprites/hud/food_half'), 1)

    def test_effect_removal_and_fallback_status_reader(self):
        self.run_lua("MCITEM=nil; setEffects('poison')")
        self.assertIn('sprites/hud/heart/poisoned_full', self.names())
        self.run_lua('setEffects()')
        self.assertNotIn('sprites/hud/heart/poisoned_full', self.names(10.1))

    def test_gold_loss_and_expiry_have_no_history_or_blink(self):
        self.run_lua('p.absorption=4')
        self.names()
        self.run_lua('p.absorption=3; p.hurtUntil=11')
        names = self.names(10.2)
        self.assertEqual(names.count('sprites/hud/heart/absorbing_full'), 1)
        self.assertEqual(names.count('sprites/hud/heart/absorbing_half'), 1)
        self.assertFalse(any('_blinking' in name for name in names))
        self.run_lua('p.absorption=0')
        names = self.names(10.4)
        self.assertEqual(names.count('sprites/hud/heart/container'), 10)
        self.assertFalse(any('/absorbing_' in name or '_blinking' in name for name in names))

    def test_red_damage_blinks_containers_and_old_typed_health_only(self):
        self.run_lua("p.absorption=4; setEffects('poison')")
        self.names(10)
        self.run_lua('p.health=95')
        self.names(10.1)
        names = self.names(10.3)
        self.assertEqual(names.count('sprites/hud/heart/container_blinking'), 12)
        self.assertEqual(names.count('sprites/hud/heart/poisoned_full_blinking'), 10)
        self.assertEqual(names.count('sprites/hud/heart/absorbing_full'), 2)
        self.assertFalse(any('/absorbing_' in name and '_blinking' in name for name in names))
        self.assertFalse(any('_blinking' in name for name in self.names(11.2)))

    def test_healing_blink_requires_recent_hurt(self):
        self.run_lua('p.health=50')
        self.names(10)
        self.run_lua('p.health=60')
        self.names(10.1)
        self.assertFalse(any('_blinking' in name for name in self.names(10.2)))
        self.run_lua('p.hurtUntil=12; p.health=70')
        self.names(11.2)
        self.assertTrue(any('_blinking' in name for name in self.names(11.25)))

    def test_regeneration_bob_and_high_max_health_layout(self):
        self.run_lua("setEffects('regeneration'); p.maxHealth=200; p.health=200; p.absorption=3")
        draws = list(self.lua.globals().frame(10).values())
        layout = self.lua.globals().MC.BuildSurvivalHeartLayout(200, 200, 200, 3)
        self.assertEqual(layout['containerCount'], 22)
        self.assertEqual(layout['rowCount'], 3)
        # tick 200 % ceil(40+5) = 20 lies in absorption: only health bobs.
        self.assertEqual(len([d for d in draws if d['name'].endswith('/container')]), 22)
        self.run_lua('p.maxHealth=100; p.health=100; p.absorption=0')
        # Restart tracking to remove previous ordinary-health history.
        self.run_lua('p.alive=false; frame(10.9); p.alive=true')
        draws = list(self.lua.globals().frame(11.3).values())
        # tick 226 % 25 = 1 -> one container moves up two GUI pixels.
        hearts = [d for d in draws if d['name'].endswith('/container')]
        self.assertEqual(sum(d['y'] == 458 for d in hearts), 1)

    def test_server_hurt_marker_ignores_blocked_hits_and_expired_gold(self):
        self.run_lua('SERVER=true')
        self.lua.execute((LUA / 'mcgame/inventory/sh_survival_hud.lua').read_text(encoding='utf-8'))
        self.run_lua("hook.Run('PostEntityTakeDamage',p,{},false); assert(p.hurtUntil==0)")
        self.run_lua("hook.Run('MCITEM.AbsorptionChanged',p,0,'expired'); assert(p.hurtUntil==0)")
        self.run_lua("hook.Run('MCITEM.AbsorptionChanged',p,3,'damage'); assert(p.hurtUntil==11)")
        self.run_lua("hook.Run('PlayerSpawn',p); assert(p.hurtUntil==0)")
        self.run_lua("hook.Run('PostEntityTakeDamage',p,{},true); assert(p.hurtUntil==11)")

    def test_sprite_export_pixels_padding_and_source_hash(self):
        from generate_survival_hud_sprites import SPRITES
        digest = hashlib.sha256()
        for name in sorted(SPRITES):
            path = MATERIALS / 'sprites/hud' / f'{name}.png'
            original = Image.open(path).convert('RGBA')
            padded = Image.open(path.with_stem(path.stem + '__pot')).convert('RGBA')
            self.assertEqual(original.size, (9, 9))
            self.assertEqual(padded.size, (16, 16))
            self.assertEqual(original.tobytes(), padded.crop((0, 0, 9, 9)).tobytes())
            self.assertIsNone(padded.crop((9, 0, 16, 16)).getbbox())
            self.assertIsNone(padded.crop((0, 9, 16, 16)).getbbox())
            digest.update(name.encode('utf-8'))
            digest.update(path.read_bytes())
        manifest = (LUA / 'mcgame/generated/cl_generated_survival_hud_sprites.lua').read_text()
        self.assertIn(digest.hexdigest(), manifest)


if __name__ == '__main__':
    unittest.main(verbosity=2)
