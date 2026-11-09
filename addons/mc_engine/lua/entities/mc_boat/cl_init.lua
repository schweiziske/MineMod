include( "shared.lua" )

local MATERIAL_FLAGS = "alphatest vertexcolor vertexalpha noclamp nocull"
local MATERIALS = {}
local TWO_PI = math.pi * 2
local PADDLE_SPEED = math.pi / 8
local TICKS_PER_SECOND = 20

local BOAT_BODY = {
	{ -14, -9, -3, 28, 16, 3, 0, 0, 0, 3, 1, math.pi / 2, 0, 0 },
	{ -13, -7, -1, 18, 6, 2, 0, 19, -15, 4, 4, 0, math.pi * 1.5, 0 },
	{ -8, -7, -1, 16, 6, 2, 0, 27, 15, 4, 0, 0, math.pi / 2, 0 },
	{ -14, -7, -1, 28, 6, 2, 0, 35, 0, 4, -9, 0, math.pi, 0 },
	{ -14, -7, -1, 28, 6, 2, 0, 43, 0, 4, 9, 0, 0, 0 },
}

local RAFT_BODY = {
	{ -14, -11, -4, 28, 20, 4, 0, 0, 0, -2.1, 1, 1.5708, 0, 0 },
	{ -14, -9, -8, 28, 16, 4, 0, 0, 0, -2.1, 1, 1.5708, 0, 0 },
}

local function materialFor( boatType )
	boatType = boatType ~= "" and boatType or "oak"
	if not MATERIALS[boatType] then MATERIALS[boatType] = Material( "mc/entity/boat/" .. boatType .. ".png", MATERIAL_FLAGS ) end
	return MATERIALS[boatType]
end

local function rotateX( vector, angle )
	local c, s = math.cos( angle ), math.sin( angle )
	return Vector( vector.x, vector.y * c - vector.z * s, vector.y * s + vector.z * c )
end

local function rotateY( vector, angle )
	local c, s = math.cos( angle ), math.sin( angle )
	return Vector( vector.x * c + vector.z * s, vector.y, -vector.x * s + vector.z * c )
end

local function rotateZ( vector, angle )
	local c, s = math.cos( angle ), math.sin( angle )
	return Vector( vector.x * c - vector.y * s, vector.x * s + vector.y * c, vector.z )
end

local function transform( point, part, rootScale )
	local value = Vector( point.x / 16, point.y / 16, point.z / 16 )
	-- Cube data stores PartPose offset in [9..11] and rotation in [12..14].
	-- Keeping these indices aligned with Java is essential: shifting them by one
	-- turns the pose's X rotation into a Z offset and scatters every hull panel.
	value = rotateX( value, part[12] or 0 )
	value = rotateY( value, part[13] or 0 )
	value = rotateZ( value, part[14] or 0 )
	value = value + Vector( ( part[9] or 0 ) / 16, ( part[10] or 0 ) / 16, ( part[11] or 0 ) / 16 )
	-- AbstractBoatRenderer applies Y(180-yaw), scale(-1,-1,1), then Y(90).
	-- Source yaw zero faces +X while Java yaw -90 faces +X, so the equivalent
	-- entity-local frame is Java +X -> Source +X and Java +Z -> Source -Y.
	return Vector( value.x, -value.z, -value.y ) * rootScale
end

local function emitVertex( position, u, v, color, normal )
	mesh.Position( position )
	if mesh.Normal then mesh.Normal( normal ) end
	mesh.Color( color.r, color.g, color.b, color.a )
	mesh.TexCoord( 0, u, v )
	mesh.AdvanceVertex()
end

local function emitQuad( a, b, c, d, u0, v0, u1, v1, color )
	local normal = ( b - a ):Cross( d - a ):GetNormalized()
	emitVertex( a, u1, v0, color, normal )
	emitVertex( b, u0, v0, color, normal )
	emitVertex( c, u0, v1, color, normal )
	emitVertex( d, u1, v1, color, normal )
end

local function drawCube( part, color, textureWidth, textureHeight, rootScale )
	local x, y, z, width, height, depth = part[1], part[2], part[3], part[4], part[5], part[6]
	local u, v = part[7], part[8]
	local t0 = transform( Vector( x, y, z ), part, rootScale )
	local t1 = transform( Vector( x + width, y, z ), part, rootScale )
	local t2 = transform( Vector( x + width, y + height, z ), part, rootScale )
	local t3 = transform( Vector( x, y + height, z ), part, rootScale )
	local l0 = transform( Vector( x, y, z + depth ), part, rootScale )
	local l1 = transform( Vector( x + width, y, z + depth ), part, rootScale )
	local l2 = transform( Vector( x + width, y + height, z + depth ), part, rootScale )
	local l3 = transform( Vector( x, y + height, z + depth ), part, rootScale )
	local u0, u1, u2 = u, u + depth, u + depth + width
	local u22, u3, u4 = u2 + width, u + depth + width + depth, u + depth + width + depth + width
	local v0, v1, v2 = v, v + depth, v + depth + height
	local tw, th = textureWidth, textureHeight
	emitQuad( l1, l0, t0, t1, u1 / tw, v0 / th, u2 / tw, v1 / th, color )
	emitQuad( t2, t3, l3, l2, u2 / tw, v0 / th, u22 / tw, v1 / th, color )
	emitQuad( t0, l0, l3, t3, u0 / tw, v1 / th, u1 / tw, v2 / th, color )
	emitQuad( t1, t0, t3, t2, u1 / tw, v1 / th, u2 / tw, v2 / th, color )
	emitQuad( l1, t1, t2, l2, u2 / tw, v1 / th, u3 / tw, v2 / th, color )
	emitQuad( l0, l1, l2, l3, u3 / tw, v1 / th, u4 / tw, v2 / th, color )
