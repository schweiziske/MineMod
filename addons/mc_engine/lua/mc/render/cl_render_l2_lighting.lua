-- Java 26.2-pre-4 quad lighting. Inputs are independent state properties and
-- raw light levels in block coordinates, never Source/render-space positions.
MC = MC or {}
local V = {}
MC.RenderL2Lighting = V

local floor, ceil, min, max = math.floor, math.ceil, math.min, math.max
local frexp, ldexp = math.frexp, math.ldexp
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift
local FACES = MC.RenderMeshConstants.FACES

-- Java float intermediates are observable when light/shade bytes truncate.
local function float32( value )
	if value == 0 then return 0 end
	local sign = value < 0 and -1 or 1
	local mantissa, exponent = frexp( value * sign )
	local shift = max( exponent - 24, -149 )
	local scaled = ldexp( mantissa, exponent - shift )
	local rounded = floor( scaled )
	local fraction = scaled - rounded
	if fraction > 0.5 or ( fraction == 0.5 and rounded % 2 ~= 0 ) then rounded = rounded + 1 end
	return sign * ldexp( rounded, shift )
end

local function sum4( a, b, c, d )
	return float32( float32( float32( a + b ) + c ) + d )
end

local function int( value )
	if value >= 2147483647 then return 2147483647 end
	if value <= -2147483648 then return -2147483648 end
	return value < 0 and ceil( value ) or floor( value )
end

local function pack( block, sky )
	return bor( lshift( block, 4 ), lshift( sky, 20 ) )
end

local function smoothPack( block, sky )
	return bor( band( block, 255 ), lshift( band( sky, 255 ), 16 ) )
end

local function smoothBlend( a, b, c, center )
	if band( rshift( center, 20 ), 15 ) > 2 or band( rshift( center, 4 ), 15 ) > 2 then
		local sky = band( center, 0xFF0000 )
		if a == 0 then a = center elseif band( rshift( a, 20 ), 15 ) == 0 then a = bor( a, sky ) end
		if b == 0 then b = center elseif band( rshift( b, 20 ), 15 ) == 0 then b = bor( b, sky ) end
		if c == 0 then c = center elseif band( rshift( c, 20 ), 15 ) == 0 then c = bor( c, sky ) end
	end
	return band( rshift( a + b + c + center, 2 ), 0xFF00FF )
end

local function weightedBlend( a, b, c, d, wa, wb, wc, wd )
	local block = int( sum4( float32( band( a, 255 ) * wa ), float32( band( b, 255 ) * wb ),
		float32( band( c, 255 ) * wc ), float32( band( d, 255 ) * wd ) ) )
	local sky = int( sum4( float32( band( rshift( a, 16 ), 255 ) * wa ), float32( band( rshift( b, 16 ), 255 ) * wb ),
		float32( band( rshift( c, 16 ), 255 ) * wc ), float32( band( rshift( d, 16 ), 255 ) * wd ) ) )
	return smoothPack( block, sky )
end

local function quadEmission( coords, emission )
	if emission == 0 then return coords end
	-- Quad emission raises both components at whole levels. State emission only
	-- raises block light and independently disables smooth AO.
	return pack( max( band( rshift( coords, 4 ), 15 ), emission ), max( band( rshift( coords, 20 ), 15 ), emission ) )
end

local ADJACENCY = {
	{ { 1, 0, 0 }, { -1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 } },
	{ { -1, 0, 0 }, { 1, 0, 0 }, { 0, -1, 0 }, { 0, 1, 0 } },
	{ { 0, 0, -1 }, { 0, 0, 1 }, { 0, -1, 0 }, { 0, 1, 0 } },
	{ { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 }, { 0, 1, 0 } },
	{ { -1, 0, 0 }, { 1, 0, 0 }, { 0, 0, -1 }, { 0, 0, 1 } },
	{ { 0, 0, 1 }, { 0, 0, -1 }, { 1, 0, 0 }, { -1, 0, 0 } },
}
-- Java tempShade1..4 to FACES order, independent of triangle/UV ordering.
local CORNER_REMAP = {
	{ 3, 2, 1, 4 }, { 1, 4, 3, 2 }, { 2, 1, 4, 3 },
	{ 4, 3, 2, 1 }, { 3, 2, 1, 4 }, { 4, 3, 2, 1 },
}
local PAIR_A, PAIR_B = { 4, 3, 3, 4 }, { 1, 1, 2, 2 }
local SHADE = { 1, 0.5, float32( 0.6 ), float32( 0.6 ), float32( 0.8 ), float32( 0.8 ) }
local QUAD_LOWER, QUAD_UPPER = float32( 0.0001 ), float32( 0.9999 )

