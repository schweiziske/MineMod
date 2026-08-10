-- Client sparse Block Entity renderer for vanilla standing and wall banners.

MC = MC or {}

local MAX_RENDER_DISTANCE_SQR = ( ( MC.BS or 36.5 ) * 64 ) ^ 2
local MATERIAL_FLAGS = "alphatest vertexcolor vertexalpha noclamp nocull"
local BANNER_BODY = Material( "mc/entity/banner/banner_base.png", MATERIAL_FLAGS )
local BANNER_MATERIALS = {}

for _, patternName in ipairs( MC.BannerPatternNames or {} ) do
	local pattern = MC.BannerPatternAssets[patternName]
	BANNER_MATERIALS[patternName] = Material( "mc/entity/banner/" .. pattern.asset .. ".png", MATERIAL_FLAGS )
end

local function emitVertex( position, u, v, color, normal )
	mesh.Position( position )
	if mesh.Normal then mesh.Normal( normal ) end
	mesh.Color( color.r, color.g, color.b, color.a )
	mesh.TexCoord( 0, u, v )
	mesh.AdvanceVertex()
end

local function emitQuad( a, b, c, d, u0, v0, u1, v1, color, normal )
	emitVertex( a, u0, v0, color, normal )
	emitVertex( b, u1, v0, color, normal )
	emitVertex( c, u1, v1, color, normal )
	emitVertex( d, u0, v1, color, normal )
end

local function emitBox( center, right, forward, up, halfRight, halfForward, halfUp, uv, color )
	local r, f, z = right * halfRight, forward * halfForward, up * halfUp
	local ppp, ppn = center + r + f + z, center + r + f - z
	local pnp, pnn = center + r - f + z, center + r - f - z
	local npp, npn = center - r + f + z, center - r + f - z
	local nnp, nnn = center - r - f + z, center - r - f - z
	local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
	emitQuad( npp, ppp, ppn, npn, u0, v0, u1, v1, color, forward )
	emitQuad( pnp, nnp, nnn, pnn, u0, v0, u1, v1, color, -forward )
	emitQuad( ppp, pnp, pnn, ppn, u0, v0, u1, v1, color, right )
	emitQuad( nnp, npp, npn, nnn, u0, v0, u1, v1, color, -right )
	emitQuad( nnp, pnp, ppp, npp, u0, v0, u1, v1, color, up )
	emitQuad( npn, ppn, pnn, nnn, u0, v0, u1, v1, color, -up )
end

local function bannerYaw( stateId )
	if MC.IsWallBannerState( stateId ) then
		local facing = MC.GetStateProperty( stateId, "facing" )
		return facing == "south" and 0 or facing == "west" and 90 or facing == "north" and 180 or 270
	end
	return ( tonumber( MC.GetStateProperty( stateId, "rotation" ) ) or 0 ) * 22.5
end

