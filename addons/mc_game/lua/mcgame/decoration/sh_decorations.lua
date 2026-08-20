-- Shared decoration placement/interaction policy.
-- Every rule in this file is a direct translation of the corresponding
-- HangingEntityItem/ArmorStandItem/ItemFrame method in out/.  World writes
-- remain server-only; the client half only answers prediction queries.

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local function normalComponent( normal )
	if not normal then return nil end
	local x, y, z = tonumber( normal.x ) or 0, tonumber( normal.y ) or 0, tonumber( normal.z ) or 0
	if math.abs( x ) >= math.abs( y ) and math.abs( x ) >= math.abs( z ) and math.abs( x ) > 0.5 then
		return x > 0 and D.Direction( "east" ) or D.Direction( "west" )
	end
	if math.abs( y ) >= math.abs( z ) and math.abs( y ) > 0.5 then
		return y > 0 and D.Direction( "south" ) or D.Direction( "north" )
	end
	if math.abs( z ) > 0.5 then return z > 0 and D.Direction( "up" ) or D.Direction( "down" ) end
	return nil
end

function D.DecorationKind( stack )
	return D.ItemKind( stack )
end

function D.EntityClassForKind( kind )
	return ({
		painting = "mc_painting",
		item_frame = "mc_item_frame",
		glow_item_frame = "mc_glow_item_frame",
		armor_stand = "mc_armor_stand",
	})[kind]
end

function D.PlacementCell( hit )
	if type( hit ) ~= "table" or hit.Hit == false then return nil end
	local normal = normalComponent( hit.HitNormal )
	if not normal then return nil end
	local bx, by, bz = tonumber( hit.bx ), tonumber( hit.by ), tonumber( hit.bz )
	if bx == nil and hit.HitPos and MC.API and MC.API.Coords and MC.API.Coords.WorldToCell then
		bx, by, bz = MC.API.Coords.WorldToCell( hit.HitPos - Vector( hit.HitNormal ) * 0.5 )
	end
	if bx == nil then return nil end
	-- PlayerBlockAim already reports the clicked block. Eye traces are converted
	-- above by sampling half a normal inside that same block. HangingEntityItem
	-- then places at clickedPos.relative(clickedFace), exactly one cell outward.
	return math.floor( bx + normal.x ), math.floor( by + normal.y ), math.floor( bz + normal.z ), normal
end

function D.CanEditAndReach( ply, bx, by, bz )
	local playerAPI = MC.API and MC.API.Player or nil
	if playerAPI and playerAPI.CanEdit and playerAPI.CanEdit( ply ) ~= true then return false, "edit_rejected" end
	if playerAPI and playerAPI.CanReachCell then
		local ok = playerAPI.CanReachCell( ply, bx, by, bz )
		if ok ~= true then return false, "out_of_reach" end
	end
	return true
end

function D.WorldPositionForCell( bx, by, bz, bottom )
	local coords = MC.API and MC.API.Coords or nil
	if not coords then return nil end
	if bottom and coords.CellMin then
		local min = coords.CellMin( bx, by, bz )
		local size = coords.BlockSize and coords.BlockSize() or 36.5
		-- ArmorStandItem: Vec3.atBottomCenterOf(blockPos), i.e. x/y center
		-- and the block's lower Y/Z plane (the adapter's vertical axis is z).
		return min and ( min + Vector( size * 0.5, size * 0.5, 0 ) ) or nil
	end
	return coords.CellCenter and coords.CellCenter( bx, by, bz ) or nil
end

function D.EntityDecorationTarget( entity )
	if not IsValid or not IsValid( entity ) then return false end
	return entity.IsMinecraftHangingDecoration == true or entity.IsMinecraftArmorStand == true
end

function D.IsDecorationEnabledForStack( stack )
	return D.Enabled() and D.IsDecorationItem( stack )
end

-- Client-side prediction query.  The server repeats every check before any
-- mutation, so this function is deliberately side-effect free.
function D.PreviewPlace( ply, stack, hit )
	if not D.IsDecorationEnabledForStack( stack ) then return nil end
	local kind = D.DecorationKind( stack )
	local bx, by, bz, direction = D.PlacementCell( hit )
	if bx == nil then return false, "invalid_placement_face" end
	if kind ~= "armor_stand" and not direction.horizontal then return false, "vertical_face" end
	if kind == "armor_stand" and direction.name == "down" then return false, "down_face" end
	local ok, err = D.CanEditAndReach( ply, bx, by, bz )
	if not ok then return false, err end
	return true, { kind = kind, bx = bx, by = by, bz = bz, direction = direction }
end

D.PublicAPI = D.PublicAPI or {}
D.PublicAPI.PreviewPlace = D.PreviewPlace
D.PublicAPI.DecorationKind = D.DecorationKind
