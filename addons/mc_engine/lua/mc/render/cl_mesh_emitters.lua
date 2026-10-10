-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local bit_band, bit_lshift = bit.band, bit.lshift
local meshDebugFullCubeOnly = RM.meshDebugFullCubeOnly
local shouldStoreBlockEmissionCache = RM.shouldStoreBlockEmissionCache
local meshPerfAdd = RM.meshPerfAdd
local meshPerfElapsedMS = RM.meshPerfElapsedMS
local meshPerfAddBlockKind = RM.meshPerfAddBlockKind
local meshPerfAddKindDuration = RM.meshPerfAddKindDuration
local isLiquidBlock = RM.isLiquidBlock
local sameLiquidKind = RM.sameLiquidKind
local rotatedModelQuads = RM.rotatedModelQuads
local rotatedUVFlags = RM.rotatedUVFlags
local tileUVRect = RM.tileUVRect
local tileUVPointRaw = RM.tileUVPointRaw
local bakedFaceData = RM.bakedFaceData
local boxFaceCornerValues = RM.boxFaceCornerValues
local cornerUV16Raw = RM.cornerUV16Raw
local coveredByBoxes = RM.coveredByBoxes
local connectionShapeFaceValues = RM.connectionShapeFaceValues
local dynamicShapeFaceData = RM.dynamicShapeFaceData
local BOX_UV_FLAGS = RM.BOX_UV_FLAGS
local EPS = RM.EPS or 0.0001
local fullCubeFaceCornerColors = RM.fullCubeFaceCornerColors
local quadCornerColors = RM.quadCornerColors
local quadCornerColorValues = RM.quadCornerColorValues
local shadeIndexForFace = RM.shadeIndexForFace
local cornerXYZ = RM.cornerXYZ
local quadFaceCubic = RM.quadFaceCubic
local blockModelSurface = MC.BlockModelSurface
local modelQuadVertex = MC.ModelQuadVertex
local resolveBlockStateVisual = MC.ResolveBlockStateVisual
local stateVisualPlanRangeFast = MC.StateVisualPlanRangeFast
local stateVisualPlanModelAtFast = MC.StateVisualPlanModelAtFast
local stateVisualModelData = MC.StateVisualModelData
local blockStateTintCode = MC.BlockStateTintCode
local fluidGeometryAt = RM.FluidGeometryAt
local liquidFlowAtCell = MC.LiquidFlowAtCell
local isWaterloggedState = MC.IsWaterloggedState
local recolorCachedBlockEmission = RM.recolorCachedBlockEmission
local BS = C.BS
local LiquidFlowTiles = {
	water = MC.Tiles and MC.Tiles.water_flow or nil,
	lava = MC.Tiles and MC.Tiles.lava_flow or nil,
}
local LiquidStillTiles = {
	water = MC.Tiles and MC.Tiles.water_still or nil,
	lava = MC.Tiles and MC.Tiles.lava_still or nil,
}

local ShapeModelTemplateCache = {
	model = {},
	shape = {},
	connection = {},
}
local GeneratedModelTemplateCache = {}
local GeneratedCullPlans = {}
local GeneratedCullVisualRevision, GeneratedCullAtlasRevision
local FullCubeTemplateCache = {}
local FullCubeVisualRevision, FullCubeAtlasRevision
local SpecialBlockVisualEmitters = {}

local function specialEmitterForBlock( block )
	if not block then return nil end
	return SpecialBlockVisualEmitters[block.mcid] or SpecialBlockVisualEmitters[block.name]
end

function MC.RegisterSpecialBlockVisualEmitter( blockName, emitter )
	if type( emitter ) ~= "function" then return nil, "invalid_special_visual_emitter" end
	blockName = string.lower( string.match( tostring( blockName or "" ), "^%s*(.-)%s*$" ) )
	if blockName == "" then return nil, "invalid_special_visual_block" end
	SpecialBlockVisualEmitters[blockName] = emitter
	if string.sub( blockName, 1, 10 ) == "minecraft:" then
		SpecialBlockVisualEmitters[string.sub( blockName, 11 )] = emitter
	end
	return emitter
end

function MC.BlockUsesSpecialVisualEmitter( block )
	if type( block ) ~= "table" then block = MC.Blocks and MC.Blocks[block] or nil end
	return specialEmitterForBlock( block ) ~= nil
end

local function stateFace( ctx, id, face, orient, bx, by, bz )
	local stateId = ctx and ctx.currentStateId
	if stateId and ctx.currentVisual and MC.BlockVisualFace then return MC.BlockVisualFace( ctx.currentVisual, face, bx, by, bz ) end
	return MC.BlockFace( id, face, orient )
end

local function atlasPageForTile( tile )
	if MC.ResolveAtlasSurface then
		local page = MC.ResolveAtlasSurface( tile )
		return page
	end
	return 0
end

local function liquidFace( id, face, orient )
	-- Waterlogged overlays keep the host state in ctx, so resolving through
	-- stateFace would accidentally put fence/slab textures on the water mesh.
	return MC.BlockFace( id, face, orient )
end

local function stateBoxes( ctx, id, orient, bx, by, bz )
	local stateId = ctx and ctx.currentStateId
	if stateId and ctx.currentVisual and MC.BlockVisualBoxes then return MC.BlockVisualBoxes( ctx.currentVisual, bx, by, bz ) end
	return MC.BlockBoxes and MC.BlockBoxes( id, orient, bx, by, bz ) or nil
end

local function stateEmission( ctx, id, bx, by, bz )
	local stateId = ctx and ctx.currentStateId
	if stateId and ctx.currentVisual and MC.BlockVisualLightEmission then return MC.BlockVisualLightEmission( ctx.currentVisual, bx, by, bz ) end
	return MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
end

local function stateFullCube( ctx, id, orient, bx, by, bz )
	local stateId = ctx and ctx.currentStateId
	if stateId and ctx.currentVisual and MC.BlockVisualIsFullCube then return MC.BlockVisualIsFullCube( ctx.currentVisual, bx, by, bz ) end
	return MC.BlockIsFullCube and MC.BlockIsFullCube( id, orient ) == true or false
end

local function stateTranslucent( ctx, id, bx, by, bz )
	local stateId = ctx and ctx.currentStateId
	if stateId and ctx.currentVisual and MC.BlockVisualIsTranslucent then return MC.BlockVisualIsTranslucent( ctx.currentVisual, bx, by, bz ) end
	return MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) == true or false
end

function RM.resetShapeModelTemplateCache()
	ShapeModelTemplateCache = {
		model = {},
		shape = {},
		connection = {},
	}
	GeneratedModelTemplateCache = {}
	GeneratedCullPlans = {}
	FullCubeTemplateCache = {}
end

local function templateBucket( store, id )
	local bucket = store[id]
	if not bucket then
		bucket = {}
		store[id] = bucket
	end
	return bucket
end

local function connectionKindForBlock( b, id )
	if not b then return nil end
	local connection = b.connection
	if connection == "fence" then return "fence" end
	if connection == "pane" or connection == "bars" then return "pane" end
	if connection == "wall" then return "wall" end
	if connection == "pipe6" then return "pipe6" end
	if MC.IsFenceBlock and MC.IsFenceBlock( id ) then return "fence" end
	if MC.IsPaneBlock and MC.IsPaneBlock( id ) then return "pane" end
	if MC.IsWallBlock and MC.IsWallBlock( id ) then return "wall" end
	return nil
end

local setTemplateTriVertex

local function isUnitCubeFace( quad, face )
	local mask = 0
	for vertex = 1, 4 do
		local x, y, z = modelQuadVertex( quad, vertex )
		for corner = 1, 4 do
			local c = face.c[corner]
			if x == c[1] and y == c[2] and z == c[3] then
				mask = bit.bor( mask, bit_lshift( 1, corner - 1 ) )
				break
			end
		end
	end
	return mask == 15
end

local function buildModelTemplate( b, orient, cubicBlockId )
	local quads = rotatedModelQuads( b, orient )
	if not quads then return false end

	local mirrorU = b.orient == "door"
	local tri = C.TRI
	local out = { n = 0, allFacesCubic = true }
	local cubeFaceMask, unitCubeFaces = 0, true
	for qi = 1, #quads do
		local quad = quads[qi]
		local verts = quad and quad.verts
		if verts and verts[1] then
			local faceIndex = quad.face or MC.Face.TOP
			local face = C.FACES[faceIndex] or C.FACES[MC.Face.TOP]
			local tile, quadLightEmission = blockModelSurface( b, quad )
			local u0, v0, u1, v1 = tileUVRect( tile, quad.uv )
			local c1x, c1y, c1z = modelQuadVertex( quad, 1 )
			local c2x, c2y, c2z = modelQuadVertex( quad, 2 )
			local c3x, c3y, c3z = modelQuadVertex( quad, 3 )
			local c4x, c4y, c4z = modelQuadVertex( quad, 4 )
			local rec = {
				sourceQuad = qi,
				atlasPage = atlasPageForTile( tile ),
				faceIndex = faceIndex,
				tintIndex = quad.tintIndex or -1,
				normal = face.n,
				shade = face.sh,
				quadLightEmission = quadLightEmission,
				faceCubic = quadFaceCubic( faceIndex, cubicBlockId, orient, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z ),
				c1x = c1x, c1y = c1y, c1z = c1z,
				c2x = c2x, c2y = c2y, c2z = c2z,
				c3x = c3x, c3y = c3y, c3z = c3z,
				c4x = c4x, c4y = c4y, c4z = c4z,
			}
			for t = 1, 6 do
				local ci = tri[t]
				local vx, vy, vz, vu, vv = modelQuadVertex( quad, ci )
				local uf, vf = rotatedUVFlags( vu, vv, quad.rot or 0 )
				if mirrorU then uf = 1 - uf end
				setTemplateTriVertex( rec, t, ci, vx, vy, vz, uf == 1 and u1 or u0, vf == 1 and v1 or v0 )
			end
			local n = out.n + 1
			if not rec.faceCubic then out.allFacesCubic = false end
			if not isUnitCubeFace( quad, face ) then unitCubeFaces = false end
			cubeFaceMask = bit.bor( cubeFaceMask, bit_lshift( 1, faceIndex - 1 ) )
			out.n = n
			out[n] = rec
		end
	end
	out.sixCubeFaces = out.n == 6 and unitCubeFaces and cubeFaceMask == 63
	return out
end

local function getModelTemplate( b, orient, stateId )
	local bucket = templateBucket( ShapeModelTemplateCache.model, b.id )
	local cacheKey = stateId or orient
	local cached = bucket[cacheKey]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildModelTemplate( b, orient, b.id )
	bucket[cacheKey] = cached or false
	return cached ~= false and cached or nil
end

local function getGeneratedModelTemplate( modelData )
	local cached = GeneratedModelTemplateCache[modelData]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildModelTemplate( modelData, 0, nil )
	GeneratedModelTemplateCache[modelData] = cached or false
	return cached ~= false and cached or nil
end

-- Validate every weighted/multipart alternative once at the build boundary.
-- A solid collision box alone cannot prove that a model has no interior quads.
function RM.PrepareGeneratedPlanCulling( snapshots, sectionIndex )
	if GeneratedCullVisualRevision ~= MC.BlockStateVisualRevision or GeneratedCullAtlasRevision ~= MC.AtlasProfileRevision then
		GeneratedCullPlans = {}
		GeneratedModelTemplateCache = {}
		GeneratedCullVisualRevision, GeneratedCullAtlasRevision = MC.BlockStateVisualRevision, MC.AtlasProfileRevision
	end
	local visit = MC.VisitStateVisualModelCandidates
	if not visit then return GeneratedCullPlans end -- No generated catalog in legacy-only clients.
	for index = sectionIndex or 1, sectionIndex or #snapshots do
		local snapshot = snapshots[index]
		-- Native-only sections keep their voxel arrays in the worker world.
		for i = 1, snapshot.nativeOnly and 0 or snapshot.count do
			local stateId = snapshot.states[i]
			if GeneratedCullPlans[stateId] == nil then
				local allCubic, found = true, false
				visit( stateId, function( modelId )
					local model = stateVisualModelData( modelId )
					local template = model and getGeneratedModelTemplate( model )
					found = true
					if not template or not template.allFacesCubic then allCubic = false end
				end )
				GeneratedCullPlans[stateId] = found and allCubic
			end
		end
	end
	return GeneratedCullPlans
end

local function shapeCornerValuesByIndex( ci, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z )
	if ci == 1 then return c1x, c1y, c1z end
	if ci == 2 then return c2x, c2y, c2z end
	if ci == 3 then return c3x, c3y, c3z end
	return c4x, c4y, c4z
