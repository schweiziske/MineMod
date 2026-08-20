-- Public-engine and optional-MCITEM adapters for block physics.  This module
-- never reads the engine's storage/registry tables directly.

MC = MC or {}
MC.BlockPhysics = MC.BlockPhysics or {}

local P = MC.BlockPhysics
local C = P.Constants

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

function P.BlockSize()
	local coordinateAPI = coords()
	local value = coordinateAPI and coordinateAPI.BlockSize and coordinateAPI.BlockSize() or 36.5
	return math.max( tonumber( value ) or 36.5, 0.001 )
end

function P.BlockNameFromInfo( info )
	if type( info ) ~= "table" then return "minecraft:air" end
	return P.NormalizeBlockName( info.mcid or info.name )
end

function P.BlockInfoAt( bx, by, bz )
	local worldAPI = world()
	if not worldAPI or type( worldAPI.GetBlockInfo ) ~= "function" then return nil end
	return worldAPI.GetBlockInfo( bx, by, bz )
end

function P.BlockNameAt( bx, by, bz )
	return P.BlockNameFromInfo( P.BlockInfoAt( bx, by, bz ) )
end

function P.WorldOriginForMove( entity, move )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.EntityWorldPos ) ~= "function" then return nil end
	local base = coordinateAPI.EntityWorldPos( entity )
	if not isvector or not isvector( base ) then return nil end
	if not move or type( move.GetOrigin ) ~= "function" or type( entity.GetPos ) ~= "function" then
		return Vector( base.x, base.y, base.z )
	end
	local moveOrigin, engineOrigin = move:GetOrigin(), entity:GetPos()
	if not isvector( moveOrigin ) or not isvector( engineOrigin ) then
		return Vector( base.x, base.y, base.z )
	end
	return Vector(
		base.x + moveOrigin.x - engineOrigin.x,
		base.y + moveOrigin.y - engineOrigin.y,
		base.z + moveOrigin.z - engineOrigin.z
	)
end

local function copiedBounds( minimum, maximum )
	if not isvector or not isvector( minimum ) or not isvector( maximum ) then return nil, nil end
	return Vector( minimum.x, minimum.y, minimum.z ), Vector( maximum.x, maximum.y, maximum.z )
end

function P.WorldBoundsForEntity( entity, move )
	if move and type( entity.OBBMins ) == "function" and type( entity.OBBMaxs ) == "function" then
		local origin = P.WorldOriginForMove( entity, move )
		local minimum, maximum = entity:OBBMins(), entity:OBBMaxs()
		if origin and isvector( minimum ) and isvector( maximum ) then
			return origin + minimum, origin + maximum, origin
		end
	end
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.EntityWorldAABB ) ~= "function" then return nil, nil, nil end
	local minimum, maximum = coordinateAPI.EntityWorldAABB( entity )
	minimum, maximum = copiedBounds( minimum, maximum )
	local origin = coordinateAPI.EntityWorldPos and coordinateAPI.EntityWorldPos( entity ) or nil
	if origin and type( entity.MCBlockPhysicsWorldOrigin ) == "function" then
		local ok, override = pcall( entity.MCBlockPhysicsWorldOrigin, entity, minimum, maximum, origin )
		if ok and isvector( override ) then origin = override end
	end
	return minimum, maximum, origin
end

local function intersectedCellRange( minimum, maximum )
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.WorldToCell ) ~= "function" then return nil end
	local blockSize = P.BlockSize()
	local inset = math.max( blockSize * C.insideBoundsDeflate, 0.000001 )
	local lo = Vector( minimum.x + inset, minimum.y + inset, minimum.z + inset )
	local hi = Vector( maximum.x - inset, maximum.y - inset, maximum.z - inset )
	if hi.x < lo.x or hi.y < lo.y or hi.z < lo.z then return nil end
	local minX, minY, minZ = coordinateAPI.WorldToCell( lo )
	local maxX, maxY, maxZ = coordinateAPI.WorldToCell( hi )
	if minX == nil or maxX == nil then return nil end
	return minX, minY, minZ, maxX, maxY, maxZ
end

