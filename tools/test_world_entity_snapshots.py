"""World entity save contracts using actual LuaJIT code and a GLua shim.

Run: python tools/test_world_entity_snapshots.py
Source entities, VPhysics and Derma rendering require in-game acceptance.
"""
import json
from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime, lua_type

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "addons/mc_engine/lua/mc"
POTIONS = ROOT / "addons/mc_item/lua/mcitem/potions"

SHIM = r'''
SERVER=true; now=100; C={}; MC={SV={},World={},Messages={Spec=function(k) return k end}}
function isstring(v) return type(v)=='string' end
function isnumber(v) return type(v)=='number' end
function istable(v) return type(v)=='table' end
function isfunction(v) return type(v)=='function' end
function isbool(v) return type(v)=='boolean' end
function IsValid(v) return type(v)=='table' and not v.removed end
function CurTime() return now end
function SysTime() return now end
function MsgN() end
function ErrorNoHalt(msg) error(msg) end
function GetConVar() return nil end
function Color(r,g,b,a) return {r=r,g=g,b=b,a=a or 255} end
math.Clamp=function(v,a,b) return math.max(a,math.min(b,v)) end
string.Trim=function(s) return s:match('^%s*(.-)%s*$') end
string.EndsWith=function(s,t) return s:sub(-#t)==t end
string.StartWith=function(s,t) return s:sub(1,#t)==t end
string.GetPathFromFilename=function(s) return s:match('^(.*[/])') or '' end
game={GetMap=function() return 'gm_test' end,GetWorld=function() return {} end}
callbacks={}; hook={Add=function(e,k,fn) callbacks[k]=fn end,Remove=function() end,Run=function() end}
timer={Create=function() end,Remove=function() end,Simple=function(_,fn) fn() end}
concommand={Add=function() end}; cvars={AddChangeCallback=function() end}
files={}; file={Exists=function(p,r) return files[(r or 'DATA')..':'..p]~=nil end,
 Read=function(p,r) return files[(r or 'DATA')..':'..p] end,
 Write=function(p,v) files['DATA:'..p]=v end,CreateDir=function() end,
 Delete=function(p) files['DATA:'..p]=nil end,
 Rename=function(a,b) files['DATA:'..b]=files['DATA:'..a]; files['DATA:'..a]=nil; return true end,
 Find=function() return {} end}
file.Size=function(p,r) local v=file.Read(p,r); return v and #v or -1 end
file.Open=function(p) return {Write=function(_,v) file.Write(p,v) end,Close=function() end} end
util={AddNetworkString=function() end,Compress=function(s) return s end,Decompress=function(s) return s end,
 CRC=function() return '1234' end}
receivers={}; writes={}; net={Receive=function(n,f) receivers[n]=f end,Start=function() writes={} end,
 WriteBool=function(v) writes[#writes+1]=v end,WriteUInt=function(v) writes[#writes+1]=v end,
 WriteString=function(v) writes[#writes+1]=v end,Send=function() end,SendToServer=function() end}
admin={IsAdmin=function() return true end}; guest={IsAdmin=function() return false end}
function entity() return {IsMarkedForDeletion=function() return false end,
 Remove=function(s) s.removed=true end} end
local drops={}; ents={FindByClass=function(c) return drops[c] or {} end}; dropClasses=drops
player={GetAll=function() return {} end}
'''


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(SHIM)

    def decode(value):
        if lua_type(value) != "table":
            return value
        items = dict(value.items())
        if items and set(items) == set(range(1, len(items) + 1)):
            return [decode(items[i]) for i in range(1, len(items) + 1)]
        return {str(k): decode(v) for k, v in items.items()}

    def encode(value):
        if isinstance(value, dict):
            # GLua JSONToTable's default converts numeric object keys, unlike
            # Python's JSON parser. Bodygroup keys must survive that conversion.
            return lua.table_from({int(k) if k.lstrip('-').isdigit() else k: encode(v) for k, v in value.items()})
        if isinstance(value, list):
            return lua.table_from([encode(v) for v in value])
        return value

    def parse(raw):
        try:
            return encode(json.loads(raw))
        except (ValueError, TypeError):
            return None

    lua.globals().util.TableToJSON = lambda value, *_: json.dumps(decode(value), ensure_ascii=False)
    lua.globals().util.JSONToTable = parse
    lua.execute((ENGINE / "state/sv_entity_snapshots.lua").read_text(encoding="utf-8"))
    return lua


