#ifndef MC_GPU_SHADOW_RECEIVER_PLANE_FXH
#define MC_GPU_SHADOW_RECEIVER_PLANE_FXH

// Reconstruct d(reference depth) / d(shadow UV) from screen-space
// derivatives. Each PCF tap can then compare against the depth of the same
// receiver plane at that tap instead of moving the whole receiver away from
// the caster (the source of Peter Panning in the legacy normal-bias path).
float2 mcShadowReceiverDepthGradient( float2 shadowUV, float referenceDepth )
{
	float2 uvDx = ddx( shadowUV );
	float2 uvDy = ddy( shadowUV );
	float depthDx = ddx( referenceDepth );
	float depthDy = ddy( referenceDepth );
	float determinant = uvDx.x * uvDy.y - uvDx.y * uvDy.x;

	if ( abs( determinant ) < 1.0e-8f )
	{
		return float2( 0.0f, 0.0f );
	}

	float inverseDeterminant = 1.0f / determinant;
	return float2(
		( depthDx * uvDy.y - depthDy * uvDx.y ) * inverseDeterminant,
		( depthDy * uvDx.x - depthDx * uvDy.x ) * inverseDeterminant
	);
}

float mcShadowReceiverTapDepth(
	float centerDepth,
	float2 centerUV,
	float2 tapUV,
	float2 receiverDepthGradient )
{
	return centerDepth
		+ dot( receiverDepthGradient, tapUV - centerUV )
		- 1.0e-6f;
}

#endif
