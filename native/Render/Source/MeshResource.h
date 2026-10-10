#pragma once

#include "Mesh/SectionGeometry.h"
#include <array>
#include <string>

class IMesh;
class IMaterial;

namespace mcmesh::l2
{
struct Part;
}

namespace mcmesh::source
{
/// Borrowed draw metadata. Valid while its MeshResource owner exists; mMesh is
/// cleared by Destroy. A scene must retain the owner's Lua userdata separately.
struct DrawResource
{
	IMesh							 *mMesh = nullptr;
	unsigned						  mIndices = 0;
	float							  mBounds[6]{};
	std::array<l2::DirectionRange, 7> mDirections{};
};

/// Owns one Source static mesh and its material reference. Create, upload,
/// draw and destruction all belong to the Lua/render thread. No worker access.
class MeshResource
{
public:
	MeshResource() = default;
	~MeshResource() { Destroy(); }
	MeshResource(const MeshResource &) = delete;
	MeshResource &operator=(const MeshResource &) = delete;

	/// Validates the upload boundary, then writes the original and directional
	/// index streams. On failure releases any acquired mesh/material and throws.
	void		  Upload(const l2::Part &inPart, unsigned inFirst, const std::string &inMaterialName);
	void		  Destroy();
	bool		  IsValid() const { return mDraw.mMesh != nullptr; }
	DrawResource &GetDrawResource() { return mDraw; }

private:
	IMaterial	*mMaterial = nullptr;
	DrawResource mDraw;
};
} // namespace mcmesh::source
