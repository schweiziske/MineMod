#include "../Render/Source/MaterialSystemAbi.h"
#include <array>
#include <cstdio>
#include <cstring>

int main()
{
	using namespace mcmesh::source;
	// Instruction bytes from the locally verified public and beta binaries.
	const uint8_t public_hardware[] = {0x48, 0x8b, 0xc2, 0x4c, 0x8b, 0xc9, 0x49, 0x8b, 0xd0, 0x48, 0x8b, 0xc8, 0x49, 0xff, 0xa1, 0xd8, 0x2e, 0x00, 0x02};
	const uint8_t beta_hardware[] = {0x48, 0x8b, 0xc2, 0x4c, 0x8b, 0xc9, 0x49, 0x8b, 0xd0, 0x48, 0x8b, 0xc8, 0x49, 0xff, 0xa1, 0x48, 0x2f, 0x00, 0x02};
	const uint8_t config[] = {0x48, 0x8d, 0x05, 0x39, 0xe3, 0x0b, 0x00, 0xc3};
	auto read_code = [&](uintptr_t inAddress, void *outBytes, size_t inSize)
	{
		if ((inAddress == reinterpret_cast<uintptr_t>(public_hardware) && inSize == sizeof(public_hardware))
			|| (inAddress == reinterpret_cast<uintptr_t>(beta_hardware) && inSize == sizeof(beta_hardware))
			|| (inAddress == reinterpret_cast<uintptr_t>(config) && inSize == sizeof(config)))
		{
			std::memcpy(outBytes, reinterpret_cast<const void *>(inAddress), inSize);
			return true;
		}
		return false;
	};
	std::array<uintptr_t, 22> methods{};
	EEngineBranch branch = EEngineBranch::X86_64;
	if (DetectMaterialSystemAbi(methods.data(), read_code, branch))
		return 1;
	methods[14] = reinterpret_cast<uintptr_t>(public_hardware);
	methods[17] = reinterpret_cast<uintptr_t>(config);
	if (!DetectMaterialSystemAbi(methods.data(), read_code, branch) || branch != EEngineBranch::Public)
		return 2;
	methods[18] = reinterpret_cast<uintptr_t>(beta_hardware);
	methods[21] = reinterpret_cast<uintptr_t>(config);
	if (DetectMaterialSystemAbi(methods.data(), read_code, branch))
		return 3;
	methods[14] = methods[17] = 0;
	if (!DetectMaterialSystemAbi(methods.data(), read_code, branch) || branch != EEngineBranch::X86_64)
		return 4;
	// A matching factory thunk alone is insufficient, and unreadable memory
	// must produce an unsupported-layout result rather than a speculative call.
	methods[21] = 1;
	if (DetectMaterialSystemAbi(methods.data(), read_code, branch))
		return 5;
	std::puts("material system ABI detection passed");
	return 0;
}
