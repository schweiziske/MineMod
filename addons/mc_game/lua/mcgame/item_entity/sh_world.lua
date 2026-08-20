-- Read-only MC.API adapters for ItemEntity parity.  No engine registry/storage
-- table is read here; all coordinates are Minecraft world-space and InfMap-safe.

MC = MC or {}
MC.ItemEntityParity = MC.ItemEntityParity or {}

local R = MC.ItemEntityParity
local C = R.Constants

local function api()
	return MC and MC.API or nil
end

local function coords()
	local value = api()
	return value and value.Coords or nil
end

local function world()
	local value = api()
	return value and value.World or nil
end

local function liquid()
	local value = api()
	return value and value.Liquid or nil
end

function R.BlockSize()
	local coordinateAPI = coords()
	local value = coordinateAPI and coordinateAPI.BlockSize and coordinateAPI.BlockSize() or 36.5
	return math.max( 0.001, tonumber( value ) or 36.5 )
end

function R.WorldBounds( entity )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.EntityWorldAABB ) ~= "function" then return nil, nil end
	local minimum, maximum = coordinateAPI.EntityWorldAABB( entity )
	if not isvector or not isvector( minimum ) or not isvector( maximum ) then return nil, nil end
	return Vector( minimum.x, minimum.y, minimum.z ), Vector( maximum.x, maximum.y, maximum.z )
end

function R.FootWorldPosition( entity, minimum, maximum )
	minimum, maximum = minimum or nil, maximum or nil
	if not minimum or not maximum then minimum, maximum = R.WorldBounds( entity ) end
	if not minimum or not maximum then return nil end
	return Vector( ( minimum.x + maximum.x ) * 0.5, ( minimum.y + maximum.y ) * 0.5, minimum.z )
end

function R.BlockNameAt( bx, by, bz )
	local worldAPI = world()
	if not worldAPI or type( worldAPI.GetBlockInfo ) ~= "function" then return "minecraft:air" end
	local info = worldAPI.GetBlockInfo( bx, by, bz )
	local name = type( info ) == "table" and ( info.mcid or info.name ) or nil
	name = tostring( name or "" )
	if name == "" then return "minecraft:air" end
	return string.find( name, ":", 1, true ) and name or "minecraft:" .. name
end

function R.CellWorldBounds( bx, by, bz )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.CellMin ) ~= "function" then return nil, nil end
	local minimum = coordinateAPI.CellMin( bx, by, bz )
	if not isvector or not isvector( minimum ) then return nil, nil end
	local size = R.BlockSize()
	return minimum, minimum + Vector( size, size, size )
end

local function deflatedRange( minimum, maximum, amount )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.WorldToCell ) ~= "function" then return nil end
	local inset = math.max( R.BlockSize() * amount, 0.000001 )
	local lo = minimum + Vector( inset, inset, inset )
	local hi = maximum - Vector( inset, inset, inset )
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z then return nil end
	local x0, y0, z0 = coordinateAPI.WorldToCell( lo )
	local x1, y1, z1 = coordinateAPI.WorldToCell( hi )
	if x0 == nil or x1 == nil then return nil end
	return x0, y0, z0, x1, y1, z1, lo, hi
end

local function emptyTracker()
	return { height = 0, flowX = 0, flowY = 0, flowZ = 0, count = 0 }
end

function R.FluidTrackersForBounds( minimum, maximum )
	local liquidAPI, coordinateAPI = liquid(), coords()
	local output = { water = emptyTracker(), lava = emptyTracker() }
	if not liquidAPI or type( liquidAPI.GetAt ) ~= "function"
	or type( liquidAPI.FlowAt ) ~= "function" or not coordinateAPI then return output end
	local x0, y0, z0, x1, y1, z1 = deflatedRange( minimum, maximum, C.fluidBoundsDeflate )
	if x0 == nil then return output end
	local size = R.BlockSize()
	-- Java loop order is x, vertical y, horizontal z. MCSWEP maps those axes to
	-- bx, bz, by respectively; the order matters while tracker.height grows.
	for bx = x0, x1 do
		for bz = z0, z1 do
			for by = y0, y1 do
				local fluid = liquidAPI.GetAt( bx, by, bz )
				local tracker = fluid and output[fluid.kind] or nil
				if tracker then
					local cellMin = coordinateAPI.CellMin and coordinateAPI.CellMin( bx, by, bz ) or nil
					local surface = cellMin and cellMin.z + ( tonumber( fluid.height ) or 0 ) * size or nil
					if surface and surface >= minimum.z + size * C.fluidBoundsDeflate then
						tracker.height = math.max( tracker.height, ( surface - minimum.z ) / size )
						local flowX, flowY, flowZ = liquidAPI.FlowAt( bx, by, bz, fluid.kind )
						if tracker.height < C.currentHeightScaleThreshold then
							flowX, flowY, flowZ = flowX * tracker.height,
								flowY * tracker.height, flowZ * tracker.height
						end
						tracker.flowX = tracker.flowX + ( tonumber( flowX ) or 0 )
						tracker.flowY = tracker.flowY + ( tonumber( flowY ) or 0 )
						tracker.flowZ = tracker.flowZ + ( tonumber( flowZ ) or 0 )
						tracker.count = tracker.count + 1
					end
				end
			end
		end
	end
	return output
