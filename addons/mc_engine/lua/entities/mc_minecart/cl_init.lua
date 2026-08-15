include( "shared.lua" )

local MATERIAL_FLAGS = "alphatest vertexcolor vertexalpha noclamp nocull"
local MINECART_MATERIAL = Material( "mc/entity/minecart/minecart.png", MATERIAL_FLAGS )

local PARTS = {
	{ -10, -8, -1, 20, 16, 2, 0, 10, 0, 4, 0, math.pi / 2, 0, 0 },
	{ -8, -9, -1, 16, 8, 2, 0, 0, -9, 4, 0, 0, math.pi * 1.5, 0 },
	{ -8, -9, -1, 16, 8, 2, 0, 0, 9, 4, 0, 0, math.pi / 2, 0 },
	{ -8, -9, -1, 16, 8, 2, 0, 0, 0, 4, -7, 0, math.pi, 0 },
	{ -8, -9, -1, 16, 8, 2, 0, 0, 0, 4, 7, 0, 0, 0 },
}

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

local function transform( point, part, scale )
	local value = Vector( point.x / 16, point.y / 16, point.z / 16 )
	-- Cube data stores PartPose offset in [9..11] and rotation in [12..14].
	value = rotateX( value, part[12] or 0 )
	value = rotateY( value, part[13] or 0 )
	value = rotateZ( value, part[14] or 0 )
	value = value + Vector( ( part[9] or 0 ) / 16, ( part[10] or 0 ) / 16, ( part[11] or 0 ) / 16 )
	-- Old minecart rendering applies Y(180-railYaw) then scale(-1,-1,1).
	-- Java model -X is its front; map it to Source +X at yaw zero. Java +Z
	-- maps to Source +Y, while model +Y is down in both authored models.
	return Vector( -value.x, value.z, -value.y ) * scale
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

local function drawCube( part, color, scale )
	local x, y, z, width, height, depth = part[1], part[2], part[3], part[4], part[5], part[6]
	local u, v = part[7], part[8]
	local t0 = transform( Vector( x, y, z ), part, scale )
	local t1 = transform( Vector( x + width, y, z ), part, scale )
	local t2 = transform( Vector( x + width, y + height, z ), part, scale )
	local t3 = transform( Vector( x, y + height, z ), part, scale )
	local l0 = transform( Vector( x, y, z + depth ), part, scale )
	local l1 = transform( Vector( x + width, y, z + depth ), part, scale )
	local l2 = transform( Vector( x + width, y + height, z + depth ), part, scale )
	local l3 = transform( Vector( x, y + height, z + depth ), part, scale )
	local u0, u1, u2 = u, u + depth, u + depth + width
	local u22, u3, u4 = u2 + width, u + depth + width + depth, u + depth + width + depth + width
	local v0, v1, v2 = v, v + depth, v + depth + height
	emitQuad( l1, l0, t0, t1, u1 / 64, v0 / 32, u2 / 64, v1 / 32, color )
	emitQuad( t2, t3, l3, l2, u2 / 64, v0 / 32, u22 / 64, v1 / 32, color )
	emitQuad( t0, l0, l3, t3, u0 / 64, v1 / 32, u1 / 64, v2 / 32, color )
	emitQuad( t1, t0, t3, t2, u1 / 64, v1 / 32, u2 / 64, v2 / 32, color )
	emitQuad( l1, t1, t2, l2, u2 / 64, v1 / 32, u3 / 64, v2 / 32, color )
	emitQuad( l0, l1, l2, l3, u3 / 64, v1 / 32, u4 / 64, v2 / 32, color )
end

local function lightingColor( entity )
	local current = CurTime()
	if not entity.MCNextLightSample or current >= entity.MCNextLightSample then
		entity.MCNextLightSample = current + 0.1
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( entity:GetPos(), 0 ) end
		if MC.ScaleDynamicLightingRGB then r, g, b = MC.ScaleDynamicLightingRGB( r, g, b, 0.48 ) else r, g, b = r * 0.48, g * 0.48, b * 0.48 end
		entity.MCMinecartColor = Color( math.floor( math.Clamp( r * 255, 0, 255 ) + 0.5 ),
			math.floor( math.Clamp( g * 255, 0, 255 ) + 0.5 ), math.floor( math.Clamp( b * 255, 0, 255 ) + 0.5 ), 255 )
	end
	return entity.MCMinecartColor or color_white
end

local function eventSound( eventName )
	local candidate = MC.SelectJavaSoundEvent and MC.SelectJavaSoundEvent( eventName ) or nil
	return candidate and candidate.sound or nil
end

local function ensureSoundPatchPlaying( patch, volume, pitch )
	if patch and patch.IsPlaying and not patch:IsPlaying() then
		patch:PlayEx( volume or 0, pitch or 100 )
	end
end

local function hurtRoll( entity )
	local remaining = math.max( 0, entity:GetHurtUntil() - CurTime() ) * 20
	if remaining <= 0 then return 0 end
	return math.sin( remaining ) * remaining * math.max( 0, entity:GetVehicleDamage() ) / 10
		* entity:GetHurtDirection()
end

