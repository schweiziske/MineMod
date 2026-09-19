-- Scalar light-space bounds and two texel-snapped orthographic windows.
MC = MC or {}
local M = {}
MC.RenderShadowMath = M
local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local function snap( value, step ) return floor( value / step + 0.5 ) * step end

function M.Configure( out, x, y, z, sx, sy, sz, blockSize, resolution, rangeBlocks )
	local farRadius = blockSize * rangeBlocks
	local nearRadius, farDepth = farRadius * 0.25, farRadius * 4
	local fx, fy, fz = -sx, -sy, -sz
	local horizontal = sqrt( fx * fx + fy * fy )
	local rx, ry = 0, -1
	if horizontal > 0.000001 then rx, ry = fy / horizontal, -fx / horizontal end
	local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
	local r, u = x * rx + y * ry, x * ux + y * uy + z * uz
	local farStep, nearStep = 2 * farRadius / resolution, 2 * nearRadius / resolution
	local depth = snap( x * fx + y * fy + z * fz, farStep ) - farRadius * 2
	local nearR, nearU = snap( r, nearStep ), snap( u, nearStep )
	local farR, farU = snap( r, farStep ), snap( u, farStep )
	out.sx, out.sy, out.sz, out.resolution, out.radius = sx, sy, sz, resolution, farRadius
	out.nearR, out.nearU, out.farR, out.farU, out.depth = nearR, nearU, farR, farU, depth
	local views = out.views
	if not views then views = { {}, {} } out.views = views end
	for index = 1, 2 do
		local view = views[index]
		local radius, centerR, centerU = nearRadius, nearR, nearU
		if index == 2 then radius, centerR, centerU = farRadius, farR, farU end
		view.rx, view.ry, view.rz, view.ux, view.uy, view.uz = rx, ry, 0, ux, uy, uz
		view.fx, view.fy, view.fz = fx, fy, fz
		view.arx, view.ary, view.arz = abs( rx ), abs( ry ), 0
		view.aux, view.auy, view.auz = abs( ux ), abs( uy ), abs( uz )
		view.afx, view.afy, view.afz = abs( fx ), abs( fy ), abs( fz )
		view.x, view.y, view.z = rx * centerR + ux * centerU + fx * depth,
			ry * centerR + uy * centerU + fy * depth, uz * centerU + fz * depth
		view.radius, view.znear, view.zfar = radius, 0.5, farDepth
	end
	local values = out.values
	if not values then values = {} out.values = values end
	local inverse = 1 / ( 2 * nearRadius )
	values[1], values[2], values[3], values[4] = rx * inverse, ry * inverse, 0, 0.5 - nearR * inverse
	values[5], values[6], values[7], values[8] = -ux * inverse, -uy * inverse, -uz * inverse, 0.5 + nearU * inverse
	values[9], values[10], values[11], values[12] = fx / farDepth, fy / farDepth, fz / farDepth, -depth / farDepth
	values[13], values[14], values[15], values[16] = 0.25,
		0.375 + ( nearR - farR ) / ( 2 * farRadius ), 0.375 - ( nearU - farU ) / ( 2 * farRadius ), 1 / resolution
	return out
end

function M.Same( a, b )
	return a and b and a.sx == b.sx and a.sy == b.sy and a.sz == b.sz
		and a.resolution == b.resolution and a.radius == b.radius and a.depth == b.depth
		and a.nearR == b.nearR and a.nearU == b.nearU and a.farR == b.farR and a.farU == b.farU
end

function M.Intersects( bounds, x, y, z, view )
	if not bounds then return true end -- Retained geometry from an older Lua load.
	x, y, z = x + bounds.x - view.x, y + bounds.y - view.y, z + bounds.z - view.z
	local hx, hy, hz = bounds.hx, bounds.hy, bounds.hz
	local r = x * view.rx + y * view.ry + z * view.rz
	if abs( r ) > view.radius + hx * view.arx + hy * view.ary + hz * view.arz then return false end
	local u = x * view.ux + y * view.uy + z * view.uz
	if abs( u ) > view.radius + hx * view.aux + hy * view.auy + hz * view.auz then return false end
	local f = x * view.fx + y * view.fy + z * view.fz
	local extent = hx * view.afx + hy * view.afy + hz * view.afz
	return f + extent >= view.znear and f - extent <= view.zfar
end
