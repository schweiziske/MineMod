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
		message = "no contiguous quad range available within the shared 16 MiB corner atlas" }, 0 )
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
	requireValue( buffer.l2 and count > 0 and count == math.floor( count ) and count <= G.PART_QUADS
		and #buffer.pixels == count * 4, "render_l2_buffer", "world upload requires a bounded native L2 buffer" )
	requireValue( G.liveParts < G.MAX_PARTS, "render_pack_part_budget", "native L2 mesh-part budget exceeded" )
	R.Ensure( { build = "quad_corners_v1" }, P.shared )
	local first = allocate( count )
	local object
	local ok, err = pcall( function()
		local started = perf and SysTime()
		object = Mesh( declaration() )
		if perf then MC.RenderMesh.meshPerfAdd( perf, "meshNewMS", started ) end
		requireValue( object ~= nil, "render_pack_mesh_create", "could not create a native L2 mesh" )
		started = perf and SysTime()
		-- Materialize global addresses without mutating the local CPU/cache buffer.
		MC.RenderMesh.uploadMeshVertices( object, buffer.verts, nil, false, true, first )
		if perf then
			MC.RenderMesh.meshPerfAdd( perf, "buildTriMS", started )
			perf.buildTriangleUploads = ( perf.buildTriangleUploads or 0 ) + 1
		end
		R.UploadPart( { firstQuad = first, quadCount = count, pixels = buffer.pixels }, P.shared )
	end )
	if not ok then
		local destroyOK, destroyError = true, nil
		if object then destroyOK, destroyError = pcall( object.Destroy, object ) end
		freeRange( first, count )
		if not destroyOK then MC.Fault( "render_l2_failed_mesh_destroy", "%s", tostring( destroyError ) ) end
		error( err, 0 )
	end
	G.liveParts = G.liveParts + 1
	local data = { mesh = object, firstQuad = first, quadCount = count, references = 1 }
	if G.auditPixels then
		local pixels = {}
		for i = 1, #buffer.pixels do pixels[i] = buffer.pixels[i] end
		G.auditPixels[data] = pixels
	end
	return { l2 = true, resource = data, mesh = object, material = buffer.material,
		request = buffer.request, stage = buffer.stage, blockIds = buffer.blockIds }
end
