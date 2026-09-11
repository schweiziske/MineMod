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
	local function fromCorner( shade, bx, by, bz, id, faceIndex, corner, selfEmission, unusedQuad, faceCubic, quadLightEmission, tintCode )
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
			tintCode
		)
	end

	local function fromValues( shade, bx, by, bz, id, faceIndex, cx, cy, cz, selfEmission, unusedQuad, faceCubic, quadLightEmission, tintCode )
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
			tintCode
		)
	end

	local function fast( shadeIndex, bx, by, bz, id, faceIndex, li, cx, cy, cz, selfEmission, faceCubic, quadLightEmission, tintCode )
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
			tintCode
		)
	end

	return {
		fromCorner = fromCorner,
		fromValues = fromValues,
		fast = fast,
	}
end

RM.newLightMetaFactory = newLightMetaFactory

function RM.NewBuildContext( key, sectionIndex, chunk, meshPerf, meshProbe, meshLightStyle, buildStart, meshLightProfile, blockSections )
	meshLightProfile = meshLightProfile or RM.GetLightProfile and RM.GetLightProfile( meshLightStyle ) or nil
	local meshGpuPayloadMaterial = meshLightProfile and meshLightProfile.gpuPayloadMaterial
	if type( meshGpuPayloadMaterial ) == "function" then meshGpuPayloadMaterial = meshGpuPayloadMaterial( meshLightProfile ) end
	local meshGpuPayloadMaterialTrans = meshLightProfile and meshLightProfile.gpuPayloadMaterialTranslucent
	if type( meshGpuPayloadMaterialTrans ) == "function" then meshGpuPayloadMaterialTrans = meshGpuPayloadMaterialTrans( meshLightProfile ) end
	local meshGpuPayloadStyle = meshLightProfile and meshLightProfile.gpuPayloadStyle
	if type( meshGpuPayloadStyle ) == "function" then meshGpuPayloadStyle = meshGpuPayloadStyle( meshLightProfile, meshGpuPayloadMaterial ) end
	local sectionNeedsRecolor = sectionIndex and MC.MeshLightDirty[key] and MC.MeshLightDirty[key][sectionIndex]
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

	local function styleForBuffer( buf )
		if meshGpuPayloadStyle and buf then
			local m = buf.material
			if ( meshGpuPayloadMaterial and m == meshGpuPayloadMaterial )
			or ( meshGpuPayloadMaterialTrans and m == meshGpuPayloadMaterialTrans ) then
				return meshGpuPayloadStyle
			end
		end
		return meshLightStyle
	end

	local function currentEmitLightStyle()
		return styleForBuffer( cur )
	end

	local function localIndex( lx, ly, lz )
		return lx + ly * C.CS + lz * C.CS2
	end

	local function localIndexForBlockCoords( bx, by, bz )
		local lx, ly, lz = bx - bxo, by - byo, bz - bzo
		if lx < 0 or lx >= C.CS or ly < 0 or ly >= C.CS or lz < 0 or lz >= C.CH then return nil end
		return localIndex( lx, ly, lz )
	end
	local lightSamples = LightBuffer.New()
	local lightCopies = LightBuffer.NewCopyMap()
	local lightMetaFactory = newLightMetaFactory( localIndexForBlockCoords, lightSamples )

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

	local function newMeshBuffer( material, translucent )
		local materialId, passId
		local materialABI = MC.RenderMaterialABI
		if materialABI and materialABI.Resolve then
			materialId, passId = materialABI.Resolve( material, translucent == true, false )
		end
		return {
			list = {}, records = {}, verts = VertexBuffer.New(), light = LightBuffer.New(), nv = 0,
			hasSecondaryUV = false, material = material,
			translucent = translucent == true, materialId = materialId or 0,
			passId = passId or ( translucent and 3 or 1 ),
		}
	end

	local spareBlockBuffer
	local function newBlockCacheBuffer( targetBuffer )
		local buffer = spareBlockBuffer
		spareBlockBuffer = nil
		if not buffer then
			buffer = { verts = VertexBuffer.New(), light = LightBuffer.New(), nv = 0,
				hasSecondaryUV = false, cacheOnly = true }
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

	local function buildLightIndexByLi( light, vertexCount )
		local byLi = {}
		for i = 1, vertexCount do
			local li = LightBuffer.LocalIndex( light, i )
			if li ~= nil then
				local list = byLi[li]
				if not list then
					list = { n = 0 }
					byLi[li] = list
				end
				local n = list.n + 1
				list.n = n
				list[n] = i
			end
		end
		return byLi
	end

	local function buffersForLocal( lx, ly, lz )
		local index = MC.RenderSectionIndexForLocal( lx, ly, lz )
		if sectionIndex and index ~= sectionIndex then return nil end
		local buffers = sectionBuffers[index]
		if not buffers then
			local chunkMaterial = MC.CurrentChunkMaterial or function( translucent ) return translucent and MC.MaterialTranslucent or MC.Material end
			buffers = {
				opaque = newMeshBuffer( chunkMaterial( false ), false ),
				translucent = newMeshBuffer( chunkMaterial( true ), true ),
			}
			sectionBuffers[index] = buffers
		end
		return buffers
	end

	local function flush( buf )
		if buf.nv == 0 then return end
		local vertexCount = buf.nv
		local meshNewStart = SysTime()
		local m = Mesh( buf.material )
		meshPerfAdd( meshPerf, "meshNewMS", meshNewStart )
		uploadMeshVertices( m, buf.verts, meshPerf, buf.hasSecondaryUV )
		buf.list[#buf.list + 1] = { mesh = m, material = buf.material }
		buf.records[#buf.records + 1] = {
			mesh = m,
			verts = buf.verts,
			light = buf.light,
			lightByLi = buildLightIndexByLi( buf.light, vertexCount ),
			material = buf.material,
			vertexCount = vertexCount,
			hasSecondaryUV = buf.hasSecondaryUV == true,
			translucent = buf.translucent == true,
			materialId = buf.materialId or 0,
			passId = buf.passId or ( buf.translucent and 3 or 1 ),
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
		buf.light = LightBuffer.New()
		buf.nv = 0
		buf.hasSecondaryUV = false
	end

	local function finishPush( light )
		local nv = cur.verts.count
		cur.nv = nv
		if type( light ) == "number" then
			cur.light[nv] = LightBuffer.CopySample( cur.light, lightSamples, light, lightCopies )
		else
			cur.light[nv] = LightBuffer.AddLegacy( cur.light, light )
		end
		if not cur.cacheOnly then
			meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + 1
			if nv >= C.VERT_LIMIT then flush( cur ) end
		end
	end

	local function pushValues( x, y, z, normal, u, v, color, light )
		VertexBuffer.PushValues( cur.verts, x, y, z, normal, u, v, color )
		finishPush( light )
	end

	local function push( vert, light, z, normal, u, v, color, numericLight )
		if type( vert ) == "number" then
			pushValues( vert, light, z, normal, u, v, color, numericLight )
		else
			VertexBuffer.PushLegacy( cur.verts, vert )
			if vert.u1 ~= nil or vert.v1 ~= nil then cur.hasSecondaryUV = true end
			finishPush( light )
		end
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
				flush( buffers.opaque )
				flush( buffers.translucent )
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
	ctx.flush = flush
	ctx.push = push
	-- Numeric vertex entry point used by the production emitters. Keep it
	-- explicit on the context so emitters do not need to infer capabilities
	-- from the generic push function.
	ctx.pushValues = pushValues
	-- Caller may return only unpublished scratch, after its vertices were copied.
	-- Retained block/section records never enter this bounded one-buffer cache.
	function ctx.releaseScratch( buffer )
		if not buffer or not buffer.cacheOnly then return end
		VertexBuffer.Reset( buffer.verts )
		LightBuffer.Reset( buffer.light )
		LightBuffer.ResetCopyMap( lightCopies )
		buffer.nv, buffer.hasSecondaryUV = 0, false
		if not spareBlockBuffer then spareBlockBuffer = buffer end
	end
	ctx.lightMetaFactory = lightMetaFactory
	ctx.lightMeta = lightMetaFactory.fromCorner
	ctx.lightMetaValues = lightMetaFactory.fromValues
	ctx.lightMetaFast = lightMetaFactory.fast
	function ctx.beginBlockLight()
		LightBuffer.ResetScratch( lightSamples )
		LightBuffer.ResetCopyMap( lightCopies )
	end
	ctx.flushSectionBuffers = flushSectionBuffers
	function ctx.discardSectionBuffers()
		for index, buffers in pairs( sectionBuffers ) do
			destroySectionMeshList( buffers.opaque.list )
			destroySectionMeshList( buffers.translucent.list )
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
