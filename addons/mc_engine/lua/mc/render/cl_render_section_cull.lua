-- Immutable scalar bounds, prepared at mesh publication, never per draw.
MC = MC or {}
local S = {}
MC.RenderSectionCull = S
local floor, min, max = math.floor, math.min, math.max
local SIZE = MC.RENDER_SECTION_SIZE or 16
local XY = math.ceil( MC.CS / SIZE )

MC.MeshOcclusionCull = MC.MeshOcclusionCull or CreateClientConVar( "mc_mesh_occlusion_cull", "1", true, false,
	"Conservative render-section connectivity culling; unknown/transparent space stays open" )
MC.MeshDirectionalCull = MC.MeshDirectionalCull or CreateClientConVar( "mc_mesh_directional_cull", "0", true, false,
	"Experimental six-direction opaque cube meshes; may increase DX9 draw calls; changing this rebuilds meshes" )
MC.MeshDirectionalMinBlocks = MC.MeshDirectionalMinBlocks or CreateClientConVar( "mc_mesh_directional_min_blocks", "64", true, false,
	"Only split directions in render sections containing at least this many blocks", 0, SIZE ^ 3 )

function S.Bounds( x0, y0, z0, x1, y1, z1 )
	return { minX = x0, minY = y0, minZ = z0, maxX = x1, maxY = y1, maxZ = z1,
		x = ( x0 + x1 ) * 0.5, y = ( y0 + y1 ) * 0.5, z = ( z0 + z1 ) * 0.5,
		hx = ( x1 - x0 ) * 0.5, hy = ( y1 - y0 ) * 0.5, hz = ( z1 - z0 ) * 0.5,
		radius = math.sqrt( ( x1 - x0 ) ^ 2 + ( y1 - y0 ) ^ 2 + ( z1 - z0 ) ^ 2 ) * 0.5 }
end

function S.VertexBounds( verts )
	local x0, y0, z0 = verts[1], verts[2], verts[3]
	local x1, y1, z1 = x0, y0, z0
	for o = MC.RenderVertexBuffer.STRIDE, ( verts.count - 1 ) * MC.RenderVertexBuffer.STRIDE, MC.RenderVertexBuffer.STRIDE do
		local x, y, z = verts[o + 1], verts[o + 2], verts[o + 3]
		x0, y0, z0 = min( x0, x ), min( y0, y ), min( z0, z )
		x1, y1, z1 = max( x1, x ), max( y1, y ), max( z1, z )
	end
	return S.Bounds( x0, y0, z0, x1, y1, z1 )
end

-- Only the unpublished aggregate belongs to this caller; source bounds stay
-- read-only. One table per pass list, not one temporary table per mesh part.
function S.Extend( a, b )
	if not a then return S.Bounds( b.minX, b.minY, b.minZ, b.maxX, b.maxY, b.maxZ ) end
	a.minX, a.minY, a.minZ = min( a.minX, b.minX ), min( a.minY, b.minY ), min( a.minZ, b.minZ )
	a.maxX, a.maxY, a.maxZ = max( a.maxX, b.maxX ), max( a.maxY, b.maxY ), max( a.maxZ, b.maxZ )
	a.x, a.y, a.z = ( a.minX + a.maxX ) * 0.5, ( a.minY + a.maxY ) * 0.5, ( a.minZ + a.maxZ ) * 0.5
	a.hx, a.hy, a.hz = ( a.maxX - a.minX ) * 0.5, ( a.maxY - a.minY ) * 0.5, ( a.maxZ - a.minZ ) * 0.5
	a.radius = math.sqrt( a.hx * a.hx + a.hy * a.hy + a.hz * a.hz )
	return a
end

function S.SectionBounds( index, size, opaque, translucent )
	local zero = index - 1
	local x, y, z = ( zero % XY ) * SIZE * size, ( floor( zero / XY ) % XY ) * SIZE * size,
		floor( zero / ( XY * XY ) ) * SIZE * size
	local edge = SIZE * size
	local bounds = S.Bounds( x, y, z, x + edge, y + edge, z + edge )
	for pass = 1, 2 do
		local list = pass == 1 and opaque or translucent
		for i = 1, #list do S.Extend( bounds, list[i].bounds ) end
	end
	-- Protruding models are frustum-tested with expanded bounds but must not be
	-- hidden just because their owning grid section is behind a closed portal.
	-- Source vertices use float32. Include that exact rounding of the grid
	-- boundary, without a world-size-dependent epsilon that hides real models.
	local engineMin, engineMax = Vector( x, y, z ), Vector( x + edge, y + edge, z + edge )
	bounds.protrudes = bounds.minX < min( x, engineMin.x ) or bounds.minY < min( y, engineMin.y )
		or bounds.minZ < min( z, engineMin.z ) or bounds.maxX > max( x + edge, engineMax.x )
		or bounds.maxY > max( y + edge, engineMax.y ) or bounds.maxZ > max( z + edge, engineMax.z )
	return bounds
end

-- Plane positions, not camera orientation. Every face in a positive group
-- lies on or beyond its minimum; negative groups use their maximum instead.
function S.DirectionVisible( direction, bounds, x, y, z, margin )
	if direction == 1 then return z >= bounds.minZ - margin end
	if direction == 2 then return z <= bounds.maxZ + margin end
	if direction == 3 then return x >= bounds.minX - margin end
	if direction == 4 then return x <= bounds.maxX + margin end
	if direction == 5 then return y >= bounds.minY - margin end
	return y <= bounds.maxY + margin
end

local function rebuildDirections()
	-- One explicit settings change, not a frame-loop scan. The normal queue
	-- preserves old geometry until each replacement has uploaded successfully.
	for key, sections in pairs( MC.MeshSections ) do
		for index in pairs( sections ) do
			MC.ClearSectionBlockEmitCache( key, index )
			MC.RequestRenderSectionGeometry( key, index, true )
		end
	end
end
if cvars and cvars.AddChangeCallback then
	cvars.AddChangeCallback( "mc_mesh_directional_cull", rebuildDirections, "mc_section_directions" )
	cvars.AddChangeCallback( "mc_mesh_directional_min_blocks", rebuildDirections, "mc_section_directions_min" )
end
