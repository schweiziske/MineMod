"""Exercise shipped item models, sprite meshes and atlas rebinding in LuaJIT."""

import json
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "addons/mc_game/lua"


class ItemBlockSpriteTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)

        def convert(value):
            if isinstance(value, dict):
                return self.lua.table_from({key.encode(): convert(item) for key, item in value.items()})
            if isinstance(value, list):
                return self.lua.table_from([convert(item) for item in value])
            return value.encode() if isinstance(value, str) else value

        self.lua.globals().decode_json = lambda data: convert(json.loads(data))
        self.lua.globals().include = self.include
        self.lua.execute(b"""
            CLIENT = true; MC = {}
            util = {JSONToTable = decode_json}
            function Color(r,g,b,a) return {r=r,g=g,b=b,a=a or 255} end
            color_white = Color(255,255,255)
            local V = {}; V.__index = V
            function Vector(x,y,z) return setmetatable({x=x,y=y,z=z,vector=true},V) end
            function V.__add(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
            function V.__sub(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
            function V.__mul(a,b) return Vector(a.x*b,a.y*b,a.z*b) end
            function V.__unm(a) return a*-1 end
            function V:LengthSqr() return self.x^2+self.y^2+self.z^2 end
            function V:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
            function V:Cross(b) return Vector(self.y*b.z-self.z*b.y,
                self.z*b.x-self.x*b.z,self.x*b.y-self.y*b.x) end
            function V:GetNormalized() return self*(1/math.sqrt(self:LengthSqr())) end
            vector_origin = Vector(0,0,0)
            function Angle(p,y,r)
                return {p=p,y=y,r=r,angle=true,
                    Forward=function() return Vector(1,0,0) end,
                    Right=function() return Vector(0,-1,0) end,
                    Up=function() return Vector(0,0,1) end}
            end
            function isvector(v) return type(v)=='table' and v.vector end
            function isangle(v) return type(v)=='table' and v.angle end
            function isfunction(v) return type(v)=='function' end
            function Matrix()
                return setmetatable({SetField=function(self,r,c,v) self[r..':'..c]=v end},
                    {__index=function() return function() end end})
            end
            local M = {}; M.__index = M
            function Material(path) return setmetatable({name=path},M) end
            function M:IsError() return false end
            function M:SetTexture(k,v) self[k]=v end
            function M:GetTexture(k) return self[k] end
            function M:SetMatrix(k,v) self[k]=v end
            function M:GetVector(k) return self[k] end
            function M:SetVector(k,v) self[k]=v end
            function CreateMaterial(name,shader,params)
                local m=Material(name); m.shader=shader; m.params=params; return m
            end
            function atlasTexture(name)
                return {GetName=function() return name end,IsError=function() return false end}
            end
            MC.MaterialHeldBlock = Material('held_blocks')
            MC.MaterialHeldBlock:SetTexture('$basetexture',atlasTexture('first_pack'))
            MC.Tiles = {}; uvScale=0.1; uvStart=0.2
            function MC.TileUV(tile) return uvStart,uvStart,uvStart+uvScale,uvStart+uvScale end
            function MC.Check(ok,code,...) assert(ok,code); return ok end
            MC.ResourceGeneration = {TrackMaterial=function(m) tracked=m end}
            hooks={}
            hook={Add=function(event,name,callback)
                hooks[event]=hooks[event] or {}; hooks[event][name]=callback
            end}
            concommand={Add=function() end}
            local function noop() end
            render=setmetatable({}, {__index=function() return noop end})
            cam=render
            function Mesh(material)
                return {BuildFromTriangles=function(self,v) self.vertices=v; built=self end,
                    Draw=function(self) draws=draws+1; drawn=self end,Destroy=noop}
            end
            draws=0; mesh={}
            MC.InventoryUI = {
                GetMaterial=Material, GetWorldItemMaterial=Material,
                WithPointFiltering=function(fn) return fn() end,
                DrawTexture=function(m) iconMaterial=m end,
                WorldItemHDRColorScale=1,
            }
            function MC.IsEmptyItemStack(stack) return not stack or not stack.item end
            function MC.GetItem(name) return {name=name} end
            TEXFILTER={POINT=1}; MATERIAL_CULLMODE_CCW=0; MATERIAL_CULLMODE_CW=1
        """)
        self.include(b"mcgame/item/sh_model_registry.lua")
        self.include(b"mcgame/generated/sh_generated_item_models.lua")
        self.lua.execute(b"""
            assert(MC.ItemModelCatalogStats.loaded)
            for _,model in pairs(MC.ItemModelFiles) do
                for _,layer in ipairs(model.layers) do
                    local name=type(layer)=='string' and layer:match('^mc/block/(.+)$')
                    if name then MC.Tiles[name]=1 end
                end
            end
        """)
        self.include(b"mcgame/item/cl_model_resolver.lua")
        self.include(b"mcgame/inventory/ui/cl_item_renderer.lua")

    def include(self, path):
        self.lua.execute((GAME / path.decode()).read_bytes())

    def run_lua(self, source):
        self.lua.execute(source.encode())

    def test_shipped_flower_and_mushroom_drops_submit_extruded_meshes(self):
        self.run_lua("""
            local r=MC.InventoryUI.ItemRenderer
            for _,name in ipairs({'dandelion','poppy','brown_mushroom','red_mushroom',
                'oak_sapling','fern','brain_coral','torch'}) do
                local stack={item='minecraft:'..name,count=1}
                local options={displayContext='ground',worldItem=true}
                local prepared=r.PrepareDroppedItem(stack,options)
                assert(prepared.plan.kind=='flat',name)
                assert(#prepared.materials==1,name..' has no texture layer')
                assert(prepared.plan.layers[1]:match('^mc/block/'),name)
                assert(r.DrawHeldItem(stack,vector_origin,Angle(0,0,0),1,
                    color_white,options,prepared),name..' failed to draw')
                assert(#drawn.vertices>12,name..' has no extruded silhouette')
                assert(prepared.materials[1]:GetTexture('$basetexture'):GetName()=='first_pack')
            end
            assert(draws==8)
        """)

    def test_every_block_layer_has_a_nonempty_mask(self):
        self.run_lua("""
            local count=0
            for layer,mask in pairs(MC.ItemBlockSpriteMasks) do
                local occupied=0
                for _,row in ipairs(mask.rows) do occupied=occupied+row end
                assert(occupied>0,layer..' silhouette is empty')
                count=count+1
            end
            assert(count>=100,'block-backed sprites missing from catalog')
        """)

    def test_pack_switch_updates_retained_materials_and_uvs(self):
        self.run_lua("""
            local r=MC.InventoryUI.ItemRenderer
            local m=r.MaterialForLayer('mc/block/dandelion',true)
            assert(m['$basetexturetransform']['1:4']==0.2)
            MC.MaterialHeldBlock:SetTexture('$basetexture',atlasTexture('second_pack'))
            uvStart=0.6; uvScale=0.05
            hooks['MC.TexturePackChanged']['mc_item_block_layers']()
            assert(r.MaterialForLayer('mc/block/dandelion',true)==m)
            assert(m:GetTexture('$basetexture'):GetName()=='second_pack')
            assert(m['$basetexturetransform']['1:4']==0.6)
            assert(math.abs(m['$basetexturetransform']['1:1']-0.05)<1e-9)
            assert(tracked==m)
        """)

    def test_inventory_and_regular_item_paths(self):
        self.run_lua("""
            local r=MC.InventoryUI.ItemRenderer
            assert(r.DrawIcon({item='minecraft:dandelion',count=1},0,0,16,{}))
            assert(iconMaterial:GetTexture('$basetexture'):GetName()=='first_pack')
            local materials,plan=r.MaterialsForStack({item='minecraft:stick'}, {worldItem=true})
            assert(plan.layers[1]=='mc/item/stick')
            assert(materials[1].name=='mc/item/stick.png')
        """)


if __name__ == "__main__":
    unittest.main()
