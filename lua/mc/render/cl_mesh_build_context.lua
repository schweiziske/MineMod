-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local mathFloor = math.floor
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
local ensureChunkRenderSectionIndex = RM.ensureChunkRenderSectionIndex
local ensureChunkRenderSectionBlockList = RM.ensureChunkRenderSectionBlockList

local function makeLightMeta( shade, shadeIndex, bx, by, bz, id, faceIndex, li, cx, cy, cz, selfEmission, faceCubic, quadLightEmission, tintCode )
	return {
		shade = shade,
		shadeIndex = shadeIndex,
		bx = bx,
		by = by,
		bz = bz,
		id = id,
		faceIndex = faceIndex,
		li = li,
		cx = cx,
		cy = cy,
		cz = cz,
		selfEmission = selfEmission,
		quadLightEmission = clampLightLevel( quadLightEmission ),
		tintCode = tintCode or 0,
		faceCubic = faceCubic ~= false,
	}
end

local function newLightMetaFactory( localIndexForBlockCoords )
	local function fromCorner( shade, bx, by, bz, id, faceIndex, corner, selfEmission, unusedQuad, faceCubic, quadLightEmission, tintCode )
		local cx, cy, cz = cornerXYZ( corner )
		if faceCubic == nil then
			faceCubic = not unusedQuad or unusedQuad.faceCubic ~= false
		end
		return makeLightMeta(
			shade,
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
			quadLightEmission,
			tintCode
		)
	end

	local function fromValues( shade, bx, by, bz, id, faceIndex, cx, cy, cz, selfEmission, unusedQuad, faceCubic, quadLightEmission, tintCode )
		if faceCubic == nil then
			faceCubic = not unusedQuad or unusedQuad.faceCubic ~= false
		end
		return makeLightMeta(
			shade,
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
			quadLightEmission,
			tintCode
		)
	end

	local function fast( shadeIndex, bx, by, bz, id, faceIndex, li, cx, cy, cz, selfEmission, faceCubic, quadLightEmission, tintCode )
		return makeLightMeta(
			nil,
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
			quadLightEmission,
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

function RM.NewBuildContext( key, sectionIndex, chunk, meshPerf, meshProbe, meshLightStyle, buildStart, meshLightProfile )
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
	if not chunk.stateStorageMigrated and MC.MigrateChunkStateStorage then MC.MigrateChunkStateStorage( chunk ) end
	local chunkStateSections = chunk.stateSections or {}
	local StateSection = MC.StateSection
	local getStateFast = StateSection and ( StateSection.GetFast or StateSection.Get )
	local blocksById = MC.Blocks
	local blockIsFullCube = MC.BlockIsFullCube
	local getBlockState = MC.GetBlockState
	local blockTypeForState = MC.BlockTypeForState
	local resolveBlockStateVisual = MC.ResolveBlockStateVisual
	local resolveBlockStateRenderClass = MC.ResolveBlockStateRenderClass
	local blockVisualIsTranslucent = MC.BlockVisualIsTranslucent
	local blockVisualIsFullCube = MC.BlockVisualIsFullCube
	local blockVisualBoxes = MC.BlockVisualBoxes
	local isPaneBlock = MC.IsPaneBlock
	local blockBoxes = MC.BlockBoxes
	local blockUsesSpecialVisualEmitter = MC.BlockUsesSpecialVisualEmitter

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
	local lightMetaFactory = newLightMetaFactory( localIndexForBlockCoords )

	local function inCurrentChunk( lx, ly, lz )
		return lx >= 0 and lx < C.CS and ly >= 0 and ly < C.CS and lz >= 0 and lz < C.CH
	end

	local function stateAt( lx, ly, lz, bx, by, bz )
		if inCurrentChunk( lx, ly, lz ) then
			local li = localIndex( lx, ly, lz )
			local stateSection = chunkStateSections[mathFloor( li / 4096 ) + 1]
			return stateSection and getStateFast and getStateFast( stateSection, li % 4096 ) or 0
		end
		return getBlockState and getBlockState( bx, by, bz ) or 0
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

	local function visibleAt( curId, lx, ly, lz, bx, by, bz )
		local nbState = stateAt( lx, ly, lz, bx, by, bz )
		if not nbState or nbState == 0 then return true end
		local nb, fullCube, translucent
		if resolveBlockStateRenderClass then
			nb, fullCube, translucent = resolveBlockStateRenderClass( nbState, bx, by, bz )
		end
		local nbVisual
		if not nb then
			nbVisual = resolveBlockStateVisual and resolveBlockStateVisual( nbState, bx, by, bz ) or nil
			nb = nbVisual and nbVisual.id or blockTypeForState and blockTypeForState( nbState ) or 0
		end
		if nb == 0 then return true end
		if blockUsesSpecialVisualEmitter and blockUsesSpecialVisualEmitter( nb ) then return true end
		if sameLiquidKind( curId, nb ) then return false end
		local d = blocksById[nb]
		if translucent == nil then
			nbVisual = nbVisual or resolveBlockStateVisual and resolveBlockStateVisual( nbState, bx, by, bz ) or nil
			translucent = nbVisual and blockVisualIsTranslucent and blockVisualIsTranslucent( nbVisual, bx, by, bz )
		end
		if translucent or d and d.transparent then return nb ~= curId end
		if fullCube ~= nil then
			if not fullCube then return true end
		elseif nbVisual and blockVisualIsFullCube then
			if not blockVisualIsFullCube( nbVisual, bx, by, bz ) then return true end
		elseif blockIsFullCube and not blockIsFullCube( nb, orientAt( lx, ly, lz, bx, by, bz ) ) then
			return true
		end
		return false
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
		local nbState = stateAt( nlx, nly, nlz, nbx, nby, nbz )
		if not nbState or nbState == 0 then return false end
		local nb, fullCube, translucent
		if resolveBlockStateRenderClass then
			nb, fullCube, translucent = resolveBlockStateRenderClass( nbState, nbx, nby, nbz )
		end
		local nbVisual
		if not nb then
			nbVisual = resolveBlockStateVisual and resolveBlockStateVisual( nbState, nbx, nby, nbz ) or nil
			nb = nbVisual and nbVisual.id or blockTypeForState and blockTypeForState( nbState ) or 0
		end
		if nb == 0 then return false end
		if blockUsesSpecialVisualEmitter and blockUsesSpecialVisualEmitter( nb ) then return false end
		if sameLiquidKind( curId, nb ) then return true end
		local d = blocksById[nb]
		if translucent == nil then
			nbVisual = nbVisual or resolveBlockStateVisual and resolveBlockStateVisual( nbState, nbx, nby, nbz ) or nil
			translucent = nbVisual and blockVisualIsTranslucent and blockVisualIsTranslucent( nbVisual, nbx, nby, nbz )
		end
		if ( translucent or d and d.transparent ) and not ( isPaneBlock and isPaneBlock( nb ) ) then return false end
		if fullCube == true then return true end
		nbVisual = nbVisual or resolveBlockStateVisual and resolveBlockStateVisual( nbState, nbx, nby, nbz ) or nil
		if fullCube == nil and nbVisual and blockVisualIsFullCube and blockVisualIsFullCube( nbVisual, nbx, nby, nbz ) then return true end
		local nbOrient = nbVisual and nbVisual.renderOrient or orientAt( nlx, nly, nlz, nbx, nby, nbz )
		if not nbVisual and blockIsFullCube and blockIsFullCube( nb, nbOrient ) then return true end
		local nbBoxes = nbVisual and blockVisualBoxes and blockVisualBoxes( nbVisual, nbx, nby, nbz )
			or blockBoxes and blockBoxes( nb, nbOrient, nbx, nby, nbz ) or nil
		return coveredByBoxes( box, faceIndex, nbBoxes, off[1], off[2], off[3] )
	end

	local function shapeFaceCoveredAt( curId, box, faceIndex, boxes, bx, by, bz, lx, ly, lz )
		if boxes and #boxes > 1 and coveredByBoxes( box, faceIndex, boxes, 0, 0, 0 ) then return true end
		return shapeFaceNeighborCoveredAt( curId, box, faceIndex, bx, by, bz, lx, ly, lz )
	end

	local function newMeshBuffer( material, translucent )
		return { list = {}, records = {}, verts = {}, light = {}, nv = 0, hasSecondaryUV = false, material = material, translucent = translucent == true }
	end

	local function newBlockCacheBuffer( targetBuffer )
		return { verts = {}, light = {}, nv = 0, hasSecondaryUV = false, material = targetBuffer.material, translucent = targetBuffer.translucent == true, cacheOnly = true }
	end

	local function prepareBlockCacheBuffer( targetBuffer )
		cur = newBlockCacheBuffer( targetBuffer )
		return true
	end

	local function buildLightIndexByLi( light, vertexCount )
		local byLi = {}
		for i = 1, vertexCount do
			local meta = light[i]
			local li = meta and meta.li
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
		}
		meshPerf.vertices = meshPerf.vertices + vertexCount
		meshPerf.faces = meshPerf.faces + math.floor( vertexCount / 6 )
		meshPerf.meshes = meshPerf.meshes + 1
		if buf.translucent then
			meshPerf.translucentVerts = meshPerf.translucentVerts + vertexCount
		else
			meshPerf.opaqueVerts = meshPerf.opaqueVerts + vertexCount
		end
		buf.verts = {}
		buf.light = {}
		buf.nv = 0
		buf.hasSecondaryUV = false
	end

	local function push( vert, light )
		local nv = cur.nv + 1
		cur.nv = nv
		cur.verts[nv] = vert
		cur.light[nv] = light
		if vert and ( vert.u1 ~= nil or vert.v1 ~= nil ) then cur.hasSecondaryUV = true end
		if not cur.cacheOnly then
			meshPerf.pushedVertices = ( meshPerf.pushedVertices or 0 ) + 1
			if nv >= C.VERT_LIMIT then flush( cur ) end
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

	local blockIter
	if sectionIndex then
		local indexStart = SysTime()
		blockIter = ensureChunkRenderSectionBlockList and ensureChunkRenderSectionBlockList( chunk, sectionIndex ) or nil
		if not blockIter then
			local bySection = ensureChunkRenderSectionIndex( chunk )
			blockIter = bySection and bySection[sectionIndex] or {}
		end
		meshPerfAdd( meshPerf, "indexMS", indexStart )
	else
		blockIter = {}
		for stateSectionIndex = 1, 2 do
			local stateSection = chunk.stateSections and chunk.stateSections[stateSectionIndex]
			if stateSection and MC.StateSection and MC.StateSection.ForEach then
				MC.StateSection.ForEach( stateSection, function( sectionLocalIndex, stateId )
					if stateId ~= 0 then
						local li = ( stateSectionIndex - 1 ) * 4096 + sectionLocalIndex
						blockIter[li] = stateId
					end
				end )
			end
		end
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
		blockIter = blockIter,
		sectionBuffers = sectionBuffers,
		fluidCornerHeightCache = {},
		C = C,
	}

	ctx.styleForBuffer = styleForBuffer
	ctx.currentEmitLightStyle = currentEmitLightStyle
	ctx.localIndex = localIndex
	ctx.stateAt = stateAt
	ctx.orientAt = orientAt
	ctx.visibleAt = visibleAt
	ctx.shapeFaceCoveredAt = shapeFaceCoveredAt
	ctx.shapeFaceNeighborCoveredAt = shapeFaceNeighborCoveredAt
	ctx.buffersForLocal = buffersForLocal
	ctx.flush = flush
	ctx.push = push
	ctx.lightMetaFactory = lightMetaFactory
	ctx.lightMeta = lightMetaFactory.fromCorner
	ctx.lightMetaValues = lightMetaFactory.fromValues
	ctx.lightMetaFast = lightMetaFactory.fast
	ctx.flushSectionBuffers = flushSectionBuffers
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
