"""Focused Java 26.2 totem checks against this MineMod checkout (Python + lupa).

Run: python tools/test_mcitem_totem_effects.py
Optional pixel comparison: --minecraft-source D:/BMBTools/26.2/nnnewest
The GLua shim exercises the actual client hooks; it does not emulate Source
VPhysics/GPU rendering or claim collision coverage outside the prediction bubble.
Bytecode oracles: TrackingEmitter, TotemParticle, Particle, SingleQuadParticle,
SimpleAnimatedParticle, ParticleResources$MutableSpriteSet, Camera, Projection.
"""

import argparse
import hashlib
from pathlib import Path
import struct
import unittest

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[1]
CLIENT = ROOT / "addons/mc_item/lua/mcitem/totem/cl_effects.lua"
MATERIALS = ROOT / "addons/mc_item/materials/mcitem/totem"
MC_SOURCE = None
# SHA256 of RGBA pixels decoded from Java 26.2 glitter_7 through glitter_0.
SPRITE_HASHES = [
    "3c865e5558f89632f731496a0ad5c38fba8af32a1777213cb4de451b6ce09311",
    "57217bad31dc07ec322877883bf76656c87a1a10893bdc2513fe4aacf1a2fe76",
    "3c865e5558f89632f731496a0ad5c38fba8af32a1777213cb4de451b6ce09311",
    "57217bad31dc07ec322877883bf76656c87a1a10893bdc2513fe4aacf1a2fe76",
    "0c86dd058151d0931368c217304119372945cdfa55c44494d70438633d5bc946",
    "6486b01aca9c017013c6956452fa8454f0bbeefec3e1c23865d47132205be7be",
    "264d5c697c54e2590313a283aa6a7bcc124cde972538ba8b99c3f550bba24292",
    "ce5b4726611a8feb79345812798180c029082eec9235eada38c43743bf8977c2",
]

