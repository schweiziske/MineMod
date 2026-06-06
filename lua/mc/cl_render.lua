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

-- single atlas material: alpha cutout (glass/leaves), two-sided, vertex-shaded
MC.Material = Material( MC.Atlas.MATERIAL or "mc/atlas_365.png", "alphatest nocull vertexcolor noclamp" )

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
-- order of corner indices that make the two triangles
local TRI = { 1, 2, 3, 1, 3, 4 }

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
local function visible( cur, nb )
	if nb == 0 then return true end
	local d = MC.Blocks[nb]
	if d and d.transparent then return nb ~= cur end
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

local function rotatedUVFlags( uf, vf, rot )
	rot = rot % 4
	if rot == 1 then return vf, 1 - uf end
	if rot == 2 then return 1 - uf, 1 - vf end
	if rot == 3 then return 1 - vf, uf end
	return uf, vf
end

function MC.BuildChunkMesh( key )
	MC.FreeChunkMesh( key )

	local chunk = MC.GetChunkByKey( key )
	if not chunk or chunk.count == 0 then return end

	local wox = chunk.cx * MC.ChunkWorld
	local woy = chunk.cy * MC.ChunkWorld
	local woz = chunk.cz * MC.ChunkWorld
	local bxo = chunk.cx * CS
	local byo = chunk.cy * CS
	local bzo = chunk.cz * CS

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

	for li, id in pairs( chunk.blocks ) do
		local orient = MC.NormalizeOrient( id, chunk.orients[li] )
		local lx, ly, lz = DecodeLocal( li )
		local bx, by, bz = bxo + lx, byo + ly, bzo + lz
		local wx, wy, wz = wox + lx * BS, woy + ly * BS, woz + lz * BS

		for f = 1, 6 do
			local face = FACES[f]
			local o = face.off
			if visible( id, MC.GetBlock( bx + o[1], by + o[2], bz + o[3] ) ) then
				local tile, rot = MC.BlockFace( id, f, orient )
				local u0, v0, u1, v1 = MC.TileUV( tile )
				local corners = face.c
				local nrm, col = face.n, face.sh

				for t = 1, 6 do
					local cn = corners[ TRI[t] ]
					local uf, vf = rotatedUVFlags( cn[4], cn[5], rot or 0 )
					nv = nv + 1
					verts[nv] = {
						pos    = Vector( wx + cn[1] * BS, wy + cn[2] * BS, wz + cn[3] * BS ),
						normal = nrm,
						u      = uf == 1 and u1 or u0,
						v      = vf == 1 and v1 or v0,
						color  = col,
					}
				end

				if nv >= VERT_LIMIT then flush() end
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
		local cx, cy, cz = math.floor( x / CS ), math.floor( y / CS ), math.floor( z / CS )
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
