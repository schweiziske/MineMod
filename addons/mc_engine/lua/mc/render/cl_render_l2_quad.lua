-- Native world quad emission. The record adapter below is diagnostic-only.
-- Errors propagate to the owner for render-state restoration and MC.Fault.
MC = MC or {}
local Q = {}
MC.RenderL2Quad = Q
local VB, LB, RM = MC.RenderVertexBuffer, MC.RenderLightBuffer, MC.RenderMesh
local VERT_LIMIT = MC.RenderMeshConstants.VERT_LIMIT
local floor = math.floor
local KIND = LB.KIND
local TRI = { 1, 3, 2, 1, 4, 3 }
local CORNER_VERTICES = { 1, 3, 2, 5 }
local META_FIELDS = {
	"shadeIndex", "bx", "by", "bz", "id", "faceIndex", "li", "cx", "cy", "cz",
	"selfEmission", "faceCubic", "quadLightEmission", "tintCode",
	"lightingKind", "modelId", "sourceQuad", "cornerIndex",
}
local COMMON_FIELDS = { "bx", "by", "bz", "id", "faceIndex", "faceCubic", "selfEmission", "quadLightEmission",
	"lightingKind", "modelId", "sourceQuad" }

local function finite( value )
	return type( value ) == "number" and value == value and value > -math.huge and value < math.huge
end

local function integer( value, low, high )
	return finite( value ) and value >= low and value <= high and value == floor( value )
end

local function requireValue( ok, message )
	if not ok then error( message, 0 ) end
end

