-- Java 26.2 fire and campfire ambient effects.
--
-- ClientLevel.animateTick samples 667 coordinates at radius 16 and another
-- 667 at radius 32 every client tick. Sampling only known effect blocks with
-- the exact triangular-coordinate hit probability is statistically identical
-- to iterating the many empty coordinates and is far cheaper in Lua.

MC = MC or {}

local BS = MC.BS or 36.5
local TICK_SECONDS = 1 / 20
local REFRESH_INTERVAL = 0.25
local SAMPLE_COUNT_PER_RADIUS = 667
local MAX_NORMAL_PARTICLE_DISTANCE_SQR = ( BS * 32 ) ^ 2
-- CampfireBlock.makeParticles uses addAlwaysVisibleParticle(..., true), which
-- bypasses Java's ordinary 32-block particle limiter. A Java client only ticks
-- block entities in loaded chunks; 32 chunks is the maximum vanilla render
-- distance, so 512 blocks is the equivalent safety bound for streamed chunks.
local MAX_ALWAYS_VISIBLE_DISTANCE_SQR = ( BS * 512 ) ^ 2
local GENERIC_SMOKE_FRAMES = {
	"generic_7", "generic_6", "generic_5", "generic_4",
	"generic_3", "generic_2", "generic_1", "generic_0",
}
local CAMPFIRE_SMOKE_FRAMES = {
	"big_smoke_0", "big_smoke_1", "big_smoke_2", "big_smoke_3",
	"big_smoke_4", "big_smoke_5", "big_smoke_6", "big_smoke_7",
	"big_smoke_8", "big_smoke_9", "big_smoke_10", "big_smoke_11",
}
local EFFECT_BLOCKS = {
	["minecraft:fire"] = "fire",
	["minecraft:soul_fire"] = "fire",
	["minecraft:campfire"] = "campfire",
	["minecraft:soul_campfire"] = "campfire",
}
local Entries = {}
local EntriesByChunk = {}
local ScannedChunkVersions = {}
local SpriteMaterials = {}
local DynamicParticles = {}
local LastRefresh = 0
local LastParticleTick = 0
local LastParticleStepAt = 0
local LastGeneration = tonumber( MC.StateWorldGeneration ) or 0