SHIM = r'''
CLIENT = true
now, blockSize, signedRandom, lifetimeRandom, colorRandom = 0, 50, 0, 0, 1
local methods = {}
local mt = { __index = methods }
function Vector(x,y,z) return setmetatable({x=x or 0,y=y or 0,z=z or 0},mt) end
function methods:Set(v) self.x,self.y,self.z = v.x,v.y,v.z end
function methods:SetUnpacked(x,y,z) self.x,self.y,self.z = x,y,z end
function methods:Mul(v) self.x,self.y,self.z = self.x*v,self.y*v,self.z*v end
mt.__add = function(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
mt.__mul = function(a,b) return Vector(a.x*b,a.y*b,a.z*b) end
function Angle()
    return {Right=function() return Vector(0,-1,0) end,
        Up=function() return Vector(0,0,1) end}
end
function EyeAngles() return Angle() end
function IsValid(v) return type(v)=='table' and not v.removed end
function isfunction(v) return type(v)=='function' end
function CurTime() return now end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a or 255} end
function Material(name, flags) return {name=name,flags=flags} end
function Lerp(t,a,b) return a+(b-a)*t end
function ScrW() return 1920 end
function ScrH() return 1080 end
math.Clamp = function(v,a,b) return math.max(a,math.min(b,v)) end
math.Rand = function(a,b)
    if a==-1 and b==1 then return signedRandom end
    return (a+b)*0.5
end
math.random = function(a,b) return b and lifetimeRandom or colorRandom end
local function entity(class, world)
    return {GetClass=function() return class end, IsWorld=function() return world or false end,
        GetPos=function() return Vector(100,200,10) end,
        WorldSpaceAABB=function() return Vector(88,188,10),Vector(112,212,82) end}
end
entities = {
    world=entity('worldspawn',true), chunk=entity('mc_chunk'), phys=entity('mc_chunk_phys'),
    carrier=entity('mc_collision_carrier'), cluster=entity('mc_block_cluster'),
    prop=entity('prop_physics'), player=entity('player'), npc=entity('npc_citizen'),
}
player = entities.player
function LocalPlayer() return player end
MCITEM = {BlockSize=function() return blockSize end}
MC = {API={Sound={Play=function(name) lastSound=name end}}}
callbacks = {}
hook = {Remove=function() end, Add=function(event,id,fn) callbacks[id]=fn end}
net = {Receive=function(name,fn) receive=fn end,
    ReadEntity=function() return target or player end, ReadString=function() return 'offhand' end}
MASK_SOLID, MATERIAL_QUADS, TEXFILTER = 1,7,{POINT=0}
traceCalls, vertices, batches, filters = {},{},{},{}
util = {TraceHull=function(data)
    assert(data.mask==MASK_SOLID)
    local start,finish = data.start,data.endpos
    local result=Vector(finish.x,finish.y,finish.z)
    local axis = finish.z~=start.z and 'z' or (finish.y~=start.y and 'y' or 'x')
    traceCalls[#traceCalls+1]={axis=axis,mins=Vector(data.mins.x,data.mins.y,data.mins.z),
        maxs=Vector(data.maxs.x,data.maxs.y,data.maxs.z)}
    lastFilter = data.filter
    if floorZ and result.z < floorZ then result.z=floorZ end
    if wallX and result.x > wallX then result.x=wallX end
    return {HitPos=result}
end}
render = {
    SetMaterial=function(m) material=m end,
    PushFilterMag=function(v) filters[#filters+1]='mag'; assert(v==TEXFILTER.POINT) end,
    PushFilterMin=function(v) filters[#filters+1]='min'; assert(v==TEXFILTER.POINT) end,
    PopFilterMag=function() assert(table.remove(filters)=='mag') end,
    PopFilterMin=function() assert(table.remove(filters)=='min') end,
    SetToneMappingScaleLinear=function() error('unexpected exposure override') end,
}
mesh = {
    Begin=function(kind,count) assert(kind==MATERIAL_QUADS); batches[#batches+1]=count end,
    Position=function(p) vertex={x=p.x,y=p.y,z=p.z} end,
    TexCoord=function(_,u,v) vertex.u,vertex.v=u,v end,
    Color=function(r,g,b,a) vertex.r,vertex.g,vertex.b,vertex.a=r,g,b,a end,
    AdvanceVertex=function() vertices[#vertices+1]=vertex end, End=function() end,
}
cam={Start3D=function(...) camera={...} end, IgnoreZ=function(v) ignoreZ=v end, End3D=function() end}
function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a)..' ~= '..tostring(b)) end
function tick(t) now=t; callbacks['MCITEM.Totem.Tick']() end
function draw(depth,sky)
    vertices,batches={},{}
    callbacks['MCITEM.Totem.DrawParticles'](depth or false,sky or false)
end
function onlyParticle()
    receive()
    local p=MCITEM.Totem.Particles[1]
    MCITEM.Totem.Particles={p}; MCITEM.Totem.Emitters={}
    return p
end
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime()
        self.lua.execute(SHIM)
        self.lua.execute(CLIENT.read_text(encoding="utf-8"))

    def check(self, lua):
        self.lua.execute(lua)

    def test_immediate_emission_cadence_and_hitch(self):
        self.check('''
            receive(); assert(#MCITEM.Totem.Particles==16)
            tick(0.049); assert(#MCITEM.Totem.Particles==16)
            tick(0.05); assert(#MCITEM.Totem.Particles==32)
            tick(1.45); assert(#MCITEM.Totem.Particles==480)
            assert(#MCITEM.Totem.Emitters==0)
            near(MCITEM.Totem.Particles[480].bornAt,1.45)
            tick(1.5); assert(#MCITEM.Totem.Particles==480)
        ''')

    def test_sphere_rejection_does_not_retry(self):
        self.check('''
            signedRandom=1; target=entities.npc; receive()
            assert(#MCITEM.Totem.Particles==0)
            tick(1.5); assert(#MCITEM.Totem.Particles==0 and #MCITEM.Totem.Emitters==0)
        ''')

    def test_dimensions_units_color_and_local_activation(self):
        self.check('''
            local p=onlyParticle()
            near(p.position.x,100); near(p.position.y,200); near(p.position.z,46)
            near(p.size*2,11.25); near(p.velocity.z,10); assert(p.blockSize==50)
            assert(p.color.r==178 and p.color.g==191 and p.color.b==25)
            assert(p.lifetime==60 and p.age==0 and MCITEM.Totem.HUD)
            assert(lastSound=='item.totem.use')
            blockSize=20; colorRandom=2; lifetimeRandom=11; target=entities.npc
            MCITEM.Totem.HUD=nil; receive()
            p=MCITEM.Totem.Particles[2]
            near(p.size*2,4.5); near(p.velocity.z,4); assert(p.lifetime==71)
            assert(p.color.r==51 and p.color.g==140 and p.color.b==25)
            assert(MCITEM.Totem.HUD==nil)
        ''')

    def test_gravity_friction_and_render_interpolation(self):
        self.check('''
            local p=onlyParticle(); p.velocity=Vector(20,-10,30)
            tick(0.05)
            near(p.position.x,120); near(p.position.y,190); near(p.position.z,73.5)
            near(p.velocity.x,12); near(p.velocity.y,-6); near(p.velocity.z,16.5)
            now=0.075; draw()
            local x,y,z=0,0,0
            for _,v in ipairs(vertices) do x=x+v.x; y=y+v.y; z=z+v.z end
            near(x/4,110); near(y/4,195); near(z/4,59.75)
            assert(material.name=='mcitem/totem/particles' and #filters==0)
        ''')

    def test_sprite_and_alpha_tick_boundaries(self):
        self.check('''
            local p=onlyParticle()
            local cases={{0,0,255},{8,0,255},{9,1,255},{17,1,255},{18,2,255},
                {30,3,255},{31,3,250},{51,5,165},{52,6,161},{59,6,131},{60,7,127}}
            for _,c in ipairs(cases) do
                p.age=c[1]; draw(); near(vertices[1].u,(c[2]+1)/8)
                near(vertices[2].u,c[2]/8); assert(vertices[1].a==c[3])
                near(math.abs(vertices[1].y-vertices[2].y),11.25)
                assert(vertices[1].r==178 and vertices[1].g==191 and vertices[1].b==25)
            end
            p.lifetime=71; p.age=35; draw(); assert(vertices[1].a==255)
            p.age=36; draw(); assert(vertices[1].a==251)
            p.age=71; draw(); assert(vertices[1].a==125); near(vertices[1].u,1)
        ''')

    def test_final_frame_survives_until_following_tick(self):
        self.check('''
            local p=onlyParticle()
            tick(3.0); assert(p.age==60 and #MCITEM.Totem.Particles==1)
            draw(); near(vertices[2].u,7/8)
            tick(3.049); assert(#MCITEM.Totem.Particles==1)
            tick(3.05); assert(#MCITEM.Totem.Particles==0)
        ''')

    def test_floor_collision_box_stop_and_ground_drag(self):
        self.check('''
            local p=onlyParticle(); p.position.z=1; floorZ=0; p.velocity=Vector(8,0,-2)
            tick(0.05)
            near(p.position.z,0); near(p.velocity.x,3.36); near(p.velocity.z,-2.7)
            assert(p.onGround and not p.stoppedByCollision)
            near(traceCalls[1].mins.x,-5); near(traceCalls[1].mins.z,0)
            near(traceCalls[1].maxs.z,10)
            tick(0.1); assert(p.stoppedByCollision)
            local x=p.position.x; local count=#traceCalls
            tick(0.15); near(p.position.x,x); assert(#traceCalls==count)
        ''')

    def test_horizontal_collision_order_and_filter(self):
        self.check('''
            local p=onlyParticle(); p.velocity=Vector(8,12,0); wallX=103
            tick(0.05)
            assert(traceCalls[1].axis=='z' and traceCalls[2].axis=='y' and traceCalls[3].axis=='x')
            near(p.position.x,103); near(p.velocity.x,0); near(p.velocity.y,7.2)
            for _,key in ipairs({'world','chunk','phys','carrier','cluster'}) do assert(lastFilter(entities[key])) end
            for _,key in ipairs({'player','npc','prop'}) do assert(not lastFilter(entities[key])) end
        ''')

    def test_depth_sky_passes_and_mesh_bound(self):
        self.check('''
            local p=onlyParticle()
            draw(true,false); assert(#vertices==0 and #batches==0 and #filters==0)
            draw(false,true); assert(#vertices==0 and #batches==0 and #filters==0)
            for i=2,4097 do MCITEM.Totem.Particles[i]=p end
            draw(); assert(#batches==2 and batches[1]==4096 and batches[2]==1)
            assert(#vertices==4097*4 and #filters==0)
        ''')

    def test_hud_projection_and_duration(self):
        self.check('''
            receive(); callbacks['MCITEM.Totem.ItemActivation']()
            near(camera[3],86.06707652310801)
            -- Reconstruct the vertical FOV from Source's 4:3 reference field.
            near(math.deg(2*math.atan(math.tan(math.rad(camera[3])/2)/(4/3))),70)
            assert(camera[6]==1920 and camera[7]==1080)
            near(camera[8],0.05); near(camera[9],100); assert(ignoreZ==false)
            now=1.999; callbacks['MCITEM.Totem.ItemActivation'](); assert(MCITEM.Totem.HUD)
            now=2; callbacks['MCITEM.Totem.ItemActivation'](); assert(MCITEM.Totem.HUD==nil)
        ''')


class AssetTests(unittest.TestCase):
    def test_atlas_pixels_filter_flags_and_no_mips(self):
        data = (MATERIALS / "particles.vtf").read_bytes()
        self.assertEqual(struct.unpack_from("<4sIIIHH", data), (b"VTF\0",7,2,80,64,8))
        flags, = struct.unpack_from("<I", data,20)
        for flag in (0x1,0x4,0x8,0x100,0x200,0x2000):
            self.assertTrue(flags & flag)
        self.assertFalse(flags & (0x2 | 0x10))  # no trilinear/anisotropic
        self.assertEqual(struct.unpack_from("<H", data,24)[0],1)
        self.assertEqual(struct.unpack_from("<I", data,52)[0],0)  # RGBA8888
        self.assertEqual(data[56],1)
        self.assertEqual(len(data),80+64*8*4)
        for frame, digest in enumerate(SPRITE_HASHES):
            rgba = b"".join(data[80+(y*64+frame*8)*4:80+(y*64+frame*8+8)*4] for y in range(8))
            self.assertEqual(hashlib.sha256(rgba).hexdigest(),digest)
            self.assertEqual(set(rgba[3::4]),{0,255})
            if MC_SOURCE:
                from PIL import Image
                png = MC_SOURCE / f"assets/minecraft/textures/particle/glitter_{7-frame}.png"
                self.assertEqual(rgba,Image.open(png).convert("RGBA").tobytes())

    def test_material_preserves_alpha_and_exposure_path(self):
        text = (MATERIALS / "particles.vmt").read_text()
        self.assertIn('"$basetexture" "mcitem/totem/particles"',text)
        self.assertIn('"$translucent" "1"',text)
        self.assertIn('"$vertexcolor" "1"',text)
        self.assertIn('"$vertexalpha" "1"',text)
        for forced in ('"$ignorez"','"$selfillum"','"$fullbright"','"$additive"'):
            self.assertNotIn(forced,text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minecraft-source",type=Path)
    args, remaining = parser.parse_known_args()
    MC_SOURCE = args.minecraft_source
    unittest.main(argv=[__file__,*remaining],verbosity=2)
