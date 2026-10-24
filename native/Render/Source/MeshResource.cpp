#include "Module/Pch.h"
#include "Render/Source/MeshResource.h"
#include "Render/Source/EngineContext.h"
#include "Mesh/SectionWorker.h"
#include <algorithm>
#include <stdexcept>

namespace mcmesh::source
{
void MeshResource::Upload(const l2::Part &inPart, unsigned inFirst, const std::string &inMaterialName)
{
	l2::require(!IsValid(), "L2 resource is already uploaded");
	try
	{
		const unsigned count = static_cast<unsigned>(inPart.quads.size());
		l2::require(count > 0, "L2 upload requires geometry");
		l2::require(inPart.pixels != nullptr, "L2 upload is missing its pixels");
		inPart.pixels->validate(count);
		l2::require(!inMaterialName.empty() && inMaterialName.front() == '!', "L2 requires a runtime declaration material");
		l2::require(source::GetMaterialSystem() != nullptr, "L2 material system unavailable");
		IMaterial *material = source::GetMaterialSystem()->FindMaterial(inMaterialName.c_str(), TEXTURE_GROUP_OTHER, false);
		l2::require(material && !material->IsErrorMaterial(), "L2 declaration material not found");
		const VertexFormat_t	 format = material->GetVertexFormat() & ~VERTEX_FORMAT_COMPRESSED;
		constexpr auto			 cRequired = VERTEX_POSITION | VERTEX_COLOR;
		constexpr VertexFormat_t cAllowed = cRequired | VERTEX_NORMAL |
											VERTEX_FORMAT_VERTEX_SHADER | VERTEX_FORMAT_USE_EXACT_FORMAT |
											VERTEX_TEXCOORD_MASK(0) | VERTEX_TEXCOORD_MASK(1);
		const bool				 has_normal = (VertexFlags(format) & VERTEX_NORMAL) != 0;
		const int				 secondary_uv = TexCoordSize(1, format);
		if ((VertexFlags(format) & cRequired) != cRequired || TexCoordSize(0, format) != 2 ||
			(secondary_uv != 0 && secondary_uv != 2) || (format & ~cAllowed) != 0)
		{
			throw std::runtime_error("L2 declaration material requires position, COLOR and 2D UV0, "
									 "with only optional normal and 2D UV1: material=" +
									 inMaterialName +
									 " format=" + std::to_string(format) + " uv0=" + std::to_string(TexCoordSize(0, format)) +
									 " uv1=" + std::to_string(secondary_uv));
		}
		CMatRenderContextPtr context(source::GetMaterialSystem()->GetRenderContext());
		l2::require(!!context, "L2 render context unavailable");
		mDraw.mMesh = context->CreateStaticMesh(format, TEXTURE_GROUP_STATIC_VERTEX_BUFFER_OTHER, material);
		l2::require(mDraw.mMesh != nullptr, "L2 CreateStaticMesh failed");
		mMaterial = material;
		material->IncrementReferenceCount();
		mDraw.mIndices = count * 6;
		std::copy(inPart.bounds, inPart.bounds + 6, mDraw.mBounds);
		// Keep the original stream for water/translucency and append a second
		// index order for directional draws. Vertex/atlas/relight order is fixed.
		const auto	computed = inPart.directions.quads.empty() ? l2::directionOrder(inPart.quads) : l2::DirectionOrder{};
		const auto &ordered = inPart.directions.quads.empty() ? computed : inPart.directions;
		mDraw.mDirections = ordered.ranges;
		for (auto &range : mDraw.mDirections)
			range.first += count * 6;
		CMeshBuilder builder;
		builder.Begin(mDraw.mMesh, MATERIAL_TRIANGLES, count * 4, count * 12);
		unsigned address = inFirst * 4;
		for (const auto &quad : inPart.quads)
			for (const auto &v : quad.vertices)
			{
				builder.Position3f(v.position[0], v.position[1], v.position[2]);
				if (has_normal)
					builder.Normal3f(v.normal[0], v.normal[1], v.normal[2]);
				builder.TexCoord2f(0, v.uv[0], v.uv[1]);
				if (secondary_uv)
					builder.TexCoord2f(1, 0, 0);
				builder.Color4ub(static_cast<uint8_t>(address), static_cast<uint8_t>(address >> 8),
								 static_cast<uint8_t>(address >> 16), v.color[3]);
				++address;
				builder.AdvanceVertex();
			}
		for (unsigned i = 0; i < count; ++i)
			for (unsigned corner : l2::Triangle)
			{
				builder.Index(static_cast<unsigned short>(i * 4 + corner));
				builder.AdvanceIndex();
			}
		for (unsigned i : ordered.quads)
			for (unsigned corner : l2::Triangle)
			{
				builder.Index(static_cast<unsigned short>(i * 4 + corner));
				builder.AdvanceIndex();
			}
		builder.End();
	}
	catch (...)
	{
		Destroy();
		throw;
	}
}

void MeshResource::Destroy()
{
	if (!mDraw.mMesh)
		return;
	CMatRenderContextPtr context(GetMaterialSystem()->GetRenderContext());
	context->DestroyStaticMesh(mDraw.mMesh);
	mDraw.mMesh = nullptr;
	mMaterial->DecrementReferenceCount();
	mMaterial = nullptr;
}
} // namespace mcmesh::source
