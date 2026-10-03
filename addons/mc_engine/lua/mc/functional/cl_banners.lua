-- Client sparse Block Entity renderer for vanilla standing and wall banners.

MC = MC or {}

local Coords = MC.API.Coords
local MATERIAL_FLAGS = "alphatest vertexcolor vertexalpha noclamp nocull"
local BANNER_BODY = Material( "mc/entity/banner/banner_base.png", MATERIAL_FLAGS )
local BANNER_MATERIALS = {}
local POLE_UV = { 44 / 64, 0, 52 / 64, 42 / 64 }
local BAR_UV = { 0, 42 / 64, 44 / 64, 46 / 64 }
local WHITE = { r = 255, g = 255, b = 255 }
local LIT_COLOR = { r = 255, g = 255, b = 255, a = 255 }
local DEPTH_COLOR = { r = 255, g = 255, b = 255, a = 255 }
local EMPTY_PATTERNS = {}

-- Scratch vectors are copied by mesh.Position/Normal during template upload.
local ppp, ppn, pnp, pnn = Vector(), Vector(), Vector(), Vector()
local npp, npn, nnp, nnn = Vector(), Vector(), Vector(), Vector()
local inverse = Vector()
local basisTop, basisRight, basisNormal, basisDown = Vector(), Vector(), Vector(), Vector()
local UP, bodyCenter = Vector( 0, 0, 1 ), Vector()
local modelMatrix = Matrix()
local matrixPushed = false
local materialTint = Vector()
local colourMaterials = {}

local function setPoint( point, center, right, forward, up, x, y, z )
	point.x = center.x + right.x * x + forward.x * y + up.x * z
	point.y = center.y + right.y * x + forward.y * y + up.y * z
	point.z = center.z + right.z * x + forward.z * y + up.z * z
end

local function inverseNormal( normal )
	inverse.x, inverse.y, inverse.z = -normal.x, -normal.y, -normal.z
	return inverse
end

local function colourMaterial( source, name )
	-- IMesh:Draw ignores render.SetColorModulation. Keep tint on private
	-- materials so PNG materials shared with other renderers stay untouched.
	-- PNG imports have no VERTEXALPHA flag; adding it disables opaque Z writes.
	colourMaterials[source] = CreateMaterial( "mc_banner_retained2_" .. name, "UnlitGeneric", {
		["$basetexture"] = source:GetTexture( "$basetexture" ):GetName(),
		["$alphatest"] = 1, ["$vertexcolor"] = 1, ["$nocull"] = 1,
	} )
end
colourMaterial( BANNER_BODY, "body" )
for _, patternName in ipairs( MC.BannerPatternNames or {} ) do
	local pattern = MC.BannerPatternAssets[patternName]
	local material = Material( "mc/entity/banner/" .. pattern.asset .. ".png", MATERIAL_FLAGS )
	BANNER_MATERIALS[patternName] = material
	colourMaterial( material, pattern.asset )
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
	setPoint( ppp, center, right, forward, up, halfRight, halfForward, halfUp )
	setPoint( ppn, center, right, forward, up, halfRight, halfForward, -halfUp )
	setPoint( pnp, center, right, forward, up, halfRight, -halfForward, halfUp )
	setPoint( pnn, center, right, forward, up, halfRight, -halfForward, -halfUp )
	setPoint( npp, center, right, forward, up, -halfRight, halfForward, halfUp )
	setPoint( npn, center, right, forward, up, -halfRight, halfForward, -halfUp )
	setPoint( nnp, center, right, forward, up, -halfRight, -halfForward, halfUp )
	setPoint( nnn, center, right, forward, up, -halfRight, -halfForward, -halfUp )
	local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
	emitQuad( npp, ppp, ppn, npn, u0, v0, u1, v1, color, forward )
	emitQuad( pnp, nnp, nnn, pnn, u0, v0, u1, v1, color, inverseNormal( forward ) )
	emitQuad( ppp, pnp, pnn, ppn, u0, v0, u1, v1, color, right )
	emitQuad( nnp, npp, npn, nnn, u0, v0, u1, v1, color, inverseNormal( right ) )
	emitQuad( nnp, pnp, ppp, npp, u0, v0, u1, v1, color, up )
	emitQuad( npn, ppn, pnn, nnn, u0, v0, u1, v1, color, inverseNormal( up ) )
