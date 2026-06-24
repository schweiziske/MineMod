-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local bit_band, bit_bor, bit_lshift = bit.band, bit.bor, bit.lshift
local meshDebugFullCubeOnly = RM.meshDebugFullCubeOnly
local lightmapStyleUsesHardware = RM.lightmapStyleUsesHardware
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
local dynamicShapeFaceData = RM.dynamicShapeFaceData
local BOX_UV_FLAGS = RM.BOX_UV_FLAGS
local fullCubeFaceCornerColors = RM.fullCubeFaceCornerColors
local quadCornerColors = RM.quadCornerColors
local quadCornerColorValues = RM.quadCornerColorValues
local shadeIndexForFace = RM.shadeIndexForFace
local cornerXYZ = RM.cornerXYZ
local quadFaceCubic = RM.quadFaceCubic
local weightedLightmapQuadForFace = RM.weightedLightmapQuadForFace
local visible = RM.visible
local fluidHeightAt = RM.fluidHeightAt
local calculateAverageFluidHeight = RM.calculateAverageFluidHeight
local recolorCachedBlockEmission = RM.recolorCachedBlockEmission

local function shapeTriCornerValues( ci, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z, color1, color2, color3, color4 )
	if ci == 1 then return c1x, c1y, c1z, color1 end
	if ci == 2 then return c2x, c2y, c2z, color2 end
	if ci == 3 then return c3x, c3y, c3z, color3 end
	return c4x, c4y, c4z, color4
end

local function shapeTriUV( fd, ci, faceIndex, cx, cy, cz, tile, u0, v0, u1, v1 )
	if fd and fd.uv then
		local flags = BOX_UV_FLAGS[ci]
		local uf, vf = rotatedUVFlags( flags[1], flags[2], fd.rot or 0 )
		return uf == 1 and u1 or u0, vf == 1 and v1 or v0
	end
	local cu, cv = cornerUV16Raw( faceIndex, cx, cy, cz )
	return tileUVPointRaw( tile, cu, cv )
end

local function emitQuad( ctx, cur, push, lightMeta, currentEmitLightStyle, corners, normal, color, tile, bx, by, bz, id, faceIndex )
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	local color1, color2, color3, color4 = quadCornerColors( color, bx, by, bz, id, faceIndex, corners, emission, emitLightStyle )
	local x1, y1, z1 = cornerXYZ( corners[1] )
	local x2, y2, z2 = cornerXYZ( corners[2] )
	local x3, y3, z3 = cornerXYZ( corners[3] )
	local x4, y4, z4 = cornerXYZ( corners[4] )
	local weightedLightmapQuad = lightmapStyleUsesHardware( emitLightStyle )
		and weightedLightmapQuadForFace( faceIndex, true, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 ) or nil
	for t = 1, 6 do
		local ci = C.TRI[t]
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
		}, lightMeta( color, bx, by, bz, id, faceIndex, cn, emission, weightedLightmapQuad ) )
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

function RM.EmitModelBlock( ctx, b, orient, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	local quads = rotatedModelQuads( b, orient )
	if not quads then return false end
	local mirrorU = b.orient == "door"
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( b.id ) or 0
	for _, quad in ipairs( quads ) do
		local faceIndex = quad.face or MC.Face.TOP
		local face = C.FACES[faceIndex] or C.FACES[MC.Face.TOP]
		local u0, v0, u1, v1 = tileUVRect( quad.tile or 0, quad.uv )
		local quadLightEmission = quad.lightEmission or 0
		local emitLightStyle = currentEmitLightStyle()
		local color1, color2, color3, color4 = quadCornerColors( face.sh, bx, by, bz, b.id, faceIndex, quad.verts, emission, emitLightStyle )
		local v1x, v1y, v1z = cornerXYZ( quad.verts[1] )
		local v2x, v2y, v2z = cornerXYZ( quad.verts[2] )
		local v3x, v3y, v3z = cornerXYZ( quad.verts[3] )
		local v4x, v4y, v4z = cornerXYZ( quad.verts[4] )
		local faceCubic = quadFaceCubic( faceIndex, b.id, orient, v1x, v1y, v1z, v2x, v2y, v2z, v3x, v3y, v3z, v4x, v4y, v4z )
		local weightedLightmapQuad = lightmapStyleUsesHardware( emitLightStyle )
			and weightedLightmapQuadForFace( faceIndex, faceCubic, v1x, v1y, v1z, v2x, v2y, v2z, v3x, v3y, v3z, v4x, v4y, v4z ) or nil
		for t = 1, 6 do
			local ci = C.TRI[t]
			local vert = quad.verts[ci]
			local uf, vf = rotatedUVFlags( vert.u or 0, vert.v or 0, quad.rot or 0 )
			if mirrorU then uf = 1 - uf end
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
				pos    = Vector( wx + vert.x * C.BS, wy + vert.y * C.BS, wz + vert.z * C.BS ),
				normal = face.n,
				u      = uf == 1 and u1 or u0,
				v      = vf == 1 and v1 or v0,
				color  = vertColor,
			}, lightMeta( face.sh, bx, by, bz, b.id, faceIndex, vert, emission, weightedLightmapQuad, faceCubic, quadLightEmission ) )
		end
	end
	return true
