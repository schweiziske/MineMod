#define NOMINMAX
#include <windows.h>
#include <d3d9.h>
#include <wrl/client.h>
#include <array>
#include <cstring>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
using Microsoft::WRL::ComPtr;
static void check(HRESULT hr, const char* label) {
    if (FAILED(hr)) throw std::runtime_error(label);
}
static std::vector<DWORD> read(const char* path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f || f.tellg() <= 0 || size_t(f.tellg()) % 4) throw std::runtime_error("invalid shader file");
    std::vector<DWORD> bytes(size_t(f.tellg()) / 4);
    f.seekg(0); f.read(reinterpret_cast<char*>(bytes.data()), bytes.size() * 4);
    if (!f) throw std::runtime_error("shader read failed");
    return bytes;
}
int main(int argc, char** argv) {
    HWND window = nullptr;
    try {
        if (argc < 3 || argc > 5) throw std::runtime_error("expected vertex.bin pixel.bin [sampler-bias-bits] [ex]");
        WNDCLASSW wc{}; wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"MCAtlasSamplerProbe";
        RegisterClassW(&wc);
        window = CreateWindowW(wc.lpszClassName,L"",WS_OVERLAPPED,0,0,64,64,nullptr,nullptr,wc.hInstance,nullptr);
        if (!window) throw std::runtime_error("hidden window failed");
        ComPtr<IDirect3D9> api;
        ComPtr<IDirect3D9Ex> apiEx;
        if(argc==5) {check(Direct3DCreate9Ex(D3D_SDK_VERSION,&apiEx),"D3D9Ex");api=apiEx;}
        else api.Attach(Direct3DCreate9(D3D_SDK_VERSION));
        if (!api) throw std::runtime_error("D3D9 unavailable");
        D3DADAPTER_IDENTIFIER9 adapter{};
        check(api->GetAdapterIdentifier(D3DADAPTER_DEFAULT,0,&adapter),"adapter");
        std::cerr<<adapter.Description<<'\n';
        D3DPRESENT_PARAMETERS pp{}; pp.Windowed=TRUE; pp.SwapEffect=D3DSWAPEFFECT_DISCARD;
        pp.BackBufferWidth=64; pp.BackBufferHeight=64; pp.BackBufferFormat=D3DFMT_X8R8G8B8;
        pp.PresentationInterval=D3DPRESENT_INTERVAL_IMMEDIATE;
        ComPtr<IDirect3DDevice9> device;
        if(apiEx) {
            ComPtr<IDirect3DDevice9Ex> deviceEx;
            check(apiEx->CreateDeviceEx(D3DADAPTER_DEFAULT,D3DDEVTYPE_HAL,window,D3DCREATE_HARDWARE_VERTEXPROCESSING,&pp,nullptr,&deviceEx),"deviceEx");
            device=deviceEx;
        } else check(api->CreateDevice(D3DADAPTER_DEFAULT,D3DDEVTYPE_HAL,window,D3DCREATE_HARDWARE_VERTEXPROCESSING,&pp,&device),"device");
        auto vs=read(argv[1]), ps=read(argv[2]);
        ComPtr<IDirect3DVertexShader9> vertex; ComPtr<IDirect3DPixelShader9> pixel;
        check(device->CreateVertexShader(vs.data(),&vertex),"vertex shader");
        check(device->CreatePixelShader(ps.data(),&pixel),"pixel shader");
        check(device->SetVertexShader(vertex.Get()),"bind vertex");
        check(device->SetPixelShader(pixel.Get()),"bind pixel");
        const D3DVERTEXELEMENT9 elements[]={{0,0,D3DDECLTYPE_FLOAT3,D3DDECLMETHOD_DEFAULT,D3DDECLUSAGE_POSITION,0},
            {0,12,D3DDECLTYPE_FLOAT2,D3DDECLMETHOD_DEFAULT,D3DDECLUSAGE_TEXCOORD,0},D3DDECL_END()};
        ComPtr<IDirect3DVertexDeclaration9> declaration;
        check(device->CreateVertexDeclaration(elements,&declaration),"declaration");
        check(device->SetVertexDeclaration(declaration.Get()),"bind declaration");
        ComPtr<IDirect3DTexture9> texture;
        check(device->CreateTexture(64,64,0,D3DUSAGE_DYNAMIC,D3DFMT_A8R8G8B8,D3DPOOL_DEFAULT,&texture,nullptr),"texture");
        constexpr DWORD colors[]={0xffff0000,0xff00ff00,0xff0000ff,0xffffff00,0xffff00ff,0xff00ffff,0xffffffff};
        for (unsigned mip=0;mip<7;++mip) {
            D3DLOCKED_RECT mapped{}; check(texture->LockRect(mip,&mapped,nullptr,0),"lock mip");
            for (unsigned y=0;y<(64u>>mip);++y) {
                auto row=reinterpret_cast<DWORD*>(static_cast<char*>(mapped.pBits)+y*mapped.Pitch);
                for(unsigned x=0;x<(64u>>mip);++x) row[x]=colors[mip];
            }
            check(texture->UnlockRect(mip),"unlock mip");
        }
        check(device->SetTexture(0,texture.Get()),"bind texture");
        for(auto mode:{D3DSAMP_MINFILTER,D3DSAMP_MAGFILTER,D3DSAMP_MIPFILTER})
            check(device->SetSamplerState(0,mode,D3DTEXF_LINEAR),"linear filter");
        const DWORD samplerBias=argc>=4?std::stoul(argv[3],nullptr,0):0;
        check(device->SetSamplerState(0,D3DSAMP_MIPMAPLODBIAS,samplerBias),"mip bias");
        check(device->SetSamplerState(0,D3DSAMP_MINFILTER,D3DTEXF_ANISOTROPIC),"anisotropic min");
        check(device->SetSamplerState(0,D3DSAMP_MAGFILTER,D3DTEXF_ANISOTROPIC),"anisotropic mag");
        check(device->SetSamplerState(0,D3DSAMP_MAXANISOTROPY,8),"anisotropy");
        check(device->SetSamplerState(0,D3DSAMP_SRGBTEXTURE,FALSE),"linear read");
        check(device->SetRenderState(D3DRS_SRGBWRITEENABLE,FALSE),"linear write");
        check(device->SetRenderState(D3DRS_CULLMODE,D3DCULL_NONE),"cull");
        check(device->SetRenderState(D3DRS_ZENABLE,FALSE),"depth");
        ComPtr<IDirect3DSurface9> target,staging;
        check(device->CreateRenderTarget(64,64,D3DFMT_A8R8G8B8,D3DMULTISAMPLE_NONE,0,FALSE,&target,nullptr),"target");
        check(device->CreateOffscreenPlainSurface(64,64,D3DFMT_A8R8G8B8,D3DPOOL_SYSTEMMEM,&staging,nullptr),"staging");
        check(device->SetRenderTarget(0,target.Get()),"bind target");
        D3DVIEWPORT9 viewport{0,0,64,64,0,1}; check(device->SetViewport(&viewport),"viewport");
        struct Vertex {float x,y,z,u,v;};
        const Vertex vertices[]={{-1,1,0,0,0},{1,1,0,1,0},{1,-1,0,1,1},
            {-1,1,0,0,0},{1,-1,0,1,1},{-1,-1,0,0,1}};
        bool passed=true;
        std::cout<<"{\"samples\":[";
        for(unsigned mip=0;mip<7;++mip) {
            const float params[]={float(mip),0,0,0};
            check(device->SetPixelShaderConstantF(0,params,1),"mip constant");
            check(device->Clear(0,nullptr,D3DCLEAR_TARGET,0xff252525,1,0),"clear");
            check(device->BeginScene(),"begin");
            check(device->DrawPrimitiveUP(D3DPT_TRIANGLELIST,2,vertices,sizeof(Vertex)),"draw");
            check(device->EndScene(),"end");
            check(device->GetRenderTargetData(target.Get(),staging.Get()),"readback");
            D3DLOCKED_RECT mapped{}; check(staging->LockRect(&mapped,nullptr,D3DLOCK_READONLY),"lock readback");
            DWORD actual=*reinterpret_cast<DWORD*>(static_cast<char*>(mapped.pBits)+16*mapped.Pitch+16*4);
            check(staging->UnlockRect(),"unlock readback");
            passed=passed && actual==colors[mip];
            if(mip) std::cout<<',';
            std::cout<<"{\"lod\":"<<mip<<",\"rgb\":["<<((actual>>16)&255)<<','<<((actual>>8)&255)<<','<<(actual&255)<<"]}";
        }
        DWORD bits=0; check(device->GetSamplerState(0,D3DSAMP_MIPMAPLODBIAS,&bits),"read mip bias");
        float bias=0; std::memcpy(&bias,&bits,sizeof(bias));
        std::cout<<"],\"samplerBias\":"<<bias<<",\"passed\":"<<(passed?"true":"false")<<"}\n";
        DestroyWindow(window); return passed?0:2;
    } catch(const std::exception& error) {
        if(window) DestroyWindow(window);
        std::cerr<<error.what()<<'\n'; return 1;
    }
}