end

local function bannerYaw( stateId )
	if MC.IsWallBannerState( stateId ) then
		local facing = MC.GetStateProperty( stateId, "facing" )
		return facing == "south" and 0 or facing == "west" and 90 or facing == "north" and 180 or 270
	end
	return ( tonumber( MC.GetStateProperty( stateId, "rotation" ) ) or 0 ) * 22.5
end

local function litColor( source, lightR, lightG, lightB )
	LIT_COLOR.r = math.Clamp( math.floor( source.r * lightR + 0.5 ), 0, 255 )
	LIT_COLOR.g = math.Clamp( math.floor( source.g * lightG + 0.5 ), 0, 255 )
	LIT_COLOR.b = math.Clamp( math.floor( source.b * lightB + 0.5 ), 0, 255 )
	return LIT_COLOR
end

local function bannerBasis( bx, by, bz, stateId, bs, renderCenter )
	local yaw = bannerYaw( stateId )
	local radians = math.rad( yaw )
	local cosine, sine = math.cos( radians ), math.sin( radians )
	basisRight.x, basisRight.y, basisRight.z = cosine, sine, 0
	basisNormal.x, basisNormal.y, basisNormal.z = -sine, cosine, 0
	local wall = MC.IsWallBannerState( stateId )
	local wallOffset = wall and bs * 0.46 or 0
	basisTop.x = renderCenter.x - basisNormal.x * wallOffset
	basisTop.y = renderCenter.y - basisNormal.y * wallOffset
	basisTop.z = renderCenter.z - bs * 0.5 + bs * ( wall and 20.5 / 24 or 44 / 24 )
	local phase = ( ( bx * 7 + by * 9 + bz * 13 ) % 100 + CurTime() * 20 ) / 100
	local angle = ( -0.0125 + 0.01 * math.cos( math.pi * 2 * phase ) ) * math.pi
	local sway = math.sin( angle )
	basisDown.x, basisDown.y, basisDown.z = basisNormal.x * sway, basisNormal.y * sway, -math.cos( angle )
	return basisTop, basisRight, basisNormal, UP, basisDown, wall
end

local function buildBody( object, wall )
	local right, normal = Vector( 1, 0, 0 ), Vector( 0, 1, 0 )
	mesh.Begin( object, MATERIAL_QUADS, wall and 6 or 12 )
	if not wall then
		bodyCenter.z = -23 / 24
		emitBox(
			bodyCenter, right, normal, UP,
			1 / 24, 1 / 24, 21 / 24,
			POLE_UV, DEPTH_COLOR
		)
	end
	bodyCenter.z = -1 / 24
	emitBox(
		bodyCenter, right, normal, UP,
		10 / 24, 1 / 24, 1 / 24,
		BAR_UV, DEPTH_COLOR
	)
	mesh.End()
end

local function buildFlag( object )
	local top, right, normal, down = Vector(), Vector( 1, 0, 0 ), Vector( 0, 1, 0 ), UP
	local halfWidth, height = 10 / 24, 40 / 24
	mesh.Begin( object, MATERIAL_QUADS, 2 )
	setPoint( ppp, top, right, normal, down, -halfWidth, 1, 0 )
	setPoint( ppn, top, right, normal, down, halfWidth, 1, 0 )
	setPoint( pnp, top, right, normal, down, halfWidth, 1, height )
	setPoint( pnn, top, right, normal, down, -halfWidth, 1, height )
	emitQuad( ppp, ppn, pnp, pnn,
		1 / 64, 1 / 64, 21 / 64, 41 / 64, DEPTH_COLOR, normal )
	setPoint( ppp, top, right, normal, down, halfWidth, -1, 0 )
	setPoint( ppn, top, right, normal, down, -halfWidth, -1, 0 )
	setPoint( pnp, top, right, normal, down, -halfWidth, -1, height )
	setPoint( pnn, top, right, normal, down, halfWidth, -1, height )
	emitQuad( ppp, ppn, pnp, pnn,
		22 / 64, 1 / 64, 42 / 64, 41 / 64, DEPTH_COLOR, inverseNormal( normal ) )
	mesh.End()
