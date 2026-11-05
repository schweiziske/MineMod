#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace mcmesh::source
{
enum class EEngineBranch
{
	Public,
	X86_64,
};

/// Inspect the two known Windows x64 layouts without calling either candidate.
/// The reader must reject addresses outside readable/executable engine sections.
/// Slot numbers are detection anchors only; engine calls use the typed SDK.
template<class TReadCode>
bool DetectMaterialSystemAbi(const uintptr_t *inMethods, TReadCode &&inReadCode, EEngineBranch &outBranch)
{
	// Verified CMaterialSystem::GetHardwareConfig implementation:
	// move (version, returnCode) into the factory argument registers, then tail
	// jump through the object's shader factory. Ignore its member displacement.
	constexpr uint8_t cHardwarePrefix[] = {0x48, 0x8b, 0xc2, 0x4c, 0x8b, 0xc9,
		0x49, 0x8b, 0xd0, 0x48, 0x8b, 0xc8, 0x49, 0xff, 0xa1};
	auto matches = [&](size_t inHardwareSlot, size_t inConfigSlot)
	{
		uint8_t hardware[19]{}, config[8]{};
		return inReadCode(inMethods[inHardwareSlot], hardware, sizeof(hardware))
			&& inReadCode(inMethods[inConfigSlot], config, sizeof(config))
			&& std::memcmp(hardware, cHardwarePrefix, sizeof(cHardwarePrefix)) == 0
			// GetCurrentConfigForVideoCard returns the static configuration:
			// lea rax, [rip + displacement]; ret.
			&& config[0] == 0x48 && config[1] == 0x8d && config[2] == 0x05 && config[7] == 0xc3;
	};
	const bool public_layout = matches(14, 17);
	const bool beta_layout = matches(18, 21);
	if (public_layout == beta_layout)
		return false;
	outBranch = public_layout ? EEngineBranch::Public : EEngineBranch::X86_64;
	return true;
}
} // namespace mcmesh::source
