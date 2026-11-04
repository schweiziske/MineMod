"""CPU regression tests against the shipped model catalog; requires lupa.

Run: python -m unittest discover -s tools/tests -p test_block_presentation.py
These capture Lua draw submissions, not GMod's GPU output.
"""
import base64
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "addons/mc_engine/lua"


class BlockPresentationTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.lua.globals().decode64 = base64.b64decode
        self.lua.globals().include = self.include
        self.lua.execute(b"""
            CLIENT = true
            MC = { Blocks = {}, Material = {}, MaterialHeldBlock = {} }
            util = { Base64Decode = decode64 }
            hook = { Add = function() end }
            function Color(r,g,b,a) return {r=r,g=g,b=b,a=a or 255} end
            function math.Clamp(x,a,b) return math.max(a,math.min(x,b)) end
            local V = {}; V.__index = V
            function Vector(x,y,z) return setmetatable({x=x,y=y,z=z}, V) end
            function V.__sub(a,b) return Vector(a.x-b.x,a.y-b.y,a.z-b.z) end
            function V:Cross(b) return Vector(self.y*b.z-self.z*b.y,
                self.z*b.x-self.x*b.z,self.x*b.y-self.y*b.x) end
            function V:Normalize()
                local n = math.sqrt(self.x^2+self.y^2+self.z^2)
                if n > 0 then self.x,self.y,self.z=self.x/n,self.y/n,self.z/n end
            end
            function MC.Check(ok,...) assert(ok); return ok end
            MC.Need = MC.Check
            function MC.BlockStateTintCode() return 0 end
            function MC.BlockFace() error('model used box face fallback') end
            function MC.BlockBoxes() error('model used box geometry fallback') end
            function MC.TileUV(tile,uv)
                lastTile = tile
                uv = uv or {0,0,16,16}
                return uv[1]/16,uv[2]/16,uv[3]/16,uv[4]/16
            end
            surface = { SetMaterial=function() end, SetDrawColor=function() end,
                DrawPoly=function(p) polygons[#polygons+1]={tile=lastTile,verts=p} end }
            local function noop() end
            render = setmetatable({}, {__index=function() return noop end})
            cam = render
            TEXFILTER = {POINT=1}; MATERIAL_TRIANGLES=1
            function Matrix() return render end
            function CreateClientConVar() return {GetFloat=function() return 0 end} end
            mesh = { Begin=function(_,n) triangleCount=n end, End=function() end,
                Position=function(p) current={pos=p} end,
                Normal=function(n) current.normal=n end,
                TexCoord=function(_,u,v) current.u,current.v=u,v end,
                Color=function() end,
                AdvanceVertex=function() vertices[#vertices+1]=current end }
        """)
        self.include(b"mc/generated/sh_generated_state_visual_catalog.lua")
        self.include(b"mc/state/cl_state_visual_catalog.lua")
        source = (LUA / "mc/sh_blocks.lua").read_text(encoding="utf-8")
        functions = source[source.index("function MC.BlockModelSurface"):source.index("MC.Blocks = {}")]
        self.lua.execute(b"local bit_band, bit_rshift = bit.band, bit.rshift\n"
                         b"local MODEL_SURFACE_TILE_MASK, MODEL_SURFACE_TILE_SHIFT = 4095, 12\n"
                         + functions.encode())
        self.include(b"mc/generated/sh_generated_block_state_schemas.lua")
        self.include(b"mc/generated/sh_generated_tiles.lua")
        self.lua.execute(b"""
            states, visuals = {}, {}
            local catalog = MC.GeneratedBlockStateSchemaCatalog
            local first = 0
            for id,row in ipairs(catalog.rows) do
                local ordinal,stride = 0,1
                for i=#row-2,3,-3 do
                    ordinal = ordinal + (row[i+2]-1)*stride
                    stride = stride * #catalog.domains[row[i+1]].values
                end
                local state = first+ordinal
                states[row[1]]=state
                MC.Blocks[id]={id=id,name=row[1]}
                visuals[state]={id=id,block=MC.Blocks[id],stateId=state,renderOrient=0,
                    schema={defaultStateId=state}}
                first=first+row[2]
            end
            function MC.ResolveBlockStateVisual(state) return visuals[state] end
            -- The two piston fixtures use the catalog's six-value facing
            -- domain: default north is index 1, up is index 5, stride is 1.
            function MC.StateWith(state,property,value)
                assert(property=='facing' and value=='up')
                return state+4
            end
        """)
        self.include(b"mc/cl_block_presentation.lua")
        source = (LUA / "mc/cl_ui.lua").read_text(encoding="utf-8")
        self.lua.execute(source[source.index("local function iconMaterialFor"):source.index("MC.CreativeCategories =")].encode())
        source = (LUA / "weapons/mc_creative_placer/shared.lua").read_text(encoding="utf-8")
        self.lua.execute(source[source.index("\tlocal HELD_FACE_SHADE"):source.index("\tlocal function creativeHeldOrient")].encode())
        # Use the same registered UV correction as the world renderer.
        source = (LUA / "mc/redstone/sh_piston.lua").read_text(encoding="utf-8")
        self.lua.execute((source[source.index("local function transformClosedPistonModel"):source.index("local function registerClosedPistonModel")]
                          + "\nfor _,name in ipairs({'minecraft:piston','minecraft:sticky_piston'}) do "
                          "for _,state in ipairs({states[name],states[name]+4}) do "
                          "MC.VisitStateVisualModels(state,0,0,0,function(id) "
                          "MC.RegisterStateVisualModelTransform(id,transformClosedPistonModel) end) end end").encode())

    def include(self, path):
        self.lua.execute((LUA / path.decode()).read_bytes())

    def run_lua(self, code):
        self.lua.execute(code.encode())

    def test_sensor_tendrils_and_calibrated_crystal(self):
        self.run_lua("""
            for _,name in ipairs({'sculk_sensor','calibrated_sculk_sensor'}) do
                local q=MC.BlockPresentationQuads(states['minecraft:'..name])
                local tendrils,crystal=0,0
                for _,face in ipairs(q) do
                    if face.tile==MC.GeneratedTiles.sculk_sensor_tendril_inactive then
                        tendrils=tendrils+1
                        local lo,hi=math.huge,-math.huge
                        for _,p in ipairs(face.points) do lo=math.min(lo,p.pos.z); hi=math.max(hi,p.pos.z) end
                        assert(hi>lo, 'tendril flattened into a floating horizontal face')
                    end
                    if face.tile==MC.GeneratedTiles.calibrated_sculk_sensor_amethyst then crystal=crystal+1 end
                end
                assert(tendrils>0, 'missing tendril texture')
                if name=='calibrated_sculk_sensor' then assert(crystal>0, 'missing crystal') end
            end
        """)

    def test_icons_and_hands_submit_model_geometry(self):
        self.run_lua("""
            for _,name in ipairs({'piston','sticky_piston','sculk_sensor',
                'calibrated_sculk_sensor','sculk_shrieker','slime_block','heavy_weighted_pressure_plate','stone'}) do
                local state=states['minecraft:'..name]
                local visual=visuals[state]
                local quads=MC.BlockPresentationQuads(state)
                assert(quads and #quads>0,name)
                polygons={}; vertices={}
                MC.DrawMinecraftBlockIcon(visual.id,0,0,128,128,0,true,visual)
                assert(#polygons>0,name..' icon is empty')
                assert(MC.DrawCreativeHeldBlockState(state,Vector(0,0,0),{},1,1))
                assert(#vertices==#quads*6,name..' held geometry lost faces')
                assert(triangleCount==#quads*2)
                local order={1,3,2,1,4,3}
                for qi,q in ipairs(quads) do
                    for i,corner in ipairs(order) do
                        local actual=vertices[(qi-1)*6+i]
                        local expected=q.points[corner]
                        assert(actual.pos==expected.pos,'held vertex differs from catalog')
                        local uv=q.uv
                        assert(math.abs(actual.u-(uv[1]+expected.u*(uv[3]-uv[1]))/16)<1e-9)
                        assert(math.abs(actual.v-(uv[2]+expected.v*(uv[4]-uv[2]))/16)<1e-9)
                    end
                end
            end
        """)

    def test_cube_icon_culls_back_faces(self):
        self.run_lua("""
            local state=states['minecraft:stone']; local v=visuals[state]
            polygons={}
            MC.DrawMinecraftBlockIcon(v.id,0,0,128,128,0,true,v)
            assert(#polygons==3, 'cube must show exactly three faces')
            local quads=MC.BlockPresentationQuads(state)
            for _,q in ipairs(quads) do
                if q.face==1 then assert(q.normal.z>0.99, 'top normal points inward') end
            end
        """)

    def test_piston_faces_use_distinct_surfaces(self):
        self.run_lua("""
            for _,name in ipairs({'piston','sticky_piston'}) do
                local found={}
                for _,q in ipairs(MC.BlockPresentationQuads(states['minecraft:'..name])) do found[q.tile]=true end
                assert(found[MC.GeneratedTiles.piston_side])
                assert(found[MC.GeneratedTiles[name=='piston' and 'piston_top' or 'piston_top_sticky']])
                local state=states['minecraft:'..name]; local v=visuals[state]
                polygons={}
                MC.DrawMinecraftBlockIcon(v.id,0,0,128,128,0,true,v)
                local headVisible=false
                for _,p in ipairs(polygons) do
                    if p.tile==MC.GeneratedTiles[name=='piston' and 'piston_top' or 'piston_top_sticky'] then
                        headVisible=true
                    end
                end
                assert(headVisible,'piston item hides its head texture')
            end
        """)

    def test_revisions_invalidate_cached_geometry(self):
        self.run_lua("""
            local state=states['minecraft:piston']
            local first=MC.BlockPresentationQuads(state)
            assert(first==MC.BlockPresentationQuads(state))
            MC.ClearDecodedStateVisualModels()
            assert(first~=MC.BlockPresentationQuads(state))
            local second=MC.BlockPresentationQuads(state)
            MC.BlockStateVisualRevision=1
            assert(second~=MC.BlockPresentationQuads(state))
            visuals[state].block.connection='fence'
            assert(MC.BlockPresentationQuads(state)==nil)
            assert(MC.BlockPresentationQuads(MC.StateVisualCatalog.stateCount)==nil)
        """)

    def test_warm_draws_do_not_allocate_per_frame(self):
        self.run_lua("""
            local function noop() end
            surface.DrawPoly=noop
            mesh.Begin=noop; mesh.End=noop; mesh.Position=noop
            mesh.Normal=noop; mesh.TexCoord=noop; mesh.Color=noop; mesh.AdvanceVertex=noop
            local state=states['minecraft:calibrated_sculk_sensor']
            local visual=visuals[state]
            local pos,ang=Vector(0,0,0),{}
            local function drawMany(count)
                for i=1,count do
                    MC.DrawMinecraftBlockIcon(visual.id,i%64,0,128,128,0,true,visual)
                    MC.DrawCreativeHeldBlockState(state,pos,ang,1,1)
                end
            end
            for _,enabled in ipairs({true,false}) do
                if enabled then jit.on() else jit.off() end
                jit.flush()
                drawMany(2000)
                collectgarbage('collect'); collectgarbage('stop')
                local before=collectgarbage('count')
                local started=os.clock()
                drawMany(5000)
                local elapsed=os.clock()-started
                local growth=collectgarbage('count')-before
                collectgarbage('restart')
                print(string.format('LuaJIT %s: 5000 icon+hand draws, %.3f KiB Lua heap growth, %.3f s',
                    enabled and 'JIT' or 'interpreter',growth,elapsed))
                assert(growth<32, 'warm draw path allocates per frame')
            end
        """)


if __name__ == "__main__":
    unittest.main()