local function stateName( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	return schema and schema.name or nil
end

local function cellKey( bx, by, bz )
	return MC.CellKey and MC.CellKey( bx, by, bz ) or ( bx .. ":" .. by .. ":" .. bz )
end

local function chunkKeyForCell( bx, by, bz )
	local cx, cy, cz = MC.CellToChunk( bx, by, bz )
	return MC.ChunkKey( cx, cy, cz )
end

local function removeEntry( key )
	local entry = Entries[key]
	if not entry then return end
	Entries[key] = nil
	local chunkEntries = EntriesByChunk[entry.chunkKey]
	if chunkEntries then
		chunkEntries[key] = nil
		if next( chunkEntries ) == nil then EntriesByChunk[entry.chunkKey] = nil end
	end
end

local function removeChunkEntries( chunkKey )
	for key in pairs( EntriesByChunk[chunkKey] or {} ) do Entries[key] = nil end
	EntriesByChunk[chunkKey] = nil
end

local function addEntry( bx, by, bz, stateId, kind )
	local key = cellKey( bx, by, bz )
	local chunkKey = chunkKeyForCell( bx, by, bz )
	local entry = Entries[key]
	if not entry then
		entry = { key = key, bx = bx, by = by, bz = bz, chunkKey = chunkKey }
		Entries[key] = entry
		EntriesByChunk[chunkKey] = EntriesByChunk[chunkKey] or {}
		EntriesByChunk[chunkKey][key] = true
	end
	entry.stateId = stateId
	entry.kind = kind
	return entry
end

local function scanChunk( key, chunk )
	removeChunkEntries( key )
	if MC.ForEachBlockState then
		MC.ForEachBlockState( chunk, function( bx, by, bz, _, _, _, stateId )
			local kind = EFFECT_BLOCKS[stateName( stateId )]
			if kind then addEntry( bx, by, bz, stateId, kind ) end
		end )
	end
	ScannedChunkVersions[key] = { chunk = chunk, version = chunk.collisionVersion or 0 }
end

local function clearEntries()
	Entries = {}
	EntriesByChunk = {}
	ScannedChunkVersions = {}
end

local function refreshChunks()
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if generation ~= LastGeneration then
		clearEntries()
		LastGeneration = generation
	end
	for key, scanned in pairs( ScannedChunkVersions ) do
		local current = MC.GetChunkByKey and MC.GetChunkByKey( key ) or MC.World and MC.World[key]
		if current ~= scanned.chunk then
			removeChunkEntries( key )
			ScannedChunkVersions[key] = nil
		end
	end
	for key, chunk in pairs( MC.World or {} ) do
		local scanned = ScannedChunkVersions[key]
		local version = chunk.collisionVersion or 0
		if not scanned or scanned.chunk ~= chunk or scanned.version ~= version then scanChunk( key, chunk ) end
	end
end

local function spriteMaterial( name )
	local cached = SpriteMaterials[name]
	if cached then return cached end
	cached = Material( "mc/particle/" .. name .. ".png", "noclamp vertexcolor vertexalpha" )
	SpriteMaterials[name] = cached
	return cached
end

local function cellMin( bx, by, bz )
	return MC.CellRenderMin and MC.CellRenderMin( bx, by, bz ) or MC.CellWorldMin( bx, by, bz )
end

local function cellCenter( bx, by, bz )
	return MC.CellRenderCenter and MC.CellRenderCenter( bx, by, bz ) or MC.CellWorldCenter( bx, by, bz )
end

-- Particle's six-argument constructor adds a normalized random velocity before
-- SmokeParticle scales it by 0.1. Source uses Z as vertical, so the Java Y
-- component maps to this vector's Z component.
local function randomParticleConstructorVelocity()
	local velocity = Vector( math.Rand( -0.4, 0.4 ), math.Rand( -0.4, 0.4 ), math.Rand( -0.4, 0.4 ) )
	local speed = ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) + 1 ) * 0.15
	if velocity:LengthSqr() > 0.000001 then velocity:Normalize() else velocity = Vector( 0, 0, 1 ) end
	velocity = velocity * speed * 0.4
	velocity.z = velocity.z + 0.1
	return velocity
end

local function spawnAnimatedSmoke( pos, scale, velocity )
	local lifetimeTicks = math.max( 1, math.floor( 8 / ( math.Rand( 0, 1 ) * 0.8 + 0.2 ) * scale ) )
	local colour = math.floor( math.Rand( 0, 0.3 ) * 255 + 0.5 )
	local initialVelocity = randomParticleConstructorVelocity() * 0.1 * BS * 20
	initialVelocity:Add( velocity or vector_origin )
	DynamicParticles[#DynamicParticles + 1] = {
		kind = "smoke", pos = Vector( pos.x, pos.y, pos.z ),
		vel = initialVelocity,
		age = 0, lifetime = lifetimeTicks, scale = scale,
		baseSize = BS * 0.1 * math.Rand( 0.5, 1 ) * 0.75 * scale * 2,
		colour = colour,
	}
	return true
end

local function spawnLargeSmoke( pos )
	return spawnAnimatedSmoke( pos, 2.5, vector_origin, true )
end

local function spawnSmallSmoke( pos, velocity )
	return spawnAnimatedSmoke( pos, 1, velocity or Vector( 0, 0, BS * 0.005 * 20 ) )
end