end

local function emitFluidQuad( ctx, push, lightMeta, currentEmitLightStyle, verts, normal, shade, tile, bx, by, bz, id, faceIndex, lightCorners, uvCorners )
	local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
	local emitLightStyle = currentEmitLightStyle()
	local color1, color2, color3, color4 = quadCornerColors( shade, bx, by, bz, id, faceIndex, lightCorners, emission, emitLightStyle )
	local x1, y1, z1 = cornerXYZ( lightCorners[1] )
	local x2, y2, z2 = cornerXYZ( lightCorners[2] )
	local x3, y3, z3 = cornerXYZ( lightCorners[3] )
	local x4, y4, z4 = cornerXYZ( lightCorners[4] )
	local faceCubic = quadFaceCubic( faceIndex, id, 0, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	local weightedLightmapQuad = lightmapStyleUsesHardware( emitLightStyle )
		and weightedLightmapQuadForFace( faceIndex, faceCubic, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 ) or nil
	for t = 1, 6 do
		local ci = C.TRI[t]
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
		}, lightMeta( shade, bx, by, bz, id, faceIndex, lightCorners[ci], emission, weightedLightmapQuad, faceCubic ) )
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
	local blockBoxes = ctx.blockBoxes
	local blocksById = ctx.blocksById
	local cur = ctx.getCur()
	local function flush( buf ) return ctx.flush( buf ) end
	local function push( vert, light ) ctx.setCur( cur ); local result = ctx.push( vert, light ); cur = ctx.getCur(); return result end
	local function lightMeta( ... ) return ctx.lightMeta( ... ) end
	local function lightMetaValues( ... ) return ctx.lightMetaValues( ... ) end
	local function prepareBlockCacheBuffer( targetBuffer ) local ok = ctx.prepareBlockCacheBuffer( targetBuffer ); cur = ctx.getCur(); return ok end
	local function buffersForLocal( lx, ly, lz ) return ctx.buffersForLocal( lx, ly, lz ) end
	local function visibleAt( ... ) return ctx.visibleAt( ... ) end
	local function shapeFaceCoveredAt( ... ) return ctx.shapeFaceCoveredAt( ... ) end
	local function styleForBuffer( buf ) return ctx.styleForBuffer( buf ) end
	local function currentEmitLightStyle() return ctx.currentEmitLightStyle() end
	local function emitCrossBlock( blockId, bx, by, bz, wx, wy, wz )
		return RM.EmitCrossBlock( ctx, blockId, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	end
	local function emitModelBlock( block, orient, bx, by, bz, wx, wy, wz )
		return RM.EmitModelBlock( ctx, block, orient, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	end
	local function emitLiquidBlock( blockId, orient, bx, by, bz, wx, wy, wz )
		return RM.EmitLiquidBlock( ctx, blockId, orient, bx, by, bz, wx, wy, wz, push, lightMeta, currentEmitLightStyle )
	end
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
		if cached and cached.lightmap ~= targetBuffer.lightmap then
			MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
			cached = nil
		end
		if cached and ( blockNeedsRecolor or cached.lightStyle ~= targetLightStyle ) then
			local recolorStart = SysTime()
			if recolorCachedBlockEmission( cached, targetLightStyle ) then
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
		cur = nil

		local emitStart = SysTime()
		local emitKind = "shape"
		local directEmitCheapFullCube = false
		local directEmitVertexCount = 0
		local b = blocksById[id]
		if b and b.shape == "cross" then
			emitKind = "cross"
			prepareBlockCacheBuffer( targetBuffer )
			emitCrossBlock( id, bx, by, bz, wx, wy, wz )
		elseif b and b.shape == "model" and not ( ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) or ( MC.IsWallBlock and MC.IsWallBlock( id ) ) or b.connection == "pipe6" ) and prepareBlockCacheBuffer( targetBuffer ) and emitModelBlock( b, orient, bx, by, bz, wx, wy, wz ) then
			emitKind = "model"
			-- rendered from exact Minecraft model quads; boxes remain for collision/outline
		elseif isLiquidBlock( id ) and prepareBlockCacheBuffer( targetBuffer ) and emitLiquidBlock( id, orient, bx, by, bz, wx, wy, wz ) then
			emitKind = "liquid"
			-- rendered with Minecraft fluid surface height/offsets instead of full cube faces
		elseif MC.BlockIsFullCube and blockIsFullCube and blockIsFullCube( id, orient ) then
			emitKind = "fullCube"
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
			directEmitVertexCount = visibleFaceCount * 6
			directEmitCheapFullCube = not shouldStoreBlockEmissionCache( emitKind, directEmitVertexCount )
			if directEmitCheapFullCube then meshPerf.fullDirectBlocks = meshPerf.fullDirectBlocks + 1 end
			if directEmitCheapFullCube then
				if targetBuffer.nv + directEmitVertexCount >= C.VERT_LIMIT then flush( targetBuffer ) end
				cur = targetBuffer
				ctx.setCur( cur )
			else
				prepareBlockCacheBuffer( targetBuffer )
			end
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
					local nrm, col = face.n, face.sh
					local shadeIndex = shadeIndexForFace( f )
					if faceStart then meshPerfAdd( meshPerf, "fullFaceMS", faceStart ) end
					local colorStart = meshProbe and SysTime() or nil
					local color1, color2, color3, color4 = fullCubeFaceCornerColors( shadeIndex, bx, by, bz, f, emission, currentEmitLightStyle() )
					if colorStart then meshPerfAdd( meshPerf, "fullColorMS", colorStart ) end

					for t = 1, 6 do
						local ci = C.TRI[t]
						local cn = corners[ci]
						local u, v
						if baked and baked.uvs then
							local uv = baked.uvs[ci]
							u, v = tileUVPointRaw( tile, uv and uv[1], uv and uv[2] )
						else
							local uf, vf = rotatedUVFlags( cn[4], cn[5], rot or 0, flipU, flipV )
							u = uf == 1 and u1 or u0
							v = vf == 1 and v1 or v0
						end
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
						if meshProbe then
							local vertexStart = SysTime()
							local vert = {
								pos    = Vector( wx + cn[1] * C.BS, wy + cn[2] * C.BS, wz + cn[3] * C.BS ),
								normal = nrm,
								u      = u,
								v      = v,
								color  = vertColor,
							}
							meshPerfAdd( meshPerf, "fullVertexMS", vertexStart )
							local metaStart = SysTime()
							local meta = lightMeta( col, bx, by, bz, id, f, cn, emission, nil, nil, quadLightEmission )
							meshPerfAdd( meshPerf, "fullMetaMS", metaStart )
							local pushStart = SysTime()
							push( vert, meta )
							meshPerfAdd( meshPerf, "fullPushMS", pushStart )
						else
							push( {
								pos    = Vector( wx + cn[1] * C.BS, wy + cn[2] * C.BS, wz + cn[3] * C.BS ),
								normal = nrm,
								u      = u,
								v      = v,
								color  = vertColor,
							}, lightMeta( col, bx, by, bz, id, f, cn, emission, nil, nil, quadLightEmission ) )
						end
					end
				end
			end
		else
			-- fence/pane/wall/pipe boxes come from the runtime connection logic, so their
			-- indices do not line up with the generator's static boxFaces list;
			-- only the centre post (box 1) may take static face data
			prepareBlockCacheBuffer( targetBuffer )
			local isPipe6Shape = b and b.connection == "pipe6"
			local isConnShape = ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) or ( MC.IsWallBlock and MC.IsWallBlock( id ) ) or isPipe6Shape
			local boxes = blockBoxes and blockBoxes( id, orient, bx, by, bz ) or nil
			local emission = MC.BlockLightEmission and MC.BlockLightEmission( id ) or 0
			for boxIndex, box in ipairs( boxes or {} ) do
				for f = 1, 6 do
					repeat
						if shapeFaceCoveredAt( id, box, f, boxes, bx, by, bz, lx, ly, lz ) then break end
						local face = C.FACES[f]
						local modelFaces = b and b.boxFaces
						if isPipe6Shape then modelFaces = nil end
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
						local weightedLightmapQuad = lightmapStyleUsesHardware( emitLightStyle )
							and weightedLightmapQuadForFace( f, faceCubic, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z ) or nil
						for t = 1, 6 do
							local ci = C.TRI[t]
							local cx, cy, cz, color = shapeTriCornerValues( ci, c1x, c1y, c1z, c2x, c2y, c2z, c3x, c3y, c3z, c4x, c4y, c4z, color1, color2, color3, color4 )
							local u, v = shapeTriUV( fd, ci, f, cx, cy, cz, tile, u0, v0, u1, v1 )
							push( {
								pos    = Vector( wx + cx * C.BS, wy + cy * C.BS, wz + cz * C.BS ),
								normal = nrm,
								u      = u,
								v      = v,
								color  = color,
							}, lightMetaValues( col, bx, by, bz, id, f, cx, cy, cz, emission, weightedLightmapQuad, faceCubic, quadLightEmission ) )
						end
					until true
				end
			end
		end
		local emittedVertices = directEmitCheapFullCube and directEmitVertexCount or ( cur and cur.nv or 0 )
		if directEmitCheapFullCube then
			MC.DropBlockEmitCacheRecord( key, blockSectionIndex, li )
			if MC.ClearBlockCacheDirtySlot then MC.ClearBlockCacheDirtySlot( key, blockSectionIndex, li ) end
		else
			local blockRecord = {
				verts = cur.verts,
				light = cur.light,
				vertexCount = emittedVertices,
				material = targetBuffer.material,
				translucent = targetBuffer.translucent,
				lightmap = targetBuffer.lightmap == true,
				kind = emitKind,
			}
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
