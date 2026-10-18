-- Read-only overlay paired with the existing visual catalog. Decode on demand;
-- neither canonical corner permutations nor exact float positions modify L1.
MC = MC or {}
local M = {}
MC.RenderL2Models = M
local data, catalog = MC.GeneratedModelLighting, MC.StateVisualCatalog
local RM, FACES = MC.RenderMesh, MC.RenderMeshConstants.FACES
local byte, floor = string.byte, math.floor
local band, rshift = bit.band, bit.rshift
local profiles, positions = {}, {}
local projectSelections = {}
local projectMatches = {}
local initialized = false

local function u16( bytes, at )
	local a, b = byte( bytes, at, at + 1 )
	return a + b * 256
end

local function u32( bytes, at )
	local a, b, c, d = byte( bytes, at, at + 3 )
	return a + b * 256 + c * 65536 + d * 16777216
end

local function initialize()
	if initialized then return M.ready end
	initialized = true
	if not MC.Check( type( data ) == "table" and type( catalog ) == "table"
		and data.formatVersion == 3 and data.minecraftId == catalog.minecraftId
		and data.visualPlanSha256 == catalog.visualPlanSha256 and data.modelCount == catalog.modelInstanceCount
		and type( data.profileCount ) == "number" and data.profileCount > 0 and data.profileCount <= 65535
		and data.profileCount == floor( data.profileCount )
		and type( data.positionCount ) == "number" and data.positionCount >= 0 and data.positionCount <= 65535
		and data.positionCount == floor( data.positionCount )
		and type( data.modelMap ) == "string" and #data.modelMap == data.modelCount * 2
		and type( data.profileIndex ) == "string" and #data.profileIndex == data.profileCount * 4
		and type( data.profileData ) == "string"
		and type( data.positionData ) == "string" and #data.positionData == data.positionCount * 48
		and #data.modelMap + #data.profileIndex + #data.profileData + #data.positionData == data.binaryBytes,
		"l2_model_catalog", "quad metadata differs from the loaded visual catalog" ) then return false end
	local hash = MC.Need( util and util.SHA256, "l2_model_hash_api", "util.SHA256 is required to pair geometry and metadata" )
	if not hash then return false end
	if not MC.Check( hash( catalog.geometryIndex .. catalog.geometryData .. catalog.modelMap .. catalog.surfaceIndex .. catalog.surfaceData ) == data.geometrySha256
		and hash( data.modelMap .. data.profileIndex .. data.profileData .. data.positionData ) == data.metadataSha256,
		"l2_model_hash", "stale or corrupted model geometry/lighting overlay" ) then return false end
	local nextOffset = 0
	for i = 1, data.profileCount do
		local offset = u32( data.profileIndex, ( i - 1 ) * 4 + 1 )
		if not MC.Check( offset == nextOffset and offset + 7 <= #data.profileData,
			"l2_model_profile_index", "invalid profile offset %s", i ) then return false end
		local geometry, ao = u16( data.profileData, offset + 1 ), byte( data.profileData, offset + 3 )
		local sourceCount, count = u16( data.profileData, offset + 4 ), u16( data.profileData, offset + 6 )
		if not MC.Check( geometry > 0 and geometry <= catalog.geometryTemplateCount and ao <= 1 and count > 0 and count <= sourceCount
			and sourceCount == u16( catalog.geometryIndex, ( geometry - 1 ) * 6 + 5 ),
			"l2_model_profile", "invalid geometry/AO/count in profile %s", i ) then return false end
		nextOffset = offset + 7 + count * 8
	end
	if not MC.Check( nextOffset == #data.profileData, "l2_model_profile_size", "truncated or trailing quad metadata" ) then return false end
	for i = 1, data.modelCount do
		local profile = u16( data.modelMap, ( i - 1 ) * 2 + 1 )
		if not MC.Check( profile <= data.profileCount, "l2_model_map", "invalid profile for model %s", i ) then return false end
		if profile > 0 then
			local offset = u32( data.profileIndex, ( profile - 1 ) * 4 + 1 )
			if not MC.Check( u16( data.profileData, offset + 1 ) == u16( catalog.modelMap, ( i - 1 ) * 4 + 1 ),
				"l2_model_geometry_id", "model %s changed geometry identity", i ) then return false end
		end
	end
	M.ready, M.signature = true, data.metadataSha256
	return true
end

local modelFields = { compact = true, generatedStateVisual = true, geometryId = true,
	surfaceId = true, modelQuads = true, modelSurfaces = true }
local quadFields = { face = true, tintIndex = true, surface = true, rot = true, uv = true, verts = true }

local function hasOnlyFields( value, fields )
	for key in pairs( value ) do if not fields[key] then return false end end
	return true
end

local function compatibleTransform( modelId )
	local model = MC.StateVisualModelData( modelId )
	local mapAt = ( modelId - 1 ) * 4 + 1
	local geometryId, surfaceId = u16( catalog.modelMap, mapAt ), u16( catalog.modelMap, mapAt + 2 )
	if type( model ) ~= "table" or model.compact ~= true or model.generatedStateVisual ~= true
		or model.geometryId ~= geometryId or model.surfaceId ~= surfaceId
		or not hasOnlyFields( model, modelFields ) then return false, "transform changed model identity or fields" end

	-- Compare with the hash-paired bytes, not decoded tables that a transform
	-- can mutate in place. UV-only corrections do not change lighting metadata.
	local surfaceAt = ( surfaceId - 1 ) * 6 + 1
	local surfaceOffset, surfaceCount = u32( catalog.surfaceIndex, surfaceAt ), u16( catalog.surfaceIndex, surfaceAt + 4 )
	local surfaces = model.modelSurfaces
	if type( surfaces ) ~= "table" or #surfaces ~= surfaceCount then return false, "transform changed surface count" end
	for i = 1, surfaceCount do
		if surfaces[i] ~= u16( catalog.surfaceData, ( surfaceOffset + i - 1 ) * 2 + 1 ) then
			return false, "transform changed surface material or emission"
		end
	end

	local geometryAt = ( geometryId - 1 ) * 6 + 1
	local geometryOffset, quadCount = u32( catalog.geometryIndex, geometryAt ), u16( catalog.geometryIndex, geometryAt + 4 )
	local quads = model.modelQuads
	if type( quads ) ~= "table" or #quads ~= quadCount then return false, "transform changed quad count" end
	for i = 1, quadCount do
		local quad = quads[i]
		local at = geometryOffset + ( i - 1 ) * catalog.packedQuadBytes + 1
		local packedFace = byte( catalog.geometryData, at )
		if type( quad ) ~= "table" or not hasOnlyFields( quad, quadFields )
			or quad.face ~= band( packedFace, 7 ) or quad.tintIndex ~= rshift( packedFace, 3 ) - 1
			or quad.surface ~= byte( catalog.geometryData, at + 1 ) then
			return false, "transform changed quad face, tint, surface or fields"
		end
		local verts = quad.verts
		if type( verts ) ~= "table" or #verts ~= 20 then return false, "transform changed vertex layout" end
		for vertex = 0, 3 do
			for axis = 1, 3 do
				local coordinate = u16( catalog.geometryData, at + 8 + vertex * 6 + ( axis - 1 ) * 2 )
				if coordinate >= 32768 then coordinate = coordinate - 65536 end
				if verts[vertex * 5 + axis] ~= coordinate / catalog.coordinateScale then
					return false, "transform changed ordered vertex positions"
				end
			end
		end
	end
	return true
end

function M.Has( modelId )
	if not initialize() then return false, "catalog verification failed" end
	if type( modelId ) ~= "number" or modelId < 1 or modelId > data.modelCount
		or modelId ~= floor( modelId ) then return false, "model id is outside the paired catalog" end
	if u16( data.modelMap, ( modelId - 1 ) * 2 + 1 ) == 0 then return false, "no lighting profile" end
	if MC.StateVisualModelHasTransform( modelId ) then return compatibleTransform( modelId ) end
	return true
end

local function decodePositions( id )
	if positions[id] then return positions[id] end
	local result = {}
	for i = 1, 12 do
		local bits = u32( data.positionData, ( id - 1 ) * 48 + ( i - 1 ) * 4 + 1 )
		local exponent, fraction = floor( bits / 8388608 ) % 256, bits % 8388608
		if not MC.Check( exponent < 255, "l2_model_position_finite", "nonfinite position set %s", id ) then return nil end
		local value
		if exponent == 0 then value = math.ldexp( fraction, -149 )
		else value = math.ldexp( fraction + 8388608, exponent - 150 ) end
		if bits >= 2147483648 then value = -value end
		if not MC.Check( math.abs( value ) < 32768, "l2_model_position_bounds", "invalid coordinate in set %s", id ) then return nil end
		result[i] = value
	end
	positions[id] = result
	return result
end

function M.Profile( modelId )
	local verified, reason = M.Has( modelId )
	if not MC.Check( verified, "l2_model_unverified", "model %s has no compatible verified metadata: %s",
		tostring( modelId ), reason ) then return nil end
	local id = u16( data.modelMap, ( modelId - 1 ) * 2 + 1 )
	if profiles[id] then return profiles[id] end
	local offset = u32( data.profileIndex, ( id - 1 ) * 4 + 1 )
	local result = { geometryId = u16( data.profileData, offset + 1 ), modelAO = byte( data.profileData, offset + 3 ) == 1,
		sourceCount = u16( data.profileData, offset + 4 ), quads = {} }
	local count, lastSource = u16( data.profileData, offset + 6 ), 0
	for i = 1, count do
		local at = offset + 7 + ( i - 1 ) * 8 + 1
		local source = u16( data.profileData, at )
		local face, cull, flags, packedOrder = byte( data.profileData, at + 2, at + 5 )
		local positionId = u16( data.profileData, at + 6 )
		if not MC.Check( source > lastSource and source <= result.sourceCount and face >= 1 and face <= 6
			and cull <= 6 and flags <= 31 and positionId <= data.positionCount,
			"l2_model_quad", "invalid quad %s in profile %s", i, id ) then return nil end
		lastSource = source
		local exact
		if positionId > 0 then
			exact = decodePositions( positionId )
			if not exact then return nil end
		end
		local order, inverse, mask = {}, {}, 0
		for ci = 1, 4 do
			local vertex = band( rshift( packedOrder, ( ci - 1 ) * 2 ), 3 ) + 1
			if not MC.Check( band( mask, 2 ^ vertex ) == 0, "l2_model_order", "invalid permutation in profile %s quad %s", id, i ) then return nil end
			mask, order[ci], inverse[vertex] = mask + 2 ^ vertex, vertex, ci
		end
		result.quads[source] = { face = face, vertexOrder = order, cornerOrder = inverse, positions = exact,
			shade = band( flags, 1 ) ~= 0, quadEmission = rshift( flags, 1 ), cullFace = cull ~= 0 and cull or nil }
	end
	profiles[id] = result
	return result
end

function M.Selection( stateId, bx, by, bz, singleSelections )
	local project = projectSelections[stateId]
	if project then return project end
	local schema = MC.BlockStateSchemaForState( stateId )
	if schema and schema.project then
		local block = MC.Blocks[schema.blockId]
		if not MC.Check( block and block.shape == "model" and block.modelQuads and #block.modelQuads > 0,
			"l2_project_model", "project state %s has no authored model", stateId ) then return nil end
		-- Project models have no Mojang lighting overlay. Their authored vertices
		-- are the geometry contract; flat face lighting also supports triangular
		-- wedge sides without inventing a four-corner vanilla AO permutation.
		project = { n = 0, modelAO = false, l2Key = "project:" .. stateId }
		projectSelections[stateId] = project
		return project
	end
	if not MC.Check( initialize() and type( stateId ) == "number" and stateId >= 0 and stateId < catalog.stateCount
		and stateId == floor( stateId ), "l2_model_state", "state %s is outside the paired catalog", tostring( stateId ) ) then return nil end
	-- A synchronous slice can borrow one immutable selection per single model.
	-- Resolve the positional choice first: two placements of the same state can
	-- choose different weighted alternatives. Multipart order retains its path.
	if singleSelections then
		local planId, groupOffset, groupCount = MC.StateVisualPlanRangeFast( stateId )
		if groupCount == 1 then
			local modelId = MC.StateVisualPlanModelAtFast( planId, groupOffset, 0, bx, by, bz )
			if not MC.Check( modelId ~= nil, "l2_model_plan", "state %s has no static model plan", stateId ) then return nil end
			local selected = singleSelections[modelId]
			if selected then return selected end
			local profile = M.Profile( modelId )
			if not profile then return nil end
			selected = { modelId, n = 1, modelAO = profile.modelAO }
			singleSelections[modelId] = selected
			return selected
		end
	end
	local selected = MC.CollectStateVisualModels( stateId, bx, by, bz )
	if not MC.Check( selected and selected.n > 0, "l2_model_plan", "state %s has no static model plan", stateId ) then return nil end
	local profile = M.Profile( selected[1] )
	if not profile then return nil end
	-- The first part controls AO for all parts of this exact selected plan.
	selected.modelAO = profile.modelAO
	return selected
end

function M.Geometry( modelId )
	local profile = M.Profile( modelId )
	if not profile then return nil end
	local model = MC.StateVisualModelData( modelId )
	if not MC.Check( model and model.generatedStateVisual == true and model.geometryId == profile.geometryId
		and type( model.modelQuads ) == "table" and #model.modelQuads == profile.sourceCount,
		"l2_model_runtime_geometry", "model %s no longer has the paired geometry", modelId ) then return nil end
	return model, profile
end

function M.Corners( model, source, metadata, mapping )
	local corners, order = {}, {}
	for i = 1, 4 do
		local vertex = mapping and mapping[i] or i
		local canonical = metadata.cornerOrder[vertex]
		local x, y, z = MC.ModelQuadVertex( model.modelQuads[source], vertex )
		if metadata.positions then
			local at = ( canonical - 1 ) * 3
			x, y, z = metadata.positions[at + 1], metadata.positions[at + 2], metadata.positions[at + 3]
		end
		corners[i], order[i] = { x, y, z }, canonical
	end
	return corners, order
end

local function vertices( quad, xSteps, zSteps )
	local out = {}
	for i = 1, 4 do
		local x, y, z = MC.ModelQuadVertex( quad, i )
		if xSteps then x, y, z = RM.rotateModelPoint( x, y, z, xSteps, zSteps ) end
		out[i] = { x, y, z }
	end
	return out
end

local function matchVertices( legacy, candidate, degenerate )
	local mapping, used = {}, {}
	local scale = catalog.coordinateScale
	for i = 1, 4 do
		local match
		for j = 1, 4 do
			local a, b, same = legacy[i], candidate[j], not used[j]
			for axis = 1, 3 do
				-- Legacy ratios already use the six-decimal import codec.
				-- Apply the catalog's fixed-point codec, not a nearest corner.
				same = same and floor( a[axis] * scale + 0.5 ) == b[axis] * scale
			end
			if same then
				if match and not degenerate then return nil end
				match = j
			end
		end
		if not match then return nil end
		mapping[i], used[match] = match, true
	end
	return mapping
end

local function sameLighting( a, b )
	if a.degenerate ~= b.degenerate or a.modelAO ~= b.modelAO then return false end
	if a.degenerate then return true end
	for _, key in ipairs( { "face", "shade", "quadEmission", "cullFace" } ) do
		if a.metadata[key] ~= b.metadata[key] then return false end
	end
	for i = 1, 4 do
		if a.order[i] ~= b.order[i] then return false end
		for axis = 1, 3 do if a.corners[i][axis] ~= b.corners[i][axis] then return false end end
	end
	return true
end

local function rotateMatch( match, xSteps, zSteps )
	if match.degenerate or ( xSteps == 0 and zSteps == 0 ) then return match end
	local metadata = match.metadata
	local face = RM.rotateModelFace( metadata.face, xSteps, zSteps )
	local remap = {}
	-- Quarter turns permute the unit face exactly, including its canonical
	-- lighting corners. Do not infer this permutation from a slanted quad.
	for i = 1, 4 do
		local c = FACES[metadata.face].c[i]
		local x, y, z = RM.rotateModelPoint( c[1], c[2], c[3], xSteps, zSteps )
		for j = 1, 4 do
			local target = FACES[face].c[j]
			if x == target[1] and y == target[2] and z == target[3] then remap[i] = j break end
		end
		if not MC.Check( remap[i] ~= nil, "l2_model_legacy_rotation",
			"face %s corner %s has no canonical quarter-turn mapping", metadata.face, i ) then return nil end
	end
	for i = 1, 4 do
		local c = match.corners[i]
		c[1], c[2], c[3] = RM.rotateModelPoint( c[1], c[2], c[3], xSteps, zSteps )
		match.order[i] = remap[match.order[i]]
	end
	local cullFace
	if metadata.cullFace then cullFace = RM.rotateModelFace( metadata.cullFace, xSteps, zSteps ) end
	match.metadata = { face = face, shade = metadata.shade, quadEmission = metadata.quadEmission, cullFace = cullFace }
	return match
end

local function legacySelection( visual, selected )
	local name, property, value = visual.schema.name
	local xSteps, zSteps = 0, 0
	-- _build/build_atlas.ps1 Choose-Variant selected the first north-facing
	-- dripleaf (full tilt) and the first portal variant (axis=x). L1 still uses
	-- those templates. Pair their actual sources without changing L1's shapes.
	if name == "minecraft:big_dripleaf" then
		property, value = "tilt", "full"
	elseif name == "minecraft:nether_portal" then
		property, value = "axis", "x"
		xSteps, zSteps = RM.modelOrientSteps( visual.block, visual.renderOrient )
	else
		return selected, xSteps, zSteps
	end
	local stateId, err = MC.StateWith( visual.stateId, property, value )
	if not MC.Check( stateId ~= nil, "l2_model_legacy_plan", "%s source state is unavailable: %s", name, tostring( err ) ) then return nil end
	local source = M.Selection( stateId, 0, 0, 0 )
	if not source then return nil end
	if not MC.Check( source.n == 1 and not MC.StateVisualPlanHasRandomChoice( MC.StateVisualPlanIdFast( stateId ) ),
		"l2_model_legacy_source_plan", "%s import contract requires one deterministic source model", name ) then return nil end
	return source, xSteps, zSteps
end

-- Bell-Elements in the legacy importer appends these three cuboids to the
-- 16-quad floor frame. Bounds use Minecraft model units, not Source units.
local BELL_BOXES = {
	{ 4, 0, 4, 12, 4, 12 }, { 5, 4, 5, 11, 10, 11 }, { 6, 10, 6, 10, 12, 10 },
}
local IMPORT_FACE_ORDER = { 2, 1, 6, 5, 4, 3 }

local function bellBody( visual, sourceQuad, legacyQuads, source, emission )
	if visual.schema.name ~= "minecraft:bell" or #legacyQuads ~= 34 or sourceQuad < 17 or sourceQuad > 34
		or MC.GetStateProperty( visual.stateId, "attachment" ) ~= "floor" then return nil end
	local legacy = legacyQuads[sourceQuad]
	if emission ~= 0 or ( legacy.tintIndex or -1 ) ~= -1 then return nil end
	local box = BELL_BOXES[floor( ( sourceQuad - 17 ) / 6 ) + 1]
	local face = IMPORT_FACE_ORDER[( sourceQuad - 17 ) % 6 + 1]
	local xSteps, zSteps = RM.modelOrientSteps( visual.block, visual.renderOrient )
	if legacy.face ~= RM.rotateModelFace( face, xSteps, zSteps ) then return nil end
	local bounds = { box[1] / 16, 1 - box[6] / 16, box[2] / 16, box[4] / 16, 1 - box[3] / 16, box[5] / 16 }
	local canonical, rotated = {}, {}
	for i = 1, 4 do
		local c, v = FACES[face].c[i], {}
		for axis = 1, 3 do v[axis] = bounds[axis + c[axis] * 3] end
		canonical[i] = v
		rotated[i] = { RM.rotateModelPoint( v[1], v[2], v[3], xSteps, zSteps ) }
	end
	local mapping = matchVertices( source, rotated, false )
	if not mapping then return nil end
	local match = { source = source, corners = {}, order = mapping, degenerate = false, modelAO = true,
		metadata = { face = face, shade = true, quadEmission = 0 } }
	for i = 1, 4 do match.corners[i] = canonical[mapping[i]] end
	return rotateMatch( match, xSteps, zSteps )
end

local function legacyContext( visual, sourceQuad, selected )
	local state = MC.FormatBlockState( visual.stateId )
	return string.format( "block=%s state=%s (%s) orient=%s quad=%s models=%s",
		visual.schema.name, tostring( visual.stateId ), tostring( state ), tostring( visual.renderOrient ),
		tostring( sourceQuad ), table.concat( selected, ",", 1, selected.n ) )
end

function M.MatchLegacy( visual, sourceQuad, selected )
	if visual and visual.schema and visual.schema.project then
		if not MC.Check( visual.block == MC.Blocks[visual.id] and not visual.generatedVisualOverride
			and visual.modelData == nil and visual.faces == nil,
			"l2_project_visual", "project model overrides its authored geometry" ) then return nil end
		local quads = RM.rotatedModelQuads( visual.block, visual.renderOrient )
		local blockMatches = projectMatches[visual.block]
		local matches = blockMatches and quads and blockMatches[quads]
		if matches and matches[sourceQuad] then return matches[sourceQuad] end
		local quad = quads and quads[sourceQuad]
		if not MC.Check( quad ~= nil, "l2_project_quad", "missing project source quad %s", sourceQuad ) then return nil end
		local source = vertices( quad )
		local _, emission = MC.BlockModelSurface( visual.block, quad )
		local result = {
			source = source, corners = source, modelAO = false, degenerate = false,
			metadata = { face = quad.face, shade = true, quadEmission = emission },
		}
		if not blockMatches then blockMatches = {} projectMatches[visual.block] = blockMatches end
		if not matches then matches = {} blockMatches[quads] = matches end
		matches[sourceQuad] = result
		return result
	end
	if not MC.Check( visual and visual.block == MC.Blocks[visual.id] and not visual.forceBaseRenderer
		and not visual.generatedVisualOverride and visual.schema and visual.schema.blockId == visual.id
		and visual.faces == nil and visual.boxes == nil and visual.modelData == nil
		and visual.lightEmission == nil and visual.lightOpacity == nil and visual.fullCube == nil,
		"l2_model_custom_visual", "legacy visual has no catalog metadata contract" ) then return nil end
	local legacyQuads = RM.rotatedModelQuads( visual.block, visual.renderOrient )
	local legacy = legacyQuads and legacyQuads[sourceQuad]
	if not MC.Check( legacy ~= nil, "l2_model_legacy_source", "missing legacy source quad %s", sourceQuad ) then return nil end
	local _, emission = MC.BlockModelSurface( visual.block, legacy )
	local source = vertices( legacy )
	local sourceModels, xSteps, zSteps = legacySelection( visual, selected )
	if not sourceModels then return nil end
	local result
	for i = 1, sourceModels.n do
		local model, profile = M.Geometry( sourceModels[i] )
		if not model then return nil end
		for qi = 1, profile.sourceCount do
			local quad, metadata = model.modelQuads[qi], profile.quads[qi]
			local _, targetEmission = MC.BlockModelSurface( model, quad )
			-- Albedo/UVs are retained from the emitted mesh and do not define
			-- lighting. Keep emission and tint provenance distinct from them.
			if RM.rotateModelFace( quad.face, xSteps, zSteps ) == legacy.face and emission == targetEmission
				and ( quad.tintIndex or -1 ) == ( legacy.tintIndex or -1 ) then
				local degenerate = metadata == nil
				local mapping = matchVertices( source, vertices( quad, xSteps, zSteps ), degenerate )
				if mapping then
					local match = { metadata = metadata, source = source, degenerate = degenerate, modelAO = sourceModels.modelAO }
					if metadata then match.corners, match.order = M.Corners( model, qi, metadata, mapping ) end
					match = rotateMatch( match, xSteps, zSteps )
					if not match then return nil end
					if result and not sameLighting( result, match ) then
						MC.Fault( "l2_model_legacy_ambiguous", "%s: different paired lighting semantics",
							legacyContext( visual, sourceQuad, selected ) )
						return nil
					end
					result = match
				end
			end
		end
	end
	if not result then result = bellBody( visual, sourceQuad, legacyQuads, source, emission ) end
	if not result then
		MC.Fault( "l2_model_legacy_unmatched", "%s: no paired geometry/lighting match",
			legacyContext( visual, sourceQuad, selected ) )
		return nil
	end
	return result
end