local function spawnCampfireSmoke( pos, signal )
	DynamicParticles[#DynamicParticles + 1] = {
		kind = "campfire_smoke", pos = Vector( pos.x, pos.y, pos.z ),
		vel = Vector( 0, 0, BS * ( 0.07 + math.Rand( 0, 1 ) / 500 ) * 20 ),
		age = 0, lifetime = math.random( 50 ) - 1 + ( signal and 280 or 80 ),
		alpha = signal and 0.95 or 0.9,
		size = BS * 0.1 * math.Rand( 0.5, 1 ) * 2 * 3,
		material = spriteMaterial( CAMPFIRE_SMOKE_FRAMES[math.random( #CAMPFIRE_SMOKE_FRAMES )] ),
	}
end

local function spawnLavaSpark( pos )
	local lifetime = math.max( 1, math.floor( 16 / ( math.Rand( 0, 1 ) * 0.8 + 0.2 ) ) )
	local velocity = randomParticleConstructorVelocity()
	velocity.x, velocity.y = velocity.x * 0.8, velocity.y * 0.8
	velocity.z = math.Rand( 0.05, 0.45 )
	velocity:Mul( BS * 20 )
	DynamicParticles[#DynamicParticles + 1] = {
		kind = "lava", pos = Vector( pos.x, pos.y, pos.z ),
		vel = velocity,
		age = 0, lifetime = lifetime,
		size = BS * 0.1 * math.Rand( 0.5, 1 ) * 2 * math.Rand( 0.2, 2.2 ),
		material = spriteMaterial( "lava" ),
	}
end

local function tickDynamicParticles()
	for index = #DynamicParticles, 1, -1 do
		local particle = DynamicParticles[index]
		particle.previousPos = Vector( particle.pos.x, particle.pos.y, particle.pos.z )
		particle.previousAge = particle.age
		particle.previousAlpha = particle.alpha
		particle.age = particle.age + 1
		if particle.age >= particle.lifetime then
			table.remove( DynamicParticles, index )
		elseif particle.kind == "campfire_smoke" then
			particle.vel.x = particle.vel.x + BS * math.Rand( 0, 1 ) / 5000
				* ( math.random( 2 ) == 1 and -1 or 1 ) * 20
			particle.vel.y = particle.vel.y + BS * math.Rand( 0, 1 ) / 5000
				* ( math.random( 2 ) == 1 and -1 or 1 ) * 20
			particle.vel.z = particle.vel.z - BS * 3e-6 * 20 * 20 * TICK_SECONDS
			particle.pos:Add( particle.vel * TICK_SECONDS )
			if particle.age >= particle.lifetime - 60 and particle.alpha > 0.01 then
				particle.alpha = particle.alpha - 0.015
			end
		elseif particle.kind == "lava" then
			particle.vel.z = particle.vel.z - BS * 0.03 * 20 * 20 * TICK_SECONDS
			particle.vel:Mul( 0.999 )
			particle.pos:Add( particle.vel * TICK_SECONDS )
			if math.Rand( 0, 1 ) > particle.age / particle.lifetime then
				spawnSmallSmoke( particle.pos, particle.vel )
			end
		else
			particle.vel.z = particle.vel.z + BS * 0.004 * 20 * 20 * TICK_SECONDS
			particle.vel:Mul( 0.96 )
			particle.pos:Add( particle.vel * TICK_SECONDS )
		end
	end
end

local function topFaceSturdyAt( bx, by, bz )
	local stateId = MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
	if not stateId or stateId == 0 then return false end
	local liquid = MC.Liquid
	if liquid and liquid.FaceSturdyForFlow then
		return liquid.FaceSturdyForFlow( stateId, bx, by, bz, liquid.FACE_TOP or 1 ) == true
	end
	return MC.BlockIsFullCubeForState and MC.BlockIsFullCubeForState( stateId, bx, by, bz ) == true or false
end

local function flammableAt( bx, by, bz )
	local flammable = MC.GeneratedFireFlammableBlocks or {}
	return flammable[stateName( MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0 )] == true
end

local function animateFire( entry )
	local base = cellMin( entry.bx, entry.by, entry.bz )
	if math.random( 24 ) == 1 then
		MC.PlayJavaSoundEvent( "block.fire.ambient", cellCenter( entry.bx, entry.by, entry.bz ),
			1 + math.Rand( 0, 1 ), 0.3 + math.Rand( 0, 1 ) * 0.7 )
	end
	if flammableAt( entry.bx, entry.by, entry.bz - 1 ) or topFaceSturdyAt( entry.bx, entry.by, entry.bz - 1 ) then
		for _ = 1, 3 do
			spawnLargeSmoke( base + Vector( math.Rand( 0, BS ), math.Rand( 0, BS ), math.Rand( BS * 0.5, BS ) ) )
		end
		return
	end
	local sides = {
		{ entry.bx - 1, entry.by, entry.bz, function() return Vector( math.Rand( 0, BS * 0.1 ), math.Rand( 0, BS ), math.Rand( 0, BS ) ) end },
		{ entry.bx + 1, entry.by, entry.bz, function() return Vector( BS - math.Rand( 0, BS * 0.1 ), math.Rand( 0, BS ), math.Rand( 0, BS ) ) end },
		{ entry.bx, entry.by - 1, entry.bz, function() return Vector( math.Rand( 0, BS ), math.Rand( 0, BS * 0.1 ), math.Rand( 0, BS ) ) end },
		{ entry.bx, entry.by + 1, entry.bz, function() return Vector( math.Rand( 0, BS ), BS - math.Rand( 0, BS * 0.1 ), math.Rand( 0, BS ) ) end },
		{ entry.bx, entry.by, entry.bz + 1, function() return Vector( math.Rand( 0, BS ), math.Rand( 0, BS ), BS - math.Rand( 0, BS * 0.1 ) ) end },
	}
	for _, side in ipairs( sides ) do
		if flammableAt( side[1], side[2], side[3] ) then
			for _ = 1, 2 do spawnLargeSmoke( base + side[4]() ) end
		end
	end
end

local function campfireFoodSlots( entry )
	local record = MC.GetBlockEntity and MC.GetBlockEntity( entry.bx, entry.by, entry.bz ) or nil
	local items = record and record.data and record.data.items or nil
	local occupied = {}
	for _, value in ipairs( items or {} ) do
		local slot = math.floor( tonumber( value.slot ) or -1 )
		if slot >= 0 and slot < 4 and value.stack then occupied[slot] = true end
	end
	return occupied
end

local FACING_INDEX = { south = 0, west = 1, north = 2, east = 3 }
local DIRECTIONS = {
	[0] = { x = 0, y = 1, cwX = -1, cwY = 0 },
	[1] = { x = -1, y = 0, cwX = 0, cwY = -1 },
	[2] = { x = 0, y = -1, cwX = 1, cwY = 0 },
	[3] = { x = 1, y = 0, cwX = 0, cwY = 1 },
}

local function animateCampfire( entry )
	if MC.GetStateProperty( entry.stateId, "lit" ) ~= true then return end
	if math.random( 10 ) == 1 then
		MC.PlayJavaSoundEvent( "block.campfire.crackle", cellCenter( entry.bx, entry.by, entry.bz ),
			0.5 + math.Rand( 0, 1 ), 0.6 + math.Rand( 0, 1 ) * 0.7 )
	end
	if math.random( 5 ) == 1 then spawnLavaSpark( cellCenter( entry.bx, entry.by, entry.bz ) ) end
end

local function campfireSmokeTick( entry )
	if MC.GetStateProperty( entry.stateId, "lit" ) ~= true then return end
	local base = cellMin( entry.bx, entry.by, entry.bz )
	local signal = MC.GetStateProperty( entry.stateId, "signal_fire" ) == true
	if math.Rand( 0, 1 ) < 0.11 then
		for _ = 1, math.random( 2, 3 ) do
			spawnCampfireSmoke( base + Vector(
				BS * ( 0.5 + math.Rand( 0, 1 ) / 3 * ( math.random( 2 ) == 1 and -1 or 1 ) ),
				BS * ( 0.5 + math.Rand( 0, 1 ) / 3 * ( math.random( 2 ) == 1 and -1 or 1 ) ),
				BS * ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) )
			), signal )
		end
	end
	return base
end

local function campfireFoodSmokeTick( entry, base )
	if MC.GetStateProperty( entry.stateId, "lit" ) ~= true then return end
	base = base or cellMin( entry.bx, entry.by, entry.bz )
	local occupied = campfireFoodSlots( entry )
	local facingIndex = FACING_INDEX[MC.GetStateProperty( entry.stateId, "facing" )] or 0
	for slot = 0, 3 do
		if occupied[slot] and math.Rand( 0, 1 ) < 0.2 then
			local direction = DIRECTIONS[( slot + facingIndex ) % 4]
			local pos = base + Vector(
				BS * ( 0.5 - direction.x * 0.3125 + direction.cwX * 0.3125 ),
				BS * ( 0.5 - direction.y * 0.3125 + direction.cwY * 0.3125 ),
				BS * 0.5
			)
			for _ = 1, 4 do spawnSmallSmoke( pos, Vector( 0, 0, BS * 0.0005 * 20 ) ) end
		end
	end
end

function MC.SpawnCampfireDowseParticles( bx, by, bz, signal )
	local base = cellMin( bx, by, bz )
	for _ = 1, 20 do
		spawnCampfireSmoke( base + Vector(
			BS * ( 0.5 + math.Rand( 0, 1 ) / 3 * ( math.random( 2 ) == 1 and -1 or 1 ) ),
			BS * ( 0.5 + math.Rand( 0, 1 ) / 3 * ( math.random( 2 ) == 1 and -1 or 1 ) ),
			BS * ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) )
		), signal == true )
		spawnSmallSmoke( base + Vector(
			BS * ( 0.5 + math.Rand( 0, 1 ) / 4 * ( math.random( 2 ) == 1 and -1 or 1 ) ),
			BS * ( 0.5 + math.Rand( 0, 1 ) / 4 * ( math.random( 2 ) == 1 and -1 or 1 ) ),
			BS * 0.4
		), Vector( 0, 0, BS * 0.005 * 20 ) )
	end
