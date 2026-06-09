--[[----------------------------------------------------------------------------
	MC : client rendering

	Builds one (or a few, if huge) IMesh per chunk from the voxel store with
	hidden-face culling and Minecraft-style directional face shading. The
	mc_chunk entity calls MC.DrawChunk in its Draw -> 1 draw call per chunk.
------------------------------------------------------------------------------]]

MC = MC or {}
if MC.ClientRenderLoaded and MC.FreeAllMeshes then
	MC.FreeAllMeshes()
end
MC.ClientRenderLoaded = true

local BS  = MC.BS
local CS  = MC.CS

if MC.GeneratedAtlas then
	MC.Atlas.COLS = MC.GeneratedAtlas.COLS or MC.Atlas.COLS
	MC.Atlas.ROWS = MC.GeneratedAtlas.ROWS or MC.Atlas.ROWS
	MC.Atlas.TILE = MC.GeneratedAtlas.TILE or MC.Atlas.TILE
	MC.Atlas.MATERIAL = MC.GeneratedAtlas.MATERIAL or MC.Atlas.MATERIAL
	MC.Atlas.W = MC.Atlas.COLS * MC.Atlas.TILE
	MC.Atlas.H = MC.Atlas.ROWS * MC.Atlas.TILE
end

-- single atlas material: alpha cutout (glass/leaves), vertex-shaded, backface-culled
MC.Material = Material( MC.Atlas.MATERIAL or "mc/atlas_365.png", "alphatest vertexcolor" )

-- directional shading (modulates the texture via vertex colour)
local SH_TOP    = Color( 255, 255, 255 )
local SH_BOTTOM = Color( 130, 130, 130 )
local SH_X      = Color( 160, 160, 160 )
local SH_Y      = Color( 205, 205, 205 )

local N_UP    = Vector(  0,  0,  1 )
local N_DOWN  = Vector(  0,  0, -1 )
local N_XP    = Vector(  1,  0,  0 )
local N_XN    = Vector( -1,  0,  0 )
local N_YP    = Vector(  0,  1,  0 )
local N_YN    = Vector(  0, -1,  0 )

-- face table. slot: 1=top tile, 2=bottom tile, 3=side tile
-- c = four corners as { offX, offY, offZ, uFlag, vFlag } (a,b,c,d), drawn a,b,c + a,c,d
local FACES = {
	{ n = N_UP,   sh = SH_TOP,    slot = 1, off = {  0,  0,  1 }, c = { {0,0,1,0,1}, {1,0,1,1,1}, {1,1,1,1,0}, {0,1,1,0,0} } },
	{ n = N_DOWN, sh = SH_BOTTOM, slot = 2, off = {  0,  0, -1 }, c = { {0,1,0,0,1}, {1,1,0,1,1}, {1,0,0,1,0}, {0,0,0,0,0} } },
	{ n = N_XP,   sh = SH_X,      slot = 3, off = {  1,  0,  0 }, c = { {1,0,0,0,1}, {1,1,0,1,1}, {1,1,1,1,0}, {1,0,1,0,0} } },
	{ n = N_XN,   sh = SH_X,      slot = 3, off = { -1,  0,  0 }, c = { {0,1,0,0,1}, {0,0,0,1,1}, {0,0,1,1,0}, {0,1,1,0,0} } },
	{ n = N_YP,   sh = SH_Y,      slot = 3, off = {  0,  1,  0 }, c = { {1,1,0,0,1}, {0,1,0,1,1}, {0,1,1,1,0}, {1,1,1,0,0} } },
	{ n = N_YN,   sh = SH_Y,      slot = 3, off = {  0, -1,  0 }, c = { {0,0,0,0,1}, {1,0,0,1,1}, {1,0,1,1,0}, {0,0,1,0,0} } },
}
-- Source's front-face winding is opposite the corner order above.
local TRI = { 1, 3, 2, 1, 4, 3 }

local VERT_LIMIT = 64998 -- multiple of 6, under the 65535 IMesh vertex cap

MC.Meshes    = MC.Meshes or {}    -- key -> { IMesh, ... }
MC.MeshDirty = MC.MeshDirty or {}  -- key -> true
MC.ChunkEnts = MC.ChunkEnts or {}  -- key -> mc_chunk entity (clientside physics owner)
MC.PhysDirty = MC.PhysDirty or {}  -- key -> true (clientside collision rebuild)

