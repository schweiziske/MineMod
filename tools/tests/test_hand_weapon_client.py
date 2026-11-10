"""Client weapon ownership across predicted switches (LuaJIT, without GMod).

Run: python -m unittest discover -s tools/tests -p test_hand_weapon_client.py
"""

from pathlib import Path
import unittest

from lupa.luajit21 import LuaRuntime


ROOT = Path(__file__).resolve().parents[2]
BRIDGE_SOURCE = (ROOT / "addons/mc_engine/lua/mc/integration/cl_hand_weapon_bridge.lua").read_bytes()
ENTRY_SOURCE = (ROOT / "addons/mc_game/lua/mcgame/inventory/ui/cl_entry.lua").read_bytes()


class HandWeaponClientTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
        self.lua.execute(b"""
            CLIENT = true
            function IsValid(value) return type(value) == 'table' and not value.invalid end
            hooks = {}
            hook = {Add = function(event, id, fn)
                hooks[event] = hooks[event] or {}
                hooks[event][id] = fn
            end}
            ply = {weapons = {}, alive = true, request = ''}
            function ply:Alive() return self.alive end
            function ply:GetActiveWeapon() return self.active end
            function ply:GetWeapon(class) return self.weapons[class] end
            function ply:GetNW2String(key, default)
                assert(key == 'MC_HandWeaponSwitchRequest')
                return self.request
            end
            function LocalPlayer() return ply end
            function CurTime() return 1 end
            input = {SelectWeapon = function(weapon) predictedWeapon = weapon end}
            command = {SelectWeapon = function(_, weapon) predictedWeapon = weapon end}
            function newWeapon(class, proxy)
                local weapon = {class = class, proxy = proxy == true}
                function weapon:GetClass() return self.class end
                function weapon:GetOwner() return ply end
                function weapon:GetNW2Bool(key, default)
                    assert(key == 'MCITEM_InventoryProxy')
                    return self.proxy
                end
                ply.weapons[class] = weapon
                return weapon
            end
            MC = {HandWeaponBridge = {
                HandClass = 'mc_item_hand', InventoryClass = 'mc_inventory',
                GetSelected = function(player) return player.selected end,
                Resolve = function(stack) return stack.class end,
                ManagedClasses = {weapon_registered = true},
            }}
            hand = newWeapon('mc_item_hand')
            foreign = newWeapon('weapon_physgun')
            ply.active = hand
        """)
        self.lua.execute(BRIDGE_SOURCE)
        self.lua.execute(ENTRY_SOURCE)
        self.lua.execute(b"""
            api = MC.API.HandWeapon
            function assertForeign()
                assert(not api.IsManagedActive(ply), 'ordinary weapon retained MC ownership')
                assert(not api.IsSelectedActive(ply), 'ordinary weapon treated as selected MC item')
                assert(not MC.InventoryUI.IsInventoryWeapon(ply.active), 'HUD/input still owned by MC')
            end
        """)

    def test_return_still_predicts_switch_without_claiming_hud_or_input(self):
        self.lua.execute(b"""
            assert(api.IsManagedActive(ply))
            ply.request = '1:weapon_physgun'
            assert(not api.IsManagedSwitchPending(ply), 'return captured MC hotbar input')
            hooks.CreateMove.mc_hand_weapon_bridge_switch(command)
            assert(predictedWeapon == foreign, 'return must still select through prediction')
            ply.active = foreign
            assertForeign()
            ply.request = ''
            assertForeign()
        """)

    def test_hud_query_before_confirmation_does_not_latch_foreign_weapon(self):
        self.lua.execute(b"""
            ply.request = '1:weapon_physgun'
            ply.active = foreign
            -- HUDPaint/lifecycle can query before the server clears its request.
            api.IsManagedActive(ply)
            ply.request = ''
            for _ = 1, 3 do assertForeign() end
        """)

    def test_return_with_temporarily_missing_active_weapon_is_not_managed(self):
        self.lua.execute(b"""
            ply.active = nil
            ply.request = '1:weapon_physgun'
            assert(not api.IsManagedActive(ply))
            assert(not api.IsManagedSwitchPending(ply))
        """)

    def test_inventory_switch_retains_outgoing_identity_until_replacement(self):
        self.lua.execute(b"""
            local old = newWeapon('weapon_mc_old', true)
            ply.active = old
            assert(api.IsManagedActive(ply))
            old.proxy = false
            ply.selected = {class = 'weapon_mc_new'}
            ply.request = '2:weapon_mc_new'
            assert(api.IsManagedActive(ply), 'outgoing proxy lost identity too early')
            assert(api.IsManagedSwitchPending(ply))
            ply.active = nil
            assert(api.IsManagedActive(ply), 'managed switch gap lost ownership')
            local replacement = newWeapon('weapon_mc_new')
            ply.active = replacement
            assert(api.IsSelectedActive(ply), 'selected payload must cover delayed proxy replication')
            ply.request = ''
            replacement.proxy = true
            ply.selected = nil
            assert(api.IsManagedActive(ply))
            ply.active = foreign
            assertForeign()
        """)

    def test_registered_class_alone_does_not_claim_standalone_weapon(self):
        self.lua.execute(b"""
            ply.active = newWeapon('weapon_registered')
            ply.request = '3:weapon_registered'
            assertForeign()
            assert(not api.IsManagedSwitchPending(ply))
        """)

    def test_managed_base_and_proxy_switches_remain_pending(self):
        self.lua.execute(b"""
            ply.active = nil
            ply.request = '4:mc_item_hand'
            assert(api.IsManagedActive(ply))
            assert(api.IsManagedSwitchPending(ply))
            local proxy = newWeapon('weapon_mc_proxy', true)
            ply.request = '5:weapon_mc_proxy'
            assert(api.IsManagedSwitchPending(ply))
            ply.active = proxy
            assert(api.IsSelectedActive(ply))
            ply.active = newWeapon('mc_inventory')
            assert(api.IsManagedActive(ply))
            assert(not api.IsSelectedActive(ply))
        """)

    def test_invalid_or_dead_player_does_not_have_active_inventory(self):
        self.lua.execute(b"""
            assert(not api.IsManagedActive(nil))
            assert(not api.IsManagedSwitchPending(nil))
            ply.alive = false
            assert(not api.IsManagedActive(ply))
        """)


if __name__ == '__main__':
    unittest.main()
