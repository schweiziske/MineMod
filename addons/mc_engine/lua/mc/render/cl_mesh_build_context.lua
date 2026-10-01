-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh
local VertexBuffer = MC.RenderVertexBuffer
local LightBuffer = MC.RenderLightBuffer


local C = MC.RenderMeshConstants
local clampLightLevel = RM.clampLightLevel
local sameLiquidKind = RM.sameLiquidKind
local coveredByBoxes = RM.coveredByBoxes
local facePlane = RM.facePlane
local EPS = RM.EPS
local cornerXYZ = RM.cornerXYZ
local shadeRecolorIndex = RM.shadeRecolorIndex
local uploadMeshVertices = RM.uploadMeshVertices
local meshPerfAdd = RM.meshPerfAdd
local meshPerfMS = RM.meshPerfMS
local setMeshSampleCacheOrigin = RM.setMeshSampleCacheOrigin
local destroySectionMeshList = RM.destroySectionMeshList

local function newLightMetaFactory( localIndexForBlockCoords, samples )
	local function fromCorner( shade, bx, by, bz, id, faceIndex, corner, selfEmission, unusedQuad, faceCubic, quadLightEmission, tintCode,
		lightingKind, modelId, sourceQuad, cornerIndex )
		local cx, cy, cz = cornerXYZ( corner )
		if faceCubic == nil then
			faceCubic = not unusedQuad or unusedQuad.faceCubic ~= false
		end
		return LightBuffer.AddValues(
			samples,
			shadeRecolorIndex( shade ),
			bx,
			by,
			bz,
			id,
			faceIndex,
			localIndexForBlockCoords( bx, by, bz ),
			cx,
			cy,
			cz,
			selfEmission,
			faceCubic,
			clampLightLevel( quadLightEmission ),
			tintCode, lightingKind, modelId, sourceQuad, cornerIndex
		)
	end

	local function fromValues( shade, bx, by, bz, id, faceIndex, cx, cy, cz, selfEmission, unusedQuad, faceCubic, quadLightEmission, tintCode,
		lightingKind, modelId, sourceQuad, cornerIndex )
		if faceCubic == nil then
			faceCubic = not unusedQuad or unusedQuad.faceCubic ~= false
		end
		return LightBuffer.AddValues(
			samples,
			shadeRecolorIndex( shade ),
			bx,
			by,
			bz,
			id,
			faceIndex,
			localIndexForBlockCoords( bx, by, bz ),
			cx,
			cy,
			cz,
			selfEmission,
			faceCubic,
			clampLightLevel( quadLightEmission ),
			tintCode, lightingKind, modelId, sourceQuad, cornerIndex
		)
	end

	local function fast( shadeIndex, bx, by, bz, id, faceIndex, li, cx, cy, cz, selfEmission, faceCubic, quadLightEmission, tintCode,
		lightingKind, modelId, sourceQuad, cornerIndex )
		return LightBuffer.AddValues(
			samples,
			shadeIndex,
			bx,
			by,
			bz,
			id,
			faceIndex,
			li,
			cx,
			cy,
			cz,
			selfEmission,
			faceCubic,
			clampLightLevel( quadLightEmission ),
			tintCode, lightingKind, modelId, sourceQuad, cornerIndex
		)
	end

	return {
		fromCorner = fromCorner,
		fromValues = fromValues,
		fast = fast,
	}
end

RM.newLightMetaFactory = newLightMetaFactory