end

local function releaseMeshes()
	for _, object in pairs( MC.BannerRenderMeshes or {} ) do object:Destroy() end
	MC.BannerRenderMeshes = nil
end
releaseMeshes()
hook.Add( "ShutDown", "mc_banner_meshes", releaseMeshes )

local bannerMeshes
local function buildMeshes( objects )
	buildBody( objects.standing, false )
	buildBody( objects.wall, true )
	buildFlag( objects.flag )
end

local function ensureMeshes()
	if bannerMeshes then return end
	local objects = { standing = Mesh( BANNER_BODY ), wall = Mesh( BANNER_BODY ), flag = Mesh( BANNER_BODY ) }
	MC.BannerRenderMeshes = objects
	local ok, err = pcall( buildMeshes, objects )
	if not ok then releaseMeshes() error( err, 0 ) end
	bannerMeshes = objects
end

local function setBasis( top, right, normal, up, bs, thickness )
	modelMatrix:SetField( 1, 1, right.x * bs )
	modelMatrix:SetField( 2, 1, right.y * bs )
	modelMatrix:SetField( 3, 1, right.z * bs )
	modelMatrix:SetField( 1, 2, normal.x * thickness )
	modelMatrix:SetField( 2, 2, normal.y * thickness )
	modelMatrix:SetField( 3, 2, normal.z * thickness )
	modelMatrix:SetField( 1, 3, up.x * bs )
	modelMatrix:SetField( 2, 3, up.y * bs )
	modelMatrix:SetField( 3, 3, up.z * bs )
	modelMatrix:SetTranslation( top )
end

local function drawMesh( object, material, color )
	local tinted = colourMaterials[material]
	if tinted then
		materialTint.x, materialTint.y, materialTint.z = color.r / 255, color.g / 255, color.b / 255
		tinted:SetVector( "$color", materialTint )
		render.SetMaterial( tinted )
	else
		render.SetMaterial( material )
	end
	cam.PushModelMatrix( modelMatrix )
	matrixPushed = true
	object:Draw()
	cam.PopModelMatrix()
	matrixPushed = false
end

local function drawBody( topCenter, right, normal, up, wall, lightColor, bs, depthMaterial )
	setBasis( topCenter, right, normal, up, bs, bs )
	drawMesh( wall and bannerMeshes.wall or bannerMeshes.standing, depthMaterial or BANNER_BODY, lightColor )
end

local function drawFlagLayer( material, topCenter, right, normal, down, color, order, bs )
	-- Keep the original Source-unit layer separation while scaling the cloth
	-- in block units. Sway and re-origining only change this draw's matrix.
	setBasis( topCenter, right, normal, down, bs, bs / 48 + order * 0.01 )
	drawMesh( bannerMeshes.flag, material, color )
end

