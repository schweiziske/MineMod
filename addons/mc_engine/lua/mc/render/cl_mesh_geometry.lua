-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local GeometryStore = MC.RenderGeometryStore
local geometrySections
local CS = C.CS
local CS2 = C.CS2
local CH = C.CH
local RENDER_SECTION_SIZE = MC.RENDER_SECTION_SIZE or 8
local RENDER_SECTIONS_XY = C.RENDER_SECTIONS_XY
local RENDER_SECTIONS_Z = C.RENDER_SECTIONS_Z

MC.Meshes      = MC.Meshes or {}      -- key -> { IMesh, ... } (opaque/cutout pass)
MC.MeshesTrans = MC.MeshesTrans or {} -- key -> { IMesh, ... } (translucent pass)
MC.MeshSections = MC.MeshSections or {} -- key -> sectionIndex -> { opaque = {}, translucent = {} }
geometrySections = GeometryStore.sections
MC.MeshDirty = MC.MeshDirty or {}  -- key -> true
MC.MeshLightDirty = MC.MeshLightDirty or {} -- key -> sectionIndex -> true for light-only colour updates
MC.MeshDirtyRateLimited = MC.MeshDirtyRateLimited or {} -- key -> true for explosion-driven mesh rebuilds
MC.ChunkEnts = MC.ChunkEnts or {}  -- key -> mc_chunk entity (clientside physics owner)
MC.PhysDirty = MC.PhysDirty or {}  -- key -> true while a clientside collision rebuild is being fired
MC.PhysDirtyPriority = MC.PhysDirtyPriority or {} -- key -> true for priority rebuild diagnostics
MC.PhysDirtyBulk = MC.PhysDirtyBulk or {} -- key -> true when bulk client collision rebuild is throttled
MC.PhysDirtyBulkOrder = MC.PhysDirtyBulkOrder or {}
MC.PhysDirtyBulkOrderHead = MC.PhysDirtyBulkOrderHead or 1
MC.ClientPhysRetryPending = MC.ClientPhysRetryPending or {}
MC.ClientPhysRetryAttempts = MC.ClientPhysRetryAttempts or {}
MC.RenderStats = MC.RenderStats or {}
MC.ClientPhysStats = MC.ClientPhysStats or {}
MC.ClientPhysBuiltSignatures = MC.ClientPhysBuiltSignatures or {}
MC.ClientPhysBuiltHadObjects = MC.ClientPhysBuiltHadObjects or {}
MC.ClientPhysBuiltObjectCounts = MC.ClientPhysBuiltObjectCounts or {}
MC.ClientPhysTargetSignatures = MC.ClientPhysTargetSignatures or {}
MC.ClientCollisionPlayerInterest = MC.ClientCollisionPlayerInterest or {}
MC.ClientCollisionAimInterest = MC.ClientCollisionAimInterest or {}


-- should the face between `cur` and neighbour `nb` be drawn?
local function sameLiquidKind( cur, nb )
	if not MC.LiquidKind then return false end
	local curKind = MC.LiquidKind( cur )
	if not curKind then return false end
	return curKind == MC.LiquidKind( nb )
end

local function visible( cur, nb, nbOrient )
	if nb == 0 then return true end
	if sameLiquidKind( cur, nb ) then return false end
	local d = MC.Blocks[nb]
	if d and d.transparent then return nb ~= cur end
	if MC.BlockIsFullCube and not MC.BlockIsFullCube( nb, nbOrient ) then return true end
	return false
end

local FLUID_FACE_OFFSET = 0.001
MC.RenderMeshConstants.FLUID_FACE_OFFSET = FLUID_FACE_OFFSET

local function isLiquidBlock( id )
	if MC.IsLiquidBlock then return MC.IsLiquidBlock( id ) end
	return MC.LiquidKind and MC.LiquidKind( id ) ~= nil or false
end

------------------------------------------------------------------ mesh lifecycle
local function destroyEntry( entry, report )
	if type( entry ) == "table" and entry.l2 then
		local resource = entry.resource
		entry.resource, entry.mesh = nil, nil
		if resource then MC.RenderPackGeometry.Release( resource, report ) end
		return
	end
	local meshObj = type( entry ) == "table" and entry.mesh or entry
	if meshObj and meshObj.Destroy then
		local ok, err = pcall( meshObj.Destroy, meshObj )
		if not ok then ( report or MC.Fault )( "render_mesh_destroy", tostring( err ) ) end
	end
