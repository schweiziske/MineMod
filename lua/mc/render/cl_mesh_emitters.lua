-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local bit_band, bit_bor, bit_lshift = bit.band, bit.bor, bit.lshift
local meshDebugFullCubeOnly = RM.meshDebugFullCubeOnly
local shouldStoreBlockEmissionCache = RM.shouldStoreBlockEmissionCache
local meshPerfAdd = RM.meshPerfAdd
local meshPerfElapsedMS = RM.meshPerfElapsedMS
local meshPerfAddBlockKind = RM.meshPerfAddBlockKind
local meshPerfAddKindDuration = RM.meshPerfAddKindDuration
local isLiquidBlock = RM.isLiquidBlock
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
local visible = RM.visible
local fluidHeightAt = RM.fluidHeightAt
local calculateAverageFluidHeight = RM.calculateAverageFluidHeight
local recolorCachedBlockEmission = RM.recolorCachedBlockEmission
local BS = C.BS

local ShapeModelTemplateCache = {
	model = {},
	shape = {},
	connection = {},
}

function RM.resetShapeModelTemplateCache()
	ShapeModelTemplateCache = {
		model = {},
		shape = {},
		connection = {},
	}
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

local function buildModelTemplate( b, orient )
	local quads = rotatedModelQuads( b, orient )
	if not quads then return false end

	local mirrorU = b.orient == "door"
	local tri = C.TRI
	local out = { n = 0 }
	for qi = 1, #quads do
		local quad = quads[qi]
		local verts = quad and quad.verts
		if verts and verts[1] and verts[2] and verts[3] and verts[4] then
			local faceIndex = quad.face or MC.Face.TOP
			local face = C.FACES[faceIndex] or C.FACES[MC.Face.TOP]
			local u0, v0, u1, v1 = tileUVRect( quad.tile or 0, quad.uv )
			local vtx1, vtx2, vtx3, vtx4 = verts[1], verts[2], verts[3], verts[4]
			local c1x, c1y, c1z = cornerXYZ( vtx1 )
			local c2x, c2y, c2z = cornerXYZ( vtx2 )
			local c3x, c3y, c3z = cornerXYZ( vtx3 )
			local c4x, c4y, c4z = cornerXYZ( vtx4 )
			local rec = {
				faceIndex = faceIndex,
				normal = face.n,
				shade = face.sh,
				quadLightEmission = quad.lightEmission or 0,
				faceCubic = quadFaceCubic( faceIndex, b.id, orient, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z ),
				c1x = c1x, c1y = c1y, c1z = c1z,
				c2x = c2x, c2y = c2y, c2z = c2z,
				c3x = c3x, c3y = c3y, c3z = c3z,
				c4x = c4x, c4y = c4y, c4z = c4z,
			}
			for t = 1, 6 do
				local ci = tri[t]
				local vert = verts[ci]
				local uf, vf = rotatedUVFlags( vert.u or 0, vert.v or 0, quad.rot or 0 )
				if mirrorU then uf = 1 - uf end
				setTemplateTriVertex( rec, t, ci, vert.x, vert.y, vert.z, uf == 1 and u1 or u0, vf == 1 and v1 or v0 )
			end
			local n = out.n + 1
			out.n = n
			out[n] = rec
		end
	end
	return out
end

local function getModelTemplate( b, orient )
	local bucket = templateBucket( ShapeModelTemplateCache.model, b.id )
	local cached = bucket[orient]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildModelTemplate( b, orient )
	bucket[orient] = cached or false
	return cached ~= false and cached or nil
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

local function buildShapeTemplate( b, id, orient, blockBoxes )
	if not blockBoxes then return false end
	local boxes = blockBoxes( id, orient )
	if not boxes then return false end

	local modelFaces = b and b.boxFaces
	local tri = C.TRI
	local out = { boxes = boxes, n = 0 }
	for boxIndex = 1, #boxes do
		local box = boxes[boxIndex]
		local boxFaces = modelFaces and modelFaces[boxIndex] or nil
		for f = 1, 6 do
			local fd = boxFaces and boxFaces[f] or nil
			if not modelFaces or fd then
				local face = C.FACES[f]
				local tile = fd and fd.tile or MC.BlockFace( id, f, orient )
				local quadLightEmission = fd and fd.lightEmission or 0
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

