#include "pch.h"
#include "l2_bridge.h"
#include "l2_core.h"
#include "l2_worker.h"
#include "world_bridge.h"
#include "world_mesh.h"
#include "global.h"
#include <algorithm>
#include <cmath>
#include <exception>
#include <limits>
#include <stdexcept>
#include <string>
#include <chrono>

namespace mcmesh::l2bridge {
using namespace GarrysMod::Lua;
namespace {
int templateType = -1, meshType = -1, cubeType = -1, modelType = -1;
using ModelHandle = std::shared_ptr<const l2::Model>;
uint64_t templates = 0, liveTemplates = 0, batches = 0, liveMeshes = 0;
uint64_t vertices = 0, indices = 0, reads = 0, hits = 0, failures = 0;
bool building = false;
l2::WorkerPool workers;
std::unordered_map<uint64_t, std::shared_ptr<const world::MeshSnapshot>> worldTickets;
double snapshotMS = 0, commandMS = 0, uploadMS = 0;
double clockMS() {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

struct MeshHandle {
    IMesh* mesh = nullptr;
    IMaterial* material = nullptr;
    MeshHandle* previous = nullptr;
    MeshHandle* next = nullptr;
};
MeshHandle* firstMesh = nullptr;

void unlink(MeshHandle* handle) {
    if (handle->previous) handle->previous->next = handle->next;
    else firstMesh = handle->next;
    if (handle->next) handle->next->previous = handle->previous;
    handle->previous = handle->next = nullptr;
}
void destroy(MeshHandle* handle) {
    if (!handle || !handle->mesh) return;
    CMatRenderContextPtr context(g_matsys);
    context->DestroyStaticMesh(handle->mesh);
    handle->mesh = nullptr;
    handle->material->DecrementReferenceCount();
    handle->material = nullptr;
    unlink(handle);
    --liveMeshes;
}
LUA_FUNCTION(meshDestroy) {
    destroy(LUA->GetUserType<MeshHandle>(1, meshType));
    return 0;
}
LUA_FUNCTION(meshValid) {
    auto* handle = LUA->GetUserType<MeshHandle>(1, meshType);
    LUA->PushBool(handle && handle->mesh);
    return 1;
}
LUA_FUNCTION(meshDraw) {
    auto* handle = LUA->GetUserType<MeshHandle>(1, meshType);
    if (!handle || !handle->mesh) {
        LUA->ThrowError("Native L2: drawing a destroyed mesh");
        return 0;
    }
    // The Lua render stage has already bound its material and view transform.
    handle->mesh->Draw();
    return 0;
}
LUA_FUNCTION(templateGC) {
    if (LUA->GetUserType<l2::Template>(1, templateType)) {
        LUA->SetUserType(1, nullptr);
        --liveTemplates;
    }
    return 0;
}
LUA_FUNCTION(modelGC) {
    delete LUA->GetUserType<ModelHandle>(1, modelType);
    LUA->SetUserType(1, nullptr);
    return 0;
}
void function(ILuaBase* lua, const char* name, CFunc fn) {
    lua->PushCFunction(fn); lua->SetField(-2, name);
}
void numberField(ILuaBase* lua, const char* name, double value) {
    lua->PushNumber(value); lua->SetField(-2, name);
}
double number(ILuaBase* lua, int at) {
    l2::require(lua->IsType(at, Type::Number), "expected numeric L2 field");
    const double value = lua->GetNumber(at);
    l2::require(std::isfinite(value), "non-finite L2 field");
    return value;
}
double item(ILuaBase* lua, int table, int index) {
    lua->PushNumber(index); lua->RawGet(table);
    const double value = number(lua, -1);
    lua->Pop();
    return value;
}
int field(ILuaBase* lua, const char* name, int low, int high) {
    lua->PushString(name); lua->RawGet(3);
    const int value = l2::integer(number(lua, -1), low, high, "invalid L2 snapshot field");
    lua->Pop();
    return value;
}
void resetStack(ILuaBase* lua, int top) {
    if (lua->Top() > top) lua->Pop(lua->Top() - top);
}
int failure(ILuaBase* lua, int top, const char* reason) {
    resetStack(lua, top);
    ++failures;
    lua->PushNil(); lua->PushString(reason);
    return 2;
}
l2::Cell readCell(void* data, int x, int y, int z) {
    auto* lua = static_cast<ILuaBase*>(data);
    lua->Push(2);
    lua->PushNumber(x); lua->PushNumber(y); lua->PushNumber(z);
    // A Lua error must not longjmp across C++ snapshot/vector destructors.
    if (lua->PCall(3, 3, 0) != 0) {
        const char* message = lua->IsType(-1, Type::String) ? lua->GetString(-1) : "non-string Lua reader error";
        throw std::runtime_error(std::string("L2 snapshot reader: ") + message);
    }
    const auto word = l2::integer(number(lua, -3), 0, 2097151, "invalid packed L2 cell");
    const double shade = number(lua, -2);
    l2::require(shade >= 0 && shade <= 1, "invalid L2 cell shade");
    uint32_t renderClass = 0;
    if (!lua->IsType(-1, Type::Nil)) {
        const double packed = number(lua, -1);
        l2::require(packed >= 0 && packed <= UINT32_MAX && packed == std::floor(packed), "invalid L2 render class");
        renderClass = static_cast<uint32_t>(packed);
    } else l2::require(!lua->IsType(4, Type::Table), "voxel input requires neighbour render classes");
    lua->Pop(3);
    return {static_cast<uint32_t>(word), static_cast<float>(shade), renderClass};
}

struct BuildGuard {
    BuildGuard() { l2::require(!building, "recursive L2 mesh build"); building = true; }
    ~BuildGuard() { building = false; }
};
void array(ILuaBase* lua, const uint32_t* values, size_t count) {
    lua->CreateTable();
    const int table = lua->Top();
    for (size_t i = 0; i < count; ++i) {
        lua->PushNumber(static_cast<double>(i + 1));
        lua->PushNumber(values[i]); lua->RawSet(table);
    }
}
std::vector<l2::Work> readWork(ILuaBase* lua, int table, l2::Snapshot& snapshot, bool allowEmpty = false) {
    l2::require(lua->IsType(table, Type::Table), "invalid L2 commands table");
    const int length = lua->ObjLen(table);
    l2::require((length > 0 || allowEmpty) && length % 11 == 0 && length / 11 <= l2::MaxQuads, "invalid L2 command count");
    std::vector<l2::Work> work(length / 11);
    for (unsigned i = 0; i < work.size(); ++i) {
        const unsigned offset = i * 11;
        lua->PushNumber(offset + 1); lua->RawGet(table);
        const auto* geometry = lua->GetUserType<l2::Template>(-1, templateType);
        l2::require(geometry != nullptr, "invalid or destroyed L2 template");
        auto& w = work[i];
        w.geometry = *geometry;
        lua->Pop();
        auto& c = w.command;
        for (unsigned a = 0; a < 3; ++a) {
            c.source[a] = l2::integer(item(lua, table, offset + 2 + a), INT32_MIN, INT32_MAX, "invalid L2 source coordinate");
            c.translation[a] = item(lua, table, offset + 5 + a);
        }
        c.size = item(lua, table, offset + 8);
        c.tint = l2::integer(item(lua, table, offset + 9), 0, 31, "invalid L2 tint");
        c.opacity = l2::integer(item(lua, table, offset + 10), 0, 255, "invalid L2 opacity");
        l2::validateCommand(w.geometry, c, snapshot, i);
        lua->PushNumber(offset + 11); lua->RawGet(table);
        if (w.geometry.mode == 2) {
            l2::require(lua->IsType(-1, Type::Table) && lua->ObjLen(-1) == 4, "prepared L2 quad requires four pixels");
            const int prepared = lua->Top();
            for (unsigned corner = 0; corner < 4; ++corner) {
                const double pixel = item(lua, prepared, corner + 1);
                l2::require(pixel >= 0 && pixel <= UINT32_MAX && pixel == std::floor(pixel), "invalid prepared pixel");
                c.prepared[corner] = static_cast<uint32_t>(pixel);
            }
        } else {
            l2::require(lua->IsType(-1, Type::Bool) && !lua->GetBool(-1), "unexpected prepared L2 pixels");
        }
        lua->Pop();
    }
    return work;
}
l2::Snapshot readSnapshot(ILuaBase* lua) {
    int origin[3] = {field(lua, "x", INT32_MIN, INT32_MAX), field(lua, "y", INT32_MIN, INT32_MAX),
        field(lua, "z", INT32_MIN, INT32_MAX)};
    int dimensions[3] = {field(lua, "sx", 5, 4096), field(lua, "sy", 5, 4096), field(lua, "sz", 5, 4096)};
    return l2::Snapshot(origin, dimensions, readCell, lua);
}
void readVoxels(ILuaBase* lua, l2::Input& input) {
    if (!lua->IsType(4, Type::Table)) return;
    const int cs = l2::integer(item(lua, 4, 2), 1, 64, "invalid voxel chunk width");
    const int ch = l2::integer(item(lua, 4, 3), 1, 64, "invalid voxel chunk height");
    input.blockSize = item(lua, 4, 1);
    input.maxQuads = l2::integer(item(lua, 4, 8), 1, l2::MaxQuads, "invalid voxel part limit");
    l2::require(input.blockSize > 0 && input.blockSize * std::max(cs, ch) <= FLT_MAX,
        "invalid voxel block size");
    int origin[3];
    for (int a = 0; a < 3; ++a)
        origin[a] = l2::integer(item(lua, 4, a + 4), INT32_MIN + 64, INT32_MAX - 128, "invalid voxel origin");
    lua->PushNumber(7); lua->RawGet(4);
    const int sections = lua->Top();
    l2::require(lua->IsType(sections, Type::Table) && lua->ObjLen(sections) <= 512, "invalid voxel sections");
    for (int s = 1; s <= lua->ObjLen(sections); ++s) {
        lua->PushNumber(s); lua->RawGet(sections);
        const int section = lua->Top();
        l2::require(lua->IsType(section, Type::Table), "invalid voxel section");
        lua->PushNumber(1); lua->RawGet(section);
        const int indicesTable = lua->Top();
        lua->PushNumber(2); lua->RawGet(section);
        const int statesTable = lua->Top();
        lua->PushNumber(3); lua->RawGet(section);
        const int recipes = lua->Top();
        l2::require(lua->IsType(indicesTable, Type::Table) && lua->IsType(statesTable, Type::Table)
            && lua->IsType(recipes, Type::Table), "invalid voxel index/recipe arrays");
        const int count = lua->ObjLen(indicesTable);
        l2::require(count <= 512 && lua->ObjLen(statesTable) == count, "invalid voxel section length");
        int low[3], high[3];
        for (int a = 0; a < 3; ++a) {
            low[a] = l2::integer(item(lua, section, a + 4), 0, (a == 2 ? ch : cs) - 1, "invalid voxel minimum");
            high[a] = l2::integer(item(lua, section, a + 7), low[a], std::min(low[a] + 7, (a == 2 ? ch : cs) - 1),
                "invalid voxel maximum");
        }
        std::unordered_map<uint32_t, std::pair<unsigned, bool>> mapped;
        lua->PushNil();
        while (lua->Next(recipes)) {
            const double state = number(lua, -2);
            l2::require(state > 0 && state <= UINT32_MAX && state == std::floor(state), "invalid voxel recipe state");
            const int recipe = lua->Top();
            l2::require(lua->IsType(recipe, Type::Table), "invalid voxel recipe");
            lua->PushNumber(1); lua->RawGet(recipe);
            const auto* cube = lua->GetUserType<l2::Cube>(-1, cubeType);
            const auto* model = lua->GetUserType<ModelHandle>(-1, modelType);
            l2::require(cube != nullptr || (model && *model), "invalid compiled voxel recipe");
            l2::require(mapped.size() < 512 && input.cubes.size() + input.models.size() < l2::WorkerPool::MaxSectionQuads / 6,
                "voxel recipe count exceeds budget");
            if (cube) {
                auto value = *cube;
                lua->Pop();
                for (unsigned f = 0; f < 6; ++f)
                    value.groups[f] = l2::integer(item(lua, recipe, f + 2), 1, l2::WorkerPool::MaxParts, "invalid voxel group");
                mapped.emplace(static_cast<uint32_t>(state), std::make_pair(static_cast<unsigned>(input.cubes.size()), false));
                input.cubes.push_back(value);
            } else {
                l2::ModelBinding value{*model, 0};
                lua->Pop();
                value.group = l2::integer(item(lua, recipe, 2), 1, l2::WorkerPool::MaxParts, "invalid model group");
                mapped.emplace(static_cast<uint32_t>(state), std::make_pair(static_cast<unsigned>(input.models.size()), true));
                input.models.push_back(std::move(value));
            }
            lua->Pop();
        }
        for (int i = 1; i <= count; ++i) {
            const double state = item(lua, statesTable, i);
            l2::require(state > 0 && state <= UINT32_MAX && state == std::floor(state), "invalid voxel state");
            const auto found = mapped.find(static_cast<uint32_t>(state));
            const int li = l2::integer(item(lua, indicesTable, i), 0, cs * cs * ch - 1, "invalid voxel local index");
            const int local[3] = {li % cs, li / cs % cs, li / (cs * cs)};
            for (int a = 0; a < 3; ++a)
                l2::require(local[a] >= low[a] && local[a] <= high[a], "voxel index outside its section");
            if (found == mapped.end()) continue;
            l2::require(input.voxels.size() < l2::WorkerPool::MaxSectionQuads / 6, "voxel section exceeds cell budget");
            l2::Voxel voxel;
            voxel.cube = found->second.first;
            voxel.model = found->second.second;
            for (int a = 0; a < 3; ++a) {
                voxel.source[a] = origin[a] + local[a];
                voxel.translation[a] = local[a] * input.blockSize;
            }
            input.snapshot.validateSource(voxel.source);
            input.voxels.push_back(voxel);
        }
        lua->Pop(4);
    }
    lua->Pop();
}
}

void initialize(ILuaBase* lua) {
    modelType = lua->CreateMetaTable("MCSWEP_L2Model_v1");
    function(lua, "__gc", modelGC);
    lua->PushString("immutable Native L2 model"); lua->SetField(-2, "__metatable");
    lua->Pop();
    cubeType = lua->CreateMetaTable("MCSWEP_L2Cube_v1");
    lua->PushString("immutable Native L2 cube"); lua->SetField(-2, "__metatable");
    lua->Pop();
    templateType = lua->CreateMetaTable("MCSWEP_L2Template_v1");
    function(lua, "__gc", templateGC);
    lua->PushString("immutable Native L2 template"); lua->SetField(-2, "__metatable");
    lua->Pop();
    meshType = lua->CreateMetaTable("MCSWEP_L2Mesh_v1");
    function(lua, "Draw", meshDraw);
    function(lua, "Destroy", meshDestroy);
    function(lua, "IsValid", meshValid);
    function(lua, "__gc", meshDestroy);
    lua->Push(-1); lua->SetField(-2, "__index");
    lua->PushString("Native L2 mesh"); lua->SetField(-2, "__metatable");
    lua->Pop();
}
void shutdown() {
    workers.stop();
    worldTickets.clear();
    while (firstMesh) destroy(firstMesh);
}
int version(ILuaBase* lua) { lua->PushNumber(2); return 1; }
int compileCube(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        const int origin[3] = {-2,-2,-2}, dims[3] = {5,5,5};
        l2::Snapshot snapshot(origin, dims, readCell, lua);
        const auto work = readWork(lua, 1, snapshot);
        l2::require(work.size() == 6, "cube recipe requires six ordered faces");
        l2::Cube cube;
        cube.block = l2::integer(number(lua, 2), 1, 536870911, "invalid cube block ID");
        std::copy(work.begin(), work.end(), cube.faces.begin());
        l2::validateCube(cube);
        lua->PushUserType_Value(cube, cubeType);
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int compileModel(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        l2::require(lua->IsType(1, Type::Table), "invalid model plan");
        const int count = lua->ObjLen(1);
        l2::require(count > 0 && count <= 255, "invalid model plan group count");
        auto model = std::make_shared<l2::Model>();
        model->block = l2::integer(number(lua, 2), 1, 536870911, "invalid model block ID");
        l2::require(lua->IsType(3, Type::Bool), "model requires internal-face policy");
        model->keepInternalFaces = lua->GetBool(3);
        const int origin[3] = {-2,-2,-2}, dims[3] = {5,5,5};
        l2::Snapshot snapshot(origin, dims, readCell, lua);
        size_t total = 0;
        for (int i = 1; i <= count; ++i) {
            lua->PushNumber(i); lua->RawGet(1);
            const int groupTable = lua->Top();
            l2::require(lua->IsType(groupTable, Type::Table), "invalid model group");
            l2::ModelGroup group;
            group.salt = l2::integer(item(lua, groupTable, 1), 0, 65535 * 132, "invalid model salt");
            lua->PushNumber(2); lua->RawGet(groupTable);
            const int alternatives = lua->Top();
            l2::require(lua->IsType(alternatives, Type::Table) && lua->ObjLen(alternatives) > 0
                && lua->ObjLen(alternatives) <= 255, "invalid model alternatives");
            for (int a = 1; a <= lua->ObjLen(alternatives); ++a) {
                lua->PushNumber(a); lua->RawGet(alternatives);
                const int alternative = lua->Top();
                l2::require(lua->IsType(alternative, Type::Table), "invalid model alternative");
                l2::ModelAlternative value;
                value.weight = l2::integer(item(lua, alternative, 1), 1, 255, "invalid model weight");
                lua->PushNumber(2); lua->RawGet(alternative);
                l2::require(lua->IsType(-1, Type::Bool), "invalid model AO");
                value.modelAO = lua->GetBool(-1);
                lua->Pop();
                lua->PushNumber(3); lua->RawGet(alternative);
                auto shaded = readWork(lua, lua->Top(), snapshot, true);
                lua->Pop();
                lua->PushNumber(4); lua->RawGet(alternative);
                auto flat = readWork(lua, lua->Top(), snapshot, true);
                lua->Pop();
                lua->PushNumber(5); lua->RawGet(alternative);
                const int culls = lua->Top();
                l2::require(shaded.size() == flat.size() && lua->IsType(culls, Type::Table)
                    && lua->ObjLen(culls) == shaded.size(), "model AO/cull array count mismatch");
                total += shaded.size();
                l2::require(total <= l2::WorkerPool::MaxSectionQuads, "model plan exceeds quad budget");
                for (size_t q = 0; q < shaded.size(); ++q) {
                    const auto& first = shaded[q];
                    const auto& second = flat[q];
                    l2::require(first.command.tint == second.command.tint && first.command.opacity == second.command.opacity
                        && second.command.size == 1, "model AO variants changed command");
                    for (unsigned axis = 0; axis < 3; ++axis)
                        l2::require(second.command.source[axis] == 0 && second.command.translation[axis] == 0,
                            "model AO variant changed origin");
                    l2::ModelQuad quad;
                    quad.work = first;
                    quad.withoutAO = second.geometry;
                    quad.cullFace = l2::integer(item(lua, culls, static_cast<int>(q + 1)), 0, 6, "invalid model cull");
                    value.quads.push_back(std::move(quad));
                }
                lua->Pop();
                group.alternatives.push_back(std::move(value));
                lua->Pop();
            }
            model->groups.push_back(std::move(group));
            lua->Pop(2);
        }
        l2::validateModel(*model);
        auto handle = std::make_unique<ModelHandle>(std::move(model));
        lua->PushUserType(handle.get(), modelType);
        handle.release();
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int compileTemplate(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        l2::require(lua->IsType(1, Type::Table) && lua->ObjLen(1) == l2::TemplateSize,
            "L2 template must contain exactly 46 numbers");
        double packet[l2::TemplateSize];
        for (unsigned i = 0; i < l2::TemplateSize; ++i) packet[i] = item(lua, 1, i + 1);
        const auto value = l2::compile(packet);
        lua->PushUserType_Value(value, templateType);
        ++templates; ++liveTemplates;
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}

static int upload(ILuaBase* lua, const l2::Part& part, unsigned first, const std::string& materialName) {
    const int top = lua->Top();
    MeshHandle* handle = nullptr;
    try {
        const double started = clockMS();
        const unsigned count = static_cast<unsigned>(part.quads.size());
        l2::require(!materialName.empty() && materialName.front() == '!', "L2 requires a runtime declaration material");
        l2::require(g_matsys != nullptr, "L2 material system unavailable");
        IMaterial* material = g_matsys->FindMaterial(materialName.c_str(), TEXTURE_GROUP_OTHER, false);
        l2::require(material && !material->IsErrorMaterial(), "L2 declaration material not found");
        const VertexFormat_t format = material->GetVertexFormat() & ~VERTEX_FORMAT_COMPRESSED;
        constexpr auto required = VERTEX_POSITION | VERTEX_COLOR;
        constexpr VertexFormat_t allowed = required | VERTEX_NORMAL |
            VERTEX_FORMAT_VERTEX_SHADER | VERTEX_FORMAT_USE_EXACT_FORMAT |
            VERTEX_TEXCOORD_MASK(0) | VERTEX_TEXCOORD_MASK(1);
        const bool hasNormal = (VertexFlags(format) & VERTEX_NORMAL) != 0;
        const int secondaryUV = TexCoordSize(1, format);
        if ((VertexFlags(format) & required) != required || TexCoordSize(0, format) != 2 ||
            (secondaryUV != 0 && secondaryUV != 2) || (format & ~allowed) != 0) {
            throw std::runtime_error("L2 declaration material requires position, COLOR and 2D UV0, "
                "with only optional normal and 2D UV1: material=" + materialName +
                " format=" + std::to_string(format) + " uv0=" + std::to_string(TexCoordSize(0, format)) +
                " uv1=" + std::to_string(secondaryUV));
        }
        CMatRenderContextPtr context(g_matsys);
        l2::require(!!context, "L2 render context unavailable");
        // GC owns the handle before acquiring a Source resource.
        lua->PushUserType_Value(MeshHandle{}, meshType);
        handle = lua->GetUserType<MeshHandle>(-1, meshType);
        handle->mesh = context->CreateStaticMesh(format, TEXTURE_GROUP_STATIC_VERTEX_BUFFER_OTHER, material);
        l2::require(handle->mesh != nullptr, "L2 CreateStaticMesh failed");
        handle->material = material;
        material->IncrementReferenceCount();
        handle->next = firstMesh;
        if (firstMesh) firstMesh->previous = handle;
        firstMesh = handle; ++liveMeshes;
        CMeshBuilder builder;
        builder.Begin(handle->mesh, MATERIAL_TRIANGLES, count * 4, count * 6);
        unsigned address = first * 4;
        for (const auto& quad : part.quads) for (const auto& v : quad.vertices) {
            builder.Position3f(v.position[0], v.position[1], v.position[2]);
            if (hasNormal) builder.Normal3f(v.normal[0], v.normal[1], v.normal[2]);
            builder.TexCoord2f(0, v.uv[0], v.uv[1]);
            if (secondaryUV) builder.TexCoord2f(1, 0, 0);
            builder.Color4ub(static_cast<uint8_t>(address), static_cast<uint8_t>(address >> 8),
                static_cast<uint8_t>(address >> 16), v.color[3]);
            ++address;
            builder.AdvanceVertex();
        }
        for (unsigned i = 0; i < count; ++i) for (unsigned corner : l2::Triangle) {
            builder.Index(static_cast<unsigned short>(i * 4 + corner));
            builder.AdvanceIndex();
        }
        builder.End();
        const int meshIndex = lua->Top();
        lua->CreateTable();
        lua->Push(meshIndex); lua->SetField(-2, "mesh");
        numberField(lua, "vertices", count * 4); numberField(lua, "indices", count * 6);
        array(lua, part.pixels.data(), part.pixels.size()); lua->SetField(-2, "pixels");
        array(lua, part.occlusion.data(), part.occlusion.size()); lua->SetField(-2, "occlusion");
        lua->CreateTable();
        for (unsigned i = 0; i < 6; ++i) {
            lua->PushNumber(i + 1); lua->PushNumber(part.bounds[i]); lua->RawSet(-3);
        }
        lua->SetField(-2, "bounds");
        ++batches; vertices += count * 4; indices += count * 6;
        uploadMS += clockMS() - started;
        return 1;
    } catch (const std::exception& e) {
        destroy(handle);
        return failure(lua, top, e.what());
    }
}
// Retained only for explicit synchronous diagnostics/compatibility, not terrain.
int buildMesh(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        BuildGuard guard;
        l2::require(lua->IsType(2, Type::Function) && lua->IsType(3, Type::Table) &&
            lua->IsType(5, Type::String), "invalid L2 build arguments");
        auto snapshot = readSnapshot(lua);
        const auto work = readWork(lua, 1, snapshot);
        const unsigned first = l2::integer(number(lua, 4), 0, l2::AtlasQuads - static_cast<int>(work.size()),
            "L2 batch exceeds corner atlas");
        const std::string material = lua->GetString(5);
        l2::Part part;
        part.quads.resize(work.size()); part.pixels.resize(work.size() * 4); part.occlusion.resize(work.size());
        std::fill(part.bounds, part.bounds + 3, FLT_MAX);
        std::fill(part.bounds + 3, part.bounds + 6, -FLT_MAX);
        for (unsigned i = 0; i < work.size(); ++i) {
            auto& q = part.quads[i];
            q = l2::evaluate(work[i].geometry, work[i].command, snapshot, i);
            std::copy(std::begin(q.pixels), std::end(q.pixels), part.pixels.begin() + i * 4);
            part.occlusion[i] = q.occlusion;
            for (const auto& v : q.vertices) for (unsigned a = 0; a < 3; ++a) {
                part.bounds[a] = std::min(part.bounds[a], v.position[a]);
                part.bounds[a + 3] = std::max(part.bounds[a + 3], v.position[a]);
            }
        }
        reads += snapshot.reads; hits += snapshot.hits;
        return upload(lua, part, first, material);
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int submitSection(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        BuildGuard guard;
        l2::require(lua->IsType(1, Type::Table) && lua->IsType(2, Type::Function) &&
            lua->IsType(3, Type::Table), "invalid L2 submission arguments");
        workers.start();
        if (!workers.canSubmit()) { lua->PushBool(false); return 1; }
        const double started = clockMS();
        const int count = lua->ObjLen(1);
        l2::require(count >= 0 && count <= l2::WorkerPool::MaxParts
            && (count > 0 || lua->IsType(4, Type::Table)), "L2 section exceeds part budget");
        auto input = std::make_unique<l2::Input>(readSnapshot(lua));
        input->parts.reserve(count);
        size_t quads = 0;
        for (int i = 1; i <= count; ++i) {
            lua->PushNumber(i); lua->RawGet(1);
            input->parts.push_back(readWork(lua, lua->Top(), input->snapshot));
            lua->Pop();
            quads += input->parts.back().size();
            l2::require(quads <= l2::WorkerPool::MaxSectionQuads, "L2 section exceeds quad budget");
        }
        readVoxels(lua, *input);
        commandMS += clockMS() - started;
        const double frozenAt = clockMS();
        l2::prefetchVoxels(*input);
        // Capture only cells reachable by these commands, once per section.
        // Detach the reader before the immutable snapshot crosses threads.
        for (const auto& part : input->parts) for (const auto& w : part)
            l2::prefetch(w.geometry, w.command, input->snapshot);
        snapshotMS += clockMS() - frozenAt;
        reads += input->snapshot.reads; hits += input->snapshot.hits;
        const auto id = workers.submit(std::move(input));
        if (id) lua->PushNumber(static_cast<double>(id));
        else lua->PushBool(false);
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int submitWorldSection(ILuaBase* lua) {
    const int top = lua->Top();
    uint64_t submitted = 0;
    try {
        BuildGuard guard;
        auto& store = worldbridge::session(lua, 2).store();
        const world::Coord chunk{
            l2::integer(number(lua, 3), INT32_MIN, INT32_MAX, "invalid world chunk x"),
            l2::integer(number(lua, 4), INT32_MIN, INT32_MAX, "invalid world chunk y"),
            l2::integer(number(lua, 5), INT32_MIN, INT32_MAX, "invalid world chunk z")};
        store.config().validateChunk(chunk);
        const unsigned section = l2::integer(number(lua, 6), 1, store.config().sectionCount(), "invalid world section") - 1;
        l2::require(lua->IsType(1, Type::Table) && lua->IsType(7, Type::Table) && lua->IsType(9, Type::Bool),
            "invalid world L2 submission");
        workers.start();
        if (!workers.canSubmit()) { lua->PushBool(false); return 1; }
        const auto started = clockMS();
        auto source = std::make_shared<const world::MeshSnapshot>(store.meshSnapshot(chunk, section));
        const int origin[3] = {source->origin.x, source->origin.y, source->origin.z};
        const int dims[3] = {source->dimensions.x, source->dimensions.y, source->dimensions.z};
        auto input = std::make_unique<l2::Input>(l2::Snapshot(origin, dims, source));
        input->blockSize = store.config().blockSize;
        input->maxQuads = l2::integer(number(lua, 8), 1, l2::MaxQuads, "invalid world part limit");
        std::unordered_map<uint32_t, world::MeshRecipe> recipes;
        lua->PushNil();
        while (lua->Next(7)) {
            const auto state = l2::integer(number(lua, -2), 1, int(store.catalog()->states.size()) - 1, "invalid recipe state");
            const int table = lua->Top();
            l2::require(lua->IsType(table, Type::Table), "invalid world recipe");
            lua->PushNumber(1); lua->RawGet(table);
            const auto* cube = lua->GetUserType<l2::Cube>(-1, cubeType);
            const auto* model = lua->GetUserType<ModelHandle>(-1, modelType);
            world::MeshRecipe recipe;
            if (cube) {
                auto value = *cube;
                lua->Pop();
                for (unsigned f = 0; f < 6; ++f)
                    value.groups[f] = l2::integer(item(lua, table, f + 2), 1, l2::WorkerPool::MaxParts, "invalid cube group");
                recipe.index = unsigned(input->cubes.size()); recipe.maxQuads = 6;
                input->cubes.push_back(std::move(value));
            } else {
                l2::require(model && *model, "invalid world compiled model");
                l2::ModelBinding value{*model, 0};
                lua->Pop();
                value.group = l2::integer(item(lua, table, 2), 1, l2::WorkerPool::MaxParts, "invalid model group");
                recipe.index = unsigned(input->models.size()); recipe.model = true; recipe.maxQuads = value.model->maxQuads;
                input->models.push_back(std::move(value));
            }
            lua->GetField(table, "blocking");
            l2::require(lua->IsType(-1, Type::Bool), "missing topology classification");
            recipe.blocking = lua->GetBool(-1);
            lua->Pop();
            recipes.emplace(uint32_t(state), recipe);
            l2::require(recipes.size() <= 512, "world section recipe limit");
            lua->Pop();
        }
        input->instances = std::make_shared<world::MeshInstances>(source, chunk, section, std::move(recipes), lua->GetBool(9));
        const int count = lua->ObjLen(1);
        l2::require(count >= 0 && count <= l2::WorkerPool::MaxParts, "world section part limit");
        size_t quads = 0;
        for (int i = 1; i <= count; ++i) {
            lua->PushNumber(i); lua->RawGet(1);
            input->parts.push_back(readWork(lua, lua->Top(), input->snapshot));
            lua->Pop();
            quads += input->parts.back().size();
            l2::require(quads <= l2::WorkerPool::MaxSectionQuads, "world fallback quad limit");
        }
        commandMS += clockMS() - started;
        // The owned CPU reader is sampled only by the worker. No Lua prefetch.
        submitted = workers.submit(std::move(input));
        if (submitted) {
            worldTickets.emplace(submitted, std::move(source));
            lua->PushNumber(double(submitted));
        } else lua->PushBool(false);
        return 1;
    } catch (const std::exception& e) {
        if (submitted) workers.cancel(submitted);
        return failure(lua, top, e.what());
    }
}
int worldSectionCurrent(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        const auto id = uint64_t(l2::integer(number(lua, 1), 1, INT32_MAX, "invalid world L2 job"));
        const auto found = worldTickets.find(id);
        lua->PushBool(found != worldTickets.end() && worldbridge::session(lua, 2).store().current(*found->second));
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int sectionTopology(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        const auto id = uint64_t(l2::integer(number(lua, 1), 1, INT32_MAX, "invalid topology job"));
        const auto job = workers.ready(id);
        l2::require(job->error.empty(), job->error.c_str());
        const auto& value = job->topology;
        l2::require(value.uniform != 0 || !value.cells.empty(), "world topology was not requested");
        lua->CreateTable();
        for (unsigned face = 0; face < 6; ++face) {
            lua->PushNumber(face + 1); lua->PushNumber(value.faces[face]); lua->RawSet(-3);
        }
        lua->PushBool(value.graphOpen); lua->SetField(-2, "graphOpen");
        if (value.uniform) numberField(lua, "uniform", value.uniform);
        else {
            lua->PushString(reinterpret_cast<const char*>(value.cells.data()), unsigned(value.cells.size()));
            lua->SetField(-2, "cells");
        }
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int pollSection(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        const auto id = static_cast<uint64_t>(l2::integer(number(lua, 1), 1, INT32_MAX, "invalid L2 job"));
        const auto state = workers.state(id);
        if (state == l2::JobState::Failed) {
            const auto job = workers.ready(id);
            return failure(lua, top, job->error.c_str());
        }
        lua->PushBool(state == l2::JobState::Ready);
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int sectionParts(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        const auto id = static_cast<uint64_t>(l2::integer(number(lua, 1), 1, INT32_MAX, "invalid L2 job"));
        const auto job = workers.ready(id);
        l2::require(job->error.empty(), job->error.c_str());
        lua->CreateTable();
        for (size_t i = 0; i < job->parts.size(); ++i) {
            lua->PushNumber(static_cast<double>(i + 1));
            lua->CreateTable();
            numberField(lua, "group", job->parts[i].group);
            numberField(lua, "quads", static_cast<double>(job->parts[i].quads.size()));
            lua->RawSet(-3);
        }
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int uploadPart(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        BuildGuard guard;
        const auto id = static_cast<uint64_t>(l2::integer(number(lua, 1), 1, INT32_MAX, "invalid L2 job"));
        const auto job = workers.ready(id);
        l2::require(job->error.empty(), job->error.c_str());
        const auto index = l2::integer(number(lua, 2), 1, static_cast<int>(job->parts.size()), "invalid L2 part") - 1;
        const auto& part = job->parts[index];
        const unsigned first = l2::integer(number(lua, 3), 0, l2::AtlasQuads - static_cast<int>(part.quads.size()),
            "L2 batch exceeds corner atlas");
        l2::require(lua->IsType(4, Type::String), "invalid L2 material");
        return upload(lua, part, first, lua->GetString(4));
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int cancelSection(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        const auto id = static_cast<uint64_t>(l2::integer(number(lua, 1), 0, INT32_MAX, "invalid L2 job"));
        workers.cancel(id);
        if (id) worldTickets.erase(id);
        else worldTickets.clear();
        lua->PushBool(true);
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int canSubmit(ILuaBase* lua) { lua->PushBool(workers.canSubmit()); return 1; }
int statistics(ILuaBase* lua) {
    lua->CreateTable();
    numberField(lua, "templates", static_cast<double>(templates));
    numberField(lua, "liveTemplates", static_cast<double>(liveTemplates));
    numberField(lua, "batches", static_cast<double>(batches));
    numberField(lua, "liveMeshes", static_cast<double>(liveMeshes));
    numberField(lua, "vertices", static_cast<double>(vertices));
    numberField(lua, "indices", static_cast<double>(indices));
    numberField(lua, "sampleReads", static_cast<double>(reads));
    numberField(lua, "sampleCacheHits", static_cast<double>(hits));
    numberField(lua, "failures", static_cast<double>(failures));
    const auto s = workers.stats();
    numberField(lua, "workers", s.workers); numberField(lua, "queued", s.queued);
    numberField(lua, "running", s.running); numberField(lua, "ready", s.ready);
    numberField(lua, "peakRunning", s.peakRunning); numberField(lua, "workerBytes", static_cast<double>(s.bytes));
    numberField(lua, "submitted", static_cast<double>(s.submitted));
    numberField(lua, "completed", static_cast<double>(s.completed));
    numberField(lua, "releasedOrCancelled", static_cast<double>(s.cancelled));
    numberField(lua, "commandMS", commandMS); numberField(lua, "snapshotMS", snapshotMS);
    numberField(lua, "computeMS", s.computeMS); numberField(lua, "queueMS", s.queueMS);
    numberField(lua, "uploadMS", uploadMS);
    numberField(lua, "sectionVoxels", static_cast<double>(s.sectionVoxels));
    numberField(lua, "sectionQuads", static_cast<double>(s.sectionQuads));
    return 1;
}
}
