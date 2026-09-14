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
	local result = { plan = plan, nodes = {}, requests = {}, sources = {}, files = {}, textures = {} }
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
		requireValue( def.abi == 1 and def.layout == "mc:quad_corners_v1" and def.adapter == "mc:vanilla_quad_draft",
			"render_pack_adapter", ownerKey .. ": runtime currently supports only quad-corners-v1 / vanilla-quad-draft" )
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
		for name, pass in pairs( def.passes ) do
			requireValue( pass.stage == "world_opaque" or pass.stage == "world_cutout" or pass.stage == "world_translucent",
				"render_pack_stage", ownerKey .. "/" .. name .. ": unsupported processing stage " .. pass.stage )
			for semantic in pairs( pass.inputs ) do
				requireValue( semantic == "albedo", "render_pack_input",
					ownerKey .. "/" .. name .. ": unsupported quad-v1 input " .. semantic )
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
		local byStage = {}
		for _, stage in ipairs( STAGES ) do byStage[stage] = {} end
		result.requests[key] = byStage
		for _, name in ipairs( request.passes ) do
			local pass, nodeKey = def.passes[name], request.owner .. "/" .. name
			local node = nodes[nodeKey]
			if not node then
				node = { key = nodeKey, stage = pass.stage, program = def.programs[pass.program] }
				if pass.inputs.albedo then
					node.albedo = result.textures[request.owner .. "/" .. pass.inputs.albedo]
				end
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
		files = bundle.files, textures = bundle.textures, sources = {}, newBuilds = {}, bytesRead = 0 }
end

function P.Ensure( bundle )
	R.Ensure( { build = "quad_corners_v1" }, P.shared )
	for _, key in ipairs( bundle.newBuilds ) do
		if not P.builds[key] then
			P.builds[key], P.buildCount = true, P.buildCount + 1
		end
	end
end

local function textureFor( resource )
	local key = resource.path .. "/" .. resource.sha256
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
		material = Material( path )
	end
	local texture = R.SourceTexture( material )
	requireValue( texture:Width() > 0 and texture:Width() <= 4096 and texture:Height() > 0 and texture:Height() <= 4096,
		"render_pack_texture_size", resource.path .. ": dimensions exceed the 4096-square limit" )
	P.textures[key], P.textureCount = texture, P.textureCount + 1
	return texture
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
	local colorSpace = "linear"
	if node.albedo then source, colorSpace = textureFor( node.albedo ), node.albedo.colorSpace end
	local signature = Schema.Canonical( { vertex = node.program.vertex, pixel = node.program.pixel,
		stage = node.stage, source = source:GetName(), colorSpace = colorSpace, blockSize = blockSize } )
	local cached = P.materials[signature]
	if cached then
		requireValue( R.SameTexture( cached.source, source ), "render_pack_texture_identity",
			"cached texture name or dimensions changed: " .. source:GetName() )
		return cached.material
	end
	requireValue( P.materialCount < 2048, "render_pack_material_budget", "2048 immutable runtime materials reached" )
	local slot = tostring( P.materialCount + 1 )
	local material = R.BoundMaterial( P.shared, slot, source, node.stage, blockSize, node.program, colorSpace )
	P.materials[signature] = { material = material, source = source }
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