local function getShapeTemplate( b, id, orient, blockBoxes )
	local bucket = templateBucket( ShapeModelTemplateCache.shape, id )
	local cached = bucket[orient]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildShapeTemplate( b, id, orient, blockBoxes )
	bucket[orient] = cached or false
	return cached ~= false and cached or nil
end

local function faceMetaValues( lightMetaFast, shadeIndex, bx, by, bz, id, faceIndex, li, emission, faceCubic, quadLightEmission,
	c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z )
	local meta1 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c1x, c1y, c1z, emission, faceCubic, quadLightEmission )
	local meta2 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c2x, c2y, c2z, emission, faceCubic, quadLightEmission )
	local meta3 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c3x, c3y, c3z, emission, faceCubic, quadLightEmission )
	local meta4 = lightMetaFast( shadeIndex, bx, by, bz, id, faceIndex, li, c4x, c4y, c4z, emission, faceCubic, quadLightEmission )
	meta1.shared, meta2.shared, meta3.shared, meta4.shared = true, true, true, true
	return meta1, meta2, meta3, meta4
end

local function pushFaceQuad( push, normal,
	x1, y1, z1, u1, v1, color1, meta1,
	x2, y2, z2, u2, v2, color2, meta2,
	x3, y3, z3, u3, v3, color3, meta3,
	x4, y4, z4, u4, v4, color4, meta4,
	meshProbe, meshPerf )
	local vertexStart = meshProbe and SysTime() or nil
	local pos1 = Vector( x1, y1, z1 )
	local pos2 = Vector( x2, y2, z2 )
	local pos3 = Vector( x3, y3, z3 )
	local pos4 = Vector( x4, y4, z4 )
	if meshProbe then
		local vert1 = { pos = pos1, normal = normal, u = u1, v = v1, color = color1 }
		local vert2 = { pos = pos3, normal = normal, u = u3, v = v3, color = color3 }
		local vert3 = { pos = pos2, normal = normal, u = u2, v = v2, color = color2 }
		local vert4 = { pos = pos1, normal = normal, u = u1, v = v1, color = color1 }
		local vert5 = { pos = pos4, normal = normal, u = u4, v = v4, color = color4 }
		local vert6 = { pos = pos3, normal = normal, u = u3, v = v3, color = color3 }
		meshPerfAdd( meshPerf, "fullVertexMS", vertexStart )
		local pushStart = SysTime()
		push( vert1, meta1 )
		push( vert2, meta3 )
		push( vert3, meta2 )
		push( vert4, meta1 )
		push( vert5, meta4 )
		push( vert6, meta3 )
		meshPerfAdd( meshPerf, "fullPushMS", pushStart )
		return
	end
	push( { pos = pos1, normal = normal, u = u1, v = v1, color = color1 }, meta1 )
	push( { pos = pos3, normal = normal, u = u3, v = v3, color = color3 }, meta3 )
	push( { pos = pos2, normal = normal, u = u2, v = v2, color = color2 }, meta2 )
	push( { pos = pos1, normal = normal, u = u1, v = v1, color = color1 }, meta1 )
	push( { pos = pos4, normal = normal, u = u4, v = v4, color = color4 }, meta4 )
	push( { pos = pos3, normal = normal, u = u3, v = v3, color = color3 }, meta3 )
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

local function connectionTemplateBucket( kind, id, orient )
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
	local orientBucket = idBucket[orient]
	if not orientBucket then
		orientBucket = {}
		idBucket[orient] = orientBucket
	end
	return orientBucket
end

local function buildConnectionShapeTemplate( kind, id, orient, b, mask, boxes )
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
					if not ok then tile = MC.BlockFace( id, f, orient ) end
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