function ENT:Initialize()
	local scale = tonumber( MC and MC.BS ) or 36.5
	self:SetRenderBounds( Vector( -scale, -scale, -scale * 0.6 ), Vector( scale, scale, scale ) )
	local exterior = eventSound( "entity.minecart.riding" )
	if exterior then self.MCExteriorSound = CreateSound( self, exterior ) self.MCExteriorSound:PlayEx( 0, 50 ) end
	self.MCExteriorPitch = 0
	self.MCSmoothedMotionSpeed = 0
	self.MCLastSoundUpdate = CurTime()
end

function ENT:UpdateMinecartSounds()
	local current = CurTime()
	local elapsed = math.Clamp( current - ( self.MCLastSoundUpdate or current ), 0, 0.25 )
	self.MCLastSoundUpdate = current
	local targetSpeed = self.GetMotionSpeed and math.max( 0, self:GetMotionSpeed() )
		or self:GetVelocity():Length2D() / math.max( 1, ( tonumber( MC and MC.BS ) or 36.5 ) * 20 )
	local blend = 1 - math.exp( -elapsed * 20 )
	self.MCSmoothedMotionSpeed = Lerp( blend, self.MCSmoothedMotionSpeed or targetSpeed, targetSpeed )
	local speed = self.MCSmoothedMotionSpeed
	local volume = speed >= 0.01 and Lerp( math.Clamp( speed, 0, 0.5 ), 0, 0.7 ) or 0
	if speed >= 0.01 then
		self.MCExteriorPitch = math.Clamp( ( self.MCExteriorPitch or 0 ) + 0.0025 * elapsed * 20, 0, 1 )
	else
		self.MCExteriorPitch = 0
	end
	if self.MCExteriorSound then
		ensureSoundPatchPlaying( self.MCExteriorSound, volume, math.Clamp( math.floor( self.MCExteriorPitch * 100 + 0.5 ), 50, 100 ) )
		self.MCExteriorSound:ChangeVolume( volume, 0.05 )
		-- SoundEngine clamps every instance pitch to [0.5, 2.0].
		self.MCExteriorSound:ChangePitch( math.Clamp( math.floor( self.MCExteriorPitch * 100 + 0.5 ), 50, 100 ), 0.05 )
	end
	local player = LocalPlayer()
	local seat = self:GetVehicleSeat()
	local riding = IsValid( player ) and IsValid( seat ) and player:InVehicle() and player:GetVehicle() == seat
	if riding then
		local eyeLiquid = MC.PlayerEyeLiquid and MC.PlayerEyeLiquid( player ) or nil
		local underwater = eyeLiquid and eyeLiquid.kind == "water"
			or ( player.WaterLevel and player:WaterLevel() >= 3 ) or false
		if not self.MCInsideSound then
			local path = eventSound( "entity.minecart.inside" )
			self.MCInsideSound = path and CreateSound( player, path ) or nil
			if self.MCInsideSound then self.MCInsideSound:PlayEx( 0, 100 ) end
		end
		if not self.MCInsideUnderwaterSound then
			local path = eventSound( "entity.minecart.inside.underwater" )
			self.MCInsideUnderwaterSound = path and CreateSound( player, path ) or nil
			if self.MCInsideUnderwaterSound then self.MCInsideUnderwaterSound:PlayEx( 0, 100 ) end
		end
		local insideVolume = speed >= 0.01 and 0.75 * math.Clamp( speed, 0, 1 ) or 0
		if self.MCInsideSound then
			ensureSoundPatchPlaying( self.MCInsideSound, underwater and 0 or insideVolume, 100 )
			self.MCInsideSound:ChangeVolume( underwater and 0 or insideVolume, 0.05 )
		end
		if self.MCInsideUnderwaterSound then
			ensureSoundPatchPlaying( self.MCInsideUnderwaterSound, underwater and insideVolume or 0, 100 )
			self.MCInsideUnderwaterSound:ChangeVolume( underwater and insideVolume or 0, 0.05 )
		end
	else
		if self.MCInsideSound then self.MCInsideSound:Stop() self.MCInsideSound = nil end
		if self.MCInsideUnderwaterSound then self.MCInsideUnderwaterSound:Stop() self.MCInsideUnderwaterSound = nil end
	end
end

function ENT:Think()
	self:UpdateMinecartSounds()
	self:SetNextClientThink( CurTime() )
	return true
end

function ENT:Draw()
	local scale = tonumber( MC and MC.BS ) or 36.5
	local matrix = Matrix()
	matrix:SetTranslation( self:GetPos() + Vector( 0, 0, scale * 0.375 ) )
	matrix:SetAngles( Angle( self:GetRailPitch(), self:GetAngles().y, hurtRoll( self ) ) )
	cam.PushModelMatrix( matrix, true )
	render.SetMaterial( MINECART_MATERIAL )
	mesh.Begin( MATERIAL_QUADS, #PARTS * 6 )
	local color = lightingColor( self )
	for _, part in ipairs( PARTS ) do drawCube( part, color, scale ) end
	mesh.End()
	cam.PopModelMatrix()
end

function ENT:OnRemove()
	if self.MCExteriorSound then self.MCExteriorSound:Stop() end
	if self.MCInsideSound then self.MCInsideSound:Stop() end
	if self.MCInsideUnderwaterSound then self.MCInsideUnderwaterSound:Stop() end
end
