-- Section-owned native L2 meshes and copy-on-write corner-atlas allocations.
MC = MC or {}
local G = MC.RenderPackGeometry or { free = { { first = 0, count = 1048576 } }, liveQuads = 0 }
MC.RenderPackGeometry = G
local R, P = MC.RenderL2Resources, MC.RenderPackResources
local requireValue = R.Require
G.PART_QUADS = math.floor( MC.RenderMeshConstants.VERT_LIMIT / 6 )
G.MAX_PARTS, G.liveParts = 16384, G.liveParts or 0
G.retired, G.retiredHead = G.retired or {}, G.retiredHead or 1

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

local function destroy( data, report )
	local ok, err = pcall( data.mesh.Destroy, data.mesh )
	freeRange( data.firstQuad, data.quadCount )
	G.liveParts = G.liveParts - 1
	data.mesh = nil
	if not ok then
		local reportFault = report or MC.Fault
		reportFault( "render_pack_mesh_destroy", tostring( err ) )
	end
end

function G.Release( data, report )
	requireValue( data.references > 0, "render_pack_geometry_refs", "releasing unowned geometry" )
	data.deferRetirement = data.deferRetirement or G.deferRetirement
	data.references = data.references - 1
	if data.references ~= 0 then return end
	if data.deferRetirement then G.retired[#G.retired + 1] = data
	else destroy( data, report ) end
end

function G.PumpRetired( budget )
	local faults = {}
	local function report( code, message ) faults[#faults + 1] = { code, message } end
	while G.retiredHead <= #G.retired do
		if budget.attempts > 0 and budget.deadline and SysTime() >= budget.deadline then break end
		local data = G.retired[G.retiredHead]
		G.retired[G.retiredHead], G.retiredHead = false, G.retiredHead + 1
		budget.attempts = budget.attempts + 1
		destroy( data, report )
	end
	if G.retiredHead > #G.retired then G.retired, G.retiredHead = {}, 1 end
	for _, fault in ipairs( faults ) do MC.Fault( fault[1], "%s", fault[2] ) end
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
		if buffer.nativeVoxelPart then
			requireValue( buffer.nativeJob ~= nil and buffer.nativePart ~= nil and buffer.quadCount == count,
				"render_l2_buffer", "Native L2 worker part is missing its validated layout" )
		else
			requireValue( #buffer.nativeCommands == count * MC.NativeL2.COMMAND_STRIDE,
				"render_l2_buffer", "Native L2 command count does not match its quads" )
		end
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
			buffer.nativeRelight = result.relight == true
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
		local cornerStarted = perf and SysTime()
		R.UploadPart( { firstQuad = first, quadCount = count, pixels = buffer.pixels, occlusion = buffer.occlusion }, P.shared )
		if perf then MC.RenderMesh.meshPerfAdd( perf, "cornerUploadMS", cornerStarted ) end
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
	if buffer.nativeRelight then data.pixels, data.occlusion = buffer.pixels, buffer.occlusion end
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
		bounds = bounds, direction = buffer.direction, castsShadow = buffer.castsShadow, water = buffer.water }
end

-- Results are staged first. A live section is updated in one render-thread
-- transaction, restoring even the partially written part if an upload fails.
function G.ApplyLighting( updates )
	for _, update in ipairs( updates ) do
		local data = update.data
		requireValue( data.references > 0 and data.pixels and #update.pixels == data.quadCount * 4
			and #update.occlusion == data.quadCount, "native_relight_layout", "invalid retained lighting output" )
		update.firstQuad, update.quadCount = data.firstQuad, data.quadCount
	end
	local attempted = 0
	local ok, err = pcall( function()
		for i, update in ipairs( updates ) do
			attempted = i
			R.UploadPart( update, P.shared )
		end
	end )
	if not ok then
		local restoreError
		for i = 1, attempted do
			local restored, reason = pcall( R.UploadPart, updates[i].data, P.shared )
			if not restored then restoreError = reason end
		end
		requireValue( not restoreError, "native_relight_restore",
			"atlas rollback failed; rebuild required: " .. tostring( restoreError ) )
		error( err, 0 )
	end
	for _, update in ipairs( updates ) do
		local data = update.data
		data.pixels, data.occlusion = update.pixels, update.occlusion
		if data.lightRecord then
			data.lightRecord.pixels, data.lightRecord.occlusion = update.pixels, update.occlusion
		end
		if G.auditPixels then
			update.pixels.occlusion = update.occlusion
			G.auditPixels[data] = update.pixels
		end
	end
end
