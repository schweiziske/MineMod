-- DX9 sun shadows: opaque cascades update together and retain their projection.
-- V5 adds sky-entrance/interior rows; the water row still updates independently.
MC = MC or {}
local S = MC.RenderPBRShadows or { targets = {}, depthMaterials = {}, materialCount = 0 }
MC.RenderPBRShadows = S
local B, M, R, L = MC.RenderPBR, MC.RenderShadowMath, MC.RenderL2Resources, MC.RenderPackRuntime
local requireValue = R.Require
local DEPTH_MATERIAL_VERSION = 2
S.SKY_BOUNDARY_VERSION = 1
S.ORDINARY_SHADOW_VERSION = 1
S.skyTargets = S.skyTargets or {}
S.skyMaterials = S.skyMaterials or {}
S.skyCopyMaterials = S.skyCopyMaterials or {}
S.skyCopyQuads = S.skyCopyQuads or {}
S.waterMaterials = S.waterMaterials or setmetatable( {}, { __mode = "k" } )
S.entityMaterials = S.entityMaterials or {}
if S.atlasVersion ~= 2 then S.targets, S.atlasVersion = {}, 2 end
if S.depthMaterialVersion ~= DEPTH_MATERIAL_VERSION then
	-- Retained caster snapshots must also lose the old ALWAYS comparison.
	for _, record in pairs( S.depthMaterials ) do
		record.material:SetInt( "$depthtest", 1 )
		record.material:SetInt( "$writedepth", 0 )
		record.material:SetInt( "$ignorez", 0 )
		record.material:Recompute()
	end
	S.depthMaterialVersion = DEPTH_MATERIAL_VERSION
end
local enabled = MC.RenderPackSettings.Handle( "shadows" )
local skyBoundary = MC.RenderPackSettings.Handle( "shadow_sky_boundary" )
local resolution = MC.RenderPackSettings.Handle( "shadow_resolution" )
local distance = MC.RenderPackSettings.Handle( "shadow_range" )
local interval = MC.RenderPackSettings.Handle( "shadow_interval" )
local strength = MC.RenderPackSettings.Handle( "shadow_strength" )
local bias = MC.RenderPackSettings.Handle( "shadow_bias" )
local entityShadows = CreateClientConVar( "mc_pbr_shadow_entities", "1", true, false,
	"Cast Source prop, player, NPC and vehicle model shadows onto Minecraft surfaces" )
local waterEnabled = MC.RenderPackSettings.Handle( "water" )
local waterWaves = MC.RenderPackSettings.Handle( "water_waves" )
local waterCaustics = MC.RenderPackSettings.Handle( "water_caustics" )
local underwaterVolume = MC.RenderPackSettings.Handle( "underwater_volumetric" )
local underwaterStrength = MC.RenderPackSettings.Handle( "underwater_strength" )
local underwaterDensity = MC.RenderPackSettings.Handle( "underwater_density" )
local settingsRevision = 1
local settings = {}
local function readSettings()
	local size = resolution:GetInt()
	local useSkyBoundary = skyBoundary:GetBool()
	if settings.skyBoundary ~= useSkyBoundary then
		-- A mode switch must not publish old sky rows, even within the interval.
		S.valid, S.retryAt, S.nextUpdate = false, 0, 0
		B.DisableShadow()
	end
	settings.skyBoundary = useSkyBoundary
	settings.enabled, settings.size = enabled:GetBool(), size <= 256 and 256 or size <= 512 and 512 or size <= 1024 and 1024 or 2048
	local updateInterval = interval:GetFloat()
	if settings.interval ~= updateInterval then S.nextUpdate = 0 end
	settings.range, settings.interval = distance:GetFloat(), updateInterval
	settings.strength, settings.bias = strength:GetFloat(), bias:GetFloat()
	settingsRevision = settingsRevision + 1
end
for _, key in ipairs( { "shadows", "shadow_sky_boundary", "shadow_resolution", "shadow_range", "shadow_interval", "shadow_strength", "shadow_bias" } ) do
	MC.RenderPackSettings.OnChange( key, "mc_l2_pbr_shadows", readSettings )
end
readSettings()
S.stats = { mode = "full", updates = 0, nearUpdates = 0, farUpdates = 0, cascades = 0, cached = 0, throttled = 0, failures = 0, draws = 0, vertices = 0,
	testedChunks = 0, testedSections = 0, culledChunks = 0, culledSections = 0, duplicates = 0,
	testedRegions = 0, culledRegions = 0, regionChunks = 0, coverageUpdates = 0, fullCoverageFallbacks = 0,
	materialWrites = 0, cpuMS = 0, waterUpdates = 0, waterCPU = 0, skyDraws = 0, skyCopies = 0,
	interiorDraws = 0, interiorCascades = 0, status = "initializing" }
S.stats.entityDraws, S.stats.entityCasters = 0, 0
S.surfaceMaterials = setmetatable( {}, { __mode = "k" } )
S.renderRevision, S.tileToken = ( S.renderRevision or 0 ) + 1, ( S.tileToken or 0 ) + 1
S.valid, S.modelPushed, S.current, S.pending = false, false, {}, {}
S.rendering = false
S.nextUpdate, S.retryAt, S.camera = 0, 0, { enabled = false }
S.gridOrigin = nil
S.fullDirty, S.cascadeCasters = false, { {}, {} }
-- Discard metadata retained from the retired partial-update path on refresh.
S.dirtyChunks, S.dirtyCount, S.nearDirty, S.farDirty = nil, nil, nil, nil
local matrix, angles, unitTone = Matrix(), Angle(), Vector( 1, 1, 1 )
local setups = {
	{ type = "3D", origin = Vector(), angles = angles, ortho = {}, y = 0, drawviewmodel = false,
		drawviewer = false, dopostprocess = false, bloomtone = false },
	{ type = "3D", origin = Vector(), angles = angles, ortho = {}, y = 0, drawviewmodel = false,
		drawviewer = false, dopostprocess = false, bloomtone = false },
}
local stageNames = { "world_opaque", "world_cutout", "world_translucent" }
local pushedRT, startedCam, stateActive, toneActive, oldTone = false, false, false, false, nil
local clipActive, oldClip, scissorActive = false, false, false
local entityCamActive, entityOverrideActive = false, false
local entityCasters, entityCount = {}, 0
local entitySetup = { type = "3D", origin = Vector(), angles = angles, ortho = {},
	drawviewmodel = false, drawviewer = true, dopostprocess = false, bloomtone = false }
local entityMaterials = S.entityMaterials
local casterClasses = {
	prop_physics = true, prop_physics_multiplayer = true, prop_dynamic = true,
	prop_dynamic_override = true, prop_ragdoll = true,
}
-- C_PhysicsProp adds static-lighting streams when it sleeps. StudioRender
-- then ignores $softwareskin. A cached C_ClientsideModel keeps the same posed
-- silhouette without entering that physics-prop-only draw branch.
for _, record in pairs( S.entityProxies or {} ) do
	if IsValid( record.proxy ) then record.proxy:Remove() end
end
local entityProxies = {}
S.entityProxies = entityProxies
local proxyClasses = { prop_physics = true, prop_physics_multiplayer = true }
local proxyCollection = 0
local function removeEntityProxy( ent, record )
	entityProxies[ent] = nil
	if IsValid( record.proxy ) then record.proxy:Remove() end
