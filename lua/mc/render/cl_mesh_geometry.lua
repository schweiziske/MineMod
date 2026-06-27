-- Render mesh internals split from cl_mesh_core.lua.
MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}
local RM = MC.RenderMesh


local C = MC.RenderMeshConstants
local CS = C.CS
local CS2 = C.CS2
local RENDER_SECTIONS_XY = C.RENDER_SECTIONS_XY
local RENDER_SECTIONS_Z = C.RENDER_SECTIONS_Z

MC.Meshes      = MC.Meshes or {}      -- key -> { IMesh, ... } (opaque/cutout pass)
MC.MeshesTrans = MC.MeshesTrans or {} -- key -> { IMesh, ... } (translucent pass)
MC.MeshSections = MC.MeshSections or {} -- key -> sectionIndex -> { opaque = {}, translucent = {} }
MC.MeshSectionGeometry = MC.MeshSectionGeometry or {} -- key -> sectionIndex -> cached vertex/light records
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

local FLUID_SURFACE_HEIGHT = 0.8888889
local FLUID_WEIGHTED_HEIGHT = 0.8
local FLUID_FACE_OFFSET = 0.001
MC.RenderMeshConstants.FLUID_FACE_OFFSET = FLUID_FACE_OFFSET

local function isLiquidBlock( id )
	if MC.IsLiquidBlock then return MC.IsLiquidBlock( id ) end
	return MC.LiquidKind and MC.LiquidKind( id ) ~= nil or false
end

local function solidForFluidHeight( id, orient )
	if id == 0 then return false end
	local b = MC.Blocks[id]
	if not b then return true end
	if b.solid == false or b.transparent == true then return false end
	if MC.BlockIsFullCube then return MC.BlockIsFullCube( id, orient ) == true end
	return not b.shape
end

local function fluidHeightAt( bx, by, bz, kind )
	local id = MC.GetBlock( bx, by, bz )
	if MC.LiquidKind and MC.LiquidKind( id ) == kind then
		if sameLiquidKind( id, MC.GetBlock( bx, by, bz + 1 ) ) then return 1.0 end
		return FLUID_SURFACE_HEIGHT
	end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( bx, by, bz ) or 0
	return solidForFluidHeight( id, orient ) and -1.0 or 0.0
end

local function addWeightedFluidHeight( total, weight, height )
	if height >= FLUID_WEIGHTED_HEIGHT then
		return total + height * 10, weight + 10
	elseif height >= 0 then
		return total + height, weight + 1
	end
	return total, weight
end

local function calculateAverageFluidHeight( kind, heightSelf, heightA, heightB, bx, by, bz )
	if heightA >= 1.0 or heightB >= 1.0 then return 1.0 end
	local total, weight = 0, 0
	if heightA > 0 or heightB > 0 then
		local cornerHeight = fluidHeightAt( bx, by, bz, kind )
		if cornerHeight >= 1.0 then return 1.0 end
		total, weight = addWeightedFluidHeight( total, weight, cornerHeight )
	end
	total, weight = addWeightedFluidHeight( total, weight, heightSelf )
	total, weight = addWeightedFluidHeight( total, weight, heightA )
	total, weight = addWeightedFluidHeight( total, weight, heightB )
	if weight <= 0 then return 0 end
	return total / weight
end

------------------------------------------------------------------ mesh lifecycle
local function destroyMeshList( store, key )
	local list = store[key]
	if not list then return end
	for i = 1, #list do
		local entry = list[i]
		local meshObj = type( entry ) == "table" and entry.mesh or entry
		if meshObj and meshObj.Destroy then meshObj:Destroy() end
	end
	store[key] = nil
end

local function destroySectionMeshList( list )
	if not list then return end
	for i = 1, #list do
		local entry = list[i]
		local meshObj = type( entry ) == "table" and entry.mesh or entry
		if meshObj and meshObj.Destroy then meshObj:Destroy() end
	end
end

local sectionIndexForLocal = MC.RenderSectionIndexForLocal
local clearChunkBlockEmitCache = MC.ClearChunkBlockEmitCache

local function rebuildFlatMeshLists( key )
	local sections = MC.MeshSections[key]
	if not sections then
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
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
end

