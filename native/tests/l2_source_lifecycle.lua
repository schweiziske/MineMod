-- Explicit client-side diagnostic; does not enable Native or mutate the world.
-- Execute this file's contents through the client Lua bridge after loading the DLL.
assert(CLIENT and mcmesh and mcmesh.L2Version() == 2, "load the local Native L2 DLL first")
local module = mcmesh
local resources = {}
collectgarbage("collect")
collectgarbage("collect")
local before = module.GetL2Stats()
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message)
end
local function failed(fn, text)
    local value, reason = fn()
    check(value == nil and type(reason) == "string" and reason:find(text, 1, true), "expected failure: " .. text)
end
local function packet(mode)
    local p = {}
    for i = 1, 46 do p[i] = 0 end
    p[1], p[2], p[3], p[4], p[5], p[30] = mode, 1, 3, 1, 255, 1
    local positions = {{0,0,0},{0,1,0},{1,1,0},{1,0,0}}
    for corner = 1, 4 do
        for axis = 1, 3 do p[7 + (corner - 1) * 3 + axis] = positions[corner][axis] end
        p[20 + (corner - 1) * 2], p[21 + (corner - 1) * 2] = positions[corner][1], positions[corner][2]
        p[31 + (corner - 1) * 4] = corner - 1
    end
    return p
end
local function run()
    local declaration = CreateMaterial("mc_native_l2_lifecycle_declaration_v1", "screenspace_general_8tex", {
        ["$basetexture"] = "vgui/white", ["$x360appchooser"] = 1, ["$vertexcolor"] = 1,
    })
    local name = "!" .. declaration:GetName()
    local snapshot = {x = -2, y = -2, z = -2, sx = 5, sy = 5, sz = 5}
    local template = assert(module.CompileL2Template(packet(0)))
    local commands = {template, 0, 0, 0, 10, 20, 30, 2, 31, 127, false}
    local function reader() return 1048576 + 240, 1 end
    local function build(cmd, read, first, material)
        local result, reason = module.BuildL2Mesh(cmd, read, snapshot, first or 0, material or name)
        if result then resources[#resources + 1] = result.mesh end
        return result, reason
    end
    failed(function() return module.CompileL2Template({}) end, "46")
    local malformed = packet(0)
    malformed[20] = math.huge
    failed(function() return module.CompileL2Template(malformed) end, "non-finite")
    failed(function() return build({}, reader) end, "command count")
    failed(function() return build(commands, reader, 1048576) end, "atlas")
    failed(function() return build(commands, function() error("injected reader failure") end) end, "injected reader failure")
    failed(function() return build(commands, function() return nil end) end, "numeric")
    failed(function() return build(commands, reader, 0, "!mc_native_l2_missing_material") end, "material not found")
    check(module.GetL2Stats().liveMeshes == before.liveMeshes, "failed build leaked Source mesh")
    -- Match the production declaration, then exercise alternate Source layouts.
    -- Screenspace/UnlitGeneric may omit NORMAL; it must not be required or written.
    local declarations = {
        declaration,
        CreateMaterial("mc_native_l2_lifecycle_unlit_v1", "UnlitGeneric", {
            ["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1,
        }),
        CreateMaterial("mc_native_l2_lifecycle_lit_v1", "VertexLitGeneric", {
            ["$basetexture"] = "vgui/white", ["$vertexcolor"] = 1, ["$vertexalpha"] = 1,
        }),
    }
    for _, material in ipairs(declarations) do
        local candidate, reason = build(commands, reader, 0, "!" .. material:GetName())
        check(candidate ~= nil, material:GetShader() .. " declaration rejected: " .. tostring(reason))
        check(candidate.mesh:IsValid() and candidate.vertices == 4 and candidate.indices == 6,
            material:GetShader() .. " declaration mesh invalid")
        candidate.mesh:Destroy()
    end
    check(module.GetL2Stats().liveMeshes == before.liveMeshes, "declaration tests leaked Source mesh")
    local nested = false
    local result = assert(build(commands, function()
        if not nested then
            nested = true
            failed(function() return build(commands, reader) end, "recursive")
        end
        return reader()
    end, 1048575))
    check(nested and result.mesh:IsValid(), "reentry corrupted outer build")
    check(result.vertices == 4 and result.indices == 6, "indexed mesh counts")
    check(#result.pixels == 4 and result.pixels[1] == 0x1FFFF000, "corner transport")
    check(result.occlusion[1] == 4294967295, "flat AO")
    check(table.concat(result.bounds, ",") == "10,20,30,12,22,30", "mesh bounds")
    result.mesh:Destroy()
    result.mesh:Destroy()
    check(not result.mesh:IsValid(), "Destroy must be idempotent")
    local drawn = pcall(function() result.mesh:Draw() end)
    check(not drawn, "destroyed Draw must fail")

    local fluid = assert(module.CompileL2Template(packet(2)))
    local prepared = {0x12345678, 0, 0xFFFFFFFF, 0x01FFFFFF}
    local fluidCommands = {fluid, 0, 0, 0, 0, 0, 0, 1, 0, 255, prepared}
    local water = assert(build(fluidCommands, function() error("prepared quad read world") end))
    for corner = 1, 4 do check(water.pixels[corner] == prepared[corner], "prepared pixel changed") end
    water.mesh:Destroy()

    -- Drop commands/templates during a protected reader; C++ must own its inputs.
    local mutable = {assert(module.CompileL2Template(packet(0))), 0, 0, 0, 0, 0, 0, 1, 0, 255, false}
    local copied = assert(build(mutable, function()
        table.Empty(mutable)
        collectgarbage("collect")
        return reader()
    end))
    check(copied.mesh:IsValid(), "reader invalidated copied template")
    copied.mesh:Destroy()

    -- This mesh is deliberately left to GC, unlike resources kept for cleanup.
    local function orphan()
        local abandoned = assert(module.BuildL2Mesh(commands, reader, snapshot, 0, name))
        check(abandoned.mesh:IsValid(), "GC fixture mesh")
    end
    orphan()
    collectgarbage("collect")
    collectgarbage("collect")
    check(module.GetL2Stats().liveMeshes == before.liveMeshes, "mesh GC leaked Source resource")
end
local ok, reason = xpcall(run, debug.traceback)
for _, mesh in ipairs(resources) do mesh:Destroy() end
resources = nil
collectgarbage("collect")
collectgarbage("collect")
local after = module.GetL2Stats()
local report = {
    scope = "real Source construction/lifetime; no GPU pixel or world parity",
    ok = ok and after.liveMeshes == before.liveMeshes and after.liveTemplates <= before.liveTemplates,
    checks = checks, error = reason, before = before, after = after,
}
MCNativeL2Lifecycle = report
PrintTable(report)
assert(report.ok, reason or "Native L2 resources did not return to baseline")
return report
