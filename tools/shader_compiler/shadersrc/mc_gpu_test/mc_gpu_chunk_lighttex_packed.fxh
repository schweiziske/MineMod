#ifndef MC_GPU_CHUNK_LIGHTTEX_PACKED_FXH
#define MC_GPU_CHUNK_LIGHTTEX_PACKED_FXH

// Native atlas layout (RGBA8888, point sampled): one 324x9 tile per chunk.
// x + y*18 chooses the pixel column; floor(z/4) chooses the row; z%4 chooses
// the byte channel. Each byte is block | (sky << 4), both raw 0..15 levels.
static const float MC_PACKED_ATLAS_SIZE = 4096.0f;
static const float MC_PACKED_BLOCK_SIZE = 36.5f;
static const float MC_PACKED_PAD = 1.0f;
static const float MC_PACKED_GRID_XY = 18.0f;
static const float MC_PACKED_GRID_Z = 34.0f;
static const float MC_PACKED_FACE_EPS = 0.01f;

float3 mcPackedFaceSampleLocalPos( float3 localPos, float faceIndex )
{
	if ( faceIndex < 1.5f ) localPos.z += MC_PACKED_FACE_EPS;
	else if ( faceIndex < 2.5f ) localPos.z -= MC_PACKED_FACE_EPS;
	else if ( faceIndex < 3.5f ) localPos.x += MC_PACKED_FACE_EPS;
	else if ( faceIndex < 4.5f ) localPos.x -= MC_PACKED_FACE_EPS;
	else if ( faceIndex < 5.5f ) localPos.y += MC_PACKED_FACE_EPS;
	else localPos.y -= MC_PACKED_FACE_EPS;
	return localPos;
}

float3 mcSamplePackedLightCell( float3 cell, float2 tileOrigin )
{
	cell = floor( cell ) + MC_PACKED_PAD;
	cell.x = clamp( cell.x, 0.0f, MC_PACKED_GRID_XY - 1.0f );
	cell.y = clamp( cell.y, 0.0f, MC_PACKED_GRID_XY - 1.0f );
	cell.z = clamp( cell.z, 0.0f, MC_PACKED_GRID_Z - 1.0f );

	float pixelX = cell.x + cell.y * MC_PACKED_GRID_XY;
	float pixelY = floor( cell.z * 0.25f );
	float4 packedTexel = tex2D( ChunkLightSampler,
		( tileOrigin + float2( pixelX + 0.5f, pixelY + 0.5f ) ) / MC_PACKED_ATLAS_SIZE );
	float channel = cell.z - pixelY * 4.0f;
	float4 selector = 1.0f - step( 0.5f, abs( float4( 0.0f, 1.0f, 2.0f, 3.0f ) - channel ) );
	float packed = floor( dot( packedTexel, selector ) * 255.0f + 0.5f );
	float sky = floor( packed / 16.0f );
	float block = packed - sky * 16.0f;
	return float3( 0.0f, block / 15.0f, sky / 15.0f );
}

// Exact separable form of the old bilerp-of-four-2x2-corner-averages. The
// repeated samples collapse from 16 texture reads to one 3x3 kernel (9 reads).
float3 mcSampleSmoothFaceLight9( float3 localPos, float faceIndex, float2 tileOrigin )
{
	// Cross plants occupy the sampled cell, not its boundary. Side-face
	// smoothing would mix in the opaque soil below and darken their bases.
	if ( faceIndex < 0.5f )
	{
		return mcSamplePackedLightCell( localPos / MC_PACKED_BLOCK_SIZE, tileOrigin );
	}
	float3 samplePos = mcPackedFaceSampleLocalPos( localPos, faceIndex );
	float3 baseCell = floor( samplePos / MC_PACKED_BLOCK_SIZE );
	float3 blockPos = localPos / MC_PACKED_BLOCK_SIZE;
	float2 blend = frac( blockPos.xz );
	float3 axisA = float3( 1.0f, 0.0f, 0.0f );
	float3 axisB = float3( 0.0f, 0.0f, 1.0f );
	if ( faceIndex < 2.5f )
	{
		blend = frac( blockPos.xy );
		axisA = float3( 1.0f, 0.0f, 0.0f );
		axisB = float3( 0.0f, 1.0f, 0.0f );
	}
	else if ( faceIndex < 4.5f )
	{
		blend = frac( blockPos.yz );
		axisA = float3( 0.0f, 1.0f, 0.0f );
		axisB = float3( 0.0f, 0.0f, 1.0f );
	}

	float3 weightA = float3( ( 1.0f - blend.x ) * 0.5f, 0.5f, blend.x * 0.5f );
	float3 weightB = float3( ( 1.0f - blend.y ) * 0.5f, 0.5f, blend.y * 0.5f );
	float3 a0 = baseCell - axisA;
	float3 a1 = baseCell;
	float3 a2 = baseCell + axisA;
	float3 light = mcSamplePackedLightCell( a0 - axisB, tileOrigin ) * weightA.x * weightB.x;
	light += mcSamplePackedLightCell( a1 - axisB, tileOrigin ) * weightA.y * weightB.x;
	light += mcSamplePackedLightCell( a2 - axisB, tileOrigin ) * weightA.z * weightB.x;
	light += mcSamplePackedLightCell( a0, tileOrigin ) * weightA.x * weightB.y;
	light += mcSamplePackedLightCell( a1, tileOrigin ) * weightA.y * weightB.y;
	light += mcSamplePackedLightCell( a2, tileOrigin ) * weightA.z * weightB.y;
	light += mcSamplePackedLightCell( a0 + axisB, tileOrigin ) * weightA.x * weightB.z;
	light += mcSamplePackedLightCell( a1 + axisB, tileOrigin ) * weightA.y * weightB.z;
	light += mcSamplePackedLightCell( a2 + axisB, tileOrigin ) * weightA.z * weightB.z;
	return light;
}

#endif