end

local function triangularOffsetChance( delta, radius )
	delta = math.floor( tonumber( delta ) or 0 )
	if delta <= -radius or delta >= radius then return 0 end
	return ( radius - math.abs( delta ) ) / ( radius * radius )
end

function MC.FireCampfireAnimateSampleProbability( dx, dy, dz )
	local function radiusChance( radius )
		return triangularOffsetChance( dx, radius )
			* triangularOffsetChance( dy, radius )
			* triangularOffsetChance( dz, radius )
	end
	local p16, p32 = radiusChance( 16 ), radiusChance( 32 )
	return 1 - ( 1 - p16 ) ^ SAMPLE_COUNT_PER_RADIUS * ( 1 - p32 ) ^ SAMPLE_COUNT_PER_RADIUS
end

-- The same block can be selected more than once by ClientLevel.animateTick in
-- a single client tick.  Sampling only "at least one hit" loses those repeats
-- (and therefore a small but real number of particles/sounds).  Inverting the
-- binomial CDF preserves the exact Binomial(667, p) count without iterating all
-- 1,334 sampled coordinates for every known effect block.
local function sampleBinomial( trials, probability )
	if probability <= 0 or trials <= 0 then return 0 end
	if probability >= 1 then return trials end
	local target = math.Rand( 0, 1 )
	local q = 1 - probability
	local term = q ^ trials
	local cumulative = term
	local hits = 0
	while target > cumulative and hits < trials do
		hits = hits + 1
		term = term * ( trials - hits + 1 ) / hits * probability / q
		cumulative = cumulative + term
	end
	return hits
