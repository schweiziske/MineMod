--[[----------------------------------------------------------------------------
	MC : client-side Minecraft block sounds and destroy particles.
------------------------------------------------------------------------------]]

MC = MC or {}

local Net = MC.Net

local function generatedSoundSetForBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	local soundType = b and b.soundType or "STONE"
	local sets = MC.GeneratedSoundTypes or {}
	return sets[soundType] or sets.STONE
end

local function playBlockSound( kind, id, pos )
	local set = generatedSoundSetForBlock( id )
	if not set then return end

	local list = kind == 2 and set.breaks or set.place
	if not list or #list == 0 then return end

	local snd = list[math.random( #list )]
	local volume = ((tonumber( set.volume ) or 1) + 1) * 0.5
	local pitch = (tonumber( set.pitch ) or 1) * 80 * math.Rand( 0.96, 1.04 )
	sound.Play( snd, pos, 72, math.floor( pitch + 0.5 ), volume )
end

local ParticleMaterialCache = {}
local ParticleAtlasTexture = nil
local ParticleAtlasTextureName = nil
local ParticleFallbackMaterial = Material( "particle/particle_noisesphere" )
local PredictedFx = MC.PredictedFx or {}
MC.PredictedFx = PredictedFx
local ParticleUvSteps = 4
local MaxDestroyParticles = 64
local ParticleWarmQueue = {}
local ParticleReadyBursts = {}
local ParticleWarmByTile = {}
local ParticleEmitterPrewarmed = false
local ParticleAtlasPrewarmed = false
local ParticleWarmMaterialsPerFrame = 4
local ParticleWarmFrameSeconds = 0.001
local ParticleWarmBurstsPerFrame = 2

function MC.GetBlockParticleTile( id )
	if MC.BlockParticleTile then
		return MC.BlockParticleTile( id )
	elseif MC.BlockIconTile then
		return MC.BlockIconTile( id )
	end
	return nil
end

function MC.GetBlockParticleTileName( id )
	if not MC.TileNames then return nil, nil end
	local tile = MC.GetBlockParticleTile( id )
	local name = MC.TileNames[tile]
	if not name or name == "" then return nil end
	return name, tile
end

local function tileNameForBlock( id )
	return MC.GetBlockParticleTileName( id )
end

local function particleAtlasTexture()
	if ParticleAtlasTexture and not ParticleAtlasTexture:IsError() then
		return ParticleAtlasTexture, ParticleAtlasTextureName
	end

	local atlasMaterial = MC.Material
	local texture = atlasMaterial and atlasMaterial.GetTexture and atlasMaterial:GetTexture( "$basetexture" ) or nil
	if not texture or texture:IsError() then return nil, nil end
	local textureName = texture.GetName and texture:GetName() or nil
	if not textureName or textureName == "" then return nil, nil end
	ParticleAtlasTexture = texture
	ParticleAtlasTextureName = textureName
	return texture, textureName
end

local function particleMaterialForTile( tileName, col, row )
	local tile = type( tileName ) == "number" and tileName or MC.Tiles and MC.Tiles[tileName]
	if tile == nil then return ParticleFallbackMaterial end

	col = math.Clamp( math.floor( tonumber( col ) or math.random( 0, ParticleUvSteps - 1 ) ), 0, ParticleUvSteps - 1 )
	row = math.Clamp( math.floor( tonumber( row ) or math.random( 0, ParticleUvSteps - 1 ) ), 0, ParticleUvSteps - 1 )
	local byTile = ParticleMaterialCache[tile]
	if not byTile then
		byTile = {}
		ParticleMaterialCache[tile] = byTile
	end
	local byColumn = byTile[col]
	if not byColumn then
		byColumn = {}
		byTile[col] = byColumn
	end
	local cached = byColumn[row]
	if cached then return cached end

	local atlas = MC.Atlas
	local atlasTexture, atlasTextureName = particleAtlasTexture()
	if not atlas or not atlasTexture or not atlasTextureName then return ParticleFallbackMaterial end
	local stride = atlas.STRIDE or atlas.TILE
	local pad = atlas.PAD or 0
	local atlasColumn = tile % atlas.COLS
	local atlasRow = math.floor( tile / atlas.COLS )
	local sampleOffset = 0.75 / ( ParticleUvSteps - 1 )
	local scaleX = atlas.TILE * 0.25 / atlas.W
	local scaleY = atlas.TILE * 0.25 / atlas.H
	local translateX = ( atlasColumn * stride + pad + col * sampleOffset * atlas.TILE ) / atlas.W
	local translateY = ( atlasRow * stride + pad + row * sampleOffset * atlas.TILE ) / atlas.H
	local matName = "mc_particle_atlas_v2_" .. tile .. "_" .. col .. "_" .. row
	local transform = string.format(
		"center 0 0 scale %.9f %.9f rotate 0 translate %.9f %.9f",
		scaleX, scaleY, translateX, translateY
	)

	local mat = CreateMaterial( matName, "UnlitGeneric", {
		["$basetexture"] = atlasTextureName,
		["$translucent"] = "1",
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
		["$nocull"] = "1",
		["$pointsample"] = "1",
		["$basetexturetransform"] = transform,
	} )

	if mat and not mat:IsError() then
		mat:SetTexture( "$basetexture", atlasTexture )
	else
		mat = ParticleFallbackMaterial
	end

	byColumn[row] = mat
	return mat
end

function MC.GetParticleMaterialForTile( tileName, col, row )
	return particleMaterialForTile( tileName, col, row )
end

function MC.GetBlockParticleMaterial( id, col, row )
	local tileName, tile = MC.GetBlockParticleTileName( id )
	return particleMaterialForTile( tileName, col, row ), tileName, tile
end

local function particleLightingAt( pos )
	if MC.SampleDynamicLightingRGB then
		-- Exactly the same world-light sampler used by the held block. Particles
		-- are not light sources and do not apply a separate surface-probe policy.
		return MC.SampleDynamicLightingRGB( pos, 0 )
	end
	if not ( MC.WorldToCell and MC.SampleLighting ) then return 1, 1, 1 end
	local bx, by, bz = MC.WorldToCell( pos )
	if bx == nil then return 1, 1, 1 end
	local brightness = MC.SampleLighting( bx, by, bz, 0 )
	brightness = math.Clamp( tonumber( brightness ) or 1, 0, 1 )
	return brightness, brightness, brightness
end

local function addTerrainParticle( emitter, tileName, pos, relX, relY, relZ, bs, tintCode, lightR, lightG, lightB )
	local p = emitter:Add( particleMaterialForTile( tileName ), pos )
	if not p then return end

	local vx = relX + math.Rand( -0.4, 0.4 )
	local vy = relY + math.Rand( -0.4, 0.4 )
	local vz = relZ + math.Rand( -0.4, 0.4 )
	local len = math.sqrt( vx * vx + vy * vy + vz * vz )
	if len < 0.001 then len = 1 end
	local speed = ( math.Rand( 0, 1 ) + math.Rand( 0, 1 ) + 1 ) * 0.15
	local size = bs * 0.1 * ( math.Rand( 0, 1 ) * 0.5 + 0.5 )

	p:SetVelocity( Vector(
		vx / len * speed * 0.4 * bs * 20,
		vy / len * speed * 0.4 * bs * 20,
		( vz / len * speed * 0.4 + 0.1 ) * bs * 20
	) )
	p:SetDieTime( 4 / ( math.Rand( 0, 1 ) * 0.9 + 0.1 ) / 20 )
	p:SetStartAlpha( 255 )
	p:SetEndAlpha( 255 )
	p:SetStartSize( size )
	p:SetEndSize( size )
	p:SetRoll( 0 )
	p:SetRollDelta( 0 )
	p:SetGravity( Vector( 0, 0, -bs * 0.04 * 20 * 20 ) )
	p:SetCollide( true )
	p:SetBounce( 0 )
	p:SetLighting( false )
	-- Keep particles slightly brighter than held blocks while leaving enough
	-- HDR headroom to avoid clipped, glowing fragments outdoors.
	if MC.ScaleDynamicLightingRGB then
		lightR, lightG, lightB = MC.ScaleDynamicLightingRGB( lightR, lightG, lightB, 0.60 )
	else
		local rawR = math.Clamp( tonumber( lightR ) or 1, 0, 1 )
		local rawG = math.Clamp( tonumber( lightG ) or rawR, 0, 1 )
		local rawB = math.Clamp( tonumber( lightB ) or rawR, 0, 1 )
		lightR, lightG, lightB = rawR * 0.60, rawG * 0.60, rawB * 0.60
	end
	local shadeR = math.Clamp( math.floor( 255 * lightR + 0.5 ), 0, 255 )
	local shadeG = math.Clamp( math.floor( 255 * lightG + 0.5 ), 0, 255 )
	local shadeB = math.Clamp( math.floor( 255 * lightB + 0.5 ), 0, 255 )
	if tintCode and tintCode ~= 0 and MC.BlockTintRGB then
		local tr, tg, tb = MC.BlockTintRGB( tintCode )
		p:SetColor( math.floor( shadeR * tr / 255 + 0.5 ), math.floor( shadeG * tg / 255 + 0.5 ), math.floor( shadeB * tb / 255 + 0.5 ) )
	else
		p:SetColor( shadeR, shadeG, shadeB )
	end
end

local function addDestroyParticleSample( samples, base, box, bs, xx, yy, zz, countX, countY, countZ )
	local x1, y1, z1 = box[1], box[2], box[3]
	local x2, y2, z2 = box[4], box[5], box[6]
	local widthX = math.min( 1, x2 - x1 )
	local widthY = math.min( 1, y2 - y1 )
	local widthZ = math.min( 1, z2 - z1 )
	local relX = ( xx + 0.5 ) / countX
	local relY = ( yy + 0.5 ) / countY
	local relZ = ( zz + 0.5 ) / countZ
	local x = relX * widthX + x1
	local y = relY * widthY + y1
	local z = relZ * widthZ + z1

	samples[#samples + 1] = {
		pos = base + Vector( x * bs, y * bs, z * bs ),
		relX = relX - 0.5,
		relY = relY - 0.5,
		relZ = relZ - 0.5,
	}
end

local function expandParticleAxis( minv, maxv )
	local minSize = 0.0625
	if maxv - minv >= minSize then return minv, maxv end

	local center = ( minv + maxv ) * 0.5
	minv = math.Clamp( center - minSize * 0.5, 0, 1 )
	maxv = math.Clamp( center + minSize * 0.5, 0, 1 )
	if maxv - minv >= minSize then return minv, maxv end
	if minv <= 0 then return 0, minSize end
	return 1 - minSize, 1
end

local function modelParticleBoxes( b )
	if not b or not b.modelQuads then return nil end
	if b._particleBoxes then return b._particleBoxes end

	local minX, minY, minZ = 1, 1, 1
	local maxX, maxY, maxZ = 0, 0, 0
	for _, quad in ipairs( b.modelQuads ) do
		for index = 1, 4 do
			local vx, vy, vz = MC.ModelQuadVertex( quad, index )
			local x = math.Clamp( tonumber( vx ) or 0, 0, 1 )
			local y = math.Clamp( tonumber( vy ) or 0, 0, 1 )
			local z = math.Clamp( tonumber( vz ) or 0, 0, 1 )
			if x < minX then minX = x end
			if y < minY then minY = y end
			if z < minZ then minZ = z end
			if x > maxX then maxX = x end
			if y > maxY then maxY = y end
			if z > maxZ then maxZ = z end
		end
	end

	if maxX <= minX and maxY <= minY and maxZ <= minZ then return nil end
	minX, maxX = expandParticleAxis( minX, maxX )
	minY, maxY = expandParticleAxis( minY, maxY )
	minZ, maxZ = expandParticleAxis( minZ, maxZ )

	b._particleBoxes = { { minX, minY, minZ, maxX, maxY, maxZ } }
	return b._particleBoxes
end

local function spawnBreakParticlesNow( id, orient, bx, by, bz, options )
	options = istable( options ) and options or {}
	local b = MC.Blocks and MC.Blocks[id]
	if b and b.spawnTerrainParticles == false then return 0 end
	if not MC.BlockBoxes then return 0 end

	local boxes = options.boxes or MC.BlockBoxes( id, orient, bx, by, bz )
	if ( not boxes or #boxes == 0 ) and b and b.modelQuads then
		boxes = modelParticleBoxes( b )
	end
	if not boxes or #boxes == 0 then return 0 end

	local base = MC.CellWorldMin( bx, by, bz )
	local bs = MC.BS
	local emitter = ParticleEmitter( options.emitterPos or base + Vector( bs * 0.5, bs * 0.5, bs * 0.5 ) )
	if not emitter then return 0 end

	local tileName = options.tileName or tileNameForBlock( id )
	local tintCode = options.tintCode or 0
	-- A held block samples once and applies that one RGB value to the whole
	-- object. Do the same for a particle burst. Sampling every fragment inside
	-- the old block volume blends against zero-light neighbouring solid cells
	-- and makes otherwise illuminated break particles look black.
	local lightPos = options.lightPos or base + Vector( bs * 0.5, bs * 0.5, bs * 0.5 )
	local lightR, lightG, lightB = particleLightingAt( lightPos )
	local samples = {}
	for _, box in ipairs( boxes ) do
		local widthX = math.min( 1, box[4] - box[1] )
		local widthY = math.min( 1, box[5] - box[2] )
		local widthZ = math.min( 1, box[6] - box[3] )
		local countX = math.max( 2, math.ceil( widthX / 0.25 ) )
		local countY = math.max( 2, math.ceil( widthY / 0.25 ) )
		local countZ = math.max( 2, math.ceil( widthZ / 0.25 ) )

		for xx = 0, countX - 1 do
			for yy = 0, countY - 1 do
				for zz = 0, countZ - 1 do
					addDestroyParticleSample( samples, base, box, bs, xx, yy, zz, countX, countY, countZ )
				end
			end
		end
	end

	local total = #samples
	local maxParticles = math.max( 0, math.floor( tonumber( options.maxParticles ) or MaxDestroyParticles ) )
	local count = math.min( total, maxParticles )
	if count <= 0 then
		emitter:Finish()
		return 0
	end
	local step = total > count and total / count or 1
	local offset = total > count and math.Rand( 0, step ) or 0

	for i = 1, count do
		local sampleIndex = math.min( total, math.floor( offset + ( i - 1 ) * step ) + 1 )
		local sample = samples[sampleIndex]
		addTerrainParticle( emitter, tileName, sample.pos, sample.relX, sample.relY, sample.relZ, bs, tintCode, lightR, lightG, lightB )
	end

	emitter:Finish()
	return count
end

local function copyParticleOptions( options )
	local copy = {}
	for key, value in pairs( options or {} ) do copy[key] = value end
	return copy
end

local function prewarmParticleEmitter( material, atlas )
	if atlas and ParticleAtlasPrewarmed or not atlas and ParticleEmitterPrewarmed then return true end
	local ply = LocalPlayer()
	if not IsValid( ply ) then return false end
	local pos = ply:EyePos() + ply:EyeAngles():Forward() * 32
	local emitter = ParticleEmitter( pos )
	if not emitter then return false end
	local particle = emitter:Add( material, pos )
	if particle then
		particle:SetDieTime( 0.05 )
		particle:SetStartAlpha( 1 )
		particle:SetEndAlpha( 1 )
		particle:SetStartSize( 0.01 )
		particle:SetEndSize( 0.01 )
		particle:SetVelocity( vector_origin )
		particle:SetGravity( vector_origin )
		particle:SetCollide( false )
		particle:SetLighting( false )
	end
	emitter:Finish()
	if atlas then ParticleAtlasPrewarmed = true else ParticleEmitterPrewarmed = true end
	return true
end

local function queueParticleTileWarm( tileName, request )
	local tile = type( tileName ) == "number" and tileName or MC.Tiles and MC.Tiles[tileName]
	if tile == nil then return false end
	local state = ParticleWarmByTile[tile]
	if state and state.ready then return false end
	if not state then
		state = { tile = tile, nextVariant = 0, pending = {} }
		ParticleWarmByTile[tile] = state
		ParticleWarmQueue[#ParticleWarmQueue + 1] = state
	end
	state.pending[#state.pending + 1] = request
	return true
end

local function spawnBreakParticles( id, orient, bx, by, bz, options )
	options = istable( options ) and options or {}
	local tileName = options.tileName or tileNameForBlock( id )
	local queuedOptions = copyParticleOptions( options )
	queuedOptions.tileName = tileName
	local request = {
		id = id, orient = orient,
		bx = bx, by = by, bz = bz,
		options = queuedOptions,
		expires = CurTime() + 3,
	}
	if queueParticleTileWarm( tileName, request ) then return 0 end
	return spawnBreakParticlesNow( id, orient, bx, by, bz, options )
end

hook.Remove( "Think", "mc_particle_material_prewarm" )
hook.Add( "Think", "mc_particle_material_prewarm", function()
	if not ParticleEmitterPrewarmed then prewarmParticleEmitter( ParticleFallbackMaterial, false ) end

	local state = ParticleWarmQueue[1]
	if state then
		local atlasTexture = particleAtlasTexture()
		if atlasTexture then
			local started = SysTime()
			local built = 0
			local variantCount = ParticleUvSteps * ParticleUvSteps
			while state.nextVariant < variantCount and built < ParticleWarmMaterialsPerFrame
			and ( built == 0 or SysTime() - started < ParticleWarmFrameSeconds ) do
				local variant = state.nextVariant
				local col = math.floor( variant / ParticleUvSteps )
				local row = variant % ParticleUvSteps
				local material = particleMaterialForTile( state.tile, col, row )
				if not ParticleAtlasPrewarmed then prewarmParticleEmitter( material, true ) end
				state.nextVariant = variant + 1
				built = built + 1
			end

			if state.nextVariant >= variantCount then
				state.ready = true
				for _, request in ipairs( state.pending ) do
					ParticleReadyBursts[#ParticleReadyBursts + 1] = request
				end
				state.pending = {}
				table.remove( ParticleWarmQueue, 1 )
			end
		end
	end

	for _ = 1, ParticleWarmBurstsPerFrame do
		local request = ParticleReadyBursts[1]
		if not request then break end
		table.remove( ParticleReadyBursts, 1 )
		if CurTime() <= request.expires then
			spawnBreakParticlesNow( request.id, request.orient,
				request.bx, request.by, request.bz, request.options )
		end
	end
end )

function MC.SpawnBlockBreakParticles( id, orient, bx, by, bz, options )
	return spawnBreakParticles( id, orient, bx, by, bz, options )
end

local function fxKey( kind, bx, by, bz, id )
	local key = MC.CellKey( bx, by, bz )
	if type( key ) == "number" then return key * 4 + kind end
	return key
end

local function prunePredictedFx()
	local now = CurTime()
	for key, expire in pairs( PredictedFx ) do
		if expire <= now then PredictedFx[key] = nil end
	end
end

function MC.PlayBlockFx( kind, id, orient, bx, by, bz, predicted, stateId )
	local pos = MC.CellWorldCenter( bx, by, bz )
	playBlockSound( kind, id, pos )
	if kind == 2 then
		local tintCode = stateId and MC.BlockStateTintCode and MC.BlockStateTintCode( stateId, id, 0 ) or 0
		spawnBreakParticles( id, orient, bx, by, bz, { tintCode = tintCode } )
	end
	if predicted then
		prunePredictedFx()
		PredictedFx[fxKey( kind, bx, by, bz, id )] = CurTime() + 2.5
	end
end

local function normalizeFxKind( kind )
	if kind == "place" then return 1 end
	if kind == "break" or kind == "destroy" then return 2 end
	kind = math.floor( tonumber( kind ) or 0 )
	if kind == 1 or kind == 2 then return kind end
	return nil
end

function MC.PlayBlockEffect( kind, id, orient, bx, by, bz, options )
	kind = normalizeFxKind( kind )
	if not kind then return false, "invalid_kind" end
	options = istable( options ) and options or {}
	MC.PlayBlockFx( kind, id, orient, bx, by, bz, options.predicted == true, options.stateId )
	return true
end

local function consumePredictedFx( kind, bx, by, bz, id )
	prunePredictedFx()
	local key = fxKey( kind, bx, by, bz, id )
	local expire = PredictedFx[key]
	if not expire then return false end
	PredictedFx[key] = nil
	return CurTime() <= expire
end

net.Receive( "mc_fx", function()
	local kind = net.ReadUInt( 2 )
	local bx = net.ReadInt( Net.COORD_BITS )
	local by = net.ReadInt( Net.COORD_BITS )
	local bz = net.ReadInt( Net.COORD_BITS )
	local id = net.ReadUInt( Net.ID_BITS )
	local orient = net.ReadUInt( Net.ORIENT_BITS )
	local stateId = net.ReadUInt( Net.STATE_ID_BITS or Net.ID_BITS )

	if consumePredictedFx( kind, bx, by, bz, id ) then return end
	MC.PlayBlockFx( kind, id, orient, bx, by, bz, false, stateId )
end )