class Snapshots(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        self.lua.execute('''
            captures=0; commits=0; rollbacks=0
            assert(MC.SV.RegisterEntitySnapshotProvider('test',{version=1,
              capture=function() captures=captures+1; return {value=42} end,
              validate=function(d) return istable(d) and d.value==42 end,
              stage=function() return {commit=function() commits=commits+1 end,
                rollback=function() rollbacks=rollbacks+1 end} end}))
        ''')

    def test_default_and_unchecked_overwrite(self):
        self.lua.execute('''
            local s=assert(MC.SV.CaptureEntitySnapshots()); assert(s.enabled and captures==1)
            s=util.JSONToTable(util.TableToJSON(s))
            local staged=assert(MC.SV.StageEntitySnapshots(assert(MC.SV.PrepareEntitySnapshots(s))))
            assert(commits==0); MC.SV.CommitEntitySnapshots(staged); assert(commits==1)
            local off=assert(MC.SV.CaptureEntitySnapshots({saveEntities=false}))
            assert(not off.enabled and next(off.providers)==nil and captures==1)
            assert(#MC.SV.PrepareEntitySnapshots(off)==0)
            assert(#MC.SV.PrepareEntitySnapshots(nil)==0)
            assert(not MC.SV.CaptureEntitySnapshots({saveEntities='false'}))
            local overlay={}; MC.SV.AttachEntitySnapshotsToOverlay(overlay,s)
            assert(MC.SV.EntitySnapshotFromOverlay(off,overlay)==off)
        ''')

    def test_validation_and_provider_failure(self):
        self.lua.execute('''
            local s=assert(MC.SV.CaptureEntitySnapshots()); s.providers.test.version=2
            assert(not MC.SV.PrepareEntitySnapshots(s)); s.providers.test.version=1
            s.providers.test.data.value=9; assert(not MC.SV.PrepareEntitySnapshots(s))
            MC.SV.EntitySnapshotProviders.test=nil; assert(#MC.SV.PrepareEntitySnapshots(s)==0)
            local cyclic={}; cyclic.self=cyclic
            MC.SV.RegisterEntitySnapshotProvider('bad',{version=1,capture=function() return cyclic end,
              validate=function() error('bad validator') end,stage=function() end})
            assert(not MC.SV.CaptureEntitySnapshots())
            MC.SV.EntitySnapshotProviders.bad.capture=function() return {} end
            assert(not MC.SV.CaptureEntitySnapshots())
            local staged,err=MC.SV.StageEntitySnapshots({
              {id='first',data={},provider={stage=function() return {commit=function() end,
                rollback=function() rollbacks=rollbacks+1 end} end}},
              {id='second',data={},provider={stage=function() return nil,'creation_failed' end}}})
            assert(not staged and err:find('creation_failed') and rollbacks==1)
            local ok,rollbackError=MC.SV.RollbackEntitySnapshots({
              {rollback=function() rollbacks=rollbacks+1 end},
              {rollback=function() error('rollback_error') end}})
            assert(not ok and rollbackError:find('rollback_error') and rollbacks==2)
        ''')

    def test_overlay_identity_and_realm(self):
        self.lua.execute('''
            local base=assert(MC.SV.CaptureEntitySnapshots())
            MC.SV.ChunkStore={EntitySnapshotBase=base.id}
            local changed=assert(MC.SV.CaptureEntitySnapshots({saveEntities=false})); local overlay={edits={}}
            MC.SV.AttachEntitySnapshotsToOverlay(overlay,changed)
            file.Write('mc/a/edits.json',util.TableToJSON(overlay))
            assert(#MC.SV.ResolveEntitySnapshots({entitySnapshots=base,editOverlay='edits.json'},'mc/a/manifest.json','DATA')==0)
            local replacement=assert(MC.SV.CaptureEntitySnapshots())
            assert(#MC.SV.ResolveEntitySnapshots({entitySnapshots=replacement,editOverlay='edits.json'},'mc/a/manifest.json','DATA')==1)
            files['GAME:mc/b/edits.json']=files['DATA:mc/a/edits.json']
            assert(#MC.SV.ResolveEntitySnapshots({entitySnapshots=base,editOverlay='edits.json'},'mc/b/manifest.json','GAME')==0)
            MC.SV.ChunkStore.IsLazyWorld=function() return true end
            MC.SV.ChunkStore.LoadedEntitySnapshots=changed
            assert(#MC.SV.ResolveEntitySnapshots({},'unused','DATA')==0)
        ''')

    def test_legacy_region_and_lazy_save_writers(self):
        world = (ENGINE / "sv_world.lua").read_text(encoding="utf-8")
        self.lua.execute('''
            SV=MC.SV; SV.BlockCount=0; function ensureSaveDir() end
            function isDefaultSavePath() return false end
            function normalizedSavePath(p) return p end
            function overlaySavePath(p) return p:gsub('%.dat$','_edits.dat') end
            function savePath() return 'mc/default.dat' end
            function buildSaveData() return {v=5,chunks={}},{} end
            function reconcileBuiltBlockCount() return 0 end
            function verifyWrittenSave() return true end
            SV.VerifyStateSavePayload=function() return true end
            SV.WriteStateSaveFile=function(p,v) file.Write(p,v); return true end
            MC.Fault=function(_,fmt,...) error(string.format(fmt,...)) end
        ''')
        self.lua.execute(world[world.index("local function saveLegacyToPath("):world.index("local function savedHeightForData(")])
        self.lua.execute('''
            local ok,path,data=SV.SaveToPath('mc/test.dat',nil,{saveEntities=false})
            assert(ok and not data.entitySnapshots.enabled and not SV.SaveInProgress)
        ''')
        self.lua.execute((ENGINE / "state/sv_region_save.lua").read_text(encoding="utf-8"))
        self.lua.execute((ENGINE / "state/sv_region_persistence.lua").read_text(encoding="utf-8"))
        self.lua.execute('''
            local ok,path,data=SV.SaveToPath('mc/saves/test/manifest.json',nil,{saveEntities=false})
            assert(ok and not data.entitySnapshots.enabled and not SV.SaveInProgress)
            local raw=assert(file.Read(path,'DATA')); assert(not util.JSONToTable(raw).entitySnapshots.enabled)
            SV.ChunkStore={ManifestPath=path,EntitySnapshotBase='base',EditOverlayPath='mc/saves/test/edits.json',
              IsLazyWorld=function() return true end,SaveOverlay=function() return {edits={}} end}
            ok,path,data=SV.SaveToPath(path,nil,{saveEntities=false})
            assert(ok and data.entitySnapshotsBase=='base' and not data.entitySnapshots.enabled)
        ''')

    def test_chunk_store_uses_selected_legacy_overlay_and_resets_snapshot(self):
        self.lua.execute((ENGINE / "sv_chunk_store.lua").read_text(encoding="utf-8"))
        self.lua.execute('''
            local base=assert(MC.SV.CaptureEntitySnapshots())
            local off=assert(MC.SV.CaptureEntitySnapshots({saveEntities=false}))
            local manifest={v=10,parts={},chunkIndex={},p={},h=16,cs=16,stats={parts=0,chunks=0,blocks=0},
              editOverlay='edits.json',entitySnapshots=base}
            files['GAME:mc/a/edits.json']=util.TableToJSON({edits={},entitySnapshots=base,entitySnapshotsBase=base.id})
            file.Write('mc/a/manifest_edits.dat',util.TableToJSON({edits={},entitySnapshots=off,entitySnapshotsBase=base.id}))
            local store=MC.SV.ChunkStore
            assert(store.LoadLazyManifest(manifest,'mc/a/manifest.json','GAME'))
            assert(store.EntitySnapshotBase==base.id and not store.LoadedEntitySnapshots.enabled)
            assert(#MC.SV.ResolveEntitySnapshots(manifest,'mc/a/manifest.json','GAME')==0)
            store.Reset(); assert(store.EntitySnapshotBase==false and store.LoadedEntitySnapshots==nil)
        ''')

    def test_cleanup_permissions_and_precise_classes(self):
        self.lua.execute((ENGINE / "sv_config_ui.lua").read_text(encoding="utf-8"))
        self.lua.execute('''
            local item,orb,other=entity(),entity(),entity()
            dropClasses.mc_item_drop={item}; dropClasses.mcitem_experience_orb={orb}; dropClasses.prop_physics={other}
            receivers.mc_config_cleanup(0,guest); assert(not item.removed and writes[1]==false)
            receivers.mc_config_cleanup(0,admin)
            assert(item.removed and orb.removed and not other.removed and writes[2]==1 and writes[3]==1)
            receivers.mc_config_cleanup(0,admin); assert(writes[2]==0 and writes[3]==0)
        ''')

    def test_save_network_single_bit_and_old_clients(self):
        source = (ENGINE / "sv_saves.lua").read_text(encoding="utf-8")
        self.lua.execute('''
            SV=MC.SV; message=function(k) return k end; canUseSaves=function() return true end
            sendSaveList=function() end; SV.SaveNamed=function(n,c,o) option=o.saveEntities; return true end
        ''')
        self.lua.execute(source[source.index('net.Receive( "mc_save_action",'):])
        self.lua.execute('''
            local strings={'save','new',''}; local index=0
            net.ReadString=function() index=index+1; return strings[index] end
            net.ReadBool=function() return false end
            receivers.mc_save_action((4+1+3+1+1)*8+1,admin); assert(option==false)
            index=0; receivers.mc_save_action((4+1+3+1+1)*8,admin); assert(option==true)
            index=0; receivers.mc_save_action((4+1+3+1)*8,admin); assert(option==true)
        ''')

    def test_cover_upload_preserves_click_time_choice(self):
        source = (ENGINE / "cl_save_ui.lua").read_text(encoding="utf-8")
        self.lua.execute('''
            MC.SaveManagerFrame={SaveEntities=false,SetVisible=function() end,MakePopup=function() end}
            canUseSaveManager=function() return true end; setStatus=function() end; trim=string.Trim
            captureSaveCover=function(_,fn) coverCallback=fn end
            uploadSaveCover=function(_,_,_,fn) uploadCallback=fn end
        ''')
        code = source[source.index("local function sendSaveActionNow("):source.index("local ROW_HEIGHT")]
        self.lua.execute(code + "\nsendForTest=sendSaveAction")
        self.lua.execute('''
            sendForTest('save','new',true); MC.SaveManagerFrame.SaveEntities=true
            coverCallback('cover','bytes'); uploadCallback(true,'cover'); assert(writes[4]==false)
        ''')

    def test_load_failure_rolls_back_blocks_before_replacement(self):
        source = (ENGINE / "sv_world.lua").read_text(encoding="utf-8")
        self.lua.execute('''
            SV=MC.SV; SV.BlockCount=0; saved={v=5,chunks={}}; file.Write('mc/test.dat','save')
            readSaveJSON=function() return saved end
            savedHeightForData=function() return 16 end; savedChunkSizeForData=function() return 16 end
            MC.CH=16; MC.CS=16
            previous={marker='previous'}; MC.World=previous
            beginWorldLoadStage=function() MC.World={marker='staged'}; return previous end
            restoreWorldLoadStage=function(p) MC.World=p end
            captureWorldLoadStage=function() return MC.World end
            selectWorldLoadStage=function(p) MC.World=p end
            loadSaveChunks=function() return true end
            commitWorldLoadStage=function() worldCommits=(worldCommits or 0)+1 end
            resyncAllClients=function() end
            MC.RunEvent=function(e) if e=='MC.PreWorldLoad' then preLoads=(preLoads or 0)+1 end end
        ''')
        code = source[source.index("function SV.LoadFromPath("):source.index("local function autosaveConVar(")]
        self.lua.execute(code)
        self.lua.execute('''
            saved.entitySnapshots=assert(SV.CaptureEntitySnapshots())
            SV.EntitySnapshotProviders.test.stage=function() return nil,'create_failed' end
            local ok,err=SV.LoadFromPath('mc/test.dat',false)
            assert(not ok and err:find('create_failed') and MC.World==previous and not worldCommits and not preLoads)
            saved.entitySnapshots=nil; assert(SV.LoadFromPath('mc/test.dat',false))
            assert(worldCommits==1 and preLoads==1 and MC.World.marker=='staged')
        ''')

    def test_checkbox_default_clicks_and_disabled_state(self):
        source = (ENGINE / "cl_save_ui.lua").read_text(encoding="utf-8")
        self.lua.execute('''
            fr={}; actions={}; UI={}; MOUSE_LEFT=107
            viewState=nil
            vgui={Create=function(kind)
              local p={kind=kind,enabled=true}; setmetatable(p,{__index=function(_,key)
                return function() end end})
              function p:SetValue(v) self.checked=v==1; if self.OnChange then self:OnChange(self.checked) end end
              function p:GetChecked() return self.checked end
              function p:IsEnabled() return self.enabled end
              function p:Toggle() self:SetValue(self.checked and 0 or 1) end
              if kind=='DLabel' then label=p end; return p end}
            L=function(k) return k end
        ''')
        default = next(line for line in source.splitlines() if "fr.SaveEntities = not viewState" in line)
        controls = source[source.index('\tlocal saveEntities = vgui.Create('):source.index('\tlocal publishWorkshop = vgui.Create(')]
        self.lua.execute(default + "\n" + controls)
        self.lua.execute('''
            assert(fr.SaveEntities and fr.SaveEntitiesCheckBox:GetChecked())
            label:OnMousePressed(MOUSE_LEFT); assert(not fr.SaveEntities)
            fr.SaveEntitiesCheckBox.enabled=false; label:OnMousePressed(MOUSE_LEFT); assert(not fr.SaveEntities)
        ''')

    def test_new_ui_phrases_in_both_languages(self):
        data = ROOT / "addons/mc_engine/data_static/mc/i18n"
        for namespace, keys in [
            ("save", ["save_entities", "save_entities_help"]),
            ("config", ["cleanup.button", "cleanup.confirm", "cleanup.done", "cleanup.admin_only",
                        "setting.mc_cleanup_drops.label", "setting.mc_cleanup_drops.help"]),
        ]:
            for lang in ["en_us", "zh_cn"]:
                phrases = json.loads((data / namespace / f"mc_engine.{lang}.json").read_text(encoding="utf-8"))["entries"]
                for key in keys:
                    self.assertTrue(phrases[key])


class PotionPersistence(unittest.TestCase):
    def setUp(self):
        self.lua = runtime()
        self.lua.execute((POTIONS / "sh_contract.lua").read_text(encoding="utf-8"))
        self.lua.execute('''
            MCITEM.Potions.Effects={poison={},speed={},absorption={},instant_health={instant=true}}
            MCITEM.Potions.GetMinecraftHealthScale=function() return 1 end
            damage=0; MCITEM.Potions.DamageMagic=function() damage=damage+1 end
            function target() return {IsPlayer=function() return false end,IsNPC=function() return true end,
              SetNW2String=function() end,SetNW2Int=function() end,SetNW2Bool=function() end,
              SetNW2Float=function() end,Health=function() return 50 end} end
        ''')
        self.lua.execute((POTIONS / "status/sv_runtime.lua").read_text(encoding="utf-8"))

    def test_hidden_absorption_and_remaining_periodic_time(self):
        self.lua.execute('''
            local P=MCITEM.Potions; local a=target()
            assert(P.ApplyEffect(a,{id='poison',durationTicks=101,amplifier=1}))
            assert(P.ApplyEffect(a,{id='poison',durationTicks=301,amplifier=0}))
            assert(P.ApplyEffect(a,{id='absorption',durationTicks=200,amplifier=1}))
            P.SetAbsorptionAmount(a,2)
            local saved=util.JSONToTable(util.TableToJSON(P.ExportPersistentState(a)))
            now=1000; local b=target(); assert(P.RestorePersistentState(b,saved))
            local poison=P.GetEffect(b,'poison')
            assert(poison.durationTicks==101 and poison.hidden.durationTicks==301 and poison.hidden.amplifier==0)
            assert(P.GetAbsorptionAmount(b)==2 and damage==0 and P.Tracked[b])
            -- Finite periodic ticks use duration modulo the interval, so restoring
            -- the remaining tick count preserves the exact next damage phase.
            P.Tracked[a]=nil; now=1000.01; callbacks['MCITEM.Potions.StatusTick']()
            assert(poison.durationTicks==93 and poison.hidden.durationTicks==293)
            assert(damage==1 and P.GetAbsorptionAmount(b)==2)
        ''')

    def test_infinite_phase_and_malformed_data(self):
        self.lua.execute('''
            local P=MCITEM.Potions; local a=target()
            assert(P.ApplyEffect(a,{id='poison',durationTicks=-1,amplifier=0}))
            P.StatusTick=24; local saved=P.ExportPersistentState(a); P.StatusTick=100
            local b=target(); assert(P.RestorePersistentState(b,saved))
            assert(P.GetEffect(b,'poison').persistentTickOffset==-76)
            saved.effects.poison='bad'; assert(not P.ValidatePersistentState(saved))
            saved.effects={instant_health={id='instant_health',durationTicks=1,amplifier=0,
              ambient=false,visible=true,showIcon=true}}; assert(not P.ValidatePersistentState(saved))
            saved.effects={}; saved.absorption=math.huge; assert(not P.ValidatePersistentState(saved))
        ''')


if __name__ == "__main__":
    unittest.main()
