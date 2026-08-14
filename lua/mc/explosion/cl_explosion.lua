--[[----------------------------------------------------------------------------
	MC : Minecraft Java 26.2 client explosion effects.

	The packet carries the exact explosion center, radius and selected-cell count.
	Large explosions run the eight-tick EXPLOSION_EMITTER; all explosions entering
	the same client tick share ClientExplosionTracker's 512 secondary-particle cap.
------------------------------------------------------------------------------]]

if not CLIENT then return end

MC = MC or {}

local TICKS_PER_SECOND = 20
local TICK_INTERVAL = 1 / TICKS_PER_SECOND
local MAX_SECONDARY_PARTICLES = 512
local FRACTION_SCALE = 65536

local EXPLOSION_MATERIALS = {}
local GENERIC_MATERIALS = {}
local GENERIC_FRAMES = {
	"generic_7", "generic_6", "generic_5", "generic_4",
	"generic_3", "generic_2", "generic_1", "generic_0",
}

MC.ClientExplosionQueue = MC.ClientExplosionQueue or {}
MC.ClientExplosionEmitters = MC.ClientExplosionEmitters or {}

local function blockSize()
	return math.max( 1, tonumber( MC.BS ) or 36.5 )
end

local function renderPosition( worldPosition )
	return MC.WorldToRenderPos and MC.WorldToRenderPos( worldPosition ) or worldPosition
end

local function explosionMaterial( index )
	index = math.Clamp( math.floor( tonumber( index ) or 1 ), 1, 16 )
	local cached = EXPLOSION_MATERIALS[index]
	if cached then return cached end
	cached = Material( "mc/particle/explosion_" .. ( index - 1 ) .. ".png", "noclamp vertexcolor vertexalpha" )
	EXPLOSION_MATERIALS[index] = cached
	return cached
end

local function genericMaterial( index )
	index = math.Clamp( math.floor( tonumber( index ) or 1 ), 1, #GENERIC_FRAMES )
	local cached = GENERIC_MATERIALS[index]
	if cached then return cached end
	cached = Material( "mc/particle/" .. GENERIC_FRAMES[index] .. ".png", "noclamp vertexcolor vertexalpha" )
	GENERIC_MATERIALS[index] = cached
	return cached
end

local function animatedFrame( lifeSeconds, lifetimeTicks, frameCount )
	local age = math.Clamp( math.floor( math.max( 0, lifeSeconds ) * TICKS_PER_SECOND ), 0, lifetimeTicks )
	return math.Clamp( math.floor( age * ( frameCount - 1 ) / math.max( 1, lifetimeTicks ) ) + 1, 1, frameCount )
end

local function attachAnimatedMaterial( particle, lifetimeTicks, frameCount, materialForFrame, simulate )
	particle:SetNextThink( CurTime() )
	particle:SetThinkFunction( function( current )
		if simulate then simulate( current ) end
		current:SetMaterial( materialForFrame( animatedFrame( current:GetLifeTime(), lifetimeTicks, frameCount ) ) )
		current:SetNextThink( CurTime() )
	end )
end

local function spawnExplosionSprite( emitter, position, sizeParameter )
	if not emitter then return nil end
	local lifetimeTicks = 6 + math.random( 0, 3 )
	local grey = math.floor( math.Rand( 0.4, 1 ) * 255 + 0.5 )
	local size = 2 * ( 1 - math.Clamp( tonumber( sizeParameter ) or 0, 0, 1 ) * 0.5 ) * blockSize()
	local particle = emitter:Add( explosionMaterial( 1 ), position )
	if not particle then return nil end
	particle:SetDieTime( lifetimeTicks * TICK_INTERVAL )
	particle:SetStartAlpha( 255 )
	particle:SetEndAlpha( 255 )
	particle:SetStartSize( size )
	particle:SetEndSize( size )
	particle:SetVelocity( vector_origin )
	particle:SetGravity( vector_origin )
	particle:SetAirResistance( 0 )
	particle:SetCollide( false )
	particle:SetLighting( false )
	particle:SetColor( grey, grey, grey )
	attachAnimatedMaterial( particle, lifetimeTicks, 16, explosionMaterial )
	return particle
end

local function randomParticleConstructorVelocity()
	local velocity = Vector( math.Rand( -0.4, 0.4 ), math.Rand( -0.4, 0.4 ), math.Rand( -0.4, 0.4 ) )
	local speed = ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) + 1 ) * 0.15
	if velocity:LengthSqr() > 0.000001 then velocity:Normalize() else velocity = Vector( 0, 0, 1 ) end
	velocity = velocity * speed * 0.4
	velocity.z = velocity.z + 0.1
	return velocity
end

