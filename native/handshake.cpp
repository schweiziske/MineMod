#include "pch.h"
#include "handshake.h"
#include "global.h"
#include "blob_format.h"
#include "blockdefs.h"
#include "meshbuild.h"
#include "meshworker.h"
#include "worldstate.h"

#include <cmath>
#include <limits>

using namespace GarrysMod::Lua;
namespace mcmesh::handshake {
    static bool ConfigurationMutable() {
        const auto workerStats = meshworker::GetStats();
        auto defsLock = blockdefs::LockForRead();
        return !blockdefs::g_loaded && worldstate::g_world.empty()
            && meshbuild::g_meshes.empty() && workerStats.outstanding == 0
            && workerStats.workerCount == 0;
    }

    int Handshake(ILuaBase* LUA) {
        // A completed handshake alone is retryable: no world/defs/workers own
        // the promise yet, so validated parameters may safely replace it.
        if (!ConfigurationMutable()) { LUA->PushBool(false); return 1; }
        for (int i = 1; i <= 4; ++i) if (!LUA->IsType(i, Type::Number)) { LUA->PushBool(false); return 1; }
        double cd = LUA->GetNumber(1), hd = LUA->GetNumber(2), sd = LUA->GetNumber(3), bs = LUA->GetNumber(4);
        auto integral = [](double v) {return std::isfinite(v) && v == std::floor(v) && v > 0 && v <= 2147483647.0; };
        if (!integral(cd) || !integral(hd) || !integral(sd) || !std::isfinite(bs) || bs <= 0) { LUA->PushBool(false); return 1; }
        int cs = int(cd), ch = int(hd), ss = int(sd);
        if (cs != kCS || ch != kCH || std::abs(bs - kBS) > EQUAL_EPSILON || ss == 0 || cs % ss || ch % ss) { LUA->PushBool(false); return 1; }
        int64_t nsx = cs / ss, nsz = ch / ss, cpc = int64_t(cs) * cs * ch, spc = nsx * nsx * nsz;
        if (nsx <= 0 || nsz <= 0 || cpc != kCellsPerChunk || spc <= 0 || spc > 64) { LUA->PushBool(false); return 1; }
        unsigned int lo = 0, lt = 0; const char* mo = LUA->GetString(5, &lo); const char* mt = LUA->GetString(6, &lt);
        if (!mo || !mt || !lo || !lt || !g_matsys) { LUA->PushBool(false); return 1; }
        IMaterial* a = g_matsys->FindMaterial(mo, TEXTURE_GROUP_OTHER), * b = g_matsys->FindMaterial(mt, TEXTURE_GROUP_OTHER);
        if (!SupportsNativeMeshVertexFormat(a) || !SupportsNativeMeshVertexFormat(b)) { LUA->PushBool(false); return 1; }
        Promise configured{};
        configured.CS = cs; configured.CH = ch; configured.SS = ss; configured.BS = bs;
        configured.NSX = int(nsx); configured.NSZ = int(nsz); configured.CPC = int(cpc); configured.SPC = int(spc);
        configured.AtlasMaterials.push_back({ a, b });
        g_promise = std::move(configured);
        LUA->PushBool(true); return 1;
    }

    int SetAtlasPageMaterial(ILuaBase* LUA) {
        if (!ConfigurationMutable() || g_promise.SS <= 0 || !LUA->IsType(1, Type::Number)
            || !LUA->IsType(2, Type::String) || !LUA->IsType(3, Type::String)) {
            LUA->PushBool(false); return 1;
        }
        const double pageValue = LUA->GetNumber(1);
        if (!std::isfinite(pageValue) || pageValue != std::floor(pageValue)
            || pageValue < 0 || pageValue >= 64) {
            LUA->PushBool(false); return 1;
        }
        unsigned int opaqueLength = 0, translucentLength = 0;
        const char* opaqueName = LUA->GetString(2, &opaqueLength);
        const char* translucentName = LUA->GetString(3, &translucentLength);
        if (!opaqueName || !translucentName || !opaqueLength || !translucentLength || !g_matsys) {
            LUA->PushBool(false); return 1;
        }
        IMaterial* opaque = g_matsys->FindMaterial(opaqueName, TEXTURE_GROUP_OTHER);
        IMaterial* translucent = g_matsys->FindMaterial(translucentName, TEXTURE_GROUP_OTHER);
        if (!SupportsNativeMeshVertexFormat(opaque) || !SupportsNativeMeshVertexFormat(translucent)) {
            LUA->PushBool(false); return 1;
        }
        const size_t page = size_t(pageValue);
        try {
            if (g_promise.AtlasMaterials.size() <= page) g_promise.AtlasMaterials.resize(page + 1);
        }
        catch (...) { LUA->PushBool(false); return 1; }
        g_promise.AtlasMaterials[page] = { opaque, translucent };
        LUA->PushBool(true); return 1;
    }
    int SetBlockDefs(ILuaBase* LUA) { LUA->PushBool(false); return 1; } int Think(ILuaBase* L) { L->PushNumber(0); return 1; } int DrawChunk(ILuaBase* L) { L->PushBool(false); return 1; } int UnloadChunk(ILuaBase* L) { L->PushBool(false); return 1; } int ClearWorld(ILuaBase*) { return 0; } int Shutdown(ILuaBase*) { return 0; }
}