end

function setTemplateTriVertex( rec, t, ci, x, y, z, u, v )
	if ci == 1 then
		rec.u1, rec.v1 = u, v
	elseif ci == 2 then
		rec.u2, rec.v2 = u, v
	elseif ci == 3 then
		rec.u3, rec.v3 = u, v
	else
		rec.u4, rec.v4 = u, v
	end
	if t == 1 then
		rec.t1ci, rec.t1x, rec.t1y, rec.t1z, rec.t1u, rec.t1v = ci, x, y, z, u, v
	elseif t == 2 then
		rec.t2ci, rec.t2x, rec.t2y, rec.t2z, rec.t2u, rec.t2v = ci, x, y, z, u, v
	elseif t == 3 then
		rec.t3ci, rec.t3x, rec.t3y, rec.t3z, rec.t3u, rec.t3v = ci, x, y, z, u, v
	elseif t == 4 then
		rec.t4ci, rec.t4x, rec.t4y, rec.t4z, rec.t4u, rec.t4v = ci, x, y, z, u, v
	elseif t == 5 then
		rec.t5ci, rec.t5x, rec.t5y, rec.t5z, rec.t5u, rec.t5v = ci, x, y, z, u, v
	else
		rec.t6ci, rec.t6x, rec.t6y, rec.t6z, rec.t6u, rec.t6v = ci, x, y, z, u, v
	end
end

local function buildShapeTemplate( ctx, b, id, orient, blockBoxes, resolvedBoxes )
	if not blockBoxes and not MC.BlockBoxesForState then return false end
	local boxes = resolvedBoxes or stateBoxes( ctx, id, orient )
	if not boxes then return false end

	local modelFaces = b and b.boxFaces
	if resolvedBoxes and b.shape == "stairs" then modelFaces = nil end
	local tri = C.TRI
	local out = { boxes = boxes, n = 0 }
	for boxIndex = 1, #boxes do
		local box = boxes[boxIndex]
		local boxFaces = modelFaces and modelFaces[boxIndex] or nil
		for f = 1, 6 do
			local fd = boxFaces and boxFaces[f] or nil
			if not modelFaces or fd then
				local face = C.FACES[f]
				local tile, quadLightEmission
				if fd then
					tile, quadLightEmission = blockModelSurface( b, fd )
				else
					tile, quadLightEmission = stateFace( ctx, id, f, orient ), 0
				end
				local u0, v0, u1, v1
				if fd and fd.uv then
					u0, v0, u1, v1 = tileUVRect( tile, fd.uv )
				end
				local c1x, c1y, c1z = boxFaceCornerValues( box, f, 1 )
				local c2x, c2y, c2z = boxFaceCornerValues( box, f, 2 )
				local c3x, c3y, c3z = boxFaceCornerValues( box, f, 3 )
				local c4x, c4y, c4z = boxFaceCornerValues( box, f, 4 )
				local rec = {
					box = box,
					atlasPage = atlasPageForTile( tile ),
					faceIndex = f,
					normal = face.n,
					shade = face.sh,
					quadLightEmission = quadLightEmission,
					faceCubic = quadFaceCubic( f, id, orient, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z ),
					c1x = c1x, c1y = c1y, c1z = c1z,
					c2x = c2x, c2y = c2y, c2z = c2z,
					c3x = c3x, c3y = c3y, c3z = c3z,
					c4x = c4x, c4y = c4y, c4z = c4z,
				}
				for t = 1, 6 do
					local ci = tri[t]
					local cx, cy, cz = shapeCornerValuesByIndex( ci, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z )
					local u, v
					if fd and fd.uv then
						local flags = BOX_UV_FLAGS[ci]
						local uf, vf = rotatedUVFlags( flags[1], flags[2], fd.rot or 0 )
						u, v = uf == 1 and u1 or u0, vf == 1 and v1 or v0
					else
						local cu, cv = cornerUV16Raw( f, cx, cy, cz )
						u, v = tileUVPointRaw( tile, cu, cv )
					end
					setTemplateTriVertex( rec, t, ci, cx, cy, cz, u, v )
				end
				local n = out.n + 1
				out.n = n
				out[n] = rec
			end
		end
	end
	return out
end

local function getShapeTemplate( ctx, b, id, orient, blockBoxes )
	local bucket = templateBucket( ShapeModelTemplateCache.shape, id )
	local cacheKey = ctx.currentStateId or orient
	local cached = bucket[cacheKey]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildShapeTemplate( ctx, b, id, orient, blockBoxes )
	bucket[cacheKey] = cached or false
	return cached ~= false and cached or nil
end

local function faceMetaValues( lightMetaFast, shadeIndex, bx, by, bz, id, faceIndex, li, emission, faceCubic, quadLightEmission,
	c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z, tintCode, lightingKind, modelId, sourceQuad )
	lightingKind = lightingKind or MC.RenderLightBuffer.KIND.BOX
	local meta1 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c1x, c1y, c1z, emission, faceCubic, quadLightEmission, tintCode, lightingKind, modelId, sourceQuad, 1 )
	local meta2 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c2x, c2y, c2z, emission, faceCubic, quadLightEmission, tintCode, lightingKind, modelId, sourceQuad, 2 )
	local meta3 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c3x, c3y, c3z, emission, faceCubic, quadLightEmission, tintCode, lightingKind, modelId, sourceQuad, 3 )
	local meta4 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c4x, c4y, c4z, emission, faceCubic, quadLightEmission, tintCode, lightingKind, modelId, sourceQuad, 4 )
	return meta1, meta2, meta3, meta4
end

local function pushFaceQuad( push, normal,
	x1, y1, z1, u1, v1, color1, meta1,
	x2, y2, z2, u2, v2, color2, meta2,
	x3, y3, z3, u3, v3, color3, meta3,
	x4, y4, z4, u4, v4, color4, meta4,
	meshProbe, meshPerf )
	local vertexStart = meshProbe and SysTime() or nil
	if meshProbe then
		meshPerfAdd( meshPerf, "fullVertexMS", vertexStart )
		local pushStart = SysTime()
		push( x1, y1, z1, normal, u1, v1, color1, meta1 )
		push( x3, y3, z3, normal, u3, v3, color3, meta3 )
		push( x2, y2, z2, normal, u2, v2, color2, meta2 )
		push( x1, y1, z1, normal, u1, v1, color1, meta1 )
		push( x4, y4, z4, normal, u4, v4, color4, meta4 )
		push( x3, y3, z3, normal, u3, v3, color3, meta3 )
		meshPerfAdd( meshPerf, "fullPushMS", pushStart )
		return
	end
	push( x1, y1, z1, normal, u1, v1, color1, meta1 )
	push( x3, y3, z3, normal, u3, v3, color3, meta3 )
	push( x2, y2, z2, normal, u2, v2, color2, meta2 )
	push( x1, y1, z1, normal, u1, v1, color1, meta1 )
	push( x4, y4, z4, normal, u4, v4, color4, meta4 )
	push( x3, y3, z3, normal, u3, v3, color3, meta3 )
end

local function pushTemplateFace( push, quad, wx, wy, wz, color1, color2, color3, color4, meta1, meta2, meta3, meta4 )
	pushFaceQuad(
		push, quad.normal,
		wx + quad.c1x * BS, wy + quad.c1y * BS, wz + quad.c1z * BS, quad.u1, quad.v1, color1, meta1,
		wx + quad.c2x * BS, wy + quad.c2y * BS, wz + quad.c2z * BS, quad.u2, quad.v2, color2, meta2,
		wx + quad.c3x * BS, wy + quad.c3y * BS, wz + quad.c3z * BS, quad.u3, quad.v3, color3, meta3,
		wx + quad.c4x * BS, wy + quad.c4y * BS, wz + quad.c4z * BS, quad.u4, quad.v4, color4, meta4
	)
end

local function shapeFaceUVs( fd, explicitUV, faceIndex, tile, u0, v0, u1, v1,
	c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
	)
	if explicitUV then
		local eu0, ev0, eu1, ev1 = tileUVRect( tile, explicitUV )
		local f1, f2, f3, f4 = BOX_UV_FLAGS[1], BOX_UV_FLAGS[2], BOX_UV_FLAGS[3], BOX_UV_FLAGS[4]
		return f1[1] == 1 and eu1 or eu0, f1[2] == 1 and ev1 or ev0,
			f2[1] == 1 and eu1 or eu0, f2[2] == 1 and ev1 or ev0,
			f3[1] == 1 and eu1 or eu0, f3[2] == 1 and ev1 or ev0,
			f4[1] == 1 and eu1 or eu0, f4[2] == 1 and ev1 or ev0
	end
	if fd and fd.uv then
		local f1, f2, f3, f4 = BOX_UV_FLAGS[1], BOX_UV_FLAGS[2], BOX_UV_FLAGS[3], BOX_UV_FLAGS[4]
		local r = fd.rot or 0
		local u1f, v1f = rotatedUVFlags( f1[1], f1[2], r )
		local u2f, v2f = rotatedUVFlags( f2[1], f2[2], r )
		local u3f, v3f = rotatedUVFlags( f3[1], f3[2], r )
		local u4f, v4f = rotatedUVFlags( f4[1], f4[2], r )
		return u1f == 1 and u1 or u0, v1f == 1 and v1 or v0,
			u2f == 1 and u1 or u0, v2f == 1 and v1 or v0,
			u3f == 1 and u1 or u0, v3f == 1 and v1 or v0,
			u4f == 1 and u1 or u0, v4f == 1 and v1 or v0
	end
	local cu1, cv1 = cornerUV16Raw( faceIndex, c1x, c1y, c1z )
	local cu2, cv2 = cornerUV16Raw( faceIndex, c2x, c2y, c2z )
	local cu3, cv3 = cornerUV16Raw( faceIndex, c3x, c3y, c3z )
	local cu4, cv4 = cornerUV16Raw( faceIndex, c4x, c4y, c4z )
	local uv1u, uv1v = tileUVPointRaw( tile, cu1, cv1 )
	local uv2u, uv2v = tileUVPointRaw( tile, cu2, cv2 )
	local uv3u, uv3v = tileUVPointRaw( tile, cu3, cv3 )
	local uv4u, uv4v = tileUVPointRaw( tile, cu4, cv4 )
	return uv1u, uv1v, uv2u, uv2v, uv3u, uv3v, uv4u, uv4v
end

local function pushShapeFace( push, wx, wy, wz, nrm, fd, explicitUV, faceIndex, tile, u0, v0, u1, v1,
	c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z,
	color1, color2, color3, color4, meta1, meta2, meta3, meta4 )
	local uv1u, uv1v, uv2u, uv2v, uv3u, uv3v, uv4u, uv4v = shapeFaceUVs(
		fd, explicitUV, faceIndex, tile, u0, v0, u1, v1,
		c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
	)
	pushFaceQuad(
		push, nrm,
		wx + c1x * BS, wy + c1y * BS, wz + c1z * BS, uv1u, uv1v, color1, meta1,
		wx + c2x * BS, wy + c2y * BS, wz + c2z * BS, uv2u, uv2v, color2, meta2,
		wx + c3x * BS, wy + c3y * BS, wz + c3z * BS, uv3u, uv3v, color3, meta3,
		wx + c4x * BS, wy + c4y * BS, wz + c4z * BS, uv4u, uv4v, color4, meta4
	)
end

local CONNECTION_YN, CONNECTION_YP = 1, 2
local CONNECTION_XN, CONNECTION_XP = 4, 8
local CONNECTION_ZN, CONNECTION_ZP = 16, 32

local function connectionBoundaryBit( box, faceIndex )
	if faceIndex == MC.Face.TOP then
		return math.abs( box[6] - 1 ) <= EPS and CONNECTION_ZP or 0
	elseif faceIndex == MC.Face.BOTTOM then
		return math.abs( box[3] ) <= EPS and CONNECTION_ZN or 0
	elseif faceIndex == MC.Face.XP then
		return math.abs( box[4] - 1 ) <= EPS and CONNECTION_XP or 0
	elseif faceIndex == MC.Face.XN then
		return math.abs( box[1] ) <= EPS and CONNECTION_XN or 0
	elseif faceIndex == MC.Face.YP then
		return math.abs( box[5] - 1 ) <= EPS and CONNECTION_YP or 0
	elseif faceIndex == MC.Face.YN then
		return math.abs( box[2] ) <= EPS and CONNECTION_YN or 0
	end
	return 0
end