local function getConnectionShapeTemplate( kind, id, orient, b, mask, boxes )
	local bucket = connectionTemplateBucket( kind, id, orient )
	local cached = bucket[mask]
	if cached ~= nil then return cached ~= false and cached or nil end
	cached = buildConnectionShapeTemplate( kind, id, orient, b, mask, boxes )
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

local function emitModelBlockTemplate( template, b, bx, by, bz, wx, wy, wz, li, push, lightMetaFast, currentEmitLightStyle )
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( b.id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	for qi = 1, template.n do
		local quad = template[qi]
		local color1, color2, color3, color4 = quadCornerColorValues(
			quad.shade, bx, by, bz, b.id, quad.faceIndex, emission, emitLightStyle,
			quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z
		)
		local f = quad.faceIndex
		local meta1, meta2, meta3, meta4 = faceMetaValues(
			lightMetaFast, shadeIndexForFace( f ), bx, by, bz, b.id, f, li, emission, quad.faceCubic, quad.quadLightEmission,
			quad.c1x, quad.c1y, quad.c1z, quad.c2x, quad.c2y, quad.c2z, quad.c3x, quad.c3y, quad.c3z, quad.c4x, quad.c4y, quad.c4z
		)
		pushTemplateFace( push, quad, wx, wy, wz, color1, color2, color3, color4, meta1, meta2, meta3, meta4 )
	end
	return true
end

local function emitShapeBlockTemplate( template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle )
	local boxes = template.boxes
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
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

	local template = getConnectionShapeTemplate( kind, id, orient, b, mask, boxes )
	if not template then return false end

	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	for qi = 1, template.n do
		local quad = template[qi]
		local f = quad.faceIndex
		if not quad.neighborCheck or not shapeFaceNeighborCoveredAt( id, quad.box, f, bx, by, bz, lx, ly, lz ) then
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

	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	for boxIndex = 1, #boxes do
		local box = boxes[boxIndex]
		for f = 1, 6 do
			if not shapeFaceCoveredAt( id, box, f, boxes, bx, by, bz, lx, ly, lz ) then
				local face = C.FACES[f]
				local tile, uv, ok = connectionShapeFaceValues( b, f, box )
				if not ok then tile = MC.BlockFace( id, f, orient ) end
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
	if connectionVisibleTemplateEnabled()
		and emitConnectionShapeBlockTemplate( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle ) then
		return true
	end
	return emitConnectionShapeBlockLegacy( ctx, kind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceCoveredAt, currentEmitLightStyle )
end

local function emitQuad( ctx, cur, push, lightMeta, currentEmitLightStyle, corners, normal, color, tile, bx, by, bz, id, faceIndex )
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	local color1, color2, color3, color4 = quadCornerColors( color, bx, by, bz, id, faceIndex, corners, emission, emitLightStyle )
	local tri = C.TRI
	for t = 1, 6 do
		local ci = tri[t]
		local cn = corners[ci]
		local u, v = tileUVPointRaw( tile, cn[4], cn[5] )
		local vertColor
		if ci == 1 then
			vertColor = color1
		elseif ci == 2 then
			vertColor = color2
		elseif ci == 3 then
			vertColor = color3
		else
			vertColor = color4
		end
		push( {
			pos    = Vector( cn[1], cn[2], cn[3] ),
			normal = normal,
			u      = u,
			v      = v,
			color  = vertColor,
		}, lightMeta( color, bx, by, bz, id, faceIndex, cn, emission, nil, nil, 0 ) )
	end
end

function RM.EmitCrossBlock( ctx, id, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	local b = MC.Blocks[id]
	local tile = b and b.side or 0
	local z0, z1 = wz, wz + C.BS
	local a, c = 0.08 * C.BS, 0.92 * C.BS
	local p1 = {
		{ wx + a, wy + a, z0, 0, 16 },
		{ wx + c, wy + c, z0, 16, 16 },
		{ wx + c, wy + c, z1, 16, 0 },
		{ wx + a, wy + a, z1, 0, 0 },
	}
	local p2 = {
		{ wx + c, wy + a, z0, 0, 16 },
		{ wx + a, wy + c, z0, 16, 16 },
		{ wx + a, wy + c, z1, 16, 0 },
		{ wx + c, wy + a, z1, 0, 0 },
	}
	emitQuad( ctx, nil, push, lightMeta, currentEmitLightStyle, p1, C.N_YP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.YP )
	emitQuad( ctx, nil, push, lightMeta, currentEmitLightStyle, { p1[4], p1[3], p1[2], p1[1] }, C.N_YN, C.SH_TOP, tile, bx, by, bz, id, MC.Face.YN )
	emitQuad( ctx, nil, push, lightMeta, currentEmitLightStyle, p2, C.N_XP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.XP )
	emitQuad( ctx, nil, push, lightMeta, currentEmitLightStyle, { p2[4], p2[3], p2[2], p2[1] }, C.N_XN, C.SH_TOP, tile, bx, by, bz, id, MC.Face.XN )
end

function RM.EmitModelBlock( ctx, b, orient, bx, by, bz, wx, wy, wz, li, push, lightMeta, currentEmitLightStyle )
	local template = getModelTemplate( b, orient )
	if not template then return false end
	return emitModelBlockTemplate( template, b, bx, by, bz, wx, wy, wz, li, push, ctx.lightMetaFast, currentEmitLightStyle )
end

local function emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle, verts, normal, shade, tile, bx, by, bz, id, faceIndex, lightCorners, uvCorners )
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	local x1, y1, z1 = cornerXYZ( lightCorners[1] )
	local x2, y2, z2 = cornerXYZ( lightCorners[2] )
	local x3, y3, z3 = cornerXYZ( lightCorners[3] )
	local x4, y4, z4 = cornerXYZ( lightCorners[4] )
	local faceCubic = quadFaceCubic( faceIndex, id, 0, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	local color1, color2, color3, color4 = quadCornerColors( shade, bx, by, bz, id, faceIndex, lightCorners, emission, emitLightStyle )
	local tri = C.TRI
	for t = 1, 6 do
		local ci = tri[t]
		local vert = verts[ci]
		local uv = uvCorners[ci]
		local u, v = tileUVPointRaw( tile, uv and uv[1], uv and uv[2] )
		local vertColor
		if ci == 1 then
			vertColor = color1
		elseif ci == 2 then
			vertColor = color2
		elseif ci == 3 then
			vertColor = color3
		else
			vertColor = color4
		end
		push( {
			pos    = Vector( vert[1], vert[2], vert[3] ),
			normal = normal,
			u      = u,
			v      = v,
			color  = vertColor,
		}, lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[ci], emission, nil, faceCubic, 0 ) )
	end
end

function RM.EmitLiquidBlock( ctx, id, orient, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	local kind = MC.LiquidKind and MC.LiquidKind( id )
	if not kind then return false end

	local x0, y0, z0 = wx, wy, wz
	local x1, y1 = wx + C.BS, wy + C.BS
	local bottom = z0
	local hSelf = fluidHeightAt( bx, by, bz, kind )
	local hXN = fluidHeightAt( bx - 1, by, bz, kind )
	local hXP = fluidHeightAt( bx + 1, by, bz, kind )
	local hYN = fluidHeightAt( bx, by - 1, bz, kind )
	local hYP = fluidHeightAt( bx, by + 1, bz, kind )
	local h00, h10, h11, h01

	if hSelf >= 1.0 then
		h00, h10, h11, h01 = 1.0, 1.0, 1.0, 1.0
	else
		h00 = calculateAverageFluidHeight( kind, hSelf, hYN, hXN, bx - 1, by - 1, bz )
		h10 = calculateAverageFluidHeight( kind, hSelf, hYN, hXP, bx + 1, by - 1, bz )
		h11 = calculateAverageFluidHeight( kind, hSelf, hYP, hXP, bx + 1, by + 1, bz )
		h01 = calculateAverageFluidHeight( kind, hSelf, hYP, hXN, bx - 1, by + 1, bz )
	end

	local nbUp = MC.GetBlock( bx, by, bz + 1 )
	local renderUp = visible( id, nbUp, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz + 1 ) or 0 )
	local topOffset = renderUp and C.FLUID_FACE_OFFSET or 0
	local rh00 = math.max( h00 - topOffset, 0 )
	local rh10 = math.max( h10 - topOffset, 0 )
	local rh11 = math.max( h11 - topOffset, 0 )
	local rh01 = math.max( h01 - topOffset, 0 )
	local z00, z10, z11, z01 = z0 + rh00 * C.BS, z0 + rh10 * C.BS, z0 + rh11 * C.BS, z0 + rh01 * C.BS
	local tile

	if renderUp then
		tile = MC.BlockFace( id, MC.Face.TOP, orient )
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			{ { x0, y0, z00 }, { x1, y0, z10 }, { x1, y1, z11 }, { x0, y1, z01 } },
			C.N_UP, C.SH_TOP, tile, bx, by, bz, id, MC.Face.TOP,
			{ { 0, 0, rh00 }, { 1, 0, rh10 }, { 1, 1, rh11 }, { 0, 1, rh01 } },
			{ { 0, 16 }, { 16, 16 }, { 16, 0 }, { 0, 0 } }
		)
	end

	local nbDown = MC.GetBlock( bx, by, bz - 1 )
	local renderDown = visible( id, nbDown, MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz - 1 ) or 0 )
	local bottomZ = bottom + ( renderDown and C.FLUID_FACE_OFFSET or 0 ) * C.BS
	if renderDown then
		tile = MC.BlockFace( id, MC.Face.BOTTOM, orient )
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			{ { x0, y1, bottomZ }, { x1, y1, bottomZ }, { x1, y0, bottomZ }, { x0, y0, bottomZ } },
			C.N_DOWN, C.SH_BOTTOM, tile, bx, by, bz, id, MC.Face.BOTTOM,
			{ { 0, 1, 0 }, { 1, 1, 0 }, { 1, 0, 0 }, { 0, 0, 0 } },
			{ { 0, 16 }, { 16, 16 }, { 16, 0 }, { 0, 0 } }
		)
	end

	local function sideV( height )
		return math.Clamp( ( 1 - height ) * 8, 0, 8 )
	end

	local sideBottomV = 8
	local sideBottom = bottomZ
	local sideInset = C.FLUID_FACE_OFFSET * C.BS

	if visible( id, MC.GetBlock( bx + 1, by, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx + 1, by, bz ) or 0 ) then
		tile = MC.BlockFace( id, MC.Face.XP, orient )
		local sx = x1 - sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			{ { sx, y0, sideBottom }, { sx, y1, sideBottom }, { sx, y1, z11 }, { sx, y0, z10 } },
			C.N_XP, C.SH_X, tile, bx, by, bz, id, MC.Face.XP,
			{ { 1, 0, 0 }, { 1, 1, 0 }, { 1, 1, rh11 }, { 1, 0, rh10 } },
			{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh11 ) }, { 0, sideV( rh10 ) } }
		)
	end

	if visible( id, MC.GetBlock( bx - 1, by, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx - 1, by, bz ) or 0 ) then
		tile = MC.BlockFace( id, MC.Face.XN, orient )
		local sx = x0 + sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			{ { sx, y1, sideBottom }, { sx, y0, sideBottom }, { sx, y0, z00 }, { sx, y1, z01 } },
			C.N_XN, C.SH_X, tile, bx, by, bz, id, MC.Face.XN,
			{ { 0, 1, 0 }, { 0, 0, 0 }, { 0, 0, rh00 }, { 0, 1, rh01 } },
			{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh00 ) }, { 0, sideV( rh01 ) } }
		)
	end

	if visible( id, MC.GetBlock( bx, by + 1, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx, by + 1, bz ) or 0 ) then
		tile = MC.BlockFace( id, MC.Face.YP, orient )
		local sy = y1 - sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			{ { x1, sy, sideBottom }, { x0, sy, sideBottom }, { x0, sy, z01 }, { x1, sy, z11 } },
			C.N_YP, C.SH_Y, tile, bx, by, bz, id, MC.Face.YP,
			{ { 1, 1, 0 }, { 0, 1, 0 }, { 0, 1, rh01 }, { 1, 1, rh11 } },
			{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh01 ) }, { 0, sideV( rh11 ) } }
		)
	end

	if visible( id, MC.GetBlock( bx, by - 1, bz ), MC.GetBlockOrient and MC.GetBlockOrient( bx, by - 1, bz ) or 0 ) then
		tile = MC.BlockFace( id, MC.Face.YN, orient )
		local sy = y0 + sideInset
		emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle,
			{ { x0, sy, sideBottom }, { x1, sy, sideBottom }, { x1, sy, z10 }, { x0, sy, z00 } },
			C.N_YN, C.SH_Y, tile, bx, by, bz, id, MC.Face.YN,
			{ { 0, 0, 0 }, { 1, 0, 0 }, { 1, 0, rh10 }, { 0, 0, rh00 } },
			{ { 0, sideBottomV }, { 8, sideBottomV }, { 8, sideV( rh10 ) }, { 0, sideV( rh00 ) } }
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