-- safety valve: clientside collision (movement prediction). 0 = server-only.
MC.ClientCollision = CreateClientConVar( "mc_client_collision", "1", true, false,
	"Build clientside block collision for smooth movement prediction (0 = server-only)" )

cvars.AddChangeCallback( "mc_client_collision", function()
	for key, e in pairs( MC.ChunkEnts ) do
		if IsValid( e ) then MC.PhysDirty[key] = true end
	end
end, "mc" )

-- should the face between `cur` and neighbour `nb` be drawn?
local function visible( cur, nb, nbOrient )
	if nb == 0 then return true end
	local d = MC.Blocks[nb]
	if d and d.transparent then return nb ~= cur end
	if MC.BlockIsFullCube and not MC.BlockIsFullCube( nb, nbOrient ) then return true end
	return false
end

------------------------------------------------------------------ mesh lifecycle
function MC.FreeChunkMesh( key )
	local list = MC.Meshes[key]
	if not list then return end
	for i = 1, #list do
		if list[i] then list[i]:Destroy() end
	end
	MC.Meshes[key] = nil
end

local DecodeLocal = MC.DecodeLocal

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
	local inset = A.INSET or 0.5
	local u0 = col * A.TILE + ( tonumber( uv[1] ) or 0 ) / 16 * A.TILE + inset
	local v0 = row * A.TILE + ( tonumber( uv[2] ) or 0 ) / 16 * A.TILE + inset
	local u1 = col * A.TILE + ( tonumber( uv[3] ) or 16 ) / 16 * A.TILE - inset
	local v1 = row * A.TILE + ( tonumber( uv[4] ) or 16 ) / 16 * A.TILE - inset
	return u0 / A.W, v0 / A.H, u1 / A.W, v1 / A.H
end

local function tileUVPoint( tile, uv )
	local A = MC.Atlas
	local col = tile % A.COLS
	local row = math.floor( tile / A.COLS )
	local inset = A.INSET or 0.5
	local u = tonumber( uv and uv[1] ) or 0
	local v = tonumber( uv and uv[2] ) or 0
	local px = col * A.TILE + u / 16 * A.TILE
	local py = row * A.TILE + v / 16 * A.TILE
	if u <= 0 then px = px + inset elseif u >= 16 then px = px - inset end
	if v <= 0 then py = py + inset elseif v >= 16 then py = py - inset end
	return px / A.W, py / A.H
end

local function bakedFaceData( id, face, orient )
	local b = MC.Blocks[id]
	if not b or not b.baked then return nil end
	local baked = b.baked[orient] or b.baked[MC.DefaultOrient( id )] or b.baked[0]
	return baked and baked[face] or nil
end

local EPS = 0.0001

local BOX_FACE_CORNERS = {
	[1] = function( b ) return { { b[1], b[2], b[6] }, { b[4], b[2], b[6] }, { b[4], b[5], b[6] }, { b[1], b[5], b[6] } } end,
	[2] = function( b ) return { { b[1], b[5], b[3] }, { b[4], b[5], b[3] }, { b[4], b[2], b[3] }, { b[1], b[2], b[3] } } end,
	[3] = function( b ) return { { b[4], b[2], b[3] }, { b[4], b[5], b[3] }, { b[4], b[5], b[6] }, { b[4], b[2], b[6] } } end,
	[4] = function( b ) return { { b[1], b[5], b[3] }, { b[1], b[2], b[3] }, { b[1], b[2], b[6] }, { b[1], b[5], b[6] } } end,
	[5] = function( b ) return { { b[4], b[5], b[3] }, { b[1], b[5], b[3] }, { b[1], b[5], b[6] }, { b[4], b[5], b[6] } } end,
	[6] = function( b ) return { { b[1], b[2], b[3] }, { b[4], b[2], b[3] }, { b[4], b[2], b[6] }, { b[1], b[2], b[6] } } end,
}

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
	if b.orient ~= "horizontal_facing" and b.orient ~= "facing" then return 0, 0 end
	if b.orient == "facing" then
		if orient == MC.Direction.DOWN then return 1, 0 end
		if orient == MC.Direction.UP then return 3, 0 end
	end
	if orient == MC.Direction.EAST then return 0, 1 end
	if orient == MC.Direction.SOUTH then return 0, 2 end
	if orient == MC.Direction.WEST then return 0, 3 end
	return 0, 0
