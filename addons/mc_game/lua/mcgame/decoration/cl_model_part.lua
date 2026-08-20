-- Exact ModelPart.Cube face/UV emitter for entity equipment layers.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local M = MC.DecorationRenderer.Mesh

local FACE_ORDER = { "down", "up", "west", "north", "east", "south" }
local FACE_POINTS = {
	down = { 6, 5, 1, 2 }, up = { 3, 4, 8, 7 },
	west = { 1, 5, 8, 4 }, north = { 2, 1, 4, 3 },
	east = { 6, 2, 3, 7 }, south = { 5, 6, 7, 8 },
}

local function point( origin, xAxis, yAxis, zAxis, x, y, z, unit )
	return origin + xAxis * ( x * unit ) + yAxis * ( y * unit ) + zAxis * ( z * unit )
end

local function faceUVs( texU, texV, width, height, depth, textureWidth, textureHeight )
	local u0, u1 = texU, texU + depth
	local u2, u22 = u1 + width, u1 + width + width
	local u3, u4 = u2 + depth, u2 + depth + width
	local v0, v1, v2 = texV, texV + depth, texV + depth + height
	local function uv( a, b, c, d )
		return { c / textureWidth, b / textureHeight,
			a / textureWidth, b / textureHeight,
			a / textureWidth, d / textureHeight,
			c / textureWidth, d / textureHeight }
	end
	return {
		down = uv( u1, v0, u2, v1 ), up = uv( u2, v1, u22, v0 ),
		west = uv( u0, v1, u1, v2 ), north = uv( u1, v1, u2, v2 ),
		east = uv( u2, v1, u3, v2 ), south = uv( u3, v1, u4, v2 ),
	}
end

local function reversePairs( points, uv )
	return { points[4], points[3], points[2], points[1] }, {
		uv[7], uv[8], uv[5], uv[6], uv[3], uv[4], uv[1], uv[2],
	}
end

function M.DrawModelCube( origin, xAxis, yAxis, zAxis, cube, material, color, options )
	if not origin or not cube or not material then return false end
	options = options or {}
	local box = cube.box or {}
	local x, y, z = tonumber( box[1] ) or 0, tonumber( box[2] ) or 0, tonumber( box[3] ) or 0
	local width, height, depth = tonumber( box[4] ) or 0, tonumber( box[5] ) or 0, tonumber( box[6] ) or 0
	local grow = cube.grow or 0
	local growX = tonumber( type( grow ) == "table" and ( grow.x or grow[1] ) or grow ) or 0
	local growY = tonumber( type( grow ) == "table" and ( grow.y or grow[2] ) or grow ) or 0
	local growZ = tonumber( type( grow ) == "table" and ( grow.z or grow[3] ) or grow ) or 0
	local minX, minY, minZ = x - growX, y - growY, z - growZ
	local maxX, maxY, maxZ = x + width + growX, y + height + growY, z + depth + growZ
	if cube.mirror then minX, maxX = maxX, minX end
	local unit = tonumber( options.unit ) or M.BlockSize() / 16
	local points = {
		point( origin, xAxis, yAxis, zAxis, minX, minY, minZ, unit ),
		point( origin, xAxis, yAxis, zAxis, maxX, minY, minZ, unit ),
		point( origin, xAxis, yAxis, zAxis, maxX, maxY, minZ, unit ),
		point( origin, xAxis, yAxis, zAxis, minX, maxY, minZ, unit ),
		point( origin, xAxis, yAxis, zAxis, minX, minY, maxZ, unit ),
		point( origin, xAxis, yAxis, zAxis, maxX, minY, maxZ, unit ),
		point( origin, xAxis, yAxis, zAxis, maxX, maxY, maxZ, unit ),
		point( origin, xAxis, yAxis, zAxis, minX, maxY, maxZ, unit ),
	}
	local tex = cube.uv or { 0, 0 }
	local uvs = faceUVs( tonumber( tex[1] ) or 0, tonumber( tex[2] ) or 0,
		width, height, depth, tonumber( options.textureWidth ) or 64,
		tonumber( options.textureHeight ) or 32 )
	local drawn = false
	for _, face in ipairs( FACE_ORDER ) do
		local indices, polygon, uv = FACE_POINTS[face], {}, uvs[face]
		for index = 1, 4 do polygon[index] = points[indices[index]] end
		if cube.mirror then polygon, uv = reversePairs( polygon, uv ) end
		if options.uvTransform then
			local transformed = {}
			for index = 1, 4 do
				transformed[index * 2 - 1], transformed[index * 2] =
					options.uvTransform( uv[index * 2 - 1], uv[index * 2] )
			end
			uv = transformed
		end
		drawn = M.QuadRaw( polygon, uv, material, color ) or drawn
	end
	return drawn
end
