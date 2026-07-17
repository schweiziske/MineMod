-- Minecraft FluidRenderer face rules and corner-height calculations.

MC = MC or {}
MC.RenderMesh = MC.RenderMesh or {}

local RM = MC.RenderMesh
local Liquid = MC.Liquid
local decodeState = Liquid and Liquid.DecodeState
local faceOccludedByState = Liquid and Liquid.FaceOccludedByState
local oppositeFace = Liquid and Liquid.OppositeFace

local FACE_TOP = 1
local FACE_BOTTOM = 2
local FACE_XP = 3
local FACE_XN = 4
local FACE_YP = 5
local FACE_YN = 6
local MAX_FLUID_HEIGHT = 8 / 9
local WEIGHTED_HEIGHT = 0.8

local function fluidStateAt( bx, by, bz )
	return MC.GetBlockState and MC.GetBlockState( bx, by, bz ) or 0
end

local function sameFluid( kind, stateId )
	if not decodeState then return false end
	local neighbourKind = decodeState( stateId )
	return neighbourKind == kind
end

local function stateSolid( stateId, bx, by, bz )
	return Liquid and Liquid.StateSolid and Liquid.StateSolid( stateId, bx, by, bz ) == true or false
end

local function fluidHeightAt( bx, by, bz, kind )
	local stateId = fluidStateAt( bx, by, bz )
	local stateKind, ownHeight = decodeState( stateId )
	if stateKind == kind then
		if sameFluid( kind, fluidStateAt( bx, by, bz + 1 ) ) then return 1 end
		return ownHeight
	end
	return stateSolid( stateId, bx, by, bz ) and -1 or 0
end

local function addWeightedHeight( total, weight, height )
	if height >= WEIGHTED_HEIGHT then return total + height * 10, weight + 10 end
	if height >= 0 then return total + height, weight + 1 end
	return total, weight
end

local function averageHeight( kind, heightSelf, heightA, heightB, cornerX, cornerY, bz )
	if heightA >= 1 or heightB >= 1 then return 1 end
	local total, weight = 0, 0
	if heightA > 0 or heightB > 0 then
		local cornerHeight = fluidHeightAt( cornerX, cornerY, bz, kind )
		if cornerHeight >= 1 then return 1 end
		total, weight = addWeightedHeight( total, weight, cornerHeight )
	end
	total, weight = addWeightedHeight( total, weight, heightSelf )
	total, weight = addWeightedHeight( total, weight, heightA )
	total, weight = addWeightedHeight( total, weight, heightB )
	return weight > 0 and total / weight or 0
end

local function cornerHeights( bx, by, bz, kind )
	local heightSelf = fluidHeightAt( bx, by, bz, kind )
	if heightSelf >= 1 then return 1, 1, 1, 1 end
	local heightXN = fluidHeightAt( bx - 1, by, bz, kind )
	local heightXP = fluidHeightAt( bx + 1, by, bz, kind )
	local heightYN = fluidHeightAt( bx, by - 1, bz, kind )
	local heightYP = fluidHeightAt( bx, by + 1, bz, kind )
	return averageHeight( kind, heightSelf, heightYN, heightXN, bx - 1, by - 1, bz ),
		averageHeight( kind, heightSelf, heightYN, heightXP, bx + 1, by - 1, bz ),
		averageHeight( kind, heightSelf, heightYP, heightXP, bx + 1, by + 1, bz ),
		averageHeight( kind, heightSelf, heightYP, heightXN, bx - 1, by + 1, bz )
end

local function selfOccludesFace( currentStateId, bx, by, bz, face )
	if not faceOccludedByState or not currentStateId or currentStateId == 0 then return false end
	return faceOccludedByState( oppositeFace( face ), 1, currentStateId, bx, by, bz )
end

local function shouldRenderFace( kind, currentStateId, bx, by, bz, face, neighbourStateId )
	return not sameFluid( kind, neighbourStateId ) and not selfOccludesFace( currentStateId, bx, by, bz, face )
end

local function neighborOccludesFace( face, height, stateId, bx, by, bz )
	if not faceOccludedByState then return false end
	return faceOccludedByState( face, height, stateId, bx, by, bz )
end

function RM.FluidGeometryAt( currentStateId, bx, by, bz, kind )
	local downState = fluidStateAt( bx, by, bz - 1 )
	local upState = fluidStateAt( bx, by, bz + 1 )
	local xpState = fluidStateAt( bx + 1, by, bz )
	local xnState = fluidStateAt( bx - 1, by, bz )
	local ypState = fluidStateAt( bx, by + 1, bz )
	local ynState = fluidStateAt( bx, by - 1, bz )
	local h00, h10, h11, h01 = cornerHeights( bx, by, bz, kind )

	local renderUp = not sameFluid( kind, upState )
	if renderUp then
		local minHeight = math.min( h00, h10, h11, h01 )
		renderUp = not neighborOccludesFace( FACE_TOP, minHeight, upState, bx, by, bz + 1 )
	end

	local renderDown = shouldRenderFace( kind, currentStateId, bx, by, bz, FACE_BOTTOM, downState )
		and not neighborOccludesFace( FACE_BOTTOM, MAX_FLUID_HEIGHT, downState, bx, by, bz - 1 )
	local renderXP = shouldRenderFace( kind, currentStateId, bx, by, bz, FACE_XP, xpState )
		and not neighborOccludesFace( FACE_XP, math.max( h10, h11 ), xpState, bx + 1, by, bz )
	local renderXN = shouldRenderFace( kind, currentStateId, bx, by, bz, FACE_XN, xnState )
		and not neighborOccludesFace( FACE_XN, math.max( h00, h01 ), xnState, bx - 1, by, bz )
	local renderYP = shouldRenderFace( kind, currentStateId, bx, by, bz, FACE_YP, ypState )
		and not neighborOccludesFace( FACE_YP, math.max( h01, h11 ), ypState, bx, by + 1, bz )
	local renderYN = shouldRenderFace( kind, currentStateId, bx, by, bz, FACE_YN, ynState )
		and not neighborOccludesFace( FACE_YN, math.max( h00, h10 ), ynState, bx, by - 1, bz )

	return h00, h10, h11, h01, renderUp, renderDown, renderXP, renderXN, renderYP, renderYN
end

RM.fluidHeightAt = fluidHeightAt
RM.calculateAverageFluidHeight = averageHeight
