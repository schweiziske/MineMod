include( "shared.lua" )

local TICKS_PER_SECOND = 20
local SMOKE_FRAMES = {
	"generic_7", "generic_6", "generic_5", "generic_4",
	"generic_3", "generic_2", "generic_1", "generic_0",
}
local SMOKE_MATERIALS = {}

local function blockSize()
	return math.max( 1, tonumber( MC and MC.BS ) or 36.5 )
end

local function smokeMaterial( index )
	index = math.Clamp( math.floor( tonumber( index ) or 1 ), 1, #SMOKE_FRAMES )
	local cached = SMOKE_MATERIALS[index]
	if cached then return cached end
	cached = Material( "mc/particle/" .. SMOKE_FRAMES[index] .. ".png", "noclamp vertexcolor vertexalpha" )
	SMOKE_MATERIALS[index] = cached
	return cached
end

local function worldLightingColor( entity, position )
	local current = CurTime()
	if not entity.MCNextLightSample or current >= entity.MCNextLightSample then
		entity.MCNextLightSample = current + 0.1
		local r, g, b = 1, 1, 1
		if MC.SampleDynamicLightingRGB then r, g, b = MC.SampleDynamicLightingRGB( position, 0 ) end
		if MC.ScaleDynamicLightingRGB then r, g, b = MC.ScaleDynamicLightingRGB( r, g, b, 0.48 )
		else r, g, b = r * 0.48, g * 0.48, b * 0.48 end
		entity.MCTntColor = Color(
			math.floor( math.Clamp( r, 0, 1 ) * 255 + 0.5 ),
			math.floor( math.Clamp( g, 0, 1 ) * 255 + 0.5 ),
			math.floor( math.Clamp( b, 0, 1 ) * 255 + 0.5 ), 255
		)
	end
	return entity.MCTntColor or color_white
end

local function constructorVelocity()
	local velocity = Vector( math.Rand( -0.4, 0.4 ), math.Rand( -0.4, 0.4 ), math.Rand( -0.4, 0.4 ) )
	local speed = ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) + 1 ) * 0.15
	if velocity:LengthSqr() > 0.000001 then velocity:Normalize() else velocity = Vector( 0, 0, 1 ) end
	velocity = velocity * speed * 0.4
	velocity.z = velocity.z + 0.1
	return velocity * 0.1
end

local function spawnSmoke( entity )
	local size = blockSize()
	local position = entity:GetPos() + Vector( 0, 0, size * 0.5 )
	local emitter = ParticleEmitter( position )
	if not emitter then return end
	local particle = emitter:Add( smokeMaterial( 1 ), position )
	if particle then
		local lifetimeTicks = math.max( 1, math.floor( 8 / ( math.Rand( 0, 1 ) * 0.8 + 0.2 ) ) )
		local quadSize = ( 0.1 * ( math.Rand( 0, 1 ) * 0.5 + 0.5 ) * 2 ) * 0.75
		local velocity = constructorVelocity()
		local simulatedVelocity = velocity * size * TICKS_PER_SECOND
		local nextTick = 0
		particle:SetDieTime( lifetimeTicks / TICKS_PER_SECOND )
		particle:SetStartAlpha( 255 )
		particle:SetEndAlpha( 255 )
		particle:SetStartSize( 0.01 )
		particle:SetEndSize( quadSize * size )
		particle:SetVelocity( simulatedVelocity )
		particle:SetGravity( vector_origin )
		particle:SetAirResistance( 0 )
		particle:SetCollide( true )
		particle:SetBounce( 0 )
		particle:SetLighting( false )
		local grey = math.floor( math.Rand( 0, 0.3 ) * 255 + 0.5 )
		particle:SetColor( grey, grey, grey )
		particle:SetNextThink( CurTime() )
		particle:SetThinkFunction( function( current )
			local ageTicks = current:GetLifeTime() * TICKS_PER_SECOND
			while ageTicks + 0.0001 >= nextTick do
				simulatedVelocity.z = simulatedVelocity.z + 0.004 * size * TICKS_PER_SECOND
				simulatedVelocity = simulatedVelocity * 0.96
				nextTick = nextTick + 1
			end
			current:SetVelocity( simulatedVelocity )
			local frame = math.Clamp( math.floor( ageTicks * ( #SMOKE_FRAMES - 1 ) / lifetimeTicks ) + 1,
				1, #SMOKE_FRAMES )
			current:SetMaterial( smokeMaterial( frame ) )
			local currentSize = quadSize * math.Clamp( ageTicks / lifetimeTicks * 32, 0, 1 ) * size
			current:SetStartSize( currentSize )
			current:SetEndSize( currentSize )
			current:SetNextThink( CurTime() )
		end )
	end
	emitter:Finish()
end

local function interpolatedFuse( entity )
	local fuse = entity:GetFuseTicks()
	if entity.MCLastNetworkFuse ~= fuse then
		entity.MCLastNetworkFuse = fuse
		entity.MCFuseUpdatedAt = CurTime()
	end
	local partialTicks = math.Clamp( ( CurTime() - ( entity.MCFuseUpdatedAt or CurTime() ) ) * TICKS_PER_SECOND, 0, 1 )
	return math.max( 0, fuse - partialTicks + 1 )
end

local function drawWhiteOverlay( position, size )
	local half = size * 0.501
	local blended = render.OverrideBlend and BLEND_SRC_ALPHA ~= nil and BLEND_ONE ~= nil and BLENDFUNC_ADD ~= nil
	if blended then render.OverrideBlend( true, BLEND_SRC_ALPHA, BLEND_ONE, BLENDFUNC_ADD ) end
	render.SetColorMaterial()
	render.DrawBox( position, angle_zero, Vector( -half, -half, -half ), Vector( half, half, half ),
		Color( 255, 255, 255, 210 ), true )
	if blended then render.OverrideBlend( false ) end
	render.SetBlend( 1 )
	render.SetColorModulation( 1, 1, 1 )
end

function ENT:Initialize()
	local size = blockSize()
	self:SetRenderBounds( Vector( -size, -size, -size ), Vector( size, size, size * 2 ) )
	self.MCNextSmoke = CurTime()
	self.MCLastNetworkFuse = self:GetFuseTicks()
	self.MCFuseUpdatedAt = CurTime()
end

function ENT:Think()
	if not self:GetArmed() then self:SetNextClientThink( CurTime() + 0.05 ) return true end
	local current = CurTime()
	while current >= ( self.MCNextSmoke or current ) do
		self.MCNextSmoke = ( self.MCNextSmoke or current ) + 1 / TICKS_PER_SECOND
		spawnSmoke( self )
	end
	self:SetNextClientThink( current )
	return true
end

function ENT:Draw()
	if not self:GetArmed() then return end
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local size = blockSize()
	local fuse = interpolatedFuse( self )
	local swell = 0
	if fuse < 10 then
		local progress = math.Clamp( 1 - fuse / 10, 0, 1 )
		progress = progress * progress
		progress = progress * progress
		swell = progress * 0.3
	end
	local drawSize = size * ( 1 + swell )
	local position = self:GetPos() + Vector( 0, 0, size * 0.5 )
	local color = worldLightingColor( self, position )
	renderer.DrawDroppedBlock( { item = "minecraft:tnt", count = 1 }, position, angle_zero, drawSize, color, {
		displayContext = "ground",
	} )
	if math.floor( fuse / 5 ) % 2 == 0 then drawWhiteOverlay( position, drawSize ) end
end