end

function R.SampleEntityFluids( entity )
	local minimum, maximum = R.WorldBounds( entity )
	if not minimum then return { water = emptyTracker(), lava = emptyTracker() } end
	return R.FluidTrackersForBounds( minimum, maximum )
end

function R.InsideCellsForBounds( minimum, maximum )
	local liquidAPI = liquid()
	local x0, y0, z0, x1, y1, z1 = deflatedRange( minimum, maximum, C.insideBoundsDeflate )
	if x0 == nil then return {} end
	local cells = {}
	for bx = x0, x1 do
		for bz = z0, z1 do
			for by = y0, y1 do
				local name = R.BlockNameAt( bx, by, bz )
				local fluid = liquidAPI and liquidAPI.GetAt and liquidAPI.GetAt( bx, by, bz ) or nil
				if name ~= "minecraft:air" or fluid then
					cells[#cells + 1] = { bx = bx, by = by, bz = bz, name = name, fluid = fluid }
				end
			end
		end
	end
	return cells
end

local function cellKey( cell )
	return tostring( cell.bx ) .. ":" .. tostring( cell.by ) .. ":" .. tostring( cell.bz )
end

function R.InsideCellsAlongPath( startMinimum, startMaximum, endMinimum, endMaximum )
	if not startMinimum or not startMaximum then return R.InsideCellsForBounds( endMinimum, endMaximum ) end
	local size = R.BlockSize()
	local startCenter = ( startMinimum + startMaximum ) * 0.5
	local endCenter = ( endMinimum + endMaximum ) * 0.5
	local delta = endCenter - startCenter
	local distance = math.sqrt( delta.x * delta.x + delta.y * delta.y + delta.z * delta.z ) / size
	local steps = math.max( 1, math.min( 16, math.ceil( distance ) ) )
	local output, visited = {}, {}
	for step = 0, steps do
		local fraction = step / steps
		local minimum = startMinimum + ( endMinimum - startMinimum ) * fraction
		local maximum = startMaximum + ( endMaximum - startMaximum ) * fraction
		for _, cell in ipairs( R.InsideCellsForBounds( minimum, maximum ) ) do
			local key = cellKey( cell )
			if not visited[key] then
				visited[key] = true
				cell.stepIndex = step
				output[#output + 1] = cell
			end
		end
	end
	return output
end

function R.MovementBlockSample( entity, minimum, maximum )
	minimum, maximum = minimum or nil, maximum or nil
	if not minimum or not maximum then minimum, maximum = R.WorldBounds( entity ) end
	local foot = minimum and R.FootWorldPosition( entity, minimum, maximum ) or nil
	local coordinateAPI = coords()
	if not foot or not coordinateAPI or type( coordinateAPI.WorldToCell ) ~= "function" then
		return { hereName = "minecraft:air", belowName = "minecraft:air", foot = foot }
	end
	local bx, by, bz = coordinateAPI.WorldToCell( foot )
	local belowX, belowY, belowZ = coordinateAPI.WorldToCell(
		foot - Vector( 0, 0, R.BlockSize() * 0.999999 )
	)
	return {
		foot = foot,
		blockX = bx, blockY = by, blockZ = bz,
		hereName = bx and R.BlockNameAt( bx, by, bz ) or "minecraft:air",
		belowName = belowX and R.BlockNameAt( belowX, belowY, belowZ ) or "minecraft:air",
	}
end

function R.MovedAcrossCell( fromPosition, toPosition )
	local coordinateAPI = coords()
	if not fromPosition or not toPosition or not coordinateAPI
	or type( coordinateAPI.WorldToCell ) ~= "function" then return false end
	local ax, ay, az = coordinateAPI.WorldToCell( fromPosition )
	local bx, by, bz = coordinateAPI.WorldToCell( toPosition )
	return ax ~= bx or ay ~= by or az ~= bz
end

local function minmaxBounds( aMin, aMax, bMin, bMax )
	return Vector( math.min( aMin.x, bMin.x ), math.min( aMin.y, bMin.y ), math.min( aMin.z, bMin.z ) ),
		Vector( math.max( aMax.x, bMax.x ), math.max( aMax.y, bMax.y ), math.max( aMax.z, bMax.z ) )
end

function R.PlayerPickupBounds( ply )
	local minimum, maximum = R.WorldBounds( ply )
	if not minimum then return nil, nil end
	if ply.InVehicle and ply:InVehicle() and ply.GetVehicle then
		local vehicle = ply:GetVehicle()
		local vehicleMin, vehicleMax = R.WorldBounds( vehicle )
		if vehicleMin then minimum, maximum = minmaxBounds( minimum, maximum, vehicleMin, vehicleMax ) end
		local size = R.BlockSize()
		return minimum - Vector( size, size, 0 ), maximum + Vector( size, size, 0 )
	end
	local size = R.BlockSize()
	return minimum - Vector( size, size, size * 0.5 ), maximum + Vector( size, size, size * 0.5 )
end

function R.PlayerTouchesItem( ply, item )
	local playerMin, playerMax = R.PlayerPickupBounds( ply )
	local itemMin, itemMax = R.WorldBounds( item )
	return playerMin and itemMin and R.AABBIntersects( playerMin, playerMax, itemMin, itemMax ) or false
end
