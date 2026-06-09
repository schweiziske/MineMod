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
local PredictedFx = MC.PredictedFx or {}
MC.PredictedFx = PredictedFx
local ParticleUvSteps = 8
local MaxDestroyParticles = 64

local function tileNameForBlock( id )
	if not MC.BlockIconTile or not MC.TileNames then return nil end
	local tile = MC.BlockIconTile( id )
	local name = MC.TileNames[tile]
	if not name or name == "" then return nil end
	return name
end

local function particleMaterialForTile( tileName )
	if not tileName then return "particle/particle_noisesphere" end

	local col = math.random( 0, ParticleUvSteps - 1 )
	local row = math.random( 0, ParticleUvSteps - 1 )
	local key = tileName .. ":" .. col .. ":" .. row
	local cached = ParticleMaterialCache[key]
	if cached then return cached end

	local safeName = string.gsub( tileName, "[^%w_]", "_" )
	local matName = "mc_particle_" .. safeName .. "_" .. col .. "_" .. row
	local transform = string.format(
		"center 0 0 scale 0.25 0.25 rotate 0 translate %.4f %.4f",
		col * ( 0.75 / ( ParticleUvSteps - 1 ) ),
		row * ( 0.75 / ( ParticleUvSteps - 1 ) )
	)

	local mat = CreateMaterial( matName, "UnlitGeneric", {
		["$basetexture"] = "mc/tiles/" .. tileName,
		["$translucent"] = "1",
		["$vertexcolor"] = "1",
		["$vertexalpha"] = "1",
		["$nocull"] = "1",
		["$basetexturetransform"] = transform,
	} )

	if not mat or mat:IsError() then
		mat = Material( "mc/tiles/" .. tileName )
	end

	ParticleMaterialCache[key] = mat
	return mat
end

local function addTerrainParticle( emitter, tileName, pos, relX, relY, relZ, bs )
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
	p:SetColor( 153, 153, 153 )
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

local function spawnBreakParticles( id, orient, bx, by, bz )
	local b = MC.Blocks and MC.Blocks[id]
	if b and b.spawnTerrainParticles == false then return end
	if not MC.BlockBoxes then return end

	local boxes = MC.BlockBoxes( id, orient, bx, by, bz )
	if not boxes or #boxes == 0 then return end

	local base = MC.CellWorldMin( bx, by, bz )
	local bs = MC.BS
	local emitter = ParticleEmitter( base + Vector( bs * 0.5, bs * 0.5, bs * 0.5 ) )
	if not emitter then return end

	local tileName = tileNameForBlock( id )
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
	local count = math.min( total, MaxDestroyParticles )
	local step = total > count and total / count or 1
	local offset = total > count and math.Rand( 0, step ) or 0

	for i = 1, count do
		local sampleIndex = math.min( total, math.floor( offset + ( i - 1 ) * step ) + 1 )
		local sample = samples[sampleIndex]
		addTerrainParticle( emitter, tileName, sample.pos, sample.relX, sample.relY, sample.relZ, bs )
	end

	emitter:Finish()
end

local function fxKey( kind, bx, by, bz, id )
	return kind .. ":" .. bx .. ":" .. by .. ":" .. bz .. ":" .. id
end

local function prunePredictedFx()
	local now = CurTime()
	for key, expire in pairs( PredictedFx ) do
		if expire <= now then PredictedFx[key] = nil end
	end
end

function MC.PlayBlockFx( kind, id, orient, bx, by, bz, predicted )
	local pos = MC.CellWorldCenter( bx, by, bz )
	playBlockSound( kind, id, pos )
	if kind == 2 then
		spawnBreakParticles( id, orient, bx, by, bz )
	end
	if predicted then
		prunePredictedFx()
		PredictedFx[fxKey( kind, bx, by, bz, id )] = CurTime() + 2.5
	end
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

	if consumePredictedFx( kind, bx, by, bz, id ) then return end
	MC.PlayBlockFx( kind, id, orient, bx, by, bz, false )
end )