end

local function rotatedModelQuads( b, orient )
	if not b or not b.modelQuads then return nil end
	local xSteps, zSteps = modelOrientSteps( b, orient )
	if xSteps == 0 and zSteps == 0 then return b.modelQuads end
	b._rotatedModelQuads = b._rotatedModelQuads or {}
	local cacheKey = xSteps .. ":" .. zSteps
	if b._rotatedModelQuads[cacheKey] then return b._rotatedModelQuads[cacheKey] end
	local out = {}
	for qi, quad in ipairs( b.modelQuads ) do
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
			verts = verts,
		}
	end
	b._rotatedModelQuads[cacheKey] = out
	return out
end

local function cornerUV16( face, c )
	if face == MC.Face.TOP then return { c[1] * 16, ( 1 - c[2] ) * 16 } end
	if face == MC.Face.BOTTOM then return { c[1] * 16, c[2] * 16 } end
	if face == MC.Face.XP then return { c[2] * 16, ( 1 - c[3] ) * 16 } end
	if face == MC.Face.XN then return { ( 1 - c[2] ) * 16, ( 1 - c[3] ) * 16 } end
	if face == MC.Face.YP then return { ( 1 - c[1] ) * 16, ( 1 - c[3] ) * 16 } end
	return { c[1] * 16, ( 1 - c[3] ) * 16 }
end

local function paneSideTile( b )
	if not b or not b.name then return b and b.side or 0 end
	if b.name == "iron_bars" then return b.side end
	if b.name == "glass_pane" and MC.Tiles and MC.Tiles.glass then return MC.Tiles.glass end
	local glassName = string.match( b.name, "^(.*_stained_glass)_pane$" )
	if glassName and MC.Tiles and MC.Tiles[glassName] ~= nil then return MC.Tiles[glassName] end
	return b.side
end

local function dynamicShapeFaceData( b, face )
	if not b then return nil end
	if MC.IsPaneBlock and MC.IsPaneBlock( b.id ) then
		if face == MC.Face.TOP or face == MC.Face.BOTTOM then
			return { tile = b.top, rot = 0 }
		end
		return { tile = paneSideTile( b ), rot = 0 }
	end
	if MC.IsFenceBlock and MC.IsFenceBlock( b.id ) then
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

local function shapeFaceCovered( box, face, boxes, bx, by, bz )
	if coveredByBoxes( box, face, boxes, 0, 0, 0 ) then return true end
	local plane = facePlane( box, face )
	local off = FACES[face].off
	if ( face == MC.Face.TOP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.BOTTOM and math.abs( plane ) > EPS )
	or ( face == MC.Face.XP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.XN and math.abs( plane ) > EPS )
	or ( face == MC.Face.YP and math.abs( plane - 1 ) > EPS )
	or ( face == MC.Face.YN and math.abs( plane ) > EPS ) then
		return false
	end
	local nb = MC.GetBlock( bx + off[1], by + off[2], bz + off[3] )
	if nb == 0 then return false end
	local d = MC.Blocks[nb]
	if d and d.transparent and not ( MC.IsPaneBlock and MC.IsPaneBlock( nb ) ) then return false end
	local nbOrient = MC.GetBlockOrient( bx + off[1], by + off[2], bz + off[3] )
	return coveredByBoxes( box, face, MC.BlockBoxes( nb, nbOrient, bx + off[1], by + off[2], bz + off[3] ), off[1], off[2], off[3] )
end

