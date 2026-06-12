--[[----------------------------------------------------------------------------
	MC functional block: doors.

	Doors are still voxel cells, not entities. Using a door toggles the encoded
	open bit on both halves and lets the normal server write path handle sync,
	collision rebuild, save dirty state, and client redraw.
------------------------------------------------------------------------------]]

MC = MC or {}
MC.BlockHandlers = MC.BlockHandlers or {}

local DoorSoundSets = {
	wood = {
		open = { "mc/block/wooden_door/open1.ogg", "mc/block/wooden_door/open2.ogg" },
		close = {
			"mc/block/wooden_door/close1.ogg",
			"mc/block/wooden_door/close2.ogg",
			"mc/block/wooden_door/close3.ogg",
		},
	},
	iron = {
		open = {
			"mc/block/iron_door/open1.ogg",
			"mc/block/iron_door/open2.ogg",
			"mc/block/iron_door/open3.ogg",
			"mc/block/iron_door/open4.ogg",
		},
		close = {
			"mc/block/iron_door/close1.ogg",
			"mc/block/iron_door/close2.ogg",
			"mc/block/iron_door/close3.ogg",
			"mc/block/iron_door/close4.ogg",
		},
	},
	copper = {
		open = {
			"mc/block/copper_door/toggle1.ogg",
			"mc/block/copper_door/toggle2.ogg",
			"mc/block/copper_door/toggle2.ogg",
			"mc/block/copper_door/toggle3.ogg",
			"mc/block/copper_door/toggle3.ogg",
		},
		close = {
			"mc/block/copper_door/toggle1.ogg",
			"mc/block/copper_door/toggle2.ogg",
			"mc/block/copper_door/toggle3.ogg",
		},
	},
	cherry = {
		open = {
			"mc/block/cherrywood_door/toggle1.ogg",
			"mc/block/cherrywood_door/toggle2.ogg",
			"mc/block/cherrywood_door/toggle3.ogg",
			"mc/block/cherrywood_door/toggle4.ogg",
		},
		close = {
			"mc/block/cherrywood_door/toggle1.ogg",
			"mc/block/cherrywood_door/toggle2.ogg",
			"mc/block/cherrywood_door/toggle3.ogg",
			"mc/block/cherrywood_door/toggle4.ogg",
		},
	},
	nether = {
		open = {
			"mc/block/nether_wood_door/toggle1.ogg",
			"mc/block/nether_wood_door/toggle2.ogg",
			"mc/block/nether_wood_door/toggle3.ogg",
			"mc/block/nether_wood_door/toggle4.ogg",
		},
		close = {
			"mc/block/nether_wood_door/toggle1.ogg",
			"mc/block/nether_wood_door/toggle2.ogg",
			"mc/block/nether_wood_door/toggle3.ogg",
			"mc/block/nether_wood_door/toggle4.ogg",
		},
	},
	bamboo = {
		open = {
			"mc/block/bamboo_wood_door/toggle1.ogg",
			"mc/block/bamboo_wood_door/toggle2.ogg",
			"mc/block/bamboo_wood_door/toggle3.ogg",
			"mc/block/bamboo_wood_door/toggle4.ogg",
		},
		close = {
			"mc/block/bamboo_wood_door/toggle1.ogg",
			"mc/block/bamboo_wood_door/toggle2.ogg",
			"mc/block/bamboo_wood_door/toggle3.ogg",
			"mc/block/bamboo_wood_door/toggle4.ogg",
		},
	},
}

local function doorSoundSetForBlock( id )
	local b = MC.Blocks and MC.Blocks[id]
	local name = b and b.name or ""
	if name == "iron_door" then return DoorSoundSets.iron end
	if string.find( name, "copper_door", 1, true ) then return DoorSoundSets.copper end
	if name == "cherry_door" then return DoorSoundSets.cherry end
	if name == "crimson_door" or name == "warped_door" then return DoorSoundSets.nether end
	if name == "bamboo_door" then return DoorSoundSets.bamboo end
	return DoorSoundSets.wood
end

local function playDoorSound( id, open, bx, by, bz )
	if not SERVER then return end
	local set = doorSoundSetForBlock( id )
	local list = open and set.open or set.close
	if not list or #list == 0 then return end
	local pos = MC.CellWorldCenter and MC.CellWorldCenter( bx, by, bz ) or Vector( 0, 0, 0 )
	sound.Play( list[math.random( #list )], pos, 72, math.floor( math.Rand( 90, 100 ) + 0.5 ), 1 )
end

local function matchingDoorPart( id, orient, wantId, facing, half, open )
	return id == wantId
		and MC.IsDoorBlock and MC.IsDoorBlock( id )
		and MC.DoorOrientFacing( orient ) == facing
		and MC.DoorOrientHalf( orient ) == half
		and MC.DoorOrientOpen( orient ) == open
end

local function toggleDoorCell( ply, bx, by, bz, id, facing, half, open )
	local orient = MC.MakeDoorOrient( facing, half, open )
	return MC.SV.SetBlock( bx, by, bz, id, orient, {
		actor = ply,
		fx = false,
		handlers = false,
		priorityPhys = true,
	} )
end

MC.BlockHandlers.door = MC.BlockHandlers.door or {
	OnUse = function( ply, bx, by, bz, orient )
		if not SERVER or not MC.SV or not MC.SV.SetBlock then return false end

		local id = MC.GetBlock( bx, by, bz )
		if not MC.IsDoorBlock( id ) then return false end

		orient = MC.NormalizeOrient( id, orient )
		local facing = MC.DoorOrientFacing( orient )
		local half = MC.DoorOrientHalf( orient )
		local open = MC.DoorOrientOpen( orient )
		local nextOpen = not open
		local lowerZ = half == "upper" and bz - 1 or bz
		local upperZ = lowerZ + 1
		local changed = false

		local lowerId = MC.GetBlock( bx, by, lowerZ )
		local lowerOrient = MC.GetBlockOrient( bx, by, lowerZ )
		if matchingDoorPart( lowerId, lowerOrient, id, facing, "lower", open ) then
			local ok = toggleDoorCell( ply, bx, by, lowerZ, id, facing, "lower", nextOpen )
			changed = changed or ok == true
		end

		local upperId = MC.GetBlock( bx, by, upperZ )
		local upperOrient = MC.GetBlockOrient( bx, by, upperZ )
		if matchingDoorPart( upperId, upperOrient, id, facing, "upper", open ) then
			local ok = toggleDoorCell( ply, bx, by, upperZ, id, facing, "upper", nextOpen )
			changed = changed or ok == true
		end

		if changed then
			playDoorSound( id, nextOpen, bx, by, bz )
		end

		return changed
	end,
}