local function particleSimulation( initialVelocity, friction, upwardGravityPerTick, sizeFunction )
	local velocity = initialVelocity * blockSize() * TICKS_PER_SECOND
	local nextTick = 0
	return function( particle )
		local ageTicks = particle:GetLifeTime() * TICKS_PER_SECOND
		while ageTicks + 0.0001 >= nextTick do
			velocity.z = velocity.z + upwardGravityPerTick * blockSize() * TICKS_PER_SECOND
			velocity = velocity * friction
			nextTick = nextTick + 1
		end
		particle:SetVelocity( velocity )
		if sizeFunction then
			local size = sizeFunction( ageTicks ) * blockSize()
			particle:SetStartSize( size )
			particle:SetEndSize( size )
		end
	end
end

local function spawnPoofParticle( emitter, position, inputVelocity )
	local velocity = inputVelocity + Vector( math.Rand( -0.05, 0.05 ), math.Rand( -0.05, 0.05 ), math.Rand( -0.05, 0.05 ) )
	local grey = math.floor( math.Rand( 0.7, 1 ) * 255 + 0.5 )
	local sizeBlocks = 0.1 * ( math.Rand( 0, 1 ) * math.Rand( 0, 1 ) * 6 + 1 )
	local lifetimeTicks = math.floor( 16 / ( math.Rand( 0, 1 ) * 0.8 + 0.2 ) ) + 2
	local particle = emitter:Add( genericMaterial( 1 ), position )
	if not particle then return nil end
	particle:SetDieTime( lifetimeTicks * TICK_INTERVAL )
	particle:SetStartAlpha( 255 )
	particle:SetEndAlpha( 255 )
	particle:SetStartSize( sizeBlocks * blockSize() )
	particle:SetEndSize( sizeBlocks * blockSize() )
	particle:SetVelocity( velocity * blockSize() * TICKS_PER_SECOND )
	particle:SetGravity( vector_origin )
	particle:SetAirResistance( 0 )
	particle:SetCollide( true )
	particle:SetBounce( 0 )
	particle:SetLighting( false )
	particle:SetColor( grey, grey, grey )
	attachAnimatedMaterial( particle, lifetimeTicks, #GENERIC_FRAMES, genericMaterial,
		particleSimulation( velocity, 0.9, 0.004 ) )
	return particle
end

local function spawnSmokeParticle( emitter, position, inputVelocity )
	local velocity = randomParticleConstructorVelocity() * 0.1 + inputVelocity
	local grey = math.floor( math.Rand( 0, 0.3 ) * 255 + 0.5 )
	local sizeBlocks = ( 0.1 * ( math.Rand( 0, 1 ) * 0.5 + 0.5 ) * 2 ) * 0.75
	local lifetimeTicks = math.max( 1, math.floor( 8 / ( math.Rand( 0, 1 ) * 0.8 + 0.2 ) ) )
	local particle = emitter:Add( genericMaterial( 1 ), position )
	if not particle then return nil end
	particle:SetDieTime( lifetimeTicks * TICK_INTERVAL )
	particle:SetStartAlpha( 255 )
	particle:SetEndAlpha( 255 )
	particle:SetStartSize( 0.01 )
	particle:SetEndSize( sizeBlocks * blockSize() )
	particle:SetVelocity( velocity * blockSize() * TICKS_PER_SECOND )
	particle:SetGravity( vector_origin )
	particle:SetAirResistance( 0 )
	particle:SetCollide( true )
	particle:SetBounce( 0 )
	particle:SetLighting( false )
	particle:SetColor( grey, grey, grey )
	attachAnimatedMaterial( particle, lifetimeTicks, #GENERIC_FRAMES, genericMaterial,
		particleSimulation( velocity, 0.96, 0.004, function( ageTicks )
			return sizeBlocks * math.Clamp( ageTicks / lifetimeTicks * 32, 0, 1 )
		end ) )
	return particle
end