local function connectionTemplateBucket( kind, id, orient, stateId )
	local kindBucket = ShapeModelTemplateCache.connection[kind]
	if not kindBucket then
		kindBucket = {}
		ShapeModelTemplateCache.connection[kind] = kindBucket
	end
	local idBucket = kindBucket[id]
	if not idBucket then
		idBucket = {}
		kindBucket[id] = idBucket
	end
	local cacheKey = stateId or orient
	local orientBucket = idBucket[cacheKey]
	if not orientBucket then
		orientBucket = {}
		idBucket[cacheKey] = orientBucket
	end
	return orientBucket
end

local function buildConnectionShapeTemplate( ctx, kind, id, orient, b, mask, boxes )
	if not boxes or not connectionShapeFaceValues then return false end
	local out = { boxes = boxes, n = 0 }
	local boxCount = #boxes
	for boxIndex = 1, #boxes do
		local box = boxes[boxIndex]
		for f = 1, 6 do
			local boundaryBit = connectionBoundaryBit( box, f )
			local connectedBoundary = boundaryBit ~= 0 and bit_band( mask, boundaryBit ) ~= 0
			if not connectedBoundary and ( boxCount <= 1 or not coveredByBoxes( box, f, boxes, 0, 0, 0 ) ) then
					local face = C.FACES[f]
					local tile, uv, ok = connectionShapeFaceValues( b, f, box )
					if not ok then tile = stateFace( ctx, id, f, orient ) end
					local c1x, c1y, c1z = boxFaceCornerValues( box, f, 1 )
					local c2x, c2y, c2z = boxFaceCornerValues( box, f, 2 )
					local c3x, c3y, c3z = boxFaceCornerValues( box, f, 3 )
					local c4x, c4y, c4z = boxFaceCornerValues( box, f, 4 )
					local uv1u, uv1v, uv2u, uv2v, uv3u, uv3v, uv4u, uv4v = shapeFaceUVs(
						nil, uv, f, tile, nil, nil, nil, nil,
						c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
					)
					local n = out.n + 1
					out.n = n
					local rec = {
						box = box,
						atlasPage = atlasPageForTile( tile ),
						faceIndex = f,
						normal = face.n,
						shade = face.sh,
						quadLightEmission = 0,
						faceCubic = quadFaceCubic( f, id, orient, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z ),
						neighborCheck = boundaryBit == CONNECTION_ZN or boundaryBit == CONNECTION_ZP,
						c1x = c1x, c1y = c1y, c1z = c1z,
						c2x = c2x, c2y = c2y, c2z = c2z,
						c3x = c3x, c3y = c3y, c3z = c3z,
						c4x = c4x, c4y = c4y, c4z = c4z,
					}
					rec.u1, rec.v1 = uv1u, uv1v
					rec.u2, rec.v2 = uv2u, uv2v
					rec.u3, rec.v3 = uv3u, uv3v
					rec.u4, rec.v4 = uv4u, uv4v
					out[n] = rec
			end
		end
	end
	return out
end

local function getConnectionShapeTemplate( ctx, kind, id, orient, b, mask, boxes )
	local bucket = connectionTemplateBucket( kind, id, orient, ctx.currentStateId )
	local cached = bucket[mask]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildConnectionShapeTemplate( ctx, kind, id, orient, b, mask, boxes )
	bucket[mask] = cached or false
	return cached ~= false and cached or nil
end

local function connectionVisibleTemplateEnabled()
	local cv = MC.MeshConnectionVisibleTemplate
	return cv and cv.GetBool and cv:GetBool() or false
end

local function fullCubeFaceUVs( corners, baked, tile, u0, v0, u1, v1, rot, flipU, flipV )
	local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
	if baked and baked.uvs then
		local buv1, buv2, buv3, buv4 = baked.uvs[1], baked.uvs[2], baked.uvs[3], baked.uvs[4]
		local uv1u, uv1v = tileUVPointRaw( tile, buv1 and buv1[1], buv1 and buv1[2] )
		local uv2u, uv2v = tileUVPointRaw( tile, buv2 and buv2[1], buv2 and buv2[2] )
		local uv3u, uv3v = tileUVPointRaw( tile, buv3 and buv3[1], buv3 and buv3[2] )
		local uv4u, uv4v = tileUVPointRaw( tile, buv4 and buv4[1], buv4 and buv4[2] )
		return uv1u, uv1v, uv2u, uv2v, uv3u, uv3v, uv4u, uv4v
	end
	local uf1, vf1 = rotatedUVFlags( c1[4], c1[5], rot or 0, flipU, flipV )
	local uf2, vf2 = rotatedUVFlags( c2[4], c2[5], rot or 0, flipU, flipV )
	local uf3, vf3 = rotatedUVFlags( c3[4], c3[5], rot or 0, flipU, flipV )
	local uf4, vf4 = rotatedUVFlags( c4[4], c4[5], rot or 0, flipU, flipV )
	return uf1 == 1 and u1 or u0, vf1 == 1 and v1 or v0,
		uf2 == 1 and u1 or u0, vf2 == 1 and v1 or v0,
		uf3 == 1 and u1 or u0, vf3 == 1 and v1 or v0,
		uf4 == 1 and u1 or u0, vf4 == 1 and v1 or v0
end

local function pushFullCubeFace( push, wx, wy, wz, nrm, corners, baked, tile, u0, v0, u1, v1, rot, flipU, flipV,
	color1, color2, color3, color4, meta1, meta2, meta3, meta4, meshProbe, meshPerf )
	local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
	local uv1u, uv1v, uv2u, uv2v, uv3u, uv3v, uv4u, uv4v = fullCubeFaceUVs( corners, baked, tile, u0, v0, u1, v1, rot, flipU, flipV )
	pushFaceQuad(
		push, nrm,
		wx + c1[1] * BS, wy + c1[2] * BS, wz + c1[3] * BS, uv1u, uv1v, color1, meta1,
		wx + c2[1] * BS, wy + c2[2] * BS, wz + c2[3] * BS, uv2u, uv2v, color2, meta2,
		wx + c3[1] * BS, wy + c3[2] * BS, wz + c3[3] * BS, uv3u, uv3v, color3, meta3,
		wx + c4[1] * BS, wy + c4[2] * BS, wz + c4[3] * BS, uv4u, uv4v, color4, meta4,
		meshProbe, meshPerf
	)
end

local function nativeScratch( ctx )
	local quad = ctx.nativeQuadScratch
	if not quad then
		quad = { l2Corners = { {}, {}, {}, {} }, l2UV = { {}, {}, {}, {} }, nativeL2Mutable = true }
		ctx.nativeQuadScratch = quad
	end
	return quad
end

local function fullCubeTemplate( ctx, faceIndex, tile, baked, rot, flipU, flipV, quadEmission )
	local templates = ctx.fullCubeTemplates
	if not templates then
		-- Bind once at this build's first cube. Reloaded definitions/layouts must
		-- invalidate physical UVs even when an importer reused the same table.
		if FullCubeVisualRevision ~= MC.BlockStateVisualRevision or FullCubeAtlasRevision ~= MC.AtlasProfileRevision then
			FullCubeTemplateCache = {}
			FullCubeVisualRevision, FullCubeAtlasRevision = MC.BlockStateVisualRevision, MC.AtlasProfileRevision
		end
		templates = FullCubeTemplateCache
		ctx.fullCubeTemplates = templates
	end
	-- Resolve position-dependent faces before this lookup. Cache the resulting
	-- surface, never a state ID: two placements may choose different tiles/UVs.
	local surfaces = templateBucket( templateBucket( templateBucket( templates, faceIndex ), tile ), quadEmission )
	local key = baked or ( ( rot or 0 ) % 4 * 4 + ( flipU and 1 or 0 ) + ( flipV and 2 or 0 ) )
	local quad = surfaces[key]
	if quad then return quad end
	local face = C.FACES[faceIndex]
	local u0, v0, u1, v1 = tileUVRect( tile, baked and baked.uv )
	local au, av, bu, bv, cu, cv, du, dv = fullCubeFaceUVs( face.c, baked, tile, u0, v0, u1, v1, rot, flipU, flipV )
	local lightingByEmission = face.l2LightingByEmission
	if not lightingByEmission then lightingByEmission = {} face.l2LightingByEmission = lightingByEmission end
	local lighting = lightingByEmission[quadEmission]
	if not lighting then
		lighting = MC.RenderL2Lighting.BakeQuad( faceIndex, face.c, { quadEmission = quadEmission } )
		if not lighting then error( "full cube lighting template preparation failed", 0 ) end
		lightingByEmission[quadEmission] = lighting
	end
	quad = { faceIndex = faceIndex, normal = face.n, shade = face.sh,
		quadLightEmission = quadEmission, atlasPage = atlasPageForTile( tile ),
		l2Corners = face.c, l2UV = { { au, av }, { bu, bv }, { cu, cv }, { du, dv } }, l2Lighting = lighting }
	surfaces[key] = quad
	return quad
end

local function emitNativeValues( ctx, id, bx, by, bz, wx, wy, wz, face, normal, shade, emission, quadEmission, lighting, tile,
	c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z, u1, v1, u2, v2, u3, v3, u4, v4 )
	local quad = nativeScratch( ctx )
	quad.atlasPage = atlasPageForTile( tile )
	local a, b, c, d = quad.l2Corners[1], quad.l2Corners[2], quad.l2Corners[3], quad.l2Corners[4]
	a[1], a[2], a[3], b[1], b[2], b[3] = c1x, c1y, c1z, c2x, c2y, c2z
	c[1], c[2], c[3], d[1], d[2], d[3] = c3x, c3y, c3z, c4x, c4y, c4z
	a, b, c, d = quad.l2UV[1], quad.l2UV[2], quad.l2UV[3], quad.l2UV[4]
	a[1], a[2], b[1], b[2], c[1], c[2], d[1], d[2] = u1, v1, u2, v2, u3, v3, u4, v4
	quad.faceIndex, quad.normal, quad.shade = face, normal, shade
	quad.quadLightEmission, quad.positions, quad.faceCubic = quadEmission, nil, nil
	-- Runtime boxes change with neighbors; never reuse another shape's bake.
	quad.l2Lighting, quad.nativeL2Owner = lighting, lighting
	ctx.emitL2( quad, id, bx, by, bz, wx, wy, wz, emission )
end

local function emitNativeArrays( ctx, id, bx, by, bz, wx, wy, wz, face, normal, shade, emission, kind,
	corners, positions, tile, rawUV, faceCubic )
	local quad = nativeScratch( ctx )
	quad.atlasPage = atlasPageForTile( tile )
	for i = 1, 4 do
		local p, c, uv = corners[i], quad.l2Corners[i], quad.l2UV[i]
		c[1], c[2], c[3] = p[1], p[2], p[3]
		local raw = rawUV and rawUV[i] or p
		local u, v
		if rawUV then u, v = raw[1], raw[2] else u, v = raw[4], raw[5] end
		uv[1], uv[2] = tileUVPointRaw( tile, u, v )
	end
	quad.faceIndex, quad.normal, quad.shade = face, normal, shade
	quad.quadLightEmission, quad.positions, quad.faceCubic = 0, positions, faceCubic
	quad.l2Lighting = nil
	quad.nativeL2Owner = kind ~= MC.RenderLightBuffer.KIND.FLUID and corners or nil
	ctx.emitL2( quad, id, bx, by, bz, wx, wy, wz, emission, 0, kind )
end

local function emitModelBlockTemplate( ctx, template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, currentEmitLightStyle, cullCubicFaces, modelId, visibleFaceMask )
	local emission = stateEmission( ctx, id, bx, by, bz )
	local emitLightStyle = currentEmitLightStyle()
	local lightingKind = modelId and MC.RenderLightBuffer.KIND.GENERATED or MC.RenderLightBuffer.KIND.MODEL
	for qi = 1, template.n do
		local quad = template[qi]
		local f = quad.faceIndex
		local visible = true
		if cullCubicFaces and quad.faceCubic then
			if visibleFaceMask ~= nil then
				visible = bit_band( visibleFaceMask, bit_lshift( 1, f - 1 ) ) ~= 0
			else
				local off = C.FACES[f].off
				visible = ctx.visibleAt( id, lx + off[1], ly + off[2], lz + off[3], bx + off[1], by + off[2], bz + off[3] )
			end
		end
		if visible then
			local tintCode = quad.tintIndex and quad.tintIndex >= 0 and blockStateTintCode
				and blockStateTintCode( ctx.currentStateId, id, quad.tintIndex ) or 0
			if ctx.l2 then
				ctx.emitL2( quad, id, bx, by, bz, wx, wy, wz, emission, tintCode, lightingKind, modelId )
			else
				local color1, color2, color3, color4 = quadCornerColorValues(
					quad.shade, bx, by, bz, id, f, emission, emitLightStyle,
					quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z, tintCode
				)
				local meta1, meta2, meta3, meta4 = faceMetaValues(
					lightMetaFast, shadeIndexForFace( f ), bx, by, bz, id, f, li, emission, quad.faceCubic, quad.quadLightEmission,
					quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z, tintCode,
					lightingKind, modelId, quad.sourceQuad
				)
				pushTemplateFace( push, quad, wx, wy, wz, color1, color2, color3, color4, meta1, meta2, meta3, meta4 )
			end
		end
	end
	return true
