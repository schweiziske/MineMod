"""Regression tests for rejected block names leaving orphaned state schemas.

Uses the existing LuaJIT harness; pass --deps <directory containing lupa>.
"""
import sys

from lua_runtime import ENGINE_LUA, Runtime, VirtualFS, run_tests


def runtime():
    rt = Runtime(VirtualFS([])).load_i18n()
    rt.run("""
        function math.Clamp(value, low, high)
            return math.max(low, math.min(high, value))
        end
    """)
    rt.run_file(ENGINE_LUA / "mc/custom/sh_custom_blocks.lua")
    return rt


def load_blocks(rt):
    rt.run_file(ENGINE_LUA / "mc/sh_blocks.lua")
    rt.run_file(ENGINE_LUA / "mc/sh_block_states.lua")
    rt.run_file(ENGINE_LUA / "mc/state/sh_project_block_state_schemas.lua")
    rt.run("""
        assert(MC.RegisterBlockStateSchema({
            name = "minecraft:air", blockId = 0,
        }))
    """)


def test_failed_registration_leaves_no_orphan_when_registry_freezes():
    for strict in (False, True):
        rt = runtime()
        load_blocks(rt)
        rt.call("TEST.SetConVar", "mc_strict", "1" if strict else "0")
        rt.run("""
            local nextID, orderCount = MC.CustomNextBlockID, #MC.CustomBlockOrder
            local ok, result, reason = pcall(MC.RegisterCustomBlock, {
                mcid = "mcbr:level0_carpet", disp = "rejected inline name",
                handlers = { OnTick = function() end },
            })
            if MC.StrictFaults() then
                assert(not ok and string.find(result, "inline_name_unsupported", 1, true))
            else
                assert(ok and result == nil and reason == "inline_name_unsupported")
            end
            assert(MC.PendingBlockStateSchemas["mcbr:level0_carpet"] == nil)
            assert(MC.CustomBlockDefs["mcbr:level0_carpet"] == nil)
            assert(MC.CustomBlockOrderSeen["mcbr:level0_carpet"] == nil)
            assert(MC.ResolveBlock("mcbr:level0_carpet") == nil)
            assert(MC.CustomNextBlockID == nextID)
            assert(#MC.CustomBlockOrder == orderCount)
            assert(not MC.HasBlockTickHandlers)
            assert(MC.RegisterCustomBlock({ mcid = "example:healthy" }).id == nextID)
            assert(MC.FinalizeBlockStateRegistry())
            for stateID = 1, MC.BlockStateCount - 1 do
                local schema = MC.BlockStateSchemaById[stateID]
                assert(MC.Blocks[schema.blockId], "orphan state " .. stateID)
            end
        """)
        assert "block_translation_key" in rt.faults()


def test_failed_replacement_preserves_existing_block_and_schema():
    rt = runtime()
    load_blocks(rt)
    rt.run("""
        local original = assert(MC.RegisterCustomBlock({
            id = 62020, mcid = "example:existing",
        }))
        local schema = MC.PendingBlockStateSchemas["example:existing"]
        local definition = MC.CustomBlockDefs["example:existing"]
        local orderCount = #MC.CustomBlockOrder
        for _, strict in ipairs({ "0", "1" }) do
            TEST.SetConVar("mc_strict", strict)
            local ok, result = pcall(MC.RegisterCustomBlock, {
                id = 62020, mcid = "example:existing", disp = "invalid",
            })
            assert(not ok or result == nil)
            assert(MC.Blocks[62020] == original)
            assert(MC.PendingBlockStateSchemas["example:existing"] == schema)
            assert(MC.CustomBlockDefs["example:existing"] == definition)
            assert(MC.CustomBlockOrderSeen["example:existing"])
            assert(#MC.CustomBlockOrder == orderCount)
        end
    """)


def test_invalid_schema_does_not_publish_block_or_consume_id():
    rt = runtime()
    load_blocks(rt)
    rt.run("""
        local nextID = MC.CustomNextBlockID
        local block = MC.RegisterCustomBlock({
            mcid = "example:bad_schema", stateSchema = { properties = false },
        })
        assert(block == nil)
        assert(MC.CustomNextBlockID == nextID)
        assert(MC.ResolveBlock("example:bad_schema") == nil)
        assert(MC.CustomBlockDefs["example:bad_schema"] == nil)
        assert(MC.PendingBlockStateSchemas["example:bad_schema"] == nil)
    """)


def test_pending_failure_is_removed_and_healthy_entries_still_register():
    for strict in (False, True):
        rt = runtime()
        rt.run("""
            assert(MC.RegisterCustomBlock({
                id = 62020, mcid = "mcbr:level0_carpet", disp = "invalid",
            }))
            assert(MC.RegisterCustomBlock({
                id = 62021, mcid = "example:queued_healthy",
            }))
        """)
        if strict:
            # Load the real block registry without draining yet, then raise
            # inside the explicit drain so its retained queue can be inspected.
            rt.run("TEST.drain = MC.RegisterPendingCustomBlocks; MC.RegisterPendingCustomBlocks = nil")
        rt.run_file(ENGINE_LUA / "mc/sh_blocks.lua")
        if strict:
            rt.run("""
                MC.RegisterPendingCustomBlocks = TEST.drain
                TEST.SetConVar("mc_strict", "1")
                local ok, reason = pcall(MC.RegisterPendingCustomBlocks)
                assert(not ok and string.find(reason, "inline_name_unsupported", 1, true))
                TEST.SetConVar("mc_strict", "0")
                MC.RegisterPendingCustomBlocks()
            """)
        rt.run("""
            assert(MC.CustomBlockDefs["mcbr:level0_carpet"] == nil)
            assert(MC.CustomBlockOrderSeen["mcbr:level0_carpet"] == nil)
            for _, key in ipairs(MC.CustomBlockOrder) do
                assert(key ~= "mcbr:level0_carpet")
            end
            assert(MC.Blocks[62020] == nil)
            assert(MC.Blocks[62021].mcid == "example:queued_healthy")
        """)


if __name__ == "__main__":
    sys.exit(run_tests(globals(), sys.argv[1:]))
