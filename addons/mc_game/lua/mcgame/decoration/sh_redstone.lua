-- Item-frame side of ComparatorBlock#getItemFrame. The engine asks an optional
-- generic entity-analog query and remains fully usable when mc_game is absent.

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local FRAME_CLASSES = {
	["mc_item_frame"] = true,
	["mc_glow_item_frame"] = true,
}

local function frameCandidates()
	local output = {}
	if not ents or not ents.FindByClass then return output end
	for class in pairs( FRAME_CLASSES ) do
		for _, entity in ipairs( ents.FindByClass( class ) or {} ) do
			output[#output + 1] = entity
		end
	end
	return output
end

local function validEntity( entity )
	return IsValid == nil or IsValid( entity )
end

-- ComparatorBlock#getItemFrame queries the exact target block AABB, filters by
-- ItemFrame#getDirection, and accepts the result only when the list size is 1.
-- Our hanging entities retain that constructor BlockPos directly, so matching
-- their networked cell is the exact Source-world equivalent of that AABB test.
function D.ComparatorFrameAnalogOutputAt( bx, by, bz, direction, candidates )
	bx, by, bz = tonumber( bx ), tonumber( by ), tonumber( bz )
	direction = D.Direction( direction )
	if bx == nil or by == nil or bz == nil or not direction or not direction.horizontal then return nil end
	bx, by, bz = math.floor( bx ), math.floor( by ), math.floor( bz )
	local matches = {}
	for _, entity in ipairs( candidates or frameCandidates() ) do
		local class = validEntity( entity ) and entity.GetClass and entity:GetClass() or nil
		if FRAME_CLASSES[class]
		and entity.GetDecorationBX and entity:GetDecorationBX() == bx
		and entity.GetDecorationBY and entity:GetDecorationBY() == by
		and entity.GetDecorationBZ and entity:GetDecorationBZ() == bz
		and entity.GetDecorationDirection and entity:GetDecorationDirection() == direction.id then
			matches[#matches + 1] = entity
		end
	end
	if #matches == 0 then return nil end
	if #matches ~= 1 then return { present = false, count = #matches } end
	local entity = matches[1]
	local output = entity.GetAnalogOutput and entity:GetAnalogOutput() or 0
	return {
		present = true,
		count = 1,
		output = math.max( 0, math.min( 15, math.floor( tonumber( output ) or 0 ) ) ),
		entity = entity,
	}
end

if hook and hook.Add then
	hook.Add( "MC.EntityAnalogOutputAt", "mcgame_item_frame_analog_output", function( bx, by, bz, dx, dy, dz )
		if not D.Enabled() then return nil end
		local direction = D.DirectionFromNormal( { x = dx, y = dy, z = dz } )
		return D.ComparatorFrameAnalogOutputAt( bx, by, bz, direction )
	end )
end