end

local function destroyMeshList( store, key, report )
	local list = store[key]
	if not list then return end
	store[key] = nil
	for i = 1, #list do
		destroyEntry( list[i], report )
	end
end

local function destroySectionMeshList( list, report )
	if not list then return end
	local faults = {}
	local function collect( code, message )
		faults[#faults + 1] = { code = code, message = message }
	end
	for i = 1, #list do
		destroyEntry( list[i], report or collect )
	end
	local firstError
	for _, fault in ipairs( faults ) do
		local ok, err = pcall( MC.Fault, fault.code, "%s", fault.message )
		if not ok and not firstError then firstError = err end
	end
	if firstError then error( firstError, 0 ) end
end

local clearChunkBlockEmitCache = MC.ClearChunkBlockEmitCache

local function rebuildFlatMeshLists( key )
	local sections = MC.MeshSections[key]
	if not sections then
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
		if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty( key ) end
		return
	end
	local opaque, translucent = {}, {}
	local totalSections = RENDER_SECTIONS_XY * RENDER_SECTIONS_XY * RENDER_SECTIONS_Z
	for i = 1, totalSections do
		local section = sections[i]
		if section then
			for j = 1, #( section.opaque or {} ) do opaque[#opaque + 1] = section.opaque[j] end
			for j = 1, #( section.translucent or {} ) do translucent[#translucent + 1] = section.translucent[j] end
		end
	end
	MC.Meshes[key] = #opaque > 0 and opaque or nil
	MC.MeshesTrans[key] = #translucent > 0 and translucent or nil
	if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty( key ) end
end

function MC.FreeChunkMesh( key, keepBlockEmitCache )
	if MC.RenderOcclusion then MC.RenderOcclusion.Forget( key ) end
	if MC.MarkChunkDrawListDirty then MC.MarkChunkDrawListDirty( key ) end
	if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	if MC.MeshLightDirty then MC.MeshLightDirty[key] = nil end
	if not keepBlockEmitCache then clearChunkBlockEmitCache( key ) end
	local faults = {}
	local function collect( code, message )
		faults[#faults + 1] = { code = code, message = message }
	end
	local sections = MC.MeshSections[key]
	MC.MeshSections[key] = nil
	if MC.ForgetChunkMeshSectionGeometryCache then
		MC.ForgetChunkMeshSectionGeometryCache( key )
	else
		GeometryStore.ClearChunk( key )
	end
	if sections then
		MC.Meshes[key], MC.MeshesTrans[key] = nil, nil
		for _, section in pairs( sections ) do
			destroySectionMeshList( section.opaque, collect )
			destroySectionMeshList( section.translucent, collect )
		end
	else
		destroyMeshList( MC.Meshes, key, collect )
		destroyMeshList( MC.MeshesTrans, key, collect )
	end
	local firstError
	for _, fault in ipairs( faults ) do
		local ok, err = pcall( MC.Fault, fault.code, "%s", fault.message )
		if not ok and not firstError then firstError = err end
	end
	if firstError then error( firstError, 0 ) end
end

local function DecodeLocal( li )
	if MC.DecodeLocal then return MC.DecodeLocal( li ) end
	local lz = math.floor( li / CS2 )
	local ly = math.floor( ( li - lz * CS2 ) / CS )
	local lx = li - lz * CS2 - ly * CS
	return lx, ly, lz
end

local function rotatedUVFlags( uf, vf, rot, flipU, flipV )
	rot = rot % 4
	if rot == 1 then uf, vf = vf, 1 - uf
	elseif rot == 2 then uf, vf = 1 - uf, 1 - vf
	elseif rot == 3 then uf, vf = 1 - vf, uf end
	if flipU then uf = 1 - uf end
	if flipV then vf = 1 - vf end
	return uf, vf
end

local function tileUVRect( tile, uv )
	local A = MC.Atlas
	if MC.ResolveAtlasSurface then
		local page
		page, tile, A = MC.ResolveAtlasSurface( tile )
	else
		if not uv then return MC.TileUV( tile ) end
		tile = MC.ResolveAtlasTile and MC.ResolveAtlasTile( tile ) or tile
	end
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	local baseX = col * stride + pad
	local baseY = row * stride + pad
	local u0 = baseX + ( uv and tonumber( uv[1] ) or 0 ) / 16 * A.TILE + inset
	local v0 = baseY + ( uv and tonumber( uv[2] ) or 0 ) / 16 * A.TILE + inset
	local u1 = baseX + ( uv and tonumber( uv[3] ) or 16 ) / 16 * A.TILE - inset
	local v1 = baseY + ( uv and tonumber( uv[4] ) or 16 ) / 16 * A.TILE - inset
	return u0 / A.W, v0 / A.H, u1 / A.W, v1 / A.H
end

local function tileUVPointRaw( tile, u, v )
	local A = MC.Atlas
	if MC.ResolveAtlasSurface then
		local page
		page, tile, A = MC.ResolveAtlasSurface( tile )
	else
		tile = MC.ResolveAtlasTile and MC.ResolveAtlasTile( tile ) or tile
	end
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	u = tonumber( u ) or 0
	v = tonumber( v ) or 0
	local px = col * stride + pad + u / 16 * A.TILE
	local py = row * stride + pad + v / 16 * A.TILE
	if u <= 0 then px = px + inset elseif u >= 16 then px = px - inset end
	if v <= 0 then py = py + inset elseif v >= 16 then py = py - inset end
	return px / A.W, py / A.H
end

local function quadFaceCubic( faceIndex, id, orient, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	if MC.BlockIsFullCube and id and MC.BlockIsFullCube( id, orient or 0 ) then return true end
	local eps = 0.0001
	local minX, maxX = math.min( x1, x2, x3, x4 ), math.max( x1, x2, x3, x4 )
	local minY, maxY = math.min( y1, y2, y3, y4 ), math.max( y1, y2, y3, y4 )
	local minZ, maxZ = math.min( z1, z2, z3, z4 ), math.max( z1, z2, z3, z4 )
	if faceIndex == MC.Face.TOP then return math.abs( minZ - maxZ ) <= eps and maxZ > 1 - eps end
	if faceIndex == MC.Face.BOTTOM then return math.abs( minZ - maxZ ) <= eps and minZ < eps end
	if faceIndex == MC.Face.XP then return math.abs( minX - maxX ) <= eps and maxX > 1 - eps end
	if faceIndex == MC.Face.XN then return math.abs( minX - maxX ) <= eps and minX < eps end
	if faceIndex == MC.Face.YP then return math.abs( minY - maxY ) <= eps and maxY > 1 - eps end
	if faceIndex == MC.Face.YN then return math.abs( minY - maxY ) <= eps and minY < eps end
	return true
end

local function bakedFaceData( id, face, orient )
	local b = MC.Blocks[id]
	if not b or not b.baked then return nil end
	local baked = b.baked[orient] or b.baked[MC.DefaultOrient( id )] or b.baked[0]
	return baked and baked[face] or nil
end

local EPS = 0.0001

local function boxFaceCornerValues( b, face, corner )
	local x0, y0, z0, x1, y1, z1 = b[1], b[2], b[3], b[4], b[5], b[6]
	if face == MC.Face.TOP then
		if corner == 1 then return x0, y0, z1 end
		if corner == 2 then return x1, y0, z1 end
		if corner == 3 then return x1, y1, z1 end
		return x0, y1, z1
	elseif face == MC.Face.BOTTOM then
		if corner == 1 then return x0, y1, z0 end
		if corner == 2 then return x1, y1, z0 end
		if corner == 3 then return x1, y0, z0 end
		return x0, y0, z0
	elseif face == MC.Face.XP then
		if corner == 1 then return x1, y0, z0 end
		if corner == 2 then return x1, y1, z0 end
		if corner == 3 then return x1, y1, z1 end
		return x1, y0, z1
	elseif face == MC.Face.XN then
		if corner == 1 then return x0, y1, z0 end
		if corner == 2 then return x0, y0, z0 end
		if corner == 3 then return x0, y0, z1 end
		return x0, y1, z1
	elseif face == MC.Face.YP then
		if corner == 1 then return x1, y1, z0 end
		if corner == 2 then return x0, y1, z0 end
		if corner == 3 then return x0, y1, z1 end
		return x1, y1, z1
	end
	if corner == 1 then return x0, y0, z0 end
	if corner == 2 then return x1, y0, z0 end
	if corner == 3 then return x1, y0, z1 end
	return x0, y0, z1
end

local BOX_UV_FLAGS = {
	{ 0, 1 },
	{ 1, 1 },
	{ 1, 0 },
	{ 0, 0 },
}

local function rotateModelXY( x, y, steps )
	steps = steps % 4
	if steps == 1 then return 1 - y, x end
	if steps == 2 then return 1 - x, 1 - y end
	if steps == 3 then return y, 1 - x end
	return x, y
end

local function rotateModelXZ( y, z, steps )
	steps = steps % 4
	if steps == 1 then return 1 - z, y end
	if steps == 2 then return 1 - y, 1 - z end
	if steps == 3 then return z, 1 - y end
	return y, z
end

local function rotateModelFaceZ( face, steps )
	steps = steps % 4
	for _ = 1, steps do
		if face == MC.Face.YN then face = MC.Face.XP
		elseif face == MC.Face.XP then face = MC.Face.YP
		elseif face == MC.Face.YP then face = MC.Face.XN
		elseif face == MC.Face.XN then face = MC.Face.YN end
	end
	return face
end

local function rotateModelFaceX( face, steps )
	steps = steps % 4
	for _ = 1, steps do
		if face == MC.Face.YN then face = MC.Face.BOTTOM
		elseif face == MC.Face.BOTTOM then face = MC.Face.YP
		elseif face == MC.Face.YP then face = MC.Face.TOP
		elseif face == MC.Face.TOP then face = MC.Face.YN end
	end
	return face
end

local function modelOrientSteps( b, orient )
	if not b then return 0, 0 end
	orient = MC.NormalizeOrient( b.id, orient )
	if b.orient == "axis" then
		if orient == MC.Axis.X then return 1, 1 end
		if orient == MC.Axis.Z then return 1, 0 end
		return 0, 0
	end
	if b.orient ~= "horizontal_facing" and b.orient ~= "facing" and b.orient ~= "door" and b.orient ~= "trapdoor" and b.orient ~= "bed" then return 0, 0 end
	if b.orient == "facing" then
		-- down/up model variants are baked vertical already (see MC.BlockModelData)
		if orient == MC.Direction.DOWN then return ( b.modelVariants and b.modelVariants.down ) and 0 or 1, 0 end
		if orient == MC.Direction.UP then return ( b.modelVariants and b.modelVariants.up ) and 0 or 3, 0 end
	end
	if b.orient == "door" or b.orient == "trapdoor" or b.orient == "bed" then
		orient = MC.BlockHorizontalFacingForOrient and MC.BlockHorizontalFacingForOrient( b, orient ) or orient
	end
	if orient == MC.Direction.EAST then return 0, 1 end
	if orient == MC.Direction.SOUTH then return 0, 2 end
	if orient == MC.Direction.WEST then return 0, 3 end
	return 0, 0
end

local function rotateModelPoint( x, y, z, xSteps, zSteps )
	y, z = rotateModelXZ( y, z, xSteps )
	x, y = rotateModelXY( x, y, zSteps )
	return x, y, z
end

local function rotateModelFace( face, xSteps, zSteps )
	return rotateModelFaceZ( rotateModelFaceX( face, xSteps ), zSteps )
end

local function rotatedModelQuads( b, orient )
	local data = MC.BlockModelData and MC.BlockModelData( b, orient ) or b
	if not data or not data.modelQuads then return nil end
	local xSteps, zSteps = modelOrientSteps( b, orient )
	if xSteps == 0 and zSteps == 0 then return data.modelQuads end
	data._rotatedModelQuads = data._rotatedModelQuads or {}
	local cacheKey = xSteps * 4 + zSteps
	if data._rotatedModelQuads[cacheKey] then return data._rotatedModelQuads[cacheKey] end
	local out = {}
	for qi, quad in ipairs( data.modelQuads ) do
		local verts = {}
		for vi = 1, 4 do
			local vx, vy, vz, vu, vv = MC.ModelQuadVertex( quad, vi )
			local x, y, z = rotateModelPoint( vx, vy, vz, xSteps, zSteps )
			local offset = ( vi - 1 ) * 5
			verts[offset + 1], verts[offset + 2], verts[offset + 3] = x, y, z
			verts[offset + 4], verts[offset + 5] = vu, vv
		end
		out[qi] = {
			face = rotateModelFace( quad.face or MC.Face.TOP, xSteps, zSteps ),
			tile = quad.tile,
			surface = quad.surface,
			uv = quad.uv,
			rot = quad.rot or 0,
			tintIndex = quad.tintIndex or -1,
			lightEmission = quad.lightEmission or 0,
			verts = verts,
		}
	end
	data._rotatedModelQuads[cacheKey] = out
	return out
end

local function cornerUV16Raw( face, x, y, z )
	if face == MC.Face.TOP then return x * 16, ( 1 - y ) * 16 end
	if face == MC.Face.BOTTOM then return x * 16, y * 16 end
	if face == MC.Face.XP then return y * 16, ( 1 - z ) * 16 end
	if face == MC.Face.XN then return ( 1 - y ) * 16, ( 1 - z ) * 16 end
	if face == MC.Face.YP then return ( 1 - x ) * 16, ( 1 - z ) * 16 end
	return x * 16, ( 1 - z ) * 16
end

local function paneSideTile( b )
	if not b or not b.name then return b and b.side or 0 end
	-- bar blocks (iron_bars, copper_bars variants) keep their own lattice texture
	if b.connection == "bars" then return b.side end
	if b.name == "glass_pane" and MC.Tiles and MC.Tiles.glass then return MC.Tiles.glass end
	local glassName = string.match( b.name, "^(.*_stained_glass)_pane$" )
	if glassName and MC.Tiles and MC.Tiles[glassName] ~= nil then return MC.Tiles[glassName] end
	return b.side
end

-- connection-arm direction tag -> the face at the open end of that arm
local ARM_END_FACE = {
	yn = MC.Face.YN,
	yp = MC.Face.YP,
	xn = MC.Face.XN,
	xp = MC.Face.XP,
}
local PANE_ARM_EDGE_UV = { 7, 0, 9, 7 }

local function connectionShapeFaceValues( b, face, box )
	if not b then return nil end
	if b.connection == "pipe6" then
		return b.side, nil, true
	end
	if MC.IsPaneBlock and MC.IsPaneBlock( b.id ) then
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then
			if box and box.part == "arm" then
				return b.top, PANE_ARM_EDGE_UV, true
			end
			return b.top, nil, true
		end
		-- the open end of an arm shows the pane edge strip, like Minecraft's
		-- cullfaced #edge face on the pane side models
		if box and box.part == "arm" and ARM_END_FACE[box.dir] == face then
			return b.top, nil, true
		end
		return paneSideTile( b ), nil, true
	end
	if MC.IsFenceBlock and MC.IsFenceBlock( b.id ) then
		return b.side, nil, true
	end
	if MC.IsWallBlock and MC.IsWallBlock( b.id ) then
		return b.side, nil, true
	end
	return nil, nil, false
end

local function dynamicShapeFaceData( b, face, box )
	local tile, uv, ok = connectionShapeFaceValues( b, face, box )
	if not ok then return nil end
	if uv then return { tile = tile, rot = 0, uv = uv } end
	return { tile = tile, rot = 0 }
end

local function rectForFace( box, face )
	if face == MC.Face.TOP or face == MC.Face.BOTTOM then return box[1], box[4], box[2], box[5] end
	if face == MC.Face.XP or face == MC.Face.XN then return box[2], box[5], box[3], box[6] end
	return box[1], box[4], box[3], box[6]
end

local function facePlane( box, face )
	if face == MC.Face.TOP then return box[6] end
	if face == MC.Face.BOTTOM then return box[3] end
	if face == MC.Face.XP then return box[4] end
	if face == MC.Face.XN then return box[1] end
	if face == MC.Face.YP then return box[5] end
	return box[2]
end

local function coverRectForBox( box, face, plane, ox, oy, oz )
	local x0, y0, z0 = box[1] + ox, box[2] + oy, box[3] + oz
	local x1, y1, z1 = box[4] + ox, box[5] + oy, box[6] + oz
	if face == MC.Face.TOP and math.abs( z0 - plane ) <= EPS then return x0, x1, y0, y1 end
	if face == MC.Face.BOTTOM and math.abs( z1 - plane ) <= EPS then return x0, x1, y0, y1 end
	if face == MC.Face.XP and math.abs( x0 - plane ) <= EPS then return y0, y1, z0, z1 end
	if face == MC.Face.XN and math.abs( x1 - plane ) <= EPS then return y0, y1, z0, z1 end
	if face == MC.Face.YP and math.abs( y0 - plane ) <= EPS then return x0, x1, z0, z1 end
	if face == MC.Face.YN and math.abs( y1 - plane ) <= EPS then return x0, x1, z0, z1 end
	return nil
end

local function addEdge( list, value, lo, hi )
	if value > lo + EPS and value < hi - EPS then list[#list + 1] = value end
end

local function pointInRectFlat( a, b, covers, i )
	return a >= covers[i] - EPS and a <= covers[i + 1] + EPS and b >= covers[i + 2] - EPS and b <= covers[i + 3] + EPS
end

local function rectCovered( a0, a1, b0, b1, covers, coverValues )
	if not covers or coverValues <= 0 then return false end
	local as = { a0, a1 }
	local bs = { b0, b1 }
	for i = 1, coverValues, 4 do
		addEdge( as, math.max( a0, math.min( a1, covers[i] ) ), a0, a1 )
		addEdge( as, math.max( a0, math.min( a1, covers[i + 1] ) ), a0, a1 )
		addEdge( bs, math.max( b0, math.min( b1, covers[i + 2] ) ), b0, b1 )
		addEdge( bs, math.max( b0, math.min( b1, covers[i + 3] ) ), b0, b1 )
	end
	table.sort( as )
	table.sort( bs )
	for ai = 1, #as - 1 do
		for bi = 1, #bs - 1 do
			local ma = ( as[ai] + as[ai + 1] ) * 0.5
			local mb = ( bs[bi] + bs[bi + 1] ) * 0.5
			local ok = false
			for i = 1, coverValues, 4 do
				if pointInRectFlat( ma, mb, covers, i ) then ok = true break end
			end
			if not ok then return false end
		end
	end
	return true
end

local function coveredByBoxes( targetBox, face, boxes, ox, oy, oz )
	if not boxes or #boxes == 0 then return false end
	local plane = facePlane( targetBox, face )
	local a0, a1, b0, b1 = rectForFace( targetBox, face )
	local covers = nil
	local coverValues = 0
	ox, oy, oz = ox or 0, oy or 0, oz or 0
	local sameBlock = ox == 0 and oy == 0 and oz == 0
	for i = 1, #boxes do
		local box = boxes[i]
		-- Adjacent blocks may share one box template; identity excludes only self.
		if box ~= targetBox or not sameBlock then
			local ca0, ca1, cb0, cb1 = coverRectForBox( box, face, plane, ox, oy, oz )
			if ca0 and ca1 > a0 + EPS and ca0 < a1 - EPS and cb1 > b0 + EPS and cb0 < b1 - EPS then
				local ra0, ra1 = math.max( a0, ca0 ), math.min( a1, ca1 )
				local rb0, rb1 = math.max( b0, cb0 ), math.min( b1, cb1 )
				if ra0 <= a0 + EPS and ra1 >= a1 - EPS and rb0 <= b0 + EPS and rb1 >= b1 - EPS then return true end
				if not covers then covers = {} end
				coverValues = coverValues + 4
				covers[coverValues - 3] = ra0
				covers[coverValues - 2] = ra1
				covers[coverValues - 1] = rb0
				covers[coverValues] = rb1
			end
		end
	end
	return rectCovered( a0, a1, b0, b1, covers, coverValues )
end

RM.sameLiquidKind = sameLiquidKind
RM.visible = visible
RM.isLiquidBlock = isLiquidBlock
RM.destroySectionMeshList = destroySectionMeshList
RM.rebuildFlatMeshLists = rebuildFlatMeshLists
RM.DecodeLocal = DecodeLocal
RM.rotatedUVFlags = rotatedUVFlags
RM.tileUVRect = tileUVRect
RM.tileUVPointRaw = tileUVPointRaw
RM.quadFaceCubic = quadFaceCubic
RM.bakedFaceData = bakedFaceData
RM.EPS = EPS
RM.boxFaceCornerValues = boxFaceCornerValues
RM.BOX_UV_FLAGS = BOX_UV_FLAGS
RM.modelOrientSteps = modelOrientSteps
RM.rotateModelPoint = rotateModelPoint
RM.rotateModelFace = rotateModelFace
RM.rotatedModelQuads = rotatedModelQuads
RM.cornerUV16Raw = cornerUV16Raw
RM.connectionShapeFaceValues = connectionShapeFaceValues
RM.dynamicShapeFaceData = dynamicShapeFaceData
RM.facePlane = facePlane
RM.coveredByBoxes = coveredByBoxes
RM.FLUID_FACE_OFFSET = FLUID_FACE_OFFSET