local function playExplosionSound( worldCenter )
	local pitch = ( 1 + ( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 0.2 ) * 0.7
	-- Java volume 4 expands the event's audible distance from 16 to 64 blocks.
	-- The server already applies that exact packet range; 83 dB gives Source a
	-- matching local attenuation without passing an out-of-range volume value.
	if MC.PlayJavaSoundEvent then
		MC.PlayJavaSoundEvent( "entity.generic.explode", renderPosition( worldCenter ), 1, pitch, 83 )
	end
end

local function tickMainExplosionEmitters()
	for index = #MC.ClientExplosionEmitters, 1, -1 do
		local state = MC.ClientExplosionEmitters[index]
		if state.age >= 8 then
			table.remove( MC.ClientExplosionEmitters, index )
		else
			local center = renderPosition( state.center )
			local emitter = ParticleEmitter( center )
			if emitter then
				local size = blockSize()
				for _ = 1, 6 do
					local position = center + Vector(
						( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 4 * size,
						( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 4 * size,
						( math.Rand( 0, 1 ) - math.Rand( 0, 1 ) ) * 4 * size
					)
					spawnExplosionSprite( emitter, position, state.age / 8 )
				end
				emitter:Finish()
			end
			state.age = state.age + 1
		end
	end
end

local function weightedExplosion( explosions, totalWeight )
	if totalWeight <= 0 then return nil end
	local choice = math.random( 1, totalWeight )
	for _, info in ipairs( explosions ) do
		choice = choice - math.max( 0, math.floor( tonumber( info.blockCount ) or 0 ) )
		if choice <= 0 then return info end
	end
	return explosions[#explosions]
end

local function randomUnitVector()
	local direction = Vector( math.Rand( -1, 1 ), math.Rand( -1, 1 ), math.Rand( -1, 1 ) )
	if direction:LengthSqr() <= 0.000001 then return Vector( 0, 0, 1 ) end
	direction:Normalize()
	return direction
end

local function targetCellIsAir( worldPosition )
	if not MC.WorldToCell or not MC.GetBlockState then return true end
	local bx, by, bz = MC.WorldToCell( worldPosition )
	return ( MC.GetBlockState( bx, by, bz ) or 0 ) == 0
end

local function tickSecondaryExplosions()
	local explosions = MC.ClientExplosionQueue
	MC.ClientExplosionQueue = {}
	if #explosions == 0 then return end
	local totalBlocks = 0
	for _, info in ipairs( explosions ) do
		totalBlocks = totalBlocks + math.max( 0, math.floor( tonumber( info.blockCount ) or 0 ) )
	end
	local particleCount = math.min( totalBlocks, MAX_SECONDARY_PARTICLES )
	if particleCount <= 0 then return end
	local emitters = {}
	for _ = 1, particleCount do
		local info = weightedExplosion( explosions, totalBlocks )
		if info then
			local direction = randomUnitVector()
			local radius = math.max( 0.0001, tonumber( info.radius ) or 0.0001 )
			local localRadius = ( math.Rand( 0, 1 ) ^ ( 1 / 3 ) ) * radius
			local localPosition = direction * localRadius * blockSize()
			local targetWorld = info.center + localPosition
			if targetCellIsAir( targetWorld ) then
				local speed = 0.5 / ( localRadius / radius + 0.1 )
					* math.Rand( 0, 1 ) * math.Rand( 0, 1 ) + 0.3
				local inputVelocity = direction * speed
				local emitter = emitters[info]
				if not emitter then
					emitter = ParticleEmitter( renderPosition( info.center ) )
					emitters[info] = emitter
				end
				if emitter then
					if math.random( 0, 1 ) == 0 then
						spawnPoofParticle( emitter, renderPosition( info.center + localPosition * 0.5 ), inputVelocity )
					else
						spawnSmokeParticle( emitter, renderPosition( targetWorld ), inputVelocity )
					end
				end
			end
		end
	end
	for _, emitter in pairs( emitters ) do if emitter then emitter:Finish() end end
end

local lastTick = CurTime()
local accumulator = 0
hook.Add( "Think", "mc_java_explosion_particles", function()
	local current = CurTime()
	local elapsed = math.Clamp( current - lastTick, 0, 0.25 )
	lastTick = current
	accumulator = math.min( 0.25, accumulator + elapsed )
	while accumulator >= TICK_INTERVAL do
		accumulator = accumulator - TICK_INTERVAL
		tickMainExplosionEmitters()
		tickSecondaryExplosions()
	end
end )

local function readCoordinate( size, bits )
	return ( net.ReadInt( bits ) + net.ReadUInt( 16 ) / FRACTION_SCALE ) * size
end

net.Receive( "mc_explosion_fx", function()
	local size = blockSize()
	local coordinateBits = MC.Net and tonumber( MC.Net.COORD_BITS ) or 20
	local x = readCoordinate( size, coordinateBits )
	local y = readCoordinate( size, coordinateBits )
	local z = readCoordinate( size, coordinateBits )
	local center = Vector( x, y, z )
	local radius = math.max( 0, net.ReadFloat() )
	local blockCount = net.ReadUInt( 32 )
	local large = net.ReadBool()
	playExplosionSound( center )
	if large then
		MC.ClientExplosionEmitters[#MC.ClientExplosionEmitters + 1] = { center = center, age = 0 }
	else
		local emitter = ParticleEmitter( renderPosition( center ) )
		if emitter then spawnExplosionSprite( emitter, renderPosition( center ), 1 ) emitter:Finish() end
	end
	MC.ClientExplosionQueue[#MC.ClientExplosionQueue + 1] = {
		center = center,
		radius = radius,
		blockCount = blockCount,
	}
end )