end

local function emitShapeBlockTemplate( ctx, template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle )
	local boxes = template.boxes
	local emission = stateEmission( ctx, id, bx, by, bz )
	local emitLightStyle = currentEmitLightStyle()
	for faceI = 1, template.n do
		local quad = template[faceI]
		local f = quad.faceIndex
		local selfCovered = quad.selfCovered
		if selfCovered == nil then
			selfCovered = boxes and #boxes > 1 and coveredByBoxes( quad.box, f, boxes, 0, 0, 0 ) or false
			quad.selfCovered = selfCovered
		end
		if not selfCovered and not shapeFaceNeighborCoveredAt( id, quad.box, f, bx, by, bz, lx, ly, lz ) then
			if ctx.l2 then
				ctx.emitL2( quad, id, bx, by, bz, wx, wy, wz, emission )
			else
				local color1, color2, color3, color4 = quadCornerColorValues(
					quad.shade, bx, by, bz, id, f, emission, emitLightStyle,
					quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z
				)
				local meta1, meta2, meta3, meta4 = faceMetaValues(
					lightMetaFast, shadeIndexForFace( f ), bx, by, bz, id, f, li, emission, quad.faceCubic, quad.quadLightEmission,
					quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z
				)
				pushTemplateFace( push, quad, wx, wy, wz, color1, color2, color3, color4, meta1, meta2, meta3, meta4 )
			end
		end
	end
	return true
end

local function emitConnectionShapeBlockTemplate( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle )
	if not kind then return false end
	local mask = MC.BlockConnectionMask and MC.BlockConnectionMask( kind, bx, by, bz ) or 0
	local boxes = MC.ConnectionBlockBoxes and MC.ConnectionBlockBoxes( kind, mask ) or nil
	if not boxes then
		boxes = ctx.blockBoxes and ctx.blockBoxes( id, orient, bx, by, bz ) or nil
	end
	if not boxes then return false end

	local template = getConnectionShapeTemplate( ctx, kind, id, orient, b, mask, boxes )
	if not template then return false end

	local emission = stateEmission( ctx, id, bx, by, bz )
	local emitLightStyle = currentEmitLightStyle()
	for qi = 1, template.n do
		local quad = template[qi]
		local f = quad.faceIndex
		if not quad.neighborCheck or not shapeFaceNeighborCoveredAt( id, quad.box, f, bx, by, bz, lx, ly, lz ) then
			if ctx.l2 then
				ctx.emitL2( quad, id, bx, by, bz, wx, wy, wz, emission )
			else
				local color1, color2, color3, color4 = quadCornerColorValues(
					quad.shade, bx, by, bz, id, f, emission, emitLightStyle,
					quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z
				)
				local meta1, meta2, meta3, meta4 = faceMetaValues(
					lightMetaFast, shadeIndexForFace( f ), bx, by, bz, id, f, li, emission, quad.faceCubic, quad.quadLightEmission,
					quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z
				)
				pushTemplateFace( push, quad, wx, wy, wz, color1, color2, color3, color4, meta1, meta2, meta3, meta4 )
			end
		end
	end
	return true
end

local function emitConnectionShapeBlockLegacy( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceCoveredAt, currentEmitLightStyle )
	if not kind or not connectionShapeFaceValues then return false end
	local mask = MC.BlockConnectionMask and MC.BlockConnectionMask( kind, bx, by, bz ) or 0
	local boxes = MC.ConnectionBlockBoxes and MC.ConnectionBlockBoxes( kind, mask ) or nil
	if not boxes then
		boxes = ctx.blockBoxes and ctx.blockBoxes( id, orient, bx, by, bz ) or nil
	end
	if not boxes then return false end

	local emission = stateEmission( ctx, id, bx, by, bz )
	local emitLightStyle = currentEmitLightStyle()
	for boxIndex = 1, #boxes do
		local box = boxes[boxIndex]
		for f = 1, 6 do
			if not shapeFaceCoveredAt( id, box, f, boxes, bx, by, bz, lx, ly, lz ) then
				local face = C.FACES[f]
				local tile, uv, ok = connectionShapeFaceValues( b, f, box )
				if not ok then tile = stateFace( ctx, id, f, orient, bx, by, bz ) end
				local c1x, c1y, c1z = boxFaceCornerValues( box, f, 1 )
				local c2x, c2y, c2z = boxFaceCornerValues( box, f, 2 )
				local c3x, c3y, c3z = boxFaceCornerValues( box, f, 3 )
				local c4x, c4y, c4z = boxFaceCornerValues( box, f, 4 )
				local faceCubic = quadFaceCubic( f, id, orient, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z )
				local color1, color2, color3, color4 = quadCornerColorValues(
					face.sh, bx, by, bz, id, f, emission, emitLightStyle,
					c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
				)
				local meta1, meta2, meta3, meta4 = faceMetaValues(
					lightMetaFast, shadeIndexForFace( f ), bx, by, bz, id, f, li, emission, faceCubic, 0,
					c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
				)
				pushShapeFace(
					push, wx, wy, wz, face.n, nil, uv, f, tile, nil, nil, nil, nil,
					c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z,
					color1, color2, color3, color4, meta1, meta2, meta3, meta4
				)
			end
		end
	end
	return true
end

local function emitConnectionShapeBlock( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceCoveredAt, shapeFaceNeighborCoveredAt, currentEmitLightStyle )
	if ( ctx.l2 or connectionVisibleTemplateEnabled() )
		and emitConnectionShapeBlockTemplate( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle ) then
		return true
	end
	if ctx.l2 then return false end -- The caller can emit native box quads.
	return emitConnectionShapeBlockLegacy( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceCoveredAt, currentEmitLightStyle )
end

local CrossPlanes = {
	{ { 0.08, 0.08, 0, 0, 16 }, { 0.92, 0.92, 0, 16, 16 }, { 0.92, 0.92, 1, 16, 0 }, { 0.08, 0.08, 1, 0, 0 } },
	{ { 0.92, 0.08, 0, 0, 16 }, { 0.08, 0.92, 0, 16, 16 }, { 0.08, 0.92, 1, 16, 0 }, { 0.92, 0.08, 1, 0, 0 } },
}
for i = 1, 2 do
	local plane = CrossPlanes[i]
	CrossPlanes[i + 2] = { plane[4], plane[3], plane[2], plane[1] }
end

local function emitCrossQuad( ctx, push, lightMeta, currentEmitLightStyle, corners, normal, color, tile, bx, by, bz, id, faceIndex, wx, wy, wz )
	local emission = stateEmission( ctx, id, bx, by, bz )
	if ctx.l2 then
		return emitNativeArrays( ctx, id, bx, by, bz, wx, wy, wz, faceIndex, normal, color, emission,
			MC.RenderLightBuffer.KIND.CROSS, corners, nil, tile )
	end
	local emitLightStyle = currentEmitLightStyle()
	local color1, color2, color3, color4 = quadCornerColors( color, bx, by, bz, id, faceIndex, corners, emission, emitLightStyle )
	local kind = MC.RenderLightBuffer.KIND.CROSS
	local meta1 = lightMeta( color, bx, by, bz, id, faceIndex, corners[1], emission, nil, nil, 0, 0, kind, 0, 0, 1 )
	local meta2 = lightMeta( color, bx, by, bz, id, faceIndex, corners[2], emission, nil, nil, 0, 0, kind, 0, 0, 2 )
	local meta3 = lightMeta( color, bx, by, bz, id, faceIndex, corners[3], emission, nil, nil, 0, 0, kind, 0, 0, 3 )
	local meta4 = lightMeta( color, bx, by, bz, id, faceIndex, corners[4], emission, nil, nil, 0, 0, kind, 0, 0, 4 )
	local tri = C.TRI
	for t = 1, 6 do
		local ci = tri[t]
		local cn = corners[ci]
		local u, v = tileUVPointRaw( tile, cn[4], cn[5] )
		local vertColor, meta
		if ci == 1 then
			vertColor, meta = color1, meta1
		elseif ci == 2 then
			vertColor, meta = color2, meta2
		elseif ci == 3 then
			vertColor, meta = color3, meta3
		else
			vertColor, meta = color4, meta4
		end
		if ctx and ctx.fluidAnimationColorResolver then
			vertColor = ctx.fluidAnimationColorResolver(
				color, faceIndex, cn, vertColor, bx, by, bz, id
			) or vertColor
		end
		if ctx and ctx.pushValues then
			ctx.pushValues( wx + cn[1] * C.BS, wy + cn[2] * C.BS, wz + cn[3] * C.BS, normal, u, v, vertColor, meta )
		else
			push( {
				pos = Vector( wx + cn[1] * C.BS, wy + cn[2] * C.BS, wz + cn[3] * C.BS ),
				normal = normal, u = u, v = v, color = vertColor,
			}, meta )
		end
	end
end

function RM.EmitCrossBlock( ctx, b, id, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	b = b or MC.Blocks[id]
	local tile = b and b.side or 0
	-- Lighting consumes block ratios; only emitted positions use Source units.
	emitCrossQuad( ctx, push, lightMeta, currentEmitLightStyle, CrossPlanes[1], C.N_YP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.YP, wx, wy, wz )
	emitCrossQuad( ctx, push, lightMeta, currentEmitLightStyle, CrossPlanes[3], C.N_YN, C.SH_TOP, tile, bx, by, bz, id, MC.Face.YN, wx, wy, wz )
	emitCrossQuad( ctx, push, lightMeta, currentEmitLightStyle, CrossPlanes[2], C.N_XP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.XP, wx, wy, wz )
	emitCrossQuad( ctx, push, lightMeta, currentEmitLightStyle, CrossPlanes[4], C.N_XN, C.SH_TOP, tile, bx, by, bz, id, MC.Face.XN, wx, wy, wz )
end

function RM.EmitModelBlock( ctx, b, orient, bx, by, bz, wx, wy, wz, li, push, lightMeta, currentEmitLightStyle )
	local template = getModelTemplate( b, orient, ctx.currentStateId )
	if not template then return false end
	local decode = RM.DecodeLocal or MC.DecodeLocal
	local lx, ly, lz = decode( li )
	return emitModelBlockTemplate( ctx, template, b.id, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, ctx.lightMetaFast, currentEmitLightStyle, false )
end

local function fluidQuadScratch( ctx )
	local scratch = ctx and ctx.fluidQuadScratch
	if not scratch then
		scratch = { verts = { {}, {}, {}, {} }, light = { {}, {}, {}, {} }, uv = { {}, {}, {}, {} } }
		if ctx then ctx.fluidQuadScratch = scratch end
	end
	return scratch
end

local function quadXYZ( corners, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	local a, b, c, d = corners[1], corners[2], corners[3], corners[4]
	a[1], a[2], a[3] = x1, y1, z1
	b[1], b[2], b[3] = x2, y2, z2
	c[1], c[2], c[3] = x3, y3, z3
	d[1], d[2], d[3] = x4, y4, z4
	return corners
end

local function quadUV( corners, u1, v1, u2, v2, u3, v3, u4, v4 )
	local a, b, c, d = corners[1], corners[2], corners[3], corners[4]
	a[1], a[2], b[1], b[2] = u1, v1, u2, v2
	c[1], c[2], d[1], d[2] = u3, v3, u4, v4
	return corners
end

local function sideV( height )
	return math.Clamp( ( 1 - height ) * 16, 0, 16 )
end

local function emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle, verts, normal, shade, tile, bx, by, bz, id, faceIndex, lightCorners, uvCorners, fluidEmission )
	local emission = fluidEmission ~= nil and fluidEmission or stateEmission( ctx, id, bx, by, bz )
	local emitLightStyle = currentEmitLightStyle()
	local x1, y1, z1 = cornerXYZ( lightCorners[1] )
	local x2, y2, z2 = cornerXYZ( lightCorners[2] )
	local x3, y3, z3 = cornerXYZ( lightCorners[3] )
	local x4, y4, z4 = cornerXYZ( lightCorners[4] )
	local faceCubic = quadFaceCubic( faceIndex, id, 0, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	if ctx.l2 then
		return emitNativeArrays( ctx, id, bx, by, bz, 0, 0, 0, faceIndex, normal, shade, emission,
			MC.RenderLightBuffer.KIND.FLUID, lightCorners, verts, tile, uvCorners, faceCubic )
	end
	local color1, color2, color3, color4 = quadCornerColors( shade, bx, by, bz, id, faceIndex, lightCorners, emission, emitLightStyle )
	local kind = MC.RenderLightBuffer.KIND.FLUID
	local meta1 = lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[1], emission, nil, faceCubic, 0, 0, kind, 0, 0, 1 )
	local meta2 = lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[2], emission, nil, faceCubic, 0, 0, kind, 0, 0, 2 )
	local meta3 = lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[3], emission, nil, faceCubic, 0, 0, kind, 0, 0, 3 )
	local meta4 = lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[4], emission, nil, faceCubic, 0, 0, kind, 0, 0, 4 )
	local tri = C.TRI
	for t = 1, 6 do
		local ci = tri[t]
		local vert = verts[ci]
		local uv = uvCorners[ci]
		local rawU, rawV = uv and uv[1], uv and uv[2]
		local u, v, animationName
		if ctx and ctx.fluidAnimationResolver then
			u, v, animationName = ctx.fluidAnimationResolver( tile, faceIndex, rawU, rawV, bx, by, bz, id )
		end
		if u == nil or v == nil then u, v = tileUVPointRaw( tile, rawU, rawV ) end
		local vertColor, meta
		if ci == 1 then
			vertColor, meta = color1, meta1
		elseif ci == 2 then
			vertColor, meta = color2, meta2
		elseif ci == 3 then
			vertColor, meta = color3, meta3
		else
			vertColor, meta = color4, meta4
		end
		if animationName and ctx and ctx.pushFluidValues then
			ctx.pushFluidValues( animationName, vert[1], vert[2], vert[3], normal, u, v, vertColor, meta )
		elseif ctx and ctx.pushValues and not animationName then
			ctx.pushValues( vert[1], vert[2], vert[3], normal, u, v, vertColor, meta )
		else
			push( {
				pos = Vector( vert[1], vert[2], vert[3] ),
				normal = normal, u = u, v = v, color = vertColor,
				fluidAnimation = animationName,
			}, meta )
		end
	end