function MC.FreeChunkMesh( key )
	if MC.MeshDirtyRateLimited then MC.MeshDirtyRateLimited[key] = nil end
	if MC.MeshLightDirty then MC.MeshLightDirty[key] = nil end
	clearChunkBlockEmitCache( key )
	local sections = MC.MeshSections[key]
	if sections then
		for _, section in pairs( sections ) do
			destroySectionMeshList( section.opaque )
			destroySectionMeshList( section.translucent )
		end
		MC.MeshSections[key] = nil
		if MC.ForgetChunkMeshSectionGeometryCache then
			MC.ForgetChunkMeshSectionGeometryCache( key )
		else
			MC.MeshSectionGeometry[key] = nil
		end
		MC.Meshes[key] = nil
		MC.MeshesTrans[key] = nil
		return
	end
	if MC.ForgetChunkMeshSectionGeometryCache then
		MC.ForgetChunkMeshSectionGeometryCache( key )
	else
		MC.MeshSectionGeometry[key] = nil
	end
	destroyMeshList( MC.Meshes, key )
	destroyMeshList( MC.MeshesTrans, key )
end

local function DecodeLocal( li )
	if MC.DecodeLocal then return MC.DecodeLocal( li ) end
	local lz = math.floor( li / CS2 )
	local ly = math.floor( ( li - lz * CS2 ) / CS )
	local lx = li - lz * CS2 - ly * CS
	return lx, ly, lz
end

local function ensureChunkRenderSectionIndex( chunk )
	if not chunk then return nil end
	local version = chunk.collisionVersion or 0
	if chunk.renderSectionBlocks and chunk.renderSectionIndexVersion == version then
		return chunk.renderSectionBlocks
	end

	local bySection = {}
	for li, id in pairs( chunk.blocks or {} ) do
		local lx, ly, lz = DecodeLocal( li )
		local sectionIndex = sectionIndexForLocal( lx, ly, lz )
		local list = bySection[sectionIndex]
		if not list then
			list = {}
			bySection[sectionIndex] = list
		end
		list[li] = id
	end

	chunk.renderSectionBlocks = bySection
	chunk.renderSectionIndexVersion = version
	return bySection
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
	if not uv then return MC.TileUV( tile ) end
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local stride = A.STRIDE or A.TILE
	local pad = A.PAD or 0
	local inset = A.INSET or 0.5
	local baseX = col * stride + pad
	local baseY = row * stride + pad
	local u0 = baseX + ( tonumber( uv[1] ) or 0 ) / 16 * A.TILE + inset
	local v0 = baseY + ( tonumber( uv[2] ) or 0 ) / 16 * A.TILE + inset
	local u1 = baseX + ( tonumber( uv[3] ) or 16 ) / 16 * A.TILE - inset
	local v1 = baseY + ( tonumber( uv[4] ) or 16 ) / 16 * A.TILE - inset
	return u0 / A.W, v0 / A.H, u1 / A.W, v1 / A.H
end

local function tileUVPointRaw( tile, u, v )
	local A = MC.Atlas
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
		if orient == MC.Direction.DOWN then return 1, 0 end
		if orient == MC.Direction.UP then return 3, 0 end
	end
	if b.orient == "door" or b.orient == "trapdoor" or b.orient == "bed" then
		orient = MC.BlockHorizontalFacingForOrient and MC.BlockHorizontalFacingForOrient( b, orient ) or orient
	end
	if orient == MC.Direction.EAST then return 0, 1 end
	if orient == MC.Direction.SOUTH then return 0, 2 end
	if orient == MC.Direction.WEST then return 0, 3 end
	return 0, 0
end