local function litColor( source, lightR, lightG, lightB )
	return Color(
		math.Clamp( math.floor( source.r * lightR + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( source.g * lightG + 0.5 ), 0, 255 ),
		math.Clamp( math.floor( source.b * lightB + 0.5 ), 0, 255 ),
		255
	)
end

local function bannerBasis( bx, by, bz, stateId )
	local bs = MC.BS or 36.5
	local yaw = bannerYaw( stateId )
	local radians = math.rad( yaw )
	local right = Vector( math.cos( radians ), math.sin( radians ), 0 )
	local normal = Vector( -math.sin( radians ), math.cos( radians ), 0 )
	local up = Vector( 0, 0, 1 )
	local base = MC.CellWorldMin( bx, by, bz )
	local wall = MC.IsWallBannerState( stateId )
	local centerXY = Vector( base.x + bs * 0.5, base.y + bs * 0.5, 0 )
	if wall then centerXY = centerXY - normal * ( bs * 0.46 ) end
	local topZ = base.z + bs * ( wall and 20.5 / 24 or 44 / 24 )
	local phase = ( ( bx * 7 + by * 9 + bz * 13 ) % 100 + CurTime() * 20 ) / 100
	local angle = ( -0.0125 + 0.01 * math.cos( math.pi * 2 * phase ) ) * math.pi
	local down = Vector( 0, 0, -math.cos( angle ) ) + normal * math.sin( angle )
	return centerXY + Vector( 0, 0, topZ ), right, normal, up, down, wall
end

local function drawBody( topCenter, right, normal, up, wall, lightColor )
	local bs = MC.BS or 36.5
	render.SetMaterial( BANNER_BODY )
	mesh.Begin( MATERIAL_QUADS, wall and 6 or 12 )
	if not wall then
		emitBox(
			Vector( topCenter.x, topCenter.y, topCenter.z - bs * 23 / 24 ), right, normal, up,
			bs / 24, bs / 24, bs * 21 / 24,
			{ 44 / 64, 0, 52 / 64, 42 / 64 }, lightColor
		)
	end
	emitBox(
		topCenter + Vector( 0, 0, -bs / 24 ), right, normal, up,
		bs * 10 / 24, bs / 24, bs / 24,
		{ 0, 42 / 64, 44 / 64, 46 / 64 }, lightColor
	)
	mesh.End()
end

local function drawFlagLayer( material, topCenter, right, normal, down, color, order )
	local bs = MC.BS or 36.5
	local halfWidth = bs * 10 / 24
	local height = bs * 40 / 24
	local thickness = bs / 48
	local bias = math.max( 0, tonumber( order ) or 0 ) * 0.01
	local leftTop, rightTop = topCenter - right * halfWidth, topCenter + right * halfWidth
	local leftBottom, rightBottom = leftTop + down * height, rightTop + down * height
	local frontOffset = normal * ( thickness + bias )
	local backOffset = -normal * ( thickness + bias )
	render.SetMaterial( material )
	mesh.Begin( MATERIAL_QUADS, 2 )
	emitQuad( leftTop + frontOffset, rightTop + frontOffset, rightBottom + frontOffset, leftBottom + frontOffset,
		1 / 64, 1 / 64, 21 / 64, 41 / 64, color, normal )
	emitQuad( rightTop + backOffset, leftTop + backOffset, leftBottom + backOffset, rightBottom + backOffset,
		22 / 64, 1 / 64, 42 / 64, 41 / 64, color, -normal )
	mesh.End()
end

local function drawBanner( bx, by, bz, stateId, record )
	local baseName = MC.BannerBaseColorForState( stateId )
	local baseColor = baseName and MC.BannerColors[baseName]
	if not baseColor or not record.data then return end
	local center = MC.CellWorldCenter( bx, by, bz )
	local lightR, lightG, lightB = 1, 1, 1
	if MC.SampleDynamicLightingRGB then lightR, lightG, lightB = MC.SampleDynamicLightingRGB( center, 0 ) end
	local white = litColor( { r = 255, g = 255, b = 255 }, lightR, lightG, lightB )
	local topCenter, right, normal, up, down, wall = bannerBasis( bx, by, bz, stateId )
	drawBody( topCenter, right, normal, up, wall, white )
	drawFlagLayer( BANNER_BODY, topCenter, right, normal, down, white, 0 )
	drawFlagLayer( BANNER_MATERIALS["minecraft:base"], topCenter, right, normal, down,
		litColor( baseColor, lightR, lightG, lightB ), 1 )
	for index, layer in ipairs( record.data.patterns or {} ) do
		if index > ( MC.BannerMaxStoredPatterns or 16 ) then break end
		local material = BANNER_MATERIALS[layer.pattern]
		local dye = MC.BannerColors[layer.color]
		if material and dye then
			drawFlagLayer( material, topCenter, right, normal, down,
				litColor( dye, lightR, lightG, lightB ), index + 1 )
		end
	end
end

local BannerRenderEntries, BannerRenderCount = {}, 0
local BannerRenderRevision, BannerRenderGeneration = -1, -1
local BannerRenderDirty = true

function MC.MarkBannerRenderEntriesDirty()
	BannerRenderDirty = true
end

local function rebuildBannerRenderEntries()
	for index = 1, BannerRenderCount do BannerRenderEntries[index] = nil end
	BannerRenderCount = 0
	for _, chunk in pairs( MC.World or {} ) do
		for localIndex, record in pairs( chunk.blockEntities or {} ) do
			if record.type == "minecraft:banner" then
				local lx, ly, lz = MC.DecodeLocal( localIndex )
				BannerRenderCount = BannerRenderCount + 1
				BannerRenderEntries[BannerRenderCount] = {
					bx = chunk.cx * MC.CS + lx,
					by = chunk.cy * MC.CS + ly,
					bz = chunk.cz * MC.CH + lz,
					record = record,
				}
			end
		end
	end
	BannerRenderRevision = tonumber( MC.AppliedStateRevision ) or 0
	BannerRenderGeneration = tonumber( MC.StateWorldGeneration ) or 0
	BannerRenderDirty = false
end

hook.Add( "PostDrawTranslucentRenderables", "mc_banner_block_entities", function( _, _, bSky3D )
	if bSky3D then return end
	local revision = tonumber( MC.AppliedStateRevision ) or 0
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if BannerRenderDirty or revision ~= BannerRenderRevision or generation ~= BannerRenderGeneration then
		rebuildBannerRenderEntries()
	end
	local eye = EyePos()
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	for index = 1, BannerRenderCount do
		local entry = BannerRenderEntries[index]
		local center = MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
		if eye:DistToSqr( center ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = MC.GetBlockState( entry.bx, entry.by, entry.bz )
			if MC.IsBannerState( stateId ) then drawBanner( entry.bx, entry.by, entry.bz, stateId, entry.record ) end
		end
	end
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )
