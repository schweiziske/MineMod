-- Scalar light-space bounds and two texel-snapped orthographic windows.
MC = MC or {}
local M = {}
MC.RenderShadowMath = M
local floor, sqrt, abs = math.floor, math.sqrt, math.abs
local sin, cos, tan, max, min = math.sin, math.cos, math.tan, math.max, math.min
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

function M.SameCascade( a, b, index )
	if not a or not b or a.sx ~= b.sx or a.sy ~= b.sy or a.sz ~= b.sz
		or a.resolution ~= b.resolution or a.radius ~= b.radius or a.depth ~= b.depth then return false end
	if index == 1 then return a.nearR == b.nearR and a.nearU == b.nearU end
	return a.farR == b.farR and a.farU == b.farU
end

function M.Same( a, b )
	return M.SameCascade( a, b, 1 ) and M.SameCascade( a, b, 2 )
end

local function finite( value )
	return type( value ) == "number" and value == value and abs( value ) < math.huge
end

-- Read the actual render view, not the player's aim. Unsupported/missing
-- projection metadata requests the complete light volume. Validation and
-- trigonometry stay here; the caster loops only consume scalar planes.
function M.ReadCamera( out, x, y, z, view )
	out.x, out.y, out.z, out.enabled = x, y, z, false
	if not view or view.ortho or view.offcenter then return end
	local angle, fov = view.angles, view.fov
	if not angle or not finite( angle.p ) or not finite( angle.y ) or not finite( angle.r )
		or not finite( fov ) or fov <= 0 or fov >= 179 then return end
	local aspect = view.aspectratio
	if not finite( aspect ) or aspect <= 0 then
		local width, height = view.width or view.w, view.height or view.h
		if not finite( width ) or not finite( height ) or width <= 0 or height <= 0 then return end
		aspect = width / height
	end
	if out.pitch ~= angle.p or out.yaw ~= angle.y or out.roll ~= angle.r or out.fov ~= fov or out.aspect ~= aspect then
		local radians = math.pi / 180
		local sp, cp = sin( angle.p * radians ), cos( angle.p * radians )
		local sy, cy = sin( angle.y * radians ), cos( angle.y * radians )
		local sr, cr = sin( angle.r * radians ), cos( angle.r * radians )
		out.fx, out.fy, out.fz = cp * cy, cp * sy, -sp
		out.rx, out.ry, out.rz = -sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp
		out.ux, out.uy, out.uz = cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp
		-- Conservatively cover both Source's 4:3-basis FOV and a view whose
		-- horizontal FOV has already been adjusted, including portrait targets.
		out.tanY = tan( fov * radians * 0.5 ) * max( 0.75, 1 / aspect )
		out.tanX = out.tanY * aspect
		out.pitch, out.yaw, out.roll, out.fov, out.aspect = angle.p, angle.y, angle.r, fov, aspect
	end
	out.enabled = true
end

local function newCasterVolume()
	local out = { planes = {}, cone = {}, vertices = {}, count = 0, enabled = false }
	for i = 1, 91 do out.planes[i] = 0 end -- five faces plus eight silhouette edges
	for i = 1, 12 do out.cone[i] = 0 end
	for i = 1, 15 do out.vertices[i] = 0 end
	return out
end

local function addCasterPlane( out, nx, ny, nz, d, padding )
	local p, i = out.planes, out.count * 7 + 1
	p[i], p[i + 1], p[i + 2], p[i + 3] = nx, ny, nz, d + padding
	p[i + 4], p[i + 5], p[i + 6] = abs( nx ), abs( ny ), abs( nz )
	out.count = out.count + 1
end

-- A cached map has finite spatial coverage even when its caster cone is off.
-- Keep a quarter-radius margin around the new eye before allowing throttling;
-- a remote camera/teleport must not sample a map centered on another view.
-- Within that volume, cone containment covers subtexel motion and view turns.
function M.CoversCamera( view, camera )
	local dx, dy, dz = camera.x - view.x, camera.y - view.y, camera.z - view.z
	local margin = view.radius * 0.75
	if abs( dx * view.rx + dy * view.ry + dz * view.rz ) > margin
		or abs( dx * view.ux + dy * view.uy + dz * view.uz ) > margin then return false end
	local depth = dx * view.fx + dy * view.fy + dz * view.fz
	if depth < view.zfar * 0.25 or depth > view.zfar * 0.75 then return false end
	local cull = view.cull
	if not cull or not cull.enabled then return true end
	if not camera.enabled then return false end
	local x, y, z = camera.x - cull.x, camera.y - cull.y, camera.z - cull.z
	local planes = cull.cone
	for i = 1, 12, 3 do
		local nx, ny, nz = planes[i], planes[i + 1], planes[i + 2]
		if nx * x + ny * y + nz * z < 0 then return false end
		local forward = nx * camera.fx + ny * camera.fy + nz * camera.fz
		local width = abs( nx * camera.rx + ny * camera.ry + nz * camera.rz ) * camera.tanX
		local height = abs( nx * camera.ux + ny * camera.uy + nz * camera.uz ) * camera.tanY
		if forward < width + height then return false end
	end
	return true
end

local edgeA, edgeB = { 1, 1, 1, 1, 2, 3, 4, 5 }, { 2, 3, 4, 5, 3, 4, 5, 2 }

