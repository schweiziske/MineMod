// Production HLSL against the native semantic reducer on a hidden D3D9 device.
// This checks GPU sampling, not Source's sampler-state/atlas binding ABI.
#define NOMINMAX
#include <windows.h>
#include <d3d9.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include "Resources/Atlas/AtlasPixels.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <stdexcept>
using Microsoft::WRL::ComPtr;
using namespace mcmesh::atlas;
namespace fs = std::filesystem;
static void check(HRESULT hr, const char *label)
{
	if (FAILED(hr))
		throw std::runtime_error(label);
}
class Includes : public ID3DInclude
{
	fs::path						 root_;
	std::map<const void *, fs::path> paths_;

public:
	explicit Includes(const fs::path &source) : root_(source.parent_path()) {}
	HRESULT __stdcall Open(D3D_INCLUDE_TYPE, LPCSTR name, LPCVOID parent, LPCVOID *data, UINT *bytes) override
	{
		try
		{
			auto		  found = paths_.find(parent);
			fs::path	  path = (found == paths_.end() ? root_ : found->second.parent_path()) / name;
			std::ifstream file(path, std::ios::binary | std::ios::ate);
			if (!file)
				return E_FAIL;
			auto size = file.tellg();
			if (size < 0 || size > 1048576)
				return E_FAIL;
			auto buffer = std::make_unique<char[]>(size_t(size));
			file.seekg(0);
			if (!file.read(buffer.get(), size))
				return E_FAIL;
			paths_.emplace(buffer.get(), path);
			*bytes = UINT(size);
			*data = buffer.release();
			return S_OK;
		}
		catch (...)
		{
			return E_FAIL;
		}
	}
	HRESULT __stdcall Close(LPCVOID data) override
	{
		paths_.erase(data);
		delete[] static_cast<const char *>(data);
		return S_OK;
	}
};
static ComPtr<ID3DBlob> compile(const fs::path &path, const char *profile)
{
	ComPtr<ID3DBlob> code, errors;
	Includes		 includes(path);
	HRESULT			 hr = D3DCompileFromFile(path.c_str(), nullptr, &includes,
											 "main", profile, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
	if (FAILED(hr) && errors)
		std::cerr << static_cast<const char *>(errors->GetBufferPointer());
	check(hr, "compile production shader");
	return code;
}
static DWORD rgba(Pixel p)
{
	return D3DCOLOR_ARGB(p.a, p.r, p.g, p.b);
}
static Pixel integer(unsigned n)
{
	return {uint8_t(n), uint8_t(n >> 8), uint8_t(n >> 16), uint8_t(n >> 24)};
}
static Pixel number(float n)
{
	unsigned bits;
	std::memcpy(&bits, &n, sizeof(bits));
	return integer(bits);
}
static Pixel mix(Pixel a, Pixel b, float w, MipStrategy strategy)
{
	if (w <= 0)
		return a;
	if (w >= 1)
		return b;
	Pixel values[] = {a, b};
	float weights[] = {1 - w, w};
	return FilterMaterial(values, weights, 2, strategy);
}
int wmain(int argc, wchar_t **argv)
{
	HWND window = nullptr;
	try
	{
		if (argc != 2)
			throw std::runtime_error("expected repository root");
		const fs::path root = argv[1];
		WNDCLASSW	   wc{};
		wc.lpfnWndProc = DefWindowProcW;
		wc.hInstance = GetModuleHandleW(nullptr);
		wc.lpszClassName = L"MCMaterialMips";
		RegisterClassW(&wc);
		window = CreateWindowW(wc.lpszClassName, L"", WS_OVERLAPPED, 0, 0, 16, 16, nullptr, nullptr, wc.hInstance, nullptr);
		if (!window)
			throw std::runtime_error("hidden window");
		ComPtr<IDirect3D9> api;
		api.Attach(Direct3DCreate9(D3D_SDK_VERSION));
		if (!api)
			throw std::runtime_error("D3D9 unavailable");
		D3DPRESENT_PARAMETERS pp{};
		pp.Windowed = TRUE;
		pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
		pp.BackBufferWidth = 16;
		pp.BackBufferHeight = 16;
		pp.BackBufferFormat = D3DFMT_X8R8G8B8;
		ComPtr<IDirect3DDevice9> device;
		check(api->CreateDevice(0, D3DDEVTYPE_HAL, window, D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &device), "device");
		auto						   vs = compile(root / "shadersrc/l2/probes/probe_animation_vertex.fxc", "vs_3_0");
		auto						   ps = compile(root / "shadersrc/l2/probes/probe_material_mips.fxc", "ps_3_0");
		ComPtr<IDirect3DVertexShader9> vertex;
		ComPtr<IDirect3DPixelShader9>  pixel;
		check(device->CreateVertexShader(static_cast<const DWORD *>(vs->GetBufferPointer()), &vertex), "vertex");
		check(device->CreatePixelShader(static_cast<const DWORD *>(ps->GetBufferPointer()), &pixel), "pixel");
		check(device->SetVertexShader(vertex.Get()), "bind vertex");
		check(device->SetPixelShader(pixel.Get()), "bind pixel");
		const D3DVERTEXELEMENT9				elements[] = {{0, 0, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0}, D3DDECL_END()};
		ComPtr<IDirect3DVertexDeclaration9> declaration;
		check(device->CreateVertexDeclaration(elements, &declaration), "declaration");
		check(device->SetVertexDeclaration(declaration.Get()), "bind declaration");
		ComPtr<IDirect3DSurface9> target, staging;
		check(device->CreateRenderTarget(16, 16, D3DFMT_A8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &target, nullptr), "target");
		check(device->CreateOffscreenPlainSurface(16, 16, D3DFMT_A8R8G8B8, D3DPOOL_SYSTEMMEM, &staging, nullptr), "staging");
		check(device->SetRenderTarget(0, target.Get()), "bind target");
		D3DVIEWPORT9 viewport{0, 0, 16, 16, 0, 1};
		check(device->SetViewport(&viewport), "viewport");
		check(device->SetRenderState(D3DRS_CULLMODE, D3DCULL_NONE), "cull");
		check(device->SetRenderState(D3DRS_ZENABLE, FALSE), "depth");
		check(device->SetRenderState(D3DRS_SRGBWRITEENABLE, FALSE), "linear output");
		const float vertices[] = {0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1};
		const Pixel fixtures[2][6] = {
			{{128, 128, 255, 0}, {192, 160, 0, 255}, {64, 96, 64, 32}, {160, 64, 192, 224}, {96, 192, 128, 128}, {128, 128, 255, 255}},
			{{255, 10, 0, 255}, {0, 229, 64, 0}, {32, 230, 65, 254}, {224, 231, 255, 10}, {240, 255, 32, 0}, {16, 40, 192, 255}}};
		int cases = 0, worst = 0;
		for (int kind = 0; kind < 2; ++kind)
		{
			const auto						  strategy = kind == 0 ? MipStrategy::LabNormal : MipStrategy::LabSpecular;
			std::array<std::vector<Image>, 2> frames;
			for (int frame = 0; frame < 2; ++frame)
			{
				Image image{16, 16, {}};
				for (int y = 0; y < 16; ++y)
					for (int x = 0; x < 16; ++x)
						image.pixels.push_back(fixtures[kind][(x + y * 3 + frame * 2) % 6]);
				std::string error;
				if (!GenerateMips(image, 2, strategy, 0, false, frames[frame], error))
					throw std::runtime_error(error);
			}
			for (bool animated : {false, true})
			{
				ComPtr<IDirect3DTexture9> texture;
				check(device->CreateTexture(64, 64, 3, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &texture, nullptr), "texture");
				for (int level = 0; level <= 2; ++level)
				{
					D3DLOCKED_RECT lock{};
					check(texture->LockRect(level, &lock, nullptr, 0), "lock");
					auto put = [&](int x, int y, Pixel p)
					{
						reinterpret_cast<DWORD *>(static_cast<char *>(lock.pBits) + y * lock.Pitch)[x] = rgba(p);
					};
					for (int y = 0; y < (64 >> level); ++y)
						for (int x = 0; x < (64 >> level); ++x)
							put(x, y, {});
					for (int frame = 0; frame < 2; ++frame)
					{
						const auto &image = frames[frame][level];
						for (int y = 0; y < image.height; ++y)
							for (int x = 0; x < image.width; ++x)
								put(((16 + frame * 16) >> level) + x, ((frame * 16) >> level) + y, image.pixels[y * image.width + x]);
					}
					if (level == 0 && animated)
					{
						auto table = [&](int index, Pixel p)
						{
							put(index % 64, 32 + index / 64, p);
						};
						for (int y = 0; y < 4; ++y)
							for (int x = 4; x < 8; ++x)
								table(y * 16 + x, integer(256));
						table(256, integer(16)); // uint16 origin XY = (16,0)
						table(258, integer(261));
						table(259, integer(2));
						table(260, number(4));
						table(261, number(0));
						table(262, number(2));
						table(263, integer(16));
						table(264, integer(32 + 16 * 65536));
						table(265, number(2));
						table(266, number(2));
						table(267, integer(32 + 16 * 65536));
						table(268, integer(16));
					}
					check(texture->UnlockRect(level), "unlock");
				}
				const unsigned slot = kind == 0 ? 3 : 4;
				check(device->SetTexture(slot, texture.Get()), "bind texture");
				for (auto mode : {D3DSAMP_MINFILTER, D3DSAMP_MAGFILTER, D3DSAMP_MIPFILTER})
					check(device->SetSamplerState(slot, mode, D3DTEXF_LINEAR), "linear filter");
				check(device->SetSamplerState(slot, D3DSAMP_SRGBTEXTURE, FALSE), "linear input");
				// Color and material samplers need not share a calibration offset.
				for (int flags : {-1, 0, 1, 2, 3})
					for (int colorOffset : {0, 1})
						for (float tick : {0.f, .5f, 1.f, 1.5f, 2.f, 3.f, 4.f})
						{
							const float animation[] = {0, 32, 64, tick};
							const float scale = float(1 << colorOffset);
							const float footprint[] = {64 * scale * (flags > 0 && flags % 2 ? -1.f : 1.f),
													   64 * scale * (flags >= 2 ? -1.f : 1.f), scale * scale, float(-colorOffset)};
							const float mode[] = {float(flags), 0, 0, 0};
							check(device->SetPixelShaderConstantF(1, mode, 1), "mode");
							const float atlas[] = {64, 64, float(2 + colorOffset), 1.f / 4096};
							check(device->SetPixelShaderConstantF(16, animation, 1), "animation");
							check(device->SetPixelShaderConstantF(17, footprint, 1), "footprint");
							check(device->SetPixelShaderConstantF(18, atlas, 1), "atlas");
							for (float lod : {-1.f, 0.f, .25f, .5f, .75f, 1.f, 1.5f, 2.f, 3.f})
								for (float u : {.01f, .24f, .51f, .99f})
								{
									const float v = .37f;
									const float probe[] = {(16 + u * 16) / 64, v * 16 / 64, lod, kind == 0 ? 1.f : 0.f};
									check(device->SetPixelShaderConstantF(0, probe, 1), "probe");
									check(device->BeginScene(), "begin");
									check(device->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 2, vertices, 2 * sizeof(float)), "draw");
									check(device->EndScene(), "end");
									check(device->GetRenderTargetData(target.Get(), staging.Get()), "readback");
									D3DLOCKED_RECT lock{};
									check(staging->LockRect(&lock, nullptr, D3DLOCK_READONLY), "read lock");
									DWORD actual = reinterpret_cast<DWORD *>(static_cast<char *>(lock.pBits) + 8 * lock.Pitch)[8];
									check(staging->UnlockRect(), "read unlock");
									const int	frame = animated && std::fmod(tick, 4.f) >= 2 ? 1 : 0;
									const float timeWeight = animated ? std::floor(std::fmod(tick, 2.f) / 2 * 1000) / 1000 : 0;
									auto		sample = [&](int level)
									{
										const auto &image = frames[frame][level];
										auto		spatial = [&](int at)
										{
											const auto &pixels = frames[at][level];
											if (flags < 2)
											{
												float sampleU = flags < 0 ? u : (std::floor(u * 16) + .5f) / 16;
												float sampleV = flags < 0 ? v : (std::floor(v * 16) + .5f) / 16;
												return pixels.pixels[int(sampleV * image.height) * image.width + int(sampleU * image.width)];
											}
											float x = u * image.width - .5f, y = v * image.height - .5f;
											int	  ix = int(std::floor(x)), iy = int(std::floor(y));
											float fx = x - ix, fy = y - iy;
											Pixel taps[4];
											for (int t = 0; t < 4; ++t)
											{
												int tx = ix + t % 2, ty = iy + t / 2;
												taps[t] = tx >= 0 && tx < image.width && ty >= 0 && ty < image.height
															  ? pixels.pixels[ty * image.width + tx]
															  : Pixel{};
											}
											float weights[] = {(1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy};
											return FilterMaterial(taps, weights, 4, strategy);
										};
										return mix(spatial(frame), spatial(1 - frame), timeWeight, strategy);
									};
									float physical = std::clamp(lod, 0.f, 2.f);
									int	  low = int(physical);
									Pixel expected = mix(sample(low), sample(std::min(low + 1, 2)), physical - low, strategy);
									DWORD wanted = rgba(expected);
									for (int shift : {0, 8, 16, 24})
									{
										int delta = std::abs(int((actual >> shift) & 255) - int((wanted >> shift) & 255));
										worst = std::max(worst, delta);
										if (delta > 1)
										{
											std::cerr << "kind=" << kind << " flags=" << flags << " animated=" << animated << " tick=" << tick << " lod=" << lod << " u=" << u
													  << " actual=" << std::hex << actual << " expected=" << wanted << std::dec << '\n';
											throw std::runtime_error("material mip mismatch");
										}
									}
									++cases;
								}
						}
			}
		}
		std::cout << "Material mip GPU/native: " << cases << " cases, max channel difference " << worst << '\n';
		// Raw runtime color must be decoded at texel centres before spatial
		// interpolation. Alpha remains linear, including depth/shadow sampling.
		ComPtr<IDirect3DTexture9> color;
		check(device->CreateTexture(64, 64, 3, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &color, nullptr), "color texture");
		auto colorPixel = [](int level, int x, int y)
		{
			return Pixel{uint8_t((x % 2) * 192 + level * 16), uint8_t((y % 2) * 160 + level * 24),
						 uint8_t(((x + y) % 2) * 128 + level * 32), uint8_t((x % 2) * 255)};
		};
		for (int level = 0; level < 3; ++level)
		{
			D3DLOCKED_RECT lock{};
			check(color->LockRect(level, &lock, nullptr, 0), "color lock");
			int size = 64 >> level;
			for (int y = 0; y < size; ++y)
				for (int x = 0; x < size; ++x)
				{
					Pixel p = y < size / 2 ? colorPixel(level, x, y) : Pixel{};
					reinterpret_cast<DWORD *>(static_cast<char *>(lock.pBits) + y * lock.Pitch)[x] = rgba(p);
				}
			check(color->UnlockRect(level), "color unlock");
		}
		check(device->SetTexture(0, color.Get()), "color bind");
		for (auto mode : {D3DSAMP_MINFILTER, D3DSAMP_MAGFILTER, D3DSAMP_MIPFILTER})
			check(device->SetSamplerState(0, mode, D3DTEXF_LINEAR), "color filter");
		check(device->SetSamplerState(0, D3DSAMP_SRGBTEXTURE, FALSE), "raw color");
		const float animation[] = {0, 32, 64, 0}, atlas[] = {64, 64, 2, 1.f / 4096};
		check(device->SetPixelShaderConstantF(16, animation, 1), "color animation");
		check(device->SetPixelShaderConstantF(18, atlas, 1), "color atlas");
		auto decode = [](float v)
		{
			return v <= .04045f ? v / 12.92f : std::pow((v + .055f) / 1.055f, 2.4f);
		};
		int colorCases = 0;
		for (int flags : {0, 1, 2, 3})
			for (int kind : {1, 2})
			{
				const float mode[] = {0, float(kind), 0, 0};
				const float footprint[] = {flags % 2 ? -64.f : 64.f, flags >= 2 ? -64.f : 64.f, 1, 0};
				check(device->SetPixelShaderConstantF(1, mode, 1), "color mode");
				check(device->SetPixelShaderConstantF(17, footprint, 1), "color flags");
				for (float lod : {0.f, .25f, .5f, 1.f, 1.75f, 2.f, 3.f})
					for (float u : {.323f, .417f, .511f})
					{
						const float v = .19f;
						const float probe[] = {u, v, lod, 0};
						check(device->SetPixelShaderConstantF(0, probe, 1), "color probe");
						check(device->BeginScene(), "color begin");
						check(device->DrawPrimitiveUP(D3DPT_TRIANGLELIST, 2, vertices, 2 * sizeof(float)), "color draw");
						check(device->EndScene(), "color end");
						check(device->GetRenderTargetData(target.Get(), staging.Get()), "color read");
						D3DLOCKED_RECT lock{};
						check(staging->LockRect(&lock, nullptr, D3DLOCK_READONLY), "color read lock");
						DWORD actual = reinterpret_cast<DWORD *>(static_cast<char *>(lock.pBits) + 8 * lock.Pitch)[8];
						check(staging->UnlockRect(), "color read unlock");
						float physical = std::min(lod, 2.f);
						int	  low = int(physical);
						for (int channel = 0; channel < 4; ++channel)
						{
							auto sample = [&](int level)
							{
								float su = flags % 2 ? u : (std::floor(u * 64) + .5f) / 64;
								float sv = flags % 2 ? v : (std::floor(v * 64) + .5f) / 64;
								float size = float(64 >> level), x = su * size - .5f, y = sv * size - .5f;
								int	  ix = int(std::floor(x)), iy = int(std::floor(y));
								float fx = x - ix, fy = y - iy, result = 0;
								for (int t = 0; t < 4; ++t)
								{
									Pixel p = colorPixel(level, ix + t % 2, iy + t / 2);
									float value = (channel == 0 ? p.r : channel == 1 ? p.g
																	: channel == 2	 ? p.b
																					 : p.a) /
												  255.f;
									if (flags % 2 && kind == 1 && channel < 3)
										value = decode(value);
									result += value * (t % 2 ? fx : 1 - fx) * (t / 2 ? fy : 1 - fy);
								}
								return result;
							};
							float w = physical - low;
							float expected = sample(low) * (1 - w) + sample(std::min(low + 1, 2)) * w;
							if (!(flags % 2) && kind == 1 && channel < 3)
								expected = decode(expected);
							const int shifts[] = {16, 8, 0, 24};
							int		  delta = std::abs(int((actual >> shifts[channel]) & 255) - int(std::floor(expected * 255 + .5f)));
							if (delta > 2)
								throw std::runtime_error("color spatial/LOD/gamma interpolation mismatch");
						}
						++colorCases;
					}
			}
		std::cout << "Color GPU: " << colorCases << " cases, independent flags, linear-light RGB and alpha, mip bounds passed\n";
		DestroyWindow(window);
		return 0;
	}
	catch (const std::exception &error)
	{
		if (window)
			DestroyWindow(window);
		std::cerr << error.what() << '\n';
		return 1;
	}
}