local function classifyQuad( face, fullCollision, x1, y1, z1, x2, y2, z2, x3, y3, z3, x4, y4, z4 )
	local x0, y0, z0 = min( x1, x2, x3, x4 ), min( y1, y2, y3, y4 ), min( z1, z2, z3, z4 )
	local x, y, z = max( x1, x2, x3, x4 ), max( y1, y2, y3, y4 ), max( z1, z2, z3, z4 )
	local normalMin, normalMax, a0, a1, b0, b1
	if face == 1 or face == 2 then normalMin, normalMax, a0, a1, b0, b1 = z0, z, x0, x, y0, y
	elseif face == 3 or face == 4 then normalMin, normalMax, a0, a1, b0, b1 = x0, x, y0, y, z0, z
	elseif face == 5 or face == 6 then normalMin, normalMax, a0, a1, b0, b1 = y0, y, x0, x, z0, z
	else return MC.Fault( "l2_quad_face", "invalid face %s", tostring( face ) ) end
	local lower, upper = QUAD_LOWER, QUAD_UPPER
	local boundary = face % 2 == 1 and normalMax > upper or face % 2 == 0 and normalMin < lower
	local cubic = normalMin == normalMax and ( boundary or fullCollision == true )
	local partial = a0 >= lower or b0 >= lower or a1 <= upper or b1 <= upper
	return cubic, partial, x0, y0, z0, x, y, z, normalMin == normalMax
end

local function lightCoords( cell, state )
	state = state or cell
	if state.emissive then return 0xF000F0 end
	return pack( max( cell.block, state.emission ), cell.sky )
end

local function validInteger( value, limit )
	return type( value ) == "number" and value >= 0 and value <= limit and value == floor( value )
end

local Lighter = {}
Lighter.__index = Lighter

function Lighter:Cell( x, y, z )
	-- The snapshot validates new cells and reports read failures before caching.
	return self.readCell( x, y, z )
end

function Lighter:SampleFace( bx, by, bz, face, cubic )
	local adjacency = ADJACENCY[face]
	local off = FACES[face].off
	local nx, ny, nz = off[1], off[2], off[3]
	local baseX, baseY, baseZ = bx, by, bz
	if cubic then baseX, baseY, baseZ = bx + nx, by + ny, bz + nz end
	local sides, open = self.sides, self.open
	for i = 1, 4 do
		local d = adjacency[i]
		local x, y, z = baseX + d[1], baseY + d[2], baseZ + d[3]
		local side, test = self:Cell( x, y, z ), self:Cell( x + nx, y + ny, z + nz )
		if not side or not test then return false end
		sides[i] = side
		open[i] = not test.viewBlocking or test.dampening == 0
	end
	local current, nextCell = self:Cell( bx, by, bz ), self:Cell( bx + nx, by + ny, bz + nz )
	if not current or not nextCell then return false end
	local center = current
	if cubic or not nextCell.solidRender then center = nextCell end
	local centerLight = lightCoords( center )
	local centerShade = float32( ( cubic and nextCell or current ).shade )
	for i = 1, 4 do
		local a, b = PAIR_A[i], PAIR_B[i]
		local diagonal = sides[1]
		if open[a] or open[b] then
			local da, db = adjacency[a], adjacency[b]
			diagonal = self:Cell( baseX + da[1] + db[1], baseY + da[2] + db[2], baseZ + da[3] + db[3] )
			if not diagonal then return false end
		end
		self.coords[i] = smoothBlend( lightCoords( sides[a] ), lightCoords( sides[b] ), lightCoords( diagonal ), centerLight )
		self.ao[i] = float32( sum4( float32( sides[a].shade ), float32( sides[b].shade ), float32( diagonal.shade ), centerShade ) * 0.25 )
	end
	return true
end

