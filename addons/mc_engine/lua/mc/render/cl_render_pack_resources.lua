-- Quad-v1 is deliberately one supported adapter, not a callback/plugin ABI.
MC = MC or {}
local P = MC.RenderPackResources or {
	materials = {}, textures = {}, materialCount = 0, textureCount = 0,
	builds = {}, buildCount = 0,
	shared = { prefix = "mc_l2_runtime", capacity = 1048576, materials = {} },
}
MC.RenderPackResources = P
local R, Schema = MC.RenderL2Resources, MC.RenderPackSchema
local requireValue = R.Require
local STAGES = { "world_opaque", "world_cutout", "world_translucent" }
P.STAGES = STAGES

local function sortedKeys( values )
	local keys = {}
	for key in pairs( values ) do keys[#keys + 1] = key end
	table.sort( keys )
	return keys
end

function P.Validate( plan )
	requireValue( file and file.Read and util and util.SHA256,
		"render_pack_verify_api", "mounted-file reads and SHA256 are required" )
	local result = { plan = plan, nodes = {}, requests = {}, sources = {}, files = {}, textures = {}, materialMaps = {} }
	local bytesRead, fileCount = 0, 0
	local function verify( path, hash )
		if result.files[path] then
			requireValue( result.files[path] == hash, "render_pack_resource_conflict", "conflicting content: " .. path )
			return
		end
		local bytes = file.Read( path, "GAME" )
		requireValue( type( bytes ) == "string" and #bytes > 0, "render_pack_file_missing",
			plan.pack .. ": missing mounted resource " .. path )
		bytesRead, fileCount = bytesRead + #bytes, fileCount + 1
		requireValue( #bytes <= 16777216 and bytesRead <= 67108864 and fileCount <= 256,
			"render_pack_file_budget", plan.pack .. ": selected resources exceed 64 MiB / 256 files" )
		requireValue( util.SHA256( bytes ) == hash, "render_pack_file_hash",
			plan.pack .. ": mounted bytes do not match " .. path )
		result.files[path] = hash
	end
	local newBuilds = {}
	for _, ownerKey in ipairs( sortedKeys( plan.owners ) ) do
		local owner = plan.owners[ownerKey]
		local def = owner.definition
		local moving = def.adapter == "mc:pbr_quad_v4" or def.adapter == "mc:vanilla_quad_v2"
		local independentAO = def.adapter == "mc:pbr_quad_v3" or def.adapter == "mc:pbr_quad_v4"
		local ibl = independentAO or def.adapter == "mc:pbr_quad_v2"
		local pbr = ibl or def.adapter == "mc:pbr_quad_v1"
		requireValue( def.abi == 1 and def.layout == "mc:quad_corners_v1"
			and ( pbr or def.adapter == "mc:vanilla_quad_draft" or def.adapter == "mc:vanilla_quad_v2" ),
			"render_pack_adapter", ownerKey .. ": unsupported quad-corners-v1 adapter" )
		if moving then
			requireValue( MC.RenderDynamicLights and MC.RenderDynamicLights.VERSION == 1,
				"render_dynamic_light_adapter", ownerKey .. ": moving lights require engine light-data v1" )
			for _, name in ipairs( { "opaque", "cutout", "translucent", "sprite" } ) do
				requireValue( def.programs["dynamic_" .. name], "render_dynamic_light_program", ownerKey .. ": missing dynamic_" .. name )
			end
			for _, name in ipairs( { "water", "block_entity" } ) do
				requireValue( not def.programs[name] or def.programs["dynamic_" .. name],
					"render_dynamic_light_program", ownerKey .. ": missing dynamic_" .. name )
			end
		end
		requireValue( not independentAO or R.OCCLUSION_VERSION == 1, "render_pbr_occlusion_adapter",
			ownerKey .. ": PBR v3 requires the independent corner AO atlas; update the engine and restart the client" )
		if def.programs.block_entity then
			local pass = def.passes.terrain_cutout
			requireValue( independentAO and pass and pass.stage == "world_cutout",
				"render_block_entity_adapter", ownerKey .. ": standalone PBR requires the v3 terrain_cutout resources" )
		end
		if def.programs.water then
			local pass, normal = def.passes.terrain_translucent, def.resources.water_normal
			requireValue( independentAO and MC.RenderPBRWater and MC.RenderPBRWater.VERSION == 1
				and pass and pass.stage == "world_translucent" and normal and normal.colorSpace == "linear",
				"render_water_adapter", ownerKey .. ": water requires v3 terrain_translucent, linear water_normal and water payload v1" )
		end
		if def.programs.water_ssr then
			requireValue( def.programs.water and def.programs.scene_depth and def.programs.ssr_copy
				and def.programs.water_ssr_composite and MC.RenderPBRSSR and MC.RenderPBRSSR.VERSION == 1,
				"render_ssr_adapter", ownerKey .. ": SSR requires the water SSR v1 engine and all four auxiliary programs" )
		end
		if def.programs.post_ssao then
			requireValue( pbr and MC.RenderPBRPost and MC.RenderPBRPost.VERSION == 1
				and def.programs.post_ssao_composite and def.programs.post_scene_depth
				and def.programs.post_depth_copy and def.programs.ssr_copy,
				"render_post_adapter", ownerKey .. ": post lighting requires scene depth and the AO/resolve programs" )
		end
		if def.programs.post_fog then
			requireValue( def.programs.post_ssao, "render_fog_adapter", ownerKey .. ": fog requires the shared post-depth contract" )
		end
		if def.programs.post_bloom_prefilter then
			requireValue( def.programs.post_ssao and def.programs.post_bloom_blur and def.programs.post_bloom_composite,
				"render_bloom_adapter", ownerKey .. ": bloom requires the post contract and all three programs" )
		end
		if def.programs.post_volumetric then
			requireValue( def.programs.post_fog and def.programs.post_volumetric_composite
				and MC.RenderPBRPost and MC.RenderPBRPost.VOLUMETRIC_VERSION == 1,
				"render_volumetric_adapter", ownerKey .. ": volumetric sunlight requires the v1 atmosphere and resolve programs" )
		end
		local buildKey = ownerKey .. "/" .. def.build
		if not P.builds[buildKey] then newBuilds[#newBuilds + 1] = buildKey end
		for _, name in ipairs( sortedKeys( def.programs ) ) do
			local program = def.programs[name]
			verify( "shaders/fxc/" .. program.vertex .. ".vcs", program.vertexHash )
			verify( "shaders/fxc/" .. program.pixel .. ".vcs", program.pixelHash )
		end
		for _, name in ipairs( sortedKeys( def.resources ) ) do
			local resource = def.resources[name]
			verify( resource.path, resource.sha256 )
			result.textures[ownerKey .. "/" .. name] = resource
		end
		requireValue( pbr or next( def.materialMaps ) == nil, "render_pack_material_maps",
			ownerKey .. ": source material maps require the PBR adapter" )
		for name, mapping in pairs( def.materialMaps ) do
			requireValue( def.resources[mapping.normal].colorSpace == "linear"
				and def.resources[mapping.orm].colorSpace == "linear", "render_pbr_map_color_space",
				ownerKey .. "/" .. name .. ": material normal and ORM maps must be linear data" )
		end
		for name, pass in pairs( def.passes ) do
			requireValue( pass.stage == "world_opaque" or pass.stage == "world_cutout" or pass.stage == "world_translucent",
				"render_pack_stage", ownerKey .. "/" .. name .. ": unsupported processing stage " .. pass.stage )
			requireValue( not moving or def.programs["dynamic_" .. pass.program],
				"render_dynamic_light_program", ownerKey .. "/" .. name .. ": missing local-light companion program" )
			for semantic in pairs( pass.inputs ) do
				requireValue( semantic == "albedo" or pbr and ( semantic == "normal" or semantic == "orm" )
					or ibl and ( semantic == "environment" or semantic == "dfg" ), "render_pack_input",
					ownerKey .. "/" .. name .. ": unsupported quad-v1 input " .. semantic )
			end
			if pbr then
				requireValue( pass.inputs.normal and pass.inputs.orm, "render_pbr_maps",
					ownerKey .. "/" .. name .. ": PBR requires normal and ORM maps (1x1 neutral maps are supported)" )
				requireValue( def.resources[pass.inputs.normal].colorSpace == "linear"
					and def.resources[pass.inputs.orm].colorSpace == "linear", "render_pbr_map_color_space",
					ownerKey .. "/" .. name .. ": normal and ORM maps must use linear data reads" )
			end
			if ibl then
				requireValue( pass.inputs.environment and pass.inputs.dfg, "render_pbr_ibl",
					ownerKey .. "/" .. name .. ": PBR IBL requires prefiltered environment and DFG maps" )
				requireValue( def.resources[pass.inputs.environment].colorSpace == "linear"
					and def.resources[pass.inputs.dfg].colorSpace == "linear", "render_pbr_ibl_color_space",
					ownerKey .. "/" .. name .. ": IBL and DFG maps must use linear data reads" )
			end
		end
	end
	requireValue( P.buildCount + #newBuilds <= 64, "render_pack_build_budget",
		"64 runtime owner/build versions reached; restart the client before loading more" )
	result.newBuilds, result.bytesRead = newBuilds, bytesRead
	for _, stage in ipairs( STAGES ) do result.nodes[stage] = {} end
	local nodes, successors, predecessors = {}, {}, {}
	for _, key in ipairs( sortedKeys( plan.requests ) ) do
		local request = plan.requests[key]
		local def = plan.owners[request.owner].definition
		local moving = def.adapter == "mc:pbr_quad_v4" or def.adapter == "mc:vanilla_quad_v2"
		local byStage = {}
		for _, stage in ipairs( STAGES ) do byStage[stage] = {} end
		result.requests[key] = byStage
		for _, name in ipairs( request.passes ) do
			local pass, nodeKey = def.passes[name], request.owner .. "/" .. name
			local node = nodes[nodeKey]
			if not node then
				node = { key = nodeKey, stage = pass.stage, program = def.programs[pass.program], adapter = def.adapter,
					dynamicProgram = moving and def.programs["dynamic_" .. pass.program] or nil,
					owner = request.owner, materialMaps = def.materialMaps,
					shadowProgram = ( def.adapter == "mc:pbr_quad_v1" or def.adapter == "mc:pbr_quad_v2"
						or def.adapter == "mc:pbr_quad_v3" or def.adapter == "mc:pbr_quad_v4" ) and def.programs.shadow or nil }
				if pass.inputs.albedo then
					node.albedo = result.textures[request.owner .. "/" .. pass.inputs.albedo]
				end
				if pass.inputs.normal then node.normal = result.textures[request.owner .. "/" .. pass.inputs.normal] end
				if pass.inputs.orm then node.orm = result.textures[request.owner .. "/" .. pass.inputs.orm] end
				if pass.inputs.environment then node.environment = result.textures[request.owner .. "/" .. pass.inputs.environment] end
				if pass.inputs.dfg then node.dfg = result.textures[request.owner .. "/" .. pass.inputs.dfg] end
				nodes[nodeKey] = node
				successors[nodeKey], predecessors[nodeKey] = {}, 0
				local stageNodes = result.nodes[pass.stage]
				stageNodes[#stageNodes + 1] = node
			end
			local list = byStage[pass.stage]
			local previous = list[#list]
			if previous and not successors[previous.key][nodeKey] then
				successors[previous.key][nodeKey] = true
				predecessors[nodeKey] = predecessors[nodeKey] + 1
			end
			list[#list + 1] = node
		end
	end
	-- Shared passes must satisfy every public implementation's declared order.
	for _, stage in ipairs( STAGES ) do
		local pending, ordered = {}, {}
		for _, node in ipairs( result.nodes[stage] ) do
			if predecessors[node.key] == 0 then pending[#pending + 1] = node.key end
		end
		while #pending > 0 do
			table.sort( pending )
			local key = table.remove( pending, 1 )
			ordered[#ordered + 1] = nodes[key]
			for nextKey in pairs( successors[key] ) do
				predecessors[nextKey] = predecessors[nextKey] - 1
				if predecessors[nextKey] == 0 then pending[#pending + 1] = nextKey end
			end
		end
		requireValue( #ordered == #result.nodes[stage], "render_pack_pass_order",
			plan.pack .. ": conflicting pass order in " .. stage )
		result.nodes[stage] = ordered
	end
	return result
end

function P.Fork( bundle )
	return { plan = bundle.plan, nodes = bundle.nodes, requests = bundle.requests,
		files = bundle.files, textures = bundle.textures, sources = {}, newBuilds = {}, bytesRead = 0, materialMaps = {} }
end

function P.Ensure( bundle )
	R.Ensure( { build = "quad_corners_v1" }, P.shared )
	for _, key in ipairs( bundle.newBuilds ) do
		if not P.builds[key] then
			P.builds[key], P.buildCount = true, P.buildCount + 1
		end
	end
end

local function textureFor( resource, dataMap, repeatTexture, pixelated )
	local key = resource.path .. "/" .. resource.sha256 .. ( dataMap and "/data" or "" )
		.. ( repeatTexture and "/repeat" or "" ) .. ( pixelated and "/point" or "" )
	local cached = P.textures[key]
	if cached then return cached end
	requireValue( P.textureCount < 128, "render_pack_texture_budget", "128 runtime texture versions reached" )
	local path = resource.path:sub( 11 )
	local material
	if path:sub( -4 ) == ".vtf" then
		material = CreateMaterial( "mc_l2_file_" .. resource.sha256, "UnlitGeneric",
			{ ["$basetexture"] = path:sub( 1, -5 ) } )
	else
		requireValue( Material ~= nil, "render_pack_image_api", "Material() is required for image resources" )
		-- Imported PNGs clamp by default. Water uses unbounded world/time UVs;
		-- ordinary atlases and IBL data must retain their existing clamp policy.
		-- Block normal/specular texels stay square like the albedo: no "smooth".
		material = Material( path, repeatTexture and "smooth mips noclamp" or pixelated and "mips"
			or dataMap and "smooth mips" or nil )
	end
	local texture = R.SourceTexture( material )
	requireValue( texture:Width() > 0 and texture:Width() <= 4096 and texture:Height() > 0 and texture:Height() <= 4096,
		"render_pack_texture_size", resource.path .. ": dimensions exceed the 4096-square limit" )
	P.textures[key], P.textureCount = texture, P.textureCount + 1
	return texture
end

-- Material( "x.png", flags ) prefixes the texture name with seven flag digits;
-- the same image loaded with different flags must still find its maps.
local function sourceKey( texture )
	return ( string.gsub( texture:GetName(), "^%d%d%d%d%d%d%d", "" ) )
end

local function mappingFor( bundle, node, source )
	if next( node.materialMaps ) == nil then return nil end
	local mappings = bundle.materialMaps[node.owner]
	if not mappings then
		mappings = {}
		for _, name in ipairs( sortedKeys( node.materialMaps ) ) do
			local mapping = node.materialMaps[name]
			local prefix = node.owner .. "/"
			local albedoResource = bundle.textures[prefix .. mapping.albedo]
			local normalResource, ormResource = bundle.textures[prefix .. mapping.normal], bundle.textures[prefix .. mapping.orm]
			local albedo = textureFor( albedoResource )
			local key = sourceKey( albedo )
			local previous = mappings[key]
			requireValue( not previous or previous.normalResource.sha256 == normalResource.sha256
				and previous.ormResource.sha256 == ormResource.sha256, "render_pbr_map_conflict",
				"conflicting PBR maps for source texture " .. key )
			mappings[key] = { source = albedo, colorSpace = albedoResource.colorSpace,
				normalResource = normalResource, ormResource = ormResource }
		end
		bundle.materialMaps[node.owner] = mappings
	end
	local mapping = mappings[sourceKey( source )]
	if mapping then
		requireValue( source:Width() == mapping.source:Width() and source:Height() == mapping.source:Height(),
			"render_pbr_source_identity", "mapped albedo texture dimensions changed: " .. source:GetName() )
		if not mapping.normal then
			local normal, orm = textureFor( mapping.normalResource, true, false, true ), textureFor( mapping.ormResource, true, false, true )
			-- All maps use normalized source UVs. Their pixel aspect and
			-- resolution may differ; textureFor validates hardware size limits.
			mapping.normal, mapping.orm = normal, orm
		end
	end
	return mapping
end

function P.Passes( bundle, request, stage )
	local stages = bundle.requests[request]
	local nodes = stages and stages[stage]
	requireValue( nodes and #nodes > 0, "render_pack_missing_stage",
		bundle.plan.pack .. ": " .. request .. " has no implementation for " .. stage )
	return nodes
end

function P.Material( bundle, node, sourceMaterial, blockSize )
	local source = R.SourceTexture( sourceMaterial )
	bundle.sources[sourceMaterial] = source
	local ibl = node.adapter == "mc:pbr_quad_v2" or node.adapter == "mc:pbr_quad_v3" or node.adapter == "mc:pbr_quad_v4"
	local pbr = ibl or node.adapter == "mc:pbr_quad_v1"
	local colorSpace = pbr and "srgb" or "linear"
	if node.albedo then source, colorSpace = textureFor( node.albedo ), node.albedo.colorSpace end
	local normal, orm
	local normalResource, ormResource = node.normal, node.orm
	if pbr then
		local mapping = mappingFor( bundle, node, source )
		if mapping then
			normal, orm, colorSpace = mapping.normal, mapping.orm, mapping.colorSpace
			normalResource, ormResource = mapping.normalResource, mapping.ormResource
		else
			normal, orm = textureFor( normalResource, true ), textureFor( ormResource, true )
		end
	end
	local environment, dfg
	if ibl then
		environment, dfg = textureFor( node.environment, true ), textureFor( node.dfg, true )
		requireValue( environment:Width() == 512 and environment:Height() == 256 and dfg:Width() == 128 and dfg:Height() == 128,
			"render_pbr_ibl_dimensions", "PBR IBL requires a 512x256 radiance atlas and a 128x128 DFG map" )
	end
	local signature = Schema.Canonical( { vertex = node.program.vertex, pixel = node.program.pixel,
		stage = node.stage, source = source:GetName(), colorSpace = colorSpace, blockSize = blockSize,
		adapter = node.adapter, normal = normal and ( normal:GetName() .. "/" .. normalResource.sha256 ),
		orm = orm and ( orm:GetName() .. "/" .. ormResource.sha256 ),
		environment = environment and ( environment:GetName() .. "/" .. node.environment.sha256 ),
		dfg = dfg and ( dfg:GetName() .. "/" .. node.dfg.sha256 ) } )
	local cached = P.materials[signature]
	if cached then
		requireValue( R.SameTexture( cached.source, source ), "render_pack_texture_identity",
			"cached texture name or dimensions changed: " .. source:GetName() )
		if pbr then
			requireValue( R.SameTexture( cached.normal, normal ) and R.SameTexture( cached.orm, orm ),
				"render_pbr_texture_identity", "cached PBR data-map dimensions changed" )
		end
		return cached.material
	end
	requireValue( P.materialCount < 2048, "render_pack_material_budget", "2048 immutable runtime materials reached" )
	local slot = tostring( P.materialCount + 1 )
	local maps
	if pbr then maps = { normal = normal, orm = orm, environment = environment, dfg = dfg, colorSpace = colorSpace } end
	local material = R.BoundMaterial( P.shared, slot, source, node.stage, blockSize, node.program, colorSpace, maps )
	if node.dynamicProgram then
		MC.RenderDynamicLights.RegisterMaterial( material, node.dynamicProgram, P.shared, source, node.stage, blockSize, maps )
	end
	P.materials[signature] = { material = material, source = source, normal = normal, orm = orm }
	P.materialCount = P.materialCount + 1
	return material
end

function P.WaterMaterial( bundle, owner, blockSize )
	local def = bundle.plan.owners[owner].definition
	local inputs = def.passes.terrain_translucent.inputs
	local normal = textureFor( def.resources.water_normal, true, true )
	local orm = textureFor( def.resources[inputs.orm], true )
	local environment = textureFor( def.resources[inputs.environment], true )
	local dfg = textureFor( def.resources[inputs.dfg], true )
	requireValue( normal:Width() == 256 and normal:Height() == 256
		and environment:Width() == 512 and environment:Height() == 256 and dfg:Width() == 128 and dfg:Height() == 128,
		"render_water_texture_size", "water requires 256x256 normal/foam, 512x256 IBL and 128x128 DFG textures" )
	local signature = Schema.Canonical( { water = def.programs.water, normal = def.resources.water_normal.sha256,
		environment = def.resources[inputs.environment].sha256, dfg = def.resources[inputs.dfg].sha256, blockSize = blockSize } )
	local cached = P.materials[signature]
	if cached then return cached.material end
	requireValue( P.materialCount < 2048, "render_pack_material_budget", "2048 immutable runtime materials reached" )
	local maps = { normal = normal, orm = orm, environment = environment, dfg = dfg, water = true }
	local material = R.BoundMaterial( P.shared, tostring( P.materialCount + 1 ), normal,
		"world_translucent", blockSize, def.programs.water, "srgb", maps )
	if def.adapter == "mc:pbr_quad_v4" and def.programs.dynamic_water then
		MC.RenderDynamicLights.RegisterMaterial( material, def.programs.dynamic_water, P.shared, normal,
			"world_translucent", blockSize, maps )
	end
	if def.programs.water_ssr then MC.RenderPBRSSR.Register( material, def, maps, blockSize ) end
	P.materials[signature] = { material = material }
	P.materialCount = P.materialCount + 1
	return material
end

function P.SourcesCurrent( bundle )
	for material, texture in pairs( bundle.sources ) do
		if not R.SameTexture( R.SourceTexture( material ), texture ) then return false end
	end
	return true
end

function P.RefreshLightmap()
	R.RefreshLightmap( P.shared )
end