end

function RM.EmitLiquidBlock( ctx, id, orient, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	local kind = MC.LiquidKind and MC.LiquidKind( id )
	if not kind then return false end
	local fluidEmission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local quad = fluidQuadScratch( ctx )
	local size = ctx.blockSize or MC.API.Coords.BlockSize()

	local x0, y0, z0 = wx, wy, wz
	local x1, y1 = wx + size, wy + size
	local bottom = z0
	if not fluidGeometryAt then return false end
	local h00, h10, h11, h01, renderUp, renderDown, renderXP, renderXN, renderYP, renderYN =
		fluidGeometryAt( ctx.currentStateId, bx, by, bz, kind, ctx.fluidCornerHeightCache )
	local topOffset = renderUp and C.FLUID_FACE_OFFSET or 0
	local rh00 = math.max( h00 - topOffset, 0 )
	local rh10 = math.max( h10 - topOffset, 0 )
	local rh11 = math.max( h11 - topOffset, 0 )
	local rh01 = math.max( h01 - topOffset, 0 )
	local z00, z10, z11, z01 = z0 + rh00 * size, z0 + rh10 * size, z0 + rh11 * size, z0 + rh01 * size
	local tile

	if renderUp then
		tile = LiquidStillTiles[kind] or liquidFace( id, MC.Face.TOP, orient )
		local topUV = quadUV( quad.uv, 0, 16, 16, 16, 16, 0, 0, 0 )
		local flowX, flowY = 0, 0
		if liquidFlowAtCell then flowX, flowY = liquidFlowAtCell( bx, by, bz, kind ) end
		-- Minecraft's flowing sprite is 32x32. The 0.25 rotation radius below
		-- selects its central 16x16 block-sized region without crossing the tile.
		local flowTile = LiquidFlowTiles[kind]
		if flowTile and ( math.abs( flowX ) > 0.000001 or math.abs( flowY ) > 0.000001 ) then
			tile = flowTile
			local angle = math.atan2( flowY, flowX ) - math.pi * 0.5
			local s = math.sin( angle ) * 0.25
			local c = math.cos( angle ) * 0.25
			local u00, v00 = ( 0.5 - c - s ) * 16, ( 0.5 - c + s ) * 16
			local u01, v01 = ( 0.5 - c + s ) * 16, ( 0.5 + c + s ) * 16
			local u10, v10 = ( 0.5 + c + s ) * 16, ( 0.5 + c - s ) * 16
			local u11, v11 = ( 0.5 + c - s ) * 16, ( 0.5 - c - s ) * 16
			-- Keep FluidRenderer's V coordinates intact. Reversing V here makes
			-- the animated sprite visibly travel against the computed flow.
			topUV = quadUV( quad.uv, u00, v00, u11, v11, u10, v10, u01, v01 )
		end
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			quadXYZ( quad.verts, x0, y0, z00, x1, y0, z10, x1, y1, z11, x0, y1, z01 ),
			C.N_UP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.TOP,
			quadXYZ( quad.light, 0, 0, rh00, 1, 0, rh10, 1, 1, rh11, 0, 1, rh01 ),
			topUV, fluidEmission
		)
	end

	local bottomZ = bottom + ( renderDown and C.FLUID_FACE_OFFSET or 0 ) * size
	if renderDown then
		tile = LiquidStillTiles[kind] or liquidFace( id, MC.Face.BOTTOM, orient )
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			quadXYZ( quad.verts, x0, y1, bottomZ, x1, y1, bottomZ, x1, y0, bottomZ, x0, y0, bottomZ ),
			C.N_DOWN, C.SH_BOTTOM, tile, bx, by, bz, id, MC.Face.BOTTOM,
			quadXYZ( quad.light, 0, 1, 0, 1, 1, 0, 1, 0, 0, 0, 0, 0 ),
			quadUV( quad.uv, 0, 16, 16, 16, 16, 0, 0, 0 ), fluidEmission
		)
	end

	-- The registered liquid side is a normal 16x16 atlas tile. Unlike the
	-- dedicated 32x32 flowing top sprite, it must use the whole tile or the
	-- side either magnifies one quadrant or lands on an atlas-only slot that is
	-- not part of the block-face material contract.
	local sideBottomV = 16
	local sideBottom = bottomZ
	local sideInset = C.FLUID_FACE_OFFSET * size

	if renderXP then
		tile = liquidFace( id, MC.Face.XP, orient )
		local sx = x1 - sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			quadXYZ( quad.verts, sx, y0, sideBottom, sx, y1, sideBottom, sx, y1, z11, sx, y0, z10 ),
			C.N_XP, C.SH_X, tile, bx, by, bz, id, MC.Face.XP,
			quadXYZ( quad.light, 1, 0, 0, 1, 1, 0, 1, 1, rh11, 1, 0, rh10 ),
			quadUV( quad.uv, 0, sideBottomV, 16, sideBottomV, 16, sideV( rh11 ), 0, sideV( rh10 ) ), fluidEmission
		)
	end

	if renderXN then
		tile = liquidFace( id, MC.Face.XN, orient )
		local sx = x0 + sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			quadXYZ( quad.verts, sx, y1, sideBottom, sx, y0, sideBottom, sx, y0, z00, sx, y1, z01 ),
			C.N_XN, C.SH_X, tile, bx, by, bz, id, MC.Face.XN,
			quadXYZ( quad.light, 0, 1, 0, 0, 0, 0, 0, 0, rh00, 0, 1, rh01 ),
			quadUV( quad.uv, 0, sideBottomV, 16, sideBottomV, 16, sideV( rh00 ), 0, sideV( rh01 ) ), fluidEmission
		)
	end

	if renderYP then
		tile = liquidFace( id, MC.Face.YP, orient )
		local sy = y1 - sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			quadXYZ( quad.verts, x1, sy, sideBottom, x0, sy, sideBottom, x0, sy, z01, x1, sy, z11 ),
			C.N_YP, C.SH_Y, tile, bx, by, bz, id, MC.Face.YP,
			quadXYZ( quad.light, 1, 1, 0, 0, 1, 0, 0, 1, rh01, 1, 1, rh11 ),
			quadUV( quad.uv, 0, sideBottomV, 16, sideBottomV, 16, sideV( rh01 ), 0, sideV( rh11 ) ), fluidEmission
		)
	end

	if renderYN then
		tile = liquidFace( id, MC.Face.YN, orient )
		local sy = y0 + sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			quadXYZ( quad.verts, x0, sy, sideBottom, x1, sy, sideBottom, x1, sy, z10, x0, sy, z00 ),
			C.N_YN, C.SH_Y, tile, bx, by, bz, id, MC.Face.YN,
			quadXYZ( quad.light, 0, 0, 0, 1, 0, 0, 1, 0, rh10, 0, 0, rh00 ),
			quadUV( quad.uv, 0, sideBottomV, 16, sideBottomV, 16, sideV( rh10 ), 0, sideV( rh00 ) ), fluidEmission
		)
	end

	return true
end

local function decodeLocal( li )
	local fn = RM.DecodeLocal or MC.DecodeLocal
	if fn then return fn( li ) end
	local cs, cs2 = C.CS, C.CS2
	local lz = math.floor( li / cs2 )
	local ly = math.floor( ( li - lz * cs2 ) / cs )
	local lx = li - lz * cs2 - ly * cs
	return lx, ly, lz
end

local BlockEmitters = {}
RM.BlockEmitters = BlockEmitters
local emitFullCubeBlockRecord
local emitLiquidBlockRecord

local function modelUsesConnectionShape( b, id )
	return ( MC.IsFenceBlock and MC.IsFenceBlock( id ) )
		or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) )
		or ( MC.IsWallBlock and MC.IsWallBlock( id ) )
		or ( b and b.connection == "pipe6" )
end

local function selectBaseBlockEmitter( ctx, b, id, orient, blockIsFullCube, bx, by, bz )
	if b and b.shape == "cross" then return BlockEmitters.cross end
	if b and b.shape == "model" and not modelUsesConnectionShape( b, id ) then return BlockEmitters.model end
	if isLiquidBlock( id ) then return BlockEmitters.liquid end
	if stateFullCube( ctx, id, orient, bx, by, bz ) then return BlockEmitters.fullCube end
	return BlockEmitters.shape
end

local function selectBlockEmitter( ctx, b, id, orient, blockIsFullCube, bx, by, bz )
	if specialEmitterForBlock( b ) then return BlockEmitters.special end
	if isLiquidBlock( id ) then return BlockEmitters.liquid end
	if ctx.currentVisual and ctx.currentVisual.generatedVisualOverride then return BlockEmitters.statePlan end
	return selectBaseBlockEmitter( ctx, b, id, orient, blockIsFullCube, bx, by, bz )
end

