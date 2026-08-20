-- ArmorStand#showBreakingParticles client adapter.
if not CLIENT then return end

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local spareGaussian
local function gaussian()
	if spareGaussian then
		local value = spareGaussian
		spareGaussian = nil
		return value
	end
	local radius = math.sqrt( -2 * math.log( math.max( math.Rand( 0, 1 ), 1.0e-12 ) ) )
	local angle = math.Rand( 0, math.pi * 2 )
	spareGaussian = radius * math.sin( angle )
	return radius * math.cos( angle )
end

local function terrainVelocity( xAux, yAux, zAux, blockSize )
	-- Particle(level, ..., xa, ya, za), followed by TerrainParticle gravity.
	local x = xAux + math.Rand( -0.4, 0.4 )
	local y = yAux + math.Rand( -0.4, 0.4 )
	local z = zAux + math.Rand( -0.4, 0.4 )
	local length = math.sqrt( x * x + y * y + z * z )
	if length < 1.0e-12 then length = 1 end
	local speed = ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) + 1 ) * 0.15
	return Vector( x / length * speed * 0.4,
		z / length * speed * 0.4,
		y / length * speed * 0.4 + 0.1 ) * blockSize * 20
end

local function spawnBreakingParticles( worldPosition, small )
	local params = D.ArmorStandBreakingParticleParameters( small )
	local blockSize = MC.API and MC.API.Coords and MC.API.Coords.BlockSize
		and MC.API.Coords.BlockSize() or 36.5
	local renderOrigin = D.EnginePositionFromWorld( worldPosition, LocalPlayer() ) or worldPosition
	local center = renderOrigin + Vector( 0, 0, params.centerY * blockSize )
	local worldCenter = worldPosition + Vector( 0, 0, params.centerY * blockSize )
	local lightR, lightG, lightB = D.SampleDecorationLight( worldCenter, false )
	local effects = MC.API and MC.API.Effects
	if not effects or not effects.BlockParticleMaterial or not ParticleEmitter then return end
	local emitter = ParticleEmitter( center )
	if not emitter then return end
	for _ = 1, params.count do
		local material = effects.BlockParticleMaterial( params.block )
		if material then
			local position = center + Vector(
				gaussian() * params.xDist * blockSize,
				gaussian() * params.zDist * blockSize,
				gaussian() * params.yDist * blockSize )
			local particle = emitter:Add( material, position )
			if particle then
				particle:SetVelocity( terrainVelocity( gaussian() * params.speed,
					gaussian() * params.speed, gaussian() * params.speed, blockSize ) )
				particle:SetDieTime( 4 / ( math.Rand( 0, 1 ) * 0.9 + 0.1 ) / 20 )
				local size = blockSize * 0.1 * ( math.Rand( 0, 1 ) * 0.5 + 0.5 )
				particle:SetStartSize( size )
				particle:SetEndSize( size )
				particle:SetStartAlpha( 255 )
				particle:SetEndAlpha( 255 )
				particle:SetRoll( 0 )
				particle:SetRollDelta( 0 )
				particle:SetGravity( Vector( 0, 0, -blockSize * 0.04 * 20 * 20 ) )
				particle:SetCollide( true )
				particle:SetBounce( 0 )
				particle:SetLighting( false )
				particle:SetColor( math.floor( math.Clamp( lightR or 1, 0, 1 ) * 0.6 * 255 + 0.5 ),
					math.floor( math.Clamp( lightG or lightR or 1, 0, 1 ) * 0.6 * 255 + 0.5 ),
					math.floor( math.Clamp( lightB or lightR or 1, 0, 1 ) * 0.6 * 255 + 0.5 ) )
			end
		end
	end
	emitter:Finish()
end

net.Receive( "mc_decoration_armor_stand_break_particles", function()
	spawnBreakingParticles( net.ReadVector(), net.ReadBool() )
end )
