"""Mounted presets, sparse overwrite and optional screenshots, on LuaJIT 5.1."""
import json
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
LUA = ROOT / "addons/mc_engine/lua/mc"


class PresetTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            bit=require('bit'); SERVER=true; CLIENT=false
            function istable(v) return type(v)=='table' end
            function isstring(v) return type(v)=='string' end
            function IsValid(v) return type(v)=='table' and v.valid==true end
            function string.Trim(s) return s:match('^%s*(.-)%s*$') end
            function string.StartWith(s,p) return s:sub(1,#p)==p end
            function math.Clamp(v,a,b) return math.max(a,math.min(b,v)) end
            MC={CS=16,CH=32,SV={},Config={
                PresetMaxBlocks={GetInt=function() return 1 end},
                WorldLimit={GetInt=function() return 1000 end},
                MaxBlocks={GetInt=function() return 0 end}},Net={COORD_BITS=16},
                Messages={Spec=function() return {} end,Reply=function() end,
                    Notify=function() end,Console=function() end}}
            function MC.Fault(...) end
            net={Receive=function() end}; hook={Add=function() end}
            timer={Simple=function() end}; concommand={Add=function() end}
            function CurTime() return 100 end
            game={GetMap=function() return 'gm_flatgrass' end}
            function MC.ParseBlockState(spec)
                parseCalls=(parseCalls or 0)+1
                if spec=='minecraft:stone' then return 1 end
                if spec=='minecraft:dirt' then return 2 end
                return nil,'unknown_state'
            end
            function MC.IsValidBlockState(id) return id==1 or id==2 end
            function MC.LegacyFromState(id) return id,0 end
            function MC.GetStateProperty() return nil end
            function MC.StateWith(id) return id end
            function MC.CellKey(x,y,z) return x..':'..y..':'..z end
            MC.ChunkKey=MC.CellKey
            worldChunks={}; worldCells={}
            function MC.GetChunk(cx,cy,cz) return worldChunks[MC.ChunkKey(cx,cy,cz)] end
            function MC.GetBlockState(x,y,z) return worldCells[MC.CellKey(x,y,z)] or 0 end
            function MC.ForEachBlockState(chunk,callback)
                for _,c in ipairs(chunk) do callback(c[1],c[2],c[3],0,0,0,c[4]) end
            end
            MC.SV.BlockCount=1
            function MC.SV.CanEdit() return true end
            function MC.SV.SetBlocksBulk(cells)
                proposedCells=cells; return #cells
            end
        ''')
        self.game = {}
        self.data = {}
        definition = {"name": "builtin_sample", "file": "sample.json", "titleKey": "preset.sample",
                      "cover": "mc/preset_covers/sample.jpg", "size": [3, 2, 1], "blocks": 2, "map": "gm_flatgrass"}
        self.game["data_static/mc/presets/catalog.json"] = json.dumps({"v": 1, "presets": [definition]})
        preset = {"v": 2, "name": "builtin_sample", "size": [3, 2, 1], "anchor": [0, 0, 0, 0, 0, 1],
                  "cells": [[0, 0, 0, 0, 0, "minecraft:stone"], [2, 1, 0, 0, 0, "minecraft:dirt"]],
                  "blocks": 2, "bundled": True, "titleKey": "preset.sample", "cover": definition["cover"]}
        self.game["data_static/mc/presets/sample.json"] = json.dumps(preset)
        spoof = dict(preset, name="local_sample")
        self.data["mc/presets/local_sample.dat"] = json.dumps(spoof)
        self.lua.globals().file = self.to_lua({
            "Exists": lambda p, realm: p in (self.game if realm == "GAME" else self.data),
            "Read": lambda p, realm: (self.game if realm == "GAME" else self.data).get(p),
            "Time": lambda *_: 1, "CreateDir": lambda *_: None,
            "Find": lambda *_: self.to_lua(["local_sample.dat"]), "Write": self.write_data,
        })
        self.lua.globals().util = self.to_lua({
            "JSONToTable": self.parse_json,
            "TableToJSON": lambda *_: "{}", "Compress": lambda raw: raw, "Decompress": lambda raw: raw,
        })
        self.lua.execute((LUA / "sh_presets.lua").read_text(encoding="utf-8"))
        self.lua.execute((LUA / "sv_presets.lua").read_text(encoding="utf-8"))

    def write_data(self, path, data):
        self.data[path] = data

    def parse_json(self, raw, ignore_limits=False):
        data = json.loads(raw)
        cells = data.get("cells")
        if not ignore_limits and cells and sum(len(row) for row in cells) > 15000:
            data["cells"] = cells[:2500]
        return self.to_lua(data)

    def to_lua(self, value):
        if isinstance(value, dict): return self.lua.table_from({k: self.to_lua(v) for k, v in value.items()})
        if isinstance(value, list): return self.lua.table_from([self.to_lua(v) for v in value])
        return value

    def test_bundled_load_never_installs_into_player_data(self):
        self.lua.execute('''
            local d,e,c=MC.SV.LoadPreset('builtin_sample')
            assert(d and not e and d.bundled and c.bundled)
            assert(d.cover=='mc/preset_covers/sample.jpg')
            local list=MC.SV.PresetList()
            assert(#list==2)
            local count=0
            for _,row in ipairs(list) do if row.bundled then count=count+1 end end
            assert(count==1)
            assert(not MC.SV.DeletePreset('builtin_sample'))
            assert(not MC.SV.SavePreset('builtin_sample',{}, {}, {}, '',nil))
        ''')
        self.assertNotIn("mc/presets/builtin_sample.dat", self.data)

    def test_local_bundled_flag_cannot_bypass_limits(self):
        self.lua.execute('''
            local d,e,c=MC.SV.LoadPreset('local_sample')
            assert(d and not d.bundled and not c.bundled)
            local ok,err=MC.SV.PlacePreset(nil,'local_sample',{bx=0,by=0,bz=0},{},0)
            assert(ok==false and err=='preset_too_large')
        ''')

    def test_bundled_preset_exceeding_engine_json_key_limit(self):
        catalog_path = "data_static/mc/presets/catalog.json"
        preset_path = "data_static/mc/presets/sample.json"
        catalog = json.loads(self.game[catalog_path])
        preset = json.loads(self.game[preset_path])
        size = [51, 50, 1]
        cells = [[x, y, 0, 0, 0, "minecraft:stone"] for x in range(51) for y in range(50)]
        catalog["presets"][0].update(size=size, blocks=len(cells))
        preset.update(size=size, blocks=len(cells), cells=cells)
        self.game[catalog_path] = json.dumps(catalog)
        self.game[preset_path] = json.dumps(preset)
        data, err, _ = self.lua.globals().MC.SV.LoadPreset("builtin_sample")
        self.assertIsNone(err)
        self.assertEqual(len(data.cells), len(cells))

    def test_bundled_size_exception_and_sparse_overwrite(self):
        self.lua.execute('''
            worldCells['1:0:0']=1
            worldChunks['0:0:0']={{1,0,0,1},{5,0,0,1}}
            local ok,count=MC.SV.PlacePreset(nil,'builtin_sample',{bx=0,by=0,bz=0},true,0)
            assert(ok and count==3 and #proposedCells==3)
            local clears=0
            for _,c in ipairs(proposedCells) do
                assert(c.bx~=5)
                if c.stateId==0 then assert(c.bx==1 and c.by==0); clears=clears+1 end
            end
            assert(clears==1)
        ''')

    def test_lazy_chunks_are_read_before_overwrite(self):
        self.lua.execute('''
            MC.SV.ChunkStore={IsLazyWorld=function() return true end,
                HasBaseChunk=function() return true end,HasChunkEdits=function() return false end,
                LoadedKeys={},HydrateChunkNow=function(key)
                    worldChunks[key]={{1,0,0,1}};worldCells['1:0:0']=1
                    return worldChunks[key]
                end}
            local ok=MC.SV.PlacePreset(nil,'builtin_sample',{bx=0,by=0,bz=0},true,0)
            assert(ok and #proposedCells==3)
        ''')

    def test_cache_preserves_empty_spec_legacy_semantics(self):
        self.lua.execute('''
            local d={anchor={0,0,0},cells={}}
            for i=1,100 do d.cells[i]={i,0,0,0,0,'minecraft:stone'} end
            parseCalls=0
            local result=MC.PresetCells(d,{bx=0,by=0,bz=0},0)
            assert(#result==100 and parseCalls==1)
            MC.StateFromLegacy=function(id) return id end
            local legacy=MC.PresetCells({cells={{0,0,0,1,0,''},{1,0,0,2,0,''}}},{},0)
            assert(legacy[1].stateId==1 and legacy[2].stateId==2)
        ''')

    def test_bounds_follow_all_four_quarter_turns(self):
        self.lua.execute('''
            local d={size={3,2,2},anchor={1,1,0}}
            for r=0,3 do
                local ax,ay,az,bx,by,bz=MC.PresetBounds(d,{bx=7,by=-3,bz=-1},r)
                assert((bx-ax+1)*(by-ay+1)*(bz-az+1)==12)
                for z=0,1 do for y=0,1 do for x=0,2 do
                    local rx,ry,rz=MC.PresetRotateLocalCell(d,x,y,z,r)
                    assert(rx+7>=ax and rx+7<=bx and ry-3>=ay and ry-3<=by)
                    assert(rz-1>=az and rz-1<=bz)
                end end end
            end
        ''')

    def test_cell_protection_still_applies_to_bundled_placements(self):
        self.lua.execute('''
            local player={valid=true,IsAdmin=function() return true end}
            MC.SV.CellEditAllowed=function() return false end
            local ok,err=MC.SV.PlacePreset(player,'builtin_sample',{bx=0,by=0,bz=0},false,0)
            assert(ok==false and err=='permission')
        ''')


class CoverCaptureTest(unittest.TestCase):
    def run_capture(self, responses, write_fails=False, timeout=False):
        lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        source = (LUA / "cl_ui.lua").read_bytes()
        start = source.index(b"function MC.LibraryCaptureCover")
        end = source.index(b"function MC.LibraryStyleButton", start)
        lua.execute(b'''
            MC={};hooks={};timers={};writes={};calls=0;captures=0
            hook={Add=function(_,key,cb) hooks[key]=cb end,Remove=function(_,key) hooks[key]=nil end}
            timer={Create=function(key,_,_,cb) timers[key]=cb end,Remove=function(key) timers[key]=nil end}
            util={CRC=function() return 'test' end};function SysTime() return 1 end
            function ScrW() return 1280 end;function ScrH() return 720 end
            file={Write=function(key,data) if failWrite then error('disk') end; writes[key]=data end,
                Exists=function(key) return writes[key]~=nil end,Size=function(key) return #(writes[key] or '') end}
            render={Capture=function(opts)
                assert(opts.alpha==false and opts.format=='jpeg')
                captures=captures+1
                local r=responses[captures]
                if r=='throw' then error('render target') end
                return r
            end}
        ''')
        lua.globals().responses = lua.table_from(responses)
        lua.globals().failWrite = write_fails
        lua.execute(source[start:end])
        lua.execute(b"MC.LibraryCaptureCover('mc/cover.jpg',function(p,d,e) calls=calls+1; result={p,d,e} end)")
        if timeout:
            lua.execute(b"for _,cb in pairs(timers) do cb() end")
        else:
            lua.execute(b"for i=1,6 do for _,cb in pairs(hooks) do cb() end end")
        lua.execute(b"assert(calls==1 and next(hooks)==nil and next(timers)==nil)")
        return lua

    def test_capture_retries_a_transient_nil(self):
        lua = self.run_capture([None, b"\xff\xd8image\xff\xd9"])
        self.assertEqual(lua.globals().captures, 2)
        self.assertEqual(lua.globals().result[1], b"mc/cover.jpg")

    def test_capture_exception_finishes_without_cover(self):
        lua = self.run_capture([b"throw", b"throw", b"throw"])
        self.assertEqual(lua.globals().result[1], b"")
        self.assertEqual(lua.globals().result[3], b"capture_failed")

    def test_failed_write_and_timeout_each_finish_once(self):
        lua = self.run_capture([b"\xff\xd8image\xff\xd9"], write_fails=True)
        self.assertEqual(lua.globals().result[3], b"write_failed")
        lua = self.run_capture([], timeout=True)
        self.assertEqual(lua.globals().result[3], b"timeout")


if __name__ == "__main__": unittest.main()
