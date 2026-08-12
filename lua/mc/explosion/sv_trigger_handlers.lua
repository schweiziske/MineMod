--[[----------------------------------------------------------------------------
	MC : Java 26.2 Block#onExplosionHit TRIGGER_BLOCK handlers.

	Normal blocks remain untouched. Only vanilla overrides are represented here;
	custom blocks can provide handlers.OnExplosionHit or listen to the documented
	MC.TriggerExplosionBlock hook.
------------------------------------------------------------------------------]]

if not SERVER then return end

MC = MC or {}
MC.SV = MC.SV or {}
MC.Explosion = MC.Explosion or {}

local SV = MC.SV
local Explosion = MC.Explosion

local function stateInfo( stateId )
	local schema = MC.BlockStateSchemaForState and MC.BlockStateSchemaForState( stateId ) or nil
	local blockId = schema and schema.blockId or nil
	local block = blockId and MC.Blocks and MC.Blocks[blockId] or nil
	if not block and MC.LegacyFromState then
		blockId = MC.LegacyFromState( stateId )
		block = blockId and MC.Blocks and MC.Blocks[blockId] or nil
	end
	local name = schema and schema.name or block and ( block.mcid or block.name ) or nil
	if name and not string.find( name, ":", 1, true ) then name = "minecraft:" .. name end
	return name, block, schema, blockId
end

function Explosion.StateName( stateId )
	local name = stateInfo( stateId )
	return name
end

local function callHandler( handler, ... )
	local ok, result = pcall( handler, ... )
	if ok then return result end
	local message = "[MC] explosion block handler error: " .. tostring( result ) .. "\n"
	if ErrorNoHalt then ErrorNoHalt( message ) else print( message ) end
	return false
end

local function callUseHandler( context )
	local handlers = context.block and context.block.handlers
	local handler = handlers and handlers.OnUse
	if not isfunction( handler ) then return false end
	local orient = MC.GetBlockOrient and MC.GetBlockOrient( context.bx, context.by, context.bz ) or 0
	return callHandler( handler, nil, context.bx, context.by, context.bz, orient, nil ) == true
end

local function setState( context, nextState )
	if not nextState or nextState == context.stateId or not SV.SetBlockState then return false end
	local result = SV.SetBlockState( context.bx, context.by, context.bz, nextState, {
		actor = context.actor,
		fx = false,
		handlers = false,
		compareCollision = true,
		priorityPhys = true,
		immediatePhys = true,
	} )
	return result and result.ok == true and ( result.changed or 0 ) > 0
end

local function triggerDoor( context )
	if MC.GetStateProperty( context.stateId, "half" ) ~= "lower" then return false end
	if MC.GetStateProperty( context.stateId, "powered" ) == true then return false end
	if not context.blockId then return false end
	if MC.DoorCanOpenByHand and not MC.DoorCanOpenByHand( context.blockId ) then return false end
	return callUseHandler( context )
end

local function triggerTrapdoor( context )
	if MC.GetStateProperty( context.stateId, "powered" ) == true then return false end
	if not context.blockId then return false end
	if MC.TrapdoorCanOpenByHand and not MC.TrapdoorCanOpenByHand( context.blockId ) then return false end
	return callUseHandler( context )
end

local function triggerFenceGate( context )
	if MC.GetStateProperty( context.stateId, "powered" ) == true then return false end
	return callUseHandler( context )
end

local function triggerLever( context )
	return callUseHandler( context )
end

local function triggerButton( context )
	if MC.GetStateProperty( context.stateId, "powered" ) == true then return false end
	return callUseHandler( context )
end

local function triggerBell( context )
	-- BellBlock.attemptToRing receives a null direction for explosions and falls
	-- back to the block state's facing. MCSWEP has no BellBlockEntity animation,
	-- so integrations receive the exact logical ring through this event.
	context.ringDirection = MC.GetStateProperty( context.stateId, "facing" )
	if MC.RunEvent then MC.RunEvent( "MC.BellRungByExplosion", context ) end
	return true
end

local function triggerCandle( context )
	if MC.GetStateProperty( context.stateId, "lit" ) ~= true then return false end
	local nextState = MC.StateWith and MC.StateWith( context.stateId, "lit", false ) or nil
	if not setState( context, nextState ) then return false end
	if MC.RunEvent then MC.RunEvent( "MC.CandleExtinguishedByExplosion", context ) end
	return true
end

local function triggerBeehive( context )
	-- BeehiveBlock calls angerNearbyBees even for TRIGGER_BLOCK. The voxel addon
	-- does not own a bee AI system, so the exact 8x6x8 targeting operation is an
	-- integration event instead of silently substituting unrelated NPC logic.
	if MC.RunEvent then MC.RunEvent( "MC.BeehiveAngeredByExplosion", context ) end
	return true
end

local function isCandle( name )
	return name == "minecraft:candle" or name == "minecraft:candle_cake"
		or string.match( name or "", "_candle$") ~= nil
		or string.match( name or "", "_candle_cake$") ~= nil
end

function Explosion.TriggerBlockOnExplosionHit( context )
	if not istable( context ) or not isnumber( context.stateId ) or context.stateId == 0 then return false end
	context.name, context.block, context.schema, context.blockId = stateInfo( context.stateId )
	if not context.name or not context.block then return false end

	if MC.RunEvent then
		local overridden = MC.RunEvent( "MC.TriggerExplosionBlock", context )
		if overridden ~= nil then return overridden == true end
	end

	local custom = context.block.handlers and context.block.handlers.OnExplosionHit
	if isfunction( custom ) then
		local handled = callHandler( custom, context )
		if handled ~= nil then return handled == true end
	end

	if context.name == "minecraft:bee_nest" or context.name == "minecraft:beehive" then
		return triggerBeehive( context )
	end
	if context.canTriggerBlocks ~= true then return false end
	if context.name == "minecraft:lever" then return triggerLever( context ) end
	if context.name == "minecraft:bell" then return triggerBell( context ) end
	if isCandle( context.name ) then return triggerCandle( context ) end
	if string.match( context.name, "_button$") then return triggerButton( context ) end
	if string.match( context.name, "_fence_gate$") then return triggerFenceGate( context ) end
	if string.match( context.name, "_trapdoor$") then return triggerTrapdoor( context ) end
	if string.match( context.name, "_door$") then return triggerDoor( context ) end
	return false
end
