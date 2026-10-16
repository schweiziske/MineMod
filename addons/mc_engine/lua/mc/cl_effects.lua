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

local function selectSoundCandidate( list )
	if not list or #list == 0 then return nil end
	local totalWeight = 0
	for _, candidate in ipairs( list ) do
		local weight = istable( candidate ) and tonumber( candidate.weight ) or 1
		totalWeight = totalWeight + math.max( 1, math.floor( weight or 1 ) )
	end
	local choice = math.random( totalWeight )
	for _, candidate in ipairs( list ) do
		local weight = istable( candidate ) and tonumber( candidate.weight ) or 1
		choice = choice - math.max( 1, math.floor( weight or 1 ) )
		if choice <= 0 then
			if istable( candidate ) then return candidate end
			return { sound = candidate, volume = 1, pitch = 1 }
		end
	end
	return nil
end

local function playBlockSound( kind, id, pos )
	local set = generatedSoundSetForBlock( id )
	if not set then return end

	local list = kind == 2 and set.breaks or set.place
	if not list or #list == 0 then return end

	local selected = selectSoundCandidate( list )
	if not selected or not selected.sound then return end
	local volume = ((tonumber( set.volume ) or 1) + 1) * 0.5 * (tonumber( selected.volume ) or 1)
	local pitch = (tonumber( set.pitch ) or 1) * (tonumber( selected.pitch ) or 1) * 80 * math.Rand( 0.96, 1.04 )
	sound.Play( selected.sound, pos, 72, math.floor( pitch + 0.5 ), volume )
end

function MC.PlayBlockMiningHitSound( id, pos, volumeOverride, pitchOverride )
	local set = generatedSoundSetForBlock( id )
	if not set then return false end
	-- SoundType#getHitSound is a separate Java event.  Generated catalogs must
	-- carry it explicitly: break samples are not a valid mining-progress alias.
	local candidates = set.hits
	if not candidates or #candidates == 0 then return false end

	local selected = selectSoundCandidate( candidates )
	if not selected or not selected.sound then return false end
	-- Two-argument callers retain MultiPlayerGameMode.continueDestroyBlock's
	-- `(SoundType#getVolume() + 1.0F) / 8.0F` and SoundType pitch * 0.5.
	-- Explicit overrides are for other Java call sites that obtain the same
	-- hit SoundEvent but pass their own Level.playLocalSound volume/pitch (for
	-- example Sniffer.emitDiggingParticles uses exactly 0.5F, 0.5F).
	local baseVolume = tonumber( volumeOverride )
	if baseVolume == nil then baseVolume = ((tonumber( set.volume ) or 1) + 1) / 8 end
	local basePitch = tonumber( pitchOverride )
	if basePitch == nil then basePitch = (tonumber( set.pitch ) or 1) * 0.5 end
	local volume = math.Clamp( baseVolume, 0, 4 ) * (tonumber( selected.volume ) or 1)
	local pitch = math.Clamp( basePitch, 0.01, 2.55 ) * (tonumber( selected.pitch ) or 1)
	sound.Play( selected.sound, pos, 72, math.Clamp( math.floor( pitch * 100 + 0.5 ), 1, 255 ), volume )
	return true
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
	if tile == nil then return nil, nil end
	local name = MC.TileNames[tile]
	-- External blocks may intentionally use legal unnamed tail slots. The
	-- particle material path accepts a numeric tile and still applies the active
	-- atlas profile, so do not discard those custom block particles.
	if not name or name == "" then return tile, tile end
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
	local x, y, width, height, layout = MC.AtlasRegion(tile)
	local sampleOffset = 0.75 / ( ParticleUvSteps - 1 )
	local scaleX = width * 0.25 / layout.W
	local scaleY = height * 0.25 / layout.H
	local translateX = (x + col * sampleOffset * width) / layout.W
	local translateY = (y + row * sampleOffset * height) / layout.H
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

function MC.RefreshBlockParticleMaterials( atlasTexture )
	if not atlasTexture or ( atlasTexture.IsError and atlasTexture:IsError() ) then return false end
	ParticleAtlasTexture = atlasTexture
	ParticleAtlasTextureName = atlasTexture.GetName and atlasTexture:GetName() or ParticleAtlasTextureName
	for _, byTile in pairs( ParticleMaterialCache ) do
		for _, byColumn in pairs( byTile ) do
			for _, material in pairs( byColumn ) do
				if material and material.SetTexture then material:SetTexture( "$basetexture", atlasTexture ) end
			end
		end
	end
	return true
end

hook.Add( "MC.AtlasProfileChanged", "mc_particle_atlas_profile", function()
	ParticleMaterialCache = {}
	ParticleWarmQueue = {}
	ParticleWarmByTile = {}
	ParticleAtlasPrewarmed = false
end )

function MC.GetParticleMaterialForTile( tileName, col, row )
	return particleMaterialForTile( tileName, col, row )
end

function MC.GetBlockParticleMaterial( id, col, row )
	local tileName, tile = MC.GetBlockParticleTileName( id )
	return particleMaterialForTile( tileName, col, row ), tileName, tile
end

-- Capture one colour per destruction event, including queued material warmup.
-- Fragments retain this colour for their entire lifetime.
local function terrainParticleColor( bx, by, bz, tintCode )
	local tr, tg, tb = 255, 255, 255
	if tintCode and tintCode ~= 0 and MC.BlockTintRGB then
		tr, tg, tb = MC.BlockTintRGB( tintCode )
	end
	-- TerrainParticle.java uses 0.6 base colour before the lightmap multiplier.
	tr, tg, tb = tr * 0.6, tg * 0.6, tb * 0.6
	local world = MC.API.Coords.CellCenter( bx, by, bz )
	local r, g, b = MC.API.Light.SamplePresentationRGB( world, 0 )
	if not MC.Check( r ~= nil, "terrain_particle_light", "Cannot sample terrain particle lighting: %s", g ) then return nil end
	return Color( math.floor( r * tr + 0.5 ), math.floor( g * tg + 0.5 ), math.floor( b * tb + 0.5 ) )
end

local function addTerrainParticle( emitter, tileName, pos, relX, relY, relZ, bs, color )
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
	p:SetColor( color.r, color.g, color.b )
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

	local base = MC.CellRenderMin and MC.CellRenderMin( bx, by, bz )
		or MC.CellWorldMin( bx, by, bz )
	local bs = MC.BS
	local emitter = ParticleEmitter( options.emitterPos or base + Vector( bs * 0.5, bs * 0.5, bs * 0.5 ) )
	if not emitter then return 0 end

	local tileName = options.tileName or tileNameForBlock( id )
	local color = options.particleColor
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
		addTerrainParticle( emitter, tileName, sample.pos, sample.relX, sample.relY, sample.relZ, bs, color )
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
	queuedOptions.particleColor = terrainParticleColor( bx, by, bz, options.tintCode or 0 )
	if not queuedOptions.particleColor then return 0 end
	local request = {
		id = id, orient = orient,
		bx = bx, by = by, bz = bz,
		options = queuedOptions,
		expires = CurTime() + 3,
	}
	if queueParticleTileWarm( tileName, request ) then return 0 end
	return spawnBreakParticlesNow( id, orient, bx, by, bz, queuedOptions )
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
	local pos = MC.CellRenderCenter and MC.CellRenderCenter( bx, by, bz )
		or MC.CellWorldCenter( bx, by, bz )
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
