-- Client crack-stage projection. It is presentation only; the server decides
-- progress, cancellation and completion.

if not CLIENT then return end

MC = MC or {}
MC.ClientMiningCracks = MC.ClientMiningCracks or {}

local materials = {}
for stage = 0, 9 do
	materials[stage] = Material( "mc/block/destroy_stage_" .. stage .. ".png",
		"alphatest noclamp vertexcolor vertexalpha" )
end

local TRI = { 1, 3, 2, 1, 4, 3 }
local TRI_BACK = { 1, 2, 3, 1, 3, 4 }
local N_UP = Vector( 0, 0, 1 )
local N_DOWN = Vector( 0, 0, -1 )
local N_XP = Vector( 1, 0, 0 )
local N_XN = Vector( -1, 0, 0 )
local N_YP = Vector( 0, 1, 0 )
local N_YN = Vector( 0, -1, 0 )
local WHITE = Color( 255, 255, 255, 255 )
local SURFACE_OFFSET = 0.04

local FACE_NORMALS = {
	[MC.Face.TOP] = N_UP,
	[MC.Face.BOTTOM] = N_DOWN,
	[MC.Face.XP] = N_XP,
	[MC.Face.XN] = N_XN,
	[MC.Face.YP] = N_YP,
	[MC.Face.YN] = N_YN,
}

local BOX_FACE_CORNERS = {
	[MC.Face.TOP] = function( b ) return {
		{ b[1], b[2], b[6] }, { b[4], b[2], b[6] }, { b[4], b[5], b[6] }, { b[1], b[5], b[6] },
	} end,
	[MC.Face.BOTTOM] = function( b ) return {
		{ b[1], b[5], b[3] }, { b[4], b[5], b[3] }, { b[4], b[2], b[3] }, { b[1], b[2], b[3] },
	} end,
	[MC.Face.XP] = function( b ) return {
		{ b[4], b[2], b[3] }, { b[4], b[5], b[3] }, { b[4], b[5], b[6] }, { b[4], b[2], b[6] },
	} end,
	[MC.Face.XN] = function( b ) return {
		{ b[1], b[5], b[3] }, { b[1], b[2], b[3] }, { b[1], b[2], b[6] }, { b[1], b[5], b[6] },
	} end,
	[MC.Face.YP] = function( b ) return {
		{ b[4], b[5], b[3] }, { b[1], b[5], b[3] }, { b[1], b[5], b[6] }, { b[4], b[5], b[6] },
	} end,
	[MC.Face.YN] = function( b ) return {
		{ b[1], b[2], b[3] }, { b[4], b[2], b[3] }, { b[4], b[2], b[6] }, { b[1], b[2], b[6] },
	} end,
}

local function freeCrackMesh( crack )
	local meshObject = crack and crack.mesh
	if meshObject and meshObject.Destroy then meshObject:Destroy() end
	if crack then
		crack.mesh = nil
		crack.meshStateId = nil
	end
end

net.Receive( "mc_mining_progress", function()
	local miner = net.ReadEntity()
	local bx = net.ReadInt( MC.Net.COORD_BITS )
	local by = net.ReadInt( MC.Net.COORD_BITS )
	local bz = net.ReadInt( MC.Net.COORD_BITS )
	local encodedStage = net.ReadUInt( 4 )
	if not IsValid( miner ) then return end

	local key = miner:EntIndex()
	local previous = MC.ClientMiningCracks[key]
	if encodedStage == 0 then
		freeCrackMesh( previous )
		MC.ClientMiningCracks[key] = nil
		return
	end

	local crack = {
		miner = miner,
		bx = bx, by = by, bz = bz,
		stage = math.Clamp( encodedStage - 1, 0, 9 ),
	}
	-- The ten progress stages share geometry. Preserve it while the miner keeps
	-- working on the same cell and only switch the material at draw time.
	if previous and previous.bx == bx and previous.by == by and previous.bz == bz then
		crack.mesh = previous.mesh
		crack.meshStateId = previous.meshStateId
		crack.matrix = previous.matrix
		crack.nextHitSoundAt = previous.nextHitSoundAt
	else
		freeCrackMesh( previous )
		crack.nextHitSoundAt = CurTime()
	end
	MC.ClientMiningCracks[key] = crack
end )

local function rotatedUVFlags( uf, vf, rotation )
	rotation = ( rotation or 0 ) % 4
	if rotation == 1 then return vf, 1 - uf end
	if rotation == 2 then return 1 - uf, 1 - vf end
	if rotation == 3 then return 1 - vf, uf end
	return uf, vf
end

