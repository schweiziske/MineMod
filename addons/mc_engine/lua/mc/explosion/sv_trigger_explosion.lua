--[[----------------------------------------------------------------------------
	MC : public-server implementation of Explosion.BlockInteraction.TRIGGER_BLOCK.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.Explosion = MC.Explosion or {}

local SV = MC.SV
local Explosion = MC.Explosion

local DEFAULT_IMMUNE_BLOCKS = {
	["minecraft:barrier"] = true,
	["minecraft:bedrock"] = true,
}

local function normalizedName( value )
	if not isstring( value ) or value == "" then return nil end
	return string.find( value, ":", 1, true ) and value or "minecraft:" .. value
end

local function immuneSet( input )
	if input == false then return nil end
	input = istable( input ) and input or DEFAULT_IMMUNE_BLOCKS
	local result = {}
	for key, value in pairs( input ) do
		local name
		if isnumber( key ) then name = normalizedName( value )
		elseif value == true then name = normalizedName( key ) end
		if name then result[name] = true end
	end
	return result
end

local function shuffle( values )
	for index = #values, 2, -1 do
		local other = math.random( 1, index )
		values[index], values[other] = values[other], values[index]
	end
end

function SV.TriggerBlockExplosion( center, radius, options )
	if not isvector( center ) then return false, 0, "invalid_center" end
	radius = tonumber( radius ) or 0
	if radius <= 0 then return false, 0, "invalid_radius" end
	options = istable( options ) and options or {}
	if options.interaction ~= nil and options.interaction ~= "trigger_block" then
		return false, 0, "invalid_interaction"
	end
	if not isfunction( Explosion.SelectJavaExplosionCells )
		or not isfunction( Explosion.TriggerBlockOnExplosionHit ) then
		return false, 0, "trigger_explosion_unavailable"
	end

	local immune = immuneSet( options.immuneBlocks )
	local customResistance = options.blockResistance
	local selected, selectionError = Explosion.SelectJavaExplosionCells( center, radius, {
		inBounds = function( bx, by, bz )
			return not SV.WorldBoundsOK or SV.WorldBoundsOK( bx, by, bz )
		end,
		resistance = function( stateId, bx, by, bz, remainingPower )
			if isfunction( customResistance ) then
				return customResistance( stateId, bx, by, bz, remainingPower, options )
			end
			if immune then
				local name = Explosion.StateName and Explosion.StateName( stateId ) or nil
				-- SimpleExplosionDamageCalculator returns Optional.empty() for every
				-- non-immune block when an immune tag is supplied. Do not substitute
				-- the block's ordinary blast resistance here.
				return name and immune[name] and 3600000 or nil
			end
			local blockId = MC.LegacyFromState and MC.LegacyFromState( stateId ) or nil
			return blockId and MC.BlockExplosionResistance and MC.BlockExplosionResistance( blockId ) or nil
		end,
		shouldSelect = function()
			-- SimpleExplosionDamageCalculator(explodesBlocks=true).
			return true
		end,
	} )
	if not selected then return false, 0, selectionError or "selection_failed" end

	shuffle( selected ) -- ServerExplosion uses Util.shuffle before interaction.
	local triggered = 0
	for index = 1, #selected do
		local cell = selected[index]
		local stateId = MC.GetBlockState( cell.bx, cell.by, cell.bz ) or 0
		if stateId ~= 0 and Explosion.TriggerBlockOnExplosionHit( {
			bx = cell.bx,
			by = cell.by,
			bz = cell.bz,
			stateId = stateId,
			center = center,
			radius = radius,
			actor = options.actor,
			source = options.source,
			interaction = "trigger_block",
			canTriggerBlocks = options.canTriggerBlocks ~= false,
			shouldAffectBlocklikeEntities = false,
			options = options,
		} ) then
			triggered = triggered + 1
		end
	end

	if MC.RunEvent then
		MC.RunEvent( "MC.TriggerExplosionFinished", center, radius, triggered, #selected, options )
	end
	return true, triggered, #selected
end

