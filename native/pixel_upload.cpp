#include "pch.h"
#include "pixel_upload.h"
#include "global.h"
#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace mcmesh::pixelupload {
namespace {
using namespace GarrysMod::Lua;
struct Run { int x,y,length;uint32_t color; };
double number(ILuaBase* lua,int at,double low,double high,bool integral) {
    if(!lua->IsType(at,Type::Number)) throw std::runtime_error("pixel_upload_number");
    const double value=lua->GetNumber(at);
    if(!std::isfinite(value) || value<low || value>high || (integral && value!=std::floor(value)))
        throw std::runtime_error("pixel_upload_range");
    return value;
}
void append(ILuaBase* lua,int at,int width,int height,int first,double scale,double offset,std::vector<Run>& runs) {
    if(!lua->IsType(at,Type::Table)) throw std::runtime_error("pixel_upload_table");
    const int count=lua->ObjLen(at);
    if(count<1 || count>262144) throw std::runtime_error("pixel_upload_count");
    const double last=std::floor(std::floor(double(first+count-1)/width)*scale+offset);
    if(last>=height) throw std::runtime_error("pixel_upload_target_bounds");
    for(int i=0;i<count;++i) {
        lua->PushNumber(i+1);lua->RawGet(at);
        const uint32_t color=uint32_t(number(lua,-1,0,4294967295.0,true));lua->Pop();
        const int pixel=first+i,x=pixel%width,y=int(std::floor((pixel/width)*scale+offset));
        if(!runs.empty() && runs.back().y==y && runs.back().x+runs.back().length==x && runs.back().color==color)
            ++runs.back().length;
        else runs.push_back({x,y,1,color});
    }
}
}
int Draw(GarrysMod::Lua::ILuaBase* lua) {
    const int stack=lua->Top();
    try {
        const int width=int(number(lua,1,1,16384,true)),first=int(number(lua,2,0,268435455,true));
        const double scale=number(lua,4,1,5,false),offset=number(lua,5,0,4,false);
        if(!g_matsys || !lua->IsType(6,Type::String)) throw std::runtime_error("pixel_upload_material");
        auto* material=g_matsys->FindMaterial(lua->GetString(6),TEXTURE_GROUP_OTHER,false);
        if(!material || material->IsErrorMaterial()) throw std::runtime_error("pixel_upload_material");
        CMatRenderContextPtr context(g_matsys);
        if(!context) throw std::runtime_error("pixel_upload_context");
        int vx,vy,vw,vh;context->GetViewport(vx,vy,vw,vh);
        if(vx!=0 || vy!=0 || width!=vw) throw std::runtime_error("pixel_upload_viewport");
        std::vector<Run> runs;
        append(lua,3,width,vh,first,scale,offset,runs);
        if(lua->Top()>=8 && !lua->IsType(8,Type::Nil))
            append(lua,8,width,vh,int(number(lua,7,0,268435455,true)),5,2,runs);
        // Lua owns RT/projection/blend restoration. All inputs are validated
        // before drawing. IMesh accepts alpha zero without VGUI's early discard.
        context->Bind(material);
        for(size_t firstRun=0;firstRun<runs.size();firstRun+=4096) {
            const int count=int(std::min(size_t(4096),runs.size()-firstRun));
            auto* mesh=context->GetDynamicMesh(true,nullptr,nullptr,material);
            if(!mesh) throw std::runtime_error("pixel_upload_dynamic_mesh");
            CMeshBuilder builder;builder.Begin(mesh,MATERIAL_QUADS,count);
            for(int i=0;i<count;++i) {
                const auto& run=runs[firstRun+i];
                auto vertex=[&](float x,float y) {
                    builder.Position3f(x,y,0);builder.Color4ub(uint8_t(run.color),uint8_t(run.color>>8),uint8_t(run.color>>16),uint8_t(run.color>>24));
                    builder.TexCoord2f(0,0.5f,0.5f);builder.AdvanceVertex();
                };
                vertex(float(run.x),float(run.y));vertex(float(run.x+run.length),float(run.y));
                vertex(float(run.x+run.length),float(run.y+1));vertex(float(run.x),float(run.y+1));
            }
            builder.End();mesh->Draw();
        }
        lua->PushBool(true);return 1;
    } catch(const std::exception& e) {
        if(lua->Top()>stack) lua->Pop(lua->Top()-stack);
        lua->PushNil();lua->PushString(e.what());return 2;
    }
}
}