end

function MC.FireCampfireAnimateSampleCount( dx, dy, dz )
	local function radiusChance( radius )
		return triangularOffsetChance( dx, radius )
			* triangularOffsetChance( dy, radius )
			* triangularOffsetChance( dz, radius )
	end
	return sampleBinomial( SAMPLE_COUNT_PER_RADIUS, radiusChance( 16 ) )
		+ sampleBinomial( SAMPLE_COUNT_PER_RADIUS, radiusChance( 32 ) )
end

local function runAmbientSamples()
	local player = LocalPlayer()
	if not IsValid( player ) then return end
	local eye = player:EyePos()
	local px, py, pz = MC.WorldToCell( player:GetPos() )
	if px == nil then return end
	for key, entry in pairs( Entries ) do
		local stateId = MC.GetBlockState and MC.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
		local kind = EFFECT_BLOCKS[stateName( stateId )]
		if not kind then
			removeEntry( key )
		else
			entry.stateId, entry.kind = stateId, kind
			local sampleHits = MC.FireCampfireAnimateSampleCount(
				entry.bx - px, entry.by - py, entry.bz - pz )
			for _ = 1, sampleHits do
				if kind == "fire" then animateFire( entry ) else animateCampfire( entry ) end
			end
			if kind == "campfire" and eye then
				local distanceSqr = eye:DistToSqr( cellCenter( entry.bx, entry.by, entry.bz ) )
				local base
				if distanceSqr <= MAX_ALWAYS_VISIBLE_DISTANCE_SQR then base = campfireSmokeTick( entry ) end
				if distanceSqr <= MAX_NORMAL_PARTICLE_DISTANCE_SQR then campfireFoodSmokeTick( entry, base ) end
			end
		end
	end