local function rotatedModelQuads( b, orient )
	local data = MC.BlockModelData and MC.BlockModelData( b, orient ) or b
	if not data or not data.modelQuads then return nil end
	local xSteps, zSteps = modelOrientSteps( b, orient )
	if xSteps == 0 and zSteps == 0 then return data.modelQuads end
	data._rotatedModelQuads = data._rotatedModelQuads or {}
	local cacheKey = xSteps .. ":" .. zSteps
	if data._rotatedModelQuads[cacheKey] then return data._rotatedModelQuads[cacheKey] end
	local out = {}
	for qi, quad in ipairs( data.modelQuads ) do
		local verts = {}
		for vi, v in ipairs( quad.verts or {} ) do
			local y, z = rotateModelXZ( v.y, v.z, xSteps )
			local x
			x, y = rotateModelXY( v.x, y, zSteps )
			verts[vi] = { x = x, y = y, z = v.z, u = v.u, v = v.v }
			verts[vi].z = z
		end
		out[qi] = {
			face = rotateModelFaceZ( rotateModelFaceX( quad.face or MC.Face.TOP, xSteps ), zSteps ),
			tile = quad.tile,
			uv = quad.uv,
			rot = quad.rot or 0,
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

local function dynamicShapeFaceData( b, face, box )
	if not b then return nil end
	if b.connection == "pipe6" then
		return { tile = b.side, rot = 0 }
	end
	if MC.IsPaneBlock and MC.IsPaneBlock( b.id ) then
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then
			if box and box.part == "arm" then
				return { tile = b.top, rot = 0, uv = PANE_ARM_EDGE_UV }
			end
			return { tile = b.top, rot = 0 }
		end
		-- the open end of an arm shows the pane edge strip, like Minecraft's
		-- cullfaced #edge face on the pane side models
		if box and box.part == "arm" and ARM_END_FACE[box.dir] == face then
			return { tile = b.top, rot = 0 }
		end
		return { tile = paneSideTile( b ), rot = 0 }
	end
	if MC.IsFenceBlock and MC.IsFenceBlock( b.id ) then
		return { tile = b.side, rot = 0 }
	end
	if MC.IsWallBlock and MC.IsWallBlock( b.id ) then
		return { tile = b.side, rot = 0 }
	end
	return nil
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

local function pointInRect( a, b, r )
	return a >= r[1] - EPS and a <= r[2] + EPS and b >= r[3] - EPS and b <= r[4] + EPS
end

local function rectCovered( a0, a1, b0, b1, covers )
	if #covers == 0 then return false end
	local as = { a0, a1 }
	local bs = { b0, b1 }
	for _, r in ipairs( covers ) do
		addEdge( as, math.max( a0, math.min( a1, r[1] ) ), a0, a1 )
		addEdge( as, math.max( a0, math.min( a1, r[2] ) ), a0, a1 )
		addEdge( bs, math.max( b0, math.min( b1, r[3] ) ), b0, b1 )
		addEdge( bs, math.max( b0, math.min( b1, r[4] ) ), b0, b1 )
	end
	table.sort( as )
	table.sort( bs )
	for ai = 1, #as - 1 do
		for bi = 1, #bs - 1 do
			local ma = ( as[ai] + as[ai + 1] ) * 0.5
			local mb = ( bs[bi] + bs[bi + 1] ) * 0.5
			local ok = false
			for _, r in ipairs( covers ) do
				if pointInRect( ma, mb, r ) then ok = true break end
			end
			if not ok then return false end
		end
	end
	return true
end

local function coveredByBoxes( targetBox, face, boxes, ox, oy, oz )
	local plane = facePlane( targetBox, face )
	local a0, a1, b0, b1 = rectForFace( targetBox, face )
	local covers = {}
	for _, box in ipairs( boxes or {} ) do
		if box ~= targetBox then
			local ca0, ca1, cb0, cb1 = coverRectForBox( box, face, plane, ox or 0, oy or 0, oz or 0 )
			if ca0 and ca1 > a0 + EPS and ca0 < a1 - EPS and cb1 > b0 + EPS and cb0 < b1 - EPS then
				covers[#covers + 1] = { math.max( a0, ca0 ), math.min( a1, ca1 ), math.max( b0, cb0 ), math.min( b1, cb1 ) }
			end
		end
	end
	return rectCovered( a0, a1, b0, b1, covers )
end

RM.sameLiquidKind = sameLiquidKind
RM.visible = visible
RM.isLiquidBlock = isLiquidBlock
RM.fluidHeightAt = fluidHeightAt
RM.calculateAverageFluidHeight = calculateAverageFluidHeight
RM.destroySectionMeshList = destroySectionMeshList
RM.rebuildFlatMeshLists = rebuildFlatMeshLists
RM.DecodeLocal = DecodeLocal
RM.ensureChunkRenderSectionIndex = ensureChunkRenderSectionIndex
RM.rotatedUVFlags = rotatedUVFlags
RM.tileUVRect = tileUVRect
RM.tileUVPointRaw = tileUVPointRaw
RM.quadFaceCubic = quadFaceCubic
RM.bakedFaceData = bakedFaceData
RM.EPS = EPS
RM.boxFaceCornerValues = boxFaceCornerValues
RM.BOX_UV_FLAGS = BOX_UV_FLAGS
RM.rotatedModelQuads = rotatedModelQuads
RM.cornerUV16Raw = cornerUV16Raw
RM.dynamicShapeFaceData = dynamicShapeFaceData
RM.facePlane = facePlane
RM.coveredByBoxes = coveredByBoxes
RM.FLUID_FACE_OFFSET = FLUID_FACE_OFFSET
