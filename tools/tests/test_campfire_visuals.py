"""Campfire world-render routing against the shipped block/state catalogs.

Run: python -m unittest discover -s tools/tests -p test_campfire_visuals.py
Requires lupa; does not launch GMod or test GPU output.
"""
import base64
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime


LUA = Path(__file__).resolve().parents[2] / "addons/mc_engine/lua"


class CampfireVisualTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.lua.globals().include = self.include
        self.lua.globals().decode64 = base64.b64decode
        self.lua.execute(b"""
            CLIENT = true
            MC = {Blocks = {}, BlockByName = {}}
            util = {Base64Decode = decode64}
            function MC.ResolveBlock(name) return MC.BlockByName[name] end
        """)
        self.include(b"mc/generated/sh_generated_blocks.lua")
        self.lua.execute(b"""
            local catalog = MC.GeneratedBlockCatalog
            for _,row in ipairs(catalog.rows) do
                local geometry = catalog.geometry[row[13]]
                local block = {id=row[1], name=row[2],
                    stateRule=catalog.stateRules[row[10]],
                    shape=catalog.shapes[row[12]],
                    modelQuads=geometry and geometry.modelQuads,
                    modelSurfaces=catalog.surfaces[row[14]]}
                MC.Blocks[block.id] = block
                MC.BlockByName['minecraft:'..(row[3] or row[2])] = block
            end
            MC.Blocks[0] = {id=0,name='air'}
            MC.BlockByName['minecraft:air'] = MC.Blocks[0]
        """)
        self.include(b"mc/generated/sh_generated_block_state_schemas.lua")
        self.include(b"mc/sh_block_states.lua")
        self.include(b"mc/generated/sh_generated_state_visual_catalog.lua")
        self.include(b"mc/state/cl_state_visual_catalog.lua")
        self.include(b"mc/state/sh_state_visuals.lua")
        self.include(b"mc/generated/sh_generated_tiles.lua")

    def include(self, path):
        self.lua.execute((LUA / path.decode()).read_bytes())

    def test_all_campfire_states_use_complete_world_models(self):
        self.lua.execute(b"""
            for _,name in ipairs({'campfire','soul_campfire'}) do
                local schema = assert(MC.BlockStateSchemaByName['minecraft:'..name])
                assert(MC.GetStateProperty(schema.defaultStateId,'lit') == true)
                local visited = 0
                for state = schema.firstStateId,schema.lastStateId do
                    local visual = assert(MC.ResolveBlockStateVisual(state))
                    assert(visual.generatedVisualOverride,
                        name..' routed to the legacy wood-only model: '..MC.FormatBlockState(state))
                    local flame,embers,wood = 0,0,0
                    MC.VisitStateVisualModels(state,0,0,0,function(id)
                        local model = MC.StateVisualModelData(id)
                        for _,quad in ipairs(model.modelQuads) do
                            local tile = bit.band(model.modelSurfaces[quad.surface],4095)
                            if tile == MC.GeneratedTiles[name..'_fire'] then flame=flame+1 end
                            if tile == MC.GeneratedTiles[name..'_log_lit'] then embers=embers+1 end
                            if tile == MC.GeneratedTiles.campfire_log then wood=wood+1 end
                        end
                    end)
                    if MC.GetStateProperty(state,'lit') then
                        assert(flame == 4, 'lit campfire lost its double-sided flame planes')
                        assert(embers > 0, 'lit campfire lost its glowing logs')
                    else
                        assert(flame == 0 and embers == 0, 'unlit campfire still burns')
                    end
                    assert(wood > 0, 'campfire lost its wood')
                    visited = visited+1
                end
                assert(visited == 32, 'did not cover facing, lit, signal_fire and waterlogged')
            end
        """)

    def test_explicit_base_renderer_override_is_respected(self):
        self.lua.execute(b"""
            MC.RegisterBlockStateVisual('campfire',{forceBaseRenderer=true})
            local state = MC.DefaultBlockState('campfire')
            assert(MC.ResolveBlockStateVisual(state).generatedVisualOverride == false)
        """)

    def test_ordinary_default_cube_keeps_existing_route(self):
        self.lua.execute(b"""
            local state = MC.DefaultBlockState('glass')
            assert(MC.ResolveBlockStateVisual(state).generatedVisualOverride == false)
        """)


if __name__ == '__main__':
    unittest.main()
