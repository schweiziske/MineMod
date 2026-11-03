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
	return math.max( 0.001, coordinateAPI.BlockSize() )
end

function R.WorldBounds( entity )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.EntityWorldAABB ) ~= "function" then return nil, nil end
	local minimum, maximum = coordinateAPI.EntityWorldAABB( entity )
	if not isvector or not isvector( minimum ) or not isvector( maximum ) then return nil, nil end
	-- The public coordinate API already returns owned vectors.
	return minimum, maximum
end

function R.FootWorldPosition( entity, minimum, maximum, output )
	minimum, maximum = minimum or nil, maximum or nil
	if not minimum or not maximum then minimum, maximum = R.WorldBounds( entity ) end
	if not minimum or not maximum then return nil end
	output = output or Vector( 0, 0, 0 )
	output.x, output.y, output.z = ( minimum.x + maximum.x ) * 0.5, ( minimum.y + maximum.y ) * 0.5, minimum.z
	return output
end

function R.BlockNameAt( bx, by, bz )
	local worldAPI = world()
	if not worldAPI or type( worldAPI.GetBlockInfo ) ~= "function" then return "minecraft:air" end
	local blocks = api().Blocks
	local name
	if worldAPI.GetBlockState and blocks and blocks.Name then
		local stateId = worldAPI.GetBlockState( bx, by, bz )
		name = blocks.Name( stateId )
	else
		local info = worldAPI.GetBlockInfo( bx, by, bz )
		name = type( info ) == "table" and ( info.mcid or info.name ) or nil
	end
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

local function deflatedRange( minimum, maximum, amount, lo, hi )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.WorldToCell ) ~= "function" then return nil end
	local inset = math.max( R.BlockSize() * amount, 0.000001 )
	lo, hi = lo or Vector( 0, 0, 0 ), hi or Vector( 0, 0, 0 )
	lo.x, lo.y, lo.z = minimum.x + inset, minimum.y + inset, minimum.z + inset
	hi.x, hi.y, hi.z = maximum.x - inset, maximum.y - inset, maximum.z - inset
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z then return nil end
	local x0, y0, z0 = coordinateAPI.WorldToCell( lo )
	local x1, y1, z1 = coordinateAPI.WorldToCell( hi )
	if x0 == nil or x1 == nil then return nil end
	return x0, y0, z0, x1, y1, z1, lo, hi
end

local function emptyTracker()
	return { height = 0, flowX = 0, flowY = 0, flowZ = 0, count = 0 }
end

local function clearTracker( tracker )
	tracker.height, tracker.flowX, tracker.flowY, tracker.flowZ, tracker.count = 0, 0, 0, 0, 0
end

function R.FluidTrackersForBounds( minimum, maximum, output )
	local liquidAPI, coordinateAPI = liquid(), coords()
	output = output or { water = emptyTracker(), lava = emptyTracker(),
		queryMin = Vector( 0, 0, 0 ), queryMax = Vector( 0, 0, 0 ) }
	clearTracker( output.water )
	clearTracker( output.lava )
	if not liquidAPI or type( liquidAPI.GetAt ) ~= "function"
	or type( liquidAPI.FlowAt ) ~= "function" or not coordinateAPI then return output end
	local x0, y0, z0, x1, y1, z1 = deflatedRange( minimum, maximum, C.fluidBoundsDeflate, output.queryMin, output.queryMax )
	if x0 == nil then return output end
	local size = R.BlockSize()
	-- Java loop order is x, vertical y, horizontal z. MineMod maps those axes to
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

local function insideScratch( scratch )
	scratch = scratch or {}
	if not scratch.output then
		scratch.output, scratch.pool = {}, {}
		scratch.minimum, scratch.maximum = Vector( 0, 0, 0 ), Vector( 0, 0, 0 )
		scratch.queryMin, scratch.queryMax = Vector( 0, 0, 0 ), Vector( 0, 0, 0 )
	end
	scratch.hasRange = false
	return scratch
end

