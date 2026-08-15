-- Java CampfireRenderer-equivalent food display using the inventory renderer.

if not CLIENT then return end

MC = MC or {}

local API = MC.API or {}
local Blocks = API.Blocks or {}
local Coords = API.Coords or {}
local World = API.World or {}
local BS = Coords.BlockSize and Coords.BlockSize() or 36.5
local MAX_RENDER_DISTANCE_SQR = ( BS * 64 ) ^ 2
local Entries, EntryCount = {}, 0
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
	for _, entry in ipairs( World.ListBlockEntities
		and World.ListBlockEntities( "minecraft:campfire" ) or {} ) do
		EntryCount = EntryCount + 1
		Entries[EntryCount] = entry
	end
	Dirty = false
end

local function drawFood( entry, stateId )
	local renderer = MC.InventoryUI and MC.InventoryUI.ItemRenderer
	if not renderer then return end
	local base = Coords.CellRenderMin and Coords.CellRenderMin( entry.bx, entry.by, entry.bz ) or nil
	if not base then return end
	local facing = FACING_INDEX[Blocks.GetProperty and Blocks.GetProperty( stateId, "facing" )] or 0
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
	if Dirty then rebuildEntries() end
	local eye = EyePos()
	for index = 1, EntryCount do
		local entry = Entries[index]
		local center = Coords.CellRenderCenter and Coords.CellRenderCenter( entry.bx, entry.by, entry.bz ) or nil
		if center and eye:DistToSqr( center ) <= MAX_RENDER_DISTANCE_SQR then
			local stateId = World.GetBlockState and World.GetBlockState( entry.bx, entry.by, entry.bz ) or 0
			if MC.IsCampfireState and MC.IsCampfireState( stateId ) then drawFood( entry, stateId ) end
		end
	end
end )

hook.Add( "MC.ClientWorldProjectionChanged", "mcgame_campfire_world_projection", function()
	Dirty = true
end )

hook.Add( "OnReloaded", "mc_campfire_food_items_reset", function() Dirty = true end )