function MC.BuildChunkMesh( key )
	MC.FreeChunkMesh( key )

	local chunk = MC.GetChunkByKey( key )
	if not chunk or chunk.count == 0 then return end

	local bxo = chunk.cx * CS
	local byo = chunk.cy * CS
	local bzo = chunk.cz * MC.CH

	local list = {}
	local verts = {}
	local nv = 0
	chunk.orients = chunk.orients or {}

	local function flush()
		if nv == 0 then return end
		local m = Mesh( MC.Material )
		m:BuildFromTriangles( verts )
		list[#list + 1] = m
		verts = {}
		nv = 0
	end

	local function emitQuad( corners, normal, color, tile )
		for t = 1, 6 do
			local cn = corners[TRI[t]]
			local u, v = tileUVPoint( tile, { cn[4], cn[5] } )
			nv = nv + 1
			verts[nv] = {
				pos    = Vector( cn[1], cn[2], cn[3] ),
				normal = normal,
				u      = u,
				v      = v,
				color  = color,
			}
		end
		if nv >= VERT_LIMIT then flush() end
	end

	local function emitCrossBlock( id, wx, wy, wz )
		local b = MC.Blocks[id]
		local tile = b and b.side or 0
		local z0, z1 = wz, wz + BS
		local a, c = 0.08 * BS, 0.92 * BS
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
		emitQuad( p1, N_YP, SH_TOP, tile )
		emitQuad( { p1[4], p1[3], p1[2], p1[1] }, N_YN, SH_TOP, tile )
		emitQuad( p2, N_XP, SH_TOP, tile )
		emitQuad( { p2[4], p2[3], p2[2], p2[1] }, N_XN, SH_TOP, tile )
	end

	local function emitModelBlock( b, orient, wx, wy, wz )
		local quads = rotatedModelQuads( b, orient )
		if not quads then return false end
		for _, quad in ipairs( quads ) do
			local face = FACES[quad.face or MC.Face.TOP] or FACES[MC.Face.TOP]
			local u0, v0, u1, v1 = tileUVRect( quad.tile or 0, quad.uv )
			for t = 1, 6 do
				local vert = quad.verts[TRI[t]]
				local uf, vf = rotatedUVFlags( vert.u or 0, vert.v or 0, quad.rot or 0 )
				nv = nv + 1
				verts[nv] = {
					pos    = Vector( wx + vert.x * BS, wy + vert.y * BS, wz + vert.z * BS ),
					normal = face.n,
					u      = uf == 1 and u1 or u0,
					v      = vf == 1 and v1 or v0,
					color  = face.sh,
				}
			end
			if nv >= VERT_LIMIT then flush() end
		end
		return true
	end

	for li, id in pairs( chunk.blocks ) do
		local orient = MC.NormalizeOrient( id, chunk.orients[li] )
		local lx, ly, lz = DecodeLocal( li )
		local bx, by, bz = bxo + lx, byo + ly, bzo + lz
		local wx, wy, wz = lx * BS, ly * BS, lz * BS

		local b = MC.Blocks[id]
		if b and b.shape == "cross" then
			emitCrossBlock( id, wx, wy, wz )
		elseif b and b.shape == "model" and not ( ( MC.IsFenceBlock and MC.IsFenceBlock( id ) ) or ( MC.IsPaneBlock and MC.IsPaneBlock( id ) ) ) and emitModelBlock( b, orient, wx, wy, wz ) then
			-- rendered from exact Minecraft model quads; boxes remain for collision/outline
		elseif MC.BlockIsFullCube( id, orient ) then
			for f = 1, 6 do
				local face = FACES[f]
				local o = face.off
				local nbx, nby, nbz = bx + o[1], by + o[2], bz + o[3]
				if visible( id, MC.GetBlock( nbx, nby, nbz ), MC.GetBlockOrient( nbx, nby, nbz ) ) then
					local baked = bakedFaceData( id, f, orient )
					local tile, rot, flipU, flipV
					local u0, v0, u1, v1
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

					for t = 1, 6 do
						local cn = corners[ TRI[t] ]
						local u, v
						if baked and baked.uvs then
							u, v = tileUVPoint( tile, baked.uvs[TRI[t]] )
						else
							local uf, vf = rotatedUVFlags( cn[4], cn[5], rot or 0, flipU, flipV )
							u = uf == 1 and u1 or u0
							v = vf == 1 and v1 or v0
						end
						nv = nv + 1
						verts[nv] = {
							pos    = Vector( wx + cn[1] * BS, wy + cn[2] * BS, wz + cn[3] * BS ),
							normal = nrm,
							u      = u,
							v      = v,
							color  = col,
						}
					end

					if nv >= VERT_LIMIT then flush() end
				end
			end
		else
			local boxes = MC.BlockBoxes( id, orient, bx, by, bz )
			for boxIndex, box in ipairs( boxes or {} ) do
				for f = 1, 6 do
					if not shapeFaceCovered( box, f, boxes, bx, by, bz ) then
						local face = FACES[f]
						local modelFaces = b and b.boxFaces
						local fd = modelFaces and modelFaces[boxIndex] and modelFaces[boxIndex][f]
						local dynamicFd = dynamicShapeFaceData( b, f )
						if not modelFaces or fd or dynamicFd then
							fd = fd or dynamicFd
							local tile = fd and fd.tile or MC.BlockFace( id, f, orient )
							local u0, v0, u1, v1
							if fd and fd.uv then
								u0, v0, u1, v1 = tileUVRect( tile, fd.uv )
							end
							local corners = BOX_FACE_CORNERS[f]( box )
							local nrm, col = face.n, face.sh
							for t = 1, 6 do
								local ci = TRI[t]
								local cn = corners[ci]
								local u, v
								if fd and fd.uv then
									local flags = BOX_UV_FLAGS[ci]
									local uf, vf = rotatedUVFlags( flags[1], flags[2], fd.rot or 0 )
									u = uf == 1 and u1 or u0
									v = vf == 1 and v1 or v0
								else
									u, v = tileUVPoint( tile, cornerUV16( f, cn ) )
								end
								nv = nv + 1
								verts[nv] = {
									pos    = Vector( wx + cn[1] * BS, wy + cn[2] * BS, wz + cn[3] * BS ),
									normal = nrm,
									u      = u,
									v      = v,
									color  = col,
								}
							end
							if nv >= VERT_LIMIT then flush() end
						end
					end
				end
			end
		end
	end

	flush()

	if #list > 0 then
		MC.Meshes[key] = list
	end
end

------------------------------------------------------------------------- drawing
function MC.DrawChunk( key )
	local list = MC.Meshes[key]
	if not list then return end
	render.SetMaterial( MC.Material )
	for i = 1, #list do
		list[i]:Draw()
	end
end

hook.Remove( "PostDrawOpaqueRenderables", "mc_draw_chunks" )
hook.Remove( "PostDrawTranslucentRenderables", "mc_draw_chunks" )
hook.Add( "PostDrawOpaqueRenderables", "mc_draw_chunks", function()
	for key, list in pairs( MC.Meshes or {} ) do
		if list then
			local c = MC.GetChunkByKey( key )
			if c then
				local mat = Matrix()
				mat:SetTranslation( MC.ChunkWorldOrigin( c.cx, c.cy, c.cz ) )
				cam.PushModelMatrix( mat )
					MC.DrawChunk( key )
				cam.PopModelMatrix()
			end
		end
	end
end )

------------------------------------------------------------------- dirty tracking
function MC.MarkChunkDirty( key )
	MC.MeshDirty[key] = true
end

function MC.MarkChunkPhysDirty( key )
	MC.PhysDirty[key] = true
end

-- a block changed: its own chunk and any chunk owning a face-neighbour cell
-- may need a rebuild (boundary faces).
function MC.MarkDirty( bx, by, bz )
	local function mark( x, y, z )
		local cx, cy, cz = MC.CellToChunk( x, y, z )
		MC.MeshDirty[ MC.ChunkKey( cx, cy, cz ) ] = true
	end
	mark( bx, by, bz )
	mark( bx + 1, by, bz ) ; mark( bx - 1, by, bz )
	mark( bx, by + 1, bz ) ; mark( bx, by - 1, bz )
	mark( bx, by, bz + 1 ) ; mark( bx, by, bz - 1 )
end

-- rebuild a few chunks per frame to avoid hitches (meshes + clientside collision)
hook.Remove( "Think", "mc_meshbuild" )
hook.Add( "Think", "mc_meshbuild", function()
	if next( MC.MeshDirty ) then
		local budget = 3
		for key in pairs( MC.MeshDirty ) do
			MC.BuildChunkMesh( key )
			MC.MeshDirty[key] = nil
			budget = budget - 1
			if budget <= 0 then break end
		end
	end

	if next( MC.PhysDirty ) then
		local enabled = MC.ClientCollision:GetBool()
		local budget = 3
		for key in pairs( MC.PhysDirty ) do
			local e = MC.ChunkEnts[key]
			if IsValid( e ) then
				if enabled then e:RebuildPhysics() else e:PhysicsDestroy() end
			end
			MC.PhysDirty[key] = nil
			budget = budget - 1
			if budget <= 0 then break end
		end
	end
end )

-- free all meshes (used by mc_clear)
function MC.FreeAllMeshes()
	for key in pairs( MC.Meshes ) do MC.FreeChunkMesh( key ) end
end