local function drawBanner( bx, by, bz, stateId, record, bs, renderCenter )
	local baseName = MC.BannerBaseColorForState( stateId )
	local baseColor = baseName and MC.BannerColors[baseName]
	if not baseColor or not record.data then return end
	local center = Coords.CellCenter( bx, by, bz )
	local lightR, lightG, lightB = 1, 1, 1
	if MC.SampleDynamicLightingRGB then lightR, lightG, lightB = MC.SampleDynamicLightingRGB( center, 0 ) end
	local white = litColor( WHITE, lightR, lightG, lightB )
	local topCenter, right, normal, up, down, wall = bannerBasis( bx, by, bz, stateId, bs, renderCenter )
	drawBody( topCenter, right, normal, up, wall, white, bs )
	drawFlagLayer( BANNER_BODY, topCenter, right, normal, down, white, 0, bs )
	drawFlagLayer( BANNER_MATERIALS["minecraft:base"], topCenter, right, normal, down,
		litColor( baseColor, lightR, lightG, lightB ), 1, bs )
	for index, layer in ipairs( record.data.patterns or EMPTY_PATTERNS ) do
		if index > ( MC.BannerMaxStoredPatterns or 16 ) then break end
		local material = BANNER_MATERIALS[layer.pattern]
		local dye = MC.BannerColors[layer.color]
		if material and dye then
			drawFlagLayer( material, topCenter, right, normal, down,
				litColor( dye, lightR, lightG, lightB ), index + 1, bs )
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

local function drawBannerEntries( eye, bs, maxDistanceSqr, drawingDepth )
	ensureMeshes()
	local depthMaterial
	if drawingDepth then depthMaterial = MC.RenderPBRSSR.DepthMaterial( BANNER_BODY, true ) end
	for index = 1, BannerRenderCount do
		local entry = BannerRenderEntries[index]
		local center = Coords.CellRenderCenter( entry.bx, entry.by, entry.bz )
		if eye:DistToSqr( center ) <= maxDistanceSqr then
			local stateId = MC.GetBlockState( entry.bx, entry.by, entry.bz )
			if MC.IsBannerState( stateId ) then
				if drawingDepth then
					local top, right, normal, up, down, wall = bannerBasis( entry.bx, entry.by, entry.bz, stateId, bs, center )
					drawBody( top, right, normal, up, wall, DEPTH_COLOR, bs, depthMaterial )
					-- Pattern layers share the cloth coverage; one base layer is
					-- sufficient for depth and avoids repeating all decorations.
					drawFlagLayer( depthMaterial, top, right, normal, down, DEPTH_COLOR, 0, bs )
				else drawBanner( entry.bx, entry.by, entry.bz, stateId, entry.record, bs, center ) end
			end
		end
	end
end

-- Cloth/patterns use alpha testing, not blending. Their solid pixels belong
-- in the opaque depth buffer before transparent terrain and animated water.
hook.Remove( "PostDrawTranslucentRenderables", "mc_banner_block_entities" )
local function drawBanners( drawingDepth, eye )
	if drawingDepth and ( not MC.RenderPBRSSR or not MC.RenderPBRSSR.BeginDepth() ) then return end
	if MC.WorldFrameSettled and not MC.WorldFrameSettled() then return end
	if MC.RenderPBRShadows and MC.RenderPBRShadows.rendering then return end
	local revision = tonumber( MC.AppliedStateRevision ) or 0
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if BannerRenderDirty or revision ~= BannerRenderRevision or generation ~= BannerRenderGeneration then
		rebuildBannerRenderEntries()
	end
	eye = eye or EyePos()
	local bs = Coords.BlockSize()
	local maxDistanceSqr = ( bs * 64 ) ^ 2
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	local ok, err = pcall( drawBannerEntries, eye, bs, maxDistanceSqr, drawingDepth )
	if matrixPushed then cam.PopModelMatrix() matrixPushed = false end
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
	if not ok then
		if drawingDepth then error( { code = "render_banner_draw", message = tostring( err ) }, 0 ) end
		MC.Fault( "render_banner_draw", "%s", tostring( err ) )
	end
end
hook.Add( "PostDrawOpaqueRenderables", "mc_banner_block_entities", function( drawingDepth, _, bSky3D )
	if drawingDepth or bSky3D then return end
	drawBanners( false )
end )
MC.RenderPBRSSR.RegisterDepthRenderer( "banners", function( view )
	drawBanners( true, view.origin )
end )
