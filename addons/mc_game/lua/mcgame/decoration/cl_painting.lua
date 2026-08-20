-- PaintingRenderer#renderPainting translated to Source mesh quads.
if not CLIENT then return end

MC = MC or {}
MC.DecorationRenderer = MC.DecorationRenderer or {}
local R = MC.DecorationRenderer
local M = R.Mesh
local D = MC.Decoration

local function materialForPainting( variant )
	return M.Material( "painting_" .. tostring( variant.key ),
		"mc/painting/" .. tostring( variant.key ) .. ".png" )
end

local function lightColor( position )
	local r, g, b = 1, 1, 1
	if D.SampleDecorationLight then r, g, b = D.SampleDecorationLight( position, false ) end
	return Color( math.floor( math.Clamp( tonumber( r ) or 1, 0, 1 ) * 255 + 0.5 ),
		math.floor( math.Clamp( tonumber( g ) or r or 1, 0, 1 ) * 255 + 0.5 ),
		math.floor( math.Clamp( tonumber( b ) or r or 1, 0, 1 ) * 255 + 0.5 ), 255 )
end

local function rawQuad( points, uv, material, color )
	return M.QuadRaw( points, uv, material, color )
end

local function tilePoint( center, xAxis, yAxis, normal, x, y, z )
	-- PaintingRenderer's PoseStack has local X/Y in blocks and local Z in
	-- blocks.  Its front is z=-0.03125, its back z=+0.03125.
	local bs = M.BlockSize()
	return center + xAxis * ( x * bs ) + yAxis * ( y * bs ) - normal * ( z * bs )
end

local function renderTile( center, xAxis, yAxis, normal, front, back,
	offsetX, offsetY, totalWidth, totalHeight, segmentX, segmentY, color )
	local x0 = offsetX + segmentX + 1
	local x1 = offsetX + segmentX
	local y0 = offsetY + segmentY + 1
	local y1 = offsetY + segmentY
	local zFront, zBack = -0.03125, 0.03125
	local du, dv = 1 / totalWidth, 1 / totalHeight
	local frontU0 = du * ( totalWidth - segmentX )
	local frontU1 = du * ( totalWidth - ( segmentX + 1 ) )
	local frontV0 = dv * ( totalHeight - segmentY )
	local frontV1 = dv * ( totalHeight - ( segmentY + 1 ) )
	local drawn = false

	-- The four vertex/UV pairs below are copied from PaintingRenderer.java,
	-- including its reversed horizontal front-U order.
	drawn = rawQuad( {
		tilePoint( center, xAxis, yAxis, normal, x0, y1, zFront ),
		tilePoint( center, xAxis, yAxis, normal, x1, y1, zFront ),
		tilePoint( center, xAxis, yAxis, normal, x1, y0, zFront ),
		tilePoint( center, xAxis, yAxis, normal, x0, y0, zFront ),
	}, { frontU1, frontV0, frontU0, frontV0, frontU0, frontV1, frontU1, frontV1 }, front, color ) or drawn

	local backU0, backU1, backV0, backV1 = 0, 1, 0, 1
	drawn = rawQuad( {
		tilePoint( center, xAxis, yAxis, normal, x0, y0, zBack ),
		tilePoint( center, xAxis, yAxis, normal, x1, y0, zBack ),
		tilePoint( center, xAxis, yAxis, normal, x1, y1, zBack ),
		tilePoint( center, xAxis, yAxis, normal, x0, y1, zBack ),
	}, { backU1, backV0, backU0, backV0, backU0, backV1, backU1, backV1 }, back, color ) or drawn

	local topBottomU0, topBottomU1 = 0, 1
	local topBottomV0, topBottomV1 = 0, 0.0625
	local leftRightU0, leftRightU1 = 0, 0.0625
	local leftRightV0, leftRightV1 = 0, 1
	if segmentY == totalHeight - 1 then
		drawn = rawQuad( {
			tilePoint( center, xAxis, yAxis, normal, x0, y0, zFront ),
			tilePoint( center, xAxis, yAxis, normal, x1, y0, zFront ),
			tilePoint( center, xAxis, yAxis, normal, x1, y0, zBack ),
			tilePoint( center, xAxis, yAxis, normal, x0, y0, zBack ),
		}, { topBottomU0, topBottomV0, topBottomU1, topBottomV0,
			topBottomU1, topBottomV1, topBottomU0, topBottomV1 }, back, color ) or drawn
	end
	if segmentY == 0 then
		drawn = rawQuad( {
			tilePoint( center, xAxis, yAxis, normal, x0, y1, zBack ),
			tilePoint( center, xAxis, yAxis, normal, x1, y1, zBack ),
			tilePoint( center, xAxis, yAxis, normal, x1, y1, zFront ),
			tilePoint( center, xAxis, yAxis, normal, x0, y1, zFront ),
		}, { topBottomU0, topBottomV0, topBottomU1, topBottomV0,
			topBottomU1, topBottomV1, topBottomU0, topBottomV1 }, back, color ) or drawn
	end
	if segmentX == totalWidth - 1 then
		drawn = rawQuad( {
			tilePoint( center, xAxis, yAxis, normal, x0, y0, zBack ),
			tilePoint( center, xAxis, yAxis, normal, x0, y1, zBack ),
			tilePoint( center, xAxis, yAxis, normal, x0, y1, zFront ),
			tilePoint( center, xAxis, yAxis, normal, x0, y0, zFront ),
		}, { leftRightU1, leftRightV0, leftRightU1, leftRightV1,
			leftRightU0, leftRightV1, leftRightU0, leftRightV0 }, back, color ) or drawn
	end
	if segmentX == 0 then
		drawn = rawQuad( {
			tilePoint( center, xAxis, yAxis, normal, x1, y0, zFront ),
			tilePoint( center, xAxis, yAxis, normal, x1, y1, zFront ),
			tilePoint( center, xAxis, yAxis, normal, x1, y1, zBack ),
			tilePoint( center, xAxis, yAxis, normal, x1, y0, zBack ),
		}, { leftRightU1, leftRightV0, leftRightU1, leftRightV1,
			leftRightU0, leftRightV1, leftRightU0, leftRightV0 }, back, color ) or drawn
	end
	return drawn
end

function R.DrawPainting( ent )
	if not IsValid( ent ) then return false end
	local variant = ent.GetMinecraftVariant and ent:GetMinecraftVariant() or D.PaintingVariant( "kebab" )
	if not variant then return false end
	local center = M.RenderPosition( ent )
	if not center then return false end
	local worldCenter = M.WorldPosition( ent ) or center
	local xAxis, yAxis, _, normal = M.Basis( M.Direction( ent ) )
	local front = materialForPainting( variant )
	local back = M.Material( "painting_back", "mc/painting/back.png" )
	if not front or not back then return false end
	local width, height = variant.width, variant.height
	local offsetX, offsetY = -width / 2, -height / 2
	local drawn = false
	for segmentX = 0, width - 1 do
		for segmentY = 0, height - 1 do
			local tileX = offsetX + segmentX + 0.5
			local tileY = offsetY + segmentY + 0.5
			local tileCenter = worldCenter + xAxis * ( tileX * M.BlockSize() )
				+ yAxis * ( tileY * M.BlockSize() )
			drawn = renderTile( center, xAxis, yAxis, normal, front, back,
				offsetX, offsetY, width, height, segmentX, segmentY,
				lightColor( tileCenter ) ) or drawn
		end
	end
	M.ResetState()
	return drawn
end
