-- Client enchanting-table state, option request helper and the animated
-- block-entity book. Inventory stacks remain on the ordinary authoritative
-- inventory transport; this file never constructs an enchanted result.

if not CLIENT then return end

MC = MC or {}

local STATE_VERSION = 2
local API = MC.API or {}
local World = API.World or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}
local Light = API.Light or {}
local Font = API.Font or {}
local BLOCK_ENTITY_TYPE = "minecraft:enchanting_table"
local resolvedTable = type( Blocks.Resolve ) == "function" and Blocks.Resolve( "minecraft:enchanting_table" ) or nil
local ENCHANTING_TABLE_BLOCK_ID = resolvedTable and resolvedTable.id or nil
local BS = type( Coords.BlockSize ) == "function" and tonumber( Coords.BlockSize() ) or 36.5
local MODEL_SCALE = BS / 16
local UP = Vector( 0, 0, 1 )
local TICK_SECONDS = 1 / 20
local SAMPLE_COUNT_PER_RADIUS = 667
local MAX_RENDER_DISTANCE_SQR = ( BS * 64 ) ^ 2
local PLAYER_RANGE_SQR = ( BS * 3 ) ^ 2
local MAX_PARTICLE_DISTANCE_SQR = ( BS * 32 ) ^ 2
local MAX_ENCHANT_PARTICLES = 2048
local BOOK_MATERIAL = Material( "mc/entity/enchantment/enchanting_table_book.png",
	"alphatest vertexcolor vertexalpha" )
-- The world mesh uses ordinary back-face culling. The GUI path projects the
-- same boxes into surface.DrawPoly, whose 2D winding is inverted by the PIP
-- transform; give that path its own double-sided runtime PNG material so the
-- lids/pages are not reduced to the thin edge faces seen on a closed book.
local BOOK_GUI_MATERIAL = Material( "mc/entity/enchantment/enchanting_table_book.png",
	"alphatest vertexcolor vertexalpha nocull" )
local ENCHANT_PARTICLE_MATERIALS = {}
for codepoint = string.byte( "a" ), string.byte( "z" ) do
	ENCHANT_PARTICLE_MATERIALS[#ENCHANT_PARTICLE_MATERIALS + 1] = Material(
		"mc/particle/sga_" .. string.char( codepoint ) .. ".png",
		"alphatest noclamp vertexcolor vertexalpha"
	)
end
local ENCHANTMENT_WORDS = {
	"the", "elder", "scrolls", "klaatu", "berata", "niktu", "xyzzy", "bless", "curse", "light",
	"darkness", "fire", "air", "earth", "water", "hot", "dry", "cold", "wet", "ignite", "snuff",
	"embiggen", "twist", "shorten", "stretch", "fiddle", "destroy", "imbue", "galvanize", "enchant",
	"free", "limited", "range", "of", "towards", "inside", "sphere", "cube", "self", "other", "ball",
	"mental", "physical", "grow", "shrink", "demon", "elemental", "spirit", "animal", "creature",
	"beast", "humanoid", "undead", "fresh", "stale", "phnglui", "mglwnafh", "cthulhu", "rlyeh",
	"wgahnagl", "fhtagn", "baguette",
}

local function emit( eventName, ... )
	if hook and hook.Run then hook.Run( eventName, ... ) end
end

