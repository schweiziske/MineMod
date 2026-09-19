-- Default-off, one-section L1/L2 comparison. Not a pack selector or scheduler.
MC = MC or {}
local D = MC.RenderL2Visual or { mode = "off", faults = {} }
MC.RenderL2Visual = D
local R, Q, RM = MC.RenderL2Resources, MC.RenderL2Quad, MC.RenderMesh
local requireValue = R.Require
local MAX_QUADS, MAX_RECORDS, SLICE_QUADS, PART_QUADS = 8192, 16, 64, 256

local function integer( value )
	return type( value ) == "number" and value == math.floor( value ) and math.abs( value ) < 2147483648
end

local function queueFault( code, message )
	if type( message ) == "table" and message.code then code, message = message.code, message.message end
	D.faults[#D.faults + 1] = { code = code, message = tostring( message ) }
end

function D.Off()
	local candidate = D.candidate
	D.candidate, D.mode = nil, "off"
	if not candidate then return end
	for i = 1, #candidate.parts do
		local meshObj = candidate.parts[i].mesh
		if meshObj then
			local ok, err = pcall( meshObj.Destroy, meshObj )
			if not ok then queueFault( "l2_visual_mesh_destroy", err ) end
		end
	end
end

-- Draw callers defer reporting until their model matrix and pass overrides are
-- restored. Other callers report immediately after their protected operation.
function D.Fail( code, message )
	queueFault( code, message )
	D.Off()
end

function D.ReportFaults()
	local pending, firstError = D.faults, nil
	D.faults = {}
	for i = 1, #pending do
		local fault = pending[i]
		local ok, err = pcall( MC.Fault, fault.code, "%s; L2 disabled, original L1 meshes retained", fault.message )
		if not ok and firstError == nil then firstError = err end
	end
	if firstError ~= nil then error( firstError, 0 ) end
end

local function dirty( key, index )
	local geometry, light = MC.MeshDirty[key], MC.MeshLightDirty[key]
	return geometry == true or light == true
		or ( type( geometry ) == "table" and geometry[index] ~= nil )
		or ( type( light ) == "table" and light[index] ~= nil )
end

local function nativeActive()
	local backend = MC.NativeChunkBackend
	return backend and backend.IsActive and backend.IsActive()
end

local function validate( c )
	requireValue( not nativeActive(), "l2_visual_native_active",
		"this diagnostic uses Lua geometry; set mc_native_mesh 0 and wait for Lua meshes before prepare" )
	requireValue( MC.World == c.world and MC.StateWorldGeneration == c.generation
		and MC.GetChunkByKey( c.key ) == c.chunk, "l2_visual_world_changed", "selected world/chunk changed" )
	requireValue( MC.RenderGeometryStore.GetSection( c.key, c.sectionIndex ) == c.section
		and ( c.section.lightingRevision or 0 ) == c.lightingRevision and not dirty( c.key, c.sectionIndex ),
		"l2_visual_section_changed", "selected section changed, was relit, or was evicted; prepare it again" )
	requireValue( MC.API.Coords.BlockSize() == c.blockSize and MC.CS == c.cs and MC.CH == c.ch,
		"l2_visual_coordinates_changed", "block size or chunk layout changed" )
	requireValue( MC.RenderPackRegistry.Revision( "pack", "mc:vanilla" ) == c.buildRevision and c.build.build == c.fingerprint,
		"l2_visual_manifest_changed", "candidate manifest changed; restart the client" )
	requireValue( MC.Meshes[c.key] == c.opaqueList and MC.MeshesTrans[c.key] == c.translucentList,
		"l2_visual_draw_list_changed", "selected chunk draw lists changed; prepare it again" )
	for i = 1, #c.sources do
		local source, record = c.sources[i], c.sources[i].record
		requireValue( record.mesh == source.mesh and record.material == source.material
			and record.verts == source.verts and record.light == source.light
			and record.vertexCount == source.quads * 6,
			"l2_visual_record_changed", "selected geometry record changed" )
		requireValue( R.SameTexture( R.SourceTexture( source.material ), source.texture ),
			"l2_visual_texture_changed", "selected material texture changed; prepare it again" )
	end
end

local function preflight()
	local runtime = MC.RenderPackRuntime
	requireValue( not runtime or ( not runtime.active and not runtime.pending ), "l2_visual_pack_active",
		"use mc_render_pack off before preparing the one-section diagnostic" )
	requireValue( MC.API and MC.API.Coords and MC.API.Coords.BlockSize and MC.API.Coords.EntityEyeCell
		and MC.API.Coords.CellToChunk and MC.GetChunkByKey and MC.ChunkKey and MC.RenderGeometryStore
		and MC.RenderGeometryStore.GetSection and MC.MeshDirty and MC.MeshLightDirty
		and MC.RenderVertexBuffer and MC.RenderLightBuffer and Mesh and MC.Blocks and MC.IsTranslucentBlock
		and RM.isLiquidBlock and RM.blockLightEmissionAt and RM.shadeRGBAByIndex
		and RM.withIsolatedRawLighting and RM.uploadMeshVertices,
		"l2_visual_dependencies", "Lua geometry, raw lighting, coordinate or mesh APIs are unavailable" )
	requireValue( not nativeActive(), "l2_visual_prepare_native",
		"set mc_native_mesh 0 and wait for Lua meshes before prepare; this command never switches backends" )
	local blockSize = MC.API.Coords.BlockSize()
	requireValue( type( blockSize ) == "number" and blockSize > 0 and blockSize < math.huge,
		"l2_visual_block_size", "invalid runtime block size" )
	return blockSize
end

local function findNearby()
	local bx, by, bz = MC.API.Coords.EntityEyeCell( LocalPlayer() )
	requireValue( integer( bx ) and integer( by ) and integer( bz ), "l2_visual_eye_cell", "player eye cell is unavailable" )
	local cx, cy, cz = MC.API.Coords.CellToChunk( bx, by, bz )
	requireValue( integer( cx ) and integer( cy ) and integer( cz ), "l2_visual_eye_chunk", "player chunk coordinates are unavailable" )
	local size = RM.RENDER_SECTION_SIZE
	local sectionCount = math.ceil( MC.CS / size ) ^ 2 * math.ceil( MC.CH / size )
	requireValue( integer( sectionCount ) and sectionCount > 0 and sectionCount <= 512,
		"l2_visual_section_layout", "unsupported render section layout" )
	local offsets = { 0, -1, 1 }
	for z = 1, 3 do
		for y = 1, 3 do
			for x = 1, 3 do
				local nx, ny, nz = cx + offsets[x], cy + offsets[y], cz + offsets[z]
				local key = MC.ChunkKey( nx, ny, nz )
				for index = 1, sectionCount do
					local section = MC.RenderGeometryStore.GetSection( key, index )
					if section and not dirty( key, index )
						and ( #( section.opaque or {} ) + #( section.translucent or {} ) ) > 0 then
						return nx, ny, nz, index
					end
				end
			end
		end
	end
	error( { code = "l2_visual_no_section", message = "no cached, settled Lua section in the nearby 3x3x3 chunks" }, 0 )
end

local function prepare( coords )
	local blockSize = preflight()
	local cx, cy, cz, index
	if coords then cx, cy, cz, index = coords[1], coords[2], coords[3], coords[4]
	else cx, cy, cz, index = findNearby() end
	local key = MC.ChunkKey( cx, cy, cz )
	local chunk = MC.GetChunkByKey( key )
	local section = MC.RenderGeometryStore.GetSection( key, index )
	requireValue( chunk and section, "l2_visual_selection", "selected chunk/section has no cached Lua geometry" )
	local c = {
		key = key, chunk = chunk, section = section, sectionIndex = index,
		cx = cx, cy = cy, cz = cz, cs = MC.CS, ch = MC.CH,
		world = MC.World, generation = MC.StateWorldGeneration, blockSize = blockSize,
		lightingRevision = section.lightingRevision or 0,
		opaqueList = MC.Meshes[key], translucentList = MC.MeshesTrans[key],
		sources = {}, parts = {}, replacements = {},
		phase = "resources", totalQuads = 0, converted = 0, uploaded = 0, sourceIndex = 1, sourceQuad = 0,
	}
	c.build, c.buildRevision = R.ValidateBuild()
	c.fingerprint = c.build.build
	for passIndex, pass in ipairs( { "opaque", "translucent" } ) do
		local records = section[pass]
		requireValue( type( records ) == "table" and #records <= MAX_RECORDS,
			"l2_visual_records", "section pass records are missing or exceed the diagnostic cap" )
		local list = passIndex == 1 and c.opaqueList or c.translucentList
		local drawn = {}
		if list then
			for i = 1, #list do
				local entry = list[i]
				drawn[type( entry ) == "table" and entry.mesh or entry] = true
			end
		end
		for i = 1, #records do
			local record = records[i]
			local quads = Q.RecordQuadCount( record, passIndex == 2 )
			requireValue( drawn[record.mesh] and c.replacements[record.mesh] == nil,
				"l2_visual_source_draw", "record mesh is missing from its draw list or appears in multiple records" )
			c.totalQuads = c.totalQuads + quads
			c.sources[#c.sources + 1] = {
				record = record, mesh = record.mesh, material = record.material, texture = R.SourceTexture( record.material ),
				verts = record.verts, light = record.light, quads = quads, translucent = passIndex == 2,
			}
			c.replacements[record.mesh] = {}
		end
	end
	requireValue( #c.sources > 0 and #c.sources <= MAX_RECORDS and c.totalQuads <= MAX_QUADS,
		"l2_visual_capacity", "select a smaller section (maximum 16 records / 8192 quads)" )
	validate( c )
	D.candidate, D.mode = c, "l1"
	print( string.format( "[MC L2 visual] preparing %s/%d: %d quads; L1 remains active", tostring( key ), index, c.totalQuads ) )
end

function D.Prepare( coords )
	D.Off()
	local ok, err = pcall( prepare, coords )
	if not ok then D.Fail( "l2_visual_prepare", err ) end
	D.ReportFaults()
	return ok
end

local function convertSlice( c, deadline, slice )
	local source = c.sources[c.sourceIndex]
	if not c.part then
		if not source.targetMaterial then
			source.targetMaterial = R.Material( c.sourceIndex, source.texture, source.translucent, c.blockSize, c.build )
		end
		c.part = Q.NewPart( c.sourceIndex, c.converted )
		c.part.material = source.targetMaterial
		c.parts[#c.parts + 1] = c.part
	end
	local count = 0
	while count < SLICE_QUADS and c.part.quadCount < PART_QUADS and c.sourceQuad < source.quads do
		if count > 0 and SysTime() >= deadline then break end
		Q.AppendQuad( c.part, source.record, c.sourceQuad, c.converted, slice )
		c.sourceQuad, c.converted, count = c.sourceQuad + 1, c.converted + 1, count + 1
	end
end

local function step( c )
	validate( c )
	if c.phase == "resources" then
		R.Ensure( c.build )
		R.RefreshLightmap()
		c.phase = "convert"
		return
	end
	R.RefreshLightmap()
	if c.phase == "ready" then return end
	local slice = Q.NewSlice( c.chunk, c.blockSize )
	RM.withIsolatedRawLighting( c.cx * c.cs, c.cy * c.cs, c.cz * c.ch, convertSlice, c, SysTime() + 0.002, slice )
	local part, source = c.part, c.sources[c.sourceIndex]
	if part.quadCount == PART_QUADS or c.sourceQuad == source.quads then
		part.mesh = Mesh( part.material )
		requireValue( part.mesh ~= nil, "l2_visual_mesh_create", "could not create candidate mesh" )
		RM.uploadMeshVertices( part.mesh, part.verts, nil, false, true )
		R.UploadPart( part )
		local replacements = c.replacements[source.mesh]
		replacements[#replacements + 1] = { mesh = part.mesh, material = part.material }
		c.uploaded = c.uploaded + part.quadCount
			part.verts, part.pixels, part.occlusion, part.scratch = nil, nil, nil, nil
			part.corners, part.lighting = nil, nil
		c.part = nil
		if c.sourceQuad == source.quads then c.sourceIndex, c.sourceQuad = c.sourceIndex + 1, 0 end
	end
	if c.uploaded == c.totalQuads then
		c.phase = "ready"
		print( "[MC L2 visual] ready; use mc_render_l2_visual l2 / l1 to compare this section" )
	end
end

function D.Step()
	local c = D.candidate
	if not c then return end
	local frame = FrameNumber()
	if D.lastFrame == frame then return end
	D.lastFrame = frame
	local ok, err = pcall( step, c )
	if not ok then D.Fail( "l2_visual_prepare_slice", err ) end
	D.ReportFaults()
end

function D.IsDrawing()
	return D.mode == "l2" and D.candidate ~= nil and D.candidate.phase == "ready"
end

function D.GetReplacements( key )
	if not D.IsDrawing() or key ~= D.candidate.key then return nil end
	local c = D.candidate
	local ok, err = pcall( validate, c )
	if not ok then D.Fail( "l2_visual_draw_validate", err ) return nil end
	return c.replacements
end

function D.SetMode( mode )
	if mode == "off" then D.Off() D.ReportFaults() return true end
	if mode == "l2" and ( not D.candidate or D.candidate.phase ~= "ready" ) then
		return MC.Fault( "l2_visual_not_ready", "prepare a candidate and wait for ready before switching to L2" )
	end
	if mode == "l2" and MC.RenderPackRuntime
		and ( MC.RenderPackRuntime.active or MC.RenderPackRuntime.pending ) then
		return MC.Fault( "l2_visual_pack_conflict", "use mc_render_pack off before enabling the one-section diagnostic" )
	end
	D.mode = mode
	return true
end

function D.Status()
	local c = D.candidate
	print( string.format( "[MC L2 visual] mode=%s phase=%s section=%s quads=%d/%d parts=%d lightmapRevision=%s build=%s GPU=unverified",
		D.mode, c and c.phase or "idle", c and ( tostring( c.key ) .. "/" .. c.sectionIndex ) or "-",
		c and c.uploaded or 0, c and c.totalQuads or 0, c and #c.parts or 0,
		tostring( R.lightmapRevision or 0 ), c and c.fingerprint or "-" ) )
end

concommand.Add( "mc_render_l2_visual", function( _, _, args )
	local action = args[1] or "status"
	if action == "prepare" then
		local coords
		if #args ~= 1 then
			coords = { tonumber( args[2] ), tonumber( args[3] ), tonumber( args[4] ), tonumber( args[5] ) }
			if #args ~= 5 or not integer( coords[1] ) or not integer( coords[2] )
				or not integer( coords[3] ) or not integer( coords[4] ) or coords[4] < 1 then
				print( "mc_render_l2_visual prepare [cx cy cz sectionIndex]" )
				return
			end
		end
		D.Prepare( coords )
	elseif action == "l1" or action == "l2" or action == "off" then
		D.SetMode( action )
		D.Status()
	elseif action == "status" then D.Status()
	else print( "mc_render_l2_visual prepare [cx cy cz sectionIndex] | l1 | l2 | off | status" ) end
end )
hook.Add( "PreRender", "mc_render_l2_visual", D.Step )
hook.Add( "ShutDown", "mc_render_l2_visual", function() D.Off() D.ReportFaults() end )
if D.candidate then D.Fail( "l2_visual_reload", "diagnostic Lua reloaded; prepare the candidate again" ) D.ReportFaults() end