local function emitShapeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	local blockBoxes = ctx.blockBoxes
	local push = ctx.push
	local lightMetaFast = ctx.lightMetaFast
	local shapeFaceCoveredAt = ctx.shapeFaceCoveredAt
	local shapeFaceNeighborCoveredAt = ctx.shapeFaceNeighborCoveredAt
	local currentEmitLightStyle = ctx.currentEmitLightStyle

	-- fence/pane/wall/pipe boxes come from runtime connection masks, so their
	-- box order does not match generated static boxFaces except for the centre.
	ctx.prepareBlockCacheBuffer( targetBuffer )
	local isPipe6Shape = b and b.connection == "pipe6"
	local isDynamicStairs = b and b.shape == "stairs"
	local connectionKind = connectionKindForBlock( b, id )
	local isConnShape = connectionKind ~= nil
	local template
	if not isConnShape and not isDynamicStairs then
		template = getShapeTemplate( ctx, b, id, orient, blockBoxes )
	end
	if isConnShape and emitConnectionShapeBlock( ctx, connectionKind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceCoveredAt, shapeFaceNeighborCoveredAt, currentEmitLightStyle ) then
		return "shape", false, 0
	end
	if template then
		emitShapeBlockTemplate( ctx, template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle )
		return "shape", false, 0
	end

	local boxes = stateBoxes( ctx, id, orient, bx, by, bz )
	local emission = stateEmission( ctx, id, bx, by, bz )
	for boxIndex, box in ipairs( boxes or {} ) do
		for f = 1, 6 do
			repeat
				if shapeFaceCoveredAt( id, box, f, boxes, bx, by, bz, lx, ly, lz ) then break end
				local face = C.FACES[f]
				local modelFaces = b and b.boxFaces
				if isPipe6Shape or isDynamicStairs then modelFaces = nil end
				local fd = modelFaces and modelFaces[boxIndex] and modelFaces[boxIndex][f]
				if isConnShape and boxIndex > 1 then fd = nil end
				local dynamicFd = dynamicShapeFaceData( b, f, box )
				if modelFaces and not fd and not dynamicFd then break end
				fd = fd or dynamicFd
				local tile, quadLightEmission
				if fd then
					tile, quadLightEmission = blockModelSurface( b, fd )
				else
					tile, quadLightEmission = stateFace( ctx, id, f, orient, bx, by, bz ), 0
				end
				local u0, v0, u1, v1
				if fd and fd.uv then
					u0, v0, u1, v1 = tileUVRect( tile, fd.uv )
				end
				local nrm, col = face.n, face.sh
				local c1x, c1y, c1z = boxFaceCornerValues( box, f, 1 )
				local c2x, c2y, c2z = boxFaceCornerValues( box, f, 2 )
				local c3x, c3y, c3z = boxFaceCornerValues( box, f, 3 )
				local c4x, c4y, c4z = boxFaceCornerValues( box, f, 4 )
				if ctx.l2 then
					emitNativeValues( ctx, id, bx, by, bz, wx, wy, wz, f, nrm, col, emission, quadLightEmission, nil, tile,
						c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z,
						shapeFaceUVs( fd, nil, f, tile, u0, v0, u1, v1,
							c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z ) )
					break
				end
				local emitLightStyle = currentEmitLightStyle()
				local faceCubic = quadFaceCubic( f, id, orient, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z )
				local color1, color2, color3, color4 = quadCornerColorValues(
					col, bx, by, bz, id, f, emission, emitLightStyle,
					c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
				)
				local meta1, meta2, meta3, meta4 = faceMetaValues(
					lightMetaFast, shadeIndexForFace( f ), bx, by, bz, id, f, li, emission, faceCubic, quadLightEmission,
					c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z
				)
				pushShapeFace(
					push, wx, wy, wz, nrm, fd, nil, f, tile, u0, v0, u1, v1,
					c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z,
					color1, color2, color3, color4, meta1, meta2, meta3, meta4
				)
			until true
		end
	end
	return "shape", false, 0
end

local function emitCrossBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	ctx.prepareBlockCacheBuffer( targetBuffer )
	RM.EmitCrossBlock( ctx, b, id, bx, by, bz, wx, wy, wz, ctx.push, ctx.lightMeta, ctx.currentEmitLightStyle )
	return "cross", false, 0
end

local function emitModelBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	if ctx.prepareBlockCacheBuffer( targetBuffer )
		and RM.EmitModelBlock( ctx, b, orient, bx, by, bz, wx, wy, wz, li, ctx.push, ctx.lightMeta, ctx.currentEmitLightStyle ) then
		return "model", false, 0
	end
	if isLiquidBlock( id ) and emitLiquidBlockRecord then
		return emitLiquidBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	end
	if stateFullCube( ctx, id, orient, bx, by, bz ) and emitFullCubeBlockRecord then
		return emitFullCubeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	end
	return emitShapeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
end

local function emitStatePlanBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer, visibleFaceMask, visibleFaceCount )
	if not stateVisualPlanRangeFast or not stateVisualPlanModelAtFast or not stateVisualModelData then
		local fallback = selectBaseBlockEmitter( ctx, b, id, orient, ctx.blockIsFullCube, bx, by, bz )
		return fallback( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	end
	local planId, groupOffset, groupCount = stateVisualPlanRangeFast( ctx.currentStateId )
	if groupCount == 0 then return "statePlan", false, 0 end
	-- Preserve the direct cold-load path. Per-cell edits opt into caching even
	-- small generated cubes, whose neighbourhood lighting is expensive to repeat.
	if ctx.l2 and not ctx.nativeL2 and not ctx.pagedAtlas and not ctx.retainSmallBlockCache
		and groupCount == 1 and visibleFaceCount and visibleFaceCount > 0
		and not shouldStoreBlockEmissionCache( "fullCube", visibleFaceCount * 6 ) then
		local modelId = stateVisualPlanModelAtFast( planId, groupOffset, 0, bx, by, bz )
		local modelData = modelId and stateVisualModelData( modelId )
		local template = modelData and getGeneratedModelTemplate( modelData )
		if template and template.sixCubeFaces then
			local vertexCount = visibleFaceCount * 6
			ctx.setCur( targetBuffer )
			emitModelBlockTemplate( ctx, template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li,
				ctx.push, ctx.lightMetaFast, ctx.currentEmitLightStyle, true, modelId, visibleFaceMask )
			return "statePlan", true, vertexCount
		end
	end
	ctx.prepareBlockCacheBuffer( targetBuffer )
	local rendered = false
	for groupIndex = 0, groupCount - 1 do
		local modelId = stateVisualPlanModelAtFast( planId, groupOffset, groupIndex, bx, by, bz )
		local modelData = modelId and stateVisualModelData( modelId ) or nil
		local template = modelData and getGeneratedModelTemplate( modelData ) or nil
		if template then
			emitModelBlockTemplate(
				ctx, template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li,
				ctx.push, ctx.lightMetaFast, ctx.currentEmitLightStyle,
				not ( ctx.currentVisual and ctx.currentVisual.cullGeneratedFaces == false ), modelId, visibleFaceMask
			)
			rendered = true
		end
	end
	if rendered then return "statePlan", false, 0 end
	-- A plan that intentionally references a built-in/entity/special renderer
	-- must stay absent from the static chunk mesh until that renderer registers.
	-- Falling back to the generic cube path turns chests, banners, skulls,
	-- portals and invisible technical blocks into grass-textured full cubes.
	return "statePlan", false, 0
end

local function emitSpecialBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	local special = specialEmitterForBlock( b )
	if not special then return "special", false, 0 end
	local kind, cacheable, vertices = special( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	return kind or "special", cacheable == true, tonumber( vertices ) or 0
end

emitLiquidBlockRecord = function( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	if ctx.prepareBlockCacheBuffer( targetBuffer )
		and RM.EmitLiquidBlock( ctx, id, orient, bx, by, bz, wx, wy, wz, ctx.push, ctx.lightMeta, ctx.currentEmitLightStyle ) then
		return "liquid", false, 0
	end
	if stateFullCube( ctx, id, orient, bx, by, bz ) and emitFullCubeBlockRecord then
		return emitFullCubeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	end
	return emitShapeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
end

emitFullCubeBlockRecord = function( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer, visibleFaceMask, visibleFaceCount )
	local meshPerf = ctx.meshPerf
	local meshProbe = ctx.meshProbe
	local lightMetaFast = ctx.lightMetaFast
	local flush = ctx.flush
	local push = ctx.push
	local emission = stateEmission( ctx, id, bx, by, bz )
	if visibleFaceMask == nil then
		local fullVisibleStart = meshProbe and SysTime() or nil
		visibleFaceMask, visibleFaceCount = ctx.visibleFaceMask( id, lx, ly, lz, bx, by, bz )
		if fullVisibleStart then meshPerfAdd( meshPerf, "fullVisibleMS", fullVisibleStart ) end
	end
	if visibleFaceMask == nil then return "fullCube", false, 0 end
	meshPerf.fullVisibleFaces = meshPerf.fullVisibleFaces + visibleFaceCount
	local directEmitVertexCount = visibleFaceCount * 6
	local directionalEmit = ctx.l2 and targetBuffer.directional
	local directEmitCheapFullCube = directionalEmit
		or not shouldStoreBlockEmissionCache( "fullCube", directEmitVertexCount, ctx.retainSmallBlockCache )
	if directEmitCheapFullCube then meshPerf.fullDirectBlocks = meshPerf.fullDirectBlocks + 1 end
	if directEmitCheapFullCube then
		if not ctx.nativeRecipe and targetBuffer.nv + directEmitVertexCount >= C.VERT_LIMIT then flush( targetBuffer ) end
		ctx.setCur( targetBuffer )
	else
		ctx.prepareBlockCacheBuffer( targetBuffer )
	end
	local emitLightStyle = ctx.currentEmitLightStyle()
	local receiveAO = not ( MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) )
	for f = 1, 6 do
		if bit_band( visibleFaceMask, bit_lshift( 1, f - 1 ) ) ~= 0 then
			local face = C.FACES[f]
			local faceStart = meshProbe and SysTime() or nil
			local baked = not ( ctx.currentVisual and ctx.currentVisual.faces ) and bakedFaceData( id, f, orient ) or nil
			local tile, rot, flipU, flipV
			local u0, v0, u1, v1
			local quadLightEmission = 0
			if baked then
				tile, quadLightEmission = blockModelSurface( b, baked )
				rot = baked.rot or 0
			else
				tile, rot, flipU, flipV = stateFace( ctx, id, f, orient, bx, by, bz )
			end
			local corners = face.c
			local nrm = face.n
			local shadeIndex = shadeIndexForFace( f )
			if faceStart then meshPerfAdd( meshPerf, "fullFaceMS", faceStart ) end
			local colorStart = meshProbe and SysTime() or nil
			if ctx.l2 then
				if directionalEmit then ctx.setCur( ctx.fullCubeBuffer( targetBuffer, f ) ) end
				local quad = fullCubeTemplate( ctx, f, tile, baked, rot, flipU, flipV, quadLightEmission )
				ctx.emitL2( quad, id, bx, by, bz, wx, wy, wz, emission )
			else
				u0, v0, u1, v1 = tileUVRect( tile, baked and baked.uv )
				local color1, color2, color3, color4 = fullCubeFaceCornerColors( shadeIndex, bx, by, bz, f, emission, emitLightStyle, receiveAO )
				if colorStart then meshPerfAdd( meshPerf, "fullColorMS", colorStart ) end
				local metaStart = meshProbe and SysTime() or nil
				local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
				local kind = MC.RenderLightBuffer.KIND.BOX
				local meta1 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c1[1], c1[2], c1[3], emission, true, quadLightEmission, 0, kind, 0, 0, 1 )
				local meta2 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c2[1], c2[2], c2[3], emission, true, quadLightEmission, 0, kind, 0, 0, 2 )
				local meta3 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c3[1], c3[2], c3[3], emission, true, quadLightEmission, 0, kind, 0, 0, 3 )
				local meta4 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c4[1], c4[2], c4[3], emission, true, quadLightEmission, 0, kind, 0, 0, 4 )
				if metaStart then meshPerfAdd( meshPerf, "fullMetaMS", metaStart ) end
				pushFullCubeFace( push, wx, wy, wz, nrm, corners, baked, tile, u0, v0, u1, v1, rot, flipU, flipV, color1, color2, color3, color4, meta1, meta2, meta3, meta4, meshProbe, meshPerf )
			end
		end
	end
	return "fullCube", directEmitCheapFullCube, directEmitVertexCount
end

BlockEmitters.cross = emitCrossBlockRecord
BlockEmitters.model = emitModelBlockRecord
BlockEmitters.special = emitSpecialBlockRecord
BlockEmitters.statePlan = emitStatePlanBlockRecord
BlockEmitters.liquid = emitLiquidBlockRecord
BlockEmitters.fullCube = emitFullCubeBlockRecord
BlockEmitters.shape = emitShapeBlockRecord

-- Compile only state-invariant, opaque direct cubes. Other emitters retain
-- their existing Lua semantics until their worker recipes are implemented.
function RM.NativeCubeRecipe( stateId )
	local visual = MC.ResolveBlockStateVisual( stateId, 0, 0, 0 )
	if not visual then return false end
	local b, id = visual.block, visual.id
	local name = visual.schema and visual.schema.name
	if visual.cacheable == false or visual.generatedVisualOverride
		or ( name and MC.BlockStateVisualResolvers and MC.BlockStateVisualResolvers[name] )
		or ( name and MC.BlockStateCollisionResolvers and MC.BlockStateCollisionResolvers[name] )
		or b ~= MC.Blocks[id] or b.transparent or b.shape == "model" or b.shape == "cross"
		or specialEmitterForBlock( b ) or isLiquidBlock( id )
		or ( isWaterloggedState and isWaterloggedState( stateId ) )
		or not MC.BlockVisualIsFullCube( visual, 0, 0, 0 )
		or MC.BlockVisualIsTranslucent( visual, 0, 0, 0 ) then return false end
	for _, field in ipairs( { "faces", "fullCube", "translucent", "lightEmission" } ) do
		if type( visual[field] ) == "function" then return false end
	end
	local slice = { blockSize = 1, nativeL2 = true }
	local buffer = MC.RenderL2Quad.NewBuffer( slice )
	buffer.directional = true
	local ctx = { l2 = true, nativeRecipe = true, currentVisual = visual, currentStateId = stateId,
		meshPerf = RM.newMeshPerfStats(), meshProbe = false }
	ctx.setCur = function() end
	ctx.fullCubeBuffer = function() return buffer end
	ctx.currentEmitLightStyle = function() return "l2" end
	ctx.flush = function() error( "cube recipe exceeded one batch", 0 ) end
	ctx.emitL2 = function( quad, block, bx, by, bz, wx, wy, wz, emission )
		MC.RenderL2Quad.EmitNative( slice, buffer, quad, block, bx, by, bz, wx, wy, wz, emission )
	end
	emitFullCubeBlockRecord( ctx, b, id, visual.renderOrient, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, buffer, 63, 6 )
	local recipe, err = MC.NativeL2.module.CompileL2Cube( buffer.nativeCommands, id )
	MC.RenderL2Resources.Require( recipe ~= nil, "native_l2_cube", tostring( err ) )
	return { value = recipe, id = id }