end

hook.Add( "Think", "mc_fire_campfire_effects", function()
	local now = CurTime()
	if now >= LastRefresh then
		LastRefresh = now + REFRESH_INTERVAL
		refreshChunks()
	end
	if LastParticleTick <= 0 then
		LastParticleTick = now
		LastParticleStepAt = now - TICK_SECONDS
	end
	local steps = 0
	while now >= LastParticleTick and steps < 5 do
		LastParticleStepAt = LastParticleTick
		LastParticleTick = LastParticleTick + TICK_SECONDS
		tickDynamicParticles()
		runAmbientSamples()
		steps = steps + 1
	end
	-- Do not replay an unbounded backlog after a long pause/loading hitch. Java
	-- still advances at 20 TPS, while the next visible interval starts here.
	if steps >= 5 and now >= LastParticleTick then
		LastParticleStepAt = now
		LastParticleTick = now + TICK_SECONDS
	end
end )

net.Receive( "mc_campfire_dowse_fx", function()
	local coordinateBits = MC.Net and MC.Net.COORD_BITS or 20
	local bx = net.ReadInt( coordinateBits )
	local by = net.ReadInt( coordinateBits )
	local bz = net.ReadInt( coordinateBits )
	MC.SpawnCampfireDowseParticles( bx, by, bz, net.ReadBool() )
end )

hook.Add( "PostDrawTranslucentRenderables", "mc_campfire_dynamic_particles", function( _, _, skybox )
	if skybox or #DynamicParticles == 0 then return end
	local partialTick = math.Clamp( ( CurTime() - LastParticleStepAt ) / TICK_SECONDS, 0, 1 )
	for _, particle in ipairs( DynamicParticles ) do
		local renderAge = Lerp( partialTick, particle.previousAge or particle.age, particle.age )
		local progress = math.Clamp( renderAge / math.max( particle.lifetime, 1 ), 0, 1 )
		local size = particle.kind == "lava" and particle.size * ( 1 - progress * progress )
			or particle.kind == "smoke" and particle.baseSize * math.Clamp( progress * 32, 0, 1 )
			or particle.size
		local renderAlpha = Lerp( partialTick, particle.previousAlpha or particle.alpha or 1, particle.alpha or 1 )
		local alpha = particle.kind == "campfire_smoke" and math.Clamp( renderAlpha, 0, 1 ) * 255 or 255
		local material = particle.material
		local colour = 255
		if particle.kind == "smoke" then
			local frameIndex = math.min( #GENERIC_SMOKE_FRAMES,
				math.floor( progress * ( #GENERIC_SMOKE_FRAMES - 1 ) ) + 1 )
			material = spriteMaterial( GENERIC_SMOKE_FRAMES[frameIndex] )
			colour = particle.colour or 0
		end
		render.SetMaterial( material )
		local renderPos = particle.previousPos and LerpVector( partialTick, particle.previousPos, particle.pos ) or particle.pos
		render.DrawSprite( renderPos, size, size, Color( colour, colour, colour, alpha ) )
	end
end )

hook.Add( "OnReloaded", "mc_fire_campfire_effects_reset", function()
	clearEntries()
	DynamicParticles = {}
	LastParticleTick = 0
	LastParticleStepAt = 0
end )
