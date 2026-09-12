-- Shared broad phase for item merging, hoppers and pistons. All bounds are in
-- MC world space; engine-space FindInBox is not safe across InfMap origins.
if not SERVER then return end

MC.ItemDropQuery = MC.ItemDropQuery or {}
local Q = MC.ItemDropQuery
local Coords = MC.API.Coords
local floor, max, min = math.floor, math.max, math.min
local records, byEntity, grid = {}, {}, {}
local refreshedAt, cellSize = -math.huge, 0
local halfX, halfY, halfZ = 0, 0, 0

local function removeSlot( entries, slot, field )
	local last = entries[#entries]
	entries[slot] = last
	entries[#entries] = nil
	if last then last[field] = slot end
end

local function unlinkMerge( record )
	if not record.mergeEntries then return end
	local entries = record.mergeEntries
	removeSlot( entries, record.mergeSlot, "mergeSlot" )
	if #entries == 0 then record.bucket.merging[record.mergeItem] = nil end
	record.mergeEntries, record.mergeItem = nil, nil
end

local function unlink( record )
	local bucket = record.bucket
	if not bucket then return end
	unlinkMerge( record )
	removeSlot( bucket, record.bucketSlot, "bucketSlot" )
	record.bucket = nil
	if #bucket == 0 then
		local column = grid[record.cx]
		local layer = column[record.cy]
		layer[record.cz] = nil
		if next( layer ) == nil then column[record.cy] = nil end
		if next( column ) == nil then grid[record.cx] = nil end
	end
end

local function updateMerge( record )
	local stack = record.entity.MCItemStack
	if record.stack == stack and ( record.mergeEntries or record.mergeFull ) then return end
	if stack and record.entity.MCItemComponentKey == nil then
		record.entity.MCItemComponentKey = MC.CanonicalItemComponents( stack.components )
	end
	local item
	if not MC.IsEmptyItemStack( stack ) and stack.count < MC.ItemStackMaxCount( stack ) then
		item = stack.item
	end
	if item ~= record.mergeItem then unlinkMerge( record ) end
	record.stack = stack
	record.mergeFull = item == nil
	if not item or record.mergeEntries then return end
	local entries = record.bucket.merging[item]
	if not entries then entries = {}; record.bucket.merging[item] = entries end
	record.mergeEntries, record.mergeItem = entries, item
	record.mergeSlot = #entries + 1
	entries[record.mergeSlot] = record
end

function Q.Unregister( entity )
	local record = byEntity[entity]
	if not record then return end
	unlink( record )
	removeSlot( records, record.slot, "slot" )
	byEntity[entity] = nil
end

local function updateBounds( record )
	local minimum, maximum = Coords.EntityWorldAABB( record.entity )
	if not isvector( minimum ) or not isvector( maximum ) then
		unlink( record )
		MC.Fault( "item_drop_query_bounds", "Cannot index item entity %s", record.entity )
		return
	end
	local x, y, z = ( minimum.x + maximum.x ) * 0.5,
		( minimum.y + maximum.y ) * 0.5, ( minimum.z + maximum.z ) * 0.5
	record.minX, record.minY, record.minZ = minimum.x, minimum.y, minimum.z
	record.maxX, record.maxY, record.maxZ = maximum.x, maximum.y, maximum.z
	halfX, halfY, halfZ = max( halfX, maximum.x - x ),
		max( halfY, maximum.y - y ), max( halfZ, maximum.z - z )
	local cx, cy, cz = floor( x / cellSize ), floor( y / cellSize ), floor( z / cellSize )
	if not record.bucket or record.cx ~= cx or record.cy ~= cy or record.cz ~= cz then
		unlink( record )
		local column = grid[cx]
		if not column then column = {}; grid[cx] = column end
		local layer = column[cy]
		if not layer then layer = {}; column[cy] = layer end
		local bucket = layer[cz]
		if not bucket then bucket = { merging = {} }; layer[cz] = bucket end
		record.cx, record.cy, record.cz = cx, cy, cz
		record.bucket, record.bucketSlot = bucket, #bucket + 1
		bucket[record.bucketSlot] = record
	end
	updateMerge( record )
end

function Q.Register( entity )
	if byEntity[entity] or not IsValid( entity ) or entity:GetClass() ~= "mc_item_drop" then return end
	local record = { entity = entity, slot = #records + 1 }
	records[record.slot], byEntity[entity] = record, record
	if cellSize > 0 then updateBounds( record ) end
end

-- Call after an explicit SetPos/PhysicsInit/SetDropStack as well: these writes
-- can happen after the first query in the same engine tick.
function Q.Update( entity )
	local record = byEntity[entity]
	if not record then Q.Register( entity ); return end
	if cellSize > 0 then updateBounds( record ) end
end

function Q.StackChanged( entity )
	local record = byEntity[entity]
	if record and record.bucket then updateMerge( record ) end
end

function Q.Refresh()
	local current = CurTime()
	local size = max( 0.001, Coords.BlockSize() ) * 2
	if refreshedAt == current and cellSize == size then return end
	refreshedAt = current
	if cellSize ~= size then
		grid, cellSize = {}, size
		for i = 1, #records do
			local record = records[i]
			record.bucket, record.mergeEntries, record.mergeItem = nil, nil, nil
		end
	end
	halfX, halfY, halfZ = 0, 0, 0
	for i = #records, 1, -1 do
		local record = records[i]
		if IsValid( record.entity ) then updateBounds( record )
		else Q.Unregister( record.entity ) end
	end
end

-- output belongs to the caller (never a shared scratch table across callbacks).
-- item selects only non-full stacks of that item for merge queries. Full stacks
-- stay in the general index, so hoppers and pistons still see every drop.
function Q.InBox( minX, minY, minZ, maxX, maxY, maxZ, output, item )
	Q.Refresh()
	output = output or {}
	local previous, count = #output, 0
	local x0, y0, z0 = floor( ( minX - halfX ) / cellSize ),
		floor( ( minY - halfY ) / cellSize ), floor( ( minZ - halfZ ) / cellSize )
	local x1, y1, z1 = floor( ( maxX + halfX ) / cellSize ),
		floor( ( maxY + halfY ) / cellSize ), floor( ( maxZ + halfZ ) / cellSize )
	for x = x0, x1 do
		local column = grid[x]
		if column then
			for y = y0, y1 do
				local layer = column[y]
				if layer then
					for z = z0, z1 do
						local bucket = layer[z]
						local entries = bucket
						if bucket and item then entries = bucket.merging[item] end
						if entries then
							for i = 1, #entries do
								local record = entries[i]
								if record.maxX >= minX and record.minX <= maxX
								and record.maxY >= minY and record.minY <= maxY
								and record.maxZ >= minZ and record.minZ <= maxZ then
									count = count + 1
									output[count] = record.entity
								end
							end
						end
					end
				end
			end
		end
	end
	for i = count + 1, previous do output[i] = nil end
	return output
end

function Q.All()
	return records
end

function Q.InSphere( position, radius, output, item )
	output = Q.InBox( position.x - radius, position.y - radius, position.z - radius,
		position.x + radius, position.y + radius, position.z + radius, output, item )
	local count, previous, squared = 0, #output, radius * radius
	for i = 1, previous do
		local entity = output[i]
		local record = byEntity[entity]
		if record then
			local dx = max( record.minX - position.x, 0, position.x - record.maxX )
			local dy = max( record.minY - position.y, 0, position.y - record.maxY )
			local dz = max( record.minZ - position.z, 0, position.z - record.maxZ )
			if dx * dx + dy * dy + dz * dz <= squared then
				count = count + 1
				output[count] = entity
			end
		end
	end
	for i = count + 1, previous do output[i] = nil end
	return output
end

local pickupPlayers, playersAt = {}, -math.huge

-- Player bounds used to be reallocated for every item/player pair. Cache the
-- numeric bounds once per engine tick, including the vehicle pickup union.
function Q.PickupPlayers()
	local current = CurTime()
	if playersAt == current then return pickupPlayers end
	playersAt = current
	local players, count = player.GetAll(), 0
	local size = Coords.BlockSize()
	for i = 1, #players do
		local ply = players[i]
		if IsValid( ply ) and ply:Alive() then
			local minimum, maximum = Coords.EntityWorldAABB( ply )
			if isvector( minimum ) and isvector( maximum ) then
				count = count + 1
				local record = pickupPlayers[count]
				if not record then record = {}; pickupPlayers[count] = record end
				record.entity = ply
				record.minX, record.minY, record.minZ = minimum.x, minimum.y, minimum.z
				record.maxX, record.maxY, record.maxZ = maximum.x, maximum.y, maximum.z
				local inflateZ = size * 0.5
				if ply:InVehicle() then
					local vehicleMin, vehicleMax = Coords.EntityWorldAABB( ply:GetVehicle() )
					if isvector( vehicleMin ) and isvector( vehicleMax ) then
						minimum.x, minimum.y, minimum.z = min( minimum.x, vehicleMin.x ),
							min( minimum.y, vehicleMin.y ), min( minimum.z, vehicleMin.z )
						maximum.x, maximum.y, maximum.z = max( maximum.x, vehicleMax.x ),
							max( maximum.y, vehicleMax.y ), max( maximum.z, vehicleMax.z )
					end
					inflateZ = 0
				end
				record.pickMinX, record.pickMinY, record.pickMinZ = minimum.x - size, minimum.y - size, minimum.z - inflateZ
				record.pickMaxX, record.pickMaxY, record.pickMaxZ = maximum.x + size, maximum.y + size, maximum.z + inflateZ
			else
				MC.Fault( "item_drop_player_bounds", "Cannot query pickup bounds for %s", ply )
			end
		end
	end
	for i = #pickupPlayers, count + 1, -1 do pickupPlayers[i] = nil end
	return pickupPlayers
end

hook.Add( "OnEntityCreated", "mcgame_item_drop_query", Q.Register )
hook.Add( "EntityRemoved", "mcgame_item_drop_query", Q.Unregister )
hook.Add( "PlayerDisconnected", "mcgame_item_drop_query_players", function( ply )
	for i = #pickupPlayers, 1, -1 do
		if pickupPlayers[i].entity == ply then
			pickupPlayers[i] = pickupPlayers[#pickupPlayers]
			pickupPlayers[#pickupPlayers] = nil
		end
	end
	playersAt = -math.huge
end )
-- One cold scan also makes Lua auto-refresh safe for already spawned drops.
local existing = ents.FindByClass( "mc_item_drop" )
for i = 1, #existing do Q.Register( existing[i] ) end