local function appendInsideCells( minimum, maximum, step, scratch, count )
	local x0, y0, z0, x1, y1, z1 = deflatedRange( minimum, maximum, C.insideBoundsDeflate, scratch.queryMin, scratch.queryMax )
	if x0 == nil then return count end
	if scratch.hasRange and x0 == scratch.x0 and y0 == scratch.y0 and z0 == scratch.z0
	and x1 == scratch.x1 and y1 == scratch.y1 and z1 == scratch.z1 then return count end
	scratch.hasRange = true
	scratch.x0, scratch.y0, scratch.z0, scratch.x1, scratch.y1, scratch.z1 = x0, y0, z0, x1, y1, z1
	local output, pool, liquidAPI = scratch.output, scratch.pool, liquid()
	for bx = x0, x1 do
		for bz = z0, z1 do
			for by = y0, y1 do
				-- Item AABBs cover only a handful of cells. Numeric comparisons
				-- avoid a fresh visited hash and concatenated coordinate strings.
				local seen = false
				for i = 1, count do
					local cell = output[i]
					if cell.bx == bx and cell.by == by and cell.bz == bz then seen = true; break end
				end
				if not seen then
					local name = R.BlockNameAt( bx, by, bz )
					local fluid = liquidAPI and liquidAPI.GetAt and liquidAPI.GetAt( bx, by, bz ) or nil
					if name ~= "minecraft:air" or fluid then
						count = count + 1
						local cell = pool[count]
						if not cell then cell = {}; pool[count] = cell end
						cell.bx, cell.by, cell.bz, cell.name, cell.fluid, cell.stepIndex = bx, by, bz, name, fluid, step
						output[count] = cell
					end
				end
			end
		end
	end
	return count
end

function R.InsideCellsForBounds( minimum, maximum )
	local scratch = insideScratch()
	appendInsideCells( minimum, maximum, 0, scratch, 0 )
	return scratch.output
end

function R.InsideCellsAlongPath( startMinimum, startMaximum, endMinimum, endMaximum, scratch )
	startMinimum, startMaximum = startMinimum or endMinimum, startMaximum or endMaximum
	scratch = insideScratch( scratch )
	local size = R.BlockSize()
	local lx, ly, lz = endMinimum.x - startMinimum.x, endMinimum.y - startMinimum.y, endMinimum.z - startMinimum.z
	local hx, hy, hz = endMaximum.x - startMaximum.x, endMaximum.y - startMaximum.y, endMaximum.z - startMaximum.z
	local dx, dy, dz = ( lx + hx ) * 0.5, ( ly + hy ) * 0.5, ( lz + hz ) * 0.5
	local distance = math.sqrt( dx * dx + dy * dy + dz * dz ) / size
	local steps = math.max( 1, math.min( 16, math.ceil( distance ) ) )
	local output, count = scratch.output, 0
	local previous = #output
	local minimum, maximum = scratch.minimum, scratch.maximum
	for step = 0, steps do
		local fraction = step / steps
		minimum.x, minimum.y, minimum.z = startMinimum.x + lx * fraction, startMinimum.y + ly * fraction, startMinimum.z + lz * fraction
		maximum.x, maximum.y, maximum.z = startMaximum.x + hx * fraction, startMaximum.y + hy * fraction, startMaximum.z + hz * fraction
		count = appendInsideCells( minimum, maximum, step, scratch, count )
	end
	for i = count + 1, previous do output[i] = nil end
	return output
end

function R.MovementBlockSample( entity, minimum, maximum, output )
	output = output or {}
	minimum, maximum = minimum or nil, maximum or nil
	if not minimum or not maximum then minimum, maximum = R.WorldBounds( entity ) end
	local foot = minimum and R.FootWorldPosition( entity, minimum, maximum, output.foot ) or nil
	local coordinateAPI = coords()
	if not foot or not coordinateAPI or type( coordinateAPI.WorldToCell ) ~= "function" then
		return { hereName = "minecraft:air", belowName = "minecraft:air", foot = foot }
	end
	local bx, by, bz = coordinateAPI.WorldToCell( foot )
	local below = output.belowPosition or Vector( 0, 0, 0 )
	below.x, below.y, below.z = foot.x, foot.y, foot.z - R.BlockSize() * 0.999999
	output.belowPosition = below
	local belowX, belowY, belowZ = coordinateAPI.WorldToCell( below )
	output.foot, output.blockX, output.blockY, output.blockZ = foot, bx, by, bz
	output.hereName = bx and R.BlockNameAt( bx, by, bz ) or "minecraft:air"
	output.belowName = belowX and R.BlockNameAt( belowX, belowY, belowZ ) or "minecraft:air"
	return output
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
