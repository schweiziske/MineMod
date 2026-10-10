#include "pch.h"
#include "l2_draw_bridge.h"
#include "l2_draw.h"
#include "l2_bridge.h"
#include "global.h"
#include "pixel_upload.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <unordered_set>

namespace mcmesh::l2drawbridge {
using namespace GarrysMod::Lua;
namespace {
int sceneType = -1;
uint64_t nextLane = 0;
l2draw::Worker worker;
std::shared_ptr<const l2draw::Graph> currentGraph;
struct Ref {
    ILuaBase* lua;
    int id;
    explicit Ref(ILuaBase* l, int index) : lua(l) { lua->Push(index); id = lua->ReferenceCreate(); }
    ~Ref() { lua->ReferenceFree(id); }
};
struct Mesh {
    l2bridge::DrawResource* resource = nullptr;
    std::shared_ptr<Ref> material;
    IMaterial* identity = nullptr;
    bool cullable = false;
};
struct Section { unsigned first = 0, end = 0; uint64_t vertices = 0; };
struct Chunk {
    std::shared_ptr<Ref> list;
    std::shared_ptr<const l2draw::Chunk> cpu;
    std::vector<Mesh> meshes;
    std::vector<Section> sections;
    uint64_t vertices = 0;
};
struct Scene {
    bool drawing = false;
    std::vector<std::unique_ptr<Chunk>> chunks;
    std::shared_ptr<const l2draw::Scene> cpu;
    uint64_t lanes[3] = {++nextLane, ++nextLane, ++nextLane};
    void clear() {
        for (auto lane : lanes) worker.forget(lane);
        chunks.clear(); cpu.reset();
    }
    ~Scene() { clear(); }
};
std::unordered_set<Scene*> scenes;
int absolute(ILuaBase* lua, int at) { return at > 0 ? at : lua->Top() + at + 1; }
double numeric(ILuaBase* lua, int at) {
    l2::require(lua->IsType(at, Type::Number), "Native draw requires a numeric field");
    const double v = lua->GetNumber(at);
    l2::require(std::isfinite(v), "Native draw received a non-finite field");
    return v;
}
double field(ILuaBase* lua, int at, const char* name) {
    lua->GetField(at, name); const double v = numeric(lua, -1); lua->Pop(); return v;
}
double item(ILuaBase* lua, int at, size_t index) {
    lua->PushNumber(static_cast<double>(index)); lua->RawGet(at); const double v = numeric(lua, -1); lua->Pop(); return v;
}
bool boolean(ILuaBase* lua, int at, const char* name) {
    lua->GetField(at, name); const bool v = lua->GetBool(-1); lua->Pop(); return v;
}
template<class T>
void number(ILuaBase* lua, const char* name, T v) { lua->PushNumber(static_cast<double>(v)); lua->SetField(-2, name); }
int failure(ILuaBase* lua, int top, const char* error) {
    lua->Pop(lua->Top() - top); lua->PushNil(); lua->PushString(error); return 2;
}
void call(ILuaBase* lua, int args, int results) {
    if (lua->PCall(args, results, 0) != 0) {
        const char* message = lua->GetString(-1);
        throw std::runtime_error(message ? message : "Native draw callback failed");
    }
}
Scene& scene(ILuaBase* lua) {
    auto* value = lua->GetUserType<Scene>(1, sceneType);
    l2::require(value && scenes.count(value), "invalid Native draw scene");
    return *value;
}
l2draw::Bounds bounds(ILuaBase* lua, int at) {
    l2draw::Bounds out;
    out.center = {field(lua, at, "x"), field(lua, at, "y"), field(lua, at, "z")};
    out.half = {field(lua, at, "hx"), field(lua, at, "hy"), field(lua, at, "hz")};
    out.radius = field(lua, at, "radius");
    l2::require(out.half[0] >= 0 && out.half[1] >= 0 && out.half[2] >= 0 &&
        out.radius >= std::sqrt(out.half[0]*out.half[0]+out.half[1]*out.half[1]+out.half[2]*out.half[2]) - 0.001,
        "invalid Native draw bounds");
    return out;
}
std::unique_ptr<Chunk> readChunk(ILuaBase* lua, int at) {
    at = absolute(lua, at);
    auto out = std::make_unique<Chunk>();
    auto cpu = std::make_shared<l2draw::Chunk>();
    cpu->key = field(lua, at, "key");
    lua->GetField(at, "frame");
    const int frame = lua->Top();
    cpu->origin = {field(lua, frame, "originX"), field(lua, frame, "originY"), field(lua, frame, "originZ")};
    const double width = field(lua, frame, "chunkW"), height = field(lua, frame, "chunkH");
    lua->Pop();
    lua->GetField(at, "list");
    const int list = lua->Top();
    l2::require(lua->IsType(list, Type::Table), "missing Native draw mesh list");
    out->list = std::make_shared<Ref>(lua, list);
    lua->GetField(list, "bounds");
    if (lua->IsType(-1, Type::Table)) cpu->bounds = bounds(lua, lua->Top());
    else {
        cpu->bounds.center = cpu->bounds.half = {width/2, width/2, height/2};
        cpu->bounds.radius = std::sqrt(width*width/2+height*height/4);
    }
    lua->Pop();
    const unsigned count = lua->ObjLen(list);
    l2::require(count < INT32_MAX, "Native draw list exceeds index representation");
    out->meshes.reserve(count);
    // Adjacent material references share an identity for bind caching.
    std::unordered_map<IMaterial*, std::shared_ptr<Ref>> materials;
    for (unsigned i = 1; i <= count; ++i) {
        lua->PushNumber(i); lua->RawGet(list);
        const int entry = lua->Top();
        lua->GetField(entry, "mesh");
        Mesh mesh; mesh.resource = l2bridge::drawResource(lua, -1); lua->Pop();
        lua->GetField(entry, "material");
        l2::require(lua->IsType(-1, Type::Material), "Native draw entry has no material");
        // A registry reference retains the Lua material and its GPU ownership.
        auto* identity = lua->GetUserType<IMaterial>(-1, Type::Material);
        l2::require(identity != nullptr, "invalid Native draw material identity");
        mesh.identity = identity;
        mesh.cullable = !identity->GetMaterialVarFlag(MATERIAL_VAR_NOCULL);
        auto& material = materials[identity];
        if (!material) material = std::make_shared<Ref>(lua, -1);
        mesh.material = material;
        lua->Pop();
        out->vertices += mesh.resource->indices / 6 * 4;
        out->meshes.push_back(std::move(mesh)); lua->Pop();
    }
    lua->GetField(list, "sections");
    const int sections = lua->Top();
    const bool hasSections = lua->IsType(sections, Type::Table);
    const unsigned sectionCount = hasSections ? lua->ObjLen(sections) : 1;
    for (unsigned s = 1; s <= sectionCount; ++s) {
        l2draw::Section metadata;
        Section range; range.end = count;
        if (hasSections) {
            lua->PushNumber(s); lua->RawGet(sections);
            const int sec = lua->Top();
            range.first = l2::integer(field(lua, sec, "first"), 1, count + 1, "invalid Native draw section start") - 1;
            range.end = l2::integer(field(lua, sec, "last"), range.first, count, "invalid Native draw section end");
            metadata.index = l2::integer(field(lua, sec, "index"), 1, INT32_MAX, "invalid Native draw section index");
            lua->GetField(sec, "bounds");
            metadata.bounded = lua->IsType(-1, Type::Table);
            if (metadata.bounded) {
                metadata.bounds = bounds(lua, lua->Top());
                metadata.protrudes = boolean(lua, lua->Top(), "protrudes");
            }
            lua->Pop(2);
        }
        for (unsigned i = range.first; i < range.end; ++i) range.vertices += out->meshes[i].resource->indices / 6 * 4;
        out->sections.push_back(range); cpu->sections.push_back(metadata);
    }
    lua->Pop(2);
    out->cpu = std::move(cpu);
    return out;
}
LUA_FUNCTION(collect) {
    auto* value = LUA->GetUserType<Scene>(1, sceneType);
    if (value) { scenes.erase(value); delete value; LUA->SetUserType(1, nullptr); }
    return 0;
}
}
void initialize(ILuaBase* lua) {
    sceneType = lua->CreateMetaTable("MCSWEP_L2DrawScene_v1");
    lua->PushCFunction(collect); lua->SetField(-2, "__gc");
    lua->PushString("Native L2 draw scene"); lua->SetField(-2, "__metatable"); lua->Pop();
}
void shutdown() {
    worker.stop();
    for (auto* value : scenes) value->clear();
    currentGraph.reset();
}
int version(ILuaBase* lua) { lua->PushNumber(1); return 1; }
int create(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        auto value = std::make_unique<Scene>();
        lua->PushUserType(value.get(), sceneType);
        scenes.insert(value.get()); value.release(); return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int patch(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        auto& value = scene(lua);
        l2::require(!value.drawing, "cannot patch a Native scene during its draw");
        l2::require(lua->IsType(2, Type::Table), "missing Native draw scene updates");
        const unsigned count = l2::integer(numeric(lua, 3), 0, INT32_MAX, "Native draw chunk count out of range");
        std::unordered_map<unsigned, std::unique_ptr<Chunk>> updates;
        lua->PushNil();
        while (lua->Next(2) != 0) {
            const unsigned index = l2::integer(numeric(lua, -2), 1, count, "invalid Native scene update index") - 1;
            updates[index] = readChunk(lua, -1); lua->Pop();
        }
        auto cpu = std::make_shared<l2draw::Scene>();
        cpu->chunks.reserve(count);
        for (unsigned i = 0; i < count; ++i) {
            auto update = updates.find(i);
            const auto* chunk = update != updates.end() ? update->second.get() :
                i < value.chunks.size() ? value.chunks[i].get() : nullptr;
            l2::require(chunk != nullptr, "incomplete Native scene update");
            cpu->chunks.push_back(chunk->cpu);
        }
        value.chunks.resize(count);
        for (auto& update : updates) value.chunks[update.first] = std::move(update.second);
        value.cpu = std::move(cpu);
        lua->PushBool(true); return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
static int readGraph(ILuaBase* lua, bool spatial) {
    const int top = lua->Top();
    try {
        numeric(lua, 1); // Lua owns revision caching; module reloads may restart its counter.
        const unsigned count = l2::integer(numeric(lua, 2), 0, INT32_MAX, "Native graph exceeds index representation");
        l2::require(lua->IsType(3, Type::Table) && lua->IsType(4, Type::Table) && lua->IsType(5, Type::Table),
            "invalid Native graph tables");
        auto result = std::make_shared<l2draw::Graph>();
        const unsigned side = spatial ? l2::integer(numeric(lua, 9), 1, 64, "invalid Native graph section size") : 0;
        result->nodes.resize(count + 1);
        for (unsigned id = 1; id <= count; ++id) {
            lua->PushNumber(id); lua->RawGet(3);
            const int source = lua->Top();
            auto& node = result->nodes[id];
            node.live = lua->IsType(source, Type::Table);
            if (node.live) for (unsigned f = 0; f < 6; ++f) {
                node.exits[f] = uint8_t(l2::integer(item(lua, source, f+1), 0, 63, "invalid Native portal mask"));
                node.neighbors[f] = l2::integer(item(lua, 4, size_t(id-1)*6+f+1), 0, count, "invalid Native portal neighbor");
            }
            if (node.live && spatial) {
                lua->GetField(source, "uniform");
                if (lua->IsType(-1, Type::Number)) {
                    const auto uniform = l2::integer(numeric(lua, -1), 0, 64, "invalid Native uniform topology");
                    l2::require(uniform == 63 || uniform == 64, "Native uniform topology must be air or solid");
                    for (auto& face : node.boundary) face.assign(side*side, uint8_t(uniform));
                    lua->Pop();
                } else {
                    lua->Pop(); lua->GetField(source, "cells");
                    l2::require(lua->IsType(-1, Type::String), "missing Native topology cells");
                    unsigned length = 0;
                    const auto* cells = reinterpret_cast<const uint8_t*>(lua->GetString(-1, &length));
                    l2::require(length == side*side*side, "Native topology cell count disagrees with section size");
                    for (unsigned i = 0; i < length; ++i)
                        l2::require(cells[i] <= 64, "invalid Native topology component");
                    for (unsigned face = 0; face < 6; ++face) {
                        auto& boundary = node.boundary[face]; boundary.resize(side*side);
                        const unsigned edge = face & 1 ? 0 : side-1;
                        for (unsigned b = 0; b < side; ++b) for (unsigned a = 0; a < side; ++a) {
                            const unsigned x = face < 2 || face >= 4 ? a : edge;
                            const unsigned y = face < 2 ? b : face < 4 ? a : edge;
                            const unsigned z = face < 2 ? edge : b;
                            boundary[a+side*b] = cells[x+side*(y+side*z)];
                        }
                    }
                    lua->Pop();
                }
            }
            lua->Pop();
        }
        for (unsigned id = 1; id <= count; ++id) if (result->nodes[id].live)
            for (auto neighbor : result->nodes[id].neighbors)
                l2::require(!neighbor || result->nodes[neighbor].live, "Native graph edge points to a retired node");
        const unsigned perChunk = l2::integer(numeric(lua, 6), 1, INT32_MAX, "invalid Native graph section count");
        unsigned xy = 1, z = 1;
        if (spatial) {
            xy = l2::integer(numeric(lua, 7), 1, INT32_MAX, "invalid Native graph horizontal dimensions");
            z = l2::integer(numeric(lua, 8), 1, INT32_MAX, "invalid Native graph vertical dimensions");
            l2::require(double(xy)*xy*z == perChunk, "Native graph dimensions disagree with section count");
        }
        std::vector<uint8_t> assigned(spatial ? count + 1 : 0);
        lua->PushNil();
        while (lua->Next(5) != 0) {
            const double key = numeric(lua, -2);
            const unsigned base = l2::integer(field(lua, lua->Top(), "base"), 0, count, "invalid Native graph base");
            l2::require(perChunk <= count - base, "Native graph chunk exceeds node storage");
            for (unsigned i = 1; i <= perChunk; ++i)
                l2::require(result->nodes[base+i].live, "Native graph chunk contains retired node");
            if (spatial) {
                lua->GetField(lua->Top(), "chunk");
                const int chunk = lua->Top();
                l2::require(lua->IsType(chunk, Type::Table), "missing Native graph chunk coordinates");
                const double cx = field(lua, chunk, "cx"), cy = field(lua, chunk, "cy"), cz = field(lua, chunk, "cz");
                l2::require(std::floor(cx) == cx && std::floor(cy) == cy && std::floor(cz) == cz,
                    "fractional Native graph chunk coordinates");
                for (unsigned i = 0; i < perChunk; ++i) {
                    const unsigned id = base+i+1;
                    l2::require(!assigned[id], "Native spatial node has multiple owners");
                    assigned[id] = 1;
                    result->nodes[id].position = {
                        l2::integer(cx*xy+i%xy, INT32_MIN, INT32_MAX, "Native graph X out of range"),
                        l2::integer(cy*xy+i/xy%xy, INT32_MIN, INT32_MAX, "Native graph Y out of range"),
                        l2::integer(cz*z+i/(xy*xy), INT32_MIN, INT32_MAX, "Native graph Z out of range")};
                }
                lua->Pop();
            }
            result->bases.emplace(key, base); lua->Pop();
        }
        if (spatial) {
            for (unsigned id = 1; id <= count; ++id)
                l2::require(!result->nodes[id].live || assigned[id], "unpositioned Native spatial node");
            l2draw::buildSpatialGraph(*result);
            for (auto& node : result->nodes) for (auto& face : node.boundary) std::vector<uint8_t>().swap(face);
        }
        currentGraph = std::move(result);
        lua->PushBool(true); return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int graph(ILuaBase* lua) { return readGraph(lua, false); }
int spatialGraph(ILuaBase* lua) { return readGraph(lua, true); }
int draw(ILuaBase* lua) {
    const int top = lua->Top();
    try {
        pixelupload::Flush();
        auto& value = scene(lua);
        l2::require(!value.drawing, "recursive Native scene draw");
        struct DrawScope {
            bool& flag;
            explicit DrawScope(bool& f) : flag(f) { flag = true; }
            ~DrawScope() { flag = false; }
        } drawing(value.drawing);
        l2::require(value.cpu && lua->IsType(2, Type::Table) && lua->IsType(3, Type::Function) &&
            lua->IsType(4, Type::Function) && lua->IsType(5, Type::Function), "invalid Native draw arguments");
        l2draw::View view;
        view.eye = {field(lua, 2, "eyeX"), field(lua, 2, "eyeY"), field(lua, 2, "eyeZ")};
        view.distance = field(lua, 2, "distance");
        view.moveBudget = field(lua, 2, "moveBudget");
        l2::require(view.distance >= 0 && view.moveBudget >= 0, "invalid Native draw distance");
        view.portals = boolean(lua, 2, "portals");
        view.root = l2::integer(field(lua, 2, "root"), 0, INT32_MAX, "invalid Native draw root");
        view.seed = uint8_t(l2::integer(field(lua, 2, "seed"), 0, 63, "invalid Native draw seed"));
        if (view.portals && currentGraph && currentGraph->spatial) {
            view.portalCell = {
                l2::integer(field(lua, 2, "portalX"), INT32_MIN, INT32_MAX, "invalid Native camera section X"),
                l2::integer(field(lua, 2, "portalY"), INT32_MIN, INT32_MAX, "invalid Native camera section Y"),
                l2::integer(field(lua, 2, "portalZ"), INT32_MIN, INT32_MAX, "invalid Native camera section Z")};
        }
        lua->GetField(2, "planes");
        const int planes = lua->Top();
        l2::require(lua->IsType(planes, Type::Table) && lua->ObjLen(planes) % 3 == 0,
            "invalid Native draw plane array");
        view.planeCount = l2::integer(lua->ObjLen(planes) / 3, 0, 5, "invalid Native draw frustum");
        for (unsigned p = 0; p < view.planeCount; ++p) {
            auto& n = view.planes[p];
            for (unsigned a = 0; a < 3; ++a) n[a] = item(lua, planes, p*3+a+1);
            const double length = std::sqrt(n[0]*n[0]+n[1]*n[1]+n[2]*n[2]);
            l2::require(length > 0, "degenerate Native draw frustum");
            for (auto& axis : n) axis /= length;
        }
        lua->Pop();
        const l2draw::Vec offset = {field(lua, 2, "offsetX"), field(lua, 2, "offsetY"), field(lua, 2, "offsetZ")};
        const bool directional = boolean(lua, 2, "directional");
        const double margin = field(lua, 2, "directionMargin");
        l2::require(margin >= 0, "invalid Native direction margin");
        const unsigned lane = l2::integer(field(lua, 2, "lane"), 1, 3, "invalid Native draw lane") - 1;
        const auto graph = view.portals ? currentGraph : nullptr;
        std::shared_ptr<const l2draw::Frame> frame;
        const bool background = boolean(lua, 2, "background");
        bool asyncHit = false;
        if (background) frame = worker.resolve(value.lanes[lane], value.cpu, graph, view, asyncHit);
        if (!frame) {
            auto exact = view; exact.moveBudget = exact.normalBudget = 0;
            frame = std::make_shared<l2draw::Frame>(l2draw::compute(value.cpu, graph, exact));
        }
        l2::require(frame->error.empty(), frame->error.c_str());
        uint64_t drawn = 0, distance = 0, frustum = 0, stale = 0, meshes = 0, testedSections = 0,
            drawnSections = 0, sectionFrustum = 0, sectionPortal = 0, rejectedDirections = 0,
            vertices = 0, rejectedVertices = 0, binds = 0, rangesDrawn = 0;
        CMatRenderContextPtr context(g_matsys);
        l2::require(!!context, "Native draw render context unavailable");
        context->MatrixMode(MATERIAL_MODEL);
        struct MatrixScope {
            IMatRenderContext* context;
            bool pushed = false;
            ~MatrixScope() { if (pushed) { context->MatrixMode(MATERIAL_MODEL); context->PopMatrix(); } }
        };
        IMaterial* bound = nullptr;
        for (size_t i = 0; i < value.chunks.size(); ++i) {
            const auto& chunk = *value.chunks[i];
            const auto& cpu = *chunk.cpu;
            const auto& visible = frame->chunks[i];
            if (visible.reject != l2draw::Reject::None) {
                rejectedVertices += chunk.vertices;
                if (visible.reject == l2draw::Reject::Distance) ++distance; else ++frustum;
                continue;
            }
            lua->Push(3); lua->PushNumber(cpu.key); lua->ReferencePush(chunk.list->id);
            for (unsigned a = 0; a < 3; ++a) lua->PushNumber(cpu.origin[a] - view.eye[a]);
            call(lua, 5, 2);
            const int status = l2::integer(numeric(lua, -2), 0, 3, "invalid Native chunk callback result");
            const bool dynamic = lua->GetBool(-1); lua->Pop(2);
            if (status != 3) {
                if (status == 0) ++stale;
                if (status == 2) { ++distance; rejectedVertices += chunk.vertices; }
                continue;
            }
            MatrixScope matrix{context};
            bool chunkDrawn = false;
            const l2draw::Vec localEye = {view.eye[0]-cpu.origin[0], view.eye[1]-cpu.origin[1], view.eye[2]-cpu.origin[2]};
            for (size_t s = 0; s < chunk.sections.size(); ++s) {
                const auto& section = chunk.sections[s];
                ++testedSections;
                if (visible.sections[s] != l2draw::Reject::None) {
                    rejectedVertices += section.vertices;
                    if (visible.sections[s] == l2draw::Reject::Portal) ++sectionPortal; else ++sectionFrustum;
                    continue;
                }
                bool sectionDrawn = false;
                for (unsigned j = section.first; j < section.end; ++j) {
                    const auto& mesh = chunk.meshes[j];
                    const auto& resource = *mesh.resource;
                    l2::require(resource.mesh != nullptr, "Native draw encountered a destroyed L2 mesh");
                    CPrimList ranges[7];
                    unsigned rangeCount = 0, selected = resource.indices;
                    const bool useRanges = directional && mesh.cullable;
                    if (useRanges) {
                        selected = 0;
                        for (unsigned g = 0; g < 7; ++g) {
                            const auto& range = resource.directions[g];
                            if (!range.count) continue;
                            if (l2draw::directionVisible(g, resource.bounds, localEye, margin)) {
                                ranges[rangeCount++] = CPrimList(range.first, range.count); selected += range.count;
                            } else ++rejectedDirections;
                        }
                        rejectedVertices += (resource.indices - selected) / 6 * 4;
                        if (!selected) continue;
                    }
                    if (!matrix.pushed) {
                        VMatrix model;
                        model.Init(1,0,0,float(cpu.origin[0]+offset[0]),
                            0,1,0,float(cpu.origin[1]+offset[1]), 0,0,1,float(cpu.origin[2]+offset[2]), 0,0,0,1);
                        context->MatrixMode(MATERIAL_MODEL); context->PushMatrix(); matrix.pushed = true;
                        context->LoadMatrix(model);
                    }
                    auto* source = mesh.identity;
                    if (source != bound) {
                        lua->Push(4); lua->ReferencePush(mesh.material->id); call(lua, 1, 0);
                        bound = source; ++binds;
                    }
                    auto drawMesh = [&] {
                        if (useRanges) resource.mesh->Draw(ranges, rangeCount);
                        else resource.mesh->Draw(0, resource.indices);
                    };
                    drawMesh();
                    if (dynamic) {
                        lua->Push(5); lua->PushBool(true); lua->ReferencePush(mesh.material->id); call(lua, 2, 1);
                        const bool overlay = lua->GetBool(-1); lua->Pop();
                        if (overlay) {
                            drawMesh();
                            lua->Push(5); lua->PushBool(false); lua->ReferencePush(mesh.material->id); call(lua, 2, 0);
                        }
                    }
                    ++meshes; vertices += selected / 6 * 4; rangesDrawn += useRanges ? rangeCount : 1;
                    chunkDrawn = sectionDrawn = true;
                }
                if (sectionDrawn) ++drawnSections;
            }
            if (chunkDrawn) ++drawn;
        }
        lua->CreateTable();
        number(lua, "drawn", drawn); number(lua, "distanceCulled", distance); number(lua, "frustumCulled", frustum);
        number(lua, "stale", stale); number(lua, "meshes", meshes); number(lua, "sectionsTested", testedSections);
        number(lua, "sectionsDrawn", drawnSections); number(lua, "sectionFrustumCulled", sectionFrustum);
        number(lua, "sectionOcclusionCulled", sectionPortal); number(lua, "directionCulled", rejectedDirections);
        number(lua, "vertices", vertices); number(lua, "verticesCulled", rejectedVertices);
        number(lua, "nativeBinds", binds); number(lua, "nativeRanges", rangesDrawn);
        number(lua, "nativeAsyncHits", asyncHit ? 1 : 0); number(lua, "nativeSyncCulls", asyncHit ? 0 : 1);
        number(lua, "nativeCullMS", frame->milliseconds);
        lua->PushString(!view.portals ? "disabled" : !graph->spatial ? "connectivity_legacy" :
            graph->grid.empty() ? "connectivity_extent" : "spatial_outward");
        lua->SetField(-2, "portalMode");
        number(lua, "portalGridCells", graph ? graph->grid.size() : 0);
        number(lua, "portalVisited", frame->portals ? frame->portals->visited : 0);
        return 1;
    } catch (const std::exception& e) { return failure(lua, top, e.what()); }
}
int stats(ILuaBase* lua) {
    const auto value = worker.stats();
    lua->CreateTable();
    number(lua, "requests", value.requests); number(lua, "cacheHits", value.cacheHits);
    number(lua, "coalesced", value.coalesced); number(lua, "scheduled", value.scheduled);
    number(lua, "completed", value.completed); number(lua, "running", value.running);
    number(lua, "synchronous", value.synchronous); number(lua, "computeMS", value.computeMS);
    number(lua, "portalTraversals", value.portalTraversals); number(lua, "portalCacheHits", value.portalCacheHits);
    return 1;
}
}
