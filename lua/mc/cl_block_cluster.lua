--[[----------------------------------------------------------------------------
	MC : client block-cluster support.

	Mesh building for mc_block_cluster entities (atlas IMesh from a cluster
	record), the structure grabber tool's selection model (fine / box / flood
	selection), preview rendering, paste-snap ghosting, and the cluster net
	receivers.
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net
local CLUSTER_CLASS = "mc_block_cluster"

local function chat( msg )
	local ply = LocalPlayer()
	if IsValid( ply ) then ply:ChatPrint( "[MC] " .. msg ) end
end

local function L( key, fallback, vars )
	return MC.T and MC.T( key, fallback, vars ) or fallback
end

------------------------------------------------------------------ mesh build
local TRI = { 1, 3, 2, 1, 4, 3 }
local TRI_BACK = { 1, 2, 3, 1, 3, 4 }
local VERT_LIMIT = 60000

local N_UP    = Vector(  0,  0,  1 )
local N_DOWN  = Vector(  0,  0, -1 )
local N_XP    = Vector(  1,  0,  0 )
local N_XN    = Vector( -1,  0,  0 )
local N_YP    = Vector(  0,  1,  0 )
local N_YN    = Vector(  0, -1,  0 )

local FACE_NORMALS = {
	[MC.Face.TOP] = N_UP,
	[MC.Face.BOTTOM] = N_DOWN,
	[MC.Face.XP] = N_XP,
	[MC.Face.XN] = N_XN,
	[MC.Face.YP] = N_YP,
	[MC.Face.YN] = N_YN,
}

local FACE_OFFSETS = {
	[MC.Face.TOP] = { 0, 0, 1 },
	[MC.Face.BOTTOM] = { 0, 0, -1 },
	[MC.Face.XP] = { 1, 0, 0 },
	[MC.Face.XN] = { -1, 0, 0 },
	[MC.Face.YP] = { 0, 1, 0 },
	[MC.Face.YN] = { 0, -1, 0 },
}

-- Classic look (MC.ClusterEngineStyle off): unlit chunk materials with the
-- same per-face shade the chunk mesher bakes into vertex colors.
local FACE_SHADE = {
	[MC.Face.TOP] = Color( 255, 255, 255, 255 ),
	[MC.Face.BOTTOM] = Color( 128, 128, 128, 255 ),
	[MC.Face.XP] = Color( 153, 153, 153, 255 ),
	[MC.Face.XN] = Color( 153, 153, 153, 255 ),
	[MC.Face.YP] = Color( 204, 204, 204, 255 ),
	[MC.Face.YN] = Color( 204, 204, 204, 255 ),
}
local CROSS_SHADE = Color( 210, 210, 210, 255 )

-- Engine-style look (MC.ClusterEngineStyle on): VertexLitGeneric picks up the
-- model lighting context inside ENT:Draw (ambient cube, lamps, flashlight),
-- which is what makes the cluster read like a normal prop. Face shading then
-- comes from normals, so vertices carry no baked colors. The unlit chunk
-- materials stay in use for the paste ghost either way, since it draws
-- outside any model lighting context.
local clusterMatOpaque, clusterMatTranslucent

local function refreshClusterMaterialTexture( mat, source )
	local tex = source and source.GetTexture and source:GetTexture( "$basetexture" ) or nil
	if not tex or tex:IsError() then return end
	local current = mat:GetTexture( "$basetexture" )
	if not current or current:IsError() or current:GetName() ~= tex:GetName() then
		mat:SetTexture( "$basetexture", tex )
	end
end

local function clusterMaterials()
	if MC.ClusterEngineStyle ~= true then
		return MC.Material, MC.MaterialTranslucent or MC.Material
	end
	if not clusterMatOpaque then
		local opaque = CreateMaterial( "mc_cluster_lit_opaque1", "VertexLitGeneric", {
			["$basetexture"] = "color/white",
			["$alphatest"] = "1",
			["$alphatestreference"] = "0.5",
			["$nocull"] = "0",
		} )
		local translucent = CreateMaterial( "mc_cluster_lit_translucent1", "VertexLitGeneric", {
			["$basetexture"] = "color/white",
			["$translucent"] = "1",
			["$nocull"] = "0",
		} )
		clusterMatOpaque = opaque and not opaque:IsError() and opaque or nil
		clusterMatTranslucent = translucent and not translucent:IsError() and translucent or nil
	end
	if clusterMatOpaque then refreshClusterMaterialTexture( clusterMatOpaque, MC.Material ) end
	if clusterMatTranslucent then refreshClusterMaterialTexture( clusterMatTranslucent, MC.MaterialTranslucent or MC.Material ) end
	return clusterMatOpaque or MC.Material,
		clusterMatTranslucent or MC.MaterialTranslucent or MC.Material
end

local BOX_FACE_CORNERS = {
	[MC.Face.TOP] = function( b ) return { { b[1], b[2], b[6], 0, 1 }, { b[4], b[2], b[6], 1, 1 }, { b[4], b[5], b[6], 1, 0 }, { b[1], b[5], b[6], 0, 0 } } end,
	[MC.Face.BOTTOM] = function( b ) return { { b[1], b[5], b[3], 0, 1 }, { b[4], b[5], b[3], 1, 1 }, { b[4], b[2], b[3], 1, 0 }, { b[1], b[2], b[3], 0, 0 } } end,
	[MC.Face.XP] = function( b ) return { { b[4], b[2], b[3], 0, 1 }, { b[4], b[5], b[3], 1, 1 }, { b[4], b[5], b[6], 1, 0 }, { b[4], b[2], b[6], 0, 0 } } end,
	[MC.Face.XN] = function( b ) return { { b[1], b[5], b[3], 0, 1 }, { b[1], b[2], b[3], 1, 1 }, { b[1], b[2], b[6], 1, 0 }, { b[1], b[5], b[6], 0, 0 } } end,
	[MC.Face.YP] = function( b ) return { { b[4], b[5], b[3], 0, 1 }, { b[1], b[5], b[3], 1, 1 }, { b[1], b[5], b[6], 1, 0 }, { b[4], b[5], b[6], 0, 0 } } end,
	[MC.Face.YN] = function( b ) return { { b[1], b[2], b[3], 0, 1 }, { b[4], b[2], b[3], 1, 1 }, { b[4], b[2], b[6], 1, 0 }, { b[1], b[2], b[6], 0, 0 } } end,
}

local function rotatedUVFlags( uf, vf, rot )
	rot = ( rot or 0 ) % 4
	if rot == 1 then return vf, 1 - uf end
	if rot == 2 then return 1 - uf, 1 - vf end
	if rot == 3 then return 1 - vf, uf end
	return uf, vf
end

local function isFullBlockBox( box )
	return box[1] == 0 and box[2] == 0 and box[3] == 0 and box[4] == 1 and box[5] == 1 and box[6] == 1
end

local function tileUVRectWithUV( tile, uv )
	if not uv then return MC.TileUV( tile ) end
	local atlas = MC.Atlas
	local col = tile % atlas.COLS
	local row = math.floor( tile / atlas.COLS )
	local stride = atlas.STRIDE or atlas.TILE
	local pad = atlas.PAD or 0
	local inset = atlas.INSET or 0.5
	local baseX = col * stride + pad
	local baseY = row * stride + pad
	local u0 = baseX + ( tonumber( uv[1] ) or 0 ) / 16 * atlas.TILE + inset
	local v0 = baseY + ( tonumber( uv[2] ) or 0 ) / 16 * atlas.TILE + inset
	local u1 = baseX + ( tonumber( uv[3] ) or 16 ) / 16 * atlas.TILE - inset
	local v1 = baseY + ( tonumber( uv[4] ) or 16 ) / 16 * atlas.TILE - inset
	return u0 / atlas.W, v0 / atlas.H, u1 / atlas.W, v1 / atlas.H
end

local function stateModels( stateId, dx, dy, dz )
	if not stateId or not MC.VisitStateVisualModels or not MC.StateVisualModelData then return nil end
	local models = {}
	MC.VisitStateVisualModels( stateId, dx, dy, dz, function( modelId )
		local data = MC.StateVisualModelData( modelId )
		if data and data.modelQuads and #data.modelQuads > 0 then models[#models + 1] = data end
	end )
	return #models > 0 and models or nil
end

local function localCellKey( dx, dy, dz )
	return dx + dy * 256 + dz * 65536
end

function MC.BuildClusterMeshes( record )
	local BS = MC.BS
	local built = { opaque = {}, translucent = {} }
	local litOpaque, litTranslucent = clusterMaterials()

	local function newBuffer( material, ghostMaterial, listKey )
		return { verts = {}, n = 0, material = material, ghostMaterial = ghostMaterial, listKey = listKey }
	end
	local buffers = {
		opaque = newBuffer( litOpaque, MC.Material, "opaque" ),
		translucent = newBuffer( litTranslucent, MC.MaterialTranslucent or MC.Material, "translucent" ),
	}

	local function flush( buf )
		if buf.n == 0 then return end
		local meshObj = Mesh( buf.material )
		meshObj:BuildFromTriangles( buf.verts )
		built[buf.listKey][#built[buf.listKey] + 1] = {
			mesh = meshObj,
			material = buf.material,
			ghostMaterial = buf.ghostMaterial,
		}
		buf.verts = {}
		buf.n = 0
	end

	local function push( buf, vert )
		buf.n = buf.n + 1
		buf.verts[buf.n] = vert
		if buf.n >= VERT_LIMIT then flush( buf ) end
	end

	local infos = {}
	local fullCells = {}
	local cells = record.cells
	for i = 1, #cells, 4 do
		local dx, dy, dz, stateId = cells[i], cells[i + 1], cells[i + 2], cells[i + 3]
		local id, fullCube, translucent
		if MC.ResolveBlockStateRenderClass then
			id, fullCube, translucent = MC.ResolveBlockStateRenderClass( stateId, dx, dy, dz )
		else
			id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
			fullCube = MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, dx, dy, dz ) or false
			translucent = false
		end
		if id and id ~= 0 then
			local block = MC.Blocks and MC.Blocks[id] or nil
			local info = {
				dx = dx, dy = dy, dz = dz,
				stateId = stateId, id = id,
				translucent = translucent == true,
				cross = block and block.shape == "cross" or false,
				models = nil,
			}
			if not fullCube and not info.cross then
				info.models = stateModels( stateId, dx, dy, dz )
			end
			infos[#infos + 1] = info
			if fullCube and not translucent then
				fullCells[localCellKey( dx, dy, dz )] = true
			end
		end
	end

	local function faceUV( info, face )
		local tile, rot, flipU, flipV = MC.BlockFaceForState( info.stateId, face, info.dx, info.dy, info.dz )
		local u0, v0, u1, v1 = MC.TileUV( tile or 0 )
		return u0, v0, u1, v1, rot or 0, flipU == true, flipV == true
	end

	-- baked vertex shading only in classic mode; engine-style leaves vertices
	-- white so VertexLitGeneric owns the shading
	local useBakedShade = MC.ClusterEngineStyle ~= true

	local function pushQuad( buf, info, corners, order, normal, u0, v0, u1, v1, rot, flipU, flipV, color )
		for t = 1, 6 do
			local corner = corners[order[t]]
			local uf, vf = rotatedUVFlags( corner[4], corner[5], rot )
			if flipU then uf = 1 - uf end
			if flipV then vf = 1 - vf end
			push( buf, {
				pos = Vector( ( info.dx + corner[1] ) * BS, ( info.dy + corner[2] ) * BS, ( info.dz + corner[3] ) * BS ),
				normal = normal,
				u = uf == 1 and u1 or u0,
				v = vf == 1 and v1 or v0,
				color = color,
			} )
		end
	end

	local function emitBoxFace( buf, info, box, face )
		local u0, v0, u1, v1, rot, flipU, flipV = faceUV( info, face )
		pushQuad( buf, info, BOX_FACE_CORNERS[face]( box ), TRI,
			FACE_NORMALS[face] or N_UP, u0, v0, u1, v1, rot, flipU, flipV,
			useBakedShade and FACE_SHADE[face] or nil )
	end

	local CROSS_QUADS = {
		{ { 0, 0, 0, 0, 1 }, { 1, 1, 0, 1, 1 }, { 1, 1, 1, 1, 0 }, { 0, 0, 1, 0, 0 } },
		{ { 1, 0, 0, 0, 1 }, { 0, 1, 0, 1, 1 }, { 0, 1, 1, 1, 0 }, { 1, 0, 1, 0, 0 } },
	}

	local function emitCross( buf, info )
		local u0, v0, u1, v1 = faceUV( info, MC.Face.XP )
		local color = useBakedShade and CROSS_SHADE or nil
		for _, corners in ipairs( CROSS_QUADS ) do
			pushQuad( buf, info, corners, TRI, N_UP, u0, v0, u1, v1, 0, false, false, color )
			pushQuad( buf, info, corners, TRI_BACK, N_UP, u0, v0, u1, v1, 0, false, false, color )
		end
	end

	local function emitModelQuad( buf, info, modelData, quad )
		local tile = MC.BlockModelSurface and MC.BlockModelSurface( modelData, quad ) or quad.tile or 0
		local u0, v0, u1, v1 = tileUVRectWithUV( tile or 0, quad.uv )
		local face = quad.face or MC.Face.TOP
		local normal = FACE_NORMALS[face] or N_UP
		local color = useBakedShade and ( FACE_SHADE[face] or CROSS_SHADE ) or nil
		for t = 1, 6 do
			local vertexIndex = TRI[t]
			local x, y, z, uf, vf = MC.ModelQuadVertex( quad, vertexIndex )
			uf, vf = rotatedUVFlags( uf, vf, quad.rot or 0 )
			push( buf, {
				pos = Vector( ( info.dx + x ) * BS, ( info.dy + y ) * BS, ( info.dz + z ) * BS ),
				normal = normal,
				u = uf == 1 and u1 or u0,
				v = vf == 1 and v1 or v0,
				color = color,
			} )
		end
	end

	for _, info in ipairs( infos ) do
		local buf = info.translucent and buffers.translucent or buffers.opaque
		if info.cross then
			emitCross( buf, info )
		elseif info.models then
			for _, modelData in ipairs( info.models ) do
				for _, quad in ipairs( modelData.modelQuads ) do emitModelQuad( buf, info, modelData, quad ) end
			end
		else
			local boxes = MC.BlockBoxesForState and MC.BlockBoxesForState( info.stateId, info.dx, info.dy, info.dz ) or nil
			if not boxes or #boxes == 0 then boxes = { { 0, 0, 0, 1, 1, 1 } } end
			for _, box in ipairs( boxes ) do
				for face = 1, 6 do
					local off = FACE_OFFSETS[face]
					local hidden = isFullBlockBox( box )
						and fullCells[localCellKey( info.dx + off[1], info.dy + off[2], info.dz + off[3] )]
					if not hidden then emitBoxFace( buf, info, box, face ) end
				end
			end
		end
	end

	flush( buffers.opaque )
	flush( buffers.translucent )
	return built
end

------------------------------------------------------------- voxel lighting
-- Classic-style clusters are unlit meshes; modulate them with the same voxel
-- light sampler the entity lighting system uses (MC.SampleDynamicLightingRGB:
-- block + sky light, day cycle) so structures match the chunks around them.
-- mc_light_entity_cluster is a sub-item of the mc_light_entity family (both
-- convars are declared in cl_entity_lighting.lua): the master switch and the
-- cluster switch must both be on, mirroring the props/vehicles sub-switches.
local function clusterLightInterval()
	local cv = MC.EntityLightingInterval or GetConVar( "mc_light_entity_interval" )
	return math.Clamp( cv and cv:GetFloat() or 0.10, 0, 2 )
end

function MC.ClusterLightRGB( ent )
	if MC.ClusterEngineStyle == true then return 1, 1, 1 end -- engine lighting owns shading there
	local master = MC.EntityLightingEnabled or GetConVar( "mc_light_entity" )
	if not ( master and master:GetBool() ) then return 1, 1, 1 end
	local clusterSwitch = MC.EntityLightingClusters or GetConVar( "mc_light_entity_cluster" )
	if not ( clusterSwitch and clusterSwitch:GetBool() ) then return 1, 1, 1 end
	if not MC.SampleDynamicLightingRGB then return 1, 1, 1 end

	local sx, sy, sz
	local record = ent.ClusterRecord
	if record then
		sx, sy, sz = record.size[1], record.size[2], record.size[3]
	elseif ent.GetSizeX then
		sx, sy, sz = ent:GetSizeX(), ent:GetSizeY(), ent:GetSizeZ()
	end

	local samplePos
	if sx and sx > 0 and sy > 0 and sz > 0 then
		-- structure center at 65% height, same convention as entity lighting
		samplePos = ent:LocalToWorld( Vector( sx * MC.BS * 0.5, sy * MC.BS * 0.5, sz * MC.BS * 0.65 ) )
	else
		samplePos = ent:GetPos()
	end

	local now = CurTime()
	local interval = clusterLightInterval()
	local state = ent.ClusterLightState
	if not state then
		local r, g, b = MC.SampleDynamicLightingRGB( samplePos, 0 )
		state = {
			r = r, g = g, b = b,
			targetR = r, targetG = g, targetB = b,
			nextSample = now + interval * ( ( ent:EntIndex() % 7 ) / 7 ),
			lastUpdate = now,
		}
		ent.ClusterLightState = state
	else
		if interval <= 0 or now >= ( state.nextSample or 0 ) then
			local r, g, b = MC.SampleDynamicLightingRGB( samplePos, 0 )
			state.targetR, state.targetG, state.targetB = r, g, b
			state.nextSample = now + interval
		end
		local dt = math.Clamp( now - ( state.lastUpdate or now ), 0, 0.1 )
		state.lastUpdate = now
		local blend = 1 - math.exp( -dt * 12 )
		state.r = Lerp( blend, state.r, state.targetR or state.r )
		state.g = Lerp( blend, state.g, state.targetG or state.g )
		state.b = Lerp( blend, state.b, state.targetB or state.b )
	end

	local gainCv = MC.EntityLightingClusterGain or GetConVar( "mc_light_entity_cluster_gain" )
	local mul = math.Clamp( gainCv and gainCv:GetFloat() or 1, 0, 4 )
	return state.r * mul, state.g * mul, state.b * mul
end

------------------------------------------------------------- selection model
MC.ClusterSelection = MC.ClusterSelection or { cells = {}, count = 0, version = 0 }
MC.ClusterSelectMode = MC.ClusterSelectMode or "fine" -- "fine" | "box"
MC.ClusterBoxCorner = MC.ClusterBoxCorner or nil

local BOX_MAX_VOLUME = 300000
local aabbCache = { version = -1 }

local function selectionAABB()
	local sel = MC.ClusterSelection
	if aabbCache.version == sel.version then return aabbCache end
	aabbCache.version = sel.version
	if sel.count == 0 then
		aabbCache.valid = false
		return aabbCache
	end
	local minx, miny, minz = math.huge, math.huge, math.huge
	local maxx, maxy, maxz = -math.huge, -math.huge, -math.huge
	for _, cell in pairs( sel.cells ) do
		minx, miny, minz = math.min( minx, cell.bx ), math.min( miny, cell.by ), math.min( minz, cell.bz )
		maxx, maxy, maxz = math.max( maxx, cell.bx ), math.max( maxy, cell.by ), math.max( maxz, cell.bz )
	end
	aabbCache.valid = true
	aabbCache.minx, aabbCache.miny, aabbCache.minz = minx, miny, minz
	aabbCache.maxx, aabbCache.maxy, aabbCache.maxz = maxx, maxy, maxz
	return aabbCache
end

function MC.ClusterSelectionCount()
	return MC.ClusterSelection.count
end

function MC.ClusterSelectionClear( silent )
	MC.ClusterSelection = { cells = {}, count = 0, version = MC.ClusterSelection.version + 1 }
	MC.ClusterBoxCorner = nil
	if not silent then chat( L( "cluster.cleared", "已清空选区" ) ) end
end

-- silent add used by flood/box bulk paths; returns false, reason on failure
local function selectionTryAdd( bx, by, bz )
	local sel = MC.ClusterSelection
	local key = MC.CellKey( bx, by, bz )
	if sel.cells[key] then return true end
	if sel.count >= MC.ClusterMaxBlocks() then return false, "count" end
	if ( MC.GetBlockState( bx, by, bz ) or 0 ) == 0 then return false, "air" end

	local maxExtent = MC.ClusterMaxExtent()
	local aabb = selectionAABB()
	if aabb.valid then
		if math.max( aabb.maxx, bx ) - math.min( aabb.minx, bx ) + 1 > maxExtent
			or math.max( aabb.maxy, by ) - math.min( aabb.miny, by ) + 1 > maxExtent
			or math.max( aabb.maxz, bz ) - math.min( aabb.minz, bz ) + 1 > maxExtent then
			return false, "extent"
		end
	end

	sel.cells[key] = { bx = bx, by = by, bz = bz }
	sel.count = sel.count + 1
	sel.version = sel.version + 1
	return true
end

local ADD_FAIL_TEXT = {
	count = { "cluster.add_failed_count", "选区已达方块数上限" },
	extent = { "cluster.add_failed_extent", "选区尺寸超过上限" },
	air = { "cluster.add_failed_air", "那里没有方块" },
}

function MC.ClusterSelectionAdd( bx, by, bz )
	local ok, reason = selectionTryAdd( bx, by, bz )
	if not ok then
		local entry = ADD_FAIL_TEXT[reason]
		chat( entry and L( entry[1], entry[2] ) or L( "cluster.add_failed", "无法加选" ) )
	end
	return ok
end

function MC.ClusterSelectionRemove( bx, by, bz )
	local sel = MC.ClusterSelection
	local key = MC.CellKey( bx, by, bz )
	if not sel.cells[key] then return false end
	sel.cells[key] = nil
	sel.count = sel.count - 1
	sel.version = sel.version + 1
	return true
end

local FLOOD_NEIGHBORS = {
	{ 1, 0, 0 }, { -1, 0, 0 },
	{ 0, 1, 0 }, { 0, -1, 0 },
	{ 0, 0, 1 }, { 0, 0, -1 },
}

-- Flood-select the connected structure (6-neighborhood over non-air cells).
function MC.ClusterFloodSelect( bx, by, bz )
	if ( MC.GetBlockState( bx, by, bz ) or 0 ) == 0 then
		chat( L( "cluster.flood_air", "请准星对准一个方块再连通选择" ) )
		return
	end

	local visited = { [MC.CellKey( bx, by, bz )] = true }
	local queue = { { bx, by, bz } }
	local head = 1
	local added, limited = 0, false

	while queue[head] do
		local cell = queue[head]
		head = head + 1
		local ok, reason = selectionTryAdd( cell[1], cell[2], cell[3] )
		if ok then
			added = added + 1
			for _, off in ipairs( FLOOD_NEIGHBORS ) do
				local nx, ny, nz = cell[1] + off[1], cell[2] + off[2], cell[3] + off[3]
				local key = MC.CellKey( nx, ny, nz )
				if not visited[key] and ( MC.GetBlockState( nx, ny, nz ) or 0 ) ~= 0 then
					visited[key] = true
					queue[#queue + 1] = { nx, ny, nz }
				end
			end
		elseif reason == "count" or reason == "extent" then
			limited = true
			break
		end
	end

	if limited then
		chat( L( "cluster.flood_limited", "连通选择到达上限, 已选 {n} 个方块", { n = MC.ClusterSelection.count } ) )
	elseif added > 0 then
		chat( L( "cluster.flood_done", "连通选择 +{n} (共 {total})", { n = added, total = MC.ClusterSelection.count } ) )
	end
end

-- Box mode: first click stores a corner, second click commits every non-air
-- cell in the box into the selection set.
function MC.ClusterBoxClick( bx, by, bz )
	local corner = MC.ClusterBoxCorner
	if not corner then
		MC.ClusterBoxCorner = { bx = bx, by = by, bz = bz }
		chat( L( "cluster.corner_a", "已选第一个角点, 再选对角完成框选" ) )
		return
	end

	local minx, maxx = math.min( corner.bx, bx ), math.max( corner.bx, bx )
	local miny, maxy = math.min( corner.by, by ), math.max( corner.by, by )
	local minz, maxz = math.min( corner.bz, bz ), math.max( corner.bz, bz )
	local maxExtent = MC.ClusterMaxExtent()
	if maxx - minx + 1 > maxExtent or maxy - miny + 1 > maxExtent or maxz - minz + 1 > maxExtent then
		chat( L( "cluster.box_extent", "框选尺寸超过上限 ({max} 格)", { max = maxExtent } ) )
		return
	end
	local volume = ( maxx - minx + 1 ) * ( maxy - miny + 1 ) * ( maxz - minz + 1 )
	if volume > BOX_MAX_VOLUME then
		chat( L( "cluster.box_volume", "框选体积太大" ) )
		return
	end

	MC.ClusterBoxCorner = nil
	local added, limited = 0, false
	for z = minz, maxz do
		for y = miny, maxy do
			for x = minx, maxx do
				if ( MC.GetBlockState( x, y, z ) or 0 ) ~= 0 then
					local ok, reason = selectionTryAdd( x, y, z )
					if ok then
						added = added + 1
					elseif reason == "count" or reason == "extent" then
						limited = true
						break
					end
				end
			end
			if limited then break end
		end
		if limited then break end
	end

	if limited then
		chat( L( "cluster.box_limited", "框选到达上限, 已选 {n} 个方块", { n = MC.ClusterSelection.count } ) )
	else
		chat( L( "cluster.box_done", "框选 +{n} (共 {total})", { n = added, total = MC.ClusterSelection.count } ) )
	end
end

--------------------------------------------------------------- aim / senders
-- Client entities carry no physics for the multiconvex, so aim detection
-- ray-tests each cluster's OBB instead of relying on the eye trace.
function MC.ClusterAimedCluster()
	local ply = LocalPlayer()
	if not IsValid( ply ) then return nil end
	local eye = ply:EyePos()
	local dir = ply:EyeAngles():Forward()

	local tr = ply:GetEyeTrace()
	local worldDist = tr and tr.Hit and tr.HitPos:Distance( eye ) or 32768

	local best, bestDist
	for _, ent in ipairs( ents.FindByClass( CLUSTER_CLASS ) ) do
		-- prefer the record, but fall back to the networked size so aiming
		-- works before the cell payload has arrived
		local sx, sy, sz
		local record = ent.ClusterRecord
		if record then
			sx, sy, sz = record.size[1], record.size[2], record.size[3]
		elseif ent.GetSizeX then
			sx, sy, sz = ent:GetSizeX(), ent:GetSizeY(), ent:GetSizeZ()
		end
		if sx and sx > 0 and sy > 0 and sz > 0 then
			local maxs = Vector( sx * MC.BS, sy * MC.BS, sz * MC.BS )
			local hit = util.IntersectRayWithOBB( eye, dir * 4096, ent:GetPos(), ent:GetAngles(), vector_origin, maxs )
			if hit then
				local dist = hit:Distance( eye )
				if dist <= worldDist + 1 and ( not bestDist or dist < bestDist ) then
					best, bestDist = ent, dist
				end
			end
		end
	end
	return best
end

function MC.ClusterSendConvert()
	local sel = MC.ClusterSelection
	if sel.count == 0 then
		chat( L( "cluster.nothing_selected", "先选择一些方块 (左键加选 / E 连通选择 / 框选)" ) )
		return
	end
	net.Start( "mc_cluster_convert" )
		net.WriteUInt( sel.count, 13 )
		net.WriteBool( MC.ClusterSelectMode == "crate" )
		for _, cell in pairs( sel.cells ) do
			net.WriteInt( cell.bx, Net.COORD_BITS )
			net.WriteInt( cell.by, Net.COORD_BITS )
			net.WriteInt( cell.bz, Net.COORD_BITS )
		end
	net.SendToServer()
	MC.ClusterSelectionClear( true )
end

function MC.ClusterSendPaste( ent )
	if not IsValid( ent ) then return end
	net.Start( "mc_cluster_paste" )
		net.WriteUInt( ent:EntIndex(), 16 )
	net.SendToServer()
end

------------------------------------------------------------------ paste ghost
-- Mirror of the server snap so the ghost lands exactly where the paste will.
function MC.ClusterPasteGhost( ent )
	local record = ent.ClusterRecord
	if not record then return nil end

	local cache = ent.ClusterGhostCache
	if cache and cache.expires > CurTime() then return cache end

	local snap = MC.ClusterComputeSnap( ent:GetPos(), ent:GetAngles() )
	if not snap then
		cache = { tilted = true, expires = CurTime() + 0.15 }
		ent.ClusterGhostCache = cache
		return cache
	end

	local targetMin, rotatedCells, rotatedSize = MC.ClusterSnapTargets( record, snap.pos, snap.rotation )
	local blocked = 0
	for i = 1, #rotatedCells, 4 do
		local bx = targetMin[1] + rotatedCells[i]
		local by = targetMin[2] + rotatedCells[i + 1]
		local bz = targetMin[3] + rotatedCells[i + 2]
		if ( MC.GetBlockState( bx, by, bz ) or 0 ) ~= 0 then blocked = blocked + 1 end
	end

	local offset = MC.ClusterRotatedMinOffset( rotatedSize, snap.rotation )
	local matrix = Matrix()
	matrix:SetTranslation( MC.CellWorldMin( targetMin[1], targetMin[2], targetMin[3] ) - offset )
	matrix:Rotate( Angle( 0, snap.rotation * 90, 0 ) )

	cache = {
		matrix = matrix,
		blocked = blocked,
		rotation = snap.rotation,
		expires = CurTime() + 0.15,
	}
	ent.ClusterGhostCache = cache
	return cache
end

--------------------------------------------------------------- net receivers
-- Spawn-pushed payloads can arrive before the entity snapshot; park them here
-- and the entity claims them from its Initialize/Think (TryClusterData).
MC.ClusterPendingRecords = MC.ClusterPendingRecords or {}

local function prunePendingRecords()
	local now = CurTime()
	for index, entry in pairs( MC.ClusterPendingRecords ) do
		if entry.expires < now then MC.ClusterPendingRecords[index] = nil end
	end
end

net.Receive( "mc_cluster_data", function()
	local index = net.ReadUInt( 16 )
	local len = net.ReadUInt( 16 )
	local blob = net.ReadData( len )
	local record = MC.ClusterDecode( blob )
	if not record then return end

	local ent = Entity( index )
	if IsValid( ent ) and ent:GetClass() == CLUSTER_CLASS and ent.ApplyClusterRecord then
		ent:ApplyClusterRecord( record )
		return
	end

	prunePendingRecords()
	MC.ClusterPendingRecords[index] = { record = record, expires = CurTime() + 15 }
end )

local function pruneRecentRemoved()
	local now = CurTime()
	for index, entry in pairs( MC.ClusterRecentRemoved or {} ) do
		if entry.expires < now then MC.ClusterRecentRemoved[index] = nil end
	end
end

net.Receive( "mc_cluster_break", function()
	local index = net.ReadUInt( 16 )
	local isSpawn = net.ReadBool()
	pruneRecentRemoved()

	local record, matrix
	local ent = Entity( index )
	if IsValid( ent ) and ent:GetClass() == CLUSTER_CLASS and ent.ClusterRecord then
		record = ent.ClusterRecord
		matrix = ent:GetWorldTransformMatrix()
	else
		local cached = MC.ClusterRecentRemoved and MC.ClusterRecentRemoved[index] or nil
		if cached then
			record, matrix = cached.record, cached.matrix
			MC.ClusterRecentRemoved[index] = nil
		end
	end
	if not record or not matrix then return end

	local cells = record.cells
	local cellCount = math.floor( #cells / 4 )
	local samples = math.min( cellCount, isSpawn and 8 or 14 )
	local soundSamples = isSpawn and 2 or 4
	local fxKind = isSpawn and 1 or 2
	for s = 1, samples do
		local i = ( math.random( cellCount ) - 1 ) * 4 + 1
		local stateId = cells[i + 3]
		local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
		if id and id ~= 0 then
			local pos = matrix * Vector( ( cells[i] + 0.5 ) * MC.BS, ( cells[i + 1] + 0.5 ) * MC.BS, ( cells[i + 2] + 0.5 ) * MC.BS )
			local cx, cy, cz = MC.WorldToCell( pos )
			if s <= soundSamples and MC.PlayBlockFx then
				MC.PlayBlockFx( fxKind, id, 0, cx, cy, cz, false, stateId )
			elseif MC.SpawnBlockBreakParticles then
				local tintCode = MC.BlockStateTintCode and MC.BlockStateTintCode( stateId, id, 0 ) or 0
				MC.SpawnBlockBreakParticles( id, 0, cx, cy, cz, { tintCode = tintCode } )
			end
		end
	end
end )

------------------------------------------------------------ preview rendering
local COLOR_SELECTED_WIRE = Color( 120, 225, 255, 255 )
local COLOR_SELECTED_FILL = Color( 90, 200, 255, 42 )
local COLOR_CORNER = Color( 255, 220, 80, 255 )
local COLOR_CORNER_FILL = Color( 255, 220, 80, 60 )
local COLOR_PENDING_BOX = Color( 255, 220, 80, 230 )

-- Cell-exact boxes z-fight with the block faces they sit on; push every
-- selection box outward so the lines float clearly off the surface. Fills
-- use a smaller inflate than wires so their surfaces are never coplanar.
local CELL_INFLATE = 1.6
local FILL_INFLATE = 1.1
local CORNER_INFLATE = 2.8
local CORNER_FILL_INFLATE = 2.3

local function activeClusterTool( ply )
	if not IsValid( ply ) then return false end
	local wep = ply:GetActiveWeapon()
	return IsValid( wep ) and wep:GetClass() == "mc_cluster_tool"
end

local function inflatedCellBounds( bx, by, bz, inflate )
	return MC.CellWorldMin( bx, by, bz ),
		Vector( -inflate, -inflate, -inflate ),
		Vector( MC.BS + inflate, MC.BS + inflate, MC.BS + inflate )
end

local function drawCellFill( bx, by, bz, color, inflate )
	local base, mins, maxs = inflatedCellBounds( bx, by, bz, inflate or CELL_INFLATE )
	render.DrawBox( base, angle_zero, mins, maxs, color )
end

local function drawCellBox( bx, by, bz, color, inflate )
	local base, mins, maxs = inflatedCellBounds( bx, by, bz, inflate or CELL_INFLATE )
	render.DrawWireframeBox( base, angle_zero, mins, maxs, color, true )
end

local function drawInflatedRegionBox( minx, miny, minz, maxx, maxy, maxz, color )
	local inflate = CELL_INFLATE
	local base = MC.CellWorldMin( minx, miny, minz )
	local mins = Vector( -inflate, -inflate, -inflate )
	local maxs = Vector(
		( maxx - minx + 1 ) * MC.BS + inflate,
		( maxy - miny + 1 ) * MC.BS + inflate,
		( maxz - minz + 1 ) * MC.BS + inflate )
	render.DrawWireframeBox( base, angle_zero, mins, maxs, color, true )
end

-- The selection overlay is batched into IMeshes rebuilt only when the
-- selection version changes: immediate-mode DrawWireframeBox is 12 draws per
-- cell, which both crawled at a few hundred cells and forced a draw cap that
-- silently skipped cells. Batched, every selected cell renders in a handful
-- of draw calls. The vertexalpha material is translucent, so the engine
-- depth-tests without depth-writing (fills cannot occlude each other or the
-- wires). Survives Lua refresh via the MC global.
local overlay = MC.ClusterSelectionOverlay or { version = -1, meshes = {} }
MC.ClusterSelectionOverlay = overlay
overlay.version = -1 -- force one rebuild after every file (re)load

local OVERLAY_MAX_CELLS_PER_MESH = 1500 -- quads 36k verts, lines 36k verts: both under the IMesh cap

local overlayMat

local function overlayMaterial()
	if overlayMat and not overlayMat:IsError() then return overlayMat end
	overlayMat = CreateMaterial( "mc_cluster_sel_overlay1", "UnlitGeneric", {
		["$basetexture"] = "color/white",
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
		["$nocull"] = "1",
	} )
	return overlayMat
end

-- box corners: 1..4 bottom (x0y0 x1y0 x0y1 x1y1), 5..8 top
local OVERLAY_FACES = {
	{ 1, 2, 4, 3 }, { 5, 6, 8, 7 },
	{ 1, 2, 6, 5 }, { 3, 4, 8, 7 },
	{ 1, 3, 7, 5 }, { 2, 4, 8, 6 },
}
local OVERLAY_EDGES = {
	{ 1, 2 }, { 2, 4 }, { 4, 3 }, { 3, 1 },
	{ 5, 6 }, { 6, 8 }, { 8, 7 }, { 7, 5 },
	{ 1, 5 }, { 2, 6 }, { 3, 7 }, { 4, 8 },
}

local function cellCorners( cell, inflate, out )
	local x0 = cell.bx * MC.BS - inflate
	local y0 = cell.by * MC.BS - inflate
	local z0 = cell.bz * MC.BS - inflate
	local x1 = ( cell.bx + 1 ) * MC.BS + inflate
	local y1 = ( cell.by + 1 ) * MC.BS + inflate
	local z1 = ( cell.bz + 1 ) * MC.BS + inflate
	out[1].x, out[1].y, out[1].z = x0, y0, z0
	out[2].x, out[2].y, out[2].z = x1, y0, z0
	out[3].x, out[3].y, out[3].z = x0, y1, z0
	out[4].x, out[4].y, out[4].z = x1, y1, z0
	out[5].x, out[5].y, out[5].z = x0, y0, z1
	out[6].x, out[6].y, out[6].z = x1, y0, z1
	out[7].x, out[7].y, out[7].z = x0, y1, z1
	out[8].x, out[8].y, out[8].z = x1, y1, z1
	return out
end

local function freeSelectionOverlay()
	for _, entry in ipairs( overlay.meshes ) do
		if entry.fill then entry.fill:Destroy() end
		if entry.wire then entry.wire:Destroy() end
	end
	overlay.meshes = {}
end

local overlayCorners = {}
for i = 1, 8 do overlayCorners[i] = Vector() end

local buildOverlayBatch

local function rebuildSelectionOverlay( sel )
	freeSelectionOverlay()
	overlay.version = sel.version
	if sel.count == 0 then return end

	local mat = overlayMaterial()
	local batch = {}
	local batchN = 0
	for _, cell in pairs( sel.cells ) do
		batchN = batchN + 1
		batch[batchN] = cell
		if batchN >= OVERLAY_MAX_CELLS_PER_MESH then
			overlay.meshes[#overlay.meshes + 1] = buildOverlayBatch( mat, batch, batchN )
			batch, batchN = {}, 0
		end
	end
	if batchN > 0 then
		overlay.meshes[#overlay.meshes + 1] = buildOverlayBatch( mat, batch, batchN )
	end
end

buildOverlayBatch = function( mat, cells, count )
	local meshObj = Mesh( mat )
	mesh.Begin( meshObj, MATERIAL_QUADS, count * 6 )
	for i = 1, count do
		local corners = cellCorners( cells[i], FILL_INFLATE, overlayCorners )
		for _, face in ipairs( OVERLAY_FACES ) do
			for v = 1, 4 do
				local p = corners[face[v]]
				mesh.Position( p )
				mesh.Color( COLOR_SELECTED_FILL.r, COLOR_SELECTED_FILL.g, COLOR_SELECTED_FILL.b, COLOR_SELECTED_FILL.a )
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()

	local lineObj = Mesh( mat )
	mesh.Begin( lineObj, MATERIAL_LINES, count * 12 )
	for i = 1, count do
		local corners = cellCorners( cells[i], CELL_INFLATE, overlayCorners )
		for _, edge in ipairs( OVERLAY_EDGES ) do
			for v = 1, 2 do
				local p = corners[edge[v]]
				mesh.Position( p )
				mesh.Color( COLOR_SELECTED_WIRE.r, COLOR_SELECTED_WIRE.g, COLOR_SELECTED_WIRE.b, COLOR_SELECTED_WIRE.a )
				mesh.AdvanceVertex()
			end
		end
	end
	mesh.End()

	return { fill = meshObj, wire = lineObj }
end

local function drawSelection()
	local sel = MC.ClusterSelection
	if sel.count == 0 then
		if #overlay.meshes > 0 then freeSelectionOverlay() end
		return
	end
	if overlay.version ~= sel.version then rebuildSelectionOverlay( sel ) end

	render.SetMaterial( overlayMaterial() )
	for _, entry in ipairs( overlay.meshes ) do
		entry.fill:Draw()
	end
	for _, entry in ipairs( overlay.meshes ) do
		entry.wire:Draw()
	end
end

local function drawPendingBox( aim )
	local corner = MC.ClusterBoxCorner
	if not corner then return end
	render.SetColorMaterial()
	render.OverrideDepthEnable( true, false )
	drawCellFill( corner.bx, corner.by, corner.bz, COLOR_CORNER_FILL, CORNER_FILL_INFLATE )
	render.OverrideDepthEnable( false, false )
	drawCellBox( corner.bx, corner.by, corner.bz, COLOR_CORNER, CORNER_INFLATE )
	if not aim then return end
	drawInflatedRegionBox(
		math.min( corner.bx, aim.bx ), math.min( corner.by, aim.by ), math.min( corner.bz, aim.bz ),
		math.max( corner.bx, aim.bx ), math.max( corner.by, aim.by ), math.max( corner.bz, aim.bz ),
		COLOR_PENDING_BOX )
end

local function drawPasteGhost( ent )
	local ghost = MC.ClusterPasteGhost( ent )
	if not ghost or ghost.tilted or not ghost.matrix then return end
	local built = ent.ClusterMeshes
	if not built then return end

	local good = ghost.blocked == 0
	cam.PushModelMatrix( ghost.matrix )
		render.SetBlend( 0.45 )
		if good then
			render.SetColorModulation( 0.55, 1, 0.6 )
		else
			render.SetColorModulation( 1, 0.42, 0.42 )
		end
		for _, list in pairs( built ) do
			for _, entry in ipairs( list ) do
				render.SetMaterial( entry.ghostMaterial or entry.material )
				entry.mesh:Draw()
			end
		end
		render.SetColorModulation( 1, 1, 1 )
		render.SetBlend( 1 )
	cam.PopModelMatrix()
end

hook.Add( "PostDrawTranslucentRenderables", "mc_cluster_selection_outline", function( _, bSky, bSky3D )
	-- bSky is also true on the main pass on 2D-sky maps; skip only the 3D skybox pass
	if bSky3D then return end
	local ply = LocalPlayer()
	if not IsValid( ply ) or not ply:Alive() then return end
	if not activeClusterTool( ply ) then return end

	local aim = MC.PlayerBlockAim and MC.PlayerBlockAim( ply ) or nil
	local aimedCluster = MC.ClusterAimedCluster()

	drawSelection()

	if aimedCluster then
		drawPasteGhost( aimedCluster )
		return
	end

	if MC.ClusterSelectMode == "box" or MC.ClusterSelectMode == "crate" then
		drawPendingBox( aim )
	end
	if aim then
		local inSelection = MC.ClusterSelection.cells[MC.CellKey( aim.bx, aim.by, aim.bz )] ~= nil
		MC.DrawBlockOutline( aim.Block, aim.Orient, aim.bx, aim.by, aim.bz,
			inSelection and Color( 255, 120, 120, 235 ) or Color( 255, 255, 255, 235 ), aim.StateId )
	end
end )