end

local function paddlePart( raft, side, phase )
	local time = phase or 0
	local xRot = Lerp( ( math.sin( -time ) + 1 ) * 0.5, -math.pi / 3, -math.pi / 12 )
	local yRot = Lerp( ( math.sin( -time + 1 ) + 1 ) * 0.5, -math.pi / 4, math.pi / 4 )
	if side == 2 then yRot = math.pi - yRot end
	local texU = raft and ( side == 1 and 0 or 40 ) or 62
	local texV = raft and 24 or ( side == 1 and 0 or 20 )
	local pivotZ = side == 1 and 9 or -9
	local pivotY = raft and -4 or -5
	return {
		{ -1, 0, -5, 2, 2, 18, texU, texV, 3, pivotY, pivotZ, xRot, yRot, math.pi / 16 },
		{ side == 1 and -1.001 or 0.001, -3, 8, 1, 6, 7, texU, texV, 3, pivotY, pivotZ, xRot, yRot, math.pi / 16 },
	}
end

local function lightingColor( entity )
	local current = CurTime()
	if not entity.MCNextLightSample or current >= entity.MCNextLightSample then
		entity.MCNextLightSample = current + 0.1
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( entity:GetPos(), 0 ) end
		local legacyGain = 0.48 -- [BMB 2026-11-09] unit gain under unit tonemap
		if MC.EntityExposureGain then legacyGain = MC.EntityExposureGain( legacyGain ) end
		if MC.ScaleDynamicLightingRGB then r, g, b = MC.ScaleDynamicLightingRGB( r, g, b, legacyGain ) else r, g, b = r * legacyGain, g * legacyGain, b * legacyGain end
		entity.MCBoatColor = Color( math.floor( math.Clamp( r * 255, 0, 255 ) + 0.5 ),
			math.floor( math.Clamp( g * 255, 0, 255 ) + 0.5 ), math.floor( math.Clamp( b * 255, 0, 255 ) + 0.5 ), 255 )
	end
	return entity.MCBoatColor or color_white
end

local function hurtRoll( entity )
	local remaining = math.max( 0, entity:GetHurtUntil() - CurTime() ) * 20
	if remaining <= 0 then return 0 end
	return math.sin( remaining ) * remaining * math.max( 0, entity:GetVehicleDamage() ) / 10
		* entity:GetHurtDirection()
end

local function interpolatedPaddlePhase( entity, side )
	local phase = side == 1 and entity:GetPaddlePhaseLeft() or entity:GetPaddlePhaseRight()
	local active = side == 1 and entity:GetPaddleLeft() or entity:GetPaddleRight()
	local phaseKey = side == 1 and "MCLastPaddlePhaseLeft" or "MCLastPaddlePhaseRight"
	local timeKey = side == 1 and "MCLastPaddlePhaseTimeLeft" or "MCLastPaddlePhaseTimeRight"
	if entity[phaseKey] ~= phase then
		entity[phaseKey] = phase
		entity[timeKey] = CurTime()
	end
	if not active then return 0 end
	local fraction = math.Clamp( ( CurTime() - ( entity[timeKey] or CurTime() ) ) * TICKS_PER_SECOND, 0, 1 )
	return phase - PADDLE_SPEED + PADDLE_SPEED * fraction
end

function ENT:Initialize()
	local scale = ( tonumber( MC and MC.BS ) or 36.5 ) * 1.0
	self:SetRenderBounds( Vector( -scale, -scale, -scale * 0.5 ), Vector( scale, scale, scale ) )
end

function ENT:Draw()
	local raft = self:GetRaft()
	local material = materialFor( self:GetBoatType() )
	local color = lightingColor( self )
	local scale = tonumber( MC and MC.BS ) or 36.5
	local matrix = Matrix()
	matrix:SetTranslation( self:GetPos() + Vector( 0, 0, scale * 0.375 ) )
	local angles = self:GetAngles()
	matrix:SetAngles( Angle( angles.p, angles.y, hurtRoll( self ) ) )
	cam.PushModelMatrix( matrix, true )
	render.SetMaterial( material )
	local body = raft and RAFT_BODY or BOAT_BODY
	local left = paddlePart( raft, 1, interpolatedPaddlePhase( self, 1 ) % TWO_PI )
	local right = paddlePart( raft, 2, interpolatedPaddlePhase( self, 2 ) % TWO_PI )
	if MC.BeginEntityUnitExposure then MC.BeginEntityUnitExposure() end -- [BMB 2026-11-09]
	mesh.Begin( MATERIAL_QUADS, ( #body + #left + #right ) * 6 )
	for _, part in ipairs( body ) do drawCube( part, color, 128, 64, scale ) end
	for _, part in ipairs( left ) do drawCube( part, color, 128, 64, scale ) end
	for _, part in ipairs( right ) do drawCube( part, color, 128, 64, scale ) end
	mesh.End()
	if MC.EndEntityUnitExposure then MC.EndEntityUnitExposure() end
	cam.PopModelMatrix()
end