-- Directional caster volume: sweep a finite receiver pyramid toward the sun.
-- Retain supporting faces and add supporting planes through silhouette edges.
-- Source study and applicability: docs/minecraft-shadow-optimization-research-2026-09-19.md.
-- This is for direct shadows; a voxel/GI pass needs its own coverage contract.
function M.ConfigureCasters( view, camera, blockSize, resolution )
	local out = view.cull
	if not out then out = newCasterVolume() view.cull = out end
	out.enabled, out.count, out.empty = camera.enabled, 0, false
	if not camera.enabled then return end
	local texel = 2 * view.radius / resolution
	local guard = blockSize * 2 + texel * 2
	local padding = blockSize * 1.5 + texel * 2 -- maximum 3 * receiver bias plus PCF footprint
	out.x, out.y, out.z = camera.x - camera.fx * guard, camera.y - camera.fy * guard, camera.z - camera.fz * guard
	out.ox, out.oy, out.oz = out.x - view.x, out.y - view.y, out.z - view.z
	local cone, vertices = out.cone, out.vertices
	local tanX, tanY = camera.tanX * 1.05, camera.tanY * 1.05
	for plane = 1, 4 do
		local x, y, z, tangent, sign = camera.rx, camera.ry, camera.rz, tanX, 1
		if plane >= 3 then x, y, z, tangent = camera.ux, camera.uy, camera.uz, tanY end
		if plane % 2 == 0 then sign = -1 end
		x, y, z = camera.fx * tangent + x * sign, camera.fy * tangent + y * sign, camera.fz * tangent + z * sign
		local inverse = 1 / sqrt( x * x + y * y + z * z )
		local i = ( plane - 1 ) * 3 + 1
		cone[i], cone[i + 1], cone[i + 2] = x * inverse, y * inverse, z * inverse
	end
	-- Bound receiver depth by the entire cascade OBB, not an assumed camera far
	-- distance. Every visible receiver in the tile is inside this pyramid cap.
	local halfDepth, centerDepth = ( view.zfar - view.znear ) * 0.5, ( view.zfar + view.znear ) * 0.5
	local right = camera.fx * view.rx + camera.fy * view.ry + camera.fz * view.rz
	local up = camera.fx * view.ux + camera.fy * view.uy + camera.fz * view.uz
	local forward = camera.fx * view.fx + camera.fy * view.fy + camera.fz * view.fz
	local far = -camera.fx * out.ox - camera.fy * out.oy - camera.fz * out.oz + centerDepth * forward
		+ view.radius * ( abs( right ) + abs( up ) ) + halfDepth * abs( forward ) + padding
	if far <= 0 then out.empty = true return end
	vertices[1], vertices[2], vertices[3] = 0, 0, 0
	for corner = 1, 4 do
		local r, u = tanX * far, tanY * far
		if corner == 2 or corner == 3 then r = -r end
		if corner >= 3 then u = -u end
		local i = corner * 3 + 1
		vertices[i] = camera.fx * far + camera.rx * r + camera.ux * u
		vertices[i + 1] = camera.fy * far + camera.ry * r + camera.uy * u
		vertices[i + 2] = camera.fz * far + camera.rz * r + camera.uz * u
	end
	local sx, sy, sz = -view.fx, -view.fy, -view.fz
	for i = 1, 12, 3 do
		local nx, ny, nz = cone[i], cone[i + 1], cone[i + 2]
		if nx * sx + ny * sy + nz * sz >= 0 then addCasterPlane( out, nx, ny, nz, 0, padding ) end
	end
	if camera.fx * sx + camera.fy * sy + camera.fz * sz <= 0 then
		addCasterPlane( out, -camera.fx, -camera.fy, -camera.fz, far, padding )
	end
	local epsilon = far * 1e-9
	for edge = 1, 8 do
		local a, b = ( edgeA[edge] - 1 ) * 3 + 1, ( edgeB[edge] - 1 ) * 3 + 1
		local x, y, z = vertices[b] - vertices[a], vertices[b + 1] - vertices[a + 1], vertices[b + 2] - vertices[a + 2]
		local nx, ny, nz = y * sz - z * sy, z * sx - x * sz, x * sy - y * sx
		local length = nx * nx + ny * ny + nz * nz
		if length > ( x * x + y * y + z * z ) * 1e-16 then
			local inverse = 1 / sqrt( length )
			nx, ny, nz = nx * inverse, ny * inverse, nz * inverse
			local d = -( nx * vertices[a] + ny * vertices[a + 1] + nz * vertices[a + 2] )
			local low, high = math.huge, -math.huge
			for v = 1, 15, 3 do
				local distance = nx * vertices[v] + ny * vertices[v + 1] + nz * vertices[v + 2] + d
				low, high = min( low, distance ), max( high, distance )
			end
			if low >= -epsilon then addCasterPlane( out, nx, ny, nz, d - min( low, 0 ), padding )
			elseif high <= epsilon then addCasterPlane( out, -nx, -ny, -nz, -d + max( high, 0 ), padding ) end
		end
	end
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
	if f + extent < view.znear or f - extent > view.zfar then return false end
	local cull = view.cull
	if cull and cull.enabled then
		if cull.empty then return false end
		x, y, z = x - cull.ox, y - cull.oy, z - cull.oz
		local planes = cull.planes
		for i = 1, cull.count * 7, 7 do
			if planes[i] * x + planes[i + 1] * y + planes[i + 2] * z + planes[i + 3]
				+ planes[i + 4] * hx + planes[i + 5] * hy + planes[i + 6] * hz < 0 then return false end
		end
	end
	return true
end