local function selectBlockEmitter( ctx, b, id, orient, blockIsFullCube )
	if b and b.shape == "cross" then return BlockEmitters.cross end
	if b and b.shape == "model" and not modelUsesConnectionShape( b, id ) then return BlockEmitters.model end
	if isLiquidBlock( id ) then return BlockEmitters.liquid end
	if MC.BlockIsFullCube and blockIsFullCube and blockIsFullCube( id, orient ) then return BlockEmitters.fullCube end
	return BlockEmitters.shape
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
		template = getShapeTemplate( b, id, orient, blockBoxes )
	end
	if isConnShape and emitConnectionShapeBlock( ctx, connectionKind, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceCoveredAt, shapeFaceNeighborCoveredAt, currentEmitLightStyle ) then
		return "shape", false, 0
	end
	if template then
		emitShapeBlockTemplate( template, id, bx, by, bz, wx, wy, wz, lx, ly, lz, li, push, lightMetaFast, shapeFaceNeighborCoveredAt, currentEmitLightStyle )
		return "shape", false, 0
	end

	local boxes = blockBoxes and blockBoxes( id, orient, bx, by, bz ) or nil
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
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
				local tile = fd and fd.tile or MC.BlockFace( id, f, orient )
				local quadLightEmission = fd and fd.lightEmission or 0
				local u0, v0, u1, v1
				if fd and fd.uv then
					u0, v0, u1, v1 = tileUVRect( tile, fd.uv )
				end
				local nrm, col = face.n, face.sh
				local c1x, c1y, c1z = boxFaceCornerValues( box, f, 1 )
				local c2x, c2y, c2z = boxFaceCornerValues( box, f, 2 )
				local c3x, c3y, c3z = boxFaceCornerValues( box, f, 3 )
				local c4x, c4y, c4z = boxFaceCornerValues( box, f, 4 )
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
	RM.EmitCrossBlock( ctx, id, bx, by, bz, wx, wy, wz, ctx.push, ctx.lightMeta, ctx.currentEmitLightStyle )
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
	if MC.BlockIsFullCube and ctx.blockIsFullCube and ctx.blockIsFullCube( id, orient ) and emitFullCubeBlockRecord then
		return emitFullCubeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	end
	return emitShapeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
