-- Java CampfireRenderer-equivalent food display using the inventory renderer.

if not CLIENT then return end

MC = MC or {}

local BS = MC.BS or 36.5
local MAX_RENDER_DISTANCE_SQR = ( BS * 64 ) ^ 2
local Entries, EntryCount = {}, 0
local LastRevision, LastGeneration = -1, -1
local Dirty = true
local FACING_INDEX = { south = 0, west = 1, north = 2, east = 3 }
-- Java applies rotateY(-direction.toYRot()) then rotateX(90).  Under Source's
-- Angle basis (Forward=X, Right=-Y, Up=Z), the equivalent model basis is
-- Angle(0, direction.toYRot(), 90), not a 90-degree pitch.
local DIRECTION_YAW = { [0] = 90, [1] = 180, [2] = 270, [3] = 0 }

function MC.MarkCampfireRenderEntriesDirty() Dirty = true end

local function rebuildEntries()
	for index = 1, EntryCount do Entries[index] = nil end
	EntryCount = 0
	for _, chunk in pairs( MC.World or {} ) do
		for localIndex, record in pairs( chunk.blockEntities or {} ) do
			if record.type == "minecraft:campfire" then
				local lx, ly, lz = MC.DecodeLocal( localIndex )
				EntryCount = EntryCount + 1
				Entries[EntryCount] = {
					bx = chunk.cx * MC.CS + lx,
					by = chunk.cy * MC.CS + ly,
					bz = chunk.cz * MC.CH + lz,
					record = record,
				}
			end
		end
	end
	LastRevision = tonumber( MC.AppliedStateRevision ) or 0
	LastGeneration = tonumber( MC.StateWorldGeneration ) or 0
	Dirty = false
end

local function drawFood( entry, stateId )
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local base = MC.CellRenderMin and MC.CellRenderMin( entry.bx, entry.by, entry.bz )
		or MC.CellWorldMin( entry.bx, entry.by, entry.bz )
	local facing = FACING_INDEX[MC.GetStateProperty( stateId, "facing" )] or 0
	for _, item in ipairs( entry.record.data and entry.record.data.items or {} ) do
		local slot = math.floor( tonumber( item.slot ) or -1 )
		local stack = item.stack
		if slot >= 0 and slot < 4 and not MC.IsEmptyItemStack( stack ) then
			local direction = ( slot + facing ) % 4
			local yaw = DIRECTION_YAW[direction] or 0
			local forward = Angle( 0, yaw, 0 ):Forward()
			local right = Angle( 0, yaw, 0 ):Right()
			local pos = base + Vector( BS * 0.5, BS * 0.5, BS * 0.44921875 )
				- forward * ( BS * 0.3125 ) - right * ( BS * 0.3125 )
			local angles = Angle( 0, yaw, 90 )
			local size = BS * 0.375
			local drawn = renderer.DrawDroppedBlock and renderer.DrawDroppedBlock(
				stack, pos, angles, size, color_white, { displayContext = "fixed" } )
			if not drawn and renderer.DrawHeldItem then
				renderer.DrawHeldItem( stack, pos, angles, size, color_white, { displayContext = "fixed" } )
			end
		end
	end
end

hook.Add( "PostDrawTranslucentRenderables", "mc_campfire_food_items", function( _, _, skybox )
	if skybox then return end
	local revision = tonumber( MC.AppliedStateRevision ) or 0
	local generation = tonumber( MC.StateWorldGeneration ) or 0
	if Dirty or revision ~= LastRevision or generation ~= LastGeneration then rebuildEntries() end
	local eye = EyePos()
	for index = 1, EntryCount do
		local entry = Entries[index]
		local center = MC.CellRenderCenter and MC.CellRenderCenter( entry.bx, entry.by, entry.bz )
			or MC.CellWorldCenter( entry.bx, entry.by, entry.bz )
		if eye:DistToSqr( center ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = MC.GetBlockState( entry.bx, entry.by, entry.bz )
			if MC.IsCampfireState and MC.IsCampfireState( stateId ) then drawFood( entry, stateId ) end
		end
	end
end )

hook.Add( "OnReloaded", "mc_campfire_food_items_reset", function() Dirty = true end )