end

function RM.NativeModelRecipe( stateId, includeWaterlogged )
	if meshDebugFullCubeOnly() then return false end
	local visual = MC.ResolveBlockStateVisual( stateId, 0, 0, 0 )
	if not visual or not MC.StateVisualPlanGroups or not MC.RenderL2Models then return false end
	local b, id = visual.block, visual.id
	local name = visual.schema and visual.schema.name
	if visual.cacheable == false or b ~= MC.Blocks[id]
		or ( name and MC.BlockStateVisualResolvers and MC.BlockStateVisualResolvers[name] )
		or specialEmitterForBlock( b ) or isLiquidBlock( id )
		or ( isWaterloggedState and isWaterloggedState( stateId ) and not includeWaterlogged ) then return false end
	for _, field in ipairs( { "faces", "fullCube", "translucent", "lightEmission" } ) do
		if type( visual[field] ) == "function" then return false end
	end
	local ctx = { currentVisual = visual, currentStateId = stateId }
	local emitter
	-- Base Lua shapes (stairs, slabs, connections) still have catalog models.
	-- Compile the host's complete state plan before attaching its water layer.
	local waterloggedHost = includeWaterlogged and isWaterloggedState( stateId ) and visual.forceBaseRenderer ~= true
	if waterloggedHost then
		emitter = BlockEmitters.statePlan
	else
		emitter = selectBlockEmitter( ctx, b, id, visual.renderOrient, MC.BlockIsFullCube, 0, 0, 0 )
	end
	if emitter ~= BlockEmitters.statePlan and emitter ~= BlockEmitters.model then return false end
	local groups = MC.StateVisualPlanGroups( stateId )
	if #groups == 0 then
		if not waterloggedHost then return false end
		local planId, _, count = MC.StateVisualPlanRangeFast( stateId )
		if planId < 1 or planId > MC.StateVisualCatalog.visualPlanCount or count ~= 0 then return false end
	end
	local models = MC.RenderL2Models
	for _, group in ipairs( groups ) do
		for _, alternative in ipairs( group.alternatives ) do
			if not models.Has( alternative.model ) then return false end
		end
	end
	local legacy, selected
	if emitter == BlockEmitters.model then
		local planId = MC.StateVisualPlanIdFast( stateId )
		if MC.StateVisualPlanHasRandomChoice( planId ) then return false end
		legacy = getModelTemplate( b, visual.renderOrient, stateId )
		if not legacy then return false end
		selected = models.Selection( stateId, 0, 0, 0 )
		if not selected then return false end
	end
	local function capture( template, modelId, ao )
		local selection = { n = 1, modelAO = ao }
		if modelId then selection[1] = modelId
		else
			selection.n = selected.n
			for i = 1, selected.n do selection[i] = selected[i] end
		end
		local slice = { blockSize = 1, nativeL2 = true, selections = { selection },
			snapshot = { Index = function() return 1 end, Read = function() return { stateId = stateId, loaded = true } end } }
		local buffer = MC.RenderL2Quad.NewBuffer( slice )
		local culls = {}
		for i = 1, template.n do
			local quad = template[i]
			local tint = quad.tintIndex and quad.tintIndex >= 0 and blockStateTintCode
				and blockStateTintCode( stateId, id, quad.tintIndex ) or 0
			local previous = buffer.quadCount
			MC.RenderL2Quad.EmitNative( slice, buffer, quad, id, 0, 0, 0, 0, 0, 0, 0, tint,
				modelId and MC.RenderLightBuffer.KIND.GENERATED or MC.RenderLightBuffer.KIND.MODEL, modelId )
			if buffer.quadCount > previous then
				culls[#culls + 1] = modelId and visual.cullGeneratedFaces ~= false and quad.faceCubic and quad.faceIndex or 0
			end
		end
		return buffer.nativeCommands, culls
	end
	local packet = {}
	if #groups == 0 then
		-- A registered empty multipart plan is one no-op choice in the DLL ABI.
		packet[1] = { 0, { { 1, true, {}, {}, {} } } }
	elseif legacy then
		local shaded, culls = capture( legacy, nil, true )
		local flat = capture( legacy, nil, false )
		packet[1] = { 0, { { 1, selected.modelAO, shaded, flat, culls } } }
	else
		for i, group in ipairs( groups ) do
			local alternatives = {}
			for j, alternative in ipairs( group.alternatives ) do
				local modelId = alternative.model
				local template = getGeneratedModelTemplate( stateVisualModelData( modelId ) )
				if not template then return false end
				local shaded, culls = capture( template, modelId, true )
				local flat = capture( template, modelId, false )
				alternatives[j] = { alternative.weight, models.Profile( modelId ).modelAO, shaded, flat, culls }
			end
			packet[i] = { group.salt, alternatives }
		end
	end
	local recipe, err = MC.NativeL2.module.CompileL2Model( packet, id, string.match( b.name, "_leaves$" ) ~= nil, 0 )
	MC.RenderL2Resources.Require( recipe ~= nil, "native_l2_model", "state " .. stateId .. ": " .. tostring( err ) )
	return { value = recipe, id = id, model = true, translucent = stateTranslucent( ctx, id, 0, 0, 0 ) }
end

-- Compile finite base-emitter variants once. Neighbour selection and partial
-- box coverage run against the immutable world snapshot on the worker.
function RM.NativeShapeRecipe( stateId )
	if meshDebugFullCubeOnly() then return false end
	local visual = MC.ResolveBlockStateVisual( stateId, 0, 0, 0 )
	if not visual then return false end
	local b, id, orient = visual.block, visual.id, visual.renderOrient
	local name = visual.schema and visual.schema.name
	if visual.cacheable == false or visual.generatedVisualOverride or b ~= MC.Blocks[id]
		or name and MC.BlockStateVisualResolvers and MC.BlockStateVisualResolvers[name]
		or specialEmitterForBlock( b ) or isLiquidBlock( id )
		or isWaterloggedState( stateId ) then return false end
	for _, field in ipairs( { "faces", "boxes", "fullCube", "translucent", "lightEmission" } ) do
		if type( visual[field] ) == "function" then return false end
	end
	local ctx = { l2 = true, nativeRecipe = true, currentVisual = visual, currentStateId = stateId,
		meshPerf = RM.newMeshPerfStats(), meshProbe = false }
	local emitter = selectBlockEmitter( ctx, b, id, orient, MC.BlockIsFullCube, 0, 0, 0 )
	if emitter ~= BlockEmitters.fullCube and emitter ~= BlockEmitters.cross and emitter ~= BlockEmitters.shape then return false end
	local kind = emitter == BlockEmitters.shape and connectionKindForBlock( b, id )
	local stairs = emitter == BlockEmitters.shape and b.shape == "stairs"
	local selector = stairs and 1 or kind and ( kind == "pipe6" and 3 or 2 ) or 0
	MC.RenderL2Resources.Require( selector == 0 or visual.boxes == nil,
		"native_l2_shape", "dynamic base shape overrides its boxes: " .. stateId )
	local variants, alternatives = selector == 1 and 5 or selector == 2 and 16 or selector == 3 and 64 or 1, {}
	local stairShapes = { "straight", "inner_left", "inner_right", "outer_left", "outer_right" }
	for variant = 1, variants do
		local slice = { blockSize = 1, nativeL2 = true }
		local buffer = MC.RenderL2Quad.NewBuffer( slice )
		local culls = {}
		local function emit( quad, lightingKind, cull )
			local previous = buffer.quadCount
			MC.RenderL2Quad.EmitNative( slice, buffer, quad, id, 0, 0, 0, 0, 0, 0, 0, 0, lightingKind )
			if buffer.quadCount > previous then culls[#culls + 1] = cull or 0 end
		end
		ctx.emitL2 = function( quad, _, bx, by, bz, wx, wy, wz, emission, tint, lightingKind )
			emit( quad, lightingKind, emitter == BlockEmitters.fullCube and quad.faceIndex or 0 )
		end
		ctx.setCur = function() end
		ctx.prepareBlockCacheBuffer = function() return true end
		ctx.fullCubeBuffer = function() return buffer end
		ctx.currentEmitLightStyle = function() return "l2" end
		ctx.flush = function() error( "shape recipe exceeded one batch", 0 ) end
		if emitter == BlockEmitters.fullCube then
			emitFullCubeBlockRecord( ctx, b, id, orient, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, buffer, 63, 6 )
		elseif emitter == BlockEmitters.cross then
			RM.EmitCrossBlock( ctx, b, id, 0, 0, 0, 0, 0, 0 )
		else
			local boxes, template
			if kind then
				boxes = MC.ConnectionBlockBoxes( kind, variant - 1 )
				template = buildConnectionShapeTemplate( ctx, kind, id, orient, b, variant - 1, boxes )
			else
				if stairs then boxes = MC.StairBoxes( id, orient, nil, nil, nil, stairShapes[variant] ) end
				template = buildShapeTemplate( ctx, b, id, orient, MC.BlockBoxes, boxes )
			end
			MC.RenderL2Resources.Require( template ~= false, "native_l2_shape", "missing base shape: " .. stateId )
			for i = 1, template.n do
				local quad = template[i]
				if kind or not coveredByBoxes( quad.box, quad.faceIndex, template.boxes, 0, 0, 0 ) then
					local cull = 0
					if connectionBoundaryBit( quad.box, quad.faceIndex ) ~= 0 and ( not kind or quad.neighborCheck ) then
						local box = quad.box
						cull = { quad.faceIndex, box[1], box[2], box[3], box[4], box[5], box[6] }
					end
					emit( quad, nil, cull )
				end
			end
		end
		alternatives[variant] = { 1, true, buffer.nativeCommands, buffer.nativeCommands, culls }
	end
	local value, err = MC.NativeL2.module.CompileL2Model( { { 0, alternatives } }, id,
		string.match( b.name, "_leaves$" ) ~= nil, selector )
	MC.RenderL2Resources.Require( value ~= nil, "native_l2_shape", "state " .. stateId .. ": " .. tostring( err ) )
	return { value = value, id = id, model = true, translucent = stateTranslucent( ctx, id, 0, 0, 0 ) }
end

local function emitSelectedBlock( emitter, ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer, visibleFaceMask, visibleFaceCount )
	emitter = emitter or BlockEmitters.shape
	return emitter( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer, visibleFaceMask, visibleFaceCount )
end

local WaterBlockId
local function waterBlockId()
	if WaterBlockId ~= nil then return WaterBlockId or nil end
	local schema = MC.BlockStateSchemaByName and MC.BlockStateSchemaByName["minecraft:water"] or nil
	WaterBlockId = schema and schema.blockId or false
	return WaterBlockId or nil
end

function RM.NativeFluidRecipe( stateId )
	local kind = MC.Liquid.DecodeState( stateId )
	if not kind then return nil end
	local visual = MC.ResolveBlockStateVisual( stateId, 0, 0, 0 )
	MC.RenderL2Resources.Require( visual ~= nil, "native_l2_fluid", "missing fluid visual" )
	local overlay = isWaterloggedState( stateId )
	local id = overlay and waterBlockId() or visual.id
	MC.RenderL2Resources.Require( id ~= nil and MC.LiquidKind( id ) == kind,
		"native_l2_fluid", "missing fluid block/material for state " .. stateId )
	local recipe
	if overlay then
		recipe = RM.NativeModelRecipe( stateId, true )
		MC.RenderL2Resources.Require( recipe ~= false, "native_l2_fluid",
			"waterlogged host has no Native model recipe: " .. stateId )
	else
		recipe = { value = false, id = id, fluidOnly = true,
			translucent = MC.BlockVisualIsTranslucent( visual, 0, 0, 0 ) }
	end
	local orient = overlay and 0 or visual.renderOrient
	local tiles, shades = {}, {}
	for face = 1, 7 do
		local tile
		if face == 7 then tile = LiquidFlowTiles[kind]
		elseif face <= 2 then tile = LiquidStillTiles[kind] or liquidFace( id, face, orient )
		else tile = liquidFace( id, face, orient ) end
		MC.RenderL2Resources.Require( tile ~= nil, "native_l2_fluid", "missing fluid atlas tile" )
		local u1, v1 = tileUVPointRaw( tile, 1, 1 )
		local u2, v2 = tileUVPointRaw( tile, 2, 2 )
		local u0, v0 = tileUVPointRaw( tile, 0, 0 )
		local su, sv = u2 - u1, v2 - v1
		local ou, ov = u1 - su, v1 - sv
		tiles[face] = { ou, ov, su, sv, u0 - ou, v0 - ov }
		if face <= 6 then shades[face] = RM.shadeRGBAByIndex( shadeIndexForFace( face ) ) end
	end
	local value, err = MC.NativeL2.module.CompileL2Fluid( {
		kind = kind == "water" and 1 or 2, tiles = tiles, shade = shades,
		emission = MC.BlockLightEmission( id ), opacity = C.SH_TOP.a,
		offset = C.FLUID_FACE_OFFSET, flow = 1, full = MC.BlockIsFullCube( id, 0 ) and 1 or 0,
	} )
	MC.RenderL2Resources.Require( value ~= nil, "native_l2_fluid", tostring( err ) )
	recipe.fluid, recipe.fluidId = value, id
	return recipe
end

local function emitWaterloggedOverlay( ctx, stateId, bx, by, bz, wx, wy, wz, targetBuffer, flush, meshPerf )
	if not isWaterloggedState or not isWaterloggedState( stateId ) then return 0 end
	local waterId = waterBlockId()
	if not waterId then return 0 end
	if ctx.l2 then targetBuffer = ctx.bufferForBlock( targetBuffer, waterId ) end
	local previous = ctx.getCur()
	if ctx.pagedAtlas then ctx.beginPagedBlock( targetBuffer ) end
	ctx.prepareBlockCacheBuffer( targetBuffer )
	local emitted = RM.EmitLiquidBlock(
		ctx, waterId, 0, bx, by, bz, wx, wy, wz,
		ctx.push, ctx.lightMeta, ctx.currentEmitLightStyle
	)
	local overlay = ctx.getCur()
	local vertexCount = emitted and overlay and overlay.nv or 0
	if ctx.pagedAtlas then
		vertexCount = ctx.endPagedBlock()
	elseif vertexCount > 0 then
		MC.AppendCachedBlockEmission( {
			verts = overlay.verts,
			light = overlay.light,
			l2 = overlay.l2, pixels = overlay.pixels, occlusion = overlay.occlusion, luaRelight = overlay.luaRelight,
			vertexCount = vertexCount,
			hasSecondaryUV = overlay.hasSecondaryUV == true,
		}, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
	end
	ctx.setCur( previous )
	ctx.releaseScratch( overlay )
	return vertexCount
end


function RM.EmitBlock( ctx, li, stateId )
	ctx.beginBlockLight()
	local key = ctx.key
	local meshPerf = ctx.meshPerf
	local meshProbe = ctx.meshProbe
	local sectionNeedsFullRecolor = ctx.sectionNeedsFullRecolor
	local blockLightDirtySection = ctx.blockLightDirtySection
	local bxo, byo, bzo = ctx.bxo, ctx.byo, ctx.bzo
	local chunk = ctx.chunk
	local DecodeLocal = decodeLocal
	local blockIsFullCube = ctx.blockIsFullCube
	local blocksById = ctx.blocksById
	local flush = ctx.flush
	local buffersForLocal = ctx.buffersForLocal
	local styleForBuffer = ctx.styleForBuffer
	local getCur = ctx.getCur
	meshPerf.blocksVisited = meshPerf.blocksVisited + 1
	local lx, ly, lz = DecodeLocal( li )
	local buffers = buffersForLocal( lx, ly, lz )
	if not buffers then return end
	local bx, by, bz = bxo + lx, byo + ly, bzo + lz
	local visual = stateId and MC.ResolveBlockStateVisual and MC.ResolveBlockStateVisual( stateId, bx, by, bz ) or nil
	if not visual then
		MC.DropBlockEmitCacheRecord( key, MC.RenderSectionIndexForLocal( lx, ly, lz ), li )
		error( { code = "render_l2_visual_missing",
			message = string.format( "state %s has no visual at (%s,%s,%s)", tostring( stateId ), bx, by, bz ) }, 0 )
	end
	local id = visual.id
	local orient = visual.renderOrient
	ctx.currentStateId = stateId
	ctx.currentVisual = visual
	local size = ctx.blockSize or C.BS
	local wx, wy, wz = lx * size, ly * size, lz * size
	local blockSectionIndex = MC.RenderSectionIndexForLocal( lx, ly, lz )

	if meshDebugFullCubeOnly() and not stateFullCube( ctx, id, orient, bx, by, bz ) then
		MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
		if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
		return
	end

	local cached = MC.GetCachedBlockEmission( key, blockSectionIndex, li, id, orient, stateId, ctx.nativeL2 )
	local blockNeedsRecolor = sectionNeedsFullRecolor or ( blockLightDirtySection and blockLightDirtySection[li] )
	if cached and ctx.l2 and ( ctx.pagedAtlas or ctx.nativeL2 and blockNeedsRecolor or not cached.l2 or cached.blockSize ~= size
		or not ctx.nativeL2 and ( not cached.luaRelight or cached.luaRelightVersion ~= MC.RenderL2Quad.LUA_RELIGHT_VERSION ) ) then
		MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
		cached = nil
	end
	local b = visual.block or blocksById[id]
	local emitter, visibleFaceMask, visibleFaceCount
	if not cached then
		emitter = selectBlockEmitter( ctx, b, id, orient, blockIsFullCube, bx, by, bz )
		local generatedCull = emitter == BlockEmitters.statePlan and ctx.generatedCullPlans
			and ctx.generatedCullPlans[stateId] and visual.cullGeneratedFaces ~= false
		if emitter == BlockEmitters.fullCube or generatedCull then
			local fullVisibleStart = meshProbe and SysTime() or nil
			visibleFaceMask, visibleFaceCount = ctx.visibleFaceMask( id, lx, ly, lz, bx, by, bz )
			if fullVisibleStart then meshPerfAdd( meshPerf, "fullVisibleMS", fullVisibleStart ) end
			if visibleFaceMask == nil then return false end
			if visibleFaceMask == 0 and not ( isWaterloggedState and isWaterloggedState( stateId ) ) then
				MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
				if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
				meshPerfAddBlockKind( meshPerf, generatedCull and "statePlan" or "fullCube" )
				return
			end
		end
	end
	local targetBuffer = stateTranslucent( ctx, id, bx, by, bz ) and buffers.translucent or buffers.opaque
	if ctx.l2 then targetBuffer = ctx.bufferForBlock( targetBuffer, id ) end
	if cached and ctx.l2 and targetBuffer.directional and cached.kind == "fullCube" then
		-- Crossing the section threshold after an edit must also regroup cubes
		-- whose previous unpartitioned block records were still cached.
		MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
		cached = nil
	end
	local targetLightStyle = styleForBuffer( targetBuffer )
	if cached and not ctx.l2 and ( blockNeedsRecolor or cached.lightStyle ~= targetLightStyle ) then
		local recolorStart = SysTime()
		if recolorCachedBlockEmission( cached, targetLightStyle, meshPerf ) then
			meshPerfAdd( meshPerf, "recolorMS", recolorStart )
			meshPerf.blockCacheRecolors = meshPerf.blockCacheRecolors + 1
		else
			MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
			cached = nil
		end
	end
	if cached and ctx.l2 and not ctx.nativeL2 and blockNeedsRecolor then
		-- A light change does not invalidate this block's geometry. Use the
		-- retained quad recipes; geometry dependencies already dropped their
		-- records in MarkBlockEmitCacheDirty before this build started.
		local recolorStart = meshProbe and SysTime() or nil
		local pixels, occlusion = MC.RenderL2Quad.Relight( ctx.nativeSlice, cached )
		cached.pixels, cached.occlusion = pixels, occlusion
		if recolorStart then meshPerfAdd( meshPerf, "recolorMS", recolorStart ) end
		meshPerf.blockCacheRecolors = meshPerf.blockCacheRecolors + 1
	end
	if cached then
		meshPerf.blockCacheHits = meshPerf.blockCacheHits + 1
		local cacheAppendStart = meshProbe and SysTime() or nil
		local appended = MC.AppendCachedBlockEmission( cached, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
		if cacheAppendStart then meshPerfAdd( meshPerf, "cacheAppendMS", cacheAppendStart ) end
		local overlayVertices = emitWaterloggedOverlay(
			ctx, stateId, bx, by, bz, wx, wy, wz, buffers.translucent, flush, meshPerf
		)
		if appended > 0 or overlayVertices > 0 then meshPerf.blocksRendered = meshPerf.blocksRendered + 1 end
		local cachedKind = cached.kind or "shape"
		meshPerfAddBlockKind( meshPerf, cachedKind )
		return
	end

	meshPerf.blockCacheMisses = meshPerf.blockCacheMisses + 1
	ctx.setCur( nil )

	local emitStart = meshProbe and SysTime() or nil
	emitter = emitter or selectBlockEmitter( ctx, b, id, orient, blockIsFullCube, bx, by, bz )
	if ctx.pagedAtlas then ctx.beginPagedBlock( targetBuffer ) end
	local emitKind, directEmitCheapFullCube, directEmitVertexCount = emitSelectedBlock(
		emitter,
		ctx,
		b,
		id,
		orient,
		bx,
		by,
		bz,
		wx,
		wy,
		wz,
		lx,
		ly,
		lz,
		li,
		targetBuffer,
		visibleFaceMask,
		visibleFaceCount
	)
	if ctx.pagedAtlas then
		directEmitVertexCount = ctx.endPagedBlock()
		directEmitCheapFullCube = true
		ctx.releaseScratch( getCur() )
		ctx.setCur( nil )
	end
	if ctx.visibility.error then return false end
	emitKind = emitKind or "shape"
	directEmitCheapFullCube = directEmitCheapFullCube == true
	directEmitVertexCount = directEmitVertexCount or 0
	local cur = getCur()
	local emittedVertices = directEmitCheapFullCube and directEmitVertexCount or ( cur and cur.nv or 0 )
	if directEmitCheapFullCube then
		MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
		if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
	else
		local blockRecord = cur and {
			verts = cur.verts,
			light = cur.light,
			l2 = cur.l2, pixels = cur.pixels, occlusion = cur.occlusion, luaRelight = cur.luaRelight,
			luaRelightVersion = cur.luaRelight and MC.RenderL2Quad.LUA_RELIGHT_VERSION or nil,
			quadCount = cur.quadCount,
			nativeL2 = cur.nativeL2, nativeCommands = cur.nativeCommands,
			blockSize = size,
			vertexCount = emittedVertices,
			material = targetBuffer.material,
			translucent = targetBuffer.translucent,
			hasSecondaryUV = cur.hasSecondaryUV == true,
			kind = emitKind,
		} or nil
		local retainBlock = shouldStoreBlockEmissionCache( emitKind, emittedVertices, ctx.retainSmallBlockCache )
		if retainBlock then
			blockRecord = MC.StoreBlockEmissionCache( key, blockSectionIndex, li, id, orient, targetLightStyle, blockRecord, stateId )
		else
			MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
			if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
		end
		MC.AppendCachedBlockEmission( blockRecord, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
		if not retainBlock then
			ctx.releaseScratch( cur )
			cur = nil
			ctx.setCur( nil )
		end
	end
	local overlayVertices = emitWaterloggedOverlay(
		ctx, stateId, bx, by, bz, wx, wy, wz, buffers.translucent, flush, meshPerf
	)
	if emittedVertices > 0 or overlayVertices > 0 then
		meshPerf.blocksRendered = meshPerf.blocksRendered + 1
	end
	meshPerfAddBlockKind( meshPerf, emitKind )
	if emitStart then
		local emitMS = meshPerfElapsedMS( emitStart )
		meshPerf.emitMS = meshPerf.emitMS + emitMS
		meshPerfAddKindDuration( meshPerf, emitKind, emitMS )
	end
	ctx.setCur( cur )
end