local function boxUV( face, x, y, z )
	if face == MC.Face.TOP then return x, 1 - y end
	if face == MC.Face.BOTTOM then return x, y end
	if face == MC.Face.XP then return y, 1 - z end
	if face == MC.Face.XN then return 1 - y, 1 - z end
	if face == MC.Face.YP then return 1 - x, 1 - z end
	return x, 1 - z
end

local function quadNormal( points, fallback )
	local edgeA = points[2] - points[1]
	local edgeB = points[3] - points[1]
	local normal = edgeA:Cross( edgeB )
	if normal:LengthSqr() <= 0.000001 then return fallback end
	normal:Normalize()
	return normal
end

local function addTriangleQuad( vertices, points, uvs, normal, order )
	local bs = tonumber( MC.BS ) or 36.5
	for index = 1, 6 do
		local source = order[index]
		vertices[#vertices + 1] = {
			pos = points[source] * bs + normal * SURFACE_OFFSET,
			normal = normal,
			u = uvs[source][1],
			v = uvs[source][2],
			color = WHITE,
		}
	end
end

local function emitModelQuad( vertices, quad )
	local points, uvs = {}, {}
	local uv = quad.uv
	local u0 = ( uv and tonumber( uv[1] ) or 0 ) / 16
	local v0 = ( uv and tonumber( uv[2] ) or 0 ) / 16
	local u1 = ( uv and tonumber( uv[3] ) or 16 ) / 16
	local v1 = ( uv and tonumber( uv[4] ) or 16 ) / 16
	for index = 1, 4 do
		local x, y, z, uf, vf = MC.ModelQuadVertex( quad, index )
		uf, vf = rotatedUVFlags( uf, vf, quad.rot or 0 )
		points[index] = Vector( x, y, z )
		uvs[index] = { u0 + ( u1 - u0 ) * uf, v0 + ( v1 - v0 ) * vf }
	end
	local fallback = FACE_NORMALS[quad.face or MC.Face.TOP] or N_UP
	addTriangleQuad( vertices, points, uvs, quadNormal( points, fallback ), TRI )
end

local function emitBoxFace( vertices, box, face )
	local points, uvs = {}, {}
	for index, corner in ipairs( BOX_FACE_CORNERS[face]( box ) ) do
		local x, y, z = corner[1], corner[2], corner[3]
		points[index] = Vector( x, y, z )
		uvs[index] = { boxUV( face, x, y, z ) }
	end
	addTriangleQuad( vertices, points, uvs, FACE_NORMALS[face] or N_UP, TRI )
end

local function emitCross( vertices )
	local quads = {
		{ Vector( 0, 0, 0 ), Vector( 1, 1, 0 ), Vector( 1, 1, 1 ), Vector( 0, 0, 1 ) },
		{ Vector( 1, 0, 0 ), Vector( 0, 1, 0 ), Vector( 0, 1, 1 ), Vector( 1, 0, 1 ) },
	}
	local uvs = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } }
	for _, points in ipairs( quads ) do
		local normal = quadNormal( points, N_UP )
		addTriangleQuad( vertices, points, uvs, normal, TRI )
		addTriangleQuad( vertices, points, uvs, -normal, TRI_BACK )
	end
end

local function buildCrackMesh( crack, stateId )
	local vertices = {}
	local modelCount = 0
	if MC.VisitStateVisualModels and MC.StateVisualModelData and MC.ModelQuadVertex then
		MC.VisitStateVisualModels( stateId, crack.bx, crack.by, crack.bz, function( modelId )
			local modelData = MC.StateVisualModelData( modelId )
			for _, quad in ipairs( modelData and modelData.modelQuads or {} ) do
				emitModelQuad( vertices, quad )
				modelCount = modelCount + 1
			end
		end )
	end

	if modelCount == 0 then
		local id = MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
		local block = MC.Blocks and MC.Blocks[id] or nil
		if block and block.shape == "cross" then
			emitCross( vertices )
		else
			local boxes = MC.BlockBoxesForState and MC.BlockBoxesForState(
				stateId, crack.bx, crack.by, crack.bz ) or nil
			if not boxes or #boxes == 0 then boxes = { { 0, 0, 0, 1, 1, 1 } } end
			for _, box in ipairs( boxes ) do
				for face = 1, 6 do emitBoxFace( vertices, box, face ) end
			end
		end
	end

	if #vertices < 3 then return nil end
	local meshObject = Mesh( materials[0] )
	meshObject:BuildFromTriangles( vertices )
	return meshObject
end

