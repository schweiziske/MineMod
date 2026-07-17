-- Server-only Source world collision adapter for Minecraft fluid spreading.
-- The BSP is static, so each voxel center and each adjacent face traversal can
-- be traced once and cached by packed numeric cell keys.

MC = MC or {}
MC.SV = MC.SV or {}
MC.WaterSpread = MC.WaterSpread or {}

local SV = MC.SV
local Water = MC.WaterSpread
local Liquid = MC.Liquid
local bitBand = bit.band
local bitBor = bit.bor
local bitLShift = bit.lshift
local TRACE_RADIUS = 0.05
local TraceMins = Vector( -TRACE_RADIUS, -TRACE_RADIUS, -TRACE_RADIUS )
local TraceMaxs = Vector( TRACE_RADIUS, TRACE_RADIUS, TRACE_RADIUS )
local TraceMask = MASK_SOLID_BRUSHONLY or MASK_SOLID
local CellBlocked = {}
local TraverseKnown = {}
local TraverseBlocked = {}

local function hitWorldOnly( entity )
	return IsValid( entity ) and entity:IsWorld()
end

local function cellCenter( bx, by, bz )
	return MC.CellWorldCenter( bx, by, bz )
end

local function worldTrace( startPos, endPos )
	local result = util.TraceHull( {
		start = startPos,
		endpos = endPos,
		mins = TraceMins,
		maxs = TraceMaxs,
		mask = TraceMask,
		filter = hitWorldOnly,
	} )
	return result.StartSolid == true or result.AllSolid == true or result.HitWorld == true
end

function Water.WorldCellBlocked( bx, by, bz )
	local key = MC.CellKey( bx, by, bz )
	local cached = CellBlocked[key]
	if cached ~= nil then return cached end
	local center = cellCenter( bx, by, bz )
	local blocked = worldTrace( center, center )
	CellBlocked[key] = blocked
	return blocked
end

local function rememberTraversal( key, face, blocked )
	local mask = bitLShift( 1, face - 1 )
	TraverseKnown[key] = bitBor( TraverseKnown[key] or 0, mask )
	if blocked then TraverseBlocked[key] = bitBor( TraverseBlocked[key] or 0, mask ) end
end

function Water.WorldCanTraverse( sx, sy, sz, tx, ty, tz, face )
	face = math.floor( tonumber( face ) or 0 )
	if face < 1 or face > 6 then return false end
	local sourceKey = MC.CellKey( sx, sy, sz )
	local mask = bitLShift( 1, face - 1 )
	if bitBand( TraverseKnown[sourceKey] or 0, mask ) ~= 0 then
		return bitBand( TraverseBlocked[sourceKey] or 0, mask ) == 0
	end

	local blocked = worldTrace( cellCenter( sx, sy, sz ), cellCenter( tx, ty, tz ) )
	rememberTraversal( sourceKey, face, blocked )
	local opposite = Liquid and Liquid.OppositeFace and Liquid.OppositeFace( face ) or nil
	if opposite then rememberTraversal( MC.CellKey( tx, ty, tz ), opposite, blocked ) end
	return not blocked
end

function SV.ClearWaterWorldCollisionCache()
	CellBlocked = {}
	TraverseKnown = {}
	TraverseBlocked = {}
end