function RM.NewBuildContext( key, sectionIndex, chunk, meshPerf, meshProbe, meshLightStyle, buildStart, meshLightProfile, blockSections, lightOnly )
	local Q = MC.RenderL2Quad
	local slice = Q.NewSlice( chunk, MC.API.Coords.BlockSize() )
	local sectionNeedsRecolor = lightOnly or sectionIndex and MC.MeshLightDirty[key] and MC.MeshLightDirty[key][sectionIndex]
	local blockLightDirtySection = sectionNeedsRecolor and MC.GetBlockLightDirtySection and MC.GetBlockLightDirtySection( key, sectionIndex ) or nil
	local sectionNeedsFullRecolor = sectionNeedsRecolor and not blockLightDirtySection

	local bxo = chunk.cx * C.CS
	local byo = chunk.cy * C.CS
	local bzo = chunk.cz * C.CH
	setMeshSampleCacheOrigin( bxo, byo, bzo )
	local blocksById = MC.Blocks
	local blockIsFullCube = MC.BlockIsFullCube
	local resolveBlockStateVisual = MC.ResolveBlockStateVisual
	local blockVisualBoxes = MC.BlockVisualBoxes
	local isPaneBlock = MC.IsPaneBlock
	local blockBoxes = MC.BlockBoxes
	local visibility = MC.RenderVisibility.New( chunk, blockSections, meshPerf )
	local stateAt = visibility.StateAt

	local sectionBuffers = {}
	local cur
	local directional = MC.MeshDirectionalCull and MC.MeshDirectionalCull:GetBool() or false
	local directionalMin = MC.MeshDirectionalMinBlocks and MC.MeshDirectionalMinBlocks:GetInt() or 64

	local function styleForBuffer()
		return "l2"
	end

	local function currentEmitLightStyle()
		return styleForBuffer( cur )
	end

	local function localIndex( lx, ly, lz )
		return lx + ly * C.CS + lz * C.CS2
	end

	local function orientAt( lx, ly, lz, bx, by, bz )
		local stateId = stateAt( lx, ly, lz, bx, by, bz )
		if not stateId or stateId == 0 then return 0 end
		if stateId and resolveBlockStateVisual then
			local visual = resolveBlockStateVisual( stateId, bx, by, bz )
			if visual then return visual.renderOrient end
		end
		return 0
	end

	local function shapeFaceNeighborCoveredAt( curId, box, faceIndex, bx, by, bz, lx, ly, lz )
		local plane = facePlane( box, faceIndex )
		local off = C.FACES[faceIndex].off
		if ( faceIndex == MC.Face.TOP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.BOTTOM and math.abs( plane ) > EPS )
		or ( faceIndex == MC.Face.XP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.XN and math.abs( plane ) > EPS )
		or ( faceIndex == MC.Face.YP and math.abs( plane - 1 ) > EPS )
		or ( faceIndex == MC.Face.YN and math.abs( plane ) > EPS ) then
			return false
		end
		local nlx, nly, nlz = lx + off[1], ly + off[2], lz + off[3]
		local nbx, nby, nbz = bx + off[1], by + off[2], bz + off[3]
		local nb, fullCube, transparent, special, nbState = visibility.ClassAt( nlx, nly, nlz, nbx, nby, nbz )
		if nb == nil or nb == 0 or special then return false end
		if sameLiquidKind( curId, nb ) then return true end
		if transparent and not ( isPaneBlock and isPaneBlock( nb ) ) then return false end
		if fullCube == true then return true end
		local nbVisual = resolveBlockStateVisual and resolveBlockStateVisual( nbState, nbx, nby, nbz ) or nil
		local nbOrient = nbVisual and nbVisual.renderOrient or orientAt( nlx, nly, nlz, nbx, nby, nbz )
		local nbBoxes = nbVisual and blockVisualBoxes and blockVisualBoxes( nbVisual, nbx, nby, nbz )
			or blockBoxes and blockBoxes( nb, nbOrient, nbx, nby, nbz ) or nil
		return coveredByBoxes( box, faceIndex, nbBoxes, off[1], off[2], off[3] )
	end

	local function shapeFaceCoveredAt( curId, box, faceIndex, boxes, bx, by, bz, lx, ly, lz )
		if boxes and #boxes > 1 and coveredByBoxes( box, faceIndex, boxes, 0, 0, 0 ) then return true end
		return shapeFaceNeighborCoveredAt( curId, box, faceIndex, bx, by, bz, lx, ly, lz )
	end

	local function newMeshBuffer( material, translucent, split )
		return { list = {}, records = {}, buckets = {}, material = material, translucent = translucent, directional = split }
	end

	local function bufferForBlock( root, id )
		root = root.owner or root
		local blockBuffers = root.blockBuffers
		if not blockBuffers then
			blockBuffers = {}
			root.blockBuffers = blockBuffers
		end
		local cached = blockBuffers[id]
		if cached then return cached end
		local request = MC.RenderBlockBindings.Key( id )
		local block = blocksById[id]
		-- Registered definitions do not store fullCube; query the shape contract.
		local stage = root.translucent and "world_translucent" or
			( blockIsFullCube( id ) and block.transparent ~= true and "world_opaque" or "world_cutout" )
		local bucketKey = request .. "/" .. stage
		local buffer = root.buckets[bucketKey]
		if not buffer then
			buffer = Q.NewBuffer( slice )
			buffer.owner, buffer.list, buffer.records = root, root.list, root.records
			buffer.material, buffer.translucent = root.material, root.translucent
			buffer.request, buffer.stage, buffer.blockIds = request, stage, {}
			buffer.directional = root.directional and stage == "world_opaque"
			root.buckets[bucketKey] = buffer
		end
		buffer.blockIds[id] = true
		blockBuffers[id] = buffer
		return buffer
	end

	-- Called only by the direct full-cube emitter using the six fixed C.FACES
	-- templates. Models, plants, fluids and cached special geometry stay whole.
	local function fullCubeBuffer( target, face )
		if not target.directional then return target end
		local groups = target.directions
		if not groups then groups = {} target.directions = groups end
		local buffer = groups[face]
		if not buffer then
			buffer = Q.NewBuffer( slice )
			buffer.owner, buffer.list, buffer.records = target.owner, target.list, target.records
			buffer.material, buffer.translucent = target.material, false
			buffer.request, buffer.stage, buffer.blockIds = target.request, target.stage, target.blockIds
			buffer.direction = face
			groups[face] = buffer
		end
		return buffer
	end

	local spareBlockBuffer
	local function newBlockCacheBuffer( targetBuffer )
		local buffer = spareBlockBuffer
		spareBlockBuffer = nil
		if not buffer then
			buffer = Q.NewBuffer( slice )
			buffer.cacheOnly = true
		end
		buffer.material = targetBuffer.material
		buffer.translucent = targetBuffer.translucent == true
		buffer.materialId = targetBuffer.materialId or 0
		buffer.passId = targetBuffer.passId or ( targetBuffer.translucent and 3 or 1 )
		return buffer
	end

	local function prepareBlockCacheBuffer( targetBuffer )
		cur = newBlockCacheBuffer( targetBuffer )
		return true
	end

	local function buffersForLocal( lx, ly, lz )
		local index = MC.RenderSectionIndexForLocal( lx, ly, lz )
		if sectionIndex and index ~= sectionIndex then return nil, index end
		local buffers = sectionBuffers[index]
		if not buffers then
			local split = directional and blockSections[index].count >= directionalMin
			buffers = {
				opaque = newMeshBuffer( MC.Material, false, split ),
				translucent = newMeshBuffer( MC.MaterialTranslucent, true ),
			}
			sectionBuffers[index] = buffers
		end
		return buffers, index
	end

	local function flush( buf )
		if buf.nv == 0 then return end
		local vertexCount = buf.nv
		local entry = MC.RenderPackGeometry.Upload( buf, meshPerf )
		buf.list[#buf.list + 1] = entry
		buf.records[#buf.records + 1] = {
			l2 = true, mesh = entry.mesh,
			nativeL2 = buf.nativeL2, uploadedVertices = entry.uploadedVertices,
			verts = buf.verts,
			pixels = buf.pixels,
			occlusion = buf.occlusion,
			material = buf.material,
			vertexCount = vertexCount,
			hasSecondaryUV = false,
			translucent = buf.translucent == true,
			request = buf.request, stage = buf.stage,
		}
		meshPerf.vertices = meshPerf.vertices + vertexCount
		meshPerf.faces = meshPerf.faces + math.floor( vertexCount / 6 )
		meshPerf.meshes = meshPerf.meshes + 1
		if buf.translucent then
			meshPerf.translucentVerts = meshPerf.translucentVerts + vertexCount
		else
			meshPerf.opaqueVerts = meshPerf.opaqueVerts + vertexCount
		end
		buf.verts = VertexBuffer.New()
		buf.pixels = {}
		buf.occlusion = {}
		if buf.nativeL2 then buf.nativeCommands = {} end
		buf.nv, buf.quadCount = 0, 0
		buf.hasSecondaryUV = false
	end

	local function rejectLegacy()
		error( { code = "render_l2_emitter_required", message = "world emitters must submit complete L2 quads" }, 0 )
	end

	local function emitL2( quad, id, bx, by, bz, wx, wy, wz, emission, tint, kind, modelId )
		if not cur.cacheOnly and cur.nv + 6 > C.VERT_LIMIT then flush( cur ) end
		Q.EmitNative( slice, cur, quad, id, bx, by, bz, wx, wy, wz, emission, tint, kind, modelId )
	end

	local function appendMeshList( out, list )
		for i = 1, #list do
			out[#out + 1] = list[i]
		end
	end

	local function flushSectionBuffers()
		local opaqueMeshes = {}
		local translucentMeshes = {}
		local opaqueRecords = {}
		local translucentRecords = {}
		local totalSections = C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_XY * C.RENDER_SECTIONS_Z
		for i = 1, totalSections do
			local buffers = sectionBuffers[i]
			if buffers then
				for _, buffer in pairs( buffers.opaque.buckets ) do
					flush( buffer )
					if buffer.directions then
						for face = 1, 6 do
							local group = buffer.directions[face]
							if group then flush( group ) end
						end
					end
				end
				for _, buffer in pairs( buffers.translucent.buckets ) do flush( buffer ) end
				appendMeshList( opaqueMeshes, buffers.opaque.list )
				appendMeshList( translucentMeshes, buffers.translucent.list )
				appendMeshList( opaqueRecords, buffers.opaque.records )
				appendMeshList( translucentRecords, buffers.translucent.records )
			end
		end
		return opaqueMeshes, translucentMeshes, opaqueRecords, translucentRecords
	end

	meshPerf.prepMS = meshPerfMS( buildStart )

	local ctx = {
		key = key,
		sectionIndex = sectionIndex,
		chunk = chunk,
		meshPerf = meshPerf,
		meshProbe = meshProbe,
		meshLightStyle = meshLightStyle,
		meshLightProfile = meshLightProfile,
		sectionNeedsRecolor = sectionNeedsRecolor,
		blockLightDirtySection = blockLightDirtySection,
		sectionNeedsFullRecolor = sectionNeedsFullRecolor,
		bxo = bxo,
		byo = byo,
		bzo = bzo,
		blocksById = blocksById,
		blockIsFullCube = blockIsFullCube,
		blockBoxes = blockBoxes,
		blockSections = blockSections,
		visibility = visibility,
		sectionBuffers = sectionBuffers,
		fluidCornerHeightCache = {},
		C = C,
		l2 = true,
		blockSize = slice.blockSize,
		nativeL2 = slice.nativeL2,
	}

	ctx.styleForBuffer = styleForBuffer
	ctx.currentEmitLightStyle = currentEmitLightStyle
	ctx.localIndex = localIndex
	ctx.stateAt = stateAt
	ctx.orientAt = orientAt
	ctx.beginSection = visibility.BeginSection
	ctx.visibleAt = visibility.VisibleAt
	ctx.visibleFaceMask = visibility.FaceMask
	ctx.shapeFaceCoveredAt = shapeFaceCoveredAt
	ctx.shapeFaceNeighborCoveredAt = shapeFaceNeighborCoveredAt
	ctx.buffersForLocal = buffersForLocal
	ctx.bufferForBlock = bufferForBlock
	ctx.fullCubeBuffer = fullCubeBuffer
	ctx.flush = flush
	ctx.emitL2 = emitL2
	ctx.push, ctx.pushValues = rejectLegacy, rejectLegacy
	-- Caller may return only unpublished scratch, after its vertices were copied.
	-- Retained block/section records never enter this bounded one-buffer cache.
	function ctx.releaseScratch( buffer )
		if not buffer or not buffer.cacheOnly then return end
		VertexBuffer.Reset( buffer.verts )
		for i = 1, #buffer.pixels do buffer.pixels[i] = nil end
		for i = 1, #buffer.occlusion do buffer.occlusion[i] = nil end
		if buffer.nativeCommands then
			for i = 1, #buffer.nativeCommands do buffer.nativeCommands[i] = nil end
		end
		buffer.nv, buffer.quadCount, buffer.hasSecondaryUV = 0, 0, false
		if not spareBlockBuffer then spareBlockBuffer = buffer end
	end
	ctx.lightMeta, ctx.lightMetaValues, ctx.lightMetaFast = rejectLegacy, rejectLegacy, rejectLegacy
	function ctx.beginBlockLight() end
	ctx.flushSectionBuffers = flushSectionBuffers
	function ctx.discardSectionBuffers( report )
		for index, buffers in pairs( sectionBuffers ) do
			destroySectionMeshList( buffers.opaque.list, report )
			destroySectionMeshList( buffers.translucent.list, report )
			sectionBuffers[index] = nil
		end
	end
	function ctx.prepareBlockCacheBuffer( targetBuffer )
		local ok = prepareBlockCacheBuffer( targetBuffer )
		ctx.cur = cur
		return ok
	end
	function ctx.setCur( value )
		cur = value
		ctx.cur = cur
	end
	function ctx.getCur()
		ctx.cur = cur
		return cur
	end
	return ctx
end