local function randomEnchantmentWords( random )
	local words = {}
	for _ = 1, random:NextInt( 2 ) + 3 do
		words[#words + 1] = ENCHANTMENT_WORDS[random:NextInt( #ENCHANTMENT_WORDS ) + 1]
	end
	return table.concat( words, " " )
end

function MC.EnchantingBuildDisplayNames( seed, options )
	local names = { "", "", "" }
	if type( MC.NewLegacyRandom ) ~= "function" then return names end
	local random = MC.NewLegacyRandom( tonumber( seed ) or 0 )
	for optionIndex = 0, 2 do
		local option = type( options ) == "table" and options[optionIndex + 1] or nil
		local cost = math.max( 0, math.floor( tonumber( option and option.cost ) or 0 ) )
		if cost > 0 then
			local costText = tostring( cost )
			local costWidth = type( Font.Measure ) == "function" and Font.Measure( costText, "default" ) or #costText * 6
			local maxWidth = math.max( 0, 86 - costWidth )
			local text = randomEnchantmentWords( random )
			names[optionIndex + 1] = type( Font.TrimToWidth ) == "function"
				and Font.TrimToWidth( text, maxWidth, "alt" ) or text
		end
	end
	return names
end

net.Receive( "mc_enchanting_state", function()
	local version = net.ReadUInt( 8 )
	local containerId = net.ReadUInt( 16 )
	local token = net.ReadString()
	local revision = net.ReadUInt( 32 )
	local bookshelfCount = net.ReadUInt( 4 )
	local seed = net.ReadInt( 32 )
	local options, decodeError = {}, nil
	for optionIndex = 0, 2 do
		local cost = net.ReadUInt( 32 )
		local clue = net.ReadString()
		local clueLevel = net.ReadUInt( 8 )
		local available = net.ReadBool()
		local errorCode = net.ReadString()
		if #clue > 128 or #errorCode > 96 then decodeError = "invalid_enchanting_state" end
		options[optionIndex + 1] = {
			index = optionIndex,
			cost = cost,
			lapisCost = optionIndex + 1,
			clue = clue ~= "" and clue or nil,
			clueLevel = clueLevel,
			available = available,
			error = errorCode ~= "" and errorCode or nil,
		}
	end
	local displayNames = MC.EnchantingBuildDisplayNames( seed, options )
	for index, option in ipairs( options ) do option.displayName = displayNames[index] or "" end
	local state = MC.ClientInventory
	local session = state and state.session
	if version ~= STATE_VERSION or decodeError or not session or session.kind ~= "enchanting_table"
	or session.containerId ~= containerId or session.token ~= token then return end
	if session.enchantingState and revision < ( session.enchantingState.revision or 0 ) then return end
	session.enchantingState = {
		revision = revision,
		bookshelfCount = bookshelfCount,
		seed = seed,
		options = options,
		receivedAt = RealTime(),
	}
	emit( "MCEnchantingStateChanged", session.enchantingState, state )
end )

function MC.RequestEnchantingOption( optionIndex )
	local state = MC.ClientInventory
	local session = state and state.session
	if not session or session.kind ~= "enchanting_table" then return false, "enchanting_table_not_open" end
	optionIndex = math.floor( tonumber( optionIndex ) or -1 )
	if optionIndex < 0 or optionIndex > 2 then return false, "invalid_enchantment_option" end
	local option = session.enchantingState and session.enchantingState.options
		and session.enchantingState.options[optionIndex + 1] or nil
	if not option or option.available ~= true then return false, option and option.error or "enchantment_unavailable" end
	if not MC.QueueInventoryMenuButton then return false, "menu_button_transport_unavailable" end
	return MC.QueueInventoryMenuButton( optionIndex )
end

-- Enchantment names belong to MCITEM; without it the clue shows the id.
function MC.EnchantingClueName( enchantmentId, level )
	enchantmentId = tostring( enchantmentId or "" )
	level = math.max( 0, math.floor( tonumber( level ) or 0 ) )
	if MCITEM and type( MCITEM.EnchantmentLevelName ) == "function" then
		return MCITEM.EnchantmentLevelName( enchantmentId, level )
	end
	return enchantmentId
end

-- EnchantmentScreen's tooltip, with Minecraft's own keys.
function MC.EnchantingOptionTooltipLines( option )
	if type( option ) ~= "table" or not option.clue then return nil end
	local lines = {
		{ text = MC.T( "container.enchant.clue", { MC.EnchantingClueName( option.clue, option.clueLevel ) } ),
			color = Color( 255, 255, 255 ) },
		{ text = "", color = Color( 255, 255, 255 ) },
	}
	if option.error == "not_enough_experience" then
		lines[#lines + 1] = {
			text = MC.T( "container.enchant.level.requirement", { tostring( option.cost or 0 ) } ),
			color = Color( 255, 85, 85 ),
		}
	else
		local lapis = math.max( 1, math.floor( tonumber( option.lapisCost ) or ( tonumber( option.index ) or 0 ) + 1 ) )
		local plural = lapis == 1 and "one" or "many"
		lines[#lines + 1] = {
			text = MC.T( "container.enchant.lapis." .. plural, { lapis } ),
			color = option.error == "not_enough_lapis" and Color( 255, 85, 85 ) or Color( 170, 170, 170 ),
		}
		lines[#lines + 1] = {
			text = MC.T( "container.enchant.level." .. plural, { lapis } ),
			color = Color( 170, 170, 170 ),
		}
	end
	return lines
end

-- Bound after the shared BookModel geometry helpers below have been declared.
-- The public name is retained because the inventory screen is a separate file.
local drawEnchantingBook2D
function MC.DrawEnchantingBook2D( ... )
	if not drawEnchantingBook2D then return false end
	return drawEnchantingBook2D( ... )
end

local Entries = {}
local EnchantParticles = {}
local RenderEntriesDirty = true
local NextRebuildAttempt = 0
local LastAnimationTick = CurTime()

local function cellKey( bx, by, bz )
	return tostring( bx ) .. ":" .. tostring( by ) .. ":" .. tostring( bz )
end

local function isEnchantingTableState( stateId )
	if not ENCHANTING_TABLE_BLOCK_ID or type( Blocks.StateBlockId ) ~= "function" then return false end
	return Blocks.StateBlockId( stateId ) == ENCHANTING_TABLE_BLOCK_ID
end

local function blockNameAt( bx, by, bz )
	if type( World.GetBlockInfo ) ~= "function" then return "minecraft:air" end
	local info = World.GetBlockInfo( bx, by, bz )
	return info and ( info.mcid or info.name ) or "minecraft:air"
end

local function triangularOffsetChance( delta, radius )
	delta = math.floor( tonumber( delta ) or 0 )
	if delta <= -radius or delta >= radius then return 0 end
	return ( radius - math.abs( delta ) ) / ( radius * radius )
end

function MC.EnchantingAnimateSampleProbability( dx, dy, dz )
	local function radiusChance( radius )
		return triangularOffsetChance( dx, radius )
			* triangularOffsetChance( dy, radius )
			* triangularOffsetChance( dz, radius )
	end
	local p16, p32 = radiusChance( 16 ), radiusChance( 32 )
	return 1 - ( 1 - p16 ) ^ SAMPLE_COUNT_PER_RADIUS * ( 1 - p32 ) ^ SAMPLE_COUNT_PER_RADIUS
end

local function sampleBinomial( trials, probability )
	if probability <= 0 or trials <= 0 then return 0 end
	if probability >= 1 then return trials end
	local target = math.Rand( 0, 1 )
	local miss = 1 - probability
	local term = miss ^ trials
	local cumulative = term
	local hits = 0
	while target > cumulative and hits < trials do
		hits = hits + 1
		term = term * ( trials - hits + 1 ) / hits * probability / miss
		cumulative = cumulative + term
	end
	return hits
end

function MC.EnchantingAnimateSampleCount( dx, dy, dz )
	local function radiusChance( radius )
		return triangularOffsetChance( dx, radius )
			* triangularOffsetChance( dy, radius )
			* triangularOffsetChance( dz, radius )
	end
	return sampleBinomial( SAMPLE_COUNT_PER_RADIUS, radiusChance( 16 ) )
		+ sampleBinomial( SAMPLE_COUNT_PER_RADIUS, radiusChance( 32 ) )
end

local function particlePositionAt( particle, age )
	local progress = math.Clamp( ( tonumber( age ) or 0 ) / particle.lifetime, 0, 1 )
	local remaining = 1 - progress
	local curve = progress * progress
	curve = curve * curve
	return particle.target + particle.auxiliary * remaining - UP * ( curve * 1.2 * BS )
end

function MC.EnchantingParticlePosition( target, auxiliary, age, lifetime )
	if not isvector( target ) or not isvector( auxiliary ) then return nil end
	return particlePositionAt( {
		target = target,
		auxiliary = auxiliary,
		lifetime = math.max( 1, tonumber( lifetime ) or 1 ),
	}, age )
end

local function spawnEnchantParticle( entry, offset )
	if type( Coords.CellMin ) ~= "function" then return false end
	local base = Coords.CellMin( entry.bx, entry.by, entry.bz )
	if not isvector( base ) then return false end
	local target = base + Vector( BS * 0.5, BS * 0.5, BS * 2 )
	-- Java axes x/y/z map to project bx/bz/by. The particle constructor starts
	-- at target + auxiliary (the shelf) and curves back to target (the table).
	local auxiliary = Vector(
		( offset.x + math.Rand( 0, 1 ) - 0.5 ) * BS,
		( offset.z + math.Rand( 0, 1 ) - 0.5 ) * BS,
		( offset.y - math.Rand( 0, 1 ) - 1 ) * BS
	)
	local brightness = math.Rand( 0, 1 ) * 0.6 + 0.4
	local particle = {
		bx = entry.bx, by = entry.by, bz = entry.bz,
		target = target,
		auxiliary = auxiliary,
		age = 0,
		lifetime = math.floor( math.Rand( 0, 1 ) * 10 ) + 30,
		size = 0.2 * ( math.Rand( 0, 1 ) * 0.5 + 0.2 ) * BS,
		red = 0.9 * brightness,
		green = 0.9 * brightness,
		blue = brightness,
		material = ENCHANT_PARTICLE_MATERIALS[math.random( #ENCHANT_PARTICLE_MATERIALS )],
	}
	particle.position = particlePositionAt( particle, 0 )
	particle.previousPosition = particle.position
	if #EnchantParticles >= MAX_ENCHANT_PARTICLES then table.remove( EnchantParticles, 1 ) end
	EnchantParticles[#EnchantParticles + 1] = particle
	return true
end

local function tickEnchantParticles()
	for index = #EnchantParticles, 1, -1 do
		local particle = EnchantParticles[index]
		if particle.age >= particle.lifetime then
			table.remove( EnchantParticles, index )
		else
			particle.previousPosition = particle.position
			particle.age = particle.age + 1
			particle.position = particlePositionAt( particle, particle.age )
		end
	end
end

local function runEnchantingAmbientSamples()
	local ply = LocalPlayer()
	if not IsValid( ply ) or type( Coords.EntityCell ) ~= "function" then return end
	local px, py, pz = Coords.EntityCell( ply )
	if px == nil then return end
	for _, entry in pairs( Entries ) do
		local hits = MC.EnchantingAnimateSampleCount( entry.bx - px, entry.by - py, entry.bz - pz )
		for _ = 1, hits do
			for _, offset in ipairs( MC.EnchantingBookshelfOffsets or {} ) do
				if math.random( 16 ) == 1 and MC.EnchantingBookshelfOffsetValid
				and MC.EnchantingBookshelfOffsetValid( entry.bx, entry.by, entry.bz, offset, blockNameAt ) then
					spawnEnchantParticle( entry, offset )
				end
			end
		end
	end
end

local function particleRenderPosition( particle, worldPosition )
	if type( Coords.CellCenter ) ~= "function" or type( Coords.CellRenderCenter ) ~= "function" then return nil end
	local worldCenter = Coords.CellCenter( particle.bx, particle.by, particle.bz )
	local renderCenter = Coords.CellRenderCenter( particle.bx, particle.by, particle.bz )
	if not isvector( worldCenter ) or not isvector( renderCenter ) then return nil end
	return worldPosition + renderCenter - worldCenter
end

local function drawEnchantParticles( partialTick, eye )
	if not render.DrawSprite then return end
	for _, particle in ipairs( EnchantParticles ) do
		local worldPosition = particle.previousPosition
			+ ( particle.position - particle.previousPosition ) * partialTick
		local renderPosition = particleRenderPosition( particle, worldPosition )
		if renderPosition and eye:DistToSqr( renderPosition ) <= MAX_PARTICLE_DISTANCE_SQR then
			local progress = math.Clamp( ( particle.age + partialTick ) / particle.lifetime, 0, 1 )
			local emission = progress * progress
			emission = emission * emission
			local lightR, lightG, lightB = 1, 1, 1
			if type( Light.SampleRGB ) == "function" then
				lightR, lightG, lightB = Light.SampleRGB( worldPosition, emission )
			end
			render.SetMaterial( particle.material )
			render.DrawSprite( renderPosition, particle.size, particle.size, Color(
				math.Clamp( math.floor( particle.red * lightR * 255 + 0.5 ), 0, 255 ),
				math.Clamp( math.floor( particle.green * lightG * 255 + 0.5 ), 0, 255 ),
				math.Clamp( math.floor( particle.blue * lightB * 255 + 0.5 ), 0, 255 ),
				255
			) )
		end
	end
end

local function removeEntry( key )
	Entries[key] = nil
end

local function newEntry( bx, by, bz )
	return {
		key = cellKey( bx, by, bz ), bx = bx, by = by, bz = bz,
		time = 0, flip = 0, oFlip = 0, flipT = 0, flipA = 0,
		open = 0, oOpen = 0, rot = 0, oRot = 0, tRot = 0,
		nextLightAt = 0,
	}
end

local function addEntry( bx, by, bz, destination )
	destination = destination or Entries
	local key = cellKey( bx, by, bz )
	local entry = Entries[key]
	if entry then
		entry.bx, entry.by, entry.bz = bx, by, bz
		destination[key] = entry
		return entry
	end
	entry = newEntry( bx, by, bz )
	destination[key] = entry
	return entry
end

local function rebuildEntries()
	if type( World.ForEachBlockEntity ) ~= "function" or type( World.GetBlockState ) ~= "function" then
		return false
	end
	local rebuilt = {}
	local ok = World.ForEachBlockEntity( BLOCK_ENTITY_TYPE, function( bx, by, bz )
		if isEnchantingTableState( World.GetBlockState( bx, by, bz ) ) then
			addEntry( bx, by, bz, rebuilt )
		end
	end )
	if ok ~= true then return false end
	Entries = rebuilt
	return true
end

function MC.MarkEnchantingTableRenderEntriesDirty()
	RenderEntriesDirty = true
end

local function noteEnchantingTableStateChanged( bx, by, bz, oldStateId, newStateId )
	local wasTable = isEnchantingTableState( oldStateId )
	local isTable = isEnchantingTableState( newStateId )
	if not wasTable and not isTable then return end
	local key = cellKey( bx, by, bz )
	if isTable then addEntry( bx, by, bz ) else removeEntry( key ) end
end

hook.Add( "MC.ClientBlockStateChanged", "mcgame_enchanting_table_state", noteEnchantingTableStateChanged )
hook.Add( "MC.ClientWorldProjectionChanged", "mcgame_enchanting_table_projection", function( reason, context )
	if reason == "block_entity_changed" and type( context ) == "table"
	and context.bx ~= nil and context.by ~= nil and context.bz ~= nil
	and type( World.GetBlockState ) == "function" then
		local stateId = World.GetBlockState( context.bx, context.by, context.bz )
		noteEnchantingTableStateChanged( context.bx, context.by, context.bz, stateId, stateId )
		return
	end
	RenderEntriesDirty = true
end )

local function nearestPlayer( center )
	if type( Coords.EntityWorldPos ) ~= "function" then return nil end
	local nearest, distance = nil, PLAYER_RANGE_SQR
	for _, ply in ipairs( player.GetAll() ) do
		if IsValid( ply ) and ply:Alive() then
			local position = Coords.EntityWorldPos( ply )
			local current = position and center:DistToSqr( position ) or math.huge
			if current <= distance then nearest, distance = ply, current end
		end
	end
	return nearest
end

local function wrapAngle( value )
	while value >= math.pi do value = value - math.pi * 2 end
	while value < -math.pi do value = value + math.pi * 2 end
	return value
end

local function tickBook( entry )
	entry.oOpen = entry.open
	entry.oRot = entry.rot
	local center = type( Coords.CellCenter ) == "function" and Coords.CellCenter( entry.bx, entry.by, entry.bz ) or nil
	if not center then return end
	local ply = nearestPlayer( center )
	if IsValid( ply ) then
		local delta = Coords.EntityWorldPos( ply ) - center
		entry.tRot = math.atan2( delta.y, delta.x )
		entry.open = entry.open + 0.1
		if entry.open < 0.5 or math.random( 40 ) == 1 then
			local previous = entry.flipT
			repeat entry.flipT = entry.flipT + math.random( 0, 3 ) - math.random( 0, 3 ) until entry.flipT ~= previous
		end
	else
		entry.tRot = entry.tRot + 0.02
		entry.open = entry.open - 0.1
	end
	entry.rot = wrapAngle( entry.rot )
	entry.tRot = wrapAngle( entry.tRot )
	entry.rot = entry.rot + wrapAngle( entry.tRot - entry.rot ) * 0.4
	entry.open = math.Clamp( entry.open, 0, 1 )
	entry.time = entry.time + 1
	entry.oFlip = entry.flip
	local difference = math.Clamp( ( entry.flipT - entry.flip ) * 0.4, -0.2, 0.2 )
	entry.flipA = entry.flipA + ( difference - entry.flipA ) * 0.9
	entry.flip = entry.flip + entry.flipA
end

local function emitVertex( position, u, v, color, normal )
	mesh.Position( position )
	if mesh.Normal then mesh.Normal( normal ) end
	mesh.Color( color.r, color.g, color.b, color.a )
	mesh.TexCoord( 0, u, v )
	mesh.AdvanceVertex()
end

local function emitQuad( a, b, c, d, u0, v0, u1, v1, color )
	local normal = ( b - a ):Cross( d - a )
	if normal:LengthSqr() > 0 then normal:Normalize() else normal = UP end
	emitVertex( a, u1 / 64, v0 / 32, color, normal )
	emitVertex( b, u0 / 64, v0 / 32, color, normal )
	emitVertex( c, u0 / 64, v1 / 32, color, normal )
	emitVertex( d, u1 / 64, v1 / 32, color, normal )
end

local function rotatedPartPoint( angle, tx, ty, tz, x, y, z )
	local cosine, sine = math.cos( angle ), math.sin( angle )
	local rotatedX = x * cosine + z * sine + tx
	local rotatedZ = -x * sine + z * cosine + tz
	return rotatedX, y + ty, rotatedZ
end

local function partPoint( origin, axisX, axisY, axisZ, angle, tx, ty, tz, x, y, z )
	local rotatedX, rotatedY, rotatedZ = rotatedPartPoint( angle, tx, ty, tz, x, y, z )
	return origin + axisX * ( rotatedX * MODEL_SCALE ) + axisY * ( rotatedY * MODEL_SCALE )
		+ axisZ * ( rotatedZ * MODEL_SCALE )
end

local function forEachBookBoxFace( point, x, y, z, width, height, depth, texU, texV, callback )
	local x0, x1 = x, x + width
	local y0, y1 = y, y + height
	local z0, z1 = z, z + depth
	local t0, t1, t2, t3 = point( x0, y0, z0 ), point( x1, y0, z0 ), point( x1, y1, z0 ), point( x0, y1, z0 )
	local l0, l1, l2, l3 = point( x0, y0, z1 ), point( x1, y0, z1 ), point( x1, y1, z1 ), point( x0, y1, z1 )
	local u0, u1 = texU, texU + depth
	local u2, u22 = u1 + width, u1 + width * 2
	local u3, u4 = u2 + depth, u2 + depth + width
	local v0, v1, v2 = texV, texV + depth, texV + depth + height
	callback( l1, l0, t0, t1, u1, v0, u2, v1 )
	callback( t2, t3, l3, l2, u2, v1, u22, v0 )
	callback( t0, l0, l3, t3, u0, v1, u1, v2 )
	callback( t1, t0, t3, t2, u1, v1, u2, v2 )
	callback( l1, t1, t2, l2, u2, v1, u3, v2 )
	callback( l0, l1, l2, l3, u3, v1, u4, v2 )
end

local function drawBookBox( origin, axisX, axisY, axisZ, angle, tx, ty, tz,
	x, y, z, width, height, depth, texU, texV, color )
	local function point( px, py, pz )
		return partPoint( origin, axisX, axisY, axisZ, angle, tx, ty, tz, px, py, pz )
	end
	mesh.Begin( MATERIAL_QUADS, 6 )
		forEachBookBoxFace( point, x, y, z, width, height, depth, texU, texV,
			function( a, b, c, d, u0, v0, u1, v1 )
				emitQuad( a, b, c, d, u0, v0, u1, v1, color )
			end )
	mesh.End()
end

local function forEachBookPart( time, open, flip, callback )
	local page1 = math.Clamp( ( ( flip + 0.25 ) % 1 ) * 1.6 - 0.3, 0, 1 )
	local page2 = math.Clamp( ( ( flip + 0.75 ) % 1 ) * 1.6 - 0.3, 0, 1 )
	local openness = ( math.sin( time * 0.02 ) * 0.1 + 1.25 ) * open
	local shift = math.sin( openness )
	callback( math.pi + openness, 0, 0, -1, -6, -5, -0.005, 6, 10, 0.005, 0, 0 )
	callback( -openness, 0, 0, 1, 0, -5, -0.005, 6, 10, 0.005, 16, 0 )
	callback( math.pi * 0.5, 0, 0, 0, -1, -5, 0, 2, 10, 0.005, 12, 0 )
	callback( openness, shift, 0, 0, 0, -4, -0.99, 5, 8, 1, 0, 10 )
	callback( -openness, shift, 0, 0, 0, -4, -0.01, 5, 8, 1, 12, 10 )
	callback( openness - openness * 2 * page1, shift, 0, 0, 0, -4, 0, 5, 8, 0.005, 24, 10 )
	callback( openness - openness * 2 * page2, shift, 0, 0, 0, -4, 0, 5, 8, 0.005, 24, 10 )
end

local function rotateBookX( x, y, z, angle )
	local cosine, sine = math.cos( angle ), math.sin( angle )
	return x, y * cosine - z * sine, y * sine + z * cosine
end

local function rotateBookY( x, y, z, angle )
	local cosine, sine = math.cos( angle ), math.sin( angle )
	return x * cosine + z * sine, y, -x * sine + z * cosine
end


local function projectGuiBookPoint( rawX, rawY, rawZ, left, top, open, scale )
	local x, y, z = rawX / 16, rawY / 16, rawZ / 16
	-- Reverse application order of GuiBookModelRenderer's PoseStack calls.
	x, y, z = rotateBookX( x, y, z, math.pi )
	x, y, z = rotateBookY( x, y, z, math.rad( -( 1 - open ) * 90 - 90 ) )
	x = x + ( 1 - open ) * 0.2
	y = y + ( 1 - open ) * 0.1
	z = z + ( 1 - open ) * 0.25
	x, y, z = rotateBookX( x, y, z, math.rad( 25 ) )
	x, y, z = rotateBookY( x, y, z, math.pi )
	return {
		x = left + 19 * scale + x * 40 * scale,
		y = top + 17 * scale + y * 40 * scale,
		z = z,
	}
end

local function interpolateBookVertex( from, to, fraction )
	return {
		x = Lerp( fraction, from.x, to.x ), y = Lerp( fraction, from.y, to.y ),
		z = Lerp( fraction, from.z, to.z ), u = Lerp( fraction, from.u, to.u ),
		v = Lerp( fraction, from.v, to.v ),
	}
end

local function clipBookPolygonEdge( vertices, axis, boundary, keepGreater )
	if #vertices == 0 then return vertices end
	local clipped = {}
	local previous = vertices[#vertices]
	local previousInside = keepGreater and previous[axis] >= boundary
	if not keepGreater then previousInside = previous[axis] <= boundary end
	for _, current in ipairs( vertices ) do
		local currentInside = keepGreater and current[axis] >= boundary
		if not keepGreater then currentInside = current[axis] <= boundary end
		if currentInside ~= previousInside then
			local span = current[axis] - previous[axis]
			local fraction = span == 0 and 0 or ( boundary - previous[axis] ) / span
			clipped[#clipped + 1] = interpolateBookVertex( previous, current, fraction )
		end
		if currentInside then clipped[#clipped + 1] = current end
		previous, previousInside = current, currentInside
	end
	return clipped
end

local function clipBookPolygon( vertices, left, top, right, bottom )
	vertices = clipBookPolygonEdge( vertices, "x", left, true )
	vertices = clipBookPolygonEdge( vertices, "x", right, false )
	vertices = clipBookPolygonEdge( vertices, "y", top, true )
	return clipBookPolygonEdge( vertices, "y", bottom, false )
end

drawEnchantingBook2D = function( left, top, open, flip, scale )
	scale = math.max( 1, math.floor( tonumber( scale ) or 1 ) )
	left, top = math.floor( tonumber( left ) or 0 ), math.floor( tonumber( top ) or 0 )
	open = math.Clamp( tonumber( open ) or 0, 0, 1 )
	flip = tonumber( flip ) or 0
	local faces = {}
	forEachBookPart( 0, open, flip, function( angle, tx, ty, tz,
		x, y, z, width, height, depth, texU, texV )
		local function point( px, py, pz )
			local rawX, rawY, rawZ = rotatedPartPoint( angle, tx, ty, tz, px, py, pz )
			return projectGuiBookPoint( rawX, rawY, rawZ, left, top, open, scale )
		end
		forEachBookBoxFace( point, x, y, z, width, height, depth, texU, texV,
			function( a, b, c, d, u0, v0, u1, v1 )
				faces[#faces + 1] = {
					depth = ( a.z + b.z + c.z + d.z ) * 0.25,
					vertices = {
						{ x = a.x, y = a.y, z = a.z, u = u1 / 64, v = v0 / 32 },
						{ x = b.x, y = b.y, z = b.z, u = u0 / 64, v = v0 / 32 },
						{ x = c.x, y = c.y, z = c.z, u = u0 / 64, v = v1 / 32 },
						{ x = d.x, y = d.y, z = d.z, u = u1 / 64, v = v1 / 32 },
					},
				}
			end )
	end )
	-- The PIP renderer uses an orthographic depth buffer. Painter ordering gives
	-- the same stable result in Derma without leaking a render target or depth
	-- state into the rest of the inventory screen.
	table.sort( faces, function( first, second ) return first.depth > second.depth end )
	local pushedMin, pushedMag = false, false
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ); pushedMin = true end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ); pushedMag = true end
	surface.SetMaterial( BOOK_GUI_MATERIAL )
	surface.SetDrawColor( 255, 255, 255, 255 )
	local right, bottom = left + 38 * scale, top + 31 * scale
	for _, face in ipairs( faces ) do
		local polygon = clipBookPolygon( face.vertices, left, top, right, bottom )
		if #polygon >= 3 then surface.DrawPoly( polygon ) end
	end
	if pushedMag and render.PopFilterMag then render.PopFilterMag() end
	if pushedMin and render.PopFilterMin then render.PopFilterMin() end
	return true
end

local function entryColor( entry, center )
	local now = CurTime()
	if not entry.lightColor or now >= entry.nextLightAt then
		local r, g, b = 1, 1, 1
		if type( Light.SampleRGB ) == "function" then r, g, b = Light.SampleRGB( center, 1 ) end
		entry.lightColor = Color(
			math.Clamp( math.floor( r * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( g * 255 + 0.5 ), 0, 255 ),
			math.Clamp( math.floor( b * 255 + 0.5 ), 0, 255 ), 255
		)
		entry.nextLightAt = now + 0.1
	end
	return entry.lightColor
end

local function lerpAngle( fraction, from, to )
	return from + wrapAngle( to - from ) * fraction
end

local function drawBook( entry, partialTick, renderCenter, worldCenter )
	local open = Lerp( partialTick, entry.oOpen, entry.open )
	local flip = Lerp( partialTick, entry.oFlip, entry.flip )
	local time = entry.time + partialTick
	local rotation = lerpAngle( partialTick, entry.oRot, entry.rot )
	local direction = Vector( math.cos( rotation ), math.sin( rotation ), 0 )
	local perpendicular = Vector( -direction.y, direction.x, 0 )
	local tilt = math.rad( 80 )
	local axisX = direction * math.cos( tilt ) + UP * math.sin( tilt )
	local axisY = -direction * math.sin( tilt ) + UP * math.cos( tilt )
	local axisZ = perpendicular
	local origin = renderCenter + UP * ( BS * ( 0.35 + math.sin( time * 0.1 ) * 0.01 ) )
	local color = entryColor( entry, worldCenter )
	render.SetMaterial( BOOK_MATERIAL )
	-- BookModel.createBodyLayer / setupAnim from Java 26.2.
	forEachBookPart( time, open, flip, function( angle, tx, ty, tz,
		x, y, z, width, height, depth, texU, texV )
		drawBookBox( origin, axisX, axisY, axisZ, angle, tx, ty, tz,
			x, y, z, width, height, depth, texU, texV, color )
	end )
end

hook.Add( "Think", "mc_enchanting_table_book_animation", function()
	local now = CurTime()
	if RenderEntriesDirty and now >= NextRebuildAttempt then
		RenderEntriesDirty = rebuildEntries() ~= true
		NextRebuildAttempt = now + ( RenderEntriesDirty and 1 or 0.25 )
	end
	local steps = 0
	while now - LastAnimationTick >= TICK_SECONDS and steps < 4 do
		LastAnimationTick = LastAnimationTick + TICK_SECONDS
		for _, entry in pairs( Entries ) do tickBook( entry ) end
		tickEnchantParticles()
		runEnchantingAmbientSamples()
		steps = steps + 1
	end
	if now - LastAnimationTick > 0.25 then LastAnimationTick = now end
end )

hook.Add( "PostDrawOpaqueRenderables", "mc_enchanting_table_books", function( drawingDepth, drawingSkybox, drawing3DSkybox )
	if drawingDepth or drawingSkybox or drawing3DSkybox then return end
	local eye = EyePos()
	local partialTick = math.Clamp( ( CurTime() - LastAnimationTick ) / TICK_SECONDS, 0, 1 )
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	for key, entry in pairs( Entries ) do
		local renderCenter = type( Coords.CellRenderCenter ) == "function"
			and Coords.CellRenderCenter( entry.bx, entry.by, entry.bz ) or nil
		if renderCenter and eye:DistToSqr( renderCenter ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = type( World.GetBlockState ) == "function"
				and World.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
			if not isEnchantingTableState( stateId ) then
				removeEntry( key )
			else
				local worldCenter = type( Coords.CellCenter ) == "function"
					and Coords.CellCenter( entry.bx, entry.by, entry.bz ) or nil
				if worldCenter then drawBook( entry, partialTick, renderCenter, worldCenter ) end
			end
		end
	end
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )

hook.Add( "PostDrawTranslucentRenderables", "mc_enchanting_table_particles", function( drawingDepth, drawingSkybox, drawing3DSkybox )
	if drawingDepth or drawingSkybox or drawing3DSkybox then return end
	local partialTick = math.Clamp( ( CurTime() - LastAnimationTick ) / TICK_SECONDS, 0, 1 )
	if render.PushFilterMin then render.PushFilterMin( TEXFILTER.POINT ) end
	if render.PushFilterMag then render.PushFilterMag( TEXFILTER.POINT ) end
	drawEnchantParticles( partialTick, EyePos() )
	if render.PopFilterMag then render.PopFilterMag() end
	if render.PopFilterMin then render.PopFilterMin() end
end )