end
local function clearEntityProxies()
	for ent, record in pairs( entityProxies ) do removeEntityProxy( ent, record ) end
end
local function prepareEntityProxy( ent, model )
	local record = entityProxies[ent]
	if record and ( record.model ~= model or not IsValid( record.proxy ) ) then
		removeEntityProxy( ent, record ) record = nil
	end
	if not record then
		local proxy = ClientsideModel( model, RENDERGROUP_OPAQUE )
		requireValue( IsValid( proxy ), "render_pbr_entity_proxy", "could not create a physics-prop shadow model: " .. model )
		record = { proxy = proxy, model = model, bones = {}, poseBones = {}, poseMatrices = {}, poseCount = 0,
			bodygroups = ent:GetNumBodyGroups() }
		entityProxies[ent] = record
		proxy:SetNoDraw( true )
		proxy:DrawShadow( false )
		for bone = 0, ent:GetBoneCount() - 1 do
			if ent:GetBoneName( bone ) ~= "__INVALIDBONE__" then record.bones[#record.bones + 1] = bone end
		end
		proxy:AddCallback( "BuildBonePositions", function( self )
			for i = 1, record.poseCount do self:SetBoneMatrix( record.poseBones[i], record.poseMatrices[i] ) end
		end )
	end
	local proxy = record.proxy
	record.collection = proxyCollection
	local origin = ent:GetRenderOrigin()
	if not isvector( origin ) then
		local world = MC.API.Coords.EntityWorldPos( ent )
		origin = MC.API.Coords.WorldToEngine( world, ent )
	end
	local orientation = ent:GetRenderAngles()
	if not orientation then orientation = ent:GetAngles() end
	proxy:SetRenderOrigin( origin )
	proxy:SetRenderAngles( orientation )
	proxy:SetSkin( ent:GetSkin() )
	for group = 0, record.bodygroups - 1 do proxy:SetBodygroup( group, ent:GetBodygroup( group ) ) end
	-- The copied world matrices already include model/bone scale. The proxy's
	-- own model scale stays at one so a rigid prop is not scaled a second time.
	ent:SetupBones()
	local count = 0
	for i = 1, #record.bones do
		local bone = record.bones[i]
		local pose = ent:GetBoneMatrix( bone )
		if pose then
			count = count + 1
			record.poseBones[count], record.poseMatrices[count] = bone, pose
		end
	end
	requireValue( count > 0, "render_pbr_entity_proxy_pose", "physics-prop shadow pose is unavailable: " .. model )
	record.poseCount = count
	proxy:InvalidateBoneCache()
	proxy:SetupBones()
	return proxy
end
local apiValidated = false
B.DisableShadow()

cvars.AddChangeCallback( "mc_pbr_shadow_entities", function()
	S.fullDirty = true
	if not entityShadows:GetBool() then clearEntityProxies() end
end, "mc_l2_pbr_shadows" )
hook.Add( "EntityRemoved", "mc_l2_pbr_entity_proxy", function( ent )
	local record = entityProxies[ent]
	if record then removeEntityProxy( ent, record ) end
end )
hook.Add( "ShutDown", "mc_l2_pbr_entity_proxy", clearEntityProxies )

-- Resolve each entity's engine frame at the collection boundary. Bounds are
-- culled in the same render frame as terrain; models keep their engine pose.
local function collectEntityCasters( view )
	entityCount = 0
	proxyCollection = proxyCollection + 1
	if entityShadows:GetBool() then
		local coords = MC.API.Coords
		for _, ent in ents.Iterator() do
			if IsValid( ent ) and not ent:GetNoDraw() and not ent:IsDormant()
				and ( casterClasses[ent:GetClass()] or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsVehicle() )
				and ( not ent:IsPlayer() or ent:Alive() )
				and ent:GetColor().a == 255 then
				local model = ent:GetModel()
				if model and string.sub( model, -4 ) == ".mdl" then
					local minimum, maximum = coords.EntityWorldAABB( ent )
					requireValue( minimum and maximum, "render_pbr_entity_bounds", "entity shadow bounds are unavailable" )
					minimum, maximum = coords.WorldToRender( minimum ), coords.WorldToRender( maximum )
					local bounds = {
						x = ( minimum.x + maximum.x ) * 0.5, y = ( minimum.y + maximum.y ) * 0.5,
						z = ( minimum.z + maximum.z ) * 0.5, hx = ( maximum.x - minimum.x ) * 0.5,
						hy = ( maximum.y - minimum.y ) * 0.5, hz = ( maximum.z - minimum.z ) * 0.5,
					}
					if M.Intersects( bounds, 0, 0, 0, view ) then
						local worldOrigin = coords.EngineToWorld( vector_origin, ent )
						local offset = coords.WorldToRender( worldOrigin )
						entityCount = entityCount + 1
						local record = entityCasters[entityCount] or {}
						record.entity, record.bounds = ent, bounds
						record.x, record.y, record.z = offset.x, offset.y, offset.z
						if proxyClasses[ent:GetClass()] then record.caster = prepareEntityProxy( ent, model )
						else record.caster = ent end
						entityCasters[entityCount] = record
					end
				end
			end
		end
	end
	for ent, record in pairs( entityProxies ) do
		if record.collection ~= proxyCollection then removeEntityProxy( ent, record ) end
	end
	for i = #entityCasters, entityCount + 1, -1 do entityCasters[i] = nil end
	S.stats.entityCasters = entityCount
end

-- Any scene change invalidates the complete atlas. Notifications received
-- during a render remain dirty for the next update.
function S.GeometryChanged()
	S.fullDirty = true
end
MC.RenderPackSettings.OnChange( "color_interpolation", "mc_l2_pbr_shadow_alpha", S.GeometryChanged )

function S.VisibilityChanged()
	S.fullDirty = true
end

function S.RuntimeChanged( active )
	if active == S.active then S.fullDirty = true end
end

local function shadowProgram( active )
	if not active then return nil end
	for s = 1, #stageNames do
		local nodes = active.bundle.nodes[stageNames[s]]
		for i = 1, #nodes do
			local node = nodes[i]
			if node.shadowProgram then
				if node.shadowOrdinaryProgram and not settings.skyBoundary then return node.shadowOrdinaryProgram, false end
				return node.shadowProgram, node.shadowSkyBoundary == true, node.shadowCopyProgram
			end
		end
	end
end

local function ensureTarget( size )
	if not apiValidated then
		requireValue( GetRenderTargetEx and render.PushRenderTarget and render.PopRenderTarget and render.Clear
			and render.SetStencilEnable
			and render.OverrideBlend and render.OverrideAlphaWriteEnable and render.OverrideColorWriteEnable
			and render.OverrideDepthEnable and render.EnableClipping and render.GetToneMappingScaleLinear
			and render.SetToneMappingScaleLinear and cam.Start and cam.End and cam.PushModelMatrix and cam.PopModelMatrix
			and matrix.SetField and MC.DrawPBRShadowCasters and M and M.Configure and M.Same and M.CoversCamera and M.WriteAngles and math.atan2
			and render.MaterialOverride and ents.Iterator and MC.API.Coords.EntityWorldAABB
			and MC.API.Coords.EngineToWorld and MC.API.Coords.WorldToRender
			and MATERIAL_RT_DEPTH_SEPARATE ~= nil and RT_SIZE_LITERAL ~= nil and IMAGE_FORMAT_RGBA8888 ~= nil
			and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil,
			"render_pbr_shadow_api", "PBR shadows require orthographic views, a separate depth buffer and exact RGBA8 writes" )
		apiValidated = true
	end
	-- Legacy v5 packs without ordinary companions retain their four-row ABI.
	local rows = S.skyBoundary and 4 or 2
	local key = size .. "/" .. rows
	local target = S.targets[key]
	if not target then
		target = GetRenderTargetEx( "mc_l2_pbr_shadow_rgba8_" .. rows .. "_" .. size, size * 2, size * rows,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		requireValue( target and not target:IsError() and target:Width() == size * 2 and target:Height() == size * rows,
			"render_pbr_shadow_target", "could not create the bounded point-filter shadow atlas" )
		S.targets[key] = target
	end
	return target
end

local function ensureSkyTarget( size )
	local target = S.skyTargets[size]
	if not target then
		target = GetRenderTargetEx( "mc_l2_pbr_sky_entrance1_" .. size, size * 2, size,
			RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		requireValue( target and not target:IsError() and target:Width() == size * 2 and target:Height() == size,
			"render_pbr_sky_shadow_target", "could not create the separate sky-entrance depth target" )
		S.skyTargets[size] = target
	end
	return target
end

local function copySkyRow( pending )
	local size, program = pending.resolution, S.copyProgram
	local key = program.vertex .. "/" .. program.pixel
	local material = S.skyCopyMaterials[key]
	if not material then
		requireValue( S.materialCount < 2048, "render_pbr_shadow_material_budget", "2048 immutable shadow materials reached" )
		material = CreateMaterial( "mc_l2_pbr_sky_copy1_" .. ( S.materialCount + 1 ), "screenspace_general_8tex", {
			["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
			["$basetexture"] = "vgui/white", ["$x360appchooser"] = 1, ["$nocull"] = 1,
			["$depthtest"] = 0, ["$writedepth"] = 0, ["$ignorez"] = 0,
			["$linearread_basetexture"] = 1, ["$linearwrite"] = 1,
		} )
		requireValue( material and not material:IsError(), "render_pbr_sky_copy_material", "could not create sky entrance copy material" )
		S.skyCopyMaterials[key], S.materialCount = material, S.materialCount + 1
	end
	local quad = S.skyCopyQuads[size]
	if not quad then
		quad = MC.RenderPackProcessing.CopyQuad( size * 2, size )
		S.skyCopyQuads[size] = quad
	end
	-- Copy colour only: the scratch depth buffer is not part of the atlas ABI.
	-- A row-sized viewport preserves the copy quad's D3D9 half-texel alignment.
	material:SetTexture( "$basetexture", pending.skyTarget )
	render.PopRenderTarget() pushedRT = false
	render.PushRenderTarget( pending.target, 0, size * 2, size * 2, size ) pushedRT = true
	render.OverrideDepthEnable( false, false )
	render.SetMaterial( material )
	quad:Draw()
	S.stats.skyCopies = S.stats.skyCopies + 1
	render.OverrideDepthEnable( true, true )
	render.PopRenderTarget() pushedRT = false
	render.PushRenderTarget( pending.target ) pushedRT = true
end

local function bindDepth( record )
	if record.revision ~= S.renderRevision then
		local view, material = S.renderState.views[1], record.material
		material:SetFloat( "$c0_x", view.fx )
		material:SetFloat( "$c0_y", view.fy )
		material:SetFloat( "$c0_z", view.fz )
		material:SetFloat( "$c0_w", 1 / view.zfar )
		material:SetFloat( "$c1_x", view.x )
		material:SetFloat( "$c1_y", view.y )
		material:SetFloat( "$c1_z", view.z )
		record.revision = S.renderRevision
		record.clip = nil
		S.stats.materialWrites = S.stats.materialWrites + 7
	end
	if S.skyBoundary and record.clip ~= S.skyClip then
		local size, material = S.renderState.resolution, record.material
		-- Never bind the entrance texture while it is the render target.
		if S.skyClip then material:SetTexture( "$texture1", S.renderState.skyTarget ) end
		material:SetFloat( "$c2_x", S.skyClip and 1 or 0 )
		material:SetFloat( "$c2_y", 1 / ( size * 2 ) )
		material:SetFloat( "$c2_z", 1 / size )
		material:SetFloat( "$c2_w", size * 3 )
		record.clip = S.skyClip
		S.stats.materialWrites = S.stats.materialWrites + 4
	end
	return record
end

local function skyMaterial()
	local key = S.program.vertex .. "/" .. S.program.pixel
	local record = S.skyMaterials[key]
	if not record then
		requireValue( S.materialCount < 2048, "render_pbr_shadow_material_budget", "2048 immutable shadow materials reached" )
		local material = CreateMaterial( "mc_l2_pbr_sky_entrance1_" .. ( S.materialCount + 1 ), "screenspace_general_8tex", {
			["$vertexshader"] = S.program.vertex, ["$pixshader"] = S.program.pixel,
			["$basetexture"] = "vgui/white", ["$texture1"] = "vgui/white",
			["$x360appchooser"] = 1, ["$nocull"] = 1,
			["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
			["$linearread_basetexture"] = 1, ["$linearread_texture1"] = 1, ["$linearwrite"] = 1,
			["$c1_w"] = 0, ["$c2_x"] = 0,
		} )
		requireValue( material and not material:IsError(), "render_pbr_sky_shadow_material", "could not create sky entrance material" )
		record = { material = material, seen = setmetatable( {}, { __mode = "k" } ) }
		S.skyMaterials[key], S.materialCount = record, S.materialCount + 1
	end
	return bindDepth( record )
end

S.WATER_DEPTH_VERSION = 1
function S.RegisterWater( surface, program, blockSize )
	requireValue( program and type( blockSize ) == "number" and blockSize > 0,
		"render_water_shadow_resource", "water shadows require the depth v1 program and runtime block size" )
	local previous = S.waterMaterials[surface]
	if previous and previous.program == program and previous.blockSize == blockSize then return end
	requireValue( S.materialCount < 2048, "render_pbr_shadow_material_budget", "2048 immutable shadow materials reached" )
	local material = CreateMaterial( "mc_l2_pbr_water_depth1_" .. ( S.materialCount + 1 ), "screenspace_general_8tex", {
		["$vertexshader"] = program.vertex, ["$pixshader"] = program.pixel,
		["$basetexture"] = "vgui/white", ["$x360appchooser"] = 1, ["$nocull"] = 1,
		["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
		["$linearread_basetexture"] = 1, ["$linearwrite"] = 1,
	} )
	requireValue( material and not material:IsError(), "render_water_shadow_material", "could not create water depth material" )
	S.waterMaterials[surface] = { material = material, program = program,
		blockSize = blockSize, seen = setmetatable( {}, { __mode = "k" } ) }
	S.materialCount, S.fullDirty = S.materialCount + 1, true
end

function S.CasterMaterial( surface, stage )
	if S.skyPass then return skyMaterial() end
	if S.waterPass then
		local record = S.waterMaterials[surface]
		if not record then return nil end
		if record.revision ~= S.renderRevision then
			local view, material = S.renderState.views[1], record.material
			material:SetFloat( "$c0_x", view.fx )
			material:SetFloat( "$c0_y", view.fy )
			material:SetFloat( "$c0_z", view.fz )
			material:SetFloat( "$c0_w", 1 / view.zfar )
			material:SetFloat( "$c1_x", view.x )
			material:SetFloat( "$c1_y", view.y )
			material:SetFloat( "$c1_z", view.z )
			record.revision = S.renderRevision
			S.stats.materialWrites = S.stats.materialWrites + 7
		end
		return record
	end
	if S.waterMaterials[surface] then return nil end
	local binding = S.surfaceMaterials[surface]
	local record
	if binding and binding.program == S.program and binding.stage == stage and binding.textureRevision == MC.TexturePackRevision then
		record = binding.record
	else
		local source = R.SourceTexture( surface )
		local resources = MC.ResourceGeneration
		local identity = resources and resources.Identity(source) or source:GetName()
		local signature = S.program.vertex .. "/" .. S.program.pixel .. "/" .. stage .. "/" .. identity
		record = S.depthMaterials[signature]
		if not record then
			requireValue( S.materialCount < 2048, "render_pbr_shadow_material_budget", "2048 immutable shadow materials reached" )
			local material = CreateMaterial( "mc_l2_pbr_depth" .. DEPTH_MATERIAL_VERSION .. "_" .. ( S.materialCount + 1 ), "screenspace_general_8tex", {
				["$vertexshader"] = S.program.vertex, ["$pixshader"] = S.program.pixel,
				["$basetexture"] = source:GetName(), ["$texture1"] = "vgui/white", ["$x360appchooser"] = 1, ["$nocull"] = 1,
				-- WRITEDEPTH=1 forces ALWAYS; renderAtlas owns the write override.
				["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
				["$linearread_basetexture"] = 1, ["$linearread_texture1"] = 1, ["$linearwrite"] = 1,
				["$c2_x"] = 0,
				["$c0_x"] = "0", ["$c0_y"] = "0", ["$c0_z"] = "-1", ["$c0_w"] = "1",
				["$c1_x"] = "0", ["$c1_y"] = "0", ["$c1_z"] = "0",
				["$c1_w"] = stage == "world_cutout" and "0.5" or "0",
			} )
			requireValue( material and not material:IsError(), "render_pbr_shadow_material", "could not create depth material" )
			material:SetTexture( "$basetexture", source )
			if MC.ResourceGeneration then MC.RenderPBR.BindSampling(material,source) end
			record = { material = material, source = source, seen = setmetatable( {}, { __mode = "k" } ) }
			S.depthMaterials[signature], S.materialCount = record, S.materialCount + 1
		elseif not (resources and resources.textures[source:GetName()]) then
			requireValue( R.SameTexture( source, record.source ), "render_pbr_shadow_texture_identity", "shadow albedo dimensions changed" )
		end
		record.material:SetTexture("$basetexture", source)
		if resources then MC.RenderPBR.BindSampling(record.material,source) end
		record.source = source
		S.surfaceMaterials[surface] = { program = S.program, stage = stage, record = record, textureRevision = MC.TexturePackRevision }
	end
	return bindDepth( record )
end

local function entityCasterMaterial()
	local key = "swskin/" .. S.program.vertex .. "/" .. S.program.pixel
	local record = entityMaterials[key]
	if not record then
		requireValue( S.materialCount < 2048, "render_pbr_shadow_material_budget", "2048 immutable shadow materials reached" )
		-- The terrain vertex shader has no hardware bone blending. Ask StudioRender
		-- for software-skinned world positions, with an identity model matrix, so
		-- the existing projection and linear-depth encoder consume the actual pose.
		-- This first pass casts opaque model silhouettes; it never rewrites the
		-- entity's materials, RenderOverride, render origin or bone matrices.
		local material = CreateMaterial( "mc_l2_pbr_entity_depth2_" .. ( S.materialCount + 1 ), "screenspace_general_8tex", {
			["$vertexshader"] = S.program.vertex, ["$pixshader"] = S.program.pixel,
			["$basetexture"] = "vgui/white", ["$texture1"] = "vgui/white",
			["$model"] = 1, ["$softwareskin"] = 1, ["$vertextransform"] = 1, ["$nocull"] = 1,
			["$depthtest"] = 1, ["$writedepth"] = 0, ["$ignorez"] = 0,
			["$linearread_basetexture"] = 1, ["$linearread_texture1"] = 1, ["$linearwrite"] = 1,
			["$c1_w"] = 0, ["$c2_x"] = 0,
		} )
		requireValue( material and not material:IsError(), "render_pbr_entity_shadow_material", "could not create Source model depth material" )
		record = { material = material }
		entityMaterials[key], S.materialCount = record, S.materialCount + 1
	end
	return bindDepth( record ).material
end

local function drawEntityCasters( view, setup, probeMaterial, probe )
	if entityCount == 0 then return end
	local material = probeMaterial or entityCasterMaterial()
	entitySetup.ortho.left, entitySetup.ortho.right = setup.ortho.left, setup.ortho.right
	entitySetup.ortho.top, entitySetup.ortho.bottom = setup.ortho.top, setup.ortho.bottom
	entitySetup.znear, entitySetup.zfar = setup.znear, setup.zfar
	entitySetup.x, entitySetup.y, entitySetup.w, entitySetup.h = setup.x, setup.y, setup.w, setup.h
	entityOverrideActive = true
	render.MaterialOverride( material )
	for i = 1, entityCount do
		local record = entityCasters[i]
		local ent = record.entity
		if IsValid( ent ) and M.Intersects( record.bounds, 0, 0, 0, view ) then
			-- Translate the light camera into this entity's engine frame rather
			-- than relocating the model (which would invalidate its cached pose).
			local x, y, z = view.x - record.x, view.y - record.y, view.z - record.z
			if probe and probe.renderFrame then x, y, z = view.x, view.y, view.z end
			entitySetup.origin.x, entitySetup.origin.y, entitySetup.origin.z = x, y, z
			if not probeMaterial then
				material:SetFloat( "$c1_x", x )
				material:SetFloat( "$c1_y", y )
				material:SetFloat( "$c1_z", z )
				S.stats.materialWrites = S.stats.materialWrites + 3
			end
			cam.Start( entitySetup ) entityCamActive = true
			if probe and probe.draw then probe.draw( record )
			elseif probe and probe.source then ent:DrawModel()
			elseif probeMaterial then ent:DrawModel()
			else record.caster:DrawModel() end
			cam.End() entityCamActive = false
			S.stats.entityDraws, S.stats.draws = S.stats.entityDraws + 1, S.stats.draws + 1
		end
	end
	render.MaterialOverride() entityOverrideActive = false
end

local function renderAtlas( pending, water, waterOnly, groups, version, chunks )
	S.renderState = pending
	local target = ensureTarget( pending.resolution )
	pending.target = target
	pending.skyBoundary = S.skyBoundary == true and settings.skyBoundary
	if not waterOnly then
		collectEntityCasters( pending.views[2] )
		pending.hasSky, pending.skyTarget = false, nil
		pending.skyCascades = pending.skyCascades or {}
		for i = 1, 2 do
			pending.skyCascades[i] = false
			for key in pairs( S.cascadeCasters[i] ) do S.cascadeCasters[i][key] = nil end
		end
		if pending.skyBoundary and MC.RenderSky.count > 0 then pending.skyTarget = ensureSkyTarget( pending.resolution ) end
	end
	M.WriteAngles( pending.views[1], angles )
	for i = 1, 2 do
		local view, setup = pending.views[i], setups[i]
		setup.origin.x, setup.origin.y, setup.origin.z = view.x, view.y, view.z
		setup.ortho.left, setup.ortho.right = -view.radius, view.radius
		setup.ortho.top, setup.ortho.bottom = -view.radius, view.radius
		setup.znear, setup.zfar = view.znear, view.zfar
		setup.x, setup.y, setup.w, setup.h = ( i - 1 ) * pending.resolution, 0, pending.resolution, pending.resolution
	end
	if waterOnly then
		requireValue( render.ClearBuffersObeyStencil and render.SetScissorRect,
			"render_caustics_clear_api", "water animation requires a bounded lower-row clear" )
		render.PushRenderTarget( target, 0, pending.resolution, pending.resolution * 2, pending.resolution )
	elseif pending.skyTarget then
		render.PushRenderTarget( pending.skyTarget )
	else
		render.PushRenderTarget( target )
	end
	pushedRT = true
	-- Water/portal views can leave a clip plane active. It belongs to the outer
	-- camera and must not cut the light volume.
	oldClip = render.EnableClipping( false ) clipActive = true
	oldTone = render.GetToneMappingScaleLinear()
	toneActive = true
	render.SetToneMappingScaleLinear( unitTone )
	stateActive = true
	render.SetStencilEnable( false )
	render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
	render.OverrideAlphaWriteEnable( true, true )
	render.OverrideColorWriteEnable( true, true )
	render.OverrideDepthEnable( true, true )
	S.waterPass = false
	S.skyPass, S.skyClip = false, false
	if pending.skyTarget and not waterOnly then
		render.Clear( 255, 255, 255, 255, true, true )
		S.skyPass = true
		local before = S.stats.draws
		for i = 1, 2 do
			S.casterKeys = S.cascadeCasters[i]
			local cascadeBefore = S.stats.draws
			S.tileToken = S.tileToken + 1
			cam.Start( setups[i] ) startedCam = true
			MC.DrawPBRShadowCasters( groups, version, chunks, pending.views[i], S )
			cam.End() startedCam = false
			pending.skyCascades[i] = S.stats.draws > cascadeBefore
		end
		S.stats.skyDraws = S.stats.draws - before
		pending.hasSky = S.stats.skyDraws > 0
		S.skyPass = false
		render.PopRenderTarget() pushedRT = false
		render.PushRenderTarget( target ) pushedRT = true
	end
	if waterOnly then
		-- Clear only the water row, never the retained opaque or sky rows.
		-- The opaque RG depth above remains the receiver's cached shadow map.
		scissorActive = true
		render.SetScissorRect( 0, pending.resolution, pending.resolution * 2, pending.resolution * 2, true )
		render.ClearBuffersObeyStencil( 255, 255, 255, 255, true )
		render.SetScissorRect( 0, 0, 0, 0, false ) scissorActive = false
	else
		render.Clear( 255, 255, 255, 255, true, true )
		for i = 1, 2 do
			S.casterKeys = S.cascadeCasters[i]
			S.tileToken = S.tileToken + 1
			cam.Start( setups[i] ) startedCam = true
			MC.DrawPBRShadowCasters( groups, version, chunks, pending.views[i], S )
			drawEntityCasters( pending.views[i], setups[i] )
			cam.End() startedCam = false
		end
		if pending.skyBoundary and pending.hasSky then
			copySkyRow( pending )
			S.skyClip = true
			local before = S.stats.draws
			for i = 1, 2 do
				if pending.skyCascades[i] then
					S.casterKeys = S.cascadeCasters[i]
					S.tileToken = S.tileToken + 1
					setups[i].y = pending.resolution * 3
					cam.Start( setups[i] ) startedCam = true
					MC.DrawPBRShadowCasters( groups, version, chunks, pending.views[i], S )
					drawEntityCasters( pending.views[i], setups[i] )
					cam.End() startedCam = false
					S.stats.interiorCascades = S.stats.interiorCascades + 1
				end
			end
			S.stats.interiorDraws = S.stats.draws - before
		end
	end
	S.skyPass, S.skyClip = false, false
	if water then
		requireValue( MC.DrawWaterShadowCasters, "render_caustics_draw_api", "water shadow caster draw API is unavailable" )
		S.waterPass = true
		for i = 1, 2 do
			S.casterKeys = S.cascadeCasters[i]
			S.tileToken = S.tileToken + 1
			setups[i].y = pending.resolution
			cam.Start( setups[i] ) startedCam = true
			MC.DrawWaterShadowCasters( pending.views[i], S )
			cam.End() startedCam = false
		end
	end
	S.waterPass = false
end

-- Cleanup always attempts every owned state before reporting. Strict faults
-- may throw, so none are reported until matrix/camera/RT cleanup has finished.
local cleanupError
local function restore( fn, ... )
	local ok, err = pcall( fn, ... )
	if not ok and not cleanupError then cleanupError = tostring( err ) end
end
local function cleanup()
	cleanupError = nil
	S.waterPass, S.skyPass, S.skyClip, S.renderState = false, false, false, nil
	if entityOverrideActive then restore( render.MaterialOverride ) entityOverrideActive = false end
	if entityCamActive then restore( cam.End ) entityCamActive = false end
	if scissorActive then restore( render.SetScissorRect, 0, 0, 0, 0, false ) scissorActive = false end
	if S.modelPushed then restore( cam.PopModelMatrix ) S.modelPushed = false end
	if startedCam then restore( cam.End ) startedCam = false end
	if stateActive then
		restore( render.SetStencilEnable, false )
		restore( render.OverrideDepthEnable, false, false )
		restore( render.OverrideColorWriteEnable, false, false )
		restore( render.OverrideAlphaWriteEnable, false, false )
		restore( render.OverrideBlend, false )
		-- Depth materials use $nocull; we never changed the outer winding mode.
		stateActive = false
	end
	if toneActive then restore( render.SetToneMappingScaleLinear, oldTone ) toneActive = false end
	if pushedRT then restore( render.PopRenderTarget ) pushedRT = false end
	if clipActive then restore( render.EnableClipping, oldClip ) clipActive = false end
	return cleanupError
end

local function publish()
	local current = S.current
	B.PublishShadow( current.export, matrix, settings.bias * current.blockSize / current.views[1].zfar, settings.strength )
	S.publishedSettings, S.publishedRevision = settingsRevision, B.shadowRevision
end

local function process( x, y, z, view )
	local current = S.current
	local ok, output = pcall( L.ProcessShadow, x, y, z, view, current )
	if not ok then
		current.export, S.valid, S.retryAt = nil, false, SysTime() + 1
		S.stats.failures, S.stats.status = S.stats.failures + 1, "failed"
		B.DisableShadow()
		L.QueueFault( "render_processing_shadowcomp", output )
		L.ReportFaults()
		return false
	end
	if current.export ~= output then S.publishedSettings = nil end
	current.export = output
	return true
end

local function ensurePublished( x, y, z, view )
	if not process( x, y, z, view ) then return false end
	-- Rebind refreshed constants or a changed export without redrawing geometry.
	if S.publishedSettings ~= settingsRevision or S.publishedRevision ~= B.shadowRevision then publish() end
	return true
end

local function disable( status )
	S.stats.status, S.publishedSettings = status, nil
	B.DisableShadow()
	return false
end

local function drawAtlas( state, water, waterOnly, groups, version, chunks, now )
	S.renderRevision = S.renderRevision + 1
	local stats = S.stats
	stats.draws, stats.vertices, stats.duplicates = 0, 0, 0
	stats.skyDraws, stats.skyCopies, stats.interiorDraws, stats.interiorCascades = 0, 0, 0, 0
	stats.testedChunks, stats.testedSections, stats.culledChunks, stats.culledSections = 0, 0, 0, 0
	stats.testedRegions, stats.culledRegions, stats.regionChunks = 0, 0, 0
	if not waterOnly then stats.entityDraws = 0 end
	S.rendering = true
	local ok, err = pcall( renderAtlas, state, water, waterOnly, groups, version, chunks )
	local restoreError = cleanup()
	S.rendering = false
	if not ok or restoreError then
		S.valid, S.retryAt = false, now + 1
		stats.failures = stats.failures + 1
		disable( "failed" )
		local code, message = "render_pbr_shadow_draw", tostring( err )
		if type( err ) == "table" then code, message = err.code, err.message end
		if restoreError then message = message .. "; cleanup: " .. restoreError end
		stats.lastError = message
		L.QueueFault( code, message )
		L.ReportFaults()
		return false
	end
	state.revision = S.renderRevision
	if not waterOnly then state.entityFrame = FrameNumber() end
	state.water, state.waterFrame, state.waterWaves = water, FrameNumber(), waterWaves:GetFloat()
	if waterOnly or water then stats.waterUpdates = stats.waterUpdates + 1 end
	if waterOnly then stats.waterCPU = ( SysTime() - now ) * 1000 end
	return true
end

local function updateWater( water )
	local current = S.current
	if current.water == water and ( not water or current.waterFrame == FrameNumber()
		and current.waterWaves == waterWaves:GetFloat() ) then return true end
	-- Time and water toggles never invalidate the opaque row. Use the current
	-- projection even when the camera/sun's pending projection is throttled.
	return drawAtlas( current, water, true, nil, nil, nil, SysTime() )
end

function S.Update( x, y, z, renderView )
	if S.rendering then return false end
	if not settings.enabled or settings.strength == 0 or MC.MeshRender and not MC.MeshRender:GetBool() then return disable( "off" ) end
	local active = L.active
	if active ~= S.active or S.programSkyBoundary ~= settings.skyBoundary then
		S.program, S.skyBoundary, S.copyProgram = shadowProgram( active )
		S.programSkyBoundary = settings.skyBoundary
		S.active, S.valid = active, false
		S.retryAt, S.nextUpdate = 0, 0
		B.DisableShadow()
	end
	if not S.program then return disable( "no_shadow_program" ) end
	local size = MC.API.Coords.BlockSize()
	if active.world ~= MC.World or active.worldGeneration ~= MC.StateWorldGeneration or active.blockSize ~= size
		or active.cs ~= MC.CS or active.ch ~= MC.CH or MC.WorldFrameSettled and not MC.WorldFrameSettled() then
		S.valid = false
		return disable( "world_transition" )
	end
	B.PrepareView( x, y, z )
	local sx, sy, sz, radiance = B.SunComponents()
	if radiance <= 0 then return disable( "night" ) end
	-- SunComponents already supplies a unit vector. Rounding its components
	-- independently then normalizing makes even a constant component oscillate.
	-- Throttle complete atlas/projection pairs below, not the solar trajectory.
	-- The world adapter refreshes this cache at the re-origin boundary.
	-- Polling WorldToRenderPos here would allocate an engine Vector each frame.
	local frameX, frameY, frameZ = MC.ChunkRenderFrameOffset()
	local current, pending = S.current, S.pending
	if S.valid and ( current.frameX ~= frameX or current.frameY ~= frameY or current.frameZ ~= frameZ ) then
		S.valid = false
		B.DisableShadow()
	end
	-- Derive the Iris grid from the current view's logical-world position;
	-- render re-origining must not change its world-space phase.
	M.Configure( pending, x, y, z, sx, sy, sz, size, settings.size, settings.range, frameX, frameY, frameZ )
	-- Full light-space coverage is independent of view direction/FOV. Never
	-- carry a camera-derived caster cone from an older cached projection.
	pending.views[1].cull, pending.views[2].cull = nil, nil
	local camera = S.camera
	camera.x, camera.y, camera.z = x, y, z
	local coverageMiss = S.valid and not ( M.CoversCamera( current.views[1], camera )
		and M.CoversCamera( current.views[2], camera ) )
	local groups, version, chunks = L.GetStages( false )
	local water = active.waterBinding and active.waterBinding.material
	-- Volumetric sunlight still needs the interface when caustics or waves
	-- are disabled; processing then bypasses to raw RG + neutral BA.
	local needsInterface = waterCaustics:GetBool() and waterWaves:GetFloat() > 0 or underwaterVolume:GetBool()
		and underwaterStrength:GetFloat() > 0 and underwaterDensity:GetFloat() > 0
	water = waterEnabled:GetBool() and needsInterface and water and S.waterMaterials[water] and water or nil
	pending.frameX, pending.frameY, pending.frameZ = frameX, frameY, frameZ
	local geometry, visibility = MC.ChunkDrawListVersion(), MC.StreamVisibilityVersion or 0
	-- Model movement and animation do not bump terrain's geometry version.
	-- Refresh poses at the configured shadow cadence, even with a frozen sun.
	local entityRefresh = entityShadows:GetBool() and current.entityFrame ~= FrameNumber()
	if S.valid and not S.fullDirty and not coverageMiss and current.version == version
		and current.geometry == geometry and current.visibility == visibility
		and not entityRefresh and M.Same( current, pending ) then
		if not updateWater( water ) then return false end
		if not ensurePublished( x, y, z, renderView ) then return false end
		S.stats.cached, S.stats.status = S.stats.cached + 1, "cached"
		return true
	end
	local now = SysTime()
	if now < S.retryAt then return disable( "retry_wait" ) end
	-- Retain the opaque pixels/projection during the configured interval.
	-- A remote view or changed world frame must still refresh immediately.
	if S.valid and not coverageMiss and now < S.nextUpdate then
		if not updateWater( water ) then return false end
		if not ensurePublished( x, y, z, renderView ) then return false end
		S.stats.throttled, S.stats.status = S.stats.throttled + 1, "throttled"
		return true
	end
	S.nextUpdate = now + settings.interval
	S.fullDirty = false
	if not drawAtlas( pending, water, false, groups, version, chunks, now ) then return false end
	local stats = S.stats
	pending.version, pending.geometry, pending.visibility, pending.blockSize = version, geometry, visibility, size
	pending.frameX, pending.frameY, pending.frameZ = frameX, frameY, frameZ
	S.current, S.pending, S.valid = pending, current, true
	for row = 1, 4 do for col = 1, 4 do matrix:SetField( row, col, pending.values[( row - 1 ) * 4 + col] ) end end
	if not process( x, y, z, renderView ) then return false end
	publish()
	stats.updates, stats.status, stats.lastError = stats.updates + 1, "ready", nil
	stats.nearUpdates, stats.farUpdates = stats.nearUpdates + 1, stats.farUpdates + 1
	stats.cascades = 2
	if coverageMiss then stats.coverageUpdates = stats.coverageUpdates + 1 end
	stats.cpuMS, stats.lastUpdate = ( SysTime() - now ) * 1000, now
	return true
end

function S.VolumeEnabled()
	return settings.enabled and settings.strength > 0 and B.SunEnabled()
		and ( not MC.MeshRender or MC.MeshRender:GetBool() )
end

local volumeCamera = { enabled = false }
-- Read the published atlas only. This consumer must not change update timing,
-- render another map, or pair a pending projection with the current pixels.
function S.VolumeSnapshot( x, y, z )
	if not S.VolumeEnabled() or not S.valid or S.rendering or S.active ~= L.active
		or S.publishedSettings ~= settingsRevision or S.publishedRevision ~= B.shadowRevision then return nil end
	local active, current = L.active, S.current
	if active.world ~= MC.World or active.worldGeneration ~= MC.StateWorldGeneration
		or current.blockSize ~= MC.API.Coords.BlockSize() or MC.WorldFrameSettled and not MC.WorldFrameSettled() then return nil end
	local fx, fy, fz = MC.ChunkRenderFrameOffset()
	if current.frameX ~= fx or current.frameY ~= fy or current.frameZ ~= fz then return nil end
	volumeCamera.x, volumeCamera.y, volumeCamera.z = x, y, z
	if not M.CoversCamera( current.views[2], volumeCamera ) then return nil end
	return current.export, matrix, settings.bias * current.blockSize / current.views[1].zfar, settings.strength
end

-- Draw preparation owns shadow updates. Remove the old early hook on Lua
-- refresh too: nested views could overwrite its result before terrain draws.
hook.Remove( "PreDrawOpaqueRenderables", "mc_l2_pbr_shadows" )

-- Explicit, one-shot GPU diagnostic. It never redraws the published atlas or
-- changes a setting. ReadPixels are confined to a private 256-square target.
local entityProbeQueued = false
local entityProbeIndex
concommand.Add( "mc_pbr_shadow_entity_probe", function( _, _, args )
	entityProbeIndex = tonumber( args[1] )
	entityProbeQueued = true
	print( "[MC entity shadow probe] v5 queued; comparing posed proxies with direct physics-model depth" )
end )
hook.Add( "PostRender", "mc_l2_pbr_entity_shadow_probe", function()
	if not entityProbeQueued or S.rendering then return end
	entityProbeQueued = false
	if not S.valid or not S.current.views then
		print( "[MC entity shadow probe] no valid shadow map; keep PBR shadows enabled and try again" )
		return
	end
	local savedStats = {}
	for key, value in pairs( S.stats ) do savedStats[key] = value end
	local results, size, readback, softwareSkin = {}, 256, nil, false
	local black = Color( 0, 0, 0 )
	local function readPixels()
		-- CapturePixels requires a 2D context, independently of the model camera.
		cam.Start2D() startedCam = true
		render.CapturePixels()
		local count, low, high = 0, 1, 0
		local minX, minY, maxX, maxY = size, size, -1, -1
		for y = 0, size - 1 do
			for x = 0, size - 1 do
				local r, g, b = render.ReadPixel( x, y )
				if r ~= 255 or g ~= 255 or b ~= 255 then
					count = count + 1
					minX, minY = math.min( minX, x ), math.min( minY, y )
					maxX, maxY = math.max( maxX, x ), math.max( maxY, y )
					local depth = ( r + g * 256 ) / 65535
					low, high = math.min( low, depth ), math.max( high, depth )
				end
			end
		end
		cam.End2D() startedCam = false
		return { pixels = count, low = low, high = high, bounds = { minX, minY, maxX, maxY } }
	end
	local function drawBounds( record )
		local bounds = record.bounds
		render.SetColorMaterial()
		render.DrawBox( Vector( bounds.x - record.x, bounds.y - record.y, bounds.z - record.z ),
			angle_zero, Vector( -bounds.hx, -bounds.hy, -bounds.hz ), Vector( bounds.hx, bounds.hy, bounds.hz ), black )
	end
	local function sample( view, material, mode )
		local setup = { type = "3D", origin = Vector( view.x, view.y, view.z ), angles = angles,
			ortho = { left = -view.radius, right = view.radius, top = -view.radius, bottom = view.radius },
			znear = view.znear, zfar = view.zfar, x = 0, y = 0, w = size, h = size,
			drawviewmodel = false, drawviewer = true }
		render.Clear( 255, 255, 255, 255, true, true )
		cam.Start( setup ) startedCam = true
		local before = S.stats.entityDraws
		if mode == "control" then
			-- A known primitive in the middle of the light volume bypasses all
			-- entity hooks, pose caches and world-adapter coordinate conversions.
			local half = view.radius * 0.125
			render.SetColorMaterial()
			render.DrawBox( Vector( view.x + view.fx * view.zfar * 0.5,
				view.y + view.fy * view.zfar * 0.5, view.z + view.fz * view.zfar * 0.5 ),
				angle_zero, Vector( -half, -half, -half ), Vector( half, half, half ), black )
		else
			local probe
			if mode == "bounds" then probe = { draw = drawBounds }
			elseif mode == "source" then probe = { source = true }
			elseif mode == "renderFrame" then probe = { renderFrame = true } end
			drawEntityCasters( view, setup, material, probe )
		end
		cam.End() startedCam = false
		local result = readPixels()
		result.draws = S.stats.entityDraws - before
		return result
	end
	local function probe()
		requireValue( render.CapturePixels and render.ReadPixel and render.DrawBox and render.SetColorMaterial,
			"render_pbr_entity_probe_api", "entity probe requires pixel readback and reference geometry" )
		collectEntityCasters( S.current.views[2] )
		if entityProbeIndex then
			local count = 0
			for i = 1, entityCount do
				if entityCasters[i].entity:EntIndex() == entityProbeIndex then
					count = count + 1
					entityCasters[count] = entityCasters[i]
				end
			end
			for i = entityCount, count + 1, -1 do entityCasters[i] = nil end
			entityCount = count
		end
		if not S.entityProbeTarget then
			S.entityProbeTarget = GetRenderTargetEx( "mc_l2_pbr_entity_probe1", size, size, RT_SIZE_LITERAL,
				MATERIAL_RT_DEPTH_SEPARATE, bit.bor( 1, 4, 8, 256, 512 ), 0, IMAGE_FORMAT_RGBA8888 )
		end
		requireValue( S.entityProbeTarget and not S.entityProbeTarget:IsError(), "render_pbr_entity_probe_target", "could not create private entity probe target" )
		if not S.entityProbeMaterial or S.entityProbeMaterialVersion ~= 2 then
			-- StudioRender overwrites $color with each entity's modulation. $color2
			-- survives that write, keeping the reference black against a white clear.
			S.entityProbeMaterial = CreateMaterial( "mc_l2_pbr_entity_probe_stock2", "UnlitGeneric", {
				["$basetexture"] = "vgui/white", ["$model"] = 1,
				["$color2"] = "[0 0 0]", ["$nocull"] = 1, ["$nofog"] = 1, ["$linearwrite"] = 1,
			} )
			S.entityProbeMaterialVersion = 2
		end
		requireValue( S.entityProbeMaterial and not S.entityProbeMaterial:IsError(), "render_pbr_entity_probe_material", "could not create stock model reference material" )
		S.renderState = { views = S.current.views, resolution = size }
		S.renderRevision = S.renderRevision + 1
		S.skyPass, S.skyClip, S.waterPass = false, false, false
		local depthMaterial = entityCasterMaterial()
		softwareSkin = bit.band( depthMaterial:GetInt( "$flags" ), bit.lshift( 1, 23 ) ) ~= 0
		render.PushRenderTarget( S.entityProbeTarget ) pushedRT = true
		oldClip = render.EnableClipping( false ) clipActive = true
		oldTone = render.GetToneMappingScaleLinear() toneActive = true
		render.SetToneMappingScaleLinear( unitTone )
		stateActive = true
		render.SetStencilEnable( false )
		render.OverrideBlend( true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
		render.OverrideAlphaWriteEnable( true, true )
		render.OverrideColorWriteEnable( true, true )
		render.OverrideDepthEnable( true, true )
		M.WriteAngles( S.current.views[1], angles )
		render.Clear( 17, 83, 149, 255, true, true )
		cam.Start2D() startedCam = true
		render.CapturePixels()
		local r, g, b = render.ReadPixel( size * 0.5, size * 0.5 )
		readback = string.format( "%d,%d,%d", r, g, b )
		cam.End2D() startedCam = false
		for i = 1, 2 do
			local view = S.current.views[i]
			results[i] = { control = sample( view, S.entityProbeMaterial, "control" ),
				bounds = sample( view, S.entityProbeMaterial, "bounds" ),
				depth = sample( view ), source = sample( view, nil, "source" ), stock = sample( view, S.entityProbeMaterial ),
				renderFrame = sample( view, S.entityProbeMaterial, "renderFrame" ) }
		end
	end
	S.rendering = true
	local ok, err = pcall( probe )
	local restoreError = cleanup()
	S.rendering = false
	for key, value in pairs( savedStats ) do S.stats[key] = value end
	if not ok or restoreError then
		local message = type( err ) == "table" and err.message or tostring( err )
		if restoreError then message = message .. "; cleanup: " .. restoreError end
		MC.Fault( "render_pbr_entity_probe", "%s", message )
		return
	end
	local proxyCount = 0
	for _ in pairs( entityProxies ) do proxyCount = proxyCount + 1 end
	S.entityProbeResult = { cascades = results, casters = entityCount, proxies = proxyCount,
		readback = readback, softwareSkin = softwareSkin, interval = settings.interval, frame = FrameNumber() }
	print( string.format( "[MC entity shadow probe] v5 casters=%d proxies=%d size=%d readback=%s expected=17,83,149 softwareSkin=%s interval=%.4f strength=%.3f bias=%.4f vertex=%s pixel=%s",
		entityCount, proxyCount, size, readback, tostring( softwareSkin ), settings.interval,
		settings.strength, settings.bias, S.program.vertex, S.program.pixel ) )
	for i = 1, 2 do
		local result = results[i]
		print( string.format( "[MC entity shadow probe] %s sourcePixels=%d proxyPixels=%d",
			i == 1 and "near" or "far", result.source.pixels, result.depth.pixels ) )
		print( string.format( "[MC entity shadow probe] %s customPixels=%d stockPixels=%d depth=%.6f..%.6f customBounds=%s stockBounds=%s",
			i == 1 and "near" or "far", result.depth.pixels, result.stock.pixels,
			result.depth.low, result.depth.high, table.concat( result.depth.bounds, "," ), table.concat( result.stock.bounds, "," ) ) )
		print( string.format( "[MC entity shadow probe] %s controlPixels=%d boundsPixels=%d renderFramePixels=%d modelCalls=%d",
			i == 1 and "near" or "far", result.control.pixels, result.bounds.pixels, result.renderFrame.pixels, result.stock.draws ) )
	end
	for i = 1, math.min( entityCount, 8 ) do
		local record = entityCasters[i]
		local ent, bounds = record.entity, record.bounds
		print( string.format( "[MC entity shadow probe] entity=%d class=%s pos=%s renderOrigin=%s offset=%.1f,%.1f,%.1f boundsCenter=%.1f,%.1f,%.1f",
			ent:EntIndex(), ent:GetClass(), tostring( ent:GetPos() ), tostring( ent:GetRenderOrigin() ),
			record.x, record.y, record.z, bounds.x, bounds.y, bounds.z ) )
	end
end )

concommand.Add( "mc_pbr_shadow_stats", function()
	local stats = S.stats
	print( string.format( "[MC PBR shadow] mode=full %s updates=%d near=%d far=%d cached=%d throttled=%d failures=%d size=%dx%d range=%.1f blocks updateCPU=%.3fms GPU=unmeasured interval=%.4fs",
		stats.status, stats.updates, stats.nearUpdates, stats.farUpdates, stats.cached, stats.throttled, stats.failures,
		settings.size * 2, settings.size * ( S.skyBoundary and 4 or 2 ), settings.range, stats.cpuMS, settings.interval ) )
	print( string.format( "[MC PBR shadow] skyBoundary=%s skyDraws=%d skyCopies=%d interiorDraws=%d interiorCascades=%d (single entrance per solar ray)",
		tostring( S.skyBoundary == true and settings.skyBoundary ), stats.skyDraws, stats.skyCopies, stats.interiorDraws, stats.interiorCascades ) )
	print( string.format( "[MC PBR shadow] waterUpdates=%d waterCPU=%.3fms (water row only; opaque interval unchanged)",
		stats.waterUpdates, stats.waterCPU ) )
	print( string.format( "[MC PBR shadow] entityShadows=%s entityCasters=%d entityDraws=%d (opaque model silhouettes)",
		tostring( entityShadows:GetBool() ), stats.entityCasters, stats.entityDraws ) )
	print( string.format( "[MC PBR shadow] lastDraw draws=%d vertices=%d chunksTested=%d chunksCulled=%d sectionsTested=%d sectionsCulled=%d duplicates=%d materials=%d constantWrites=%d",
		stats.draws, stats.vertices, stats.testedChunks, stats.culledChunks, stats.testedSections, stats.culledSections,
		stats.duplicates, S.materialCount, stats.materialWrites ) )
	local views = S.current.views
	print( string.format( "[MC PBR shadow] regionsTested=%d regionsCulled=%d chunksSkippedByRegions=%d coverageUpdates=%d fullCoverageFallbacks=%d nearViewCulling=%s farViewCulling=%s",
		stats.testedRegions, stats.culledRegions, stats.regionChunks, stats.coverageUpdates, stats.fullCoverageFallbacks,
		tostring( views and views[1].cull and views[1].cull.enabled == true or false ),
		tostring( views and views[2].cull and views[2].cull.enabled == true or false ) ) )
end )