function P.SampleBounds( minimum, maximum )
	if not isvector or not isvector( minimum ) or not isvector( maximum ) then return nil end
	local minX, minY, minZ, maxX, maxY, maxZ = intersectedCellRange( minimum, maximum )
	if minX == nil then return nil end
	local result = {
		hasCobweb = false,
		honeyCells = {},
		cellsVisited = 0,
	}
	for bx = minX, maxX do
		for by = minY, maxY do
			for bz = minZ, maxZ do
				result.cellsVisited = result.cellsVisited + 1
				local name = P.BlockNameAt( bx, by, bz )
				if name == "minecraft:cobweb" then
					result.hasCobweb = true
				elseif name == "minecraft:honey_block" then
					result.honeyCells[#result.honeyCells + 1] = { bx = bx, by = by, bz = bz }
				end
			end
		end
	end
	return result
end

function P.SampleEntity( entity, move )
	local minimum, maximum, origin = P.WorldBoundsForEntity( entity, move )
	if not minimum or not maximum or not origin then return nil end
	local coordinateAPI = coords()
	if not coordinateAPI or type( coordinateAPI.WorldToCell ) ~= "function" then return nil end
	local blockSize = P.BlockSize()
	local bx, by, bz = coordinateAPI.WorldToCell( origin )
	local belowX, belowY, belowZ = coordinateAPI.WorldToCell(
		origin - Vector( 0, 0, blockSize * 0.500001 )
	)
	local onX, onY, onZ = coordinateAPI.WorldToCell(
		origin - Vector( 0, 0, blockSize * 0.2 )
	)
	local inside = P.SampleBounds( minimum, maximum ) or { hasCobweb = false, honeyCells = {} }
	inside.origin = origin
	inside.minimum = minimum
	inside.maximum = maximum
	inside.blockX, inside.blockY, inside.blockZ = bx, by, bz
	inside.hereName = bx and P.BlockNameAt( bx, by, bz ) or "minecraft:air"
	inside.belowName = belowX and P.BlockNameAt( belowX, belowY, belowZ ) or "minecraft:air"
	inside.onName = onX and P.BlockNameAt( onX, onY, onZ ) or "minecraft:air"
	inside.widthBlocks = math.max( maximum.x - minimum.x, maximum.y - minimum.y ) / blockSize
	return inside
end

function P.EffectiveMovementBlock( sample )
	if type( sample ) ~= "table" then return "minecraft:air" end
	local here = P.SpeedFactorFor( sample.hereName )
	return here == C.defaultSpeedFactor and sample.belowName or sample.hereName
end

function P.EffectiveFrictionBlock( sample )
	return type( sample ) == "table" and sample.belowName or "minecraft:air"
end

local function clientHasEffect( entity, effectId )
	local potions = MCITEM and MCITEM.Potions or nil
	if not potions or type( potions.ClientEffects ) ~= "function" then return nil end
	local ok, effects = pcall( potions.ClientEffects, entity )
	if not ok or type( effects ) ~= "table" then return nil end
	for _, effect in pairs( effects ) do
		if type( effect ) == "table" and P.NormalizeBlockName( effect.id ) == P.NormalizeBlockName( effectId ) then
			return true
		end
	end
	return false
end

function P.HasMobEffect( entity, effectId )
	if hook and hook.Run then
		local handled = hook.Run( "MC.BlockPhysicsMobEffectQuery", entity, effectId )
		if handled ~= nil then return handled == true end
	end
	local potions = MCITEM and MCITEM.Potions or nil
	if SERVER and potions and type( potions.HasEffect ) == "function" then
		local ok, active = pcall( potions.HasEffect, entity, effectId )
		if ok then return active == true end
	end
	if CLIENT then
		local active = clientHasEffect( entity, effectId )
		if active ~= nil then return active end
	end
	-- Optional addon missing or its snapshot unavailable: source-compatible
	-- conservative default is the ordinary (more restrictive) web multiplier.
	return false
end

function P.EquipmentEnchantmentLevel( entity, slot, enchantmentId )
	if hook and hook.Run then
		local handled = hook.Run( "MC.BlockPhysicsEquipmentEnchantmentLevel", entity, slot, enchantmentId )
		if handled ~= nil then return math.max( 0, math.floor( tonumber( handled ) or 0 ) ) end
	end
	local runtime = MCITEM and MCITEM.EnchantmentRuntime or nil
	if not runtime or type( runtime.GetEquipmentLevel ) ~= "function" then return 0 end
	local ok, level = pcall( runtime.GetEquipmentLevel, entity, slot, enchantmentId )
	if not ok then return 0 end
	return math.max( 0, math.floor( tonumber( level ) or 0 ) )
end

function P.VelocityToBlocksPerTick( velocity )
	if not isvector or not isvector( velocity ) then return 0, 0, 0 end
	local scale = P.BlockSize() / C.tickSeconds
	return velocity.x / scale, velocity.y / scale, velocity.z / scale
end

function P.BlocksPerTickToVelocity( x, y, z )
	local scale = P.BlockSize() / C.tickSeconds
	return Vector( ( tonumber( x ) or 0 ) * scale, ( tonumber( y ) or 0 ) * scale, ( tonumber( z ) or 0 ) * scale )
end
