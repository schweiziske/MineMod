-- Bloom for the fancy GPU chunk-lighting path.
--
-- The chunk pixel shader can make bright, light-aware source pixels, but a
-- material shader cannot sample neighbouring framebuffer pixels. DrawBloom is
-- therefore the actual spread/blur stage. It is restricted to the fancy GPU
-- path and only runs while MC meshes exist, so CPU/vanilla looks keep their
-- original presentation and empty maps pay no post-process cost.
MC = MC or {}

local mathClamp = math.Clamp

local function convarFloat( cv, fallback, minValue, maxValue )
	local value = fallback
	if cv and cv.GetFloat then value = tonumber( cv:GetFloat() ) or fallback end
	return mathClamp( value, minValue, maxValue )
end

local function hasChunkMeshes()
	return ( MC.Meshes and next( MC.Meshes ) ~= nil )
		or ( MC.MeshesTrans and next( MC.MeshesTrans ) ~= nil )
end

local function bloomActive()
	if not DrawBloom then return false end
	if not ( MC.MeshBloom and MC.MeshBloom.GetBool and MC.MeshBloom:GetBool() ) then return false end
	if MC.MeshRender and MC.MeshRender.GetBool and not MC.MeshRender:GetBool() then return false end
	if not ( MC.LightStyleName and MC.LightStyleName() == "fancy" ) then return false end
	if not ( MC.UsingGpuChunkShader and MC.UsingGpuChunkShader() ) then return false end
	if not ( MC.UsingGpuLightTexture and MC.UsingGpuLightTexture() ) then return false end
	return hasChunkMeshes()
end

hook.Add( "RenderScreenspaceEffects", "mc_mesh_fancy_bloom", function()
	if not bloomActive() then return end

	local night = MC.DayCycleNightBlend and tonumber( MC.DayCycleNightBlend() ) or 0
	night = mathClamp( night, 0, 1 )

	-- Daylight uses a slightly higher threshold to avoid blooming the whole
	-- sky; at night the threshold relaxes and the strength rises so torch pools
	-- develop a readable halo without changing the underlying material color.
	local threshold = convarFloat( MC.MeshBloomThreshold, 0.7, 0, 1 )
	threshold = mathClamp( threshold + ( 1 - night ) * 0.05, 0, 1 )
	local strength = convarFloat( MC.MeshBloomStrength, 0.8, 0, 3 ) * ( 0.90 + night * 0.25 )
	local radius = convarFloat( MC.MeshBloomRadius, 6, 1, 16 )

	-- Keep the blur almost neutral. The shader seed already carries orange
	-- torch / gold sun color; this small blue reduction stops pale highlights
	-- from turning into a cold white fog.
	local warmth = convarFloat( MC.MeshShadowMapWarmth, 0.35, 0, 1 )
	local bloomGreen = 1 - warmth * 0.08
	local bloomBlue = 1 - warmth * 0.24
	DrawBloom( threshold, strength, radius, radius, 1, 1, 1, bloomGreen, bloomBlue )
end )