function Q.RecordQuadCount( record, translucent )
	requireValue( type( record ) == "table" and record.mesh and record.material, "record has no mesh/material" )
	local verts, light = record.verts, record.light
	requireValue( type( verts ) == "table" and LB.IsCompatible( light ), "record has no compatible vertex/light data" )
	requireValue( verts.vertexBufferVersion == nil or verts.vertexBufferVersion == VB.VERSION, "unsupported vertex version" )
	local count = VB.Count( verts )
	requireValue( integer( count, 6, VERT_LIMIT ) and count % 6 == 0, "record is not a bounded quad triangle list" )
	requireValue( count == record.vertexCount and count == #light, "record vertex/light count mismatch" )
	requireValue( record.translucent == translucent, "record pass mismatch" )
	if verts.vertexBufferVersion then
		requireValue( #verts == count * VB.STRIDE, "truncated packed vertices" )
	end
	return count / 6
end

local function validateMeta( meta )
	requireValue( type( meta ) == "table", "missing corner metadata" )
	requireValue( integer( meta.shadeIndex, 1, 5 ) and integer( meta.id, 1, 2147483647 )
		and integer( meta.faceIndex, 1, 6 ), "invalid corner shade/block/face" )
	requireValue( integer( meta.bx, -2147483648, 2147483647 )
		and integer( meta.by, -2147483648, 2147483647 )
		and integer( meta.bz, -2147483648, 2147483647 ), "invalid block coordinates" )
	requireValue( finite( meta.cx ) and finite( meta.cy ) and finite( meta.cz ), "invalid model corner" )
	requireValue( meta.selfEmission == nil or integer( meta.selfEmission, 0, 15 ), "invalid self emission" )
	requireValue( meta.quadLightEmission == nil or integer( meta.quadLightEmission, 0, 15 ), "invalid quad emission" )
	requireValue( meta.tintCode == nil or integer( meta.tintCode, 0, 25 ), "unsupported tint code" )
	requireValue( meta.faceCubic == nil or type( meta.faceCubic ) == "boolean", "invalid cubic flag" )
	requireValue( integer( meta.lightingKind, KIND.BOX, KIND.FLUID ) and integer( meta.cornerIndex, 1, 4 ),
		"missing quad provenance; rebuild Lua geometry before preparing L2" )
	requireValue( integer( meta.modelId, 0, 65535 ) and integer( meta.sourceQuad, 0, 65535 ), "invalid model provenance" )
end

local function sameMeta( a, b, fields )
	for i = 1, #fields do
		local key = fields[i]
		requireValue( a[key] == b[key], "quad metadata mismatch: " .. key )
	end
end

local function sameVertex( verts, first, second )
	for i = 1, VB.STRIDE do
		requireValue( verts[first + i] == verts[second + i], "unsupported quad triangle ordering" )
	end
end

local function pixel( blockByte, skyByte, shade, tint )
	-- Java's smoothPack preserves all eight bits after weighted extrapolation.
	-- The shader clamps to 240 when looking up the lightmap, not during transport.
	requireValue( integer( blockByte, 0, 255 ) and integer( skyByte, 0, 255 )
		and integer( shade, 0, 255 ), "invalid corner bytes" )
	return blockByte + skyByte * 256 + shade * 65536 + tint * 16777216
end

local function sampleFluid( meta )
	local emission = meta.selfEmission
	if emission == nil then emission = RM.blockLightEmissionAt( meta.bx, meta.by, meta.bz ) end
	emission = math.max( emission, meta.quadLightEmission or 0 )
	local blockByte, skyByte = RM.rawLightFaceVertexValues( meta, emission )
	return pixel( blockByte, skyByte, RM.shadeRGBAByIndex( meta.shadeIndex ), meta.tintCode or 0 )
end

function Q.NewSlice( chunk, blockSize )
	local snapshot = MC.RenderL2Snapshot.New( chunk )
	requireValue( snapshot ~= nil, "L2 lighting snapshot is unavailable" )
	local lighter = MC.RenderL2Lighting.New( snapshot.reader )
	requireValue( lighter ~= nil and finite( blockSize ) and blockSize > 0, "invalid L2 slice lighting/scale" )
	return { snapshot = snapshot, lighter = lighter, blockSize = blockSize, selections = {}, models = {} }
end

function Q.NewBuffer()
	return { l2 = true, verts = VB.New(), pixels = {}, nv = 0, quadCount = 0 }
end

function Q.Rebase( verts, firstVertex, count, firstQuad )
	requireValue( count % 6 == 0 and ( firstVertex - 1 ) % 6 == 0, "L2 rebasing requires whole quads" )
	for quad = 0, count / 6 - 1 do
		local address = ( firstQuad + quad ) * 4
		local r, g, b = address % 256, floor( address / 256 ) % 256, floor( address / 65536 )
		local offset = ( firstVertex - 1 + quad * 6 ) * VB.STRIDE
		for i = 1, 6 do
			local o = offset + ( i - 1 ) * VB.STRIDE
			verts[o + 11], verts[o + 12], verts[o + 13] = r + TRI[i] - 1, g, b
		end
	end
end

function Q.AppendNative( target, source, firstQuad, count )
	requireValue( target.l2 and source.l2 and #source.pixels == VB.Count( source.verts ) / 6 * 4,
		"L2 append received an incompatible buffer" )
	local firstVertex, baseQuad = target.verts.count + 1, target.verts.count / 6
	VB.AppendRange( target.verts, source.verts, firstQuad * 6 + 1, count * 6 )
	Q.Rebase( target.verts, firstVertex, count * 6, baseQuad )
	for i = firstQuad * 4 + 1, ( firstQuad + count ) * 4 do
		target.pixels[#target.pixels + 1] = source.pixels[i]
	end
	target.nv, target.quadCount = target.verts.count, baseQuad + count
end

local function templateCorners( quad )
	if quad.l2Corners then return quad.l2Corners, quad.l2UV end
	local corners = {
		{ quad.c1x, quad.c1y, quad.c1z }, { quad.c2x, quad.c2y, quad.c2z },
		{ quad.c3x, quad.c3y, quad.c3z }, { quad.c4x, quad.c4y, quad.c4z },
	}
	local uv = { { quad.u1, quad.v1 }, { quad.u2, quad.v2 }, { quad.u3, quad.v3 }, { quad.u4, quad.v4 } }
	quad.l2Corners, quad.l2UV = corners, uv
	return corners, uv
end

local function nativeModel( slice, quad, id, bx, by, bz, modelId )
	local index = slice.snapshot:Index( bx, by, bz )
	local selected = slice.selections[index]
	if not selected then
		local cell = slice.snapshot:Read( bx, by, bz )
		requireValue( cell and cell.loaded, "model source cell is unavailable" )
		selected = MC.RenderL2Models.Selection( cell.stateId, bx, by, bz )
		requireValue( selected ~= nil, "model source plan is unavailable" )
		slice.selections[index] = selected
	end
	local key = selected.l2Key
	if not key then
		key = tostring( selected.modelAO ) .. ":" .. table.concat( selected, ",", 1, selected.n )
		selected.l2Key = key
	end
	local cache = quad.l2Models
	if not cache then cache = {} quad.l2Models = cache end
	local modelKey = modelId or 0
	local modelCache = cache[modelKey]
	if not modelCache then modelCache = {} cache[modelKey] = modelCache end
	local result = modelCache[key]
	if result then return result end
	local models = MC.RenderL2Models
	if modelId then
		local present = false
		for i = 1, selected.n do if selected[i] == modelId then present = true break end end
		requireValue( present, "emitted model is not in the selected state plan" )
		local model, profile = models.Geometry( modelId )
		requireValue( model and quad.sourceQuad <= profile.sourceCount, "model source quad is unavailable" )
		local metadata = profile.quads[quad.sourceQuad]
		result = { metadata = metadata, degenerate = metadata == nil, modelAO = selected.modelAO }
		if metadata then result.corners, result.order = models.Corners( model, quad.sourceQuad, metadata ) end
	else
		local cell = slice.snapshot:Read( bx, by, bz )
		local visual, err = MC.ResolveBlockStateVisual( cell.stateId, bx, by, bz )
		requireValue( visual and visual.id == id, "model visual is unavailable: " .. tostring( err ) )
		-- Pair an imported template once, never a built mesh or each placed block.
		result = models.MatchLegacy( visual, quad.sourceQuad, selected )
		requireValue( result ~= nil, "model template has no verified lighting metadata" )
	end
	if not result.degenerate then
		local metadata = result.metadata
		result.l2Lighting = MC.RenderL2Lighting.BakeQuad( metadata.face, result.corners, {
			modelAO = result.modelAO, shade = metadata.shade, cullFace = metadata.cullFace,
			quadEmission = metadata.quadEmission, cornerOrder = result.order,
		} )
		requireValue( result.l2Lighting ~= nil, "model lighting template preparation failed" )
	end
	modelCache[key] = result
	return result
end

function Q.EmitNative( slice, buffer, quad, id, bx, by, bz, wx, wy, wz, emission, tint, kind, modelId )
	local corners, uv = templateCorners( quad )
	local positions, face = quad.positions or corners, quad.faceIndex
	local quadEmission, baked = quad.quadLightEmission or 0, quad.l2Lighting
	tint = tint or 0
	if kind == KIND.MODEL or kind == KIND.GENERATED then
		local model = nativeModel( slice, quad, id, bx, by, bz, modelId )
		if model.degenerate then return end
		local metadata = model.metadata
		corners, positions, face = model.corners, model.corners, metadata.face
		baked = model.l2Lighting
	end
	local pixels = buffer.pixels
	if kind == KIND.FLUID then
		local meta = slice.fluidMeta or {}
		slice.fluidMeta = meta
		meta.bx, meta.by, meta.bz, meta.id, meta.faceIndex = bx, by, bz, id, face
		meta.selfEmission, meta.quadLightEmission, meta.tintCode = emission, quadEmission, tint
		meta.faceCubic, meta.shadeIndex = quad.faceCubic, RM.shadeIndexForFace( face )
		for i = 1, 4 do
			meta.cx, meta.cy, meta.cz = corners[i][1], corners[i][2], corners[i][3]
			pixels[#pixels + 1] = sampleFluid( meta )
		end
	elseif kind == KIND.CROSS then
		local cell = slice.lighter:Cell( bx, by, bz )
		requireValue( cell and cell.loaded, "cross source cell is unavailable" )
		local block, sky = math.max( cell.block, cell.emission, quadEmission ), math.max( cell.sky, quadEmission )
		if cell.emissive then block, sky = 15, 15 end
		local value = pixel( block * 16, sky * 16, 255, tint )
		for i = 1, 4 do pixels[#pixels + 1] = value end
	else
		if not baked then
			baked = MC.RenderL2Lighting.BakeQuad( face, corners, { quadEmission = quadEmission } )
			requireValue( baked ~= nil, "quad lighting template preparation failed" )
			quad.l2Lighting = baked
		end
		slice.lighting = slice.lighting or { light = {}, shade = {} }
		local result = slice.lighter:PrepareBaked( bx, by, bz, baked, slice.lighting )
		requireValue( result ~= nil, "native quad lighting preparation failed" )
		for i = 1, 4 do
			local light = result.light[i]
			pixels[#pixels + 1] = pixel( light % 256, floor( light / 65536 ) % 256, result.shade[i], tint )
		end
	end
	local verts, normal = buffer.verts, quad.normal
	local base = verts.count / 6
	local address = base * 4
	local size = slice.blockSize
	if quad.positions then size, wx, wy, wz = 1, 0, 0, 0 end
	slice.color = slice.color or {}
	local color = slice.color
	color.a = quad.opacity or ( quad.shade and quad.shade.a ) or 255
	local r = address % 256
	color.g, color.b = floor( address / 256 ) % 256, floor( address / 65536 )
	for i = 1, 6 do
		local ci = TRI[i]
		local p, tex = positions[ci], uv[ci]
		color.r = r + ci - 1
		VB.PushValues( verts, wx + p[1] * size, wy + p[2] * size, wz + p[3] * size,
			normal, tex[1], tex[2], color )
	end
	buffer.nv, buffer.quadCount = verts.count, base + 1
end

local function selectedModels( slice, meta )
	local index = slice.snapshot:Index( meta.bx, meta.by, meta.bz )
	local selected = slice.selections[index]
	if not selected then
		local cell = slice.snapshot:Read( meta.bx, meta.by, meta.bz )
		requireValue( cell and cell.loaded, "source model is in an unloaded cell" )
		selected = MC.RenderL2Models.Selection( cell.stateId, meta.bx, meta.by, meta.bz )
		requireValue( selected ~= nil, "could not resolve the source model plan" )
		slice.selections[index] = selected
	end
	return selected, index
end

local function modelQuad( slice, meta, corners )
	local models = MC.RenderL2Models
	local selected, index = selectedModels( slice, meta )
	local cache = slice.models[index]
	if not cache then cache = {} slice.models[index] = cache end
	local key = meta.modelId * 65536 + meta.sourceQuad
	local result = cache[key]
	if not result then
		if meta.lightingKind == KIND.GENERATED then
			local present = false
			for i = 1, selected.n do if selected[i] == meta.modelId then present = true break end end
			requireValue( present, "generated model is not in the selected state plan" )
			local model, profile = models.Geometry( meta.modelId )
			requireValue( model ~= nil and meta.sourceQuad > 0 and meta.sourceQuad <= profile.sourceCount,
				"generated model source quad is unavailable" )
			local metadata = profile.quads[meta.sourceQuad]
			result = { metadata = metadata, source = {}, degenerate = metadata == nil, modelAO = selected.modelAO }
			for i = 1, 4 do
				local x, y, z = MC.ModelQuadVertex( model.modelQuads[meta.sourceQuad], i )
				result.source[i] = { x, y, z }
			end
			if metadata then result.corners, result.order = models.Corners( model, meta.sourceQuad, metadata ) end
		else
			local cell = slice.snapshot:Read( meta.bx, meta.by, meta.bz )
			local visual, err = MC.ResolveBlockStateVisual( cell.stateId, meta.bx, meta.by, meta.bz )
			requireValue( visual and visual.id == meta.id, "legacy state visual changed: " .. tostring( err ) )
			result = models.MatchLegacy( visual, meta.sourceQuad, selected )
			requireValue( result ~= nil, "legacy model metadata could not be paired" )
		end
		cache[key] = result
	end
	for i = 1, 4 do
		for axis = 1, 3 do
			requireValue( corners[i][axis] == result.source[i][axis], "source model geometry changed after emission" )
		end
	end
	return result, result.modelAO
end

local function prepareQuad( slice, part, offset )
	local meta = part.scratch[1]
	requireValue( MC.Blocks[meta.id] ~= nil, "missing block definition " .. meta.id )
	local corners = part.corners
	for i = 1, 4 do
		local m = part.scratch[CORNER_VERTICES[i]]
		requireValue( m.cornerIndex == i, "quad corner provenance disagrees with triangle order" )
		corners[i][1], corners[i][2], corners[i][3] = m.cx, m.cy, m.cz
	end
	if meta.lightingKind == KIND.FLUID then
		for i = 1, 4 do part.pixels[#part.pixels + 1] = sampleFluid( part.scratch[CORNER_VERTICES[i]] ) end
		return
	end
	if meta.lightingKind == KIND.CROSS then
		local cell = slice.lighter:Cell( meta.bx, meta.by, meta.bz )
		requireValue( cell and cell.loaded, "cross source cell is unavailable" )
		local block, sky = math.max( cell.block, cell.emission ), cell.sky
		if cell.emissive then block, sky = 15, 15 end
		local emission = meta.quadLightEmission or 0
		block, sky = math.max( block, emission ), math.max( sky, emission )
		for i = 1, 4 do
			part.pixels[#part.pixels + 1] = pixel( block * 16, sky * 16, 255, part.scratch[CORNER_VERTICES[i]].tintCode or 0 )
		end
		return
	end
	local face, options = meta.faceIndex, { quadEmission = meta.quadLightEmission or 0 }
	if meta.lightingKind == KIND.MODEL or meta.lightingKind == KIND.GENERATED then
		local model, effectiveAO = modelQuad( slice, meta, corners )
		if model.degenerate then
			-- The paired generator proved zero area. Keep the allocated address
			-- but collapse candidate triangles instead of inventing lighting.
			for i = 2, 6 do
				local o = offset + ( i - 1 ) * VB.STRIDE
				for axis = 1, 3 do part.verts[o + axis] = part.verts[offset + axis] end
			end
			for i = 1, 4 do part.pixels[#part.pixels + 1] = 0 end
			return
		end
		local metadata = model.metadata
		face = metadata.face
		options = { modelAO = effectiveAO, shade = metadata.shade, cullFace = metadata.cullFace,
			quadEmission = metadata.quadEmission, cornerOrder = model.order }
		for i = 1, 6 do
			local ci, o = TRI[i], offset + ( i - 1 ) * VB.STRIDE
			for axis = 1, 3 do
				part.verts[o + axis] = part.verts[o + axis] + ( model.corners[ci][axis] - corners[ci][axis] ) * slice.blockSize
			end
		end
		corners = model.corners
	end
	local result = slice.lighter:Prepare( meta.bx, meta.by, meta.bz, face, corners, options, part.lighting )
	requireValue( result ~= nil, "quad lighting preparation failed" )
	for i = 1, 4 do
		local light = result.light[i]
		part.pixels[#part.pixels + 1] = pixel( light % 256, floor( light / 65536 ) % 256,
			result.shade[i], part.scratch[CORNER_VERTICES[i]].tintCode or 0 )
	end
end

function Q.NewPart( sourceIndex, firstQuad )
	return { sourceIndex = sourceIndex, firstQuad = firstQuad, quadCount = 0,
		verts = VB.New(), pixels = {}, scratch = { {}, {}, {}, {}, {}, {} },
		corners = { {}, {}, {}, {} }, lighting = { light = {}, shade = {} } }
end

function Q.AppendQuad( part, record, sourceQuad, globalQuad, slice )
	requireValue( slice and slice.lighter and slice.snapshot, "quad conversion requires a synchronous slice context" )
	requireValue( integer( globalQuad, 0, 1048575 ) and integer( sourceQuad, 0, VERT_LIMIT / 6 - 1 ),
		"quad address exceeds source record or the 2048-square atlas" )
	local verts, offset = part.verts, part.verts.count * VB.STRIDE
	VB.AppendRange( verts, record.verts, sourceQuad * 6 + 1, 6 )
	for i = 1, 6 * VB.STRIDE do
		requireValue( finite( verts[offset + i] ), "non-finite or missing vertex data" )
	end
	for i = 1, 6 do
		local o = offset + ( i - 1 ) * VB.STRIDE
		requireValue( integer( verts[o + 14], 0, 255 ), "invalid vertex opacity" )
		local meta = LB.Read( record.light, sourceQuad * 6 + i, part.scratch[i] )
		validateMeta( meta )
		part.scratch[i] = meta
	end
	sameVertex( verts, offset, offset + 3 * VB.STRIDE )
	sameVertex( verts, offset + VB.STRIDE, offset + 5 * VB.STRIDE )
	sameMeta( part.scratch[1], part.scratch[4], META_FIELDS )
	sameMeta( part.scratch[2], part.scratch[6], META_FIELDS )
	for i = 2, 6 do sameMeta( part.scratch[1], part.scratch[i], COMMON_FIELDS ) end
	prepareQuad( slice, part, offset )
	for i = 1, 6 do
		local address = globalQuad * 4 + TRI[i] - 1
		local o = offset + ( i - 1 ) * VB.STRIDE
		verts[o + 11], verts[o + 12], verts[o + 13] = address % 256, floor( address / 256 ) % 256, floor( address / 65536 )
		-- Candidate shaders do not consume the L1 secondary-UV payload.
		verts[o + 9], verts[o + 10], verts[o + 16] = 0, 0, 0
	end
	part.quadCount = part.quadCount + 1
end
