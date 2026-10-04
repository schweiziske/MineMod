// Bounded filesystem/ZIP adapter only. Lua owns pack metadata, overlays,
// filters, resource resolution, selection and application. Synchronous API.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include "resource_io.h"
#include "resource_source.h"
#include <array>
#include <cmath>
#include <stdexcept>

namespace mcmesh::resourceio {
namespace {
namespace fs = std::filesystem;
using namespace GarrysMod::Lua;
std::array<std::unique_ptr<resources::Source>, 4> sources;
std::array<uint64_t, 4> ids{};
uint64_t sequence = 0;
int Fail(ILuaBase* lua, const char* reason) { lua->PushNil(); lua->PushString(reason); return 2; }
fs::path Root() {
    // Resolve from the running GMod executable, never from a path supplied by
    // a pack or Lua. Both legacy and bin/win64 client layouts are supported.
    wchar_t buffer[32768];
    DWORD length = GetModuleFileNameW(nullptr, buffer, 32768);
    if (!length || length >= 32768) throw std::runtime_error("resource_io_executable_path");
    fs::path base = fs::path(buffer).parent_path();
    if (base.filename() == L"win64" && base.parent_path().filename() == L"bin") base = base.parent_path().parent_path();
    if (!fs::is_regular_file(base / L"garrysmod/gameinfo.txt")) throw std::runtime_error("resource_io_game_root");
    fs::path root = base / L"garrysmod/data/mc/resourcepacks/inbox";
    fs::path current = base / L"garrysmod";
    for (const auto* segment : {L"data", L"mc", L"resourcepacks", L"inbox"}) {
        current /= segment;
        DWORD attrs = GetFileAttributesW(current.c_str());
        if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_REPARSE_POINT))
            throw std::runtime_error("resource_io_root_reparse_point");
    }
    return root;
}
int Slot(ILuaBase* lua) {
    if (!lua->IsType(1, Type::Number)) return -1;
    double id = lua->GetNumber(1);
    for (int i = 0; i < int(sources.size()); ++i) if (sources[i] && double(ids[i]) == id) return i;
    return -1;
}
std::string String(ILuaBase* lua, int index) {
    if (!lua->IsType(index, Type::String)) throw std::runtime_error("resource_io_expected_string");
    unsigned length = 0; const char* bytes = lua->GetString(index, &length);
    return std::string(bytes, length);
}
}
int List(GarrysMod::Lua::ILuaBase* lua) {
    try {
        const auto root = Root();
        std::vector<std::string> names;
        if (fs::exists(root)) for (const auto& item : fs::directory_iterator(root)) {
            const auto name = item.path().filename().u8string();
            std::string ext = item.path().extension().u8string();
            for (char& c : ext) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
            if (item.is_directory() || ext == ".zip") names.push_back(name);
            if (names.size() > 256) throw std::runtime_error("resource_io_catalog_budget");
        }
        lua->CreateTable();
        for (size_t i = 0; i < names.size(); ++i) {
            lua->PushNumber(double(i + 1)); lua->PushString(names[i].c_str()); lua->SetTable(-3);
        }
        return 1;
    } catch (const std::exception& err) { return Fail(lua, err.what()); }
}
int HashBytes(GarrysMod::Lua::ILuaBase* lua) {
    try {
        if(!lua->IsType(1,Type::String)) return Fail(lua,"resource_hash_expected_string");
        unsigned size=0;const char* data=lua->GetString(1,&size);
        if(size>268435456) return Fail(lua,"resource_hash_byte_budget");
        const auto hash=resources::Sha256(std::string_view(data,size));
        lua->PushString(hash.c_str());return 1;
    } catch(const std::exception& err) {return Fail(lua,err.what());}
}
int Open(GarrysMod::Lua::ILuaBase* lua) {
    try {
        std::string name = String(lua, 1);
        if (!resources::SafePath(name) || name.find('/') != std::string::npos) return Fail(lua, "resource_io_invalid_name");
        size_t slot = 0;
        while (slot < sources.size() && sources[slot]) ++slot;
        if (slot == sources.size()) return Fail(lua, "resource_io_handle_budget");
        auto source = resources::Source::Open(Root() / fs::u8path(name));
        lua->CreateTable();
        lua->PushNumber(double(++sequence)); lua->SetField(-2, "handle");
        lua->PushString(source->Revision().c_str()); lua->SetField(-2, "revision");
        lua->CreateTable();
        const auto& prefix = source->Root();
        for (const auto& entry : source->Entries()) {
            if (entry.first.compare(0, prefix.size(), prefix) != 0) continue;
            lua->PushNumber(double(entry.second.size)); lua->SetField(-2, entry.first.substr(prefix.size()).c_str());
        }
        lua->SetField(-2, "entries");
        ids[slot] = sequence; sources[slot] = std::move(source);
        return 1;
    } catch (const std::exception& err) { return Fail(lua, err.what()); }
}
int Read(GarrysMod::Lua::ILuaBase* lua) {
    try {
        int slot = Slot(lua); if (slot < 0) return Fail(lua, "resource_io_stale_handle");
        const auto path = String(lua, 2);
        if (!resources::SafePath(path)) return Fail(lua, "resource_io_unsafe_path");
        const auto& bytes = sources[slot]->Read(path);
        lua->PushString(bytes.data(), unsigned(bytes.size())); return 1;
    } catch (const std::exception& err) { return Fail(lua, err.what()); }
}
int Unchanged(GarrysMod::Lua::ILuaBase* lua) {
    try {
        int slot = Slot(lua); if (slot < 0) return Fail(lua, "resource_io_stale_handle");
        lua->PushBool(sources[slot]->Unchanged()); return 1;
    } catch (const std::exception& err) { return Fail(lua, err.what()); }
}
int Close(GarrysMod::Lua::ILuaBase* lua) {
    int slot = Slot(lua); if (slot < 0) return Fail(lua, "resource_io_stale_handle");
    sources[slot].reset(); lua->PushBool(true); return 1;
}
void Shutdown() { for (auto& source : sources) source.reset(); }
}