end

emitLiquidBlockRecord = function( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	if ctx.prepareBlockCacheBuffer( targetBuffer )
		and RM.EmitLiquidBlock( ctx, id, orient, bx, by, bz, wx, wy, wz, ctx.push, ctx.lightMeta, ctx.currentEmitLightStyle ) then
		return "liquid", false, 0
	end
	if MC.BlockIsFullCube and ctx.blockIsFullCube and ctx.blockIsFullCube( id, orient ) and emitFullCubeBlockRecord then
		return emitFullCubeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	end
	return emitShapeBlockRecord( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
end

emitFullCubeBlockRecord = function( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	local meshPerf = ctx.meshPerf
	local meshProbe = ctx.meshProbe
	local visibleAt = ctx.visibleAt
	local lightMetaFast = ctx.lightMetaFast
	local flush = ctx.flush
	local push = ctx.push
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local visibleFaceCount = 0
	local visibleFaceMask = 0
	local fullVisibleStart = meshProbe and SysTime() or nil
	for f = 1, 6 do
		local face = C.FACES[f]
		local o = face.off
		if visibleAt( id, lx + o[1], ly + o[2], lz + o[3], bx + o[1], by + o[2], bz + o[3] ) then
			visibleFaceCount = visibleFaceCount + 1
			visibleFaceMask = bit_bor( visibleFaceMask, bit_lshift( 1, f - 1 ) )
		end
	end
	if fullVisibleStart then meshPerfAdd( meshPerf, "fullVisibleMS", fullVisibleStart ) end
	meshPerf.fullVisibleFaces = meshPerf.fullVisibleFaces + visibleFaceCount
	local directEmitVertexCount = visibleFaceCount * 6
	local directEmitCheapFullCube = not shouldStoreBlockEmissionCache( "fullCube", directEmitVertexCount )
	if directEmitCheapFullCube then meshPerf.fullDirectBlocks = meshPerf.fullDirectBlocks + 1 end
	if directEmitCheapFullCube then
		if targetBuffer.nv + directEmitVertexCount >= C.VERT_LIMIT then flush( targetBuffer ) end
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
			local baked = bakedFaceData( id, f, orient )
			local tile, rot, flipU, flipV
			local u0, v0, u1, v1
			local quadLightEmission = baked and baked.lightEmission or 0
			if baked then
				tile = baked.tile
				rot = baked.rot or 0
				u0, v0, u1, v1 = tileUVRect( tile, baked.uv )
			else
				tile, rot, flipU, flipV = MC.BlockFace( id, f, orient )
				u0, v0, u1, v1 = MC.TileUV( tile )
			end
			local corners = face.c
			local nrm = face.n
			local shadeIndex = shadeIndexForFace( f )
			if faceStart then meshPerfAdd( meshPerf, "fullFaceMS", faceStart ) end
			local colorStart = meshProbe and SysTime() or nil
			local color1, color2, color3, color4 = fullCubeFaceCornerColors( shadeIndex, bx, by, bz, f, emission, emitLightStyle, receiveAO )
			if colorStart then meshPerfAdd( meshPerf, "fullColorMS", colorStart ) end
			local metaStart = meshProbe and SysTime() or nil
			local c1, c2, c3, c4 = corners[1], corners[2], corners[3], corners[4]
			local meta1 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c1[1], c1[2], c1[3], emission, true, quadLightEmission )
			local meta2 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c2[1], c2[2], c2[3], emission, true, quadLightEmission )
			local meta3 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c3[1], c3[2], c3[3], emission, true, quadLightEmission )
			local meta4 = lightMetaFast( shadeIndex, bx, by, bz, id, f, li, c4[1], c4[2], c4[3], emission, true, quadLightEmission )
			meta1.shared, meta2.shared, meta3.shared, meta4.shared = true, true, true, true
			if metaStart then meshPerfAdd( meshPerf, "fullMetaMS", metaStart ) end
			pushFullCubeFace( push, wx, wy, wz, nrm, corners, baked, tile, u0, v0, u1, v1, rot, flipU, flipV, color1, color2, color3, color4, meta1, meta2, meta3, meta4, meshProbe, meshPerf )
		end
	end
	return "fullCube", directEmitCheapFullCube, directEmitVertexCount
