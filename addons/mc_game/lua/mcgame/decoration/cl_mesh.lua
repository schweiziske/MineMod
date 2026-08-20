-- Shared Source mesh helpers for PaintingRenderer and ItemFrameRenderer.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh or {}
R.Mesh = M

local function blockSize()
	return tonumber( MC.API and MC.API.Coords and MC.API.Coords.BlockSize
		and MC.API.Coords.BlockSize() ) or 36.5
end

local function copyVector( value )
	return Vector( value.x or 0, value.y or 0, value.z or 0 )
end

function M.BlockSize() return blockSize() end

function M.RenderPosition( ent )
	return ent and ent.GetPos and ent:GetPos() or nil
end

function M.WorldPosition( ent )
	if not ent then return nil end
	local coords = MC.API and MC.API.Coords
	return coords and coords.EntityWorldPos and coords.EntityWorldPos( ent ) or M.RenderPosition( ent )
end

function M.Direction( ent )
	local value = ent and ent.GetDecorationDirection and ent:GetDecorationDirection() or "south"
	return MC.Decoration.Direction( value ) or MC.Decoration.Direction( "south" )
end

-- ItemFrameRenderer's post-translation basis: local +X is the negative
-- counter-clockwise wall axis, local +Y is world up, and local +Z points into
-- the support block.  `normal` points from the support block to the entity.
function M.Basis( value )
	local xAxis, yAxis, zAxis, normal = MC.Decoration.DecorationRenderBasis( value )
	return copyVector( xAxis ), copyVector( yAxis ), copyVector( zAxis ), copyVector( normal )
end

R.Materials = R.Materials or {}
function M.Material( key, path, flags )
	if R.Materials[key] == false then return nil end
	if R.Materials[key] then return R.Materials[key] end
	local value = Material( path, flags or "vertexcolor vertexalpha alphatest nocull" )
	if not value or value.IsError and value:IsError() then
		R.Materials[key] = false
		return nil
	end
	R.Materials[key] = value
	return value
end

local function emit( point, u, v, color )
	mesh.Position( point )
	mesh.TexCoord( 0, tonumber( u ) or 0, tonumber( v ) or 0 )
	color = color or color_white or Color( 255, 255, 255, 255 )
	mesh.Color( color.r or 255, color.g or 255, color.b or 255, color.a or 255 )
	mesh.AdvanceVertex()
end

function M.Quad( points, uv, material, color )
	if not points or #points ~= 4 or not material or not mesh or not mesh.Begin then return false end
	render.SetMaterial( material )
	mesh.Begin( MATERIAL_QUADS, 1 )
	uv = uv or { 0, 0, 1, 1 }
	emit( points[1], uv[1], uv[4], color )
	emit( points[2], uv[3], uv[4], color )
	emit( points[3], uv[3], uv[2], color )
	emit( points[4], uv[1], uv[2], color )
	mesh.End()
	return true
end

function M.QuadRaw( points, uv, material, color )
	if not points or #points ~= 4 or not material or not mesh or not mesh.Begin then return false end
	render.SetMaterial( material )
	mesh.Begin( MATERIAL_QUADS, 1 )
	uv = uv or { 0, 0, 1, 1, 0, 1, 1, 0 }
	for index = 1, 4 do emit( points[index], uv[index * 2 - 1], uv[index * 2], color ) end
	mesh.End()
	return true
end

function M.Plane( center, axisX, axisY, width, height, material, color, uv )
	if not center or not axisX or not axisY then return false end
	axisX, axisY = axisX:GetNormalized(), axisY:GetNormalized()
	local hx, hy = axisX * ( width * 0.5 ), axisY * ( height * 0.5 )
	return M.Quad( { center - hx - hy, center + hx - hy,
		center + hx + hy, center - hx + hy }, uv, material, color )
end

-- Block-model coordinates are converted exactly like BlockModelRenderer's
-- frame model: x/y are centred around 8 and the model-local z axis is -normal.
function M.Point( anchor, xAxis, yAxis, normal, x, y, z )
	local bs = blockSize()
	return anchor + xAxis * ( ( x - 8 ) / 16 * bs )
		+ yAxis * ( ( y - 8 ) / 16 * bs )
		- normal * ( ( z - 8 ) / 16 * bs )
end

function M.Cuboid( anchor, xAxis, yAxis, normal, from, to, faceData, materials, color )
	if not anchor or not faceData then return false end
	local drawn = false
	for name, data in pairs( faceData ) do
		local vertices = MC.Decoration.BlockModelFaceVertices( name, from, to )
		if vertices and data then
			local polygon = {}
			for _, vertex in ipairs( vertices ) do
				polygon[#polygon + 1] = M.Point( anchor, xAxis, yAxis, normal,
					vertex.x, vertex.y, vertex.z )
			end
			local uv = data.uv or { 0, 0, 16, 16 }
			local normalized = { uv[1] / 16, uv[2] / 16,
				uv[1] / 16, uv[4] / 16, uv[3] / 16, uv[4] / 16,
				uv[3] / 16, uv[2] / 16 }
			local material = materials and materials[data.texture or "wood"]
			drawn = M.QuadRaw( polygon, normalized, material, color ) or drawn
		end
	end
	return drawn
end

function M.RotateAxes( xAxis, yAxis, normal, degrees )
	local radians = math.rad( tonumber( degrees ) or 0 )
	local c, s = math.cos( radians ), math.sin( radians )
	return xAxis * c + yAxis * s, yAxis * c - xAxis * s, normal
end

function M.ResetState()
	if render and render.SetColorModulation then render.SetColorModulation( 1, 1, 1 ) end
	if render and render.SetBlend then render.SetBlend( 1 ) end
	if render and render.CullMode then render.CullMode( MATERIAL_CULLMODE_CCW or 0 ) end
end
