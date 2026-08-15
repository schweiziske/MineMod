--[[----------------------------------------------------------------------------
	MC functional block: trapdoors.

	Trapdoors are single voxel cells. Using one toggles only the encoded open bit
	and lets the normal server write path sync, redraw, and rebuild collision.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

local TrapdoorSoundSets = {
	wood = {
		open = {
			"mc/block/wooden_trapdoor/open1.ogg",
			"mc/block/wooden_trapdoor/open2.ogg",
			"mc/block/wooden_trapdoor/open3.ogg",
			"mc/block/wooden_trapdoor/open4.ogg",
			"mc/block/wooden_trapdoor/open5.ogg",
		},
		close = {
			"mc/block/wooden_trapdoor/close1.ogg",
			"mc/block/wooden_trapdoor/close2.ogg",
			"mc/block/wooden_trapdoor/close3.ogg",
		},
	},
	iron = {
		open = {
			"mc/block/iron_trapdoor/open1.ogg",
			"mc/block/iron_trapdoor/open2.ogg",
			"mc/block/iron_trapdoor/open3.ogg",
			"mc/block/iron_trapdoor/open4.ogg",
		},
		close = {
			"mc/block/iron_trapdoor/close1.ogg",
			"mc/block/iron_trapdoor/close2.ogg",
			"mc/block/iron_trapdoor/close3.ogg",
			"mc/block/iron_trapdoor/close4.ogg",
		},
	},
	copper = {
		open = {
			"mc/block/copper_trapdoor/toggle1.ogg",
			"mc/block/copper_trapdoor/toggle2.ogg",
			"mc/block/copper_trapdoor/toggle3.ogg",
			"mc/block/copper_trapdoor/toggle4.ogg",
		},
		close = {
			"mc/block/copper_trapdoor/toggle1.ogg",
			"mc/block/copper_trapdoor/toggle2.ogg",
			"mc/block/copper_trapdoor/toggle3.ogg",
			"mc/block/copper_trapdoor/toggle4.ogg",
		},
	},
	cherry = {
		open = {
			"mc/block/cherrywood_trapdoor/toggle1.ogg",
			"mc/block/cherrywood_trapdoor/toggle2.ogg",
			"mc/block/cherrywood_trapdoor/toggle3.ogg",
		},
		close = {
			"mc/block/cherrywood_trapdoor/toggle1.ogg",
			"mc/block/cherrywood_trapdoor/toggle2.ogg",
			"mc/block/cherrywood_trapdoor/toggle3.ogg",
		},
	},
	nether = {
		open = {
			"mc/block/nether_wood_trapdoor/toggle1.ogg",
			"mc/block/nether_wood_trapdoor/toggle2.ogg",
			"mc/block/nether_wood_trapdoor/toggle3.ogg",
			"mc/block/nether_wood_trapdoor/toggle4.ogg",
		},
		close = {
			"mc/block/nether_wood_trapdoor/toggle1.ogg",
			"mc/block/nether_wood_trapdoor/toggle2.ogg",
			"mc/block/nether_wood_trapdoor/toggle3.ogg",
			"mc/block/nether_wood_trapdoor/toggle4.ogg",
		},
	},
	bamboo = {
		open = {
			"mc/block/bamboo_wood_trapdoor/toggle1.ogg",
			"mc/block/bamboo_wood_trapdoor/toggle2.ogg",
			"mc/block/bamboo_wood_trapdoor/toggle3.ogg",
			"mc/block/bamboo_wood_trapdoor/toggle4.ogg",
		},
		close = {
			"mc/block/bamboo_wood_trapdoor/toggle1.ogg",
			"mc/block/bamboo_wood_trapdoor/toggle2.ogg",
			"mc/block/bamboo_wood_trapdoor/toggle3.ogg",
			"mc/block/bamboo_wood_trapdoor/toggle4.ogg",
		},
	},
}

function MC.IsTrapdoorBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	return b and b.orient == "trapdoor" or false
end

local function trapdoorSoundSetForBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	local name = b and b.name or ""
	if name == "iron_trapdoor" then return TrapdoorSoundSets.iron end
	if string.find( name, "copper_trapdoor", 1, true ) then return TrapdoorSoundSets.copper end
	if name == "cherry_trapdoor" then return TrapdoorSoundSets.cherry end
	if name == "crimson_trapdoor" or name == "warped_trapdoor" then return TrapdoorSoundSets.nether end
	if name == "bamboo_trapdoor" then return TrapdoorSoundSets.bamboo end
	return TrapdoorSoundSets.wood
end

function MC.TrapdoorCanOpenByHand( id )
	local b = MC.Blocks and MC.Blocks[id]
	return not ( b and b.name == "iron_trapdoor" )
end

local function playTrapdoorSound( id, open, bx, by, bz )
	if not SERVER then return end
	local set = trapdoorSoundSetForBlock( id )
	local list = open and set.open or set.close
	if not list or #list == 0 then return end
	local pos = MC.CellWorldCenter and MC.CellWorldCenter( bx, by, bz ) or Vector( 0, 0, 0 )
	sound.Play( list[math.random( #list )], pos, 72, math.floor( math.Rand( 90, 100 ) + 0.5 ), 1 )
end

MC.BlockHandlers.trapdoor = MC.BlockHandlers.trapdoor or {
	OnUse = function( ply, bx, by, bz, orient )
		if not SERVER or not MC.SV or not MC.SV.SetBlock then return false end

		local id = MC.GetBlock( bx, by, bz )
		if not MC.IsTrapdoorBlock( id ) then return false end
		if not MC.TrapdoorCanOpenByHand( id ) then return false end

		orient = MC.NormalizeOrient( id, orient )
		local facing = MC.TrapdoorOrientFacing( orient )
		local half = MC.TrapdoorOrientHalf( orient )
		local open = MC.TrapdoorOrientOpen( orient )
		local powered = MC.TrapdoorOrientPowered( orient )
		local nextOpen = not open
		local nextOrient = MC.MakeTrapdoorOrient( facing, half, nextOpen, powered )

		local changed = MC.SV.SetBlock( bx, by, bz, id, nextOrient, {
			actor = ply,
			fx = false,
			handlers = false,
			priorityPhys = true,
		} )

		if changed == true then
			playTrapdoorSound( id, nextOpen, bx, by, bz )
		end

		return changed == true
	end,
}