-- Validate and round immutable template geometry once, not per placed quad.
-- cornerOrder maps source vertices to FACES order, including rotated models.
function V.BakeQuad( face, corners, options )
	options = options or {}
	if not MC.Check( FACES[face] ~= nil and type( corners ) == "table" and #corners == 4,
		"l2_quad_geometry", "expected a face and four model-space corners" ) then return nil end
	local xyz = {}
	for i = 1, 4 do
		local c = corners[i]
		if not MC.Check( type( c ) == "table", "l2_quad_corner", "invalid corner %s", i ) then return nil end
		for axis = 1, 3 do
			local value = c[axis]
			if not MC.Check( type( value ) == "number" and value == value and math.abs( value ) < 32768,
				"l2_quad_coordinate", "invalid model coordinate at corner %s axis %s", i, axis ) then return nil end
			xyz[( i - 1 ) * 3 + axis] = float32( value )
		end
	end
	local cubic, partial, x0, y0, z0, x1, y1, z1, planar = classifyQuad( face, false, unpack( xyz, 1, 12 ) )
	local directionShade = options.shade == false and 1 or SHADE[face]
	local emission = options.quadEmission or 0
	if not MC.Check( validInteger( emission, 15 ), "l2_quad_emission", "invalid quad emission %s", tostring( emission ) ) then return nil end
	local order = options.cornerOrder
	if order ~= nil and not MC.Check( type( order ) == "table" and #order == 4,
		"l2_quad_order", "cornerOrder must be a permutation of 1..4" ) then return nil end
	local mask = 0
	for i = 1, 4 do
		local index = i
		if order ~= nil then index = order[i] end
		if not MC.Check( validInteger( index, 4 ) and index > 0 and band( mask, lshift( 1, index ) ) == 0,
			"l2_quad_order", "cornerOrder must be a permutation of 1..4" ) then return nil end
		mask = bor( mask, lshift( 1, index ) )
	end
	local lightFace = options.cullFace
	if lightFace ~= nil and not MC.Check( FACES[lightFace] ~= nil,
		"l2_quad_cull_face", "invalid cull face %s", tostring( lightFace ) ) then return nil end
	local baked = {
		face = face, cubic = cubic, planar = planar, partial = partial,
		smooth = options.ambientOcclusion ~= false and options.modelAO ~= false,
		directionShade = directionShade, flatShade = floor( float32( directionShade * 255 ) ),
		emission = emission, lightFace = lightFace,
	}
	local remap = CORNER_REMAP[face]
	if partial then
		local a0, a1, b0, b1, axisA, axisB
		if face <= 2 then a0, a1, b0, b1, axisA, axisB = x0, x1, y0, y1, 1, 2
		elseif face <= 4 then a0, a1, b0, b1, axisA, axisB = y0, y1, z0, z1, 2, 3
		else a0, a1, b0, b1, axisA, axisB = x0, x1, z0, z1, 1, 3 end
		local canonical = FACES[face].c
		baked.weights = {}
		for vertex = 1, 4 do
			local c, weights = canonical[order and order[vertex] or vertex], {}
			local a, b = c[axisA] == 0 and a0 or a1, c[axisB] == 0 and b0 or b1
			for i = 1, 4 do
				local corner = canonical[remap[i]]
				local wa = corner[axisA] == 0 and float32( 1 - a ) or a
				local wb = corner[axisB] == 0 and float32( 1 - b ) or b
				weights[i] = float32( wa * wb )
			end
			baked.weights[vertex] = weights
		end
	else
		baked.indices = {}
		for vertex = 1, 4 do
			local target = order and order[vertex] or vertex
			for i = 1, 4 do if remap[i] == target then baked.indices[vertex] = i break end end
		end
	end
	return baked
end

function Lighter:PrepareBaked( bx, by, bz, baked, output )
	local state = self:Cell( bx, by, bz )
	if not state then return nil end
	local face = baked.face
	local cubic = baked.cubic or baked.planar and state.fullCollision
	local smooth = baked.smooth and state.emission == 0
	local emission, directionShade = baked.emission, baked.directionShade
	local resultLight, resultShade = self.resultLight, self.resultShade
	if not smooth then
		local lightFace = baked.lightFace
		if lightFace == nil and cubic then lightFace = face end
		local cell = state
		if lightFace ~= nil then
			local d = FACES[lightFace].off
			cell = self:Cell( bx + d[1], by + d[2], bz + d[3] )
			if not cell then return nil end
		end
		local light = quadEmission( lightCoords( cell, state ), emission )
		for i = 1, 4 do resultLight[i], resultShade[i] = light, baked.flatShade end
	else
		if not self:SampleFace( bx, by, bz, face, cubic ) then return nil end
		for vertex = 1, 4 do
			local coords, ao
			if baked.partial then
				local w = baked.weights[vertex]
				coords = weightedBlend( self.coords[1], self.coords[2], self.coords[3], self.coords[4], w[1], w[2], w[3], w[4] )
				ao = max( 0, min( 1, sum4( float32( self.ao[1] * w[1] ), float32( self.ao[2] * w[2] ),
					float32( self.ao[3] * w[3] ), float32( self.ao[4] * w[4] ) ) ) )
			else
				local i = baked.indices[vertex]
				coords, ao = self.coords[i], self.ao[i]
			end
			resultLight[vertex] = quadEmission( coords, emission )
			local gray = floor( float32( ao * 255 ) )
			resultShade[vertex] = int( float32( gray * directionShade ) )
		end
	end
	-- Publish only after all samples succeed.
	output = output or { light = {}, shade = {} }
	output.light, output.shade = output.light or {}, output.shade or {}
	for i = 1, 4 do output.light[i], output.shade[i] = resultLight[i], resultShade[i] end
	output.faceCubic, output.facePartial, output.smooth = cubic, baked.partial, smooth
	return output
end

function Lighter:Prepare( bx, by, bz, face, corners, options, output )
	local baked = V.BakeQuad( face, corners, options )
	if not baked then return nil end
	return self:PrepareBaked( bx, by, bz, baked, output )
end

-- readCell returns validated lighting properties, or nil after reporting a fault.
function V.New( readCell )
	if not MC.Check( type( readCell ) == "function", "l2_sample_reader", "expected a neighbourhood reader" ) then return nil end
	return setmetatable( { readCell = readCell, sides = {}, open = {}, coords = {}, ao = {},
		resultLight = {}, resultShade = {} }, Lighter )
end

V.Float32 = float32
V.Pack = pack
V.SmoothBlend = smoothBlend
V.SmoothWeightedBlend = weightedBlend
V.ApplyQuadEmission = quadEmission