end

BlockEmitters.cross = emitCrossBlockRecord
BlockEmitters.model = emitModelBlockRecord
BlockEmitters.liquid = emitLiquidBlockRecord
BlockEmitters.fullCube = emitFullCubeBlockRecord
BlockEmitters.shape = emitShapeBlockRecord

local function emitSelectedBlock( emitter, ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
	emitter = emitter or BlockEmitters.shape
	return emitter( ctx, b, id, orient, bx, by, bz, wx, wy, wz, lx, ly, lz, li, targetBuffer )
end


function RM.EmitBlock( ctx, li, id )
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
		local orient = MC.NormalizeOrient( id, chunk.orients[li] )
		local lx, ly, lz = DecodeLocal( li )
		local buffers = buffersForLocal( lx, ly, lz )
		if not buffers then return end
		local bx, by, bz = bxo + lx, byo + ly, bzo + lz
		local wx, wy, wz = lx * C.BS, ly * C.BS, lz * C.BS
		local blockSectionIndex = MC.RenderSectionIndexForLocal( lx, ly, lz )

		if meshDebugFullCubeOnly() and not ( MC.BlockIsFullCube and blockIsFullCube and blockIsFullCube( id, orient ) ) then
			MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
			if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
			return
		end

		local targetBuffer = ( MC.IsTranslucentBlock and MC.IsTranslucentBlock( id ) ) and buffers.translucent or buffers.opaque
		local targetLightStyle = styleForBuffer( targetBuffer )
		local cached = MC.GetCachedBlockEmission( key, blockSectionIndex, li, id, orient )
		local blockNeedsRecolor = sectionNeedsFullRecolor or ( blockLightDirtySection and blockLightDirtySection[li] )
		if cached and ( blockNeedsRecolor or cached.lightStyle ~= targetLightStyle ) then
			local recolorStart = SysTime()
			if recolorCachedBlockEmission( cached, targetLightStyle, meshPerf ) then
				meshPerfAdd( meshPerf, "recolorMS", recolorStart )
				meshPerf.blockCacheRecolors = meshPerf.blockCacheRecolors + 1
			else
				MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
				cached = nil
			end
		end
		if cached then
			meshPerf.blockCacheHits = meshPerf.blockCacheHits + 1
			local cacheAppendStart = meshProbe and SysTime() or nil
			local appended = MC.AppendCachedBlockEmission( cached, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
			if cacheAppendStart then meshPerfAdd( meshPerf, "cacheAppendMS", cacheAppendStart ) end
			if appended > 0 then meshPerf.blocksRendered = meshPerf.blocksRendered + 1 end
			local cachedKind = cached.kind or "shape"
			meshPerfAddBlockKind( meshPerf, cachedKind )
			return
		end

		meshPerf.blockCacheMisses = meshPerf.blockCacheMisses + 1
		ctx.setCur( nil )

		local emitStart = SysTime()
		local b = blocksById[id]
		local emitter = selectBlockEmitter( ctx, b, id, orient, blockIsFullCube )
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
			targetBuffer
		)
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
				vertexCount = emittedVertices,
				material = targetBuffer.material,
				translucent = targetBuffer.translucent,
				kind = emitKind,
			} or nil
			if shouldStoreBlockEmissionCache( emitKind, emittedVertices ) then
				blockRecord = MC.StoreBlockEmissionCache( key, blockSectionIndex, li, id, orient, targetLightStyle, blockRecord )
			else
				MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
				if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
			end
			MC.AppendCachedBlockEmission( blockRecord, targetBuffer, flush, meshPerf, C.VERT_LIMIT )
		end
		if emittedVertices > 0 then
			meshPerf.blocksRendered = meshPerf.blocksRendered + 1
		end
		meshPerfAddBlockKind( meshPerf, emitKind )
		local emitMS = meshPerfElapsedMS( emitStart )
		meshPerf.emitMS = meshPerf.emitMS + emitMS
		meshPerfAddKindDuration( meshPerf, emitKind, emitMS )
	ctx.setCur( cur )
end
