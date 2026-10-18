-- Server-side entity placement and shared interaction dispatch.

if not SERVER then return end

MC = MC or {}
MC.Decoration = MC.Decoration or {}
local D = MC.Decoration

local function stackCopy( stack ) return MC.CopyItemStack and MC.CopyItemStack( stack ) or table.Copy( stack ) end

local function selectedStack( ply )
	return MC.SV and MC.SV.GetSelectedPlayerStack and MC.SV.GetSelectedPlayerStack( ply ) or nil
end

local function consumeSelected( ply, stack, reason, context )
	if not MC.SV or not MC.SV.ConsumeHeldItem then return false, "inventory_api_unavailable" end
	local result, amount, _, err = MC.SV.ConsumeHeldItem( ply, 1, {
		hand = context and context.hand or "mainhand",
		respectInfiniteMaterials = true,
		expectedItem = stack and stack.item,
		expectedHash = MC.ItemStackHash and MC.ItemStackHash( stack ) or nil,
		reason = reason,
	} )
	if not result or result.ok ~= true then return false, err or "selected_item_changed" end
	return true, amount
end

local function spawnEntity( class, position, player )
	if not ents or not ents.Create then return nil, "entity_factory_unavailable" end
	local entity = ents.Create( class )
	if not IsValid( entity ) then return nil, "entity_create_failed" end
	entity.MCPlacementReference = player
	entity:SetPos( position )
	entity:SetOwner( player )
	entity:Spawn()
	entity:Activate()
	if not IsValid( entity ) then return nil, "entity_spawn_failed" end
	return entity
end

local function entityAABB( entity )
	if not IsValid( entity ) then return nil, nil end
	if entity.WorldSpaceAABB then return entity:WorldSpaceAABB() end
	local pos = entity:GetPos()
	return pos + entity:OBBMins(), pos + entity:OBBMaxs()
end

local function armorStandPlacementBox( position )
	local scale = MC.API and MC.API.Coords and MC.API.Coords.BlockSize
		and MC.API.Coords.BlockSize() or 36.5
	local minimum, maximum = D.ArmorStandPlacementBounds( position, scale )
	if not minimum or not maximum then return nil, nil end
	if Vector then
		return Vector( minimum.x, minimum.y, minimum.z ), Vector( maximum.x, maximum.y, maximum.z )
	end
	return minimum, maximum
end

local function armorStandPlacementClear( position )
	-- ArmorStandItem#useOn uses level.noCollision(null, box) and then
	-- level.getEntities(null, box).isEmpty(). Unlike the hanging-entity helper,
	-- no entity class (including the player or another decoration) is excluded.
	local minimum, maximum = armorStandPlacementBox( position )
	if D.WorldAABBHasCollision and D.WorldAABBHasCollision( minimum, maximum ) then return false end
	if ents and ents.FindInBox then
		for _, other in ipairs( ents.FindInBox( minimum, maximum ) or {} ) do
			if IsValid( other ) then return false end
		end
	end
	return true
end

local function preparePainting( entity, stack )
	local requested = D.PaintingVariantFromStack and D.PaintingVariantFromStack( stack ) or nil
	if requested then
		if not entity:SetMinecraftVariant( requested ) then return false, "unknown_painting_variant" end
		return entity:SurvivesMinecraft()
	end
	local selected = D.SelectPaintingVariant( function( variant )
		entity:SetMinecraftVariant( variant.name )
		return entity:SurvivesMinecraft()
	end )
	if not selected then return false, "no_surviving_variant" end
	entity:SetMinecraftVariant( selected.name )
	return true
end

function D.PlaceDecoration( ply, stack, hit, context )
	if not D.Enabled() then return false, "feature_disabled" end
	local ok, planOrError = D.PreviewPlace( ply, stack, hit )
	if ok ~= true then return false, planOrError end
	local plan = planOrError
	local kind = plan.kind
	local position = D.WorldPositionForCell( plan.bx, plan.by, plan.bz, kind == "armor_stand" )
	if not position then return false, "position_unavailable" end
	if kind == "armor_stand" and not armorStandPlacementClear( position ) then
		return false, "placement_blocked"
	end
	local class = D.EntityClassForKind( kind )
	local entity, spawnError = spawnEntity( class, position, ply )
	if not entity then return false, spawnError end
	if kind == "armor_stand" then
		entity:SetArmorStandRotation( D.ArmorStandQuantizedYaw( ply:GetAngles().y ) )
	elseif entity.SetHangingBlockPos then
		entity:SetHangingBlockPos( plan.bx, plan.by, plan.bz )
		entity:SetHangingDirection( plan.direction )
	end
	local valid = true
	if kind == "painting" then valid = preparePainting( entity, stack )
	elseif entity.SurvivesMinecraft then valid = entity:SurvivesMinecraft() end
	if valid ~= true then entity:Remove() return false, "placement_blocked" end
	if entity.PlayMinecraftPlacementSound then entity:PlayMinecraftPlacementSound() end
	if D.EmitDecorationGameEvent then
		D.EmitDecorationGameEvent( entity, "minecraft:entity_place", ply, {
			worldPosition = D.WorldFromEntity and D.WorldFromEntity( entity ) or position,
		} )
	end
	local consumed, consumeError = consumeSelected( ply, stack, "place_" .. kind, context )
	if not consumed then entity:Remove() return false, consumeError end
	if MC.RunEvent then MC.RunEvent( "MC.DecorationPlaced", ply, entity, stack, context or {} ) end
	return true, entity
end

hook.Add( "MC.UseItemOnEntity", "mcgame_decoration_interaction", function( ply, target, stack, context )
	if not D.Enabled() or not D.EntityDecorationTarget( target ) then return nil end
	if context and context.preview == true then return true end
	if target.MinecraftInteract then return target:MinecraftInteract( ply, stack, context ) end
	return false
end )

-- The hand weapon calls this hook before block placement.  It intentionally
-- returns a three-value result so callers can distinguish a non-decoration
-- target from a claimed but rejected placement.
hook.Add( "MC.TryPlaceDecoration", "mcgame_decoration_place", function( ply, stack, hit, context )
	if not D.Enabled() or not D.IsDecorationItem( stack ) then return nil end
	return D.PlaceDecoration( ply, stack, hit, context )
end )
