-- Section-owned native L2 meshes and copy-on-write corner-atlas allocations.
MC = MC or {}
local G = MC.RenderPackGeometry or { free = { { first = 0, count = 1048576 } }, liveQuads = 0 }
MC.RenderPackGeometry = G
local R, P = MC.RenderL2Resources, MC.RenderPackResources
local requireValue = R.Require
G.PART_QUADS = math.floor( MC.RenderMeshConstants.VERT_LIMIT / 6 )
G.MAX_PARTS, G.liveParts = 16384, G.liveParts or 0

local function allocate( count )
	for i, range in ipairs( G.free ) do
		if range.count >= count then
			local first = range.first
			range.first, range.count = range.first + count, range.count - count
			if range.count == 0 then table.remove( G.free, i ) end
			G.liveQuads = G.liveQuads + count
			return first
		end
	end
	error( { code = "render_pack_atlas_budget",
		message = "no contiguous quad range available within the shared 20 MiB corner/AO atlas" }, 0 )
end

local function freeRange( first, count )
	if count == 0 then return end
	G.free[#G.free + 1] = { first = first, count = count }
	table.sort( G.free, function( a, b ) return a.first < b.first end )
	local i = 1
	while i < #G.free do
		local left, right = G.free[i], G.free[i + 1]
		if left.first + left.count == right.first then
			left.count = left.count + right.count
			table.remove( G.free, i + 1 )
		else i = i + 1 end
	end
	G.liveQuads = G.liveQuads - count
end

function G.Retain( data )
	requireValue( data.references > 0, "render_pack_geometry_refs", "retaining released geometry" )
	data.references = data.references + 1
	return data
end

function G.Release( data, report )
	requireValue( data.references > 0, "render_pack_geometry_refs", "releasing unowned geometry" )
	data.references = data.references - 1
	if data.references ~= 0 then return end
	local ok, err = pcall( data.mesh.Destroy, data.mesh )
	freeRange( data.firstQuad, data.quadCount )
	G.liveParts = G.liveParts - 1
	data.mesh = nil
	if not ok then
		local reportFault = report or MC.Fault
		reportFault( "render_pack_mesh_destroy", tostring( err ) )
	end
end

local function declaration()
	if not G.declaration then
		G.declaration = CreateMaterial( "mc_l2_world_declaration_v1", "screenspace_general_8tex", {
			["$basetexture"] = "vgui/white", ["$x360appchooser"] = 1, ["$vertexcolor"] = 1,
		} )
	end
	requireValue( G.declaration and not G.declaration:IsError(),
		"render_l2_declaration", "native L2 vertex declaration material is unavailable" )
	return G.declaration
end

function G.Upload( buffer, perf )
	local count = buffer.nv / 6
	requireValue( buffer.l2 and count > 0 and count == math.floor( count ) and count <= G.PART_QUADS,
		"render_l2_buffer", "world upload requires a bounded native L2 buffer with independent AO" )
	if buffer.nativeL2 then
		requireValue( #buffer.nativeCommands == count * MC.NativeL2.COMMAND_STRIDE,
			"render_l2_buffer", "Native L2 command count does not match its quads" )
	else
		requireValue( #buffer.pixels == count * 4 and buffer.occlusion and #buffer.occlusion == count,
			"render_l2_buffer", "Lua L2 corner/AO count does not match its quads" )
	end
	requireValue( G.liveParts < G.MAX_PARTS, "render_pack_part_budget", "native L2 mesh-part budget exceeded" )
	local bounds
	if not buffer.nativeL2 then bounds = MC.RenderSectionCull.VertexBounds( buffer.verts ) end
	R.Ensure( { build = "quad_corners_v1" }, P.shared )
	local first = allocate( count )
	local object, uploadedVertices
	local ok, err = pcall( function()
		if buffer.nativeL2 then
			local result = MC.NativeL2.Upload( buffer, first, declaration() )
			object, uploadedVertices = result.mesh, result.vertices
			buffer.pixels, buffer.occlusion = result.pixels, result.occlusion
			local b = result.bounds
			bounds = MC.RenderSectionCull.Bounds( b[1], b[2], b[3], b[4], b[5], b[6] )
		else
			local started = perf and SysTime()
			object = Mesh( declaration() )
			if perf then MC.RenderMesh.meshPerfAdd( perf, "meshNewMS", started ) end
			requireValue( object ~= nil, "render_pack_mesh_create", "could not create a native L2 mesh" )
			-- Stream global addresses without materializing or mutating the CPU buffer.
			MC.RenderMesh.uploadMeshVertices( object, buffer.verts, perf, false, false, first )
		end
		R.UploadPart( { firstQuad = first, quadCount = count, pixels = buffer.pixels, occlusion = buffer.occlusion }, P.shared )
	end )
	if not ok then
		local destroyOK, destroyError = true, nil
		if object then destroyOK, destroyError = pcall( object.Destroy, object ) end
		freeRange( first, count )
		if buffer.nativeL2 then MC.NativeL2.DisableAfterFailure( type( err ) == "table" and err.message or err ) end
		if not destroyOK then MC.Fault( "render_l2_failed_mesh_destroy", "%s", tostring( destroyError ) ) end
		error( err, 0 )
	end
	G.liveParts = G.liveParts + 1
	local data = { mesh = object, firstQuad = first, quadCount = count, references = 1 }
	if G.auditPixels then
		local pixels, occlusion = {}, {}
		for i = 1, #buffer.pixels do pixels[i] = buffer.pixels[i] end
		for i = 1, #buffer.occlusion do occlusion[i] = buffer.occlusion[i] end
		pixels.occlusion = occlusion
		G.auditPixels[data] = pixels
	end
	return { l2 = true, resource = data, mesh = object, material = buffer.material,
		nativeL2 = buffer.nativeL2, uploadedVertices = uploadedVertices,
		request = buffer.request, stage = buffer.stage, blockIds = buffer.blockIds,
		bounds = bounds, direction = buffer.direction }
end