local function drawCrack( crack )
	if not IsValid( crack.miner ) then
		freeCrackMesh( crack )
		return false
	end
	local stateId = MC.GetBlockState and MC.GetBlockState( crack.bx, crack.by, crack.bz ) or 0
	if stateId == 0 then
		freeCrackMesh( crack )
		return false
	end
	local material = materials[crack.stage]
	if not material or material:IsError() then return true end

	if not crack.mesh or crack.meshStateId ~= stateId then
		freeCrackMesh( crack )
		crack.mesh = buildCrackMesh( crack, stateId )
		crack.meshStateId = stateId
	end
	if not crack.mesh then return true end

	local origin = MC.CellRenderMin and MC.CellRenderMin( crack.bx, crack.by, crack.bz )
		or MC.CellWorldMin( crack.bx, crack.by, crack.bz )
	crack.matrix = crack.matrix or Matrix()
	crack.matrix:SetTranslation( origin )
	cam.PushModelMatrix( crack.matrix )
		render.SetMaterial( material )
		crack.mesh:Draw()
	cam.PopModelMatrix()
	return true
end

local minecraftBlendAvailable = render.OverrideBlend
	and BLEND_DST_COLOR ~= nil and BLEND_SRC_COLOR ~= nil
	and BLEND_ONE ~= nil and BLEND_ZERO ~= nil and BLENDFUNC_ADD ~= nil

local function crackCullMode()
	local value = MC.MeshCullMode and MC.MeshCullMode.GetString and MC.MeshCullMode:GetString() or "ccw"
	value = string.lower( tostring( value ) )
	if value == "cw" or value == "clockwise" then return MATERIAL_CULLMODE_CW or 1 end
	return MATERIAL_CULLMODE_CCW or 0
end

-- MultiPlayerGameMode#continueDestroyBlock plays SoundType#getHitSound every
-- four 20 TPS ticks. The server's crack session is the authority for whether
-- mining is still active; clients only schedule the positional presentation.
hook.Add( "Think", "mc_survival_mining_hit_sounds", function()
	if not MC.PlayBlockMiningHitSound then return end
	local now = CurTime()
	for _, crack in pairs( MC.ClientMiningCracks ) do
		if IsValid( crack.miner ) and now >= ( crack.nextHitSoundAt or 0 ) then
			local stateId = MC.GetBlockState and MC.GetBlockState( crack.bx, crack.by, crack.bz ) or 0
			local blockId = stateId ~= 0 and MC.BlockTypeForState and MC.BlockTypeForState( stateId ) or 0
			if blockId ~= 0 then
				local pos = MC.CellRenderCenter and MC.CellRenderCenter( crack.bx, crack.by, crack.bz )
					or MC.CellWorldCenter( crack.bx, crack.by, crack.bz )
				MC.PlayBlockMiningHitSound( blockId, pos )
			end
			crack.nextHitSoundAt = now + 4 / 20
		end
	end
end )

hook.Add( "PostDrawTranslucentRenderables", "mc_survival_mining_cracks", function( _, drawingSkybox, drawing3DSkybox )
	if drawingSkybox or drawing3DSkybox or not minecraftBlendAvailable then return end
	local usePointFilter = render.PushFilterMin and render.PushFilterMag and TEXFILTER and TEXFILTER.POINT
	if usePointFilter then
		render.PushFilterMin( TEXFILTER.POINT )
		render.PushFilterMag( TEXFILTER.POINT )
	end

	-- Minecraft's CRUMBLING pipeline uses (DST_COLOR, SRC_COLOR): white texels
	-- preserve the block and darker destroy-stage texels multiply cracks into it.
	if render.CullMode then render.CullMode( crackCullMode() ) end
	if render.OverrideDepthEnable then render.OverrideDepthEnable( true, false ) end
	render.OverrideBlend( true,
		BLEND_DST_COLOR, BLEND_SRC_COLOR, BLENDFUNC_ADD,
		BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD )
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
	for key, crack in pairs( MC.ClientMiningCracks ) do
		if not drawCrack( crack ) then MC.ClientMiningCracks[key] = nil end
	end
	render.OverrideBlend( false )
	if render.OverrideDepthEnable then render.OverrideDepthEnable( false, false ) end
	if render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
	render.SetColorModulation( 1, 1, 1 )
	render.SetBlend( 1 )

	if usePointFilter then
		render.PopFilterMag()
		render.PopFilterMin()
	end
end )

hook.Add( "ShutDown", "mc_clear_survival_mining_cracks", function()
	for _, crack in pairs( MC.ClientMiningCracks ) do freeCrackMesh( crack ) end
	MC.ClientMiningCracks = {}
end )
